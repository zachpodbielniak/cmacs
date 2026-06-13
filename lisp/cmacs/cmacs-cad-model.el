;;; cmacs-cad-model.el --- View STL/STEP/OBJ files through libregnum -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Visiting a mesh / B-rep file (.stl .obj .step .iges .3mf) opens it as a
;; rendered model in the libregnum editor, beside a small info panel
;; (format, triangle count, bounding box, watertightness).  The geometry
;; goes through cad-glib's importer + the CAD_PART bake path -- the same
;; one the workbench and the G-code viewer use -- so binary STL and B-rep
;; STEP both render with orbit / zoom / snapshot, with no raylib
;; file-loader involvement.

;;; Code:

(require 'cl-lib)
(require 'cmacs-cad nil t)
(require 'cmacs-libregnum nil t)

(declare-function cmacs-libregnum-editor "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-add-visual "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-focus "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-supported-p "cmacs-libregnum")
(declare-function cmacs-cad-available-p "cmacs-cad")
(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-inspect "cmacs-cad-defuns.c")
(declare-function cmacs-cad-doc-close "cmacs-cad-defuns.c")

(defconst cmacs-cad-model--visual-cad-part 9
  "LRG_NODE_VISUAL_CAD_PART (the import + CAD_PART bake render path).")

(defvar-local cmacs-cad-model--dir nil)
(defvar-local cmacs-cad-model--cad nil)
(defvar-local cmacs-cad-model--viewer nil)
(defvar-local cmacs-cad-model--info-buffer nil
  "On the editor buffer: the paired info buffer (for q/g from the viewport).")

(defun cmacs-cad-model--viewer-quit ()
  "Quit the model viewer (kills the info buffer, which cleans up the editor)."
  (interactive)
  (when (buffer-live-p cmacs-cad-model--info-buffer)
    (kill-buffer cmacs-cad-model--info-buffer)))

(defun cmacs-cad-model--viewer-revert ()
  "Re-import the model from the viewport."
  (interactive)
  (when (buffer-live-p cmacs-cad-model--info-buffer)
    (with-current-buffer cmacs-cad-model--info-buffer
      (cmacs-cad-model-revert))))

(defvar cmacs-cad-model--viewport-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'cmacs-cad-toggle-edges)
    (define-key map (kbd "g") #'cmacs-cad-model--viewer-revert)
    (define-key map (kbd "q") #'cmacs-cad-model--viewer-quit)
    map)
  "Keys composed onto the editor buffer when it is a model viewport.
The viewport window is focused (so mouse orbit/pan work without a
pre-click), so these mirror the info-panel keys there.")

(defun cmacs-cad-model--available-p ()
  (and (display-graphic-p)
       (fboundp 'cmacs-libregnum-supported-p)
       (ignore-errors (cmacs-libregnum-supported-p))
       (fboundp 'cmacs-cad-available-p)
       (cmacs-cad-available-p)))

(defun cmacs-cad-model--write-importer (model)
  "Write a generated part that imports MODEL (absolute path); return its path."
  (setq cmacs-cad-model--dir (make-temp-file "cmacs-cad-model" t)
        cmacs-cad-model--cad (expand-file-name "view.cad"
                                               cmacs-cad-model--dir))
  (with-temp-file cmacs-cad-model--cad
    (insert ";; generated viewer part\n"
            (format "(defpart imported (import %S))\n"
                    (expand-file-name model))))
  cmacs-cad-model--cad)

(defun cmacs-cad-model--info ()
  "Return a one-line info string for the model (triangles, bbox, …), or nil."
  (ignore-errors
    (cmacs-cad-eval cmacs-cad-model--cad)
    (let* ((i (cmacs-cad-inspect cmacs-cad-model--cad))
           (bb (plist-get i :bbox)))
      (prog1
          (format "triangles %s   watertight %s%s"
                  (plist-get i :triangles)
                  (if (plist-get i :watertight) "yes" "no")
                  (if bb
                      (format "   size %.2f x %.2f x %.2f"
                              (- (nth 3 bb) (nth 0 bb))
                              (- (nth 4 bb) (nth 1 bb))
                              (- (nth 5 bb) (nth 2 bb)))
                    ""))
        (ignore-errors (cmacs-cad-doc-close cmacs-cad-model--cad))))))

(defun cmacs-cad-model--cleanup ()
  (when (and cmacs-cad-model--dir (file-directory-p cmacs-cad-model--dir))
    (ignore-errors (delete-directory cmacs-cad-model--dir t)))
  (when (buffer-live-p cmacs-cad-model--viewer)
    (kill-buffer cmacs-cad-model--viewer)))

(defun cmacs-cad-model--open ()
  "Open the libregnum editor on the imported model beside this info buffer."
  (let* ((info-buf (current-buffer))
         (model (buffer-file-name))
         (name (file-name-base model)))
    (cmacs-cad-model--write-importer model)
    ;; Info panel (the file buffer itself is binary/irrelevant text).
    (let ((inhibit-read-only t) (info (cmacs-cad-model--info)))
      (erase-buffer)
      (insert (propertize (format "%s\n" (file-name-nondirectory model))
                          'face 'bold))
      (insert (format "%s\n\n" (upcase (or (file-name-extension model) "?"))))
      (insert (or info "(could not import — unsupported or malformed)") "\n")
      (insert (propertize "\nRendered in the libregnum editor →  (q quits)\n"
                          'face 'shadow))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (let ((editor (save-window-excursion (cmacs-libregnum-editor))))
      (with-current-buffer info-buf (setq cmacs-cad-model--viewer editor))
      (let ((id (cmacs-libregnum-editor-add-visual
                 editor cmacs-cad-model--visual-cad-part
                 cmacs-cad-model--cad name)))
        (when (fboundp 'cmacs-cad-apply-view-style)
          (cmacs-cad-apply-view-style editor))
        (when (and id (fboundp 'cmacs-libregnum-editor-focus))
          (ignore-errors (cmacs-libregnum-editor-focus editor id))))
      ;; Compose the viewport keys onto the editor + remember the info
      ;; buffer, then FOCUS the editor window: mouse orbit/pan only route to
      ;; a libregnum view when its window is selected, so a viewer that left
      ;; the info buffer focused made right-drag fall through to Emacs (a
      ;; context-menu, not a rotate).
      (with-current-buffer editor
        (setq cmacs-cad-model--info-buffer info-buf)
        (use-local-map (make-composed-keymap cmacs-cad-model--viewport-map
                                              (current-local-map))))
      (delete-other-windows)
      (set-window-buffer (selected-window) info-buf)
      (select-window (split-window-right))
      (switch-to-buffer editor)
      (select-window (get-buffer-window editor)))))

(declare-function cmacs-cad-toggle-edges "cmacs-cad")

(defvar cmacs-cad-model-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'cmacs-cad-model-revert)
    (define-key map (kbd "e") #'cmacs-cad-toggle-edges)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-cad-model-mode'.")

;;;###autoload
(define-derived-mode cmacs-cad-model-mode special-mode "CAD-Model"
  "View an STL/OBJ/STEP/IGES/3MF file as a rendered model in libregnum."
  ;; This buffer visits a (possibly binary) model file but DISPLAYS an info
  ;; panel; guard hard against ever writing the panel over the model:
  ;;   * the info text is marked unmodified, and
  ;;   * a write-contents guard refuses any save.
  (setq-local write-contents-functions
              (list (lambda ()
                      (message "Model viewer: %s is left unchanged"
                               (file-name-nondirectory
                                (or (buffer-file-name) "the file")))
                      t)))
  (setq-local revert-buffer-function
              (lambda (&rest _) (cmacs-cad-model-revert)))
  (add-hook 'kill-buffer-hook #'cmacs-cad-model--cleanup nil t)
  ;; Replace the (possibly binary) file content with a placeholder NOW so no
  ;; raw bytes flash, then DEFER the real render: opening the libregnum editor
  ;; + window juggling must run after `find-file' has displayed this buffer,
  ;; otherwise the viewport fails to attach (the `.cad' workbench defers too).
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "%s\n\n"
                                (file-name-nondirectory
                                 (or (buffer-file-name) "model")))
                        'face 'bold))
    (insert (propertize (if (cmacs-cad-model--available-p)
                            "Loading 3-D view…\n"
                          "libregnum/CAD not available — cannot render.\n")
                        'face 'shadow)))
  (set-buffer-modified-p nil)
  (when (cmacs-cad-model--available-p)
    (let ((buf (current-buffer)))
      (run-with-timer 0.1 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (ignore-errors (cmacs-cad-model--open))
             (set-buffer-modified-p nil))))))))

(defun cmacs-cad-model-revert ()
  "Re-import and re-render the model (after it changed on disk)."
  (interactive)
  (cmacs-cad-model--cleanup)
  (cmacs-cad-model--open))

;;;###autoload
(progn
  (dolist (ext '("stl" "obj" "step" "stp" "iges" "igs" "3mf"))
    (add-to-list 'auto-mode-alist
                 (cons (format "\\.%s\\'" ext) #'cmacs-cad-model-mode))))

(provide 'cmacs-cad-model)
;;; cmacs-cad-model.el ends here
