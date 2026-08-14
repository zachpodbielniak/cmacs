;;; cmacs-ai-target.el --- What is under the click  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The hard part of a universal "do something with AI here" menu is not
;; the menu.  It is answering one question, consistently, in every buffer
;; cmacs can show you:
;;
;;     what is under the point (or the click), and how do I describe it
;;     to a model?
;;
;; This file answers it once.  A `cmacs-ai-target' is a small struct --
;; a kind, a label, some text, maybe a file or a list of them -- built by
;; whichever registered resolver claims the position first.  Everything
;; downstream (the right-click menu, the `C-c a' transient, the MCP
;; surface, the summarize/rephrase/reply commands) consumes targets and
;; never looks at `major-mode' itself.
;;
;; That split is what keeps the feature from rotting.  Adding a surface
;; means writing one resolver; adding a capability means writing one
;; action.  Neither has to know about the other, and nobody has to touch
;; a growing `cond' over major modes.
;;
;; Resolvers are ordered and the first non-nil answer wins, so priority
;; is explicit rather than an accident of load order.  The region
;; resolver deliberately sits at the front: if you have highlighted text,
;; that is what you meant, in every buffer, no exceptions.
;;
;; Core resolvers live here.  The per-mode ones -- dired/dirvish,
;; vterm/eshell/term, org, magit, compilation, mail, the libregnum
;; surfaces -- live in cmacs-ai-targets.el, which this file does not
;; require (it is loaded the other way round) so that a minimal build or
;; a test can use the core alone.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup cmacs-ai-target nil
  "Resolving what the AI menu should act on."
  :group 'cmacs
  :prefix "cmacs-ai-target-")

(defcustom cmacs-ai-target-max-chars 40000
  "Maximum characters of target text handed to a model.

Targets are routinely whole buffers, whole files, or a terminal's
scrollback, and an unbounded payload is how you turn one right-click into
a surprising bill.  Text longer than this is truncated in the middle --
the head and tail of a file are almost always the informative parts --
with a marker showing what was dropped.

nil means no limit."
  :type '(choice (const :tag "No limit" nil) integer)
  :safe #'integerp)

;;;; The struct --------------------------------------------------------

(cl-defstruct (cmacs-ai-target (:constructor cmacs-ai-target-create)
                               (:copier cmacs-ai-target-copy))
  "One thing an AI action can act on.

KIND is a symbol naming what this is (`region', `file', `files',
`org-node', `diagnostic', `terminal', `hunk', `mail', `url', ...).
Actions test it to decide whether they apply.

LABEL is a short human string for menu titles (\"region\", \"3 marked
files\", \"note: Build notes\").

TEXT is the payload -- what the model reads.  May be nil when the target
is purely a file reference.

FILE / FILES name the file or files involved, when there are any.  BOUNDS
is (BEG . END) in BUFFER when the target came from buffer text, which is
what makes in-place actions (rewrite, replace) possible.

LANG is a language name derived from the major mode, for prompts that
need to say \"this is C\".  MIME is set for non-text targets.

PLIST carries whatever the resolver wants to pass through to its own
actions (a task id, an org id, a compositor client), and is ignored by
everything generic."
  kind label text file files bounds buffer lang mime plist)

(defun cmacs-ai-target-plist-get (target key)
  "Return KEY from TARGET's resolver-supplied plist."
  (plist-get (cmacs-ai-target-plist target) key))

;;;; Resolver registry -------------------------------------------------

(defvar cmacs-ai-target--resolvers (make-hash-table :test 'eq)
  "Registered target resolvers, keyed by name symbol.")

(defun cmacs-ai-register-target-resolver (&rest plist)
  "Register a target resolver from PLIST.

Recognised keys:

  :name      symbol identifying the resolver (required; re-registering
             the same name replaces it, so reloading a file is safe)
  :modes     list of major modes it applies to, or nil for any
  :predicate optional (lambda () bool) run in the target buffer
  :resolve   (lambda (CLICK) -> `cmacs-ai-target' or nil) (required)
  :order     sort key, ascending; lower runs first.  Default 50.

RESOLVE runs with point already moved to the click position (inside a
`save-excursion'), so it can just look at point.  Returning nil means
\"not mine\", and the next resolver is tried -- so a resolver may claim a
mode cheaply and still decline for positions it does not understand."
  (let ((name (plist-get plist :name)))
    (unless name
      (error "cmacs-ai-target: a resolver needs a :name"))
    (unless (plist-get plist :resolve)
      (error "cmacs-ai-target: resolver %s needs a :resolve" name))
    (puthash name plist cmacs-ai-target--resolvers)
    name))

(defun cmacs-ai-unregister-target-resolver (name)
  "Remove the resolver called NAME.  Returns non-nil if it was there."
  (let ((had (gethash name cmacs-ai-target--resolvers)))
    (remhash name cmacs-ai-target--resolvers)
    (and had t)))

(defun cmacs-ai-target-resolvers ()
  "Registered resolvers, sorted by :order then name."
  (let ((all nil))
    (maphash (lambda (_k v) (push v all)) cmacs-ai-target--resolvers)
    (sort all (lambda (a b)
                (let ((oa (or (plist-get a :order) 50))
                      (ob (or (plist-get b :order) 50)))
                  (if (= oa ob)
                      (string< (symbol-name (plist-get a :name))
                               (symbol-name (plist-get b :name)))
                    (< oa ob)))))))

(defun cmacs-ai-target--applies-p (resolver)
  "Non-nil when RESOLVER wants a say about the current buffer."
  (let ((modes (plist-get resolver :modes))
        (pred  (plist-get resolver :predicate)))
    (and (or (null modes)
             (apply #'derived-mode-p modes)
             (memq major-mode modes))
         (or (null pred) (ignore-errors (funcall pred))))))

;;;; Resolution --------------------------------------------------------

(defun cmacs-ai-target--goto-click (click)
  "Move point to CLICK's position when CLICK is a usable mouse event.
Returns non-nil when point moved.  Never selects a different window: the
caller has already made the clicked buffer current."
  (when-let* ((posn (and (consp click) (ignore-errors (event-start click))))
              (pt   (posn-point posn)))
    (when (and (integerp pt) (<= (point-min) pt) (<= pt (point-max)))
      (goto-char pt)
      t)))

;;;###autoload
(defun cmacs-ai-target-at (&optional click)
  "Return the `cmacs-ai-target' at CLICK, or at point when CLICK is nil.

Runs registered resolvers in :order and returns the first non-nil answer.
Returns nil when nothing claims the position -- callers should treat that
as \"offer nothing\" rather than an error, because it is the normal state
in a buffer nobody has taught the menu about."
  (let ((buffer (or (and (consp click)
                         (ignore-errors
                           (window-buffer (posn-window (event-start click)))))
                    (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (cmacs-ai-target--goto-click click)
          (catch 'cmacs-ai-target
            (dolist (r (cmacs-ai-target-resolvers))
              (when (cmacs-ai-target--applies-p r)
                (let ((hit (condition-case err
                               (funcall (plist-get r :resolve) click)
                             (error
                              ;; A broken resolver must not take the whole
                              ;; menu down with it -- the other surfaces
                              ;; are still perfectly usable.
                              (message "cmacs-ai-target: resolver %s failed: %s"
                                       (plist-get r :name)
                                       (error-message-string err))
                              nil))))
                  (when (cmacs-ai-target-p hit)
                    (throw 'cmacs-ai-target hit)))))
            nil))))))

;;;; Describing a target to a model ------------------------------------

(defun cmacs-ai-target-lang-of-mode (&optional mode)
  "A language name for MODE (default `major-mode'), for prompts."
  (let ((m (symbol-name (or mode major-mode))))
    (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" m)))

(defun cmacs-ai-target-truncate (text)
  "Return TEXT clipped to `cmacs-ai-target-max-chars', middle-out."
  (let ((limit cmacs-ai-target-max-chars))
    (if (or (null limit) (null text) (<= (length text) limit))
        text
      (let* ((half (/ (- limit 80) 2))
             (head (substring text 0 half))
             (tail (substring text (- (length text) half))))
        (concat head
                (format "\n\n[... %d characters elided ...]\n\n"
                        (- (length text) (* 2 half)))
                tail)))))

(defun cmacs-ai-target-content (target)
  "Return TARGET's payload text, truncated, reading its file if needed.

A file target carries no text until somebody asks for it; this is where
that read happens, so a menu can be built over a thousand files without
touching the disk."
  (or (cmacs-ai-target-truncate (cmacs-ai-target-text target))
      (let ((file (cmacs-ai-target-file target)))
        (when (and file (file-readable-p file)
                   (not (file-directory-p file)))
          (cmacs-ai-target-truncate
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-substring-no-properties (point-min) (point-max))))))))

(defun cmacs-ai-target-describe (target)
  "A one-line description of TARGET, for prompts and menu titles."
  (let ((kind  (cmacs-ai-target-kind target))
        (label (cmacs-ai-target-label target))
        (file  (cmacs-ai-target-file target)))
    (cond
     ((and label file) (format "%s (%s)" label (abbreviate-file-name file)))
     (label label)
     (file (abbreviate-file-name file))
     (t (format "%s" kind)))))

(defun cmacs-ai-target-prompt-context (target)
  "Render TARGET as the context block of a prompt.

Deliberately plain: a header line naming what this is and where it came
from, then the content.  Models do better with provenance than without
it, and a human reading the chat transcript later needs the same thing."
  (let* ((kind (cmacs-ai-target-kind target))
         (lang (cmacs-ai-target-lang target))
         (file (cmacs-ai-target-file target))
         (files (cmacs-ai-target-files target))
         (content (cmacs-ai-target-content target))
         (header
          (concat
           (format "[%s" kind)
           (when lang (format " | %s" lang))
           (when file (format " | %s" (abbreviate-file-name file)))
           (when (and files (> (length files) 1))
             (format " | %d files" (length files)))
           "]")))
    (concat header "\n"
            (when (and files (> (length files) 1))
              (concat (mapconcat (lambda (f)
                                   (concat "  - " (abbreviate-file-name f)))
                                 files "\n")
                      "\n"))
            (when content (concat "\n" content)))))

;;;; Core resolvers ----------------------------------------------------
;;
;; Order matters and is spelled out rather than implied:
;;
;;   10  region     highlighted text always wins
;;   90  symbol     a symbol at point, when there is one
;;   95  buffer     the file/buffer itself -- the catch-all
;;
;; Everything mode-specific registers in between (see cmacs-ai-targets.el).

(defun cmacs-ai-target--region-covers-click-p (click)
  "Non-nil when CLICK is nil, or falls inside the active region.
A right-click far away from the highlighted text means the user is
pointing at something else; a right-click inside it means they are
pointing at the selection.  Both readings are common, so we distinguish
them rather than guess."
  (or (null click)
      (let ((pt (ignore-errors (posn-point (event-start click)))))
        (or (null pt)
            (and (>= pt (region-beginning)) (<= pt (region-end)))))))

(cmacs-ai-register-target-resolver
 :name 'region :order 10
 :resolve
 (lambda (click)
   (when (and (use-region-p)
              (cmacs-ai-target--region-covers-click-p click))
     (let ((beg (region-beginning)) (end (region-end)))
       (cmacs-ai-target-create
        :kind 'region
        :label (format "region (%d chars)" (- end beg))
        :text (buffer-substring-no-properties beg end)
        :file (buffer-file-name)
        :bounds (cons beg end)
        :buffer (current-buffer)
        :lang (cmacs-ai-target-lang-of-mode))))))

(cmacs-ai-register-target-resolver
 :name 'symbol :order 90
 :resolve
 (lambda (_click)
   (when-let* ((bounds (bounds-of-thing-at-point 'symbol))
               (sym (buffer-substring-no-properties (car bounds) (cdr bounds))))
     (unless (string-empty-p (string-trim sym))
       (cmacs-ai-target-create
        :kind 'symbol
        :label (format "symbol `%s'" sym)
        ;; The symbol alone is rarely enough to reason about, so the
        ;; payload is the symbol plus the line it sits on.
        :text (concat sym "\n\n"
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))
        :file (buffer-file-name)
        :bounds bounds
        :buffer (current-buffer)
        :lang (cmacs-ai-target-lang-of-mode)
        :plist (list :symbol sym))))))

(cmacs-ai-register-target-resolver
 :name 'buffer :order 95
 :resolve
 (lambda (_click)
   ;; The catch-all.  Never nil for a live buffer, which is what makes the
   ;; menu appear everywhere rather than only in places we anticipated.
   (cmacs-ai-target-create
    :kind (if (buffer-file-name) 'file 'buffer)
    :label (format "buffer %s" (buffer-name))
    :text (buffer-substring-no-properties (point-min) (point-max))
    :file (buffer-file-name)
    :buffer (current-buffer)
    :lang (cmacs-ai-target-lang-of-mode))))

(provide 'cmacs-ai-target)

;;; cmacs-ai-target.el ends here
