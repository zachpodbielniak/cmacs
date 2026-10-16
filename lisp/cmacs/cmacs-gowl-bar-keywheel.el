;;; cmacs-gowl-bar-keywheel.el --- Emacs bindings on gowl's key wheel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's `keywheel' bar widget (gowl's
;; modules/bar/bar-plugins-keywheel.c, docs/bar-widgets/keywheel.org).
;;
;; The wheel already shows every compositor keybind, cmacs's own
;; `gowl-add-keybind' ones included, because it reads them straight out
;; of the compositor's config.  What it cannot see is Emacs's own
;; keymaps.  This file pushes a bounded list of notable Emacs bindings
;; to the widget, which shows them as a fifth face, "Emacs":
;;
;;   keywheel.emacs.count   N
;;   keywheel.emacs.<i>     "KEY\tCOMMAND\tFIRST-DOC-LINE"   (i < N)
;;
;; Fields are joined by a real TAB; inside a field a backslash is
;; written `\\', a tab `\t' and a newline `\n'.  The bar unescapes them.
;;
;; Which bindings: `cmacs-gowl-bar-keywheel-sources', by default
;; everything under C-c in `global-map' (which is where user and
;; cmacs-ai menu bindings live), walked through nested prefix maps,
;; capped at `cmacs-gowl-bar-keywheel-max' entries.  Walking all of
;; `global-map' would push ~1000 built-in bindings nobody needs a
;; cheat sheet for.
;;
;; A row on the Emacs face is runnable.  The bar spawns
;;
;;   emacsctl eval '(cmacs-gowl-bar-keywheel-run "COMMAND")'
;;
;; and this file answers it.  Not with `call-interactively' there and
;; then: an RPC eval runs with `inhibit-interaction' bound, so a
;; command that reads a key or a file name would fail, and under
;; `cmacs --gowl' Emacs's thread is the compositor's, so it must return
;; at once.  The name is checked against the list last pushed -- the
;; bar can only ask for a command it was shown -- and the command runs
;; from a zero-delay timer, outside the RPC, where it may prompt.
;;
;; Wiring it up: call `cmacs-gowl-bar-keywheel-setup' once the session
;; is up (it pushes after Emacs goes idle, so bindings made later in
;; init are included), or `M-x cmacs-gowl-bar-keywheel-push' after
;; changing keymaps.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)

(defcustom cmacs-gowl-bar-keywheel-sources
  '((global-map . "C-c"))
  "Where the key wheel's Emacs face finds its bindings.

A list of (KEYMAP-VARIABLE . PREFIX).  PREFIX is a `kbd' string.  When
PREFIX names a prefix keymap inside the keymap, that sub-map is walked
and its keys are shown under PREFIX: `(global-map . \"C-c\")' lists
C-c bindings.  When it does not, the keymap itself is walked and
PREFIX is only how its keys are shown: `(doom-leader-map . \"SPC\")'
lists the Doom leader map as SPC bindings.  A nil PREFIX walks the
whole keymap.  Unbound variables are skipped."
  :type '(repeat (cons (symbol :tag "Keymap variable")
                       (choice (const :tag "Whole keymap" nil)
                               (string :tag "Prefix"))))
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-keywheel-max 300
  "Most bindings pushed to the key wheel.  The bar reads no more than 300."
  :type 'integer
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-keywheel-depth 4
  "How many nested prefix maps are followed below a source's prefix."
  :type 'integer
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-keywheel-doc-length 120
  "Characters of a command's first documentation line sent to the bar."
  :type 'integer
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-keywheel-raise-frame t
  "Non-nil to focus the selected frame before running a wheel command.
The wheel is a compositor overlay; the command it runs is an Emacs
command, and it should act where the user can see it."
  :type 'boolean
  :group 'cmacs-gowl-bar)

(defconst cmacs-gowl-bar-keywheel--widget "keywheel"
  "The bar widget this file pushes to.")

(defconst cmacs-gowl-bar-keywheel--visit-cap 20000
  "Hard bound on keymap entries looked at in one collection.
The push runs on Emacs's thread, which under --gowl is the
compositor's; a pathological keymap must not stall the desktop.")

(defvar cmacs-gowl-bar-keywheel--pushed nil
  "Hash table of command names last pushed; what the bar may run.")

;;;; Collecting ------------------------------------------------------

(defun cmacs-gowl-bar-keywheel--escape (text)
  "TEXT with backslash, tab and newline escaped for the bar."
  (let ((s (or text "")))
    ;; LITERAL replacements: "\\\\" is two characters, a backslash
    ;; doubled; "\\t" is a backslash and a `t'.
    (setq s (replace-regexp-in-string "\\\\" "\\\\" s t t))
    (setq s (replace-regexp-in-string "\t" "\\t" s t t))
    (replace-regexp-in-string "\n" "\\n" s t t)))

(defun cmacs-gowl-bar-keywheel--doc (command)
  "The first line of COMMAND's documentation, bounded; never signals."
  (let ((doc (condition-case nil
                 (documentation command t)
               (error nil))))
    (when (stringp doc)
      (let ((line (car (split-string doc "\n"))))
        (truncate-string-to-width
         (string-trim line) cmacs-gowl-bar-keywheel-doc-length)))))

(defun cmacs-gowl-bar-keywheel--skip-event-p (event)
  "Non-nil for EVENTs that are not keys a person types."
  (or (consp event)                   ; a character range
      (and (symbolp event)
           (or (memq event '(remap menu-bar tool-bar tab-bar header-line
                             mode-line compose-last-chars))
               (string-match-p "mouse\\|wheel\\|drag\\|touch"
                               (symbol-name event))))))

(defun cmacs-gowl-bar-keywheel--walk (map prefix depth out budget)
  "Collect (KEY COMMAND) pairs of MAP under PREFIX (a key vector).
DEPTH is how many more prefix maps to follow.  OUT is a list cell
whose car accumulates the result.  BUDGET is a one-element vector
counting entries still allowed to be visited."
  (map-keymap
   (lambda (event binding)
     (when (> (aref budget 0) 0)
       (aset budget 0 (1- (aref budget 0)))
       (unless (cmacs-gowl-bar-keywheel--skip-event-p event)
         (let ((keys (vconcat prefix (vector event))))
           (cond
            ((and (keymapp binding) (> depth 0))
             (cmacs-gowl-bar-keywheel--walk
              binding keys (1- depth) out budget))
            ((and binding (symbolp binding)
                  (not (eq binding 'undefined))
                  (commandp binding))
             (push (list (key-description keys) binding) (car out))))))))
   map))

(defun cmacs-gowl-bar-keywheel--source-map (source)
  "The (MAP . PREFIX-VECTOR) to walk for SOURCE, or nil."
  (let* ((var (car source))
         (prefix (cdr source))
         (map (and (symbolp var) (boundp var) (symbol-value var))))
    (when (keymapp map)
      (if (not (and (stringp prefix) (not (string-empty-p prefix))))
          (cons map [])
        (let* ((keys (condition-case nil (kbd prefix) (error nil)))
               (sub (and keys (lookup-key map keys))))
          (cond
           ((null keys) nil)
           ((keymapp sub) (cons sub (vconcat keys)))
           (t (cons map (vconcat keys)))))))))

(defun cmacs-gowl-bar-keywheel-collect ()
  "The bindings the key wheel's Emacs face shows.
A list of (KEY COMMAND DOC), sorted by KEY, no longer than
`cmacs-gowl-bar-keywheel-max' (and never more than 300)."
  (let ((out (list nil))
        (budget (vector cmacs-gowl-bar-keywheel--visit-cap))
        (seen (make-hash-table :test #'equal))
        result)
    (dolist (source cmacs-gowl-bar-keywheel-sources)
      (let ((walk (cmacs-gowl-bar-keywheel--source-map source)))
        (when walk
          (cmacs-gowl-bar-keywheel--walk
           (car walk) (cdr walk) (max 0 cmacs-gowl-bar-keywheel-depth)
           out budget))))
    (dolist (pair (car out))
      (unless (gethash (car pair) seen)
        (puthash (car pair) t seen)
        (push pair result)))
    (setq result (sort result (lambda (a b) (string< (car a) (car b)))))
    (let ((cap (max 0 (min 300 cmacs-gowl-bar-keywheel-max))))
      (when (> (length result) cap)
        (setq result (cl-subseq result 0 cap))))
    (mapcar (lambda (pair)
              (list (car pair) (cadr pair)
                    (cmacs-gowl-bar-keywheel--doc (cadr pair))))
            result)))

(defun cmacs-gowl-bar-keywheel--line (entry)
  "The wire form of one ENTRY, (KEY COMMAND DOC)."
  (mapconcat #'cmacs-gowl-bar-keywheel--escape
             (list (nth 0 entry) (symbol-name (nth 1 entry))
                   (or (nth 2 entry) ""))
             "\t"))

;;;; Pushing --------------------------------------------------------

;;;###autoload
(defun cmacs-gowl-bar-keywheel-push ()
  "Send the Emacs bindings to the key wheel's Emacs face.
Returns the number pushed.  Never signals: a bar that is not running
is not an error."
  (interactive)
  (let* ((entries (condition-case err
                      (cmacs-gowl-bar-keywheel-collect)
                    (error
                     (message "cmacs-gowl-bar-keywheel: %s"
                              (error-message-string err))
                     nil)))
         (table (make-hash-table :test #'equal))
         (alist (list (cons "emacs.count"
                            (number-to-string (length entries)))))
         (i 0))
    (dolist (entry entries)
      (puthash (symbol-name (nth 1 entry)) t table)
      (push (cons (format "emacs.%d" i)
                  (cmacs-gowl-bar-keywheel--line entry))
            alist)
      (setq i (1+ i)))
    (setq cmacs-gowl-bar-keywheel--pushed table)
    (cmacs-gowl-bar-push cmacs-gowl-bar-keywheel--widget (nreverse alist))
    (when (called-interactively-p 'interactive)
      (message "Key wheel: %d Emacs bindings" (length entries)))
    (length entries)))

;;;###autoload
(defun cmacs-gowl-bar-keywheel-setup ()
  "Push the Emacs face once Emacs is idle.
Idle, so bindings made later in init are included.  Safe to call more
than once; safe when the bar does not have the widget."
  (run-with-idle-timer 2 nil #'cmacs-gowl-bar-keywheel-push)
  t)

;;;; Running ----------------------------------------------------------

(defun cmacs-gowl-bar-keywheel--call (command)
  "Run COMMAND interactively, reporting rather than signalling."
  (when cmacs-gowl-bar-keywheel-raise-frame
    (ignore-errors (select-frame-set-input-focus (selected-frame))))
  (condition-case err
      (call-interactively command)
    (quit (message "Key wheel: %s cancelled" command))
    (error (message "Key wheel: %s: %s" command
                    (error-message-string err)))))

;;;###autoload
(defun cmacs-gowl-bar-keywheel-run (name)
  "Run the command NAME, a string the key wheel sends.
Only a command in the list last pushed is run, and it runs from a timer
so it may prompt.  Returns t when scheduled, nil otherwise; never
signals, never prompts (it is called through `emacsctl eval')."
  (let ((command (and (stringp name)
                      cmacs-gowl-bar-keywheel--pushed
                      (gethash name cmacs-gowl-bar-keywheel--pushed)
                      (intern-soft name))))
    (cond
     ((and command (commandp command))
      (run-at-time 0 nil #'cmacs-gowl-bar-keywheel--call command)
      t)
     (t
      (message "Key wheel: not running %S (not in the pushed list)" name)
      nil))))

(provide 'cmacs-gowl-bar-keywheel)

;;; cmacs-gowl-bar-keywheel.el ends here
