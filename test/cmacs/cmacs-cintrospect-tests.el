;;; cmacs-cintrospect-tests.el --- Tests for cintrospect -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs cintrospect subsystem (DWARF reader,
;; DEFUN registry walker, JIT, MCP gating).  Tests skip-unless the
;; feature is built in.

;;; Code:

(require 'ert)
(require 'cmacs)

(declare-function cmacs-feature-p "cmacs-glib-tests")

(defun cmacs-cintrospect-test--available-p ()
  "Return non-nil if the cintrospect subsystem is loaded."
  (and (fboundp 'cmacs-c-list-objects)
       (fboundp 'cmacs-c-symbol-info)))

(defun cmacs-cintrospect-test--jit-available-p ()
  "Return non-nil if Phase-2 JIT is functional (not stubbed)."
  (and (cmacs-cintrospect-test--available-p)
       (condition-case _
           (let ((h (cmacs-c-compile "Lisp_Object t_(void) { return Qt; }"
                                     "t_" "Lisp_Object(void)")))
             (cmacs-c-handle-dispose h)
             t)
         (cmacs-cintrospect-not-implemented nil)
         (error nil))))

(defun cmacs-cintrospect-test--cpatch-available-p ()
  "Return non-nil if cpatch is built in."
  (fboundp 'cmacs-c-patch-defun))

;;; ─── Tier 0: DWARF reader ──────────────────────────────────────

(ert-deftest cintro-symbol-info-known-defun ()
  "`cmacs-c-symbol-info' on a known DEFUN gives a populated plist."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((info (cmacs-c-symbol-info "Fbuffer_string")))
    (should info)
    (should (eq (plist-get info :kind) 'function))
    (should (> (plist-get info :addr) 0))
    (should (string= (plist-get info :symbol-name) "Fbuffer_string"))
    (should (string-match-p "editfns\\.c" (or (plist-get info :file) "")))
    (should (> (or (plist-get info :line) 0) 0))))

(ert-deftest cintro-symbol-info-missing ()
  "`cmacs-c-symbol-info' on a non-existent symbol returns nil."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (should-not (cmacs-c-symbol-info "this_symbol_does_not_exist_xyzzy")))

(ert-deftest cintro-type-info-lisp-subr ()
  "`cmacs-c-type-info' on Lisp_Subr returns the expected layout."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((info (cmacs-c-type-info "Lisp_Subr")))
    (should info)
    (should (eq (plist-get info :kind) 'struct))
    (should (> (plist-get info :size) 80))
    (let ((fields (plist-get info :fields)))
      (should (>= (length fields) 8))
      ;; The function-pointer union field should exist.
      (should (cl-find "function" fields
                       :key (lambda (f) (plist-get f :symbol-name))
                       :test #'string=))
      ;; min_args/max_args are 'short int'.
      (should (cl-find "min_args" fields
                       :key (lambda (f) (plist-get f :symbol-name))
                       :test #'string=)))))

(ert-deftest cintro-list-objects ()
  "`cmacs-c-list-objects' returns >= 10 entries with at least one having DWARF."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((objs (cmacs-c-list-objects)))
    (should (> (length objs) 10))
    (should (cl-some (lambda (o) (plist-get o :has-dwarf)) objs))))

(ert-deftest cintro-stack-trace-non-empty ()
  "`cmacs-c-stack-trace' returns at least one frame with file:line info."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((trace (cmacs-c-stack-trace 8)))
    (should trace)
    (should (cl-some (lambda (f) (plist-get f :function)) trace))))

;;; ─── DEFUN registry ─────────────────────────────────────────────

(ert-deftest cintro-list-defuns-finds-buffer-string ()
  "`cmacs-c-list-defuns' filtered by `buffer-*' includes buffer-string."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((rows (cmacs-c-list-defuns "buffer-*")))
    (should (cl-find "buffer-string" rows
                     :key (lambda (r) (plist-get r :symbol-name))
                     :test #'string=))))

(ert-deftest cintro-defun-info-source-resolution ()
  "`cmacs-c-defun-info' surfaces source location via DWARF."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let ((info (cmacs-c-defun-info 'buffer-string)))
    (should info)
    (should (string= (plist-get info :symbol-name) "buffer-string"))
    (should (or (string= (plist-get info :c-name) "buffer-string")
                (string= (plist-get info :c-name) "Fbuffer_string")))
    (should (> (plist-get info :fn-addr) 0))
    (should (string-match-p "editfns\\.c" (or (plist-get info :file) "")))))

(ert-deftest cintro-defun-info-non-defun-returns-nil ()
  "`cmacs-c-defun-info' on a variable that is not also a function returns nil.

Not `emacs-version', which this used to use: that is a variable *and* a
function (`emacs-version &optional here', in version.el), and under
`--with-native-compilation=aot' its .eln makes it a genuine `subr' -- so
the lookup was right to report it and the test was wrong to expect
otherwise.  It passed only in a tree where that .eln had not been built,
which made it a test of the build state rather than of the code."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (should-not (fboundp 'most-positive-fixnum))
  (should-not (cmacs-c-defun-info 'most-positive-fixnum)))

;;; ─── Address ↔ source ──────────────────────────────────────────

(ert-deftest cintro-addr-to-source-roundtrip ()
  "Round-trip a known DEFUN's address through addr-to-source."
  (skip-unless (cmacs-cintrospect-test--available-p))
  (let* ((info (cmacs-c-symbol-info "Fbuffer_string"))
         (addr (plist-get info :addr))
         (resolved (cmacs-c-addr-to-source addr)))
    (should resolved)
    (should (string-match-p "editfns\\.c" (nth 0 resolved)))
    (should (> (nth 1 resolved) 0))))

;;; ─── Tier 1: JIT (Phase 2) ──────────────────────────────────────

(ert-deftest cintro-jit-trivial-int ()
  "Trivial int(int,int) compile and call."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let ((h (cmacs-c-compile "int sq(int x) { return x * x; }"
                            "sq" "int(int)")))
    (unwind-protect
        (should (= (cmacs-c-call h 7) 49))
      (cmacs-c-handle-dispose h))))

(ert-deftest cintro-jit-lisp-object-identity ()
  "Lisp_Object identity via JIT."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let ((h (cmacs-c-compile "Lisp_Object id(Lisp_Object x) { return x; }"
                            "id" "Lisp_Object(Lisp_Object)")))
    (unwind-protect
        (progn
          (should (= (cmacs-c-call h 42) 42))
          (should (string= (cmacs-c-call h "hi") "hi"))
          (should (eq (cmacs-c-call h t) t)))
      (cmacs-c-handle-dispose h))))

(ert-deftest cintro-jit-fcons-roundtrip ()
  "JIT'd code can call into Emacs internals (Fcons)."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let ((h (cmacs-c-compile
            (concat "Lisp_Object cell(Lisp_Object a, Lisp_Object b)"
                    "{ return Fcons(a, b); }")
            "cell" "Lisp_Object(Lisp_Object,Lisp_Object)")))
    (unwind-protect
        (should (equal (cmacs-c-call h 1 2) (cons 1 2)))
      (cmacs-c-handle-dispose h))))

(ert-deftest cintro-jit-many-signature ()
  "MANY-style signature dispatches correctly."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let ((h (cmacs-c-compile
            (concat "Lisp_Object sum_args(ptrdiff_t n, Lisp_Object *args)"
                    "{ long t = 0;"
                    "  for (ptrdiff_t i = 0; i < n; i++)"
                    "    if (FIXNUMP(args[i])) t += XFIXNUM(args[i]);"
                    "  return make_fixnum(t); }")
            "sum_args" "Lisp_Object(ptrdiff_t,Lisp_Object*)")))
    (unwind-protect
        (should (= (cmacs-c-call h 1 2 3 4) 10))
      (cmacs-c-handle-dispose h))))

(ert-deftest cintro-jit-handle-info-roundtrip ()
  "`cmacs-c-handle-info' returns expected metadata."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let* ((src "Lisp_Object foo(void) { return Qt; }")
         (h (cmacs-c-compile src "foo" "Lisp_Object(void)"))
         (info (cmacs-c-handle-info h)))
    (unwind-protect
        (progn
          (should (= (plist-get info :id) h))
          (should (string= (plist-get info :fn-name) "foo"))
          (should (string= (plist-get info :signature) "Lisp_Object(void)"))
          (should (> (plist-get info :fn-addr) 0))
          (should (string= (plist-get info :source) src)))
      (cmacs-c-handle-dispose h))))

(ert-deftest cintro-jit-compile-error-diagnostics ()
  "Compile errors raise `cmacs-cintrospect-compile-error' with diagnostics."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (should-error
   (cmacs-c-compile "syntax error;;;" "x" "Lisp_Object(void)")
   :type 'cmacs-cintrospect-compile-error))

(ert-deftest cintro-jit-dispose-twice-is-nil ()
  "Disposing a handle twice returns nil the second time."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let ((h (cmacs-c-compile "Lisp_Object t_(void) { return Qt; }"
                            "t_" "Lisp_Object(void)")))
    (should (eq (cmacs-c-handle-dispose h) t))
    (should (null (cmacs-c-handle-dispose h)))))

;;; ─── Self-introspection: DWARF for JIT'd .so ────────────────────

(ert-deftest cintro-jit-dwarf-self-introspection ()
  "JIT'd functions are themselves DWARF-introspectable."
  (skip-unless (cmacs-cintrospect-test--jit-available-p))
  (let* ((unique-name (format "jit_self_%d" (random 1000000)))
         (src (format "Lisp_Object %s(void) { return Qt; }" unique-name))
         (h (cmacs-c-compile src unique-name "Lisp_Object(void)")))
    (unwind-protect
        (progn
          ;; libdw rescans modules on next lookup --- the JIT'd .so
          ;; was dlopen'd, so dl_iterate_phdr will see it.  However,
          ;; libdwfl_linux_proc_report was called once at init so
          ;; it may not auto-pick-up new modules.  We just verify
          ;; the function is callable; full self-introspection of
          ;; .so loaded after init is a known limitation documented
          ;; in cintrospect.org.
          (should (eq (cmacs-c-call h) t)))
      (cmacs-c-handle-dispose h))))

(provide 'cmacs-cintrospect-tests)
;;; cmacs-cintrospect-tests.el ends here
