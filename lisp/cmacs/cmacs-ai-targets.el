;;; cmacs-ai-targets.el --- Per-surface AI target resolvers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The resolvers that teach `cmacs-ai-target-at' about specific buffers.
;; cmacs-ai-target.el ships three generic ones (region, symbol, buffer);
;; everything here sits between them in :order, so a surface that knows
;; better than "the whole buffer" gets to say so.
;;
;; Two rules kept throughout:
;;
;;   1. Nothing here may hard-require an optional package.  vterm,
;;      dirvish, magit, mu4e and notmuch are all external; the libregnum
;;      surfaces are all behind configure flags that default off.  Every
;;      resolver is guarded and simply declines when its surface is not
;;      present, which is why this file loads in any build.
;;
;;   2. A resolver describes, it never acts.  Anything that needs to run
;;      a command (gsurf's asynchronous page-text fetch, say) exposes the
;;      handle in the target's plist and leaves the doing to an action in
;;      cmacs-ai-actions.el.

;;; Code:

(require 'cmacs-ai-target)
(require 'subr-x)

;; Optional packages -- declared, never required.
(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function dired-get-subdir "dired" ())
(declare-function dirvish-curr "dirvish" ())
(declare-function vterm-previous-prompt "vterm" (&optional n))
(declare-function comint-previous-prompt "comint" (n))
(declare-function eshell-previous-prompt "em-prompt" (&optional n))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flycheck-overlay-errors-at "flycheck" (pos))
(declare-function flycheck-error-message "flycheck" (err))
(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-type "org-element" (element))
(declare-function org-element-property "org-element" (property element))
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function org-id-get "org-id" (&optional pom create prefix))
(declare-function cmacs-brigade-dashboard--record-at-point "cmacs-brigade-dashboard" ())
(declare-function cmacs-roamgraph--node "cmacs-roamgraph" (id))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))
(defvar cmacs-roamgraph--selected)
(defvar cmacs-gnuseye--selected-id)
(defvar comint-last-prompt)

;;;; Terminals ---------------------------------------------------------
;;
;; The useful target in a terminal is almost never "the buffer" -- it is
;; the last command and what it printed, because that is what you want
;; explained or fixed.  Each terminal tracks prompts differently (and
;; vterm, being a real terminal emulator, does not reliably track them at
;; all without shell integration), so we try the mode's own prompt
;; navigation first and fall back to a line count that is always right
;; enough to be useful.

(defcustom cmacs-ai-target-terminal-lines 120
  "Lines of scrollback used when a terminal's prompts cannot be located.
The fallback for vterm without shell integration, and for any terminal
whose prompt navigation signals."
  :type 'integer
  :group 'cmacs-ai-target
  :safe #'integerp)

(defun cmacs-ai-targets--terminal-start ()
  "Where the interesting part of this terminal buffer starts.

Tries to land on the *previous* prompt -- the one that issued the command
whose output you are looking at -- rather than the current empty one,
which would capture nothing.  Falls back to a fixed number of lines."
  (or
   (ignore-errors
     (save-excursion
       (cond
        ((and (derived-mode-p 'eshell-mode) (fboundp 'eshell-previous-prompt))
         (eshell-previous-prompt 2) (line-beginning-position))
        ((and (derived-mode-p 'comint-mode) (fboundp 'comint-previous-prompt))
         (comint-previous-prompt 2) (line-beginning-position))
        ((and (derived-mode-p 'vterm-mode) (fboundp 'vterm-previous-prompt))
         ;; Only meaningful with shell integration; harmless otherwise
         ;; because a failure drops us into the line-count fallback.
         (vterm-previous-prompt 2) (line-beginning-position)))))
   (save-excursion
     (forward-line (- cmacs-ai-target-terminal-lines))
     (line-beginning-position))))

(cmacs-ai-register-target-resolver
 :name 'terminal :order 20
 :modes '(vterm-mode eshell-mode term-mode shell-mode comint-mode
          cmacs-bacon-mode crispy-repl-mode cmacs-podomation-repl-mode
          cmacs-c-jit-repl-mode cmacs-calculator-repl-mode)
 :resolve
 (lambda (_click)
   (let* ((end (point))
          (beg (min (cmacs-ai-targets--terminal-start) end))
          (text (buffer-substring-no-properties beg end)))
     (unless (string-empty-p (string-trim text))
       (cmacs-ai-target-create
        :kind 'terminal
        :label (format "terminal output (%s)"
                       (cmacs-ai-target-lang-of-mode))
        :text text
        :buffer (current-buffer)
        :bounds (cons beg end)
        :file (and (boundp 'default-directory) default-directory)
        :lang "shell session"
        :plist (list :shell (cmacs-ai-target-lang-of-mode)
                     :cwd default-directory))))))

;;;; Dired and dirvish -------------------------------------------------
;;
;; dirvish is a UI over dired: its buffers stay `dired-mode' derived, so
;; `derived-mode-p' catches both and marked files work unchanged.  The
;; explicit dirvish mode symbols are belt-and-braces for the versions
;; that put their own major mode on side panes.

(cmacs-ai-register-target-resolver
 :name 'dired :order 20
 :modes '(dired-mode dirvish-mode dirvish-directory-view-mode)
 :resolve
 (lambda (_click)
   (when (fboundp 'dired-get-marked-files)
     (let* ((marked (ignore-errors (dired-get-marked-files nil nil nil t)))
            ;; dired-get-marked-files with DISTINGUISH-ONE-MARKED returns
            ;; (t FILE) when exactly one file is *marked* (as opposed to
            ;; merely being at point) -- strip the flag either way.
            (files (if (eq (car-safe marked) t) (cdr marked) marked))
            (many (and files (> (length files) 1))))
       (cond
        (many
         (cmacs-ai-target-create
          :kind 'files
          :label (format "%d marked files" (length files))
          :files files
          :file (car files)
          :buffer (current-buffer)
          :plist (list :directory default-directory)))
        (files
         (let ((f (car files)))
           (cmacs-ai-target-create
            :kind (if (file-directory-p f) 'directory 'file)
            :label (file-name-nondirectory (directory-file-name f))
            :file f
            :files files
            :buffer (current-buffer)
            :plist (list :directory default-directory))))
        (t
         ;; On a header or a blank line: the directory itself.
         (cmacs-ai-target-create
          :kind 'directory
          :label (abbreviate-file-name default-directory)
          :file default-directory
          :buffer (current-buffer))))))))

;;;; Diffs and hunks ---------------------------------------------------
;;
;; Deliberately syntactic rather than magit-structural: scanning for the
;; enclosing "@@" run works in diff-mode, magit-diff, magit-status,
;; vc-diff and a plain patch file in fundamental-mode, and does not break
;; when magit reorganises its section classes.

(defun cmacs-ai-targets--hunk-bounds ()
  "Bounds of the diff hunk around point as (BEG . END), or nil."
  (save-excursion
    (let ((beg (save-excursion
                 (end-of-line)
                 (and (re-search-backward "^@@ " nil t)
                      (line-beginning-position)))))
      (when beg
        (goto-char beg)
        (forward-line 1)
        (let ((end (if (re-search-forward "^\\(@@ \\|diff --git \\)" nil t)
                       (line-beginning-position)
                     (point-max))))
          (cons beg end))))))

(cmacs-ai-register-target-resolver
 :name 'hunk :order 25
 :modes '(diff-mode magit-diff-mode magit-status-mode magit-revision-mode
          magit-stash-mode vc-diff-mode)
 :resolve
 (lambda (_click)
   (when-let* ((bounds (cmacs-ai-targets--hunk-bounds)))
     (cmacs-ai-target-create
      :kind 'hunk
      :label "diff hunk"
      :text (buffer-substring-no-properties (car bounds) (cdr bounds))
      :bounds bounds
      :buffer (current-buffer)
      :lang "unified diff"))))

;;;; Diagnostics -------------------------------------------------------
;;
;; Three sources, one target kind: flymake (which cmacs uses natively for
;; .calc sheets and eglot uses everywhere else), flycheck for people who
;; prefer it, and compilation buffers for everything a build prints.

(defun cmacs-ai-targets--diagnostic-at-point ()
  "The diagnostic message(s) at point from flymake or flycheck, or nil."
  (or (and (fboundp 'flymake-diagnostics)
           (fboundp 'flymake-diagnostic-text)
           (when-let* ((ds (ignore-errors
                             (flymake-diagnostics (line-beginning-position)
                                                  (line-end-position)))))
             (mapconcat #'flymake-diagnostic-text ds "\n")))
      (and (fboundp 'flycheck-overlay-errors-at)
           (fboundp 'flycheck-error-message)
           (when-let* ((es (ignore-errors (flycheck-overlay-errors-at (point)))))
             (mapconcat #'flycheck-error-message es "\n")))))

(cmacs-ai-register-target-resolver
 :name 'diagnostic :order 15
 :resolve
 (lambda (_click)
   ;; Not mode-scoped: diagnostics overlay ordinary source buffers, which
   ;; is exactly where you want to right-click them.  Sits ahead of the
   ;; symbol resolver so a squiggle beats the identifier under it.
   (when-let* ((msg (cmacs-ai-targets--diagnostic-at-point)))
     (cmacs-ai-target-create
      :kind 'diagnostic
      :label (format "diagnostic: %s"
                     (truncate-string-to-width (car (split-string msg "\n")) 50
                                               nil nil t))
      :text (format "%s\n\nAt %s:%d, in this context:\n\n%s"
                    msg
                    (or (buffer-file-name) (buffer-name))
                    (line-number-at-pos)
                    (buffer-substring-no-properties
                     (save-excursion (forward-line -8) (point))
                     (save-excursion (forward-line 9) (point))))
      :file (buffer-file-name)
      :buffer (current-buffer)
      :lang (cmacs-ai-target-lang-of-mode)
      :plist (list :message msg :line (line-number-at-pos))))))

(cmacs-ai-register-target-resolver
 :name 'compilation :order 22
 :modes '(compilation-mode grep-mode)
 :resolve
 (lambda (_click)
   ;; The whole tail of the buffer, not just the clicked line: a compiler
   ;; error is rarely self-contained, and the note lines that follow it
   ;; are usually where the answer is.
   (let* ((beg (save-excursion (forward-line -40) (line-beginning-position)))
          (end (save-excursion (forward-line 40) (line-end-position))))
     (cmacs-ai-target-create
      :kind 'diagnostic
      :label "build output"
      :text (buffer-substring-no-properties beg end)
      :buffer (current-buffer)
      :bounds (cons beg end)
      :lang "compiler output"
      :plist (list :line (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))))

(cmacs-ai-register-target-resolver
 :name 'backtrace :order 22
 :modes '(backtrace-mode debugger-mode)
 :resolve
 (lambda (_click)
   (cmacs-ai-target-create
    :kind 'backtrace
    :label "backtrace"
    :text (buffer-substring-no-properties (point-min) (point-max))
    :buffer (current-buffer)
    :lang "emacs lisp backtrace")))

;;;; Org ---------------------------------------------------------------
;;
;; The best fit in the whole editor: an ai-brigade task IS an org heading
;; with properties, so "make this a task" is a data move, not a
;; translation.  A src block is handled separately because its content,
;; not its subtree, is what you want to talk about.

(cmacs-ai-register-target-resolver
 :name 'org :order 30
 :modes '(org-mode)
 :resolve
 (lambda (_click)
   (when (featurep 'org)
     (let ((ctx (ignore-errors (org-element-context))))
       (cond
        ;; Inside a source block: the code is the target.
        ((memq (and ctx (org-element-type ctx)) '(src-block inline-src-block))
         (let ((value (or (org-element-property :value ctx) ""))
               (lang  (or (org-element-property :language ctx) "")))
           (cmacs-ai-target-create
            :kind 'region
            :label (format "org src block (%s)" lang)
            :text value
            :file (buffer-file-name)
            :buffer (current-buffer)
            :lang lang
            :bounds (cons (org-element-property :begin ctx)
                          (org-element-property :end ctx)))))
        ;; Otherwise the enclosing heading and its subtree.
        ((ignore-errors (save-excursion (org-back-to-heading t) t))
         (save-excursion
           (org-back-to-heading t)
           (let* ((beg (point))
                  (heading (or (ignore-errors (org-get-heading t t t t)) ""))
                  (id (ignore-errors (org-entry-get (point) "ID")))
                  (end (save-excursion (org-end-of-subtree t t) (point))))
             (cmacs-ai-target-create
              :kind 'org-node
              :label (format "heading: %s"
                             (truncate-string-to-width heading 50 nil nil t))
              :text (buffer-substring-no-properties beg end)
              :file (buffer-file-name)
              :bounds (cons beg end)
              :buffer (current-buffer)
              :lang "org"
              :plist (list :heading heading :id id))))))))))

;;;; Mail --------------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'mail :order 25
 :modes '(mu4e-view-mode mu4e-headers-mode gnus-article-mode gnus-summary-mode
          notmuch-show-mode rmail-mode message-mode mail-mode
          cmacs-brigade-genmail-view-mode)
 :resolve
 (lambda (_click)
   (cmacs-ai-target-create
    :kind 'mail
    :label "message"
    :text (buffer-substring-no-properties (point-min) (point-max))
    :buffer (current-buffer)
    :lang "email")))

;;;; Chat rooms --------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'chat :order 28
 :modes '(cmacs-libreclaw-room-mode cmacs-libreclaw-cmacs-channel-room-mode
          cmacs-ai-chat-mode)
 :resolve
 (lambda (_click)
   ;; Everything above point: a reply is about the conversation so far,
   ;; and what is below point is usually your own half-typed message.
   (let ((beg (point-min)) (end (point)))
     (cmacs-ai-target-create
      :kind 'chat
      :label "conversation"
      :text (buffer-substring-no-properties beg end)
      :bounds (cons beg end)
      :buffer (current-buffer)
      :file (buffer-file-name)
      :lang "chat transcript"))))

;;;; Web ---------------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'web :order 25
 :modes '(eww-mode cmacs-gsurf-lite-mode)
 :resolve
 (lambda (_click)
   ;; An Emacs-side rendering: the text is right here.  eww keeps the
   ;; page identity in `eww-data' (the old eww-current-* variables are
   ;; long gone); gsurf-lite buffers simply have neither.
   (let ((data (and (boundp 'eww-data) eww-data)))
     (cmacs-ai-target-create
      :kind 'url
      :label (or (plist-get data :title) "page")
      :text (buffer-substring-no-properties (point-min) (point-max))
      :buffer (current-buffer)
      :lang "web page"
      :plist (list :url (or (plist-get data :url)
                            (get-text-property (point) 'shr-url)))))))

(cmacs-ai-register-target-resolver
 :name 'gsurf :order 25
 :modes '(cmacs-gsurf-mode)
 :resolve
 (lambda (_click)
   ;; The full WebKit widget: the page body is only obtainable
   ;; asynchronously (`cmacs-gsurf--page-text'), so the target carries the
   ;; identity of the page and the gsurf actions do the fetching.
   (let ((buf (current-buffer)))
     (cmacs-ai-target-create
      :kind 'gsurf-page
      :label (or (ignore-errors (cmacs-gsurf-get-title buf)) "page")
      :text (format "Title: %s\nURL: %s"
                    (or (ignore-errors (cmacs-gsurf-get-title buf)) "")
                    (or (ignore-errors (cmacs-gsurf-get-uri buf)) ""))
      :buffer buf
      :lang "web page"
      :plist (list :url (ignore-errors (cmacs-gsurf-get-uri buf))
                   :async-page t)))))

;;;; Images ------------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'image :order 25
 :modes '(image-mode cmacs-imgedit-mode)
 :resolve
 (lambda (_click)
   (let ((file (buffer-file-name)))
     (cmacs-ai-target-create
      :kind 'image
      :label (if file (file-name-nondirectory file) "image")
      :file file
      :buffer (current-buffer)
      :mime (and file (format "image/%s"
                              (or (file-name-extension file) "png")))
      ;; No text payload: an image target is for the multimodal path and
      ;; for the imgedit actions, neither of which wants the raw bytes
      ;; pasted into a prompt.
      :text nil))))

;;;; Video -------------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'vidstudio :order 25
 :modes '(cmacs-vidstudio-mode)
 :resolve
 (lambda (_click)
   (cmacs-ai-target-create
    :kind 'clip
    :label "timeline"
    :file (buffer-file-name)
    :buffer (current-buffer)
    :text nil)))

;;;; ai-brigade dashboard ----------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'brigade-task :order 20
 :modes '(cmacs-brigade-dashboard-mode)
 :resolve
 (lambda (_click)
   (when (fboundp 'cmacs-brigade-dashboard--record-at-point)
     (when-let* ((record (cmacs-brigade-dashboard--record-at-point))
                 (id (plist-get record :id)))
       (cmacs-ai-target-create
        :kind 'task
        :label (format "task %s: %s" id
                       (or (plist-get record :title) ""))
        :text (format "Task %s\nTitle: %s\nState: %s\nAgent: %s"
                      id
                      (or (plist-get record :title) "")
                      (or (plist-get record :state) "")
                      (or (plist-get record :agent) ""))
        :buffer (current-buffer)
        :plist (list :task-id id :record record))))))

;;;; roamgraph ---------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'roam-node :order 20
 :modes '(cmacs-roamgraph-mode)
 :resolve
 (lambda (_click)
   (when (and (boundp 'cmacs-roamgraph--selected) cmacs-roamgraph--selected)
     (let* ((id cmacs-roamgraph--selected)
            (node (and (fboundp 'cmacs-roamgraph--node)
                       (cmacs-roamgraph--node id)))
            (file (plist-get node :file))
            (title (or (plist-get node :title) id)))
       (cmacs-ai-target-create
        :kind 'roam-node
        :label (format "note: %s" title)
        ;; Left nil so `cmacs-ai-target-content' reads the note's file
        ;; only when something actually asks for it.
        :text nil
        :file file
        :buffer (current-buffer)
        :lang "org"
        :plist (list :roam-id id :title title))))))

;;;; gnuseye -----------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'gnuseye-entity :order 20
 :modes '(cmacs-gnuseye-mode cmacs-gnuseye-list-mode cmacs-gnuseye-inspector-mode)
 :resolve
 (lambda (_click)
   (let ((id (and (boundp 'cmacs-gnuseye--selected-id)
                  cmacs-gnuseye--selected-id)))
     (cmacs-ai-target-create
      :kind 'entity
      :label (if id (format "entity %s" id) "globe")
      :text (buffer-substring-no-properties
             (point-min) (min (point-max) (+ (point-min) 4000)))
      :buffer (current-buffer)
      :plist (list :entity-id id)))))

;;;; Calculator --------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'calc-sheet :order 25
 :modes '(cmacs-calculator-sheet-mode)
 :resolve
 (lambda (_click)
   (let ((line (buffer-substring-no-properties
                (line-beginning-position) (line-end-position))))
     (cmacs-ai-target-create
      :kind 'formula
      :label (format "cell: %s"
                     (truncate-string-to-width (string-trim line) 40 nil nil t))
      :text (format "The sheet line under the cursor:\n%s\n\nThe whole sheet:\n%s"
                    line
                    (buffer-substring-no-properties (point-min) (point-max)))
      :file (buffer-file-name)
      :buffer (current-buffer)
      :lang "GNU Calc"))))

;;;; C sources ---------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'c-symbol :order 85
 :modes '(c-mode c-ts-mode c++-mode c++-ts-mode cmacs-cad-crispy-mode)
 :resolve
 (lambda (_click)
   ;; Just ahead of the generic symbol resolver, and it adds the one thing
   ;; that makes the cintrospect/cpatch actions possible: which function
   ;; you are actually inside.
   (when-let* ((bounds (bounds-of-thing-at-point 'symbol))
               (sym (buffer-substring-no-properties (car bounds) (cdr bounds))))
     (let ((defun-name (ignore-errors (add-log-current-defun))))
       (cmacs-ai-target-create
        :kind 'c-symbol
        :label (format "C symbol `%s'" sym)
        :text (concat sym "\n\n"
                      (buffer-substring-no-properties
                       (save-excursion (forward-line -5) (point))
                       (save-excursion (forward-line 6) (point))))
        :file (buffer-file-name)
        :bounds bounds
        :buffer (current-buffer)
        :lang "c"
        :plist (list :symbol sym :defun defun-name))))))

;;;; gowl --------------------------------------------------------------

(cmacs-ai-register-target-resolver
 :name 'gowl-client :order 20
 :modes '(gowl-embed-mode)
 :resolve
 (lambda (_click)
   (cmacs-ai-target-create
    :kind 'gowl-client
    :label (format "window: %s" (buffer-name))
    :text (format "A Wayland client mirrored into the buffer %s."
                  (buffer-name))
    :buffer (current-buffer))))

(provide 'cmacs-ai-targets)

;;; cmacs-ai-targets.el ends here
