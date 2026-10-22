;;; cmacs-podomation-tests.el --- Tests for podomation integration  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)

(ert-deftest cmacs-podomation-start-stop ()
  "Test engine lifecycle."
  (skip-unless (fboundp 'cmacs-podomation-start))
  (cmacs-podomation-start)
  (should (cmacs-podomation-running-p))
  (cmacs-podomation-stop)
  (should-not (cmacs-podomation-running-p)))

(ert-deftest cmacs-podomation-double-start ()
  "Starting twice should signal an error."
  (skip-unless (fboundp 'cmacs-podomation-start))
  (cmacs-podomation-start)
  (unwind-protect
      (should-error (cmacs-podomation-start)
                    :type 'cmacs-podomation-error)
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-load-dsl ()
  "Test DSL parsing."
  (skip-unless (fboundp 'cmacs-podomation-start))
  (cmacs-podomation-start)
  (unwind-protect
      (progn
        (cmacs-podomation-eval-dsl
         "pod test = timer->new(60000); test->on_tick => print->string(\"tick\");")
        (let ((pods (cmacs-podomation-list-pods)))
          (should (assoc "test" pods))))
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-list-modules ()
  "Test module listing includes cmacs built-in."
  (skip-unless (fboundp 'cmacs-podomation-start))
  (cmacs-podomation-start)
  (unwind-protect
      (let ((mods (cmacs-podomation-list-modules)))
        (should (member "cmacs" mods))
        (should (member "timer" mods)))
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-repl ()
  "Test REPL eval."
  (skip-unless (fboundp 'cmacs-podomation-repl-eval))
  (cmacs-podomation-start)
  (unwind-protect
      (let ((result (cmacs-podomation-repl-eval ":modules")))
        (should (consp result))
        (should (eq (car result) 'info)))
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-emit-event ()
  "Test event emission does not error."
  (skip-unless (fboundp 'cmacs-podomation-emit-event))
  (cmacs-podomation-start)
  (unwind-protect
      (should (cmacs-podomation-emit-event
               "on_buffer_save"
               '((buffer_name . "test.txt")
                 (file_name . "/tmp/test.txt"))))
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-stats ()
  "Test stats returns a plist."
  (skip-unless (fboundp 'cmacs-podomation-stats))
  (cmacs-podomation-start)
  (unwind-protect
      (let ((stats (cmacs-podomation-stats)))
        (should (plist-get stats :events-dispatched)))
    (cmacs-podomation-stop)))

(ert-deftest cmacs-podomation-context ()
  "Test setting engine context."
  (skip-unless (fboundp 'cmacs-podomation-set-context))
  (cmacs-podomation-start)
  (unwind-protect
      (should (cmacs-podomation-set-context
               '((user . "zach") (project . "cmacs"))))
    (cmacs-podomation-stop)))

(defvar cmacs-podomation-tests--ran nil
  "Set by the rule `cmacs-podomation-run-pod' fires.")

(ert-deftest cmacs-podomation-run-pod ()
  "A pod's rules run by name, as if its source had fired."
  (skip-unless (fboundp 'cmacs-podomation-run-pod))
  (should-error (cmacs-podomation-run-pod "ptest") :type 'cmacs-podomation-error)
  (cmacs-podomation-start)
  (unwind-protect
      (progn
        (setq cmacs-podomation-tests--ran nil)
        (cmacs-podomation-eval-dsl
         (concat "pod ptest = timer->new(3600000);"
                 " ptest->on_tick => cmacs->eval(\"(setq cmacs-podomation-tests--ran t)\");"))
        (should (equal (cmacs-podomation-pod-events "ptest") '("on_tick")))
        (should (equal (cmacs-podomation-run-pod "ptest") "on_tick"))
        ;; the cmacs module's eval handler may land on the next iteration
        (let ((deadline (+ (float-time) 10)))
          (while (and (not cmacs-podomation-tests--ran) (< (float-time) deadline))
            (accept-process-output nil 0.05)))
        (should cmacs-podomation-tests--ran)
        (should (equal (cmacs-podomation-run-pod "ptest" "on_tick"
                                                 '(("why" . "test")))
                       "on_tick"))
        (should-error (cmacs-podomation-run-pod "no-such-pod")
                      :type 'cmacs-podomation-error)
        (should-error (cmacs-podomation-pod-events "no-such-pod")
                      :type 'cmacs-podomation-error))
    (cmacs-podomation-stop)))

;;; cmacs-podomation-tests.el ends here
