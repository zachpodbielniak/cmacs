;;; cmacs-secondbrain-sources.el --- ARMS data providers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where the four ARMS rings get their nodes.
;;
;; A source is a plist registered under a name; the visualiser asks each
;; enabled one to enumerate, and stitches the results into one graph.
;; Adding a ring member is therefore a registration, not a patch -- the
;; same shape `cmacs-brigade-register-memory-source' and
;; `cmacs-roamgraph-sources' already use.
;;
;;   (cmacs-secondbrain-register-source
;;    :name 'my-thing :ring 'applications :label "My thing"
;;    :enumerate (lambda () (list (list :id "x" :title "X"))))
;;
;; Shipped providers cover two worlds, because both are real: the Claude
;; Code workspace under ~/.claude (skills, scheduled tasks, MCP servers,
;; plugins) and cmacs's own equivalents (podomation pods, brigade
;; schedule and tools).  Each is independently toggleable through
;; `cmacs-secondbrain-enabled-sources', because which of them is
;; meaningful depends entirely on how you work.
;;
;; A provider that signals is caught and reported rather than being
;; allowed to take the whole graph down: one unreadable config file
;; should cost you one ring member, not the map.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-brigade-registry-get "cmacs-brigade-registry")
(require 'cmacs-para)

(defgroup cmacs-secondbrain nil
  "The ARMS second-brain visualiser."
  :group 'cmacs
  :prefix "cmacs-secondbrain-")

;;;; Registry ---------------------------------------------------------

(defvar cmacs-secondbrain--sources (make-hash-table :test 'eq)
  "Registered ARMS sources, keyed by name symbol.")

(defcustom cmacs-secondbrain-enabled-sources t
  "Which registered sources contribute to the graph.

t enables every registered source.  A list of name symbols enables
exactly those.  A source you do not use is not merely noise: an
Applications ring that lists things you have never connected tells you
nothing about your actual trust surface."
  :type '(choice (const :tag "All registered sources" t)
                 (repeat symbol))
  :group 'cmacs-secondbrain)

(defun cmacs-secondbrain-register-source (&rest plist)
  "Register an ARMS source from PLIST.

Recognised keys:
  :name       symbol, required -- re-registering a name replaces it,
              which is how a config reload works
  :ring       `skills', `memory', `routines' or `applications'
  :label      human-readable name, for the source list
  :enumerate  function of no arguments returning a list of node plists
  :edges      optional function of the node list returning edge plists

A node plist is what `cmacs-secondbrain-set-graph' documents; :ring is
filled in from the source when the node omits it, so a provider only
has to say it once."
  (let ((name (plist-get plist :name)))
    (unless (symbolp name)
      (error "cmacs-secondbrain: source :name must be a symbol"))
    (unless (functionp (plist-get plist :enumerate))
      (error "cmacs-secondbrain: source %s needs an :enumerate function" name))
    (puthash name plist cmacs-secondbrain--sources)
    name))

(defun cmacs-secondbrain-unregister-source (name)
  "Remove the source called NAME."
  (remhash name cmacs-secondbrain--sources))

(defun cmacs-secondbrain-sources ()
  "Return the registered source names, sorted."
  (sort (hash-table-keys cmacs-secondbrain--sources) #'string<))

(defun cmacs-secondbrain-source-get (name)
  "Return the plist registered for NAME, or nil."
  (gethash name cmacs-secondbrain--sources))

(defun cmacs-secondbrain--source-enabled-p (name)
  "Return non-nil when source NAME should contribute."
  (or (eq cmacs-secondbrain-enabled-sources t)
      (memq name cmacs-secondbrain-enabled-sources)))

;;;; Helpers ----------------------------------------------------------

(defun cmacs-secondbrain--read-json (file)
  "Read FILE as JSON into a plist, or nil when it cannot be read."
  (when (and file (file-readable-p file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (json-parse-buffer :object-type 'plist :array-type 'list
                           :null-object nil :false-object nil)))))

(defun cmacs-secondbrain--file-mtime (file)
  "Return FILE's modification time as a float, or nil."
  (when (and file (file-exists-p file))
    (float-time (file-attribute-modification-time (file-attributes file)))))

;;;; Applications -----------------------------------------------------

(defcustom cmacs-secondbrain-claude-dir "~/.claude"
  "Root of the Claude Code workspace to read."
  :type 'directory
  :group 'cmacs-secondbrain)

(defun cmacs-secondbrain--claude-mcp-servers ()
  "Return MCP server names configured for Claude Code.

Read from ~/.claude.json rather than ~/.claude/settings.json: that is
where the servers actually live, and the two files are easy to
confuse."
  (let* ((cfg (cmacs-secondbrain--read-json (expand-file-name "~/.claude.json")))
         (servers (plist-get cfg :mcpServers))
         (out nil))
    ;; A plist of NAME -> config; we want the names.
    (while servers
      (let ((k (car servers)))
        (when (keywordp k)
          (push (substring (symbol-name k) 1) out)))
      (setq servers (cddr servers)))
    (nreverse out)))

(defun cmacs-secondbrain--enumerate-claude-apps ()
  "Nodes for the Applications ring, from the Claude Code workspace."
  (let ((nodes nil))
    (dolist (name (cmacs-secondbrain--claude-mcp-servers))
      (push (list :id (concat "app:mcp:" name)
                  :title name
                  :kind 'app
                  :department "MCP"
                  :ring 'applications)
            nodes))
    (let* ((plugins (cmacs-secondbrain--read-json
                     (expand-file-name "plugins/installed_plugins.json"
                                       cmacs-secondbrain-claude-dir))))
      (when plugins
        (let ((repos plugins))
          (while repos
            (let ((k (car repos)))
              (when (keywordp k)
                (push (list :id (concat "app:plugin:" (substring (symbol-name k) 1))
                            :title (substring (symbol-name k) 1)
                            :kind 'app
                            :department "Plugins"
                            :ring 'applications)
                      nodes)))
            (setq repos (cddr repos))))))
    (nreverse nodes)))

(defun cmacs-secondbrain--enumerate-cmacs-apps ()
  "Nodes for the Applications ring, from cmacs's own connections."
  (let ((nodes nil))
    ;; What cmacs itself is wired into.  Probed rather than assumed:
    ;; the point of this ring is what is actually connected.
    (dolist (spec '(("gsurf"      "Browser"   cmacs-gsurf-supported-p)
                    ("dbexplorer" "Databases" cmacs-dbexplorer-supported-p)
                    ("mcp"        "MCP"       cmacs-mcp-server-running-p)
                    ("whisper"    "Voice"     cmacs-whisper-supported-p)
                    ("piper"      "Voice"     cmacs-piper-supported-p)))
      (cl-destructuring-bind (id dept pred) spec
        (when (and (fboundp pred) (ignore-errors (funcall pred)))
          (push (list :id (concat "app:cmacs:" id)
                      :title id
                      :kind 'app
                      :department dept
                      :ring 'applications)
                nodes))))
    (nreverse nodes)))

;;;; Routines ---------------------------------------------------------

(defun cmacs-secondbrain--enumerate-claude-routines ()
  "Nodes for the Routines ring, from ~/.claude/scheduled-tasks."
  (let* ((dir (expand-file-name "scheduled-tasks" cmacs-secondbrain-claude-dir))
         (nodes nil))
    (when (file-directory-p dir)
      (dolist (entry (directory-files dir nil "\\`[^.]" t))
        (let ((path (expand-file-name entry dir)))
          (push (list :id (concat "routine:claude:" entry)
                      :title entry
                      :kind 'routine
                      :file (when (file-regular-p path) path)
                      :department "Scheduled"
                      :ring 'routines
                      :mtime (cmacs-secondbrain--file-mtime path))
                nodes))))
    (nreverse nodes)))

(defun cmacs-secondbrain--enumerate-cmacs-routines ()
  "Nodes for the Routines ring, from brigade schedules and podomation pods."
  (let ((nodes nil))
    (when (fboundp 'cmacs-brigade-schedule-list)
      (dolist (s (ignore-errors (cmacs-brigade-schedule-list)))
        (let ((name (format "%s" (or (plist-get s :name) s))))
          (push (list :id (concat "routine:brigade:" name)
                      :title name
                      :kind 'routine
                      :department "Brigade"
                      :ring 'routines)
                nodes))))
    (when (fboundp 'cmacs-podomation-list-pods)
      (dolist (p (ignore-errors (cmacs-podomation-list-pods)))
        (let ((name (format "%s" p)))
          (push (list :id (concat "routine:pod:" name)
                      :title name
                      :kind 'routine
                      :department "Podomation"
                      :ring 'routines)
                nodes))))
    (nreverse nodes)))

;;;; Skills -----------------------------------------------------------

(defun cmacs-secondbrain--enumerate-claude-skills ()
  "Nodes for the Skills ring, from ~/.claude/skills and agents."
  (let ((nodes nil)
        (skills (expand-file-name "skills" cmacs-secondbrain-claude-dir))
        (agents (expand-file-name "agents" cmacs-secondbrain-claude-dir)))
    (when (file-directory-p skills)
      (dolist (d (directory-files skills nil "\\`[^.]" t))
        (let ((md (expand-file-name (format "%s/SKILL.md" d) skills)))
          (when (file-readable-p md)
            (push (list :id (concat "skill:" d)
                        :title d
                        :kind 'skill
                        :file md
                        :department "Skills"
                        :ring 'skills
                        :mtime (cmacs-secondbrain--file-mtime md))
                  nodes)))))
    (when (file-directory-p agents)
      (dolist (f (directory-files agents nil "\\.md\\'" t))
        (push (list :id (concat "skill:agent:" f)
                    :title (file-name-base f)
                    :kind 'skill
                    :file (expand-file-name f agents)
                    :department "Agents"
                    :ring 'skills)
              nodes)))
    (nreverse nodes)))

(defun cmacs-secondbrain--enumerate-cmacs-skills ()
  "Nodes for the Skills ring, from the brigade tool registry."
  (let ((nodes nil))
    (when (fboundp 'cmacs-brigade-registry-list)
      (dolist (tool (ignore-errors (cmacs-brigade-registry-list 'tool)))
        (let* ((plist (ignore-errors (cmacs-brigade-registry-get 'tool tool)))
               (group (or (plist-get plist :group) 'tools)))
          (push (list :id (concat "skill:tool:" (symbol-name tool))
                      :title (symbol-name tool)
                      :kind 'skill
                      :department (capitalize (format "%s" group))
                      :ring 'skills)
                nodes))))
    (nreverse nodes)))

;;;; Memory -----------------------------------------------------------

(defcustom cmacs-secondbrain-memory-max-nodes 4000
  "Cap on Memory-ring nodes taken from the notes tree.

A mature tree is thousands of notes and the map stops being a map long
before it stops being drawable.  Whatever is dropped is reported rather
than silently truncated."
  :type 'integer
  :group 'cmacs-secondbrain)

(defun cmacs-secondbrain--scan-org-tree ()
  "Scan the PARA tree for org-roam nodes without the database.

Returns (:nodes LIST :edges LIST) in the shape `cmacs-roamgraph-db-fetch'
produces.

This exists because the database is not always there.  org-roam builds
`org-roam.db' on demand, a fresh checkout has never had it built, and
roamgraph's native C scanner is a stub that returns nil -- so without
this the Memory ring, which is the largest of the four, comes up empty
on a machine whose notes are perfectly well formed.

One pass per file: the `:ID:' in the top drawer is the node, `#+title:'
is its name, and every `[[id:...]]' is an edge."
  (let ((files nil) (nodes nil) (edges nil)
        (by-id (make-hash-table :test 'equal)))
    (dolist (root cmacs-para-roots)
      (let ((dir (expand-file-name root)))
        (when (file-directory-p dir)
          (setq files (append files
                              (directory-files-recursively dir "\\.org\\'"))))))
    ;; Newest first, so a cap keeps what you were most recently working on.
    (setq files (sort files
                      (lambda (a b)
                        (time-less-p
                         (file-attribute-modification-time (file-attributes b))
                         (file-attribute-modification-time (file-attributes a))))))
    (dolist (file files)
      (when (and (file-readable-p file)
                 (not (string-match-p "/\\.git/" file)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (let ((id (and (re-search-forward
                          "^[ \t]*:ID:[ \t]+\\([0-9a-fA-F-]+\\)" nil t)
                         (match-string 1)))
                (title nil))
            (goto-char (point-min))
            (when (re-search-forward "^#\\+title:[ \t]*\\(.*\\)$" nil t)
              (setq title (string-trim (match-string 1))))
            (when id
              (puthash id t by-id)
              (push (list :id id
                          :title (or title (file-name-base file))
                          :file file)
                    nodes)
              ;; Links out.  Collected even when the target has not been
              ;; seen yet; dangling ones are dropped at the end.
              (goto-char (point-min))
              (while (re-search-forward "\\[\\[id:\\([0-9a-fA-F-]+\\)" nil t)
                (let ((to (match-string 1)))
                  (unless (equal to id)
                    (push (cons id to) edges)))))))))
    (list :nodes (nreverse nodes)
          :edges (delq nil
                       (mapcar (lambda (e)
                                 (when (gethash (cdr e) by-id)
                                   (list :from (car e) :to (cdr e))))
                               (nreverse edges))))))

(defun cmacs-secondbrain--fetch-notes ()
  "Return the notes graph, from the org-roam database or by scanning.

The database is preferred: it is already built, it already handles
emacsql's prin1-quoted values and the id-only link filter, and it is far
faster than reading every file.  The scanner is what makes the ring work
when there is no database yet."
  (require 'cmacs-roamgraph-db nil 'noerror)
  (or (and (fboundp 'cmacs-roamgraph-db-fetch)
           (ignore-errors (cmacs-roamgraph-db-fetch)))
      (cmacs-secondbrain--scan-org-tree)))

(defun cmacs-secondbrain--enumerate-notes ()
  "Nodes for the Memory ring, from the PARA notes tree.

Reuses `cmacs-roamgraph-db-fetch' rather than reimplementing the
org-roam reader: that function already handles emacsql's prin1-quoted
values and the `type = \\='\"id\"\\=' link filter, both of which are
easy to get subtly wrong."
  (let* ((g (cmacs-secondbrain--fetch-notes))
         (raw (append (plist-get g :nodes) nil))
         (n (length raw))
         (kept (if (> n cmacs-secondbrain-memory-max-nodes)
                   (seq-take raw cmacs-secondbrain-memory-max-nodes)
                 raw))
         (nodes nil))
    (when (> n (length kept))
      (message "cmacs-secondbrain: showing %d of %d notes (see %s)"
               (length kept) n 'cmacs-secondbrain-memory-max-nodes))
    (dolist (node kept)
      (let* ((file (plist-get node :file))
             (class (and file (cmacs-para-classify file)))
             (bucket (or (plist-get class :bucket) "notes")))
        (push (list :id (plist-get node :id)
                    :title (plist-get node :title)
                    :kind 'file
                    :file file
                    ;; PARA is the department taxonomy for Memory: it is
                    ;; how the tree is actually organised, so grouping by
                    ;; anything else would be inventing a second one.
                    :department bucket
                    :ring 'memory
                    :color (cmacs-para-color bucket))
              nodes)))
    (nreverse nodes)))

(defun cmacs-secondbrain--notes-edges (nodes)
  "Return org-roam link edges among NODES."
  (let ((ids (make-hash-table :test 'equal))
        (out nil))
    (dolist (n nodes) (puthash (plist-get n :id) t ids))
    (let ((g (cmacs-secondbrain--fetch-notes)))
      (dolist (e (append (plist-get g :edges) nil))
        (let ((from (plist-get e :from)) (to (plist-get e :to)))
          (when (and (gethash from ids) (gethash to ids))
            (push (list :from from :to to) out)))))
    (nreverse out)))

;;;; Shipped registrations --------------------------------------------

(cmacs-secondbrain-register-source
 :name 'claude-applications :ring 'applications
 :label "Claude Code: MCP servers and plugins"
 :enumerate #'cmacs-secondbrain--enumerate-claude-apps)

(cmacs-secondbrain-register-source
 :name 'cmacs-applications :ring 'applications
 :label "cmacs: connected subsystems"
 :enumerate #'cmacs-secondbrain--enumerate-cmacs-apps)

(cmacs-secondbrain-register-source
 :name 'claude-routines :ring 'routines
 :label "Claude Code: scheduled tasks"
 :enumerate #'cmacs-secondbrain--enumerate-claude-routines)

(cmacs-secondbrain-register-source
 :name 'cmacs-routines :ring 'routines
 :label "cmacs: brigade schedules and pods"
 :enumerate #'cmacs-secondbrain--enumerate-cmacs-routines)

(cmacs-secondbrain-register-source
 :name 'claude-skills :ring 'skills
 :label "Claude Code: skills and agents"
 :enumerate #'cmacs-secondbrain--enumerate-claude-skills)

(cmacs-secondbrain-register-source
 :name 'cmacs-skills :ring 'skills
 :label "cmacs: brigade tools"
 :enumerate #'cmacs-secondbrain--enumerate-cmacs-skills)

(cmacs-secondbrain-register-source
 :name 'notes :ring 'memory
 :label "PARA notes tree"
 :enumerate #'cmacs-secondbrain--enumerate-notes
 :edges #'cmacs-secondbrain--notes-edges)

;;;; Icons -------------------------------------------------------------

(defcustom cmacs-secondbrain-icon-dirs
  (list (expand-file-name "icons" cmacs-secondbrain-claude-dir)
        "/usr/share/icons/hicolor/scalable/apps")
  "Directories searched for an application\='s SVG icon.

Searched in order for `NAME.svg\='.  Nothing ships icons with cmacs --
application logos are other people\='s trademarks -- so this points at
places one may already have them, and a node with no icon simply keeps
its glyph."
  :type '(repeat directory)
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-show-icons t
  "Whether to draw SVG icons on Applications-ring nodes."
  :type 'boolean
  :group 'cmacs-secondbrain)

(defun cmacs-secondbrain-icon-for (name)
  "Return a readable SVG path for NAME, or nil.

Tried case-insensitively and with spaces folded to hyphens, because an
application called \"Google Drive\" is `google-drive.svg\=' about as often
as it is anything else."
  (when (stringp name)
    (let* ((base (downcase (replace-regexp-in-string "[ _]+" "-" name)))
           (candidates (list (concat base ".svg")
                             (concat (car (split-string base "-")) ".svg"))))
      (cl-loop for dir in cmacs-secondbrain-icon-dirs
               thereis (cl-loop for c in candidates
                                for f = (expand-file-name c dir)
                                when (file-readable-p f) return f)))))

(defun cmacs-secondbrain-apply-icons (buffer nodes)
  "Draw an icon on every visible Applications node in BUFFER that has one.

Called after the scene is built, because icons are cleared along with
the drawables."
  (when (and cmacs-secondbrain-show-icons
             (fboundp 'cmacs-secondbrain-add-icon))
    (let ((n 0))
      (dolist (node nodes)
        (when (eq (plist-get node :ring) 'applications)
          (let ((svg (cmacs-secondbrain-icon-for (plist-get node :title))))
            (when (and svg
                       (cmacs-secondbrain-add-icon buffer (plist-get node :id)
                                                   svg 128))
              (cl-incf n)))))
      n)))

;;;; Collection -------------------------------------------------------

(defcustom cmacs-secondbrain-centre-title "CLAUDE.md"
  "Title of the node at the centre of the rings."
  :type 'string
  :group 'cmacs-secondbrain)

(defconst cmacs-secondbrain-centre-id "centre"
  "Id of the synthetic centre node.")

(defun cmacs-secondbrain-collect ()
  "Run every enabled source and return (:nodes LIST :edges LIST).

Departments become collapsed hub nodes: a ring holding four thousand
notes is not a map, and the reference this is modelled on shows a
handful of sized circles rather than the whole corpus at once.

A source that signals is reported and skipped -- one unreadable config
should cost one ring member, not the graph."
  (let ((nodes nil) (edges nil) (hubs (make-hash-table :test 'equal)))
    (dolist (name (cmacs-secondbrain-sources))
      (when (cmacs-secondbrain--source-enabled-p name)
        (let* ((src (cmacs-secondbrain-source-get name))
               (ring (or (plist-get src :ring) 'memory))
               (got (condition-case err
                        (funcall (plist-get src :enumerate))
                      (error
                       (message "cmacs-secondbrain: source %s failed: %s"
                                name (error-message-string err))
                       nil))))
          (dolist (n got)
            ;; The source says its ring once; a node may still override.
            (unless (plist-get n :ring)
              (setq n (plist-put (copy-sequence n) :ring ring)))
            (push n nodes))
          (when (and got (functionp (plist-get src :edges)))
            (setq edges
                  (append (condition-case err
                              (funcall (plist-get src :edges) got)
                            (error
                             (message "cmacs-secondbrain: %s edges failed: %s"
                                      name (error-message-string err))
                             nil))
                          edges))))))
    (setq nodes (nreverse nodes))

    ;; One hub per (ring, department), and every node parented to it.
    (dolist (n nodes)
      (let* ((ring (plist-get n :ring))
             (dept (or (plist-get n :department) "Other"))
             (key (format "%s/%s" ring dept)))
        (unless (gethash key hubs)
          (puthash key (list :id (concat "hub:" key)
                             :title dept
                             :kind 'hub
                             :ring ring
                             :department dept
                             :collapsed t)
                   hubs))))

    (let ((hub-nodes nil)
          (counts (make-hash-table :test 'equal))
          (parented nil))
      (dolist (n nodes)
        (let* ((ring (plist-get n :ring))
               (dept (or (plist-get n :department) "Other"))
               (key (format "%s/%s" ring dept)))
          (puthash key (1+ (gethash key counts 0)) counts)
          (push (plist-put (copy-sequence n) :parent (concat "hub:" key))
                parented)))
      ;; The count IS the headline: a collapsed department that only says
      ;; its name tells you nothing about whether it holds four files or
      ;; four thousand, which is the first thing you want to know when
      ;; deciding whether to open it.  It rides in the title because the
      ;; label is what renders in-scene, and in :count so the inspector
      ;; and the AI target can read it without parsing the title back.
      (maphash
       (lambda (key h)
         (let ((c (gethash key counts 0)))
           (push (plist-put
                  (plist-put (copy-sequence h) :count c)
                  :title (format "%s  %d" (plist-get h :title) c))
                 hub-nodes)))
       hubs)
      (list :nodes (append
                    (list (list :id cmacs-secondbrain-centre-id
                                :title cmacs-secondbrain-centre-title
                                :kind 'centre
                                :ring 'skills))
                    hub-nodes
                    (nreverse parented))
            ;; Hubs hang off the centre, so the rings read as one system
            ;; rather than four unrelated orbits.
            :edges (append
                    (mapcar (lambda (h)
                              (list :from cmacs-secondbrain-centre-id
                                    :to (plist-get h :id)))
                            hub-nodes)
                    edges)))))

(provide 'cmacs-secondbrain-sources)

;;; cmacs-secondbrain-sources.el ends here
