;;; cmacs-secondbrain-ingest-migrate.el --- Markdown notes to Org, in bulk  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The notes repository moved from Markdown to Org, and a tail of `.md'
;; files is still in it: archived tickets, people cards, a few captures.
;; This migrates them IN PLACE -- each becomes an Org node in the same
;; directory, with the same base name, its front matter mapped onto the
;; header keywords, and its links rewritten -- through the ingest
;; pipeline, so a migrated note is indistinguishable from an ingested
;; one: an `:ID:', an index bullet, and (if asked) a summary.
;;
;; Links are the part worth doing carefully.  The old notes link to each
;; other as `[[02_areas/work/people/x.md]]', as `![[path.md]]' (the
;; repository's own transclusion convention, which the org notes keep),
;; and as `[text](other.md)'.  A note that will be migrated in the same
;; batch gets its id minted UP FRONT, so a link to it can be rewritten as
;; `[[id:...]]' before the target exists; a link to an org note that is
;; already there resolves through its `:ID:'; a link to nothing stays as
;; it was and is reported.  A dangling id would be worse than a stale
;; path.
;;
;; Nothing runs by default.  `cmacs-secondbrain-ingest-migrate' plans,
;; and returns the plan, unless told to apply it.  Originals are kept
;; unless `:remove' says otherwise, and even then they go to the trash.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org-id)
(require 'cmacs-secondbrain-ingest)

;;;; Configuration ----------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-migrate-exclude
  '("/\\.git/" "/\\.claude/" "/\\.vimban/" "/trees/" "/\\.ingested/"
    "\\`CLAUDE\\.md\\'" "\\`README\\.md\\'" "/node_modules/")
  "Regexps matched against a Markdown file's path (and its base name).
A match leaves it alone: tooling files, agent memory, vimban's own store."
  :type '(repeat regexp)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-migrate-include-archives nil
  "Whether `04_archives' is migrated.  The archive is mostly finished
tickets; converting them is safe but noisy, so it is opt-in."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-migrate-front-matter-keys
  '(("title" . :title) ("description" . :description) ("summary" . :description)
    ("tags" . :tags) ("created" . :created) ("date" . :created)
    ("aliases" . :aliases))
  "Front-matter keys that map onto the note header; the rest are kept
verbatim in a `* Front matter' section so nothing a ticket knew is lost."
  :type '(alist :key-type string :value-type symbol)
  :group 'cmacs-secondbrain-ingest)

;;;; Front matter -----------------------------------------------------------

(defun cmacs-secondbrain-ingest-migrate-split-front-matter (text)
  "Return (FRONT . BODY) for Markdown TEXT with an optional YAML front matter.
FRONT is an alist of (KEY . VALUE) where a VALUE is a string or, for a
YAML list, a list of strings; nil when there is no front matter."
  (if (not (string-match "\\`---[ \t]*\n\\(\\(?:.*\n\\)*?\\)---[ \t]*\n" text))
      (cons nil text)
    (let ((yaml (match-string 1 text))
          (body (substring text (match-end 0)))
          (front nil) (key nil))
      (dolist (line (split-string yaml "\n"))
        (cond
         ((string-match "\\`\\([A-Za-z_][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)\\'" line)
          (setq key (match-string 1 line))
          (let ((v (string-trim (match-string 2 line))))
            (push (cons key (cond ((member v '("" "[]" "null" "~")) (if (equal v "[]") nil ""))
                                  ((string-match "\\`\\[\\(.*\\)\\]\\'" v)
                                   (mapcar (lambda (i) (string-trim i "['\" ]+" "['\" ]+"))
                                           (split-string (match-string 1 v) "," t)))
                                  (t (string-trim v "['\"]" "['\"]"))))
                  front)))
         ((and key (string-match "\\`[ \t]*-[ \t]+\\(.*\\)\\'" line))
          (let ((cell (assoc key front))
                (item (string-trim (match-string 1 line) "['\"]" "['\"]")))
            (setcdr cell (append (if (listp (cdr cell)) (cdr cell) nil) (list item)))))
         (t nil)))
      (cons (nreverse front) body))))

(defun cmacs-secondbrain-ingest-migrate--iso (value)
  "Return VALUE as an ISO 8601 timestamp with offset, or nil."
  (when (and (stringp value) (not (string-empty-p value)))
    (condition-case nil
        (let ((time (or (ignore-errors (date-to-time value))
                        (ignore-errors (encode-time (parse-time-string value))))))
          (and time (format-time-string "%FT%T%z" time)))
      (error nil))))

;;;; Link rewriting -------------------------------------------------------------

(defun cmacs-secondbrain-ingest-migrate--org-nodes (root)
  "Return a hash of root-relative `.org' path -> (ID . TITLE) for ROOT."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (f (directory-files-recursively root "\\.org\\'"))
      (unless (string-match-p "/\\.git/\\|/trees/" f)
        (let ((id (cmacs-secondbrain-ingest-file-id f)))
          (when id
            (puthash (file-relative-name f root)
                     (cons id (cmacs-secondbrain-ingest-file-title f)) h)))))
    h))

(defun cmacs-secondbrain-ingest-migrate--resolve (target from root nodes planned)
  "Resolve link TARGET written in file FROM to (ID . TITLE), or nil.
NODES maps existing org notes; PLANNED maps Markdown sources being
migrated to their pre-minted ids.  TARGET may be root-relative or
relative to FROM's directory, with or without an extension."
  (let* ((clean (car (split-string target "[#|]")))
         (candidates (delete-dups
                      (list clean
                            (file-relative-name (expand-file-name clean (file-name-directory from)) root)))))
    (cl-loop for c in candidates
             for org = (concat (file-name-sans-extension c) ".org")
             for md = (concat (file-name-sans-extension c) ".md")
             for hit = (or (gethash org nodes)
                           (gethash (expand-file-name md root) planned))
             when hit return hit)))

(defun cmacs-secondbrain-ingest-migrate-rewrite-links (text from root nodes planned)
  "Rewrite the Markdown links in TEXT (from file FROM under ROOT).
Returns (TEXT . UNRESOLVED), where UNRESOLVED lists link targets that
matched no note.  Transclusion links `![[path.md]]' keep their form with
the path re-pointed to `.org'; `[[path.md]]' and `[text](path.md)' become
`[[id:ID][text]]'."
  (let ((unresolved nil))
    (cl-flet ((resolve (target)
                (or (cmacs-secondbrain-ingest-migrate--resolve target from root nodes planned)
                    (progn (cl-pushnew target unresolved :test #'equal) nil))))
      ;; ![[path]] transclusions: only the extension changes.
      (setq text (replace-regexp-in-string
                  "!\\[\\[\\([^]|\n]+\\.md\\)\\(|[^]]*\\)?\\]\\]"
                  (lambda (m)
                    (let ((target (match-string 1 m)))
                      (if (resolve target)
                          (format "![[%s.org]]" (file-name-sans-extension target))
                        m)))
                  text t t))
      ;; [[path.md]] and [[path.md|label]] wikilinks.
      (setq text (replace-regexp-in-string
                  "\\(^\\|[^!]\\)\\[\\[\\([^]|\n]+\\.md\\)\\(?:|\\([^]]*\\)\\)?\\]\\]"
                  (lambda (m)
                    (let* ((pre (match-string 1 m))
                           (target (match-string 2 m))
                           (label (match-string 3 m))
                           (hit (resolve target)))
                      (if hit
                          (format "%s[[id:%s][%s]]" pre (car hit) (or label (cdr hit)))
                        m)))
                  text t t))
      ;; [text](path.md) links.
      (setq text (replace-regexp-in-string
                  "\\[\\([^]\n]+\\)\\](\\([^)\n#]+\\.md\\)\\(#[^)]*\\)?)"
                  (lambda (m)
                    (let* ((label (match-string 1 m))
                           (target (match-string 2 m))
                           (hit (resolve target)))
                      (if hit (format "[[id:%s][%s]]" (car hit) label) m)))
                  text t t)))
    (cons text (nreverse unresolved))))

;;;; Planning ---------------------------------------------------------------

(defun cmacs-secondbrain-ingest-migrate-candidates (&optional dir root include-archives)
  "Return the Markdown files under DIR (default: the whole ROOT) to migrate."
  (let* ((root (file-name-as-directory (expand-file-name (or root (cmacs-secondbrain-ingest-root)))))
         (dir (file-name-as-directory (expand-file-name (or dir root) root))))
    (cl-remove-if
     (lambda (f)
       (let ((rel (file-relative-name f root)))
         (or (cl-some (lambda (re) (or (string-match-p re f)
                                        (string-match-p re (file-name-nondirectory f))))
                      cmacs-secondbrain-ingest-migrate-exclude)
             (and (not (or include-archives cmacs-secondbrain-ingest-migrate-include-archives))
                  (string-prefix-p "04_archives/" rel)))))
     (directory-files-recursively dir "\\.md\\'"))))

(defun cmacs-secondbrain-ingest-migrate-plan (&optional dir root include-archives)
  "Plan the migration of the Markdown under DIR; nothing is written.

Returns a plist (:root :count :entries :unresolved) where each entry is
\(:source :target :title :id :tags :created :links :unresolved :exists).
An existing `.org' twin (same base name) is reported with :exists and is
skipped when the plan is applied."
  (let* ((root (file-name-as-directory (expand-file-name (or root (cmacs-secondbrain-ingest-root)))))
         (files (cmacs-secondbrain-ingest-migrate-candidates dir root include-archives))
         (nodes (cmacs-secondbrain-ingest-migrate--org-nodes root))
         (planned (make-hash-table :test 'equal))
         (entries nil) (all-unresolved nil))
    ;; Pass one: mint or reuse ids so cross-links inside the batch resolve.
    (dolist (f files)
      (let* ((target (concat (file-name-sans-extension f) ".org"))
             (front (car (cmacs-secondbrain-ingest-migrate-split-front-matter
                          (cmacs-secondbrain-ingest--read-file f))))
             (title (or (let ((tt (cdr (assoc "title" front)))) (and (stringp tt) (not (string-empty-p tt)) tt))
                        (cmacs-secondbrain-ingest--md-title (cmacs-secondbrain-ingest--read-file f))
                        (replace-regexp-in-string "[_-]+" " " (file-name-base f))))
             (id (or (and (file-exists-p target) (cmacs-secondbrain-ingest-file-id target))
                     (org-id-new))))
        (puthash f (cons id title) planned)))
    ;; Pass two: the entries, with links resolved against both maps.
    (dolist (f files)
      (let* ((raw (cmacs-secondbrain-ingest--read-file f))
             (split (cmacs-secondbrain-ingest-migrate-split-front-matter raw))
             (front (car split))
             (section (cmacs-secondbrain-ingest-migrate--front-section front))
             (rewritten (cmacs-secondbrain-ingest-migrate-rewrite-links
                         (if section (concat (cdr split) "\n\n" section) (cdr split))
                         f root nodes planned))
             (target (concat (file-name-sans-extension f) ".org"))
             (idt (gethash f planned))
             (tags (let ((v (cdr (assoc "tags" front))))
                     (cond ((listp v) v) ((stringp v) (split-string v "[, ]+" t)))))
             (created (cmacs-secondbrain-ingest-migrate--iso
                       (or (cdr (assoc "created" front)) (cdr (assoc "date" front))))))
        (setq all-unresolved (append all-unresolved (cdr rewritten)))
        (push (list :source f :target target
                    :title (cdr idt) :id (car idt)
                    :tags tags
                    :created (or created (format-time-string "%FT%T%z"
                                                             (file-attribute-modification-time (file-attributes f))))
                    :front front
                    :body (car rewritten)
                    :links (- (length (split-string (cdr split) "\\[\\[\\|](" t)) 1)
                    :unresolved (cdr rewritten)
                    :exists (file-exists-p target))
              entries)))
    (list :root root :count (length entries) :entries (nreverse entries)
          :unresolved (delete-dups all-unresolved))))

(defun cmacs-secondbrain-ingest-migrate-plan-json (&optional dir root include-archives)
  "The plan as JSON, without the bodies."
  (let ((plan (cmacs-secondbrain-ingest-migrate-plan dir root include-archives)))
    (json-serialize
     (list :root (plist-get plan :root)
           :count (plist-get plan :count)
           :unresolved (vconcat (plist-get plan :unresolved))
           :entries (vconcat
                     (mapcar (lambda (e)
                               (list :source (plist-get e :source)
                                     :target (plist-get e :target)
                                     :title (plist-get e :title)
                                     :tags (vconcat (plist-get e :tags))
                                     :created (plist-get e :created)
                                     :unresolved (vconcat (plist-get e :unresolved))
                                     :exists (and (plist-get e :exists) t)))
                             (plist-get plan :entries)))))))

;;;; Applying -----------------------------------------------------------------

(defun cmacs-secondbrain-ingest-migrate--front-section (front)
  "Render the front-matter keys that did not map onto the header.

Written as Markdown, not Org, because it is appended to the Markdown
body before conversion: an Org heading dropped into Markdown text would
come out as a bullet.  Values keep their links so the rewriter can
resolve them like any other."
  (let ((rest (cl-remove-if (lambda (kv) (assoc (car kv) cmacs-secondbrain-ingest-migrate-front-matter-keys))
                            front)))
    (when rest
      (concat "## Front matter\n\n"
              (mapconcat (lambda (kv)
                           (format "- %s: %s" (car kv)
                                   (let ((v (cdr kv)))
                                     (cond ((null v) "")
                                           ((listp v) (string-join v ", "))
                                           (t v)))))
                         rest "\n")))))

;;;###autoload
(defun cmacs-secondbrain-ingest-migrate (&optional dir &rest opts)
  "Migrate the Markdown notes under DIR (default: the whole tree) to Org.

Without `:apply', only plans: returns the plan plist and, interactively,
shows it.  With `:apply' each note goes through the ingest pipeline into
its own directory with its own base name, its pre-minted id, its front
matter mapped onto the header and its links rewritten.  Other OPTS:

  :include-archives  also migrate 04_archives
  :ai                let the model summarise and tag (default: no model)
  :remove            what to do with the original: nil keeps it,
                     `trash' moves it to the system trash
  :callback          function of the list of jobs when all are done
  :root              notes root

Returns the plan, with :jobs added when applied."
  (interactive (list (read-directory-name "Migrate Markdown under: " (cmacs-secondbrain-ingest-root))))
  (let* ((root (or (plist-get opts :root) (cmacs-secondbrain-ingest-root)))
         (plan (cmacs-secondbrain-ingest-migrate-plan dir root (plist-get opts :include-archives))))
    (if (not (plist-get opts :apply))
        (progn
          (when (called-interactively-p 'any)
            (cmacs-secondbrain-ingest-migrate-show-plan plan))
          plan)
      (let* ((entries (cl-remove-if (lambda (e) (plist-get e :exists)) (plist-get plan :entries)))
             (jobs nil) (remaining (length entries))
             (finish (lambda ()
                       (when (functionp (plist-get opts :callback))
                         (funcall (plist-get opts :callback) jobs)))))
        (when (null entries) (funcall finish))
        (dolist (e entries)
          (let* ((source (plist-get e :source))
                 (text (plist-get e :body))
                 (job (cmacs-secondbrain-ingest-enqueue
                       nil
                       :text text :format 'markdown :source source
                       :title (plist-get e :title)
                       :id (plist-get e :id)
                       :created (plist-get e :created)
                       :tags (append (plist-get e :tags) '("migrated"))
                       :name (file-name-base source)
                       :directory (file-relative-name (file-name-directory source) root)
                       :root root
                       :no-ai (not (plist-get opts :ai))
                       :link (and (plist-get opts :ai) t)
                       :start t
                       :callback
                       (lambda (job)
                         (when (and (eq (cmacs-secondbrain-ingest-job-stage job) 'done)
                                    (eq (plist-get opts :remove) 'trash)
                                    (file-exists-p source))
                           (ignore-errors (move-file-to-trash source)))
                         (cl-decf remaining)
                         (when (<= remaining 0) (funcall finish))))))
            (push job jobs)))
        (setq jobs (nreverse jobs))
        (plist-put plan :jobs jobs)))))

(defun cmacs-secondbrain-ingest-migrate-show-plan (plan)
  "Display PLAN in a buffer."
  (with-current-buffer (get-buffer-create "*second brain: migration plan*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Markdown -> Org migration plan for %s\n%d files"
                      (plist-get plan :root) (plist-get plan :count)))
      (insert (format ", %d unresolved link target%s\n\n"
                      (length (plist-get plan :unresolved))
                      (if (= 1 (length (plist-get plan :unresolved))) "" "s")))
      (dolist (e (plist-get plan :entries))
        (insert (format "%s %s\n    -> %s%s\n"
                        (if (plist-get e :exists) "skip" "  ->")
                        (file-relative-name (plist-get e :source) (plist-get plan :root))
                        (plist-get e :title)
                        (if (plist-get e :unresolved)
                            (format "  [unresolved: %s]" (string-join (plist-get e :unresolved) ", "))
                          ""))))
      (insert "\nNothing has been written.  (cmacs-secondbrain-ingest-migrate DIR :apply t)"
              " applies it; :remove 'trash moves the originals to the trash.\n")
      (special-mode))
    (pop-to-buffer (current-buffer))))

(defun cmacs-secondbrain-ingest-migrate-from-json (dir options-json)
  "The D-Bus/MCP face: plan (default) or apply per OPTIONS-JSON.
Options: apply, include_archives, ai, remove (\"trash\").  Returns the
plan as JSON; when applied, also the job ids."
  (let* ((obj (or (cmacs-secondbrain-ingest-json-parse
                   (if (or (null options-json) (string-blank-p options-json)) "{}" options-json))
                  (error "options are not a JSON object")))
         (get (lambda (k) (cmacs-secondbrain-ingest-json-get obj k)))
         (dir (and dir (not (string-empty-p dir)) dir)))
    (if (not (funcall get "apply"))
        (cmacs-secondbrain-ingest-migrate-plan-json dir nil (funcall get "include_archives"))
      (let ((plan (cmacs-secondbrain-ingest-migrate
                   dir :apply t
                   :include-archives (funcall get "include_archives")
                   :ai (funcall get "ai")
                   :remove (and (equal (funcall get "remove") "trash") 'trash))))
        (json-serialize
         (list :root (plist-get plan :root)
               :count (plist-get plan :count)
               :jobs (vconcat (mapcar #'cmacs-secondbrain-ingest-job-id (plist-get plan :jobs)))
               :unresolved (vconcat (plist-get plan :unresolved))))))))

(provide 'cmacs-secondbrain-ingest-migrate)
;;; cmacs-secondbrain-ingest-migrate.el ends here
