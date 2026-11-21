;;; cmacs-brigade-call-errors-tests.el --- A bad call is not a bad definition  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A caller that left out a required argument was told "Invalid brigade
;; tool definition: list_buffers: missing required argument `buffer'":
;; the argument check in cmacs-brigade-tools.el signalled
;; `cmacs-brigade-tool-error', whose message is about DEFINITIONS.  A
;; model reading that looks for a fault in the tool and not in its own
;; call.
;;
;; The contract held here: a mistake in a CALL (a required argument
;; missing, arguments that are not JSON) signals
;; `cmacs-brigade-tool-call-error', whose text names the tool and the
;; argument and never says "definition"; a mistake in a DEFINITION still
;; signals `cmacs-brigade-tool-error'.  The two are siblings under
;; `cmacs-brigade-error', so neither handler catches the other's.
;;
;; These call the registry's dispatch in-process.  The wire (MCP, D-Bus)
;; carries the same string and is not exercised here.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'cmacs-brigade-registry nil t)
(require 'cmacs-brigade-tools nil t)

(defvar cmacs-brigade--registries)
(defvar cmacs-brigade-tool-registered-functions)
(defvar cmacs-brigade-before-tool-call-functions)
(defvar cmacs-brigade-after-tool-call-functions)
(defvar cmacs-brigade-confirm-function)
(defvar cmacs-brigade-auto-approve)
(declare-function cmacs-brigade-register-tool "cmacs-brigade-registry")
(declare-function cmacs-brigade--tool-by-wire "cmacs-brigade-registry")
(declare-function cmacs-brigade--invoke "cmacs-brigade-tools")
(declare-function cmacs-brigade--parse-args "cmacs-brigade-tools")
(declare-function cmacs-brigade-call-tool "cmacs-brigade-tools")
(declare-function cmacs-brigade-call-tool-async "cmacs-brigade-tools")

(defmacro cmacs-brigade-call-errors-tests--with-tool (&rest body)
  "Run BODY with a private registry holding one tool, `probe_show'.
It takes a required `buffer' and an optional `limit'."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (skip-unless (and (featurep 'cmacs-brigade-registry)
                       (featurep 'cmacs-brigade-tools)))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (cmacs-brigade-register-tool
        :name 'probe-show :description "Show a buffer."
        :params '((buffer string "Buffer name")
                  (limit integer "Most lines" :optional t))
        :handler (lambda (buffer &optional _limit) (format "shown %s" buffer)))
       ,@body)))

(ert-deftest cmacs-brigade-call-errors-test-symbol-exists ()
  "The call error is its own condition, beside the definition error."
  (skip-unless (featurep 'cmacs-brigade-tools))
  (let ((conditions (get 'cmacs-brigade-tool-call-error 'error-conditions)))
    (should (memq 'cmacs-brigade-tool-call-error conditions))
    (should (memq 'cmacs-brigade-error conditions))
    ;; Not a kind of definition error: a handler for bad definitions
    ;; must not swallow a bad call, nor the other way round.
    (should-not (memq 'cmacs-brigade-tool-error conditions))
    (should-not (memq 'cmacs-brigade-tool-call-error
                      (get 'cmacs-brigade-tool-error 'error-conditions))))
  (should-not (string-match-p
               "definition"
               (or (get 'cmacs-brigade-tool-call-error 'error-message) ""))))

(ert-deftest cmacs-brigade-call-errors-test-missing-required-argument ()
  "A missing required argument blames the call, naming tool and argument."
  (cmacs-brigade-call-errors-tests--with-tool
    (let* ((tool (cmacs-brigade--tool-by-wire "probe_show"))
           (err (should-error (cmacs-brigade--invoke tool nil)
                              :type 'cmacs-brigade-tool-call-error))
           (text (error-message-string err)))
      (should (string-match-p
               "probe_show: missing required argument `buffer'" text))
      (should-not (string-match-p "definition" text)))
    ;; The optional one may be absent.
    (should (equal (cmacs-brigade--invoke
                    (cmacs-brigade--tool-by-wire "probe_show")
                    '(("buffer" . "x")))
                   "shown x"))))

(ert-deftest cmacs-brigade-call-errors-test-what-the-caller-reads ()
  "Both dispatch paths hand the caller text about its call."
  (cmacs-brigade-call-errors-tests--with-tool
    (dolist (args '(nil "{}" "{\"limit\": 3}"))
      (let ((text (cmacs-brigade-call-tool "probe_show" args)))
        (should (string-prefix-p "Error: " text))
        (should (string-match-p
                 "probe_show: missing required argument `buffer'" text))
        (should-not (string-match-p "definition" text)))
      (let (status answer)
        (cmacs-brigade-call-tool-async
         "probe_show" args
         (lambda (s text) (setq status s answer text)))
        (should (eq status 'error))
        (should (string-match-p
                 "probe_show: missing required argument `buffer'" answer))
        (should-not (string-match-p "definition" answer))))
    (should (equal (cmacs-brigade-call-tool "probe_show" "{\"buffer\":\"b\"}")
                   "shown b"))))

(ert-deftest cmacs-brigade-call-errors-test-arguments-not-json ()
  "Arguments that do not parse are the caller's mistake too."
  (cmacs-brigade-call-errors-tests--with-tool
    (should-error (cmacs-brigade--parse-args "{not json")
                  :type 'cmacs-brigade-tool-call-error)
    (let ((text (cmacs-brigade-call-tool "probe_show" "{not json")))
      (should (string-match-p "not valid JSON" text))
      (should-not (string-match-p "definition" text)))))

(ert-deftest cmacs-brigade-call-errors-test-bad-definition-keeps-its-error ()
  "A tool defined wrongly is still reported as a definition error."
  (cmacs-brigade-call-errors-tests--with-tool
    (let ((err (should-error
                (cmacs-brigade-register-tool
                 :name 'probe-bad :description "d" :handler #'ignore
                 :params '((x array "d" :items frobnicate)))
                :type 'cmacs-brigade-tool-error)))
      (should-not (memq 'cmacs-brigade-tool-call-error
                        (get (car err) 'error-conditions)))
      (should (string-match-p "Invalid brigade tool definition"
                              (error-message-string err))))))

(provide 'cmacs-brigade-call-errors-tests)

;;; cmacs-brigade-call-errors-tests.el ends here
