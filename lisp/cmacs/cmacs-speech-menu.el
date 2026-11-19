;;; cmacs-speech-menu.el --- the right-click Speech menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One top-level "Speech" entry on the right-click menu, everywhere,
;; whose contents depend on what was clicked:
;;
;;   text / a region   Speak, Speak with voice ▸, Read from here,
;;                     Save speech as WAV, Add punctuation, Stop speaking
;;   an audio or video file (dired, an org link, a file name at point,
;;   the file a buffer visits)
;;                     Transcribe ▸, Who spoke?, Identify speaker,
;;                     Detect language, What's in this audio?, Clean up
;;                     noise, Split vocals, Ingest into the second brain
;;   anywhere          Dictate here, Voice loop, Speech settings…
;;
;; Items are `cmacs-media-menu' plists, so the same definition renders as
;; a GTK menu, in the --lrg engine and through the keyboard fallbacks,
;; and anything else can add to it with `add-hook' on
;; `cmacs-speech-context-menu-functions'.  An item is offered only when
;; something can run it now -- a component whose engine and model
;; resolve -- so the menu never lists an action that would just fail.
;;
;; Everything slow runs asynchronously and lands in a buffer or a file
;; next to the input; nothing here blocks the editor.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-speech)
(require 'cmacs-menu)
(require 'cmacs-media-menu)

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function cmacs-voice-speak "cmacs-voice" (text &optional voice))
(declare-function cmacs-voice-speaking-p "cmacs-voice" ())
(declare-function cmacs-voice-stop-speaking "cmacs-voice" ())
(declare-function cmacs-speech-sherpa-speakers "cmacs-speech-sherpa" (&optional model))
(declare-function cmacs-secondbrain-ingest-file "cmacs-secondbrain-ingest" (file &rest opts))

(defgroup cmacs-speech-menu nil
  "The right-click Speech menu."
  :group 'cmacs-speech
  :prefix "cmacs-speech-menu-")

(defcustom cmacs-speech-menu-auto-enable t
  "Install the Speech entry on the right-click menu at startup."
  :type 'boolean
  :group 'cmacs-speech-menu)

(defcustom cmacs-speech-menu-media-extensions
  '("wav" "mp3" "ogg" "oga" "opus" "flac" "m4a" "aac" "wma" "aiff"
    "mp4" "mkv" "webm" "mov" "avi" "m4v")
  "File extensions the Speech menu treats as audio/video."
  :type '(repeat string)
  :group 'cmacs-speech-menu)

(defcustom cmacs-speech-context-menu-functions
  '(cmacs-speech-menu-text-items
    cmacs-speech-menu-file-items
    cmacs-speech-menu-anywhere-items)
  "Providers of Speech menu items: each is called with the click context.
The context is a plist (:buffer :text :region :file :point).  Each
function returns a list of `cmacs-media-menu' items (see that file's
Commentary).  Add your own with `add-hook'."
  :type 'hook
  :group 'cmacs-speech-menu)

;;;; Context

(defun cmacs-speech-menu--media-p (file)
  "Non-nil when FILE is an existing audio or video file."
  (and (stringp file)
       (member (downcase (or (file-name-extension file) ""))
               cmacs-speech-menu-media-extensions)
       (file-readable-p file)
       (not (file-directory-p file))))

(defun cmacs-speech-menu--file-at-point ()
  "An audio/video file named at point, by dired, an org link, or the text."
  (let ((candidates
         (list (and (derived-mode-p 'dired-mode) (ignore-errors (dired-get-filename nil t)))
               (and (derived-mode-p 'org-mode)
                    (ignore-errors
                      (let ((el (org-element-context)))
                        (and (eq (car el) 'link)
                             (member (org-element-property :type el) '("file" "attachment"))
                             (expand-file-name (org-element-property :path el))))))
               (ignore-errors (let ((f (thing-at-point 'filename t)))
                                (and f (expand-file-name f))))
               buffer-file-name)))
    (cl-find-if #'cmacs-speech-menu--media-p candidates)))

(defun cmacs-speech-menu-context (&optional click)
  "The Speech menu context for mouse CLICK (or point)."
  (let* ((posn (and click (event-start click)))
         (window (and posn (posn-window posn)))
         (buffer (if (windowp window) (window-buffer window) (current-buffer))))
    (with-current-buffer buffer
      (save-excursion
        (when (and posn (integer-or-marker-p (posn-point posn)))
          (goto-char (posn-point posn)))
        (let ((region (and (use-region-p) (cons (region-beginning) (region-end)))))
          (list :buffer buffer
                :point (point)
                :region region
                :text (if region
                          (buffer-substring-no-properties (car region) (cdr region))
                        (let ((s (thing-at-point 'sentence t)))
                          (and s (string-trim s))))
                :file (cmacs-speech-menu--file-at-point)))))))

;;;; Helpers for the actions

(defun cmacs-speech-menu--report (name fmt &rest args)
  "Show a result in buffer *NAME* and return it."
  (with-current-buffer (get-buffer-create (format "*%s*" name))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (apply #'format fmt args))
      (goto-char (point-min)))
    (display-buffer (current-buffer))
    (current-buffer)))

(defun cmacs-speech-menu--clock (ms)
  "MS as HH:MM:SS,mmm (SubRip)."
  (let ((ms (or ms 0)))
    (format "%02d:%02d:%02d,%03d" (/ ms 3600000) (% (/ ms 60000) 60)
            (% (/ ms 1000) 60) (% ms 1000))))

(defun cmacs-speech-menu--srt (segments)
  "SubRip text for whisper-shaped SEGMENTS."
  (let ((i 0))
    (mapconcat (lambda (s)
                 (cl-incf i)
                 (format "%d\n%s --> %s\n%s\n" i
                         (cmacs-speech-menu--clock (alist-get :start s))
                         (cmacs-speech-menu--clock (alist-get :end s))
                         (string-trim (or (alist-get :text s) ""))))
               segments "\n")))

(defun cmacs-speech-menu--sibling (file suffix)
  "FILE with its extension replaced by SUFFIX."
  (concat (file-name-sans-extension file) suffix))

(defun cmacs-speech-menu--can (component)
  "Non-nil when COMPONENT can run right now."
  (and (cmacs-speech-can-p component) t))

;;;; Text actions

(defun cmacs-speech-menu-speak-text (text &optional voice backend)
  "Speak TEXT, with VOICE on BACKEND if given."
  (cmacs-speech-with-config (and backend `((tts ,backend)))
    (cmacs-speech-speak text :voice voice :feature 'reader)))

(defun cmacs-speech-menu-read-from (buffer pos)
  "Read BUFFER aloud from POS, a paragraph at a time, interruptible."
  (require 'cmacs-voice)
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (while (< (point) (point-max))
        (let ((beg (point)))
          (forward-paragraph)
          (let ((s (string-trim (buffer-substring-no-properties beg (point)))))
            (unless (string-empty-p s) (cmacs-voice-speak s))))))))

(defun cmacs-speech-menu-save-wav (text)
  "Synthesise TEXT into a WAV file the user names."
  (let ((file (read-file-name "Save speech to: " nil nil nil "speech.wav")))
    (cmacs-speech-synthesize-to-file
     text file (lambda (r) (message (if (stringp r) "Wrote %s" "Speech failed: %s")
                                    (if (stringp r) r (cdr r)))))))

(defun cmacs-speech-menu-punctuate (buffer region)
  "Replace REGION of BUFFER with a punctuated version."
  (let ((beg (copy-marker (car region))) (end (copy-marker (cdr region) t)))
    (cmacs-speech-punctuate
     (with-current-buffer buffer (buffer-substring-no-properties beg end))
     (lambda (r)
       (if (assq :error r)
           (message "Punctuation: %s" (alist-get :error r))
         (with-current-buffer buffer
           (save-excursion
             (goto-char beg)
             (delete-region beg end)
             (insert (alist-get :text r)))))))))

(defun cmacs-speech-menu--voices ()
  "Installed voices as ((LABEL BACKEND ID) ...)."
  (cl-loop for b in (cmacs-speech-backends 'tts)
           when (cmacs-speech-backend-available-p b 'tts)
           append (mapcar (lambda (id) (list (format "%s  (%s)" id b) b id))
                          (cmacs-speech-backend-models b 'tts))))

(defun cmacs-speech-menu-text-items (ctx)
  "Speech items for text in CTX."
  (let* ((region (plist-get ctx :region))
         ;; Without a region, "the sentence at point" only means something
         ;; in prose: not on a file in dired, not in a listing buffer.
         (text (and (or region
                        (not (or (plist-get ctx :file)
                                 (with-current-buffer (plist-get ctx :buffer)
                                   (derived-mode-p 'special-mode 'dired-mode)))))
                    (plist-get ctx :text))))
    (append
     (when (and text (not (string-empty-p text)) (cmacs-speech-menu--can 'tts))
       (list
        (list :label (if region "Speak selection" "Speak sentence")
              :action (lambda (c) (cmacs-speech-menu-speak-text (plist-get c :text)))
              :help "Say it with the voice chosen in M-x cmacs-speech")
        (list :label "Speak with voice"
              :items (lambda (_c)
                       (mapcar (lambda (v)
                                 (list :label (nth 0 v)
                                       :action (lambda (c)
                                                 (cmacs-speech-menu-speak-text
                                                  (plist-get c :text) (nth 2 v) (nth 1 v)))))
                               (cmacs-speech-menu--voices))))
        (list :label "Read aloud from here"
              :action (lambda (c) (cmacs-speech-menu-read-from (plist-get c :buffer)
                                                               (plist-get c :point))))
        (list :label "Save speech as WAV…"
              :action (lambda (c) (cmacs-speech-menu-save-wav (plist-get c :text))))))
     (when (and region (cmacs-speech-menu--can 'punctuate))
       (list (list :label "Add punctuation"
                   :action (lambda (c) (cmacs-speech-menu-punctuate (plist-get c :buffer)
                                                                    (plist-get c :region)))
                   :help "Punctuate and case raw transcript text")))
     (when (or (cmacs-speech-speaking-p)
               (and (fboundp 'cmacs-voice-speaking-p) (cmacs-voice-speaking-p)))
       (list (list :label "Stop speaking"
                   :action (lambda (_c)
                             (cmacs-speech-stop-speaking)
                             (when (fboundp 'cmacs-voice-stop-speaking)
                               (cmacs-voice-stop-speaking)))))))))

;;;; File actions

(defun cmacs-speech-menu-transcribe (file how &optional backend model)
  "Transcribe FILE; HOW is `buffer', `txt', `srt' or `org'."
  (message "Transcribing %s…" (file-name-nondirectory file))
  (cmacs-speech-transcribe-file
   file
   (lambda (r)
     (if (assq :error r)
         (message "Transcription failed: %s" (alist-get :error r))
       (let ((text (string-trim (or (alist-get :text r) "")))
             (segs (alist-get :segments r)))
         (pcase how
           ('txt (with-temp-file (cmacs-speech-menu--sibling file ".txt") (insert text "\n"))
                 (message "Wrote %s" (cmacs-speech-menu--sibling file ".txt")))
           ('srt (with-temp-file (cmacs-speech-menu--sibling file ".srt")
                   (insert (cmacs-speech-menu--srt segs)))
                 (message "Wrote %s" (cmacs-speech-menu--sibling file ".srt")))
           ('org (with-current-buffer (cmacs-speech-menu--report
                                       "transcript"
                                       "#+title: Transcript of %s\n#+created: %s\n\n* Transcript\n\n%s\n\n* Segments\n%s"
                                       (file-name-nondirectory file)
                                       (format-time-string "%FT%T%z") text
                                       (mapconcat (lambda (s) (format "- [%s] %s"
                                                                      (substring (cmacs-speech-menu--clock (alist-get :start s)) 0 8)
                                                                      (string-trim (alist-get :text s))))
                                                  segs "\n"))
                   (org-mode)))
           (_ (cmacs-speech-menu--report "transcript" "%s\n\n(%s, %s)" text
                                         (alist-get :backend r) (alist-get :model r)))))))
   :component 'stt :backend backend :model model))

(defun cmacs-speech-menu-who-spoke (file)
  "Diarize and transcribe FILE into a speaker-labelled org transcript."
  (message "Working out who spoke in %s…" (file-name-nondirectory file))
  (cmacs-speech-file-pcm
   file
   (lambda (got)
     (if (eq (car got) :error)
         (message "%s" (cdr got))
       (let ((pcm (car got)))
         (cmacs-speech-diarize
          pcm
          (lambda (d)
            (if (assq :error d)
                (message "Diarization failed: %s" (alist-get :error d))
              (cmacs-speech-transcribe
               pcm
               (lambda (tr)
                 (cmacs-speech-menu--report
                  "who spoke"
                  "#+title: Who spoke in %s\n\n%d speakers.\n\n%s\n"
                  (file-name-nondirectory file) (alist-get :num-speakers d)
                  (cmacs-speech-menu-label-speakers (alist-get :segments d)
                                                    (alist-get :segments tr)))
                 (with-current-buffer "*who spoke*" (org-mode) (visual-line-mode 1)))
               :component 'stt :rate (cdr got))))
          :rate (cdr got)))))))

(defalias 'cmacs-speech-menu-label-speakers #'cmacs-speech-label-speakers)

(defun cmacs-speech-menu--file-pcm-then (file fn)
  "Call FN with (PCM . RATE) of FILE, or report the error."
  (cmacs-speech-file-pcm file (lambda (got)
                                (if (eq (car got) :error) (message "%s" (cdr got))
                                  (funcall fn got)))))

(defun cmacs-speech-menu-detect-language (file)
  "Message the spoken language of FILE."
  (cmacs-speech-menu--file-pcm-then
   file (lambda (got)
          (cmacs-speech-detect-language
           (car got) (lambda (r) (message "%s: %s" (file-name-nondirectory file)
                                          (or (alist-get :lang r) (alist-get :error r))))
           :rate (cdr got)))))

(defun cmacs-speech-menu-tag (file)
  "Show what sounds are in FILE."
  (cmacs-speech-menu--file-pcm-then
   file (lambda (got)
          (cmacs-speech-tag-audio
           (car got)
           (lambda (r)
             (if (assq :error r) (message "%s" (alist-get :error r))
               (message "%s: %s" (file-name-nondirectory file)
                        (mapconcat (lambda (e) (format "%s %.0f%%" (alist-get :name e)
                                                       (* 100 (alist-get :prob e))))
                                   (alist-get :events r) ", "))))
           :rate (cdr got)))))

(defun cmacs-speech-menu-denoise (file)
  "Write a denoised copy of FILE beside it."
  (cmacs-speech-menu--file-pcm-then
   file (lambda (got)
          (cmacs-speech-denoise
           (car got)
           (lambda (r)
             (if (assq :error r) (message "%s" (alist-get :error r))
               (let ((out (cmacs-speech-menu--sibling file ".denoised.wav")))
                 (cmacs-speech-write-wav out (alist-get :pcm r) (alist-get :sample-rate r))
                 (message "Wrote %s" out))))
           :rate (cdr got)))))

(defun cmacs-speech-menu-separate (file)
  "Write vocals and accompaniment of FILE beside it."
  (cmacs-speech-menu--file-pcm-then
   file (lambda (got)
          (cmacs-speech-separate
           (car got)
           (lambda (r)
             (if (assq :error r) (message "%s" (alist-get :error r))
               (let ((names '("vocals" "accompaniment" "drums" "bass" "other")) out)
                 (dolist (s (alist-get :stems r))
                   (let ((f (cmacs-speech-menu--sibling
                             file (format ".%s.wav" (or (nth (alist-get :index s) names)
                                                       (alist-get :index s))))))
                     (cmacs-speech-write-wav f (alist-get :pcm s) (alist-get :sample-rate r))
                     (push (file-name-nondirectory f) out)))
                 (message "Wrote %s" (string-join (nreverse out) ", ")))))
           :rate (cdr got)))))

(defun cmacs-speech-menu-identify (file)
  "Message which enrolled speaker FILE sounds like."
  (cmacs-speech-menu--file-pcm-then
   file (lambda (got)
          (cmacs-speech-identify-speaker
           (car got)
           (lambda (r)
             (let ((best (car (alist-get :matches r))))
               (message (if best "Sounds like %s (%.2f)" "No enrolled speaker matches%s%s")
                        (if best (alist-get :name best) "")
                        (if best (alist-get :score best) ""))))
           :rate (cdr got)))))

(defun cmacs-speech-menu--stt-models ()
  "Installed recognizers as ((LABEL BACKEND ID) ...)."
  (cl-loop for b in (cmacs-speech-backends 'stt)
           when (cmacs-speech-backend-available-p b 'stt)
           append (mapcar (lambda (id) (list (format "%s  (%s)" id b) b id))
                          (cmacs-speech-backend-models b 'stt))))

(defun cmacs-speech-menu-file-items (ctx)
  "Speech items for an audio/video file in CTX."
  (when-let* ((file (plist-get ctx :file)))
    (let ((name (file-name-nondirectory file)))
      (append
       (list (list :label (format "— %s —" (truncate-string-to-width name 40 nil nil "…"))
                   :enable nil))
       (when (cmacs-speech-menu--can 'stt)
         (list
          (list :label "Transcribe"
                :items
                (lambda (_c)
                  (append
                   (list (list :label "Into a buffer"
                               :action (lambda (c) (cmacs-speech-menu-transcribe (plist-get c :file) 'buffer)))
                         (list :label "As an org note"
                               :action (lambda (c) (cmacs-speech-menu-transcribe (plist-get c :file) 'org)))
                         (list :label (format "As %s" (file-name-nondirectory
                                                       (cmacs-speech-menu--sibling file ".txt")))
                               :action (lambda (c) (cmacs-speech-menu-transcribe (plist-get c :file) 'txt)))
                         (list :label (format "As %s subtitles" (file-name-nondirectory
                                                                 (cmacs-speech-menu--sibling file ".srt")))
                               :action (lambda (c) (cmacs-speech-menu-transcribe (plist-get c :file) 'srt)))
                         (list :sep))
                   (list (list :label "With model"
                               :items (mapcar (lambda (m)
                                                (list :label (nth 0 m)
                                                      :action (lambda (c)
                                                                (cmacs-speech-menu-transcribe
                                                                 (plist-get c :file) 'buffer
                                                                 (nth 1 m) (nth 2 m)))))
                                              (cmacs-speech-menu--stt-models)))))))))
       (when (and (cmacs-speech-menu--can 'diarize) (cmacs-speech-menu--can 'stt))
         (list (list :label "Who spoke? (speaker-labelled transcript)"
                     :action (lambda (c) (cmacs-speech-menu-who-spoke (plist-get c :file))))))
       (when (and (cmacs-speech-menu--can 'speaker-id)
                  (fboundp 'cmacs-speech-sherpa-speakers)
                  (cmacs-speech-sherpa-speakers))
         (list (list :label "Identify speaker"
                     :action (lambda (c) (cmacs-speech-menu-identify (plist-get c :file))))))
       (when (cmacs-speech-menu--can 'lang-id)
         (list (list :label "Detect language"
                     :action (lambda (c) (cmacs-speech-menu-detect-language (plist-get c :file))))))
       (when (cmacs-speech-menu--can 'audio-tag)
         (list (list :label "What's in this audio?"
                     :action (lambda (c) (cmacs-speech-menu-tag (plist-get c :file))))))
       (when (cmacs-speech-menu--can 'denoise)
         (list (list :label "Clean up noise → new file"
                     :action (lambda (c) (cmacs-speech-menu-denoise (plist-get c :file))))))
       (when (cmacs-speech-menu--can 'separate)
         (list (list :label "Split vocals / accompaniment"
                     :action (lambda (c) (cmacs-speech-menu-separate (plist-get c :file))))))
       (when (locate-library "cmacs-secondbrain-ingest")
         (list (list :label "Ingest into the second brain"
                     :action (lambda (c)
                               (require 'cmacs-secondbrain-ingest)
                               (cmacs-secondbrain-ingest-file (plist-get c :file))))))
       (list (list :sep))))))

;;;; Anywhere

(defun cmacs-speech-menu-anywhere-items (_ctx)
  "Speech items that need no target."
  (append
   (when (locate-library "cmacs-whisper-dictate")
     (list (list :label "Dictate here" :command 'cmacs-whisper-dictate)))
   (when (locate-library "cmacs-voice-loop")
     (list (list :label (if (bound-and-true-p cmacs-voice-loop-mode)
                            "Stop the voice loop" "Start the voice loop")
                 :command 'cmacs-voice-loop-mode)))
   (list (list :label "Speech settings…" :command 'cmacs-speech))))

;;;; Wiring

(defun cmacs-speech-menu-keymap (ctx)
  "The Speech submenu keymap for CTX, or nil when it would be empty."
  (let ((items (cmacs-media-menu-collect 'cmacs-speech-context-menu-functions ctx)))
    (when items
      (cmacs-media-menu-keymap "Speech" items ctx))))

(defun cmacs-speech-menu-populate (menu click)
  "Add the Speech entry to context MENU for CLICK."
  (when-let* ((ctx (ignore-errors (cmacs-speech-menu-context click)))
              (sub (cmacs-speech-menu-keymap ctx)))
    (define-key-after menu [cmacs-speech-separator] menu-bar-separator)
    (define-key-after menu [cmacs-speech] (list 'menu-item "Speech" sub)))
  menu)

;;;###autoload
(define-minor-mode cmacs-speech-menu-mode
  "Put a Speech entry on the right-click menu, everywhere.
Supersedes the older Piper-only entries."
  :global t
  :group 'cmacs-speech-menu
  (if cmacs-speech-menu-mode
      (progn
        (add-hook 'context-menu-functions #'cmacs-speech-menu-populate 91)
        (unless (bound-and-true-p context-menu-mode)
          (context-menu-mode 1)))
    (remove-hook 'context-menu-functions #'cmacs-speech-menu-populate)))

;;;###autoload
(defun cmacs-speech-menu ()
  "Open the Speech menu at point (the keyboard way in)."
  (interactive)
  (let* ((ctx (cmacs-speech-menu-context))
         (map (or (cmacs-speech-menu-keymap ctx) (user-error "Nothing to do here"))))
    (cmacs-media-menu-open map (cmacs-media-menu-position))))

;;;###autoload
(defun cmacs-speech-menu-bootstrap ()
  "Install the Speech menu at startup (honours `cmacs-speech-menu-auto-enable')."
  (when (and cmacs-speech-menu-auto-enable (not noninteractive))
    (cmacs-speech-menu-mode 1)
    (when (fboundp 'cmacs-menu-claim-mouse-3)
      (cmacs-menu-claim-mouse-3 #'cmacs-menu-open-context-menu))))

;;;###autoload
(add-hook 'after-init-hook #'cmacs-speech-menu-bootstrap)

(when (and after-init-time (not noninteractive))
  (cmacs-speech-menu-bootstrap))

(provide 'cmacs-speech-menu)
;;; cmacs-speech-menu.el ends here
