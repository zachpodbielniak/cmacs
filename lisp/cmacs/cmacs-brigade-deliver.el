;;; cmacs-brigade-deliver.el --- Turning agent output into artifacts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Four deliverables -- a cited report, a slide deck, a podcast, a
;; highlight reel -- each of which is mostly a spec plus a subsystem that
;; already exists.  ox-html exports, org-tree-slide presents, piper
;; speaks, vidstudio cuts.  What is genuinely new is small and named in
;; each section.
;;
;; The interesting one is the Sparkpage citation model.  An agent that
;; writes a confident paragraph with no source is the failure mode of
;; every research tool, and the only defence that works is refusing to
;; produce the artifact.  So the linter is not advisory: an uncited claim
;; fails the export.
;;
;; All four register through the public deliverable registry, so a fifth
;; is one form in a user's config and needs nothing from this file.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)
(require 'org)

(defgroup cmacs-brigade-deliver nil
  "Artifacts produced from agent output."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-deliver-")

(defcustom cmacs-brigade-deliver-directory nil
  "Where deliverables are written.  Defaults under the state directory."
  :type '(choice (const :tag "Default" nil) directory)
  :group 'cmacs-brigade-deliver)

(defcustom cmacs-brigade-deliver-require-citations t
  "Whether an uncited claim fails a Sparkpage export.

On, and it should stay on.  A research artifact whose citations are
optional is one whose citations are decorative, and the whole reason to
generate a cited report rather than a summary is that the claims can be
checked."
  :type 'boolean
  :group 'cmacs-brigade-deliver)

(defcustom cmacs-brigade-deliver-pod-voices '("en_US-amy-medium" "en_US-ryan-medium")
  "Piper voices used for the two speakers in a pod."
  :type '(repeat string)
  :group 'cmacs-brigade-deliver)

(define-error 'cmacs-brigade-deliver-error
  "Deliverable error" 'cmacs-brigade-error)

(defun cmacs-brigade-deliver--dir ()
  (or cmacs-brigade-deliver-directory
      (expand-file-name "deliverables" cmacs-brigade-state-dir)))

(defun cmacs-brigade-deliver (kind source &rest options)
  "Render SOURCE as a KIND deliverable.  Returns the output path.

SOURCE is an org file or buffer produced by an agent."
  (let ((d (cmacs-brigade-registry-get 'deliverable kind)))
    (unless d
      (signal 'cmacs-brigade-deliver-error
              (list (format "no deliverable named %s" kind))))
    (when-let* ((validate (plist-get d :validate)))
      (let ((problems (funcall validate source)))
        (when problems
          (signal 'cmacs-brigade-deliver-error
                  (cons (format "%s is not ready:" kind) problems)))))
    (apply (plist-get d :render) source options)))

;;;###autoload
(defun cmacs-brigade-deliver-list ()
  "Show the registered deliverable kinds."
  (interactive)
  (message "cmacs-brigade deliverables: %s"
           (mapconcat #'symbol-name
                      (cmacs-brigade-registry-list 'deliverable) ", ")))


;;;; Sparkpage
;;
;; A cited report.  ox-html does the export; the citation model is what
;; is new.
;;
;; Sources live in a `#+BRIGADE_SOURCES:' drawer and claims reference
;; them as [[cite:id]].  The linter walks paragraphs and fails the export
;; when an assertion carries no citation.

(defun cmacs-brigade-deliver--sources (buffer)
  "Return the source ids declared in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (ids)
        (while (re-search-forward "^#\\+BRIGADE_SOURCE:[ \t]*\\([^ \t\n]+\\)" nil t)
          (push (match-string-no-properties 1) ids))
        (nreverse ids)))))

(defun cmacs-brigade-deliver--citations (buffer)
  "Return the citation ids referenced in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (ids)
        (while (re-search-forward "\\[\\[cite:\\([^]]+\\)\\]\\]" nil t)
          (push (match-string-no-properties 1) ids))
        (nreverse (delete-dups ids))))))

(defun cmacs-brigade-deliver--lint-sparkpage (source)
  "Return a list of problems with SOURCE, or nil.

Two failures matter: a claim with no citation, and a citation naming a
source that was never declared.  The first is the tool inventing things;
the second is the tool citing something that does not exist, which reads
as more trustworthy and is worse."
  (let ((buffer (cmacs-brigade-deliver--as-buffer source))
        problems)
    (with-current-buffer buffer
      (let ((declared (cmacs-brigade-deliver--sources buffer))
            (cited (cmacs-brigade-deliver--citations buffer)))
        (dolist (c cited)
          (unless (member c declared)
            (push (format "cites %s, which is not declared" c) problems)))
        (when cmacs-brigade-deliver-require-citations
          (save-excursion
            (goto-char (point-min))
            (let ((n 0))
              (while (re-search-forward "^\\([A-Z][^\n]\\{40,\\}\\)$" nil t)
                (let ((line (match-string-no-properties 1)))
                  ;; A substantial prose line with no citation anywhere in
                  ;; its paragraph is an assertion nobody can check.
                  (unless (or (string-match-p "\\[\\[cite:" line)
                              (save-excursion
                                (forward-line 1)
                                (looking-at-p ".*\\[\\[cite:")))
                    (setq n (1+ n)))))
              (when (> n 0)
                (push (format "%d claim(s) with no citation" n) problems)))))))
    (nreverse problems)))

(defun cmacs-brigade-deliver--as-buffer (source)
  (cond ((bufferp source) source)
        ((and (stringp source) (file-readable-p source))
         (find-file-noselect source))
        (t (signal 'cmacs-brigade-deliver-error
                   (list "source is not a file or buffer" source)))))

(defun cmacs-brigade-deliver--render-sparkpage (source &rest _)
  "Export SOURCE as a single self-contained HTML file."
  (let* ((buffer (cmacs-brigade-deliver--as-buffer source))
         (dir (cmacs-brigade-deliver--dir))
         (out (expand-file-name
               (format "%s.html"
                       (file-name-base (or (buffer-file-name buffer)
                                           (buffer-name buffer))))
               dir)))
    (make-directory dir t)
    (with-current-buffer buffer
      ;; Inlined rather than linked: a report that only renders next to
      ;; its assets is one you cannot send to anybody.
      (let ((org-html-htmlize-output-type 'inline-css)
            (org-export-with-broken-links t))
        (org-export-to-file 'html out)))
    out))

(cmacs-brigade-register-deliverable
 :name 'sparkpage
 :description "A cited report, exported as one self-contained HTML file."
 :extension "html"
 :validate #'cmacs-brigade-deliver--lint-sparkpage
 :render #'cmacs-brigade-deliver--render-sparkpage)


;;;; Slides
;;
;; org-tree-slide already presents an org file in Emacs -- including in a
;; terminal -- so a deck is a spec over headlines rather than a new
;; renderer.  One subtree per slide, :LAYOUT: choosing how it is shown.

(defconst cmacs-brigade-deliver-slide-layouts
  '("title" "bullets" "image" "chart" "quote" "code")
  "Recognised :LAYOUT: values.")

(defun cmacs-brigade-deliver--lint-slides (source)
  "Check SOURCE's slide layouts."
  (let ((buffer (cmacs-brigade-deliver--as-buffer source))
        problems)
    (with-current-buffer buffer
      (org-map-entries
       (lambda ()
         (let ((layout (org-entry-get nil "LAYOUT")))
           (when (and layout
                      (not (member layout cmacs-brigade-deliver-slide-layouts)))
             (push (format "%s: unknown layout %s"
                           (org-get-heading t t t t) layout)
                   problems))))
       ;; nil, not 'file: a deliverable is routinely handed a buffer that
       ;; is not visiting a file, and 'file signals there.
       nil nil))
    (nreverse problems)))

(defun cmacs-brigade-deliver--render-slides (source &rest _)
  "Export SOURCE as a reveal.js deck, or HTML when ox-reveal is absent."
  (let* ((buffer (cmacs-brigade-deliver--as-buffer source))
         (dir (cmacs-brigade-deliver--dir))
         (out (expand-file-name
               (format "%s-slides.html"
                       (file-name-base (or (buffer-file-name buffer)
                                           (buffer-name buffer))))
               dir)))
    (make-directory dir t)
    (with-current-buffer buffer
      (if (fboundp 'org-re-reveal-export-to-html)
          (let ((f (funcall 'org-re-reveal-export-to-html)))
            (rename-file f out t))
        ;; No reveal backend: plain HTML still presents, and
        ;; org-tree-slide presents the org file itself in Emacs.
        (let ((org-export-with-broken-links t))
          (org-export-to-file 'html out))))
    out))

(cmacs-brigade-register-deliverable
 :name 'slides
 :description "A deck: one subtree per slide, presentable in Emacs or a browser."
 :extension "html"
 :validate #'cmacs-brigade-deliver--lint-slides
 :render #'cmacs-brigade-deliver--render-slides)


;;;; Pod
;;
;; A two-voice conversation.  piper speaks each turn, ffmpeg concatenates.
;; The script format is a headline per turn with a :VOICE: property.

(defun cmacs-brigade-deliver--pod-turns (buffer)
  "Return (VOICE . TEXT) for each turn in BUFFER."
  (with-current-buffer buffer
    (let (turns)
      (org-map-entries
       (lambda ()
         (let ((voice (or (org-entry-get nil "VOICE") "a"))
               (text (cmacs-brigade-deliver--entry-text)))
           (when (and text (not (string-empty-p (string-trim text))))
             (push (cons voice (string-trim text)) turns))))
       nil nil)
      (nreverse turns))))

(defun cmacs-brigade-deliver--entry-text ()
  "Return the body of the entry at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (forward-line 1)
      ;; Skip whole drawers, not just their delimiters: matching only
      ;; :PROPERTIES: and :END: leaves every property between them in the
      ;; body, which for a pod means the narrator reads them aloud.
      (while (looking-at-p "^[ \t]*:[A-Za-z]+:")
        (if (looking-at-p "^[ \t]*:\\(PROPERTIES\\|LOGBOOK\\):")
            (progn (re-search-forward "^[ \t]*:END:" end t) (forward-line 1))
          (forward-line 1)))
      (string-trim (buffer-substring-no-properties
                    (min (point) end) (min end (point-max)))))))

(defun cmacs-brigade-deliver--lint-pod (source)
  (let ((turns (cmacs-brigade-deliver--pod-turns
                (cmacs-brigade-deliver--as-buffer source))))
    (cond ((null turns) (list "no turns with any text"))
          ((not (fboundp 'cmacs-piper-synthesize-to-file))
           (list "cmacs-piper is not available in this build"))
          (t nil))))

(defun cmacs-brigade-deliver--render-pod (source &rest _)
  "Speak SOURCE's turns and concatenate them into one audio file."
  (let* ((buffer (cmacs-brigade-deliver--as-buffer source))
         (turns (cmacs-brigade-deliver--pod-turns buffer))
         (dir (cmacs-brigade-deliver--dir))
         (work (make-temp-file "cmacs-pod" t))
         (out (expand-file-name
               (format "%s.mp3" (file-name-base
                                 (or (buffer-file-name buffer)
                                     (buffer-name buffer))))
               dir))
         (voices cmacs-brigade-deliver-pod-voices)
         (parts nil)
         (i 0))
    (make-directory dir t)
    (unwind-protect
        (progn
          (dolist (turn turns)
            (let* ((which (if (member (car turn) '("b" "B" "2")) 1 0))
                   (voice (or (nth which voices) (car voices)))
                   (wav (expand-file-name (format "%03d.wav" i) work)))
              (cmacs-piper-synthesize-to-file (cdr turn) wav voice)
              (push wav parts)
              (setq i (1+ i))))
          (setq parts (nreverse parts))
          (cmacs-brigade-deliver--concat-audio parts out)
          out)
      (delete-directory work t))))

(defun cmacs-brigade-deliver--concat-audio (parts out)
  "Concatenate PARTS into OUT with ffmpeg."
  (unless (executable-find "ffmpeg")
    (signal 'cmacs-brigade-deliver-error (list "ffmpeg is not installed")))
  (let ((list-file (make-temp-file "cmacs-pod-list" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file list-file
            (dolist (p parts)
              ;; ffmpeg's concat demuxer needs single quotes escaped, and
              ;; a temp path can contain anything.
              (insert (format "file '%s'\n"
                              (string-replace "'" "'\\''" p)))))
          (unless (zerop (call-process "ffmpeg" nil nil nil
                                       "-y" "-f" "concat" "-safe" "0"
                                       "-i" list-file "-b:a" "192k" out))
            (signal 'cmacs-brigade-deliver-error (list "ffmpeg concat failed"))))
      (delete-file list-file))))

(cmacs-brigade-register-deliverable
 :name 'pod
 :description "A two-voice audio conversation, spoken offline by piper."
 :extension "mp3"
 :validate #'cmacs-brigade-deliver--lint-pod
 :render #'cmacs-brigade-deliver--render-pod)


;;;; Clip
;;
;; A highlight reel.  The span selection lives in cmacs-vidstudio-ai; this
;; is the deliverable wrapper so it composes with the rest.

(defun cmacs-brigade-deliver--lint-clip (source)
  (cond ((not (stringp source)) (list "source must be a recording path"))
        ((not (file-readable-p source)) (list "recording is not readable"))
        ((not (fboundp 'cmacs-vidstudio-ai-suggest-spans))
         (list "cmacs-vidstudio AI is not available in this build"))
        (t nil)))

(defun cmacs-brigade-deliver--render-clip (source &rest options)
  "Build a highlight reel from the recording at SOURCE."
  (let* ((dir (cmacs-brigade-deliver--dir))
         (out (expand-file-name
               (format "%s-reel.mp4" (file-name-base source)) dir))
         (handle (apply #'cmacs-vidstudio-ai-build-reel source
                        (list (plist-get options :brief)))))
    (make-directory dir t)
    (cmacs-vidstudio-export-video handle out)
    out))

(cmacs-brigade-register-deliverable
 :name 'clip
 :description "A highlight reel cut from a transcribed recording."
 :extension "mp4"
 :validate #'cmacs-brigade-deliver--lint-clip
 :render #'cmacs-brigade-deliver--render-clip)


;;;; Tool

(cmacs-brigade-deftool deliverable-emit
  "Turn an org file you have written into a finished artifact.  KIND is
one of sparkpage, slides, pod or clip.  Returns the path, or the reasons
it was refused."
  ((kind string "sparkpage, slides, pod or clip")
   (source string "Path to the org file (or recording, for clip)"))
  :group 'deliver :destructive t
  (condition-case err
      (format "Wrote %s" (cmacs-brigade-deliver (intern kind) source))
    (cmacs-brigade-deliver-error
     ;; Reported rather than signalled so the agent can fix the document
     ;; and try again -- which for an uncited claim is exactly what it
     ;; should do.
     (format "Refused: %s" (string-join (cdr err) "; ")))
    (error (format "Error: %s" (error-message-string err)))))

(provide 'cmacs-brigade-deliver)

;;; cmacs-brigade-deliver.el ends here
