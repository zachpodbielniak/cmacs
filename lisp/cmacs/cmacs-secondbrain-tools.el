;;; cmacs-secondbrain-tools.el --- The second-brain view as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tools of cmacs/mcp/cmacs-mcp-tools-secondbrain.c that the registry
;; did not already provide, moved onto the capability table
;; (doc_org/cmacs/cmacs-capability.org has the recipe): the ones that
;; drive the ARMS view, and the ingester's cancel, migrate and doctor.
;; Wire names, parameter names and the required/optional split are the C
;; ones.  That C file is deleted; the schema these tools must keep is
;; what it published, frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; `secondbrain_ingest', `secondbrain_ingest_status', `secondbrain_tree'
;; and `secondbrain_find' are in cmacs-secondbrain-ingest-tools.el, and
;; `secondbrain_search' -- whose C called a function that does not
;; exist -- in cmacs-secondbrain-search-tools.el.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - No argument is spliced into Lisp source.  The layout name was
;;     passed to `intern'; here it has to be one of the four layouts.
;;
;;   - A failure is signalled instead of returned as ordinary text.
;;
;;   - `secondbrain_doctor' reports an unavailable program as
;;     "available": false.  The C serialised nil there, which
;;     `json-serialize' writes as {} -- an empty object, and truthy to
;;     most clients.
;;
;;   - `secondbrain_migrate' is declared destructive and asks for
;;     confirmation: with 'apply' it rewrites notes in bulk and can move
;;     the originals to the trash.  Without 'apply' it only plans.

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-secondbrain-buffer-name)

(declare-function cmacs-secondbrain "cmacs-secondbrain" ())
(declare-function cmacs-secondbrain-3d "cmacs-secondbrain" ())
(declare-function cmacs-secondbrain-refresh "cmacs-secondbrain" ())
(declare-function cmacs-secondbrain-set-layout-interactive "cmacs-secondbrain"
                  (kind))
(declare-function cmacs-secondbrain-sources "cmacs-secondbrain-sources" ())
(declare-function cmacs-secondbrain-layout-kind "cmacs-secondbrain-defuns.c"
                  (buffer))
(declare-function cmacs-secondbrain-node-at "cmacs-secondbrain-defuns.c"
                  (buffer id))
(declare-function cmacs-secondbrain-node-count "cmacs-secondbrain-defuns.c"
                  (buffer))
(declare-function cmacs-secondbrain-visible-count "cmacs-secondbrain-defuns.c"
                  (buffer))
(declare-function cmacs-secondbrain-edge-count "cmacs-secondbrain-defuns.c"
                  (buffer))
(declare-function cmacs-secondbrain-set-collapsed "cmacs-secondbrain-defuns.c"
                  (buffer id collapsed &optional frames))
(declare-function cmacs-secondbrain-collapse-all "cmacs-secondbrain-defuns.c"
                  (buffer &optional collapsed frames))
(declare-function cmacs-secondbrain-ingest-cancel "cmacs-secondbrain-ingest"
                  (job))
(declare-function cmacs-secondbrain-ingest-status-json
                  "cmacs-secondbrain-ingest" (id))
(declare-function cmacs-secondbrain-ingest-doctor
                  "cmacs-secondbrain-ingest-extract" ())
(declare-function cmacs-secondbrain-ingest-migrate-from-json
                  "cmacs-secondbrain-ingest-migrate" (dir options-json))

(defconst cmacs-secondbrain-tools--layouts '("rings" "circle" "hex" "force")
  "The layout names `secondbrain_set_layout' accepts.")

(defun cmacs-secondbrain-tools--text (value)
  "Return VALUE when it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun cmacs-secondbrain-tools--buffer ()
  "Return the second-brain buffer, or signal when the view is not open.
Every view tool acts on that one buffer, and saying it is not open is a
better answer than silently doing nothing."
  (require 'cmacs-secondbrain)
  (or (get-buffer cmacs-secondbrain-buffer-name)
      (error "The second brain is not open; call secondbrain_open")))


;;;; The view

(cmacs-brigade-deftool secondbrain-open
  "Open the ARMS second-brain visualiser: the user's agentic workspace \
as four concentric rings (Applications, Routines, Memory, Skills). Set \
'three_d' for the free 3D view rather than the flat one."
    ((three_d boolean "Free 3D view" :optional t))
  :group 'secondbrain
  :destructive t
  :undo '(irreversible "close the map buffer it opened")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.SecondBrain.Open
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool secondbrain open --three-d"
  (require 'cmacs-secondbrain)
  (if three_d (cmacs-secondbrain-3d) (cmacs-secondbrain))
  "opened")

(cmacs-brigade-deftool secondbrain-set-layout
  "Switch the layout.  'rings' is the ARMS layout (concentric bands), \
'circle' one circle per department, 'hex' a hex lattice, 'force' a \
force-directed graph.  The change animates."
    ((kind string "rings, circle, hex or force"
           :enum ("rings" "circle" "hex" "force")))
  :group 'secondbrain
  :destructive t
  :undo '(irreversible "set the layout back with the tool")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.SecondBrain.SetLayout
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool secondbrain set-layout --kind hex"
  (unless (member kind cmacs-secondbrain-tools--layouts)
    (error "secondbrain_set_layout: 'kind' must be one of %s"
           (string-join cmacs-secondbrain-tools--layouts ", ")))
  (with-current-buffer (cmacs-secondbrain-tools--buffer)
    ;; `intern' is safe here: KIND is one of four literals by now.
    (cmacs-secondbrain-set-layout-interactive (intern kind))
    (format "%s" (cmacs-secondbrain-layout-kind (current-buffer)))))

(cmacs-brigade-deftool secondbrain-expand
  "Expand or collapse a department.  With 'id', acts on that node; \
without one, acts on every department at once.  Departments start \
collapsed, so this is how you see what is inside one."
    ((id string "Node id; omit for all" :optional t)
     (collapse boolean "Collapse instead" :optional t))
  :group 'secondbrain
  :destructive t
  :undo '(irreversible "the map keeps no previous expansion")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.SecondBrain.Expand
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool secondbrain expand --id memory/areas"
  (let ((collapsed (and collapse t)))
    (with-current-buffer (cmacs-secondbrain-tools--buffer)
      ;; Zero frames: no tween.  Nobody is watching a transition an RPC
      ;; asked for, and the next call should see the settled state.
      (if (cmacs-secondbrain-tools--text id)
          (if (cmacs-secondbrain-set-collapsed (current-buffer) id collapsed 0)
              "changed"
            "no change")
        (cmacs-secondbrain-collapse-all (current-buffer) collapsed 0)
        "ok"))))

(cmacs-brigade-deftool secondbrain-node-info
  "Return the full record for a node id: title, role, ARMS ring, \
department and file."
    ((id string "Node id"))
  :group 'secondbrain
  :example "emacsctl tool secondbrain node-info --id memory/areas"
  (unless (cmacs-secondbrain-tools--text id)
    (error "secondbrain_node_info: missing 'id'"))
  (with-current-buffer (cmacs-secondbrain-tools--buffer)
    (format "%S" (cmacs-secondbrain-node-at (current-buffer) id))))

(cmacs-brigade-deftool secondbrain-stats
  "Counts for the open view: total nodes, how many are visible (the \
rest are inside collapsed departments), edges, and the layout."
    ()
  :group 'secondbrain
  :example "emacsctl tool secondbrain stats"
  (with-current-buffer (cmacs-secondbrain-tools--buffer)
    (format "nodes=%s visible=%s edges=%s layout=%s"
            (cmacs-secondbrain-node-count (current-buffer))
            (cmacs-secondbrain-visible-count (current-buffer))
            (cmacs-secondbrain-edge-count (current-buffer))
            (cmacs-secondbrain-layout-kind (current-buffer)))))

(cmacs-brigade-deftool secondbrain-sources
  "List the registered ARMS data sources -- where each ring's contents \
come from."
    ()
  :group 'secondbrain
  :example "emacsctl tool secondbrain sources"
  (require 'cmacs-secondbrain)
  (format "%S" (cmacs-secondbrain-sources)))

(cmacs-brigade-deftool secondbrain-refresh
  "Re-read every enabled source and rebuild the graph."
    ()
  :group 'secondbrain
  :example "emacsctl tool secondbrain refresh"
  (with-current-buffer (cmacs-secondbrain-tools--buffer)
    (cmacs-secondbrain-refresh)
    "refreshed"))


;;;; The ingester: needs no open view

(cmacs-brigade-deftool secondbrain-ingest-cancel
  "Cancel an ingest job by id."
    ((id string "Job id, e.g. sbi-3"))
  :group 'secondbrain :returns 'json
  :destructive t
  :undo '(irreversible "a cancelled ingest cannot be resumed")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.SecondBrain.IngestCancel
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool secondbrain ingest-cancel --id sbi-3"
  (require 'cmacs-secondbrain-ingest)
  (unless (cmacs-secondbrain-tools--text id)
    (error "secondbrain_ingest_cancel: missing 'id'"))
  (cmacs-secondbrain-ingest-cancel id)
  (cmacs-secondbrain-ingest-status-json id))

(cmacs-brigade-deftool secondbrain-migrate
  "Plan -- or with 'apply', perform -- the bulk migration of the \
Markdown notes under 'dir' (default: the whole tree) into Org nodes in \
place: same directory, same base name, front matter mapped onto the \
header, links rewritten to ids.  Without 'apply' nothing is written and \
the plan lists every file and every link that would not resolve.  \
'remove' = 'trash' moves the originals to the trash afterwards."
    ((dir string "Directory to migrate; omit for the whole tree" :optional t)
     (apply boolean "Perform the migration instead of planning it"
            :optional t)
     (include_archives boolean "Also migrate 04_archives" :optional t)
     (ai boolean "Summarise and tag with the model" :optional t)
     (remove string "'trash' moves the originals to the trash"
             :optional t :enum ("trash")))
  ;; Destructive, so by the registry's rule not on D-Bus or the CLI:
  ;; `emacsctl sb' and org.cmacs.Editor1.SecondBrain already have their
  ;; own, deliberate, way to ask for this.
  :group 'secondbrain :returns 'json :destructive t :confirm 'ask
  :undo '(irreversible "an applied migration is not reversed by undo")
  (require 'cmacs-secondbrain-ingest-migrate)
  ;; The options travel as the JSON object the D-Bus method and the C
  ;; tool hand the same function, so there is one parser of them.  Only
  ;; the literal "trash" is passed on as a removal policy.
  (cmacs-secondbrain-ingest-migrate-from-json
   (cmacs-secondbrain-tools--text dir)
   (json-serialize
    (list :apply (if apply t :false)
          :include_archives (if include_archives t :false)
          :ai (if ai t :false)
          :remove (if (equal remove "trash") "trash" "")))))

(cmacs-brigade-deftool secondbrain-doctor
  "Which external programs (pandoc, pdftotext, yt-dlp, ffmpeg, ...) and \
cmacs features (office, whisper, ai) the ingester can use on this host."
    ()
  :group 'secondbrain :returns 'json
  :example "emacsctl tool secondbrain doctor"
  (require 'cmacs-secondbrain-ingest)
  (json-serialize
   (vconcat
    (mapcar (lambda (entry)
              (list :name (symbol-name (nth 0 entry))
                    :available (if (nth 1 entry) t :false)
                    :detail (or (nth 2 entry) "")))
            (cmacs-secondbrain-ingest-doctor)))))

(provide 'cmacs-secondbrain-tools)

;;; cmacs-secondbrain-tools.el ends here
