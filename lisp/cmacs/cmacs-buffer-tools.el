;;; cmacs-buffer-tools.el --- The buffer tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The eight tools of cmacs/mcp/cmacs-mcp-tools-buffer.c, written once
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Same wire names,
;; same parameters, same result text: the C handlers printed their value
;; with `prin1', so these do too (`cmacs-core-tools-print').
;;
;; What differs from the C, all of it on purpose:
;;
;;   - No argument is spliced into Lisp source.
;;
;;   - A failure is signalled instead of being returned as text.  That
;;     includes `find_file', whose C handler called `find-file' through
;;     `safe_calln' and answered with the path whether or not the file
;;     had opened.
;;
;;   - The redaction contract (cmacs-redact.el).  `list_buffers' leaves
;;     out a buffer the rules exclude; every other tool answers such a
;;     buffer exactly as it answers one that does not exist.
;;
;;   - The tools that write are marked :destructive (so a read-only agent
;;     is never handed them, and they stay off D-Bus and emacsctl until a
;;     configuration names those surfaces) and :confirm 'ask (so
;;     `cmacs-brigade-auto-approve' governs them like every other writing
;;     tool).  Neither changes what an MCP client that was already
;;     allowed to call them sees.
;;
;;   - `kill_buffer', `save_buffer' and `find_file' bind
;;     `inhibit-interaction'.  The C dispatch bound it for them; an
;;     in-process agent's call does not come through that dispatch, and
;;     "kill modified buffer?" asked from a tool call is a prompt nobody
;;     is there to answer.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-buffer "cmacs-core-tools" (name))
(declare-function cmacs-core-tools-check-name "cmacs-core-tools" (name))
(declare-function cmacs-core-tools-buffer-hidden-p "cmacs-core-tools"
                  (buffer-or-name))
(declare-function cmacs-core-tools-file-hidden-p "cmacs-core-tools"
                  (file &optional project))

(defun cmacs-buffer-tools--range-p (start end)
  "Non-nil when START and END name a range the way the C handlers took one.
Both must be given and positive; anything else means the whole buffer."
  (and (integerp start) (integerp end) (> start 0) (> end 0)))

(cmacs-brigade-deftool list-buffers
  "List all buffers with name, file, modified status, major-mode, and size. \
Returns pipe-separated fields, one buffer per line."
    ()
  :group 'buffer
  :example "emacsctl tool buffer list-buffers"
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat
    (lambda (b)
      (format "%s|%s|%s|%s|%d"
              (buffer-name b)
              (or (buffer-file-name b) "")
              (if (buffer-modified-p b) "modified" "unmodified")
              (with-current-buffer b (symbol-name major-mode))
              (buffer-size b)))
    ;; An excluded buffer is not listed at all: a blanked row would
    ;; still say that something is there.
    (seq-remove #'cmacs-core-tools-buffer-hidden-p (buffer-list))
    "\n")))

(cmacs-brigade-deftool get-buffer-content
  "Read the text content of a buffer. Optionally specify start/end positions."
    ((buffer string "Buffer name")
     (start integer "Start position (1-based)" :optional t)
     (end integer "End position (1-based)" :optional t))
  :group 'buffer
  :example "emacsctl tool buffer get-buffer-content --buffer '*scratch*'"
  (require 'cmacs-core-tools)
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (cmacs-core-tools-print
     (if (cmacs-buffer-tools--range-p start end)
         (buffer-substring-no-properties start end)
       (buffer-substring-no-properties (point-min) (point-max))))))

(cmacs-brigade-deftool set-buffer-content
  "Replace text in a buffer. If start/end given, replaces that range; \
otherwise replaces entire buffer content."
    ((buffer string "Buffer name")
     (content string "New text content")
     (start integer "Start position (1-based)" :optional t)
     (end integer "End position (1-based)" :optional t))
  :group 'buffer :destructive t :confirm 'ask
  :undo 'cmacs-brigade-undo-capture-buffer-text
  (require 'cmacs-core-tools)
  (unless (stringp content)
    (error "Missing required arguments: buffer, content"))
  ;; A read-only buffer signals `buffer-read-only' from the first edit,
  ;; as it did under the C handler: nothing here binds
  ;; `inhibit-read-only'.
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    (if (cmacs-buffer-tools--range-p start end)
        (progn (delete-region start end)
               (goto-char start)
               (insert content))
      (erase-buffer)
      (insert content))
    (cmacs-core-tools-print t)))

(cmacs-brigade-deftool create-buffer
  "Create a new buffer with an optional initial content."
    ((name string "Buffer name")
     (content string "Initial content" :optional t))
  :group 'buffer :destructive t :confirm 'ask
  :undo 'cmacs-brigade-undo-capture-create-buffer
  (require 'cmacs-core-tools)
  (unless (and (stringp name) (not (string-empty-p name)))
    (error "Missing required argument: name"))
  ;; `get-buffer-create' returns an existing buffer of that name, and the
  ;; content is then inserted into it -- so this can write to a buffer
  ;; that is already open, and an excluded one must be refused here too.
  (cmacs-core-tools-check-name name)
  (cmacs-core-tools-print
   (if content
       (with-current-buffer (get-buffer-create name)
         (insert content)
         (buffer-name))
     (buffer-name (get-buffer-create name)))))

(cmacs-brigade-deftool kill-buffer
  "Kill (close) a buffer."
    ((buffer string "Buffer name"))
  :group 'buffer :destructive t :confirm 'ask
  :undo 'cmacs-brigade-undo-capture-kill-buffer
  (require 'cmacs-core-tools)
  (let ((target (cmacs-core-tools-buffer buffer))
        (inhibit-interaction t))
    (cmacs-core-tools-print (kill-buffer target))))

(cmacs-brigade-deftool switch-to-buffer
  "Switch the current window to display a buffer."
    ((buffer string "Buffer name"))
  :group 'buffer
  :destructive t
  :undo 'cmacs-brigade-undo-capture-switch-to-buffer
  (require 'cmacs-core-tools)
  ;; Like the command it wraps, this creates a buffer that does not
  ;; exist, so only exclusion is an error here.
  (cmacs-core-tools-check-name buffer)
  (cmacs-core-tools-print (buffer-name (switch-to-buffer buffer))))

(cmacs-brigade-deftool save-buffer
  "Save a buffer to its associated file."
    ((buffer string "Buffer name"))
  :group 'buffer :destructive t :confirm 'ask
  :undo 'cmacs-brigade-undo-capture-save-buffer
  (require 'cmacs-core-tools)
  (with-current-buffer (cmacs-core-tools-buffer buffer)
    ;; `save-buffer' is a prime source of prompts nobody can answer from
    ;; a tool call: most often `select-safe-coding-system' asking which
    ;; coding system to use for text the file's own cannot encode.  With
    ;; `inhibit-interaction' bound that is an error instead of a
    ;; recursive edit; name the offending character so the caller can
    ;; act on it rather than only seeing "interaction inhibited".
    (condition-case nil
        (let ((inhibit-interaction t))
          (save-buffer)
          (cmacs-core-tools-print t))
      (inhibited-interaction
       (let* ((cs buffer-file-coding-system)
              (pos (and cs (ignore-errors
                             (unencodable-char-position
                              (point-min) (point-max) cs)))))
         (error "save-buffer needs an interactive answer%s"
                (if pos
                    (format ": char at %d cannot be encoded in %s" pos cs)
                  " (a prompt no MCP client can answer)")))))))

(cmacs-brigade-deftool find-file
  "Open a file in Emacs (equivalent to C-x C-f / find-file)."
    ((path string "File path to open"))
  :group 'buffer :destructive t :confirm 'ask
  :undo 'cmacs-brigade-undo-capture-find-file
  (require 'cmacs-core-tools)
  (unless (and (stringp path) (not (string-empty-p path)))
    (error "Missing required argument: path"))
  ;; Opening a file is the first half of reading it, so an excluded file
  ;; is refused before it is visited -- with the message a file that
  ;; cannot be opened gets, for the same no-oracle reason as buffers.
  (when (cmacs-core-tools-file-hidden-p (expand-file-name path))
    (error "Cannot open file: %s" path))
  (let ((opened (let ((inhibit-interaction t))
                  (condition-case nil
                      (find-file path)
                    (error (error "Cannot open file: %s" path))))))
    ;; The buffer can be excluded by rules the path alone did not match
    ;; (its mode, its project).  It is open now, which is what the C tool
    ;; did too; what must not happen is this call confirming it.
    (when (and (bufferp opened) (cmacs-core-tools-buffer-hidden-p opened))
      (error "Cannot open file: %s" path))
    ;; The C handler answered with the path as given, unprinted.
    path))

(provide 'cmacs-buffer-tools)

;;; cmacs-buffer-tools.el ends here
