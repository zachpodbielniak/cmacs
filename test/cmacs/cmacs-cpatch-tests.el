;;; cmacs-cpatch-tests.el --- Tests for cpatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs cpatch (runtime C hot-patching) subsystem.
;; Tests skip-unless cpatch was built in.  They use cintrospect's
;; JIT to compile real replacement functions and verify that calls
;; observe the patched behaviour.

;;; Code:

(require 'ert)

(defun cmacs-cpatch-test--available-p ()
  "Return non-nil when cpatch + JIT are both functional."
  (and (fboundp 'cmacs-c-patch-defun)
       (condition-case _
           (let ((h (cmacs-c-compile "Lisp_Object t_(void) { return Qt; }"
                                     "t_" "Lisp_Object(void)")))
             (cmacs-c-handle-dispose h)
             t)
         (cmacs-cintrospect-not-implemented nil)
         (error nil))))

;;; ─── DEFUN-pointer swap ────────────────────────────────────────

(ert-deftest cpatch-defun-swap-and-restore ()
  "Patch a DEFUN, observe the change, unpatch, observe restore."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((replacement-src
          (concat "Lisp_Object my_time(Lisp_Object spec, Lisp_Object zone)"
                  "{ (void)spec; (void)zone;"
                  "  return build_string(\"PATCHED\"); }"))
         (h (cmacs-c-compile replacement-src "my_time"
                             "Lisp_Object(Lisp_Object,Lisp_Object)"))
         (info (cmacs-c-handle-info h))
         (addr (plist-get info :fn-addr))
         (orig (current-time-string)))
    (unwind-protect
        (progn
          (cmacs-c-patch-defun 'current-time-string addr)
          (should (string= (current-time-string) "PATCHED"))
          (cmacs-c-unpatch-defun 'current-time-string)
          ;; After restore, current-time-string returns a real time
          ;; string of the form "Day Mon  D HH:MM:SS YYYY".
          (let ((after (current-time-string)))
            (should-not (string= after "PATCHED"))
            (should (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
                                    after))))
      (cmacs-c-handle-dispose h)
      ;; Defensive: ensure no patches leak.
      (cmacs-c-unpatch-all))
    ;; Reference unused binding to silence -Wunused.
    (ignore orig)))

(ert-deftest cpatch-patch-list-shape ()
  "`cmacs-c-patch-list' surfaces :kind / :symbol after a patch."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((info (cmacs-c-defun-info 'buffer-name))
         (addr (plist-get info :fn-addr)))
    (unwind-protect
        (progn
          (cmacs-c-patch-defun 'buffer-name addr)
          (let* ((patches (cmacs-c-patch-list))
                 (entry (car patches)))
            (should patches)
            (should (eq (plist-get entry :kind) 'defun-swap))
            (should (eq (plist-get entry :symbol) 'buffer-name))
            (should (= (plist-get entry :original-addr) addr))
            (should (= (plist-get entry :patched-addr) addr))))
      (cmacs-c-unpatch-all))))

(ert-deftest cpatch-unpatch-all-counts ()
  "`cmacs-c-unpatch-all' returns the number of patches restored."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((a (plist-get (cmacs-c-defun-info 'buffer-name) :fn-addr))
         (b (plist-get (cmacs-c-defun-info 'point-marker) :fn-addr)))
    (cmacs-c-patch-defun 'buffer-name a)
    (cmacs-c-patch-defun 'point-marker b)
    (should (= (length (cmacs-c-patch-list)) 2))
    (should (= (cmacs-c-unpatch-all) 2))
    (should (null (cmacs-c-patch-list)))))

;;; ─── Trampoline detour (Phase 3) ───────────────────────────────

(ert-deftest cpatch-detour-install-uninstall-roundtrip ()
  "Install + uninstall a trampoline detour without crashing."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((target-name "cmacs_cintrospect_function_address")
         (h (cmacs-c-compile
             "void *my_repl(const char *n) { (void)n; return (void *)0; }"
             "my_repl" "Lisp_Object(Lisp_Object)"))
         (addr (plist-get (cmacs-c-handle-info h) :fn-addr)))
    (unwind-protect
        (progn
          (should (eq (cmacs-c-patch-function target-name addr) t))
          (let* ((entry (car (cmacs-c-patch-list))))
            (should (eq (plist-get entry :kind) 'detour))
            (should (string= (plist-get entry :symbol) target-name))
            (should (= (plist-get entry :replacement-addr) addr)))
          (should (eq (cmacs-c-unpatch-function target-name) t))
          (should (null (cmacs-c-patch-list))))
      (cmacs-c-handle-dispose h)
      (cmacs-c-unpatch-all))))

(ert-deftest cpatch-detour-double-install-rejected ()
  "Patching the same target twice errors."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((target-name "cmacs_cintrospect_function_address")
         (h (cmacs-c-compile
             "void *my_repl2(const char *n) { (void)n; return (void *)0; }"
             "my_repl2" "Lisp_Object(Lisp_Object)"))
         (addr (plist-get (cmacs-c-handle-info h) :fn-addr)))
    (unwind-protect
        (progn
          (cmacs-c-patch-function target-name addr)
          (should-error (cmacs-c-patch-function target-name addr)))
      (cmacs-c-unpatch-function target-name)
      (cmacs-c-handle-dispose h))))

(ert-deftest cpatch-diff-preview-format ()
  "`cmacs-c-patch-diff' produces a multi-line readable string."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((target-name "cmacs_cintrospect_function_address")
         (h (cmacs-c-compile "Lisp_Object q(void) { return Qt; }"
                             "q" "Lisp_Object(void)"))
         (addr (plist-get (cmacs-c-handle-info h) :fn-addr)))
    (unwind-protect
        (let ((diff (cmacs-c-patch-diff target-name addr)))
          (should (stringp diff))
          (should (string-match-p "current bytes" diff))
          (should (string-match-p "new bytes" diff))
          (should (string-match-p "48 b8" diff))) ;; mov rax, imm64
      (cmacs-c-handle-dispose h))))

(ert-deftest cpatch-diff-defun-form ()
  "`cmacs-c-patch-diff' on a symbol returns the DEFUN-swap explanation."
  (skip-unless (cmacs-cpatch-test--available-p))
  (let* ((info (cmacs-c-defun-info 'buffer-name))
         (addr (plist-get info :fn-addr))
         (diff (cmacs-c-patch-diff 'buffer-name addr)))
    (should (string-match-p "DEFUN swap" diff))))

(provide 'cmacs-cpatch-tests)
;;; cmacs-cpatch-tests.el ends here
