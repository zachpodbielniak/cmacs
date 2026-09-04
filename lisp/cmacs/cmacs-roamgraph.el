;;; cmacs-roamgraph.el --- native org-roam graph visualiser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `M-x cmacs-roamgraph' opens your org-roam link graph as a live
;; libregnum scene inside a cmacs buffer: the in-editor replacement for
;; org-roam-ui's local web server plus browser.  `M-x cmacs-roamgraph-3d'
;; opens the same graph in three dimensions.
;;
;; Two navigation tiers, both always live:
;;
;;   h j k l   spatial -- the nearest node in that screen direction.
;;             This is what you mean when you are looking at a picture
;;             of a graph and want the node over there.
;;   ] [ < >   topological -- descend a forward link, ascend a
;;             backlink, cycle the peer set.  This is what you mean
;;             when you are following the structure of your notes.
;;
;; `/' searches incrementally and highlights every match in place;
;; `g /' opens a completing-read jump palette instead.
;;
;; IDENTITY.  libregnum scene node ids are insertion indices and churn
;; on every rebuild, so every piece of state here is keyed on the
;; org-roam id string.  That id is also what the C side stores as the
;; node's `path', which is what arrives synchronously in the click
;; dispatch -- the numeric id in that same callback may already be
;; stale.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'cmacs-libregnum)   ; popup-menu (GTK vs --lrg routing), mode parent
(require 'cmacs-roamgraph-db)

(declare-function cmacs-libregnum-resize "cmacs-libregnum")
(declare-function cmacs-libregnum-set-selection "cmacs-libregnum")
(declare-function cmacs-libregnum-set-animated "cmacs-libregnum")
(declare-function cmacs-libregnum-default-font-file "cmacs-libregnum")
(declare-function cmacs-libregnum-set-inscene-labels "cmacs-libregnum")
(declare-function cmacs-libregnum-set-label-font "cmacs-libregnum")
(declare-function cmacs-libregnum-set-label-style "cmacs-libregnum")
(declare-function cmacs-libregnum-set-node-label-mode "cmacs-libregnum")
(declare-function cmacs-libregnum-set-right-drag-pans "cmacs-libregnum")
(declare-function cmacs-libregnum-set-wheel-up-zooms-in "cmacs-libregnum")
(declare-function evil-normal-state "evil-states")
;; cmacs-roamgraph-search.el requires THIS file, so the dependency runs
;; one way only: the keymap below names its commands, and
;; `cmacs-roamgraph--open' pulls the file in at run time.
(declare-function cmacs-roamgraph-search "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-search-next "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-search-prev "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-search-clear "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-jump "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph--build-haystacks "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-scan-directory "cmacs-roamgraph")
;; cmacs-roamgraph-panes.el requires this file too, so the same one-way
;; rule applies: name its commands here, load it from the mode body.
(declare-function cmacs-roamgraph-nodes "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph-tags "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph-inspector "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph-dashboard "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph-close-panes "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph--list-goto "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph--inspector-soon "cmacs-roamgraph-panes")
(declare-function cmacs-roamgraph--tags-render "cmacs-roamgraph-panes")

;;;; Customisation -----------------------------------------------------

(defcustom cmacs-roamgraph-default-size '(1000 . 700)
  "Fallback (WIDTH . HEIGHT) for the viewport before it is fitted."
  :type '(cons integer integer)
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-label-size 13
  "Height in pixels of in-scene node labels."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-max-labels 120
  "How many labels may be drawn at once before decluttering drops them."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-hub-degree 12
  "Nodes with at least this many links are labelled permanently.
They act as landmarks, so the map is readable without pointing at
anything.  Everything else labels on hover."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-follow-camera 'edge
  "When a keyboard move should also move the camera.

`edge'  only when the target is off-screen -- \"scroll to keep point
        visible\".  The default, because flying on every step
        invalidates the very projection the spatial keys navigate by.
nil     never
t       always"
  :type '(choice (const edge) (const nil) (const t))
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-peer-sort 'title
  "Order of a node's neighbours for peer cycling and link menus."
  :type '(choice (const title) (const degree) (const file))
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-layout-fps 30
  "Frames per second while the layout is settling."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-neighbour-labels 8
  "How many of the selection's neighbours are labelled outright.

Capped because a hub can have a hundred links, and labelling all of
them buries the graph under a wall of text.  The rest are still
emphasised -- brighter nodes and brighter edges -- just not named."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-show-orphans nil
  "When non-nil, include notes with no links at all.

Off by default: an unlinked note carries no graph information, and a
mature notes tree has enough of them to form a distracting ring around
everything that does.  Toggle it with
\<cmacs-roamgraph-mode-map>\[cmacs-roamgraph-toggle-orphans]."
  :type 'boolean
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-pan-step 70
  "Pixels the view moves per WASD keypress."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-cone-degrees 45
  "Half-angle of the screen-space cone used by the spatial h/j/k/l keys."
  :type 'integer
  :group 'cmacs-roamgraph)

;;;; Buffer-local state ------------------------------------------------

(defvar-local cmacs-roamgraph--graph nil
  "Plist (:nodes VECTOR :edges VECTOR :source SYM) currently displayed.")
(defvar-local cmacs-roamgraph--by-id nil
  "Hash of org-roam id to its node plist.")
(defvar-local cmacs-roamgraph--selected nil
  "Org-roam id of the selected node, or nil.")
(defvar-local cmacs-roamgraph--3d nil
  "Non-nil when the viewport is in 3D.")
(defvar-local cmacs-roamgraph--trail nil
  "Breadcrumb stack of (PARENT-ID . CHILD-INDEX) for topological nav.")
(defvar-local cmacs-roamgraph--spatial-trail nil
  "Stack of (DIRECTION . FROM-ID) making spatial moves exactly reversible.")
(defvar-local cmacs-roamgraph--matches nil
  "Vector of matching ids from the last search, or nil.")
(defvar-local cmacs-roamgraph--match-index 0
  "Cursor into `cmacs-roamgraph--matches'.")
(defvar-local cmacs-roamgraph--layout-timer nil)
(defvar-local cmacs-roamgraph--resize-timer nil)
(defvar-local cmacs-roamgraph--root nil
  "Id the current view is rooted at, for a local graph.")
(defvar-local cmacs-roamgraph--root-history nil)
(defvar-local cmacs-roamgraph--filter-tags nil
  "Tags the view is currently restricted to.")
(defvar-local cmacs-roamgraph--full-graph nil
  "The unfiltered graph, so a filter can be lifted without re-reading.")
(defvar-local cmacs-roamgraph--color-by 'para
  "Current colouring scheme; see `cmacs-roamgraph-cycle-color'.")

(defconst cmacs-roamgraph-buffer-name "*org-roam graph*")

;;;; Helpers ------------------------------------------------------------

(defun cmacs-roamgraph--buffer ()
  "Return the live roamgraph buffer, or signal."
  (let ((buf (if (derived-mode-p 'cmacs-roamgraph-mode)
                 (current-buffer)
               (get-buffer cmacs-roamgraph-buffer-name))))
    (unless (buffer-live-p buf)
      (user-error "No roamgraph buffer; run `M-x cmacs-roamgraph'"))
    buf))

(defun cmacs-roamgraph--node (id)
  "Return the node plist for ID."
  (and id cmacs-roamgraph--by-id (gethash id cmacs-roamgraph--by-id)))

(defun cmacs-roamgraph--title (id)
  "Return ID's display title."
  (or (plist-get (cmacs-roamgraph--node id) :title) id "?"))

(defun cmacs-roamgraph--degree (id)
  "Return ID's total link count."
  (length (cmacs-roamgraph-neighbors (current-buffer) id 'both)))

(defun cmacs-roamgraph--sort-ids (ids)
  "Sort IDS by `cmacs-roamgraph-peer-sort'.
Deterministic: this ordering is what makes `<' and `>' land back where
they started after a round trip, and it must survive a rebuild."
  (let ((key (pcase cmacs-roamgraph-peer-sort
               ('degree (lambda (id) (- (cmacs-roamgraph--degree id))))
               ('file   (lambda (id) (or (plist-get (cmacs-roamgraph--node id)
                                                    :file)
                                         "")))
               (_       (lambda (id) (downcase (cmacs-roamgraph--title id)))))))
    (sort (copy-sequence ids)
          (lambda (a b)
            (let ((ka (funcall key a)) (kb (funcall key b)))
              (cond ((and (numberp ka) (numberp kb))
                     (if (= ka kb) (string< a b) (< ka kb)))
                    ((string= ka kb) (string< a b))
                    (t (string< ka kb))))))))

(defun cmacs-roamgraph--scene-index (id)
  "Return the libregnum scene node index for ID.
Scene indices track the graph's own indices because the scene builder
emits nodes in graph order."
  (cmacs-roamgraph-node-index (current-buffer) id))

;;;; Selection ----------------------------------------------------------

(defun cmacs-roamgraph--select (id &optional focus reason)
  "Make ID the selection.

The single funnel every move goes through, so the C highlight, the
label ring, the inspector and the echo area can never disagree.  FOCUS
non-nil eases the camera; `edge' only does so when ID is off-screen.
REASON is a symbol used only for the echo line."
  (when (and id (cmacs-roamgraph--node id))
    (let* ((buf (current-buffer))
           (idx (cmacs-roamgraph--scene-index id))
           (fly (pcase (or focus cmacs-roamgraph-follow-camera)
                  ('edge (not (cmacs-roamgraph--onscreen-p idx)))
                  ('nil nil)
                  (_ t))))
      (setq cmacs-roamgraph--selected id)
      (when idx
        (cmacs-libregnum-set-selection buf idx fly)
        (cmacs-roamgraph--refresh-label-ring id))
      (cmacs-roamgraph--mark-neighbours id)
      (when (fboundp 'cmacs-roamgraph--list-goto)
        (ignore-errors (cmacs-roamgraph--list-goto id)))
      (cmacs-roamgraph--echo id reason)
      (when (fboundp 'cmacs-roamgraph--inspector-soon)
        (cmacs-roamgraph--inspector-soon))
      id)))

(defconst cmacs-roamgraph--flag-neighbour 8
  "The NEIGHBOUR bit of the renderer's per-node flag mask.")

(defun cmacs-roamgraph--mark-neighbours (id)
  "Flag ID's immediate neighbours so the renderer can emphasise them.
An edge incident to the selection, and the note at its far end, is the
thing you are actually looking at when you land somewhere."
  (when (fboundp 'cmacs-libregnum-clear-node-flags)
    (let ((buf (current-buffer)))
      (cmacs-libregnum-clear-node-flags buf cmacs-roamgraph--flag-neighbour)
      (dolist (nid (cmacs-roamgraph-neighbors buf id 'both))
        (let ((idx (cmacs-roamgraph--scene-index nid)))
          (when idx
            (cmacs-libregnum-set-node-flags
             buf idx (logior (cmacs-libregnum-node-flags buf idx)
                             cmacs-roamgraph--flag-neighbour)))))
      (when (fboundp 'cmacs-roamgraph-apply-flags)
        (cmacs-roamgraph-apply-flags buf)))))

(defun cmacs-roamgraph--onscreen-p (idx)
  "Return non-nil if scene node IDX is comfortably inside the viewport."
  (and idx
       (fboundp 'cmacs-libregnum-node-onscreen-p)
       (cmacs-libregnum-node-onscreen-p (current-buffer) idx 48)))

(defvar-local cmacs-roamgraph--label-ring nil
  "Scene indices currently forced to label, so they can be restored.")

(defun cmacs-roamgraph--refresh-label-ring (id)
  "Force ID and its immediate neighbours to label; restore the previous set."
  (when (fboundp 'cmacs-libregnum-set-node-label-mode)
    (let ((buf (current-buffer)))
      ;; Restore whatever the previous ring was showing.
      (dolist (old cmacs-roamgraph--label-ring)
        (ignore-errors
          (cmacs-libregnum-set-node-label-mode
           buf (car old) (cdr old))))
      (setq cmacs-roamgraph--label-ring nil)
      ;; The selection, plus its best-connected neighbours up to the
      ;; cap.  Naming all of a hub's hundred links would bury the map.
      (let* ((nbrs (cmacs-roamgraph-neighbors buf id 'both))
             (ranked (sort (copy-sequence nbrs)
                           (lambda (a b) (> (cmacs-roamgraph--degree a)
                                            (cmacs-roamgraph--degree b)))))
             (shown (cons id (seq-take ranked
                                       cmacs-roamgraph-neighbour-labels))))
        (dolist (nid shown)
          (let ((idx (cmacs-roamgraph--scene-index nid)))
            (when idx
              (push (cons idx (cmacs-roamgraph--default-label-mode nid))
                    cmacs-roamgraph--label-ring)
              (ignore-errors
                (cmacs-libregnum-set-node-label-mode buf idx 'always)))))))))

(defun cmacs-roamgraph--default-label-mode (id)
  "The label policy ID has when it is not part of the selection ring."
  (if (>= (cmacs-roamgraph--degree id) cmacs-roamgraph-hub-degree)
      'always
    'hover))

(defun cmacs-roamgraph--echo (id reason)
  "Describe ID in the echo area.
Without this, graph navigation feels random: you cannot tell why a key
landed where it did."
  (let* ((buf (current-buffer))
         (out (length (cmacs-roamgraph-neighbors buf id 'out)))
         (in  (length (cmacs-roamgraph-neighbors buf id 'in)))
         (peers (cmacs-roamgraph--peers id))
         (pos (and peers (cl-position id peers :test #'equal))))
    (message "→ %s   (%d back / %d fwd%s)%s"
             (cmacs-roamgraph--title id) in out
             (if (and peers pos)
                 (format " / peer %d of %d" (1+ pos) (length peers))
               "")
             (pcase reason
               ('search (format "  [match %d/%d]"
                                (1+ cmacs-roamgraph--match-index)
                                (length cmacs-roamgraph--matches)))
               (_ "")))))

(defun cmacs-roamgraph-deselect ()
  "Clear the selection."
  (interactive)
  (setq cmacs-roamgraph--selected nil
        cmacs-roamgraph--trail nil
        cmacs-roamgraph--spatial-trail nil)
  (cmacs-libregnum-set-selection (current-buffer) nil nil)
  (message "Deselected"))

;;;; Spatial navigation --------------------------------------------------

(defconst cmacs-roamgraph--directions
  '((left  . (-1.0 .  0.0))
    (right . ( 1.0 .  0.0))
    (up    . ( 0.0 . -1.0))
    (down  . ( 0.0 .  1.0)))
  "Screen-space unit vectors, y growing downward.")

(defun cmacs-roamgraph--opposite (dir)
  "Return the direction opposite DIR."
  (pcase dir ('left 'right) ('right 'left) ('up 'down) ('down 'up)))

(defun cmacs-roamgraph--move-spatial (dir)
  "Select the nearest node in screen direction DIR from the selection."
  (let ((buf (current-buffer)))
    (if (not cmacs-roamgraph--selected)
        ;; Nothing selected: start from the best-connected node, the
        ;; most useful place to be dropped into an unfamiliar graph.
        (cmacs-roamgraph--select (cmacs-roamgraph--busiest-node) t 'start)
      ;; Exact reversal.  A cone metric is not self-inverse in general,
      ;; so going back the way you came is replayed from a trail rather
      ;; than recomputed -- otherwise `l' then `h' can land somewhere
      ;; new.  Only valid while the camera has not moved, which is why
      ;; the trail is cleared on every camera change.
      (let ((top (car cmacs-roamgraph--spatial-trail)))
        (if (and top (eq dir (cmacs-roamgraph--opposite (car top))))
            (progn
              (pop cmacs-roamgraph--spatial-trail)
              (cmacs-roamgraph--select (cdr top) nil 'back))
          (let* ((from (cmacs-roamgraph--scene-index cmacs-roamgraph--selected))
                 (v (cdr (assq dir cmacs-roamgraph--directions)))
                 (hit (and from (fboundp 'cmacs-libregnum-nearest-in-direction)
                           (cmacs-libregnum-nearest-in-direction
                            buf from (car v) (cdr v)
                            cmacs-roamgraph-cone-degrees))))
            (if (not hit)
                (message "No node %s of here" dir)
              (push (cons dir cmacs-roamgraph--selected)
                    cmacs-roamgraph--spatial-trail)
              (cmacs-roamgraph--select (cmacs-roamgraph-node-id buf hit)
                                       nil dir))))))))

(defun cmacs-roamgraph--busiest-node ()
  "Return the id of the best-connected node, a sane default selection."
  (let ((best nil) (best-deg -1))
    (mapc (lambda (n)
            (let ((d (cmacs-roamgraph--degree (plist-get n :id))))
              (when (> d best-deg)
                (setq best (plist-get n :id) best-deg d))))
          (plist-get cmacs-roamgraph--graph :nodes))
    best))

(defun cmacs-roamgraph-move-left ()  (interactive) (cmacs-roamgraph--move-spatial 'left))
(defun cmacs-roamgraph-move-right () (interactive) (cmacs-roamgraph--move-spatial 'right))
(defun cmacs-roamgraph-move-up ()    (interactive) (cmacs-roamgraph--move-spatial 'up))
(defun cmacs-roamgraph-move-down ()  (interactive) (cmacs-roamgraph--move-spatial 'down))

;;;; Topological navigation ----------------------------------------------

(defun cmacs-roamgraph--out (id) (cmacs-roamgraph--sort-ids
                                  (cmacs-roamgraph-neighbors (current-buffer) id 'out)))
(defun cmacs-roamgraph--in  (id) (cmacs-roamgraph--sort-ids
                                  (cmacs-roamgraph-neighbors (current-buffer) id 'in)))

(defun cmacs-roamgraph--peers (id)
  "Return the peer set ID belongs to, in a stable order.

The peers are the other children of ID's navigation parent: the node
you actually arrived from when the last move was an ascent, otherwise
ID's first backlink.  Falling back to the whole graph would make `<'
and `>' meaningless, so that case says so instead."
  (let* ((parent (or (car (car cmacs-roamgraph--trail))
                     (car (cmacs-roamgraph--in id))))
         (peers (and parent (cmacs-roamgraph--out parent))))
    (if (and peers (member id peers))
        peers
      (let ((back (cmacs-roamgraph--in id)))
        (and back (cmacs-roamgraph--out (car back)))))))

(defun cmacs-roamgraph-descend ()
  "Follow a forward link from the selection."
  (interactive)
  (let* ((id cmacs-roamgraph--selected)
         (kids (and id (cmacs-roamgraph--out id))))
    (cond
     ((null id) (message "Nothing selected"))
     ((null kids) (message "No forward links from %s"
                           (cmacs-roamgraph--title id)))
     (t
      ;; Cap the trail: walking a cycle with `]' must not grow it forever.
      (when (> (length cmacs-roamgraph--trail) 512)
        (setq cmacs-roamgraph--trail (cl-subseq cmacs-roamgraph--trail 0 256)))
      (push (cons id 0) cmacs-roamgraph--trail)
      (cmacs-roamgraph--select (car kids) t 'descend)))))

(defun cmacs-roamgraph-ascend ()
  "Go back up: pop the breadcrumb, or follow a backlink."
  (interactive)
  (let* ((id cmacs-roamgraph--selected)
         (top (car cmacs-roamgraph--trail)))
    (cond
     ((null id) (message "Nothing selected"))
     ;; Only trust the breadcrumb if it still describes a real link --
     ;; a refresh may have removed it.
     ((and top (member id (cmacs-roamgraph--out (car top))))
      (pop cmacs-roamgraph--trail)
      (cmacs-roamgraph--select (car top) t 'ascend))
     ((cmacs-roamgraph--in id)
      (cmacs-roamgraph--select (car (cmacs-roamgraph--in id)) t 'ascend))
     (t (message "No backlinks to %s" (cmacs-roamgraph--title id))))))

(defun cmacs-roamgraph--cycle-peer (delta)
  "Move DELTA places through the selection's peer set, wrapping."
  (let* ((id cmacs-roamgraph--selected)
         (peers (and id (cmacs-roamgraph--peers id))))
    (cond
     ((null id) (message "Nothing selected"))
     ((or (null peers) (< (length peers) 2))
      (message "No peers of %s" (cmacs-roamgraph--title id)))
     (t
      (let* ((pos (or (cl-position id peers :test #'equal) 0))
             (next (nth (mod (+ pos delta) (length peers)) peers)))
        ;; Keep the trail's cursor in step, so a following `[' then `]'
        ;; returns here rather than to the first child.
        (when cmacs-roamgraph--trail
          (setcdr (car cmacs-roamgraph--trail)
                  (mod (+ pos delta) (length peers))))
        (cmacs-roamgraph--select next t 'peer))))))

(defun cmacs-roamgraph-next-peer () (interactive) (cmacs-roamgraph--cycle-peer 1))
(defun cmacs-roamgraph-prev-peer () (interactive) (cmacs-roamgraph--cycle-peer -1))

(defun cmacs-roamgraph-goto-link ()
  "Jump to one of the selection's links, chosen by name.
The answer for a hub with forty links, where cycling is hopeless."
  (interactive)
  (let* ((id cmacs-roamgraph--selected)
         (_ (unless id (user-error "Nothing selected")))
         (out (cmacs-roamgraph--out id))
         (in  (cmacs-roamgraph--in id))
         (cands (append
                 (mapcar (lambda (n) (cons (format "→ %s" (cmacs-roamgraph--title n)) n)) out)
                 (mapcar (lambda (n) (cons (format "← %s" (cmacs-roamgraph--title n)) n)) in))))
    (unless cands (user-error "%s has no links" (cmacs-roamgraph--title id)))
    (let ((pick (completing-read "Link: " (mapcar #'car cands) nil t)))
      (cmacs-roamgraph--select (cdr (assoc pick cands)) t 'link))))

;;;; Visiting ------------------------------------------------------------

(defun cmacs-roamgraph--visit (id &optional other-window)
  "Open the file behind ID, at the node's own position."
  (let* ((node (cmacs-roamgraph--node id))
         (file (plist-get node :file))
         (pos (or (plist-get node :pos) 1))
         (level (or (plist-get node :level) 0)))
    (unless (and file (file-exists-p file))
      (user-error "No readable file for %s" (cmacs-roamgraph--title id)))
    (if other-window (find-file-other-window file) (find-file file))
    ;; A heading-level node is not the top of its file.  Without this,
    ;; half a mature roam database drops you at line 1 of a long file.
    (when (> level 0)
      (goto-char (min pos (point-max)))
      (when (fboundp 'org-fold-show-entry) (ignore-errors (org-fold-show-entry)))
      (when (fboundp 'org-show-entry) (ignore-errors (org-show-entry)))
      (recenter 3))))

(defun cmacs-roamgraph-visit ()
  "Open the selected node's file."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (cmacs-roamgraph--visit cmacs-roamgraph--selected))

(defun cmacs-roamgraph-visit-other-window ()
  "Open the selected node's file in another window."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (cmacs-roamgraph--visit cmacs-roamgraph--selected t))

(defun cmacs-roamgraph-copy-id-link ()
  "Copy an org [[id:...]] link to the selected node."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (let ((s (format "[[id:%s][%s]]" cmacs-roamgraph--selected
                   (cmacs-roamgraph--title cmacs-roamgraph--selected))))
    (kill-new s)
    (message "Copied %s" s)))

;;;; Click dispatch ------------------------------------------------------

(defun cmacs-roamgraph--on-pick (buffer id _vx _vy path)
  "Handle a viewport click in BUFFER.

Called from `cmacs-libregnum--node-clicked' on the cmacs GMainContext.
PATH is the org-roam id captured synchronously at pick time; ID is the
numeric scene index, which may already be stale, so PATH wins."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((node-id (or (and (stringp path) (> (length path) 0)
                              (cmacs-roamgraph--node path) path)
                         (and (integerp id) (>= id 0)
                              (cmacs-roamgraph-node-id buffer id)))))
        (if node-id
            (cmacs-roamgraph--select node-id nil 'click)
          (cmacs-roamgraph-deselect))))))

(defun cmacs-roamgraph--menu-items (id)
  "Return the context-menu items for note ID, or for empty space when nil.

Each item is (LABEL . THUNK); a nil entry becomes a separator.  A single
pane with explicit separators, rather than several panes: a pane title
is rendered as a visible heading by the GTK path, which is why gnuseye
does it this way too.  The thunks run later, from the command loop."
  (if (and id (cmacs-roamgraph--node id))
      (let* ((node (cmacs-roamgraph--node id))
             (out (length (cmacs-roamgraph-neighbors (current-buffer) id 'out)))
             (in (length (cmacs-roamgraph-neighbors (current-buffer) id 'in)))
             (tags (plist-get node :tags))
             (pinned (plist-get node :pinned)))
        (append
         (list (cons "Open note" #'cmacs-roamgraph-visit)
               (cons "Open in other window"
                     #'cmacs-roamgraph-visit-other-window)
               (cons "Copy [[id:…]] link" #'cmacs-roamgraph-copy-id-link)
               nil
               (cons (format "Follow a link…  (%d out, %d in)" out in)
                     #'cmacs-roamgraph-goto-link)
               (cons "Centre the view here" #'cmacs-roamgraph-focus-selected)
               (cons "Show only this neighbourhood"
                     (lambda () (cmacs-roamgraph-local 2)))
               (cons (if pinned "Unpin from the layout" "Pin in place")
                     #'cmacs-roamgraph-toggle-pin)
               nil
               (cons "Inspect" (lambda ()
                                 (when (fboundp 'cmacs-roamgraph-inspector)
                                   (cmacs-roamgraph-inspector))))
               (cons "Show in the node list"
                     (lambda () (when (fboundp 'cmacs-roamgraph-nodes)
                                  (cmacs-roamgraph-nodes)))))
         (when tags
           (cons nil
                 (mapcar (lambda (tg)
                           (cons (format "Filter by :%s:" tg)
                                 (lambda ()
                                   (setq cmacs-roamgraph--filter-tags (list tg))
                                   (cmacs-roamgraph--apply-filter))))
                         tags)))
         (when (and (boundp 'cmacs-roamgraph-inspector-actions)
                    cmacs-roamgraph-inspector-actions)
           (cons nil
                 (delq nil
                       (mapcar
                        (lambda (a)
                          (let ((label (nth 1 a)) (fn (nth 2 a))
                                (pred (nth 3 a)))
                            (when (or (null pred)
                                      (ignore-errors (funcall pred id)))
                              (cons label (lambda () (funcall fn id))))))
                        (reverse cmacs-roamgraph-inspector-actions)))))))
    ;; Empty space: act on the view rather than on a note.
    (list (cons "Fit the whole graph" #'cmacs-roamgraph-fit-view)
          (cons (if cmacs-roamgraph--3d "Flatten to 2D" "Lift into 3D")
                #'cmacs-roamgraph-toggle-3d)
          (cons "Next colour scheme" #'cmacs-roamgraph-cycle-color)
          nil
          (cons (if cmacs-roamgraph-show-orphans
                    "Hide unlinked notes" "Show unlinked notes")
                #'cmacs-roamgraph-toggle-orphans)
          (cons "Filter by tag…" #'cmacs-roamgraph-filter-tag)
          (cons "Clear filters" #'cmacs-roamgraph-filter-clear)
          nil
          (cons "Deselect" #'cmacs-roamgraph-deselect)
          (cons "Dashboard" (lambda ()
                              (when (fboundp 'cmacs-roamgraph-dashboard)
                                (cmacs-roamgraph-dashboard))))
          (cons "Re-read the database" #'cmacs-roamgraph-refresh))))

(defun cmacs-roamgraph--context-menu (buffer _id path _vx _vy)
  "Pop a real context menu for PATH in BUFFER, or for empty space.

Goes through `cmacs-libregnum-popup-menu', so it is a native GTK menu
under pgtk and the in-engine libregnum popup under `emacs --lrg' --
the same routing gnuseye, imgedit and vidstudio use.

Called on the cmacs GMainContext, i.e. inside the pselect wait, so the
popup is re-scheduled onto the command loop: opening a nested GTK menu
loop from inside the GLib dispatch re-enters the event machinery."
  (when (buffer-live-p buffer)
    (run-with-timer
     0 nil
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let* ((id (and (stringp path) (> (length path) 0)
                           (cmacs-roamgraph--node path) path))
                  (title (if id (cmacs-roamgraph--title id) "org-roam graph"))
                  (items (cmacs-roamgraph--menu-items id)))
             ;; Selection happens below, so the AI section is appended
             ;; after it -- `cmacs-ai-menu-scene-items' resolves the
             ;; buffer's target, which for a graph IS the selection.
             ;; Right-clicking a note selects it too, so the menu and the
             ;; viewport agree about what is being acted on.
             (when id (cmacs-roamgraph--select id nil 'click))
             (setq items
                   (append items
                           (and (fboundp 'cmacs-ai-menu-scene-items)
                                (cmacs-ai-menu-scene-items))))
             (let ((choice
                    (cmacs-libregnum-popup-menu
                     t (list title
                             (cons ""
                                   (mapcar (lambda (it) (or it '("--")))
                                           items))))))
               (when (functionp choice) (funcall choice))))))))))

;;;; Camera --------------------------------------------------------------

(defun cmacs-roamgraph-fit-view ()
  "Frame the whole graph."
  (interactive)
  (cmacs-roamgraph-fit (current-buffer)))

(defun cmacs-roamgraph-focus-selected ()
  "Ease the camera onto the selection."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (cmacs-roamgraph--select cmacs-roamgraph--selected t 'focus))

;; The underlying zoom scales the camera distance by 0.9^AMOUNT, so a
;; POSITIVE amount moves closer.
(defun cmacs-roamgraph-zoom-in ()
  "Move the camera closer."
  (interactive) (cmacs-roamgraph-zoom (current-buffer) 2.0))

(defun cmacs-roamgraph-zoom-out ()
  "Move the camera further away."
  (interactive) (cmacs-roamgraph-zoom (current-buffer) -2.0))

;;;; Moving the view -------------------------------------------------------

;; Panning works identically in 2D and 3D: it slides the camera across
;; its own view plane, which is what "move around" means in both.  Right
;; -drag does the same thing with the mouse.

(defun cmacs-roamgraph--pan (dx dy)
  "Slide the view by DX and DY screen pixels."
  (cmacs-roamgraph-pan (current-buffer) dx dy)
  ;; The spatial trail replays moves against a fixed projection, so it
  ;; is only valid while the camera has not moved.
  (setq cmacs-roamgraph--spatial-trail nil))

(defun cmacs-roamgraph-pan-up ()
  "Move the view up."
  (interactive) (cmacs-roamgraph--pan 0 cmacs-roamgraph-pan-step))

(defun cmacs-roamgraph-pan-down ()
  "Move the view down."
  (interactive) (cmacs-roamgraph--pan 0 (- cmacs-roamgraph-pan-step)))

(defun cmacs-roamgraph-pan-left ()
  "Move the view left."
  (interactive) (cmacs-roamgraph--pan cmacs-roamgraph-pan-step 0))

(defun cmacs-roamgraph-pan-right ()
  "Move the view right."
  (interactive) (cmacs-roamgraph--pan (- cmacs-roamgraph-pan-step) 0))

(defun cmacs-roamgraph-toggle-pin ()
  "Pin or unpin the selected node so the solver leaves it alone."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (let* ((id cmacs-roamgraph--selected)
         (node (cmacs-roamgraph--node id))
         (now (not (plist-get node :pinned))))
    (cmacs-roamgraph-set-pinned (current-buffer) id now)
    (puthash id (plist-put (copy-sequence node) :pinned now)
             cmacs-roamgraph--by-id)
    (message "%s %s" (if now "Pinned" "Unpinned")
             (cmacs-roamgraph--title id))))

;;;; 2D / 3D --------------------------------------------------------------

(defun cmacs-roamgraph-view-2d ()
  "Lay the graph out flat and view it head-on."
  (interactive)
  (unless (and (not cmacs-roamgraph--3d) (cmacs-roamgraph-flat-p (current-buffer)))
    (setq cmacs-roamgraph--3d nil)
    (cmacs-roamgraph--apply-graph 2)
    (message "2D")))

(defun cmacs-roamgraph-view-3d ()
  "Lay the graph out in three dimensions."
  (interactive)
  (setq cmacs-roamgraph--3d t)
  (cmacs-roamgraph--apply-graph 3)
  (message "3D"))

(defun cmacs-roamgraph-toggle-3d ()
  "Switch between the 2D and 3D views."
  (interactive)
  (if cmacs-roamgraph--3d (cmacs-roamgraph-view-2d) (cmacs-roamgraph-view-3d)))

;;;; Building -------------------------------------------------------------

(defun cmacs-roamgraph--index-graph (graph)
  "Build the id to node-plist hash for GRAPH."
  (let ((h (make-hash-table :test #'equal)))
    (mapc (lambda (n) (puthash (plist-get n :id) n h)) (plist-get graph :nodes))
    h))

(defun cmacs-roamgraph--apply-graph (dims)
  "Push the current graph into the viewport, laid out in DIMS dimensions."
  (let ((buf (current-buffer))
        (g cmacs-roamgraph--graph))
    (cmacs-roamgraph-set-graph buf (plist-get g :nodes) (plist-get g :edges) dims)
    (cmacs-roamgraph--configure-labels)
    (cmacs-roamgraph--start-layout)
    ;; A rebuild renumbers every scene node, so anything holding a scene
    ;; index is now stale -- the label ring, and any live search.
    (setq cmacs-roamgraph--label-ring nil
          cmacs-roamgraph--spatial-trail nil)
    (when (fboundp 'cmacs-roamgraph--build-haystacks)
      (cmacs-roamgraph--build-haystacks))
    (when cmacs-roamgraph--selected
      (cmacs-roamgraph--select cmacs-roamgraph--selected nil 'rebuild))))

(defun cmacs-roamgraph--configure-labels ()
  "Set up the in-scene label pass for this buffer.

In-scene rather than the cairo overlay, because the overlay only exists
under pgtk -- a knowledge graph with no titles under `emacs --lrg'
would be useless."
  (let ((buf (current-buffer)))
    (when (fboundp 'cmacs-libregnum-set-label-font)
      (let ((ff (and (fboundp 'cmacs-libregnum-default-font-file)
                     (cmacs-libregnum-default-font-file))))
        (when ff (ignore-errors (cmacs-libregnum-set-label-font buf ff 32)))))
    (when (fboundp 'cmacs-libregnum-set-label-style)
      (cmacs-libregnum-set-label-style buf cmacs-roamgraph-label-size
                                       t t cmacs-roamgraph-max-labels))
    (when (fboundp 'cmacs-libregnum-set-label-decor)
      ;; A plate behind the text (edges run straight through it
      ;; otherwise) and screen-space rings on the selection, the hovered
      ;; node and search hits.
      (cmacs-libregnum-set-label-decor buf t t))
    (when (fboundp 'cmacs-libregnum-set-right-drag-pans)
      ;; Map-style navigation: left-drag orbits (in 3D), right-drag
      ;; moves the view.  The default CAD profile puts panning on the
      ;; middle button, which plenty of pointing devices do not have.
      (cmacs-libregnum-set-right-drag-pans buf t))
    (when (fboundp 'cmacs-libregnum-set-wheel-up-zooms-in)
      ;; Wheel up moves closer, as in every map and 3-D viewer.  The
      ;; inherited libregnum direction is the opposite.
      (cmacs-libregnum-set-wheel-up-zooms-in buf t))
    (when (fboundp 'cmacs-libregnum-set-selection-style)
      ;; The default marker is a wireframe cube, which is right for the
      ;; file-tree scene but wrong around a sphere.
      (cmacs-libregnum-set-selection-style buf 'halo))
    (when (fboundp 'cmacs-libregnum-set-inscene-labels)
      (cmacs-libregnum-set-inscene-labels buf t))))

(defun cmacs-roamgraph--start-layout ()
  "Drive the solver from a timer until it settles, then stop.

Stepped rather than solved in one go: a multi-second freeze on \\[cmacs-roamgraph]
is the org-roam-ui experience this replaces, and watching the graph
unfold is genuinely informative.  Equally, a permanently hot render
clock once it has settled is pure waste, so the timer cancels itself."
  (let ((buf (current-buffer)))
    (when (timerp cmacs-roamgraph--layout-timer)
      (cancel-timer cmacs-roamgraph--layout-timer))
    (when (fboundp 'cmacs-libregnum-set-animated)
      (cmacs-libregnum-set-animated buf t cmacs-roamgraph-layout-fps))
    (setq cmacs-roamgraph--layout-timer
          (run-with-timer
           0.03 0.03
           (lambda ()
             (if (not (buffer-live-p buf))
                 (message "")
               (with-current-buffer buf
                 (when (cmacs-roamgraph-layout-step buf 8)
                   (when (timerp cmacs-roamgraph--layout-timer)
                     (cancel-timer cmacs-roamgraph--layout-timer))
                   (setq cmacs-roamgraph--layout-timer nil)
                   (when (fboundp 'cmacs-libregnum-set-animated)
                     (cmacs-libregnum-set-animated buf nil))
                   (cmacs-roamgraph-fit buf)))))))))

(defun cmacs-roamgraph-refresh ()
  "Re-read the graph from its source and rebuild."
  (interactive)
  (let ((buf (current-buffer)))
    (with-current-buffer buf
      (message "cmacs-roamgraph: reading…")
      (let ((g (cmacs-roamgraph-fetch)))
        (when cmacs-roamgraph--root
          (setq g (cmacs-roamgraph-subgraph g cmacs-roamgraph--root 2)))
        (setq cmacs-roamgraph--full-graph g)
        (cmacs-roamgraph--apply-filter)
        (message "cmacs-roamgraph: %d notes, %d links (%s)"
                 (length (plist-get g :nodes))
                 (length (plist-get g :edges))
                 (plist-get g :source))))))

;;;; Window fitting -------------------------------------------------------

(defun cmacs-roamgraph--fit-window-now (buf)
  "Resize BUF's framebuffer to its window's pixel size.

Mandatory, not cosmetic: the framebuffer is blitted 1:1 across the
window rectangle, so any mismatch both distorts the nodes into ellipses
and resamples the in-scene label text into mush."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-roamgraph--resize-timer nil)
      (let ((win (get-buffer-window buf t)))
        (when (window-live-p win)
          ;; BODY pixels: the pgtk blit and the click mapping both use
          ;; the text area, so a full-rect FBO is painted squeezed and
          ;; every pick lands offset.
          (let ((w (window-body-width win t)) (h (window-body-height win t)))
            (when (and (> w 1) (> h 1))
              (ignore-errors (cmacs-libregnum-resize buf w h)))))))))

(defun cmacs-roamgraph--on-size-change (&optional _frame)
  "Coalesce window size changes into one refit."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (derived-mode-p 'cmacs-roamgraph-mode)
                   (not cmacs-roamgraph--resize-timer))
          (setq cmacs-roamgraph--resize-timer
                (run-with-idle-timer
                 0.06 nil #'cmacs-roamgraph--fit-window-now buf)))))))

(defun cmacs-roamgraph--on-kill ()
  "Tear down timers and the viewport when the buffer dies."
  (when (timerp cmacs-roamgraph--layout-timer)
    (cancel-timer cmacs-roamgraph--layout-timer))
  (when (timerp cmacs-roamgraph--resize-timer)
    (cancel-timer cmacs-roamgraph--resize-timer))
  (ignore-errors (cmacs-roamgraph-detach (current-buffer))))


;;;; Filtering ------------------------------------------------------------

(defun cmacs-roamgraph--apply-filter ()
  "Rebuild the view from the full graph, restricted to the active tags.

A filter changes which notes exist, so unlike a search it genuinely has
to re-solve the layout.  That is exactly why the two are separate
commands: you would not want this happening on every keystroke."
  (let* ((full (or cmacs-roamgraph--full-graph cmacs-roamgraph--graph))
         (full (if cmacs-roamgraph-show-orphans
                   full
                 (cmacs-roamgraph--drop-orphans full)))
         (tags cmacs-roamgraph--filter-tags)
         (g (if (null tags)
                full
              (let* ((keep (make-hash-table :test #'equal))
                     (nodes (cl-remove-if-not
                             (lambda (n)
                               (when (cl-every (lambda (tg)
                                                 (member tg (plist-get n :tags)))
                                               tags)
                                 (puthash (plist-get n :id) t keep)))
                             (append (plist-get full :nodes) nil))))
                (list :nodes (vconcat nodes)
                      :edges (vconcat
                              (cl-remove-if-not
                               (lambda (e)
                                 (and (gethash (plist-get e :from) keep)
                                      (gethash (plist-get e :to) keep)))
                               (append (plist-get full :edges) nil)))
                      :source (plist-get full :source))))))
    (setq cmacs-roamgraph--graph g
          cmacs-roamgraph--by-id (cmacs-roamgraph--index-graph g))
    (cmacs-roamgraph--recolor)
    (cmacs-roamgraph--apply-graph (if cmacs-roamgraph--3d 3 2))
    (message "%d notes%s"
             (length (plist-get g :nodes))
             (if tags (format " tagged %s" (string-join tags " + ")) ""))))

(defun cmacs-roamgraph--drop-orphans (g)
  "Return G without the notes that have no links at all."
  (let ((linked (make-hash-table :test #'equal)))
    (mapc (lambda (e)
            (puthash (plist-get e :from) t linked)
            (puthash (plist-get e :to) t linked))
          (append (plist-get g :edges) nil))
    (list :nodes (vconcat (cl-remove-if-not
                           (lambda (n) (gethash (plist-get n :id) linked))
                           (append (plist-get g :nodes) nil)))
          :edges (plist-get g :edges)
          :source (plist-get g :source))))

(defun cmacs-roamgraph-toggle-orphans ()
  "Show or hide the notes that have no links."
  (interactive)
  (setq cmacs-roamgraph-show-orphans (not cmacs-roamgraph-show-orphans))
  (cmacs-roamgraph--apply-filter)
  (message "Unlinked notes %s"
           (if cmacs-roamgraph-show-orphans "shown" "hidden")))

(defun cmacs-roamgraph-filter-tag ()
  "Restrict the view to notes carrying the chosen tags."
  (interactive)
  (let* ((all (let (out)
                (mapc (lambda (n)
                        (dolist (tg (plist-get n :tags))
                          (cl-pushnew tg out :test #'equal)))
                      (plist-get (or cmacs-roamgraph--full-graph
                                     cmacs-roamgraph--graph)
                                 :nodes))
                (sort out #'string<))))
    (unless all (user-error "No tags in this graph"))
    (setq cmacs-roamgraph--filter-tags
          (completing-read-multiple "Tags (comma separated): " all nil t))
    (cmacs-roamgraph--apply-filter)
    (when (fboundp 'cmacs-roamgraph--tags-render)
      (ignore-errors (cmacs-roamgraph--tags-render (current-buffer))))))

(defun cmacs-roamgraph-filter-clear ()
  "Drop the tag filter and any search highlight."
  (interactive)
  (let ((had (or cmacs-roamgraph--filter-tags cmacs-roamgraph--matches)))
    (setq cmacs-roamgraph--filter-tags nil)
    (when (fboundp 'cmacs-roamgraph-search-clear)
      (cmacs-roamgraph-search-clear))
    (when had (cmacs-roamgraph--apply-filter))
    (when (fboundp 'cmacs-roamgraph--tags-render)
      (ignore-errors (cmacs-roamgraph--tags-render (current-buffer))))
    (message "Filters cleared")))

(defun cmacs-roamgraph-filter-to-matches ()
  "Keep only the search matches and their immediate neighbours."
  (interactive)
  (unless (and cmacs-roamgraph--matches
               (> (length cmacs-roamgraph--matches) 0))
    (user-error "No search matches to filter to"))
  (let* ((full (or cmacs-roamgraph--full-graph cmacs-roamgraph--graph))
         (seed (append cmacs-roamgraph--matches nil))
         (keep (make-hash-table :test #'equal)))
    (dolist (id seed) (puthash id t keep))
    (mapc (lambda (e)
            (let ((a (plist-get e :from)) (b (plist-get e :to)))
              (when (member a seed) (puthash b t keep))
              (when (member b seed) (puthash a t keep))))
          (append (plist-get full :edges) nil))
    (setq cmacs-roamgraph--full-graph full
          cmacs-roamgraph--graph
          (list :nodes (vconcat (cl-remove-if-not
                                 (lambda (n) (gethash (plist-get n :id) keep))
                                 (append (plist-get full :nodes) nil)))
                :edges (vconcat (cl-remove-if-not
                                 (lambda (e)
                                   (and (gethash (plist-get e :from) keep)
                                        (gethash (plist-get e :to) keep)))
                                 (append (plist-get full :edges) nil)))
                :source (plist-get full :source))
          cmacs-roamgraph--by-id
          (cmacs-roamgraph--index-graph cmacs-roamgraph--graph))
    (when (fboundp 'cmacs-roamgraph-search-clear)
      (cmacs-roamgraph-search-clear))
    (cmacs-roamgraph--apply-graph (if cmacs-roamgraph--3d 3 2))
    (message "%d notes around %d matches"
             (length (plist-get cmacs-roamgraph--graph :nodes))
             (length seed))))

;;;; Colour schemes ---------------------------------------------------------

(defconst cmacs-roamgraph--color-modes '(para degree tag recency)
  "The colouring schemes `cmacs-roamgraph-cycle-color' walks through.")

(defun cmacs-roamgraph--heat (frac)
  "Return a 0xRRGGBBAA colour for FRAC in [0,1], cool to hot."
  (let* ((f (max 0.0 (min 1.0 frac)))
         (r (round (+ 60 (* 195 f))))
         (g (round (+ 90 (* 60 (- 1.0 (abs (- (* 2 f) 1.0)))))))
         (b (round (- 220 (* 170 f)))))
    (logior (ash r 24) (ash g 16) (ash b 8) 255)))

(defun cmacs-roamgraph--recolor ()
  "Recompute every node's :color for the active scheme."
  (let* ((nodes (plist-get cmacs-roamgraph--graph :nodes))
         (buf (current-buffer)))
    (pcase cmacs-roamgraph--color-by
      ('para
       (mapc (lambda (n)
               (plist-put n :color
                          (cmacs-roamgraph-db--color (plist-get n :group))))
             nodes))
      ('degree
       (let ((maxd 1))
         (mapc (lambda (n)
                 (setq maxd (max maxd (length (cmacs-roamgraph-neighbors
                                               buf (plist-get n :id) 'both)))))
               nodes)
         (mapc (lambda (n)
                 (plist-put n :color
                            (cmacs-roamgraph--heat
                             (/ (float (length (cmacs-roamgraph-neighbors
                                                buf (plist-get n :id) 'both)))
                                maxd))))
               nodes)))
      ('tag
       ;; Colour by first tag, hashed to a hue.  Unlike the PARA palette
       ;; there is no fixed vocabulary to assign colours from, so a hash
       ;; is the honest option -- stable per tag, meaningless across
       ;; sessions only if the tag itself changes.
       (mapc (lambda (n)
               (let ((tg (car (plist-get n :tags))))
                 (plist-put n :color
                            (if tg
                                (let* ((h (mod (sxhash-equal tg) 360))
                                       (c (cmacs-roamgraph--hsv h 0.55 0.90)))
                                  c)
                              #x707888FF))))
             nodes))
      ('recency
       (let* ((times (delq nil
                           (mapcar (lambda (n)
                                     (let ((f (plist-get n :file)))
                                       (and f (file-exists-p f)
                                            (float-time
                                             (file-attribute-modification-time
                                              (file-attributes f))))))
                                   nodes)))
              (lo (if times (apply #'min times) 0.0))
              (hi (if times (apply #'max times) 1.0))
              (span (max 1.0 (- hi lo))))
         (mapc (lambda (n)
                 (let* ((f (plist-get n :file))
                        (tm (and f (file-exists-p f)
                                 (float-time
                                  (file-attribute-modification-time
                                   (file-attributes f))))))
                   (plist-put n :color
                              (if tm
                                  (cmacs-roamgraph--heat (/ (- tm lo) span))
                                #x606870FF))))
               nodes))))))

(defun cmacs-roamgraph--hsv (h s v)
  "Return a 0xRRGGBBAA colour for hue H (degrees), S and V in [0,1]."
  (let* ((c (* v s))
         (x (* c (- 1.0 (abs (- (mod (/ h 60.0) 2.0) 1.0)))))
         (m (- v c))
         (seg (floor (/ (mod h 360) 60)))
         (rgb (pcase seg
                (0 (list c x 0.0)) (1 (list x c 0.0)) (2 (list 0.0 c x))
                (3 (list 0.0 x c)) (4 (list x 0.0 c)) (_ (list c 0.0 x)))))
    (logior (ash (round (* 255 (+ (nth 0 rgb) m))) 24)
            (ash (round (* 255 (+ (nth 1 rgb) m))) 16)
            (ash (round (* 255 (+ (nth 2 rgb) m))) 8)
            255)))

(defun cmacs-roamgraph-cycle-color ()
  "Cycle the node colouring: PARA bucket, degree, tag, recency."
  (interactive)
  (setq cmacs-roamgraph--color-by
        (or (cadr (memq cmacs-roamgraph--color-by
                        cmacs-roamgraph--color-modes))
            (car cmacs-roamgraph--color-modes)))
  (cmacs-roamgraph--recolor)
  ;; Colour lives on the node plists, so the scene has to be re-emitted
  ;; -- but the layout is preserved, so nothing moves.
  (cmacs-roamgraph-set-graph (current-buffer)
                             (plist-get cmacs-roamgraph--graph :nodes)
                             (plist-get cmacs-roamgraph--graph :edges)
                             (if cmacs-roamgraph--3d 3 2))
  (cmacs-roamgraph--configure-labels)
  (when cmacs-roamgraph--selected
    (cmacs-roamgraph--select cmacs-roamgraph--selected nil 'recolor))
  (message "Colour: %s" cmacs-roamgraph--color-by))

;;;; Legend -----------------------------------------------------------------

(defun cmacs-roamgraph-legend ()
  "Describe the colours, sizes and keys in a help buffer."
  (interactive)
  (let ((by cmacs-roamgraph--color-by)
        (g cmacs-roamgraph--graph))
    (with-help-window "*org-roam graph: legend*"
      (princ "org-roam graph\n==============\n\n")
      (princ (format "%d notes, %d links, source %s\n\n"
                     (length (plist-get g :nodes))
                     (length (plist-get g :edges))
                     (plist-get g :source)))
      (princ (format "Colour: %s\n" by))
      (when (eq by 'para)
        (princ "  amber   00_inbox        blue    01_projects\n")
        (princ "  green   02_areas        violet  02_areas/dailies\n")
        (princ "  yellow  03_resources    grey    04_archives\n"))
      (when (memq by '(degree recency))
        (princ "  blue = low / old      red = high / recent\n"))
      (princ "\nSize is the log of a note's link count, so hubs read bigger.\n")
      (princ "Notes with 12+ links stay labelled; the rest label on hover.\n")
      (princ "\nKeys\n----\n")
      (princ "  h j k l   nearest note in that screen direction\n")
      (princ "  ] [       follow a forward link / go back up\n")
      (princ "  < >       cycle the peer set    o  pick a link by name\n")
      (princ "  / n N     search, next, previous\n")
      (princ "  g /       jump to a note by name\n")
      (princ "  RET O     open the note / in another window\n")
      (princ "  e i T     nodes, inspector, tags panes    D  dashboard\n")
      (princ "  t c M-/   filter by tag / clear / keep search matches\n")
      (princ "  2 3 v     flat / 3D / toggle    C  cycle colour\n")
      (princ "  w a s d   move the view (right-drag does the same)\n")
      (princ "  0 f + -   fit / focus / zoom    .  pin\n")
      (princ "  g g  g r  refresh / re-root here    u  undo re-root\n"))))

;;;; Mode -----------------------------------------------------------------

(defvar cmacs-roamgraph-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Spatial tier.
    (define-key map "h" #'cmacs-roamgraph-move-left)
    (define-key map "j" #'cmacs-roamgraph-move-down)
    (define-key map "k" #'cmacs-roamgraph-move-up)
    (define-key map "l" #'cmacs-roamgraph-move-right)
    (define-key map (kbd "<left>")  #'cmacs-roamgraph-move-left)
    (define-key map (kbd "<down>")  #'cmacs-roamgraph-move-down)
    (define-key map (kbd "<up>")    #'cmacs-roamgraph-move-up)
    (define-key map (kbd "<right>") #'cmacs-roamgraph-move-right)
    ;; Topological tier.
    (define-key map "]" #'cmacs-roamgraph-descend)
    (define-key map "[" #'cmacs-roamgraph-ascend)
    (define-key map ">" #'cmacs-roamgraph-next-peer)
    (define-key map "<" #'cmacs-roamgraph-prev-peer)
    (define-key map (kbd "M-n") #'cmacs-roamgraph-next-peer)
    (define-key map (kbd "M-p") #'cmacs-roamgraph-prev-peer)
    (define-key map "o" #'cmacs-roamgraph-goto-link)
    ;; Visiting.
    (define-key map (kbd "RET") #'cmacs-roamgraph-visit)
    (define-key map "O" #'cmacs-roamgraph-visit-other-window)
    (define-key map "y" #'cmacs-roamgraph-copy-id-link)
    ;; Search.
    (define-key map "/" #'cmacs-roamgraph-search)
    (define-key map "n" #'cmacs-roamgraph-search-next)
    (define-key map "N" #'cmacs-roamgraph-search-prev)
    ;; View.
    (define-key map "2" #'cmacs-roamgraph-view-2d)
    (define-key map "3" #'cmacs-roamgraph-view-3d)
    (define-key map "v" #'cmacs-roamgraph-toggle-3d)
    (define-key map "f" #'cmacs-roamgraph-focus-selected)
    (define-key map "." #'cmacs-roamgraph-toggle-pin)
    (define-key map "0" #'cmacs-roamgraph-fit-view)
    (define-key map (kbd "<home>") #'cmacs-roamgraph-fit-view)
    (define-key map "+" #'cmacs-roamgraph-zoom-in)
    (define-key map "=" #'cmacs-roamgraph-zoom-in)
    (define-key map "-" #'cmacs-roamgraph-zoom-out)
    ;; `g' stays a PREFIX.  Binding it to a command would silently kill
    ;; g r / g / below.
    (define-key map "gg" #'cmacs-roamgraph-refresh)
    (define-key map "gr" #'cmacs-roamgraph-root-here)
    (define-key map "g/" #'cmacs-roamgraph-jump)
    ;; Shadow the parent mode's `u' and `^', which walk the FILESYSTEM.
    (define-key map "u" #'cmacs-roamgraph-root-back)
    (define-key map "^" #'cmacs-roamgraph-root-back)
    ;; Move the view.  WASD pans in both 2D and 3D, matching right-drag.
    (define-key map "w" #'cmacs-roamgraph-pan-up)
    (define-key map "a" #'cmacs-roamgraph-pan-left)
    (define-key map "s" #'cmacs-roamgraph-pan-down)
    (define-key map "d" #'cmacs-roamgraph-pan-right)
    ;; Panes.
    (define-key map "e" #'cmacs-roamgraph-nodes)
    (define-key map "i" #'cmacs-roamgraph-inspector)
    (define-key map "T" #'cmacs-roamgraph-tags)
    (define-key map "D" #'cmacs-roamgraph-dashboard)
    (define-key map "W" #'cmacs-roamgraph-close-panes)
    ;; Filtering and colour.
    (define-key map "t" #'cmacs-roamgraph-filter-tag)
    (define-key map "c" #'cmacs-roamgraph-filter-clear)
    (define-key map (kbd "M-/") #'cmacs-roamgraph-filter-to-matches)
    (define-key map "C" #'cmacs-roamgraph-cycle-color)
    (define-key map "z" #'cmacs-roamgraph-toggle-orphans)
    (define-key map "?" #'cmacs-roamgraph-legend)
    (define-key map (kbd "C-h m") #'cmacs-roamgraph-help)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `cmacs-roamgraph-mode'.")

;;;###autoload
(define-derived-mode cmacs-roamgraph-mode cmacs-libregnum-mode "RoamGraph"
  "Major mode for the org-roam knowledge-graph viewport.

Deriving from `cmacs-libregnum-mode' inherits the view attach, the
teardown, the Evil `C-w' handoff and `<escape>'.  Its keymap is the
parent of this one, so every key it binds that means something else
here is shadowed above -- in particular `h'/`j'/`k'/`l', and `u'/`^',
which in the parent walk the filesystem.

\\{cmacs-roamgraph-mode-map}"
  ;; Runtime require, not a top-level one: cmacs-roamgraph-search.el
  ;; requires this file, so the dependency has to be resolved after this
  ;; file has finished loading.
  (require 'cmacs-roamgraph-search)
  (require 'cmacs-roamgraph-panes)
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (setq-local mode-line-format
              '(" org-roam graph  "
                (:eval (if cmacs-roamgraph--3d "3D" "2D"))
                (:eval (cmacs-roamgraph--ml-counts))
                (:eval (cmacs-roamgraph--ml-filter))
                (:eval (cmacs-roamgraph--ml-search))
                (:eval (cmacs-roamgraph--ml-progress))
                "  [/]find [hjkl]select [wasd]move [RET]open [?]keys"))
  (add-hook 'kill-buffer-hook #'cmacs-roamgraph--on-kill nil t)
  (add-hook 'window-size-change-functions #'cmacs-roamgraph--on-size-change))

(defun cmacs-roamgraph--ml-counts ()
  "Mode-line fragment: how much graph is on screen."
  (if cmacs-roamgraph--graph
      (format "  %d notes / %d links"
              (length (plist-get cmacs-roamgraph--graph :nodes))
              (length (plist-get cmacs-roamgraph--graph :edges)))
    ""))

(defun cmacs-roamgraph--ml-filter ()
  "Mode-line fragment: the active tag filter and colour scheme."
  (concat
   (if cmacs-roamgraph--filter-tags
       (format "  tag:%s" (string-join cmacs-roamgraph--filter-tags "+"))
     "")
   (if (eq cmacs-roamgraph--color-by 'para)
       ""
     (format "  colour:%s" cmacs-roamgraph--color-by))))

(defun cmacs-roamgraph--ml-progress ()
  "Mode-line fragment: how far the layout has left to settle."
  (if (and cmacs-roamgraph--layout-timer
           (timerp cmacs-roamgraph--layout-timer))
      (format "  settling %d%%"
              (round (* 100 (cmacs-roamgraph-layout-progress
                             (current-buffer)))))
    ""))

(defun cmacs-roamgraph--ml-search ()
  "Mode-line fragment: the active search, if any."
  (if (and cmacs-roamgraph--matches (> (length cmacs-roamgraph--matches) 0))
      (format "  match %d/%d" (1+ cmacs-roamgraph--match-index)
              (length cmacs-roamgraph--matches))
    ""))

(defun cmacs-roamgraph-escape ()
  "Clear the search, else deselect, else return to Evil normal state."
  (interactive)
  (cond (cmacs-roamgraph--matches (cmacs-roamgraph-search-clear))
        (cmacs-roamgraph--selected (cmacs-roamgraph-deselect))
        ((fboundp 'evil-normal-state) (evil-normal-state))))

(defun cmacs-roamgraph-help ()
  "Describe the roamgraph keys."
  (interactive)
  (describe-mode))

;;;; Rooting --------------------------------------------------------------

(defun cmacs-roamgraph-root-here ()
  "Re-root the view on the selected node's neighbourhood."
  (interactive)
  (unless cmacs-roamgraph--selected (user-error "Nothing selected"))
  (push cmacs-roamgraph--root cmacs-roamgraph--root-history)
  (setq cmacs-roamgraph--root cmacs-roamgraph--selected)
  (cmacs-roamgraph-refresh))

(defun cmacs-roamgraph-root-back ()
  "Undo the last re-rooting."
  (interactive)
  (if (null cmacs-roamgraph--root-history)
      (message "Already at the full graph")
    (setq cmacs-roamgraph--root (pop cmacs-roamgraph--root-history))
    (cmacs-roamgraph-refresh)))

;;;; Entry points ----------------------------------------------------------

(defun cmacs-roamgraph--open (dims &optional root hops)
  "Open (or reuse) the graph buffer, in DIMS dimensions.
ROOT and HOPS restrict the view to a neighbourhood."
  (unless (and (fboundp 'cmacs-roamgraph-supported-p)
               (cmacs-roamgraph-supported-p))
    (user-error "cmacs-roamgraph not built; reconfigure with \
--with-cmacs-roamgraph"))
  (let ((buf (get-buffer-create cmacs-roamgraph-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-roamgraph-mode)
        (cmacs-roamgraph-mode))
      (let ((sz cmacs-roamgraph-default-size))
        (cmacs-roamgraph-attach buf (car sz) (cdr sz)))
      (setq cmacs-roamgraph--3d (= dims 3)
            cmacs-roamgraph--root root)
      (message "cmacs-roamgraph: reading…")
      (let ((g (cmacs-roamgraph-fetch)))
        (when root (setq g (cmacs-roamgraph-subgraph g root (or hops 2))))
        (setq cmacs-roamgraph--full-graph g)
        (cmacs-roamgraph--apply-filter)
        (message "cmacs-roamgraph: %d notes, %d links (%s)"
                 (length (plist-get g :nodes))
                 (length (plist-get g :edges))
                 (plist-get g :source))))
    ;; Reuse the current window rather than splitting.  The viewport is
    ;; a picture that wants all the room it can get, and a graph squeezed
    ;; into half a frame is not much of a map.
    (pop-to-buffer-same-window buf)
    (cmacs-roamgraph--fit-window-now buf)
    buf))

;;;###autoload
(defun cmacs-roamgraph ()
  "Show the org-roam knowledge graph, flat.
See `cmacs-roamgraph-3d' for the three-dimensional view."
  (interactive)
  (cmacs-roamgraph--open 2))

;;;###autoload
(defun cmacs-roamgraph-3d ()
  "Show the org-roam knowledge graph in three dimensions.
Drag to orbit, scroll to zoom."
  (interactive)
  (cmacs-roamgraph--open 3))

(defun cmacs-roamgraph--id-at-point ()
  "Return the org-roam id of the node at point, if any."
  (or (and (fboundp 'org-roam-id-at-point) (org-roam-id-at-point))
      (and (derived-mode-p 'org-mode)
           (fboundp 'org-entry-get)
           (or (org-entry-get (point) "ID" t)
               (save-excursion (goto-char (point-min))
                               (org-entry-get (point) "ID"))))))

;;;###autoload
(defun cmacs-roamgraph-here ()
  "Show the graph centred on the org-roam node at point."
  (interactive)
  (let ((id (cmacs-roamgraph--id-at-point)))
    (unless id (user-error "No org-roam node at point"))
    (cmacs-roamgraph--open 2 id 2)
    (with-current-buffer (cmacs-roamgraph--buffer)
      (cmacs-roamgraph--select id t 'here))))

;;;###autoload
(defun cmacs-roamgraph-local (&optional hops)
  "Show the HOPS-hop neighbourhood of the node at point (default 2)."
  (interactive "p")
  (let ((id (or (and (derived-mode-p 'cmacs-roamgraph-mode)
                     cmacs-roamgraph--selected)
                (cmacs-roamgraph--id-at-point))))
    (unless id (user-error "No org-roam node at point"))
    (cmacs-roamgraph--open (if cmacs-roamgraph--3d 3 2) id
                           (max 1 (or hops 2)))
    (with-current-buffer (cmacs-roamgraph--buffer)
      (cmacs-roamgraph--select id t 'local))))

;;;; Evil ------------------------------------------------------------------

;; Viewport buffers sit in Evil *emacs state* so single keys (h/j/k/l,
;; `/', digits) reach this mode's keymap instead of Evil's motions.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-roamgraph-mode 'emacs))
  (when (and (boundp 'evil-window-map) (keymapp evil-window-map))
    (define-key cmacs-roamgraph-mode-map (kbd "C-w") evil-window-map))
  (define-key cmacs-roamgraph-mode-map (kbd "<escape>")
              #'cmacs-roamgraph-escape))

(provide 'cmacs-roamgraph)

;;; cmacs-roamgraph.el ends here
