;;; cmacs-bacon-tests.el --- Tests for bacon shell integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs bacon shell integration.
;; Tests cover shell start/stop lifecycle, command evaluation,
;; C block evaluation, alias get/set, completion, environment,
;; file sourcing, and running state predicates.

;;; Code:

(require 'ert)
(require 'cmacs)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Start/stop lifecycle tests

(ert-deftest cmacs-bacon-test-start ()
  "Test that `bacon-start' returns non-nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (should (bacon-start))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-start-idempotent ()
  "Test that starting an already-running shell returns non-nil without error."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should (bacon-start)))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-stop-returns-nil ()
  "Test that `bacon-stop' returns nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-start)
  (should-not (bacon-stop)))

(ert-deftest cmacs-bacon-test-stop-when-not-running ()
  "Test that stopping when not running is a no-op."
  (skip-unless (cmacs-feature-p 'bacon))
  ;; Ensure stopped state.
  (bacon-stop)
  (should-not (bacon-stop)))

;;; Running predicate tests

(ert-deftest cmacs-bacon-test-running-p-after-start ()
  "Test that `bacon-running-p' is non-nil after start."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should (bacon-running-p)))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-running-p-after-stop ()
  "Test that `bacon-running-p' is nil after stop."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-start)
  (bacon-stop)
  (should-not (bacon-running-p)))

(ert-deftest cmacs-bacon-test-running-p-initial ()
  "Test that `bacon-running-p' returns t or nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (let ((result (bacon-running-p)))
    (should (memq result '(t nil)))))

;;; Eval tests

(ert-deftest cmacs-bacon-test-eval-returns-exit-and-output ()
  "Test that `bacon-eval' returns a cons (EXIT-CODE . OUTPUT)."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval "true")))
          (should (consp rc))
          (should (integerp (car rc)))
          (should (= (car rc) 0))
          (should (stringp (cdr rc)))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-false ()
  "Test that `bacon-eval' of false reports a nonzero exit code."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval "false")))
          (should (consp rc))
          (should (integerp (car rc)))
          (should (/= (car rc) 0))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-requires-string ()
  "Test that `bacon-eval' rejects non-string command."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-eval 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-eval-auto-starts ()
  "Test that `bacon-eval' auto-starts the shell if not running."
  (skip-unless (cmacs-feature-p 'bacon))
  ;; Ensure stopped.
  (bacon-stop)
  (unwind-protect
      (progn
        (bacon-eval "true")
        (should (bacon-running-p)))
    (bacon-stop)))

;;; C block eval tests

(ert-deftest cmacs-bacon-test-eval-c-returns-exit-and-output ()
  "Test that `bacon-eval-c' returns a cons (EXIT-CODE . OUTPUT)."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval-c "int main(void) { return 0; }")))
          (should (consp rc))
          (should (integerp (car rc)))
          (should (stringp (cdr rc)))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-c-requires-string ()
  "Test that `bacon-eval-c' rejects non-string code."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-eval-c 42)
                :type 'wrong-type-argument))

;;; Alias tests

(ert-deftest cmacs-bacon-test-alias-set-and-get ()
  "Test setting and retrieving a bacon alias."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (bacon-alias "test-alias" "echo hello")
        (let ((val (bacon-alias "test-alias")))
          (should (equal val "echo hello"))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-alias-get-nonexistent ()
  "Test that getting a nonexistent alias returns nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should-not (bacon-alias "nonexistent-alias-xyz-12345")))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-alias-requires-string-name ()
  "Test that `bacon-alias' requires a string name."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-alias 42)
                :type 'wrong-type-argument))

;;; Completion tests

(ert-deftest cmacs-bacon-test-complete-returns-list ()
  "Test that `bacon-complete' returns a list."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((result (bacon-complete "ech")))
          (should (listp result))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-complete-requires-string ()
  "Test that `bacon-complete' requires a string prefix."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-complete 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-complete-no-shell ()
  "Test that `bacon-complete' returns nil when shell is not running."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-stop)
  (should-not (bacon-complete "anything")))

;;; Environment tests

(ert-deftest cmacs-bacon-test-environment-returns-list ()
  "Test that `bacon-environment' returns a list."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (bacon-eval "true")
        (let ((env (bacon-environment)))
          (should (listp env))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-environment-no-shell ()
  "Test that `bacon-environment' returns nil when shell is not running."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-stop)
  (should-not (bacon-environment)))

;;; Source tests

(ert-deftest cmacs-bacon-test-source-requires-string ()
  "Test that `bacon-source' requires a string file path."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-source 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-source-nonexistent-file ()
  "Test that `bacon-source' signals bacon-error for missing file."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should-error (bacon-source "/nonexistent/path/to/file.sh")
                      :type 'bacon-error))
    (bacon-stop)))

;; Edge cases
;; `bacon-eval' returns (RC . OUTPUT); the exit code is the car.
(ert-deftest cmacs-bacon-eval-empty-string ()
  "Evaluating empty string should return exit code 0."
  (skip-unless (fboundp 'bacon-eval))
  (should (= 0 (car (bacon-eval "")))))

(ert-deftest cmacs-bacon-eval-pipe ()
  "Pipe commands should execute."
  (skip-unless (fboundp 'bacon-eval))
  (should (integerp (car (bacon-eval "echo hello | cat")))))

(ert-deftest cmacs-bacon-eval-semicolons ()
  "Multiple commands separated by semicolons should work."
  (skip-unless (fboundp 'bacon-eval))
  (should (integerp (car (bacon-eval "true; true; true")))))

(ert-deftest cmacs-bacon-alias-overwrite ()
  "Setting an alias twice should overwrite the first."
  (skip-unless (fboundp 'bacon-alias))
  (bacon-start)
  (bacon-alias "test_alias_ow" "echo first")
  (bacon-alias "test_alias_ow" "echo second")
  (should (equal (bacon-alias "test_alias_ow") "echo second")))

(ert-deftest cmacs-bacon-source-nonexistent ()
  "Sourcing a nonexistent file should error."
  (skip-unless (fboundp 'bacon-source))
  (should-error (bacon-source "/nonexistent/file.bacon")))

(ert-deftest cmacs-bacon-start-stop-cycle ()
  "Starting and stopping multiple times should not leak."
  (skip-unless (and (fboundp 'bacon-start) (fboundp 'bacon-stop)))
  (dotimes (_ 3)
    (bacon-start)
    (should (bacon-running-p))
    (bacon-stop)
    (should-not (bacon-running-p))))

(ert-deftest cmacs-bacon-eval-c-type-check ()
  "bacon-eval-c requires a string."
  (skip-unless (fboundp 'bacon-eval-c))
  (should-error (bacon-eval-c 42))
  (should-error (bacon-eval-c nil)))


;;; IPC: the socketpair between the editor and its shell child

(ert-deftest cmacs-bacon-test-ipc-child-fd-is-released ()
  "The parent's copy of the child's socket end can be dropped.

`bacon-ipc-start' hands the child-side fd to the shell through the
environment; the parent kept its own copy of that fd for ever, so the
connection never read as closed when the shell exited and every start
leaked a descriptor.  `bacon-ipc-release-child-fd' closes it once the
child has forked."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'bacon-ipc-release-child-fd))
  (let ((fd (bacon-ipc-start)))
    (unwind-protect
        (let ((link (format "/proc/self/fd/%d" fd)))
          (should (file-symlink-p link))
          (should (eq t (bacon-ipc-release-child-fd)))
          (should-not (file-symlink-p link))
          (should (null (bacon-ipc-release-child-fd))))
      (bacon-ipc-stop))))

(defconst cmacs-bacon-tests--ipc-client "
import json, socket, struct, sys
fd = int(sys.argv[1])
s = socket.socket(fileno=fd)
s.settimeout(20)
req = json.dumps({'id': 7, 'method': 'Eval',
                  'params': {'expression': '(make-string 600000 ?x)'}}).encode()
s.sendall(struct.pack('>I', len(req)) + req)
def read_exact(n):
    buf = b''
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError('peer closed after %d of %d bytes' % (len(buf), n))
        buf += chunk
    return buf
try:
    (n,) = struct.unpack('>I', read_exact(4))
    body = json.loads(read_exact(n))
    print('OK', len(body['result']))
except Exception as e:
    print('FAIL', type(e).__name__, e)
"
  "A synchronous IPC client, run in a child that inherits the child fd.")

(ert-deftest cmacs-bacon-test-ipc-reply-larger-than-the-socket-buffer ()
  "A reply bigger than the socket buffer arrives whole.

The parent's fd is non-blocking so reading never stalls the editor,
but the reply writer treated EAGAIN as a failure: a reply larger than
the kernel buffer went out truncated, the child read a length prefix
promising bytes that never came, and every later frame was misread.
The writer now waits for the socket to drain.  A 600 kB answer is
asked for by a separate process that inherits the child end, as the
shell does, and reads until the promised length arrives."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'bacon-ipc-release-child-fd))
  (skip-unless (executable-find "python3"))
  (let* ((fd (bacon-ipc-start))
         (buf (generate-new-buffer " *bacon-ipc-client*"))
         proc)
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "bacon-ipc-client"
                      :command (list "python3" "-c"
                                     cmacs-bacon-tests--ipc-client
                                     (number-to-string fd))
                      :buffer buf
                      :noquery t))
          ;; The child has the fd now; our copy would only keep the
          ;; connection open after it exits.
          (bacon-ipc-release-child-fd)
          (let ((deadline (+ (float-time) 30.0)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)
              (sit-for 0.05)))
          (should-not (process-live-p proc))
          (let ((out (with-current-buffer buf (buffer-string))))
            ;; prin1 of the string: 600000 x's plus the two quotes.
            (should (string-match-p "^OK 600002" out))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (kill-buffer buf)
      (bacon-ipc-stop))))

(ert-deftest cmacs-bacon-test-cmacsgi-quotes-a-bare-letter ()
  "A cmacsgi argument that is a lone letter is a string, not a symbol.

The quoting heuristic passed anything made only of digits, signs, dots
and the letter e through unquoted as a number -- which made the single
word \"e\" a symbol, and `void-variable e' the answer to any command
that took it.  A number now needs a digit in it."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (cmacs-feature-p 'gi))
  (skip-unless (= 0 (car (bacon-eval "cmacsgi --help"))))
  (gi-require "GLib" "2.0")
  (let ((rc (bacon-eval "cmacsgi call GLib utf8_strup e -1")))
    (should (= 0 (car rc)))
    (should (string-match-p "\"E\"" (cdr rc)))))

(provide 'cmacs-bacon-tests)
;;; cmacs-bacon-tests.el ends here
