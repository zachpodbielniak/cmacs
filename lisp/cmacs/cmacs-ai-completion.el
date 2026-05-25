;;; cmacs-ai-completion.el --- Idle-timer FIM ghost-text  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Copilot/Cursor-style inline ghost-text completion driven by
;; ai-glib.  Idle-timer fires after `cmacs-ai-completion-idle-delay'
;; seconds with no input; an in-flight request is cancelled on the
;; next keypress.  Ghost text is shown via an after-string overlay
;; (face `shadow') and accepted with TAB.
;;
;; The completion provider defaults to a CLI wrapper
;; (`cmacs-ai-completion-provider' = 'claude-code) to avoid per-
;; keystroke HTTP costs.  ai-glib has no native FIM API so we pin
;; the model with a strict system prompt that returns ONLY the
;; insertion text.

;;; Code:

(require 'cmacs-ai)

(defcustom cmacs-ai-completion-idle-delay 0.3
  "Idle seconds before a completion request fires."
  :type 'number
  :group 'cmacs-ai)

(defcustom cmacs-ai-completion-min-prefix 3
  "Minimum number of pre-point characters before a request fires."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-completion-max-prefix-chars 1000
  "Maximum prefix chars sent to the model."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-completion-max-suffix-chars 500
  "Maximum suffix chars sent to the model."
  :type 'integer
  :group 'cmacs-ai)

(defvar-local cmacs-ai-completion--overlay nil)
(defvar-local cmacs-ai-completion--timer nil)
(defvar-local cmacs-ai-completion--session-pair nil)

(defface cmacs-ai-completion-face
  '((t :inherit shadow :slant italic))
  "Face for cmacs-ai inline ghost completions."
  :group 'cmacs-ai)

(defvar cmacs-ai-completion-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB") #'cmacs-ai-completion-accept-or-fallback)
    (define-key m (kbd "<tab>") #'cmacs-ai-completion-accept-or-fallback)
    m)
  "Keymap for `cmacs-ai-completion-mode'.")

(defun cmacs-ai-completion--clear ()
  (when (and cmacs-ai-completion--overlay
             (overlayp cmacs-ai-completion--overlay))
    (delete-overlay cmacs-ai-completion--overlay))
  (setq cmacs-ai-completion--overlay nil))

(defun cmacs-ai-completion--show (text)
  (cmacs-ai-completion--clear)
  (when (and text (not (string-empty-p text)))
    (let ((ov (make-overlay (point) (point) nil t t)))
      (overlay-put ov 'after-string
                   (propertize text 'face 'cmacs-ai-completion-face))
      (overlay-put ov 'cmacs-ai-completion t)
      (setq cmacs-ai-completion--overlay ov))))

(defun cmacs-ai-completion-accept-or-fallback ()
  "Accept the ghost completion, or fall back to TAB's normal binding."
  (interactive)
  (let ((ov cmacs-ai-completion--overlay))
    (if (and ov (overlayp ov))
        (let ((text (substring-no-properties
                     (or (overlay-get ov 'after-string) ""))))
          (cmacs-ai-completion--clear)
          (insert text))
      (let ((cmacs-ai-completion-mode nil))
        (call-interactively
         (or (key-binding (kbd "TAB") t)
             #'indent-for-tab-command))))))

(defun cmacs-ai-completion--system-prompt (mode-name)
  (format
   "You complete %s code at a fill-in-the-middle cursor.
Respond ONLY with the text to insert between the PREFIX and the
SUFFIX -- no commentary, no fences, no quotes, no trailing newline
unless it belongs in the insertion.  Aim for ONE LINE; prefer the
shortest completion that finishes the current expression or
statement.  If unsure, return an empty response."
   mode-name))

(defun cmacs-ai-completion--prefix ()
  (buffer-substring-no-properties
   (max (point-min) (- (point) cmacs-ai-completion-max-prefix-chars))
   (point)))

(defun cmacs-ai-completion--suffix ()
  (buffer-substring-no-properties
   (point)
   (min (point-max) (+ (point) cmacs-ai-completion-max-suffix-chars))))

(defun cmacs-ai-completion--fire ()
  (cmacs-ai-completion--clear)
  (when (and cmacs-ai-completion-mode
             (>= (- (point) (line-beginning-position))
                 cmacs-ai-completion-min-prefix))
    (let* ((mode (replace-regexp-in-string "-mode\\'" ""
                                            (symbol-name major-mode)))
           (system (cmacs-ai-completion--system-prompt mode))
           (prefix (cmacs-ai-completion--prefix))
           (suffix (cmacs-ai-completion--suffix))
           (prompt (format "<|fim_prefix|>%s<|fim_suffix|>%s<|fim_middle|>"
                           prefix suffix))
           (buf (current-buffer))
           (pt  (point)))
      (condition-case _err
          (let ((out (cmacs-ai-prompt-sync
                      prompt cmacs-ai-completion-provider system)))
            (when (and (buffer-live-p buf)
                       (eq buf (current-buffer))
                       (= pt (point))
                       (stringp out))
              (cmacs-ai-completion--show out)))
        (error nil)))))

(defun cmacs-ai-completion--schedule ()
  (when cmacs-ai-completion--timer
    (cancel-timer cmacs-ai-completion--timer))
  (cmacs-ai-completion--clear)
  (setq cmacs-ai-completion--timer
        (run-with-idle-timer cmacs-ai-completion-idle-delay nil
                             #'cmacs-ai-completion--fire)))

(defun cmacs-ai-completion--after-change (_b _e _l)
  (when cmacs-ai-completion-mode
    (cmacs-ai-completion--schedule)))

;;;###autoload
(define-minor-mode cmacs-ai-completion-mode
  "Inline ghost-text AI completion via ai-glib.
When enabled, an idle timer queries the model for a one-line
completion at point and renders it as a shadow overlay; TAB
accepts.  Any keypress before idle clears the overlay and any
in-flight request."
  :lighter " AI"
  :keymap cmacs-ai-completion-mode-map
  (if cmacs-ai-completion-mode
      (progn
        (cmacs-ai--ensure)
        (add-hook 'after-change-functions
                  #'cmacs-ai-completion--after-change nil t)
        (add-hook 'pre-command-hook #'cmacs-ai-completion--clear nil t))
    (when cmacs-ai-completion--timer
      (cancel-timer cmacs-ai-completion--timer)
      (setq cmacs-ai-completion--timer nil))
    (cmacs-ai-completion--clear)
    (remove-hook 'after-change-functions
                 #'cmacs-ai-completion--after-change t)
    (remove-hook 'pre-command-hook #'cmacs-ai-completion--clear t)))

(provide 'cmacs-ai-completion)
;;; cmacs-ai-completion.el ends here
