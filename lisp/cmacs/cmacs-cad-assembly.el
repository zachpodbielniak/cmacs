;;; cmacs-cad-assembly.el --- Assembly UI for cmacs CAD  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Emacs-facing UI over the cad-glib assembly layer (see
;; `cmacs-cad-assembly.c').  Parts are mated in a `defassembly' form in
;; the .cad/.ccad source; this module inspects the solved result:
;;
;;   C-c C-a b   bill of materials (tabulated list)
;;   C-c C-a i   interference report
;;   C-c C-a s   assembly state + instance transforms
;;   C-c C-a j   drive a joint (prompt for a value) and re-pose
;;   C-c C-a a   open the assembly in the libregnum workbench
;;
;; Joint motion drives the LIVE assembly (no source re-eval), so the
;; mechanism does not reset; `cmacs-cad-assembly-animate-joint' tweens a
;; joint value over time for a "watch the hinge sweep" playback.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'cmacs-cad nil t)

(declare-function cmacs-cad-supported-p "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-assembly-names "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-info "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-bom "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-interference "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-joints "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-set-joint "cmacs-cad-assembly.c")
(declare-function cmacs-libregnum-editor "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-add-visual "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-position "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-rotation "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-visual-param
                  "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-refresh "cmacs-libregnum-defuns.c")
(declare-function cmacs-cad-apply-view-style "cmacs-cad")

(defun cmacs-cad-assembly--available-p ()
  "Return non-nil when the assembly primitives are built in."
  (and (fboundp 'cmacs-cad-supported-p)
       (cmacs-cad-supported-p)
       (fboundp 'cmacs-cad-assembly-names)))

(defun cmacs-cad-assembly--path ()
  "Return this buffer's part file, evaluated, or signal."
  (let ((path (or (buffer-file-name)
                  (user-error "This buffer is not visiting a part file"))))
    (unless (cmacs-cad-assembly--available-p)
      (user-error "CAD assembly support is not built in"))
    ;; Ensure the document is evaluated so the assembly exists.
    (cmacs-cad-eval path)
    path))

(defun cmacs-cad-assembly--pick (path)
  "Pick one assembly name defined in PATH (the only one, or prompt)."
  (let ((names (cmacs-cad-assembly-names path)))
    (cond ((null names) (user-error "This part defines no assembly"))
          ((= (length names) 1) (car names))
          (t (completing-read "Assembly: " names nil t)))))

;;;; Bill of materials -------------------------------------------------

(defvar-local cmacs-cad-bom--entries nil)

(define-derived-mode cmacs-cad-bom-mode tabulated-list-mode "CAD-BOM"
  "Major mode for a CAD assembly bill of materials."
  (setq tabulated-list-format
        [("Part" 24 t) ("Qty" 6 t) ("Volume" 14 t) ("Mass" 14 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-cad-show-bom ()
  "Show the bill of materials for the assembly in this part buffer."
  (interactive)
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (bom (cmacs-cad-assembly-bom path name))
         (buf (get-buffer-create (format "*CAD BOM: %s*" name))))
    (with-current-buffer buf
      (cmacs-cad-bom-mode)
      (setq tabulated-list-entries
            (let ((n 0))
              (mapcar
               (lambda (e)
                 (prog1
                     (list n (vector (plist-get e :part)
                                     (number-to-string (plist-get e :quantity))
                                     (format "%.3f" (plist-get e :volume))
                                     (format "%.3f" (plist-get e :mass))))
                   (setq n (1+ n))))
               bom)))
      (tabulated-list-print))
    (pop-to-buffer buf)))

;;;; Interference -----------------------------------------------------

;;;###autoload
(defun cmacs-cad-check-interference (&optional tolerance)
  "Report interferences between parts of the assembly in this buffer.
With prefix arg, prompt for a volume TOLERANCE."
  (interactive
   (list (when current-prefix-arg
           (read-number "Volume tolerance: " 1e-6))))
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (info (cmacs-cad-assembly-info path name))
         (insts (plist-get info :instances))
         (hits (cmacs-cad-assembly-interference path name tolerance))
         (buf (get-buffer-create (format "*CAD interference: %s*" name))))
    (cl-flet ((iname (id)
                (let ((row (assq id insts)))
                  (if row (format "%s (#%d)" (nth 1 row) id)
                    (format "#%d" id)))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if (null hits)
              (insert "No interferences detected.\n")
            (insert (format "%d interference%s:\n\n"
                            (length hits)
                            (if (= (length hits) 1) "" "s")))
            (dolist (h hits)
              (insert (format "  %s <-> %s : %.4f mm^3\n"
                              (iname (plist-get h :a))
                              (iname (plist-get h :b))
                              (plist-get h :volume)))))
          (goto-char (point-min))
          (special-mode))))
    (pop-to-buffer buf)))

;;;; Assembly info ----------------------------------------------------

;;;###autoload
(defun cmacs-cad-assembly-show-info ()
  "Echo the solved state, DOF, and instance count of the assembly."
  (interactive)
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (info (cmacs-cad-assembly-info path name)))
    (message "Assembly %s: %s, %d DOF, %d instances"
             name (plist-get info :state) (plist-get info :dof)
             (length (plist-get info :instances)))))

;;;; Joints -----------------------------------------------------------

(defun cmacs-cad-assembly--pick-joint (path name)
  "Pick a joint of assembly NAME in PATH; return its plist."
  (let ((joints (cmacs-cad-assembly-joints path name)))
    (when (null joints)
      (user-error "Assembly %s has no joints" name))
    (if (= (length joints) 1)
        (car joints)
      (let* ((labels (mapcar (lambda (j)
                               (format "#%d %s" (plist-get j :id)
                                       (plist-get j :kind)))
                             joints))
             (choice (completing-read "Joint: " labels nil t)))
        (nth (cl-position choice labels :test #'string=) joints)))))

;;;###autoload
(defun cmacs-cad-drive-joint (value)
  "Drive a joint of this assembly to VALUE and re-pose (no source re-eval)."
  (interactive (list (read-number "Joint value: " 0.0)))
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (joint (cmacs-cad-assembly--pick-joint path name))
         (id (plist-get joint :id)))
    (cmacs-cad-assembly-set-joint path name id value)
    (message "Joint #%d -> %s" id value)))

(defvar cmacs-cad-assembly-animate-steps 30
  "Number of frames in `cmacs-cad-assembly-animate-joint'.")

;;;###autoload
(defun cmacs-cad-assembly-animate-joint (from to &optional seconds)
  "Animate a joint of this assembly FROM a value TO another over SECONDS.
Re-solves at each step (driving the live assembly); a workbench paired
with this buffer re-poses as it goes."
  (interactive (list (read-number "From: " 0.0)
                     (read-number "To: " 90.0)
                     (read-number "Seconds: " 1.5)))
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (joint (cmacs-cad-assembly--pick-joint path name))
         (id (plist-get joint :id))
         (steps (max 1 cmacs-cad-assembly-animate-steps))
         (dt (/ (or seconds 1.5) steps))
         (i 0))
    (cl-labels
        ((tick ()
           (let ((v (+ from (* (- to from) (/ (float i) steps)))))
             (ignore-errors (cmacs-cad-assembly-set-joint path name id v))
             (when (fboundp 'cmacs-cad-assembly--repose-workbench)
               (cmacs-cad-assembly--repose-workbench path name))
             (setq i (1+ i))
             (when (<= i steps)
               (run-with-timer dt nil #'tick)))))
      (tick))))

;;;; Workbench (3-D) --------------------------------------------------

(defun cmacs-cad-assembly--euler-from-matrix (m)
  "Extract ZYX Euler angles (radians) from column-major 3x4 vector M.
Returns (RX RY RZ)."
  ;; m[0..2]=col0, m[3..5]=col1, m[6..8]=col2 (rotation), m[9..11]=t.
  (let* ((r00 (aref m 0)) (r10 (aref m 1)) (r20 (aref m 2))
         (r21 (aref m 5)) (r22 (aref m 8))
         (sy (sqrt (+ (* r00 r00) (* r10 r10))))
         rx ry rz)
    (if (> sy 1e-6)
        (setq rx (atan r21 r22)
              ry (atan (- r20) sy)
              rz (atan r10 r00))
      (setq rx (atan (- (aref m 7)) (aref m 4))
            ry (atan (- r20) sy)
            rz 0.0))
    (list rx ry rz)))

(defvar-local cmacs-cad-assembly--workbench nil)
(defvar-local cmacs-cad-assembly--nodes nil
  "Alist of (INSTANCE-ID . NODE-ID) for the open assembly workbench.")

(defun cmacs-cad-assembly--place (editor id m)
  "Position NODE id ID in EDITOR from column-major 3x4 transform vector M."
  (cmacs-libregnum-editor-set-position editor id
                                       (aref m 9) (aref m 10) (aref m 11))
  (pcase-let ((`(,rx ,ry ,rz) (cmacs-cad-assembly--euler-from-matrix m)))
    (cmacs-libregnum-editor-set-rotation editor id rx ry rz)))

(defun cmacs-cad-assembly--repose-workbench (path name)
  "Re-read solved instance transforms and re-pose the workbench nodes."
  (when (and (buffer-live-p cmacs-cad-assembly--workbench)
             cmacs-cad-assembly--nodes)
    (let ((info (cmacs-cad-assembly-info path name))
          (editor cmacs-cad-assembly--workbench))
      (dolist (inst (plist-get info :instances))
        (let ((node (cdr (assq (nth 0 inst) cmacs-cad-assembly--nodes))))
          (when node
            (cmacs-cad-assembly--place editor node (nth 2 inst)))))
      (ignore-errors (cmacs-libregnum-editor-refresh editor)))))

;;;###autoload
(defun cmacs-cad-assembly-workbench ()
  "Open the assembly in this part buffer in the libregnum 3-D workbench.
Each instance becomes a CAD_PART node placed at its solved transform;
drive a joint (\\[cmacs-cad-drive-joint]) or animate one to watch the
mechanism move."
  (interactive)
  (unless (and (fboundp 'cmacs-libregnum-editor)
               (fboundp 'cmacs-libregnum-editor-add-visual))
    (user-error "The assembly workbench needs --with-cmacs-libregnum"))
  (let* ((path (cmacs-cad-assembly--path))
         (name (cmacs-cad-assembly--pick path))
         (info (cmacs-cad-assembly-info path name))
         (part-buffer (current-buffer))
         (editor (save-window-excursion (cmacs-libregnum-editor)))
         (nodes nil))
    (with-current-buffer editor
      (dolist (inst (plist-get info :instances))
        (let ((id (cmacs-libregnum-editor-add-visual
                   (current-buffer) 9 path (nth 1 inst))))
          (when id
            ;; Render this instance's part (cad:part selects by name).
            (ignore-errors
              (cmacs-libregnum-editor-set-visual-param
               (current-buffer) id "cad:instance" (float (nth 0 inst))))
            (cmacs-cad-assembly--place (current-buffer) id (nth 2 inst))
            (push (cons (nth 0 inst) id) nodes))))
      (when (fboundp 'cmacs-cad-apply-view-style)
        (cmacs-cad-apply-view-style (current-buffer))))
    (with-current-buffer part-buffer
      (setq cmacs-cad-assembly--workbench editor
            cmacs-cad-assembly--nodes (nreverse nodes)))
    (delete-other-windows)
    (set-window-buffer (selected-window) part-buffer)
    (select-window (split-window-right))
    (switch-to-buffer editor)
    (select-window (get-buffer-window part-buffer))
    (message "Assembly %s: %d instances placed" name (length nodes))))

;;;; Keymap -----------------------------------------------------------

;;;###autoload
(defun cmacs-cad-assembly-install-keys (map)
  "Bind the C-c C-a assembly commands into MAP."
  (define-key map (kbd "C-c C-a b") #'cmacs-cad-show-bom)
  (define-key map (kbd "C-c C-a i") #'cmacs-cad-check-interference)
  (define-key map (kbd "C-c C-a s") #'cmacs-cad-assembly-show-info)
  (define-key map (kbd "C-c C-a j") #'cmacs-cad-drive-joint)
  (define-key map (kbd "C-c C-a J") #'cmacs-cad-assembly-animate-joint)
  (define-key map (kbd "C-c C-a a") #'cmacs-cad-assembly-workbench))

(provide 'cmacs-cad-assembly)
;;; cmacs-cad-assembly.el ends here
