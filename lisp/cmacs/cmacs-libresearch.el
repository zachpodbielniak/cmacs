;;; cmacs-libresearch.el --- A libresearch client: search results to comb through  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: comm, hypermedia, tools
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

;; A client of a libresearch server (libresearchd, the GLib metasearch
;; engine) for people rather than models.  The transport is the one the
;; AI side already uses (cmacs-ai-libresearch.c over ai-glib), and so is
;; the configuration: the server and its token come from
;; `cmacs-ai-libresearch-endpoint', i.e. an ~/.authinfo(.gpg) line
;;
;;   machine search.example.org port 443 login libresearch password TOKEN
;;
;; with no setup beyond that line.
;;
;; Commands:
;;
;;   `cmacs-libresearch-search'    results in a grid to comb through
;;   `cmacs-libresearch-query'     an LQL query on the server, in a grid
;;   `cmacs-libresearch-research'  a cited answer, in org
;;   `cmacs-libresearch-fetch'     a page's readable text, in org
;;
;; The search grid is a `cmacs-lql-results-mode' buffer, so it sorts,
;; exports and marks like any LQL result, and adds:
;;
;;   RET  open in gsurf (or the browser)    f  fetch the page as org
;;   r    research a question about the marked results
;;   i    ingest the marked results into the second brain
;;   E    export marked results to an org note in the inbox
;;   l    copy an org link                   /  refine with LQL, locally
;;   s    search again                       S  next page of results

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-ai)
(require 'cmacs-ai-research)
(require 'cmacs-lql-results)

(declare-function cmacs-secondbrain-ingest "cmacs-secondbrain-ingest" (input &optional para tags))
(declare-function cmacs-para-roots "cmacs-para" ())
(defvar cmacs-para-roots)

(defgroup cmacs-libresearch nil
  "A libresearch client."
  :group 'cmacs
  :prefix "cmacs-libresearch-")

(defcustom cmacs-libresearch-count 30
  "Results a search asks the server for."
  :type 'natnum)

(defcustom cmacs-libresearch-categories
  '("general" "news" "code" "science" "images" "videos" "files" "it" "social")
  "Categories `cmacs-libresearch-search' offers with a prefix argument."
  :type '(repeat string))

(defcustom cmacs-libresearch-inbox-directory nil
  "Where `cmacs-libresearch-export-to-inbox' writes notes.
Nil means 00_inbox/personal under the first of `cmacs-para-roots'."
  :type '(choice (const :tag "PARA inbox" nil) directory))

(defvar cmacs-libresearch-history nil "Minibuffer history of searches.")

;;;; Search results -> table

(defconst cmacs-libresearch--columns
  '(("title" . "String") ("url" . "String") ("engines" . "Array")
    ("score" . "Double") ("category" . "String") ("published" . "String")
    ("snippet" . "String") ("author" . "String"))
  "Columns of a search results grid, in display order.")

(defun cmacs-libresearch--search-table (payload)
  "A results table plist from a search PAYLOAD, or (:error MSG)."
  (pcase (car payload)
    (:ok
     (let ((doc (cmacs-ai-research-payload-document payload)))
       (list :columns cmacs-libresearch--columns
             :rows (mapcar (lambda (r)
                             (vconcat
                              (mapcar (lambda (c)
                                        (let ((v (plist-get r (intern (concat ":" (car c))))))
                                          (if (and (stringp v) (equal (car c) "snippet"))
                                              (replace-regexp-in-string "[\n\r]+" " " v)
                                            v)))
                                      cmacs-libresearch--columns)))
                           (plist-get doc :results))
             :total (length (plist-get doc :results))
             :infoboxes (plist-get doc :infoboxes))))
    (:error payload)
    (_ (list :error "cancelled"))))

;;;; The search grid

(defvar-local cmacs-libresearch--search nil
  "(QUERY . OPTIONS) of the search this buffer shows.")
(defvar-local cmacs-libresearch--page 1 "Page of results shown.")

(defvar-keymap cmacs-libresearch-results-mode-map
  :doc "Keymap for `cmacs-libresearch-results-mode'."
  :parent cmacs-lql-results-mode-map
  "f" #'cmacs-libresearch-fetch-at-point
  "r" #'cmacs-libresearch-research-marked
  "i" #'cmacs-libresearch-ingest-marked
  "E" #'cmacs-libresearch-export-to-inbox
  "l" #'cmacs-libresearch-copy-org-link
  "/" #'cmacs-lql-results-refine
  "s" #'cmacs-libresearch-search
  "S" #'cmacs-libresearch-next-page)

(define-derived-mode cmacs-libresearch-results-mode cmacs-lql-results-mode "Search"
  "Major mode for libresearch search results.

\\{cmacs-libresearch-results-mode-map}"
  :group 'cmacs-libresearch
  ;; Hide the long columns by default; `c' shows them.
  (setq cmacs-lql-results--hidden '("snippet" "author" "category")))

(with-eval-after-load 'cmacs-evil
  (cmacs-evil-setup-mode-map cmacs-libresearch-results-mode-map
                             'cmacs-libresearch-results-mode))

(defun cmacs-libresearch--search-target (options)
  "A `cmacs-lql-results' target running a search with OPTIONS."
  (lambda (query callback)
    (let ((started (float-time)))
      (apply #'cmacs-ai-research-request 'search query
             (lambda (payload)
               (let ((table (cmacs-libresearch--search-table payload)))
                 (funcall callback
                          (if (eq (car table) :error) table
                            (append table (list :elapsed (- (float-time) started)))))))
             options))))

(defun cmacs-libresearch--open-search (query options)
  "Open a search results buffer for QUERY with request OPTIONS."
  (let ((buf (get-buffer-create (format "*Search: %s*" query))))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-libresearch-results-mode)
        (cmacs-libresearch-results-mode))
      (setq cmacs-libresearch--search (cons query options)
            cmacs-libresearch--page (or (plist-get options :page) 1)))
    (cmacs-lql-results--loading query
                                :target (cmacs-libresearch--search-target options)
                                :buffer buf)))

;;;###autoload
(defun cmacs-libresearch-search (query &optional category)
  "Search the web through libresearch for QUERY; comb the results in a grid.
With a prefix argument, also pick a CATEGORY.  QUERY may use the
server's own syntax (bangs, `site:', ...)."
  (interactive
   (list (read-string "Search: " nil 'cmacs-libresearch-history)
         (and current-prefix-arg
              (completing-read "Category: " cmacs-libresearch-categories nil nil))))
  (cmacs-ai-research--ensure)
  (cmacs-libresearch--open-search
   query (append (list :count cmacs-libresearch-count)
                 (and category (not (string-empty-p category))
                      (list :category category)))))

(defun cmacs-libresearch-next-page ()
  "Show the next page of this search's results."
  (interactive)
  (unless cmacs-libresearch--search (user-error "Not a search buffer"))
  (let ((opts (plist-put (copy-sequence (cdr cmacs-libresearch--search))
                         :page (1+ cmacs-libresearch--page))))
    (cmacs-libresearch--open-search (car cmacs-libresearch--search) opts)))

;;;; Acting on results

(defun cmacs-libresearch--url-at-point ()
  "The URL of the result at point."
  (or (cdr (assoc "url" (cmacs-lql-results--row-or-error)))
      (user-error "This row has no URL")))

(defun cmacs-libresearch-fetch-at-point (&optional archive)
  "Fetch the result at point's page as readable text in an org buffer.
With a prefix argument, fall back to the Wayback Machine's copy (ARCHIVE)."
  (interactive "P")
  (cmacs-ai-web-fetch (cmacs-libresearch--url-at-point) (and archive 'fallback)))

(defun cmacs-libresearch-copy-org-link ()
  "Copy org links to the marked results (or the one at point)."
  (interactive)
  (let ((links (mapcar (lambda (row)
                         (format "[[%s][%s]]" (cdr (assoc "url" row))
                                 (replace-regexp-in-string
                                  "[][]" "" (or (cdr (assoc "title" row))
                                                (cdr (assoc "url" row))))))
                       (cmacs-lql-results-marked-rows))))
    (kill-new (string-join links "\n"))
    (message "Copied %d org link%s" (length links) (if (cdr links) "s" ""))))

(defun cmacs-libresearch-research-marked (question)
  "Research QUESTION, pointing the server at the marked results' pages."
  (interactive (list (read-string "Research question: ")))
  (let ((urls (delq nil (mapcar (lambda (r) (cdr (assoc "url" r)))
                                (cmacs-lql-results-marked-rows)))))
    (cmacs-ai-research
     (if urls
         (format "%s\n\nStart from these sources:\n%s" question
                 (mapconcat (lambda (u) (concat "- " u)) urls "\n"))
       question))))

(defun cmacs-libresearch-ingest-marked ()
  "Ingest the marked results (or the one at point) into the second brain."
  (interactive)
  (unless (require 'cmacs-secondbrain-ingest nil t)
    (user-error "The second-brain ingest is not available in this cmacs"))
  (let ((urls (delq nil (mapcar (lambda (r) (cdr (assoc "url" r)))
                                (cmacs-lql-results-marked-rows)))))
    (dolist (u urls) (cmacs-secondbrain-ingest u))
    (message "Ingesting %d page%s into the second brain" (length urls)
             (if (cdr urls) "s" ""))))

(defun cmacs-libresearch--inbox ()
  "The directory `cmacs-libresearch-export-to-inbox' writes to."
  (or cmacs-libresearch-inbox-directory
      (expand-file-name "00_inbox/personal"
                        (car (or (and (require 'cmacs-para nil t) cmacs-para-roots)
                                 '("~/Documents/notes"))))))

(defun cmacs-libresearch--slug (text)
  "TEXT as a file-name slug."
  (let ((s (downcase (replace-regexp-in-string "[^[:alnum:]]+" "_" text))))
    (string-trim (truncate-string-to-width s 50) "_" "_")))

(defun cmacs-libresearch-export-to-inbox ()
  "Write the marked results (or the one at point) to an org note in the inbox.
The note follows the notes repo's conventions: header keywords, one
heading per result with its link, engines and snippet."
  (interactive)
  (let* ((rows (cmacs-lql-results-marked-rows))
         (query (or (car cmacs-libresearch--search) cmacs-lql-results--query))
         (now (format-time-string "%FT%T%:z"))
         (dir (cmacs-libresearch--inbox))
         (file (expand-file-name (format "%s_search_%s.org" (format-time-string "%F")
                                         (cmacs-libresearch--slug query))
                                 dir)))
    (make-directory dir t)
    (with-temp-file file
      (insert (format "#+title: Search: %s\n" query)
              (format "#+description: %d result%s from libresearch for \"%s\"\n"
                      (length rows) (if (cdr rows) "s" "") query)
              "#+authors: " user-full-name "\n"
              "#+categories: search\n"
              "#+created: " now "\n#+updated: " now "\n#+version: 1.0.0\n\n")
      (dolist (r rows)
        (let ((title (or (cdr (assoc "title" r)) (cdr (assoc "url" r)) "result")))
          (insert (format "* [[%s][%s]]\n" (cdr (assoc "url" r))
                          (replace-regexp-in-string "[][]" "" title)))
          (when-let* ((engines (cdr (assoc "engines" r))))
            (insert (format ":PROPERTIES:\n:ENGINES: %s\n:END:\n"
                            (mapconcat (lambda (e) (format "%s" e)) engines " "))))
          (when-let* ((snippet (cdr (assoc "snippet" r))))
            (insert snippet "\n"))
          (insert "\n"))))
    (message "Wrote %s" (abbreviate-file-name file))
    file))

;;;; The other request kinds

;;;###autoload
(defun cmacs-libresearch-query (query)
  "Run the LQL QUERY on the libresearch server; comb the rows in a grid."
  (interactive (list (read-string "libresearch LQL: " nil 'cmacs-lql-history)))
  (cmacs-ai-research--ensure)
  (cmacs-lql-results--loading query :target 'libresearch))

;;;###autoload
(defun cmacs-libresearch-research (question &optional deep)
  "Ask libresearch QUESTION; read the cited answer in org.
With a prefix argument, run a DEEP research (follow-up searches)."
  (interactive (list (read-string "Research: ") current-prefix-arg))
  (cmacs-ai-research question deep))

;;;###autoload
(defun cmacs-libresearch-fetch (url &optional archive)
  "Fetch URL's readable text through libresearch, in org.
With a prefix argument, fall back to the Wayback Machine's copy (ARCHIVE)."
  (interactive (list (read-string "URL: " (thing-at-point 'url)) current-prefix-arg))
  (cmacs-ai-web-fetch url (and archive 'fallback)))

;;;###autoload
(defun cmacs-libresearch-server ()
  "Show which libresearch server cmacs uses, and how it was found."
  (interactive)
  (let ((url (cmacs-ai-libresearch-endpoint)))
    (message "libresearch: %s (%s, %s)"
             url
             (cond ((and (stringp cmacs-ai-libresearch-url)
                         (not (string-empty-p cmacs-ai-libresearch-url)))
                    "cmacs-ai-libresearch-url")
                   ((cmacs-ai-libresearch--auth-entry) "authinfo")
                   ((getenv "LIBRESEARCH_URL") "LIBRESEARCH_URL")
                   (t "default"))
             (if (cmacs-ai-libresearch-token url) "token found" "no token"))))

(provide 'cmacs-libresearch)

;;; cmacs-libresearch.el ends here
