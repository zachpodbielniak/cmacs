;;; cmacs-lql-notes-tests.el --- ERT tests for the notes LQL sources  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Builds a small PARA tree in a temporary directory, points
;; `cmacs-lql-notes-directories' at it, and checks the four sources:
;; header keywords and classification, headings with per-file TODO
;; keywords and planning, links resolved through id: and file: (and
;; never through Tramp), backlinks, property drawers, the archive
;; switch, unsaved buffers, and the snapshot cache.
;;
;; The parser and time helpers are pure Elisp; queries skip without the
;; LQL primitives.
;;
;; Run with:
;;   src/emacs -Q --batch -L lisp/cmacs -L test/cmacs -l ert \
;;     -l test/cmacs/cmacs-lql-notes-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'cmacs-lql nil 'noerror)
(require 'cmacs-lql-notes nil 'noerror)

(defvar cmacs-lql-notes-directories)
(defvar cmacs-lql-notes-include-archives)
(defvar cmacs-lql-notes-warm-in-idle)

(defconst cmacs-lql-notes-tests--files
  '(("00_inbox/00_index.org" .
     "#+title: Inbox Index\n#+created: 2026-01-01T00:00:00-05:00\n#+updated: 2026-01-01T00:00:00-05:00\n\n- [[file:../01_projects/work/alpha.org][alpha]]\n")
    ("00_inbox/idea.org" .
     ":PROPERTIES:\n:ID: idea-id\n:END:\n#+title: An Idea\n#+filetags: :spark:later:\n\nSome words here.\n")
    ("01_projects/work/alpha.org" .
     "#+title: Alpha\n#+description: The alpha project\n#+authors: Zach Podbielniak\n#+categories: work planning\n#+created: 2026-02-01T09:00:00-05:00\n#+updated: 2026-02-03T09:00:00-05:00\n#+version: 1.0.0\n#+TODO: TODO WAIT | DONE KILLED\n\n* WAIT [#A] Ship it :ops:\nSCHEDULED: <2026-02-10 Tue> DEADLINE: <2026-02-12 Thu>\n:PROPERTIES:\n:ID: alpha-ship\n:OWNER: zach\n:END:\nSee [[id:idea-id][the idea]] and [[https://example.org][a site]].\n** KILLED Old plan\nCLOSED: [2026-02-02 Mon 10:00]\n* NEXT not a keyword here\n")
    ("02_areas/dailies/2026-02-05.org" .
     "#+title: 2026-02-05\n\n- [[id:alpha-ship][ship]] [[file:/ssh:nohost.invalid:/tmp/x.org][remote]]\n")
    ("04_archives/01_projects/old.org" .
     "#+title: Old\n\n- [[file:missing.org][gone]]\n"))
  "The fixture tree: relative path -> contents.")

(defmacro cmacs-lql-notes-tests--with-tree (&rest body)
  "Run BODY with a fixture notes tree as the only notes directory."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "cmacs-notes" t)))
          (cmacs-lql-notes-directories (list root))
          (cmacs-lql-notes-include-archives t)
          (cmacs-lql-notes-warm-in-idle nil))
     (unwind-protect
         (progn
           (dolist (f cmacs-lql-notes-tests--files)
             (let ((path (expand-file-name (car f) root)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert (cdr f)))))
           (cmacs-lql-notes-clear-cache)
           ,@body)
       (cmacs-lql-notes-clear-cache)
       (delete-directory root t))))

(defun cmacs-lql-notes-tests--rows (query)
  "Rows of QUERY as alists (column . value)."
  (let* ((p (cmacs-lql-run-sync query))
         (table (cmacs-lql-payload-table p)))
    (should (eq (car p) :ok))
    (mapcar (lambda (r)
              (cl-loop for c in (plist-get table :columns) for i from 0
                       collect (cons (car c) (aref r i))))
            (plist-get table :rows))))

;;;; Pure Elisp

(ert-deftest cmacs-lql-notes-time-parsing ()
  "ISO 8601 and org timestamps parse; garbage does not."
  (skip-unless (fboundp 'cmacs-lql-notes--time))
  (should (= (cmacs-lql-notes--time "2026-02-01T09:00:00-05:00")
             (cmacs-lql-notes--time "2026-02-01T14:00:00Z")))
  (should (numberp (cmacs-lql-notes--time "<2026-02-10 Tue>")))
  (should (numberp (cmacs-lql-notes--time "[2026-02-02 Mon 10:00]")))
  (should-not (cmacs-lql-notes--time "someday")))

(ert-deftest cmacs-lql-notes-parse-file ()
  "Header, custom TODO keywords, planning, drawers and links are read."
  (skip-unless (fboundp 'cmacs-lql-notes--parse-buffer))
  (with-temp-buffer
    (insert (cdr (assoc "01_projects/work/alpha.org" cmacs-lql-notes-tests--files)))
    (let* ((p (cmacs-lql-notes--parse-buffer "/x/alpha.org" t))
           (h (plist-get p :headings)))
      (should (equal (cdr (assoc "title" (plist-get p :header))) "Alpha"))
      (should (= (length h) 3))
      (should (equal (plist-get (nth 0 h) :todo) "WAIT"))
      (should (equal (plist-get (nth 0 h) :priority) "A"))
      (should (equal (plist-get (nth 0 h) :tags) '("ops")))
      (should (equal (plist-get (nth 0 h) :id) "alpha-ship"))
      (should (string-match-p "2026-02-12" (plist-get (nth 0 h) :deadline)))
      (should (plist-get (nth 1 h) :done))
      (should (equal (plist-get (nth 1 h) :olpath) "Ship it / Old plan"))
      ;; NEXT is not a keyword in this file (#+TODO: overrides).
      (should-not (plist-get (nth 2 h) :todo))
      (should (equal (mapcar (lambda (l) (plist-get l :type)) (plist-get p :links))
                     '("id" "https"))))))

;;;; Queries

(ert-deftest cmacs-lql-notes-notes-source ()
  "The notes source classifies files and reads their headers."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-notes-tests--with-tree
    (let ((rows (cmacs-lql-notes-tests--rows "fetch notes | sort path")))
      (should (= (length rows) 5))
      (let ((alpha (cl-find "01_projects/work/alpha.org" rows
                            :key (lambda (r) (cdr (assoc "path" r))) :test #'equal)))
        (should (equal (cdr (assoc "para" alpha)) "projects"))
        (should (equal (cdr (assoc "scope" alpha)) "work"))
        (should (equal (cdr (assoc "title" alpha)) "Alpha"))
        (should (equal (cdr (assoc "categories" alpha)) ["work" "planning"]))
        (should (= (cdr (assoc "todos" alpha)) 1))
        (should (= (cdr (assoc "done" alpha)) 1))
        (should (eq (cdr (assoc "has_header" alpha)) t))
        ;; The inbox index and the daily link to it.
        (should (= (cdr (assoc "backlinks" alpha)) 2)))
      (let ((idea (cl-find "00_inbox/idea.org" rows
                           :key (lambda (r) (cdr (assoc "path" r))) :test #'equal)))
        (should (equal (cdr (assoc "tags" idea)) ["spark" "later"]))
        (should (equal (cdr (assoc "id" idea)) "idea-id"))
        (should (eq (cdr (assoc "has_header" idea)) :false)))
      (should (equal (cdr (assoc "path" (car (cmacs-lql-notes-tests--rows
                                              "fetch notes | filter daily"))))
                     "02_areas/dailies/2026-02-05.org")))))

(ert-deftest cmacs-lql-notes-inbox-filter ()
  "The headline example works: fetch notes | filter para == \"inbox\"."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-notes-tests--with-tree
    (should (equal (sort (mapcar (lambda (r) (cdr (assoc "path" r)))
                                 (cmacs-lql-notes-tests--rows
                                  "fetch notes | filter para == \"inbox\""))
                         #'string<)
                   '("00_inbox/00_index.org" "00_inbox/idea.org")))))

(ert-deftest cmacs-lql-notes-headings-links-properties ()
  "Headings, links (resolved, remote untouched) and properties."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-notes-tests--with-tree
    (let ((todo (cmacs-lql-notes-tests--rows
                 "fetch note_headings | filter is_not_null(todo) and not done")))
      (should (= (length todo) 1))
      (should (equal (cdr (assoc "heading" (car todo))) "Ship it")))
    (let ((links (cmacs-lql-notes-tests--rows "fetch note_links")))
      ;; id: resolves to the file holding the ID.
      (should (cl-some (lambda (r) (and (equal (cdr (assoc "target" r)) "id:idea-id")
                                        (string-suffix-p "00_inbox/idea.org"
                                                         (cdr (assoc "resolved" r)))))
                       links))
      ;; A remote target is never checked (no Tramp connection).
      (should (cl-some (lambda (r) (and (string-prefix-p "file:/ssh:" (cdr (assoc "target" r)))
                                        (eq (cdr (assoc "exists" r)) :false)))
                       links))
      ;; A missing local file is broken.
      (should (cl-some (lambda (r) (and (equal (cdr (assoc "target" r)) "file:missing.org")
                                        (eq (cdr (assoc "exists" r)) :false)))
                       links)))
    (should (equal (cdr (assoc "value" (car (cmacs-lql-notes-tests--rows
                                             "fetch note_properties | filter key == \"OWNER\""))))
                   "zach"))))

(ert-deftest cmacs-lql-notes-archives-switch ()
  "`cmacs-lql-notes-include-archives' nil leaves 04_archives out."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-notes-tests--with-tree
    (let ((cmacs-lql-notes-include-archives nil))
      (cmacs-lql-notes-clear-cache)
      (should-not (cmacs-lql-notes-tests--rows "fetch notes | filter para == \"archives\"")))))

(ert-deftest cmacs-lql-notes-unsaved-buffer-and-cache ()
  "An open, modified note is read from its buffer; an unchanged tree
reuses the snapshot JSON."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-notes-tests--with-tree
    (cmacs-lql-notes-tests--rows "fetch notes")
    (let ((a (cmacs-lql--snapshot "notes")) (b (cmacs-lql--snapshot "notes")))
      (should (eq a b)))
    (let ((buf (find-file-noselect (expand-file-name "00_inbox/idea.org" root))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-max))
            (insert "* TODO Fresh task\n")
            (let ((rows (cmacs-lql-notes-tests--rows
                         "fetch notes | filter path == \"00_inbox/idea.org\"")))
              (should (eq (cdr (assoc "unsaved" (car rows))) t))
              (should (= (cdr (assoc "todos" (car rows))) 1))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(provide 'cmacs-lql-notes-tests)

;;; cmacs-lql-notes-tests.el ends here
