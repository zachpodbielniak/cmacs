;;; cmacs-brigade-log-tests.el --- The transaction log  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The log is what a sidecar agent reads to find out what another agent
;; actually did, so the properties that matter are: everything written is
;; readable back, order is preserved, filtering is exact, and a damaged
;; file degrades rather than disappears.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-output nil 'noerror)
(require 'cmacs-brigade-log nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

;; `fboundp', not `cmacs-feature-p': the latter is void when a test file
;; is run on its own, which makes every `skip-unless' in the file skip
;; silently and the suite report green without having executed anything.
(defun cmacs-brigade-log-tests--available-p ()
  (and (featurep 'cmacs-brigade-log)
       (fboundp 'cmacs-brigade-log-append)))

(defmacro cmacs-brigade-log-tests--with-dir (&rest body)
  "Run BODY with the log written to a throwaway directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "brigade-log" t))
          (cmacs-brigade-output-dir dir))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))


;;;; Round trip

(ert-deftest cmacs-brigade-log-round-trip ()
  "Everything appended comes back, in order, with its fields."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log-append "T" "message" :turn 1 :text "one" :from "human")
    (cmacs-brigade-log-append "T" "reply" :turn 1 :text "two" :state "done")
    (let ((es (cmacs-brigade-log-read "T")))
      (should (= 2 (length es)))
      (should (equal "message" (alist-get 'kind (nth 0 es))))
      (should (equal "one" (alist-get 'text (nth 0 es))))
      (should (equal "human" (alist-get 'from (nth 0 es))))
      (should (equal "reply" (alist-get 'kind (nth 1 es))))
      (should (equal "two" (alist-get 'text (nth 1 es))))
      ;; Every entry is stamped even when the caller did not say so.
      (should (numberp (alist-get 'at (nth 0 es)))))))

(ert-deftest cmacs-brigade-log-nil-fields-are-omitted ()
  "A field with no value is left out rather than written as null.

A log line should say what happened; a run of `\"reason\": null' says
only that the writer had a slot for it."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log-append "T" "state" :turn 1 :state "running" :reason nil)
    (let ((e (car (cmacs-brigade-log-read "T"))))
      (should (equal "running" (alist-get 'state e)))
      (should-not (assq 'reason e)))))

(ert-deftest cmacs-brigade-log-escapes-hostile-text ()
  "Quotes, newlines and control characters survive the round trip.

Every one of these appears in ordinary tool output, and any of them
breaking the encoding would corrupt the whole line, not just the field."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (let ((nasty "he said \"hi\"\nthen\ttabbed \\ and \x01 rang"))
      (cmacs-brigade-log-append "T" "reply" :turn 1 :text nasty)
      (should (equal nasty (alist-get 'text (car (cmacs-brigade-log-read "T")))))
      ;; And it is still one line on disk, which is the point of JSONL.
      (with-temp-buffer
        (insert-file-contents (cmacs-brigade-log-file "T"))
        (should (= 1 (count-lines (point-min) (point-max))))))))

(ert-deftest cmacs-brigade-log-clips-huge-fields ()
  "An enormous field is truncated, and says that it was."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (let ((cmacs-brigade-log-max-field 50))
      (cmacs-brigade-log-append "T" "tool" :turn 1 :result (make-string 500 ?x))
      (let ((got (alist-get 'result (car (cmacs-brigade-log-read "T")))))
        (should (< (length got) 200))
        (should (string-match-p "elided" got))))))


;;;; Filtering

(ert-deftest cmacs-brigade-log-filters-by-turn-and-kind ()
  "from-turn and kinds narrow exactly, and compose."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log-append "T" "message" :turn 1 :text "m1")
    (cmacs-brigade-log-append "T" "reply"   :turn 1 :text "r1")
    (cmacs-brigade-log-append "T" "tool"    :turn 2 :tool "bash")
    (cmacs-brigade-log-append "T" "reply"   :turn 2 :text "r2")
    (should (= 4 (length (cmacs-brigade-log-read "T"))))
    (should (= 2 (length (cmacs-brigade-log-read "T" 2))))
    (should (= 2 (length (cmacs-brigade-log-read "T" nil '("reply")))))
    (should (= 1 (length (cmacs-brigade-log-read "T" 2 '("reply")))))
    (should (equal "r2" (alist-get 'text (car (cmacs-brigade-log-read
                                               "T" 2 '("reply"))))))
    (should (= 2 (cmacs-brigade-log-turns "T")))))

(ert-deftest cmacs-brigade-log-unknown-task-is-empty-not-an-error ()
  "Reading a task that never logged anything returns nothing quietly."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (should-not (cmacs-brigade-log-read "nope"))
    (should (= 0 (cmacs-brigade-log-turns "nope")))))


;;;; Damage tolerance

(ert-deftest cmacs-brigade-log-skips-malformed-lines ()
  "A truncated or corrupt line costs that line and nothing else.

The file is appended to from a process sentinel, so a half-written final
line is the normal consequence of the editor dying -- refusing to read
the other entries because of it would lose the record exactly when it is
most wanted."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log-append "T" "reply" :turn 1 :text "kept")
    (write-region "{\"kind\":\"reply\",\"tur\n" nil
                  (cmacs-brigade-log-file "T") 'append 'silent)
    (write-region "\n   \n" nil (cmacs-brigade-log-file "T") 'append 'silent)
    (cmacs-brigade-log-append "T" "reply" :turn 2 :text "also kept")
    (let ((es (cmacs-brigade-log-read "T")))
      (should (= 2 (length es)))
      (should (equal "kept" (alist-get 'text (nth 0 es))))
      (should (equal "also kept" (alist-get 'text (nth 1 es)))))))

(ert-deftest cmacs-brigade-log-append-never-signals ()
  "A log that cannot be written does not take the run down with it."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (let ((cmacs-brigade-output-dir "/proc/cmacs-brigade-cannot-exist"))
    (should-not (cmacs-brigade-log-append "T" "reply" :turn 1 :text "x"))))


;;;; Rendering

(ert-deftest cmacs-brigade-log-render-shows-every-turn ()
  "The rendered log is the whole conversation, not the last reply."
  (skip-unless (cmacs-brigade-log-tests--available-p))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log-append "T" "message" :turn 1 :text "first ask" :from "human")
    (cmacs-brigade-log-append "T" "tool" :turn 1 :tool "bash" :result "ran it")
    (cmacs-brigade-log-append "T" "reply" :turn 1 :text "first answer")
    (cmacs-brigade-log-append "T" "message" :turn 2 :text "second ask" :from "human")
    (cmacs-brigade-log-append "T" "reply" :turn 2 :text "second answer")
    (let ((text (cmacs-brigade-log-render "T")))
      (dolist (needle '("first ask" "ran it" "first answer"
                        "second ask" "second answer"))
        (should (string-match-p (regexp-quote needle) text)))
      ;; Order, not merely presence.
      (should (< (string-match "first answer" text)
                 (string-match "second ask" text))))))

(ert-deftest cmacs-brigade-log-render-falls-back-to-legacy-output ()
  "A run recorded before the log existed still reads.

Its output is a flat `<id>.txt' with no JSONL beside it, and refusing to
show it would make upgrading cmacs look like losing history."
  (skip-unless (and (cmacs-brigade-log-tests--available-p)
                    (fboundp 'cmacs-brigade-output-put)))
  (cmacs-brigade-log-tests--with-dir
    (let ((cmacs-brigade-output--cache (make-hash-table :test 'equal)))
      (cmacs-brigade-output-put "OLD" "what it said back then")
      (should (equal "what it said back then"
                     (cmacs-brigade-log-render "OLD")))
      ;; But a filtered read of a task with no log is empty, not the
      ;; legacy blob -- a caller asking for turn 3 must not be handed
      ;; something that has no turns at all.
      (should-not (cmacs-brigade-log-render "OLD" 3)))))


;;;; Attribution

(ert-deftest cmacs-brigade-log-records-tool-calls-with-a-task ()
  "A tool call carrying a task id lands in that task's log."
  (skip-unless (and (cmacs-brigade-log-tests--available-p)
                    (fboundp 'cmacs-brigade-log--on-tool-call)))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log--on-tool-call
     (list :tool "bash" :args '(("command" . "ls")) :task "T" :result "a b c"))
    (let ((e (car (cmacs-brigade-log-read "T"))))
      (should (equal "tool" (alist-get 'kind e)))
      (should (equal "bash" (alist-get 'tool e)))
      (should (equal "a b c" (alist-get 'result e)))
      (should (string-match-p "ls" (or (alist-get 'args e) ""))))))

(ert-deftest cmacs-brigade-log-ignores-tool-calls-with-no-task ()
  "A chat's or an external client's tool call belongs to no run.

Filing it against a guess would put another agent's activity into a
task's log, which is worse than not recording it."
  (skip-unless (and (cmacs-brigade-log-tests--available-p)
                    (fboundp 'cmacs-brigade-log--on-tool-call)))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log--on-tool-call (list :tool "bash" :result "x"))
    (should-not (directory-files cmacs-brigade-output-dir nil "\\.jsonl\\'"))))

(ert-deftest cmacs-brigade-log-records-tool-errors ()
  "A failed tool call is logged with its error rather than dropped."
  (skip-unless (and (cmacs-brigade-log-tests--available-p)
                    (fboundp 'cmacs-brigade-log--on-tool-call)))
  (cmacs-brigade-log-tests--with-dir
    (cmacs-brigade-log--on-tool-call
     (list :tool "bash" :task "T" :error '(error "it blew up")))
    (let ((e (car (cmacs-brigade-log-read "T"))))
      (should (string-match-p "blew up" (or (alist-get 'error e) ""))))))

(provide 'cmacs-brigade-log-tests)

;;; cmacs-brigade-log-tests.el ends here
