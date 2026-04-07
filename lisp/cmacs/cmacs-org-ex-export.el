;;; cmacs-org-ex-export.el --- Org export backend for widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Org export derived backends that handle WIDGET special blocks.
;;
;; When exporting an Org buffer with org-ex widgets, the standard
;; export backends skip WIDGET blocks entirely.  This file defines
;; derived backends for HTML and plain text that use the C export
;; primitives:
;;   `org-ex-widget-export-html' -- export widget as HTML string
;;   `org-ex-widget-export-text' -- export widget as plain text
;;
;; Usage:
;;   C-c C-e w h   -- export to HTML with widget support
;;   C-c C-e w t   -- export to plain text with widget support

;;; Code:

(require 'ox)
(require 'ox-html)

;;; HTML export backend

(org-export-define-derived-backend 'org-ex-html 'html
  :menu-entry
  '(?w "Org-Ex export"
       ((?h "As HTML file" cmacs-org-ex-export-to-html)
        (?H "As HTML buffer" cmacs-org-ex-export-as-html)
        (?t "As text file" cmacs-org-ex-export-to-text)
        (?T "As text buffer" cmacs-org-ex-export-as-text)))
  :translate-alist
  '((special-block . cmacs-org-ex-export--special-block-html)))

(defun cmacs-org-ex-export--special-block-html (special-block contents info)
  "Transcode a SPECIAL-BLOCK element for HTML export.
If the block type is WIDGET, export it via `org-ex-widget-export-html'.
Otherwise, fall through to the default HTML handler.
CONTENTS is the block body.  INFO is the export plist."
  (let ((type (org-element-property :type special-block)))
    (if (string-equal-ignore-case type "WIDGET")
        (cmacs-org-ex-export--widget-html special-block info)
      ;; Fall through to standard HTML special-block handler.
      (org-html-special-block special-block contents info))))

(defun cmacs-org-ex-export--widget-html (element info)
  "Export a WIDGET block ELEMENT as HTML.
INFO is the export plist.  Looks up the widget in the buffer's
document and calls `org-ex-widget-export-html'.  Falls back to a
placeholder div if the widget is not live."
  (let* ((subtype (cmacs-org-ex-export--block-subtype element))
         (id (cmacs-org-ex-export--block-id subtype element))
         (document (plist-get info :org-ex-document))
         (widget (when document
                   (org-ex-document-get-widget document id)))
         (html (when widget
                 (org-ex-widget-export-html widget))))
    (or html
        (format "<div class=\"org-ex-widget org-ex-%s\" data-id=\"%s\">\n%s\n</div>\n"
                (or subtype "unknown")
                id
                (cmacs-org-ex-export--fallback-html element)))))

(defun cmacs-org-ex-export--fallback-html (element)
  "Generate fallback HTML for a WIDGET ELEMENT that has no live widget."
  (let* ((subtype (cmacs-org-ex-export--block-subtype element))
         (props (cmacs-org-ex-export--block-props element)))
    (format "<p class=\"org-ex-placeholder\">[%s widget: %s]</p>"
            (or subtype "unknown")
            (mapconcat (lambda (pair)
                         (format "%s=%s" (car pair) (cdr pair)))
                       props ", "))))

;;; Text export backend

(org-export-define-derived-backend 'org-ex-text 'ascii
  :translate-alist
  '((special-block . cmacs-org-ex-export--special-block-text)))

(defun cmacs-org-ex-export--special-block-text (special-block contents info)
  "Transcode a SPECIAL-BLOCK element for plain text export.
If the block type is WIDGET, export via `org-ex-widget-export-text'.
Otherwise, fall through to the default ASCII handler.
CONTENTS is the block body.  INFO is the export plist."
  (let ((type (org-element-property :type special-block)))
    (if (string-equal-ignore-case type "WIDGET")
        (cmacs-org-ex-export--widget-text special-block info)
      ;; Fall through to standard ASCII special-block handler.
      (org-ascii-special-block special-block contents info))))

(defun cmacs-org-ex-export--widget-text (element info)
  "Export a WIDGET block ELEMENT as plain text.
INFO is the export plist."
  (let* ((subtype (cmacs-org-ex-export--block-subtype element))
         (id (cmacs-org-ex-export--block-id subtype element))
         (document (plist-get info :org-ex-document))
         (widget (when document
                   (org-ex-document-get-widget document id)))
         (text (when widget
                 (org-ex-widget-export-text widget))))
    (or text
        (format "[%s widget: %s]\n"
                (or subtype "unknown") id))))

;;; Block parsing helpers

(defun cmacs-org-ex-export--block-subtype (element)
  "Extract the widget subtype from a WIDGET special block ELEMENT."
  (save-excursion
    (goto-char (org-element-property :begin element))
    (when (re-search-forward
           "^[ \t]*#\\+BEGIN_WIDGET[ \t]+\\(\\S-+\\)"
           (line-end-position) t)
      (match-string-no-properties 1))))

(defun cmacs-org-ex-export--block-id (subtype element)
  "Generate a widget ID from SUBTYPE and ELEMENT position."
  (format "%s-%d" (or subtype "widget")
          (org-element-property :begin element)))

(defun cmacs-org-ex-export--block-props (element)
  "Parse :key value lines from a WIDGET block ELEMENT.
Returns an alist of (KEY . VALUE) string pairs."
  (let ((contents (org-element-property :value element))
        props)
    (when contents
      (dolist (line (split-string contents "\n" t "[ \t]+"))
        (when (string-match "^:\\([^ \t]+\\)[ \t]+\\(.+\\)$" line)
          (push (cons (match-string 1 line)
                      (match-string 2 line))
                props))))
    (nreverse props)))

;;; Export commands

;;;###autoload
(defun cmacs-org-ex-export-to-html
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current buffer to an HTML file with org-ex widget support.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY, and EXT-PLIST are
passed through to `org-export-to-file'."
  (interactive)
  (let ((info (cmacs-org-ex-export--make-info)))
    (org-export-to-file 'org-ex-html
        (org-export-output-file-name ".html" subtreep)
      async subtreep visible-only body-only
      (append info ext-plist))))

;;;###autoload
(defun cmacs-org-ex-export-as-html
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current buffer to an HTML buffer with org-ex widget support.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY, and EXT-PLIST are
passed through to `org-export-to-buffer'."
  (interactive)
  (let ((info (cmacs-org-ex-export--make-info)))
    (org-export-to-buffer 'org-ex-html "*Org-Ex HTML Export*"
      async subtreep visible-only body-only
      (append info ext-plist))))

;;;###autoload
(defun cmacs-org-ex-export-to-text
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current buffer to a text file with org-ex widget support.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY, and EXT-PLIST are
passed through to `org-export-to-file'."
  (interactive)
  (let ((info (cmacs-org-ex-export--make-info)))
    (org-export-to-file 'org-ex-text
        (org-export-output-file-name ".txt" subtreep)
      async subtreep visible-only body-only
      (append info ext-plist))))

;;;###autoload
(defun cmacs-org-ex-export-as-text
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current buffer to a text buffer with org-ex widget support.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY, and EXT-PLIST are
passed through to `org-export-to-buffer'."
  (interactive)
  (let ((info (cmacs-org-ex-export--make-info)))
    (org-export-to-buffer 'org-ex-text "*Org-Ex Text Export*"
      async subtreep visible-only body-only
      (append info ext-plist))))

(defun cmacs-org-ex-export--make-info ()
  "Build the export info plist with the current buffer's document."
  (let ((doc (when (boundp 'cmacs-org-ex--document)
               cmacs-org-ex--document)))
    (list :org-ex-document doc)))

(provide 'cmacs-org-ex-export)
;;; cmacs-org-ex-export.el ends here
