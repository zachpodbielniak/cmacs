;;; cmacs-gsurf-ai.el --- AI commands for gsurf pages  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Bridge the gsurf live browser to cmacs-ai: summarize the current page or
;; ask a question about it.  Page text is extracted asynchronously (the page
;; need not be focused) and fed to `cmacs-ai-prompt-sync'; the answer opens
;; in an Org side window, mirroring the cmacs-ai region commands.

;;; Code:

(require 'subr-x)

(declare-function cmacs-ai--ensure "cmacs-ai" ())
(declare-function cmacs-ai-prompt-sync "cmacs-ai-stream.c"
                  (prompt &optional provider system))
(declare-function cmacs-gsurf--page-text "cmacs-gsurf" (buffer callback))
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))

(defgroup cmacs-gsurf-ai nil
  "AI commands for the cmacs-gsurf embedded browser."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-ai-")

(defcustom cmacs-gsurf-ai-max-chars 16000
  "Maximum characters of page text sent to the model.
Longer pages are truncated to keep the request within limits."
  :type 'integer
  :group 'cmacs-gsurf-ai)

(defun cmacs-gsurf-ai--require ()
  (unless (cmacs-gsurf-attached-p (current-buffer))
    (user-error "Not a gsurf buffer"))
  (when (fboundp 'cmacs-ai--ensure) (cmacs-ai--ensure)))

(defun cmacs-gsurf-ai--truncate (text)
  (if (> (length text) cmacs-gsurf-ai-max-chars)
      (substring text 0 cmacs-gsurf-ai-max-chars)
    text))

(defun cmacs-gsurf-ai--show (name out)
  "Render OUT (Org text) in a side window named NAME."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert out)
        (when (fboundp 'org-mode) (org-mode))
        (goto-char (point-min))))
    (display-buffer-in-side-window
     buf '((side . right) (slot . 0) (window-width . 0.42)))))

(defun cmacs-gsurf-ai--context (buffer text)
  "Format a Title/URL/page-text context block for BUFFER."
  (format "Title: %s\nURL: %s\n\nPage text:\n%s"
          (or (ignore-errors (cmacs-gsurf-get-title buffer)) "")
          (or (ignore-errors (cmacs-gsurf-get-uri buffer)) "")
          (cmacs-gsurf-ai--truncate text)))

;;;###autoload
(defun cmacs-gsurf-summarize ()
  "Summarize the current gsurf page with cmacs-ai (Org side window)."
  (interactive)
  (cmacs-gsurf-ai--require)
  (let ((buf (current-buffer)))
    (cmacs-gsurf--page-text
     buf
     (lambda (text)
       (let ((out (cmacs-ai-prompt-sync
                   (cmacs-gsurf-ai--context buf text)
                   nil
                   "You summarize web pages.  Use concise Org-mode markup: a
one-line *TL;DR*, then the key points as a short bullet list.  No preamble.")))
         (cmacs-gsurf-ai--show "*gsurf-summary*" out))))))

;;;###autoload
(defun cmacs-gsurf-ask (question)
  "Ask a QUESTION about the current gsurf page with cmacs-ai."
  (interactive "sAsk about this page: ")
  (cmacs-gsurf-ai--require)
  (let ((buf (current-buffer)))
    (cmacs-gsurf--page-text
     buf
     (lambda (text)
       (let ((out (cmacs-ai-prompt-sync
                   (format "%s\n\nQuestion: %s"
                           (cmacs-gsurf-ai--context buf text) question)
                   nil
                   "Answer the question using ONLY the page content above.
Use Org-mode markup; say so if the page does not contain the answer.")))
         (cmacs-gsurf-ai--show "*gsurf-ask*" out))))))

(provide 'cmacs-gsurf-ai)
;;; cmacs-gsurf-ai.el ends here
