;;; cmacs-cintrospect.el --- Runtime C self-introspection UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;;
;; High-level Lisp surface and interactive buffers for the cintrospect
;; subsystem.  Built on the C-side `cmacs-c-*' DEFUNs.
;;
;; Buffers:
;;   `cmacs-c-introspect'        --- top-level dashboard
;;   `cmacs-c-list-symbols'      --- *cmacs-c-symbols* tabulated list
;;   `cmacs-c-list-defuns-buffer' --- DEFUN registry
;;   `cmacs-c-list-objects-buffer' --- loaded ELF objects
;;   `cmacs-c-show-type'         --- *cmacs-c-type: NAME* detail
;;   `cmacs-c-show-stack'        --- C stack trace
;;
;; The JIT REPL and the patch list buffers live in their own modules
;; (cmacs-cintrospect-jit-repl.el, cmacs-cpatch.el).
;;
;; Patterns mirrored: `cmacs-gowl-dashboard.el' (org dashboard),
;; `cmacs-crispy.el:58' (comint REPL), `cmacs-gi.el:127' (describe
;; pattern with `with-help-window').

;;; Code:

(require 'tabulated-list)
(require 'cl-lib)

(defgroup cmacs-cintrospect nil
  "Runtime C self-introspection for cmacs."
  :group 'cmacs
  :prefix "cmacs-c-")

(defcustom cmacs-c-default-glob nil
  "Default glob filter for `cmacs-c-list-symbols' and friends."
  :type '(choice (const :tag "No filter" nil) string))

(defcustom cmacs-c-list-limit 25000
  "Maximum number of rows shown in symbol browsers.
The walker now walks GLOBAL symbols across all modules first, then
locals --- so cmacs-side `cmacs_*' globals appear with much smaller
limits than the local-symbol total of ~22K would suggest.  25000 is
chosen to comfortably hold every global from cmacs's main binary
plus every loaded shared object."
  :type 'integer)

;; ─── Capability detection ─────────────────────────────────────────

(defun cmacs-c-available-p ()
  "Return non-nil if the cintrospect C subsystem is loaded."
  (fboundp 'cmacs-c-list-objects))

(defun cmacs-c-jit-available-p ()
  "Return non-nil if the JIT (Phase 2) DEFUNs are functional, not stubs."
  (when (fboundp 'cmacs-c-compile)
    (condition-case _
        (let ((h (cmacs-c-compile "Lisp_Object t_(void) { return Qt; }"
                                  "t_" "Lisp_Object(void)")))
          (cmacs-c-handle-dispose h)
          t)
      (cmacs-cintrospect-not-implemented nil)
      (error nil))))

;;;###autoload
(defun cmacs-c-eval (source &optional sig)
  "Compile SOURCE and call the resulting function (no-arg by default).
Convenience wrapper around `cmacs-c-compile' + `cmacs-c-call' +
`cmacs-c-handle-dispose'.  SIG defaults to \"Lisp_Object(void)\".

Use this from M-x for one-off evaluation of a self-contained C
function definition.  The function name is parsed from the source.

Example interactive: M-x cmacs-c-eval RET
  Lisp_Object greet(void) { return build_string(\"hi\"); }"
  (interactive "sC source: ")
  (let* ((sig (or sig "Lisp_Object(void)"))
         (fn (and (string-match
                   "[_a-zA-Z][_a-zA-Z0-9]*[[:space:]\n]+\\([_a-zA-Z][_a-zA-Z0-9]*\\)[[:space:]\n]*("
                   source)
                  (match-string 1 source))))
    (unless fn
      (user-error "could not parse a function definition from SOURCE"))
    (let ((h (cmacs-c-compile source fn sig)))
      (unwind-protect
          (let ((result (cmacs-c-call h)))
            (when (called-interactively-p 'any)
              (message "=> %S" result))
            result)
        (cmacs-c-handle-dispose h)))))

(defun cmacs-c-cpatch-available-p ()
  "Return non-nil if the cpatch subsystem is loaded."
  (fboundp 'cmacs-c-patch-defun))

;; ─── *cmacs-c-introspect* dashboard ───────────────────────────────

;;;###autoload
(defun cmacs-c-introspect ()
  "Open the cmacs runtime-C introspection dashboard."
  (interactive)
  (unless (cmacs-c-available-p)
    (user-error "cintrospect not available --- rebuild with --with-cmacs-cintrospect"))
  (let ((buf (get-buffer-create "*cmacs-c-introspect*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "* CMacs Runtime C Introspection\n\n")
        (insert (format "Status: cintrospect=%s  JIT=%s  cpatch=%s\n\n"
                        (if (cmacs-c-available-p)       "ON"  "OFF")
                        (if (cmacs-c-jit-available-p)   "Phase-2 (live)"
                          "Phase-1 stub")
                        (if (cmacs-c-cpatch-available-p) "ON"  "OFF")))
        (let* ((objs (cmacs-c-list-objects))
               (with-dwarf (cl-count-if (lambda (o) (plist-get o :has-dwarf)) objs))
               (defuns (cmacs-c-list-defuns nil)))
          (insert (format "Loaded ELF objects:  %d (%d with DWARF)\n"
                          (length objs) with-dwarf))
          (insert (format "C primitives (DEFUNs): %d\n\n" (length defuns))))
        (insert "** Browsers\n\n")
        (insert "  [[elisp:(cmacs-c-list-symbols)][Symbols]]      ")
        (insert "[[elisp:(cmacs-c-list-defuns-buffer)][DEFUNs]]      ")
        (insert "[[elisp:(cmacs-c-list-objects-buffer)][Objects]]\n\n")
        (insert "  [[elisp:(call-interactively (function cmacs-c-show-type))][Type info]]   ")
        (insert "[[elisp:(cmacs-c-show-stack)][Stack trace]]\n\n")
        (when (cmacs-c-cpatch-available-p)
          (insert "** Hot patches\n\n")
          (insert "  [[elisp:(cmacs-c-list-patches-buffer)][Patches]]   ")
          (insert "[[elisp:(call-interactively (function cmacs-c-unpatch-all))][Unpatch all (panic)]]\n\n"))
        (unless (cmacs-c-cpatch-available-p)
          (insert "** Hot patches\n\n  cpatch is OFF — rebuild with `--enable-cmacs-cpatch`.\n\n"))
        (when (cmacs-c-jit-available-p)
          (insert "** JIT REPL\n\n  [[elisp:(cmacs-c-jit-repl)][cmacs-c-jit-repl]]\n\n"))
        (unless (cmacs-c-jit-available-p)
          (insert "** JIT REPL\n\n  Phase 2 — not yet implemented in this build.\n\n"))
        (insert "Press `g' to refresh, `q' to bury.\n")
        (org-mode)
        ;; Trust elisp: links inside this dashboard --- they're our
        ;; own static link table, not user input.  Without this org
        ;; prompts "Execute (cmacs-c-list-symbols)?" on every RET.
        (setq-local org-link-elisp-skip-confirm-regexp
                    "\\`(cmacs-")
        (use-local-map (copy-keymap org-mode-map))
        (local-set-key "g" #'cmacs-c-introspect)
        (local-set-key "q" #'bury-buffer)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;; ─── *cmacs-c-symbols* browser ────────────────────────────────────

(defvar cmacs-c-symbols-glob nil
  "Buffer-local glob filter for the symbols list.")
(make-variable-buffer-local 'cmacs-c-symbols-glob)

(defcustom cmacs-c-symbols-show-values t
  "When non-nil, the *cmacs-c-symbols* browser includes a Value column.
For function symbols this is empty; for data the value is read via
`cmacs-c-symbol-value' (Lisp_Object for V-/Q- prefixed names of size
8, hex bytes otherwise).  Set to nil to suppress reads if you ever
encounter a stability issue (DWARF lies = SIGSEGV)."
  :type 'boolean :group 'cmacs-cintrospect)

(defcustom cmacs-c-symbols-value-truncate 60
  "Maximum width of the rendered Value column in characters."
  :type 'integer :group 'cmacs-cintrospect)

(define-derived-mode cmacs-c-symbols-mode tabulated-list-mode "C-Symbols"
  "Browse C symbols in the cmacs binary."
  (setq tabulated-list-format
        (vconcat
         [("Name"   42 t)
          ("Kind"    9 t)
          ("Object" 22 t)
          ("Size"    8 (lambda (a b)
                         (< (string-to-number (aref (cadr a) 3))
                            (string-to-number (aref (cadr b) 3)))))
          ("Addr"   16 t)]
         (when cmacs-c-symbols-show-values
           [("Value"  60 nil)])))
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "Name" nil))
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'cmacs-c--symbols-refresh nil t))

(defun cmacs-c--read-value-safely (sym-info)
  "Return a short Value-column string for SYM-INFO plist, or empty.
Function symbols return \"\".  Data symbols return the formatted
result of `cmacs-c-symbol-value' truncated to
`cmacs-c-symbols-value-truncate' chars."
  (cond
   ((eq (plist-get sym-info :kind) 'function) "")
   (t
    (condition-case _
        (let* ((v (cmacs-c-symbol-value (plist-get sym-info :symbol-name)))
               (s (cond
                   ((null v) "")
                   ((stringp v) v)
                   (t (format "%S" v)))))
          (if (> (length s) cmacs-c-symbols-value-truncate)
              (concat (substring s 0
                                 (- cmacs-c-symbols-value-truncate 1))
                      "…")
            s))
      (error "(error)")))))

(defun cmacs-c--symbols-refresh ()
  (let* ((rows (cmacs-c-list 'symbol cmacs-c-symbols-glob
                             cmacs-c-list-limit))
         (entries
          (mapcar
           (lambda (s)
             (let ((base (vector
                          (or (plist-get s :symbol-name) "")
                          (format "%s" (or (plist-get s :kind) ""))
                          (or (plist-get s :object) "")
                          (format "%d" (or (plist-get s :size) 0))
                          (format "0x%x" (or (plist-get s :addr) 0)))))
               (list (plist-get s :symbol-name)
                     (if cmacs-c-symbols-show-values
                         (vconcat base
                                  (vector (cmacs-c--read-value-safely s)))
                       base))))
           rows)))
    (setq tabulated-list-entries entries)))

(defun cmacs-c--symbols-edit-at-point ()
  "Edit the value of the data symbol on the current row.
Reads the current value, prompts for a new one, and writes it back
via `cmacs-c-symbol-set-value'.  Refuses to edit function symbols.

Format inferred from the current value's type when possible:
- integer current value → int format
- string current value → str format
- otherwise prompts for explicit format."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (cols (and id (tabulated-list-get-entry)))
         (kind (and cols (intern (aref cols 1)))))
    (unless id
      (user-error "no symbol on this row"))
    (when (eq kind 'function)
      (user-error "cannot edit a function symbol's value"))
    (let* ((current (cmacs-c-symbol-value id))
           (fmt (cond
                 ((stringp current)
                  (if (string-match-p "\\` *[0-9a-fA-F]\\{2\\}\\([ ][0-9a-fA-F]\\{2\\}\\)*\\($\\| \\.\\.\\.\\)"
                                      current)
                      ;; Looks like our hex output --- offer hex.
                      'hex
                    'str))
                 ((integerp current) 'int)
                 (t 'lisp)))
           (prompt (format "New %s value (current: %s): "
                           fmt
                           (if (stringp current)
                               (if (> (length current) 60)
                                   (concat (substring current 0 57) "...")
                                 current)
                             (format "%S" current))))
           (input (read-string prompt))
           (new-value (cond
                       ((eq fmt 'int) (string-to-number input))
                       ((eq fmt 'lisp) (read input))
                       (t input))))
      (condition-case err
          (progn
            (cmacs-c-symbol-set-value id new-value fmt)
            ;; Refresh just this row's value.
            (let ((inhibit-read-only t))
              (cmacs-c--symbols-refresh)
              (tabulated-list-print 'remember))
            (message "Set %s = %s (format: %s)" id input fmt))
        (error (user-error "cmacs-c-symbol-set-value failed: %S" err))))))

;;;###autoload
(defun cmacs-c-list-symbols (&optional glob)
  "Open the *cmacs-c-symbols* browser; optional GLOB filters by name."
  (interactive
   (list (read-string "Symbol glob (empty for all): "
                      cmacs-c-default-glob)))
  (unless (cmacs-c-available-p)
    (user-error "cintrospect not available"))
  (let ((buf (get-buffer-create "*cmacs-c-symbols*")))
    (with-current-buffer buf
      (cmacs-c-symbols-mode)
      (setq cmacs-c-symbols-glob (and glob (not (string-empty-p glob)) glob))
      (cmacs-c--symbols-refresh)
      (tabulated-list-print)
      (local-set-key (kbd "RET")
                     (lambda () (interactive)
                       (cmacs-c-show-symbol (tabulated-list-get-id))))
      (local-set-key (kbd "t")
                     (lambda () (interactive)
                       (cmacs-c-show-type
                        (read-string "Type name: " (tabulated-list-get-id)))))
      ;; Edit-at-point: pick bindings that don't collide with Evil
      ;; motion (`e' = evil-forward-word-end, `g e' =
      ;; evil-backward-end-of-word).  `C-c C-e' is the Emacs-standard
      ;; prefix that Evil never intercepts; `, e' uses the Doom local
      ;; leader; `M-RET' is a single-keystroke alt for non-Evil
      ;; users.
      (local-set-key (kbd "C-c C-e") #'cmacs-c--symbols-edit-at-point)
      (local-set-key (kbd ", e")    #'cmacs-c--symbols-edit-at-point)
      (local-set-key (kbd "M-RET")  #'cmacs-c--symbols-edit-at-point)
      (local-set-key (kbd "/")
                     (lambda () (interactive)
                       (setq cmacs-c-symbols-glob
                             (read-string "Filter glob: " cmacs-c-symbols-glob))
                       (cmacs-c--symbols-refresh)
                       (tabulated-list-print))))
    (pop-to-buffer buf)))

;; ─── DEFUN registry browser ───────────────────────────────────────

(define-derived-mode cmacs-c-defuns-mode tabulated-list-mode "C-DEFUNs"
  "Browse cmacs DEFUN registry."
  (setq tabulated-list-format
        [("Symbol"   38 t)
         ("C name"   38 t)
         ("Min"       4 t)
         ("Max"       5 t)
         ("Source"   60 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "Symbol" nil))
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-c-list-defuns-buffer ()
  "Open the DEFUN registry browser."
  (interactive)
  (let ((buf (get-buffer-create "*cmacs-c-defuns*")))
    (with-current-buffer buf
      (cmacs-c-defuns-mode)
      (let ((rows (cmacs-c-list-defuns nil)))
        (setq tabulated-list-entries
              (mapcar
               (lambda (d)
                 (let* ((sym (plist-get d :symbol-name))
                        (info (when sym
                                (cmacs-c-defun-info (intern sym))))
                        (file (plist-get info :file))
                        (line (plist-get info :line)))
                   (list sym
                         (vector
                          (or sym "")
                          (or (plist-get d :c-name) "")
                          (format "%d" (or (plist-get d :min-args) 0))
                          (format "%d" (or (plist-get d :max-args) 0))
                          (if (and file line)
                              (format "%s:%d" (file-name-nondirectory file) line)
                            "")))))
               rows)))
      (tabulated-list-print)
      (local-set-key (kbd "RET")
                     (lambda () (interactive)
                       (cmacs-c-show-defun (intern (tabulated-list-get-id))))))
    (pop-to-buffer buf)))

;; ─── Loaded objects browser ───────────────────────────────────────

(define-derived-mode cmacs-c-objects-mode tabulated-list-mode "C-Objects"
  "Browse loaded ELF objects."
  (setq tabulated-list-format
        [("Name"     35 t)
         ("DWARF"     6 t)
         ("Size"     12 (lambda (a b)
                          (< (string-to-number (aref (cadr a) 2))
                             (string-to-number (aref (cadr b) 2)))))
         ("Path"     90 nil)])
  (setq tabulated-list-sort-key (cons "Name" nil))
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-c-list-objects-buffer ()
  "Open the loaded-ELF-objects browser."
  (interactive)
  (let ((buf (get-buffer-create "*cmacs-c-objects*")))
    (with-current-buffer buf
      (cmacs-c-objects-mode)
      (setq tabulated-list-entries
            (mapcar
             (lambda (o)
               (list (plist-get o :symbol-name)
                     (vector
                      (or (plist-get o :symbol-name) "")
                      (if (plist-get o :has-dwarf) "yes" "—")
                      (format "%d" (or (plist-get o :size) 0))
                      (or (plist-get o :path) ""))))
             (cmacs-c-list-objects)))
      (tabulated-list-print))
    (pop-to-buffer buf)))

;; ─── Symbol detail (help-window pattern from cmacs-gi.el:127) ──────

;;;###autoload
(defun cmacs-c-show-symbol (name)
  "Show details for the C symbol NAME."
  (interactive "sSymbol: ")
  (let ((info (cmacs-c-symbol-info name)))
    (with-help-window (format "*cmacs-c-symbol: %s*" name)
      (princ (format "C symbol %s\n" name))
      (princ (make-string (+ 9 (length name)) ?─))
      (princ "\n\n")
      (if (null info)
          (princ "Not found.\n")
        (princ (format "Kind:   %s\n" (plist-get info :kind)))
        (princ (format "Object: %s\n" (plist-get info :object)))
        (princ (format "Size:   %d bytes\n" (or (plist-get info :size) 0)))
        (princ (format "Addr:   0x%x\n" (or (plist-get info :addr) 0)))
        (when (plist-get info :file)
          (princ (format "File:   %s\n" (plist-get info :file)))
          (princ (format "Line:   %s\n" (plist-get info :line))))))))

;; ─── DEFUN detail ─────────────────────────────────────────────────

;;;###autoload
(defun cmacs-c-show-defun (sym)
  "Show details for the DEFUN named SYM."
  (interactive "SDEFUN: ")
  (let ((info (cmacs-c-defun-info sym)))
    (with-help-window (format "*cmacs-c-defun: %s*" sym)
      (princ (format "DEFUN %s\n" sym))
      (princ (make-string (+ 6 (length (symbol-name sym))) ?─))
      (princ "\n\n")
      (if (null info)
          (princ "Not a DEFUN.\n")
        (princ (format "Lisp name: %s\n" (plist-get info :symbol-name)))
        (princ (format "C name:    %s\n" (plist-get info :c-name)))
        (princ (format "Arity:     %d..%d\n"
                       (plist-get info :min-args)
                       (plist-get info :max-args)))
        (princ (format "Fn addr:   0x%x\n" (or (plist-get info :fn-addr) 0)))
        (when (plist-get info :file)
          (princ (format "Source:    %s:%d\n"
                         (plist-get info :file)
                         (plist-get info :line))))
        (princ "\nDocstring:\n  ")
        (princ (or (documentation sym) "(no docstring)"))))))

;; ─── Type detail ──────────────────────────────────────────────────

;;;###autoload
(defun cmacs-c-show-type (name)
  "Show the C type layout for NAME."
  (interactive "sType name: ")
  (let ((info (cmacs-c-type-info name)))
    (with-help-window (format "*cmacs-c-type: %s*" name)
      (princ (format "C type %s\n" name))
      (princ (make-string (+ 7 (length name)) ?─))
      (princ "\n\n")
      (if (null info)
          (princ "Type not found in DWARF.\n")
        (princ (format "Kind:   %s\n" (plist-get info :kind)))
        (princ (format "Size:   %d bytes\n" (plist-get info :size)))
        (princ (format "Align:  %d\n\n" (plist-get info :align)))
        (let ((fields (plist-get info :fields)))
          (cond
           ((eq (plist-get info :kind) 'enum)
            (princ "Enumerators:\n")
            (dolist (f fields)
              (princ (format "  %-30s = %d\n"
                             (plist-get f :symbol-name)
                             (or (plist-get f :values) 0)))))
           (t
            (princ (format "Fields (%d):\n" (length fields)))
            (dolist (f fields)
              (princ (format "  +%-5d %-30s %-20s (size %d%s)\n"
                             (or (plist-get f :addr) 0)
                             (or (plist-get f :symbol-name) "<anon>")
                             (or (plist-get f :type-name) "")
                             (or (plist-get f :size) 0)
                             (let ((b (plist-get f :bit-size)))
                               (if (and b (> b 0)) (format " bit:%d" b) "")))))))) ))))

;; ─── Stack trace ──────────────────────────────────────────────────

;;;###autoload
(defun cmacs-c-show-stack (&optional depth)
  "Show the current C stack as a buffer."
  (interactive (list (read-number "Depth: " 32)))
  (with-help-window "*cmacs-c-stack*"
    (princ (format "C stack trace (depth %d)\n" depth))
    (princ (make-string 28 ?─))
    (princ "\n\n")
    (let ((i 0))
      (dolist (frame (cmacs-c-stack-trace depth))
        (princ (format "  #%-3d 0x%x  %s"
                       i (or (plist-get frame :addr) 0)
                       (or (plist-get frame :function) "?")))
        (when (plist-get frame :file)
          (princ (format "\n         %s:%s"
                         (plist-get frame :file)
                         (plist-get frame :line))))
        (princ "\n")
        (cl-incf i)))))

(provide 'cmacs-cintrospect)
;;; cmacs-cintrospect.el ends here
