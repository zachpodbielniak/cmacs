;;; cmacs-perf-vm.el --- cmacs-perf: Lisp VM workloads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; Copyright (C) 2026 Eval Exec and the neomacs contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The evaluator's hot paths in isolation: bytecode function calls,
;; lexical and dynamic variable access, and calls from bytecode into
;; C primitives.  Ported from neomacs-perf's bytecode-call-loop.el,
;; vm-loop.el and builtin-call.el (GPL-3.0-or-later); the workloads and
;; their invariants are theirs, the registration form is cmacs-perf's.
;;
;; The driver byte-compiles this file before the run (or native-compiles
;; it with --native), and every CHECK refuses a run whose loop was not
;; compiled, because an interpreted loop measures a different engine.

;;; Code:

(require 'cmacs-perf)

;;;; bytecode-call-loop: one bytecode-to-bytecode call per iteration.

(defun cmacs-perf-vm--identity (value)
  "Return VALUE.  The callee of `cmacs-perf-vm--call-loop'."
  value)

(defun cmacs-perf-vm--call-loop (iterations)
  "Call `cmacs-perf-vm--identity' ITERATIONS times; return the last value."
  (let ((last-value nil))
    (while (> iterations 0)
      (setq last-value (cmacs-perf-vm--identity iterations)
            iterations (1- iterations)))
    last-value))

(cmacs-perf-define
 "bytecode-call-loop"
 :doc "bytecode function calling a bytecode function, N times"
 :iterations 20000000
 :budget 5
 :setup (lambda (_iterations)
          ;; Warm the instruction and data caches outside the window.
          (cmacs-perf-vm--call-loop 1000))
 :body (lambda (_state iterations)
         `((result . ,(cmacs-perf-vm--call-loop iterations))))
 :check (lambda (_state metrics)
          (let ((failures nil))
            (unless (cmacs-perf-compiled-p 'cmacs-perf-vm--identity
                                           'cmacs-perf-vm--call-loop)
              (push "call loop is not compiled" failures))
            (cmacs-perf-expect failures "loop result"
                               (alist-get 'result metrics) 1))))

;;;; vm-loop family: variable access in a counted loop.

(defvar cmacs-perf-vm--special 17
  "A special variable the dynamic loops bind, read and rebind.")

(defvar cmacs-perf-vm--alias)
;; The alias is made at run time (`cmacs-perf-vm--make-alias'), never
;; with a literal `defvaralias' here: the byte compiler rejects an alias
;; declared after its referent, and the bytecode has to keep reading the
;; ALIAS symbol -- the indirection is the thing being measured.

(defun cmacs-perf-vm--make-alias ()
  "Make `cmacs-perf-vm--alias' an alias of `cmacs-perf-vm--special'.
The name is interned at run time so the compiler never sees a constant
`defvaralias' form."
  (defvaralias (intern "cmacs-perf-vm--alias") 'cmacs-perf-vm--special))

(defun cmacs-perf-vm--lexical (iterations)
  "Sum 0..ITERATIONS-1 over lexical variables only."
  (let ((held 7) (i 0) (sum 0))
    (while (< i iterations)
      (setq sum (+ sum i) i (1+ i)))
    (list i sum held)))

(defun cmacs-perf-vm--dynamic (iterations)
  "Like `cmacs-perf-vm--lexical' with the special variable bound once."
  (let ((cmacs-perf-vm--special 7) (i 0) (sum 0))
    (while (< i iterations)
      (setq sum (+ sum i) i (1+ i)))
    (list i sum cmacs-perf-vm--special)))

(defun cmacs-perf-vm--dynamic-read (iterations)
  "Read the dynamically bound special variable on every iteration."
  (let ((cmacs-perf-vm--special 7) (i 0) (sum 0))
    (while (< i iterations)
      (setq sum (+ sum cmacs-perf-vm--special) i (1+ i)))
    (list i sum cmacs-perf-vm--special)))

(defun cmacs-perf-vm--dynamic-rebind (iterations)
  "Rebind the special variable (specbind + unbind) on every iteration."
  (let ((cmacs-perf-vm--special 7) (i 0) (sum 0))
    (while (< i iterations)
      (let ((cmacs-perf-vm--special i))
        (setq sum (+ sum cmacs-perf-vm--special)))
      (setq i (1+ i)))
    (list i sum cmacs-perf-vm--special)))

(defun cmacs-perf-vm--alias-read (iterations)
  "Read the special variable through a `defvaralias' on every iteration."
  (let ((cmacs-perf-vm--special 7) (i 0) (sum 0))
    (while (< i iterations)
      (setq sum (+ sum cmacs-perf-vm--alias) i (1+ i)))
    (list i sum cmacs-perf-vm--special)))

(defun cmacs-perf-vm--define-loop (name doc function per-iteration
                                        &optional buffer-local)
  "Register vm-loop workload NAME running FUNCTION.
PER-ITERATION is what one iteration adds to the sum: nil means the
loop index itself (sum of 0..N-1), a number means that constant.  With
BUFFER-LOCAL, the special variable is made buffer-local first, so every
read goes through the buffer-local lookup path."
  (cmacs-perf-define
   name
   :doc doc
   :iterations 10000000
   :setup (lambda (_iterations)
            (when buffer-local
              (make-local-variable 'cmacs-perf-vm--special))
            (when (eq function #'cmacs-perf-vm--alias-read)
              (cmacs-perf-vm--make-alias))
            ;; One short call warms the startup paths.
            (funcall function 100)
            (list :outer-before cmacs-perf-vm--special
                  :global-before (default-value 'cmacs-perf-vm--special)))
   :body (lambda (_state iterations)
           (let ((result (funcall function iterations)))
             `((completed . ,(nth 0 result))
               (sum . ,(nth 1 result))
               (held . ,(nth 2 result)))))
   :check (lambda (state metrics)
            (let* ((n (alist-get 'completed metrics))
                   (expected-sum (if per-iteration
                                     (* n per-iteration)
                                   (/ (* n (1- n)) 2)))
                   (failures nil))
              (unless (cmacs-perf-compiled-p function)
                (push (format "%s is not compiled" function) failures))
              (when (and buffer-local
                         (not (local-variable-p 'cmacs-perf-vm--special)))
                (push "special variable is not buffer-local" failures))
              (setq failures (cmacs-perf-expect failures "sum"
                                                (alist-get 'sum metrics)
                                                expected-sum))
              ;; The binding must be undone on exit, everywhere.
              (setq failures (cmacs-perf-expect
                              failures "outer value after the loop"
                              cmacs-perf-vm--special
                              (plist-get state :outer-before)))
              (cmacs-perf-expect failures "global value after the loop"
                                 (default-value 'cmacs-perf-vm--special)
                                 (plist-get state :global-before))))))

(cmacs-perf-vm--define-loop
 "lexical-loop" "counted loop over lexical variables"
 #'cmacs-perf-vm--lexical nil)
(cmacs-perf-vm--define-loop
 "dynamic-binding-loop" "counted loop inside one dynamic binding"
 #'cmacs-perf-vm--dynamic nil)
(cmacs-perf-vm--define-loop
 "dynamic-variable-read-loop" "read a dynamically bound variable per step"
 #'cmacs-perf-vm--dynamic-read 7)
(cmacs-perf-vm--define-loop
 "dynamic-rebinding-loop" "specbind and unbind a variable per step"
 #'cmacs-perf-vm--dynamic-rebind nil)
(cmacs-perf-vm--define-loop
 "dynamic-alias-read-loop" "read a variable through a defvaralias per step"
 #'cmacs-perf-vm--alias-read 7)
(cmacs-perf-vm--define-loop
 "buffer-local-read-loop" "read a buffer-local variable per step"
 #'cmacs-perf-vm--dynamic-read 7 t)

;;;; builtin-call family: bytecode calling a C primitive.

;; Calling through an alias keeps the byte compiler from turning these
;; calls into dedicated opcodes (`point', `max-char' and friends have
;; one), so every iteration pays a real funcall into a DEFUN.
(defalias 'cmacs-perf-vm--call-zero (symbol-function 'point))
(defalias 'cmacs-perf-vm--call-one (symbol-function 'string-bytes))
(defalias 'cmacs-perf-vm--call-two (symbol-function 'string-lessp))
(defalias 'cmacs-perf-vm--call-three (symbol-function 'get-text-property))
(defalias 'cmacs-perf-vm--call-multibyte (symbol-function 'multibyte-string-p))
(defalias 'cmacs-perf-vm--call-character (symbol-function 'char-or-string-p))
(defalias 'cmacs-perf-vm--call-max-char (symbol-function 'max-char))

(defun cmacs-perf-vm--builtin-zero (n)
  "Call a zero-argument primitive N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-zero)))
    answer))

(defun cmacs-perf-vm--builtin-one (n)
  "Call a one-argument primitive N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-one "abc")))
    answer))

(defun cmacs-perf-vm--builtin-two (n)
  "Call a two-argument primitive N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-two "abc" "def")))
    answer))

(defun cmacs-perf-vm--builtin-three (n)
  "Call a three-argument primitive N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-three 0 'face "abc")))
    answer))

(defun cmacs-perf-vm--builtin-multibyte (n)
  "Call `multibyte-string-p' on a multibyte string N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-multibyte "Aé中")))
    answer))

(defun cmacs-perf-vm--builtin-character (n)
  "Call `char-or-string-p' on the largest character N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-character #x3fffff)))
    answer))

(defun cmacs-perf-vm--builtin-max-char (n)
  "Call `max-char' with an argument N times."
  (let ((answer nil))
    (dotimes (_ n) (setq answer (cmacs-perf-vm--call-max-char t)))
    answer))

(defun cmacs-perf-vm--bytecode-calls-p (function alias)
  "Return non-nil when FUNCTION's bytecode still calls ALIAS by name.
Native-compiled code has no constant vector to inspect, so it passes."
  (let ((definition (symbol-function function)))
    (or (not (byte-code-function-p definition))
        (memq alias (append (aref definition 2) nil)))))

(dolist (case '(("builtin-call-point" cmacs-perf-vm--builtin-zero
                 cmacs-perf-vm--call-zero 1)
                ("builtin-call-string-bytes" cmacs-perf-vm--builtin-one
                 cmacs-perf-vm--call-one 3)
                ("builtin-call-string-lessp" cmacs-perf-vm--builtin-two
                 cmacs-perf-vm--call-two t)
                ("builtin-call-get-text-property" cmacs-perf-vm--builtin-three
                 cmacs-perf-vm--call-three nil)
                ("builtin-call-multibyte-string-p"
                 cmacs-perf-vm--builtin-multibyte
                 cmacs-perf-vm--call-multibyte t)
                ("builtin-call-char-or-string-p"
                 cmacs-perf-vm--builtin-character
                 cmacs-perf-vm--call-character t)
                ("builtin-call-max-char" cmacs-perf-vm--builtin-max-char
                 cmacs-perf-vm--call-max-char #x10ffff)))
  (pcase-let ((`(,name ,function ,alias ,expected) case))
    (cmacs-perf-define
     name
     :doc (format "bytecode calling the primitive `%s'"
                  (subr-name (symbol-function alias)))
     :iterations 5000000
     :setup (lambda (_iterations)
              ;; 40 x 2,000 warm calls, each checked, outside the window.
              ;; The buffer is the current one, empty under -Q batch, so
              ;; `point' answers 1.
              (dotimes (_ 40)
                (let ((value (funcall function 2000)))
                  (unless (equal value expected)
                    (error "warm-up of %s returned %S" name value)))))
     :body (lambda (_state iterations)
             `((result . ,(prin1-to-string (funcall function iterations)))))
     :check (lambda (_state metrics)
              (let ((failures nil))
                (unless (cmacs-perf-compiled-p function)
                  (push (format "%s is not compiled" function) failures))
                (unless (cmacs-perf-vm--bytecode-calls-p function alias)
                  (push (format "%s no longer calls %s" function alias)
                        failures))
                (cmacs-perf-expect failures "result"
                                   (alist-get 'result metrics)
                                   (prin1-to-string expected)))))))

(provide 'cmacs-perf-vm)

;;; cmacs-perf-vm.el ends here
