;;; cmacs-cad-tools.el --- Parametric CAD as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Seventeen of the eighteen `cad_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-cad.c that
;; evaluated a printf-built call to a `cmacs-cad-mcp-*' helper
;; (lisp/cmacs/cmacs-cad-mcp.el).  Here they are `cmacs-brigade-deftool'
;; forms calling the same helpers (doc_org/cmacs/cmacs-capability.org
;; has the recipe), reaching in-process agents, MCP clients,
;; org.cmacs.Editor1.Tools and `emacsctl tool cad ...' from one
;; definition.  Wire names, parameter names and the required/optional
;; split are the C ones.  Those handlers are deleted; the schema they
;; published is frozen in test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; Not here: `cad_snapshot'.  It answers with an inline PNG, and the
;; registry's results are text; it keeps its C handler, the one tool
;; left in that C file.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - `cad_slice' does not block.  The helper it called waited in an
;;     `accept-process-output' loop for up to five minutes, in the
;;     dispatch -- under `emacs --gowl' that is the compositor thread.
;;     Here the slicer's own completion callback answers the call.
;;
;;   - A failure is a failure.  The helpers report trouble by returning
;;     a string that starts "error:", which an MCP client could not tell
;;     from success; that prefix is turned back into an error here.
;;
;;   - No argument is spliced into Lisp source, and the names the
;;     helpers `intern' (an export format) or branch on (a section
;;     axis) are checked against the set the tool documents.
;;
;;   - The tools that write a file or reach a printer say so:
;;     `cad_set_source', `cad_patch_source', `cad_export', `cad_slice'
;;     and `cad_print' are :destructive and go through the shared
;;     confirmation policy (`cmacs-brigade-auto-approve'), like
;;     `project_write_file'.  `cad_print' keeps the C gate as well: a
;;     print only starts when START and CONFIRM are both true.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-cad-mcp-open "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-get-source "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-set-source "cmacs-cad-mcp"
                  (path source &optional no-write))
(declare-function cmacs-cad-mcp-patch-source "cmacs-cad-mcp" (path old new))
(declare-function cmacs-cad-mcp-eval "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-params "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-inspect "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-feature-tree "cmacs-cad-mcp" (path))
(declare-function cmacs-cad-mcp-section "cmacs-cad-mcp" (path axis offset))
(declare-function cmacs-cad-mcp-export "cmacs-cad-mcp" (path out format))
(declare-function cmacs-cad-mcp-printers "cmacs-cad-mcp" ())
(declare-function cmacs-cad-mcp-print "cmacs-cad-mcp"
                  (printer gcode &optional start confirm))
(declare-function cmacs-cad-mcp-assembly-info "cmacs-cad-mcp" (path name))
(declare-function cmacs-cad-mcp-assembly-bom "cmacs-cad-mcp" (path name))
(declare-function cmacs-cad-mcp-assembly-interference "cmacs-cad-mcp"
                  (path name))
(declare-function cmacs-cad-mcp-assembly-set-joint "cmacs-cad-mcp"
                  (path name joint value))
(declare-function cmacs-cad-export "cmacs-cad-defuns.c" (path out format))
(declare-function cmacs-cad-slice "cmacs-cad-slicer"
                  (stl &optional out-gcode extra callback))

(defconst cmacs-cad-tools--export-formats
  '("stl" "stl-ascii" "obj" "step" "iges")
  "The formats `cad_export' documents.
The helper interns the format name, so it is checked against this list
first rather than interned from whatever a caller sent.")

(defconst cmacs-cad-tools--slice-timeout 3600
  "Seconds the registry lets `cad_slice' run.
The tool's own TIMEOUT argument (default 300) is what normally ends a
slice that hangs; this is the ceiling on it.")

(defun cmacs-cad-tools--report (text)
  "Return TEXT, a helper's result, or signal when it reports an error.
The `cmacs-cad-mcp-*' helpers catch errors and return them as a string
beginning \"error:\".  That was the only shape the C handlers could
pass on; a registered tool has a real failure channel."
  (if (and (stringp text) (string-prefix-p "error:" text))
      (error "%s" (string-trim (substring text (length "error:"))))
    text))

(defun cmacs-cad-tools--call (fn &rest args)
  "Load the CAD helper library, apply FN to ARGS, and report the result."
  (require 'cmacs-cad-mcp)
  (cmacs-cad-tools--report (apply fn args)))

(defun cmacs-cad-tools--path (path)
  "Return PATH, or signal when it is missing."
  (when (or (null path) (string-empty-p path))
    (error "Missing path"))
  path)

(cmacs-brigade-deftool cad-open
    "Open a .cad/.ccad part; returns its language + capabilities."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad open --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-open (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-get-source
    "Return a part's source text."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad get-source --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-get-source
                         (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-set-source
    "Replace a part's whole SOURCE, write it, re-evaluate, and report \
ok+parts or the error with its source location. The edit-eval loop."
    ((path string "The part file")
     (source string "The whole new source"))
  :group 'cad
  :destructive t
  :undo '(irreversible "no CAD undo is reachable from the tools")
  :confirm 'ask
  (cmacs-cad-tools--call #'cmacs-cad-mcp-set-source
                         (cmacs-cad-tools--path path) (or source "")))

(cmacs-brigade-deftool cad-patch-source
    "Replace the single occurrence of OLD with NEW in a part, then \
re-evaluate. Token-economical edits; errors if OLD is absent/ambiguous."
    ((path string "The part file")
     (old string "Text to replace; must occur exactly once")
     (new string "Replacement text"))
  :group 'cad
  :destructive t
  :undo '(irreversible "no CAD undo is reachable from the tools")
  :confirm 'ask
  (when (or (null old) (string-empty-p old))
    (error "Missing old"))
  (cmacs-cad-tools--call #'cmacs-cad-mcp-patch-source
                         (cmacs-cad-tools--path path) old (or new "")))

(cmacs-brigade-deftool cad-eval
    "Re-evaluate a part; report ok+parts/error."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad eval --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-eval (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-params
    "List a part's parameters and ranges."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad params --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-params
                         (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-inspect
    "Mass properties: volume, area, triangles, watertight, COM, bbox."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad inspect --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-inspect
                         (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-feature-tree
    "The part's feature (CSG) tree as indented text."
    ((path string "The part file"))
  :group 'cad
  :example "emacsctl tool cad feature-tree --path ~/cad/bracket.cad"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-feature-tree
                         (cmacs-cad-tools--path path)))

(cmacs-brigade-deftool cad-section
    "Section the part by an X/Y/Z plane at OFFSET; report segments + \
perimeter."
    ((path string "The part file")
     (axis string "x, y or z (default z)" :optional t)
     (offset number "Plane offset along the axis (default 0)" :optional t))
  :group 'cad
  :example "emacsctl tool cad section --path ~/cad/bracket.cad --axis z \
--offset 2.5"
  (let ((axis (if (or (null axis) (string-empty-p axis)) "z" axis))
        (offset (or offset 0.0)))
    ;; The helper treats anything that is not x or y as z; say so
    ;; instead of sectioning along an axis nobody asked for.
    (unless (member axis '("x" "y" "z"))
      (error "axis must be x|y|z"))
    (unless (numberp offset)
      (error "offset must be a number"))
    (cmacs-cad-tools--call #'cmacs-cad-mcp-section
                           (cmacs-cad-tools--path path) axis offset)))

(cmacs-brigade-deftool cad-export
    "Export the part to OUT in FORMAT (stl/stl-ascii/obj/step/iges)."
    ((path string "The part file")
     (out string "Destination file")
     (format string "stl (the default), stl-ascii, obj, step or iges"
             :optional t))
  :group 'cad
  :destructive t
  :undo '(irreversible "the export overwrites its destination")
  :confirm 'ask
  (let ((fmt (if (or (null format) (string-empty-p format)) "stl" format)))
    (unless (member fmt cmacs-cad-tools--export-formats)
      (error "format must be %s"
             (string-join cmacs-cad-tools--export-formats "|")))
    (when (or (null out) (string-empty-p out))
      (error "Missing out"))
    (cmacs-cad-tools--call #'cmacs-cad-mcp-export
                           (cmacs-cad-tools--path path) out fmt)))

(cmacs-brigade-deftool cad-slice
    "Export the part to STL and slice it to G-code (waits, default 300s)."
    ((path string "The part file")
     (timeout number "Seconds to wait for the slicer (default 300)"
              :optional t))
  :group 'cad
  :destructive t
  :undo '(irreversible "slicer output is written by another program")
  :confirm 'ask
  :async t
  :timeout cmacs-cad-tools--slice-timeout
  (require 'cmacs-cad-mcp)
  (require 'cmacs-cad-slicer)
  (let* ((path (cmacs-cad-tools--path path))
         (limit (min (if (and (numberp timeout) (> timeout 0)) timeout 300)
                     (- cmacs-cad-tools--slice-timeout 10)))
         (stl (make-temp-file "cmacs-cad-mcp" nil ".stl"))
         (timer nil)
         (settled nil)
         (finish
          (lambda (text)
            ;; The slicer's callback and the timeout can both get here;
            ;; the caller is answered by whichever is first.
            (unless settled
              (setq settled t)
              (when (timerp timer) (cancel-timer timer))
              (funcall done text)))))
    (cmacs-cad-export path stl 'stl)
    ;; `cmacs-cad-slice' starts the slicer as a subprocess and returns;
    ;; its sentinel calls back with the outcome.
    (cmacs-cad-slice
     stl nil nil
     (lambda (status out)
       ;; The intermediate STL has served its purpose either way.
       (ignore-errors (delete-file stl))
       (funcall finish
                (if (eq status 'done)
                    (format "sliced: %s" out)
                  (format "Error: slice failed (%s)" out)))))
    (setq timer
          (run-at-time limit nil
                       (lambda ()
                         (funcall finish "Error: slice timed out"))))))

(cmacs-brigade-deftool cad-printers
    "List configured printers."
    ()
  :group 'cad
  :example "emacsctl tool cad printers"
  ;; The helper reads `cmacs-cad-printers', which lives in the printer
  ;; library; nothing else guarantees that is loaded.  (The C handler
  ;; did not load it and answered "void variable" in a fresh session.)
  (require 'cmacs-cad-printer)
  (cmacs-cad-tools--call #'cmacs-cad-mcp-printers))

(cmacs-brigade-deftool cad-print
    "Upload GCODE to PRINTER. A print only STARTS when BOTH start and \
confirm are true; otherwise it only uploads (the safe default)."
    ((printer string "Printer name, as cad_printers lists it")
     (gcode string "G-code file to upload")
     (start boolean "Start the print after uploading" :optional t)
     (confirm boolean "Must also be true for START to take effect"
              :optional t))
  :group 'cad
  :destructive t
  :undo '(irreversible "a print job cannot be taken back")
  :confirm 'ask
  (when (or (null printer) (string-empty-p printer))
    (error "Missing printer"))
  (when (or (null gcode) (string-empty-p gcode))
    (error "Missing gcode"))
  ;; The upload is asynchronous in the printer backend; the helper
  ;; reports that it was started.  Both flags are passed through as
  ;; given: the helper is where "start AND confirm" is decided.
  (cmacs-cad-tools--call #'cmacs-cad-mcp-print printer gcode
                         (and start t) (and confirm t)))

(cmacs-brigade-deftool cad-assembly-info
    "Assembly NAME's solved state, DOF, and per-instance transforms."
    ((path string "The part file")
     (name string "Assembly name"))
  :group 'cad
  :example "emacsctl tool cad assembly-info --path ~/cad/arm.cad --name arm"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-assembly-info
                         (cmacs-cad-tools--path path) name))

(cmacs-brigade-deftool cad-assembly-bom
    "Assembly NAME's bill of materials (part, quantity, volume, mass)."
    ((path string "The part file")
     (name string "Assembly name"))
  :group 'cad
  :example "emacsctl tool cad assembly-bom --path ~/cad/arm.cad --name arm"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-assembly-bom
                         (cmacs-cad-tools--path path) name))

(cmacs-brigade-deftool cad-assembly-interference
    "Interferences (overlapping instance pairs + volume) in assembly NAME."
    ((path string "The part file")
     (name string "Assembly name"))
  :group 'cad
  :example "emacsctl tool cad assembly-interference --path ~/cad/arm.cad \
--name arm"
  (cmacs-cad-tools--call #'cmacs-cad-mcp-assembly-interference
                         (cmacs-cad-tools--path path) name))

(cmacs-brigade-deftool cad-assembly-set-joint
    "Drive JOINT (id) of assembly NAME to VALUE and re-solve (no source \
re-eval); report the new instance transforms."
    ((path string "The part file")
     (name string "Assembly name")
     (joint integer "Joint id")
     (value number "Value to drive the joint to"))
  :group 'cad
  :destructive t
  :undo '(irreversible "no CAD undo is reachable from the tools")
  :example "emacsctl tool cad assembly-set-joint --path ~/cad/arm.cad \
--name arm --joint 0 --value 45"
  (unless (integerp joint)
    (error "joint must be an integer"))
  (unless (numberp value)
    (error "value must be a number"))
  (cmacs-cad-tools--call #'cmacs-cad-mcp-assembly-set-joint
                         (cmacs-cad-tools--path path) name joint value))

(provide 'cmacs-cad-tools)

;;; cmacs-cad-tools.el ends here
