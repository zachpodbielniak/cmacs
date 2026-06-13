;;; cmacs-cad-mcp.el --- Elisp helpers for the CAD MCP tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The "vibe CAD" surface: small, fused entry points that an MCP agent
;; drives via cmacs/mcp/cmacs-mcp-tools-cad.c.  Each returns a STRING (the
;; tool's text result) or, for `cmacs-cad-mcp-snapshot', a PNG path the C
;; layer attaches as inline image content.  Keeping the logic here (not in
;; C) makes it testable and one-line to evolve.
;;
;; The headline tool is `cmacs-cad-mcp-set-source': one call edits the
;; part, re-evaluates it, and reports success + part names or the error
;; with its source location -- the agent's inner loop.

;;; Code:

(require 'cl-lib)

(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-set-source "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-params "cmacs-cad-defuns.c")
(declare-function cmacs-cad-part-names "cmacs-cad-defuns.c")
(declare-function cmacs-cad-inspect "cmacs-cad-defuns.c")
(declare-function cmacs-cad-feature-tree "cmacs-cad-defuns.c")
(declare-function cmacs-cad-section "cmacs-cad-defuns.c")
(declare-function cmacs-cad-export "cmacs-cad-defuns.c")
(declare-function cmacs-cad-supported-p "cmacs-cad-defuns.c")
(declare-function cmacs-cad-slice "cmacs-cad-slicer")
(declare-function cmacs-cad-printer-upload "cmacs-cad-printer")
(declare-function cmacs-cad-printer-start "cmacs-cad-printer")
(defvar cmacs-cad-printers)

(defun cmacs-cad-mcp--eval-report (path)
  "Evaluate PATH and return a one-line status string."
  (condition-case err
      (progn
        (cmacs-cad-eval path)
        (format "ok; parts: %s" (or (cmacs-cad-part-names path) "(none)")))
    (error (format "error: %s" (error-message-string err)))))

(defun cmacs-cad-mcp-open (path)
  "Open PATH; return its language + capabilities (the agent learns which
language it is authoring)."
  (let ((info (cmacs-cad-doc-open path)))
    (format "language: %s\ncapabilities: %s"
            (plist-get info :language)
            (plist-get info :capabilities))))

(defun cmacs-cad-mcp-get-source (path)
  "Return the current source text of PATH."
  (if (file-readable-p path)
      (with-temp-buffer (insert-file-contents path) (buffer-string))
    (format "error: %s is not readable" path)))

(defun cmacs-cad-mcp-set-source (path source &optional no-write)
  "Replace PATH's source with SOURCE, write it to disk (unless NO-WRITE),
re-evaluate, and report.  This is the agent's edit-eval inner loop."
  (unless no-write
    (with-temp-file path (insert source)))
  (cmacs-cad-set-source path source)
  (cmacs-cad-mcp--eval-report path))

(defun cmacs-cad-mcp-patch-source (path old new)
  "Replace the single occurrence of OLD with NEW in PATH, then re-eval.
Token-economical edits.  Errors if OLD is absent or ambiguous."
  (let ((text (cmacs-cad-mcp-get-source path)))
    (let ((first (string-search old text)))
      (cond
       ((null first) (format "error: OLD text not found"))
       ((string-search old text (1+ first))
        (format "error: OLD text is not unique"))
       (t (cmacs-cad-mcp-set-source
           path (string-replace old new text)))))))

(defun cmacs-cad-mcp-eval (path)
  "Evaluate PATH and report."
  (cmacs-cad-mcp--eval-report path))

(defun cmacs-cad-mcp-params (path)
  "Return PATH's parameters as a readable table."
  (mapconcat
   (lambda (p)
     (format "%s = %g%s" (plist-get p :name) (plist-get p :value)
             (if (plist-get p :min)
                 (format "  [%g..%g]" (plist-get p :min) (plist-get p :max))
               "")))
   (cmacs-cad-params path) "\n"))

(defun cmacs-cad-mcp-inspect (path)
  "Return PATH's mass properties as text."
  (let* ((i (cmacs-cad-inspect path))
         (com (plist-get i :center-of-mass))
         (bb (plist-get i :bbox)))
    (concat
     (format "volume %.4f  area %.4f  triangles %s  watertight %s"
             (plist-get i :volume) (plist-get i :area)
             (plist-get i :triangles)
             (if (plist-get i :watertight) "yes" "no"))
     (when com (format "\ncenter-of-mass (%.3f %.3f %.3f)"
                       (nth 0 com) (nth 1 com) (nth 2 com)))
     (when bb (format "\nbbox (%.3f %.3f %.3f)-(%.3f %.3f %.3f)"
                      (nth 0 bb) (nth 1 bb) (nth 2 bb)
                      (nth 3 bb) (nth 4 bb) (nth 5 bb))))))

(defun cmacs-cad-mcp--tree-string (node depth)
  (concat (make-string (* 2 depth) ?\s)
          (format "%s (%s)\n" (plist-get node :label) (plist-get node :kind))
          (mapconcat (lambda (c) (cmacs-cad-mcp--tree-string c (1+ depth)))
                     (plist-get node :children) "")))

(defun cmacs-cad-mcp-feature-tree (path)
  "Return PATH's feature tree as indented text."
  (let ((tree (cmacs-cad-feature-tree path)))
    (if tree (cmacs-cad-mcp--tree-string tree 0) "(no evaluated part)")))

(defun cmacs-cad-mcp-section (path axis offset)
  "Section PATH by AXIS (\"x\"/\"y\"/\"z\") at OFFSET; report perimeter."
  (let* ((pt (pcase axis ("x" (list offset 0 0)) ("y" (list 0 offset 0))
                   (_ (list 0 0 offset))))
         (nrm (pcase axis ("x" '(1 0 0)) ("y" '(0 1 0)) (_ '(0 0 1))))
         (segs (apply #'cmacs-cad-section path (append pt nrm)))
         (perim (apply #'+
                       (mapcar (lambda (s)
                                 (sqrt (+ (expt (- (nth 3 s) (nth 0 s)) 2)
                                          (expt (- (nth 4 s) (nth 1 s)) 2)
                                          (expt (- (nth 5 s) (nth 2 s)) 2))))
                               segs))))
    (if (null segs)
        (format "section %s=%g misses the part" axis offset)
      (format "section %s=%g: %d segments, perimeter %.3f"
              axis offset (length segs) perim))))

(defun cmacs-cad-mcp-export (path out format)
  "Export PATH to OUT in FORMAT (a string like \"stl\"); report."
  (cmacs-cad-export path (expand-file-name out) (intern format))
  (format "exported %s (%s)" out format))

(defun cmacs-cad-mcp-snapshot (path &optional png width height)
  "Render PATH in a workbench and snapshot to PNG; return the PNG path.
WIDTH/HEIGHT size the offscreen view.  Returns a string starting with
\"error:\" on failure so the C layer reports text instead of an image."
  (if (not (display-graphic-p))
      "error: snapshot needs a graphical display"
    (require 'cmacs-cad-editor)
    (let ((out (or png (make-temp-file "cmacs-cad-mcp" nil ".png")))
          (buf (find-file-noselect path)))
      (with-current-buffer buf
        (cmacs-cad-eval path)
        (when (fboundp 'cmacs-cad-workbench)
          (cmacs-cad-workbench))
        (let ((editor (and (boundp 'cmacs-cad-editor--workbench)
                           cmacs-cad-editor--workbench)))
          (if (and editor (buffer-live-p editor)
                   (fboundp 'cmacs-libregnum-snapshot))
              (progn
                (ignore width height)
                (cmacs-libregnum-snapshot editor out)
                out)
            "error: could not open a workbench viewport"))))))

(defun cmacs-cad-mcp-slice (path &optional timeout)
  "Export PATH to STL, slice it synchronously (waiting up to TIMEOUT
seconds, default 300), and report the produced G-code path or an error."
  (require 'cmacs-cad-slicer)
  (let* ((stl (make-temp-file "cmacs-cad-mcp" nil ".stl"))
         (done nil) (result nil)
         (deadline (+ (float-time) (or timeout 300))))
    (cmacs-cad-export path stl 'stl)
    (cmacs-cad-slice stl nil nil
                     (lambda (status out)
                       (setq done t result (cons status out))))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.2))
    (cond
     ((not done) "error: slice timed out")
     ((eq (car result) 'done) (format "sliced: %s" (cdr result)))
     (t (format "error: slice failed (%s)" (cdr result))))))

(defun cmacs-cad-mcp-printers ()
  "List configured printers."
  (if (null cmacs-cad-printers)
      "(no printers configured in cmacs-cad-printers)"
    (mapconcat (lambda (p) (format "%s  %s  %s"
                                   (plist-get p :name) (plist-get p :type)
                                   (plist-get p :url)))
               cmacs-cad-printers "\n")))

(defun cmacs-cad-mcp-print (printer gcode &optional start confirm)
  "Upload GCODE to PRINTER; START + CONFIRM both required to begin a print.
Without both, only uploads (the default safe behaviour)."
  (require 'cmacs-cad-printer)
  (condition-case err
      (if (and start confirm)
          (progn (cmacs-cad-printer-start printer gcode :confirm t)
                 (format "uploading + starting print on %s" printer))
        (progn (cmacs-cad-printer-upload printer gcode)
               (format "uploaded to %s (print NOT started)" printer)))
    (error (format "error: %s" (error-message-string err)))))

;;;; Assemblies

(declare-function cmacs-cad-assembly-info "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-bom "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-interference "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-set-joint "cmacs-cad-assembly.c")

(defun cmacs-cad-mcp-assembly-info (path name)
  "Return assembly NAME of PATH as a readable summary."
  (require 'cmacs-cad-assembly nil t)
  (condition-case err
      (progn
        (cmacs-cad-eval path)
        (let ((info (cmacs-cad-assembly-info path name)))
          (format "%s: %s, %d DOF, %d instances\n%s"
                  name (plist-get info :state) (plist-get info :dof)
                  (length (plist-get info :instances))
                  (mapconcat
                   (lambda (i)
                     (let ((m (nth 2 i)))
                       (format "  #%d %s @ (%.2f %.2f %.2f)"
                               (nth 0 i) (nth 1 i)
                               (aref m 9) (aref m 10) (aref m 11))))
                   (plist-get info :instances) "\n"))))
    (error (format "error: %s" (error-message-string err)))))

(defun cmacs-cad-mcp-assembly-bom (path name)
  "Return assembly NAME of PATH as a bill-of-materials table."
  (require 'cmacs-cad-assembly nil t)
  (condition-case err
      (progn
        (cmacs-cad-eval path)
        (mapconcat
         (lambda (e)
           (format "%-20s x%-3d  vol=%.3f  mass=%.3f"
                   (plist-get e :part) (plist-get e :quantity)
                   (plist-get e :volume) (plist-get e :mass)))
         (cmacs-cad-assembly-bom path name) "\n"))
    (error (format "error: %s" (error-message-string err)))))

(defun cmacs-cad-mcp-assembly-interference (path name)
  "Return interferences in assembly NAME of PATH."
  (require 'cmacs-cad-assembly nil t)
  (condition-case err
      (progn
        (cmacs-cad-eval path)
        (let ((hits (cmacs-cad-assembly-interference path name)))
          (if (null hits)
              "no interferences"
            (mapconcat
             (lambda (h)
               (format "instance #%d <-> #%d : %.4f mm^3"
                       (plist-get h :a) (plist-get h :b)
                       (plist-get h :volume)))
             hits "\n"))))
    (error (format "error: %s" (error-message-string err)))))

(defun cmacs-cad-mcp-assembly-set-joint (path name joint value)
  "Drive JOINT of assembly NAME in PATH to VALUE; report new transforms."
  (require 'cmacs-cad-assembly nil t)
  (condition-case err
      (progn
        (cmacs-cad-eval path)
        (let ((insts (cmacs-cad-assembly-set-joint path name joint value)))
          (format "joint #%d -> %s\n%s" joint value
                  (mapconcat
                   (lambda (i)
                     (let ((m (nth 2 i)))
                       (format "  #%d %s @ (%.2f %.2f %.2f)"
                               (nth 0 i) (nth 1 i)
                               (aref m 9) (aref m 10) (aref m 11))))
                   insts "\n"))))
    (error (format "error: %s" (error-message-string err)))))

(provide 'cmacs-cad-mcp)
;;; cmacs-cad-mcp.el ends here
