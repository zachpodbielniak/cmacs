;;; cmacs-secondbrain-nav.el --- keyboard navigation for the second brain -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Everything you can do with the mouse, done from the keyboard.  The
;; map was clickable long before it was navigable, which is a bad place
;; for an Emacs tool to stop: pointing at a node to find out what it is
;; does not compose with anything.
;;
;; Four tiers, cheapest gesture first, mirroring `cmacs-roamgraph' so
;; the two siblings feel like one tool:
;;
;;   h j k l   SPATIAL -- the nearest node in that screen direction.
;;             What you reach for when you can see where you want to be.
;;
;;   [ ] < >   TOPOLOGICAL -- walk links, and walk the department you
;;             are standing in.  What you reach for when you cannot.
;;
;;   ^ RET     HIERARCHICAL -- the ARMS tier, which roamgraph has no
;;             equivalent of: a node belongs to a department, which
;;             belongs to a ring.  `^' goes up it.
;;
;;   / n N J o SEARCH -- incremental highlight-in-place, match cycling,
;;             and two `completing-read' palettes (any node; a link of
;;             the selection).
;;
;; Two rules run through all of it.
;;
;; *Ids, never scene indices.*  Emission order churns on every rebuild
;; and a collapsed department is not emitted at all, so every piece of
;; state here keys on the id string.
;;
;; *Navigation reveals.*  The map opens collapsed, so most nodes you can
;; search for are not on screen.  Selecting one that is hidden would
;; silently do nothing -- so anything that jumps expands the ancestors
;; it needs first, then flies the camera.  A jump you cannot see is not
;; a jump.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-secondbrain)

(declare-function cmacs-secondbrain-inspector-render "cmacs-secondbrain-panes")

(defcustom cmacs-secondbrain-cone-degrees 50
  "Half-angle of the screen-space cone used by the spatial h/j/k/l keys.

Wider than roamgraph's because this map is laid out on rings: a
neighbour on the same band sits at an angle from you, not beside you,
so a narrow cone finds nothing and the key feels dead."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-search-style 'orderless
  "How `cmacs-secondbrain-find' matches what you type.

`literal'    plain substring
`regexp'     Emacs regexp
`orderless'  space-separated substrings, all of which must appear

`orderless' by default: paths are the haystack here, so \"proj api\"
finding 01_projects/api.org is the common case."
  :type '(choice (const literal) (const regexp) (const orderless))
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-keep-selection-visible t
  "When non-nil, a spatial move that leaves the viewport flies the camera.

A step with `h\='/`j\='/`k\='/`l\=' deliberately does NOT move the camera --
moving it on every step makes the whole map swim under you, and the
node you stepped to is normally right there already.  But the ring
layout is far bigger than the viewport, so a few steps in one direction
walk the selection off the edge, and from then on you are navigating
something you cannot see.

So the camera follows only when it has to: when the new selection is
outside the viewport (inset by `cmacs-secondbrain-edge-margin\=', so a
node hugging the edge counts as outside).  `f\=' always flies,
deliberately."
  :type 'boolean
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-edge-margin 48
  "Pixels of inset when deciding whether the selection is off-screen.

A node half-clipped by the edge is legible enough to prove it exists
and useless for seeing what it connects to, so it counts as off-screen."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-zoom-step 2.0
  "Wheel notches per press of `+\=' / `-\='.

Positive is closer.  Each notch scales the remaining distance to the
target by 0.9, so steps shrink as you approach and the target can never
be overshot."
  :type 'number
  :group 'cmacs-secondbrain)

(defvar-local cmacs-secondbrain--matches nil
  "Vector of matching ids from the last search, or nil.")
(defvar-local cmacs-secondbrain--match-index 0
  "Cursor into `cmacs-secondbrain--matches'.")
(defvar-local cmacs-secondbrain--haystacks nil
  "Vector of lowercased searchable text, parallel to `--haystack-ids'.")
(defvar-local cmacs-secondbrain--haystack-ids nil
  "Vector of ids parallel to `cmacs-secondbrain--haystacks'.")
(defvar-local cmacs-secondbrain--search-last nil
  "Last string matched, so an idle tick is not re-run for free.")
(defvar-local cmacs-secondbrain--search-saved nil
  "Selection to restore if an incremental search is aborted.")
(defvar-local cmacs-secondbrain--trail nil
  "Breadcrumb stack of ids for `]' / `['.")
(defvar-local cmacs-secondbrain--spatial-trail nil
  "Stack of (DIRECTION . FROM-ID) making spatial moves exactly reversible.")

;;;; Graph access -----------------------------------------------------

(defun cmacs-secondbrain--nav-nodes ()
  "Every node plist in the current buffer's graph."
  (append (plist-get cmacs-secondbrain--graph :nodes) nil))

(defun cmacs-secondbrain--nav-edges ()
  "Every edge plist in the current buffer's graph."
  (append (plist-get cmacs-secondbrain--graph :edges) nil))

(defun cmacs-secondbrain--nav-node (id)
  "The node plist for ID, from the Lisp-side graph."
  (and id (seq-find (lambda (n) (equal (plist-get n :id) id))
                    (cmacs-secondbrain--nav-nodes))))

(defun cmacs-secondbrain--nav-title (id)
  "A human label for ID."
  (or (plist-get (cmacs-secondbrain--nav-node id) :title) id "nothing"))

(defun cmacs-secondbrain--nav-parent (id)
  "ID's parent id, or nil."
  (plist-get (cmacs-secondbrain--nav-node id) :parent))

(defun cmacs-secondbrain--nav-children (id)
  "Ids parented to ID, in title order."
  (let (out)
    (dolist (n (cmacs-secondbrain--nav-nodes))
      (when (equal (plist-get n :parent) id)
        (push (plist-get n :id) out)))
    (cmacs-secondbrain--nav-sort (nreverse out))))

(defun cmacs-secondbrain--nav-sort (ids)
  "Sort IDS by title, so every walk is stable and alphabetical."
  (sort (copy-sequence ids)
        (lambda (a b) (string-lessp (cmacs-secondbrain--nav-title a)
                                    (cmacs-secondbrain--nav-title b)))))

(defun cmacs-secondbrain--nav-links (id)
  "Ids linked to ID by a graph edge, either direction, in title order.

Both directions on purpose: the hub->member edges point one way and the
org-roam links the other, and a reader walking connections does not care
which end the data happened to store first."
  (let (out)
    (dolist (e (cmacs-secondbrain--nav-edges))
      (let ((from (plist-get e :from)) (to (plist-get e :to)))
        (cond ((equal from id) (push to out))
              ((equal to id) (push from out)))))
    (cmacs-secondbrain--nav-sort (delete-dups (nreverse out)))))

(defun cmacs-secondbrain--nav-siblings (id)
  "The other children of ID's parent, including ID, in title order."
  (let ((parent (cmacs-secondbrain--nav-parent id)))
    (if parent
        (cmacs-secondbrain--nav-children parent)
      ;; A top-level node's peers are the other top-level nodes: the
      ;; department hubs.  Walking those IS walking the rings, which is
      ;; the most useful thing `<' and `>' can mean up there.
      (cmacs-secondbrain--nav-sort
       (delq nil (mapcar (lambda (n)
                           (and (null (plist-get n :parent))
                                (plist-get n :id)))
                         (cmacs-secondbrain--nav-nodes)))))))

;;;; Revealing --------------------------------------------------------

(defun cmacs-secondbrain--nav-reveal (id)
  "Expand whatever is hiding ID, so selecting it can actually show it.

The map opens collapsed, so most of what a search can find is not on
screen; selecting a hidden node sets no scene selection and draws no
halo, which reads as the key having done nothing at all.  Walks the
parent chain -- bounded, because a corrupt graph must not hang the
editor -- and expands each ancestor."
  (let ((chain nil)
        (cur (cmacs-secondbrain--nav-parent id))
        (guard 0))
    (while (and cur (< guard 64))
      (push cur chain)
      (setq cur (cmacs-secondbrain--nav-parent cur)
            guard (1+ guard)))
    ;; Outermost first: expanding a child of something still collapsed
    ;; would be undone by its parent's own state.
    (dolist (ancestor chain)
      (ignore-errors
        (cmacs-secondbrain-set-collapsed (current-buffer) ancestor nil 0)))
    chain))

(defun cmacs-secondbrain--nav-onscreen-p (id)
  "Non-nil when ID is currently inside the viewport, with a margin."
  (let ((idx (cmacs-secondbrain--nav-scene-index id)))
    (and idx
         (fboundp 'cmacs-libregnum-node-onscreen-p)
         (ignore-errors
           (cmacs-libregnum-node-onscreen-p
            (current-buffer) idx cmacs-secondbrain-edge-margin)))))

(defun cmacs-secondbrain--nav-goto (id &optional fly)
  "Reveal, select and report ID.  With FLY, bring the camera to it.

The single choke point for every keyboard move, so revealing can never
be forgotten by one of them."
  (when id
    (cmacs-secondbrain--nav-reveal id)
    (cmacs-secondbrain--select id)
    (when (and fly (fboundp 'cmacs-secondbrain-focus))
      (ignore-errors (cmacs-secondbrain-focus (current-buffer) id)))
    id))

;;;; Spatial tier -----------------------------------------------------

(defconst cmacs-secondbrain--nav-directions
  '((left . (-1.0 . 0.0)) (right . (1.0 . 0.0))
    (up . (0.0 . -1.0))   (down . (0.0 . 1.0)))
  "Screen-space unit vectors per direction; y grows downward.")

(defun cmacs-secondbrain--nav-opposite (dir)
  "The direction opposite DIR."
  (pcase dir ('left 'right) ('right 'left) ('up 'down) ('down 'up)))

(defun cmacs-secondbrain--nav-busiest ()
  "The id of the most-connected visible node -- a sane place to start."
  (let ((deg (make-hash-table :test #'equal))
        (best nil) (best-n -1))
    (dolist (e (cmacs-secondbrain--nav-edges))
      (dolist (end (list (plist-get e :from) (plist-get e :to)))
        (puthash end (1+ (gethash end deg 0)) deg)))
    (dolist (n (cmacs-secondbrain--nav-nodes))
      (let* ((id (plist-get n :id))
             (d (gethash id deg 0)))
        (when (> d best-n) (setq best id best-n d))))
    best))

(defun cmacs-secondbrain--nav-scene-index (id)
  "ID's current scene index, or nil when it is not on screen."
  (and id (fboundp 'cmacs-secondbrain-scene-index)
       (ignore-errors (cmacs-secondbrain-scene-index (current-buffer) id))))

(defun cmacs-secondbrain--nav-id-at (index)
  "The id string at scene INDEX, or nil."
  (and index (fboundp 'cmacs-secondbrain-node-id-at)
       (ignore-errors (cmacs-secondbrain-node-id-at (current-buffer) index))))

(defun cmacs-secondbrain--move-spatial (dir)
  "Select the nearest node in screen direction DIR from the selection."
  (let ((buf (current-buffer)))
    (if (not cmacs-secondbrain--selected)
        ;; Nothing selected: drop onto the busiest node rather than
        ;; refusing.  The first press of an arrow key should do
        ;; something, or the map reads as keyboard-dead.
        (cmacs-secondbrain--nav-goto (cmacs-secondbrain--nav-busiest) t)
      ;; Exact reversal.  A cone metric is not self-inverse, so going
      ;; back the way you came is replayed from a trail rather than
      ;; recomputed -- otherwise `l' then `h' lands somewhere new.
      (let ((top (car cmacs-secondbrain--spatial-trail)))
        (if (and top (eq dir (cmacs-secondbrain--nav-opposite (car top))))
            (progn (pop cmacs-secondbrain--spatial-trail)
                   (cmacs-secondbrain--nav-goto (cdr top)))
          (let* ((from (cmacs-secondbrain--nav-scene-index
                        cmacs-secondbrain--selected))
                 (v (cdr (assq dir cmacs-secondbrain--nav-directions)))
                 (hit (and from (fboundp 'cmacs-libregnum-nearest-in-direction)
                           (cmacs-libregnum-nearest-in-direction
                            buf from (car v) (cdr v)
                            cmacs-secondbrain-cone-degrees))))
            (if (not hit)
                (message "No node %s of here" dir)
              (let ((id (cmacs-secondbrain--nav-id-at hit)))
                (if (not id)
                    (message "No node %s of here" dir)
                  (push (cons dir cmacs-secondbrain--selected)
                        cmacs-secondbrain--spatial-trail)
                  ;; Do not fly by default: the step normally lands on
                  ;; something already visible, and moving the camera
                  ;; every time makes the map swim under you.  But a few
                  ;; steps in one direction walk off the edge of a ring
                  ;; layout far larger than the viewport, and navigating
                  ;; something you cannot see is useless -- so follow
                  ;; exactly when the new selection is not on screen.
                  (cmacs-secondbrain--nav-goto id)
                  (when (and cmacs-secondbrain-keep-selection-visible
                             (not (cmacs-secondbrain--nav-onscreen-p id)))
                    (ignore-errors
                      (cmacs-secondbrain-focus (current-buffer) id))))))))))))

(defun cmacs-secondbrain-move-left ()
  "Select the nearest node to the left."
  (interactive) (cmacs-secondbrain--move-spatial 'left))
(defun cmacs-secondbrain-move-right ()
  "Select the nearest node to the right."
  (interactive) (cmacs-secondbrain--move-spatial 'right))
(defun cmacs-secondbrain-move-up ()
  "Select the nearest node above."
  (interactive) (cmacs-secondbrain--move-spatial 'up))
(defun cmacs-secondbrain-move-down ()
  "Select the nearest node below."
  (interactive) (cmacs-secondbrain--move-spatial 'down))

;;;; Topological tier -------------------------------------------------

(defun cmacs-secondbrain-follow-link ()
  "Follow a link out of the selection, remembering where you came from."
  (interactive)
  (let* ((id cmacs-secondbrain--selected)
         (links (and id (cmacs-secondbrain--nav-links id)))
         ;; Do not immediately walk back the way we arrived: that turns
         ;; `]' `]' into a two-node oscillation on any pair.
         (fresh (or (cl-remove (car cmacs-secondbrain--trail) links
                               :test #'equal)
                    links)))
    (cond
     ((null id) (message "Nothing selected"))
     ((null links) (message "%s has no links"
                            (cmacs-secondbrain--nav-title id)))
     (t
      ;; Cap the trail: walking a cycle must not grow it forever.
      (when (> (length cmacs-secondbrain--trail) 512)
        (setq cmacs-secondbrain--trail
              (cl-subseq cmacs-secondbrain--trail 0 256)))
      (push id cmacs-secondbrain--trail)
      (cmacs-secondbrain--nav-goto (car fresh) t)))))

(defun cmacs-secondbrain-back ()
  "Go back the way you came, or to a link if there is no trail."
  (interactive)
  (let ((id cmacs-secondbrain--selected))
    (cond
     (cmacs-secondbrain--trail
      (cmacs-secondbrain--nav-goto (pop cmacs-secondbrain--trail) t))
     ((null id) (message "Nothing selected"))
     ((cmacs-secondbrain--nav-links id)
      (cmacs-secondbrain--nav-goto (car (cmacs-secondbrain--nav-links id)) t))
     (t (message "Nowhere to go back to")))))

(defun cmacs-secondbrain--cycle-sibling (delta)
  "Move DELTA places through the selection's sibling set, wrapping."
  (let* ((id cmacs-secondbrain--selected)
         (peers (and id (cmacs-secondbrain--nav-siblings id))))
    (cond
     ((null id) (message "Nothing selected"))
     ((or (null peers) (< (length peers) 2))
      (message "%s has no siblings" (cmacs-secondbrain--nav-title id)))
     (t
      (let* ((pos (or (cl-position id peers :test #'equal) 0))
             (next (nth (mod (+ pos delta) (length peers)) peers)))
        (cmacs-secondbrain--nav-goto next)
        (message "%s  (%d/%d in %s)"
                 (cmacs-secondbrain--nav-title next)
                 (1+ (mod (+ pos delta) (length peers)))
                 (length peers)
                 (or (cmacs-secondbrain--nav-title
                      (cmacs-secondbrain--nav-parent next))
                     "the rings")))))))

(defun cmacs-secondbrain-next-sibling ()
  "Select the next node in the same department."
  (interactive) (cmacs-secondbrain--cycle-sibling 1))
(defun cmacs-secondbrain-prev-sibling ()
  "Select the previous node in the same department."
  (interactive) (cmacs-secondbrain--cycle-sibling -1))

(defun cmacs-secondbrain-goto-link ()
  "Jump to one of the selection's links, chosen by name.
The answer for a hub with forty links, where cycling is hopeless."
  (interactive)
  (let* ((id cmacs-secondbrain--selected)
         (_ (unless id (user-error "Nothing selected")))
         (links (cmacs-secondbrain--nav-links id))
         (table (make-hash-table :test #'equal))
         (cands nil))
    (unless links
      (user-error "%s has no links" (cmacs-secondbrain--nav-title id)))
    (dolist (l links)
      (let ((label (cmacs-secondbrain--nav-label l)))
        (while (gethash label table) (setq label (concat label " ")))
        (puthash label l table)
        (push label cands)))
    (let ((pick (completing-read "Link: " (nreverse cands) nil t)))
      (push id cmacs-secondbrain--trail)
      (cmacs-secondbrain--nav-goto (gethash pick table) t))))

;;;; Hierarchical tier ------------------------------------------------

(defun cmacs-secondbrain-up ()
  "Select the department this node belongs to, then its ring."
  (interactive)
  (let* ((id cmacs-secondbrain--selected)
         (parent (and id (cmacs-secondbrain--nav-parent id))))
    (cond
     ((null id) (message "Nothing selected"))
     (parent (cmacs-secondbrain--nav-goto parent t))
     (t (message "%s is already a top-level node"
                 (cmacs-secondbrain--nav-title id))))))

(defun cmacs-secondbrain-down ()
  "Select the first member of the selected department, expanding it."
  (interactive)
  (let* ((id cmacs-secondbrain--selected)
         (kids (and id (cmacs-secondbrain--nav-children id))))
    (cond
     ((null id) (message "Nothing selected"))
     ((null kids) (message "%s holds nothing"
                           (cmacs-secondbrain--nav-title id)))
     (t
      (ignore-errors
        (cmacs-secondbrain-set-collapsed (current-buffer) id nil
                                         cmacs-secondbrain-transition-frames))
      (cmacs-secondbrain--animate)
      (cmacs-secondbrain--nav-goto (car kids) t)))))

;;;; Search -----------------------------------------------------------

(defun cmacs-secondbrain--nav-label (id)
  "A completion label for ID: title, kind and department."
  (let* ((n (cmacs-secondbrain--nav-node id))
         (dept (plist-get n :department))
         (kind (plist-get n :kind))
         (count (plist-get n :count)))
    (format "%s%s%s"
            (or (plist-get n :title) id)
            (if (and kind (not (eq kind 'file))) (format "  <%s>" kind) "")
            (cond (count (format "  (%s, %d)" (or dept "?") count))
                  (dept (format "  (%s)" dept))
                  (t "")))))

(defun cmacs-secondbrain--build-haystacks ()
  "Precompute the searchable text for every node.

Done once per rebuild, so a keystroke scans already-lowercased strings
rather than re-deriving every node's metadata.  With 4000 memory nodes
that is the difference between a search that keeps up with typing and
one that does not."
  (let* ((nodes (cmacs-secondbrain--nav-nodes))
         (n (length nodes))
         (hay (make-vector n ""))
         (ids (make-vector n nil))
         (i 0))
    (dolist (node nodes)
      (aset ids i (plist-get node :id))
      (aset hay i
            (downcase
             (mapconcat
              #'identity
              (delq nil (list (plist-get node :title)
                              (plist-get node :department)
                              (and (plist-get node :kind)
                                   (format "%s" (plist-get node :kind)))
                              (plist-get node :file)))
              " ")))
      (setq i (1+ i)))
    (setq cmacs-secondbrain--haystacks hay
          cmacs-secondbrain--haystack-ids ids)))

(defun cmacs-secondbrain--match-p (needle hay)
  "Return non-nil if NEEDLE matches HAY under the configured style."
  (pcase cmacs-secondbrain-search-style
    ('regexp (ignore-errors (string-match-p needle hay)))
    ('orderless (cl-every (lambda (w) (string-search w hay))
                          (split-string needle " " t)))
    (_ (string-search needle hay))))

(defun cmacs-secondbrain--matches-for (needle)
  "Return the vector of ids matching NEEDLE, ordered for cycling."
  (if (or (null needle) (string-empty-p needle))
      nil
    (unless cmacs-secondbrain--haystacks (cmacs-secondbrain--build-haystacks))
    (let ((needle (downcase needle))
          (hits nil))
      (dotimes (i (length cmacs-secondbrain--haystacks))
        (when (cmacs-secondbrain--match-p needle
                                          (aref cmacs-secondbrain--haystacks i))
          (push (aref cmacs-secondbrain--haystack-ids i) hits)))
      (vconcat (cmacs-secondbrain--nav-sort (nreverse hits))))))

(defun cmacs-secondbrain--apply-highlight ()
  "Push the current match set to the renderer.

Goes through `cmacs-secondbrain--flag-ids', the one place that decides
what a match looks like, so incremental search, semantic search and
similarity cannot drift apart."
  (ignore-errors
    (cmacs-secondbrain--flag-ids
     (and cmacs-secondbrain--matches
          (> (length cmacs-secondbrain--matches) 0)
          (append cmacs-secondbrain--matches nil)))))

(defun cmacs-secondbrain--search-tick ()
  "Re-match on what is currently typed in the minibuffer."
  (let ((s (minibuffer-contents-no-properties)))
    (unless (equal s cmacs-secondbrain--search-last)
      (setq cmacs-secondbrain--search-last s)
      (let ((buf (window-buffer (minibuffer-selected-window))))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (derived-mode-p 'cmacs-secondbrain-mode)
              (setq cmacs-secondbrain--matches
                    (cmacs-secondbrain--matches-for s)
                    cmacs-secondbrain--match-index 0)
              (cmacs-secondbrain--apply-highlight))))))))

(defvar cmacs-secondbrain-search-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m minibuffer-local-map)
    (define-key m (kbd "C-n") #'cmacs-secondbrain-search-next)
    (define-key m (kbd "C-p") #'cmacs-secondbrain-search-prev)
    (define-key m (kbd "M-n") #'cmacs-secondbrain-search-next)
    (define-key m (kbd "M-p") #'cmacs-secondbrain-search-prev)
    m)
  "Minibuffer keymap during `cmacs-secondbrain-find'.")

(defun cmacs-secondbrain-find ()
  "Search the map incrementally, highlighting every match in place.

Matches take the accent colour and the rest of the map dims, so you can
see whether your six hits are one cluster or scattered across four
rings -- which a completion list cannot tell you, and which is the
entire reason to have a visualiser.

\\<cmacs-secondbrain-search-map>\\[cmacs-secondbrain-search-next] and \\[cmacs-secondbrain-search-prev] walk the hits while you are still typing.
RET keeps the highlight, so `n' and `N' stay live in the viewport; C-g
clears it and restores the selection you started from."
  (interactive)
  (unless (derived-mode-p 'cmacs-secondbrain-mode)
    (user-error "Not in a second brain buffer"))
  (let ((buf (current-buffer))
        (ok nil))
    (setq cmacs-secondbrain--search-saved cmacs-secondbrain--selected
          cmacs-secondbrain--search-last nil)
    (cmacs-secondbrain--build-haystacks)
    (unwind-protect
        (progn
          (minibuffer-with-setup-hook
              (lambda ()
                (add-hook 'post-command-hook
                          #'cmacs-secondbrain--search-tick nil t))
            (read-from-minibuffer "Find: " nil cmacs-secondbrain-search-map))
          (setq ok t)
          ;; Hover highlighting reads this to know a deliberate question
          ;; is on screen, and must not silently answer a different one.
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq cmacs-secondbrain--search
                    (and cmacs-secondbrain--search-last
                         (not (string-empty-p cmacs-secondbrain--search-last))
                         cmacs-secondbrain--search-last))))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (if (and cmacs-secondbrain--matches
                       (> (length cmacs-secondbrain--matches) 0))
                  (progn
                    (setq cmacs-secondbrain--match-index 0)
                    (cmacs-secondbrain--nav-goto
                     (aref cmacs-secondbrain--matches 0) t)
                    (message "%d match%s -- n / N to walk them"
                             (length cmacs-secondbrain--matches)
                             (if (= 1 (length cmacs-secondbrain--matches))
                                 "" "es")))
                (message "No matches")))))
      (unless ok
        ;; Aborted: put everything back the way it was.
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (cmacs-secondbrain-search-clear)
            (when cmacs-secondbrain--search-saved
              (cmacs-secondbrain--nav-goto
               cmacs-secondbrain--search-saved))))))))

(defun cmacs-secondbrain-search-clear ()
  "Drop the search highlight."
  (interactive)
  (setq cmacs-secondbrain--matches nil
        cmacs-secondbrain--match-index 0
        cmacs-secondbrain--search-last nil
        cmacs-secondbrain--search nil)
  (cmacs-secondbrain--apply-highlight))

(defun cmacs-secondbrain--cycle-match (delta)
  "Move DELTA places through the match set, wrapping."
  (let ((buf (if (minibufferp)
                 (window-buffer (minibuffer-selected-window))
               (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (or (null cmacs-secondbrain--matches)
                (zerop (length cmacs-secondbrain--matches)))
            (message "No matches -- / to search")
          (setq cmacs-secondbrain--match-index
                (mod (+ cmacs-secondbrain--match-index delta)
                     (length cmacs-secondbrain--matches)))
          ;; A search jump SHOULD fly: you asked to be taken there.
          (cmacs-secondbrain--nav-goto
           (aref cmacs-secondbrain--matches cmacs-secondbrain--match-index) t)
          (message "%s  (%d/%d)"
                   (cmacs-secondbrain--nav-title
                    (aref cmacs-secondbrain--matches
                          cmacs-secondbrain--match-index))
                   (1+ cmacs-secondbrain--match-index)
                   (length cmacs-secondbrain--matches)))))))

(defun cmacs-secondbrain-search-next ()
  "Go to the next search match."
  (interactive) (cmacs-secondbrain--cycle-match 1))
(defun cmacs-secondbrain-search-prev ()
  "Go to the previous search match."
  (interactive) (cmacs-secondbrain--cycle-match -1))

(defun cmacs-secondbrain-jump ()
  "Jump to any node, chosen by name.

Goes through `completing-read', so vertico/orderless/marginalia apply
rather than a hand-rolled matcher -- and it searches the WHOLE map,
including departments that are still collapsed, expanding whatever is
needed to show you where you landed."
  (interactive)
  (unless (derived-mode-p 'cmacs-secondbrain-mode)
    (user-error "Not in a second brain buffer"))
  (let ((table (make-hash-table :test #'equal))
        (cands nil))
    (dolist (n (cmacs-secondbrain--nav-nodes))
      (let ((label (cmacs-secondbrain--nav-label (plist-get n :id))))
        ;; Titles repeat (every daily is a date); keep both.
        (while (gethash label table) (setq label (concat label " ")))
        (puthash label (plist-get n :id) table)
        (push label cands)))
    (unless cands (user-error "Nothing to jump to"))
    (let ((pick (completing-read "Go to: " (nreverse cands) nil t)))
      (cmacs-secondbrain--nav-goto (gethash pick table) t))))

(defun cmacs-secondbrain-reset-view ()
  "Clear the search, the ring filter and isolate mode in one key.

Four independent ways to narrow the map is three too many to unwind one
at a time, and a half-cleared map that still hides things is how you
end up believing a department is empty."
  (interactive)
  (cmacs-secondbrain-search-clear)
  (setq cmacs-secondbrain--ring-filter nil
        cmacs-secondbrain--isolate nil
        cmacs-secondbrain--trail nil
        cmacs-secondbrain--spatial-trail nil)
  (ignore-errors (cmacs-secondbrain-set-ring-filter (current-buffer) nil))
  (ignore-errors (cmacs-secondbrain-set-isolate (current-buffer) nil))
  (force-mode-line-update)
  (message "View reset"))

;;;; Camera -----------------------------------------------------------

(defun cmacs-secondbrain-recenter ()
  "Bring the camera to the selection and pivot around it.

The companion to the spatial keys, which deliberately leave the camera
alone: this is how you say \"take me to what I have selected\".  It also
re-aims the camera TARGET at the node, so orbiting and zooming from
here revolve around it rather than around wherever the view was last
centred."
  (interactive)
  (unless cmacs-secondbrain--selected (user-error "Nothing selected"))
  (cmacs-secondbrain--nav-reveal cmacs-secondbrain--selected)
  (unless (ignore-errors
            (cmacs-secondbrain-focus (current-buffer)
                                     cmacs-secondbrain--selected))
    (user-error "%s is not on screen to fly to"
                (cmacs-secondbrain--nav-title cmacs-secondbrain--selected))))

(define-obsolete-function-alias 'cmacs-secondbrain-fly-to-selected
  'cmacs-secondbrain-recenter "cmacs 32"
  "Renamed: it re-aims the camera target too, which `fly\=' did not say.")

(defun cmacs-secondbrain--zoom (amount)
  "Zoom the camera by AMOUNT wheel notches; positive is closer."
  (unless (and (fboundp 'cmacs-libregnum-zoom)
               (ignore-errors (cmacs-libregnum-zoom (current-buffer) amount)))
    (user-error "No viewport to zoom")))

(defun cmacs-secondbrain-zoom-in ()
  "Move the camera closer.

Toward the camera\'s current target -- so after `f\=' (or any move that
brought the camera to a node) this zooms in on that node rather than on
the middle of the map."
  (interactive)
  (cmacs-secondbrain--zoom cmacs-secondbrain-zoom-step))

(defun cmacs-secondbrain-zoom-out ()
  "Move the camera further away."
  (interactive)
  (cmacs-secondbrain--zoom (- cmacs-secondbrain-zoom-step)))

(defun cmacs-secondbrain-cycle-galaxy-tilt ()
  "Cycle the 3D warp through flat, gentle, default and steep.

Only does anything in `cmacs-secondbrain-3d\=': the flat view snaps every
node into the plane, so it says so rather than appearing to be broken."
  (interactive)
  (let* ((steps '(0.0 16.0 32.0 42.0))
         (cur (or cmacs-secondbrain-galaxy-tilt 0.0))
         (next (or (cadr (member (car (cl-member cur steps
                                                 :test (lambda (a b)
                                                         (< (abs (- a b))
                                                            0.01))))
                                 steps))
                   (car steps))))
    (setq-local cmacs-secondbrain-galaxy-tilt next)
    (ignore-errors
      (cmacs-secondbrain-set-galaxy-tilt
       (current-buffer) next cmacs-secondbrain-transition-frames))
    (cmacs-secondbrain--animate)
    (message "Galaxy tilt %.0f°%s" next
             (if cmacs-secondbrain--3d "" "  (flat view: no effect until v)"))))

;;;; Help -------------------------------------------------------------

(defun cmacs-secondbrain-help ()
  "Show every key, and how to read the map, in one buffer."
  (interactive)
  (let* ((g cmacs-secondbrain--graph)
         (nodes (length (plist-get g :nodes)))
         (edges (length (plist-get g :edges)))
         (shown (or (ignore-errors
                      (cmacs-secondbrain-visible-count (current-buffer)))
                    0)))
    (with-help-window "*second brain: keys*"
      (princ "The second brain\n================\n\n")
      (princ (format "%d nodes (%d on screen), %d links.\n" nodes shown edges))
      (princ (format "View: %s%s%s%s\n\n"
                     (if cmacs-secondbrain--3d "3D" "flat")
                     (if cmacs-secondbrain--ring-filter
                         (format ", ring filter %s"
                                 cmacs-secondbrain--ring-filter) "")
                     (if cmacs-secondbrain--isolate ", isolating" "")
                     (if cmacs-secondbrain-age-fade ", age fade" "")))

      (princ "Moving around\n-------------\n")
      (princ "  h j k l    nearest node left / down / up / right\n")
      (princ "  arrows     the same\n")
      (princ "  ]          follow a link out of the selection\n")
      (princ "  [          go back the way you came\n")
      (princ "  > <        next / previous node in this department\n")
      (princ "  M-n M-p    the same\n")
      (princ "  ^          up to the department this belongs to\n")
      (princ "  m          down into it (opens it, selects the first)\n")
      (princ "  o          jump to a link of the selection, by name\n")
      (princ "  J          jump to ANY node, by name\n\n")

      (princ "Finding things\n--------------\n")
      (princ "  /          incremental search; matches light, rest dims\n")
      (princ "  n N        next / previous match\n")
      (princ "  M-/        semantic search (embeddings)\n")
      (princ "  ~          find nodes similar to the selection\n")
      (princ "  z          reset: clear search, filter and isolate\n\n")

      (princ "Opening\n-------\n")
      (princ "  RET        open the node's file\n")
      (princ "  O          open it in another window\n")
      (princ "  y          copy its path\n")
      (princ "  i          inspector pane\n")
      (princ "  p          preview pane\n")
      (princ "  W          close the panes\n\n")

      (princ "Shaping the map\n---------------\n")
      (princ "  TAB        expand or collapse the selection\n")
      (princ "  e c        expand all / collapse all\n")
      (princ "  1 2 3 4    force / circle / hex / rings layout\n")
      (princ "  x          isolate the selection's neighbourhood\n")
      (princ "  F          cycle the ring filter\n")
      (princ "  a          age fade: colour Memory by staleness\n")
      (princ "  s S        spin the rings\n")
      (princ "  R          slow auto-rotation\n")
      (princ "  u U        unpin the selection / everything\n\n")

      (princ "Camera and looks\n----------------\n")
      (princ "  f          fly to the selection, and pivot around it\n")
      (princ "  + = -      zoom in / in / out, toward the camera target\n")
      (princ "  T          galaxy tilt: flat / gentle / default / steep\n")
      (princ "  0          frame the whole map\n")
      (princ "  v          flat / 3D\n")
      (princ "  b          background (wallpaper or screensaver)\n")
      (princ "  G          node glow\n")
      (princ "  P          particles\n")
      (princ "  H          hover department-highlighting\n")
      (princ "  g          re-read every source\n")
      (princ "  q          quit\n\n")

      (princ "Reading the map\n---------------\n")
      (princ "  Four rings, innermost out: Skills, Memory, Routines,\n")
      (princ "  Applications.  A department is a contiguous wedge, sized\n")
      (princ "  by how much it holds; its hub carries the count.\n\n")
      (princ "  sphere  a note or a department      gem     a skill\n")
      (princ "  prism   an application              ring    a routine\n\n")
      (princ "  Memory colours are PARA: amber inbox, blue projects,\n")
      (princ "  green areas, yellow resources, grey archives.\n\n")
      (princ "  Mouse: left-click selects, double-click flies, drag moves\n")
      (princ "  a node (and pins it), right-drag pans, wheel zooms.\n"))))

(provide 'cmacs-secondbrain-nav)

;;; cmacs-secondbrain-nav.el ends here
