;;; cmacs-gnuseye-news.el --- GNU's Eye live news panel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A live-news side panel aggregating a few RSS/Atom feeds (parsed with
;; libxml).  Headlines are buttons that open the article in gsurf (or eww /
;; browse-url).  Refreshed on demand.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-news-feeds
  '("https://feeds.bbci.co.uk/news/world/rss.xml"
    "https://www.aljazeera.com/xml/rss/all.xml"
    "https://feeds.reuters.com/reuters/worldNews")
  "RSS/Atom feed URLs for the live-news panel."
  :type '(repeat string) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-news-per-feed 8
  "Maximum headlines kept per feed."
  :type 'integer :group 'cmacs-gnuseye)

(defconst cmacs-gnuseye-news-buffer "*GNU's Eye News*")

(defun cmacs-gnuseye-news--collect (node tag)
  "Collect all descendant nodes of NODE whose tag is TAG."
  (let (out)
    (when (and (consp node) (not (stringp node)))
      (when (eq (car node) tag) (push node out))
      (dolist (c (cddr node))
        (setq out (nconc out (cmacs-gnuseye-news--collect c tag)))))
    out))

(defun cmacs-gnuseye-news--child-text (node tag)
  "Concatenated text of NODE's first child element named TAG."
  (let ((c (seq-find (lambda (x) (and (consp x) (eq (car x) tag))) (cddr node))))
    (and c (string-trim
            (mapconcat (lambda (x) (if (stringp x) x "")) (cddr c) "")))))

(defun cmacs-gnuseye-news--link (node)
  "Article link from an RSS item or Atom entry NODE."
  (or (cmacs-gnuseye-news--child-text node 'link)
      ;; Atom: <link href="..."/>
      (let ((l (seq-find (lambda (x) (and (consp x) (eq (car x) 'link)))
                         (cddr node))))
        (and l (cdr (assq 'href (cadr l)))))))

(defun cmacs-gnuseye-news--parse (xml)
  "Parse RSS/Atom XML string into a list of (TITLE . LINK)."
  (let* ((tree (ignore-errors
                 (with-temp-buffer
                   (insert xml)
                   (libxml-parse-xml-region (point-min) (point-max)))))
         (items (and tree (or (cmacs-gnuseye-news--collect tree 'item)
                              (cmacs-gnuseye-news--collect tree 'entry))))
         out)
    (dolist (it (seq-take items cmacs-gnuseye-news-per-feed))
      (let ((title (cmacs-gnuseye-news--child-text it 'title))
            (link (cmacs-gnuseye-news--link it)))
        (when title (push (cons title link) out))))
    (nreverse out)))

(defun cmacs-gnuseye-news-open (url)
  "Open URL in gsurf (or eww / browse-url)."
  (cond ((null url) (message "No link"))
        ((fboundp 'cmacs-gsurf) (cmacs-gsurf url))
        ((fboundp 'cmacs-gsurf-lite-open) (cmacs-gsurf-lite-open url))
        ((fboundp 'eww) (eww url))
        (t (browse-url url))))

(define-derived-mode cmacs-gnuseye-news-mode special-mode "GnuseyeNews"
  "GNU's Eye live news panel.")

(defun cmacs-gnuseye-news--render (feed-results)
  (with-current-buffer (get-buffer-create cmacs-gnuseye-news-buffer)
    (unless (derived-mode-p 'cmacs-gnuseye-news-mode) (cmacs-gnuseye-news-mode))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "GNU's Eye — live news\n" 'face 'bold))
      (insert "──────────────────────────\n")
      (dolist (item (apply #'append feed-results))
        (let ((title (car item)) (url (cdr item)))
          (insert "• ")
          (if url
              (insert-text-button
               (truncate-string-to-width title 64)
               'action (lambda (_) (cmacs-gnuseye-news-open url))
               'follow-link t 'help-echo url)
            (insert (truncate-string-to-width title 64)))
          (insert "\n")))
      (goto-char (point-min)))))

;;;###autoload
(defun cmacs-gnuseye-news ()
  "Open / refresh the live-news panel."
  (interactive)
  (let ((results (make-vector (length cmacs-gnuseye-news-feeds) nil))
        (pending (length cmacs-gnuseye-news-feeds)) (i 0))
    (if (zerop pending)
        (cmacs-gnuseye-news--render nil)
      (dolist (url cmacs-gnuseye-news-feeds)
        (let ((idx i))
          (cmacs-gnuseye-fetch-text
           url
           (lambda (body)
             (aset results idx (and body (cmacs-gnuseye-news--parse body)))
             (when (zerop (setq pending (1- pending)))
               (cmacs-gnuseye-news--render (append results nil))))))
        (setq i (1+ i))))
    (display-buffer (get-buffer-create cmacs-gnuseye-news-buffer)
                    '((display-buffer-in-side-window) (side . right)
                      (window-width . 0.3)))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "N") #'cmacs-gnuseye-news))

(provide 'cmacs-gnuseye-news)
;;; cmacs-gnuseye-news.el ends here
