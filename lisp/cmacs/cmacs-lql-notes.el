;;; cmacs-lql-notes.el --- Your notes repo as LQL sources  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: outlines, data, tools
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

;; A PARA-organised org notes repository (by default ~/Documents/notes,
;; the first of `cmacs-para-roots') as four LQL sources:
;;
;;   notes            one row per .org file: PARA place, header keywords
;;                    (#+title ... #+version), tags, ids, sizes, counts of
;;                    headings / TODOs / links, backlinks, dates, and
;;                    whether it is open (and unsaved) in a buffer
;;   note_headings    one row per heading: level, TODO state, priority,
;;                    tags, SCHEDULED / DEADLINE / CLOSED, ID, outline path
;;   note_links       one row per [[link]], with id: and file: targets
;;                    resolved to the note they point at
;;   note_properties  one row per property-drawer entry
;;
;;   fetch notes | filter para == "inbox" | sort modified DESC
;;   fetch note_headings | filter todo == "TODO" and para == "projects"
;;
;; LQL's logic is three-valued: `x != null' is NULL, never true, so test
;; for presence with is_not_null(x) / is_null(x).
;;   fetch notes | filter backlinks == 0 and not index | fields path, title
;;
;; Files are parsed with plain regexps (no `org-mode' per file) and cached
;; by modification time and size, so only files that changed since the
;; last query are read again; a file open in a buffer is read from the
;; buffer, unsaved edits included.  The snapshot JSON itself is cached
;; per source and reused while nothing changed.
;;
;; `cmacs-lql-notes' offers named queries (inbox triage, stale projects,
;; open TODOs, header lint, orphans, ...); `cmacs-lql-notes-backlinks'
;; shows what links to the current note.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-para)
(require 'cmacs-lql)

(declare-function cmacs-lql-results--loading "cmacs-lql-results" (query &rest props))

(defgroup cmacs-lql-notes nil
  "Your notes repository as LQL sources."
  :group 'cmacs-lql
  :prefix "cmacs-lql-notes-")

;;;; Customization

(defcustom cmacs-lql-notes-directories nil
  "Directories holding your notes, or nil for `cmacs-para-roots'.

`cmacs-para-roots' defaults to (\"~/Documents/notes\") and is shared
with roamgraph, secondbrain and the brigade memory index, so setting
it moves all of them; set this instead to point only the LQL sources
somewhere else.  PARA classification (the `para', `scope' and `area'
columns) is made against these directories."
  :type '(choice (const :tag "Same as `cmacs-para-roots'" nil)
                 (repeat directory)))

(defcustom cmacs-lql-notes-include-archives t
  "Non-nil means files under 04_archives are part of the sources."
  :type 'boolean)

(defcustom cmacs-lql-notes-exclude-regexp
  "/\\(?:\\.git\\|\\.stversions\\|node_modules\\|\\.trash\\)\\(?:/\\|\\'\\)"
  "Paths (relative to a notes directory, with a leading /) to skip."
  :type 'regexp)

(defcustom cmacs-lql-notes-max-file-size (* 4 1024 1024)
  "Files larger than this many bytes contribute only their header."
  :type 'natnum)

(defcustom cmacs-lql-notes-todo-keywords '("TODO" "NEXT" "STARTED" "WAITING" "HOLD")
  "Open TODO keywords, unless a file says otherwise with #+TODO:."
  :type '(repeat string))

(defcustom cmacs-lql-notes-done-keywords '("DONE" "CANCELLED" "CANCELED")
  "Done keywords, unless a file says otherwise with #+TODO:."
  :type '(repeat string))

(defcustom cmacs-lql-notes-stale-days 30
  "Days without an update after which the stale-projects query lists a note."
  :type 'natnum)

;;;; Locating files

(defun cmacs-lql-notes-roots ()
  "The notes directories, expanded, that exist."
  (cl-remove-if-not
   #'file-directory-p
   (mapcar (lambda (d) (file-name-as-directory (expand-file-name d)))
           (or cmacs-lql-notes-directories cmacs-para-roots))))

(defun cmacs-lql-notes--files ()
  "Every notes file: list of (FILE . ROOT)."
  (let (out)
    (dolist (root (cmacs-lql-notes-roots))
      (dolist (f (directory-files-recursively
                  root "\\.org\\'" nil
                  (lambda (dir)
                    (not (string-match-p cmacs-lql-notes-exclude-regexp
                                         (concat "/" (file-relative-name dir root)))))))
        (let ((rel (file-relative-name f root)))
          (unless (or (string-match-p cmacs-lql-notes-exclude-regexp (concat "/" rel))
                      (string-prefix-p ".#" (file-name-nondirectory f))
                      (and (not cmacs-lql-notes-include-archives)
                           (string-prefix-p "04_archives/" rel)))
            (push (cons f root) out)))))
    (nreverse out)))

;;;; Time parsing

(defun cmacs-lql-notes--time (s)
  "S (ISO 8601 or an org timestamp) as `float-time' seconds, or nil."
  (when (and (stringp s)
             (string-match
              "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[T ]\\(?:[A-Za-z]+ \\)?\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?\\([-+][0-9]\\{2\\}:?[0-9]\\{2\\}\\|Z\\)?\\)?"
              s))
    (let* ((y (string-to-number (match-string 1 s)))
           (mo (string-to-number (match-string 2 s)))
           (d (string-to-number (match-string 3 s)))
           (h (if (match-string 4 s) (string-to-number (match-string 4 s)) 0))
           (mi (if (match-string 5 s) (string-to-number (match-string 5 s)) 0))
           (se (if (match-string 6 s) (string-to-number (match-string 6 s)) 0))
           (zone (match-string 7 s))
           (offset (cond ((null zone) nil)
                         ((equal zone "Z") 0)
                         (t (let ((z (string-replace ":" "" zone)))
                              (* (if (eq (aref z 0) ?-) -1 1)
                                 (+ (* 3600 (string-to-number (substring z 1 3)))
                                    (* 60 (string-to-number (substring z 3 5))))))))))
      (ignore-errors
        (float-time (encode-time (list se mi h d mo y nil -1 offset)))))))

;;;; Parsing one file

(defconst cmacs-lql-notes--heading-re "^\\(\\*+\\)[ \t]+\\(.*?\\)[ \t]*$"
  "A heading line: stars, then the rest.")

(defun cmacs-lql-notes--split-tags (s)
  "Tags of an org tag string \":a:b:\" (or \"a b\") as a list."
  (and s (split-string s "[: \t]+" t)))

(defun cmacs-lql-notes--todo-sets ()
  "(OPEN . DONE) keyword lists for the current buffer (#+TODO: lines win)."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) open done found)
      (while (re-search-forward "^#\\+\\(?:seq_\\|typ_\\)?todo:[ \t]*\\(.*\\)$" nil t)
        (setq found t)
        (let* ((parts (split-string (match-string 1) "|"))
               (strip (lambda (k) (replace-regexp-in-string "(.*)\\'" "" k)))
               (o (mapcar strip (split-string (or (car parts) "") nil t)))
               (dn (mapcar strip (split-string (or (cadr parts) "") nil t))))
          (if (cdr parts)
              (setq open (append open o) done (append done dn))
            ;; No `|': the last keyword is the done state.
            (setq open (append open (butlast o)) done (append done (last o))))))
      (if found
          (cons open done)
        (cons cmacs-lql-notes-todo-keywords cmacs-lql-notes-done-keywords)))))

(defun cmacs-lql-notes--header ()
  "The #+KEY: values before the first heading, as an alist (lowercase keys)."
  (save-excursion
    (goto-char (point-min))
    (let ((limit (save-excursion
                   (if (re-search-forward "^\\*+[ \t]" nil t) (match-beginning 0) (point-max))))
          out)
      (while (re-search-forward "^#\\+\\([A-Za-z_]+\\):[ \t]*\\(.*?\\)[ \t]*$" limit t)
        (let ((k (downcase (match-string 1))))
          (unless (assoc k out)
            (push (cons k (match-string-no-properties 2)) out))))
      out)))

(defun cmacs-lql-notes--drawer-at (pos limit)
  "Properties of the :PROPERTIES: drawer starting at POS (before LIMIT).
An alist of (KEY . VALUE), keys as written."
  (save-excursion
    (goto-char pos)
    (when (looking-at "^[ \t]*:PROPERTIES:[ \t]*$")
      (let ((end (save-excursion (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)))
            out)
        (when end
          (forward-line 1)
          (while (re-search-forward "^[ \t]*:\\([^:\n]+\\):[ \t]*\\(.*?\\)[ \t]*$" end t)
            (unless (equal (match-string 1) "END")
              (push (cons (match-string-no-properties 1) (match-string-no-properties 2)) out))))
        (nreverse out)))))

(defun cmacs-lql-notes--link-type (target)
  "The link type of TARGET (id, file, https, ..., or fuzzy)."
  (cond ((string-match "\\`\\([a-zA-Z][a-zA-Z0-9+.-]*\\):" target)
         (downcase (match-string 1 target)))
        ((string-match-p "\\`[/.~]" target) "file")
        (t "fuzzy")))

(defun cmacs-lql-notes--parse-buffer (file whole)
  "Parse the current buffer, the contents of notes FILE.
WHOLE nil means only the header is read (the file is too large).
Returns a plist (:header :file-id :file-props :headings :links :props
:words :lines)."
  (let* ((header (cmacs-lql-notes--header))
         (todo (cmacs-lql-notes--todo-sets))
         (first-heading (save-excursion
                          (goto-char (point-min))
                          (if (re-search-forward "^\\*+[ \t]" nil t)
                              (line-beginning-position) (point-max))))
         (file-props (save-excursion
                       (goto-char (point-min))
                       (when (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" first-heading t)
                         (cmacs-lql-notes--drawer-at (line-beginning-position) first-heading))))
         headings links props (outline nil))
    (dolist (p file-props) (push (list :line 1 :heading nil :key (car p) :value (cdr p)) props))
    (when whole
      ;; Headings, with their planning line and property drawer.
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward cmacs-lql-notes--heading-re nil t)
          (let* ((level (length (match-string 1)))
                 (rest (match-string-no-properties 2))
                 (line (line-number-at-pos (match-beginning 0)))
                 kw prio tags)
            (when (string-match "\\`\\([A-Z]+\\)[ \t]+" rest)
              (let ((k (match-string 1 rest)))
                (when (or (member k (car todo)) (member k (cdr todo)))
                  (setq kw k rest (substring rest (match-end 0))))))
            (when (string-match "\\`\\[#\\([A-Z0-9]\\)\\][ \t]*" rest)
              (setq prio (match-string 1 rest) rest (substring rest (match-end 0))))
            (when (string-match "[ \t]+\\(:[[:alnum:]_@#%:]+:\\)\\'" rest)
              ;; Take the cut point first: splitting the tags runs
              ;; another regexp and clobbers the match data.
              (let ((cut (match-beginning 0)) (raw (match-string 1 rest)))
                (setq tags (cmacs-lql-notes--split-tags raw)
                      rest (substring rest 0 cut))))
            (setq outline (append (seq-take outline (1- level)) (list rest)))
            (let* ((bol (line-beginning-position 2))
                   (next (save-excursion
                           (goto-char bol)
                           (if (re-search-forward "^\\*+[ \t]" nil t)
                               (line-beginning-position) (point-max))))
                   (planning (save-excursion
                               (goto-char bol)
                               (and (looking-at "^[ \t]*\\(?:\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):.*\\)$")
                                    (prog1 (match-string-no-properties 0) (forward-line 1)))))
                   (drawer-pos (save-excursion
                                 (goto-char bol)
                                 (when planning (forward-line 1))
                                 (point)))
                   (drawer (cmacs-lql-notes--drawer-at drawer-pos next))
                   (plan (lambda (key)
                           (and planning
                                (string-match (concat key ":[ \t]*\\([<[][^]>]+[]>]\\)") planning)
                                (match-string 1 planning)))))
              (dolist (p drawer)
                (push (list :line line :heading rest :key (car p) :value (cdr p)) props))
              (push (list :line line :level level :heading rest :todo kw
                          :done (and kw (member kw (cdr todo)) t)
                          :priority prio :tags tags
                          :scheduled (funcall plan "SCHEDULED")
                          :deadline (funcall plan "DEADLINE")
                          :closed (funcall plan "CLOSED")
                          :id (cdr (assoc "ID" drawer))
                          :olpath (string-join outline " / "))
                    headings)))))
      ;; Links.
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "\\[\\[\\([^]\n]+\\)\\]\\(?:\\[\\([^]\n]*\\)\\]\\)?\\]" nil t)
          (let ((target (match-string-no-properties 1)))
            (push (list :line (line-number-at-pos (match-beginning 0))
                        :type (cmacs-lql-notes--link-type target)
                        :target target
                        :description (match-string-no-properties 2))
                  links)))))
    (list :header header
          :file-id (cdr (assoc "ID" file-props))
          :headings (nreverse headings)
          :links (nreverse links)
          :props (nreverse props)
          :words (if whole (count-words (point-min) (point-max)) nil)
          :lines (count-lines (point-min) (point-max))
          :file file)))

;;;; The cache

(defvar cmacs-lql-notes--cache (make-hash-table :test #'equal)
  "FILE -> (STAMP . PARSED), STAMP being (MTIME SIZE) or a buffer tick.")

(defvar cmacs-lql-notes--generation 0
  "Bumped whenever the cache changes; snapshot JSON is reused while it holds.")

(defun cmacs-lql-notes-clear-cache ()
  "Forget every parsed note; the next query reads all of them again."
  (interactive)
  (clrhash cmacs-lql-notes--cache)
  (clrhash cmacs-lql--snapshot-cache)
  (cl-incf cmacs-lql-notes--generation))

(defun cmacs-lql-notes--parse-file (file)
  "Parsed plist for FILE, from the cache when it has not changed."
  (let* ((buf (get-file-buffer file))
         (attrs (and (not buf) (file-attributes file)))
         (stamp (if buf
                    (list 'buffer (buffer-chars-modified-tick buf))
                  (list (file-attribute-modification-time attrs)
                        (file-attribute-size attrs))))
         (hit (gethash file cmacs-lql-notes--cache)))
    (if (and hit (equal (car hit) stamp))
        (cdr hit)
      (let ((parsed
             (if buf
                 (with-current-buffer buf
                   (save-restriction
                     (widen)
                     (let ((case-fold-search nil))
                       (cmacs-lql-notes--parse-buffer file t))))
               (with-temp-buffer
                 (let ((whole (<= (file-attribute-size attrs) cmacs-lql-notes-max-file-size))
                       (case-fold-search nil))
                   (insert-file-contents file nil 0 (unless whole 65536))
                   (cmacs-lql-notes--parse-buffer file whole))))))
        (puthash file (cons stamp parsed) cmacs-lql-notes--cache)
        (cl-incf cmacs-lql-notes--generation)
        parsed))))

(defun cmacs-lql-notes--refresh ()
  "Parse every changed note and drop deleted ones.
Return a list of ((FILE . ROOT) . PARSED)."
  (let ((files (cmacs-lql-notes--files))
        (live (make-hash-table :test #'equal))
        out)
    (dolist (fr files)
      (puthash (car fr) t live)
      (push (cons fr (condition-case err
                         (cmacs-lql-notes--parse-file (car fr))
                       (error (message "cmacs-lql-notes: %s: %s" (car fr)
                                       (error-message-string err))
                              nil)))
            out))
    (maphash (lambda (k _) (unless (gethash k live)
                             (remhash k cmacs-lql-notes--cache)
                             (cl-incf cmacs-lql-notes--generation)))
             cmacs-lql-notes--cache)
    (cl-remove-if-not #'cdr (nreverse out))))

;;;; Classification

(defun cmacs-lql-notes--exists-p (file)
  "Non-nil when FILE exists locally.
A remote (Tramp) target is never checked: a query must not open SSH
connections, so it reports nil."
  (and file (not (file-remote-p file)) (file-exists-p file) t))

(defun cmacs-lql-notes--place (file root)
  "PARA plist for FILE under ROOT: :para :scope :area :rel :index :daily."
  (let* ((cmacs-para-roots (list root))
         (c (cmacs-para-classify file))
         (rel (plist-get c :rel))
         (parts (split-string (or rel "") "/" t))
         ;; The first directory below the category (and below
         ;; personal/work), e.g. 02_areas/personal/finance -> finance.
         (below (let ((p (cdr parts)))
                  (when (and (equal (car parts) "04_archives")
                             (assoc (car p) cmacs-para-category-symbols))
                    (setq p (cdr p)))
                  (when (member (car p) '("personal" "work")) (setq p (cdr p)))
                  p)))
    (list :para (let ((cat (plist-get c :category))) (if cat (symbol-name cat) "root"))
          :scope (let ((s (plist-get c :scope))) (and s (symbol-name s)))
          :area (and (cdr below) (car below))
          :rel rel
          :dir (let ((d (file-name-directory (or rel "")))) (and d (directory-file-name d)))
          :index (eq (plist-get c :special) 'index)
          :daily (eq (plist-get c :special) 'dailies))))

;;;; Rows

(defun cmacs-lql-notes--id-index (entries)
  "ID -> file, over every file and heading ID in ENTRIES."
  (let ((ids (make-hash-table :test #'equal)))
    (dolist (e entries)
      (let ((p (cdr e)) (file (caar e)))
        (when (plist-get p :file-id) (puthash (plist-get p :file-id) file ids))
        (dolist (h (plist-get p :headings))
          (when (plist-get h :id) (puthash (plist-get h :id) file ids)))))
    ids))

(defun cmacs-lql-notes--resolve (link file ids)
  "The file LINK (a link plist in FILE) points at, or nil."
  (let ((target (plist-get link :target)))
    (pcase (plist-get link :type)
      ("id" (gethash (substring target 3) ids))
      ("file" (let* ((path (replace-regexp-in-string "\\`file:" "" target))
                     (path (replace-regexp-in-string "::.*\\'" "" path)))
                (expand-file-name path (file-name-directory file))))
      (_ nil))))

(defun cmacs-lql-notes--entries ()
  "Refreshed entries plus the id index and backlink counts: (ENTRIES IDS BACK)."
  (let* ((entries (cmacs-lql-notes--refresh))
         (ids (cmacs-lql-notes--id-index entries))
         (back (make-hash-table :test #'equal)))
    (dolist (e entries)
      (let ((file (caar e)) (seen (make-hash-table :test #'equal)))
        (dolist (l (plist-get (cdr e) :links))
          (let ((to (cmacs-lql-notes--resolve l file ids)))
            (when (and to (not (equal to file)) (not (gethash to seen)))
              (puthash to t seen)
              (puthash to (1+ (gethash to back 0)) back))))))
    (list entries ids back)))

(defun cmacs-lql-notes--date-from-name (file)
  "A date at the start of FILE's name (YYYY-MM-DD), as `float-time', or nil."
  (let ((name (file-name-nondirectory file)))
    (and (string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" name)
         (cmacs-lql-notes--time (match-string 1 name)))))

(defun cmacs-lql-notes--note-rows ()
  "Rows of the `notes' source."
  (pcase-let ((`(,entries ,_ids ,back) (cmacs-lql-notes--entries)))
    (mapcar
     (lambda (e)
       (let* ((file (caar e)) (root (cdar e)) (p (cdr e))
              (h (plist-get p :header))
              (place (cmacs-lql-notes--place file root))
              (heads (plist-get p :headings))
              (buf (get-file-buffer file))
              (mtime (float-time (file-attribute-modification-time
                                  (or (file-attributes file) (list nil nil nil nil nil 0)))))
              (updated (or (cmacs-lql-notes--time (cdr (assoc "updated" h))) mtime)))
         (list :file file :path (plist-get place :rel) :root root
               :name (file-name-base file)
               :dir (plist-get place :dir)
               :para (plist-get place :para) :scope (plist-get place :scope)
               :area (plist-get place :area)
               :title (cdr (assoc "title" h))
               :description (cdr (assoc "description" h))
               :authors (and (assoc "authors" h)
                             (split-string (cdr (assoc "authors" h)) "[,;]+[ \t]*" t))
               :categories (and (assoc "categories" h)
                                (split-string (cdr (assoc "categories" h)) "[ ,]+" t))
               :tags (cmacs-lql-notes--split-tags (cdr (assoc "filetags" h)))
               :created (cmacs-lql-notes--time (cdr (assoc "created" h)))
               :updated updated
               :modified mtime
               :age_days (/ (fround (* 10 (/ (- (float-time) updated) 86400.0))) 10)
               :version (cdr (assoc "version" h))
               :id (plist-get p :file-id)
               :date (cmacs-lql-notes--date-from-name file)
               :size (or (file-attribute-size (file-attributes file)) 0)
               :lines (plist-get p :lines) :words (plist-get p :words)
               :headings (length heads)
               :todos (cl-count-if (lambda (x) (and (plist-get x :todo) (not (plist-get x :done)))) heads)
               :done (cl-count-if (lambda (x) (plist-get x :done)) heads)
               :links (length (plist-get p :links))
               :backlinks (gethash file back 0)
               :index (plist-get place :index) :daily (plist-get place :daily)
               :has_header (and (assoc "title" h) (assoc "created" h) (assoc "updated" h) t)
               :open (and buf t)
               :unsaved (and buf (buffer-modified-p buf) t))))
     entries)))

(defun cmacs-lql-notes--heading-rows ()
  "Rows of the `note_headings' source."
  (pcase-let ((`(,entries ,_ ,_) (cmacs-lql-notes--entries)))
    (let (rows)
      (dolist (e entries)
        (let* ((file (caar e)) (place (cmacs-lql-notes--place file (cdar e))))
          (dolist (h (plist-get (cdr e) :headings))
            (push (list :file file :path (plist-get place :rel)
                        :para (plist-get place :para) :scope (plist-get place :scope)
                        :area (plist-get place :area)
                        :line (plist-get h :line) :level (plist-get h :level)
                        :heading (plist-get h :heading) :todo (plist-get h :todo)
                        :done (plist-get h :done) :priority (plist-get h :priority)
                        :tags (plist-get h :tags)
                        :scheduled (cmacs-lql-notes--time (plist-get h :scheduled))
                        :deadline (cmacs-lql-notes--time (plist-get h :deadline))
                        :closed (cmacs-lql-notes--time (plist-get h :closed))
                        :id (plist-get h :id) :olpath (plist-get h :olpath))
                  rows))))
      (nreverse rows))))

(defun cmacs-lql-notes--link-rows ()
  "Rows of the `note_links' source."
  (pcase-let ((`(,entries ,ids ,_) (cmacs-lql-notes--entries)))
    (let (rows)
      (dolist (e entries)
        (let* ((file (caar e)) (place (cmacs-lql-notes--place file (cdar e))))
          (dolist (l (plist-get (cdr e) :links))
            (let ((to (cmacs-lql-notes--resolve l file ids)))
              (push (list :file file :path (plist-get place :rel)
                          :para (plist-get place :para)
                          :line (plist-get l :line) :type (plist-get l :type)
                          :target (plist-get l :target)
                          :description (plist-get l :description)
                          :resolved to
                          :exists (if (member (plist-get l :type) '("id" "file"))
                                      (cmacs-lql-notes--exists-p to)
                                    nil))
                    rows)))))
      (nreverse rows))))

(defun cmacs-lql-notes--property-rows ()
  "Rows of the `note_properties' source."
  (pcase-let ((`(,entries ,_ ,_) (cmacs-lql-notes--entries)))
    (let (rows)
      (dolist (e entries)
        (let* ((file (caar e)) (place (cmacs-lql-notes--place file (cdar e))))
          (dolist (p (plist-get (cdr e) :props))
            (push (list :file file :path (plist-get place :rel)
                        :para (plist-get place :para)
                        :line (plist-get p :line) :heading (plist-get p :heading)
                        :key (plist-get p :key) :value (plist-get p :value))
                  rows))))
      (nreverse rows))))

;;;; Snapshot reuse

(defun cmacs-lql-notes--generation-now ()
  "Refresh the parse cache and return a key that changes with the rows.
The hour is part of it because `age_days' moves with the clock."
  (cmacs-lql-notes--refresh)
  (list cmacs-lql-notes--generation (floor (float-time) 3600)))

;;;; Definitions

(defun cmacs-lql-notes-define-sources ()
  "Define the notes sources."
  (cmacs-lql-define-source
   "notes"
   '(("file" string) ("path" string) ("root" string) ("name" string) ("dir" string)
     ("para" string) ("scope" string) ("area" string)
     ("title" string) ("description" string) ("authors" array)
     ("categories" array) ("tags" array)
     ("created" timestamp) ("updated" timestamp) ("modified" timestamp)
     ("age_days" double) ("version" string) ("id" string) ("date" timestamp)
     ("size" int) ("lines" int) ("words" int) ("headings" int) ("todos" int)
     ("done" int) ("links" int) ("backlinks" int)
     ("index" boolean) ("daily" boolean) ("has_header" boolean)
     ("open" boolean) ("unsaved" boolean))
   #'cmacs-lql-notes--note-rows
   "Every .org file of your notes: PARA place, header keywords, counts, backlinks.")
  (cmacs-lql-define-source
   "note_headings"
   '(("file" string) ("path" string) ("para" string) ("scope" string) ("area" string)
     ("line" int) ("level" int) ("heading" string) ("todo" string) ("done" boolean)
     ("priority" string) ("tags" array) ("scheduled" timestamp)
     ("deadline" timestamp) ("closed" timestamp) ("id" string) ("olpath" string))
   #'cmacs-lql-notes--heading-rows
   "Every heading of your notes, with TODO state, planning and ID.")
  (cmacs-lql-define-source
   "note_links"
   '(("file" string) ("path" string) ("para" string) ("line" int) ("type" string)
     ("target" string) ("description" string) ("resolved" string) ("exists" boolean))
   #'cmacs-lql-notes--link-rows
   "Every link in your notes; id: and file: targets resolved to a file.")
  (cmacs-lql-define-source
   "note_properties"
   '(("file" string) ("path" string) ("para" string) ("line" int)
     ("heading" string) ("key" string) ("value" string))
   #'cmacs-lql-notes--property-rows
   "Every property-drawer entry in your notes (file-level and per heading).")
  (dolist (name '("notes" "note_headings" "note_links" "note_properties"))
    (cmacs-lql-set-source-generation name #'cmacs-lql-notes--generation-now)))

;;;; Commands

(defcustom cmacs-lql-notes-queries
  `(("Inbox triage"
     . "fetch notes | filter para == \"inbox\" | sort modified DESC | fields path, title, modified, words")
    ("Recently updated (7 days)"
     . "fetch notes | filter updated > now() - 7d | sort updated DESC | fields path, para, title, updated")
    ("Stale projects"
     . ,(format "fetch notes | filter para == \"projects\" and not index and age_days > %d | sort age_days DESC | fields path, title, updated, age_days, todos"
                cmacs-lql-notes-stale-days))
    ("Open TODOs"
     . "fetch note_headings | filter is_not_null(todo) and not done | sort priority, deadline | fields path, line, todo, priority, heading, deadline, scheduled")
    ("Due within a week"
     . "fetch note_headings | filter not done and is_not_null(deadline) and deadline < now() + 7d | sort deadline | fields path, line, heading, deadline")
    ("Missing header keywords"
     . "fetch notes | filter not has_header | fields path, title, para")
    ("Orphans (nothing links here)"
     . "fetch notes | filter backlinks == 0 and not index and not daily | sort modified DESC | fields path, title, para")
    ("Broken links"
     . "fetch note_links | filter (type == \"id\" or type == \"file\") and not exists | fields path, line, target")
    ("Notes per area"
     . "fetch notes | summarize notes = count(), words = sum(words), by: {para, area} | sort notes DESC")
    ("Tags"
     . "fetch notes | expand tags, as: tag | filter is_not_null(tag) | summarize n = count(), by: {tag} | sort n DESC")
    ("Unsaved notes"
     . "fetch notes | filter unsaved | fields path, title"))
  "Named notes queries `cmacs-lql-notes' offers.  An alist of (NAME . QUERY)."
  :type '(alist :key-type string :value-type string))

;;;###autoload
(defun cmacs-lql-notes (query)
  "Run a notes QUERY (pick a named one, or type your own) in a grid."
  (interactive
   (let* ((name (completing-read "Notes query (or type LQL): "
                                 (mapcar #'car cmacs-lql-notes-queries) nil nil)))
     (list (or (cdr (assoc name cmacs-lql-notes-queries)) name))))
  (cmacs-lql--ensure)
  (require 'cmacs-lql-results)
  (cmacs-lql-results--loading query :target 'local))

;;;###autoload
(defun cmacs-lql-notes-backlinks (&optional file)
  "Show every link in your notes that points at FILE (the current note)."
  (interactive)
  (let ((file (expand-file-name (or file buffer-file-name
                                    (user-error "This buffer visits no file")))))
    (cmacs-lql-notes (format "fetch note_links | filter resolved == %s | fields path, line, type, description"
                             (prin1-to-string file)))))

;;;###autoload
(defun cmacs-lql-notes-outgoing (&optional file)
  "Show every link the current note (FILE) makes."
  (interactive)
  (let ((file (expand-file-name (or file buffer-file-name
                                    (user-error "This buffer visits no file")))))
    (cmacs-lql-notes (format "fetch note_links | filter file == %s | fields line, type, target, description, exists"
                             (prin1-to-string file)))))

;;;; Warming the cache in idle time

(defcustom cmacs-lql-notes-warm-in-idle t
  "Non-nil means parse notes a few at a time while Emacs is idle.
The first query over a cold cache reads every file (seconds, for a few
thousand notes); warming spreads that over idle moments, never more
than `cmacs-lql-notes-warm-batch' files at once, and stops at the first
input."
  :type 'boolean)

(defcustom cmacs-lql-notes-warm-batch 25
  "Files parsed per idle step while warming."
  :type 'natnum)

(defvar cmacs-lql-notes--warm-queue nil "Files still to warm.")
(defvar cmacs-lql-notes--warm-timer nil "The idle warming timer.")

(defun cmacs-lql-notes--warm-step ()
  "Parse the next batch of cold notes, unless input arrives."
  (setq cmacs-lql-notes--warm-timer nil)
  (when (and cmacs-lql-notes-warm-in-idle (null cmacs-lql-notes--warm-queue))
    (setq cmacs-lql-notes--warm-queue
          (cl-remove-if (lambda (f) (gethash f cmacs-lql-notes--cache))
                        (mapcar #'car (cmacs-lql-notes--files)))))
  (let ((n 0))
    (while (and cmacs-lql-notes--warm-queue (< n cmacs-lql-notes-warm-batch)
                (not (input-pending-p)))
      (let ((f (pop cmacs-lql-notes--warm-queue)))
        (ignore-errors (cmacs-lql-notes--parse-file f)))
      (setq n (1+ n))))
  (when cmacs-lql-notes--warm-queue
    (setq cmacs-lql-notes--warm-timer
          (run-with-idle-timer (time-add (current-idle-time) 0.2) nil
                               #'cmacs-lql-notes--warm-step))))

(defun cmacs-lql-notes-warm ()
  "Start warming the notes cache in idle time."
  (interactive)
  (unless (timerp cmacs-lql-notes--warm-timer)
    (setq cmacs-lql-notes--warm-timer
          (run-with-idle-timer 5 nil #'cmacs-lql-notes--warm-step))))

(when (cmacs-lql-available-p)
  (cmacs-lql-notes-define-sources)
  (when (and cmacs-lql-notes-warm-in-idle (not noninteractive))
    (cmacs-lql-notes-warm)))

(provide 'cmacs-lql-notes)

;;; cmacs-lql-notes.el ends here
