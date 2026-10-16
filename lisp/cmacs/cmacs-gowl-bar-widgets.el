;;; cmacs-gowl-bar-widgets.el --- cmacs defaults for gowl's extended bar widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl ships an extended set of bar widgets (docs/bar-widgets/ in the
;; gowl tree): ai-assistant, ai-rewrite, meeting-notes, translate,
;; keywheel, webmail, devservices, netshares, tvremote, wow-gold, and an
;; activity style for the cpu widget.  Standalone gowl turns none of
;; them on.  Under `cmacs --gowl' this file decides what is on and wires
;; the widgets to cmacs:
;;
;;   - `cmacs-gowl-bar-cpu-style' puts the cpu widget in its activity
;;     ("creature") style;
;;   - `cmacs-gowl-bar-default-widgets' adds widgets to the bar --
;;     meeting-notes and ai-assistant by default;
;;   - every AI-capable widget is pointed at cmacs-ai
;;     (`ai-backend: cmacs'), so it uses the providers configured here
;;     and nothing is configured twice;
;;   - `cmacs-gowl-bar-widgets-setup-functions' lets each widget's cmacs
;;     half push what it needs (meeting destinations, rewrite actions,
;;     provider lists ...).
;;
;; All of it goes through the bar's AMENDMENT keys (widgets-right-add
;; and friends), never a wholesale region list, so the shipped layout --
;; and anything the user configured -- is left alone, and running it
;; twice adds nothing twice (each add is preceded by its remove).
;;
;; `cmacs-gowl-bar-widgets-apply' is called once from cmacs-gowl.el when
;; the compositor's bar comes up.  Call it again after changing these
;; options, or toggle them with the customize interface.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)

(declare-function cmacs-gowl-bar-configure-top "cmacs-gowl" (alist))
(declare-function cmacs-gowl-bar-configure-bottom "cmacs-gowl" (alist))

(defcustom cmacs-gowl-bar-cpu-style 'creature
  "The style of the bar's cpu widget under cmacs --gowl.

`creature' is the activity style: a small character whose eyes show CPU
and memory and whose body fills with load, with a process list and
per-core map in its panel.  `label' is the plain \"CPU 23%\" text.  nil
leaves whatever the bar configuration says."
  :type '(choice (const :tag "Activity creature" creature)
                 (const :tag "Plain label" label)
                 (const :tag "Leave it alone" nil))
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-default-widgets
  '(("meeting-notes" . top-right)
    ("ai-assistant" . top-right))
  "Extended bar widgets cmacs --gowl turns on, and where.

Each element is (WIDGET . PLACE): WIDGET a gowl bar widget name, PLACE
one of `top-left', `top-center', `top-right', `bottom-left',
`bottom-center', `bottom-right'.  Remove an element to turn that widget
off; add one -- (\"wow-gold\" . bottom-right), say -- to turn another
on.  Widgets added to a right region land nearest the centre, in this
order.  Adding to a centre region resets the bar's centre anchor, so
prefer a side region."
  :type '(repeat (cons (string :tag "Widget")
                       (choice (const top-left) (const top-center)
                               (const top-right) (const bottom-left)
                               (const bottom-center) (const bottom-right))))
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-ai-widgets
  '("ai-assistant" "ai-rewrite" "translate" "meeting-notes")
  "Bar widgets told to use cmacs-ai (`ai-backend: cmacs').

Each is pushed whether or not it is on the bar, so adding one later
needs no further configuration.  Remove a widget here to let it use
ai-glib's `ai' command instead."
  :type '(repeat string)
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-widgets-setup-functions
  '(cmacs-gowl-bar-assistant-push
    cmacs-gowl-bar-meeting-push
    cmacs-gowl-bar-rewrite-push
    cmacs-gowl-bar-keywheel-push)
  "Functions that push cmacs state into the extended bar widgets.

Called with no arguments by `cmacs-gowl-bar-widgets-apply', each one if
it is defined.  A function that signals is reported and skipped; the
rest still run."
  :type '(repeat function)
  :group 'cmacs-gowl-bar)

(defvar cmacs-gowl-bar-widgets-configure-function
  #'cmacs-gowl-bar-widgets--configure
  "How an alist for one bar is applied.  Tests rebind it.
Called with (BAR ALIST), BAR being `top' or `bottom'.")

(defun cmacs-gowl-bar-widgets--configure (bar alist)
  "Send ALIST to BAR, `top' or `bottom', when the bar is running."
  (when (fboundp 'gowl-bar-configure)
    (if (eq bar 'bottom)
        (cmacs-gowl-bar-configure-bottom alist)
      (cmacs-gowl-bar-configure-top alist))))

(defun cmacs-gowl-bar-widgets--place (place)
  "Split PLACE into (BAR . REGION-KEY-STEM)."
  (pcase place
    ('top-left      '(top . "widgets-left"))
    ('top-center    '(top . "widgets-center"))
    ('top-right     '(top . "widgets-right"))
    ('bottom-left   '(bottom . "widgets-left"))
    ('bottom-center '(bottom . "widgets-center"))
    ('bottom-right  '(bottom . "widgets-right"))
    (_ (error "cmacs-gowl-bar: unknown place %S" place))))

(defun cmacs-gowl-bar-widgets--placement-alists ()
  "The configure alists that place `cmacs-gowl-bar-default-widgets'.
Returns ((BAR . ALIST) ...), one entry per bar touched.  Each widget
is removed from its region before it is added, in the same alist (the
bar applies removals first), so running this twice adds nothing twice."
  (let ((by-bar nil))
    (dolist (cell cmacs-gowl-bar-default-widgets)
      (let* ((widget (car cell))
             (where (cmacs-gowl-bar-widgets--place (cdr cell)))
             (bar (car where))
             (stem (cdr where))
             (entry (assq bar by-bar)))
        (unless entry
          (setq entry (list bar))
          (push entry by-bar))
        ;; Accumulate space-separated lists per key.
        (dolist (suffix '("-remove" "-add"))
          (let* ((key (concat stem suffix))
                 (have (assoc key (cdr entry))))
            (if have
                (setcdr have (concat (cdr have) " " widget))
              (setcdr entry (append (cdr entry)
                                    (list (cons key widget)))))))))
    (nreverse by-bar)))

;;;###autoload
(defun cmacs-gowl-bar-widgets-apply ()
  "Apply the cmacs defaults for gowl's extended bar widgets.

Idempotent.  Never signals: each step is reported and skipped on
failure, so one widget's trouble cannot cost the others -- or the rest
of the compositor's startup, which calls this."
  (interactive)
  ;; 1. The cpu widget's style.
  (when cmacs-gowl-bar-cpu-style
    (condition-case err
        (cmacs-gowl-bar-push "cpu" (list (cons "style"
                                               (symbol-name
                                                cmacs-gowl-bar-cpu-style))))
      (error (message "cmacs-gowl-bar: cpu style: %s"
                      (error-message-string err)))))
  ;; 2. AI widgets talk to cmacs-ai.  The bar remembers a widget's
  ;;    settings until that widget is added, so this reaches widgets
  ;;    the user places later too; pushed before placement so a widget
  ;;    placed below never starts out on the wrong backend.
  (dolist (w cmacs-gowl-bar-ai-widgets)
    (cmacs-gowl-bar-push w '(("ai-backend" . "cmacs"))))
  (when (member "translate" cmacs-gowl-bar-ai-widgets)
    (cmacs-gowl-bar-push "translate" '(("engine" . "ai"))))
  ;; 3. Place the default widgets.
  (dolist (entry (cmacs-gowl-bar-widgets--placement-alists))
    (condition-case err
        (funcall cmacs-gowl-bar-widgets-configure-function
                 (car entry) (cdr entry))
      (error (message "cmacs-gowl-bar: placing widgets: %s"
                      (error-message-string err)))))
  ;; 4. Each widget's cmacs half.
  (dolist (fn cmacs-gowl-bar-widgets-setup-functions)
    (when (fboundp fn)
      (condition-case err
          (funcall fn)
        (error (message "cmacs-gowl-bar: %s: %s"
                        fn (error-message-string err))))))
  nil)

(provide 'cmacs-gowl-bar-widgets)

;;; cmacs-gowl-bar-widgets.el ends here
