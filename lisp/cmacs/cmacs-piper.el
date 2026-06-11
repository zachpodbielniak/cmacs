;;; cmacs-piper.el --- Piper offline TTS for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lisp layer for cmacs-piper.  Provides voice management, a default
;; keybind (C-c v s) to speak the active region, M-x speak-buffer,
;; and `cmacs-piper-stop' to interrupt in-flight playback.
;;
;; Piper voice (.onnx) files live in `cmacs-piper-voices-directory'
;; (default ~/.local/share/cmacs/piper-voices/).  Each voice ships with
;; a sample-rate hint in its .onnx.json sidecar; we default to 22050
;; Hz if absent.

;;; Code:

(require 'cl-lib)
(require 'cmacs-audio)

(defgroup cmacs-piper nil
  "Offline text-to-speech via Piper."
  :group 'cmacs
  :prefix "cmacs-piper-")

(defcustom cmacs-piper-voices-directory
  (expand-file-name ".local/share/cmacs/piper-voices/" "~")
  "Directory where user-downloaded Piper .onnx voices live.
System-installed voices under `cmacs-piper-system-voices-directory'
are also searched (see `cmacs-piper-voices-search-path')."
  :type 'directory
  :group 'cmacs-piper)

(defcustom cmacs-piper-system-voices-directory
  "/usr/share/cmacs/piper-voices/"
  "Read-only directory for system-installed Piper voices.
Populated by image builds (Containerfile stages the default
English voice here).  User-installed voices take precedence."
  :type 'directory
  :group 'cmacs-piper)

(defcustom cmacs-piper-voices-search-path
  (list cmacs-piper-voices-directory
        cmacs-piper-system-voices-directory)
  "Ordered list of directories searched for Piper voice files."
  :type '(repeat directory)
  :group 'cmacs-piper)

(defcustom cmacs-piper-default-voice "en_US-amy-low.onnx"
  "Default voice basename inside `cmacs-piper-voices-directory'."
  :type 'string
  :group 'cmacs-piper)

(defcustom cmacs-piper-default-rate 22050
  "Fallback sample rate (Hz) if the voice .onnx.json sidecar is absent."
  :type 'integer
  :group 'cmacs-piper)

;; `cmacs-piper-auto-enable-context-menu' and `cmacs-piper-override-mouse-3'
;; are intentionally defined in `cmacs-piper-context-menu.el' (with autoload
;; cookies) so the startup bootstrap can read them BEFORE this file loads.
;; Customize them as usual via M-x customize-group RET cmacs-piper RET.

(defvar cmacs-piper--playback-handle nil
  "Shared playback handle, reused across utterances.
Opening a `cmacs-audio' playback stream creates a system audio
output (a PulseAudio sink input), so each utterance must NOT open
its own --- they would accumulate forever, one per `speak'.  All
piper speech funnels through this one handle; pushed PCM is
timestamped on arrival (appsrc do-timestamp), so feeding an
already-playing pipeline plays immediately.")

(defvar cmacs-piper--playback-rate nil
  "Sample rate (Hz) of `cmacs-piper--playback-handle'.")

(defun cmacs-piper--playback-live-p (handle)
  "Non-nil when HANDLE still exists in the audio registry."
  (and handle (ignore-errors (cmacs-audio-state handle) t)))

(defun cmacs-piper--ensure-playback (rate)
  "Return the shared playback handle at RATE Hz, opening it on demand.
The handle (and its audio output) persists across utterances; only a
RATE change (a different voice) replaces it.  The pipeline is set
PLAYING before returning: a stopped appsrc flushes pushed buffers,
so callers must only push PCM into a started handle."
  (if (and (eql cmacs-piper--playback-rate rate)
           (cmacs-piper--playback-live-p cmacs-piper--playback-handle))
      (cmacs-audio-start cmacs-piper--playback-handle)
    (when cmacs-piper--playback-handle
      (ignore-errors (cmacs-audio-close cmacs-piper--playback-handle)))
    (setq cmacs-piper--playback-handle
          (cmacs-audio--playback-open-pcm-1 rate 1)
          cmacs-piper--playback-rate rate)
    (cmacs-audio-start cmacs-piper--playback-handle))
  cmacs-piper--playback-handle)

(defun cmacs-piper-speaking-p ()
  "Non-nil when piper playback is active (or has queued audio)."
  (and (cmacs-piper--playback-live-p cmacs-piper--playback-handle)
       (eq (cmacs-audio-state cmacs-piper--playback-handle) 'playing)))

(defun cmacs-piper-voice-path (&optional name)
  "Resolve NAME (or `cmacs-piper-default-voice') to an absolute path.
Walks `cmacs-piper-voices-search-path' and returns the first existing
match.  Falls back to the user dir (download target) if absent."
  (let ((basename (or name cmacs-piper-default-voice)))
    (or (cl-some
         (lambda (dir)
           (let ((p (expand-file-name basename dir)))
             (and (file-exists-p p) p)))
         cmacs-piper-voices-search-path)
        (expand-file-name basename cmacs-piper-voices-directory))))

(defun cmacs-piper-list-voices ()
  "Return basenames of every .onnx voice visible via the search path."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (dir cmacs-piper-voices-search-path)
      (when (file-directory-p dir)
        (dolist (f (directory-files dir))
          (when (string-match-p "\\.onnx\\'" f)
            (puthash f t seen)))))
    (sort (hash-table-keys seen) #'string<)))

(defun cmacs-piper--voice-sample-rate (voice)
  "Read VOICE's .onnx.json sidecar, return :sample_rate or default."
  (let ((side (concat voice ".json")))
    (or (and (file-exists-p side)
             (with-temp-buffer
               (insert-file-contents side)
               (let* ((json (ignore-errors (json-parse-buffer
                                            :object-type 'alist)))
                      (audio (alist-get 'audio json))
                      (rate  (alist-get 'sample_rate audio)))
                 (and (numberp rate) rate))))
        cmacs-piper-default-rate)))

;;;###autoload
(defun cmacs-piper-speak (text &optional voice)
  "Speak TEXT through cmacs-audio playback.  Returns the audio handle."
  (interactive "MSpeak: ")
  (unless (cmacs-piper-supported-p)
    (user-error "cmacs-piper: piper executable not on PATH"))
  (let* ((v   (cmacs-piper-voice-path voice))
         (pcm (cmacs-piper--synth-sync-1 v text))
         (rate (cmacs-piper--voice-sample-rate v))
         (h   (cmacs-piper--ensure-playback rate)))
    (cmacs-audio-push-pcm h pcm)
    (cmacs-audio-start h)
    h))

;;;###autoload
(defun cmacs-piper-speak-async (text &optional callback voice)
  "Asynchronously synthesise TEXT and play it.
Optional CALLBACK is called with the audio handle when playback starts."
  (interactive "MSpeak: ")
  (unless (cmacs-piper-supported-p)
    (user-error "cmacs-piper: piper executable not on PATH"))
  (let ((v (cmacs-piper-voice-path voice)))
    (cmacs-piper--synth-async-1
     v text
     (lambda (result)
       (cond
        ((and (consp result) (consp (car result))
              (eq :error (caar result)))
         (message "cmacs-piper: %s" (cdar result)))
        ((stringp result)
         (let* ((rate (cmacs-piper--voice-sample-rate v))
                (h    (cmacs-piper--ensure-playback rate)))
           (cmacs-audio-push-pcm h result)
           (cmacs-audio-start h)
           (when callback (funcall callback h)))))))))

;;;###autoload
(defun cmacs-piper-speak-region (beg end)
  "Speak the active region (or sentence at point if no region)."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (save-excursion
       (let ((p (point)))
         (list (progn (backward-sentence) (point))
               (progn (goto-char p) (forward-sentence) (point)))))))
  (cmacs-piper-speak-async (buffer-substring-no-properties beg end)))

;;;###autoload
(defun cmacs-piper-speak-buffer ()
  "Speak the entire buffer."
  (interactive)
  (cmacs-piper-speak-async (buffer-substring-no-properties
                            (point-min) (point-max))))

;;;###autoload
(defun cmacs-piper-stop ()
  "Interrupt in-flight playback, flushing anything still queued.
The shared audio output is kept open for reuse by the next
utterance."
  (interactive)
  (when (cmacs-piper--playback-live-p cmacs-piper--playback-handle)
    (ignore-errors (cmacs-audio-stop cmacs-piper--playback-handle))))

;;;###autoload
(defun cmacs-piper-stop-all ()
  "Interrupt playback and release the shared audio output entirely."
  (interactive)
  (when cmacs-piper--playback-handle
    (ignore-errors (cmacs-audio-close cmacs-piper--playback-handle))
    (setq cmacs-piper--playback-handle nil
          cmacs-piper--playback-rate nil)))

;; --- Voice keymap entries -------------------------------------------

;; C-c v s / C-c v S bindings are installed via autoload cookies below
;; so they work at startup BEFORE this file is loaded.  Cookies
;; reference `cmacs-voice-map' which is autoload-cookied in
;; cmacs-audio.el (loaddefs processes files alphabetically so the
;; defvar lands ahead of these define-keys).
;;
;;;###autoload (define-key cmacs-voice-map (kbd "s") #'cmacs-piper-speak-region)
;;;###autoload (define-key cmacs-voice-map (kbd "S") #'cmacs-piper-stop)

;; Right-click context menu lives in cmacs-piper-context-menu.el and
;; installs itself at startup via an autoload-cookie + after-init-hook,
;; so this require chain is just to make customize-group RET cmacs-piper
;; surface those defcustoms together with the rest.
(require 'cmacs-piper-context-menu nil 'noerror)

(provide 'cmacs-piper)

;;; cmacs-piper.el ends here
