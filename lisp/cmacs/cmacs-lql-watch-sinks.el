;;; cmacs-lql-watch-sinks.el --- Where a watch's change goes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: data, tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Three small consumers of cmacs-lql-watch.el, each written against
;; its public surface only -- the two hooks, `cmacs-lql-watch-get' and
;; `cmacs-lql-watch-extra-keys' -- which is the point: anything else
;; that wants to be driven by a query is written the same way.
;;
;;   :event t          A podomation event, `on_lql_watch', on every
;;                     change, so a .pod rule can bind the query:
;;
;;                       pod c = cmacs->new();
;;                       c->on_lql_watch where event->watch == "dead-processes"
;;                           => cmacs->notify("Processes exited", "{event->rows} now");
;;
;;   :bar FORMAT       The watch IS a gowl bar item: a slot of its own
;;                     (cmacs-gowl-bar-slots.el), created on the first
;;                     result, refilled on every change, and removed
;;                     when the watch is paused or removed.  t, a
;;                     format string, a function of the rows, or a
;;                     plist saying where it goes and how it looks.
;;
;;   :toast t          A bar toast (a message where there is no bar) on
;;                     every change.
;;
;; None of them is reachable from an agent's watch: cmacs-lql-watch-
;; tools.el passes none of these keys, and the functions here ignore a
;; watch that has an owner.  An agent choosing a watch name must not be
;; able to fire your podomation rules or write on your bar.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; cmacs-lql-watch.el loads this file when it has finished loading
;; itself.  When this file is the one loaded first, the flag tells it
;; not to: the feature is not provided yet, and it would load us again.
(defvar cmacs-lql-watch-sinks--loading nil
  "Non-nil while this file is loading cmacs-lql-watch.el.")
(eval-when-compile (require 'cmacs-lql-watch))
(let ((cmacs-lql-watch-sinks--loading t))
  (require 'cmacs-lql-watch))

(declare-function cmacs-lql-watch-get "cmacs-lql-watch" (name property))
(declare-function cmacs-lql-watch-rows-json "cmacs-lql-watch"
                  (rows &optional max-chars))
(declare-function cmacs-lql-watch-diff-json "cmacs-lql-watch"
                  (diff &optional max-chars))
(declare-function cmacs-podomation-emit-event "cmacs-podomation.c" (event data))
(declare-function cmacs-podomation-running-p "cmacs-podomation.c" ())
(declare-function cmacs-gowl-bar-push "cmacs-gowl-bar-ai" (widget alist))
(declare-function cmacs-gowl-bar-slot-set "cmacs-gowl-bar-slots"
                  (id &rest plist))
(declare-function cmacs-gowl-bar-slot-remove "cmacs-gowl-bar-slots" (id))
(declare-function cmacs-gowl-bar-slot-id "cmacs-gowl-bar-slots" (name))
(declare-function cmacs-lql-watch-rows "cmacs-lql-watch" (name))
(declare-function gowl-bar-notify "cmacs-gowl.c" (summary &optional body panel))
(declare-function gowl-running-p "cmacs-gowl.c" ())

(defvar cmacs-gowl-bar-push-function)

(defcustom cmacs-lql-watch-event-name "on_lql_watch"
  "The podomation event a watch with :event emits on a change."
  :type 'string
  :group 'cmacs-lql-watch)

(defcustom cmacs-lql-watch-event-diff-max 4096
  "Most characters of diff JSON put in a podomation event's `diff' field."
  :type 'natnum
  :group 'cmacs-lql-watch)

(defcustom cmacs-lql-watch-bar-max-chars 80
  "Longest text, in columns, a watch puts on the bar; the rest is cut."
  :type 'natnum
  :group 'cmacs-lql-watch)

(dolist (key '(:event :bar :toast))
  (add-to-list 'cmacs-lql-watch-extra-keys key))

(defun cmacs-lql-watch-sinks--user-p (name)
  "Non-nil when the watch NAME is the user's own (has no owner)."
  (null (cmacs-lql-watch-get name :owner)))

;;;; Formatting

(defun cmacs-lql-watch-format (template name rows)
  "Fill TEMPLATE for the watch NAME whose result is ROWS.

`{rows}' is the number of rows, `{total}' the result's own total,
`{name}' the watch's name, and `{COLUMN}' the value of that column in
the FIRST row (empty when it is NULL).  An unknown placeholder is left
as written, so a typo shows -- except when there are no rows at all,
where every other placeholder is empty."
  (let ((first (car rows))
        (case-fold-search nil))
    (replace-regexp-in-string
     "{\\([^{}\n]+\\)}"
     (lambda (match)
       (let ((field (match-string 1 match)))
         (cond
          ((equal field "rows") (number-to-string (length rows)))
          ((equal field "total")
           (format "%s" (or (cmacs-lql-watch-get name :total) (length rows))))
          ((equal field "name") name)
          ((assoc field first)
           (let ((value (cdr (assoc field first))))
             (cond ((null value) "")
                   ((eq value :false) "false")
                   ((eq value t) "true")
                   (t (format "%s" value)))))
          ;; With no row there is no telling a column from a typo, and
          ;; a bar reading "{title}" helps nobody.
          ((null rows) "")
          (t match))))
     template t t)))

;;;; podomation

(defun cmacs-lql-watch-sinks--event (name new _old diff)
  "Emit the podomation event for the changed watch NAME.
NEW are its rows and DIFF what changed.  Every value is a string,
because that is what an event's data holds."
  (when (and (cmacs-lql-watch-get name :event)
             (cmacs-lql-watch-sinks--user-p name)
             (fboundp 'cmacs-podomation-emit-event)
             (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-emit-event
     cmacs-lql-watch-event-name
     `(("watch" . ,name)
       ("rows" . ,(number-to-string (length new)))
       ("total" . ,(format "%s" (or (cmacs-lql-watch-get name :total)
                                    (length new))))
       ("added" . ,(number-to-string (length (plist-get diff :added))))
       ("removed" . ,(number-to-string (length (plist-get diff :removed))))
       ("changed" . ,(number-to-string (length (plist-get diff :changed))))
       ;; The first row, for the common rule that wants one value out
       ;; of a one-row summary without parsing the whole diff.
       ("row" . ,(if new
                     (substring (cmacs-lql-watch-rows-json
                                 (list (car new))
                                 cmacs-lql-watch-event-diff-max)
                                1 -1)
                   ""))
       ("diff" . ,(cmacs-lql-watch-diff-json
                   diff cmacs-lql-watch-event-diff-max))))))

;;;; The gowl bar
;;
;; A watch with :bar owns a bar SLOT: an item of its own that this code
;; creates, fills and removes (cmacs-gowl-bar-slots.el; gowl's
;; docs/bar.org, "Slots").  One slot per watch, named after the watch,
;; so any number of standing queries can sit on the bar side by side
;; and none of them needs anything placed in the bar's configuration
;; first.
;;
;; That replaces what this file did before slots existed: push a `text'
;; setting at the one shipped widget whose text is a setting, `label'.
;; It could drive two items in all -- a bare `label' and its alias
;; `text' -- because `label:NAME' reads its text from the spec and so
;; shows "NAME" for ever.  (Making `label' read the setting first would
;; not have fixed it: a `label.text' setting reaches EVERY label by
;; name, so each `label:Static text' on a bar that also pushed to
;; `label' would have started showing the pushed text.)  The old route
;; is still here, spelt out -- `:bar (:widget "label")' -- for a bar
;; layout that was built around it.

(defconst cmacs-lql-watch-sinks--slot-keys
  '(:icon :role :tooltip :urgency :region :order :bar :output :on-click :ttl)
  "The keys of a :bar plist handed on to `cmacs-gowl-bar-slot-set'.")

(defconst cmacs-lql-watch-sinks--bar-keys
  (append '(:format :empty :slot :widget) cmacs-lql-watch-sinks--slot-keys)
  "Every key a :bar plist may hold.")

(defvar cmacs-lql-watch-sinks--bar-items (make-hash-table :test #'equal)
  "What each watch has on the bar: name -> (slot . ID) or (widget . NAME).
Kept here because a watch that has been removed can no longer be asked
what its :bar option was, and its item still has to go.")

(defun cmacs-lql-watch-sinks--bar-spec (name)
  "The watch NAME's :bar option as a plist, or nil when it has none.
The option is

  t            a slot of its own, saying \"NAME: N\" (the row count);
  a string     the same, with the string as the format -- a template
               for `cmacs-lql-watch-format';
  a function   the same, calling it with the rows for the text;
  a plist      :format, as above (a string or a function), and any of
               :empty   the text for a result with no rows -- nil to
                        show nothing then; without it the format is
                        used, with `{rows}' being 0
               :slot    the slot's id, instead of one made from NAME
               :icon :role :tooltip :urgency :region :order :bar
               :output :on-click :ttl
                        as for `cmacs-gowl-bar-slot-set'
               :widget  NOT a slot: push the text at the `text' setting
                        of this existing bar widget (\"label\"), as
                        this option did before slots existed.

A format function may also return a plist of slot keys -- (:text ...
:urgency critical) -- to change more than the text with the result.

The strings \"label\" and \"text\" are read as (:widget ...): they were
the only two values that ever worked as a widget name, and neither is
a format anybody meant."
  (let ((bar (cmacs-lql-watch-get name :bar)))
    (cond
     ((null bar) nil)
     ((eq bar t) (list :format nil))
     ((member bar '("label" "text")) (list :widget bar))
     ((stringp bar) (list :format bar))
     ((functionp bar) (list :format bar))
     ((and (consp bar) (keywordp (car bar)))
      (let ((tail bar))
        (while tail
          (unless (memq (car tail) cmacs-lql-watch-sinks--bar-keys)
            (error "A watch's :bar has no %S" (car tail)))
          (setq tail (cddr tail))))
      bar)
     (t (error "A watch's :bar is t, a format, a function or a plist, not %S"
               bar)))))

(defun cmacs-lql-watch-sinks--bar-slot-id (name spec)
  "The id of the slot the watch NAME owns, given its :bar SPEC."
  (require 'cmacs-gowl-bar-slots)
  (cmacs-gowl-bar-slot-id (or (plist-get spec :slot)
                              (concat "lql-" name))))

(defun cmacs-lql-watch-sinks--bar-value (name spec rows)
  "What the watch NAME shows for ROWS under SPEC: a string or a plist.
A plist is what a format function returned to change more than the
text; anything else it returned is shown as text."
  (let ((format (or (plist-get spec :format) "{name}: {rows}")))
    (cond ((and (null rows) (plist-member spec :empty))
           (or (plist-get spec :empty) ""))
          ((functionp format)
           (let ((value (funcall format rows)))
             (cond ((null value) "")
                   ((and (consp value) (keywordp (car value))) value)
                   (t (format "%s" value)))))
          (t (cmacs-lql-watch-format format name rows)))))

(defun cmacs-lql-watch-sinks--bar-text (text)
  "TEXT as one line no longer than `cmacs-lql-watch-bar-max-chars'."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\r\t]+" " " (format "%s" (or text "")))
   cmacs-lql-watch-bar-max-chars nil nil t))

(defun cmacs-lql-watch-sinks--bar-drop (name)
  "Take what the watch NAME has on the bar off it.  Never signals."
  (when-let* ((item (gethash name cmacs-lql-watch-sinks--bar-items)))
    (remhash name cmacs-lql-watch-sinks--bar-items)
    (condition-case err
        (pcase item
          (`(slot . ,id)
           (require 'cmacs-gowl-bar-slots)
           (cmacs-gowl-bar-slot-remove id))
          (`(widget . ,widget)
           ;; A widget is the user's to place; all there is to take
           ;; back is the text.
           (when (or (fboundp 'cmacs-gowl-bar-push)
                     (require 'cmacs-gowl-bar-ai nil t))
             (cmacs-gowl-bar-push widget '(("text" . ""))))))
      (error (message "cmacs-lql-watch: could not clear %s from the bar: %s"
                      name (error-message-string err))))))

(defun cmacs-lql-watch-sinks--bar (name rows &rest _)
  "Show the watch NAME's ROWS on the bar, as its :bar option says.
On both the baseline and the change hook: a displayed watch needs its
first value too.  A bad :bar option signals, which the watch records
as its callback error -- visible in the watch list, and the reason
nothing appeared."
  (let ((spec (and (cmacs-lql-watch-sinks--user-p name)
                   (cmacs-lql-watch-sinks--bar-spec name))))
    (cond
     ;; The watch was redefined without :bar: what it had goes.
     ((null spec) (cmacs-lql-watch-sinks--bar-drop name))
     ;; The route from before slots: a setting on a widget the user
     ;; placed.
     ((plist-get spec :widget)
      (let ((value (cmacs-lql-watch-sinks--bar-value name spec rows)))
        (puthash name (cons 'widget (plist-get spec :widget))
                 cmacs-lql-watch-sinks--bar-items)
        ;; `cmacs-gowl-bar-push' never signals and is a no-op with no
        ;; bar running.
        (when (or (fboundp 'cmacs-gowl-bar-push)
                  (require 'cmacs-gowl-bar-ai nil t))
          (cmacs-gowl-bar-push
           (plist-get spec :widget)
           (list (cons "text" (cmacs-lql-watch-sinks--bar-text
                               (if (consp value)
                                   (plist-get value :text)
                                 value))))))))
     (t
      (let* ((id (cmacs-lql-watch-sinks--bar-slot-id name spec))
             (value (cmacs-lql-watch-sinks--bar-value name spec rows))
             (args (list :owner 'cmacs-lql-watch
                         ;; What a count on a bar most needs said about
                         ;; it: which question it is the answer to.
                         :tooltip (format "%s: %s" name
                                          (or (cmacs-lql-watch-get name :query)
                                              "")))))
        ;; The option's own keys over the defaults, then what a format
        ;; function returned over those, then the text over everything.
        (dolist (key cmacs-lql-watch-sinks--slot-keys)
          (when (plist-member spec key)
            (setq args (plist-put args key (plist-get spec key)))))
        (when (consp value)
          (let ((tail value))
            (while tail
              (setq args (plist-put args (car tail) (cadr tail))
                    tail (cddr tail)))))
        (setq args (plist-put args :text
                              (cmacs-lql-watch-sinks--bar-text
                               (if (consp value)
                                   (plist-get value :text)
                                 value))))
        ;; A slot under another id from an earlier definition of this
        ;; watch would otherwise stay beside the new one.
        (let ((had (gethash name cmacs-lql-watch-sinks--bar-items)))
          (unless (equal had (cons 'slot id))
            (cmacs-lql-watch-sinks--bar-drop name)))
        (puthash name (cons 'slot id) cmacs-lql-watch-sinks--bar-items)
        ;; Remembered by the slot layer whether or not a bar is up, so
        ;; a watch that fired before the compositor started is on the
        ;; bar when it does.  Signals only for a bad option.
        (apply #'cmacs-gowl-bar-slot-set id args))))))

(defun cmacs-lql-watch-sinks--bar-paused (name paused)
  "Take the watch NAME off the bar when PAUSED, and put it back when not.
A paused watch's last value is nobody's current answer; left on the
bar it reads as one.  On resume the last rows go back at once -- the
watch runs again, but a result equal to the last is not a change and
would never be pushed."
  (cond
   (paused (cmacs-lql-watch-sinks--bar-drop name))
   ((and (cmacs-lql-watch-get name :last-run)
         (not (cmacs-lql-watch-get name :last-error)))
    (cmacs-lql-watch-sinks--bar name (cmacs-lql-watch-rows name)))))

(defun cmacs-lql-watch-sinks--bar-removed (name &rest _)
  "Take the removed watch NAME off the bar."
  (cmacs-lql-watch-sinks--bar-drop name))

;;;###autoload
(defun cmacs-lql-watch-bar-place (widget &optional region)
  "Add the bar WIDGET to REGION of the gowl bar, without replacing anything.
REGION is `left', `center' or `right' (the default), or one of those
prefixed `bottom-' for the bottom bar.  Uses the bar's amendment keys,
so the rest of the layout -- shipped or yours -- is left alone.

Only for a watch that drives an existing widget, `:bar (:widget ...)'.
A watch with any other :bar has a slot of its own and needs nothing
placed: say where it goes in the option, with :region and :order.

  (cmacs-lql-watch-bar-place \"label\")
  (cmacs-lql-define-watch inbox \"fetch notes | filter para == \\\"inbox\\\"\"
    :bar \\='(:widget \"label\" :format \"inbox {rows}\"))"
  (let* ((region (symbol-name (or region 'right)))
         (bottom (string-prefix-p "bottom-" region))
         (side (if bottom (substring region 7) region))
         (key (format "%swidgets-%s" (if bottom "bottom-" "") side)))
    (unless (member side '("left" "center" "right"))
      (error "No such bar region: %s" region))
    (when (or (boundp 'cmacs-gowl-bar-push-function)
              (require 'cmacs-gowl-bar-ai nil t))
      (condition-case err
          ;; Remove-then-add is the bar's own idiom for \"make sure it is
          ;; there exactly once\".
          (funcall cmacs-gowl-bar-push-function
                   (list (cons (concat key "-remove") widget)
                         (cons (concat key "-add") widget)))
        (error (message "cmacs-lql-watch: could not place %s: %s" widget
                        (error-message-string err)))))))

;;;; Toasts

(defun cmacs-lql-watch-sinks--toast (name new _old diff)
  "Announce that the watch NAME changed to the rows NEW by DIFF."
  (when-let* ((toast (and (cmacs-lql-watch-sinks--user-p name)
                          (cmacs-lql-watch-get name :toast))))
    (let ((summary (if (stringp toast)
                       (cmacs-lql-watch-format toast name new)
                     (format "%s changed" name)))
          (body (format "%d rows (+%d -%d ~%d)" (length new)
                        (length (plist-get diff :added))
                        (length (plist-get diff :removed))
                        (length (plist-get diff :changed)))))
      (unless (and (fboundp 'gowl-bar-notify)
                   (fboundp 'gowl-running-p)
                   (gowl-running-p)
                   (condition-case nil
                       (progn (gowl-bar-notify summary body) t)
                     (error nil)))
        (message "%s: %s" summary body)))))

(add-hook 'cmacs-lql-watch-change-functions #'cmacs-lql-watch-sinks--event)
(add-hook 'cmacs-lql-watch-change-functions #'cmacs-lql-watch-sinks--bar)
(add-hook 'cmacs-lql-watch-change-functions #'cmacs-lql-watch-sinks--toast)
(add-hook 'cmacs-lql-watch-baseline-functions #'cmacs-lql-watch-sinks--bar)
(add-hook 'cmacs-lql-watch-paused-functions
          #'cmacs-lql-watch-sinks--bar-paused)
(add-hook 'cmacs-lql-watch-removed-functions
          #'cmacs-lql-watch-sinks--bar-removed)

(provide 'cmacs-lql-watch-sinks)

;;; cmacs-lql-watch-sinks.el ends here
