;;; cmacs-audio-org.el --- #+BEGIN_AUDIO blocks for cmacs-audio  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adds inline `#+BEGIN_AUDIO :src "FILE.wav" :width W :height H' blocks
;; to org buffers, mirroring the cmacs-video-org.el pattern.  The block
;; body renders as an SVG waveform overlay (via `cmacs-audio-waveform-svg').
;;
;; Recording flow:
;;
;;   #+BEGIN_AUDIO :record t
;;   (placeholder)
;;   #+END_AUDIO
;;
;; M-x cmacs-audio-org-record   starts capture into a sidecar
;; M-x cmacs-audio-org-finish   stops + rewrites the block header
;;                              with :src "<sidecar>" and renders
;;                              the SVG waveform.
;;
;; When `cmacs-whisper' is built, cmacs-audio-transcribe.el adds a
;; folded #+BEGIN_AUDIO_TRANSCRIPT child block automatically.

;;; Code:

(require 'cmacs-audio)

(defvar-local cmacs-audio--blocks nil
  "Buffer-local list of (HANDLE :marker M :w W :h H) plists for the
audio blocks currently rendered in this buffer.")

(defconst cmacs-audio-org--begin-rx
  "^[ \t]*#\\+BEGIN_AUDIO\\(?:[ \t]+\\(.*\\)\\)?$")
(defconst cmacs-audio-org--end-rx
  "^[ \t]*#\\+END_AUDIO[ \t]*$")

(defun cmacs-audio-org--parse-args (line)
  "Parse a #+BEGIN_AUDIO keyword string into a plist."
  (let ((out nil)
        (pos 0))
    (while (string-match
            "[ \t]*\\(:[A-Za-z-]+\\)[ \t]+\\(\"[^\"]*\"\\|[^ \t]+\\)"
            line pos)
      (let* ((k (intern (match-string 1 line)))
             (v-raw (match-string 2 line))
             (v (cond ((string-match "\\`\"\\(.*\\)\"\\'" v-raw)
                       (match-string 1 v-raw))
                      ((string-match-p "\\`[0-9]+\\'" v-raw)
                       (string-to-number v-raw))
                      ((member v-raw '("t" "T" "true"))  t)
                      ((member v-raw '("nil" "NIL" "false")) nil)
                      (t v-raw))))
        (setq out (plist-put out k v))
        (setq pos (match-end 0))))
    out))

(defun cmacs-audio-org--block-bounds ()
  "Return (BEG END :args ALIST) for the audio block at point, or nil."
  (save-excursion
    (let ((case-fold-search t))
      (beginning-of-line)
      (when (or (looking-at cmacs-audio-org--begin-rx)
                (re-search-backward cmacs-audio-org--begin-rx nil t))
        (let* ((beg (line-beginning-position))
               (args-str (or (match-string 1) ""))
               (args (cmacs-audio-org--parse-args args-str)))
          (forward-line 1)
          (when (re-search-forward cmacs-audio-org--end-rx nil t)
            (list beg (line-end-position) args)))))))

(defun cmacs-audio-org--read-pcm (path)
  "Read PCM samples from PATH (WAV file).  Returns a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    ;; Skip 44-byte WAV header (minimal handling).
    (if (>= (buffer-size) 44)
        (buffer-substring-no-properties 45 (point-max))
      "")))

(defun cmacs-audio-org--render-overlay (beg end args)
  "Replace the block body with an SVG waveform overlay."
  (let* ((src (plist-get args :src))
         (w   (or (plist-get args :width)  800))
         (h   (or (plist-get args :height) 100))
         (col (or (plist-get args :colour) (plist-get args :color)))
         (pcm (and src (file-exists-p src) (cmacs-audio-org--read-pcm src)))
         (svg (and pcm (cmacs-audio-waveform-svg pcm w h col))))
    (when svg
      (let ((ov (make-overlay beg end nil t nil)))
        (overlay-put ov 'cmacs-audio t)
        (overlay-put ov 'display (create-image svg 'svg t :ascent 'center))
        (overlay-put ov 'help-echo (format "cmacs-audio: %s" src))
        (overlay-put ov 'keymap
                     (let ((m (make-sparse-keymap)))
                       (define-key m [mouse-1]
                                   (lambda (_e) (interactive "e")
                                     (cmacs-audio-play-file src)))
                       m))
        ov))))

(defun cmacs-audio-org-refresh-buffer ()
  "Render all #+BEGIN_AUDIO blocks in the current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward cmacs-audio-org--begin-rx nil t)
      (when-let* ((bounds (cmacs-audio-org--block-bounds)))
        (apply #'cmacs-audio-org--render-overlay bounds)))))

(defun cmacs-audio-org-clear-buffer ()
  "Remove all cmacs-audio overlays in the current buffer."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'cmacs-audio)
      (delete-overlay ov))))

;;;; ────────────────────── Recording flow ──────────────────────────

(defvar-local cmacs-audio-org--recording nil
  "Internal: (HANDLE PATH BEG END) for in-progress block recording.")

(defun cmacs-audio-org-record ()
  "Start recording into the #+BEGIN_AUDIO block at point.
The block must contain `:record t' or have no :src yet."
  (interactive)
  (let ((bounds (cmacs-audio-org--block-bounds)))
    (unless bounds
      (user-error "Point is not inside a #+BEGIN_AUDIO block"))
    (pcase-let* ((`(,beg ,end ,args) bounds)
                 (sidecar (expand-file-name
                           (format-time-string "audio-%Y%m%d-%H%M%S.wav")
                           cmacs-audio-output-dir))
                 (h (cmacs-audio--capture-open-1
                     :source cmacs-audio-capture-source
                     :rate   cmacs-audio-default-rate
                     :channels cmacs-audio-default-channels)))
      (unless (file-directory-p cmacs-audio-output-dir)
        (make-directory cmacs-audio-output-dir t))
      (cmacs-audio-start h)
      (setq cmacs-audio-org--recording (list h sidecar beg end))
      (message "cmacs-audio: recording; M-x cmacs-audio-org-finish to stop"))))

(defun cmacs-audio-org-finish ()
  "Stop the in-progress recording started by `cmacs-audio-org-record'."
  (interactive)
  (pcase cmacs-audio-org--recording
    (`(,h ,path ,beg ,_end)
     (cmacs-audio-write-file h path)
     (cmacs-audio-close h)
     (setq cmacs-audio-org--recording nil)
     ;; Rewrite the BEGIN_AUDIO line to include :src.
     (save-excursion
       (goto-char beg)
       (when (looking-at cmacs-audio-org--begin-rx)
         (let ((args (cmacs-audio-org--parse-args (or (match-string 1) ""))))
           (setq args (plist-put args :src path))
           (setq args (plist-put args :record nil))
           (delete-region (line-beginning-position) (line-end-position))
           (insert (concat "#+BEGIN_AUDIO"
                           (cl-loop for (k v) on args by #'cddr
                                    when v
                                    concat
                                    (format " %s %s" k
                                            (cond ((eq v t) "t")
                                                  ((numberp v) (number-to-string v))
                                                  (t (format "%S" v))))))))))
     (cmacs-audio-org-refresh-buffer)
     (when (and (featurep 'cmacs-whisper)
                (fboundp 'cmacs-audio-transcribe-block-at))
       (cmacs-audio-transcribe-block-at beg path))
     (message "cmacs-audio: wrote %s" path))
    (_ (user-error "cmacs-audio: no recording in progress"))))

(add-hook 'org-mode-hook
          (lambda ()
            (when (save-excursion
                    (goto-char (point-min))
                    (re-search-forward cmacs-audio-org--begin-rx nil t))
              (cmacs-audio-org-refresh-buffer))))

(provide 'cmacs-audio-org)

;;; cmacs-audio-org.el ends here
