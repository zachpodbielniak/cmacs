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
;;   :bar WIDGET       The watch drives a gowl bar item: the widget's
;;                     `text' setting is pushed on the first result and
;;                     on every change.
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
  "Longest text a watch pushes to a bar item; the rest is cut."
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
;; There is no way to create a bar item from Elisp; what Elisp can do is
;; set a widget's settings (`cmacs-gowl-bar-push'), and the one shipped
;; widget whose text is a setting is `label' (alias `text').  Its
;; configure (deps/gowl/modules/bar/bar-plugins-core.c, label_configure)
;; reads the spec parameter BEFORE the `text' setting, so `label:inbox'
;; shows "inbox" for ever and only a bare `label' and a bare `text' can
;; be driven: two items.  Reading `text' first -- so that `label:ID' is
;; an addressable, pushable slot -- is the whole of the C that unlimited
;; watch-driven items need.  Until then a third wants a bar plugin that
;; reads a `text' setting, which this code drives unchanged.

(defun cmacs-lql-watch-sinks--bar-spec (name)
  "The watch NAME's :bar option as a plist (:widget :format :empty), or nil.
The option is a widget name, or a plist with :widget and optionally
:format (a template for `cmacs-lql-watch-format', or a function of the
rows returning the text) and :empty (the text for a result with no
rows; without it the format is used, with `{rows}' being 0)."
  (let ((bar (cmacs-lql-watch-get name :bar)))
    (cond ((null bar) nil)
          ((stringp bar) (list :widget bar))
          ((and (consp bar) (stringp (plist-get bar :widget))) bar)
          (t nil))))

(defun cmacs-lql-watch-sinks--bar (name rows &rest _)
  "Push the watch NAME's ROWS, formatted, to its bar item."
  (when-let* ((spec (and (cmacs-lql-watch-sinks--user-p name)
                         (cmacs-lql-watch-sinks--bar-spec name))))
    (let* ((format (or (plist-get spec :format) "{name}: {rows}"))
           (text (cond ((and (null rows) (plist-member spec :empty))
                        (or (plist-get spec :empty) ""))
                       ((functionp format) (format "%s" (funcall format rows)))
                       (t (cmacs-lql-watch-format format name rows))))
           (text (replace-regexp-in-string "[\n\r\t]+" " " text)))
      ;; `cmacs-gowl-bar-push' is the one way Elisp sets a widget's
      ;; settings, never signals, and is a no-op with no bar running.
      (when (or (fboundp 'cmacs-gowl-bar-push)
                (require 'cmacs-gowl-bar-ai nil t))
        (cmacs-gowl-bar-push
         (plist-get spec :widget)
         (list (cons "text" (truncate-string-to-width
                             text cmacs-lql-watch-bar-max-chars nil nil t))))))))

;;;###autoload
(defun cmacs-lql-watch-bar-place (widget &optional region)
  "Add the bar WIDGET to REGION of the gowl bar, without replacing anything.
REGION is `left', `center' or `right' (the default), or one of those
prefixed `bottom-' for the bottom bar.  Uses the bar's amendment keys,
so the rest of the layout -- shipped or yours -- is left alone.  Call it
once, at startup, for a widget a watch drives:

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

(provide 'cmacs-lql-watch-sinks)

;;; cmacs-lql-watch-sinks.el ends here
