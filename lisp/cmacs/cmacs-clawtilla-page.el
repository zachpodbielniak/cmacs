;;; cmacs-clawtilla-page.el --- One buffer kind for a list and its verbs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Most of what the GTK client grew between clawtilla 0.11 and 0.52 is
;; the same thing many times: ask the daemon for a list, draw a row per
;; entry with a line of detail under it, and offer three or four verbs
;; on the row.  Projects, paired devices, version history, saved steps,
;; waits, sentinel issues, the egress allowlist -- each is that.
;;
;; So there is one buffer kind for them.  A page is a declaration:
;;
;;   (cmacs-clawtilla-define-page "devices"
;;     :title "Paired devices"
;;     :intro "Each holds a token of its own ..."
;;     :fetch '((devices "device.list"))
;;     :draw #'cmacs-clawtilla-devices--draw
;;     :events "\\`device\\."
;;     :verbs '(("i" "pair a new device" cmacs-clawtilla-devices-pair)
;;              ("D" "revoke" cmacs-clawtilla-devices-revoke)))
;;
;; and everything that is the same for all of them lives here once: the
;; fetch (every frame of a page in parallel, each kept both parsed and as
;; the text the daemon sent), the redraw that keeps point on its row, the
;; coalesced reload when an event the page cares about arrives, the
;; transient built from the verbs, and the keys.
;;
;; The keys are the part that is not obvious.  A clawtilla buffer is an
;; Evil INTERCEPT map (see `cmacs-clawtilla-setup-evil'), promoted per
;; major mode -- so a keymap per page would be a mode per page.  Instead
;; the one mode map binds every letter that is safe to take in a
;; read-only buffer to a single dispatcher, which runs whichever verb
;; the current page gave that key and says so when it gave none.  A page
;; therefore cannot bind a motion key even by mistake: the dispatcher is
;; simply not bound there.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar cmacs-clawtilla-pages nil
  "Every page defined with `cmacs-clawtilla-define-page', by name.

An alist of name to plist; see that function for the plist.")

(defvar-local cmacs-clawtilla-page--name nil
  "Which page this buffer shows.")
(defvar-local cmacs-clawtilla-page--agent nil
  "The agent this page is scoped to, for a page that is per-agent.")
(defvar-local cmacs-clawtilla-page--room nil
  "The room this page is scoped to, for a page that is per-conversation.")
(defvar-local cmacs-clawtilla-page--arg nil
  "What this page is about, for a page about one thing: a task's id.")
(defvar-local cmacs-clawtilla-page--data nil
  "What the page's frames answered: an alist of key to (DATA TEXT ERROR).")
(defvar-local cmacs-clawtilla-page--state nil
  "The page's own state, a plist: a chosen period, a filter, a countdown.")
(defvar-local cmacs-clawtilla-page--loaded nil
  "Non-nil once every frame of the page has answered at least once.")


;;;; Defining one.

(defun cmacs-clawtilla-define-page (name &rest spec)
  "Define the page NAME from the plist SPEC and return NAME.

SPEC takes:

`:title'        the heading, or a function of no arguments returning it
                (for a heading that is libclawt's to word).
`:intro'        a sentence or two under it, dimmed, or a function of no
                arguments returning one (called in the buffer).
`:needs-agent'  non-nil for a page about one agent; opening it without
                one asks.
`:fetch'        a list of (KEY KIND [PAYLOAD]) -- the frames that fill
                the page.  PAYLOAD is an alist, or a function of no
                arguments returning one, called in the buffer.  Every
                frame is sent at once; the page draws when all have
                answered.  A page scoped to an agent has `agent' added
                to each payload, and one scoped to a room `room'.
`:draw'         a function of no arguments that inserts the page's body.
`:verbs'        a list of (KEY LABEL COMMAND) offered on the page: KEY
                is one of `cmacs-clawtilla-page-verb-keys' or \"RET\".
`:events'       a regexp matched against daemon event kinds; a match
                reloads the page.  Or a function of (KIND DATA) returning
                non-nil to reload, called in the buffer.
`:on-event'     a function of (KIND DATA) called in the buffer for every
                event on its connection, for a page that reacts to one
                beyond reloading."
  (setf (alist-get name cmacs-clawtilla-pages nil nil #'equal) spec)
  name)

(defun cmacs-clawtilla-page--spec (&optional name)
  "Return the spec of page NAME, or of this buffer's page."
  (alist-get (or name cmacs-clawtilla-page--name)
             cmacs-clawtilla-pages nil nil #'equal))


;;;; What a page reads.

(defun cmacs-clawtilla-page-data (key &rest path)
  "Return PATH within what the frame KEY answered, parsed."
  (apply #'cmacs-clawtilla-get
         (nth 0 (alist-get key cmacs-clawtilla-page--data)) path))

(defun cmacs-clawtilla-page-text (key)
  "Return what the frame KEY answered, as the JSON text the daemon sent.

This is what goes to `cmacs-clawtilla-ask' as (:json . TEXT)."
  (nth 1 (alist-get key cmacs-clawtilla-page--data)))

(defun cmacs-clawtilla-page-error (key)
  "Return why the frame KEY failed, or nil if it did not."
  (nth 2 (alist-get key cmacs-clawtilla-page--data)))

(defun cmacs-clawtilla-page-member-text (key &rest path)
  "Return PATH within the frame KEY's answer as JSON text, or nil.

For handing one entry of a reply to the library as the daemon sent it."
  (cmacs-clawtilla-faithful-text
   (apply #'cmacs-clawtilla-faithful-get
          (cmacs-clawtilla-faithful (cmacs-clawtilla-page-text key))
          path)))

(defun cmacs-clawtilla-page-state (key)
  "Return the page's own state under KEY."
  (plist-get cmacs-clawtilla-page--state key))

(defun cmacs-clawtilla-page-set-state (key value)
  "Set the page's own state under KEY to VALUE."
  (setq cmacs-clawtilla-page--state
        (plist-put cmacs-clawtilla-page--state key value)))

(defun cmacs-clawtilla-payload (&rest pairs)
  "Return a payload alist from PAIRS, a plist, leaving out what is nil.

The GTK client's `clawt_build_payload' in miniature: a field that was
left blank is absent from the frame rather than sent empty, because the
daemon reads an empty string as a value somebody chose."
  (cl-loop for (key value) on pairs by #'cddr
           unless (or (null value)
                      (and (stringp value) (string-empty-p value)))
           collect (cons (if (keywordp key)
                             (intern (substring (symbol-name key) 1))
                           key)
                         value)))


;;;; Drawing.

(defun cmacs-clawtilla-page-insert-row (type value heading &rest detail)
  "Insert VALUE as a row of TYPE under HEADING, with DETAIL lines beneath.

DETAIL is strings; nil and empty ones are skipped, and a string holding
newlines is one line each.  They are drawn dimmed and belong to the row,
so a verb run with point on the detail acts on the row."
  (cmacs-clawtilla-insert-section
   :type type :value value :level 1 :heading heading
   :body (lambda ()
           (dolist (text detail)
             (when (and (stringp text) (not (string-empty-p text)))
               (dolist (line (split-string text "\n" t))
                 (insert "      " (cmacs-clawtilla-dim line) "\n")))))))

(defun cmacs-clawtilla-page-insert-note (title &optional text)
  "Insert TITLE with TEXT under it: an empty page saying what belongs there."
  (insert "  " (propertize title 'face 'bold) "\n")
  (when (and text (not (string-empty-p text)))
    (cmacs-clawtilla-page--insert-filled text "  ")))

(defun cmacs-clawtilla-page--insert-filled (text prefix)
  "Insert TEXT dimmed and filled, each line starting with PREFIX."
  (let ((start (point))
        (fill-prefix prefix)
        (fill-column (max 40 (min 78 (- (window-width) 2)))))
    (insert prefix text "\n")
    (fill-region start (point))
    (add-face-text-property start (point) 'cmacs-clawtilla-dim)))

(defun cmacs-clawtilla-page-tone-face (tone)
  "Return the face for TONE, one of libclawt's badge tones."
  (pcase tone
    ("good" 'cmacs-clawtilla-running)
    ("warn" 'cmacs-clawtilla-busy)
    ("bad" 'cmacs-clawtilla-error)
    (_ 'cmacs-clawtilla-dim)))

(defun cmacs-clawtilla-page--title (&optional spec)
  "Return the title of the page SPEC, or of this buffer's page."
  (let ((title (plist-get (or spec (cmacs-clawtilla-page--spec)) :title)))
    (or (if (functionp title) (funcall title) title)
        cmacs-clawtilla-page--name
        "Page")))

(defun cmacs-clawtilla-page--draw ()
  "Redraw the page buffer."
  (let ((spec (cmacs-clawtilla-page--spec)))
    (cmacs-clawtilla-ui-preserving
      (insert (propertize (cmacs-clawtilla-page--title spec)
                          'face 'cmacs-clawtilla-heading))
      (when cmacs-clawtilla-page--agent
        (insert "  " (cmacs-clawtilla-dim
                      (format "for %s" cmacs-clawtilla-page--agent))))
      (when cmacs-clawtilla-page--room
        (insert "  " (cmacs-clawtilla-dim
                      (format "in %s" cmacs-clawtilla-page--room))))
      (when cmacs-clawtilla-page--arg
        (insert "  " (cmacs-clawtilla-dim cmacs-clawtilla-page--arg)))
      (insert "\n")
      (let ((intro (plist-get spec :intro)))
        (when (functionp intro) (setq intro (funcall intro)))
        (when (and (stringp intro) (not (string-empty-p intro)))
          (cmacs-clawtilla-page--insert-filled intro "")))
      (insert "\n")
      (cond
       ((null spec)
        (insert "  " (propertize "This build has no such page."
                                 'face 'cmacs-clawtilla-error)
                "\n"))
       ((not cmacs-clawtilla-page--loaded)
        (insert "  " (cmacs-clawtilla-dim "asking the daemon…") "\n"))
       (t
        ;; A frame that failed says so above whatever the rest drew: a
        ;; page that silently shows less is a page that lies.
        (dolist (entry cmacs-clawtilla-page--data)
          (when (nth 3 entry)
            (insert "  " (propertize (format "%s" (nth 3 entry))
                                     'face 'cmacs-clawtilla-error)
                    "\n")))
        (funcall (plist-get spec :draw))))
      (insert "\n  " (cmacs-clawtilla-dim "? lists what this page can do")
              "\n"))))


;;;; Loading.

(defun cmacs-clawtilla-page--scope ()
  "Return the payload fragment naming this page's agent or room."
  (append (and cmacs-clawtilla-page--agent
               (list (cons 'agent cmacs-clawtilla-page--agent)))
          (and cmacs-clawtilla-page--room
               (list (cons 'room cmacs-clawtilla-page--room)))))

(defun cmacs-clawtilla-page-load (&optional buffer)
  "Refetch every frame of the page in BUFFER and redraw when all answer."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (spec (with-current-buffer buffer (cmacs-clawtilla-page--spec)))
         (frames (plist-get spec :fetch))
         (pending (length frames))
         (answers nil))
    (if (null frames)
        (with-current-buffer buffer
          (setq cmacs-clawtilla-page--loaded t)
          (cmacs-clawtilla-page--draw))
      (dolist (frame frames)
        (pcase-let ((`(,key ,kind ,payload) frame))
          (cmacs-clawtilla-request-both
           conn kind
           (with-current-buffer buffer
             (append (if (functionp payload) (funcall payload) payload)
                     (cmacs-clawtilla-page--scope)))
           (lambda (data text err)
             (push (list key data text err) answers)
             (setq pending (1- pending))
             (when (and (zerop pending) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (setq cmacs-clawtilla-page--data answers)
                 (setq cmacs-clawtilla-page--loaded t)
                 (cmacs-clawtilla-page--draw))))))))))

(defvar cmacs-clawtilla-page--pending nil
  "Page buffers with a coalesced reload waiting.")

(defun cmacs-clawtilla-page-reload-soon (buffer)
  "Reload BUFFER once, shortly, however many events asked."
  (unless (memq buffer cmacs-clawtilla-page--pending)
    (push buffer cmacs-clawtilla-page--pending)
    (run-at-time 0.4 nil
                 (lambda ()
                   (setq cmacs-clawtilla-page--pending
                         (delq buffer cmacs-clawtilla-page--pending))
                   (when (buffer-live-p buffer)
                     (ignore-errors (cmacs-clawtilla-page-load buffer)))))))

(defun cmacs-clawtilla-page-buffers (&optional name conn)
  "Return the live page buffers, showing NAME on CONN when those are given."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'cmacs-clawtilla-page-mode)
                       (or (null name) (equal cmacs-clawtilla-page--name name))
                       (or (null conn) (eq cmacs-clawtilla-connection conn)))))
              (buffer-list)))

(defun cmacs-clawtilla-page--on-event (conn kind data)
  "Let every page on CONN react to the event KIND carrying DATA."
  (dolist (buffer (cmacs-clawtilla-page-buffers nil conn))
    (with-current-buffer buffer
      (let* ((spec (cmacs-clawtilla-page--spec))
             (events (plist-get spec :events))
             (handler (plist-get spec :on-event)))
        (when handler (funcall handler kind data))
        (when (cond ((stringp events) (string-match-p events kind))
                    ((functionp events) (funcall events kind data)))
          (cmacs-clawtilla-page-reload-soon buffer))))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-page--on-event)


;;;; Acting.

(defun cmacs-clawtilla-page-send (kind payload &optional said then)
  "Send KIND with PAYLOAD from a page, then say SAID and reload it.

SAID is a string, or a function of the reply returning one -- for the
cases where what happened depends on what the daemon answered.  THEN, if
given, is called with the reply after the reload is asked for."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind payload
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((text (if (functionp said) (funcall said data) said)))
           (when text (message "clawtilla: %s" text)))
         (when (and (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (derived-mode-p 'cmacs-clawtilla-page-mode)))
           (cmacs-clawtilla-page-load buffer))
         (when then (funcall then data)))))))

(defun cmacs-clawtilla-page-row (&optional type)
  "Return the row at point, of TYPE if given, or signal."
  (or (cmacs-clawtilla-value-at-point type)
      (user-error "Nothing at point to do that to")))

(defun cmacs-clawtilla-page-need-agent ()
  "Return the agent this page is about, or signal."
  (or cmacs-clawtilla-page--agent
      (user-error "This page is about one agent; open it from an agent")))

(defun cmacs-clawtilla-read-agent (prompt &optional conn allow-none)
  "Read an agent id with PROMPT, completing over CONN's fleet.

ALLOW-NONE non-nil accepts an empty answer and returns nil.  The fleet
is whatever the fleet buffer last fetched; with nothing cached this is
a plain prompt, never a request -- there is no synchronous one."
  (let* ((conn (or conn (ignore-errors (cmacs-clawtilla-current))))
         (ids (and conn
                   (delq nil (mapcar (lambda (agent) (alist-get 'id agent))
                                     (cmacs-clawtilla-connection-agents
                                      conn)))))
         (answer (if ids
                     (completing-read prompt ids nil nil)
                   (read-string prompt))))
    (if (string-empty-p answer)
        (if allow-none nil (user-error "An agent is needed"))
      answer)))

(defun cmacs-clawtilla-page-show-text (name text &optional mode)
  "Show TEXT in a buffer called NAME, in MODE or `special-mode'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text ""))
        (goto-char (point-min)))
      (if (and mode (fboundp mode))
          (progn (funcall mode) (setq buffer-read-only t))
        (special-mode)))
    (cmacs-clawtilla-display buffer)))


;;;; Keys.

(defconst cmacs-clawtilla-page-verb-keys
  '("a" "c" "d" "i" "m" "o" "p" "r" "s" "u" "v" "x" "y" "z"
    "A" "C" "D" "I" "J" "K" "O" "P" "Q" "R" "S" "U" "V" "X" "Y" "Z"
    "RET" "+" "-" "=" "!")
  "The keys a page may give a verb.

Every letter that is not a way an Evil user moves: these buffers are
intercept maps, so a key bound here is a key Evil never sees.  `d', `c'
and `x' cost nothing in a read-only buffer; `j', `k', `n', `w' and the
rest would cost the buffer.")

(defun cmacs-clawtilla-page--verb-for (key)
  "Return the verb this page gives KEY, a (KEY LABEL COMMAND) list."
  (seq-find (lambda (verb) (equal (car verb) key))
            (plist-get (cmacs-clawtilla-page--spec) :verbs)))

(defun cmacs-clawtilla-page-act ()
  "Run the verb this page gives the key that was pressed."
  (interactive)
  (let* ((key (key-description (this-command-keys-vector)))
         (verb (cmacs-clawtilla-page--verb-for key)))
    (if verb
        (call-interactively (nth 2 verb))
      (user-error "%s does nothing on this page; ? lists what does" key))))

(defun cmacs-clawtilla-page--menu-children (_children)
  "Return this page's verbs as transient suffixes."
  (transient-parse-suffixes
   'cmacs-clawtilla-page-menu
   (append
    (mapcar (lambda (verb) (list (nth 0 verb) (nth 1 verb) (nth 2 verb)))
            (plist-get (cmacs-clawtilla-page--spec) :verbs))
    '(("gr" "refresh" cmacs-clawtilla-refresh)
      ("q" "quit" quit-window)))))

(transient-define-prefix cmacs-clawtilla-page-menu ()
  "What this page can do."
  [:description
   cmacs-clawtilla-page--title
   :class transient-column
   :setup-children cmacs-clawtilla-page--menu-children])

(defvar cmacs-clawtilla-page-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (dolist (key cmacs-clawtilla-page-verb-keys)
      (define-key map (kbd key) #'cmacs-clawtilla-page-act))
    (define-key map (kbd "?") #'cmacs-clawtilla-page-menu)
    map)
  "Keymap for `cmacs-clawtilla-page-mode'.")

(define-derived-mode cmacs-clawtilla-page-mode special-mode
  "Clawtilla-Page"
  "Major mode for one clawtilla list page.

Which page, and so which verbs, is the buffer's own; `?' lists them."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-page-load (current-buffer))))
  (setq-local truncate-lines t))

(defun cmacs-clawtilla-page-arg ()
  "Return what this page is about: the ARG it was opened with."
  cmacs-clawtilla-page--arg)

(defun cmacs-clawtilla-page-open (name &optional conn agent room arg)
  "Open the page NAME on CONN, scoped to AGENT or ROOM, and return its buffer.

ARG is what a page about one thing is about -- a task's id -- kept for
its `:fetch' payloads and its verbs to read with `cmacs-clawtilla-page-arg'."
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (spec (cmacs-clawtilla-page--spec name))
         (agent (or agent
                    (and (plist-get spec :needs-agent)
                         (cmacs-clawtilla-read-agent "Which agent? " conn))))
         (buffer (get-buffer-create
                  (format "*clawtilla %s%s*" name
                          (cond (arg (format ": %s" arg))
                                (agent (format ": %s" agent))
                                (room (format ": %s" room))
                                (t ""))))))
    (unless spec (user-error "There is no clawtilla page called %s" name))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-page-mode)
        (cmacs-clawtilla-page-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq cmacs-clawtilla-page--name name)
      (setq cmacs-clawtilla-page--agent agent)
      (setq cmacs-clawtilla-page--room room)
      (setq cmacs-clawtilla-page--arg arg)
      (cmacs-clawtilla-page--draw)
      (cmacs-clawtilla-page-load buffer))
    (cmacs-clawtilla-display buffer)))

;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-page-mode-map 'cmacs-clawtilla-page-mode)

(provide 'cmacs-clawtilla-page)

;;; cmacs-clawtilla-page.el ends here
