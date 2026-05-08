;;; ob-c-introspect.el --- Org-babel block type for cintrospect -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;;
;; Provides Org-babel `#+begin_src c-introspect ...' blocks that run
;; cintrospect lookups directly from inside an Org buffer.  Useful
;; for living architecture documentation: a struct's layout displayed
;; right next to its description, automatically refreshed on
;; `C-c C-c'.
;;
;; Block body forms:
;;
;;   #+begin_src c-introspect :type Lisp_Subr
;;   #+end_src
;;     -> outputs the field layout
;;
;;   #+begin_src c-introspect :symbol Fbuffer_string
;;   #+end_src
;;     -> outputs file:line and prototype info
;;
;;   #+begin_src c-introspect :defuns "buffer-*"
;;   #+end_src
;;     -> outputs the matching DEFUN list as an Org table
;;
;; Two block-type complementary forms are provided: `c-introspect'
;; (read-only DWARF queries) and `c-eval' (compile-and-call via JIT).

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'cmacs-cintrospect)

(defun org-babel-execute:c-introspect (body params)
  "Execute a c-introspect BODY block with PARAMS.
Recognised :params (one of):
  :type NAME       struct/union/enum layout
  :symbol NAME     C symbol info
  :defun  NAME     Lisp DEFUN info
  :defuns GLOB     list of DEFUNs matching glob
  :objects t       list of loaded ELF objects
  :stack DEPTH     C stack trace (DEPTH frames; default 16)"
  (unless (cmacs-c-available-p)
    (error "cintrospect not available; rebuild cmacs with --with-cmacs-cintrospect"))
  (let ((type    (cdr (assq :type    params)))
        (symbol  (cdr (assq :symbol  params)))
        (defun-  (cdr (assq :defun   params)))
        (defuns  (cdr (assq :defuns  params)))
        (objects (cdr (assq :objects params)))
        (stack   (cdr (assq :stack   params))))
    (cond
     (type    (ob-c-introspect--render-type type))
     (symbol  (ob-c-introspect--render-symbol symbol))
     (defun-  (ob-c-introspect--render-defun-info defun-))
     (defuns  (ob-c-introspect--render-defuns defuns))
     (objects (ob-c-introspect--render-objects))
     (stack   (ob-c-introspect--render-stack
              (if (numberp stack) stack 16)))
     (t (when (and body (not (string-empty-p (string-trim body))))
          ;; Body without explicit :param: treat first whitespace-
          ;; delimited token as a type name.
          (let ((tok (car (split-string (string-trim body)))))
            (ob-c-introspect--render-type tok)))))))

(defun ob-c-introspect--render-type (name)
  (let ((info (cmacs-c-type-info name)))
    (cond
     ((null info) (format "(type `%s' not found)" name))
     ((eq (plist-get info :kind) 'enum)
      (with-output-to-string
        (princ (format "enum %s {  /* size %d */\n" name (plist-get info :size)))
        (dolist (f (plist-get info :fields))
          (princ (format "  %-30s = %d\n"
                         (plist-get f :symbol-name)
                         (or (plist-get f :values) 0))))
        (princ "};\n")))
     (t
      (with-output-to-string
        (princ (format "%s %s {  /* size %d, align %d */\n"
                       (plist-get info :kind) name
                       (plist-get info :size) (plist-get info :align)))
        (dolist (f (plist-get info :fields))
          (princ (format "  +%-5d %-30s %-20s (size %d)\n"
                         (or (plist-get f :addr) 0)
                         (or (plist-get f :symbol-name) "<anon>")
                         (or (plist-get f :type-name) "")
                         (or (plist-get f :size) 0))))
        (princ "};\n"))))))

(defun ob-c-introspect--render-symbol (name)
  (let ((info (cmacs-c-symbol-info name)))
    (if (null info)
        (format "(symbol `%s' not found)" name)
      (with-output-to-string
        (princ (format "C symbol: %s\n" (plist-get info :symbol-name)))
        (princ (format "  kind:   %s\n" (plist-get info :kind)))
        (princ (format "  object: %s\n" (plist-get info :object)))
        (princ (format "  addr:   0x%x\n" (or (plist-get info :addr) 0)))
        (princ (format "  size:   %d bytes\n" (or (plist-get info :size) 0)))
        (when (plist-get info :file)
          (princ (format "  source: %s:%s\n"
                         (plist-get info :file)
                         (plist-get info :line))))))))

(defun ob-c-introspect--render-defun-info (sym-or-name)
  (let ((sym (if (stringp sym-or-name) (intern sym-or-name) sym-or-name))
        info)
    (setq info (cmacs-c-defun-info sym))
    (if (null info)
        (format "(`%S' is not a DEFUN)" sym)
      (with-output-to-string
        (princ (format "DEFUN %s\n" (plist-get info :symbol-name)))
        (princ (format "  C name:  %s\n" (plist-get info :c-name)))
        (princ (format "  arity:   %d..%d\n"
                       (plist-get info :min-args)
                       (plist-get info :max-args)))
        (princ (format "  fn-addr: 0x%x\n" (or (plist-get info :fn-addr) 0)))
        (when (plist-get info :file)
          (princ (format "  source:  %s:%d\n"
                         (plist-get info :file)
                         (plist-get info :line))))))))

(defun ob-c-introspect--render-defuns (glob)
  ;; Org table.
  (let ((rows (cmacs-c-list-defuns glob)))
    (with-output-to-string
      (princ "| Symbol | Min | Max | Source |\n")
      (princ "|--------+-----+-----+--------|\n")
      (dolist (r rows)
        (let* ((info (cmacs-c-defun-info (intern (plist-get r :symbol-name))))
               (file (plist-get info :file))
               (line (plist-get info :line)))
          (princ (format "| %s | %d | %d | %s |\n"
                         (plist-get r :symbol-name)
                         (plist-get r :min-args)
                         (plist-get r :max-args)
                         (if file
                             (format "%s:%d" (file-name-nondirectory file) line)
                           ""))))))))

(defun ob-c-introspect--render-objects ()
  (let ((objs (cmacs-c-list-objects)))
    (with-output-to-string
      (princ "| Name | DWARF | Path |\n")
      (princ "|------+-------+------|\n")
      (dolist (o objs)
        (princ (format "| %s | %s | %s |\n"
                       (plist-get o :symbol-name)
                       (if (plist-get o :has-dwarf) "yes" "—")
                       (plist-get o :path)))))))

(defun ob-c-introspect--render-stack (depth)
  (with-output-to-string
    (let ((i 0))
      (dolist (frame (cmacs-c-stack-trace depth))
        (princ (format "  #%-2d 0x%x  %s%s\n"
                       i
                       (or (plist-get frame :addr) 0)
                       (or (plist-get frame :function) "?")
                       (let ((f (plist-get frame :file))
                             (l (plist-get frame :line)))
                         (if (and f l)
                             (format "  %s:%d"
                                     (file-name-nondirectory f) l)
                           ""))))
        (cl-incf i)))))

(defun org-babel-execute:c-eval (body params)
  "Execute a c-eval BODY block: compile + call via cintrospect JIT.
Optional :sig PARAMS specifies the expected signature; default is
\"Lisp_Object(void)\"."
  (unless (cmacs-c-jit-available-p)
    (error "cintrospect JIT (Phase 2) not available"))
  (let ((sig (or (cdr (assq :sig params)) "Lisp_Object(void)")))
    (format "%S" (cmacs-c-eval body sig))))

;; Block-type defaults: these defvars must exist before org-babel's
;; first execution but org sometimes refuses to assume they were
;; named.  Defining them ourselves is harmless and matches the
;; pattern used by other ob-* modules (see ob-shell.el).
(defvar org-babel-default-header-args:c-introspect
  '((:results . "output"))
  "Default header args for c-introspect babel blocks.")

(defvar org-babel-default-header-args:c-eval
  '((:results . "raw"))
  "Default header args for c-eval babel blocks.")

(provide 'ob-c-introspect)
;;; ob-c-introspect.el ends here
