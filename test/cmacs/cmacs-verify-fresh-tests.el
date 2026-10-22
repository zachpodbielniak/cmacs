;;; cmacs-verify-fresh-tests.el --- the stale-artifact guard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Self-test for admin/cmacs-verify-fresh.sh, the guard that refuses a
;; test run against artifacts older than their sources.
;;
;; Each test builds a scratch tree shaped like the real one -- a src/
;; Makefile with .d files and a LIBES link line, cmacs/api, the bacon
;; modules, gowl's modules and portal, a Make-built dep with a pattern
;; rule, a cmake build tree, lisp/cmacs and test/cmacs .elc files --
;; with every artifact newer than its sources, then makes ONE source
;; newer and asserts that exactly the right class reports it.  The
;; fresh tree must pass, or every other assertion here is meaningless.
;;
;; Two properties matter as much as detection: the guard must not build
;; anything without --fix (a make probe that remakes an included
;; makefile is a build), and --fix must actually leave the tree fresh.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst cmacs-verify-fresh-tests--script
  (expand-file-name "../../admin/cmacs-verify-fresh.sh"
                    (file-name-directory
                     (or load-file-name buffer-file-name)))
  "The guard under test.")

(defconst cmacs-verify-fresh-tests--layout
  '(;; src: temacs from an object whose real prerequisites are in a
    ;; .d file, plus an archive that is only on the LIBES link line.
    ;; globals.h is the move-if-change idiom: an `@true' recipe that
    ;; leaves it older than gl-stamp for good, which is NOT staleness.
    ("src/Makefile" 300 "CMACS_DEP_BUILDTYPE = release
LIBES = -lm ../deps/x/libx.a
.PHONY: all api bacon-mods gowl-lib FORCE
all: emacs api bacon-mods ../deps/bacon/build/release/libbacon.a gowl-lib
api:
\t$(MAKE) -C ../cmacs/api all
bacon-mods:
\t$(MAKE) -C ../cmacs/bacon/modules API_DIR=$(abspath ../cmacs/api)
../deps/bacon/build/release/libbacon.a: FORCE
\t@if true; then $(MAKE) -C ../deps/bacon FLAVOUR=cmacs lib; fi
gowl-lib:
\t$(MAKE) -C ../deps/gowl lib
FORCE:
temacs: a.o globals.h
\tcc -o $@ a.o
emacs: temacs
\tcp temacs emacs
a.o:
\tcc -c a.c
globals.h: gl-stamp; @true
gl-stamp: a.c
\techo > $@
-include deps/a.d
")
    ("src/deps/a.d" 300 "a.o: a.c a.h\na.h:\n")
    ("src/a.c" 300 "")
    ("src/a.h" 300 "")
    ("src/globals.h" 250 "")
    ("src/gl-stamp" 200 "")
    ("src/a.o" 150 "")
    ("deps/x/libx.a" 150 "")
    ("src/temacs" 100 "")
    ("src/emacs" 100 "")
    ;; cmacs/api: the shape of the real Makefile (OUTDIR ?= .).
    ("cmacs/api/Makefile" 300 "OUTDIR ?= .
SRCS := api.c
all: $(OUTDIR)/libcmacs-api.so
$(OUTDIR)/libcmacs-api.so: $(SRCS) cmacs-api.h
\tcc -shared -o $@ $(SRCS)
")
    ("cmacs/api/api.c" 300 "")
    ("cmacs/api/cmacs-api.h" 300 "")
    ("cmacs/api/libcmacs-api.so" 100 "")
    ;; bacon modules, rebuilt when libcmacs-api.so moves.
    ("cmacs/bacon/modules/Makefile" 300 "API_DIR ?= ../../api
OUTDIR ?= .
$(OUTDIR)/cmacs_gi.so: gi.c $(API_DIR)/libcmacs-api.so
\tcc -shared -o $@ gi.c
")
    ("cmacs/bacon/modules/gi.c" 300 "")
    ("cmacs/bacon/modules/cmacs_gi.so" 90 "")
    ;; gowl: a module (rule from modules/dependencies.mk, as for real)
    ;; and the portal binary.
    ("deps/gowl/modules/dependencies.mk" 300
     "$(OUT): $(SRC) $(LIBDIR)/libgowl.so\n")
    ("deps/gowl/modules/foo/Makefile" 300 "OUTDIR ?= .
SRC = foo.c
OUT = $(OUTDIR)/foo.so
all: $(OUT)
$(OUT):
\tcc -shared -o $@ $(SRC)
")
    ("deps/gowl/modules/foo/foo.c" 300 "")
    ("deps/gowl/Makefile" 300 "build/release/libgowl.so: src/core.c
\tcc -shared -o $@ $<
build/release/xdg-desktop-portal-gowl: tools/portal/main.c
\tcc -o $@ $<
")
    ("deps/gowl/src/core.c" 300 "")
    ("deps/gowl/tools/portal/main.c" 300 "")
    ("deps/gowl/build/release/libgowl.so" 150 "")
    ("deps/gowl/build/release/xdg-desktop-portal-gowl" 100 "")
    ("deps/gowl/build/release/modules/foo.so" 100 "")
    ;; A Make-built dep whose objects come from a PATTERN rule and have
    ;; no .d file (libreclaw and gsurf are like this).
    ;; FLAVOUR comes only from src/Makefile's sub-make line: the object
    ;; it names exists only when the guard probes with cmacs's own
    ;; arguments.  The $(file >) is libregnum's parse-time .cflags stamp.
    ("deps/bacon/Makefile" 300 "STAMP := build/release/obj/.cflags
ifneq ($(file < $(STAMP)),$(FLAVOUR))
$(file > $(STAMP),$(FLAVOUR))
endif
build/release/libbacon.a: build/release/obj/$(FLAVOUR).o
\tar rcs $@ $^
build/release/obj/%.o: src/%.c
\tcc -c -o $@ $<
")
    ("deps/bacon/src/cmacs.c" 300 "")
    ("deps/bacon/build/release/obj/.cflags" 300 "cmacs")
    ("deps/bacon/build/release/obj/cmacs.o" 150 "")
    ("deps/bacon/build/release/libbacon.a" 100 "")
    ;; cmake: an archive, its CMakeFiles/<T>.dir object and .o.d.
    ("deps/whisper.cpp/build/CMakeCache.txt" 300 "")
    ("deps/whisper.cpp/include/whisper.h" 300 "")
    ("deps/whisper.cpp/build/src/CMakeFiles/whisper.dir/whisper.cpp.o.d" 300
     "src/CMakeFiles/whisper.dir/whisper.cpp.o: \\\n @ROOT@/deps/whisper.cpp/include/whisper.h\n")
    ("deps/whisper.cpp/build/src/CMakeFiles/whisper.dir/whisper.cpp.o" 150 "")
    ("deps/whisper.cpp/build/src/libwhisper.a" 100 "")
    ;; Lisp.  lisp/Makefile is the stand-in --fix rebuilds through.
    ("lisp/Makefile" 300 "%.elc: %.el\n\ttouch $@\n")
    ("lisp/cmacs/cmacs-foo.el" 300 "")
    ("lisp/cmacs/cmacs-foo.elc" 100 "")
    ;; Tests: compiled by src/emacs, which is a prerequisite too.
    ("test/cmacs/cmacs-foo-tests.el" 300 "")
    ("test/cmacs/cmacs-foo-tests.elc" 50 ""))
  "Scratch tree: (PATH AGE-IN-SECONDS CONTENT).  Every artifact is
younger than everything it is built from, so the tree is fresh.")

(defun cmacs-verify-fresh-tests--age (root path seconds)
  "Set the mtime of PATH under ROOT to SECONDS ago."
  (set-file-times (expand-file-name path root)
                  (time-subtract (current-time) seconds)))

(defun cmacs-verify-fresh-tests--make-tree ()
  "Create the fresh scratch tree; return its root."
  (let ((root (file-name-as-directory
               (file-truename (make-temp-file "cmacs-verify-fresh-" t)))))
    (dolist (entry cmacs-verify-fresh-tests--layout)
      (let ((file (expand-file-name (car entry) root)))
        (make-directory (file-name-directory file) t)
        (with-temp-file file
          (insert (string-replace "@ROOT@" (directory-file-name root)
                                  (nth 2 entry))))))
    (dolist (entry cmacs-verify-fresh-tests--layout)
      (cmacs-verify-fresh-tests--age root (car entry) (nth 1 entry)))
    root))

(defun cmacs-verify-fresh-tests--run (root &rest args)
  "Run the guard on ROOT with ARGS; return (EXIT-STATUS . OUTPUT)."
  (with-temp-buffer
    (let* ((process-environment
            (cl-remove-if (lambda (e)
                            (string-match-p
                             "\\`\\(CMACS_SKIP_FRESH_CHECK\\|CMACS_BUILD_LOCK\\|MAKEFLAGS\\|MAKELEVEL\\|MFLAGS\\)="
                             e))
                          process-environment))
           (status (apply #'call-process "bash" nil t nil
                          cmacs-verify-fresh-tests--script
                          "--root" root "--all" args)))
      (cons status (buffer-string)))))

(defmacro cmacs-verify-fresh-tests--with-tree (var &rest body)
  "Bind VAR to a fresh scratch tree around BODY; delete it after."
  (declare (indent 1))
  `(let ((,var (cmacs-verify-fresh-tests--make-tree)))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,var t))))

(defmacro cmacs-verify-fresh-tests--deftouch (name class source artifact)
  "Define a test: making SOURCE newer makes CLASS report ARTIFACT."
  `(ert-deftest ,(intern (format "cmacs-verify-fresh-test-%s" name)) ()
     ,(format "A newer %s makes `%s' stale (%s)." source artifact class)
     (skip-unless (and (executable-find "make") (executable-find "bash")))
     (cmacs-verify-fresh-tests--with-tree root
       (cmacs-verify-fresh-tests--age root ,source 1)
       (let ((res (cmacs-verify-fresh-tests--run root)))
         (should (= (car res) 1))
         (should (string-match-p
                  ,(format "^STALE %s: " (regexp-quote class)) (cdr res)))
         (should (string-match-p
                  ,(format "^    %s  (" (regexp-quote artifact)) (cdr res)))
         ;; Exactly one class failed.
         (should (string-match-p "in 1 class(es)" (cdr res)))))))

(ert-deftest cmacs-verify-fresh-test-fresh-tree-passes ()
  "Every class finds the fresh scratch tree fresh, and checks something."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (let ((res (cmacs-verify-fresh-tests--run root "--verbose")))
      (should (equal (car res) 0))
      (should (string-match-p "fresh (" (cdr res)))
      (dolist (class '("src-link" "api-so" "bacon-modules" "gowl-release"
                       "gowl-modules-release" "dep-bacon" "dep-whisper"
                       "lisp-elc" "test-elc"))
        (should (string-match-p
                 (format "^fresh %s: [1-9]" (regexp-quote class))
                 (cdr res)))))))

;; Through a .d file, transitively: a.c -> a.o -> temacs.
(cmacs-verify-fresh-tests--deftouch c-source "src-link" "src/a.c" "src/temacs")
;; A header named only by the compiler's .d file.
(cmacs-verify-fresh-tests--deftouch c-header "src-link" "src/a.h" "src/temacs")
;; An archive that is a link input but not a make prerequisite.
(cmacs-verify-fresh-tests--deftouch link-input "src-link" "deps/x/libx.a" "src/temacs")
;; temacs relinked, emacs not copied from it.
(cmacs-verify-fresh-tests--deftouch relink "src-link" "src/temacs" "src/emacs")
(cmacs-verify-fresh-tests--deftouch api-so "api-so" "cmacs/api/cmacs-api.h"
                                    "cmacs/api/libcmacs-api.so")
(cmacs-verify-fresh-tests--deftouch bacon-modules "bacon-modules"
                                    "cmacs/bacon/modules/gi.c"
                                    "cmacs/bacon/modules/cmacs_gi.so")
(cmacs-verify-fresh-tests--deftouch gowl-module "gowl-modules-release"
                                    "deps/gowl/modules/foo/foo.c"
                                    "deps/gowl/build/release/modules/foo.so")
(cmacs-verify-fresh-tests--deftouch gowl-module-abi "gowl-modules-release"
                                    "deps/gowl/build/release/libgowl.so"
                                    "deps/gowl/build/release/modules/foo.so")
(cmacs-verify-fresh-tests--deftouch gowl-portal "gowl-release"
                                    "deps/gowl/tools/portal/main.c"
                                    "deps/gowl/build/release/xdg-desktop-portal-gowl")
;; Pattern-rule object with no .d: src/x.c -> obj/x.o -> libbacon.a.
(cmacs-verify-fresh-tests--deftouch dep-pattern "dep-bacon" "deps/bacon/src/cmacs.c"
                                    "deps/bacon/build/release/libbacon.a")
(cmacs-verify-fresh-tests--deftouch cmake-header "dep-whisper"
                                    "deps/whisper.cpp/include/whisper.h"
                                    "deps/whisper.cpp/build/src/libwhisper.a")
(cmacs-verify-fresh-tests--deftouch cmake-object "dep-whisper"
                                    "deps/whisper.cpp/build/src/CMakeFiles/whisper.dir/whisper.cpp.o"
                                    "deps/whisper.cpp/build/src/libwhisper.a")
(cmacs-verify-fresh-tests--deftouch lisp-elc "lisp-elc" "lisp/cmacs/cmacs-foo.el"
                                    "lisp/cmacs/cmacs-foo.elc")

(ert-deftest cmacs-verify-fresh-test-elc-vs-byte-compiler ()
  "A rebuilt src/emacs makes test .elc stale -- a failure unless
test/Makefile carries the `## CMACS:' byte-compiler prerequisite, in
which case check-cmacs recompiles them and it is only a note."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (cmacs-verify-fresh-tests--age root "src/emacs" 1)
    (cmacs-verify-fresh-tests--age root "src/temacs" 2)
    (let ((res (cmacs-verify-fresh-tests--run root "--only" "test-elc")))
      (should (= (car res) 1))
      (should (string-match-p "^STALE test-elc: " (cdr res)))
      (should (string-match-p "older than src/emacs" (cdr res))))
    (with-temp-file (expand-file-name "test/Makefile" root)
      (insert "%.elc: %.el $(cmacs_byte_compiler)\n"))
    (let ((res (cmacs-verify-fresh-tests--run root "--only" "test-elc")))
      (should (= (car res) 0))
      (should (string-match-p "^note  test-elc: " (cdr res))))))

(ert-deftest cmacs-verify-fresh-test-noop-recipe-is-not-stale ()
  "globals.h older than gl-stamp is the move-if-change idiom, not
staleness: its `@true' recipe leaves it as it is and make rebuilds
nothing above it.  The fresh tree has exactly that shape."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (cmacs-verify-fresh-tests--age root "src/gl-stamp" 120)
    (let ((res (cmacs-verify-fresh-tests--run root "--only" "src-link")))
      (should (= (car res) 0)))))

(defun cmacs-verify-fresh-tests--snapshot (root)
  "Every file under ROOT with its mtime and size, sorted."
  (sort (mapcar (lambda (f)
                  (let ((a (file-attributes f)))
                    (list (file-relative-name f root)
                          (format-time-string "%s.%N"
                                              (file-attribute-modification-time a))
                          (file-attribute-size a))))
                (directory-files-recursively root "" nil))
        (lambda (x y) (string< (car x) (car y)))))

(ert-deftest cmacs-verify-fresh-test-plain-run-changes-nothing ()
  "A run without --fix leaves every file byte-for-byte as it was, even
when a probed makefile writes at parse time.  deps/bacon/Makefile does
`$(file > .cflags)' unless the stamp matches FLAVOUR; with the stamp
set to something else, every probe of it would rewrite the stamp --
which is how the guard once made cmacs recompile all of libregnum."
  (skip-unless (and (executable-find "make") (executable-find "bash")
                    (executable-find "bwrap")))
  (cmacs-verify-fresh-tests--with-tree root
    (with-temp-file (expand-file-name "deps/bacon/build/release/obj/.cflags"
                                      root)
      (insert "something-else"))
    (cmacs-verify-fresh-tests--age root "deps/bacon/build/release/obj/.cflags" 300)
    (let ((before (cmacs-verify-fresh-tests--snapshot root))
          (res (cmacs-verify-fresh-tests--run root)))
      (should-not (= (car res) 3))
      (should (equal before (cmacs-verify-fresh-tests--snapshot root)))
      (should (equal "something-else"
                     (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name "deps/bacon/build/release/obj/.cflags"
                                          root))
                       (buffer-string)))))))

(ert-deftest cmacs-verify-fresh-test-dep-fix-is-cmacs-build ()
  "The fix for a dep class is cmacs's own build, not a bare make in the
dep (which would build cmacs's build/<type> with the dep's defaults)."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (cmacs-verify-fresh-tests--age root "deps/bacon/src/cmacs.c" 1)
    (let ((res (cmacs-verify-fresh-tests--run root "--only" "dep-bacon")))
      ;; The replay of src/Makefile's own sub-make line (its cwd, its
      ;; arguments, its goal), then cmacs's top-level build to relink.
      (should (string-match-p
               (concat "^    fix (from the tree root): (R=\\$PWD && "
                       "cd \"\\$R\"/src && make "
                       "-j\"\\$(nproc)\" -C \\.\\./deps/bacon FLAVOUR=cmacs lib) "
                       "&& make -j\"\\$(nproc)\"$")
               (cdr res)))
      (should-not (string-match-p "make -C deps/" (cdr res))))))

(ert-deftest cmacs-verify-fresh-test-probe-builds-nothing ()
  "Reading a make database must not run a recipe, even one make wants
to run to remake an included makefile (which -q does not prevent)."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (let ((mk (expand-file-name "cmacs/api/Makefile" root)))
      (with-temp-file mk
        (insert "-include gen.mk\n-include stale.d\n"
                "gen.mk:\n\ttouch REMADE-gen\n"
                "stale.d: api.c\n\ttouch REMADE-d\n"
                "OUTDIR ?= .\n"
                "$(OUTDIR)/libcmacs-api.so: api.c cmacs-api.h\n"
                "\tcc -shared -o $@ api.c\n"))
      (cmacs-verify-fresh-tests--age root "cmacs/api/Makefile" 300)
      (with-temp-file (expand-file-name "cmacs/api/stale.d" root))
      (cmacs-verify-fresh-tests--age root "cmacs/api/stale.d" 400))
    (let ((res (cmacs-verify-fresh-tests--run root "--only" "api-so")))
      (should (= (car res) 0))
      (should-not (file-exists-p
                   (expand-file-name "cmacs/api/REMADE-gen" root)))
      (should-not (file-exists-p
                   (expand-file-name "cmacs/api/REMADE-d" root)))
      ;; And it says it refused, so the class can be given the -o.
      (should (string-match-p "refused a recipe" (cdr res))))))

(ert-deftest cmacs-verify-fresh-test-gate-escape-hatch ()
  "--gate fails a stale tree, and CMACS_SKIP_FRESH_CHECK=1 lets it pass."
  (skip-unless (and (executable-find "make") (executable-find "bash")))
  (cmacs-verify-fresh-tests--with-tree root
    (cmacs-verify-fresh-tests--age root "lisp/cmacs/cmacs-foo.el" 1)
    (let ((res (cmacs-verify-fresh-tests--run root "--gate")))
      (should (= (car res) 1))
      (should (string-match-p "CMACS_SKIP_FRESH_CHECK=1" (cdr res))))
    (let* ((process-environment
            (cons "CMACS_SKIP_FRESH_CHECK=1" process-environment))
           (status (call-process "bash" nil nil nil
                                 cmacs-verify-fresh-tests--script
                                 "--root" root "--gate" "--quiet")))
      (should (= status 0)))
    ;; Without --gate the variable is ignored: an explicit check checks.
    (let* ((process-environment
            (cons "CMACS_SKIP_FRESH_CHECK=1" process-environment))
           (status (call-process "bash" nil nil nil
                                 cmacs-verify-fresh-tests--script
                                 "--root" root "--quiet")))
      (should (= status 1)))))

(ert-deftest cmacs-verify-fresh-test-fix-under-lock ()
  "--fix runs the class's rebuild command under flock when
CMACS_BUILD_LOCK names a lock file, and leaves the tree fresh."
  (skip-unless (and (executable-find "make") (executable-find "bash")
                    (executable-find "flock")))
  (cmacs-verify-fresh-tests--with-tree root
    (cmacs-verify-fresh-tests--age root "lisp/cmacs/cmacs-foo.el" 1)
    (let* ((lock (expand-file-name "build.lock" root))
           (process-environment
            (cons (concat "CMACS_BUILD_LOCK=" lock) process-environment))
           (status (call-process "bash" nil nil nil
                                 cmacs-verify-fresh-tests--script
                                 "--root" root "--fix" "--quiet")))
      (should (= status 0))
      (should (file-exists-p lock)))
    (should (= (car (cmacs-verify-fresh-tests--run root)) 0))))

(ert-deftest cmacs-verify-fresh-test-shellcheck ()
  "The guard is ShellCheck-clean."
  (skip-unless (executable-find "shellcheck"))
  (should (= 0 (call-process "shellcheck" nil nil nil
                             cmacs-verify-fresh-tests--script))))

(provide 'cmacs-verify-fresh-tests)

;;; cmacs-verify-fresh-tests.el ends here
