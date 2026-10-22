;;; cmacs-vidstudio-ai.el --- AI editing for vidstudio  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Cutting a long recording down to its good parts, and captioning it.
;;
;; The asset that makes this work is `cmacs-transcribe': it already
;; produces a timestamped transcript, so a model can be asked which
;; *spans* are worth keeping — a text question about text, which models
;; are good at — instead of being asked to watch a video, which they are
;; not.  The spans then compile into vidstudio clips.
;;
;; Captions are close to free: transcribe already writes an .srt, and
;; ffmpeg burns one in with a filter.  Nothing here re-derives timing.
;;
;; Guarded at load, like the imgedit layer: no configure flag, no C
;; dependency, and vidstudio is unaffected when cmacs-ai is absent.

;;; Code:

(require 'cmacs-vidstudio nil 'noerror)
(require 'cmacs-ai-call nil 'noerror)
;; For `cmacs-brigade-deftool' below.  Soft: the direct commands work
;; without the brigade, they simply are not published as agent tools.
(require 'cmacs-brigade-registry nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-vidstudio--open-handle "cmacs-vidstudio"
                  (handle name &optional file))
(declare-function cmacs-vidstudio--secs-to-frames "cmacs-vidstudio" (secs))
(declare-function cmacs-vidstudio--render "cmacs-vidstudio" ())
(defvar cmacs-vidstudio--handle)
(defvar cmacs-vidstudio--active-track)

(defgroup cmacs-vidstudio-ai nil
  "Prompt-driven video editing."
  :group 'cmacs-vidstudio
  :prefix "cmacs-vidstudio-ai-")

(defcustom cmacs-vidstudio-ai-model nil
  "Model used to choose highlights.  nil means the default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-vidstudio-ai)

(defcustom cmacs-vidstudio-ai-pad-seconds 0.4
  "Seconds of padding added to each side of a chosen span.

A cut exactly on a word boundary sounds clipped; a little air either side
is the difference between a highlight and an edit that draws attention to
itself."
  :type 'number
  :group 'cmacs-vidstudio-ai)

(defconst cmacs-vidstudio-ai-highlight-prompt
  "You are given a timestamped transcript of a recording.

Choose the spans worth keeping for a highlight reel.  Return JSON only:
a list of objects with \"start\", \"end\" (both seconds, numbers) and
\"why\" (a short phrase).

Prefer complete thoughts.  A span that starts mid-sentence reads as a
mistake however good the content is.  Prefer fewer, longer spans over
many short ones -- a reel that cuts every four seconds is exhausting to
watch.

If nothing in the recording is worth keeping, return an empty list.  That
is a legitimate answer and much more useful than padding the reel."
  "Prompt used to pick highlight spans.")


;;;; Transcript

(defun cmacs-vidstudio-ai--transcript (file)
  "Return FILE's timestamped transcript as a list of (START END TEXT).

Reads a sidecar .srt when transcribe has already produced one -- there
is no reason to transcribe the same recording twice."
  (let ((srt (concat (file-name-sans-extension file) ".srt")))
    (cond
     ((file-readable-p srt) (cmacs-vidstudio-ai--parse-srt srt))
     ((fboundp 'cmacs-transcribe-file)
      (user-error "cmacs-vidstudio: no transcript for %s; run \
M-x cmacs-transcribe on it first" (file-name-nondirectory file)))
     (t (user-error "cmacs-vidstudio: no transcript and no transcriber")))))

(defun cmacs-vidstudio-ai--parse-srt (file)
  "Parse SRT FILE into (START END TEXT) triples, seconds as floats."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (out)
      (while (re-search-forward
              "\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)[,.]\\([0-9]+\\)[ \t]*-->[ \t]*\
\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)[,.]\\([0-9]+\\)"
              nil t)
        (let ((start (cmacs-vidstudio-ai--srt-secs
                      (match-string 1) (match-string 2)
                      (match-string 3) (match-string 4)))
              (end (cmacs-vidstudio-ai--srt-secs
                    (match-string 5) (match-string 6)
                    (match-string 7) (match-string 8)))
              (text ""))
          (forward-line 1)
          (while (and (not (eobp)) (not (looking-at-p "^[ \t]*$")))
            (setq text (concat text (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position)) " "))
            (forward-line 1))
          (push (list start end (string-trim text)) out)))
      (nreverse out))))

(defun cmacs-vidstudio-ai--srt-secs (h m s ms)
  (+ (* 3600 (string-to-number h))
     (* 60 (string-to-number m))
     (string-to-number s)
     (/ (string-to-number ms) 1000.0)))

(defun cmacs-vidstudio-ai--transcript-text (segments)
  "Render SEGMENTS as text a model can reason about."
  (mapconcat (lambda (seg)
               (format "[%.1f-%.1f] %s" (nth 0 seg) (nth 1 seg) (nth 2 seg)))
             segments "\n"))


;;;; Highlights

(defun cmacs-vidstudio-ai-suggest-spans (file &optional brief)
  "Ask a model which spans of FILE are worth keeping.

Returns a list of plists with :start, :end and :why.  BRIEF adds extra
direction, such as \"only the parts about the build system\"."
  (let* ((segments (cmacs-vidstudio-ai--transcript file))
         (prompt (concat (when brief (format "Additional direction: %s\n\n" brief))
                         "Transcript:\n\n"
                         (cmacs-vidstudio-ai--transcript-text segments)))
         (answer (cmacs-ai-call prompt
                                :system cmacs-vidstudio-ai-highlight-prompt
                                :model cmacs-vidstudio-ai-model)))
    (cmacs-vidstudio-ai--parse-spans answer)))

(defun cmacs-vidstudio-ai--parse-spans (answer)
  "Extract span plists from ANSWER.

Models wrap JSON in prose and fences however firmly they are asked not
to, so the JSON is located rather than assumed to be the whole reply."
  (let* ((start (string-search "[" answer))
         (end (and start (cl-position ?\] answer :from-end t)))
         (json (and start end (substring answer start (1+ end)))))
    (when json
      (condition-case nil
          (let ((parsed (json-parse-string json :object-type 'alist
                                          :array-type 'list
                                          :null-object nil :false-object nil)))
            (delq nil
                  (mapcar
                   (lambda (o)
                     (let ((s (alist-get 'start o))
                           (e (alist-get 'end o)))
                       (when (and (numberp s) (numberp e) (> e s))
                         (list :start s :end e
                               :why (or (alist-get 'why o) "")))))
                   parsed)))
        (error nil)))))

;;;###autoload
(defun cmacs-vidstudio-ai-suggest-cuts (file &optional brief)
  "Show the spans a model would keep from FILE, without editing anything.

Separate from applying them on purpose: seeing the proposal before it
rearranges a timeline is the difference between a suggestion and a
surprise."
  (interactive "fRecording: \nsExtra direction (optional): ")
  (let ((spans (cmacs-vidstudio-ai-suggest-spans
                file (unless (string-empty-p (or brief "")) brief))))
    (if (null spans)
        (message "cmacs-vidstudio: nothing suggested")
      (with-current-buffer (get-buffer-create "*vidstudio cuts*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Suggested cuts for %s\n\n"
                          (file-name-nondirectory file)))
          (dolist (s spans)
            (insert (format "  %6.1fs - %6.1fs  (%.1fs)  %s\n"
                            (plist-get s :start) (plist-get s :end)
                            (- (plist-get s :end) (plist-get s :start))
                            (plist-get s :why))))
          (insert (format "\n  %d span(s), %.1fs total\n"
                          (length spans)
                          (cl-reduce #'+ spans :initial-value 0.0
                                     :key (lambda (s) (- (plist-get s :end)
                                                         (plist-get s :start)))))))
        (special-mode)
        (display-buffer (current-buffer))))
    spans))

;;;###autoload
(defun cmacs-vidstudio-ai-build-reel (file &optional brief)
  "Build a highlight reel from FILE into a new vidstudio project.

Each suggested span becomes one video clip on the first track, sliced
from FILE (padded by `cmacs-vidstudio-ai-pad-seconds').  Returns the
project handle; interactively the project is also opened in an editor."
  (interactive "fRecording: \nsExtra direction (optional): ")
  (unless (fboundp 'cmacs-vidstudio-new)
    (user-error "cmacs-vidstudio is not available in this build"))
  (let ((spans (cmacs-vidstudio-ai-suggest-spans
                file (unless (string-empty-p (or brief "")) brief))))
    (when (null spans)
      (user-error "cmacs-vidstudio: nothing worth keeping was suggested"))
    (let* ((handle (cmacs-vidstudio-new 1920 1080 30))
           (path (expand-file-name file))
           (pad cmacs-vidstudio-ai-pad-seconds)
           (n 0))
      (dolist (s spans)
        ;; Padded outward and clamped at zero: a cut exactly on a word
        ;; boundary sounds clipped.  The DEFUN takes (TRACK PATH DURATION
        ;; IN-SEC OUT-SEC); DURATION nil derives it from the slice.
        (let ((start (max 0.0 (- (plist-get s :start) pad)))
              (end (+ (plist-get s :end) pad)))
          (cmacs-vidstudio-add-video-clip handle 0 path nil start end)
          (setq n (1+ n))))
      (message "cmacs-vidstudio: reel with %d clip(s)" n)
      (when (and (called-interactively-p 'any)
                 (fboundp 'cmacs-vidstudio--open-handle))
        (cmacs-vidstudio--open-handle
         handle (format "*vidstudio reel: %s*" (file-name-nondirectory file))))
      handle)))

;;;###autoload
(defun cmacs-vidstudio-ai-auto-caption (file)
  "Caption the current project from FILE's existing transcript.

Costs nothing to compute: transcribe already wrote the timings into a
sidecar .srt, which is added as a caption clip on the active track,
running for as long as the transcript does."
  (interactive "fRecording: ")
  (unless (and (boundp 'cmacs-vidstudio--handle) cmacs-vidstudio--handle)
    (user-error "Not in a vidstudio buffer"))
  (let* ((segments (cmacs-vidstudio-ai--transcript file))
         (srt (concat (file-name-sans-extension (expand-file-name file))
                      ".srt"))
         (end (apply #'max 0.1 (mapcar #'cadr segments))))
    (unless (file-readable-p srt)
      (user-error "cmacs-vidstudio: no .srt next to %s"
                  (file-name-nondirectory file)))
    (cmacs-vidstudio-add-caption cmacs-vidstudio--handle
                                 cmacs-vidstudio--active-track
                                 (cmacs-vidstudio--secs-to-frames end) srt)
    (when (fboundp 'cmacs-vidstudio--render) (cmacs-vidstudio--render))
    (message "cmacs-vidstudio: %d caption(s)" (length segments))
    (length segments)))


;;;; Right-click menu
;;
;; Registered on `cmacs-vidstudio-context-menu-functions' like any other
;; provider -- vidstudio itself knows nothing about this file.  The hook
;; form is autoloaded, so the AI entries are in the menu from the first
;; right-click of a session; calling the (autoloaded) item function is
;; what loads this file.  Visibility is decided by the C DEFUN
;; `cmacs-ai-supported-p', never by `fboundp' on lazily-loaded Elisp,
;; which reports "no AI" until something else happens to load it.

;;;###autoload
(defun cmacs-vidstudio-ai-context-menu-items (_ctx)
  "The AI entries of the vidstudio right-click menu."
  (when (and (fboundp 'cmacs-ai-supported-p) (cmacs-ai-supported-p))
    (let ((model (or (fboundp 'cmacs-ai-call)
                     (and (locate-library "cmacs-ai-call") t))))
      `((:sep)
        (:id ai :label "AI"
         :items
         ((:label "Suggest cuts from a recording…" :enable ,model
           :command cmacs-vidstudio-ai-suggest-cuts)
          (:label "Build a highlight reel…" :enable ,model
           :command cmacs-vidstudio-ai-build-reel)
          (:label "Captions from a transcript…"
           :command cmacs-vidstudio-ai-auto-caption)))))))

;;;###autoload
(with-eval-after-load 'cmacs-vidstudio
  (add-hook 'cmacs-vidstudio-context-menu-functions
            #'cmacs-vidstudio-ai-context-menu-items 90))


;;;; Brigade tools

(when (fboundp 'cmacs-brigade-deftool)
  (cmacs-brigade-deftool video-suggest-cuts
    "Given a recording that has already been transcribed, propose which
spans are worth keeping for a highlight reel.  Returns the spans; it
does not edit anything."
    ((file string "Path to the recording")
     (brief string "Extra direction, e.g. 'only the parts about X'"
            :optional t))
    :group 'vidstudio
    (condition-case err
        (let ((spans (cmacs-vidstudio-ai-suggest-spans file brief)))
          (if (null spans) "No spans suggested."
            (mapconcat (lambda (s)
                         (format "%.1f-%.1f (%.1fs): %s"
                                 (plist-get s :start) (plist-get s :end)
                                 (- (plist-get s :end) (plist-get s :start))
                                 (plist-get s :why)))
                       spans "\n")))
      (error (format "Error: %s" (error-message-string err))))))

(provide 'cmacs-vidstudio-ai)

;;; cmacs-vidstudio-ai.el ends here
