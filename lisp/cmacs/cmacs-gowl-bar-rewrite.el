;;; cmacs-gowl-bar-rewrite.el --- cmacs actions for gowl's ai-rewrite widget  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's `ai-rewrite' bar widget (gowl's
;; modules/bar/bar-plugins-airewrite.c, docs/bar-widgets/ai-rewrite.org):
;; select text anywhere on the desktop, press the keybind, pick an
;; action, look at the diff, press Enter and the result is pasted over
;; the selection.
;;
;; The widget ships five standalone actions.  Under `cmacs --gowl' it
;; offers what the right-click AI menu offers instead -- every text
;; operation of `cmacs-ai-textops' (proofread, rephrase, summarize,
;; explain, reply, ask) plus Improve, Shorten, Translate to English and
;; Custom -- with the SAME system prompts, so a prompt customised for
;; the menu is the prompt the bar uses.  That is why the list is built
;; at push time from `cmacs-ai-textops--specs' and the system-prompt
;; variables, never copied into this file: a copy would go stale the
;; first time anybody customised the original.
;;
;; The list travels as ONE widget setting, `ai-rewrite.actions', in a
;; line format both sides test against the same golden string (gowl's
;; tests/fixtures/bar/ai-rewrite/pushed-from-cmacs.txt and
;; `cmacs-gowl-bar-rewrite-tests--golden'):
;;
;;   #ai-rewrite-actions 1
;;   KEY<TAB>ID<TAB>LABEL<TAB>FLAGS<TAB>INPUT<TAB>PROVIDER<TAB>MODEL<TAB>SYSTEM<TAB>INSTRUCTION
;;
;; one action per line, each field with backslash, tab, newline and
;; carriage return escaped as \\ \t \n \r.  FLAGS holds `p' (preview the
;; answer before pasting) and `d' (show it as a word diff rather than as
;; plain text).  An INSTRUCTION may contain `{input}': the widget then
;; asks for a line first (INPUT is the field's placeholder) and puts
;; what was typed there.  The widget sends the model
;;
;;   INSTRUCTION (with {input} replaced) + "\n\n" + the selected text
;;
;; so an instruction built from a text operation ends in "The text:",
;; mirroring `cmacs-ai-textops--prompt'.
;;
;; The answer comes back through the shared bar AI contract
;; (`cmacs-gowl-bar-ai-run', cmacs-gowl-bar-ai.el); this file only
;; pushes the list, `ai-backend=cmacs' and the provider names.
;;
;; A setting pushed to a widget that is not in the bar is dropped, so
;; push AFTER the widget is added: `cmacs --gowl' does it at startup,
;; and `M-x cmacs-gowl-bar-rewrite-push' does it by hand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)

(defvar cmacs-ai-textops--specs)

(defconst cmacs-gowl-bar-rewrite-widget "ai-rewrite"
  "The widget's registry name.")

(defconst cmacs-gowl-bar-rewrite--header "#ai-rewrite-actions 1"
  "First line of the pushed action list; the widget skips `#' lines.")

(defconst cmacs-gowl-bar-rewrite--translate-system
  "You are a translator.  Translate the text you are given into natural
English, keeping its tone, formatting, names and any code exactly as
they are.  Text that is already English is returned unchanged.  Output
ONLY the translation: no preamble, no notes, no quotes or fences."
  "System prompt for the Translate to English action.
No text operation translates, so this one is the widget's own.")

(defun cmacs-gowl-bar-rewrite--set (symbol value)
  "Set SYMBOL to VALUE and push the new list to a running bar."
  (set-default symbol value)
  (when (fboundp 'gowl-bar-configure)
    (cmacs-gowl-bar-rewrite-push)))

(defcustom cmacs-gowl-bar-rewrite-actions
  `(("f" "proofread" "Fix spelling & grammar"
     cmacs-ai-proofread-system-prompt (textops proofread))
    ("r" "rephrase" "Rephrase"
     cmacs-ai-rephrase-system-prompt (textops rephrase))
    ("i" "improve" "Improve"
     cmacs-ai-rephrase-system-prompt
     "Improve the following.\n\nHow: make it clearer, tighter and more direct, keeping the author's voice and format.\n\nThe text:")
    ("h" "shorten" "Shorten"
     cmacs-ai-rephrase-system-prompt
     "Shorten the following.\n\nHow: keep every fact, name, number and decision and the author's voice; cut padding, repetition and hedging.\n\nThe text:")
    ("e" "translate-en" "Translate to English"
     ,cmacs-gowl-bar-rewrite--translate-system
     "Translate the following into English.\n\nThe text:")
    ("s" "summarize" "Summarize"
     cmacs-ai-summarize-system-prompt (textops summarize) :diff nil)
    ("x" "explain" "Explain"
     cmacs-ai-explain-system-prompt (textops explain) :diff nil)
    ("p" "reply" "Reply"
     cmacs-ai-reply-system-prompt (textops reply) :diff nil)
    ("a" "ask" "Ask about this..."
     cmacs-ai-ask-system-prompt (textops ask input)
     :input "What do you want to know?" :diff nil)
    ("c" "custom" "Custom..."
     cmacs-ai-rephrase-system-prompt (textops rephrase input)
     :input "How should it be rewritten?"))
  "Actions the gowl `ai-rewrite' widget offers under cmacs --gowl.

Each entry is (KEY ID LABEL SYSTEM INSTRUCTION . PROPS):

KEY          a one-letter string, the panel hotkey (`a'-`z', `0'-`9';
             j, k, y and v are the panel's own and are dropped), or nil.
ID           a unique string.
LABEL        what the panel row says.
SYSTEM       a string, a variable holding one (read at push time, so a
             customised prompt is honoured), or nil.
INSTRUCTION  a string, or (textops OP) to use text operation OP's
             instruction and default refinement from
             `cmacs-ai-textops--specs', or (textops OP input) to put
             what the user types in place of the default refinement.
             `{input}' in a string is replaced the same way.
PROPS        :input PLACEHOLDER (ask for a line first), :preview nil
             (paste without showing), :diff nil (show the answer as text,
             not as a diff -- for answers that are not rewrites),
             :provider and :model (strings; recorded for the widget,
             which uses its own ai-provider/ai-model today).

Proofread comes first because it is the one people reach for."
  :type '(repeat sexp)
  :initialize #'custom-initialize-default
  :set #'cmacs-gowl-bar-rewrite--set
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-rewrite-actions-mode "replace"
  "How the pushed actions combine with the widget's built-in five.
\"replace\" shows only `cmacs-gowl-bar-rewrite-actions' (which already
covers the built-ins); \"extend\" lays them over the built-ins, a pushed
action replacing a built-in with the same id or key."
  :type '(choice (const "replace") (const "extend"))
  :initialize #'custom-initialize-default
  :set #'cmacs-gowl-bar-rewrite--set
  :group 'cmacs-gowl-bar)

;;;; Building the list ------------------------------------------------

(defun cmacs-gowl-bar-rewrite--textops-instruction (op &optional input)
  "The instruction text operation OP gives the model, ending \"The text:\".
With INPUT non-nil, `{input}' takes the place of OP's default refinement."
  (require 'cmacs-ai-textops nil t)
  (let ((spec (and (boundp 'cmacs-ai-textops--specs)
                   (alist-get op cmacs-ai-textops--specs))))
    (when spec
      (format "%s\n\nHow: %s\n\nThe text:"
              (plist-get spec :instruction)
              (if input "{input}" (plist-get spec :default))))))

(defun cmacs-gowl-bar-rewrite--system (system)
  "SYSTEM resolved to a string or nil (see `cmacs-gowl-bar-rewrite-actions')."
  (cond
   ((stringp system) system)
   ((and system (symbolp system))
    ;; The proofread prompt lives in its own library; load it rather
    ;; than push an empty system prompt.
    (unless (boundp system)
      (require 'cmacs-ai-textops nil t))
    (and (boundp system) (stringp (symbol-value system))
         (symbol-value system)))
   (t nil)))

(defun cmacs-gowl-bar-rewrite--instruction (instruction)
  "INSTRUCTION resolved to a string, or nil when it cannot be."
  (pcase instruction
    ((pred stringp) instruction)
    (`(textops ,op) (cmacs-gowl-bar-rewrite--textops-instruction op))
    (`(textops ,op input)
     (cmacs-gowl-bar-rewrite--textops-instruction op t))
    (_ nil)))

(defun cmacs-gowl-bar-rewrite-resolve ()
  "`cmacs-gowl-bar-rewrite-actions' resolved to plists.
Each has :key :id :label :system :instruction :input :provider :model
:preview :diff.  An entry whose instruction cannot be resolved (a text
operation that no longer exists) is left out with a message rather
than pushed empty."
  (let (out)
    (dolist (entry cmacs-gowl-bar-rewrite-actions)
      (pcase-let ((`(,key ,id ,label ,system ,instruction . ,props) entry))
        (let ((inst (cmacs-gowl-bar-rewrite--instruction instruction)))
          (if (not (and (stringp id) (stringp label) inst))
              (message "cmacs-gowl-bar-rewrite: skipping action %S" id)
            (push (list :key (and (stringp key) (= (length key) 1) key)
                        :id id
                        :label label
                        :system (cmacs-gowl-bar-rewrite--system system)
                        :instruction inst
                        :input (plist-get props :input)
                        :provider (plist-get props :provider)
                        :model (plist-get props :model)
                        :preview (if (plist-member props :preview)
                                     (plist-get props :preview)
                                   t)
                        :diff (if (plist-member props :diff)
                                  (plist-get props :diff)
                                t))
                  out)))))
    (nreverse out)))

;;;; The wire format --------------------------------------------------

(defun cmacs-gowl-bar-rewrite--escape (text)
  "TEXT with backslash, tab, newline and return escaped; nil is \"\"."
  (if (null text)
      ""
    (mapconcat (lambda (c)
                 (pcase c
                   (?\\ "\\\\")
                   (?\t "\\t")
                   (?\n "\\n")
                   (?\r "\\r")
                   (_ (string c))))
               text "")))

(defun cmacs-gowl-bar-rewrite--unescape (text)
  "Undo `cmacs-gowl-bar-rewrite--escape' on TEXT."
  (let ((i 0) (n (length text)) (out nil))
    (while (< i n)
      (let ((c (aref text i)))
        (if (and (eq c ?\\) (< (1+ i) n))
            (let ((d (aref text (1+ i))))
              (push (pcase d (?t ?\t) (?n ?\n) (?r ?\r) (_ d)) out)
              (setq i (+ i 2)))
          (push c out)
          (setq i (1+ i)))))
    (apply #'string (nreverse out))))

(defun cmacs-gowl-bar-rewrite-serialize (actions)
  "ACTIONS (plists from `cmacs-gowl-bar-rewrite-resolve') as the widget's
`actions' setting."
  (concat
   cmacs-gowl-bar-rewrite--header "\n"
   (mapconcat
    (lambda (a)
      (concat
       (mapconcat
        #'cmacs-gowl-bar-rewrite--escape
        (list (or (plist-get a :key) "")
              (plist-get a :id)
              (plist-get a :label)
              (concat (if (plist-get a :preview) "p" "")
                      (if (plist-get a :diff) "d" ""))
              (plist-get a :input)
              (plist-get a :provider)
              (plist-get a :model)
              (plist-get a :system)
              (plist-get a :instruction))
        "\t")
       "\n"))
    actions "")))

;;;; Pushing ----------------------------------------------------------

;;;###autoload
(defun cmacs-gowl-bar-rewrite-push ()
  "Push the cmacs action list to gowl's `ai-rewrite' widget.

Sends `actions', `actions-mode' and `ai-backend=cmacs', then the
provider names (`cmacs-gowl-bar-ai-push-providers').  Returns nil at
once and never signals: under --gowl this runs on the compositor's
thread, and a bar that is not running is not an error."
  (interactive)
  (condition-case err
      (progn
        (cmacs-gowl-bar-push
         cmacs-gowl-bar-rewrite-widget
         (list (cons "actions"
                     (cmacs-gowl-bar-rewrite-serialize
                      (cmacs-gowl-bar-rewrite-resolve)))
               (cons "actions-mode" cmacs-gowl-bar-rewrite-actions-mode)
               (cons "ai-backend" "cmacs")))
        (cmacs-gowl-bar-ai-push-providers cmacs-gowl-bar-rewrite-widget))
    (error
     (message "cmacs-gowl-bar-rewrite: could not push: %s"
              (error-message-string err))))
  nil)

(provide 'cmacs-gowl-bar-rewrite)

;;; cmacs-gowl-bar-rewrite.el ends here
