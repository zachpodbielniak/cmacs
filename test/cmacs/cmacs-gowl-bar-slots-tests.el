;;; cmacs-gowl-bar-slots-tests.el --- Tests for bar slots from Elisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-bar-slot-set' and friends (cmacs-gowl-bar-slots.el) are
;; how Elisp puts an item on the gowl bar.  No bar runs here: the one
;; function that would reach one, `cmacs-gowl-bar-slots-command-function',
;; is rebound to record what it was given and answer as the bar would.
;;
;; What would go wrong unnoticed without these:
;;
;;   - a push that sends only what changed, so a slot the bar lost is
;;     never made again;
;;   - a click handler run inside the compositor's signal dispatch, or
;;     one that signals taking the hook down with it;
;;   - a click on somebody else's slot of the same id running OUR
;;     handler;
;;   - a hex colour reaching the bar from a caller that meant well;
;;   - a refused push reported on every tick of a timer;
;;   - slots that linger after the code that made them is gone.
;;
;; The C half (cmacs/gowl/cmacs-gowl-bar-slots.c) is held to the gowl
;; lock rules by source, the way cmacs-gowl-tests.el holds cmacs-gowl.c:
;; nothing in the suite can be made to race it.  The primitives
;; themselves need a compositor and are only touched when one of them is
;; bound and nothing is running.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-bar-slots)

;; The primitives are C; an Emacs built before them does not have them,
;; and the one test that calls them skips itself there.
(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-bar-slot-set "cmacs-gowl-bar-slots.c" (id fields))
(declare-function gowl-bar-slot-remove "cmacs-gowl-bar-slots.c"
                  (id &optional owner))
(declare-function gowl-bar-slot-clear "cmacs-gowl-bar-slots.c" (owner))
(declare-function gowl-bar-slot-list "cmacs-gowl-bar-slots.c"
                  (&optional owner))

(defvar cmacs-gowl-bar-slots-tests--this-file
  (or load-file-name buffer-file-name)
  "Where this file was loaded from, to find the C source beside it.")

(defmacro cmacs-gowl-bar-slots-tests--with (calls &rest body)
  "Run BODY with an empty slot table and a recording bar.
CALLS is bound to the list of (OP . ARGS) sent, oldest first, as BODY
runs.  The bar answers `set' with \"created ID\" the first time it
sees an id and \"updated ID\" after, like the real one."
  (declare (indent 1))
  `(let* ((,calls nil)
          (seen nil)
          (cmacs-gowl-bar-slots--table (make-hash-table :test #'equal))
          (cmacs-gowl-bar-slots--reported (make-hash-table :test #'equal))
          (cmacs-gowl-bar-slots-owner "cmacs")
          (cmacs-gowl-bar-slots-max-text 120)
          (cmacs-gowl-bar-slots-command-function
           (lambda (op &rest args)
             (setq ,calls (append ,calls (list (cons op args))))
             (pcase op
               ('set (prog1 (format "%s %s\n"
                                    (if (member (car args) seen)
                                        "updated" "created")
                                    (car args))
                       (cl-pushnew (car args) seen :test #'equal)))
               ('remove (format "removed %s\n" (car args)))
               ('clear "removed 0\n")
               ('list "[]\n")))))
     (unwind-protect
         (progn ,@body)
       ;; No timer a test started may outlive it.
       (maphash (lambda (_id plist)
                  (when (timerp (plist-get plist :timer))
                    (cancel-timer (plist-get plist :timer))))
                cmacs-gowl-bar-slots--table))))

(defun cmacs-gowl-bar-slots-tests--field (call key)
  "The value of the field KEY in CALL, a recorded `set'."
  (cdr (assoc key (nth 2 call))))

;;;; Setting

(ert-deftest cmacs-gowl-bar-slots-test-set-sends-every-field ()
  "A push carries the whole slot, defaults included.
The bar ignores what has not changed, and a slot it lost -- the
compositor restarted, somebody cleared it -- is made again by the
push that would have updated it.  A push of only the changed key
would update nothing and say so to nobody."
  (cmacs-gowl-bar-slots-tests--with calls
    (should (cmacs-gowl-bar-slot-set "mail" :text "3 unread" :role 'peach
                                     :region 'left :order -1))
    (let ((call (car calls)))
      (should (eq (car call) 'set))
      (should (equal (nth 1 call) "mail"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "text")
                     "3 unread"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "role") "peach"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "region")
                     "left"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "order") -1))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "owner")
                     "cmacs"))
      ;; What was not said goes as its default, not as nothing.
      (should (equal (cmacs-gowl-bar-slots-tests--field call "bar") "top"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "urgency")
                     "normal"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "icon") ""))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "output") ""))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "ttl") 0))
      (should-not (cmacs-gowl-bar-slots-tests--field call "click")))
    ;; A second call names one key; the rest is remembered and resent.
    (should (cmacs-gowl-bar-slot-set 'mail :text "4 unread"))
    (let ((call (nth 1 calls)))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "text")
                     "4 unread"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "role") "peach"))
      (should (equal (cmacs-gowl-bar-slots-tests--field call "region")
                     "left")))
    (should (= (length calls) 2))))

(ert-deftest cmacs-gowl-bar-slots-test-text-is-one-bounded-line ()
  "Text reaches the bar as one line of bounded width, without properties."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((cmacs-gowl-bar-slots-max-text 10))
      (cmacs-gowl-bar-slot-set "a" :text "one\ntwo\tthree four five")
      (let ((text (cmacs-gowl-bar-slots-tests--field (car calls) "text")))
        (should-not (string-match-p "[\n\t]" text))
        (should (<= (string-width text) 10))
        (should (string-prefix-p "one two" text))))
    (cmacs-gowl-bar-slot-set "b" :text (propertize "plain" 'face 'bold))
    (let ((text (cmacs-gowl-bar-slots-tests--field (nth 1 calls) "text")))
      (should (equal text "plain"))
      (should-not (text-properties-at 0 text)))
    ;; nil is "nothing to show", and a number is shown as one.
    (cmacs-gowl-bar-slot-set "c" :text nil)
    (should (equal (cmacs-gowl-bar-slots-tests--field (nth 2 calls) "text")
                   ""))
    (cmacs-gowl-bar-slot-set "c" :text 7)
    (should (equal (cmacs-gowl-bar-slots-tests--field (nth 3 calls) "text")
                   "7"))))

(ert-deftest cmacs-gowl-bar-slots-test-bad-arguments-signal-and-send-nothing ()
  "A slot that could never be right is an error where it was written."
  (cmacs-gowl-bar-slots-tests--with calls
    ;; A role is a theme role.  Never a colour.
    (should-error (cmacs-gowl-bar-slot-set "x" :role "#ff0000"))
    (should-error (cmacs-gowl-bar-slot-set "x" :role 'crimson))
    (should-error (cmacs-gowl-bar-slot-set "x" :urgency 'loud))
    (should-error (cmacs-gowl-bar-slot-set "x" :region 'top))
    (should-error (cmacs-gowl-bar-slot-set "x" :bar 'left))
    (should-error (cmacs-gowl-bar-slot-set "x" :order "1"))
    (should-error (cmacs-gowl-bar-slot-set "x" :on-click "not a function"))
    (should-error (cmacs-gowl-bar-slot-set "x" :colour 'red))
    (should-error (cmacs-gowl-bar-slot-set "x" :text))
    ;; An id is a word.
    (should-error (cmacs-gowl-bar-slot-set "two words" :text "x"))
    (should-error (cmacs-gowl-bar-slot-set "a:b" :text "x"))
    (should-error (cmacs-gowl-bar-slot-set "--all" :text "x"))
    (should-error (cmacs-gowl-bar-slot-set "" :text "x"))
    (should-error (cmacs-gowl-bar-slot-set (make-string 65 ?a) :text "x"))
    (should-not calls)
    (should (= 0 (hash-table-count cmacs-gowl-bar-slots--table)))
    ;; Every role the bar documents is accepted, as symbol or string.
    (dolist (role cmacs-gowl-bar-slot-roles)
      (should (cmacs-gowl-bar-slot-set "ok" :role role))
      (should (cmacs-gowl-bar-slot-set "ok" :role (intern role))))
    ;; `centre' is spelt the bar's way on the wire.
    (cmacs-gowl-bar-slot-set "ok" :region 'centre)
    (should (equal (cmacs-gowl-bar-slots-tests--field (car (last calls))
                                                      "region")
                   "center"))))

(ert-deftest cmacs-gowl-bar-slots-test-id-from-any-name ()
  "`cmacs-gowl-bar-slot-id' gives every name a valid id, and the same one."
  (dolist (name '("inbox" "unread mail" "ci/main: failing" "--all" "..x"
                  "ümlaut" "" "a@5" foo:bar))
    (let ((id (cmacs-gowl-bar-slot-id name)))
      (ert-info ((format "%S -> %S" name id))
        (should (equal id (cmacs-gowl-bar-slots--check-id id)))
        (should (equal id (cmacs-gowl-bar-slot-id name))))))
  (should (equal (cmacs-gowl-bar-slot-id "inbox") "inbox"))
  (should (equal (cmacs-gowl-bar-slot-id "unread mail") "unread-mail"))
  (should (<= (length (cmacs-gowl-bar-slot-id (make-string 200 ?a))) 64)))

;;;; No bar, and a bar that refuses

(ert-deftest cmacs-gowl-bar-slots-test-no-bar-is-not-an-error ()
  "With no compositor a slot is remembered, and nothing signals."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((cmacs-gowl-bar-slots-command-function (lambda (&rest _) nil)))
      (should-not (cmacs-gowl-bar-slot-set "later" :text "soon"))
      (should (equal (plist-get (gethash "later" cmacs-gowl-bar-slots--table)
                                :text)
                     "soon"))
      (should (cmacs-gowl-bar-slot-remove "later"))
      (should-not (cmacs-gowl-bar-slot-remove "later"))
      (should-not (cmacs-gowl-bar-slot-list t)))
    ;; The real backend with nothing running asks nobody.
    (let ((cmacs-gowl-bar-slots-command-function
           #'cmacs-gowl-bar-slots--command))
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
        (should-not (cmacs-gowl-bar-slot-set "later" :text "soon"))
        (should-not (cmacs-gowl-bar-slots-restore))))))

(ert-deftest cmacs-gowl-bar-slots-test-a-refusal-is-said-once ()
  "A push the bar refuses returns nil and is reported once, not per tick."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((messages nil)
          (reply "error: there are already 64 bar slots; remove one first\n"))
      (let ((cmacs-gowl-bar-slots-command-function (lambda (&rest _) reply)))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (should-not (cmacs-gowl-bar-slot-set "full" :text "1"))
          (should-not (cmacs-gowl-bar-slot-set "full" :text "2"))
          (should-not (cmacs-gowl-bar-slot-set "full" :text "3"))
          (should (= (length messages) 1))
          (should (string-match-p "64 bar slots" (car messages)))
          ;; A different reason is news.
          (setq reply "error: slot `full' belongs to `other'\n")
          (should-not (cmacs-gowl-bar-slot-set "full" :text "4"))
          (should (= (length messages) 2))
          ;; So is the same reason after it worked in between.
          (setq reply "updated full\n")
          (should (cmacs-gowl-bar-slot-set "full" :text "5"))
          (setq reply "error: slot `full' belongs to `other'\n")
          (should-not (cmacs-gowl-bar-slot-set "full" :text "6"))
          (should (= (length messages) 3))))
      ;; A backend that signals is a refusal, not an error here.
      (let ((cmacs-gowl-bar-slots-command-function
             (lambda (&rest _) (error "No bar module"))))
        (cl-letf (((symbol-function 'message) #'ignore))
          (should-not (cmacs-gowl-bar-slot-set "full" :text "7")))))))

;;;; Removing

(ert-deftest cmacs-gowl-bar-slots-test-remove-and-clear-by-owner ()
  "Removal names our owner tag; `-clear' takes one package's slots or all."
  (cmacs-gowl-bar-slots-tests--with calls
    (cmacs-gowl-bar-slot-set "a" :text "1" :owner 'pkg-one)
    (cmacs-gowl-bar-slot-set "b" :text "2" :owner 'pkg-one)
    (cmacs-gowl-bar-slot-set "c" :text "3" :owner 'pkg-two)
    (cmacs-gowl-bar-slot-set "d" :text "4")
    (setq calls nil)

    (should (cmacs-gowl-bar-slot-remove "d"))
    ;; With the tag: a slot of that id made by somebody else is refused
    ;; by the bar rather than taken off it.
    (should (equal calls '((remove "d" "cmacs"))))
    (setq calls nil)

    (should (= 2 (cmacs-gowl-bar-slot-clear 'pkg-one)))
    (should (equal (sort (mapcar #'cadr calls) #'string<) '("a" "b")))
    (should (cl-every (lambda (c) (eq (car c) 'remove)) calls))
    (should (equal (mapcar #'car (cmacs-gowl-bar-slot-list)) '("c")))
    (setq calls nil)

    ;; Everything: one call that also drops what this table never knew.
    (should (= 1 (cmacs-gowl-bar-slot-clear)))
    (should (equal calls '((clear "cmacs"))))
    (should-not (cmacs-gowl-bar-slot-list))))

(ert-deftest cmacs-gowl-bar-slots-test-list ()
  "The list is the table by id; LIVE parses what the bar answers."
  (cmacs-gowl-bar-slots-tests--with calls
    (cmacs-gowl-bar-slot-set "zeta" :text "z")
    (cmacs-gowl-bar-slot-set "alpha" :text "a")
    (should (equal (mapcar #'car (cmacs-gowl-bar-slot-list))
                   '("alpha" "zeta")))
    (let ((cmacs-gowl-bar-slots-command-function
           (lambda (op &rest args)
             (should (eq op 'list))
             (should (equal args '("cmacs")))
             (concat "[{\"id\":\"alpha\",\"text\":\"a\",\"click\":false,"
                     "\"order\":0,\"placed\":true}]\n"))))
      (let ((live (cmacs-gowl-bar-slot-list t)))
        (should (= (length live) 1))
        (should (equal (alist-get 'id (car live)) "alpha"))
        (should (eq (alist-get 'placed (car live)) t))
        (should-not (alist-get 'click (car live)))))
    ;; Not JSON: nil, not an error.
    (let ((cmacs-gowl-bar-slots-command-function (lambda (&rest _) "what")))
      (should-not (cmacs-gowl-bar-slot-list t)))))

;;;; Clicks

(ert-deftest cmacs-gowl-bar-slots-test-parse-click ()
  "The bar's click line becomes a plist; anything else becomes nil."
  (should (equal (cmacs-gowl-bar-slots--parse-click
                  "slot-click mail left - eDP-1 cmacs")
                 '(:id "mail" :button left :modifiers nil
                   :output "eDP-1" :owner "cmacs")))
  (should (equal (cmacs-gowl-bar-slots--parse-click
                  "slot-click ci right ctrl+shift - -")
                 '(:id "ci" :button right :modifiers (ctrl shift)
                   :output nil :owner nil)))
  (should-not (cmacs-gowl-bar-slots--parse-click "slot-click mail left"))
  (should-not (cmacs-gowl-bar-slots--parse-click
               "slot-click mail left - eDP-1 cmacs extra"))
  (should-not (cmacs-gowl-bar-slots--parse-click "plugin-loaded pomodoro"))
  (should-not (cmacs-gowl-bar-slots--parse-click nil))
  (should-not (cmacs-gowl-bar-slots--parse-click "")))

(ert-deftest cmacs-gowl-bar-slots-test-click-runs-the-handler-later ()
  "A click reaches its handler from a timer, never inside the event.
The event arrives in the compositor's signal dispatch.  A handler that
prompts or pops a buffer there is running on the thread the desktop is
waiting on, so the dispatch only schedules."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((got nil)
          (scheduled nil))
      (cmacs-gowl-bar-slot-set "mail" :text "3"
                               :on-click (lambda (click) (push click got)))
      ;; The bar is told to report, and is not told the function.
      (should (eq t (cmacs-gowl-bar-slots-tests--field (car calls) "click")))
      (should-not (cl-some #'functionp (mapcar #'cdr (nth 2 (car calls)))))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (time repeat fn &rest args)
                   (should (equal time 0))
                   (should-not repeat)
                   (push (cons fn args) scheduled)
                   nil)))
        (cmacs-gowl-bar-slots--on-module-event
         "bar" "slot-click mail left ctrl eDP-1 cmacs")
        ;; Nothing has run yet.
        (should-not got)
        (should (= (length scheduled) 1))
        ;; Not ours: another module, another owner, an unknown slot, a
        ;; slot with no handler, a line that is not a click.
        (cmacs-gowl-bar-slot-set "quiet" :text "x")
        (cmacs-gowl-bar-slots--on-module-event
         "hotkey" "slot-click mail left - eDP-1 cmacs")
        (cmacs-gowl-bar-slots--on-module-event
         "bar" "slot-click mail left - eDP-1 somebody-else")
        (cmacs-gowl-bar-slots--on-module-event
         "bar" "slot-click mail left - eDP-1 -")
        (cmacs-gowl-bar-slots--on-module-event
         "bar" "slot-click nosuch left - eDP-1 cmacs")
        (cmacs-gowl-bar-slots--on-module-event
         "bar" "slot-click quiet left - eDP-1 cmacs")
        (cmacs-gowl-bar-slots--on-module-event "bar" "something else")
        (cmacs-gowl-bar-slots--on-module-event "bar" nil)
        (should (= (length scheduled) 1)))
      ;; What the timer would do.
      (apply (caar scheduled) (cdar scheduled))
      (should (equal got '((:id "mail" :button left :modifiers (ctrl)
                            :output "eDP-1")))))))

(ert-deftest cmacs-gowl-bar-slots-test-a-failing-handler-is-contained ()
  "A handler that signals is reported; it does not signal out of the timer."
  (cl-letf (((symbol-function 'message) #'ignore))
    (should-not (condition-case nil
                    (progn
                      (cmacs-gowl-bar-slots--call-handler
                       (lambda (_) (error "Boom")) '(:id "x"))
                      nil)
                  (error t)))))

(ert-deftest cmacs-gowl-bar-slots-test-listens-for-module-events ()
  "Loading the file is what connects clicks; nothing else has to."
  (should (memq #'cmacs-gowl-bar-slots--on-module-event
                (default-value 'cmacs-gowl-module-event-functions))))

;;;; Definitions

(ert-deftest cmacs-gowl-bar-slots-test-define-slot ()
  "`cmacs-gowl-bar-define-slot' replaces, refreshes, and times itself."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((value "one"))
      (cmacs-gowl-bar-define-slot task
        :region 'left :role 'accent
        :update (lambda () value)
        :every 3600)
      (should (equal (cmacs-gowl-bar-slots-tests--field (car calls) "text")
                     "one"))
      (should (equal (cmacs-gowl-bar-slots-tests--field (car calls) "region")
                     "left"))
      (should (timerp (plist-get (gethash "task" cmacs-gowl-bar-slots--table)
                                 :timer)))
      ;; A refresh asks the function again.
      (setq value "two")
      (cmacs-gowl-bar-slot-refresh "task")
      (should (equal (cmacs-gowl-bar-slots-tests--field (car (last calls))
                                                        "text")
                     "two"))
      ;; nil is nothing to show; a plist changes more than the text.
      (setq value nil)
      (cmacs-gowl-bar-slot-refresh)
      (should (equal (cmacs-gowl-bar-slots-tests--field (car (last calls))
                                                        "text")
                     ""))
      (setq value '(:text "late" :urgency critical))
      (cmacs-gowl-bar-slot-refresh "task")
      (should (equal (cmacs-gowl-bar-slots-tests--field (car (last calls))
                                                        "urgency")
                     "critical"))
      ;; An update that signals leaves the slot as it was.
      (let ((before (length calls)))
        (cl-letf (((symbol-function 'message) #'ignore))
          (setq value '(:role "#ff0000"))
          (cmacs-gowl-bar-slot-refresh "task"))
        (should (= (length calls) before)))

      ;; Redefining replaces: the old keys do not leak through, and the
      ;; old timer is gone.
      (let ((old-timer (plist-get (gethash "task"
                                           cmacs-gowl-bar-slots--table)
                                  :timer)))
        (cmacs-gowl-bar-define-slot task :text "fixed")
        (should-not (memq old-timer timer-list))
        (let ((plist (gethash "task" cmacs-gowl-bar-slots--table)))
          (should-not (plist-get plist :timer))
          (should-not (plist-get plist :update))
          (should-not (plist-get plist :role)))
        (should (equal (cmacs-gowl-bar-slots-tests--field (car (last calls))
                                                          "region")
                       "right")))
      ;; Removing a timed slot stops its timer.
      (cmacs-gowl-bar-define-slot timed :update (lambda () "x") :every 3600)
      (let ((timer (plist-get (gethash "timed" cmacs-gowl-bar-slots--table)
                              :timer)))
        (should (memq timer timer-list))
        (cmacs-gowl-bar-slot-remove "timed")
        (should-not (memq timer timer-list))))))

;;;; Restoring

(ert-deftest cmacs-gowl-bar-slots-test-restore-clears-then-pushes-all ()
  "A restore drops what our tag owns, then shows what the table holds."
  (cmacs-gowl-bar-slots-tests--with calls
    (let ((cmacs-gowl-bar-slots-command-function (lambda (&rest _) nil)))
      ;; Set before there was a bar.
      (cmacs-gowl-bar-slot-set "b" :text "2")
      (cmacs-gowl-bar-slot-set "a" :text "1"))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t)))
      (should (= 2 (cmacs-gowl-bar-slots-restore))))
    (should (equal (car calls) '(clear "cmacs")))
    (should (equal (mapcar #'car (cdr calls)) '(set set)))
    (should (equal (mapcar #'cadr (cdr calls)) '("a" "b")))
    ;; What `cmacs-gowl-mode' calls does the same, and cannot signal
    ;; into the compositor's startup.
    (setq calls nil)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t)))
      (should (= 2 (cmacs-gowl-bar-slots--on-start)))
      (should (equal (car calls) '(clear "cmacs")))
      ;; A bar that fails every call took nothing; that is a count of
      ;; zero, not an error.
      (let ((cmacs-gowl-bar-slots-command-function
             (lambda (&rest _) (signal 'wrong-type-argument '(oops)))))
        (cl-letf (((symbol-function 'message) #'ignore))
          (should (equal 0 (cmacs-gowl-bar-slots--on-start)))))
      (cl-letf (((symbol-function 'cmacs-gowl-bar-slots-restore)
                 (lambda (&rest _) (error "Boom")))
                ((symbol-function 'message) #'ignore))
        (should-not (cmacs-gowl-bar-slots--on-start))))))

;;;; The primitives

(ert-deftest cmacs-gowl-bar-slots-test-primitives-without-a-compositor ()
  "With nothing running the primitives answer nil, and check their arguments."
  (skip-unless (and (fboundp 'gowl-bar-slot-set)
                    (fboundp 'gowl-running-p)
                    (not (gowl-running-p))))
  (should-not (gowl-bar-slot-set "x" '(("text" . "hello"))))
  (should-not (gowl-bar-slot-set "x" '((:text . "hello") (click . t)
                                       ("order" . 3))))
  (should-not (gowl-bar-slot-remove "x"))
  (should-not (gowl-bar-slot-remove "x" "cmacs"))
  (should-not (gowl-bar-slot-clear "cmacs"))
  (should-not (gowl-bar-slot-clear t))
  (should-not (gowl-bar-slot-list))
  (should-not (gowl-bar-slot-list "cmacs"))
  ;; An id is one word, and a value is a string, an integer, t or nil.
  (should-error (gowl-bar-slot-set "two words" nil))
  (should-error (gowl-bar-slot-set "" nil))
  (should-error (gowl-bar-slot-set 'sym nil))
  (should-error (gowl-bar-slot-set "x" '(("text" . 1.5))))
  (should-error (gowl-bar-slot-set "x" '(("text" . (a list)))))
  (should-error (gowl-bar-slot-set "x" '(not-a-cell)))
  (should-error (gowl-bar-slot-set "x" '((nil . "v"))))
  (should-error (gowl-bar-slot-remove "a b"))
  (should-error (gowl-bar-slot-remove "a" "b c"))
  (should-error (gowl-bar-slot-clear "--all"))
  (should-error (gowl-bar-slot-clear nil)))

(defun cmacs-gowl-bar-slots-tests--c-source ()
  "The text of cmacs-gowl-bar-slots.c with comments removed, or nil."
  (let* ((here cmacs-gowl-bar-slots-tests--this-file)
         (file (and here
                    (expand-file-name
                     "../../cmacs/gowl/cmacs-gowl-bar-slots.c"
                     (file-name-directory here)))))
    (when (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "/\\*" nil t)
          (let ((start (match-beginning 0)))
            (if (re-search-forward "\\*/" nil t)
                (delete-region start (point))
              (delete-region start (point-max)))))
        (buffer-string)))))

(ert-deftest cmacs-gowl-bar-slots-test-c-calls-gowl-only-under-the-lock ()
  "Every call into gowl in the C half is made with the gowl lock held.
The bar runs on the compositor's dispatch thread; a command sent to it
from Emacs's thread without the lock races its repaint.  The file has
one function that calls gowl, and that function takes the scoped lock
first and leaves only through `unbind_to' -- a plain `return' after
the lock keeps the mutex and freezes the desktop.

The same two rules `cmacs-gowl-tests.el' holds cmacs-gowl.c to; that
suite reads cmacs-gowl.c and cmacs-gowl-pointer.c only."
  (let ((source (cmacs-gowl-bar-slots-tests--c-source))
        (case-fold-search nil))
    (skip-unless source)
    ;; Split at top-level function starts: a name in column 0 followed
    ;; by an opening parenthesis, or a DEFUN.
    (let ((chunks nil)
          (starts nil)
          (pos 0))
      (while (string-match "^\\(?:DEFUN (\"\\([^\"]+\\)\"\\|\\([a-z_0-9]+\\) (\\)"
                           source pos)
        (push (cons (or (match-string 1 source) (match-string 2 source))
                    (match-beginning 0))
              starts)
        (setq pos (match-end 0)))
      (setq starts (nreverse starts))
      (while starts
        (let ((this (pop starts)))
          (push (cons (car this)
                      (substring source (cdr this)
                                 (if starts (cdar starts) (length source))))
                chunks)))
      (should (>= (length chunks) 6))
      (let ((callers nil))
        (dolist (chunk chunks)
          (when (string-match-p "\\_<gowl_[a-z0-9_]+[[:space:]]*(" (cdr chunk))
            (push (car chunk) callers)
            (ert-info ((format "%s calls into gowl" (car chunk)))
              (should (string-match-p "cmacs_gowl_lock_scoped ()"
                                      (cdr chunk)))
              ;; The lock comes before the first call into gowl.
              (should (< (string-match "cmacs_gowl_lock_scoped ()"
                                       (cdr chunk))
                         (string-match "\\_<gowl_[a-z0-9_]+[[:space:]]*("
                                       (cdr chunk))))
              ;; And every way out goes through `unbind_to'.
              (let ((body (substring (cdr chunk)
                                     (string-match "cmacs_gowl_lock_scoped ()"
                                                   (cdr chunk))))
                    (at 0))
                (while (string-match "^.*\\_<return\\_>.*$" body at)
                  (should (string-match-p "unbind_to" (match-string 0 body)))
                  (setq at (match-end 0)))))))
        ;; Sanity: the walk found the one function, so the checks above
        ;; were not vacuous -- and it is still only one.
        (should (equal callers '("bar_slots_command")))))
    ;; The release is on the specpdl, so a signal cannot strand it.
    (should (string-match-p "record_unwind_protect_void (cmacs_gowl_unlock)"
                            source))
    ;; Nothing here keeps a Lisp object in C memory or runs Lisp from a
    ;; callback: there are no callbacks.
    (should-not (string-match-p "staticpro\\|g_idle_add\\|g_signal_connect"
                                source))))

(provide 'cmacs-gowl-bar-slots-tests)

;;; cmacs-gowl-bar-slots-tests.el ends here
