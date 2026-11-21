;;; cmacs-journal-daily-tests.el --- ERT tests for the journal's daily note  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The daily note is Elisp over the journal's files, so all of it runs
;; here: events are written straight into a private journal directory,
;; against a clock the test owns, and the note goes into a private notes
;; tree.  NO TEST TOUCHES THE REAL NOTES: `cmacs-para-roots', the journal
;; directory and the filter sources are all rebound by
;; `cmacs-journal-daily-tests--with' before anything is read or written,
;; and a test fails if a note would land outside the temporary root.
;;
;; The model is never called.  `cmacs-ai-make-session' and
;; `cmacs-ai-chat-stream' are stubbed (taking &rest: they are C DEFUNs in
;; a real build), and a test plays the stream's payloads itself.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'org)
(require 'org-element)
(require 'cmacs-journal)
(require 'cmacs-journal-report)
(require 'cmacs-redact)
(require 'cmacs-journal-daily)

;; Specials of files this one does not load: without these lines a
;; `let' of them below would be lexical and bind nothing.
(defvar cmacs-ai-openai-compatible-endpoints)
(defvar cmacs-voice-commands)

(defvar cmacs-journal-daily-tests--clock 0.0
  "The time the journal sees during a test.")

(defvar cmacs-journal-daily-tests--root nil
  "The temporary directory of the running test.")

(defconst cmacs-journal-daily-tests--day "2026-03-10"
  "The day the synthetic events are on (a Tuesday).")

(defun cmacs-journal-daily-tests--at (hhmm &optional day)
  "Seconds for HHMM (\"09:30\") on DAY, default the test day."
  (float-time (date-to-time
               (format "%s %s:00" (or day cmacs-journal-daily-tests--day)
                       hhmm))))

(defmacro cmacs-journal-daily-tests--with (&rest body)
  "Run BODY with a private journal, a private notes tree and a test clock."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "cmacs-journal-daily-test" t))
          (cmacs-journal-daily-tests--root root)
          (cmacs-journal-directory (expand-file-name "state/journal" root))
          (cmacs-para-roots (list (expand-file-name "notes" root)))
          (cmacs-journal-daily-directory "02_areas/dailies")
          (cmacs-journal-daily-heading "Activity")
          (cmacs-journal-daily-weekly-heading "Activity this week")
          (cmacs-journal-daily-author "Test Author")
          (cmacs-journal-daily-categories "dailies")
          (cmacs-journal-daily-link-notes t)
          (cmacs-journal-daily-block-gap 300)
          (cmacs-journal-daily-block-min 60)
          (cmacs-journal-daily-max-rows 12)
          (cmacs-journal-daily-max-files 25)
          (cmacs-journal-daily-max-urls 25)
          (cmacs-journal-daily-stretches 3)
          (cmacs-journal-daily-summary nil)
          (cmacs-journal-daily-provider 'ollama)
          (cmacs-journal-daily-model "test-model")
          (cmacs-journal-daily-allow-remote nil)
          (cmacs-journal-daily-summary-timeout 600)
          (cmacs-journal-daily-write-yesterday t)
          (cmacs-journal-daily-time nil)
          (cmacs-journal-daily--jobs nil)
          (cmacs-journal-daily--done nil)
          (cmacs-journal-report-kinds '(focus buffer url))
          (cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters nil)
          (cmacs-journal-retention-days nil)
          (cmacs-journal-expose-to-agents nil)
          (cmacs-journal-daily-tests--clock
           (cmacs-journal-daily-tests--at "20:00"))
          (cmacs-journal-time-function
           (lambda () cmacs-journal-daily-tests--clock))
          (cmacs-journal--open nil)
          (cmacs-journal--queue nil)
          (cmacs-journal--in-tool-call nil)
          (cmacs-journal--file-cache (make-hash-table :test #'equal))
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter--signature nil)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-redact-mode t)
          (cmacs-redact-surfaces '(tool rpc prompt))
          (cmacs-redact--pending nil)
          (cmacs-redact--in-tool-call nil)
          (cmacs-redact--last-check (float-time))
          (process-environment (cons "OLLAMA_HOST" process-environment))
          (inhibit-interaction nil)
          (inhibit-message t)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (unwind-protect
         (progn (cmacs-journal-filters-reload) ,@body)
       (dolist (buffer (buffer-list))
         (let ((file (buffer-file-name buffer)))
           (when (and file (string-prefix-p root file))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (delete-directory root t))))

(defun cmacs-journal-daily-tests--span (kind from to &rest fields)
  "An event of KIND from FROM to TO (\"HH:MM\" strings) with FIELDS."
  (let ((start (cmacs-journal-daily-tests--at from))
        (end (cmacs-journal-daily-tests--at to)))
    (append (list :time start :end end :duration (- end start) :kind kind)
            fields)))

(defun cmacs-journal-daily-tests--store (events &optional day)
  "Write EVENTS as the journal's file for DAY, replacing it."
  (cmacs-journal--ensure-directory)
  (let ((file (cmacs-journal--day-file
               (or day cmacs-journal-daily-tests--day))))
    (cmacs-journal--write-lines file events nil)
    (remhash file cmacs-journal--file-cache)))

(defun cmacs-journal-daily-tests--day-events ()
  "A working day: two projects, a browser, a chat, an idle hour, a run."
  (list
   (cmacs-journal-daily-tests--span
    'buffer "09:00" "10:00" :app "emacs" :buffer "alpha.el"
    :file "~/src/alpha/alpha.el" :mode "emacs-lisp-mode" :project "alpha")
   ;; Two minutes in a chat window, then back: one block of alpha.
   (cmacs-journal-daily-tests--span
    'focus "10:00" "10:02" :app "chat" :title "Team room")
   (cmacs-journal-daily-tests--span
    'buffer "10:02" "10:30" :app "emacs" :buffer "alpha-test.el"
    :file "~/src/alpha/alpha-test.el" :mode "emacs-lisp-mode"
    :project "alpha")
   (cmacs-journal-daily-tests--span
    'url "10:30" "10:50" :app "gsurf" :title "GLib Reference"
    :buffer "*gsurf*" :url "https://docs.gtk.org/glib/index.html")
   (cmacs-journal-daily-tests--span 'idle "10:50" "11:50")
   (cmacs-journal-daily-tests--span
    'buffer "13:00" "14:30" :app "emacs" :buffer "beta.c"
    :file "~/src/beta/beta.c" :mode "c-mode" :project "beta")
   (append (list :time (cmacs-journal-daily-tests--at "14:10")
                 :end (cmacs-journal-daily-tests--at "14:10")
                 :duration 0 :kind 'agent :app "reviewer"
                 :title "Review beta" :detail "done"))))

(defun cmacs-journal-daily-tests--note (&optional day)
  "The note file for DAY, which must be inside the temporary root."
  (let ((file (expand-file-name
               (concat (or day cmacs-journal-daily-tests--day) ".org")
               (cmacs-journal-daily--directory))))
    (should (string-prefix-p cmacs-journal-daily-tests--root file))
    file))

(defun cmacs-journal-daily-tests--text (file)
  "The contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun cmacs-journal-daily-tests--run (&optional day span interactive)
  "Write the note for DAY over SPAN; return the result plist."
  (cmacs-journal-daily--run
   (cmacs-journal-daily--spec (or day cmacs-journal-daily-tests--day)
                              (or span 'day))
   interactive))

(defun cmacs-journal-daily-tests--count (regexp text)
  "How many times REGEXP matches in TEXT."
  (let ((count 0) (start 0))
    (while (string-match regexp text start)
      (setq count (1+ count) start (match-end 0)))
    count))

;;;; Facts

(ert-deftest cmacs-journal-daily-test-facts-from-events ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let* ((range (cmacs-journal-daily--day-range
                   cmacs-journal-daily-tests--day))
           (facts (cmacs-journal-daily-facts (car range) (cdr range))))
      (should (= (plist-get facts :count) 7))
      (should (= (plist-get facts :first)
                 (cmacs-journal-daily-tests--at "09:00")))
      (should (= (plist-get facts :last)
                 (cmacs-journal-daily-tests--at "14:30")))
      ;; 60 + 2 + 28 + 20 + 90 minutes; the idle hour is not activity.
      (should (= (plist-get facts :active) (* 200 60)))
      (should (= (plist-get facts :idle) 3600))
      ;; The totals are `cmacs-journal-summarize''s own.
      (should (equal (plist-get facts :projects)
                     (cmacs-journal-summarize
                      (cmacs-journal-events (car range) (cdr range))
                      'project)))
      (should (= (alist-get "beta" (plist-get facts :projects) nil nil #'equal)
                 5400))
      (should (= (alist-get "alpha" (plist-get facts :projects) nil nil #'equal)
                 5280))
      (should (= (alist-get "emacs" (plist-get facts :apps) nil nil #'equal)
                 (* 178 60)))
      (should (equal (plist-get facts :sites) '(("docs.gtk.org" . 1200.0))))
      (should (equal (mapcar #'car (plist-get facts :files))
                     '("~/src/beta/beta.c" "~/src/alpha/alpha.el"
                       "~/src/alpha/alpha-test.el")))
      (should (equal (car (car (plist-get facts :urls)))
                     "https://docs.gtk.org/glib/index.html"))
      (should (= (length (plist-get facts :runs)) 1))
      ;; Longest first: beta's 1:30, then alpha's 1:28 around the chat.
      (should (equal (mapcar (lambda (b) (plist-get b :label))
                             (plist-get facts :stretches))
                     '("beta" "alpha" "gsurf"))))))

(ert-deftest cmacs-journal-daily-test-span-across-midnight-is-cut ()
  (cmacs-journal-daily-tests--with
    (let ((start (cmacs-journal-daily-tests--at "23:00" "2026-03-09"))
          (end (cmacs-journal-daily-tests--at "01:00")))
      (cmacs-journal-daily-tests--store
       (list (list :time start :end end :duration (- end start) :kind 'buffer
                   :app "emacs" :buffer "late.el" :project "late"))
       "2026-03-09")
      (let* ((range (cmacs-journal-daily--day-range
                     cmacs-journal-daily-tests--day))
             (facts (cmacs-journal-daily-facts (car range) (cdr range))))
        (should (= (plist-get facts :active) 3600))
        (should (= (plist-get facts :first)
                   (cmacs-journal-daily-tests--at "00:00")))))))

(ert-deftest cmacs-journal-daily-test-block-merging ()
  (let* ((cmacs-journal-daily-block-gap 300)
         (ev (lambda (from to label)
               (list :time from :end to :duration (- to from)
                     :kind 'buffer :project label)))
         (blocks (cmacs-journal-daily-blocks
                  (list (funcall ev 0 1000 "a")
                        ;; 100 s later, same label: the same block.
                        (funcall ev 1100 2000 "a")
                        ;; A 120 s look at b, then back to a: absorbed.
                        (funcall ev 2000 2120 "b")
                        (funcall ev 2120 3000 "a")
                        ;; b for longer than the gap is its own block.
                        (funcall ev 3000 4000 "b")
                        ;; a again, but 1000 s after a ended: a new block.
                        (funcall ev 4000 4500 "a")
                        ;; Same label after a gap wider than the tolerance.
                        (funcall ev 5000 5100 "a")))))
    (should (equal (mapcar (lambda (b) (plist-get b :label)) blocks)
                   '("a" "b" "a" "a")))
    (let ((first (car blocks)))
      (should (= (plist-get first :start) 0))
      (should (= (plist-get first :end) 3000))
      ;; The interruption is inside the block but is not time on a.
      (should (= (plist-get first :active) (+ 1000 900 880))))
    (should (= (plist-get (nth 1 blocks) :active) 1000))
    (should (= (plist-get (nth 2 blocks) :end) 4500))
    (should (= (plist-get (nth 3 blocks) :start) 5000)))
  ;; No project: the application is the label.
  (should (equal (plist-get
                  (car (cmacs-journal-daily-blocks
                        (list (list :time 0 :end 10 :duration 10
                                    :kind 'focus :app "firefox"))))
                  :label)
                 "firefox")))

;;;; The note as Org

(ert-deftest cmacs-journal-daily-test-new-note-shape ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let* ((result (cmacs-journal-daily-tests--run))
           (file (cmacs-journal-daily-tests--note))
           (text (cmacs-journal-daily-tests--text file)))
      (should (eq (plist-get result :status) 'written))
      (should (plist-get result :created))
      (should (equal (plist-get result :file) file))
      (should (null (plist-get result :summary)))
      ;; The house header, in order, with an org-roam ID.
      (should (string-match-p
               (concat "\\`:PROPERTIES:\n:ID:       "
                       "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-"
                       "[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\n:END:\n"
                       "#\\+title: 2026-03-10\n"
                       "#\\+description: .+\n"
                       "#\\+authors: Test Author\n"
                       "#\\+categories: dailies\n"
                       "#\\+created: [0-9-]+T[0-9:]+[+-][0-9]\\{4\\}\n"
                       "#\\+updated: [0-9-]+T[0-9:]+[+-][0-9]\\{4\\}\n"
                       "#\\+version: 1\\.0\\.0\n")
               text))
      (should (string-suffix-p "\n" text))
      (should-not (string-suffix-p "\n\n" text))
      ;; No hard wrap: below the header every line is a heading, a
      ;; drawer line, a table row, a list item, blank, or the one
      ;; paragraph -- which is one line however long it is.
      (let ((body (substring text (string-match "^\\* Activity$" text)))
            (prose 0))
        (dolist (line (split-string body "\n"))
          (unless (string-match-p "\\`\\(?:\\*+ \\|:\\||\\|- \\|\\'\\)" line)
            (setq prose (1+ prose))
            (should (string-prefix-p "First activity 09:00, last 14:30." line))
            (should (> (length line) 100))))
        (should (= prose 1)))
      ;; It parses back as the Org it claims to be.
      (with-temp-buffer
        (insert text)
        (let ((org-mode-hook nil)) (delay-mode-hooks (org-mode)))
        (let* ((tree (org-element-parse-buffer))
               (headlines (org-element-map tree 'headline
                            (lambda (h)
                              (cons (org-element-property :level h)
                                    (org-element-property :raw-value h)))))
               (links (org-element-map tree 'link
                        (lambda (l)
                          (cons (org-element-property :type l)
                                (org-element-property :path l))))))
          (should (equal (car headlines) '(1 . "Activity")))
          (should (equal (mapcar #'cdr (cdr headlines))
                         '("Time by project" "Time by application"
                           "Time by site" "Timeline"
                           "Longest focus stretches" "Files touched"
                           "Pages visited" "Agent runs finished")))
          (should (cl-every (lambda (h) (= (car h) 2)) (cdr headlines)))
          (should (= (length (org-element-map tree 'table #'identity)) 3))
          (should (member '("file" . "~/src/beta/beta.c") links))
          (should (member '("https" . "//docs.gtk.org/glib/index.html") links))
          (goto-char (point-min))
          (re-search-forward "^\\* Activity$")
          (should (equal (org-entry-get (point) "CMACS_JOURNAL_DAILY") "t"))
          (should (equal (org-entry-get (point) "CUSTOM_ID")
                         "cmacs-journal-daily"))))
      ;; The timeline: the chat is absorbed, the idle hour is a gap.
      (should (string-match-p "^- 09:00--10:30 (1:28) alpha$" text))
      (should (string-match-p "^- 10:30--10:50 (0:20) gsurf$" text))
      (should (string-match-p "^- 13:00--14:30 (1:30) beta$" text))
      (should-not (string-match-p "^- 10:00--10:02" text))
      (should (string-match-p
               "^- \\[\\[https://docs.gtk.org/glib/index.html\\]\\[GLib Reference\\]\\] (0:20)$"
               text))
      (should (string-match-p "^- 14:10 reviewer: Review beta (done)$" text)))))

(ert-deftest cmacs-journal-daily-test-table-is-aligned-and-escaped ()
  (let ((table (cmacs-journal-daily--time-table
                "Project" '(("a|b" . 3600) ("longer name" . 1800)))))
    (should (equal table
                   (concat "| Project     | Time | %  |\n"
                           "|-------------+------+----|\n"
                           "| a\\vert{}b   | 1:00 | 67 |\n"
                           "| longer name | 0:30 | 33 |\n"))))
  (let ((cmacs-journal-daily-max-rows 1))
    (should (string-match-p
             "(other)"
             (cmacs-journal-daily--time-table "P" '(("a" . 60) ("b" . 30)))))))

(ert-deftest cmacs-journal-daily-test-links ()
  (let ((cmacs-journal-daily-link-notes nil))
    (should (equal (cmacs-journal-daily--file-link "~/a/b.el")
                   "[[file:~/a/b.el][b.el]]"))
    ;; A hashed name is not a path any more.
    (should (equal (cmacs-journal-daily--file-link "#3f9a2c") "#3f9a2c"))
    (should (equal (cmacs-journal-daily--url-link "https://x.org/a" "T [1]")
                   "[[https://x.org/a][T (1)]]"))
    (should (equal (cmacs-journal-daily--url-link "https://x.org/a" nil)
                   "[[https://x.org/a][x.org]]"))
    (should (equal (cmacs-journal-daily--url-link "#abc" "Title")
                   "Title (#abc)"))))

(ert-deftest cmacs-journal-daily-test-note-in-para-tree-linked-by-id ()
  (cmacs-journal-daily-tests--with
    (let ((note (expand-file-name "03_resources/topic.org"
                                  (car cmacs-para-roots))))
      (make-directory (file-name-directory note) t)
      (with-temp-file note
        (insert ":PROPERTIES:\n:ID:       abc-123\n:END:\n#+title: Topic\n"))
      (should (equal (cmacs-journal-daily--file-link note)
                     "[[id:abc-123][topic.org]]"))
      (let ((cmacs-journal-daily-link-notes nil))
        (should (string-prefix-p "[[file:"
                                 (cmacs-journal-daily--file-link note)))))))

;;;; A file the user already has

(defconst cmacs-journal-daily-tests--hand-written
  (concat ":PROPERTIES:\n:ID:       hand-written-id\n:END:\n"
          "#+title: 2026-03-10\n\n"
          "* Reflection\nA paragraph I wrote, with trailing spaces.  \n\n"
          "** A child of mine\n- an item\n\n"
          "* Tasks\n- [ ] something\n")
  "A daily the user wrote by hand.")

(ert-deftest cmacs-journal-daily-test-subtree-replaced-in-place ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((file (cmacs-journal-daily-tests--note))
          (after "\n* Evening\nWritten after the journal's subtree.\n"))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert cmacs-journal-daily-tests--hand-written))
      ;; First run: appended, nothing above it touched, no new header.
      (let ((result (cmacs-journal-daily-tests--run)))
        (should (eq (plist-get result :status) 'written))
        (should-not (plist-get result :created)))
      (let ((text (cmacs-journal-daily-tests--text file)))
        (should (string-prefix-p cmacs-journal-daily-tests--hand-written text))
        (should (= (cmacs-journal-daily-tests--count "^#\\+title:" text) 1))
        (should (string-match-p "hand-written-id" text))
        ;; The user writes more, below the subtree.
        (with-temp-file file (insert text after)))
      ;; Same facts again: nothing is written at all.
      (let ((before (cmacs-journal-daily-tests--text file))
            (result (cmacs-journal-daily-tests--run)))
        (should (eq (plist-get result :status) 'unchanged))
        (should (equal before (cmacs-journal-daily-tests--text file))))
      ;; The day goes on: the subtree is replaced where it stands.
      (cmacs-journal-daily-tests--store
       (append (cmacs-journal-daily-tests--day-events)
               (list (cmacs-journal-daily-tests--span
                      'buffer "15:00" "16:00" :app "emacs" :buffer "g.el"
                      :file "~/src/gamma/g.el" :project "gamma"))))
      (let ((result (cmacs-journal-daily-tests--run))
            (text nil))
        (should (eq (plist-get result :status) 'written))
        (setq text (cmacs-journal-daily-tests--text file))
        (should (string-prefix-p cmacs-journal-daily-tests--hand-written text))
        (should (string-suffix-p after text))
        (should (= (cmacs-journal-daily-tests--count
                    "^:CMACS_JOURNAL_DAILY: t$" text)
                   1))
        (should (= (cmacs-journal-daily-tests--count "^\\* Activity$" text) 1))
        (should (string-match-p "gamma" text))
        ;; Everything that is not the owned subtree is byte for byte
        ;; what the user had.
        (let ((beg (string-match "^\\* Activity$" text))
              (end (string-match "^\\* Evening$" text)))
          (should (equal (concat (substring text 0 beg) (substring text end))
                         (concat cmacs-journal-daily-tests--hand-written
                                 "\n" (substring after 1)))))))))

(ert-deftest cmacs-journal-daily-test-modified-buffer-is-not-saved ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((file (cmacs-journal-daily-tests--note)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert cmacs-journal-daily-tests--hand-written))
      (let ((buffer (let ((org-mode-hook nil) (find-file-hook nil))
                      (find-file-noselect file))))
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "^\\* Tasks$")
          (forward-line 1)
          (insert "- [ ] typed and not saved\n"))
        (should (buffer-modified-p buffer))
        (let ((result (cmacs-journal-daily-tests--run)))
          (should (eq (plist-get result :status) 'buffer-unsaved)))
        ;; The disk is as it was; the buffer has both the unsaved line
        ;; and the subtree, and is still the user's to save.
        (should (equal (cmacs-journal-daily-tests--text file)
                       cmacs-journal-daily-tests--hand-written))
        (should (buffer-modified-p buffer))
        (with-current-buffer buffer
          (let ((text (buffer-string)))
            (should (string-match-p "typed and not saved" text))
            (should (string-match-p "^:CMACS_JOURNAL_DAILY: t$" text))
            (should (string-match-p "^\\*\\* Time by project$" text))))
        ;; A second run updates the same buffer and adds no second one.
        (cmacs-journal-daily-tests--run)
        (with-current-buffer buffer
          (should (= (cmacs-journal-daily-tests--count
                      "^\\* Activity$" (buffer-string))
                     1)))))))

(ert-deftest cmacs-journal-daily-test-unmodified-buffer-stays-in-sync ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((file (cmacs-journal-daily-tests--note))
          (saves 0))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert cmacs-journal-daily-tests--hand-written))
      (let ((buffer (let ((org-mode-hook nil) (find-file-hook nil))
                      (find-file-noselect file))))
        (with-current-buffer buffer
          (add-hook 'before-save-hook (lambda () (setq saves (1+ saves)))
                    nil t)
          (goto-char (point-min))
          (re-search-forward "A paragraph"))
        (let ((result (cmacs-journal-daily-tests--run)))
          (should (eq (plist-get result :status) 'written)))
        (should-not (buffer-modified-p buffer))
        (should (verify-visited-file-modtime buffer))
        ;; Written without the user's save hooks.
        (should (= saves 0))
        (with-current-buffer buffer
          (should (equal (buffer-string)
                         (cmacs-journal-daily-tests--text file)))
          (should (string-match-p "^:CMACS_JOURNAL_DAILY: t$"
                                  (buffer-string)))
          ;; Point is where the user left it.
          (should (looking-back "A paragraph" (line-beginning-position))))))))

;;;; The index

(ert-deftest cmacs-journal-daily-test-index-bullet-added-once ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (cmacs-journal-daily-tests--run)
    (let* ((file (cmacs-journal-daily-tests--note))
           (index (expand-file-name "00_index.org" (file-name-directory file)))
           (id (with-temp-buffer
                 (insert-file-contents file)
                 (re-search-forward "^:ID:[ \t]+\\(.+\\)$")
                 (match-string 1)))
           (bullet (format "^- \\[\\[id:%s\\]\\[2026-03-10\\]\\]$"
                           (regexp-quote id))))
      (should (file-exists-p index))
      (let ((text (cmacs-journal-daily-tests--text index)))
        (should (string-match-p "^#\\+title: Dailies Index$" text))
        (should (string-match-p "^:ID:" text))
        (should (= (cmacs-journal-daily-tests--count bullet text) 1)))
      ;; Running again, with new facts, does not add a second bullet.
      (cmacs-journal-daily-tests--store
       (butlast (cmacs-journal-daily-tests--day-events)))
      (should (eq (plist-get (cmacs-journal-daily-tests--run) :status)
                  'written))
      (should (= (cmacs-journal-daily-tests--count
                  bullet (cmacs-journal-daily-tests--text index))
                 1)))))

(ert-deftest cmacs-journal-daily-test-index-edit-follows-the-layout ()
  (let* ((time (cmacs-journal-daily-tests--at "12:00"))
         (apply-edit
          (lambda (text id title)
            (let ((edit (cmacs-journal-daily--index-edit text id title time)))
              (if (null edit)
                  text
                (concat (substring text 0 (1- (plist-get edit :beg)))
                        (plist-get edit :new)
                        (substring text (1- (plist-get edit :end))))))))
         (monthly (concat "#+title: Dailies Index\n\n* Contents\n\n"
                          "** March 2026\n"
                          "- [[id:a][2026-03-12]]\n"
                          "- [[id:b][2026-03-04]]\n\n"
                          "** February 2026\n"
                          "- [[id:c][2026-02-20]]\n")))
    ;; Among its month's bullets, newest first.
    (should (equal (funcall apply-edit monthly "new" "2026-03-10")
                   (concat "#+title: Dailies Index\n\n* Contents\n\n"
                           "** March 2026\n"
                           "- [[id:a][2026-03-12]]\n"
                           "- [[id:new][2026-03-10]]\n"
                           "- [[id:b][2026-03-04]]\n\n"
                           "** February 2026\n"
                           "- [[id:c][2026-02-20]]\n")))
    ;; Older than every bullet of the month: after the last one.
    (should (string-match-p
             "2026-03-04\\]\\]\n- \\[\\[id:new\\]\\[2026-03-01\\]\\]\n\n\\*\\* February"
             (funcall apply-edit monthly "new" "2026-03-01")))
    ;; Already linked: nothing to do.
    (should (null (cmacs-journal-daily--index-edit monthly "b" "x" time)))
    ;; A month the index does not have yet goes above the older ones.
    (let ((text (concat "* Contents\n\n** February 2026\n"
                        "- [[id:c][2026-02-20]]\n\n** January 2026\n"
                        "- [[id:d][2026-01-02]]\n")))
      (should (equal (funcall apply-edit text "new" "2026-03-10")
                     (concat "* Contents\n\n** March 2026\n"
                             "- [[id:new][2026-03-10]]\n\n"
                             "** February 2026\n"
                             "- [[id:c][2026-02-20]]\n\n** January 2026\n"
                             "- [[id:d][2026-01-02]]\n"))))
    ;; And one older than all of them goes below.
    (let ((text "* Contents\n\n** April 2026\n- [[id:c][2026-04-02]]\n"))
      (should (equal (funcall apply-edit text "new" "2026-03-10")
                     (concat text "\n** March 2026\n"
                             "- [[id:new][2026-03-10]]\n"))))
    ;; No months: after the last id bullet.
    (should (equal (funcall apply-edit
                            "* Contents\n- [[id:x][one]]\n\n* Other\ntext\n"
                            "new" "2026-03-10")
                   (concat "* Contents\n- [[id:x][one]]\n"
                           "- [[id:new][2026-03-10]]\n\n* Other\ntext\n")))))

;;;; Privacy

(ert-deftest cmacs-journal-daily-test-todays-rules-apply-to-old-spans ()
  (cmacs-journal-daily-tests--with
    ;; Recorded while there was no rule about any of this.
    (cmacs-journal-daily-tests--store
     (append
      (cmacs-journal-daily-tests--day-events)
      (list
       (cmacs-journal-daily-tests--span
        'focus "15:00" "15:30" :app "vault" :title "Merger with Initech")
       (cmacs-journal-daily-tests--span
        'url "15:30" "16:00" :app "gsurf" :title "Account 12345678 statement"
        :url "https://bank.example/accounts")
       (cmacs-journal-daily-tests--span
        'buffer "16:00" "16:30" :app "emacs" :buffer "plan.org"
        :file "~/private/plan.org" :project "skunkworks"))))
    (let* ((range (cmacs-journal-daily--day-range
                   cmacs-journal-daily-tests--day))
           (before (cmacs-journal-daily-facts (car range) (cdr range))))
      (should (string-match-p "Initech\\|vault"
                              (cmacs-journal-daily-render before)))
      ;; The rules change AFTER the spans are on disk.
      (setq cmacs-journal-filters
            '((:match ((:app . "\\`vault\\'")) :exclude t)
              (:match ((:url . "bank"))
               :replace ((:title "[0-9]\\{6,\\}" "***")))
              (:match ((:project . "skunkworks")) :drop (:file :project))))
      (should (cmacs-journal-filters-reload))
      (let* ((facts (cmacs-journal-daily-facts (car range) (cdr range)))
             (note (cmacs-journal-daily-render facts))
             (prompt (cmacs-journal-daily-prompt facts "2026-03-10")))
        (dolist (text (list note prompt (format "%S" facts)))
          (should-not (string-match-p "Initech" text))
          (should-not (string-match-p "vault" text))
          (should-not (string-match-p "12345678" text))
          (should-not (string-match-p "skunkworks" text))
          (should-not (string-match-p "plan\\.org" text)))
        (should (string-match-p "Account \\*\\*\\* statement" note))
        (should (string-match-p "Account \\*\\*\\* statement" prompt))
        ;; The excluded half hour is gone from the totals too.
        (should (= (plist-get facts :active)
                   (- (plist-get before :active) 1800)))
        ;; What was not touched by a rule is still there.
        (should (string-match-p "alpha" prompt))
        (should (string-match-p "GLib Reference" prompt))))))

(ert-deftest cmacs-journal-daily-test-prompt-text-rules ()
  ;; A free-text rule reaches the prompt even where no field rule did.
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let* ((range (cmacs-journal-daily--day-range
                   cmacs-journal-daily-tests--day))
           (facts (cmacs-journal-daily-facts (car range) (cdr range)))
           (seen nil))
      (cl-letf (((symbol-function 'cmacs-redact-text)
                 (lambda (&rest args)
                   (push (car args) seen)
                   (should cmacs-redact--as-model)
                   (string-replace "beta" "[x]" (car args)))))
        (let ((prompt (cmacs-journal-daily-prompt facts "2026-03-10")))
          (should-not (string-match-p "beta" prompt))
          (should (string-match-p "\\[x\\]" prompt))
          ;; Every non-blank line went through it.
          (should (= (length seen)
                     (length (split-string prompt "\n" t)))))))))

(ert-deftest cmacs-journal-daily-test-fails-closed ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    ;; A rule that does not compile: no rule set, so no note.
    (setq cmacs-journal-filters '((:match ((:title . "\\(")) :exclude t)))
    (should-not (cmacs-journal-filters-reload))
    (let ((result (cmacs-journal-daily-tests--run)))
      (should (eq (plist-get result :status) 'not-ready))
      (should-not (file-exists-p (cmacs-journal-daily-tests--note)))
      (should-not (file-exists-p (cmacs-journal-daily--directory))))
    ;; The mode does not count that as dealt with: it will try again.
    (setq cmacs-journal-daily-tests--clock
          (cmacs-journal-daily-tests--at "09:00" "2026-03-11"))
    (cmacs-journal-daily-tests--store
     (list (list :time (cmacs-journal-daily-tests--at "08:00" "2026-03-11")
                 :end (cmacs-journal-daily-tests--at "08:30" "2026-03-11")
                 :duration 1800 :kind 'focus :app "term" :title "t"))
     "2026-03-11")
    (cmacs-journal-daily--tick)
    (should (null cmacs-journal-daily--done))
    (should-not (file-exists-p (cmacs-journal-daily-tests--note)))
    ;; Fixed: the next look writes it.
    (setq cmacs-journal-filters nil)
    (should (cmacs-journal-filters-reload))
    (cmacs-journal-daily--tick)
    (should (equal cmacs-journal-daily--done '("2026-03-10")))
    (should (file-exists-p (cmacs-journal-daily-tests--note)))))

(ert-deftest cmacs-journal-daily-test-refuses-agents ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((inhibit-interaction t))
      (should-error (cmacs-journal-daily cmacs-journal-daily-tests--day))
      (should-error (cmacs-journal-weekly cmacs-journal-daily-tests--day))
      (should-error (cmacs-journal-daily-preview
                     cmacs-journal-daily-tests--day)))
    (let ((cmacs-journal--in-tool-call t))
      (should-error (cmacs-journal-daily cmacs-journal-daily-tests--day))
      ;; The timer does nothing while an agent is being served.
      (setq cmacs-journal-daily-tests--clock
            (cmacs-journal-daily-tests--at "09:00" "2026-03-11"))
      (cmacs-journal-daily--tick)
      (should (null cmacs-journal-daily--done)))
    (should-not (file-exists-p (cmacs-journal-daily-tests--note)))))

(ert-deftest cmacs-journal-daily-test-empty-day-writes-nothing ()
  (cmacs-journal-daily-tests--with
    (let ((result (cmacs-journal-daily-tests--run)))
      (should (eq (plist-get result :status) 'empty))
      (should (null (cmacs-journal-daily cmacs-journal-daily-tests--day)))
      (should-not (file-exists-p (cmacs-journal-daily--directory))))))

;;;; Named contexts

(defun cmacs-journal-daily-tests--switch (at title &optional day)
  "A `context' event: a switch to the context TITLE at AT (\"HH:MM\")."
  (let ((time (cmacs-journal-daily-tests--at at day)))
    (list :time time :end time :duration 0 :kind 'context :app "emacs"
          :title title :detail "switch")))

(ert-deftest cmacs-journal-daily-test-no-context-no-table ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let* ((range (cmacs-journal-daily--day-range
                   cmacs-journal-daily-tests--day))
           (facts (cmacs-journal-daily-facts (car range) (cdr range)))
           (note (cmacs-journal-daily-render facts)))
      (should (null (plist-get facts :contexts)))
      (should-not (string-match-p "context" note))
      (should-not (string-match-p "\\] *$" note)))))

(ert-deftest cmacs-journal-daily-test-time-by-context ()
  (cmacs-journal-daily-tests--with
    ;; "client" was switched to the evening before; "writing" at 09:30,
    ;; in the middle of the first span; "client" again at 13:00.
    (cmacs-journal-daily-tests--store
     (list (cmacs-journal-daily-tests--switch "18:00" "client" "2026-03-09"))
     "2026-03-09")
    (cmacs-journal-daily-tests--store
     (sort (append (cmacs-journal-daily-tests--day-events)
                   (list (cmacs-journal-daily-tests--switch "09:30" "writing")
                         (cmacs-journal-daily-tests--switch "13:00" "client")))
           (lambda (a b) (< (plist-get a :time) (plist-get b :time)))))
    (let* ((range (cmacs-journal-daily--day-range
                   cmacs-journal-daily-tests--day))
           (facts (cmacs-journal-daily-facts (car range) (cdr range)))
           (note (cmacs-journal-daily-render facts))
           (prompt (cmacs-journal-daily-prompt facts "2026-03-10")))
      ;; client: 09:00-09:30 and 13:00-14:30; writing: 09:30-10:50.
      (should (equal (plist-get facts :contexts)
                     '(("client" . 7200.0) ("writing" . 4800.0))))
      ;; Cutting a span at a switch moves no time.
      (should (= (plist-get facts :active) (* 200 60)))
      (should (= (alist-get "alpha" (plist-get facts :projects) nil nil #'equal)
                 5280))
      (should (string-match-p "^\\*\\* Time by context\n| Context" note))
      (should (< (string-match "Time by context" note)
                 (string-match "Time by project" note)))
      ;; The same project on both sides of a switch is two blocks.
      (should (string-match-p "^- 09:00--09:30 (0:30) alpha \\[client\\]$" note))
      (should (string-match-p "^- 09:30--10:30 (0:58) alpha \\[writing\\]$" note))
      (should (string-match-p "^- 13:00--14:30 (1:30) beta \\[client\\]$" note))
      (should (string-match-p "^Time by context:$" prompt))
      (should (string-match-p "alpha \\[writing\\]" prompt))
      ;; A context's name is a title like any other to the rules.
      (setq cmacs-journal-filters
            '((:match ((:kind . "\\`context\\'") (:title . "client"))
               :replace ((:title "client" "work")))
              (:match ((:kind . "\\`context\\'") (:title . "writing"))
               :exclude t)))
      (should (cmacs-journal-filters-reload))
      (let* ((facts (cmacs-journal-daily-facts (car range) (cdr range)))
             (text (concat (cmacs-journal-daily-render facts)
                           (cmacs-journal-daily-prompt facts "2026-03-10")
                           (format "%S" facts))))
        (should-not (string-match-p "client\\|writing" text))
        ;; The excluded switch never happened: the day is all "work".
        (should (equal (plist-get facts :contexts) '(("work" . 12000.0))))))))

;;;; The model

(ert-deftest cmacs-journal-daily-test-provider-local-p ()
  (let ((cmacs-journal-daily-local-hosts '("localhost" "127.0.0.1" "::1"
                                           "[::1]"))
        (cmacs-ai-openai-compatible-endpoints
         '((mine :base-url "http://localhost:8000/v1")
           (lan :base-url "http://box.lan:8000/v1")
           (hosted :base-url "https://api.example.com/v1"))))
    (cl-letf (((symbol-function 'cmacs-ai-config-base-url) nil))
      (let ((process-environment (cons "OLLAMA_HOST" process-environment)))
        (should (cmacs-journal-daily-provider-local-p 'ollama)))
      (dolist (host '("127.0.0.1:11434" "http://localhost:11434"
                      "http://127.0.0.2:11434/" "[::1]:11434"))
        (let ((process-environment
               (cons (concat "OLLAMA_HOST=" host) process-environment)))
          (should (cmacs-journal-daily-provider-local-p 'ollama))))
      (dolist (host '("http://gpu.example.com:11434" "10.0.0.5:11434"
                      "https://ollama.example.com"))
        (let ((process-environment
               (cons (concat "OLLAMA_HOST=" host) process-environment)))
          (should-not (cmacs-journal-daily-provider-local-p 'ollama)))))
    (should (cmacs-journal-daily-provider-local-p 'mine))
    (should-not (cmacs-journal-daily-provider-local-p 'lan))
    (should-not (cmacs-journal-daily-provider-local-p 'hosted))
    (let ((cmacs-journal-daily-local-hosts '("box.lan")))
      (should (cmacs-journal-daily-provider-local-p 'lan)))
    (dolist (remote '(claude openai gemini grok claude-code codex-cli
                             openai-compatible nil-such-provider))
      (should-not (cmacs-journal-daily-provider-local-p remote)))))

(defmacro cmacs-journal-daily-tests--with-ai (calls &rest body)
  "Run BODY with cmacs-ai stubbed; CALLS collects (PROMPT CALLBACK SYSTEM)."
  (declare (indent 1) (debug t))
  `(let ((system nil) (freed 0))
     (ignore freed)
     (cl-letf (((symbol-function 'cmacs-journal-daily--ai-available-p)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-ai-make-session)
                (lambda (&rest args)
                  (setq system args)
                  (cons 11 22)))
               ((symbol-function 'cmacs-ai-free-session)
                (lambda (&rest _) (setq freed (1+ freed))))
               ((symbol-function 'cmacs-ai-chat-cancel)
                (lambda (&rest _) nil))
               ((symbol-function 'cmacs-ai-chat-stream)
                (lambda (&rest args)
                  (push (list (nth 1 args) (nth 2 args) system) ,calls)
                  t)))
       (unwind-protect
           (progn ,@body)
         (dolist (job cmacs-journal-daily--jobs)
           (when (timerp (plist-get (cdr job) :timer))
             (cancel-timer (plist-get (cdr job) :timer))))))))

(ert-deftest cmacs-journal-daily-test-remote-provider-refused ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((calls nil) (asked 0)
          (cmacs-journal-daily-summary t)
          (cmacs-journal-daily-provider 'claude))
      (cmacs-journal-daily-tests--with-ai calls
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (setq asked (1+ asked)) nil)))
          ;; Not allowed: the facts are written, nothing is sent, and
          ;; nobody is even asked.
          (let ((result (cmacs-journal-daily-tests--run nil nil t)))
            (should (eq (plist-get result :status) 'written))
            (should (stringp (plist-get result :summary)))
            (should (string-match-p "not a local model"
                                    (plist-get result :summary))))
          (should (null calls))
          (should (= asked 0))
          (should (file-exists-p (cmacs-journal-daily-tests--note)))
          ;; Allowed, and the person says no.
          (let ((cmacs-journal-daily-allow-remote t))
            (should (stringp (plist-get (cmacs-journal-daily-tests--run
                                         nil nil t)
                                        :summary)))
            (should (= asked 1))
            (should (null calls))
            ;; Allowed, but nobody to ask (the mode's timer): not sent.
            (should (stringp (cmacs-journal-daily--summary-decision nil)))
            (should (= asked 1)))
          (should (null calls)))
        ;; Allowed, and the person says yes -- to a question that names
        ;; the provider and says it is not local.
        (let ((cmacs-journal-daily-allow-remote t) (question nil))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest args) (setq question (car args)) t)))
            (should (eq (plist-get (cmacs-journal-daily-tests--run nil nil t)
                                   :summary)
                        t)))
          (should (string-match-p "claude/test-model is NOT a local model"
                                  question))
          (should (= (length calls) 1)))
        ;; `always': no question, even with nobody there.
        (let ((cmacs-journal-daily-allow-remote 'always))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) (error "Must not ask"))))
            (should (eq (cmacs-journal-daily--summary-decision nil) t))))))))

(ert-deftest cmacs-journal-daily-test-summary-off-by-default ()
  (should-not (default-value 'cmacs-journal-daily-summary))
  (should-not (default-value 'cmacs-journal-daily-allow-remote))
  (should (eq (default-value 'cmacs-journal-daily-provider) 'ollama))
  (should-not (default-value 'cmacs-journal-daily-mode))
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((calls nil))
      (cmacs-journal-daily-tests--with-ai calls
        (should (null (plist-get (cmacs-journal-daily-tests--run nil nil t)
                                 :summary)))
        (should (null calls))))))

(ert-deftest cmacs-journal-daily-test-summary-is-added-to-the-subtree ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((file (cmacs-journal-daily-tests--note))
          (calls nil)
          (cmacs-journal-daily-summary t))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert cmacs-journal-daily-tests--hand-written))
      (cmacs-journal-daily-tests--with-ai calls
        (let ((result (cmacs-journal-daily-tests--run nil nil t)))
          (should (eq (plist-get result :summary) t)))
        (should (= (length calls) 1))
        (should (= (length cmacs-journal-daily--jobs) 1))
        ;; The facts are on disk before the model has said a word.
        (should (string-match-p "^\\*\\* Time by project$"
                                (cmacs-journal-daily-tests--text file)))
        (should-not (string-match-p "^\\*\\* Summary$"
                                    (cmacs-journal-daily-tests--text file)))
        (pcase-let ((`(,prompt ,callback ,system) (car calls)))
          ;; The local default, and the system prompt of this feature.
          (should (equal (seq-take system 2) '(ollama "test-model")))
          (should (equal (nth 2 system) cmacs-journal-daily-summary-prompt))
          ;; The prompt is the facts and nothing of the user's own text.
          (should (string-match-p "^Range: 2026-03-10$" prompt))
          (should (string-match-p "^Time by project:$" prompt))
          (should (string-match-p "09:00--10:30 (1:28) alpha" prompt))
          (should (string-match-p
                   "GLib Reference <https://docs.gtk.org/glib/index.html>"
                   prompt))
          (should-not (string-match-p "Reflection\\|typed\\|Tasks" prompt))
          (should-not (string-match-p "\\[\\[" prompt))
          ;; The stream, with a model that thinks aloud and tries Markdown.
          (funcall callback '(:start))
          (funcall callback '(:delta "<think>plan the\nanswer</think>"))
          (funcall callback '(:delta "I spent the morning on alpha,\nthen "))
          (funcall callback '(:delta "read the GLib docs.\n\n* Not a heading\n"))
          (funcall callback '(:delta "#+title: nor a keyword\n\nThe **afternoon** went to beta."))
          (funcall callback '(:end :text "" :stop end)))
        (should (null cmacs-journal-daily--jobs))
        (let ((text (cmacs-journal-daily-tests--text file)))
          (should (string-prefix-p cmacs-journal-daily-tests--hand-written
                                   text))
          (should (= (cmacs-journal-daily-tests--count "^\\* Activity$" text)
                     1))
          (should (string-match-p
                   (concat "^\\*\\* Summary\n"
                           "I spent the morning on alpha, then read the GLib docs\\.\n\n"
                           "Not a heading title: nor a keyword\n\n"
                           "The \\*afternoon\\* went to beta\\.\n\n"
                           "Written by ollama/test-model from the facts below\\.\n\n"
                           "\\*\\* Time by project\n")
                   text))
          (should-not (string-match-p "think" text))
          ;; Still one top-level subtree of ours; the model added none.
          (should (equal (with-temp-buffer
                           (insert text)
                           (let ((org-mode-hook nil))
                             (delay-mode-hooks (org-mode)))
                           (org-element-map (org-element-parse-buffer)
                               'headline
                             (lambda (h)
                               (and (= (org-element-property :level h) 1)
                                    (org-element-property :raw-value h)))))
                         '("Reflection" "Tasks" "Activity"))))
        ;; The timer, later, with the same facts: the summary is kept
        ;; and the model is not asked again.
        (setq calls nil)
        (let ((before (cmacs-journal-daily-tests--text file))
              (result (cmacs-journal-daily-tests--run nil nil nil)))
          (should (eq (plist-get result :status) 'unchanged))
          (should (null calls))
          (should (equal before (cmacs-journal-daily-tests--text file))))))))

(ert-deftest cmacs-journal-daily-test-summary-failure-leaves-the-facts ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (let ((file (cmacs-journal-daily-tests--note))
          (calls nil)
          (cmacs-journal-daily-summary t))
      (cmacs-journal-daily-tests--with-ai calls
        (cmacs-journal-daily-tests--run nil nil t)
        (let ((before (cmacs-journal-daily-tests--text file)))
          (funcall (nth 1 (car calls)) '(:delta "half an ans"))
          (funcall (nth 1 (car calls)) '(:error "connection refused"))
          (should (null cmacs-journal-daily--jobs))
          (should (equal before (cmacs-journal-daily-tests--text file)))
          ;; A payload after the end finds no job and does nothing.
          (funcall (nth 1 (car calls)) '(:end :text "late" :stop end))
          (should (equal before (cmacs-journal-daily-tests--text file))))
        ;; Timed out: cancelled, dropped, facts untouched.
        (setq calls nil)
        (cmacs-journal-daily-tests--run nil nil t)
        (let ((before (cmacs-journal-daily-tests--text file))
              (id (car (car cmacs-journal-daily--jobs))))
          (cmacs-journal-daily--summary-timeout id)
          (should (null cmacs-journal-daily--jobs))
          (funcall (nth 1 (car calls)) '(:end :text "too late" :stop end))
          (should (equal before (cmacs-journal-daily-tests--text file))))
        ;; The session could not even be made.
        (cl-letf (((symbol-function 'cmacs-ai-make-session)
                   (lambda (&rest _) (error "No such model"))))
          (let ((result (cmacs-journal-daily-tests--run nil nil t)))
            (should (stringp (plist-get result :summary)))
            (should (null cmacs-journal-daily--jobs))))))))

;;;; The mode, the week, the other doors

(ert-deftest cmacs-journal-daily-test-mode-writes-yesterday-once ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (setq cmacs-journal-daily-tests--clock
          (cmacs-journal-daily-tests--at "07:00" "2026-03-11"))
    ;; A new day, but nothing has happened in it yet.
    (cmacs-journal-daily--tick)
    (should (null cmacs-journal-daily--done))
    (should-not (file-exists-p (cmacs-journal-daily-tests--note)))
    ;; Idle time is not activity either.
    (cmacs-journal-daily-tests--store
     (list (list :time (cmacs-journal-daily-tests--at "06:00" "2026-03-11")
                 :end (cmacs-journal-daily-tests--at "06:30" "2026-03-11")
                 :duration 1800 :kind 'idle))
     "2026-03-11")
    (cmacs-journal-daily--tick)
    (should (null cmacs-journal-daily--done))
    ;; The first activity of the day: yesterday's note is written.
    (let ((cmacs-journal--open
           (list :time (cmacs-journal-daily-tests--at "06:55" "2026-03-11")
                 :kind 'focus :app "term" :title "t")))
      (cmacs-journal-daily--tick))
    (should (equal cmacs-journal-daily--done '("2026-03-10")))
    (let* ((file (cmacs-journal-daily-tests--note))
           (text (cmacs-journal-daily-tests--text file)))
      (should (string-match-p "^#\\+title: 2026-03-10$" text))
      ;; The whole of yesterday, not yesterday up to "now".
      (should (string-match-p "^- 13:00--14:30 (1:30) beta$" text))
      ;; Dealt with: the next look does not write again.
      (delete-file file)
      (cmacs-journal-daily--tick)
      (should-not (file-exists-p file)))
    ;; Today's note at the set time, once.
    (setq cmacs-journal-daily-time "18:00")
    (cmacs-journal-daily-tests--store
     (list (list :time (cmacs-journal-daily-tests--at "09:00" "2026-03-11")
                 :end (cmacs-journal-daily-tests--at "10:00" "2026-03-11")
                 :duration 3600 :kind 'buffer :app "emacs" :buffer "x"
                 :project "today"))
     "2026-03-11")
    (setq cmacs-journal-daily-tests--clock
          (cmacs-journal-daily-tests--at "17:59" "2026-03-11"))
    (cmacs-journal-daily--tick)
    (should-not (file-exists-p (cmacs-journal-daily-tests--note "2026-03-11")))
    (setq cmacs-journal-daily-tests--clock
          (cmacs-journal-daily-tests--at "18:01" "2026-03-11"))
    (cmacs-journal-daily--tick)
    (should (file-exists-p (cmacs-journal-daily-tests--note "2026-03-11")))
    (should (member "2026-03-11@" cmacs-journal-daily--done))))

(ert-deftest cmacs-journal-daily-test-mode-is-a-timer-and-nothing-else ()
  (let ((cmacs-journal-daily--timer nil)
        (cmacs-journal-daily-mode nil)
        (cmacs-journal-daily-check-interval 300))
    (unwind-protect
        (progn
          (cmacs-journal-daily-mode 1)
          (should (timerp cmacs-journal-daily--timer))
          (should (memq cmacs-journal-daily--timer timer-list))
          ;; No hook of the compositor, the journal or Emacs holds it.
          (dolist (hook '(cmacs-gowl-focus-change-functions
                          gowl-focus-change-functions
                          window-selection-change-functions
                          window-buffer-change-functions
                          post-command-hook pre-command-hook))
            (when (boundp hook)
              (should-not
               (cl-some (lambda (f)
                          (and (symbolp f)
                               (string-prefix-p "cmacs-journal-daily"
                                                (symbol-name f))))
                        (let ((value (symbol-value hook)))
                          (if (listp value) value (list value)))))))
          (cmacs-journal-daily-mode -1)
          (should (null cmacs-journal-daily--timer)))
      (when (timerp cmacs-journal-daily--timer)
        (cancel-timer cmacs-journal-daily--timer)))))

(ert-deftest cmacs-journal-daily-test-weekly ()
  (cmacs-journal-daily-tests--with
    ;; Monday 2026-03-09 and Tuesday 2026-03-10: ISO week 11.
    (cmacs-journal-daily-tests--store
     (list (list :time (cmacs-journal-daily-tests--at "09:00" "2026-03-09")
                 :end (cmacs-journal-daily-tests--at "11:00" "2026-03-09")
                 :duration 7200 :kind 'buffer :app "emacs" :buffer "m.el"
                 :file "~/src/alpha/m.el" :project "alpha"))
     "2026-03-09")
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    ;; Sunday of the week before must not leak in.
    (cmacs-journal-daily-tests--store
     (list (list :time (cmacs-journal-daily-tests--at "09:00" "2026-03-08")
                 :end (cmacs-journal-daily-tests--at "10:00" "2026-03-08")
                 :duration 3600 :kind 'buffer :app "emacs" :buffer "s.el"
                 :project "sunday"))
     "2026-03-08")
    (let* ((range (cmacs-journal-daily--week-range
                   cmacs-journal-daily-tests--day)))
      (should (equal (cmacs-journal--day (car range)) "2026-03-09"))
      (should (= (cdr range) cmacs-journal-daily-tests--clock)))
    (let* ((file (cmacs-journal-weekly cmacs-journal-daily-tests--day))
           (text (cmacs-journal-daily-tests--text file)))
      (should (equal (file-name-nondirectory file) "2026-W11.org"))
      (should (string-prefix-p cmacs-journal-daily-tests--root file))
      (should (string-match-p "^#\\+title: 2026-W11$" text))
      (should (string-match-p "^\\* Activity this week$" text))
      (should (string-match-p "^\\*\\* Time by day$" text))
      (should (string-match-p "^| 2026-03-09 +| 2:00 " text))
      (should (string-match-p "^| 2026-03-10 +| 3:20 " text))
      (should-not (string-match-p "sunday\\|2026-03-08" text))
      (should-not (string-match-p "^\\*\\* Timeline$" text))
      (should (string-match-p "^- Mon 09:00--11:00 (2:00) alpha$" text))
      ;; A daily note the same day is a different file with its own
      ;; subtree; both are in the index.
      (cmacs-journal-daily cmacs-journal-daily-tests--day)
      (let ((index (cmacs-journal-daily-tests--text
                    (expand-file-name "00_index.org"
                                      (file-name-directory file)))))
        (should (string-match-p "\\]\\[2026-W11\\]\\]" index))
        (should (string-match-p "\\]\\[2026-03-10\\]\\]" index))))))

(ert-deftest cmacs-journal-daily-test-preview-writes-nothing ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (save-window-excursion
      (unwind-protect
          (progn
            (cmacs-journal-daily-preview cmacs-journal-daily-tests--day)
            (with-current-buffer "*cmacs-journal-daily*"
              (should (string-match-p "^\\*\\* Timeline$" (buffer-string)))
              (should-not (buffer-modified-p))))
        (when (get-buffer "*cmacs-journal-daily*")
          (kill-buffer "*cmacs-journal-daily*"))))
    (should-not (file-exists-p (cmacs-journal-daily--directory)))))

(ert-deftest cmacs-journal-daily-test-report-buffer-key ()
  (cmacs-journal-daily-tests--with
    (cmacs-journal-daily-tests--store (cmacs-journal-daily-tests--day-events))
    (save-window-excursion
      (unwind-protect
          (progn
            (cmacs-journal-report "today" 'project)
            (with-current-buffer "*cmacs-journal*"
              (should (eq (key-binding (kbd "C-c C-d")) 'cmacs-journal-daily))
              ;; The key that was there before is still there.
              (should (eq (key-binding (kbd "C-c C-r"))
                          'cmacs-journal-restore-at-point))))
        (when (get-buffer "*cmacs-journal*")
          (kill-buffer "*cmacs-journal*"))))))

(ert-deftest cmacs-journal-daily-test-voice-command-registered ()
  (skip-unless (require 'cmacs-voice-commands nil t))
  (skip-unless (fboundp 'cmacs-voice-define-command))
  (let ((cmacs-voice-commands nil))
    (cmacs-journal-daily-register-voice)
    (let ((entry (car cmacs-voice-commands)))
      (should (eq (nth 1 entry) 'cmacs-journal-daily-voice))
      (should (eq (plist-get (nth 3 entry) :context) 'desktop))
      (dolist (said '("write up my day" "write up my week"
                      "write up yesterday"))
        (should (string-match-p (concat "\\`" (car entry) "\\'") said)))))
  ;; No agent tool is registered for this: the note is the user's.
  (when (boundp 'cmacs-brigade-tools)
    (should-not (cl-some (lambda (tool)
                           (string-match-p "journal[-_]daily"
                                           (format "%s" (car-safe tool))))
                         (symbol-value 'cmacs-brigade-tools)))))

(provide 'cmacs-journal-daily-tests)

;;; cmacs-journal-daily-tests.el ends here
