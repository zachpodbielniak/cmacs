;;; cmacs-cad.el --- Parametric CAD part editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Editing support for parametric CAD part source:
;;
;;   .cad  -- the s-expression DSL (this file's `cmacs-cad-mode')
;;   .ccad -- crispy, C-like (see cmacs-cad-crispy.el)
;;
;; Both languages evaluate through the same cad-glib document model
;; (`cmacs-cad-eval-async' and friends, C DEFUNs).  This file owns the
;; language-agnostic eval loop: C-c C-c (or save) re-evaluates the
;; part with a debounced, single-flight async request; failures land
;; in flymake with the source span the evaluator reported.
;;
;; The 3D workbench (libregnum editor CAD toolset) layers on top in
;; cmacs-cad-editor.el.

;;; Code:

(require 'cl-lib)
(require 'flymake)

(declare-function cmacs-cad-supported-p "cmacs-cad-defuns.c")
(declare-function cmacs-cad-version "cmacs-cad-defuns.c")
(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-doc-close "cmacs-cad-defuns.c")
(declare-function cmacs-cad-set-source "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval-async "cmacs-cad-defuns.c")
(declare-function cmacs-cad-params "cmacs-cad-defuns.c")
(declare-function cmacs-cad-part-names "cmacs-cad-defuns.c")
(declare-function cmacs-cad-feature-tree "cmacs-cad-defuns.c")
(declare-function cmacs-cad-inspect "cmacs-cad-defuns.c")
(declare-function cmacs-cad-export "cmacs-cad-defuns.c")
(declare-function cmacs-cad-section "cmacs-cad-defuns.c")
(autoload 'cmacs-cad-sketch "cmacs-cad-sketch" nil t)
(autoload 'cmacs-cad-workbench "cmacs-cad-editor" nil t)
(declare-function cmacs-cad-dsl-symbols "cmacs-cad-defuns.c")

(defgroup cmacs-cad nil
  "Parametric CAD subsystem for cmacs."
  :group 'cmacs
  :prefix "cmacs-cad-")

(defcustom cmacs-cad-eval-on-save t
  "When non-nil, saving a part buffer re-evaluates it."
  :type 'boolean
  :group 'cmacs-cad)

(defcustom cmacs-cad-view-edges nil
  "Overlay edges on shaded CAD models (shaded-with-edges).
Off by default: the overlay draws every tessellation edge, which is crisp
for low-poly prismatic parts but busy on dense/curved meshes (proper
feature-edge extraction is future work).  Toggle per view with
`cmacs-cad-toggle-edges'."
  :type 'boolean
  :group 'cmacs-cad)

(declare-function cmacs-libregnum-editor-set-shading "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-headlight "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-edges "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-active-p "cmacs-libregnum")
(declare-function cmacs-libregnum-redraw "cmacs-libregnum-defuns.c")

(defvar-local cmacs-cad--view-edges-on nil
  "Buffer-local edge-overlay state for a libregnum CAD viewer buffer.")

(defun cmacs-cad-apply-view-style (editor)
  "Apply readable CAD display defaults to libregnum EDITOR.
Enables lit shading with a camera-anchored key+fill rig (so a model-only
scene shades by orientation instead of a flat, washed-out silhouette) and
the edge overlay per `cmacs-cad-view-edges'.  Safe + idempotent; call
after the part/model node is baked."
  (when (buffer-live-p editor)
    (when (fboundp 'cmacs-libregnum-editor-set-shading)
      (ignore-errors (cmacs-libregnum-editor-set-shading editor t)))
    (when (fboundp 'cmacs-libregnum-editor-set-headlight)
      (ignore-errors (cmacs-libregnum-editor-set-headlight editor t)))
    (when (fboundp 'cmacs-libregnum-editor-set-edges)
      (ignore-errors
        (cmacs-libregnum-editor-set-edges editor cmacs-cad-view-edges)))
    (with-current-buffer editor
      (setq cmacs-cad--view-edges-on cmacs-cad-view-edges))))

(defun cmacs-cad--viewer-buffer ()
  "Return the libregnum editor buffer for the current CAD context, or nil.
Works from a libregnum editor itself or from a paired source/model/gcode
buffer."
  (cond
   ((and (fboundp 'cmacs-libregnum-editor-active-p)
         (ignore-errors (cmacs-libregnum-editor-active-p (current-buffer))))
    (current-buffer))
   ((and (boundp 'cmacs-cad-editor--workbench)
         (buffer-live-p cmacs-cad-editor--workbench))
    cmacs-cad-editor--workbench)
   ((and (boundp 'cmacs-cad-model--viewer)
         (buffer-live-p cmacs-cad-model--viewer))
    cmacs-cad-model--viewer)
   ((and (boundp 'cmacs-cad-gcode--viewer)
         (buffer-live-p cmacs-cad-gcode--viewer))
    cmacs-cad-gcode--viewer)))

(defun cmacs-cad-toggle-edges ()
  "Toggle the shaded-with-edges overlay on the current CAD viewport."
  (interactive)
  (let ((editor (cmacs-cad--viewer-buffer)))
    (unless editor (user-error "No CAD viewport here"))
    (unless (fboundp 'cmacs-libregnum-editor-set-edges)
      (user-error "Edge overlay needs --with-cmacs-libregnum"))
    (let ((on (not (buffer-local-value 'cmacs-cad--view-edges-on editor))))
      (cmacs-libregnum-editor-set-edges editor on)
      (with-current-buffer editor (setq cmacs-cad--view-edges-on on))
      (when (fboundp 'cmacs-libregnum-redraw)
        (ignore-errors (cmacs-libregnum-redraw editor)))
      (message "CAD edges: %s" (if on "on" "off")))))

(defcustom cmacs-cad-auto-workbench t
  "When non-nil, visiting a part file opens the libregnum workbench
automatically (source buffer beside a live 3-D viewport), provided a
graphical display and the libregnum editor are available.  Set to nil to
keep the bare text mode and open the workbench on demand with \\[cmacs-cad-workbench]."
  :type 'boolean
  :group 'cmacs-cad)

(defcustom cmacs-cad-eval-debounce 0.15
  "Idle seconds before a buffer-driven re-evaluation fires."
  :type 'number
  :group 'cmacs-cad)

(defcustom cmacs-cad-default-export-format 'stl
  "Default export format for `cmacs-cad-export-part'."
  :type '(choice (const stl) (const stl-ascii) (const obj)
                 (const step) (const iges))
  :group 'cmacs-cad)

(defun cmacs-cad-available-p ()
  "Return non-nil when the CAD subsystem is built in."
  (and (fboundp 'cmacs-cad-supported-p)
       (cmacs-cad-supported-p)))

;;; Vocabulary (drives font-lock, capf and eldoc in both modes)

(defconst cmacs-cad--static-vocabulary
  '(("defparam") ("defpart") ("defsketch")
    ("box") ("cylinder") ("sphere") ("cone") ("torus")
    ("union") ("difference") ("intersection") ("hull")
    ("translate") ("rotate") ("scale") ("mirror")
    ("linear-pattern") ("circular-pattern")
    ("extrude") ("revolve")
    ("fillet") ("chamfer") ("shell") ("offset")
    ("pt") ("line") ("arc") ("circle") ("constrain"))
  "Fallback vocabulary (names only) for builds without the subsystem.")

(defvar cmacs-cad--vocab-cache (make-hash-table :test #'equal)
  "LANGUAGE -> list of (NAME SIGNATURE DOC).")

(defun cmacs-cad-vocabulary (&optional language)
  "Return the modeling vocabulary for LANGUAGE (default \"sexp\")."
  (let ((language (or language "sexp")))
    (or (gethash language cmacs-cad--vocab-cache)
        (puthash language
                 (if (cmacs-cad-available-p)
                     (cmacs-cad-dsl-symbols language)
                   cmacs-cad--static-vocabulary)
                 cmacs-cad--vocab-cache))))

;;; Shared eval loop (language-agnostic)

(defvar-local cmacs-cad--eval-timer nil)
(defvar-local cmacs-cad--generation 0)
(defvar-local cmacs-cad--flymake-report nil)
(defvar-local cmacs-cad--last-error nil
  "The last evaluation failure message for this part buffer, or nil.")

(defvar cmacs-cad-after-eval-hook nil
  "Run in the part buffer after a successful evaluation.
The workbench hooks viewport refreshes here.")

(defun cmacs-cad--buffer-path ()
  "This buffer's part file path, or signal."
  (or (buffer-file-name)
      (user-error "This part buffer is not visiting a file")))

(defun cmacs-cad--on-eval-done (buffer generation result)
  "Handle async eval RESULT for BUFFER at GENERATION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation cmacs-cad--generation)
        (let ((err (plist-get result :error)))
          (setq cmacs-cad--last-error err)
          (cmacs-cad--flymake-publish err)
          (if err
              (message "CAD: %s" err)
            (message "CAD: %s ok"
                     (file-name-nondirectory (or (buffer-file-name) "part")))
            (run-hooks 'cmacs-cad-after-eval-hook)))))))

(defun cmacs-cad-eval-buffer ()
  "Evaluate this part buffer (its current, possibly unsaved, text)."
  (interactive)
  (unless (cmacs-cad-available-p)
    (user-error "The CAD subsystem is not built in (--with-cmacs-cad)"))
  (let ((path (cmacs-cad--buffer-path))
        (buffer (current-buffer)))
    (cmacs-cad-set-source path (buffer-substring-no-properties
                                (point-min) (point-max)))
    (cl-incf cmacs-cad--generation)
    (let ((generation cmacs-cad--generation))
      (cmacs-cad-eval-async
       path
       (lambda (result)
         (cmacs-cad--on-eval-done buffer generation result))))))

(defun cmacs-cad--schedule-eval ()
  "Debounce a buffer re-evaluation."
  (when cmacs-cad--eval-timer
    (cancel-timer cmacs-cad--eval-timer))
  (setq cmacs-cad--eval-timer
        (run-with-idle-timer cmacs-cad-eval-debounce nil
                             (lambda (buffer)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq cmacs-cad--eval-timer nil)
                                   (cmacs-cad-eval-buffer))))
                             (current-buffer))))

(defun cmacs-cad--after-save ()
  (when (and cmacs-cad-eval-on-save (cmacs-cad-available-p))
    (cmacs-cad--schedule-eval)))

;;; Flymake backend (push style: reports on eval completion)

(defun cmacs-cad--flymake-backend (report-fn &rest _)
  "Flymake backend; stores REPORT-FN and reports the last result."
  (setq cmacs-cad--flymake-report report-fn)
  (cmacs-cad--flymake-publish cmacs-cad--last-error))

(defun cmacs-cad--flymake-publish (err)
  "Publish ERR (a message string or nil) to flymake."
  (when cmacs-cad--flymake-report
    (funcall
     cmacs-cad--flymake-report
     (if (null err)
         nil
       (list (cmacs-cad--flymake-diagnostic err))))))

(defun cmacs-cad--flymake-diagnostic (err)
  "Build a flymake diagnostic from ERR, using its span when present.
The evaluator embeds \"at line L column C\" in span-capable
languages; fall back to the first line otherwise."
  (let ((line 1) (col 0))
    (when (string-match "at line \\([0-9]+\\) column \\([0-9]+\\)" err)
      (setq line (string-to-number (match-string 1 err))
            col (string-to-number (match-string 2 err))))
    (let* ((region (flymake-diag-region (current-buffer) line
                                        (when (> col 0) col)))
           (beg (car region))
           (end (cdr region)))
      (flymake-make-diagnostic (current-buffer) beg end :error err))))

;;; Completion / eldoc (shared by both language modes)

(defvar-local cmacs-cad--language "sexp")

(defun cmacs-cad--capf ()
  "Complete modeling vocabulary names."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (mapcar #'car (cmacs-cad-vocabulary cmacs-cad--language))
            :annotation-function
            (lambda (name)
              (when-let* ((entry (assoc name (cmacs-cad-vocabulary
                                              cmacs-cad--language)))
                          (sig (cadr entry)))
                (concat " " sig)))))))

(defun cmacs-cad--eldoc (callback &rest _)
  "Eldoc for the head symbol of the enclosing form."
  (when-let* ((head (cmacs-cad--enclosing-head))
              (entry (assoc head (cmacs-cad-vocabulary
                                  cmacs-cad--language))))
    (funcall callback (or (cadr entry) (car entry))
             :thing head :face 'font-lock-function-name-face)))

(defun cmacs-cad--enclosing-head ()
  "Name of the innermost enclosing form's head symbol, or nil."
  (save-excursion
    (condition-case nil
        (progn
          (up-list -1 t t)
          (forward-char 1)
          (thing-at-point 'symbol t))
      (error nil))))

;;; The .cad (s-expression) major mode

(defconst cmacs-cad--definer-names '("defparam" "defpart" "defsketch"))
(defconst cmacs-cad--primitive-names
  '("box" "cylinder" "sphere" "cone" "torus"))
(defconst cmacs-cad--op-names
  '("union" "difference" "intersection" "hull"
    "translate" "rotate" "scale" "mirror"
    "linear-pattern" "circular-pattern"
    "extrude" "revolve" "fillet" "chamfer" "shell" "offset"))
(defconst cmacs-cad--sketch-names
  '("pt" "line" "arc" "circle" "constrain"))

(defconst cmacs-cad-font-lock-keywords
  `((,(concat "(" (regexp-opt cmacs-cad--definer-names t)
              "\\_>[ \t]*\\(\\(?:\\sw\\|\\s_\\)+\\)?")
     (1 font-lock-keyword-face)
     (2 font-lock-function-name-face nil t))
    (,(concat "(" (regexp-opt cmacs-cad--op-names t) "\\_>")
     (1 font-lock-builtin-face))
    (,(concat "(" (regexp-opt cmacs-cad--primitive-names t) "\\_>")
     (1 font-lock-type-face))
    (,(concat "(" (regexp-opt cmacs-cad--sketch-names t) "\\_>")
     (1 font-lock-preprocessor-face))))

(defvar cmacs-cad-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-cad-eval-buffer)
    (define-key map (kbd "C-c C-p") #'cmacs-cad-show-params)
    (define-key map (kbd "C-c C-i") #'cmacs-cad-show-inspect)
    (define-key map (kbd "C-c C-M-i") #'cmacs-cad-show-mass-properties)
    (define-key map (kbd "C-c C-e") #'cmacs-cad-export-part)
    (define-key map (kbd "C-c C-m") #'cmacs-cad-measure)
    (define-key map (kbd "C-c C-s") #'cmacs-cad-section-at)
    (define-key map (kbd "C-c C-k") #'cmacs-cad-sketch)
    (define-key map (kbd "C-c C-v") #'cmacs-cad-workbench)
    (define-key map (kbd "C-c C-d") #'cmacs-cad-toggle-edges)
    ;; Assembly commands (C-c C-a family); autoloaded from
    ;; cmacs-cad-assembly to avoid a load-time require cycle.
    (define-key map (kbd "C-c C-a b") #'cmacs-cad-show-bom)
    (define-key map (kbd "C-c C-a i") #'cmacs-cad-check-interference)
    (define-key map (kbd "C-c C-a s") #'cmacs-cad-assembly-show-info)
    (define-key map (kbd "C-c C-a j") #'cmacs-cad-drive-joint)
    (define-key map (kbd "C-c C-a J") #'cmacs-cad-assembly-animate-joint)
    (define-key map (kbd "C-c C-a a") #'cmacs-cad-assembly-workbench)
    map)
  "Keymap for `cmacs-cad-mode'.")

;;;###autoload
(define-derived-mode cmacs-cad-mode lisp-data-mode "CAD"
  "Major mode for .cad parametric part source (s-expression DSL).

\\{cmacs-cad-mode-map}"
  (setq cmacs-cad--language "sexp")
  (setq-local font-lock-defaults
              (list (append cmacs-cad-font-lock-keywords
                            (cadr font-lock-defaults))))
  (setq-local imenu-generic-expression
              `(("Parts" "^(defpart[ \t]+\\(\\(?:\\sw\\|\\s_\\)+\\)" 1)
                ("Params" "^(defparam[ \t]+\\(\\(?:\\sw\\|\\s_\\)+\\)" 1)
                ("Sketches" "^(defsketch[ \t]+\\(\\(?:\\sw\\|\\s_\\)+\\)" 1)))
  (add-hook 'completion-at-point-functions #'cmacs-cad--capf nil t)
  (add-hook 'eldoc-documentation-functions #'cmacs-cad--eldoc nil t)
  (add-hook 'after-save-hook #'cmacs-cad--after-save nil t)
  (when (cmacs-cad-available-p)
    (add-hook 'flymake-diagnostic-functions
              #'cmacs-cad--flymake-backend nil t)
    (flymake-mode 1))
  (cmacs-cad--maybe-auto-workbench))

(declare-function cmacs-cad-workbench "cmacs-cad-editor")
(declare-function cmacs-libregnum-supported-p "cmacs-libregnum")

(defun cmacs-cad--maybe-auto-workbench ()
  "Open the libregnum workbench for this part when configured + possible.
Deferred so visiting the file finishes first; the libregnum render is the
primary way to view a part (the text buffer is just the source)."
  (when (and cmacs-cad-auto-workbench
             (buffer-file-name)
             (display-graphic-p)
             (not noninteractive)
             (cmacs-cad-available-p)
             (fboundp 'cmacs-libregnum-supported-p)
             (ignore-errors (cmacs-libregnum-supported-p)))
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       0.3 nil
       (lambda ()
         (when (and (buffer-live-p buf)
                    ;; Don't re-open if a workbench is already paired.
                    (not (and (boundp 'cmacs-cad-editor--workbench)
                              (buffer-local-value
                               'cmacs-cad-editor--workbench buf)
                              (buffer-live-p
                               (buffer-local-value
                                'cmacs-cad-editor--workbench buf)))))
           (with-current-buffer buf
             (ignore-errors (cmacs-cad-workbench)))))))))

;; defpart/defsketch indent like defun; defparam like a one-liner.
(put 'defpart 'lisp-indent-function 1)
(put 'defsketch 'lisp-indent-function 1)

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.cad\\'" . cmacs-cad-mode))

;;; Simple inspection commands (the workbench supersedes these)

(defun cmacs-cad-show-params ()
  "Show this part's parameters in the echo area."
  (interactive)
  (let ((params (cmacs-cad-params (cmacs-cad--buffer-path))))
    (if (null params)
        (message "No parameters (evaluate the part first?)")
      (message "%s"
               (mapconcat
                (lambda (p)
                  (format "%s=%g" (plist-get p :name)
                          (plist-get p :value)))
                params "  ")))))

(defun cmacs-cad-show-inspect ()
  "Show this part's mass properties in the echo area."
  (interactive)
  (let ((info (cmacs-cad-inspect (cmacs-cad--buffer-path))))
    (message "volume %.3f  area %.3f  triangles %s  watertight %s"
             (plist-get info :volume)
             (plist-get info :area)
             (plist-get info :triangles)
             (if (plist-get info :watertight) "yes" "NO"))))

(defun cmacs-cad-show-mass-properties ()
  "Show this part's full mass properties in a help buffer."
  (interactive)
  (let* ((info (cmacs-cad-inspect (cmacs-cad--buffer-path)))
         (bbox (plist-get info :bbox))
         (com (plist-get info :center-of-mass)))
    (with-help-window "*cmacs-cad mass properties*"
      (princ (format "Mass properties for %s\n\n"
                     (file-name-nondirectory (cmacs-cad--buffer-path))))
      (princ (format "  Volume       %.4f\n" (plist-get info :volume)))
      (princ (format "  Surface area %.4f\n" (plist-get info :area)))
      (princ (format "  Triangles    %s\n" (plist-get info :triangles)))
      (princ (format "  Watertight   %s\n"
                     (if (plist-get info :watertight) "yes" "NO")))
      (when com
        (princ (format "  Center of mass  (%.3f %.3f %.3f)\n"
                       (nth 0 com) (nth 1 com) (nth 2 com))))
      (when bbox
        (princ (format "  Bounding box    min (%.3f %.3f %.3f)\n\
                  max (%.3f %.3f %.3f)\n"
                       (nth 0 bbox) (nth 1 bbox) (nth 2 bbox)
                       (nth 3 bbox) (nth 4 bbox) (nth 5 bbox)))
        (princ (format "  Dimensions      %.3f x %.3f x %.3f\n"
                       (- (nth 3 bbox) (nth 0 bbox))
                       (- (nth 4 bbox) (nth 1 bbox))
                       (- (nth 5 bbox) (nth 2 bbox))))))))

(defun cmacs-cad--read-point (prompt)
  "Read a 3D point \"X Y Z\" for PROMPT; return (X Y Z) floats."
  (let ((s (read-string (concat prompt " (X Y Z): "))))
    (mapcar #'string-to-number
            (split-string (string-trim s) "[ ,]+" t))))

(defun cmacs-cad-measure (a b)
  "Measure the distance between two points A and B (each \"X Y Z\").
Reports Euclidean distance and per-axis deltas."
  (interactive (list (cmacs-cad--read-point "From point")
                     (cmacs-cad--read-point "To point")))
  (unless (and (= 3 (length a)) (= 3 (length b)))
    (user-error "Each point needs three coordinates"))
  (let* ((dx (- (nth 0 b) (nth 0 a)))
         (dy (- (nth 1 b) (nth 1 a)))
         (dz (- (nth 2 b) (nth 2 a)))
         (d (sqrt (+ (* dx dx) (* dy dy) (* dz dz)))))
    (message "distance %.4f   Δ (%.3f %.3f %.3f)" d dx dy dz)
    d))

(defun cmacs-cad-section-at (axis offset)
  "Section this part by an AXIS-perpendicular plane at OFFSET.
AXIS is `x', `y' or `z'.  Reports the section's segment count and total
perimeter, and returns the segment list."
  (interactive
   (list (intern (completing-read "Plane axis: " '("x" "y" "z") nil t
                                  nil nil "z"))
         (read-number "Offset along axis: " 0.0)))
  (let* ((p (cmacs-cad--buffer-path))
         (pt (pcase axis ('x (list offset 0 0))
                   ('y (list 0 offset 0))
                   (_  (list 0 0 offset))))
         (nrm (pcase axis ('x '(1 0 0)) ('y '(0 1 0)) (_ '(0 0 1))))
         (segs (apply #'cmacs-cad-section p (append pt nrm)))
         (perim (apply #'+
                       (mapcar
                        (lambda (s)
                          (let ((dx (- (nth 3 s) (nth 0 s)))
                                (dy (- (nth 4 s) (nth 1 s)))
                                (dz (- (nth 5 s) (nth 2 s))))
                            (sqrt (+ (* dx dx) (* dy dy) (* dz dz)))))
                        segs))))
    (if (null segs)
        (message "Section plane %s=%g misses the part" axis offset)
      (message "Section %s=%g: %d segments, perimeter %.3f"
               axis offset (length segs) perim))
    segs))

(defun cmacs-cad-export-part (out-path format)
  "Export this part to OUT-PATH in FORMAT."
  (interactive
   (let* ((format (intern (completing-read
                           "Format: " '("stl" "stl-ascii" "obj"
                                        "step" "iges")
                           nil t nil nil
                           (symbol-name cmacs-cad-default-export-format))))
          (default (concat (file-name-sans-extension
                            (or (buffer-file-name) "part"))
                           "." (if (eq format 'stl-ascii) "stl"
                                 (symbol-name format)))))
     (list (read-file-name "Export to: " nil nil nil
                           (file-name-nondirectory default))
           format)))
  (cmacs-cad-export (cmacs-cad--buffer-path)
                    (expand-file-name out-path) format)
  (message "Exported %s" out-path))

(provide 'cmacs-cad)
;;; cmacs-cad.el ends here
