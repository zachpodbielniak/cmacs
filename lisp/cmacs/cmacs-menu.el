;;; cmacs-menu.el --- Portable popup menus across display backends  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One place that knows how to pop a menu, whatever cmacs is being
;; displayed through.  cmacs has three display backends that answer
;; "show me a popup menu" in three incompatible ways:
;;
;;   pgtk / x / ns   `x-popup-menu' renders a real native menu.  Under
;;                   pgtk -- the build everyone actually runs -- that is
;;                   a GTK menu, which is what we want.
;;
;;   lrg             `output_lrg' (`emacs --lrg') has no toolkit at all.
;;                   Its RIF `menu_show_hook' deliberately returns "no
;;                   selection" (see `lrg_menu_show' in
;;                   cmacs/lrgterm/cmacs-lrgterm.c), so `x-popup-menu'
;;                   -- and therefore `context-menu-mode' -- silently
;;                   does NOTHING there.  The backend instead draws its
;;                   own cascading menu in the engine, exposed as
;;                   `lrg-popup-menu', which takes a nested item tree
;;                   and returns the chosen leaf's index.
;;
;;   tty             `x-popup-menu' works (Emacs draws a text menu), but
;;                   only when `display-popup-menus-p' says so; otherwise
;;                   we fall back to `tmm-prompt'.
;;
;; Callers should never branch on any of that.  Use:
;;
;;   `cmacs-menu-popup'         -- alist-style menu, returns the VALUE
;;   `cmacs-menu-popup-keymap'  -- keymap menu, returns the BINDING
;;
;; and the right thing happens on every backend.  These are the only
;; functions in cmacs allowed to call `x-popup-menu' directly; a test in
;; test/cmacs/cmacs-brigade-tests.el enforces that for brigade Elisp, and
;; cmacs-ai-menu.el follows the same rule.
;;
;; The flattening code here was previously private to cmacs-libregnum.el.
;; It lives here now because it is needed by subsystems (cmacs-ai,
;; ai-brigade) that must work in a build configured WITHOUT
;; --with-cmacs-libregnum.  cmacs-libregnum.el keeps its public names as
;; thin delegations, so its callers and tests are unaffected.

;;; Code:

(require 'seq)

;; Provided by the lrg display backend (cmacs/lrgterm/), which is only
;; linked in a --with-cmacs-lrgterm build.  Every use is fboundp-guarded.
(declare-function lrg-popup-menu "cmacs-lrgterm.c" (items &optional x y))

;;;; Backend detection -------------------------------------------------

(defun cmacs-menu-lrg-frame-p (&optional frame)
  "Non-nil when FRAME (default: the selected frame) is an --lrg frame.
The libregnum/raylib display backend has no native menus, so menus must
be drawn in-engine there."
  (eq (framep (or frame (selected-frame))) 'lrg))

(defun cmacs-menu-native-p (&optional frame)
  "Non-nil when FRAME can render a native (GTK, or tty text) popup menu.

False for --lrg frames, whose `menu_show_hook' is a no-op, and for a tty
that cannot draw menus at all.

The `display-popup-menus-p' check is deliberately restricted to ttys.  It
returns nil in batch, where there is no real frame, and applying it to
every frame type would push graphical frames onto the completion fallback
whenever the predicate is merely uninformative rather than actually
saying \"no menus here\"."
  (let ((frame (or frame (selected-frame))))
    (and (not (cmacs-menu-lrg-frame-p frame))
         (or (not (eq (framep frame) t))     ; not a tty: x-popup-menu is fine
             (display-popup-menus-p frame)))))

;;;; Menu flattening ---------------------------------------------------
;;
;; `lrg-popup-menu' takes a NESTED item tree.  Each node is one of:
;;
;;   nil                  a separator row
;;   (LABEL . INDEX)      a selectable leaf returning the fixnum INDEX
;;   (LABEL) / (LABEL)    a disabled leaf
;;   (LABEL ITEM...)      a submenu whose children are ITEM...
;;
;; A parallel VALUES vector maps each leaf's INDEX back to its Lisp
;; value, so the chosen index round-trips to the value regardless of how
;; deeply nested it was.

(defun cmacs-menu-collapse-separators (tree)
  "Return TREE with runs of separators collapsed to one, and edges trimmed.
Filtering items out by context routinely leaves several separators in a
row (everything between them was dropped), and a leading or trailing
separator is pure wasted space.  Recurses into submenus."
  (let ((out nil) (prev-sep t))          ; prev-sep t => drop leading separators
    (dolist (node tree)
      (if (null node)                    ; separator
          (progn (unless prev-sep (push nil out))
                 (setq prev-sep t))
        (push (if (and (consp node) (consp (cdr node)))   ; submenu -> recurse
                  (cons (car node)
                        (cmacs-menu-collapse-separators (cdr node)))
                node)
              out)
        (setq prev-sep nil)))
    (when (and out (null (car out)))     ; drop a trailing separator
      (pop out))
    (nreverse out)))

(defun cmacs-menu-alist-to-tree (menu)
  "Flatten an alist-form `x-popup-menu' MENU into (TREE . VALUES).
MENU is (TITLE (PANE-TITLE ITEM...) ...); ITEM is (LABEL . VALUE) or a
\"--\" separator.  Panes are joined with separator rows (their titles are
dropped -- the in-engine menu has no pane headers).  TREE is the
`lrg-popup-menu' item tree; VALUES is a vector indexed by leaf INDEX."
  (let ((panes (cdr menu)) (items nil) (values nil) (idx 0) (first t))
    (dolist (pane panes)
      (when (consp pane)
        (unless first (push nil items))  ; separator between panes
        (setq first nil)
        (dolist (e (cdr pane))
          (cond
           ;; Emacs menu convention: a label starting "--" is a separator.
           ((and (consp e) (stringp (car e))
                 (not (string-prefix-p "--" (car e))))     ; (LABEL . VALUE)
            (push (cons (car e) idx) items)
            (push (cdr e) values)
            (setq idx (1+ idx)))
           (t (push nil items))))))      ; "--" / string / nil separator
    (cons (cmacs-menu-collapse-separators (nreverse items))
          (vconcat (nreverse values)))))

(defun cmacs-menu--keymap-walk (keymap start-idx)
  "Walk menu KEYMAP into (TREE NEXT-IDX . VALUES-REVERSED).
Leaves are numbered from START-IDX; VALUES-REVERSED lists the leaf values
in descending-index order.  Nested keymaps become real submenu nodes.

A `menu-item' whose :visible form evaluates to nil is dropped, and one
whose :enable form evaluates to nil becomes a disabled leaf, so the
in-engine menu honours the same item properties the GTK menu does."
  (let ((items nil) (idx start-idx) (values nil))
    (map-keymap
     (lambda (_event def)
       (let (label real (enabled t) (visible t))
         (cond
          ((and (consp def) (eq (car def) 'menu-item))
           (setq label (nth 1 def) real (nth 2 def))
           (let ((props (nthcdr 3 def)))
             (when (plist-member props :visible)
               (setq visible (ignore-errors
                               (eval (plist-get props :visible) t))))
             (when (plist-member props :enable)
               (setq enabled (ignore-errors
                               (eval (plist-get props :enable) t))))))
          ((and (consp def) (stringp (car def)))    ; (LABEL [HELP] . REAL)
           (setq label (car def)
                 real (if (and (consp (cdr def)) (stringp (cadr def)))
                          (cddr def) (cdr def)))))
         (cond
          ((not visible) nil)                       ; dropped entirely
          ((or (null label)                         ; separator / unknown
               (and (stringp label) (string-prefix-p "--" label)))
           (push nil items))
          ((keymapp real)                           ; submenu -> real node
           (let ((sub (cmacs-menu--keymap-walk real idx)))
             ;; A submenu that filtered down to nothing is noise.
             (when (nth 0 sub)
               (push (cons (format "%s" label) (nth 0 sub)) items)
               (setq idx (nth 1 sub))
               (setq values (append (cddr sub) values)))))
          ((not enabled)                            ; disabled leaf
           (push (list (format "%s" label)) items))
          ((functionp real)                         ; leaf
           (push (cons (format "%s" label) idx) items)
           (push real values)
           (setq idx (1+ idx)))
          (t (push nil items)))))                   ; unknown -> separator
     keymap)
    (cons (nreverse items) (cons idx values))))

(defun cmacs-menu-keymap-to-tree (keymap)
  "Flatten a menu KEYMAP into (TREE . VALUES) for `lrg-popup-menu'.
Submenus (nested keymaps) become real submenu nodes; VALUES maps each
leaf INDEX to its binding."
  (let ((r (cmacs-menu--keymap-walk keymap 0)))
    (cons (cmacs-menu-collapse-separators (nth 0 r))
          (vconcat (nreverse (cddr r))))))

;;;; Position ----------------------------------------------------------

(defun cmacs-menu-xy (position)
  "Return (X . Y) frame pixels from an `x-popup-menu' POSITION.
POSITION `t' (current mouse position), a click event, and anything else
we cannot resolve yield (nil . nil), which makes `lrg-popup-menu' fall
back to the current pointer position -- the right answer for a menu
opened by a click."
  (cond
   ;; ((X Y) WINDOW-OR-FRAME)
   ((and (consp position) (consp (car position)))
    (cons (car (car position)) (car (cdr (car position)))))
   ;; A mouse event: take the frame-relative pixel position of the click.
   ((and (consp position) (symbolp (car position))
         (consp (cdr position)))
    (let ((xy (ignore-errors (posn-x-y (event-start position))))
          (edges (ignore-errors
                   (window-inside-pixel-edges
                    (posn-window (event-start position))))))
      (if (and xy edges)
          (cons (+ (car xy) (nth 0 edges))
                (+ (cdr xy) (nth 1 edges)))
        (cons nil nil))))
   (t (cons nil nil))))

;;;; Public entry points -----------------------------------------------

(defun cmacs-menu-popup (position menu)
  "Show alist-style MENU at POSITION and return the chosen value.

MENU is (TITLE (PANE-TITLE (LABEL . VALUE) ...) ...), the same shape
`x-popup-menu' accepts.  On a native frame this pops a real GTK (or tty)
menu; under --lrg it draws the in-engine `lrg-popup-menu' instead.  Both
paths return the chosen VALUE, so callers need no backend awareness.
Returns nil if the menu was dismissed."
  (cond
   ((cmacs-menu-lrg-frame-p)
    (if (not (fboundp 'lrg-popup-menu))
        ;; An lrg frame without the primitive should be impossible (the
        ;; frame type comes from the same build), but a menu is never
        ;; worth an error: degrade to the keyboard picker.
        (cmacs-menu--tmm-alist menu)
      (let* ((flat (cmacs-menu-alist-to-tree menu))
             (xy   (cmacs-menu-xy position))
             (idx  (lrg-popup-menu (car flat) (car xy) (cdr xy))))
        (and idx (aref (cdr flat) idx)))))
   ((cmacs-menu-native-p) (x-popup-menu position menu))
   (t (cmacs-menu--tmm-alist menu))))

(defun cmacs-menu-popup-keymap (keymap &optional position)
  "Show menu KEYMAP at POSITION and return the chosen BINDING (or nil).

The counterpart to `cmacs-menu-popup' for keymap menus -- the form
`context-menu-map' produces.  Returns the binding itself rather than an
event path, because the three backends disagree about what they return
and every caller wants the same thing: something to `funcall'.

POSITION defaults to t (the current mouse position)."
  (let ((position (or position t)))
    (cond
     ((cmacs-menu-lrg-frame-p)
      (if (not (fboundp 'lrg-popup-menu))
          (cmacs-menu--tmm-keymap keymap)
        (let* ((flat (cmacs-menu-keymap-to-tree keymap))
               (xy   (cmacs-menu-xy position))
               (idx  (lrg-popup-menu (car flat) (car xy) (cdr xy)))
               (b    (and idx (aref (cdr flat) idx))))
          (and (functionp b) b))))
     ((cmacs-menu-native-p)
      (let ((choice (x-popup-menu position keymap)))
        (cond
         ;; Native popups return the chosen leaf's event path.
         ((and choice (listp choice))
          (let ((b (lookup-key keymap (apply #'vector choice))))
            (and (functionp b) b)))
         ((functionp choice) choice))))
     (t (cmacs-menu--tmm-keymap keymap)))))

;;;; Keyboard fallback -------------------------------------------------
;;
;; `tmm-prompt' builds a menu in the minibuffer from a keymap.  It is the
;; last resort: a tty that cannot draw popup menus, or (defensively) an
;; lrg frame in a build without the in-engine primitive.  Because it is
;; also the path a keyboard user takes deliberately, it must return a
;; binding rather than run it -- hence the NO-EXECUTE argument.

(declare-function tmm-prompt "tmm" (menu &optional in-popup default-item
                                          no-execute path))

(defun cmacs-menu--tmm-keymap (keymap)
  "Pick from menu KEYMAP with `tmm-prompt'; return the binding or nil."
  (require 'tmm)
  (let ((b (tmm-prompt keymap nil nil t)))
    (and (functionp b) b)))

(defun cmacs-menu--tmm-alist (menu)
  "Pick from alist-style MENU with `completing-read'; return the value.
`tmm-prompt' wants a keymap, so for the alist form we do the simpler
thing directly rather than synthesise one."
  (let ((choices nil))
    (dolist (pane (cdr menu))
      (when (consp pane)
        (dolist (e (cdr pane))
          (when (and (consp e) (stringp (car e))
                     (not (string-prefix-p "--" (car e))))
            (push (cons (car e) (cdr e)) choices)))))
    (setq choices (nreverse choices))
    (when choices
      (let ((pick (completing-read (format "%s: " (or (car menu) "Menu"))
                                   (mapcar #'car choices) nil t)))
        (cdr (assoc pick choices))))))

;;;; Opening the context menu ------------------------------------------
;;
;; `context-menu-mode' binds mouse-3 to `context-menu-map', which Emacs
;; resolves through `x-popup-menu' -- so under --lrg, where that hook
;; deliberately returns nothing, the entire context menu is dead: not
;; only cmacs's entries but every package's.  This command is the
;; portable replacement.  It builds the very same menu (so everything on
;; `context-menu-functions' still contributes, in the usual order) and
;; pops it through the routing above.

(defun cmacs-menu-open-context-menu (&optional event)
  "Open the context menu for EVENT (default: point) and run the choice.

The backend-portable equivalent of the stock mouse-3 binding.  Bind this
instead of `context-menu-map' if you want right-click to work under
`emacs --lrg' as well as under pgtk."
  (interactive "e")
  (require 'mouse)
  (let* ((event (or event (list 'mouse-3 (posn-at-point))))
         (map (context-menu-map event))
         (binding (if (commandp map) map (cmacs-menu-popup-keymap map event))))
    (when binding
      ;; Deferred to the command loop: the chosen item may prompt, pop a
      ;; window, or start a transient, none of which is safe inside the
      ;; modal loop the in-engine menu runs, or inside a GTK menu's own
      ;; nested loop.
      (run-at-time 0 nil (lambda () (call-interactively binding))))))

(declare-function context-menu-map "mouse" (&optional click))

;;;; mouse-3 ownership -------------------------------------------------
;;
;; `context-menu-mode' installs a remap that normally wins, but a config
;; that predates it -- Doom, most visibly -- binds mouse-3 in `global-map'
;; to `mouse-save-then-kill', which is looked up first and silently eats
;; every context-menu entry cmacs adds.  Both cmacs-ai-menu and
;; cmacs-piper hit this, so the detection lives here rather than being
;; written twice with two different opinions.

(defcustom cmacs-menu-override-mouse-3 t
  "When non-nil, `cmacs-menu-claim-mouse-3' may rebind mouse-3 globally.

Set to nil to keep whatever binding you already have.  cmacs context
menus are then reachable only from the keyboard."
  :type 'boolean
  :group 'cmacs
  :safe #'booleanp)

(defun cmacs-menu-claim-mouse-3 (command)
  "Bind mouse-3 globally to COMMAND if nothing menu-shaped owns it.

Returns non-nil when the binding changed.  A mouse-3 already bound to a
keymap, to `context-menu-map', or to COMMAND is left alone -- those all
already produce a context menu, and stomping a user's deliberate choice
to fix a problem they do not have is not an improvement."
  (when cmacs-menu-override-mouse-3
    (let ((current (lookup-key (current-global-map) [mouse-3])))
      (unless (or (eq current 'context-menu-map)
                  (eq current command)
                  (keymapp current))
        (global-set-key [mouse-3] command)
        (when (or (featurep 'doom) (boundp 'doom-version))
          (message
           "cmacs-menu: mouse-3 was %s; rebound to %s.  (Set cmacs-menu-override-mouse-3 to nil to keep it.)"
           current command))
        t))))

(provide 'cmacs-menu)

;;; cmacs-menu.el ends here
