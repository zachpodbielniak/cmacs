;;; cmacs-gowl-bar-keywheel-tests.el --- tests for the key wheel's Emacs face  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Batch tests for lisp/cmacs/cmacs-gowl-bar-keywheel.el.  No bar, no
;; compositor: pushes are captured by rebinding
;; `cmacs-gowl-bar-push-function', and the keymaps walked are private
;; ones built here, so the result does not depend on the user's init.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-bar-ai)
(require 'cmacs-gowl-bar-keywheel)

(defvar cmacs-gowl-bar-keywheel-tests--map nil
  "A private keymap for the tests to walk.")

(defun cmacs-gowl-bar-keywheel-tests--cmd-a ()
  "Open the first test thing.
Second line, never sent."
  (interactive))

(defun cmacs-gowl-bar-keywheel-tests--cmd-b ()
  "Second\tthing with a tab and a \\ backslash."
  (interactive))

(defun cmacs-gowl-bar-keywheel-tests--not-a-command ()
  "Not interactive, so not on the wheel.")

(defun cmacs-gowl-bar-keywheel-tests--build ()
  "A keymap with a nested prefix, junk entries and a mouse binding."
  (let ((map (make-sparse-keymap))
        (sub (make-sparse-keymap))
        (deep (make-sparse-keymap)))
    (define-key map (kbd "C-c a") #'cmacs-gowl-bar-keywheel-tests--cmd-a)
    (define-key map (kbd "C-c u") 'undefined)
    (define-key map (kbd "C-c l") (lambda () (interactive)))
    (define-key map (kbd "C-c n") #'cmacs-gowl-bar-keywheel-tests--not-a-command)
    (define-key map (kbd "C-c <mouse-1>") #'cmacs-gowl-bar-keywheel-tests--cmd-a)
    (define-key sub (kbd "b") #'cmacs-gowl-bar-keywheel-tests--cmd-b)
    (define-key deep (kbd "z") #'cmacs-gowl-bar-keywheel-tests--cmd-a)
    (define-key sub (kbd "d") deep)
    (define-key map (kbd "C-c s") sub)
    (define-key map (kbd "C-x q") #'cmacs-gowl-bar-keywheel-tests--cmd-b)
    map))

(defmacro cmacs-gowl-bar-keywheel-tests--with (sources &rest body)
  "Run BODY walking SOURCES over the private map; capture pushes in `pushed'."
  (declare (indent 1))
  `(let* ((cmacs-gowl-bar-keywheel-tests--map
           (cmacs-gowl-bar-keywheel-tests--build))
          (cmacs-gowl-bar-keywheel-sources ,sources)
          (cmacs-gowl-bar-keywheel-max 300)
          (cmacs-gowl-bar-keywheel-depth 4)
          (cmacs-gowl-bar-keywheel--pushed nil)
          (pushed nil)
          (cmacs-gowl-bar-push-function
           (lambda (alist) (setq pushed (append pushed alist)))))
     (ignore pushed)
     ,@body))

(defun cmacs-gowl-bar-keywheel-tests--unescape (text)
  "The bar's unescape (bar_keywheel_unescape), for round trips."
  (let ((out "") (i 0) (n (length text)))
    (while (< i n)
      (let ((c (aref text i)))
        (if (and (eq c ?\\) (< (1+ i) n))
            (let ((e (aref text (1+ i))))
              (setq out (concat out (pcase e
                                      (?t "\t") (?n "\n")
                                      (_ (string e)))))
              (setq i (+ i 2)))
          (setq out (concat out (string c)))
          (setq i (1+ i)))))
    out))

;; Catches: a tab or newline inside a field splitting the bar's TAB
;; framing, and backslashes not surviving the round trip.
(ert-deftest cmacs-gowl-bar-keywheel-test-escape-round-trip ()
  (dolist (text '("plain" "a\tb" "line\nnext" "back\\slash" "\\t literal"
                  "" "mix\t\\\n"))
    (let ((esc (cmacs-gowl-bar-keywheel--escape text)))
      (should-not (string-match-p "[\t\n]" esc))
      (should (equal (cmacs-gowl-bar-keywheel-tests--unescape esc) text)))))

;; Catches: the walk missing nested prefixes, picking up `undefined',
;; lambdas, non-commands or mouse events, or ignoring the prefix.
(ert-deftest cmacs-gowl-bar-keywheel-test-collect ()
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))
    (let* ((entries (cmacs-gowl-bar-keywheel-collect))
           (keys (mapcar #'car entries)))
      (should (equal keys '("C-c a" "C-c s b" "C-c s d z")))
      (should (eq (nth 1 (assoc "C-c a" entries))
                  'cmacs-gowl-bar-keywheel-tests--cmd-a))
      ;; Only the first doc line.
      (should (equal (nth 2 (assoc "C-c a" entries))
                     "Open the first test thing.")))))

;; Catches: a prefix the map does not have walking nothing; a nil
;; prefix walking only part of the map; the depth bound being ignored.
(ert-deftest cmacs-gowl-bar-keywheel-test-sources ()
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "SPC"))
    ;; SPC is not a prefix here: the whole map, shown under SPC.
    (let ((keys (mapcar #'car (cmacs-gowl-bar-keywheel-collect))))
      (should (member "SPC C-c a" keys))
      (should (member "SPC C-x q" keys))))
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map))
    (let ((keys (mapcar #'car (cmacs-gowl-bar-keywheel-collect))))
      (should (member "C-x q" keys))
      (should (member "C-c s d z" keys))))
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))
    (let ((cmacs-gowl-bar-keywheel-depth 1))
      (should-not (member "C-c s d z"
                          (mapcar #'car (cmacs-gowl-bar-keywheel-collect))))))
  ;; Unbound and non-keymap variables are skipped, not errors.
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--no-such-map . "C-c")
        (cmacs-gowl-bar-keywheel-max . "C-c"))
    (should (null (cmacs-gowl-bar-keywheel-collect)))))

;; Catches: the bar being sent more than it will read, which would also
;; let `run' accept commands the wheel never showed.
(ert-deftest cmacs-gowl-bar-keywheel-test-cap ()
  (let ((big (make-sparse-keymap)))
    (dotimes (i 400)
      (define-key big (vector ?\C-c (+ #x4e00 i))
                  #'cmacs-gowl-bar-keywheel-tests--cmd-a))
    (cmacs-gowl-bar-keywheel-tests--with nil
      (setq cmacs-gowl-bar-keywheel-tests--map big)
      (let ((cmacs-gowl-bar-keywheel-sources
             '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))))
        (should (= (length (cmacs-gowl-bar-keywheel-collect)) 300))
        (let ((cmacs-gowl-bar-keywheel-max 5000))
          (should (= (length (cmacs-gowl-bar-keywheel-collect)) 300)))
        (let ((cmacs-gowl-bar-keywheel-max 7))
          (should (= (cmacs-gowl-bar-keywheel-push) 7))
          (should (equal (cdr (assoc "keywheel.emacs.count" pushed))
                         "7")))))))

;; Catches: the push not matching the bar's contract -- the count, the
;; numbered keys, the TAB framing, both bar positions.
(ert-deftest cmacs-gowl-bar-keywheel-test-push ()
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))
    (should (= (cmacs-gowl-bar-keywheel-push) 3))
    (should (equal (cdr (assoc "keywheel.emacs.count" pushed)) "3"))
    (should (equal (cdr (assoc "bottom-keywheel.emacs.count" pushed)) "3"))
    (should (equal (cdr (assoc "keywheel.emacs.0" pushed))
                   (concat "C-c a\tcmacs-gowl-bar-keywheel-tests--cmd-a\t"
                           "Open the first test thing.")))
    ;; The doc's own tab and backslash are escaped, not framing.
    (let ((fields (split-string (cdr (assoc "keywheel.emacs.1" pushed))
                                "\t")))
      (should (= (length fields) 3))
      (should (equal (cmacs-gowl-bar-keywheel-tests--unescape (nth 2 fields))
                     "Second\tthing with a tab and a \\ backslash.")))
    (should-not (assoc "keywheel.emacs.3" pushed))))

;; Catches: a push that signals when the bar is not there.
(ert-deftest cmacs-gowl-bar-keywheel-test-push-never-signals ()
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))
    (let ((cmacs-gowl-bar-push-function
           (lambda (_alist) (error "No bar"))))
      (should (= (cmacs-gowl-bar-keywheel-push) 3)))))

;; Catches: `run' running a command the bar was never shown (anything
;; reachable through emacsctl could name one), running it inside the
;; RPC instead of from a timer, or signalling on junk.
(ert-deftest cmacs-gowl-bar-keywheel-test-run ()
  (cmacs-gowl-bar-keywheel-tests--with
      '((cmacs-gowl-bar-keywheel-tests--map . "C-c"))
    (let ((scheduled nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args) (push args scheduled) nil)))
        ;; Nothing pushed yet: nothing runs.
        (should-not (cmacs-gowl-bar-keywheel-run
                     "cmacs-gowl-bar-keywheel-tests--cmd-a"))
        (cmacs-gowl-bar-keywheel-push)
        (should (eq t (cmacs-gowl-bar-keywheel-run
                       "cmacs-gowl-bar-keywheel-tests--cmd-a")))
        (should (= (length scheduled) 1))
        (should (eq (nth 3 (car scheduled))
                    'cmacs-gowl-bar-keywheel-tests--cmd-a))
        ;; A real command that was not pushed.
        (should-not (cmacs-gowl-bar-keywheel-run "kill-emacs"))
        (should-not (cmacs-gowl-bar-keywheel-run "save-buffers-kill-emacs"))
        (should-not (cmacs-gowl-bar-keywheel-run 'kill-emacs))
        (should-not (cmacs-gowl-bar-keywheel-run nil))
        (should-not (cmacs-gowl-bar-keywheel-run "no-such-function-xyz"))
        (should (= (length scheduled) 1))))))

;; Catches: a command that errors (or is quit) escaping the timer as an
;; error, which would be reported as a timer failure and lose the reason.
(ert-deftest cmacs-gowl-bar-keywheel-test-call-reports ()
  (let ((cmacs-gowl-bar-keywheel-raise-frame nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)))
              ((symbol-function 'call-interactively)
               (lambda (&rest _) (error "Boom"))))
      (cmacs-gowl-bar-keywheel--call 'ignore)
      (should (string-match-p "Boom" (car messages))))))

;; Catches: setup pushing synchronously (before init finishes binding
;; keys) instead of from an idle timer.
(ert-deftest cmacs-gowl-bar-keywheel-test-setup-defers ()
  (let ((timers nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest args) (push args timers) nil)))
      (should (cmacs-gowl-bar-keywheel-setup))
      (should (= (length timers) 1))
      (should (eq (nth 2 (car timers)) #'cmacs-gowl-bar-keywheel-push)))))

;;; cmacs-gowl-bar-keywheel-tests.el ends here
