;;; cmacs-media-menu.el --- Context-built right-click menus for the media editors  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The shared machinery behind the imgedit and vidstudio right-click
;; menus.  Neither editor writes a menu literal any more: a menu is a
;; FUNCTION OF THE CLICK CONTEXT.
;;
;; A click context is a plist describing what is under the pointer --
;; for imgedit the layer, the document pixel and the selection; for
;; vidstudio the clip, the track, the audio segment and the playhead.
;; Each editor keeps an abnormal hook, `cmacs-imgedit-context-menu-functions'
;; and `cmacs-vidstudio-context-menu-functions'; every function on it is
;; called with the context and returns a list of ITEMS.  The editors'
;; own sections are ordinary hook members, so anything else -- the AI
;; layers, a user's init file -- adds items exactly the way the editors
;; do, with `add-hook', and no menu code knows any of them by name.
;;
;; An ITEM is a plist, one of:
;;
;;   (:sep)                          a separator
;;   (:label L :command CMD ...)     run CMD with `call-interactively'
;;   (:label L :command CMD :args A) run (apply CMD A), no prompting
;;   (:label L :action FN ...)       run (FN CONTEXT)
;;   (:label L :items ITEMS ...)     a submenu; ITEMS may be a function
;;                                   of the context
;;
;; with these optional keys on any of them:
;;
;;   :enable V    nil greys the item out.  V may be a function of the
;;                context.  Default: enabled.
;;   :visible V   nil drops the item entirely.  Same shape as :enable.
;;   :id SYM      names a submenu so other providers can add to it...
;;   :in SYM      ...by giving their items `:in SYM'.  An item whose
;;                target never appears is appended at the top level, so
;;                a provider can never lose an entry by naming a submenu
;;                that a context happened to leave out.
;;   :help STR    tooltip (GTK); :keys STR  accelerator hint.
;;
;; :label may itself be a function of the context.  An empty submenu is
;; dropped rather than shown as a dead arrow.
;;
;; The result is an ordinary menu KEYMAP, which is what makes one
;; definition serve every display path:
;;
;;   pgtk     `x-popup-menu' renders it as a real GTK menu;
;;   --lrg    `cmacs-menu-popup-keymap' flattens it for the in-engine
;;            `lrg-popup-menu', honouring :enable/:visible, because
;;            `x-popup-menu' is a silent no-op on that backend;
;;   context-menu-mode
;;            `cmacs-media-menu-fill-context-menu' copies the same
;;            entries into the map `context-menu-map' builds, from a
;;            buffer-local `context-menu-functions' entry -- and the pop
;;            itself still goes through `cmacs-menu-open-context-menu',
;;            so it works under --lrg too.
;;
;; Every leaf is a closure that runs its item with the editor buffer
;; current and the click context bound to `cmacs-media-menu-context',
;; whichever buffer happened to be current when the menu was chosen
;; from (a side panel, a timer's buffer).
;;
;; Lazy Elisp: a provider that lives in a lazily-loaded file must not
;; decide its visibility with `fboundp' on that file's own functions --
;; that empties the menu on a fresh session, exactly when it is first
;; reached for.  Gate on the C DEFUN that says the subsystem is built
;; (e.g. `cmacs-ai-supported-p'), or on `locate-library'.  See the
;; imgedit/vidstudio AI layers for the pattern.

;;; Code:

(require 'cl-lib)
(require 'cmacs-menu)

(defgroup cmacs-media-menu nil
  "Right-click menus of the cmacs media editors."
  :group 'cmacs
  :prefix "cmacs-media-menu-")

(defcustom cmacs-media-menu-use-context-menu-mode t
  "Route the editors' mouse-3 through `context-menu-mode' when it is on.

Non-nil: with `context-menu-mode' enabled, a right-click builds the menu
through `context-menu-map', so anything on the buffer's
`context-menu-functions' contributes alongside the editor's own items.
nil: always pop the editor's menu directly.  With `context-menu-mode'
off the editor menu is popped directly either way."
  :type 'boolean
  :group 'cmacs-media-menu)

(defcustom cmacs-media-menu-include-global-context-items nil
  "Keep the global `context-menu-functions' in editor buffers.

The editors install their menu function buffer-locally on
`context-menu-functions'.  nil (the default) installs it alone, because
the stock global entries -- Undo, Cut, Copy, Select All -- act on the
Emacs buffer text, which in an image or video editor is a rendered
preview: they would sit next to the editor's own Undo and do something
different.  Non-nil keeps them (the `t' element of the local hook)."
  :type 'boolean
  :group 'cmacs-media-menu)

(defvar cmacs-media-menu-context nil
  "The click context of the menu item now running, or nil.
Dynamically bound around every item a media-editor menu runs, so a
command invoked from the menu can ask what was right-clicked.")

(defvar cmacs-media-menu--defer t
  "When non-nil, a chosen menu item runs from a 0-delay timer.
Items may prompt, pop windows or start a transient, none of which is
safe inside the modal loop the in-engine menu runs or inside a GTK
menu's own nested loop.  Tests bind this to nil to run synchronously.")

;;;; Item evaluation --------------------------------------------------

(defun cmacs-media-menu--value (value ctx)
  "VALUE, or (VALUE CTX) when VALUE is a function."
  (if (functionp value) (funcall value ctx) value))

(defun cmacs-media-menu--prop (item key ctx &optional default)
  "ITEM's KEY evaluated against CTX, or DEFAULT when ITEM lacks KEY."
  (if (plist-member item key)
      (cmacs-media-menu--value (plist-get item key) ctx)
    default))

(defun cmacs-media-menu-collect (hook ctx)
  "Concatenate the item lists every function on HOOK returns for CTX.

HOOK is run with `run-hook-wrapped', so buffer-local members and the
`t' global marker behave as for any hook.  A provider that signals costs
its own items, not the whole menu: the error is reported and the others
still contribute."
  (let ((items nil))
    (run-hook-wrapped
     hook
     (lambda (fn)
       (condition-case err
           (setq items (append items (copy-sequence (funcall fn ctx))))
         (error
          (message "cmacs-media-menu: %s failed: %s"
                   fn (error-message-string err))))
       nil))
    items))

;;;; Keymap construction ----------------------------------------------

(defun cmacs-media-menu-invoke (item ctx)
  "Run menu ITEM for click context CTX.

The editor buffer named by CTX's :buffer is made current and CTX is
bound to `cmacs-media-menu-context'.  :action functions get CTX;
:command commands are called interactively, or applied to :args."
  (let ((buffer (plist-get ctx :buffer))
        (cmacs-media-menu-context ctx))
    (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
      (let ((action (plist-get item :action))
            (command (plist-get item :command)))
        (cond
         (action (funcall action ctx))
         ((plist-member item :args) (apply command (plist-get item :args)))
         ((commandp command) (call-interactively command))
         (command (funcall command)))))))

(defun cmacs-media-menu--entry (item ctx invoker extra)
  "The keymap entry for ITEM under CTX, or nil to leave it out.
INVOKER runs a leaf; EXTRA is the table of `:in' items by submenu id."
  (cond
   ((plist-member item :sep) menu-bar-separator)
   ((not (cmacs-media-menu--prop item :visible ctx t)) nil)
   ((plist-member item :items)
    (let* ((label (format "%s" (cmacs-media-menu--prop item :label ctx "")))
           (id (plist-get item :id))
           (children (append (cmacs-media-menu--prop item :items ctx)
                             (and id (prog1 (gethash id extra)
                                       (remhash id extra)))))
           (sub (make-sparse-keymap label))
           (n (cmacs-media-menu--add-items sub children ctx invoker extra)))
      (when (> n 0)
        (if (cmacs-media-menu--prop item :enable ctx t)
            (list 'menu-item label sub)
          (list 'menu-item label sub :enable nil)))))
   (t
    (let* ((label (format "%s" (cmacs-media-menu--prop item :label ctx "")))
           (enabled (and (cmacs-media-menu--prop item :enable ctx t) t))
           (help (plist-get item :help))
           (keys (plist-get item :keys))
           (it item)
           (binding (lambda ()
                      (interactive)
                      (funcall invoker it ctx))))
      (append (list 'menu-item label binding :enable enabled)
              (and help (list :help help))
              (and keys (list :keys keys)))))))

(defun cmacs-media-menu--entries-raw (map)
  "Every binding of MAP, separators included (for key numbering)."
  (let ((out nil))
    (map-keymap (lambda (ev _def) (push ev out)) map)
    out))

(defun cmacs-media-menu--key (map i)
  "A key for the I-th entry of MAP that MAP does not already bind.
Keys only have to be distinct within one map; they are what the GTK
popup reports back, so they must never collide with an entry added
earlier (a second batch of items, the orphans)."
  (let ((key (intern (format "cmacs-mm-%d" i))))
    (while (lookup-key map (vector key))
      (setq i (1+ i)
            key (intern (format "cmacs-mm-%d" i))))
    key))

(defun cmacs-media-menu--add-items (map items ctx invoker extra)
  "Append ITEMS to MAP for CTX; return how many real entries were added.

Separators are collapsed the way `context-menu-map' collapses them: a
run of them becomes one, and none is kept at either end -- filtering by
context routinely leaves several in a row.  They do not count towards
the total, so a submenu holding nothing but separators is empty."
  (let ((entries nil) (n 0) (i (length (cmacs-media-menu--entries-raw map))))
    (dolist (item items)
      (let ((entry (cmacs-media-menu--entry item ctx invoker extra)))
        (cond
         ((null entry))
         ((equal entry menu-bar-separator)
          (when (and entries (not (equal (car entries) menu-bar-separator)))
            (push entry entries)))
         (t (push entry entries)
            (setq n (1+ n))))))
    (when (equal (car entries) menu-bar-separator)
      (pop entries))
    (dolist (entry (nreverse entries))
      (define-key-after map (vector (cmacs-media-menu--key map i)) entry)
      (setq i (1+ i)))
    n))

(defun cmacs-media-menu-keymap (title items ctx &optional invoker)
  "Build the menu keymap titled TITLE from ITEMS for click context CTX.

INVOKER (default `cmacs-media-menu-invoke') is called as (INVOKER ITEM
CTX) when a leaf is chosen.  Items carrying `:in ID' are moved into the
submenu whose `:id' is ID, or appended at the end when no such submenu
is built."
  (let ((invoker (or invoker #'cmacs-media-menu-invoke))
        (extra (make-hash-table :test 'eq))
        (top nil)
        (map (make-sparse-keymap title)))
    (dolist (item items)
      (let ((in (plist-get item :in)))
        (if in
            (puthash in (append (gethash in extra) (list item)) extra)
          (push item top))))
    (cmacs-media-menu--add-items map (nreverse top) ctx invoker extra)
    ;; Orphans: their submenu never appeared in this context.
    (let ((orphans nil))
      (maphash (lambda (_id its) (setq orphans (append orphans its))) extra)
      (when orphans
        (clrhash extra)
        (cmacs-media-menu--add-items
         map (mapcar (lambda (it) (cl-loop for (k v) on it by #'cddr
                                           unless (eq k :in)
                                           append (list k v)))
                     orphans)
         ctx invoker extra)))
    map))

;;;; Inspection (tests, and code that drives a menu programmatically) --

(defun cmacs-media-menu--entries (keymap)
  "List (LABEL . DEF) for every non-separator menu-item in KEYMAP."
  (let ((out nil))
    (map-keymap
     (lambda (_ev def)
       (when (and (consp def) (eq (car def) 'menu-item)
                  (stringp (nth 1 def))
                  (not (string-prefix-p "--" (nth 1 def))))
         (push (cons (nth 1 def) def) out)))
     keymap)
    (nreverse out)))

(defun cmacs-media-menu-labels (keymap)
  "The labels of KEYMAP's top-level entries, in display order."
  (mapcar #'car (cmacs-media-menu--entries keymap)))

(defun cmacs-media-menu-lookup (keymap &rest path)
  "Find the entry at PATH (a list of labels) in menu KEYMAP.
Returns a plist (:binding B :enabled E :submenu S), or nil when PATH
does not exist.  B is the leaf closure (call it to run the item), S the
submenu keymap."
  (let ((map keymap) (found nil))
    (while (and path map)
      (let ((def (cdr (assoc (car path) (cmacs-media-menu--entries map)))))
        (setq path (cdr path))
        (cond
         ((null def) (setq map nil found nil))
         (t
          (let* ((real (nth 2 def))
                 (props (nthcdr 3 def))
                 (enabled (if (plist-member props :enable)
                              (eval (plist-get props :enable) t)
                            t)))
            (setq found (list :binding (and (functionp real) real)
                              :enabled (and enabled t)
                              :submenu (and (keymapp real) real)))
            (setq map (and (keymapp real) real)))))))
    (and (null path) found)))

;;;; Popping ----------------------------------------------------------

(defun cmacs-media-menu-position (&optional window)
  "An `x-popup-menu' position near the top-left of WINDOW's text area.
For menus opened from the keyboard, which have no click to anchor to.
Frame-relative, so the --lrg path (which reads frame pixels) agrees."
  (let* ((win (or window (selected-window)))
         (edges (window-inside-pixel-edges win)))
    (list (list (+ (nth 0 edges) 24) (+ (nth 1 edges) 24))
          (window-frame win))))

(defun cmacs-media-menu--run (binding)
  "Run the chosen BINDING, from the command loop unless told otherwise."
  (if cmacs-media-menu--defer
      (run-at-time 0 nil (lambda () (call-interactively binding)))
    (call-interactively binding)))

(defun cmacs-media-menu-open (keymap position)
  "Pop menu KEYMAP at POSITION and run whatever is chosen.
POSITION is an event or an `x-popup-menu' position.  The pop goes
through `cmacs-menu-popup-keymap', so it is a GTK menu under pgtk and
the in-engine menu under --lrg.  Returns the chosen binding, or nil."
  (let ((binding (cmacs-menu-popup-keymap keymap position)))
    (when binding
      (cmacs-media-menu--run binding))
    binding))

(defun cmacs-media-menu-via-context-menu-mode-p ()
  "Non-nil when a right-click should go through `context-menu-mode'."
  (and cmacs-media-menu-use-context-menu-mode
       (bound-and-true-p context-menu-mode)))

(defun cmacs-media-menu-fill-context-menu (menu keymap)
  "Copy KEYMAP's entries onto the end of the context MENU; return MENU.
For `context-menu-functions', which hand each function the map built so
far and expect it back."
  (map-keymap (lambda (ev def)
                (unless (stringp def)        ; skip a keymap title
                  (define-key-after menu (vector ev) def)))
              keymap)
  menu)

(defun cmacs-media-menu-install-context-function (fn)
  "Install FN as the buffer-local `context-menu-functions'.
See `cmacs-media-menu-include-global-context-items' for whether the
global entries are kept."
  (setq-local context-menu-functions
              (if cmacs-media-menu-include-global-context-items
                  (list fn t)
                (list fn))))

(defvar cmacs-media-menu--override nil
  "A click context to use instead of reading one off the click.

Bound by `cmacs-media-menu-show' around the `context-menu-map' build.
The context was already computed -- from a viewport pixel the C layer
reported, a keyboard request, or a panel row -- and the click that
`context-menu-map' passes on is a stand-in synthesised for positioning,
which says nothing true about what is under the pointer.")

(defun cmacs-media-menu-context-for (editor click reader)
  "The click context for EDITOR's menu at CLICK.
`cmacs-media-menu--override' when it is EDITOR's, else (READER CLICK)."
  (if (and cmacs-media-menu--override
           (eq (plist-get cmacs-media-menu--override :editor) editor))
      cmacs-media-menu--override
    (ignore-errors (funcall reader click))))

(defun cmacs-media-menu--as-event (position)
  "A mouse-3 event standing in for POSITION.
POSITION is an event (returned as-is) or an `x-popup-menu' position
\((X Y) FRAME-OR-WINDOW)."
  (cond
   ((and (consp position) (symbolp (car position))) position)
   ((and (consp position) (consp (car position)))
    (let* ((xy (car position))
           (where (cadr position))
           (posn (ignore-errors (posn-at-x-y (car xy) (cadr xy) where))))
      ;; Off every window (or no display) posn-at-x-y names the frame
      ;; itself, which `context-menu-map' cannot select: fall back to
      ;; point in the selected window.
      (list 'mouse-3 (if (and posn (window-live-p (posn-window posn)))
                         posn
                       (posn-at-point)))))
   (t (list 'mouse-3 (posn-at-point)))))

(defun cmacs-media-menu-show (ctx keymap-fn position)
  "Show the menu for click context CTX at POSITION and run the choice.

KEYMAP-FN builds the menu keymap from CTX.  With `context-menu-mode' on
\(see `cmacs-media-menu-use-context-menu-mode') the menu is built by
`context-menu-map' -- so everything on the buffer's
`context-menu-functions' contributes -- with CTX passed through
`cmacs-media-menu--override', and popped by
`cmacs-menu-open-context-menu', which also works under --lrg.
Otherwise KEYMAP-FN's menu is popped directly.  POSITION is an event or
an `x-popup-menu' position."
  (if (cmacs-media-menu-via-context-menu-mode-p)
      (let ((cmacs-media-menu--override ctx))
        (cmacs-menu-open-context-menu (cmacs-media-menu--as-event position)))
    (cmacs-media-menu-open (funcall keymap-fn ctx) position)))

(provide 'cmacs-media-menu)

;;; cmacs-media-menu.el ends here
