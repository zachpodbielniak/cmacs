;;; gowl-hotkey-examples.el --- Hotkeys (AutoHotkey) cookbook -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Recipes for gowl's hotkey module from Elisp under `cmacs --gowl' --
;; the "Hotkeys (AutoHotkey)" section of the gowl chapter in the cmacs
;; manual shows each of them, and test/cmacs/cmacs-gowl-hotkey-tests.el
;; loads this file and checks exactly what each one tells the module, so
;; the manual cannot drift from code that works.
;;
;; Copy what you want into your init.  Each recipe starts at a
;; ";;;; Recipe:" line; the manual's block for it is the text between
;; that line and the next one.  Key names are AutoHotkey's: # Super,
;; ! Alt, ^ Control, + Shift.

;;; Code:

(require 'cmacs-gowl-hotkey)

(declare-function gowl-clipboard-get "cmacs-gowl")
(declare-function gowl-find-client "cmacs-gowl")
(declare-function gowl-focus-client "cmacs-gowl")
(declare-function gowl-spawn "cmacs-gowl")
(declare-function cmacs-gsurf-open-url "cmacs-gsurf")
(declare-function cmacs-whisper-dictate "cmacs-whisper-dictate")
(declare-function cmacs-ai-chat "cmacs-ai")
(declare-function cmacs-ai-textops-stream "cmacs-ai-textops")
(defvar org-capture-initial)

;;;; Recipe: capture the selection from any window

;; Super+Alt+c in any application: copy what is selected there (the
;; module types Ctrl+c into it, waits for the copy to land), then
;; org-capture it in Emacs with the text as the initial content.
(cmacs-gowl-hotkey-define "#!c"
  (lambda ()
    (let ((org-capture-initial (gowl-clipboard-get)))
      (org-capture)))
  :do '((:send "^c") (:sleep 150))
  :description "Capture the selection")

;;;; Recipe: jump to an application, or start it

;; Super+Alt+b: focus the browser if it is open anywhere, on whatever
;; workspace, else start it.  AutoHotkey's WinExist / WinActivate / Run.
(defun my-hotkey-browser ()
  "Focus librewolf, or start it."
  (let ((c (gowl-find-client "librewolf")))
    (if c (gowl-focus-client c) (gowl-spawn "librewolf"))))

(cmacs-gowl-hotkey-define "#!b" #'my-hotkey-browser
  :description "Browser: focus or start")

;;;; Recipe: a hotkey for one application, decided in Elisp

;; Ctrl+Shift+o, but only in a browser: copy the page's address and open
;; it in an Emacs gsurf buffer.  The context is an Elisp predicate over
;; the focused window, asked when the focus or a title changes -- never
;; while a key is being decided.
(cmacs-gowl-hotkey-define-context "browser"
  (lambda (window)
    (member (alist-get 'app-id window) '("librewolf" "firefox"))))

(cmacs-gowl-hotkey-define "^+o"
  (lambda () (cmacs-gsurf-open-url (gowl-clipboard-get)))
  :context "browser"
  :do '((:send "^l^c{Esc}") (:sleep 150))
  :description "Page into gsurf")

;;;; Recipe: the scratchpad and a note, together

;; Super+Alt+n: drop the scratchpad down (a gowl command) and open the
;; inbox in Emacs -- gowl actions and Elisp in one hotkey, in order.
(cmacs-gowl-hotkey-define "#!n"
  (lambda () (find-file "~/Documents/notes/00_inbox/00_index.org"))
  :do "scratchpad-toggle"
  :description "Scratchpad + inbox")

;;;; Recipe: push to talk into dictation

;; Hold F13 (a foot pedal, a macro-pad key) to dictate, release to stop:
;; one hotkey on the press and one on the release, both toggling.
(cmacs-gowl-hotkey-define "F13" #'cmacs-whisper-dictate
  :id "dictate-down")
(cmacs-gowl-hotkey-define "F13 UP" #'cmacs-whisper-dictate
  :id "dictate-up")

;;;; Recipe: ask the AI about the selection, anywhere

;; Super+Alt+a in any window: copy the selection, and stream an
;; explanation of it into an Emacs output window (C-c C-c there asks a
;; follow-up).
(cmacs-gowl-hotkey-define "#!a"
  (lambda ()
    (cmacs-ai-textops-stream "Explain" "the selection"
                             "Explain the text briefly and plainly."
                             (gowl-clipboard-get)))
  :do '((:send "^c") (:sleep 150))
  :description "Explain the selection")

;;;; Recipe: double-tap right Control for a chat

;; Right Control tapped twice quickly opens an AI chat; once, or held
;; with another key, it is just Control.
(cmacs-gowl-hotkey-define "RCtrl" #'cmacs-ai-chat
  :double 300
  :description "AI chat")

;;;; Recipe: log where the time goes

;; Every minute, append the focused window to an org file.  The timer
;; is YAML-shaped Lisp data; the function it calls is Elisp.
(defvar my-hotkey-focus-log "~/Documents/notes/00_inbox/focus-log.org"
  "Where `my-hotkey-log-focus' writes.")

(defun my-hotkey-log-focus (&rest _)
  "Append the focused window's app id and title to `my-hotkey-focus-log'."
  (let ((w (cmacs-gowl-hotkey-focused-window)))
    (when w
      (with-temp-buffer
        (insert (format "- %s %s :: %s\n"
                        (format-time-string "[%Y-%m-%d %a %H:%M]")
                        (alist-get 'app-id w) (alist-get 'title w)))
        (append-to-file (point-min) (point-max)
                        (expand-file-name my-hotkey-focus-log))))))

(cmacs-gowl-hotkey-define-function "log-focus" #'my-hotkey-log-focus)

(cmacs-gowl-hotkey-add-section "focus-log"
  '(:timers [(:id "focus-log" :every "1m" :do (:call "log-focus"))]))

;;;; Recipe: a mode of single keys

;; Super+Alt+space enters `launch': one key starts a program and leaves
;; the mode, Escape leaves it, and nothing else typed meanwhile reaches
;; a window.  The mode line shows " HK:launch" while it is entered.
(cmacs-gowl-hotkey-add-section "launch-mode"
  '(:modes
    (:launch
     (:oneshot t :swallow t :timeout "3s" :label "Launch: t e b"
      :hotkeys [(:key "t" :do (:action "spawn" :arg "gst"))
                (:key "e" :do (:custom "(find-file \"~/Documents/notes/\")"))
                (:key "b" :do (:call "browser"))
                (:key "Esc" :do (:mode "default"))]))
    :hotkeys [(:key "#!Space" :do (:mode "launch"))]))

(cmacs-gowl-hotkey-define-function "browser"
  (lambda (&rest _) (my-hotkey-browser)))

;;;; Recipe: remaps and hotstrings from options

;; Caps Lock is Control, the back mouse button is a middle click, and
;; two hotstrings -- set in custom.el or init, installed at start.
(setq cmacs-gowl-hotkey-remaps
      '(("CapsLock" . "Control_L") ("XButton1" . "MButton"))
      cmacs-gowl-hotkey-hotstrings
      '("::btw::by the way" (";sig" . "-- \nZach")))

;;;; Recipe: game keys that stand down in EverQuest

;; F1-F3 are workspace keys everywhere except EverQuest, where they are
;; the game's own (target self and group).  :when is a gowl filter over
;; the focused window; the same keys reach the game as typed.
(dolist (n '(1 2 3))
  (cmacs-gowl-hotkey-define (format "F%d" n) nil
    :id (format "view-%d" n)
    :when '(not (app-id "eqgame.exe"))
    :do (list :command (format "view %d" n))))

;;;; Recipe: hear every hotkey

;; Log each hotkey that fires, and say so when one fails.
(add-hook 'cmacs-gowl-hotkey-fired-functions
          (lambda (id) (message "hotkey %s" id)))
(add-hook 'cmacs-gowl-hotkey-fault-functions
          (lambda (id what) (message "hotkey %s failed: %s" (or id "-") what)))

(provide 'gowl-hotkey-examples)

;;; gowl-hotkey-examples.el ends here
