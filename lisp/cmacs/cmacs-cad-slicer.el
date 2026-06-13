;;; cmacs-cad-slicer.el --- Slice CAD parts to G-code -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Drives an external slicer (PrusaSlicer by default, native binary or the
;; `com.prusa3d.PrusaSlicer' flatpak) to turn an exported STL into G-code.
;;
;; Strategy: instead of a fragile flag soup, we MERGE a small overrides
;; ini (only the common parameters the user set) on top of their base
;; profile -- `prusa-slicer --load base.ini --load overrides.ini' applies
;; loads in order, last wins.  Slicing runs async (make-process +
;; sentinel) with a live job buffer; time/filament estimates are parsed
;; from the produced G-code footer (stable across versions).
;;
;; Staging lives under $HOME so the flatpak (filesystems=home) can read
;; the input and write the output; a backend whose staging escapes $HOME
;; is rejected.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-cad-slicer nil
  "Slice CAD parts into printable G-code."
  :group 'cmacs-cad
  :prefix "cmacs-cad-slicer-")

;;; Backends

(cl-defstruct (cmacs-cad-slicer-backend
               (:constructor cmacs-cad-slicer-backend-create))
  name           ; symbol
  resolve        ; () -> (PROGRAM . BASE-ARGS) or nil if unavailable
  param-map)     ; alist of (common-key . ini-key)

(defvar cmacs-cad-slicer-backends nil
  "Registry of `cmacs-cad-slicer-backend' structs by name.")

(defun cmacs-cad-slicer-register (backend)
  "Register slicer BACKEND, replacing any with the same name."
  (setq cmacs-cad-slicer-backends
        (cons backend
              (cl-remove (cmacs-cad-slicer-backend-name backend)
                         cmacs-cad-slicer-backends
                         :key #'cmacs-cad-slicer-backend-name)))
  backend)

(defun cmacs-cad-slicer--backend (name)
  "Return the registered backend NAME, or signal."
  (or (cl-find name cmacs-cad-slicer-backends
               :key #'cmacs-cad-slicer-backend-name)
      (user-error "No slicer backend `%s'" name)))

;;; Customization

(defcustom cmacs-cad-slicer-backend 'prusa
  "The slicer backend to use (a key in `cmacs-cad-slicer-backends')."
  :type 'symbol)

(defcustom cmacs-cad-slicer-base-profile nil
  "Path to a slicer base profile ini, or nil to rely on slicer defaults."
  :type '(choice (const nil) file))

(defcustom cmacs-cad-slicer-layer-height 0.2
  "Layer height in millimetres."
  :type 'number)

(defcustom cmacs-cad-slicer-infill 15
  "Infill density as a percentage (0-100)."
  :type 'integer)

(defcustom cmacs-cad-slicer-perimeters 3
  "Number of perimeter (wall) loops."
  :type 'integer)

(defcustom cmacs-cad-slicer-first-layer-height 0.2
  "First-layer height in millimetres (thicker often improves bed adhesion)."
  :type 'number)

(defcustom cmacs-cad-slicer-supports nil
  "Whether to generate support material."
  :type 'boolean)

(defcustom cmacs-cad-slicer-support-style 'grid
  "Support material style.
`organic' is PrusaSlicer's tree-style support (2.7+); `grid' and `snug'
are the classic styles.  Only takes effect when supports are enabled."
  :type '(choice (const :tag "Grid (classic)" grid)
                 (const :tag "Snug" snug)
                 (const :tag "Organic / tree (PrusaSlicer 2.7+)" organic)))

(defcustom cmacs-cad-slicer-support-threshold 0
  "Overhang angle (degrees from horizontal) above which supports are
generated; 0 lets the slicer decide automatically."
  :type 'integer)

(defcustom cmacs-cad-slicer-brim-width 0
  "Brim width in millimetres (0 disables the brim)."
  :type 'number)

(defcustom cmacs-cad-slicer-staging-dir
  (expand-file-name "cmacs/cad/slice/" (or (getenv "XDG_CACHE_HOME")
                                           "~/.cache"))
  "Directory for slicer input/output staging.  MUST be under $HOME for
flatpak backends (which can only see the home filesystem)."
  :type 'directory)

(defcustom cmacs-cad-slicer-prusa-flatpak-id "com.prusa3d.PrusaSlicer"
  "Flatpak application id for PrusaSlicer (fallback when no native binary)."
  :type 'string)

(defcustom cmacs-cad-slicer-prusa-program nil
  "Override for how PrusaSlicer is invoked.
nil auto-detects (native binary, then the flatpak in the system and the
per-user installations, first one found).  A string runs that program
directly.  A list is a full base command, e.g.
\(\"flatpak\" \"run\" \"--command=prusa-slicer\" \"com.prusa3d.PrusaSlicer\")."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Program / path")
                 (repeat :tag "Command + base args" string)))

;;; PrusaSlicer backend

(defun cmacs-cad-slicer--flatpak-has-p (id &optional user)
  "Return non-nil if flatpak application ID is installed.
With USER non-nil, probe the per-user installation (`flatpak --user')."
  (and (executable-find "flatpak")
       (ignore-errors
         (with-temp-buffer
           (eq 0 (apply #'call-process "flatpak" nil t nil
                        (append (when user '("--user")) (list "info" id))))))))

(defun cmacs-cad-slicer--prusa-resolve ()
  "Resolve PrusaSlicer to (PROGRAM . BASE-ARGS).
Order: `cmacs-cad-slicer-prusa-program' override, then a native binary, then
the flatpak in the system installation, then the per-user installation; the
first found wins.  (`flatpak run' itself resolves either install space, but
detection probes both.)"
  (cond
   ;; Explicit override.
   ((stringp cmacs-cad-slicer-prusa-program)
    (cons cmacs-cad-slicer-prusa-program nil))
   ((consp cmacs-cad-slicer-prusa-program)
    (cons (car cmacs-cad-slicer-prusa-program)
          (cdr cmacs-cad-slicer-prusa-program)))
   ;; Native binary.
   ((executable-find "prusa-slicer") (cons "prusa-slicer" nil))
   ((executable-find "PrusaSlicer")  (cons "PrusaSlicer" nil))
   ;; Flatpak: system installation.
   ((cmacs-cad-slicer--flatpak-has-p cmacs-cad-slicer-prusa-flatpak-id)
    (cons "flatpak" (list "run" "--command=prusa-slicer"
                          cmacs-cad-slicer-prusa-flatpak-id)))
   ;; Flatpak: per-user installation.
   ((cmacs-cad-slicer--flatpak-has-p cmacs-cad-slicer-prusa-flatpak-id t)
    (cons "flatpak" (list "run" "--user" "--command=prusa-slicer"
                          cmacs-cad-slicer-prusa-flatpak-id)))
   (t nil)))

(cmacs-cad-slicer-register
 (cmacs-cad-slicer-backend-create
  :name 'prusa
  :resolve #'cmacs-cad-slicer--prusa-resolve
  :param-map '((layer-height       . "layer_height")
               (first-layer-height . "first_layer_height")
               (infill             . "fill_density")
               (perimeters         . "perimeters")
               (supports           . "support_material")
               (support-style      . "support_material_style")
               (support-threshold  . "support_material_threshold")
               (brim-width         . "brim_width"))))

;;; ini merge

(defun cmacs-cad-slicer--common-params ()
  "Return an alist of (common-key . VALUE) from the defcustoms."
  (append
   (list (cons 'layer-height cmacs-cad-slicer-layer-height)
         (cons 'first-layer-height cmacs-cad-slicer-first-layer-height)
         (cons 'infill (format "%d%%" cmacs-cad-slicer-infill))
         (cons 'perimeters cmacs-cad-slicer-perimeters)
         (cons 'supports (if cmacs-cad-slicer-supports 1 0))
         (cons 'brim-width cmacs-cad-slicer-brim-width))
   ;; Support style + overhang threshold only matter when supports are on;
   ;; emit them anyway (harmless when support_material = 0) so toggling
   ;; supports per-slice via EXTRA needs no extra plumbing.
   (list (cons 'support-style
               (symbol-name cmacs-cad-slicer-support-style))
         (cons 'support-threshold cmacs-cad-slicer-support-threshold))))

(defun cmacs-cad-slicer--write-overrides-ini (backend path &optional extra)
  "Write the common-param overrides for BACKEND to PATH.
EXTRA is an alist of (common-key . value) merged over the defcustoms,
so a per-slice call can override any common parameter."
  (let ((map (cmacs-cad-slicer-backend-param-map backend))
        (params (append extra (cmacs-cad-slicer--common-params))))
    (with-temp-file path
      (dolist (entry map)
        (let* ((common (car entry))
               (ini-key (cdr entry))
               (cell (assq common params)))
          (when cell
            (insert (format "%s = %s\n" ini-key
                            ;; %% in infill is a fill_density idiom; numbers
                            ;; print bare.
                            (let ((v (cdr cell)))
                              (if (numberp v) (format "%s" v) v))))))))
    path))

;;; Pre-flight

(defun cmacs-cad-slicer--preflight (stl)
  "Signal a `user-error' if STL is obviously unprintable."
  (unless (file-readable-p stl)
    (user-error "Slice input not readable: %s" stl))
  (when (< (or (file-attribute-size (file-attributes stl)) 0) 100)
    (user-error "Slice input looks empty: %s" stl)))

(defun cmacs-cad-slicer--staging-ok-p (backend)
  "Return non-nil if the staging dir is valid for BACKEND.
Flatpak backends require staging under $HOME."
  (let* ((res (funcall (cmacs-cad-slicer-backend-resolve backend)))
         (prog (car res))
         (home (expand-file-name "~/"))
         (stage (file-name-as-directory
                 (expand-file-name cmacs-cad-slicer-staging-dir))))
    (or (not (equal prog "flatpak"))
        (string-prefix-p home stage))))

;;; Slice

(defun cmacs-cad-slicer-argv (backend overrides-ini stl out-gcode)
  "Build the argv to slice STL to OUT-GCODE with BACKEND.
Loads the base profile (if any) then OVERRIDES-INI (last wins)."
  (let* ((res (funcall (cmacs-cad-slicer-backend-resolve backend)))
         (prog (car res))
         (base (cdr res))
         (loads (append
                 (when cmacs-cad-slicer-base-profile
                   (list "--load" (expand-file-name
                                   cmacs-cad-slicer-base-profile)))
                 (list "--load" overrides-ini))))
    (unless res
      (user-error "Slicer backend `%s' is not available"
                  (cmacs-cad-slicer-backend-name backend)))
    (cons prog
          (append base
                  (list "--export-gcode")
                  loads
                  (list "--output" out-gcode stl)))))

(defun cmacs-cad-slice (stl &optional out-gcode extra callback)
  "Slice STL to G-code asynchronously; return the job buffer.
OUT-GCODE defaults to a sibling .gcode under the staging dir.  EXTRA is an
alist of per-slice common-param overrides.  CALLBACK, if given, is called
with (STATUS OUT-GCODE) where STATUS is `done' or `error' on completion."
  (interactive (list (read-file-name "STL to slice: " nil nil t)))
  (let* ((backend (cmacs-cad-slicer--backend cmacs-cad-slicer-backend))
         (stage (file-name-as-directory
                 (expand-file-name cmacs-cad-slicer-staging-dir)))
         (out (or out-gcode
                  (expand-file-name
                   (concat (file-name-base stl) ".gcode") stage)))
         (overrides-ini (expand-file-name
                         (concat (file-name-base stl) "-overrides.ini")
                         stage)))
    (cmacs-cad-slicer--preflight stl)
    (unless (cmacs-cad-slicer--staging-ok-p backend)
      (user-error "Staging dir %s is outside $HOME (flatpak cannot reach it)"
                  cmacs-cad-slicer-staging-dir))
    (make-directory stage t)
    (cmacs-cad-slicer--write-overrides-ini backend overrides-ini extra)
    (let* ((argv (cmacs-cad-slicer-argv backend overrides-ini stl out))
           (buf (get-buffer-create "*cmacs-cad slice*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t)) (erase-buffer))
        (insert (format "$ %s\n\n" (mapconcat #'identity argv " ")))
        (special-mode))
      (make-process
       :name "cmacs-cad-slice"
       :buffer buf
       :command argv
       :noquery t
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let ((ok (and (= 0 (process-exit-status proc))
                          (file-exists-p out))))
             (with-current-buffer buf
               (let ((inhibit-read-only t))
                 (goto-char (point-max))
                 (insert (format "\n%s -> %s\n"
                                 (if ok "Sliced" "FAILED") out))))
             (when callback (funcall callback (if ok 'done 'error) out))
             (message "Slice %s: %s" (if ok "done" "FAILED") out)))))
      (display-buffer buf)
      buf)))

;;; Estimate parsing (G-code footer)

(defun cmacs-cad-slicer-estimate (gcode)
  "Parse (TIME-SECONDS . FILAMENT-MM) from the G-code file GCODE footer.
Either field is nil when absent."
  (let ((time nil) (filament nil))
    (with-temp-buffer
      ;; Footer comments live at the very end; reading the tail is enough.
      (insert-file-contents gcode nil
                            (max 0 (- (or (file-attribute-size
                                           (file-attributes gcode)) 0)
                                      8192)))
      (goto-char (point-min))
      (when (re-search-forward "TIME:\\([0-9]+\\)" nil t)
        (setq time (string-to-number (match-string 1))))
      (goto-char (point-min))
      (cond
       ((re-search-forward "Filament used:\\s-*\\([0-9.]+\\)m" nil t)
        (setq filament (* 1000.0 (string-to-number (match-string 1)))))
       ((re-search-forward "filament used \\[mm\\] = \\([0-9.]+\\)" nil t)
        (setq filament (string-to-number (match-string 1))))))
    (cons time filament)))

;;; Slice the current part

(declare-function cmacs-cad-export "cmacs-cad-defuns.c")
(declare-function cmacs-cad--buffer-path "cmacs-cad")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")

(defun cmacs-cad-slice-part (&optional view)
  "Export the part in the current buffer to STL and slice it.
With VIEW non-nil (interactively, the prefix arg) open the produced
G-code in the toolpath viewer when slicing finishes."
  (interactive "P")
  (let* ((path (cmacs-cad--buffer-path))
         (stage (file-name-as-directory
                 (expand-file-name cmacs-cad-slicer-staging-dir)))
         (stl (expand-file-name (concat (file-name-base path) ".stl")
                                stage)))
    (make-directory stage t)
    (cmacs-cad-export path stl 'stl)
    (cmacs-cad-slice
     stl nil nil
     (lambda (status out)
       (when (and view (eq status 'done) (file-exists-p out))
         (find-file out))))))

;;; Interactive settings

;;;###autoload
(defun cmacs-cad-slicer-settings ()
  "Interactively set the common slicer parameters used by `cmacs-cad-slice'.
Prompts for layer height, first-layer height, infill, perimeters, supports
(with style, including organic/tree), and brim, storing them in the slicer
defcustoms.  Persist them with \\[customize-group] cmacs-cad if desired."
  (interactive)
  (setq cmacs-cad-slicer-layer-height
        (read-number "Layer height (mm): " cmacs-cad-slicer-layer-height))
  (setq cmacs-cad-slicer-first-layer-height
        (read-number "First-layer height (mm): "
                     cmacs-cad-slicer-first-layer-height))
  (setq cmacs-cad-slicer-infill
        (round (read-number "Infill (%): " cmacs-cad-slicer-infill)))
  (setq cmacs-cad-slicer-perimeters
        (round (read-number "Perimeters (walls): "
                            cmacs-cad-slicer-perimeters)))
  (setq cmacs-cad-slicer-supports (y-or-n-p "Generate supports? "))
  (when cmacs-cad-slicer-supports
    (setq cmacs-cad-slicer-support-style
          (intern (completing-read
                   "Support style: " '("grid" "snug" "organic") nil t nil nil
                   (symbol-name cmacs-cad-slicer-support-style)))))
  (setq cmacs-cad-slicer-brim-width
        (read-number "Brim width (mm, 0 = none): "
                     cmacs-cad-slicer-brim-width))
  (message
   "Slicer: %.2fmm layers (first %.2f) · %d%% infill · %d walls · supports %s%s"
   cmacs-cad-slicer-layer-height cmacs-cad-slicer-first-layer-height
   cmacs-cad-slicer-infill cmacs-cad-slicer-perimeters
   (if cmacs-cad-slicer-supports "on" "off")
   (if cmacs-cad-slicer-supports
       (format " (%s)" cmacs-cad-slicer-support-style) "")))

(provide 'cmacs-cad-slicer)
;;; cmacs-cad-slicer.el ends here
