;;; cmacs-cad-org-block.el --- Org Babel for CAD parts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `#+begin_src cad' (s-expression DSL) and `#+begin_src ccad' (crispy)
;; blocks whose body IS the part source.  Both route through one execute
;; core:
;;
;;   :file out.png   -> snapshot the part, return an inline image link
;;   :export out.stl -> export the part (stl/obj/step/iges by extension)
;;   :var k=v ...     -> parameter overrides applied at evaluation
;;   (no output)      -> the part's mass properties as an Org table
;;
;; `:tangle out.cad' works for free via standard ob.

;;; Code:

(require 'ob)

(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-set-source "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-inspect "cmacs-cad-defuns.c")
(declare-function cmacs-cad-export "cmacs-cad-defuns.c")
(declare-function cmacs-cad-mcp-snapshot "cmacs-cad-mcp")

(defvar org-babel-default-header-args:cad '((:results . "table"))
  "Default header arguments for `cad' (s-expression) source blocks.")
(defvar org-babel-default-header-args:ccad '((:results . "table"))
  "Default header arguments for `ccad' (crispy) source blocks.")

(defun cmacs-cad-org-block--overrides (params)
  "Return a cmacs-cad override alist (NAME . VALUE) from PARAMS' :var args."
  (delq nil
        (mapcar (lambda (pair)
                  (when (eq (car pair) :var)
                    (let ((v (cdr pair)))
                      (when (consp v)
                        (cons (format "%s" (car v))
                              (if (numberp (cdr v)) (cdr v)
                                (string-to-number (format "%s" (cdr v)))))))))
                params)))

(defun cmacs-cad-org-block--execute (body params extension)
  "Execute a CAD BODY (a part in EXTENSION's language) with PARAMS."
  (unless (and (fboundp 'cmacs-cad-supported-p) (cmacs-cad-supported-p))
    (user-error "CAD subsystem not built (--with-cmacs-cad)"))
  (let* ((path (make-temp-file "cmacs-cad-ob" nil extension))
         (overrides (cmacs-cad-org-block--overrides params))
         (file (cdr (assq :file params)))
         (export (cdr (assq :export params))))
    (unwind-protect
        (progn
          (with-temp-file path (insert body))
          (cmacs-cad-doc-open path)
          (cmacs-cad-eval path overrides)
          (cond
           ;; :file -> snapshot, return the image path (Org shows it inline).
           (file
            (let ((out (cmacs-cad-mcp-snapshot path (expand-file-name file))))
              (if (and (stringp out) (string-prefix-p "error:" out))
                  out
                file)))
           ;; :export -> write the artifact, return its path.
           (export
            (let ((fmt (intern (or (file-name-extension export) "stl"))))
              (cmacs-cad-export path (expand-file-name export)
                                (if (eq fmt 'stl) 'stl fmt))
              export))
           ;; default -> mass properties as an Org table.
           (t
            (let ((i (cmacs-cad-inspect path)))
              (list (list "property" "value")
                    'hline
                    (list "volume" (format "%.4f" (plist-get i :volume)))
                    (list "area" (format "%.4f" (plist-get i :area)))
                    (list "triangles" (plist-get i :triangles))
                    (list "watertight"
                          (if (plist-get i :watertight) "yes" "no")))))))
      (ignore-errors (delete-file path)))))

;;;###autoload
(defun org-babel-execute:cad (body params)
  "Execute a `cad' (s-expression DSL) source BODY with PARAMS."
  (cmacs-cad-org-block--execute body params ".cad"))

;;;###autoload
(defun org-babel-execute:ccad (body params)
  "Execute a `ccad' (crispy) source BODY with PARAMS."
  (cmacs-cad-org-block--execute body params ".ccad"))

(provide 'cmacs-cad-org-block)
;;; cmacs-cad-org-block.el ends here
