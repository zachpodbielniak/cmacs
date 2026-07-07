;;; cmacs-lrgscript.el --- Emacs Lisp scripting for libregnum  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Emacs Lisp is a first-class libregnum scripting language inside cmacs.  The
;; C subsystem (`--with-cmacs-lrgscript') implements an LrgScripting backend
;; that routes into the live Emacs Lisp VM and registers it with libregnum's
;; scripting manager, so a scene node (or a whole game -- see the game layer)
;; can be scripted in `.el'.
;;
;; A node script defines up to three hook functions; libregnum's
;; LrgScriptComponent calls them over the lifetime of the node:
;;
;;   (defun lrg-script-start ()        ; once, when the node is attached
;;     ...)
;;   (defun lrg-script-update (delta)  ; every frame, DELTA seconds elapsed
;;     ...)
;;   (defun lrg-script-detach ()       ; once, when the node is detached
;;     ...)
;;
;; libregnum looks the hooks up by the canonical underscore names
;; (`lrg_script_start' etc.); the backend also accepts the idiomatic
;; hyphenated names above, so write elisp naturally.
;;
;; CAVEAT (single obarray): unlike Lua's per-state sandbox, every elisp script
;; context shares Emacs's one global obarray.  Two scripts that both define
;; `lrg-script-update' will clash -- the last loaded wins.  For more than one
;; scripted node, dispatch from a single set of hooks (e.g. keyed on the node)
;; or give each script a unique function prefix and a thin
;; `lrg-script-update' shim.  A whole game is best authored through the game
;; layer, which owns its loop hooks.

;;; Code:

(require 'cl-lib)

;; Provided by the --with-cmacs-gi bridge, loaded at runtime; the draw helpers
;; below reach the whole graylib/libregnum engine through it.
(declare-function cmacs-gi-call "cmacs-gi" (namespace function &rest args))
(declare-function cmacs-libregnum-editor-attach-script "src/cmacs-libregnum")
(declare-function cmacs-lrgscript-run-game "src/cmacs-lrgscript")
(declare-function cmacs-lrgscript-available-p "src/cmacs-lrgscript")

(defconst cmacs-lrgscript-language 5
  "The `LrgScriptLanguage' integer for the Emacs Lisp backend.
Matches `LRG_SCRIPT_LANGUAGE_ELISP' in libregnum.  Pass this as the LANGUAGE
argument to `cmacs-libregnum-editor-attach-script'.")

(defun cmacs-lrgscript-available-p* ()
  "Return non-nil if the elisp scripting backend is compiled in and registered.
Elisp wrapper around the C `cmacs-lrgscript-available-p'; returns nil (rather
than signalling `void-function') when the subsystem is absent."
  (and (bound-and-true-p IS-CMACS-LRGSCRIPT)
       (fboundp 'cmacs-lrgscript-available-p)
       (cmacs-lrgscript-available-p)))

;;;###autoload
(defmacro cmacs-lrgscript-define-node-script (&rest body)
  "Define the node-script hooks from BODY, a plist of :start/:update/:detach.
Each value is a function; :update receives the frame DELTA.  Expands to the
canonically-named `lrg-script-start' / `lrg-script-update' / `lrg-script-detach'
defuns libregnum drives.  Only the provided hooks are defined.  Example:

  (cmacs-lrgscript-define-node-script
   :update (lambda (delta)
             (cmacs-lrgscript-node-rotate (* 90 delta))))"
  (let ((start (plist-get body :start))
        (update (plist-get body :update))
        (detach (plist-get body :detach))
        (forms '()))
    (when detach
      (push `(defun lrg-script-detach () (funcall ,detach)) forms))
    (when update
      (push `(defun lrg-script-update (delta) (funcall ,update delta)) forms))
    (when start
      (push `(defun lrg-script-start () (funcall ,start)) forms))
    `(progn ,@forms)))

;;;###autoload
(defun cmacs-lrgscript-attach (buffer node-id path)
  "Attach the elisp script at PATH to NODE-ID in libregnum editor BUFFER.
Thin wrapper over `cmacs-libregnum-editor-attach-script' that selects the elisp
backend.  The script's `lrg-script-start/update/detach' hooks then run when the
level plays."
  (unless (cmacs-lrgscript-available-p*)
    (user-error "cmacs-lrgscript: elisp scripting backend not available"))
  (cmacs-libregnum-editor-attach-script
   buffer node-id cmacs-lrgscript-language path))

;;; ------------------------------------------------------------------
;;; Game authoring
;;;
;;; `cmacs-lrgscript-run-game' (a C DEFUN) hosts a whole libregnum game in a
;;; buffer, driven by a plist of loop hooks.  The helpers below wrap the hooks
;;; so a signalling hook is logged (not silently swallowed), and expose the
;;; engine's drawing API to elisp.
;;;
;;; RENDERING is done from the `:draw' hook through the GObject-Introspection
;;; bridge (`--with-cmacs-gi'): the *entire* graylib/libregnum draw API is
;;; already callable from elisp, so no bespoke draw primitives are needed.  The
;;; thin wrappers below cover the common cases; anything else is one
;;; `cmacs-gi-call' away.  Draw calls are only valid inside `:draw' (the engine
;;; render target is bound then).
;;; ------------------------------------------------------------------

(defun cmacs-lrgscript--wrap-hook (fn label)
  "Wrap FN so a signalled error is caught and logged with LABEL, not propagated.
Belt-and-suspenders with the C dispatch's signal guard: keeps a buggy hook from
tearing down the frame loop, and surfaces the error in *Messages*."
  (when fn
    (lambda (&rest args)
      (condition-case err
          (apply fn args)
        (error (message "cmacs-lrgscript game %s error: %S" label err)
               nil)))))

;;;###autoload
(cl-defun cmacs-lrgscript-play (&key (buffer (current-buffer))
                                     startup update fixed-update draw
                                     shutdown focus-gained focus-lost
                                     (title "cmacs-lrgscript game")
                                     (width 640) (height 480))
  "Author and run a complete libregnum game in BUFFER from Emacs Lisp.
Ergonomic keyword wrapper over the C `cmacs-lrgscript-run-game': each of
STARTUP, UPDATE, FIXED-UPDATE, DRAW, SHUTDOWN, FOCUS-GAINED and FOCUS-LOST is a
function (see the manual for their contracts) and is wrapped for error logging.
TITLE, WIDTH and HEIGHT configure the window.  Returns the integer game id.

Recommended model: build your scene in STARTUP, advance game state in
FIXED-UPDATE, and render in DRAW (via the `cmacs-lrgscript-draw-*' helpers or
`cmacs-gi-call').  Requires a running libregnum display (a graphical frame, or
`emacs --lrg')."
  (unless (cmacs-lrgscript-available-p*)
    (user-error "cmacs-lrgscript: elisp scripting backend not available"))
  (cmacs-lrgscript-run-game
   buffer
   (list :startup      (cmacs-lrgscript--wrap-hook startup "startup")
         :update       (cmacs-lrgscript--wrap-hook update "update")
         :fixed-update (cmacs-lrgscript--wrap-hook fixed-update "fixed-update")
         :draw         (cmacs-lrgscript--wrap-hook draw "draw")
         :shutdown     (cmacs-lrgscript--wrap-hook shutdown "shutdown")
         :focus-gained (cmacs-lrgscript--wrap-hook focus-gained "focus-gained")
         :focus-lost   (cmacs-lrgscript--wrap-hook focus-lost "focus-lost"))
   title width height))

;;; Drawing helpers (call only inside a :draw hook).  Thin wrappers over the
;;; graylib GI namespace; a colour is (R G B A), each 0-255.

(defun cmacs-lrgscript--color (rgba)
  "Make a GrlColor from RGBA, a list (R G B A) of 0-255 ints (A optional)."
  (cmacs-gi-call "Graylib" "color_new"
                 (nth 0 rgba) (nth 1 rgba) (nth 2 rgba) (or (nth 3 rgba) 255)))

(defun cmacs-lrgscript-clear (rgba)
  "Clear the render target to colour RGBA.  Call first in your :draw hook."
  (cmacs-gi-call "Graylib" "draw_clear_background" (cmacs-lrgscript--color rgba)))

(defun cmacs-lrgscript-draw-rect (x y w h rgba)
  "Draw a filled rectangle at X,Y of size W,H in colour RGBA."
  (cmacs-gi-call "Graylib" "draw_rectangle"
                 (round x) (round y) (round w) (round h)
                 (cmacs-lrgscript--color rgba)))

(defun cmacs-lrgscript-draw-circle (x y radius rgba)
  "Draw a filled circle centred at X,Y with RADIUS in colour RGBA."
  (cmacs-gi-call "Graylib" "draw_circle"
                 (round x) (round y) (float radius) (cmacs-lrgscript--color rgba)))

(defun cmacs-lrgscript-draw-text (text x y size rgba)
  "Draw TEXT at X,Y at font SIZE in colour RGBA."
  (cmacs-gi-call "Graylib" "draw_text"
                 text (round x) (round y) (round size)
                 (cmacs-lrgscript--color rgba)))

(provide 'cmacs-lrgscript)
;;; cmacs-lrgscript.el ends here
