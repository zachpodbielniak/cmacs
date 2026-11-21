;;; cmacs-libregnum-tools.el --- The libregnum editor as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The thirteen `lrgeditor_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-libregnum.c
;; that evaluated a printf-built Lisp form.  Here they are
;; `cmacs-brigade-deftool' forms (doc_org/cmacs/cmacs-capability.org has
;; the recipe), reaching in-process agents, MCP clients,
;; org.cmacs.Editor1.Tools and `emacsctl tool lrgeditor ...' from one
;; definition.  The C file is deleted; the schema it published is frozen
;; in test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; The editor is libregnum's `lrgeditor'.  The embedded shell
;; (M-x cmacs-lrgeditor, buffer *lrgeditor*) is preferred when it is
;; open; the older Emacs-panel editor (*cmacs-libregnum editor*)
;; otherwise.  Both answer the same node DEFUNs, since the shell's
;; LrgEditor is the one the view's render context edits.
;;
;; Ten of the tools were called `lrg_editor_*' before the rename.  The C
;; file registered each of those twice; here the old name is an :aliases
;; entry on the one tool, so it is published, gated and allowlisted like
;; the new name and there is still only one definition.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - No argument is spliced into Lisp source.
;;
;;   - A failure is a failure.  "No libregnum editor open", "unknown or
;;     disabled action" and "could not instantiate" were ordinary
;;     results an MCP client could not tell from success; they are
;;     errors now.
;;
;;   - A string result is the string, not its `prin1' form in quotes.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-lrgeditor "cmacs-lrgeditor" (&optional path))
(declare-function cmacs-lrgeditor-attached-p
                  "cmacs-libregnum-lrgeditor-defuns.c" (buffer))
(declare-function cmacs-lrgeditor-activate-action
                  "cmacs-libregnum-lrgeditor-defuns.c" (buffer id))
(declare-function cmacs-lrgeditor-actions
                  "cmacs-libregnum-lrgeditor-defuns.c" (buffer))
(declare-function cmacs-lrgeditor-socket
                  "cmacs-libregnum-lrgeditor-defuns.c" (buffer))
(declare-function cmacs-libregnum-editor-active-p "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-tree-nodes "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-editor-add-primitive
                  "cmacs-libregnum-defuns.c" (buffer prim &optional name))
(declare-function cmacs-libregnum-editor-add-visual
                  "cmacs-libregnum-defuns.c"
                  (buffer kind &optional asset name))
(declare-function cmacs-libregnum-editor-set-position
                  "cmacs-libregnum-defuns.c" (buffer node-id x y z))
(declare-function cmacs-libregnum-editor-select "cmacs-libregnum-defuns.c"
                  (buffer node-id))
(declare-function cmacs-libregnum-editor-delete "cmacs-libregnum-defuns.c"
                  (buffer node-id))
(declare-function cmacs-libregnum-editor-save "cmacs-libregnum-defuns.c"
                  (buffer path))
(declare-function cmacs-libregnum-editor-play "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-editor-stop "cmacs-libregnum-defuns.c"
                  (buffer))

(defconst cmacs-libregnum-tools--shell-buffer "*lrgeditor*"
  "Buffer of the embedded lrgeditor shell.")

(defconst cmacs-libregnum-tools--editor-buffer "*cmacs-libregnum editor*"
  "Buffer of the older Emacs-panel level editor.")

(defun cmacs-libregnum-tools--editor ()
  "Return (BUFFER . SHELL) for the active editor, or signal.
SHELL is non-nil when BUFFER is the embedded lrgeditor shell, so a tool
can prefer the shell's own actions (play, stop, save) over the older
editor's primitives."
  (let* ((sb (get-buffer cmacs-libregnum-tools--shell-buffer))
         (shell (and sb (fboundp 'cmacs-lrgeditor-attached-p)
                     (cmacs-lrgeditor-attached-p sb)))
         (buf (or (and shell sb)
                  (get-buffer cmacs-libregnum-tools--editor-buffer))))
    (unless (and buf (cmacs-libregnum-editor-active-p buf))
      (error "No libregnum editor open (M-x cmacs-lrgeditor)"))
    (cons buf (and shell t))))

(defun cmacs-libregnum-tools--shell ()
  "Return the embedded shell's buffer, or signal when it is not the editor."
  (let ((ed (cmacs-libregnum-tools--editor)))
    (unless (cdr ed)
      (error "The lrgeditor shell is not open (M-x cmacs-lrgeditor)"))
    (car ed)))

(defun cmacs-libregnum-tools--integer (value what)
  "Return VALUE if it is an integer, else signal naming WHAT."
  (unless (integerp value)
    (error "%s must be an integer" what))
  value)

(defun cmacs-libregnum-tools--number (value what)
  "Return VALUE if it is a number, else signal naming WHAT."
  (unless (numberp value)
    (error "%s must be a number" what))
  value)

(cmacs-brigade-deftool lrgeditor-object-tree
    "List the libregnum editor's node tree (name/kind/depth/id)."
    ()
  :group 'lrgeditor
  :aliases '(lrg-editor-object-tree)
  :example "emacsctl tool lrgeditor object-tree"
  (format "%S" (cmacs-libregnum-tree-nodes
                (car (cmacs-libregnum-tools--editor)))))

(cmacs-brigade-deftool lrgeditor-add-primitive
    "Add a primitive. PRIMITIVE: 0 plane,1 cube,2 circle,3 uv-sphere,\
4 ico-sphere,5 cylinder,6 cone,7 torus,8 grid."
    ((primitive integer "Primitive type, 0-8")
     (name string "Name for the node (default Object)" :optional t))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "lrgeditor's own undo is not reached from here")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.AddPrimitive
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-add-primitive)
  :example "emacsctl tool lrgeditor add-primitive --primitive 1 --name Crate"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (format "added node %S"
            (cmacs-libregnum-editor-add-primitive
             buf (cmacs-libregnum-tools--integer primitive "primitive")
             (or name "Object")))))

(cmacs-brigade-deftool lrgeditor-add-visual
    "Add a non-primitive node. KIND: 2 mesh-asset,3 sprite,4 tilemap,\
5 light,6 camera,7 audio. ASSET is the model/image/tileset file."
    ((kind integer "Visual kind, 2-7")
     (asset string "Model, image or tileset file" :optional t)
     (name string "Name for the node (default Object)" :optional t))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "lrgeditor's own undo is not reached from here")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.AddVisual
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-add-visual)
  :example "emacsctl tool lrgeditor add-visual --kind 5 --name Sun"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (format "added node %S"
            (cmacs-libregnum-editor-add-visual
             buf (cmacs-libregnum-tools--integer kind "kind")
             asset (or name "Object")))))

(cmacs-brigade-deftool lrgeditor-move
    "Set node ID's position to (X Y Z) as one undoable edit."
    ((id integer "Node id")
     (x number "X")
     (y number "Y")
     (z number "Z"))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "lrgeditor's own undo is not reached from here")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Move
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-move)
  :example "emacsctl tool lrgeditor move --id 3 --x 0 --y 1.5 --z 0"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (cmacs-libregnum-editor-set-position
     buf (cmacs-libregnum-tools--integer id "id")
     (cmacs-libregnum-tools--number x "x")
     (cmacs-libregnum-tools--number y "y")
     (cmacs-libregnum-tools--number z "z"))
    "moved"))

(cmacs-brigade-deftool lrgeditor-select
    "Select node ID in the editor."
    ((id integer "Node id"))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "the selection before is not kept")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Select
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-select)
  :example "emacsctl tool lrgeditor select --id 3"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (cmacs-libregnum-editor-select
     buf (cmacs-libregnum-tools--integer id "id"))
    "selected"))

(cmacs-brigade-deftool lrgeditor-delete
    "Delete node ID from the level."
    ((id integer "Node id"))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "lrgeditor's own undo is not reached from here")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Delete
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-delete)
  :example "emacsctl tool lrgeditor delete --id 3"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (cmacs-libregnum-editor-delete
     buf (cmacs-libregnum-tools--integer id "id"))
    "deleted"))

(cmacs-brigade-deftool lrgeditor-open
    "Open libregnum's editor (the lrgeditor shell) on PATH: a project \
directory or project.ryaml, a .rlevel/.rprefab, a .rseq, or any asset \
one of its editors handles (.rsong, .rfoley, .rmat, .rbt, .rparticles, \
...); no PATH opens its welcome screen."
    ((path string "Project, level or asset to open" :optional t))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "close the editor it opened")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Open
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-open)
  :example "emacsctl tool lrgeditor open --path ~/game/project.ryaml"
  ;; Required first: in a session that never loaded cmacs-lrgeditor.el
  ;; the entry command, and the C->Elisp click dispatchers defined
  ;; alongside it, would be void.
  (require 'cmacs-lrgeditor)
  (cmacs-lrgeditor path)
  "opened")

(cmacs-brigade-deftool lrgeditor-save
    "Save the level to a .rlevel PATH."
    ((path string "Destination .rlevel file"))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "the saved file it overwrote is not kept")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Save
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-save)
  :example "emacsctl tool lrgeditor save --path ~/game/levels/one.rlevel"
  (let ((buf (car (cmacs-libregnum-tools--editor))))
    (cmacs-libregnum-editor-save buf path)
    "saved"))

(cmacs-brigade-deftool lrgeditor-play
    "Play-in-editor: instantiate the level into a runtime world and run \
it."
    ()
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "stop it with lrgeditor_stop")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Play
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-play)
  :example "emacsctl tool lrgeditor play"
  (pcase-let ((`(,buf . ,shell) (cmacs-libregnum-tools--editor)))
    (unless (if shell
                (cmacs-lrgeditor-activate-action buf "play.start")
              (cmacs-libregnum-editor-play buf))
      (error "Could not instantiate the level"))
    "playing"))

(cmacs-brigade-deftool lrgeditor-stop
    "Stop play-in-editor."
    ()
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "start it again with lrgeditor_play")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Stop
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :aliases '(lrg-editor-stop)
  :example "emacsctl tool lrgeditor stop"
  (pcase-let ((`(,buf . ,shell) (cmacs-libregnum-tools--editor)))
    (if shell
        (cmacs-lrgeditor-activate-action buf "play.stop")
      (cmacs-libregnum-editor-stop buf))
    "stopped"))

(cmacs-brigade-deftool lrgeditor-action
    "Run an lrgeditor action by id (e.g. file.save, edit.undo, \
play.start, view.top) in the embedded shell. lrgeditor_actions lists \
them."
    ((id string "Action id, as lrgeditor_actions lists it"))
  :group 'lrgeditor
  :destructive t
  :undo '(irreversible "lrgeditor's own undo is not reached from here")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Lrg.Action
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool lrgeditor action --id edit.undo"
  (let ((buf (cmacs-libregnum-tools--shell)))
    (unless (cmacs-lrgeditor-activate-action buf id)
      (error "Unknown or disabled action: %s" id))
    "done"))

(cmacs-brigade-deftool lrgeditor-actions
    "List the action ids the embedded lrgeditor shell registers."
    ()
  :group 'lrgeditor
  :example "emacsctl tool lrgeditor actions"
  (mapconcat #'identity
             (cmacs-lrgeditor-actions (cmacs-libregnum-tools--shell))
             "\n"))

(cmacs-brigade-deftool lrgeditor-socket
    "Socket the embedded lrgeditor serves libregnum's editor protocol on \
\(for lrgeditorctl --socket, its MCP verbs, or libregnum.el)."
    ()
  :group 'lrgeditor
  :example "emacsctl tool lrgeditor socket"
  (pcase-let ((`(,buf . ,shell) (cmacs-libregnum-tools--editor)))
    (or (and shell (cmacs-lrgeditor-socket buf))
        (error "Not serving the editor protocol"))))

(provide 'cmacs-libregnum-tools)

;;; cmacs-libregnum-tools.el ends here
