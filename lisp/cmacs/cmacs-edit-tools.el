;;; cmacs-edit-tools.el --- The edit tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Six of the seven tools of cmacs/mcp/cmacs-mcp-tools-edit.c, written
;; once (doc_org/cmacs/cmacs-capability.org has the recipe).  The
;; seventh, `project_grep', is with the other workspace tools in
;; cmacs-project-tools.el.
;;
;; `edit_buffer', `replace_in_buffer', `search_buffer' and `goto_line'
;; were Lisp forms the C handler built with printf; they are the same
;; forms here, taking values instead of spliced text.  Their results were
;; printed with `prin1' and still are.
;;
;; `get_org_content' and `insert_org' were Lisp templates held as C
;; strings in cmacs/glib/cmacs-eval-dispatch.c (`org_content_template',
;; `org_insert_template'), shared with org.cmacs.Editor1.Edit.  There was
;; no Lisp function to call, so the two templates are transcribed here as
;; `cmacs-edit-tools-org-content' and `cmacs-edit-tools-org-insert'.
;; Until the D-Bus interface calls these too there are two copies, and
;; test/cmacs/cmacs-core-tools-tests.el holds them to the same JSON keys.
;; Their results were returned verbatim (`cmacs_dispatch_eval_string')
;; and still are: `get_org_content' answers the same JSON document.
;;
;; Redaction (cmacs-redact.el): every tool here answers a buffer the
;; rules exclude exactly as it answers one that does not exist.  The
;; tools that change text are :destructive and :confirm 'ask, like every
;; other writing tool on the table; a read-only buffer still refuses the
;; edit by itself, because nothing here binds `inhibit-read-only'.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-buffer "cmacs-core-tools" (name))
(declare-function cmacs-core-tools-buffer-hidden-p "cmacs-core-tools"
                  (buffer-or-name))

(declare-function json-encode "json" (object))
(declare-function org-map-entries "org"
                  (func &optional match scope &rest skip))
(declare-function org-heading-components "org" ())
(declare-function org-get-tags "org" (&optional pos-or-element local))
(declare-function org-entry-get "org"
                  (pom property &optional inherit literal-nil))
(declare-function org-entry-properties "org" (&optional epom which))
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-collect-keywords "org"
                  (keywords &optional unique directory))
(declare-function org-find-exact-headline-in-buffer "org"
                  (heading &optional buffer pos-only))
(declare-function org-find-olp "org" (path &optional this-buffer))
(declare-function org-end-of-subtree "org"
                  (&optional invisible-ok to-heading element))
(declare-function org-current-level "org" ())
(declare-function outline-next-heading "outline" ())

(defvar org-heading-regexp)

(defconst cmacs-edit-tools-search-limit 200
  "The most matches `search_buffer' returns, as in the C handler.")


;;;; Org

(defun cmacs-edit-tools--org-entry (max-depth include-body include-props)
  "Return (LEVEL . ALIST) for the org entry at point, or nil.
Nil when MAX-DEPTH is positive and the entry is deeper.  INCLUDE-BODY
and INCLUDE-PROPS decide whether the body text and the property drawer
are part of ALIST."
  (let* ((comps (org-heading-components))
         (level (nth 0 comps))
         (todo (nth 2 comps))
         (prio (nth 3 comps))
         (title (or (nth 4 comps) ""))
         (tags (mapcar #'substring-no-properties (org-get-tags nil t)))
         (sched (org-entry-get nil "SCHEDULED"))
         (deadl (org-entry-get nil "DEADLINE"))
         (closed (org-entry-get nil "CLOSED"))
         (props (and include-props
                     (let (out)
                       (dolist (kv (org-entry-properties nil 'standard)
                                   (nreverse out))
                         ;; Special properties org synthesises for every
                         ;; entry; reporting them would bury the drawer.
                         (unless (or (equal (car kv) "ITEM")
                                     (equal (car kv) "FILE")
                                     (equal (car kv) "BLOCKED")
                                     (and (equal (car kv) "CATEGORY")
                                          (equal (cdr kv) "???")))
                           (push kv out))))))
         (body (and include-body
                    (save-excursion
                      (let ((limit (save-excursion
                                     (outline-next-heading)
                                     (point))))
                        (org-end-of-meta-data t)
                        (if (>= (point) limit)
                            ""
                          (string-trim
                           (buffer-substring-no-properties
                            (point) limit))))))))
    (when (or (= max-depth 0) (<= level max-depth))
      (cons level
            (nconc
             (list (cons 'title (substring-no-properties title))
                   (cons 'level level))
             (and todo (list (cons 'todo (substring-no-properties todo))))
             (and prio (list (cons 'priority (char-to-string prio))))
             (and tags (list (cons 'tags (vconcat tags))))
             (and sched (list (cons 'scheduled sched)))
             (and deadl (list (cons 'deadline deadl)))
             (and closed (list (cons 'closed closed)))
             (and props (list (cons 'properties props)))
             (and body (> (length body) 0)
                  (list (cons 'body body))))))))

(defun cmacs-edit-tools--org-tree (entries)
  "Nest ENTRIES, a document-order list of (LEVEL . ALIST), by level.
Returns the list of top-level nodes; each node with children carries
them as a vector under `children'."
  (let ((remaining entries)
        (build nil))
    (setq build
          (lambda (parent-level)
            (let (nodes)
              (while (and remaining
                          (> (car (car remaining)) parent-level))
                (let* ((e (pop remaining))
                       (node (cdr e))
                       (kids (funcall build (car e))))
                  (when kids
                    (setq node (nconc node
                                      (list (cons 'children
                                                  (vconcat kids))))))
                  (push node nodes)))
              (nreverse nodes))))
    (funcall build 0)))

(defun cmacs-edit-tools-org-content (buffer match max-depth include-body
                                            include-props)
  "Return the org BUFFER as the JSON document `get_org_content' answers.

MATCH is an org agenda match string or nil for every entry; MAX-DEPTH
limits headline depth, 0 meaning no limit; INCLUDE-BODY and
INCLUDE-PROPS add each entry's body text and property drawer.

Entirely org porcelain (`org-map-entries', `org-entry-get',
`org-collect-keywords'), so it follows org's own notion of headlines,
planning and the match syntax instead of reimplementing a parser."
  (with-current-buffer buffer
    (require 'org)
    (require 'json)
    (unless (derived-mode-p 'org-mode)
      (error "%s is not an org-mode buffer" (buffer-name)))
    (save-excursion
      (save-restriction
        (widen)
        (let ((entries nil))
          (org-map-entries
           (lambda ()
             (let ((entry (cmacs-edit-tools--org-entry
                           max-depth include-body include-props)))
               (when entry (push entry entries))))
           match)
          (let ((tree (cmacs-edit-tools--org-tree (nreverse entries)))
                (kw (org-collect-keywords
                     '("TITLE" "AUTHOR" "DATE" "FILETAGS"))))
            (json-encode
             (nconc
              (list (cons 'buffer (buffer-name)))
              (and (buffer-file-name)
                   (list (cons 'file (buffer-file-name))))
              (let ((v (cadr (assoc "TITLE" kw))))
                (and v (list (cons 'title v))))
              (let ((v (cadr (assoc "AUTHOR" kw))))
                (and v (list (cons 'author v))))
              (let ((v (cadr (assoc "DATE" kw))))
                (and v (list (cons 'date v))))
              (let ((v (cadr (assoc "FILETAGS" kw))))
                (and v (list (cons 'filetags v))))
              (list (cons 'headlines (vconcat tree)))))))))))

(defun cmacs-edit-tools--org-goto-heading (heading where do-create)
  "Move point to where text goes under HEADING; return the heading's level.

HEADING is an exact title or a slash-separated outline path.  WHERE is
\"top\", \"subtree-end\" or anything else for the end of the entry's own
body, before its child headings.  With DO-CREATE, missing path
components are created, bottom-up from the deepest one that exists."
  (let* ((comps (split-string heading "/" t))
         (m (or (and (= (length comps) 1)
                     (org-find-exact-headline-in-buffer
                      (car comps) (current-buffer)))
                (ignore-errors
                  (org-find-olp comps (current-buffer))))))
    (when (and (not m) (not do-create))
      (error "heading not found: %s" heading))
    (unless m
      (let ((k (1- (length comps))) (pm nil))
        (while (and (> k 0)
                    (not (setq pm (ignore-errors
                                    (org-find-olp (seq-take comps k)
                                                  (current-buffer))))))
          (setq k (1- k)))
        (if pm
            (progn (goto-char pm) (org-end-of-subtree t t))
          (goto-char (point-max)))
        (unless (bolp) (insert "\n"))
        (let ((lvl (1+ k)))
          (dolist (c (seq-drop comps k))
            (insert (make-string lvl ?*) " " c "\n")
            (setq lvl (1+ lvl))))
        (setq m (org-find-olp comps (current-buffer)))))
    (goto-char m)
    (prog1 (org-current-level)
      (cond
       ((string= where "top") (org-end-of-meta-data t))
       ((string= where "subtree-end") (org-end-of-subtree t t))
       (t
        (let ((end (save-excursion (org-end-of-subtree t t) (point))))
          (org-end-of-meta-data t)
          (if (re-search-forward org-heading-regexp end t)
              (goto-char (match-beginning 0))
            (goto-char end))))))))

(defun cmacs-edit-tools-org-insert (buffer text heading where wrap lang
                                           drawer child todo tags
                                           do-create stamp)
  "Insert TEXT into the org BUFFER and return a one-line status.

HEADING, WHERE, WRAP, LANG, DRAWER, CHILD, TODO and TAGS are strings,
empty meaning \"not given\"; DO-CREATE and STAMP are booleans.  See the
`insert_org' tool for what each does.  The child headline's star count
comes from the live target level, which is why this runs in the editor
rather than in the client."
  (with-current-buffer buffer
    (require 'org)
    (unless (derived-mode-p 'org-mode)
      (error "%s is not an org-mode buffer" (buffer-name)))
    (save-excursion
      (let ((body (string-trim-right text "\n+"))
            (target-level 0))
        (if (string= heading "")
            (cond ((string= where "top") (goto-char (point-min)))
                  ((string= where "point") nil)
                  (t (goto-char (point-max))))
          (setq target-level
                (cmacs-edit-tools--org-goto-heading heading where
                                                    do-create)))
        (when stamp
          (setq body (concat (format-time-string "[%Y-%m-%d %a %H:%M]")
                             "\n" body)))
        (cond
         ((string= wrap "") nil)
         ((string= wrap "src")
          (setq body (concat "#+begin_src"
                             (if (string= lang "") "" (concat " " lang))
                             "\n" body "\n#+end_src")))
         (t
          (setq body (concat "#+begin_" wrap "\n" body
                             "\n#+end_" wrap))))
        (unless (string= drawer "")
          (setq body (concat ":" (upcase drawer) ":\n" body "\n:END:")))
        (unless (string= child "")
          (setq body (concat (make-string (1+ target-level) ?*) " "
                             (if (string= todo "") "" (concat todo " "))
                             child
                             (if (string= tags "") ""
                               (concat " :" tags ":"))
                             "\n" body)))
        (unless (bolp) (insert "\n"))
        (insert body)
        (unless (bolp) (insert "\n"))
        (format "inserted %d chars%s" (length body)
                (if (string= heading "") ""
                  (format " under %s" heading)))))))

(cmacs-brigade-deftool get-org-content
  "Parse an org-mode buffer into a structured JSON document: \
buffer keywords (#+TITLE etc.) plus a nested headline tree with \
title, level, todo, priority, tags, scheduled/deadline/closed, \
property drawers, and body text. match filters entries with \
org's agenda match syntax (e.g. \"work+urgent/TODO\")."
    ((buffer string "Buffer name")
     (match string "org agenda match string (tags/todo/property \
query); empty for all entries" :optional t)
     (max-depth integer "Limit headline depth (0 = unlimited)"
                :optional t)
     (include-body boolean "Include entry body text (default true)"
                   :optional t :default t)
     (include-properties boolean
                         "Include property drawers (default true)"
                         :optional t :default t))
  :group 'edit :returns 'json
  (require 'cmacs-core-tools)
  (cmacs-edit-tools-org-content
   (cmacs-core-tools-buffer buffer)
   (and (stringp match) (not (string-empty-p match)) match)
   (if (and (integerp max-depth) (> max-depth 0)) max-depth 0)
   include-body include-properties))

(cmacs-brigade-deftool insert-org
  "Insert text into an org buffer, org-aware: target a headline by \
exact title or slash outline path (creating missing components \
with create), position at the entry's body top/bottom or \
subtree-end, wrap in an org block (src with lang, quote, \
example, verse, center, or a custom name) or a drawer, or file \
it as a new child headline with optional todo keyword and tags. \
timestamp prepends an inactive org timestamp."
    ((buffer string "Buffer name")
     (text string "Text to insert")
     (heading string "Target headline: exact title, or \
slash-separated outline path like Projects/cmacs/Log" :optional t)
     (position string "Where in the entry (default bottom: end of \
the entry's own body, before child headings)"
               :optional t :enum ("top" "bottom" "subtree-end" "point"))
     (wrap string "Org block: src, quote, example, verse, \
center, or any custom #+begin_ name" :optional t)
     (lang string "Language for wrap=src" :optional t)
     (drawer string "Wrap in a :NAME: drawer (e.g. LOGBOOK)" :optional t)
     (child string "Create a child headline with this title; \
the text becomes its body" :optional t)
     (todo string "TODO keyword for the child headline" :optional t)
     (tags string "Colon-separated tags for the child" :optional t)
     (create boolean "Create missing heading path components"
             :optional t)
     (timestamp boolean "Prepend an inactive org timestamp" :optional t))
  :group 'edit :destructive t :confirm 'ask
  (require 'cmacs-core-tools)
  (unless (and (stringp buffer) (stringp text))
    (error "Missing required arguments: buffer, text"))
  (cmacs-edit-tools-org-insert
   (cmacs-core-tools-buffer buffer) text
   (or heading "") (or position "") (or wrap "") (or lang "")
   (or drawer "") (or child "") (or todo "") (or tags "")
   create timestamp))


;;;; Plain text

(cmacs-brigade-deftool edit-buffer
  "Replace an exact substring in a buffer. old_string must occur \
exactly once unless replace_all is true. Errors if not found."
    ((buffer string "Buffer name")
     (old-string string "Exact text to replace")
     (new-string string "Replacement text")
     (replace-all boolean "Replace every occurrence (default false)"
                  :optional t))
  :group 'edit :destructive t :confirm 'ask
  (require 'cmacs-core-tools)
  (unless (and (stringp old-string) (stringp new-string))
    (error "Missing required arguments: buffer, old_string, new_string"))
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (let ((case-fold-search nil) (cnt 0))
      ;; Counted before anything is touched, so an ambiguous edit
      ;; changes nothing.
      (save-excursion
        (goto-char (point-min))
        (while (search-forward old-string nil t) (setq cnt (1+ cnt))))
      (cond
       ((= cnt 0) (error "old_string not found in buffer"))
       ((and (> cnt 1) (not replace-all))
        (error "old_string matches %d times; pass replace_all" cnt))
       (t (save-excursion
            (goto-char (point-min))
            (let ((m 0))
              (while (and (search-forward old-string nil t)
                          (or replace-all (= m 0)))
                (replace-match new-string t t)
                (setq m (1+ m)))
              (cmacs-core-tools-print
               (format "replaced %d occurrence(s)" m)))))))))

(cmacs-brigade-deftool replace-in-buffer
  "Regexp search-and-replace across a whole buffer. Returns the \
number of matches replaced."
    ((buffer string "Buffer name")
     (regexp string "Emacs regexp to match")
     (replacement string "Replacement string (\\N backrefs allowed)"))
  :group 'edit :destructive t :confirm 'ask
  (require 'cmacs-core-tools)
  (unless (and (stringp regexp) (stringp replacement))
    (error "Missing required arguments: buffer, regexp, replacement"))
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (save-excursion
      (goto-char (point-min))
      (let ((c 0))
        (while (re-search-forward regexp nil t)
          (replace-match replacement t nil)
          (setq c (1+ c)))
        (cmacs-core-tools-print (format "replaced %d match(es)" c))))))

(cmacs-brigade-deftool search-buffer
  "Search a buffer for a regexp. Returns up to 200 matches as \
'LINE: TEXT' lines."
    ((buffer string "Buffer name")
     (regexp string "Emacs regexp to match"))
  :group 'edit
  (require 'cmacs-core-tools)
  (unless (stringp regexp)
    (error "Missing required arguments: buffer, regexp"))
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (save-excursion
      (goto-char (point-min))
      (let ((out '()) (n 0))
        (while (and (< n cmacs-edit-tools-search-limit)
                    (re-search-forward regexp nil t))
          (push (format "%d: %s" (line-number-at-pos)
                        (buffer-substring-no-properties
                         (line-beginning-position)
                         (line-end-position)))
                out)
          (setq n (1+ n))
          ;; One hit per line, and a regexp that matches the empty
          ;; string cannot spin in place.
          (forward-line 1))
        (cmacs-core-tools-print
         (if out
             (mapconcat #'identity (nreverse out) "\n")
           "(no matches)"))))))

(cmacs-brigade-deftool goto-line
  "Move point to a 1-based line number in a buffer, updating its \
window if one is showing."
    ((buffer string "Buffer name")
     (line integer "1-based line"))
  :group 'edit
  (require 'cmacs-core-tools)
  (unless (integerp line)
    (error "Missing required arguments: buffer, line"))
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (goto-char (point-min))
    (forward-line (1- line))
    (let ((w (get-buffer-window (current-buffer) t)))
      (when w (set-window-point w (point))))
    (cmacs-core-tools-print
     (format "line %d at point %d" (line-number-at-pos) (point)))))

(provide 'cmacs-edit-tools)

;;; cmacs-edit-tools.el ends here
