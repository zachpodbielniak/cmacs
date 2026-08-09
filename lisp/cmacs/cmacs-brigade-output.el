;;; cmacs-brigade-output.el --- Seeing what an agent produced  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A run that finishes and leaves nothing to read is a run you cannot use.
;;
;; Output used to be handed to `cmacs-brigade-run-finished-functions' and
;; then dropped, so the dashboard could tell you a task had succeeded and
;; nothing else -- which is most of the way to useless, since the answer
;; is the entire point of having run it.
;;
;; Kept on disk as well as in memory, because the interesting question is
;; usually "what did last night's run say", and an in-memory table does
;; not survive the restart between then and now.  Failures are kept too:
;; the output of a failed run is where the reason is.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-evil)
(require 'subr-x)

(defcustom cmacs-brigade-output-dir
  (expand-file-name "output" cmacs-brigade-state-dir)
  "Where run output is kept, one file per task."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-output-keep-days 30
  "How long output files are kept.  nil keeps them forever.

Output is small text and occasionally the only record of what an agent
concluded, so the default is generous."
  :type '(choice (const :tag "Forever" nil) integer)
  :group 'cmacs-brigade)

(defvar cmacs-brigade-output--cache (make-hash-table :test 'equal)
  "Task id -> output text, for the current session.
Keyed by task id for the latest turn, and by \"ID/TURN\" for a specific
one.")

(declare-function cmacs-brigade-conversation-turn "cmacs-brigade-run")

(defun cmacs-brigade-output--turn (id)
  "Which turn of task ID is current, or nil when it has no conversation."
  (and (fboundp 'cmacs-brigade-conversation-turn)
       (cmacs-brigade-conversation-turn id)))

(defun cmacs-brigade-output-file (id &optional turn)
  "Path holding ID's output, for TURN or for the latest."
  (expand-file-name (if (and turn (> turn 0))
                        (format "%s.%d.txt" id turn)
                      (format "%s.txt" id))
                    cmacs-brigade-output-dir))

(defun cmacs-brigade-output-put (id text &optional turn)
  "Record TEXT as the output of task ID, on TURN if given.

Written twice when there is a turn: once under `<id>.<turn>.txt', which
is never overwritten, and once as `<id>.txt', which is always the latest.
A single file was fine when a task ran once; with a conversation, turn
N+1 finishing used to destroy turn N's answer both on disk and in the
cache -- including the case where the parent had not collected it yet,
which for a model that polls is entirely normal."
  (when (and id text)
    (puthash id text cmacs-brigade-output--cache)
    (when (and turn (> turn 0))
      (puthash (format "%s/%d" id turn) text cmacs-brigade-output--cache))
    (condition-case err
        (progn
          (make-directory cmacs-brigade-output-dir t)
          (let ((coding-system-for-write 'utf-8))
            (when (and turn (> turn 0))
              (with-temp-file (cmacs-brigade-output-file id turn)
                (insert text)))
            (with-temp-file (cmacs-brigade-output-file id)
              (insert text))))
      ;; A run whose output cannot be written to disk is still a run
      ;; whose output you want to read, so this must not fail the task.
      (error (message "cmacs-brigade: could not save output for %s: %s"
                      id (error-message-string err))))
    text))

(defun cmacs-brigade-output-get (id &optional turn)
  "Return the output of task ID, from memory or from disk.
TURN selects one turn's reply; nil returns the most recent."
  (or (gethash (if (and turn (> turn 0)) (format "%s/%d" id turn) id)
               cmacs-brigade-output--cache)
      (let ((file (cmacs-brigade-output-file id turn)))
        (when (file-readable-p file)
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8))
              (insert-file-contents file))
            (buffer-string))))))

(defun cmacs-brigade-output--record (task-id _state output)
  "Store OUTPUT when TASK-ID finishes.

The run layer also records it, inside the turn it belongs to, because
only it knows the turn number.  This stays registered anyway: it is the
guarantee that output is captured for *any* caller of the finished hook,
including a worker that reports completion its own way, and writing the
same text twice costs a file write nobody notices."
  (cmacs-brigade-output-put task-id output
                            (cmacs-brigade-output--turn task-id)))

(add-hook 'cmacs-brigade-run-finished-functions
          #'cmacs-brigade-output--record)


;;;; Viewing

(defvar cmacs-brigade-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'cmacs-brigade-output-revert)
    (define-key map (kbd "w") #'cmacs-brigade-output-copy)
    ;; Reply from where you read.  Having to go back to the dashboard to
    ;; answer something you are looking at is the wrong shape.
    (define-key map (kbd "i") #'cmacs-brigade-output-send)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    map)
  "Keymap for `cmacs-brigade-output-mode'.")

(define-derived-mode cmacs-brigade-output-mode special-mode "Brigade-Out"
  "Read an agent's output."
  (setq truncate-lines nil)
  (visual-line-mode 1))

(cmacs-evil-setup-mode-map cmacs-brigade-output-mode-map
                           'cmacs-brigade-output-mode)

(defvar-local cmacs-brigade-output--id nil
  "Task whose output this buffer shows.")

(defun cmacs-brigade-output-revert ()
  "Re-read this task's output."
  (interactive)
  (when cmacs-brigade-output--id
    (cmacs-brigade-output-show cmacs-brigade-output--id)))

(defun cmacs-brigade-output-copy ()
  "Copy this output to the kill ring."
  (interactive)
  (kill-new (buffer-substring-no-properties (point-min) (point-max)))
  (message "cmacs-brigade: output copied"))

(declare-function cmacs-brigade-mailbox-send "cmacs-brigade-mailbox")
(declare-function cmacs-brigade-mailbox-count "cmacs-brigade-mailbox")

(defun cmacs-brigade-output-send (message)
  "Say something more to the agent whose output this is.

Guarded rather than required: this buffer must stay readable in a session
where nothing runs, so the mailbox is a capability it uses when present
rather than a dependency it loads."
  (interactive "sMessage: ")
  (unless cmacs-brigade-output--id
    (user-error "This buffer is not showing a task"))
  (unless (fboundp 'cmacs-brigade-mailbox-send)
    (user-error "cmacs-brigade: the mailbox is not loaded"))
  (when (string-empty-p (string-trim message))
    (user-error "Nothing to send"))
  (cmacs-brigade-mailbox-send cmacs-brigade-output--id message "human")
  (message "cmacs-brigade: queued for %s (%d waiting)"
           cmacs-brigade-output--id
           (cmacs-brigade-mailbox-count cmacs-brigade-output--id)))

;;;###autoload
(defun cmacs-brigade-output-show (id)
  "Show the output of task ID."
  (interactive
   (list (completing-read
          "Task: "
          (if (fboundp 'cmacs-brigade-task-list)
              (mapcar (lambda (r) (plist-get r :id)) (cmacs-brigade-task-list))
            (hash-table-keys cmacs-brigade-output--cache))
          nil nil)))
  (let* ((text (cmacs-brigade-output-get id))
         ;; The whole conversation when there is one, which for a
         ;; multi-turn task is the only view that makes sense: the flat
         ;; text is a single turn's reply, and showing it alone under the
         ;; heading of the task reads as though that were all that
         ;; happened.  Falls back to the flat text on its own.
         (log (and (fboundp 'cmacs-brigade-log-render)
                   (cmacs-brigade-log-render id)))
         (rec (and (fboundp 'cmacs-brigade-task-get)
                   (cmacs-brigade-task-get id)))
         (buf (get-buffer-create (format "*brigade output: %s*" id))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cmacs-brigade-output-mode)
        (setq cmacs-brigade-output--id id)
        (when rec
          (insert (propertize (or (plist-get rec :title) id) 'face 'bold) "\n")
          (insert (propertize
                   (format "%s  %s  %s turns  %s/%s tokens  $%.4f\n"
                           (plist-get rec :state)
                           (or (plist-get rec :agent) "—")
                           (or (plist-get rec :turns) 0)
                           (or (plist-get rec :in-tokens) 0)
                           (or (plist-get rec :out-tokens) 0)
                           (/ (or (plist-get rec :cost-micros) 0) 1000000.0))
                   'face 'shadow))
          (when-let* ((e (plist-get rec :error)))
            (insert (propertize (format "%s\n" e) 'face 'error)))
          (insert (make-string 72 ?─) "\n\n"))
        (cond
         ((and log (not (string-empty-p (string-trim log)))) (insert log))
         ((and text (not (string-empty-p (string-trim text)))) (insert text))
         ;; A finished run with nothing to show is worth saying out loud
         ;; rather than presenting as an empty buffer, because the two
         ;; look identical and mean very different things.
         ((and rec (memq (plist-get rec :state) '(draft queued)))
          (insert "Not started yet."))
         (t (insert "This run produced no output.")))
        (goto-char (point-min))))
    (pop-to-buffer buf)
    buf))


;;;; Housekeeping

(defun cmacs-brigade-output-prune ()
  "Delete output files older than `cmacs-brigade-output-keep-days'."
  (interactive)
  (when (and cmacs-brigade-output-keep-days
             (file-directory-p cmacs-brigade-output-dir))
    (let ((cutoff (- (float-time) (* cmacs-brigade-output-keep-days 86400)))
          (n 0))
      ;; `.jsonl' as well as `.txt', and the per-turn `<id>.<N>.txt' the
      ;; plain pattern already catches.  Missing the logs here would have
      ;; left the thing that actually grows -- one line per tool call --
      ;; accumulating forever while the small files were tidied.
      (dolist (f (directory-files cmacs-brigade-output-dir t
                                  "\\.\\(txt\\|jsonl\\)\\'"))
        (when (< (float-time (file-attribute-modification-time
                              (file-attributes f)))
                 cutoff)
          (ignore-errors (delete-file f) (setq n (1+ n)))))
      (when (called-interactively-p 'any)
        (message "cmacs-brigade: pruned %d output file(s)" n))
      n)))

(provide 'cmacs-brigade-output)

;;; cmacs-brigade-output.el ends here
