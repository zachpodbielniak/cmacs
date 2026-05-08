;;; cmacs-cintrospect-jit-repl.el --- C JIT REPL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;;
;; A comint-derived REPL for the cintrospect JIT.  Type a complete C
;; function definition (terminated by a closing brace at column 0,
;; followed by RET) and the REPL compiles it via `cmacs-c-compile',
;; reports the resulting handle, then accepts a sexp-style call
;; expression on subsequent lines.
;;
;; Two input modes (auto-detected):
;;
;;   * If the input begins with `(' it's treated as a Lisp form
;;     (typically `(cmacs-c-call HANDLE ARGS...)') and `eval'd.
;;
;;   * Otherwise it's treated as C source.  By convention, the source
;;     should contain exactly one function whose name is taken from
;;     the first identifier following the return type.  Its signature
;;     is auto-detected by counting `Lisp_Object' parameters.
;;
;; Pattern mirrors `lisp/cmacs/cmacs-crispy.el:58' (crispy-repl-mode)
;; and `lisp/cmacs/cmacs-podomation.el:137'.

;;; Code:

(require 'comint)
(require 'cl-lib)

(defcustom cmacs-c-jit-repl-buffer-name "*cmacs-c-jit-repl*"
  "Buffer name for the C JIT REPL."
  :type 'string :group 'cmacs-cintrospect)

(defcustom cmacs-c-jit-repl-prompt "cmacs-c> "
  "Prompt for the C JIT REPL."
  :type 'string :group 'cmacs-cintrospect)

(defvar cmacs-c-jit-repl--last-handle nil
  "The most recent handle returned by `cmacs-c-compile' in this REPL.")

(defvar cmacs-c-jit-repl--handles nil
  "Per-buffer list of (FN-NAME . HANDLE) cons cells.")

;; ─── Source parsing ──────────────────────────────────────────────

(defun cmacs-c-jit-repl--parse-fn (src)
  "Heuristically extract (FN-NAME . SIG) from C SOURCE.
Returns nil if no function definition is found."
  (when (string-match
         "\\([_a-zA-Z][_a-zA-Z0-9]*\\)[[:space:]\n]+\\([_a-zA-Z][_a-zA-Z0-9]*\\)[[:space:]\n]*(\\([^)]*\\))[[:space:]\n]*{"
         src)
    (let* ((retty  (match-string 1 src))
           (fn     (match-string 2 src))
           (params (string-trim (match-string 3 src)))
           (sig    (cond
                    ((or (string-empty-p params)
                         (string= params "void"))
                     (format "%s(void)" retty))
                    ((string-match-p "ptrdiff_t" params)
                     (format "%s(ptrdiff_t,Lisp_Object*)" retty))
                    (t
                     (format "%s(%s)" retty
                             (mapconcat #'string-trim
                                        (split-string params ",")
                                        ","))))))
      (cons fn sig))))

;; ─── Comint dispatch ─────────────────────────────────────────────

(defun cmacs-c-jit-repl--handle-input (proc input)
  "Process a single PROC line of REPL INPUT."
  (let* ((trimmed (string-trim input))
         (out (with-current-buffer (process-buffer proc)
                (cmacs-c-jit-repl--evaluate trimmed))))
    (when out
      (comint-output-filter
       proc (concat (if (stringp out) out (format "%S" out)) "\n"
                    cmacs-c-jit-repl-prompt)))))

(defun cmacs-c-jit-repl--evaluate (input)
  "Compile / call / Lisp-eval INPUT, returning a string."
  (cond
   ((string-empty-p input) nil)

   ;; Lisp form: dispatch to `eval'.
   ((string-prefix-p "(" input)
    (condition-case err
        (let ((form (read input)))
          (format "=> %S" (eval form t)))
      (error (format "Lisp error: %S" err))))

   ;; C source: compile.
   (t
    (let* ((parsed (cmacs-c-jit-repl--parse-fn input)))
      (cond
       ((null parsed)
        "(could not auto-detect a C function definition; type a Lisp form starting with `(' to evaluate)")
       (t
        (let ((fn  (car parsed))
              (sig (cdr parsed)))
          (condition-case err
              (let ((h (cmacs-c-compile input fn sig)))
                (push (cons fn h) cmacs-c-jit-repl--handles)
                (setq cmacs-c-jit-repl--last-handle h)
                (format "=> handle %s  %s  signature: %s" h fn sig))
            (cmacs-cintrospect-compile-error
             (format "Compile error:\n%s" (cadr err)))
            (error (format "Error: %S" err))))))))))

;; ─── Mode definition ─────────────────────────────────────────────

(defvar cmacs-c-jit-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "C-c C-d")
                #'cmacs-c-jit-repl-dispose-last)
    (define-key map (kbd "C-c C-l") #'cmacs-c-jit-repl-clear)
    map))

(define-derived-mode cmacs-c-jit-repl-mode comint-mode "C-JIT-REPL"
  "Major mode for the cintrospect C JIT REPL."
  (setq comint-prompt-regexp
        (concat "^" (regexp-quote cmacs-c-jit-repl-prompt)))
  (setq comint-input-sender #'cmacs-c-jit-repl--handle-input)
  (setq comint-process-echoes nil)
  (setq comint-prompt-read-only t)
  ;; Spawn a dummy process so comint is happy.
  (unless (comint-check-proc (current-buffer))
    (let ((proc (start-process "cmacs-c-jit-repl" (current-buffer)
                               "cat")))
      (set-process-query-on-exit-flag proc nil)))
  (insert (propertize
           (concat
            "; cmacs C JIT REPL.  Type a C function definition to compile;\n"
            "; type a Lisp form like (cmacs-c-call <handle> ...) to call.\n"
            "; C-c C-d disposes the most recent handle.\n\n")
           'font-lock-face 'font-lock-comment-face))
  (comint-output-filter (get-buffer-process (current-buffer))
                        cmacs-c-jit-repl-prompt))

(defun cmacs-c-jit-repl-dispose-last ()
  "Dispose of the most recently created handle."
  (interactive)
  (when cmacs-c-jit-repl--last-handle
    (cmacs-c-handle-dispose cmacs-c-jit-repl--last-handle)
    (setq cmacs-c-jit-repl--handles
          (cl-remove cmacs-c-jit-repl--last-handle
                     cmacs-c-jit-repl--handles
                     :key #'cdr))
    (message "Disposed handle %d" cmacs-c-jit-repl--last-handle)
    (setq cmacs-c-jit-repl--last-handle nil)))

(defun cmacs-c-jit-repl-clear ()
  "Clear the REPL buffer, preserving the prompt."
  (interactive)
  (let ((inhibit-read-only t))
    (delete-region (point-min) (point-max))
    (comint-output-filter (get-buffer-process (current-buffer))
                          cmacs-c-jit-repl-prompt)))

;;;###autoload
(defun cmacs-c-jit-repl ()
  "Open the cintrospect C JIT REPL."
  (interactive)
  (unless (and (fboundp 'cmacs-c-compile)
               (condition-case _
                   (progn (cmacs-c-handle-info -1) t)
                 (cmacs-cintrospect-not-implemented nil)
                 (error t)))
    (user-error "cintrospect JIT (Phase 2) not available; rebuild with --with-cmacs-cintrospect"))
  (let ((buf (get-buffer-create cmacs-c-jit-repl-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'cmacs-c-jit-repl-mode)
        (cmacs-c-jit-repl-mode)))
    (pop-to-buffer buf)))

(provide 'cmacs-cintrospect-jit-repl)
;;; cmacs-cintrospect-jit-repl.el ends here
