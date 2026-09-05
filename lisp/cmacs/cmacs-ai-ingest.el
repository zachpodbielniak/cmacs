;;; cmacs-ai-ingest.el --- The second brain from inside cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three doors from cmacs-ai into the second-brain ingester:
;;
;;   - `/ingest' in a chat compose region.  `/ingest URL' or `/ingest
;;     PATH' files that thing; `/ingest -p resources -c technical/linux
;;     URL' places it; `/ingest' alone (or `/ingest-chat') files the
;;     conversation you are having.  The compose text is a command to
;;     us, not something to send to the model.
;;
;;   - `cmacs-ai-ingest-chat' (C-c C-b in a chat), which turns the
;;     transcript into an Org note under `cmacs-ai-ingest-chat-directory'.
;;     The port of `ingest_last_chat'.
;;
;;   - "Ingest into second brain" in the universal AI right-click menu,
;;     for a file, a directory, marked files, a URL or page, a region, an
;;     org subtree, a mail, the clipboard, or a chat.
;;
;; And one door the model itself can use: a `secondbrain_ingest' tool
;; added to the chat's tool executor, so an HTTP-provider chat can be
;; told "file this" and do it.  CLI providers reach the same capability
;; through the brigade tool over their MCP config.
;;
;; None of this knows how ingestion works.  It builds an option plist and
;; hands it to `cmacs-secondbrain-ingest-run', so every rule about
;; placement, summaries and links lives in one place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-ai-target)
(require 'cmacs-ai-actions)

(declare-function cmacs-secondbrain-ingest-run "cmacs-secondbrain-ingest" (inputs &rest opts))
(declare-function cmacs-secondbrain-ingest-url-p "cmacs-secondbrain-ingest-extract" (string))
(declare-function cmacs-secondbrain-ingest-status-json "cmacs-secondbrain-ingest" (id))
(declare-function cmacs-secondbrain-ingest-job-id "cmacs-secondbrain-ingest" (job))
(declare-function cmacs-secondbrain-ingest-summary-types "cmacs-secondbrain-ingest-ai" ())
(declare-function cmacs-ai-define-tool "cmacs-ai-call" (name description params callback))
(declare-function cmacs-ai--register-tool "cmacs-ai-call" (executor spec))
(declare-function cmacs-ai-chat--assistant-label "cmacs-ai-chat" ())

(defvar cmacs-ai-chat-provider)
(defvar cmacs-ai-chat--compose-marker)
(defvar cmacs-ai-chat-mode-map)
(defvar cmacs-ai-chat-slash-command-functions)
(defvar cmacs-ai-chat-executor-functions)

(defgroup cmacs-ai-ingest nil
  "The second-brain ingester as seen from cmacs-ai."
  :group 'cmacs-ai
  :prefix "cmacs-ai-ingest-")

(defcustom cmacs-ai-ingest-chat-directory "02_areas/cmacs_ai_chats"
  "Root-relative directory a filed chat transcript goes to.
The notes repository keeps AI conversations here, and the placement
model is told to stay out of it, so this is set explicitly rather than
detected.  nil lets the ingester decide like any other note."
  :type '(choice (const nil) string)
  :group 'cmacs-ai-ingest)

(defcustom cmacs-ai-ingest-chat-summarize nil
  "Summarise a filed chat.  Off by default: a transcript already is the
distilled form of the exchange, and summarising it with the same model
that wrote half of it is a round trip to nowhere."
  :type 'boolean
  :group 'cmacs-ai-ingest)

(defcustom cmacs-ai-ingest-chat-tags '("ai-chat")
  "Tags every filed chat gets, plus the provider's name."
  :type '(repeat string)
  :group 'cmacs-ai-ingest)

(defun cmacs-ai-ingest--available-p ()
  "Non-nil when the ingester can be loaded."
  (or (featurep 'cmacs-secondbrain-ingest)
      (locate-library "cmacs-secondbrain-ingest")))

(defun cmacs-ai-ingest--ensure ()
  (unless (require 'cmacs-secondbrain-ingest nil t)
    (user-error "cmacs-secondbrain-ingest is not available in this build")))

;;;; The slash command ---------------------------------------------------------

(defconst cmacs-ai-ingest--flags
  '(("-p" . :para) ("--para" . :para)
    ("-c" . :category) ("--category" . :category)
    ("-d" . :directory) ("--directory" . :directory)
    ("-t" . :tags) ("--tags" . :tags)
    ("-T" . :type) ("--type" . :type)
    ("--title" . :title) ("--name" . :name)
    ("--prompt" . :prompt))
  "Flags `/ingest' understands, mapped to option keys.")

(defconst cmacs-ai-ingest--switches
  '(("-n" . :no-summary) ("--no-summary" . :no-summary)
    ("-N" . :no-ai) ("--no-ai" . :no-ai)
    ("-s" . :sanitize) ("--sanitize" . :sanitize)
    ("--principle" . :principle) ("--crawl" . :crawl) ("-a" . :append) ("--append" . :append))
  "Switches `/ingest' understands.")

(defun cmacs-ai-ingest-parse-command (line)
  "Parse a `/ingest ...' LINE into (INPUT TEXT . OPTIONS), or nil.

INPUT is a URL or path (nil when the command has none), TEXT is
free text given after `--' (nil otherwise), OPTIONS is a plist.
`/ingest-chat' parses as an ingest of the chat with no input."
  (when (string-match "\\`[ \t]*/ingest\\(-chat\\)?\\(?:[ \t]+\\(.*\\)\\)?[ \t]*\\'" line)
    (let* ((chat (match-string 1 line))
           (rest (or (match-string 2 line) ""))
           (words (condition-case nil (split-string-and-unquote rest) (error (split-string rest))))
           (opts nil) (input nil) (text nil))
      (while words
        (let ((w (pop words)))
          (cond
           ((equal w "--") (setq text (string-join words " ") words nil))
           ((assoc w cmacs-ai-ingest--flags)
            (setq opts (plist-put opts (cdr (assoc w cmacs-ai-ingest--flags)) (pop words))))
           ((assoc w cmacs-ai-ingest--switches)
            (setq opts (plist-put opts (cdr (assoc w cmacs-ai-ingest--switches)) t)))
           ((and (null input) (not (string-prefix-p "-" w))) (setq input w))
           (t (setq text (string-join (cons w words) " ") words nil)))))
      (when chat (setq opts (plist-put opts :chat t)))
      (cons input (cons text opts)))))

(defun cmacs-ai-ingest-slash-command (line)
  "Handle LINE when it is an `/ingest' compose command; non-nil if consumed."
  (let ((parsed (cmacs-ai-ingest-parse-command line)))
    (when parsed
      (cmacs-ai-ingest--ensure)
      (pcase-let ((`(,input ,text . ,opts) parsed))
        (let ((chat (plist-get opts :chat)))
          (setq opts (cl-loop for (k v) on opts by #'cddr unless (eq k :chat) append (list k v)))
          (cond
           ((and (null input) (null text))
            (apply #'cmacs-ai-ingest-chat opts))
           (input
            (let ((in (if (cmacs-secondbrain-ingest-url-p input) input (expand-file-name input))))
              (cmacs-ai-ingest--report (apply #'cmacs-secondbrain-ingest-run in opts))))
           (t
            (cmacs-ai-ingest--report
             (apply #'cmacs-secondbrain-ingest-run nil :text text :source "chat" opts))))
          (ignore chat)))
      t)))

(defun cmacs-ai-ingest--report (jobs)
  "Say what was queued."
  (message "cmacs-ai: queued %d ingest job%s (%s); M-x cmacs-secondbrain-ingest-queue to follow"
           (length jobs) (if (= 1 (length jobs)) "" "s")
           (mapconcat #'cmacs-secondbrain-ingest-job-id jobs ", "))
  jobs)

;;;; The chat itself -------------------------------------------------------------

(defun cmacs-ai-ingest--chat-text (&optional buffer)
  "Return BUFFER's transcript: everything above the compose region."
  (with-current-buffer (or buffer (current-buffer))
    (let ((end (if (and (boundp 'cmacs-ai-chat--compose-marker)
                        (markerp cmacs-ai-chat--compose-marker))
                   (marker-position cmacs-ai-chat--compose-marker)
                 (point-max))))
      (string-trim (buffer-substring-no-properties (point-min) end)))))

(defun cmacs-ai-ingest--chat-title (text)
  "A title for a chat: its `#+title', else the first user line, else the date."
  (or (and (string-match "^#\\+title:[ \t]*\\(.+\\)$" text) (string-trim (match-string 1 text)))
      (and (string-match "^\\*\\* [^\n]*\n+\\([^\n*#][^\n]\\{3,\\}\\)" text)
           (truncate-string-to-width (string-trim (match-string 1 text)) 80 nil nil "…"))
      (format "Chat %s" (format-time-string "%F %R"))))

;;;###autoload
(defun cmacs-ai-ingest-chat (&rest opts)
  "File this chat's transcript in the second brain as an Org note.
OPTS override the defaults (`:para', `:directory', `:tags', `:title', ...)."
  (interactive)
  (cmacs-ai-ingest--ensure)
  (unless (derived-mode-p 'cmacs-ai-chat-mode)
    (user-error "not a cmacs-ai chat buffer"))
  (let* ((text (cmacs-ai-ingest--chat-text))
         (provider (and (boundp 'cmacs-ai-chat-provider) cmacs-ai-chat-provider))
         (tags (append cmacs-ai-ingest-chat-tags
                       (and provider (list (format "%s" provider)))))
         (defaults (delq nil
                         (append (list :text text :format 'org :source (buffer-name)
                                       :title (cmacs-ai-ingest--chat-title text)
                                       :tags tags)
                                 (and cmacs-ai-ingest-chat-directory
                                      (not (plist-member opts :para))
                                      (not (plist-member opts :directory))
                                      (list :directory cmacs-ai-ingest-chat-directory))
                                 (and (not cmacs-ai-ingest-chat-summarize)
                                      (not (plist-member opts :no-summary))
                                      (list :no-summary t))))))
    (when (string-empty-p text) (user-error "this chat is empty"))
    (cmacs-ai-ingest--report
     (apply #'cmacs-secondbrain-ingest-run nil (append opts defaults)))))

;;;; Menu actions ---------------------------------------------------------------

(defun cmacs-ai-ingest--target-input (target)
  "Return (INPUTS . OPTS) to ingest TARGET, or nil when it has nothing to file."
  (let ((kind (cmacs-ai-target-kind target))
        (file (cmacs-ai-target-file target))
        (files (cmacs-ai-target-files target))
        (url (cmacs-ai-target-plist-get target :url)))
    (cond
     ((eq kind 'chat) (cons nil (list :chat t)))
     ((and url (cmacs-secondbrain-ingest-url-p url)) (cons url nil))
     ((memq kind '(files directory)) (and files (cons files nil)))
     ((and file (file-exists-p file) (memq kind '(file mail image)))
      (cons file nil))
     (t
      ;; Text targets: the full payload, not the truncated prompt view.
      (let ((text (or (cmacs-ai-target-text target)
                      (when-let* ((fn (cmacs-ai-target-content-fn target)))
                        (ignore-errors (funcall fn))))))
        (and text (not (string-blank-p text))
             (cons nil (list :text text
                             :format (pcase kind ('org-node 'org) ('roam-node 'org) (_ nil))
                             :source (or file (cmacs-ai-target-label target))
                             :title (and (memq kind '(org-node roam-node))
                                         (cmacs-ai-target-label target))))))))))

(defun cmacs-ai-ingest--run-target (target)
  "Ingest TARGET after asking where it should go."
  (cmacs-ai-ingest--ensure)
  (let ((spec (cmacs-ai-ingest--target-input target)))
    (unless spec (user-error "nothing here to file"))
    (if (plist-get (cdr spec) :chat)
        (with-current-buffer (or (cmacs-ai-target-buffer target) (current-buffer))
          (cmacs-ai-ingest-chat))
      (let ((para (completing-read "PARA (empty = detect/inbox per config): "
                                   '("inbox" "projects" "areas" "resources" "detect") nil nil)))
        (cmacs-ai-ingest--report
         (apply #'cmacs-secondbrain-ingest-run (car spec)
                (append (cdr spec) (and (not (string-empty-p para)) (list :para para)))))))))

(cmacs-ai-register-action
 :name 'cmacs-ai-ingest
 :group 'notes :order 5
 :label (lambda (target)
          (if (eq (cmacs-ai-target-kind target) 'chat)
              "File this chat in the second brain"
            "Ingest into the second brain"))
 :help "Turn this into an Org note: summarised, tagged, placed by PARA, linked"
 :applies (lambda (target)
            (and (cmacs-ai-ingest--available-p)
                 (memq (cmacs-ai-target-kind target)
                       '(file files directory url gsurf-page region org-node roam-node
                         mail clip chat image))))
 :run #'cmacs-ai-ingest--run-target)

;;;; A tool for the model -------------------------------------------------------------

(defun cmacs-ai-ingest--tool-spec ()
  "The `secondbrain_ingest' tool for an HTTP-provider chat executor."
  (cmacs-ai-define-tool
   "secondbrain_ingest"
   "File a URL, an absolute path, or literal text into the user's second brain as an Org note (summarised, tagged, placed in the PARA tree, linked). Returns the queued job as JSON; the work finishes in the background."
   '(("input" "string" "A URL or absolute path; omit when text is given" nil)
     ("text" "string" "Literal text to file instead of a URL or path" nil)
     ("para" "string" "inbox, projects, areas, resources or detect" nil)
     ("category" "string" "Sub path under the category, e.g. technical/linux" nil)
     ("tags" "string" "Comma-separated tags" nil)
     ("title" "string" "Title to use" nil))
   (lambda (_name input _id)
     (condition-case err
         (let* ((args (json-parse-string input :object-type 'alist :null-object nil))
                (get (lambda (k) (let ((v (alist-get k args))) (and (stringp v) (not (string-empty-p v)) v))))
                (in (funcall get 'input))
                (text (funcall get 'text)))
           (cmacs-ai-ingest--ensure)
           (unless (or in text) (error "give input or text"))
           (let ((jobs (apply #'cmacs-secondbrain-ingest-run in
                              (delq nil (append (and text (list :text text))
                                                (and (funcall get 'para) (list :para (funcall get 'para)))
                                                (and (funcall get 'category) (list :category (funcall get 'category)))
                                                (and (funcall get 'tags) (list :tags (funcall get 'tags)))
                                                (and (funcall get 'title) (list :title (funcall get 'title))))))))
             (cmacs-secondbrain-ingest-status-json (cmacs-secondbrain-ingest-job-id (car jobs)))))
       (error (json-serialize (list :error (error-message-string err))))))))

(defun cmacs-ai-ingest--install-tool (executor _provider)
  "Register the ingest tool on a chat EXECUTOR."
  (when (and (cmacs-ai-ingest--available-p) (fboundp 'cmacs-ai-define-tool))
    (ignore-errors (cmacs-ai--register-tool executor (cmacs-ai-ingest--tool-spec)))))

;;;; Wiring ------------------------------------------------------------------------

(with-eval-after-load 'cmacs-ai-chat
  (add-hook 'cmacs-ai-chat-slash-command-functions #'cmacs-ai-ingest-slash-command)
  (add-hook 'cmacs-ai-chat-executor-functions #'cmacs-ai-ingest--install-tool)
  (define-key cmacs-ai-chat-mode-map (kbd "C-c C-b") #'cmacs-ai-ingest-chat))

(provide 'cmacs-ai-ingest)
;;; cmacs-ai-ingest.el ends here
