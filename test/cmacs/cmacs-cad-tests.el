;;; cmacs-cad-tests.el --- ERT tests for the CAD subsystem -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three tiers (the cmacs-libregnum-tests pattern):
;;   1. Pure Elisp: mode machinery, vocabulary fallbacks -- always run.
;;   2. Headless kernel: real cad-glib evaluation through the DEFUNs --
;;      skip-unless the subsystem is built in.  No display needed.
;;   3. Display-guarded: the part workbench in the libregnum editor --
;;      skipped in batch / CAD-less / libregnum-less builds.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'imenu)
(require 'cmacs)
(require 'cmacs-cad)
(require 'cmacs-cad-crispy)
(require 'cmacs-cad-gcode)
(require 'cmacs-cad-slicer)
(require 'cmacs-cad-printer)
(require 'cmacs-cad-mcp)
(require 'cmacs-cad-org-block)
(require 'cmacs-cad-sketch)
(require 'cmacs-cad-project)
(require 'cmacs-cad-model)
(require 'cmacs-cad-assembly nil t)

(declare-function cmacs-cad-assembly-names "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-info "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-bom "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-interference "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-joints "cmacs-cad-assembly.c")
(declare-function cmacs-cad-assembly-set-joint "cmacs-cad-assembly.c")

(defconst cmacs-cad-tests--bracket
  "(defparam thickness 4.0 :min 2 :max 10)
(defpart bracket
  (difference
    (box 40 20 thickness)
    (translate (10 10 -1) (cylinder :r 2.5 :h (+ thickness 2)))))\n")

(defconst cmacs-cad-tests--bracket-ccad
  "int main (void)
{
    double t = cad_param_double (\"thickness\", 4.0, 2, 10);
    CadSolid *body = cad_box (40, 20, t);
    body = cad_difference (body,
        cad_translate (cad_cylinder (2.5, t + 2), 10, 10, -1));
    cad_emit_named (\"bracket\", body);
    return 0;
}\n")

(defun cmacs-cad-tests--fixture (contents &optional extension)
  "Write CONTENTS to a temp part file; return its path."
  (let ((path (make-temp-file "cmacs-cad-test" nil
                              (or extension ".cad"))))
    (with-temp-file path (insert contents))
    path))

;;; Tier 1: pure Elisp

(ert-deftest cmacs-cad-tests-mode-machinery ()
  "Major modes, font-lock tables and imenu work without the subsystem."
  (with-temp-buffer
    (insert cmacs-cad-tests--bracket)
    (cmacs-cad-mode)
    (should (derived-mode-p 'lisp-data-mode))
    (should (equal cmacs-cad--language "sexp"))
    ;; imenu finds the part and param.
    (let ((index (imenu--make-index-alist t)))
      (should (assoc "Parts" index))
      (should (assoc "Params" index)))))

(ert-deftest cmacs-cad-tests-crispy-mode-machinery ()
  (with-temp-buffer
    (insert cmacs-cad-tests--bracket-ccad)
    (cmacs-cad-crispy-mode)
    (should (derived-mode-p 'c-mode))
    (should (equal cmacs-cad--language "crispy"))))

(ert-deftest cmacs-cad-tests-vocabulary-fallback ()
  "The static vocabulary serves capf even without the subsystem."
  (let ((vocab (if (cmacs-cad-available-p)
                   (cmacs-cad-vocabulary "sexp")
                 cmacs-cad--static-vocabulary)))
    (should (assoc "box" vocab))
    (should (assoc "difference" vocab))
    (should (assoc "defparam" vocab))))

(ert-deftest cmacs-cad-tests-auto-mode-alist ()
  (should (eq (cdr (assoc "\\.cad\\'" auto-mode-alist)) 'cmacs-cad-mode))
  (should (eq (cdr (assoc "\\.ccad\\'" auto-mode-alist))
              'cmacs-cad-crispy-mode)))

(ert-deftest cmacs-cad-tests-feature-arm ()
  "The cad feature arm exists and never errors."
  (should (memq (cmacs-feature-p 'cad) '(t nil))))

;;; Tier 1: G-code parser (pure Elisp, no subsystem)

(defconst cmacs-cad-tests--gcode
  (concat "G90\nM82\n"
          "G1 Z0.2\n"
          "G1 X0 Y0 E0\nG1 X10 Y0 E1\nG1 X10 Y10 E2\n"
          "G1 X0 Y10 E3\nG1 X0 Y0 E4\n"
          "G0 X5 Y5\n"                          ; travel, not extruding
          "G1 Z0.4\n"
          "G1 X0 Y0 E5\nG1 X10 Y0 E6\n"
          ";TIME:120\n;Filament used: 1.5m\n"))

(ert-deftest cmacs-cad-tests-gcode-parse ()
  "The G-code parser groups layers and reads footer stats."
  (let ((doc (cmacs-cad-gcode-parse cmacs-cad-tests--gcode)))
    (should (= 2 (length (cmacs-cad-gcode-doc-layers doc))))
    (should (= 120 (cmacs-cad-gcode-doc-time-seconds doc)))
    (should (= 1500.0 (cmacs-cad-gcode-doc-filament-mm doc)))
    (should (equal '(0 0 10 10) (cmacs-cad-gcode-doc-bbox doc)))))

(ert-deftest cmacs-cad-tests-gcode-no-footer ()
  "A part with no footer parses with nil stats, not an error."
  (let ((doc (cmacs-cad-gcode-parse
              "G90\nG1 Z0.2\nG1 X0 Y0 E0\nG1 X5 Y5 E1\n")))
    (should (= 1 (length (cmacs-cad-gcode-doc-layers doc))))
    (should-not (cmacs-cad-gcode-doc-time-seconds doc))
    (should-not (cmacs-cad-gcode-doc-filament-mm doc))))

(ert-deftest cmacs-cad-tests-gcode-obj-mesh ()
  "The toolpath OBJ writer emits a bead box (8 v, 12 f) per extruding move."
  (let* ((doc (cmacs-cad-gcode-parse cmacs-cad-tests--gcode))
         (obj (make-temp-file "cmacs-gcode" nil ".obj")))
    (unwind-protect
        (let ((n (cmacs-cad-gcode--write-obj doc 0 99 obj)))
          ;; 6 extruding moves in the fixture (the G0 travel is skipped).
          (should (= n 6))
          (let ((text (with-temp-buffer (insert-file-contents obj)
                                        (buffer-string))))
            ;; 8 vertices + 12 faces per move.
            (should (= (* n 8) (cl-count ?\n (mapconcat
                                             (lambda (l)
                                               (if (string-prefix-p "v " l)
                                                   "\n" ""))
                                             (split-string text "\n") ""))))
            (should (string-match-p "^f [0-9]+ [0-9]+ [0-9]+" text))))
      (delete-file obj))))

(ert-deftest cmacs-cad-tests-gcode-relative ()
  "Relative positioning (G91) accumulates moves correctly."
  (let* ((doc (cmacs-cad-gcode-parse
               "G91\nM83\nG1 Z0.2\nG1 X10 Y0 E1\nG1 X0 Y10 E1\n"))
         (moves (aref (cmacs-cad-gcode-doc-layers doc) 0)))
    ;; Two extruding moves; the second ends at (10,10).
    (should (= 2 (length moves)))
    (should (= 10 (cmacs-cad-gcode-move-x1 (nth 1 moves))))
    (should (= 10 (cmacs-cad-gcode-move-y1 (nth 1 moves))))))

;;; Tier 1: fabrication (slicer + printer, pure Elisp, no hardware)

(ert-deftest cmacs-cad-tests-slicer-overrides-ini ()
  "The overrides ini maps common params to backend ini keys, with
per-slice EXTRA winning over the defcustoms."
  (let ((backend (cmacs-cad-slicer--backend 'prusa))
        (cmacs-cad-slicer-layer-height 0.2)
        (cmacs-cad-slicer-infill 15)
        (path (make-temp-file "cmacs-slice" nil ".ini")))
    (unwind-protect
        (progn
          (cmacs-cad-slicer--write-overrides-ini
           backend path '((layer-height . 0.3)))
          (let ((text (with-temp-buffer (insert-file-contents path)
                                        (buffer-string))))
            ;; EXTRA wins: layer_height 0.3 not 0.2.
            (should (string-match-p "layer_height = 0.3" text))
            (should (string-match-p "fill_density = 15%" text))
            (should (string-match-p "perimeters = 3" text))))
      (delete-file path))))

(ert-deftest cmacs-cad-tests-slicer-argv ()
  "The slice argv loads the base then overrides (last wins) and names
input + output."
  (cmacs-cad-slicer-register
   (cmacs-cad-slicer-backend-create
    :name 'test-native
    :resolve (lambda () (cons "my-slicer" nil))
    :param-map '((layer-height . "layer_height"))))
  (let* ((backend (cmacs-cad-slicer--backend 'test-native))
         (cmacs-cad-slicer-base-profile nil)
         (argv (cmacs-cad-slicer-argv backend "/tmp/ov.ini"
                                      "/tmp/in.stl" "/tmp/out.gcode")))
    (should (equal (car argv) "my-slicer"))
    (should (member "--export-gcode" argv))
    (should (member "/tmp/in.stl" argv))
    (should (member "/tmp/out.gcode" argv))
    (should (member "--load" argv))))

(ert-deftest cmacs-cad-tests-slicer-staging-escape ()
  "A flatpak backend with staging outside $HOME is rejected."
  (cmacs-cad-slicer-register
   (cmacs-cad-slicer-backend-create
    :name 'test-flatpak
    :resolve (lambda () (cons "flatpak" '("run" "x")))
    :param-map nil))
  (let ((backend (cmacs-cad-slicer--backend 'test-flatpak))
        (cmacs-cad-slicer-staging-dir "/var/tmp/escape/"))
    (should-not (cmacs-cad-slicer--staging-ok-p backend)))
  (let ((backend (cmacs-cad-slicer--backend 'test-flatpak))
        (cmacs-cad-slicer-staging-dir (expand-file-name "~/x/slice/")))
    (should (cmacs-cad-slicer--staging-ok-p backend))))

(ert-deftest cmacs-cad-tests-slicer-estimate ()
  "Estimates come from the G-code footer."
  (let ((gc (make-temp-file "cmacs-est" nil ".gcode")))
    (unwind-protect
        (progn
          (with-temp-file gc
            (insert "G1 X0 Y0\n;TIME:3600\n;Filament used: 2.5m\n"))
          (let ((est (cmacs-cad-slicer-estimate gc)))
            (should (= 3600 (car est)))
            (should (= 2500.0 (cdr est)))))
      (delete-file gc))))

(ert-deftest cmacs-cad-tests-printer-curl-config ()
  "The curl config carries url, auth header and form fields, with the
key never in argv."
  (let ((cfg (cmacs-cad-printer--curl-config
              "http://printer/api/files/local" "POST"
              '(("X-Api-Key" . "SECRET"))
              '(("file" . "@/tmp/x.gcode") ("print" . "true")))))
    (should (string-match-p "url = \"http://printer/api/files/local\"" cfg))
    (should (string-match-p "request = \"POST\"" cfg))
    (should (string-match-p "header = \"X-Api-Key: SECRET\"" cfg))
    (should (string-match-p "form = \"file=@/tmp/x.gcode\"" cfg))
    (should (string-match-p "form = \"print=true\"" cfg))))

(ert-deftest cmacs-cad-tests-printer-start-needs-confirm ()
  "`cmacs-cad-printer-start' refuses without confirmation."
  (let ((cmacs-cad-printers
         '((:name "p" :type gcode :url "/tmp/cmacs-printer-test"))))
    (should-error (cmacs-cad-printer-start "p" "/tmp/x.gcode")
                  :type 'user-error)))

(ert-deftest cmacs-cad-tests-printer-gcode-sink ()
  "The `gcode' backend copies the file into the target directory, and
only starts (a no-op) when asked."
  (let* ((dir (make-temp-file "cmacs-printer" t))
         (src (make-temp-file "cmacs-print-src" nil ".gcode"))
         (cmacs-cad-printers (list (list :name "sink" :type 'gcode
                                         :url dir))))
    (unwind-protect
        (progn
          (with-temp-file src (insert "G1 X0 Y0\n"))
          (let ((dest (cmacs-cad-printer-upload "sink" src)))
            (should (file-exists-p dest))
            (should (equal (file-name-directory dest)
                           (file-name-as-directory dir)))))
      (ignore-errors (delete-file src))
      (ignore-errors (delete-directory dir t)))))

;;; Tier 1: project tooling (scaffolds + diff helpers, pure Elisp)

(ert-deftest cmacs-cad-tests-new-project ()
  "Scaffolding a project creates a part, .gitignore and README."
  (let ((dir (make-temp-file "cmacs-cad-proj" t)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'find-file) #'ignore))
            (cmacs-cad-new-project dir))
          (let ((name (file-name-nondirectory (directory-file-name dir))))
            (should (file-exists-p (expand-file-name (concat name ".cad")
                                                     dir)))
            (should (file-exists-p (expand-file-name ".gitignore" dir)))
            (should (file-exists-p (expand-file-name "README.org" dir)))))
      (delete-directory dir t))))

(ert-deftest cmacs-cad-tests-param-diff ()
  "Parameter diffing reports changed, added and removed params."
  (let ((d (cmacs-cad--param-diff
            '((:name "s" :value 10) (:name "gone" :value 1))
            '((:name "s" :value 20) (:name "new" :value 5)))))
    (should (cl-find-if (lambda (l) (string-match-p "s: 10 -> 20" l)) d))
    (should (cl-find-if (lambda (l) (string-match-p "gone removed" l)) d))
    (should (cl-find-if (lambda (l) (string-match-p "new added" l)) d))))

;;; Tier 2: headless kernel (skip-unless built in)

(ert-deftest cmacs-cad-tests-eval-and-inspect ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket)))
    (unwind-protect
        (progn
          (let ((info (cmacs-cad-doc-open path)))
            (should (equal (plist-get info :language) "sexp"))
            (should (memq :form-spans
                          (mapcar #'intern
                                  (mapcar #'symbol-name
                                          (plist-get info :capabilities))))))
          (cmacs-cad-eval path)
          (should (equal (cmacs-cad-part-names path) '("bracket")))
          (let ((info (cmacs-cad-inspect path)))
            ;; 40*20*4 minus one r=2.5 hole.
            (should (< 3100 (plist-get info :volume) 3200))
            (should (plist-get info :watertight))
            (should (> (plist-get info :triangles) 0))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-params-metadata ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket)))
    (unwind-protect
        (progn
          (cmacs-cad-doc-open path)
          ;; Static params: present BEFORE eval for sexp.
          (let* ((params (cmacs-cad-params path))
                 (thickness (seq-find
                             (lambda (p)
                               (equal (plist-get p :name) "thickness"))
                             params)))
            (should thickness)
            (should (= (plist-get thickness :default) 4.0))
            (should (= (plist-get thickness :min) 2.0))
            (should (= (plist-get thickness :max) 10.0))
            (should (= (plist-get thickness :line) 1))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-param-override ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket)))
    (unwind-protect
        (let (v4 v8)
          (cmacs-cad-eval path)
          (setq v4 (plist-get (cmacs-cad-inspect path) :volume))
          (cmacs-cad-eval path '(("thickness" . 8.0)))
          (setq v8 (plist-get (cmacs-cad-inspect path) :volume))
          (should (> v8 (* v4 1.5)))
          ;; Out-of-bounds override signals with the param name.
          (should-error (cmacs-cad-eval path '(("thickness" . 50.0)))
                        :type 'cmacs-cad-error))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-feature-tree-spans ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (let* ((tree (cmacs-cad-feature-tree path))
                 (children (plist-get tree :children))
                 (diff (car children))
                 (span (plist-get diff :span)))
            (should (eq (plist-get tree :kind) 'group))
            (should (eq (plist-get diff :kind) 'boolean))
            (should (equal (plist-get diff :label) "difference"))
            ;; The span's substring re-reads as the difference form.
            (should (consp span))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-prefix-p
                       "(difference"
                       (buffer-substring-no-properties
                        (1+ (car span)) (1+ (cdr span))))))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-broken-source-diagnostics ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture
               "(defpart broken\n  (sphere :r -1))\n")))
    (unwind-protect
        (let ((err (should-error (cmacs-cad-eval path)
                                 :type 'cmacs-cad-error)))
          ;; Error message carries the span location (line 2).
          (should (string-match "line 2" (cadr err))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-set-source-without-saving ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          ;; Replace in-memory with a thicker bracket; file unchanged.
          (cmacs-cad-set-source
           path (replace-regexp-in-string "4\\.0" "9.0"
                                          cmacs-cad-tests--bracket))
          (cmacs-cad-eval path)
          (should (> (plist-get (cmacs-cad-inspect path) :volume) 6000)))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-export-stl ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket))
        (out (make-temp-file "cmacs-cad-test" nil ".stl")))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (cmacs-cad-export path out 'stl)
          (should (> (file-attribute-size (file-attributes out)) 100)))
      (cmacs-cad-doc-close path)
      (delete-file path)
      (delete-file out))))

(ert-deftest cmacs-cad-tests-import-roundtrip ()
  "Export a part to STL, then import it from a part-relative path."
  (skip-unless (cmacs-cad-available-p))
  (let* ((dir (make-temp-file "cmacs-cad-import" t))
         (src (expand-file-name "box.cad" dir))
         (stl (expand-file-name "box.stl" dir))
         (imp (expand-file-name "imported.cad" dir)))
    (unwind-protect
        (progn
          ;; A 10mm cube, exported to a sibling STL.
          (with-temp-file src (insert "(defpart box (box 10 10 10))\n"))
          (cmacs-cad-eval src)
          (cmacs-cad-export src stl 'stl)
          (should (> (file-attribute-size (file-attributes stl)) 100))
          ;; A second part imports it by BARE relative name.
          (with-temp-file imp
            (insert "(defpart imported (import \"box.stl\"))\n"))
          (cmacs-cad-eval imp)
          (should (equal (cmacs-cad-part-names imp) '("imported")))
          (let ((info (cmacs-cad-inspect imp)))
            (should (< 990 (plist-get info :volume) 1010))
            (should (> (plist-get info :triangles) 0))))
      (cmacs-cad-doc-close src)
      (cmacs-cad-doc-close imp)
      (ignore-errors (delete-directory dir t)))))

(ert-deftest cmacs-cad-tests-import-in-vocabulary ()
  "The import form appears in the modeling vocabulary."
  (skip-unless (cmacs-cad-available-p))
  (should (assoc "import" (cmacs-cad-dsl-symbols "sexp"))))

(ert-deftest cmacs-cad-tests-inspect-mass-properties ()
  "Inspect reports center-of-mass and bbox for a centered unit cube."
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture "(defpart box (box 10 10 10))\n")))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (let* ((info (cmacs-cad-inspect path))
                 (com (plist-get info :center-of-mass))
                 (bbox (plist-get info :bbox)))
            (should com)
            (should (< (abs (- (nth 0 com) 5.0)) 0.1))
            (should (< (abs (- (nth 1 com) 5.0)) 0.1))
            (should (< (abs (- (nth 2 com) 5.0)) 0.1))
            (should (equal 6 (length bbox)))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-section ()
  "Sectioning a box at its mid-plane returns a closed outline; a plane
that misses the part returns nil."
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture "(defpart box (box 10 10 10))\n")))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (let* ((segs (cmacs-cad-section path 0 0 5 0 0 1))
                 (perim (apply #'+
                               (mapcar
                                (lambda (s)
                                  (let ((dx (- (nth 3 s) (nth 0 s)))
                                        (dy (- (nth 4 s) (nth 1 s)))
                                        (dz (- (nth 5 s) (nth 2 s))))
                                    (sqrt (+ (* dx dx) (* dy dy)
                                             (* dz dz)))))
                                segs))))
            (should (> (length segs) 0))
            ;; Each segment is a 6-tuple.
            (should (= 6 (length (car segs))))
            ;; The 10x10 outline has perimeter ~40.
            (should (< (abs (- perim 40.0)) 1.0)))
          (should-not (cmacs-cad-section path 0 0 100 0 0 1)))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-mcp-edit-loop ()
  "The MCP set-source / patch-source loop edits + re-evaluates a part."
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture "(defpart box (box 10 10 10))\n")))
    (unwind-protect
        (progn
          ;; set-source replaces + re-evals; geometry follows.
          (should (string-prefix-p "ok"
                                   (cmacs-cad-mcp-set-source
                                    path "(defpart box (box 8 8 8))\n")))
          (should (< (abs (- (plist-get (cmacs-cad-inspect path) :volume)
                             512.0))
                     1.0))
          ;; patch-source: a unique single-occurrence replace.
          (should (string-prefix-p "ok"
                                   (cmacs-cad-mcp-patch-source
                                    path "8 8 8" "12 8 8")))
          ;; an absent OLD is reported, not applied.
          (should (string-prefix-p "error"
                                   (cmacs-cad-mcp-patch-source
                                    path "no-such-text" "x")))
          ;; feature tree + section as text.
          (should (string-match-p "box"
                                  (cmacs-cad-mcp-feature-tree path)))
          (should (string-match-p "perimeter"
                                  (cmacs-cad-mcp-section path "z" 4))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-org-babel ()
  "Org Babel cad blocks return a mass-property table and honour :var."
  (skip-unless (cmacs-cad-available-p))
  (let ((tbl (org-babel-execute:cad "(defpart box (box 10 10 10))"
                                    '((:results . "table")))))
    (should (assoc "volume" tbl))
    (should (string-prefix-p "1000" (cadr (assoc "volume" tbl)))))
  (let ((tbl (org-babel-execute:cad
              "(defparam s 10 :min 1 :max 50)\n(defpart box (box s s s))"
              '((:var . (s . 20))))))
    ;; s=20 -> 20^3 = 8000.
    (should (string-prefix-p "8000" (cadr (assoc "volume" tbl))))))

(ert-deftest cmacs-cad-tests-sketch-solver ()
  "The sketch DEFUNs constrain + solve: a fixed, horizontal, length-10
line lands its free end at (10 0); DOF reaches 0."
  (skip-unless (cmacs-cad-available-p))
  (let ((sk (cmacs-cad-sketch-new)))
    (unwind-protect
        (let* ((a (cmacs-cad-sketch-add-point sk 0 0))
               (b (cmacs-cad-sketch-add-point sk 7 2))
               (l (cmacs-cad-sketch-add-line sk a b)))
          (cmacs-cad-sketch-constrain sk 'fixed a)
          (cmacs-cad-sketch-constrain sk 'horizontal l)
          (cmacs-cad-sketch-constrain sk 'distance a b 10.0)
          (cmacs-cad-sketch-solve sk)
          (should (= 0 (cmacs-cad-sketch-dof sk)))
          (let ((pa (cmacs-cad-sketch-point sk a))
                (pb (cmacs-cad-sketch-point sk b)))
            (should (< (abs (- (nth 0 pa) 0.0)) 1e-6))
            (should (< (abs (- (nth 1 pa) 0.0)) 1e-6))
            (should (< (abs (- (abs (- (nth 0 pb) (nth 0 pa))) 10.0)) 1e-4))
            (should (< (abs (- (nth 1 pb) (nth 1 pa))) 1e-4))))
      (cmacs-cad-sketch-free sk))))

(ert-deftest cmacs-cad-tests-sketch-overconstrained ()
  "Adding two conflicting distances reports a failing-constraint set."
  (skip-unless (cmacs-cad-available-p))
  (let ((sk (cmacs-cad-sketch-new)))
    (unwind-protect
        (let* ((a (cmacs-cad-sketch-add-point sk 0 0))
               (b (cmacs-cad-sketch-add-point sk 5 0)))
          (cmacs-cad-sketch-constrain sk 'fixed a)
          (cmacs-cad-sketch-constrain sk 'fixed b)
          (cmacs-cad-sketch-constrain sk 'distance a b 3.0)
          (ignore-errors (cmacs-cad-sketch-solve sk))
          ;; Either the solve signalled, or failed-constraints is non-empty.
          (should (or (cmacs-cad-sketch-failed sk)
                      (/= 0 (cmacs-cad-sketch-dof sk)))))
      (cmacs-cad-sketch-free sk))))

(ert-deftest cmacs-cad-tests-sketch-serialize ()
  "The sketcher serialises to a parseable `defsketch' form."
  (skip-unless (cmacs-cad-available-p))
  (with-temp-buffer
    (cmacs-cad-sketch-mode)
    (setq cmacs-cad-sketch--name "slot")
    (let ((p1 (cmacs-cad-sketch-add-point cmacs-cad-sketch--handle 0 0))
          (p2 (cmacs-cad-sketch-add-point cmacs-cad-sketch--handle 10 0)))
      (push (cons p1 (cons 0 0)) cmacs-cad-sketch--points)
      (push (cons p2 (cons 10 0)) cmacs-cad-sketch--points)
      (let ((id (cmacs-cad-sketch-add-line cmacs-cad-sketch--handle p1 p2)))
        (push (cons id (cons p1 p2)) cmacs-cad-sketch--lines)))
    (let ((form (cmacs-cad-sketch-serialize)))
      (should (string-prefix-p "(defsketch slot" form))
      (should (string-match-p "(pt p" form))
      (should (string-match-p "(line l" form))
      ;; It reads as a single balanced s-expression.
      (should (car (read-from-string form))))))

(ert-deftest cmacs-cad-tests-cad-diff-git ()
  "cmacs-cad-diff compares two git revisions of a part by parameters."
  (skip-unless (cmacs-cad-available-p))
  (skip-unless (executable-find "git"))
  (let ((dir (make-temp-file "cmacs-cad-git" t)))
    (unwind-protect
        (let ((default-directory dir))
          (call-process "git" nil nil nil "init" "-q")
          (call-process "git" nil nil nil "config" "user.email" "t@t")
          (call-process "git" nil nil nil "config" "user.name" "t")
          (let ((part (expand-file-name "p.cad" dir)))
            (with-temp-file part
              (insert "(defparam s 10.0)\n(defpart p (box s s s))\n"))
            (call-process "git" nil nil nil "add" "p.cad")
            (call-process "git" nil nil nil "commit" "-qm" "v1")
            (with-temp-file part
              (insert "(defparam s 20.0)\n(defpart p (box s s s))\n"))
            (let ((buf (find-file-noselect part)))
              (unwind-protect
                  (with-current-buffer buf
                    (let ((res (cmacs-cad-diff "HEAD" "")))
                      (should (plist-get res :same-shape))
                      (should (cl-find-if
                               (lambda (l) (string-match-p "10 -> 20" l))
                               (plist-get res :param-diff)))))
                (kill-buffer buf)))))
      (delete-directory dir t))))

(ert-deftest cmacs-cad-tests-model-import ()
  "Visiting an STL renders it via the generated import part: the part
imports the mesh and inspects to the source dimensions."
  (skip-unless (cmacs-cad-available-p))
  (let* ((src (cmacs-cad-tests--fixture "(defpart box (box 10 10 10))\n"))
         (stl (make-temp-file "cmacs-cad-model" nil ".stl")))
    (unwind-protect
        (progn
          (cmacs-cad-eval src)
          (cmacs-cad-export src stl 'stl)
          ;; The model viewer wraps the file in a generated import part.
          (with-temp-buffer
            (let ((cad (cmacs-cad-model--write-importer stl)))
              (should (file-exists-p cad))
              (cmacs-cad-eval cad)
              (let* ((i (cmacs-cad-inspect cad))
                     (bb (plist-get i :bbox)))
                (should (> (plist-get i :triangles) 0))
                (should (< (abs (- (- (nth 3 bb) (nth 0 bb)) 10.0)) 0.1)))
              (cmacs-cad-doc-close cad)
              (when (and cmacs-cad-model--dir
                         (file-directory-p cmacs-cad-model--dir))
                (delete-directory cmacs-cad-model--dir t)))))
      (cmacs-cad-doc-close src)
      (ignore-errors (delete-file src))
      (ignore-errors (delete-file stl)))))

(ert-deftest cmacs-cad-tests-eval-async ()
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket))
        (result nil))
    (unwind-protect
        (progn
          (cmacs-cad-eval-async path (lambda (r) (setq result r)))
          (let ((deadline (+ (float-time) 30)))
            (while (and (null result) (< (float-time) deadline))
              (accept-process-output nil 0.1)))
          (should result)
          (should (plist-get result :ok)))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-crispy-language ()
  "The crispy twin evaluates when the crispy frontend is available."
  (skip-unless (cmacs-cad-available-p))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket-ccad
                                        ".ccad")))
    (unwind-protect
        (let ((info (condition-case nil
                        (cmacs-cad-doc-open path)
                      (cmacs-cad-error nil))))
          (skip-unless info)   ; crispy frontend compiled out
          (should (equal (plist-get info :language) "crispy"))
          (cmacs-cad-eval path)
          (should (equal (cmacs-cad-part-names path) '("bracket")))
          ;; Params appear AFTER eval (no static-params capability).
          (should (seq-find (lambda (p)
                              (equal (plist-get p :name) "thickness"))
                            (cmacs-cad-params path))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-vocabulary-introspection ()
  (skip-unless (cmacs-cad-available-p))
  (let ((vocab (cmacs-cad-dsl-symbols "sexp")))
    (should (> (length vocab) 20))
    (let ((box (assoc "box" vocab)))
      (should box)
      (should (string-match "sx" (cadr box))))))

;;; Tier 2: assemblies (headless)

(defconst cmacs-cad-tests--assembly
  (concat "(defpart post (cylinder :r 2 :h 20))\n"
          "(defpart ring (cylinder :r 1 :h 4))\n"
          "(defassembly widget\n"
          "  (instance \"base\" post :grounded #t)\n"
          "  (instance \"arm\" ring)\n"
          "  (joint revolute \"base\" (cyl-largest)"
          " \"arm\" (cyl-largest) :value 0))\n")
  "A two-part hinge assembly fixture.")

(defconst cmacs-cad-tests--clash
  (concat "(defpart blk (box 10 10 10))\n"
          "(defassembly stack\n"
          "  (instance \"a\" blk :grounded #t)\n"
          "  (instance \"b\" blk)\n"
          "  (mate coincident \"a\" (top) \"b\" (bottom)))\n")
  "Two stacked boxes (touching, not interfering).")

(ert-deftest cmacs-cad-tests-assembly-names-and-info ()
  (skip-unless (cmacs-cad-available-p))
  (skip-unless (fboundp 'cmacs-cad-assembly-names))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--assembly)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (should (equal (cmacs-cad-assembly-names path) '("widget")))
          (let ((info (cmacs-cad-assembly-info path "widget")))
            ;; a revolute joint leaves the assembly under-constrained
            (should (eq (plist-get info :state) 'under-constrained))
            (should (= (length (plist-get info :instances)) 2))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-assembly-bom ()
  (skip-unless (cmacs-cad-available-p))
  (skip-unless (fboundp 'cmacs-cad-assembly-bom))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--clash)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (let* ((bom (cmacs-cad-assembly-bom path "stack"))
                 (blk (car bom)))
            (should (= (length bom) 1))
            (should (equal (plist-get blk :part) "blk"))
            (should (= (plist-get blk :quantity) 2))
            (should (< 1990 (plist-get blk :volume) 2010))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-assembly-joint-drive ()
  (skip-unless (cmacs-cad-available-p))
  (skip-unless (fboundp 'cmacs-cad-assembly-set-joint))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--assembly)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          (let* ((joints (cmacs-cad-assembly-joints path "widget"))
                 (jid (plist-get (car joints) :id))
                 (insts (cmacs-cad-assembly-set-joint path "widget" jid 90.0))
                 (arm (cl-find "arm" insts :key (lambda (i) (nth 1 i))
                               :test #'string=))
                 (m (nth 2 arm)))
            (should (= (length joints) 1))
            ;; 90 deg about Z: R[0][0] ~ 0
            (should (< (abs (aref m 0)) 1e-5))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-assembly-interference-touching ()
  (skip-unless (cmacs-cad-available-p))
  (skip-unless (fboundp 'cmacs-cad-assembly-interference))
  (let ((path (cmacs-cad-tests--fixture cmacs-cad-tests--clash)))
    (unwind-protect
        (progn
          (cmacs-cad-eval path)
          ;; faces touch but do not overlap -> no interference
          (should (null (cmacs-cad-assembly-interference path "stack"))))
      (cmacs-cad-doc-close path)
      (delete-file path))))

(ert-deftest cmacs-cad-tests-non-manifold-stl-display ()
  "A non-manifold STL imports as a display-only mesh (issue #2), not an error.
Real-world STLs are frequently non-manifold (open shells, T-junctions) yet
must remain viewable, as FreeCAD shows them.  Guards against regressing the
\"Manifold kernel: mesh is not manifold\" import failure."
  (skip-unless (cmacs-cad-available-p))
  (let* ((stl (cmacs-cad-tests--fixture
               (concat "solid open\n"
                       "  facet normal 0 0 1\n"
                       "    outer loop\n"
                       "      vertex 0 0 0\n"
                       "      vertex 1 0 0\n"
                       "      vertex 0 1 0\n"
                       "    endloop\n"
                       "  endfacet\n"
                       "endsolid open\n")
               ".stl"))
         (cad (cmacs-cad-tests--fixture
               (format "(defpart imported (import %S))\n" stl)
               ".cad")))
    (unwind-protect
        (progn
          ;; Must NOT signal cmacs-cad-error (previously it did).
          (cmacs-cad-eval cad)
          (let ((info (cmacs-cad-inspect cad)))
            (should (> (plist-get info :triangles) 0))
            ;; A display-only imported mesh is explicitly not watertight.
            (should (null (plist-get info :watertight)))))
      (cmacs-cad-doc-close cad)
      (delete-file cad)
      (delete-file stl))))

;;; Tier 3: display-guarded workbench

(defun cmacs-cad-tests--skip-unless-workbench ()
  "Skip unless a display, the CAD subsystem and the editor are all live."
  (unless (and (display-graphic-p)
               (cmacs-cad-available-p)
               (fboundp 'cmacs-libregnum-supported-p)
               (cmacs-libregnum-supported-p)
               (fboundp 'cmacs-libregnum-cad-set-source))
    (ert-skip "no display / cmacs-cad / cmacs-libregnum not built")))

(ert-deftest cmacs-cad-tests-workbench-live-update ()
  "C-c C-v workbench renders the part; an unsaved source edit + re-eval
changes the viewport (the buffer-text -> libregnum set-source bridge)."
  (cmacs-cad-tests--skip-unless-workbench)
  (require 'cmacs-cad-editor)
  (let* ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket))
         (snap1 (make-temp-file "cmacs-cad-snap" nil ".png"))
         (snap2 (make-temp-file "cmacs-cad-snap" nil ".png"))
         (cmacs-cad-eval-on-save nil)
         (part-buffer (find-file-noselect path))
         editor)
    (unwind-protect
        (with-current-buffer part-buffer
          (cmacs-cad-eval-buffer)
          (sit-for 2)
          (cmacs-cad-workbench)
          (setq editor cmacs-cad-editor--workbench)
          (should (buffer-live-p editor))
          (sit-for 3)
          (cmacs-libregnum-snapshot editor snap1)
          (should (> (file-attribute-size (file-attributes snap1)) 1024))
          ;; The feature tree panel shows the real CSG hierarchy.
          (let ((tree (get-buffer "*cmacs-cad tree*")))
            (should (buffer-live-p tree))
            (with-current-buffer tree
              (should (string-match "difference"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
          ;; Thicken the part WITHOUT saving; the viewport must follow.
          (goto-char (point-min))
          (while (search-forward "4.0" nil t) (replace-match "9.0"))
          (cmacs-cad-eval-buffer)
          (sit-for 3)
          (cmacs-libregnum-snapshot editor snap2)
          (should-not (equal (with-temp-buffer
                               (insert-file-contents-literally snap1)
                               (buffer-string))
                             (with-temp-buffer
                               (insert-file-contents-literally snap2)
                               (buffer-string)))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p part-buffer)
        (with-current-buffer part-buffer (set-buffer-modified-p nil))
        (kill-buffer part-buffer))
      (ignore-errors (delete-file path))
      (ignore-errors (delete-file snap1))
      (ignore-errors (delete-file snap2)))))

(ert-deftest cmacs-cad-tests-workbench-param-slider ()
  "Editing a param in the inspector changes geometry and is undoable.
Sets the thickness override via the undoable path, snapshots before and
after, and asserts undo restores the original bytes (geometry restored)."
  (cmacs-cad-tests--skip-unless-workbench)
  (require 'cmacs-cad-editor)
  (unless (fboundp 'cmacs-libregnum-editor-set-visual-param-undoable)
    (ert-skip "undoable visual-param DEFUN not built"))
  (let* ((path (cmacs-cad-tests--fixture cmacs-cad-tests--bracket))
         (snap0 (make-temp-file "cmacs-cad-snap" nil ".png"))
         (snap1 (make-temp-file "cmacs-cad-snap" nil ".png"))
         (snap2 (make-temp-file "cmacs-cad-snap" nil ".png"))
         (cmacs-cad-eval-on-save nil)
         (part-buffer (find-file-noselect path))
         editor id)
    (cl-flet ((bytes (f) (with-temp-buffer
                           (insert-file-contents-literally f)
                           (buffer-string))))
      (unwind-protect
          (with-current-buffer part-buffer
            (cmacs-cad-eval-buffer)
            (sit-for 2)
            (cmacs-cad-workbench)
            (setq editor cmacs-cad-editor--workbench
                  id (buffer-local-value 'cmacs-cad-editor--node-id editor))
            (should (integerp id))
            (sit-for 2)
            ;; Seeded baseline reads the source default.
            (should (= 4.0 (cmacs-libregnum-editor-get-visual-param
                            editor id "cad:thickness" 0.0)))
            (cmacs-libregnum-snapshot editor snap0)
            ;; Drag thickness to 9; geometry must change.
            (cmacs-cad-editor--set-param editor id "thickness" 9.0 2 10 nil)
            (sit-for 2)
            (should (= 9.0 (cmacs-libregnum-editor-get-visual-param
                            editor id "cad:thickness" 0.0)))
            (cmacs-libregnum-snapshot editor snap1)
            (should-not (equal (bytes snap0) (bytes snap1)))
            ;; A single undo restores the param AND the geometry.
            (cmacs-libregnum-editor-undo editor)
            (sit-for 2)
            (should (= 4.0 (cmacs-libregnum-editor-get-visual-param
                            editor id "cad:thickness" 0.0)))
            (cmacs-libregnum-snapshot editor snap2)
            (should (equal (bytes snap0) (bytes snap2))))
        (when (buffer-live-p editor) (kill-buffer editor))
        (when (buffer-live-p part-buffer)
          (with-current-buffer part-buffer (set-buffer-modified-p nil))
          (kill-buffer part-buffer))
        (ignore-errors (delete-file path))
        (ignore-errors (delete-file snap0))
        (ignore-errors (delete-file snap1))
        (ignore-errors (delete-file snap2))))))

(provide 'cmacs-cad-tests)
;;; cmacs-cad-tests.el ends here
