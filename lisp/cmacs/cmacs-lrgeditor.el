;;; cmacs-lrgeditor.el --- libregnum's lrgeditor shell inside cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: games, tools, libregnum
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;;; Commentary:

;; `M-x cmacs-lrgeditor' opens libregnum's level/scene/world editor --
;; the same application as the standalone `lrgeditor' program, with its
;; menu bar, toolbar, docked hierarchy / inspector / assets / console /
;; timeline panels, scene viewport and play-in-editor -- inside an Emacs
;; window.  The window's libregnum view draws the editor's canvas every
;; frame (cmacs-libregnum-lrgeditor.c); the mouse goes to it from C,
;; keys from this file's keymap.
;;
;; The shell edits an `LrgEditor' that the older Emacs-panel editor
;; DEFUNs (`cmacs-libregnum-editor-*') and the `lrgeditor_*' MCP tools
;; can also reach, and it serves libregnum's editor protocol on a Unix
;; socket, so `lrgeditorctl', its MCP verbs and libregnum's own Emacs
;; package (libregnum.el: outline, inspector, log, debugger, opening
;; scripts here) all drive the embedded editor.
;;
;; Keys: everything goes to the editor -- its shortcuts are its own
;; (Ctrl+S save, Ctrl+Z undo, F5 play, ...) -- except the keys in
;; `cmacs-lrgeditor-passthrough-keys' and the `cmacs-lrgeditor-prefix'
;; map (default C-\), which holds the Emacs-side commands: switch
;; window or buffer, M-x, run an editor action by name, the libregnum.el
;; outline, kill the editor.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-libregnum)

(declare-function cmacs-lrgeditor--attach "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer &optional settings))
(declare-function cmacs-lrgeditor-attached-p "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor--open "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer path))
(declare-function cmacs-lrgeditor--new-project "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer dir name))
(declare-function cmacs-lrgeditor--start-server "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer &optional socket))
(declare-function cmacs-lrgeditor-socket "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor--key "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer grl-key phase mods))
(declare-function cmacs-lrgeditor--text "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer text))
(declare-function cmacs-lrgeditor--release-all "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor--idle-seconds "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor-playing-p "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor-quit-requested-p "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor-status "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-lrgeditor-activate-action "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer id))
(declare-function cmacs-lrgeditor-actions "cmacs-libregnum-lrgeditor-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-set-animated "cmacs-libregnum-defuns.c"
                  (buffer animated &optional fps))
(declare-function libregnum-connect "libregnum" (&optional socket))
(declare-function libregnum-connected-p "libregnum" ())
(declare-function libregnum-disconnect "libregnum" ())
(declare-function libregnum-outline "libregnum" ())
(defvar libregnum-open-file-function)
(defvar libregnum--process)


;;;; Options.

(defgroup cmacs-lrgeditor nil
  "libregnum's lrgeditor shell embedded in cmacs."
  :group 'cmacs-libregnum
  :prefix "cmacs-lrgeditor-")

(defcustom cmacs-lrgeditor-settings-file nil
  "Editor preferences file, or nil for the standalone editor's.
nil shares $XDG_CONFIG_HOME/libregnum/editor.yaml with `lrgeditor', so
recent projects, the dock layout and the external-editor choice follow
you between the two."
  :type '(choice (const :tag "Shared with lrgeditor" nil) file))

(defcustom cmacs-lrgeditor-start-server t
  "Whether the embedded editor serves libregnum's editor protocol.
With the server on, `lrgeditorctl', its MCP verbs and libregnum.el can
drive the editor in this Emacs."
  :type 'boolean)

(defcustom cmacs-lrgeditor-socket nil
  "Socket file for the editor protocol, or nil to let the editor choose.
The editor's own choice is its settings' socket, else
$XDG_RUNTIME_DIR/libregnum/editor-PID.sock."
  :type '(choice (const :tag "Editor's choice" nil) file))

(defcustom cmacs-lrgeditor-connect-libregnum-el t
  "Whether to connect libregnum.el to the embedded editor automatically.
libregnum.el is libregnum's own Emacs package (outline, inspector, log,
script debugger); connected, the editor's \"open in external editor\"
lands in this Emacs without a round trip through emacsclient."
  :type 'boolean)

(defcustom cmacs-lrgeditor-libregnum-el-directory nil
  "Directory holding libregnum.el, or nil to search for it.
The search tries `load-path', then the libregnum submodule of the cmacs
source tree (`source-directory')."
  :type '(choice (const :tag "Search" nil) directory))

(defcustom cmacs-lrgeditor-fps 30
  "Frame rate while the editor is active."
  :type 'integer)

(defcustom cmacs-lrgeditor-idle-seconds 2.0
  "Seconds without input after which the editor stops redrawing.
Play mode keeps it drawing regardless.  Any input restarts the clock."
  :type 'number)

(defcustom cmacs-lrgeditor-key-release-delay 0.4
  "Seconds after a key's last press before it is reported released.
Emacs delivers no key releases, so a held key (W/A/S/D while flying the
viewport) is emulated from keyboard auto-repeat: each repeat re-arms
this timer, and when the repeats stop the key is released.  Set it a
little longer than your key-repeat delay."
  :type 'number)

(defcustom cmacs-lrgeditor-prefix "C-\\"
  "Key that leads to the Emacs-side commands while the editor has the keyboard.
Everything else goes to the editor."
  :type 'key-sequence)

(defcustom cmacs-lrgeditor-passthrough-keys '("M-x" "C-g")
  "Keys that stay Emacs's while the editor has the keyboard."
  :type '(repeat key-sequence))


;;;; Key translation.

;; raylib KeyboardKey (GrlKey) codes.  Letters, digits, space and the
;; unshifted punctuation already equal their raylib code (letters
;; upper-cased); everything else is in these tables.
(defconst cmacs-lrgeditor--symbol-keys
  '((escape . 256) (return . 257) (kp-enter . 335) (tab . 258)
    (backtab . 258) (backspace . 259) (insert . 260) (delete . 261)
    (deletechar . 261) (right . 262) (left . 263) (down . 264) (up . 265)
    (prior . 266) (next . 267) (home . 268) (end . 269)
    (f1 . 290) (f2 . 291) (f3 . 292) (f4 . 293) (f5 . 294) (f6 . 295)
    (f7 . 296) (f8 . 297) (f9 . 298) (f10 . 299) (f11 . 300) (f12 . 301)
    (kp-0 . 320) (kp-1 . 321) (kp-2 . 322) (kp-3 . 323) (kp-4 . 324)
    (kp-5 . 325) (kp-6 . 326) (kp-7 . 327) (kp-8 . 328) (kp-9 . 329)
    (kp-decimal . 330) (kp-divide . 331) (kp-multiply . 332)
    (kp-subtract . 333) (kp-add . 334) (kp-equal . 336)
    (menu . 348))
  "Emacs key symbols to graylib key codes.")

(defconst cmacs-lrgeditor--shifted-keys
  '((?! . 49) (?@ . 50) (?# . 51) (?$ . 52) (?% . 53) (?^ . 54) (?& . 55)
    (?* . 56) (?\( . 57) (?\) . 48) (?_ . 45) (?+ . 61) (?{ . 91) (?} . 93)
    (?| . 92) (?: . 59) (?\" . 39) (?< . 44) (?> . 46) (?? . 47) (?~ . 96))
  "Shifted punctuation to the code of the key that types it.
These characters arrive with no shift modifier of their own, so the
shift is added when one of them is translated.")

(defconst cmacs-lrgeditor--mod-bits
  '((shift . 1) (control . 2) (meta . 4) (alt . 4) (super . 8))
  "Emacs event modifiers to the editor's modifier bits.")

(defun cmacs-lrgeditor--translate (event)
  "Translate key EVENT to (KEY MODS TEXT), or nil when it is not a key.
KEY is a graylib key code, MODS the modifier bit mask and TEXT the
string it types into a focused text field, or nil."
  ;; RET, TAB, ESC and DEL arrive (in a terminal, or when the window
  ;; system's symbol was translated) as the control characters they
  ;; share with C-m, C-i and C-[; `event-basic-type' would report those.
  (when-let* ((raw (and (integerp event)
                        (cdr (assq event '((?\r . return) (?\t . tab)
                                           (?\e . escape)
                                           (127 . backspace)))))))
    (setq event raw))
  (let* ((mods (event-modifiers event))
         (base (event-basic-type event))
         (bits (apply #'logior 0
                      (mapcar (lambda (m)
                                (or (cdr (assq m cmacs-lrgeditor--mod-bits)) 0))
                              mods)))
         (plain (null (cl-intersection mods '(control meta alt super hyper))))
         key text)
    (cond
     ((memq 'click mods) nil)           ; never a key
     ((memq 'down mods) nil)
     ((memq 'drag mods) nil)
     ((symbolp base)
      (setq key (cdr (assq base cmacs-lrgeditor--symbol-keys))))
     ((integerp base)
      ;; The character typed, before modifiers took it apart: C-s arrives
      ;; as 19, base `s'; `A' as base `a' with shift.
      (let ((ch (if (memq 'shift mods) (upcase base) base)))
        (cond
         ((= base ?\r) (setq key 257))
         ((= base ?\t) (setq key 258))
         ((= base 127) (setq key 259))
         ((= base ?\e) (setq key 256))
         ((and (>= base ?a) (<= base ?z)) (setq key (- base 32)))
         ((and (>= base ?A) (<= base ?Z))
          (setq key base bits (logior bits 1)))
         ((or (and (>= base ?0) (<= base ?9))
              (memq base '(?\s ?' ?, ?- ?. ?/ ?\; ?= ?\[ ?\\ ?\] ?`)))
          (setq key base))
         ((assq base cmacs-lrgeditor--shifted-keys)
          (setq key (cdr (assq base cmacs-lrgeditor--shifted-keys))
                bits (logior bits 1))))
        (when (and plain (>= ch ?\s) (/= ch 127))
          (setq text (string ch)))))
     (t nil))
    (when (or key text)
      (list key bits text))))


;;;; Held keys.

(defvar-local cmacs-lrgeditor--held nil
  "Hash table: graylib key code -> its pending release timer.")

(defun cmacs-lrgeditor--press (buffer key mods)
  "Report KEY with MODS pressed in BUFFER's editor, releasing it later.
A first press is a press; auto-repeats arrive as repeats and re-arm the
release timer, so a physically held key stays down."
  (with-current-buffer buffer
    (unless (hash-table-p cmacs-lrgeditor--held)
      (setq cmacs-lrgeditor--held (make-hash-table :test #'eql)))
    (let ((timer (gethash key cmacs-lrgeditor--held)))
      (if (timerp timer)
          (progn (cancel-timer timer)
                 (cmacs-lrgeditor--key buffer key 1 mods))
        (cmacs-lrgeditor--key buffer key 0 mods))
      (puthash key
               (run-at-time
                cmacs-lrgeditor-key-release-delay nil
                (lambda ()
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when (hash-table-p cmacs-lrgeditor--held)
                        (remhash key cmacs-lrgeditor--held))
                      (ignore-errors
                        (cmacs-lrgeditor--key buffer key 2 0))))))
               cmacs-lrgeditor--held))))

(defun cmacs-lrgeditor--release-held ()
  "Release every key and button the editor in this buffer thinks is held."
  (when (hash-table-p cmacs-lrgeditor--held)
    (maphash (lambda (key timer)
               (when (timerp timer) (cancel-timer timer))
               (ignore-errors (cmacs-lrgeditor--key (current-buffer) key 2 0)))
             cmacs-lrgeditor--held)
    (clrhash cmacs-lrgeditor--held))
  (when (cmacs-lrgeditor-attached-p (current-buffer))
    (cmacs-lrgeditor--release-all (current-buffer))))

(defun cmacs-lrgeditor-dispatch-key ()
  "Send the key that invoked this command to the editor.
This is the default binding of `cmacs-lrgeditor-mode-map'."
  (interactive)
  (let ((spec (cmacs-lrgeditor--translate last-command-event))
        (buffer (current-buffer)))
    (when (and spec (cmacs-lrgeditor-attached-p buffer))
      (pcase-let ((`(,key ,mods ,text) spec))
        (when key
          (cmacs-lrgeditor--press buffer key mods))
        (when text
          (cmacs-lrgeditor--text buffer text))))))


;;;; Activity clock.

(defvar-local cmacs-lrgeditor--timer nil
  "Timer that stops redrawing an idle editor and notices File > Quit.")

(defun cmacs-lrgeditor--tick (buffer)
  "Housekeeping for the editor in BUFFER, run twice a second."
  (if (not (and (buffer-live-p buffer)
                (cmacs-lrgeditor-attached-p buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cmacs-lrgeditor--stop-timer)))
    (cond
     ((cmacs-lrgeditor-quit-requested-p buffer)
      (kill-buffer buffer))
     ((and (not (cmacs-lrgeditor-playing-p buffer))
           (> (cmacs-lrgeditor--idle-seconds buffer)
              cmacs-lrgeditor-idle-seconds))
      ;; Idle: stop the clock.  The C input path and every DEFUN that
      ;; changes what the editor shows start it again.
      (cmacs-libregnum-set-animated buffer nil))
     (t
      (cmacs-libregnum-set-animated buffer t cmacs-lrgeditor-fps)))))

(defun cmacs-lrgeditor--stop-timer ()
  "Cancel this buffer's housekeeping timer."
  (when (timerp cmacs-lrgeditor--timer)
    (cancel-timer cmacs-lrgeditor--timer))
  (setq cmacs-lrgeditor--timer nil))


;;;; Focus.

(defun cmacs-lrgeditor--focus-from-click (buffer)
  "Select the window showing BUFFER after a click in its editor.
Called from C (cmacs-libregnum-input.c) on a press in the shell, so the
keys typed next reach the editor's keymap."
  (when (buffer-live-p buffer)
    (let ((win (get-buffer-window buffer 'visible)))
      (when (and win (not (eq win (selected-window))))
        (select-window win)))))

(defun cmacs-lrgeditor--on-selection-change (&optional _frame)
  "Release held keys when the editor's window loses the selection."
  (dolist (buf (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buf) 'cmacs-lrgeditor-mode)
               (not (eq buf (window-buffer (selected-window)))))
      (with-current-buffer buf
        (when (and (hash-table-p cmacs-lrgeditor--held)
                   (> (hash-table-count cmacs-lrgeditor--held) 0))
          (cmacs-lrgeditor--release-held))))))


;;;; libregnum.el.

(defun cmacs-lrgeditor--libregnum-el-available-p ()
  "Load libregnum.el if it can be found; return non-nil when loaded."
  (or (featurep 'libregnum)
      (let ((dirs (delq nil
                        (list cmacs-lrgeditor-libregnum-el-directory
                              (and (bound-and-true-p source-directory)
                                   (expand-file-name
                                    "deps/libregnum/editors/emacs"
                                    source-directory))))))
        (or (require 'libregnum nil t)
            (cl-some (lambda (dir)
                       (when (file-readable-p (expand-file-name "libregnum.el" dir))
                         (add-to-list 'load-path dir)
                         (require 'libregnum nil t)))
                     dirs)))))

(defun cmacs-lrgeditor--open-file (file line column)
  "Visit FILE at LINE and COLUMN for the embedded editor, beside it."
  (let ((buf (find-file-noselect file)))
    (pop-to-buffer buf '((display-buffer-reuse-window
                          display-buffer-use-some-window)
                         (inhibit-same-window . t)))
    (goto-char (point-min))
    (when (and line (> line 0)) (forward-line (1- line)))
    (when (and column (> column 0)) (move-to-column column))))

(defun cmacs-lrgeditor-connect (&optional buffer)
  "Connect libregnum.el to the editor in BUFFER (default: the current one)."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (socket (and (cmacs-lrgeditor-attached-p buffer)
                      (cmacs-lrgeditor-socket buffer))))
    (unless socket
      (user-error "This editor is not serving its protocol (see `cmacs-lrgeditor-start-server')"))
    (unless (cmacs-lrgeditor--libregnum-el-available-p)
      (user-error "libregnum.el not found; set `cmacs-lrgeditor-libregnum-el-directory'"))
    (setq libregnum-open-file-function #'cmacs-lrgeditor--open-file)
    (libregnum-connect socket)
    (message "libregnum.el connected to %s" socket)))


;;;; Commands.

(defun cmacs-lrgeditor--buffer ()
  "Return the current editor buffer, or signal."
  (unless (and (derived-mode-p 'cmacs-lrgeditor-mode)
               (cmacs-lrgeditor-attached-p (current-buffer)))
    (user-error "Not in an lrgeditor buffer"))
  (current-buffer))

(defun cmacs-lrgeditor-run-action (id)
  "Run the editor action ID, chosen from the editor's own registry."
  (interactive
   (list (completing-read "Editor action: "
                          (cmacs-lrgeditor-actions (cmacs-lrgeditor--buffer))
                          nil t)))
  (unless (cmacs-lrgeditor-activate-action (cmacs-lrgeditor--buffer) id)
    (message "lrgeditor: %s is disabled right now" id)))

(defun cmacs-lrgeditor-open (path)
  "Open PATH, a project directory or a level file, in this editor."
  (interactive (list (read-file-name "Open project or level: ")))
  (cmacs-lrgeditor--open (cmacs-lrgeditor--buffer) path))

(defun cmacs-lrgeditor-new-project (dir name)
  "Create a libregnum project in DIR named NAME and open it."
  (interactive
   (let ((dir (read-directory-name "New project directory: ")))
     (list dir (read-string "Project name: "
                            (file-name-nondirectory
                             (directory-file-name dir))))))
  (cmacs-lrgeditor--new-project (cmacs-lrgeditor--buffer) dir
                                (and (not (string-empty-p name)) name)))

(defun cmacs-lrgeditor-show-socket ()
  "Show (and copy) the socket the editor serves its protocol on."
  (interactive)
  (let ((socket (cmacs-lrgeditor-socket (cmacs-lrgeditor--buffer))))
    (if (not socket)
        (message "lrgeditor: not serving")
      (kill-new socket)
      (message "lrgeditor socket: %s (copied)" socket))))

(defun cmacs-lrgeditor-outline ()
  "Show libregnum.el's outline of the level, connecting first if needed."
  (interactive)
  (let ((buffer (cmacs-lrgeditor--buffer)))
    (unless (and (featurep 'libregnum) (libregnum-connected-p))
      (cmacs-lrgeditor-connect buffer))
    (libregnum-outline)))

(defun cmacs-lrgeditor-quit ()
  "Kill this editor (unsaved changes are the editor's to warn about)."
  (interactive)
  (when (yes-or-no-p "Close the editor? ")
    (kill-buffer (cmacs-lrgeditor--buffer))))

(defvar cmacs-lrgeditor-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'other-window)
    (define-key map (kbd "b") #'switch-to-buffer)
    (define-key map (kbd "x") #'execute-extended-command)
    (define-key map (kbd "a") #'cmacs-lrgeditor-run-action)
    (define-key map (kbd "f") #'cmacs-lrgeditor-open)
    (define-key map (kbd "n") #'cmacs-lrgeditor-new-project)
    (define-key map (kbd "l") #'cmacs-lrgeditor-outline)
    (define-key map (kbd "c") #'cmacs-lrgeditor-connect)
    (define-key map (kbd "s") #'cmacs-lrgeditor-show-socket)
    (define-key map (kbd "k") #'cmacs-lrgeditor-quit)
    (define-key map (kbd "0") #'delete-window)
    (define-key map (kbd "1") #'delete-other-windows)
    (define-key map (kbd "2") #'split-window-below)
    (define-key map (kbd "3") #'split-window-right)
    map)
  "Emacs-side commands reached through `cmacs-lrgeditor-prefix'.")

(defvar cmacs-lrgeditor-mode-map
  (let ((map (make-keymap)))
    ;; Everything is the editor's...
    (define-key map [t] #'cmacs-lrgeditor-dispatch-key)
    ;; ...except mouse and window-system events (the C layer delivers the
    ;; editor's mouse input before Emacs sees it; what arrives here was
    ;; aimed at the mode line, a fringe or a scroll bar, and those keep
    ;; their global bindings).
    (dolist (area '(mode-line header-line tab-line vertical-line
                    left-fringe right-fringe left-margin right-margin
                    vertical-scroll-bar horizontal-scroll-bar))
      (define-key map (vector area) nil))
    (dolist (ev '(switch-frame select-window focus-in focus-out
                  delete-frame iconify-frame make-frame-visible
                  wheel-up wheel-down wheel-left wheel-right
                  mouse-1 mouse-2 mouse-3 down-mouse-1 down-mouse-2
                  down-mouse-3 drag-mouse-1 drag-mouse-2 drag-mouse-3
                  double-mouse-1 triple-mouse-1 mouse-movement
                  help-echo dnd-drop))
      (define-key map (vector ev) #'ignore))
    map)
  "Keymap for `cmacs-lrgeditor-mode'.
Its default binding sends every key to the editor; see
`cmacs-lrgeditor-prefix' and `cmacs-lrgeditor-passthrough-keys'.")

(defun cmacs-lrgeditor--install-escapes ()
  "Bind the prefix map and the pass-through keys in the mode map."
  (define-key cmacs-lrgeditor-mode-map (kbd cmacs-lrgeditor-prefix)
              cmacs-lrgeditor-prefix-map)
  (dolist (k cmacs-lrgeditor-passthrough-keys)
    ;; nil, not a command: an explicitly unbound key falls through to the
    ;; global map instead of taking this map's default binding.
    (define-key cmacs-lrgeditor-mode-map (kbd k) nil)))

(define-derived-mode cmacs-lrgeditor-mode cmacs-libregnum-mode "lrgeditor"
  "Major mode for libregnum's lrgeditor shell.

The window is the editor: libregnum's menu bar, toolbar, docked panels
and scene viewport.  Mouse input goes to it directly; keys go to it
through this keymap, whose default binding forwards every key.  The
editor's own shortcuts (Ctrl+S, Ctrl+Z, F5 ...) therefore apply.

\\<cmacs-lrgeditor-mode-map>Emacs-side commands live behind \\[cmacs-lrgeditor-prefix-map]:
\\{cmacs-lrgeditor-prefix-map}"
  :group 'cmacs-lrgeditor
  ;; The parent's single-key scene bindings must not shadow the editor.
  (set-keymap-parent cmacs-lrgeditor-mode-map nil)
  (cmacs-lrgeditor--install-escapes)
  (setq-local mode-line-format
              '("%e" mode-line-front-space mode-line-buffer-identification
                "  lrgeditor  "
                (:eval (when (cmacs-lrgeditor-attached-p (current-buffer))
                         (let ((s (cmacs-lrgeditor-status (current-buffer))))
                           (and s (truncate-string-to-width s 60)))))))
  (setq cmacs-lrgeditor--held (make-hash-table :test #'eql))
  (add-hook 'kill-buffer-hook #'cmacs-lrgeditor--on-kill nil t)
  (add-hook 'window-selection-change-functions
            #'cmacs-lrgeditor--on-selection-change))

(defun cmacs-lrgeditor--on-kill ()
  "Tear down this buffer's editor housekeeping."
  (cmacs-lrgeditor--stop-timer)
  (when (hash-table-p cmacs-lrgeditor--held)
    (maphash (lambda (_k timer) (when (timerp timer) (cancel-timer timer)))
             cmacs-lrgeditor--held))
  ;; libregnum.el talks to one editor at a time; let go of it only when
  ;; that editor is this one.
  (let ((socket (ignore-errors (cmacs-lrgeditor-socket (current-buffer))))
        (proc (bound-and-true-p libregnum--process)))
    (when (and socket (featurep 'libregnum) (libregnum-connected-p)
               (processp proc)
               (equal (process-contact proc :service) socket))
      (libregnum-disconnect))))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    ;; Emacs state: every key, Escape included, belongs to the editor.
    (evil-set-initial-state 'cmacs-lrgeditor-mode 'emacs)))

;;;###autoload
(defun cmacs-lrgeditor (&optional path)
  "Open libregnum's editor (lrgeditor) in this window.
PATH is a project directory or a level file; interactively, a prefix
argument prompts for it, otherwise the editor starts empty (its welcome
screen offers recent projects).  With the server on (the default), the
editor serves libregnum's editor protocol, and libregnum.el connects
when `cmacs-lrgeditor-connect-libregnum-el' is non-nil."
  (interactive
   (list (when current-prefix-arg
           (read-file-name "Open project or level: "))))
  (unless (fboundp 'cmacs-lrgeditor--attach)
    (user-error "cmacs-lrgeditor not built; reconfigure with --with-cmacs-libregnum"))
  (let ((buffer (get-buffer-create "*lrgeditor*")))
    (switch-to-buffer buffer)
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-lrgeditor-mode)
        (let ((inhibit-read-only t))
          (erase-buffer))
        (cmacs-lrgeditor-mode))
      (unless (cmacs-lrgeditor-attached-p buffer)
        (cmacs-lrgeditor--attach buffer cmacs-lrgeditor-settings-file)
        (when cmacs-lrgeditor-start-server
          (condition-case err
              (cmacs-lrgeditor--start-server buffer cmacs-lrgeditor-socket)
            (error (message "lrgeditor: no server: %s"
                            (error-message-string err))))))
      (when path
        (cmacs-lrgeditor--open buffer path))
      (cmacs-lrgeditor--stop-timer)
      (setq cmacs-lrgeditor--timer
            (run-at-time 0.5 0.5 #'cmacs-lrgeditor--tick buffer))
      (cmacs-libregnum-set-animated buffer t cmacs-lrgeditor-fps)
      (when (and cmacs-lrgeditor-start-server
                 cmacs-lrgeditor-connect-libregnum-el
                 (cmacs-lrgeditor-socket buffer)
                 (cmacs-lrgeditor--libregnum-el-available-p)
                 (not (libregnum-connected-p)))
        (ignore-errors (cmacs-lrgeditor-connect buffer))))
    (message "lrgeditor: %s for Emacs commands"
             (key-description (kbd cmacs-lrgeditor-prefix)))
    buffer))

(provide 'cmacs-lrgeditor)

;;; cmacs-lrgeditor.el ends here
