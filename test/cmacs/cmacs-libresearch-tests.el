;;; cmacs-libresearch-tests.el --- ERT tests for the libresearch client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers how cmacs finds its libresearch server (an authinfo entry for
;; the libresearch login, the explicit URL, LIBRESEARCH_URL, the
;; default), that the AI side's `auto' web search follows it, the search
;; results table built from a canned document, the org export, and
;; refining search results locally with LQL.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-libresearch-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)

(require 'cmacs-ai nil 'noerror)
(require 'cmacs-libresearch nil 'noerror)

(defvar cmacs-ai-libresearch-url)
(defvar cmacs-libresearch-inbox-directory)

(defmacro cmacs-libresearch-tests--with-authinfo (contents &rest body)
  "Run BODY with auth-source reading only a file holding CONTENTS."
  (declare (indent 1))
  `(let* ((file (make-temp-file "cmacs-lr-authinfo"))
          (auth-sources (list file))
          (auth-source-do-cache nil)
          (process-environment (cons "LIBRESEARCH_URL" process-environment))
          (cmacs-ai-libresearch-url nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,contents))
           (auth-source-forget-all-cached)
           ,@body)
       (delete-file file)
       (auth-source-forget-all-cached))))

(ert-deftest cmacs-libresearch-endpoint-from-authinfo ()
  "An authinfo entry for the libresearch login names the server and token."
  (skip-unless (fboundp 'cmacs-ai-libresearch-endpoint))
  (cmacs-libresearch-tests--with-authinfo
      "machine search.example.org port 443 login libresearch password TOK\n"
    (should (equal (cmacs-ai-libresearch-endpoint) "https://search.example.org"))
    (should (equal (cmacs-ai-libresearch-token) "TOK"))
    (should (cmacs-ai-libresearch-configured-p))))

(ert-deftest cmacs-libresearch-endpoint-ports-and-schemes ()
  "Any other port is http with the port; a full URL as host is kept."
  (skip-unless (fboundp 'cmacs-ai-libresearch--entry-url))
  (should (equal (cmacs-ai-libresearch--entry-url '(:host "h" :port "8087"))
                 "http://h:8087"))
  (should (equal (cmacs-ai-libresearch--entry-url '(:host "h" :port "https"))
                 "https://h"))
  (should (equal (cmacs-ai-libresearch--entry-url '(:host "https://h:9/x"))
                 "https://h:9/x"))
  (should-not (cmacs-ai-libresearch--entry-url '(:host ""))))

(ert-deftest cmacs-libresearch-endpoint-precedence ()
  "The explicit URL beats authinfo; with nothing set it is localhost."
  (skip-unless (fboundp 'cmacs-ai-libresearch-endpoint))
  (cmacs-libresearch-tests--with-authinfo
      "machine search.example.org port 443 login libresearch password TOK\n"
    (let ((cmacs-ai-libresearch-url "http://mine:1"))
      (should (equal (cmacs-ai-libresearch-endpoint) "http://mine:1"))))
  (cmacs-libresearch-tests--with-authinfo ""
    (should (equal (cmacs-ai-libresearch-endpoint) "http://127.0.0.1:8087"))
    (should-not (cmacs-ai-libresearch-configured-p))))

(ert-deftest cmacs-libresearch-auto-search-prefers-configured-server ()
  "`auto' web search becomes libresearch when a server is configured."
  (skip-unless (fboundp 'cmacs-ai-set-search-provider))
  (cmacs-libresearch-tests--with-authinfo
      "machine search.example.org port 443 login libresearch password TOK\n"
    (let (seen)
      (cl-letf (((symbol-function 'cmacs-ai-tools-set-search-provider)
                 (lambda (&rest args) (setq seen args) t)))
        (cmacs-ai-set-search-provider 3 'auto))
      (should (equal seen '(3 libresearch "TOK" "https://search.example.org"))))))

(defconst cmacs-libresearch-tests--search-doc
  "{\"schema\":\"libresearch.search/1\",\"results\":[
     {\"url\":\"https://docs.gtk.org/glib/\",\"title\":\"GLib\",\"snippet\":\"Utility\\nlibrary\",
      \"engines\":[\"brave\",\"ddg\"],\"score\":2.5,\"category\":\"general\"},
     {\"url\":\"https://example.org/\",\"title\":\"Example\",\"engines\":[\"ddg\"],\"score\":0.5}]}"
  "A canned search document.")

(ert-deftest cmacs-libresearch-search-table ()
  "A search payload becomes a typed results table."
  (skip-unless (fboundp 'cmacs-libresearch--search-table))
  (let* ((table (cmacs-libresearch--search-table
                 (list :ok :kind 'search :text "" :json cmacs-libresearch-tests--search-doc)))
         (rows (plist-get table :rows))
         (cols (mapcar #'car (plist-get table :columns))))
    (should (= (length rows) 2))
    (should (equal (aref (car rows) (cl-position "url" cols :test #'equal))
                   "https://docs.gtk.org/glib/"))
    (should (equal (aref (car rows) (cl-position "snippet" cols :test #'equal))
                   "Utility library"))
    (should (eq (car (cmacs-libresearch--search-table '(:error "boom"))) :error))))

(ert-deftest cmacs-libresearch-export-to-inbox ()
  "Exported results become an org note with the notes repo's header."
  (skip-unless (fboundp 'cmacs-libresearch-export-to-inbox))
  (let* ((dir (make-temp-file "cmacs-lr-inbox" t))
         (cmacs-libresearch-inbox-directory dir))
    (unwind-protect
        (with-temp-buffer
          (cmacs-libresearch-results-mode)
          (cmacs-lql-results--fill
           (cmacs-libresearch--search-table
            (list :ok :kind 'search :text "" :json cmacs-libresearch-tests--search-doc)))
          (setq cmacs-libresearch--search (cons "glib docs" nil))
          (goto-char (point-min))
          (let ((file (cmacs-libresearch-export-to-inbox)))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p "^#\\+title: Search: glib docs" (buffer-string)))
              (should (string-match-p "^#\\+created: " (buffer-string)))
              (should (string-match-p "\\[\\[https://" (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest cmacs-libresearch-refine-search-results-locally ()
  "`/' in a search grid filters the rows already fetched, with LQL."
  (skip-unless (and (fboundp 'cmacs-lql--run)
                    (fboundp 'cmacs-libresearch--search-table)))
  (with-temp-buffer
    (cmacs-libresearch-results-mode)
    (cmacs-lql-results--fill
     (cmacs-libresearch--search-table
      (list :ok :kind 'search :text "" :json cmacs-libresearch-tests--search-doc)))
    (let ((buf (save-window-excursion (cmacs-lql-results-refine "filter score > 1"))))
      (unwind-protect
          (with-current-buffer buf
            (let ((i 0))
              (while (and cmacs-lql-results--status (< i 200))
                (accept-process-output nil 0.02) (setq i (1+ i))))
            (should (= (length cmacs-lql-results--rows) 1)))
        (kill-buffer buf)))))

(provide 'cmacs-libresearch-tests)

;;; cmacs-libresearch-tests.el ends here
