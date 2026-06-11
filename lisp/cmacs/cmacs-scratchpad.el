;;; cmacs-scratchpad.el --- Polyglot eval for scratch buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Polyglot evaluation for *scratch*-like buffers: alongside the usual
;; Emacs Lisp, blocks of crispy (C) and bacon (shell) code can be
;; written and executed in place.
;;
;; A block starts with a marker line and ends at a blank line, the
;; next marker, previously inserted output, or end of buffer:
;;
;;   ;; plain elisp, evaluated with C-j as always -- or C-c C-c:
;;   (+ 1 2)
;;
;;   %crispy
;;   for (int i = 0; i < 3; i++)
;;       g_print("%d\n", i);
;;
;;   %bacon
;;   ls /tmp | head -2
;;
;; `C-c C-c' (`cmacs-scratchpad-eval-block') evaluates the block at
;; point and inserts the output right below it.  Re-evaluating a block
;; replaces its previous output instead of stacking.  `C-c C-k'
;; removes the output at point (prefix argument: all output).
;;
;; Crispy blocks share the persistent REPL state with the `*crispy*'
;; buffer: definitions made here are visible at the REPL prompt and
;; vice versa.
;;
;; `cmacs-scratchpad-mode' is enabled automatically in buffers whose
;; name matches `cmacs-scratchpad-buffer-regexp' (*scratch* and Doom
;; scratch buffers).

;;; Code:

(require 'seq)

(declare-function crispy-eval-string "cmacs-crispy.c")
(declare-function crispy-repl-eval-string "cmacs-crispy.c")
(declare-function bacon-running-p "cmacs-bacon.c")
(declare-function bacon-eval "cmacs-bacon.c")

(defgroup cmacs-scratchpad nil
  "Polyglot eval (%crispy / %bacon blocks) for scratch buffers."
  :group 'cmacs
  :prefix "cmacs-scratchpad-")

(defcustom cmacs-scratchpad-buffer-regexp
  "\\`\\*\\(scratch\\|doom:scratch\\)"
  "Buffers matching this regexp get `cmacs-scratchpad-mode' enabled.
Checked by `cmacs-scratchpad-maybe-enable' on
`lisp-interaction-mode-hook'."
  :type 'regexp
  :group 'cmacs-scratchpad)

(defconst cmacs-scratchpad--marker-re
  "^[ \t]*%\\(crispy\\|bacon\\)[ \t]*$"
  "Regexp matching a language marker line that starts a block.")

;;; Block detection

(defun cmacs-scratchpad--output-line-p ()
  "Return non-nil if the current line carries scratchpad output."
  (get-text-property (line-beginning-position) 'cmacs-scratchpad-output))

(defun cmacs-scratchpad--blank-line-p ()
  "Return non-nil if the current line is blank."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \t]*$")))

(defun cmacs-scratchpad--block-at-point ()
  "Return the block at point as a plist (:lang LANG :beg BEG :end END :code CODE).
LANG is `crispy', `bacon', or `elisp' (no marker above the block).
BEG and END delimit the code body; the marker line is excluded.
Return nil if point is on a blank line or inside output text."
  (save-excursion
    (beginning-of-line)
    (cond
     ((cmacs-scratchpad--output-line-p) nil)
     ((and (cmacs-scratchpad--blank-line-p)
           (not (looking-at-p cmacs-scratchpad--marker-re)))
      nil)
     (t
      (let ((lang 'elisp))
        (if (looking-at cmacs-scratchpad--marker-re)
            ;; Point on the marker line: the body starts below.
            (progn
              (setq lang (intern (match-string-no-properties 1)))
              (forward-line 1))
          ;; Scan back to the top of this paragraph: stop below a
          ;; blank line, a marker, output text, or at buffer start.
          (while (and (not (bobp))
                      (save-excursion
                        (forward-line -1)
                        (not (or (cmacs-scratchpad--blank-line-p)
                                 (cmacs-scratchpad--output-line-p)
                                 (looking-at-p
                                  cmacs-scratchpad--marker-re)))))
            (forward-line -1))
          ;; A marker directly above names the block's language.
          (save-excursion
            (unless (bobp)
              (forward-line -1)
              (when (looking-at cmacs-scratchpad--marker-re)
                (setq lang
                      (intern (match-string-no-properties 1)))))))
        ;; Collect the body: lines until blank / marker / output / eob.
        (let ((beg (point))
              (end (point)))
          (while (and (not (eobp))
                      (not (cmacs-scratchpad--blank-line-p))
                      (not (looking-at-p cmacs-scratchpad--marker-re))
                      (not (cmacs-scratchpad--output-line-p)))
            (setq end (line-end-position))
            (forward-line 1))
          (when (> end beg)
            (list :lang lang :beg beg :end end
                  :code (buffer-substring-no-properties beg end)))))))))

;;; Evaluation

(defun cmacs-scratchpad--read-progn (code)
  "Read all Lisp forms in CODE and wrap them in a single `progn'."
  (let ((pos 0)
        (forms ()))
    (condition-case nil
        (while t
          (pcase-let ((`(,form . ,next) (read-from-string code pos)))
            (push form forms)
            (setq pos next)))
      (end-of-file nil))
    `(progn ,@(nreverse forms))))

(defun cmacs-scratchpad--bacon-eval (code)
  "Run CODE line by line via bacon when running, else via the shell."
  (if (and (fboundp 'bacon-running-p) (bacon-running-p))
      (mapconcat
       (lambda (line)
         (pcase-let ((`(,rc . ,output) (bacon-eval line)))
           (concat output
                   (when (and (integerp rc) (/= rc 0))
                     (format "%s[exit %d]\n"
                             (if (string-suffix-p "\n" (or output ""))
                                 "" "\n")
                             rc)))))
       (seq-remove #'string-empty-p
                   (mapcar #'string-trim (split-string code "\n")))
       "")
    (shell-command-to-string code)))

(defun cmacs-scratchpad--eval (lang code)
  "Evaluate CODE as LANG, returning the output string."
  (pcase lang
    ('crispy
     (unless (fboundp 'crispy-eval-string)
       (user-error "Crispy not available in this build"))
     (condition-case err
         (if (fboundp 'crispy-repl-eval-string)
             (crispy-repl-eval-string code)
           (crispy-eval-string code))
       (crispy-error (format "error: %s" (cadr err)))))
    ('bacon (cmacs-scratchpad--bacon-eval code))
    ('elisp
     (condition-case err
         (format "=> %S" (eval (cmacs-scratchpad--read-progn code) t))
       (error (format "error: %S" err))))
    (_ (user-error "Unknown scratchpad language %s" lang))))

;;; Output insertion

(defun cmacs-scratchpad--delete-output-after (block-end)
  "Delete the contiguous output region following BLOCK-END, if any."
  (save-excursion
    (goto-char block-end)
    (unless (eobp)
      (forward-char 1)
      (let ((start (point)))
        (while (and (< (point) (point-max))
                    (get-text-property (point) 'cmacs-scratchpad-output))
          (forward-line 1))
        (when (> (point) start)
          (delete-region start (point)))))))

(defun cmacs-scratchpad--insert-output (block-end output)
  "Insert OUTPUT below BLOCK-END, replacing any previous output region.
The inserted text (including a trailing blank separator line) carries
the `cmacs-scratchpad-output' text property so re-evaluation can find
and replace it, and so block detection never includes it."
  (save-excursion
    (goto-char block-end)
    (when (eobp)
      (insert "\n"))
    (cmacs-scratchpad--delete-output-after block-end)
    (goto-char block-end)
    (forward-char 1)
    (when (string-empty-p output)
      (setq output "(no output)"))
    (insert (propertize
             (concat output
                     (if (string-suffix-p "\n" output) "" "\n")
                     "\n")
             'cmacs-scratchpad-output t
             'font-lock-face 'shadow
             'rear-nonsticky t))))

;;; Commands

;;;###autoload
(defun cmacs-scratchpad-eval-block ()
  "Evaluate the block at point and insert its output below.
The language is selected by a %crispy or %bacon marker line above
the block; without a marker the block is evaluated as Emacs Lisp.
Re-evaluation replaces the block's previous output."
  (interactive)
  (let ((block (cmacs-scratchpad--block-at-point)))
    (unless block
      (user-error "No code block at point"))
    (let ((output (cmacs-scratchpad--eval (plist-get block :lang)
                                          (plist-get block :code))))
      (cmacs-scratchpad--insert-output (plist-get block :end)
                                       (or output "")))))

;;;###autoload
(defun cmacs-scratchpad-clear-output (&optional all)
  "Delete the output below the block at point.
With prefix argument ALL, delete every scratchpad output region in
the buffer."
  (interactive "P")
  (if all
      (let (pos)
        (while (setq pos (text-property-any (point-min) (point-max)
                                            'cmacs-scratchpad-output t))
          (delete-region pos
                         (or (text-property-not-all
                              pos (point-max)
                              'cmacs-scratchpad-output t)
                             (point-max)))))
    (let ((block (cmacs-scratchpad--block-at-point)))
      (unless block
        (user-error "No code block at point"))
      (cmacs-scratchpad--delete-output-after (plist-get block :end)))))

;;; Minor mode

(defvar cmacs-scratchpad-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-scratchpad-eval-block)
    (define-key map (kbd "C-c C-k") #'cmacs-scratchpad-clear-output)
    map)
  "Keymap for `cmacs-scratchpad-mode'.")

;;;###autoload
(define-minor-mode cmacs-scratchpad-mode
  "Polyglot eval (%crispy / %bacon markers) for scratch buffers.

\\{cmacs-scratchpad-mode-map}"
  :lighter " CScratch"
  :keymap cmacs-scratchpad-mode-map
  :group 'cmacs-scratchpad)

;;;###autoload
(defun cmacs-scratchpad-maybe-enable ()
  "Enable `cmacs-scratchpad-mode' in *scratch*-like buffers.
Intended for `lisp-interaction-mode-hook'; only buffers whose name
matches `cmacs-scratchpad-buffer-regexp' are affected, so the
keybindings never shadow other `lisp-interaction-mode' buffers."
  (when (string-match-p cmacs-scratchpad-buffer-regexp (buffer-name))
    (cmacs-scratchpad-mode 1)))

;;;###autoload
(add-hook 'lisp-interaction-mode-hook #'cmacs-scratchpad-maybe-enable)

(provide 'cmacs-scratchpad)
;;; cmacs-scratchpad.el ends here
