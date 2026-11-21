;;; cmacs-lql-watch-tests.el --- Tests for standing LQL queries  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;;; Commentary:

;; No LQL engine is needed: `cmacs-lql-run' is replaced by a stub that
;; records what it was asked and hands the test the callback, so a test
;; decides when -- and with what -- a run comes back.  The timer is
;; never armed (`cmacs-lql-watch--inhibit-timer'); ticks are called by
;; hand on a clock the test moves.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cmacs-lql-watch)
(require 'cmacs-lql-watch-sinks)
(require 'cmacs-lql-watch-tools)

(defvar cmacs-journal--in-tool-call)
(defvar cmacs-journal-expose-to-agents)
(defvar cmacs-gowl-bar-push-function)
(defvar cmacs-lql-watch-sinks--bar-items)

(defvar cmacs-lql-watch-tests--clock 1000.0 "The time watches see.")
(defvar cmacs-lql-watch-tests--runs nil
  "Runs submitted, newest first: plists (:query :callback :options :bindings).")
(defvar cmacs-lql-watch-tests--busy nil "What the engine-busy probe answers.")
(defvar cmacs-lql-watch-tests--idle t "What the idle probe answers.")
(defvar cmacs-lql-watch-tests--run-error nil
  "When non-nil, the stubbed `cmacs-lql-run' signals this message.")

(defun cmacs-lql-watch-tests--json (columns &rest rows)
  "An engine result JSON with COLUMNS (names) and ROWS (lists of values)."
  (json-serialize
   `((columns . ,(vconcat (mapcar (lambda (c) `((name . ,c) (type . "Any")))
                                  columns)))
     (rows . ,(vconcat (mapcar #'vconcat rows)))
     (total . ,(length rows)))))

(defun cmacs-lql-watch-tests--land (payload)
  "Deliver PAYLOAD to the most recently submitted run."
  (funcall (plist-get (car cmacs-lql-watch-tests--runs) :callback) payload))

(defun cmacs-lql-watch-tests--ok (columns &rest rows)
  "Deliver an :ok result with COLUMNS and ROWS to the latest run."
  (cmacs-lql-watch-tests--land
   (list :ok :json (apply #'cmacs-lql-watch-tests--json columns rows)
         :rows (length rows) :elapsed 0.0)))

(defun cmacs-lql-watch-tests--advance (seconds)
  "Move the clock SECONDS on and tick."
  (cl-incf cmacs-lql-watch-tests--clock seconds)
  (cmacs-lql-watch--tick))

(defmacro cmacs-lql-watch-tests--with (&rest body)
  "Run BODY with no watches, a stub engine, a test clock and no timer."
  (declare (indent 0) (debug t))
  `(let ((cmacs-lql-watch--table (make-hash-table :test #'equal))
         (cmacs-lql-watch--inhibit-timer t)
         (cmacs-lql-watch--timer nil)
         (cmacs-lql-watch--engine-sources '("read" "git_log" "journal"))
         (cmacs-lql-watch-tests--clock 1000.0)
         (cmacs-lql-watch-tests--runs nil)
         (cmacs-lql-watch-tests--busy nil)
         (cmacs-lql-watch-tests--idle t)
         (cmacs-lql-watch-tests--run-error nil)
         (cmacs-lql-watch-tools--pending (make-hash-table :test #'equal))
         (cmacs-lql-watch-tools--caller nil)
         (cmacs-lql-watch-min-interval 5)
         (cmacs-lql-watch-max 32)
         (cmacs-lql-watch-max-per-owner 4)
         (cmacs-lql-watch-max-backoff 3600)
         (cmacs-lql-watch-max-generation-skips 20)
         (inhibit-message t))
     (cl-letf (((symbol-function 'cmacs-lql-available-p) (lambda (&rest _) t))
               ((symbol-function 'cmacs-lql-watch--now)
                (lambda (&rest _) cmacs-lql-watch-tests--clock))
               ((symbol-function 'cmacs-lql-watch--engine-busy-p)
                (lambda (&rest _) cmacs-lql-watch-tests--busy))
               ((symbol-function 'cmacs-lql-watch--idle-p)
                (lambda (&rest _) cmacs-lql-watch-tests--idle))
               ((symbol-function 'cmacs-lql-run)
                (lambda (&rest args)
                  (when cmacs-lql-watch-tests--run-error
                    (error "%s" cmacs-lql-watch-tests--run-error))
                  (push (list :query (nth 0 args) :callback (nth 1 args)
                              :options (nthcdr 2 args)
                              :bindings
                              (list :interaction inhibit-interaction
                                    :tool-call
                                    (bound-and-true-p
                                     cmacs-journal--in-tool-call)))
                        cmacs-lql-watch-tests--runs)
                  (length cmacs-lql-watch-tests--runs))))
       ,@body)))

;;;; Baseline, change, diff

(ert-deftest cmacs-lql-watch-test-baseline-does-not-fire ()
  "The first result is the baseline; an identical one fires nothing."
  (cmacs-lql-watch-tests--with
    (let (fired)
      (cmacs-lql-watch 'w "fetch x" :every 10
                       :on-change (lambda (&rest args) (push args fired)))
      (cmacs-lql-watch--tick)
      (should (= (length cmacs-lql-watch-tests--runs) 1))
      (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 1))
      (should-not fired)
      (should (eq (cmacs-lql-watch-get 'w :state) 'ok))
      (should (= (cmacs-lql-watch-get 'w :rows) 1))
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 2))
      (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 1))
      (should-not fired)
      (should (= (cmacs-lql-watch-get 'w :changes) 0))
      (should (= (cmacs-lql-watch-get 'w :runs) 2)))))

(ert-deftest cmacs-lql-watch-test-change-fires-with-keyed-diff ()
  "A different result fires :on-change with new rows, old rows and a diff."
  (cmacs-lql-watch-tests--with
    (let (fired rows-seen)
      (cmacs-lql-watch "w" "fetch x" :every 10 :key "unit"
                       :on-change (lambda (new old diff)
                                    (push (list new old diff) fired))
                       :on-rows (lambda (rows) (setq rows-seen rows)))
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 1) '("b" 2))
      (cmacs-lql-watch-tests--advance 10)
      (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 5) '("c" 3))
      (should (= (length fired) 1))
      (pcase-let ((`(,new ,old ,diff) (car fired)))
        (should (equal new '((("unit" . "a") ("n" . 5))
                             (("unit" . "c") ("n" . 3)))))
        (should (equal old '((("unit" . "a") ("n" . 1))
                             (("unit" . "b") ("n" . 2)))))
        (should (equal (plist-get diff :added) '((("unit" . "c") ("n" . 3)))))
        (should (equal (plist-get diff :removed) '((("unit" . "b") ("n" . 2)))))
        (should (equal (plist-get diff :changed)
                       '(((("unit" . "a") ("n" . 1))
                          . (("unit" . "a") ("n" . 5))))))
        (should-not (plist-get diff :reordered))
        (should (equal rows-seen new)))
      (should (= (cmacs-lql-watch-get "w" :changes) 1))
      (should (= (cmacs-lql-watch-get "w" :last-change)
                 cmacs-lql-watch-tests--clock)))))

(ert-deftest cmacs-lql-watch-test-immediate-fires-on-first-result ()
  ":immediate fires on the baseline, with no old rows."
  (cmacs-lql-watch-tests--with
    (let (fired)
      (cmacs-lql-watch 'w "fetch x" :immediate t
                       :on-change (lambda (new old _diff)
                                    (push (cons new old) fired)))
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should (equal fired '((((("n" . 1))) . nil)))))))

(ert-deftest cmacs-lql-watch-test-diff-without-key-and-reorder ()
  "Without a key rows are compared whole, as a multiset."
  (let* ((a '(("n" . 1))) (b '(("n" . 2))) (c '(("n" . 3)))
         (diff (cmacs-lql-watch-diff (list a a b) (list a c))))
    (should (equal (plist-get diff :added) (list c)))
    (should (equal (plist-get diff :removed) (list a b)))
    (should-not (plist-get diff :changed))
    (should (plist-get (cmacs-lql-watch-diff (list a b) (list b a)) :reordered))
    (should (plist-get (cmacs-lql-watch-diff (list a b) (list b a) "n")
                       :reordered))
    (should-not (plist-get (cmacs-lql-watch-diff (list a b) (list a b))
                           :reordered))))

(ert-deftest cmacs-lql-watch-test-diff-json-is-bounded ()
  "The diff JSON keeps its counts and is cut to fit."
  (let* ((rows (cl-loop for i below 200
                        collect `(("name" . ,(format "row-%04d" i))
                                  ("note" . nil))))
         (diff (list :added rows :removed nil :changed nil))
         (json (cmacs-lql-watch-diff-json diff 600))
         (doc (json-parse-string json)))
    (should (<= (length json) 600))
    (should (eq (gethash "truncated" doc) t))
    (should (= (gethash "added" (gethash "counts" doc)) 200))
    (should (< (length (gethash "added" doc)) 200))
    ;; NULL goes back out as null, not as an empty object.
    (let ((small (json-parse-string
                  (cmacs-lql-watch-diff-json
                   (list :added (list (car rows))
                         :changed (list (cons (car rows) (cadr rows))))))))
      (should (eq (gethash "note" (aref (gethash "added" small) 0)) :null))
      (should (equal (gethash "name"
                              (gethash "new" (aref (gethash "changed" small) 0)))
                     "row-0001")))))

;;;; Cost discipline

(ert-deftest cmacs-lql-watch-test-in-flight-is-never-queued-twice ()
  "A watch whose run is out is not submitted again, and neither is another."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'a "fetch x" :every 5)
    (cmacs-lql-watch 'b "fetch y" :every 5)
    (cmacs-lql-watch--tick)
    (should (= (length cmacs-lql-watch-tests--runs) 1))
    (should (eq (cmacs-lql-watch-get 'a :state) 'running))
    ;; However often the timer comes round, the engine has one of ours.
    (cmacs-lql-watch-tests--advance 5)
    (cmacs-lql-watch-tests--advance 5)
    (should (= (length cmacs-lql-watch-tests--runs) 1))
    ;; It lands; now the other one may go.
    (cmacs-lql-watch-tests--ok '("n") '(1))
    (cmacs-lql-watch--tick)
    (should (= (length cmacs-lql-watch-tests--runs) 2))
    (should (equal (plist-get (car cmacs-lql-watch-tests--runs) :query)
                   "fetch y"))))

(ert-deftest cmacs-lql-watch-test-watchdog-frees-a-stuck-run ()
  "A run that never comes back is given up on, and its late result ignored."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'a "fetch x" :every 5 :timeout 10)
    (cmacs-lql-watch--tick)
    (cmacs-lql-watch-tests--advance 30)
    (should (eq (cmacs-lql-watch-get 'a :state) 'error))
    (should (= (cmacs-lql-watch-get 'a :failures) 1))
    (cmacs-lql-watch-tests--ok '("n") '(1))
    (should (eq (cmacs-lql-watch-get 'a :state) 'error))
    (should (= (cmacs-lql-watch-get 'a :runs) 0))))

(ert-deftest cmacs-lql-watch-test-busy-engine-skips-the-tick ()
  "While somebody's query holds the engine, no watch is submitted."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'a "fetch x" :every 60)
    (setq cmacs-lql-watch-tests--busy t)
    (cmacs-lql-watch--tick)
    (should-not cmacs-lql-watch-tests--runs)
    (should (eq (cmacs-lql-watch-get 'a :last-skip) 'busy))
    (should (= (cmacs-lql-watch-get 'a :skipped) 1))
    ;; Retried soon, not a whole interval later.
    (should (= (cmacs-lql-watch-get 'a :next-due)
               (+ 1000.0 cmacs-lql-watch-busy-retry)))
    (setq cmacs-lql-watch-tests--busy nil)
    (cmacs-lql-watch-tests--advance cmacs-lql-watch-busy-retry)
    (should (= (length cmacs-lql-watch-tests--runs) 1))))

(ert-deftest cmacs-lql-watch-test-typing-holds-back-lisp-sources-only ()
  "A watch naming an Elisp source waits for idleness; others do not."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql--sources (make-hash-table :test #'equal)))
      (puthash "wt_src" (list :columns nil :function #'ignore)
               cmacs-lql--sources)
      (cmacs-lql-watch 'lisp "fetch wt_src" :every 60)
      (cmacs-lql-watch 'plain "fetch journal" :every 60)
      (setq cmacs-lql-watch-tests--idle nil)
      (cmacs-lql-watch--tick)
      (should (= (length cmacs-lql-watch-tests--runs) 1))
      (should (equal (plist-get (car cmacs-lql-watch-tests--runs) :query)
                     "fetch journal"))
      (should (eq (cmacs-lql-watch-get 'lisp :last-skip) 'typing))
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (setq cmacs-lql-watch-tests--idle t)
      (cmacs-lql-watch-tests--advance 1)
      (should (equal (plist-get (car cmacs-lql-watch-tests--runs) :query)
                     "fetch wt_src")))))

(ert-deftest cmacs-lql-watch-test-unchanged-generation-skips-the-run ()
  "No named source moved: no snapshot, no submit.  Bounded, and provable only."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql--sources (make-hash-table :test #'equal))
          (cmacs-lql-watch-max-generation-skips 2)
          (generation 1))
      (puthash "wt_src" (list :columns nil :function #'ignore
                              :generation (lambda () generation))
               cmacs-lql--sources)
      (cmacs-lql-watch 'w "fetch wt_src | limit 5" :every 10)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should (= (length cmacs-lql-watch-tests--runs) 1))
      ;; Twice skipped...
      (cmacs-lql-watch-tests--advance 10)
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 1))
      (should (eq (cmacs-lql-watch-get 'w :last-skip) 'unchanged))
      ;; ...and then run anyway: the skip is an inference.
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 2))
      (cmacs-lql-watch-tests--ok '("n") '(1))
      ;; A moved generation runs at once.
      (setq generation 2)
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 3))
      (cmacs-lql-watch-tests--ok '("n") '(1))
      ;; A query that also reads an engine source, or the clock, is
      ;; never skipped; nor is one that says so.
      (cmacs-lql-watch 'mixed "fetch wt_src | join (fetch git_log)" :every 10)
      (cmacs-lql-watch 'clock "fetch wt_src | filter t > now() - 1h" :every 10)
      (cmacs-lql-watch 'always "fetch wt_src" :every 10 :depends 'always)
      (dolist (name '(mixed clock always))
        (cmacs-lql-watch-pause 'w)
        (dolist (other '(mixed clock always))
          (if (eq other name)
              (cmacs-lql-watch-resume other)
            (cmacs-lql-watch-pause other)))
        (let ((before (length cmacs-lql-watch-tests--runs)))
          (cmacs-lql-watch--tick)
          (cmacs-lql-watch-tests--ok '("n") '(1))
          (cmacs-lql-watch-tests--advance 10)
          (should (= (length cmacs-lql-watch-tests--runs) (+ before 2)))
          (cmacs-lql-watch-tests--ok '("n") '(1)))))))

(ert-deftest cmacs-lql-watch-test-error-is-recorded-and-backs-off ()
  "A failing watch waits longer each time, says so once, and recovers."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-max-backoff 100)
          (cmacs-lql-watch-error-functions nil)
          told)
      (add-hook 'cmacs-lql-watch-error-functions
                (lambda (name message) (push (cons name message) told)))
      (cmacs-lql-watch 'w "fetch nope" :every 10)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--land '(:error "no such source: nope"))
      (should (eq (cmacs-lql-watch-get 'w :state) 'error))
      (should (equal (cmacs-lql-watch-get 'w :last-error)
                     "no such source: nope"))
      (should (= (cmacs-lql-watch-get 'w :next-due) (+ 1000.0 20)))
      ;; Not retried at its ordinary interval.
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 1))
      (cmacs-lql-watch-tests--advance 10)
      (should (= (length cmacs-lql-watch-tests--runs) 2))
      (cmacs-lql-watch-tests--land '(:error "still no"))
      (should (= (cmacs-lql-watch-get 'w :next-due)
                 (+ cmacs-lql-watch-tests--clock 40)))
      (should (= (cmacs-lql-watch-get 'w :failures) 2))
      ;; Told once, however many times it fails.
      (should (equal told '(("w" . "no such source: nope"))))
      ;; Capped.
      (dotimes (_ 4)
        (cmacs-lql-watch-tests--advance 200)
        (cmacs-lql-watch-tests--land '(:error "no")))
      (should (= (cmacs-lql-watch-get 'w :next-due)
                 (+ cmacs-lql-watch-tests--clock 100)))
      ;; A success clears it all.
      (cmacs-lql-watch-tests--advance 200)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should (eq (cmacs-lql-watch-get 'w :state) 'ok))
      (should (= (cmacs-lql-watch-get 'w :failures) 0))
      (should-not (cmacs-lql-watch-get 'w :last-error))
      (should (= (cmacs-lql-watch-get 'w :next-due)
                 (+ cmacs-lql-watch-tests--clock 10))))))

(ert-deftest cmacs-lql-watch-test-submit-error-is-recorded ()
  "`cmacs-lql-run' signalling is an error on the watch, not in the timer."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'w "fetch x" :every 10)
    (setq cmacs-lql-watch-tests--run-error "engine exploded")
    (cmacs-lql-watch--tick)
    (should (eq (cmacs-lql-watch-get 'w :state) 'error))
    (should (string-match-p "engine exploded"
                            (cmacs-lql-watch-get 'w :last-error)))))

(ert-deftest cmacs-lql-watch-test-oversized-result-is-an-error ()
  "A result past the byte cap is refused rather than kept."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-max-result-bytes 40))
      (cmacs-lql-watch 'w "fetch x" :every 10)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") (list (make-string 200 ?x)))
      (should (eq (cmacs-lql-watch-get 'w :state) 'error))
      (should (string-match-p "too large" (cmacs-lql-watch-get 'w :last-error)))
      (should-not (cmacs-lql-watch-rows 'w)))))

(ert-deftest cmacs-lql-watch-test-rows-are-capped ()
  "A watch asks for no more rows than its cap or the engine's."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-max-rows 50)
          (cmacs-lql-max-rows 20))
      (cmacs-lql-watch 'w "fetch x" :max-rows 1000)
      (cmacs-lql-watch--tick)
      (should (= (plist-get (plist-get (car cmacs-lql-watch-tests--runs)
                                       :options)
                            :max-rows)
                 20)))))

;;;; Callbacks cannot hurt

(ert-deftest cmacs-lql-watch-test-callback-error-is-contained ()
  "A callback that signals, or prompts, is recorded; the rest still run."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-change-functions nil)
          hook-ran)
      (add-hook 'cmacs-lql-watch-change-functions
                (lambda (&rest _) (setq hook-ran t)))
      (cmacs-lql-watch 'boom "fetch x" :immediate t
                       :on-change (lambda (&rest _) (error "Kaboom")))
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should (string-match-p "Kaboom"
                              (cmacs-lql-watch-get 'boom :callback-error)))
      (should hook-ran)
      (should (eq (cmacs-lql-watch-get 'boom :state) 'ok))
      (cmacs-lql-unwatch 'boom)
      ;; A prompt would take the keyboard at a moment nobody chose.
      (cmacs-lql-watch 'ask "fetch x" :immediate t
                       :on-change (lambda (&rest _) (read-string "Really? ")))
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should (cmacs-lql-watch-get 'ask :callback-error)))))

;;;; Registration

(ert-deftest cmacs-lql-watch-test-unwatch-and-late-result ()
  "A removed watch is gone, and the result of its last run is dropped."
  (cmacs-lql-watch-tests--with
    (let (fired removed)
      (let ((cmacs-lql-watch-removed-functions
             (list (lambda (name owner) (push (cons name owner) removed)))))
        (cmacs-lql-watch 'w "fetch x" :immediate t
                         :on-change (lambda (&rest _) (setq fired t)))
        (cmacs-lql-watch--tick)
        (should (cmacs-lql-unwatch 'w))
        (should-not (cmacs-lql-unwatch 'w))
        (should (equal removed '(("w" . nil)))))
      (should-not (cmacs-lql-watch-list))
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should-not fired))))

(ert-deftest cmacs-lql-watch-test-replacing-drops-the-old-run ()
  "Re-registering a name replaces the watch; the old run's result is not its."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'w "fetch x")
    (cmacs-lql-watch--tick)
    (let ((old (car cmacs-lql-watch-tests--runs)))
      (cmacs-lql-watch 'w "fetch y")
      (funcall (plist-get old :callback)
               (list :ok :json (cmacs-lql-watch-tests--json '("n") '(1))))
      (should (eq (cmacs-lql-watch-get 'w :state) 'waiting))
      (should (equal (cmacs-lql-watch-get 'w :query) "fetch y")))))

(ert-deftest cmacs-lql-watch-test-options-are-checked ()
  "Typos, a missing query and a tiny interval are dealt with at registration."
  (cmacs-lql-watch-tests--with
    (should-error (cmacs-lql-watch 'w "fetch x" :evry 5)
                  :type 'cmacs-lql-watch-error)
    (should-error (cmacs-lql-watch 'w "  ") :type 'cmacs-lql-watch-error)
    (should-error (cmacs-lql-watch 'w "fetch x" :depends 'sometimes)
                  :type 'cmacs-lql-watch-error)
    (cmacs-lql-watch 'w "fetch x" :every 0.01)
    (should (= (cmacs-lql-watch-get 'w :every) 5))
    ;; A consumer's key is accepted and readable.
    (cmacs-lql-watch 'v "fetch x" :toast "hello")
    (should (equal (cmacs-lql-watch-get 'v :toast) "hello"))))

(ert-deftest cmacs-lql-watch-test-unavailable-engine ()
  "Without LQL a watch is an error, and `cmacs-lql-define-watch' a message."
  (cmacs-lql-watch-tests--with
    (cl-letf (((symbol-function 'cmacs-lql-available-p) (lambda (&rest _) nil)))
      (should-error (cmacs-lql-watch 'w "fetch x")
                    :type 'cmacs-lql-unavailable)
      (should-not (cmacs-lql-define-watch w2 "fetch x" :every 30))
      (should-not (cmacs-lql-watch-list)))))

(ert-deftest cmacs-lql-watch-test-caps ()
  "There is a ceiling on watches in total and on watches per owner."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-max 3)
          (cmacs-lql-watch-max-per-owner 2))
      (cmacs-lql-watch "t1/a" "fetch x" :owner "t1")
      (cmacs-lql-watch "t1/b" "fetch x" :owner "t1")
      (should-error (cmacs-lql-watch "t1/c" "fetch x" :owner "t1")
                    :type 'cmacs-lql-watch-error)
      ;; Replacing one of its own is not a third.
      (cmacs-lql-watch "t1/b" "fetch y" :owner "t1")
      (cmacs-lql-watch 'mine "fetch x")
      (should-error (cmacs-lql-watch 'another "fetch x")
                    :type 'cmacs-lql-watch-error)
      (should (= (length (cmacs-lql-watch-list)) 3))
      (should (= (length (cmacs-lql-watch-list "t1")) 2))
      (should (= (length (cmacs-lql-watch-list 'user)) 1)))))

(ert-deftest cmacs-lql-watch-test-pause-resume-run-now ()
  "A paused watch does not run; run-now clears a backoff."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'w "fetch x" :every 100 :paused t)
    (cmacs-lql-watch--tick)
    (should-not cmacs-lql-watch-tests--runs)
    (should (eq (cmacs-lql-watch-get 'w :state) 'paused))
    (cmacs-lql-watch-resume 'w)
    (cmacs-lql-watch--tick)
    (cmacs-lql-watch-tests--land '(:error "x"))
    (cmacs-lql-watch-tests--advance 1)
    (should (= (length cmacs-lql-watch-tests--runs) 1))
    (cmacs-lql-watch-run-now 'w)
    (cmacs-lql-watch--tick)
    (should (= (length cmacs-lql-watch-tests--runs) 2))))

(ert-deftest cmacs-lql-watch-test-list-buffer-renders ()
  "The list has a row per watch and shows an error in place of the query."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'good "fetch x\n| limit 1" :every 30)
    (cmacs-lql-watch 'bad "fetch y" :every 30)
    (cmacs-lql-watch-pause 'good)
    (cmacs-lql-watch--tick)
    (cmacs-lql-watch-tests--land '(:error "broken thing"))
    (let ((entries (cmacs-lql-watch--entries)))
      (should (equal (mapcar #'car entries) '("bad" "good")))
      (should (equal (aref (cadr (assoc "bad" entries)) 1) "error"))
      (should (equal (aref (cadr (assoc "bad" entries)) 9) "broken thing"))
      (should (equal (aref (cadr (assoc "good" entries)) 1) "paused"))
      (should (equal (aref (cadr (assoc "good" entries)) 9)
                     "fetch x | limit 1")))
    (with-temp-buffer
      (cmacs-lql-watches-mode)
      (tabulated-list-print)
      (goto-char (point-min))
      (should (equal (tabulated-list-get-id) "bad")))))

(ert-deftest cmacs-lql-watch-test-saved-watches-restore ()
  "Saved watches come back; a broken entry does not stop the others."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-saved
           '(("one" "fetch x" :every 30 :key "n")
             ("broken" "fetch x" :nonsense 1)
             ("two" "fetch y"))))
      (should (= (cmacs-lql-watch-restore-saved) 2))
      (should (equal (mapcar (lambda (w) (plist-get w :name))
                             (cmacs-lql-watch-list))
                     '("one" "two")))
      (should (equal (cmacs-lql-watch-get "one" :key) "n")))
    (should (cmacs-lql-watch--data-p '(:every 30 :on-change my-function)))
    (should-not (cmacs-lql-watch--data-p (list :on-change (lambda () 1))))))

;;;; Ownership and the journal gate

(ert-deftest cmacs-lql-watch-test-owned-watch-runs-in-agent-context ()
  "An owned watch is submitted as a tool call would be; yours is not."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'mine "fetch buffers" :every 10)
    (cmacs-lql-watch--tick)
    (let ((bindings (plist-get (car cmacs-lql-watch-tests--runs) :bindings)))
      (should-not (plist-get bindings :interaction))
      (should-not (plist-get bindings :tool-call)))
    (cmacs-lql-watch-tests--ok '("n") '(1))
    (cmacs-lql-watch-pause 'mine)
    (cmacs-lql-watch "t1/theirs" "fetch buffers" :every 10 :owner "t1")
    (cmacs-lql-watch--tick)
    (let ((bindings (plist-get (car cmacs-lql-watch-tests--runs) :bindings)))
      (should (plist-get bindings :interaction))
      (should (plist-get bindings :tool-call)))))

(ert-deftest cmacs-lql-watch-test-owned-generation-is-asked-as-the-agent ()
  "A source's generation function sees the agent, as its snapshot will."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql--sources (make-hash-table :test #'equal))
          seen)
      (puthash "wt_src"
               (list :columns nil :function #'ignore
                     :generation (lambda ()
                                   (push (bound-and-true-p
                                          cmacs-journal--in-tool-call)
                                         seen)
                                   1))
               cmacs-lql--sources)
      (cmacs-lql-watch "t1/w" "fetch wt_src" :owner "t1")
      (cmacs-lql-watch--tick)
      (should (equal seen '(t))))))

(ert-deftest cmacs-lql-watch-test-journal-is-gated-for-owned-watches ()
  "An agent's watch may not name `activity' unless the journal is exposed."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-journal-expose-to-agents nil))
      (should-error (cmacs-lql-watch "t1/w" "fetch activity | limit 5"
                                     :owner "t1")
                    :type 'cmacs-lql-watch-error)
      (should-not (cmacs-lql-watch-list))
      ;; Yours may.
      (cmacs-lql-watch 'mine "fetch activity | limit 5")
      ;; A column called activity_count is not the source.
      (cmacs-lql-watch "t1/ok" "fetch buffers | fields activity_count"
                       :owner "t1"))
    (let ((cmacs-journal-expose-to-agents t))
      (cmacs-lql-watch "t1/w" "fetch activity | limit 5" :owner "t1")
      (should (cmacs-lql-watch-get "t1/w" :owner)))))

(ert-deftest cmacs-lql-watch-test-name-belongs-to-its-owner ()
  "Nobody replaces somebody else's watch by picking its name."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch 'shared "fetch x")
    (should-error (cmacs-lql-watch 'shared "fetch y" :owner "t1")
                  :type 'cmacs-lql-watch-error)
    (should (equal (cmacs-lql-watch-get 'shared :query) "fetch x"))
    (cmacs-lql-watch "t1/a" "fetch x" :owner "t1")
    (should-error (cmacs-lql-watch "t1/a" "fetch y" :owner "t2")
                  :type 'cmacs-lql-watch-error)
    (should (= (cmacs-lql-unwatch-owner "t1") 1))
    (should (= (length (cmacs-lql-watch-list)) 1))))

;;;; The agent tools

(defmacro cmacs-lql-watch-tests--as-task (task &rest body)
  "Run BODY as though a watch tool call from TASK were being dispatched."
  (declare (indent 1))
  `(progn
     (run-hook-with-args-until-failure
      'cmacs-brigade-before-tool-call-functions
      (list :tool "lql_watch" :args nil :agent "tester" :task ,task))
     ,@body))

(ert-deftest cmacs-lql-watch-test-tools-are-registered ()
  "The three tools exist under their wire names with the right parameters."
  (skip-unless (fboundp 'cmacs-brigade-registry-get))
  (dolist (name '(lql-watch lql-unwatch lql-watches))
    (should (cmacs-brigade-registry-get 'tool name)))
  (let ((tool (cmacs-brigade-registry-get 'tool 'lql-watch)))
    (when (cmacs-brigade-tool-p tool)
      (should (equal (cmacs-brigade-tool-wire-name tool) "lql_watch"))
      (should (equal (mapcar (lambda (p) (format "%s" (plist-get p :name)))
                             (cmacs-brigade-tool-params tool))
                     '("name" "query" "every" "key"))))))

(ert-deftest cmacs-lql-watch-test-tool-needs-a-task ()
  "A call from no task is refused, and the caller note is used once."
  (cmacs-lql-watch-tests--with
    (should-error (cmacs-lql-watch-tools--task))
    (cmacs-lql-watch-tests--as-task "t1"
      (should (equal (cmacs-lql-watch-tools--task) "t1"))
      (should-error (cmacs-lql-watch-tools--task)))
    ;; Another tool's call does not leave a caller behind.
    (run-hook-with-args-until-failure
     'cmacs-brigade-before-tool-call-functions
     (list :tool "lql_query" :agent "tester" :task "t9"))
    (should-error (cmacs-lql-watch-tools--task))))

(ert-deftest cmacs-lql-watch-test-tool-watch-is-owned-and-bounded ()
  "An agent's watch is namespaced, owned, slowed down and capped."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-max-per-owner 2)
          (cmacs-lql-watch-tools-min-interval 30))
      (should (string-match-p
               "Watching `big'"
               (cmacs-lql-watch-tools--watch "t1" "big" "fetch buffers" 1 "name")))
      (should (equal (cmacs-lql-watch-get "t1/big" :owner) "t1"))
      (should (= (cmacs-lql-watch-get "t1/big" :every) 30))
      (should (equal (cmacs-lql-watch-get "t1/big" :key) "name"))
      (should-not (cmacs-lql-watch-get "t1/big" :on-change))
      (should-error (cmacs-lql-watch-tools--watch "t1" "../x" "fetch x" nil nil))
      (should-error (cmacs-lql-watch-tools--watch "t1" "x" "  " nil nil))
      (cmacs-lql-watch-tools--watch "t1" "two" "fetch x" nil nil)
      (should-error (cmacs-lql-watch-tools--watch "t1" "three" "fetch x" nil nil))
      ;; Another task has its own allowance and its own namespace.
      (cmacs-lql-watch-tools--watch "t2" "big" "fetch y" nil nil)
      (should (equal (cmacs-lql-watch-get "t2/big" :query) "fetch y"))
      (should (equal (cmacs-lql-watch-get "t1/big" :query) "fetch buffers"))
      ;; And cannot remove the first one's.
      (cmacs-lql-watch-tools--unwatch "t2" "big")
      (should (cmacs-lql-watch-get "t1/big" :owner))
      (should-error (cmacs-lql-watch-tools--unwatch "t2" "two"))
      (should (string-match-p "big:" (cmacs-lql-watch-tools--watches "t1")))
      (should (equal (cmacs-lql-watch-tools--watches "t2")
                     "You have no watches.")))))

(ert-deftest cmacs-lql-watch-test-tool-cannot-reach-the-journal ()
  "`lql_watch' is no way round `cmacs-journal-expose-to-agents'."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-journal-expose-to-agents nil))
      (should-error (cmacs-lql-watch-tools--watch
                     "t1" "spy" "fetch activity | fields title" nil nil))
      (should-not (cmacs-lql-watch-list)))))

(ert-deftest cmacs-lql-watch-test-tool-delivery-and-run-end ()
  "A change reaches the task's mailbox once; the run's end removes the watch."
  (cmacs-lql-watch-tests--with
    (let (sent queued)
      (cl-letf (((symbol-function 'cmacs-brigade-mailbox-send)
                 (lambda (&rest args)
                   (push args sent)
                   (push (list :text (nth 1 args) :from (nth 2 args)) queued)))
                ((symbol-function 'cmacs-brigade-mailbox-list)
                 (lambda (&rest _) queued)))
        (cmacs-lql-watch-tools--watch "t1" "w" "fetch x" 30 "n")
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("n") '(1))
        (should-not sent)               ; the baseline is not news
        (cmacs-lql-watch-tests--advance 30)
        (cmacs-lql-watch-tests--ok '("n") '(1) '(2))
        (should (= (length sent) 1))
        (pcase-let ((`(,task ,text ,from) (car sent)))
          (should (equal task "t1"))
          (should (equal from "lql-watch:w"))
          (should (string-match-p "`w' changed" text))
          (should (string-match-p "1 added" text)))
        ;; Still unread when it changes again: no second message, and
        ;; the news waits in `lql_watches'.
        (cmacs-lql-watch-tests--advance 30)
        (cmacs-lql-watch-tests--ok '("n") '(3))
        (should (= (length sent) 1))
        (should (string-match-p "undelivered: "
                                (cmacs-lql-watch-tools--watches "t1")))
        (should-not (string-match-p "undelivered: "
                                    (cmacs-lql-watch-tools--watches "t1")))
        ;; Read: the next change is sent again.
        (setq queued nil)
        (cmacs-lql-watch-tests--advance 30)
        (cmacs-lql-watch-tests--ok '("n") '(4))
        (should (= (length sent) 2))
        ;; A failing watch is reported to its owner, once.
        (setq queued nil)
        (cmacs-lql-watch-tests--advance 30)
        (cmacs-lql-watch-tests--land '(:error "bad query"))
        (should (= (length sent) 3))
        (should (string-match-p "is failing" (nth 1 (car sent))))
        ;; The user's own watches tell no agent anything.
        (cmacs-lql-watch 'mine "fetch y" :immediate t)
        (cmacs-lql-watch-pause "t1/w")
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("n") '(1))
        (should (= (length sent) 3))
        ;; The run ends: its watches go, nobody else's do.
        (run-hook-with-args 'cmacs-brigade-run-finished-functions
                            "t1" 'done "output")
        (should-not (cmacs-lql-watch-list "t1"))
        (should (= (length (cmacs-lql-watch-list)) 1))))))

;;;; The sinks

(ert-deftest cmacs-lql-watch-test-format ()
  "A template is filled from the first row and the counts."
  (cmacs-lql-watch-tests--with
    (let ((rows '((("unit" . "sshd") ("n" . 3) ("gone" . nil))
                  (("unit" . "cron") ("n" . 1) ("gone" . nil)))))
      (should (equal (cmacs-lql-watch-format
                      "{name}: {rows} ({unit}={n}{gone}) {nope}" "w" rows)
                     "w: 2 (sshd=3) {nope}"))
      (should (equal (cmacs-lql-watch-format "{rows} {unit}" "w" nil) "0 ")))))

(ert-deftest cmacs-lql-watch-test-podomation-event ()
  "A watch with :event emits one event per change; an agent's never does."
  (cmacs-lql-watch-tests--with
    (let (events)
      (cl-letf (((symbol-function 'cmacs-podomation-running-p)
                 (lambda (&rest _) t))
                ((symbol-function 'cmacs-podomation-emit-event)
                 (lambda (&rest args) (push args events))))
        (cmacs-lql-watch 'units "fetch x" :every 10 :key "unit" :event t)
        (cmacs-lql-watch 'zquiet "fetch x" :every 10)
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 1))
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 1))
        (should-not events)
        (cmacs-lql-watch-tests--advance 10)
        (cmacs-lql-watch-tests--ok '("unit" "n") '("a" 2) '("b" 1))
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("unit" "n") '("z" 9))
        (should (= (length events) 1))
        (pcase-let ((`(,event ,data) (car events)))
          (should (equal event "on_lql_watch"))
          (should (equal (cdr (assoc "watch" data)) "units"))
          (should (equal (cdr (assoc "rows" data)) "2"))
          (should (equal (cdr (assoc "added" data)) "1"))
          (should (equal (cdr (assoc "changed" data)) "1"))
          (should (equal (json-parse-string (cdr (assoc "row" data))
                                            :object-type 'alist)
                         '((unit . "a") (n . 2))))
          ;; Every value is a string: that is all an event carries.
          (should (cl-every (lambda (cell) (stringp (cdr cell))) data))
          (should (= (gethash "added"
                              (gethash "counts"
                                       (json-parse-string
                                        (cdr (assoc "diff" data)))))
                     1)))
        ;; An owned watch cannot be given the key's effect.
        (setq events nil)
        (cmacs-lql-watch-pause 'units)
        (cmacs-lql-watch-pause 'zquiet)
        (cmacs-lql-watch "t1/x" "fetch x" :owner "t1" :event t :immediate t)
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("n") '(1))
        (should-not events)))))

(defmacro cmacs-lql-watch-tests--with-bar (sets removes &rest body)
  "Run BODY with the slot layer recording instead of reaching a bar.
SETS collects the argument lists given to `cmacs-gowl-bar-slot-set' and
REMOVES the ids given to `cmacs-gowl-bar-slot-remove', newest first."
  (declare (indent 2))
  `(let ((,sets nil)
         (,removes nil)
         (cmacs-lql-watch-sinks--bar-items (make-hash-table :test #'equal)))
     (require 'cmacs-gowl-bar-slots)
     (cl-letf (((symbol-function 'cmacs-gowl-bar-slot-set)
                (lambda (&rest args) (push args ,sets) t))
               ((symbol-function 'cmacs-gowl-bar-slot-remove)
                (lambda (&rest args) (push (car args) ,removes) t)))
       ,@body)))

(ert-deftest cmacs-lql-watch-test-bar-slot ()
  "A watch with :bar owns a slot: made, refilled, and taken away with it."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch-tests--with-bar sets removes
      (cmacs-lql-watch 'inbox "fetch x" :every 10
                       :bar "inbox {rows}: {title}")
      ;; Nothing until there is a result to show.
      (should-not sets)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("title") '("first\nnote"))
      (should (= (length sets) 1))
      (let ((id (caar sets))
            (plist (cdar sets)))
        ;; Its own slot, named after the watch.
        (should (equal id "lql-inbox"))
        (should (equal (plist-get plist :text) "inbox 1: first note"))
        (should (eq (plist-get plist :owner) 'cmacs-lql-watch))
        (should (equal (plist-get plist :tooltip) "inbox: fetch x")))
      ;; A change refills the same slot.
      (cmacs-lql-watch-tests--advance 10)
      (cmacs-lql-watch-tests--ok '("title") '("a") '("b"))
      (should (= (length sets) 2))
      (should (equal (caar sets) "lql-inbox"))
      (should (equal (plist-get (cdar sets) :text) "inbox 2: a"))
      ;; An identical result is not a change and pushes nothing.
      (cmacs-lql-watch-tests--advance 10)
      (cmacs-lql-watch-tests--ok '("title") '("a") '("b"))
      (should (= (length sets) 2))
      (should-not removes)

      ;; Paused: the last value is nobody's current answer.
      (cmacs-lql-watch-pause 'inbox)
      (should (equal removes '("lql-inbox")))
      ;; Resumed: it goes back at once, from the rows it had -- the run
      ;; that follows may well find nothing changed and push nothing.
      (cmacs-lql-watch-resume 'inbox)
      (should (= (length sets) 3))
      (should (equal (plist-get (cdar sets) :text) "inbox 2: a"))

      ;; Removed: so is its slot.
      (cmacs-lql-unwatch 'inbox)
      (should (equal removes '("lql-inbox" "lql-inbox")))
      ;; And once only: nothing is left to remove.
      (cmacs-lql-watch-sinks--bar-removed "inbox" nil)
      (should (= (length removes) 2)))))

(ert-deftest cmacs-lql-watch-test-bar-slot-per-watch ()
  "Every watch with :bar has a slot of its own -- any number of them."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch-tests--with-bar sets removes
      (cmacs-lql-watch 'mail "fetch m" :immediate t :bar t)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1) '(2) '(3))
      (cmacs-lql-watch 'ci/main "fetch c" :immediate t :bar "{rows} failing")
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      ;; (An :immediate watch's first result is both its baseline and
      ;; a change, so each slot was set twice; the second is a no-op.)
      (should (equal (sort (delete-dups (mapcar #'car sets)) #'string<)
                     '("lql-ci-main" "lql-mail")))
      ;; t is \"NAME: N\".
      (should (equal (plist-get (cdr (assoc "lql-mail" sets)) :text)
                     "mail: 3"))
      (should (equal (plist-get (cdr (assoc "lql-ci-main" sets)) :text)
                     "1 failing"))
      ;; Removing one leaves the other.
      (cmacs-lql-unwatch 'mail)
      (should (equal removes '("lql-mail"))))))

(ert-deftest cmacs-lql-watch-test-bar-slot-plist ()
  "A :bar plist places and dresses the slot; a function decides per result."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch-tests--with-bar sets removes
      (let ((clicked nil))
        (cmacs-lql-watch
         'runs "fetch c" :every 10
         :bar (list :slot "ci" :region 'left :order -1 :icon "!"
                    :role 'green :empty nil
                    :on-click (lambda (_) (setq clicked t))
                    :format (lambda (rows)
                              (if (> (length rows) 1)
                                  (list :text (format "%d failing"
                                                      (length rows))
                                        :role 'red :urgency 'critical)
                                (format "%s failing"
                                        (cdr (assoc "name" (car rows))))))))
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("name") '("main"))
        (let ((plist (cdar sets)))
          (should (equal (caar sets) "ci"))
          (should (equal (plist-get plist :text) "main failing"))
          (should (eq (plist-get plist :region) 'left))
          (should (= (plist-get plist :order) -1))
          (should (equal (plist-get plist :icon) "!"))
          (should (eq (plist-get plist :role) 'green))
          (should (functionp (plist-get plist :on-click)))
          ;; Not the sink's own keys: the slot layer would refuse them.
          (should-not (plist-member plist :format))
          (should-not (plist-member plist :empty))
          (should-not (plist-member plist :slot)))
        ;; What the function returns goes over what the option said.
        (cmacs-lql-watch-tests--advance 10)
        (cmacs-lql-watch-tests--ok '("name") '("main") '("release"))
        (let ((plist (cdar sets)))
          (should (equal (plist-get plist :text) "2 failing"))
          (should (eq (plist-get plist :role) 'red))
          (should (eq (plist-get plist :urgency) 'critical))
          (should (eq (plist-get plist :region) 'left)))
        ;; No rows and `:empty nil': the slot shows nothing, and so
        ;; takes no room, but it is still the watch's.
        (cmacs-lql-watch-tests--advance 10)
        (cmacs-lql-watch-tests--ok '("name"))
        (should (equal (plist-get (cdar sets) :text) ""))
        (should-not removes)
        (should-not clicked)))))

(ert-deftest cmacs-lql-watch-test-bar-slot-text-is-bounded ()
  "What a watch puts on the bar is one line of bounded width."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch-tests--with-bar sets removes
      (let ((cmacs-lql-watch-bar-max-chars 12))
        (cmacs-lql-watch 'long "fetch x" :immediate t :bar "{title}")
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok
         '("title") '("a very long\ntitle that goes on and on"))
        (let ((text (plist-get (cdar sets) :text)))
          (should (<= (string-width text) 12))
          (should-not (string-match-p "\n" text)))
        (should-not removes)))))

(ert-deftest cmacs-lql-watch-test-bar-not-for-agents-or-typos ()
  "An agent's watch gets no slot, and a bad :bar is an error on the watch."
  (cmacs-lql-watch-tests--with
    (cmacs-lql-watch-tests--with-bar sets removes
      ;; An agent choosing a watch name must not write on your bar.
      (cmacs-lql-watch "t1/x" "fetch x" :owner "t1" :immediate t :bar t)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should-not sets)
      (cmacs-lql-unwatch "t1/x")
      (should-not removes)
      ;; A key that does not exist is said, on the watch, not ignored.
      (cmacs-lql-watch 'typo "fetch x" :immediate t
                       :bar '(:format "{rows}" :colour red))
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should-not sets)
      (should (string-match-p ":colour"
                              (cmacs-lql-watch-get 'typo :callback-error)))
      (cmacs-lql-watch 'worse "fetch x" :immediate t :bar 42)
      (cmacs-lql-watch--tick)
      (cmacs-lql-watch-tests--ok '("n") '(1))
      (should-not sets)
      (should (cmacs-lql-watch-get 'worse :callback-error)))))

(ert-deftest cmacs-lql-watch-test-bar-item ()
  "The route from before slots: :widget pushes a `text' setting at a widget."
  (cmacs-lql-watch-tests--with
    (let ((cmacs-lql-watch-sinks--bar-items (make-hash-table :test #'equal))
          pushed)
      (cl-letf (((symbol-function 'cmacs-gowl-bar-push)
                 (lambda (&rest args) (push args pushed))))
        (cmacs-lql-watch 'inbox "fetch x" :every 10
                         :bar '(:widget "label" :format "inbox {rows}: {title}"
                                :empty "inbox clear"))
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("title") '("first\nnote"))
        (should (equal (car pushed)
                       '("label" (("text" . "inbox 1: first note")))))
        (cmacs-lql-watch-tests--advance 10)
        (cmacs-lql-watch-tests--ok '("title"))
        (should (equal (car pushed) '("label" (("text" . "inbox clear")))))
        (should (= (length pushed) 2))
        ;; "label" and "text" as bare strings still mean the widget:
        ;; they were the only values that ever worked as one.
        (cmacs-lql-watch 'old "fetch y" :immediate t :bar "text")
        (cmacs-lql-watch--tick)
        (cmacs-lql-watch-tests--ok '("n") '(1) '(2))
        (should (equal (car pushed) '("text" (("text" . "old: 2")))))
        ;; A widget is the user's to place, so removal only blanks it.
        (cmacs-lql-unwatch 'old)
        (should (equal (car pushed) '("text" (("text" . "")))))))))

(ert-deftest cmacs-lql-watch-test-bar-place-amends ()
  "Placing a widget uses the bar's amendment keys, never a whole region."
  (let (configured)
    (let ((cmacs-gowl-bar-push-function
           (lambda (alist) (setq configured alist))))
      (cmacs-lql-watch-bar-place "label" 'bottom-left)
      (should (equal configured '(("bottom-widgets-left-remove" . "label")
                                  ("bottom-widgets-left-add" . "label"))))
      (cmacs-lql-watch-bar-place "label")
      (should (equal (mapcar #'car configured)
                     '("widgets-right-remove" "widgets-right-add")))
      (should-error (cmacs-lql-watch-bar-place "label" 'middle)))))

(provide 'cmacs-lql-watch-tests)

;;; cmacs-lql-watch-tests.el ends here
