;;; cmacs-ai-research.el --- libresearch: cited answers, page reads, LQL  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The editor face of libresearch, a self-hosted metasearch server
;; (libresearchd), through ai-glib's AiLibresearchSearch:
;;
;;   `cmacs-ai-research'              a question -> an Org buffer holding
;;                                    the cited answer and its sources
;;   `cmacs-ai-web-fetch'             a URL -> the page's readable text,
;;                                    optionally from the Wayback Machine
;;   `cmacs-ai-lql'                   an LQL query -> an Org table
;;   `cmacs-ai-research-search'       plain metasearch -> an Org list
;;   `cmacs-ai-research-environment'  what LQL may name on this server
;;
;; and the same four inside a cmacs-ai chat, as compose commands:
;; `/research QUESTION' (`/research! QUESTION' for a deep run), `/fetch
;; URL' and `/lql QUERY'.  The result lands in the transcript under its
;; own heading; nothing is sent to the model.
;;
;; Every request runs on a worker thread in C (cmacs-ai-libresearch.c),
;; so Emacs stays responsive for the minutes a research run takes.  The
;; commands take a callback; code that has to wait -- an MCP tool, a
;; brigade tool -- uses `cmacs-ai-research-sync', which polls rather
;; than reading events, so it also works inside an RPC dispatch, where
;; `inhibit-interaction' makes `sit-for' signal.
;;
;; The server and its token come from `cmacs-ai-libresearch-endpoint' and
;; `cmacs-ai-libresearch-token' (auth-source) in cmacs-ai.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cmacs-ai)

(declare-function cmacs-ai--libresearch-search "cmacs-ai-libresearch.c" (query callback &optional options))
(declare-function cmacs-ai--libresearch-fetch "cmacs-ai-libresearch.c" (url callback &optional options))
(declare-function cmacs-ai--libresearch-lql "cmacs-ai-libresearch.c" (lql callback &optional options))
(declare-function cmacs-ai--libresearch-research "cmacs-ai-libresearch.c" (question callback &optional options))
(declare-function cmacs-ai--libresearch-environment "cmacs-ai-libresearch.c" (&optional callback options))
(declare-function cmacs-ai--libresearch-poll "cmacs-ai-libresearch.c" (id))
(declare-function cmacs-ai--libresearch-cancel "cmacs-ai-libresearch.c" (id))
(declare-function cmacs-ai-chat--insert-heading "cmacs-ai-chat" (buf role body &optional level))
(declare-function cmacs-ai-chat--seal-history "cmacs-ai-chat" ())

(defvar cmacs-ai-chat-slash-command-functions)
(defvar cmacs-ai-chat--allow-history-edit)

(defgroup cmacs-ai-research nil
  "libresearch from cmacs-ai: research answers, page reads, LQL."
  :group 'cmacs-ai
  :prefix "cmacs-ai-research-")

(defcustom cmacs-ai-research-pages nil
  "Pages a research run reads, 1-20; nil leaves it to the server."
  :type '(choice (const :tag "Server default" nil) (integer :tag "Pages"))
  :group 'cmacs-ai-research)

(defcustom cmacs-ai-research-fetch-archive 'never
  "Whether `cmacs-ai-web-fetch' may read the Wayback Machine's copy.
`never' reads only the live page, `fallback' uses the archive when the
live page cannot be read, `only' reads the archive."
  :type '(choice (const never) (const fallback) (const only))
  :group 'cmacs-ai-research)

(defcustom cmacs-ai-research-fetch-max-chars nil
  "Longest page text to fetch, 100-1000000; nil leaves it to the server."
  :type '(choice (const :tag "Server default" nil) (integer :tag "Characters"))
  :group 'cmacs-ai-research)

(defcustom cmacs-ai-research-lql-max-rows 200
  "Most LQL rows rendered into a table; nil for all of them."
  :type '(choice (const :tag "All" nil) natnum)
  :group 'cmacs-ai-research)

(defcustom cmacs-ai-research-cell-width 80
  "Longest an LQL table cell is shown before it is truncated."
  :type 'natnum
  :group 'cmacs-ai-research)

(defvar cmacs-ai-research-history nil
  "Minibuffer history of research questions.")

(defvar cmacs-ai-research-lql-history nil
  "Minibuffer history of LQL queries.")

;;;; Requests -------------------------------------------------------------------

(defun cmacs-ai-research-available-p ()
  "Non-nil when this cmacs was built with the libresearch primitives."
  (fboundp 'cmacs-ai--libresearch-research))

(defun cmacs-ai-research--ensure ()
  "Signal a `user-error' unless the libresearch primitives exist."
  (unless (cmacs-ai-research-available-p)
    (user-error "cmacs-ai: libresearch needs a cmacs built --with-cmacs-ai")))

(defun cmacs-ai-research--timeout (kind)
  "The :timeout a KIND request gets by default."
  (if (eq kind 'research)
      cmacs-ai-libresearch-research-timeout
    cmacs-ai-libresearch-timeout))

(defun cmacs-ai-research-request (kind arg callback &rest options)
  "Start a libresearch request of KIND for ARG; return its id.

KIND is `search', `fetch', `lql', `research' or `environment' (ARG is
ignored for the last).  CALLBACK receives the payload once, on the
Lisp thread -- (:ok :kind K :text TEXT :json JSON), (:error MSG) or
\(:cancelled) -- or is nil, in which case collect it with
`cmacs-ai-research-wait'.  OPTIONS is the plist the primitive takes
\(:deep, :pages, :explain, :archive, :max-chars, :category, :count,
:site, :max-rows, :timeout); the server URL and token are added from
`cmacs-ai-libresearch-endpoint' and `cmacs-ai-libresearch-token'."
  (cmacs-ai-research--ensure)
  (let* ((timeout (cmacs-ai-research--timeout kind))
         (opts (apply #'cmacs-ai-libresearch-options
                      (append options
                              (and timeout (not (plist-member options :timeout))
                                   (list :timeout timeout))))))
    (pcase kind
      ('search (cmacs-ai--libresearch-search arg callback opts))
      ('fetch (cmacs-ai--libresearch-fetch arg callback opts))
      ('lql (cmacs-ai--libresearch-lql arg callback opts))
      ('research (cmacs-ai--libresearch-research arg callback opts))
      ('environment (cmacs-ai--libresearch-environment callback opts))
      (_ (error "cmacs-ai-research: unknown request kind %S" kind)))))

(defun cmacs-ai-research--collect-later (id)
  "Keep polling request ID in the background until it is collected.
For a request abandoned mid-wait: the C side holds it until somebody
collects it, and nobody else is going to."
  (let ((timer nil) (tries 0))
    (setq timer
          (run-with-timer
           1 1
           (lambda ()
             (setq tries (1+ tries))
             (when (or (> tries 600)
                       (condition-case nil
                           (cmacs-ai--libresearch-poll id)
                         (error t)))
               (cancel-timer timer)))))))

(defun cmacs-ai-research-wait (id &optional timeout)
  "Wait for libresearch request ID and return its payload.

Polls with `accept-process-output', never `sit-for': this is called
from MCP and D-Bus dispatch, where `inhibit-interaction' is bound and
`read-event' -- which `sit-for' uses -- signals.  Gives up after
TIMEOUT seconds (default an hour; the request carries its own
deadline) with (:error \"timed out\"), cancelling the request.  A quit
cancels it too."
  (let ((deadline (+ (float-time) (or timeout 3600)))
        (payload nil)
        (done nil))
    (unwind-protect
        (progn
          (while (and (not (setq payload (cmacs-ai--libresearch-poll id)))
                      (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (setq done (and payload t))
          (or payload
              (list :error (format "libresearch request %s timed out" id))))
      (unless done
        (cmacs-ai--libresearch-cancel id)
        (cmacs-ai-research--collect-later id)))))

(defun cmacs-ai-research-sync (kind arg &rest options)
  "Run a libresearch request of KIND for ARG and return its payload.
Blocks the caller (not the network: that runs on a worker thread)
until the request finishes; OPTIONS are as in
`cmacs-ai-research-request'."
  (let* ((timeout (or (plist-get options :timeout)
                      (cmacs-ai-research--timeout kind)))
         (id (apply #'cmacs-ai-research-request kind arg nil options)))
    ;; A little longer than the request's own deadline, so the request
    ;; reports its own timeout rather than this loop reporting a vaguer one.
    (cmacs-ai-research-wait id (and timeout (+ timeout 15)))))

(defun cmacs-ai-research-sync-text (kind arg &rest options)
  "Like `cmacs-ai-research-sync' but return the text a model should see.
An error comes back as a string starting \"error: \" rather than as a
signal, which is what a tool result wants."
  (let ((p (apply #'cmacs-ai-research-sync kind arg options)))
    (pcase (car p)
      (:ok (plist-get (cdr p) :text))
      (:error (concat "error: " (cadr p)))
      (_ "error: cancelled"))))

(defun cmacs-ai-research-payload-document (payload)
  "Parse PAYLOAD's :json into a plist (arrays as lists), or nil."
  (when (eq (car payload) :ok)
    (let ((json (plist-get (cdr payload) :json)))
      (and (stringp json)
           (ignore-errors
             (json-parse-string json :object-type 'plist :array-type 'list
                                :null-object nil :false-object nil))))))

;;;; Org rendering --------------------------------------------------------------
;;
;; Each renderer returns an Org BODY with no headlines of its own, so the
;; same text can sit under a heading in a result buffer or under a
;; `** research' heading in a chat transcript, where a stray headline would
;; split the turn.

(defun cmacs-ai-research--escape (text)
  "Make TEXT safe as Org body text: no line may start a headline or keyword."
  (replace-regexp-in-string "^\\(\\*+ \\|#\\+\\)" ",\\1" (or text "") t))

(defun cmacs-ai-research--link (url desc)
  "An Org link to URL described by DESC, or DESC alone without a URL."
  (let ((d (replace-regexp-in-string "[][]" "" (or desc ""))))
    (cond ((or (null url) (string-empty-p url)) d)
          ((string-empty-p d) (format "[[%s]]" url))
          (t (format "[[%s][%s]]" url d)))))

(defun cmacs-ai-research--cell (value)
  "VALUE as one Org table cell."
  (let* ((s (cond ((null value) "")
                  ((stringp value) value)
                  ((numberp value) (number-to-string value))
                  ((eq value t) "true")
                  (t (json-encode value))))
         (s (replace-regexp-in-string "[\n\r\t]+" " " s))
         (s (replace-regexp-in-string "|" "\\vert{}" s t t)))
    (if (and cmacs-ai-research-cell-width
             (> (length s) cmacs-ai-research-cell-width))
        (concat (substring s 0 (max 1 (1- cmacs-ai-research-cell-width))) "…")
      s)))

(defun cmacs-ai-research--failed-engines (doc)
  "One line naming the engines in DOC that did not answer, or nil."
  (let ((failed (cl-loop for e in (plist-get doc :engines)
                         for state = (plist-get e :state)
                         when (and state (not (equal state "ok")))
                         collect (format "%s (%s)" (plist-get e :id) state))))
    (and failed
         (format "/Engines that did not answer: %s/\n"
                 (string-join failed ", ")))))

(defun cmacs-ai-research-org-research (doc)
  "Org body for a libresearch.research/1 DOC: the answer, then sources."
  (let ((answer (or (plist-get doc :answer) "(no answer)"))
        (sources (plist-get doc :sources))
        (dropped (plist-get doc :dropped_citations)))
    (concat
     (cmacs-ai-research--escape (string-trim answer)) "\n"
     (when sources
       (concat
        "\n*Sources*\n\n"
        (mapconcat
         (lambda (src)
           (let* ((notes (delq nil
                               (list (and (eq (plist-get src :read) nil)
                                          (plist-member src :read) "not read")
                                     (and (eq (plist-get src :cited) nil)
                                          (plist-member src :cited) "not cited")
                                     (and (plist-get src :archive_url)
                                          (cmacs-ai-research--link
                                           (plist-get src :archive_url)
                                           "archived copy"))))))
             (format "- [%s] %s%s"
                     (or (plist-get src :n) "?")
                     (cmacs-ai-research--link (plist-get src :url)
                                              (or (plist-get src :title)
                                                  (plist-get src :url)))
                     (if notes (format " /(%s)/" (string-join notes ", ")) ""))))
         sources "\n")
        "\n"))
     (when (and (numberp dropped) (> dropped 0))
       (format "\n/%d citations named no source and were dropped./\n" dropped)))))

(defun cmacs-ai-research-org-fetch (doc)
  "Org body for a libresearch.fetch/1 DOC: where it came from, then the text."
  (let ((url (plist-get doc :url))
        (archive (plist-get doc :archive_url)))
    (concat
     (format "- URL :: %s\n" (cmacs-ai-research--link url url))
     (when (plist-get doc :title)
       (format "- Title :: %s\n" (plist-get doc :title)))
     (when archive
       (format "- Read from :: %s (archived %s)\n"
               (cmacs-ai-research--link archive "the Wayback Machine")
               (or (plist-get doc :archived_at) "?")))
     (when (plist-get doc :truncated)
       "- Note :: truncated by the server; raise =:max-chars= for more\n")
     "\n"
     (cmacs-ai-research--escape
      (or (plist-get doc :text) "(the page has no readable text)"))
     "\n")))

(defun cmacs-ai-research-org-lql (doc)
  "Org body for a libresearch.query/1 DOC: the plan, or a table of rows."
  (let ((explain (plist-get doc :explain)))
    (if explain
        (format "Plan for =%s=:\n\n#+begin_example\n%s\n#+end_example\n"
                (or (plist-get doc :query) "")
                (cmacs-ai-research--escape explain))
      (let* ((cols (cl-loop for c in (plist-get doc :columns)
                            for name = (plist-get c :name)
                            when name collect name))
             (keys (mapcar (lambda (n) (intern (concat ":" n))) cols))
             (rows (plist-get doc :rows))
             (cap cmacs-ai-research-lql-max-rows)
             (answers nil)
             (table nil)
             (shown 0))
        (dolist (row rows)
          (if (and (equal (plist-get row :kind) "answer")
                   (stringp (plist-get row :text)))
              (push (plist-get row :text) answers)
            (when (or (null cap) (< shown cap))
              (setq shown (1+ shown))
              (push (concat "| "
                            (mapconcat (lambda (k)
                                         (cmacs-ai-research--cell (plist-get row k)))
                                       keys " | ")
                            " |")
                    table))))
        (concat
         (format "Query: =%s= -- %d row%s\n"
                 (or (plist-get doc :query) "") (length rows)
                 (if (= (length rows) 1) "" "s"))
         (when (plist-get doc :confidential)
           "/A confidential engine answered: model functions were refused./\n")
         (when answers
           (concat "\n*Answer*\n\n"
                   (cmacs-ai-research--escape
                    (string-join (nreverse answers) "\n\n"))
                   "\n"))
         (when (and cols table)
           (concat "\n| " (string-join cols " | ") " |\n|-\n"
                   (string-join (nreverse table) "\n") "\n"))
         (let ((rest (- (length rows) (length answers) shown)))
           (when (> rest 0)
             (format "\n/%d more rows not shown (=cmacs-ai-research-lql-max-rows=)./\n"
                     rest)))
         (let ((f (cmacs-ai-research--failed-engines doc)))
           (and f (concat "\n" f))))))))

(defun cmacs-ai-research-org-search (doc)
  "Org body for a libresearch.search/1 DOC: instant answers, then results."
  (concat
   (mapconcat
    (lambda (box)
      (when (plist-get box :body)
        (format "- *%s* :: %s\n"
                (or (plist-get box :provider) "Answer")
                (cmacs-ai-research--escape (plist-get box :body)))))
    (plist-get doc :infoboxes) "")
   (let ((results (plist-get doc :results)))
     (if (null results)
         "No results.\n"
       (mapconcat
        (lambda (r)
          (concat
           (format "- %s" (cmacs-ai-research--link (plist-get r :url)
                                                   (or (plist-get r :title)
                                                       (plist-get r :url))))
           (when (plist-get r :published)
             (format " /(%s)/" (plist-get r :published)))
           "\n"
           (when (plist-get r :snippet)
             (format "  %s\n" (cmacs-ai-research--escape
                                (replace-regexp-in-string
                                 "[\n\r]+" " " (plist-get r :snippet)))))))
        results "")))
   (let ((f (cmacs-ai-research--failed-engines doc)))
     (and f (concat "\n" f)))))

(defun cmacs-ai-research-org-body (payload)
  "Org body for any libresearch PAYLOAD, an error included."
  (pcase (car payload)
    (:ok
     (let ((doc (cmacs-ai-research-payload-document payload))
           (kind (plist-get (cdr payload) :kind)))
       (if (null doc)
           (cmacs-ai-research--escape (plist-get (cdr payload) :text))
         (pcase kind
           ('research (cmacs-ai-research-org-research doc))
           ('fetch (cmacs-ai-research-org-fetch doc))
           ('lql (cmacs-ai-research-org-lql doc))
           ('search (cmacs-ai-research-org-search doc))
           (_ (format "#+begin_src json\n%s\n#+end_src\n"
                      (cmacs-ai-research--escape
                       (plist-get (cdr payload) :text))))))))
    (:error (format "*Error:* %s\n" (cmacs-ai-research--escape (cadr payload))))
    (_ "/Cancelled./\n")))

;;;; Result buffers -------------------------------------------------------------

(defvar-local cmacs-ai-research--rerun nil
  "Thunk that repeats this buffer's request, for \\[revert-buffer].")

(defvar-local cmacs-ai-research--request nil
  "Id of the request this buffer is waiting on, or nil.")

(defvar cmacs-ai-research-result-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'cmacs-ai-research-cancel)
    ;; The buffer is read-only, so plain keys are free.
    (define-key map (kbd "g") #'revert-buffer)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-ai-research-result-mode'.")

(define-minor-mode cmacs-ai-research-result-mode
  "Minor mode of a libresearch result buffer.
\\<cmacs-ai-research-result-mode-map>\\[revert-buffer] repeats the request, \\[cmacs-ai-research-cancel] cancels
one still running and \\[quit-window] puts the buffer away."
  :lighter " Research"
  :keymap cmacs-ai-research-result-mode-map)

(defun cmacs-ai-research-cancel ()
  "Cancel the request this result buffer is waiting on."
  (interactive)
  (if (and cmacs-ai-research--request
           (cmacs-ai--libresearch-cancel cmacs-ai-research--request))
      (message "cmacs-ai: cancelling the libresearch request")
    (message "cmacs-ai: nothing running here")))

(defun cmacs-ai-research--revert (&rest _)
  "`revert-buffer-function' of a result buffer: run its request again."
  (if cmacs-ai-research--rerun
      (funcall cmacs-ai-research--rerun)
    (user-error "Nothing to repeat here")))

(defun cmacs-ai-research--open (name title header)
  "Show a fresh result buffer NAME, titled TITLE, with HEADER under it.
Returns the buffer."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'org-mode) (org-mode))
        (insert (format "#+title: %s\n#+date: %s\n\n%s"
                        (cmacs-ai-research--escape title)
                        (format-time-string "[%Y-%m-%d %a %H:%M]")
                        header))
        (insert "/Waiting for the libresearch server .../\n"))
      (cmacs-ai-research-result-mode 1)
      (setq-local revert-buffer-function #'cmacs-ai-research--revert)
      (setq buffer-read-only t)
      (set-buffer-modified-p nil))
    (pop-to-buffer buf)
    buf))

(defun cmacs-ai-research--fill (buf payload)
  "Replace BUF's waiting line with the rendering of PAYLOAD."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-ai-research--request nil)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward "^/Waiting for the libresearch server \\.\\.\\./\n"
                                   nil t)
            (replace-match "" t t))
          (goto-char (point-max))
          (insert (cmacs-ai-research-org-body payload))))
      (set-buffer-modified-p nil)
      (when (eq (car payload) :error)
        (message "cmacs-ai: libresearch: %s" (cadr payload))))))

(defun cmacs-ai-research--run-into (buf kind arg options)
  "Start a KIND request for ARG with OPTIONS whose result fills BUF."
  (with-current-buffer buf
    (setq cmacs-ai-research--request
          (apply #'cmacs-ai-research-request kind arg
                 (lambda (payload) (cmacs-ai-research--fill buf payload))
                 options))))

(defun cmacs-ai-research--show (name title header kind arg options)
  "Open result buffer NAME and fill it from a KIND request for ARG.
TITLE and HEADER are as in `cmacs-ai-research--open'; OPTIONS go to
`cmacs-ai-research-request'.  Returns the buffer."
  (cmacs-ai-research--ensure)
  (let ((buf (cmacs-ai-research--open name title header)))
    (with-current-buffer buf
      (setq cmacs-ai-research--rerun
            (lambda ()
              (cmacs-ai-research--show name title header kind arg options))))
    (cmacs-ai-research--run-into buf kind arg options)
    buf))

;;;; Commands -------------------------------------------------------------------

;;;###autoload
(defun cmacs-ai-research (question &optional deep pages)
  "Ask the libresearch server for a cited answer to QUESTION.

The answer and its numbered sources land in an Org buffer, the
sources as links.  With a plain prefix argument, DEEP: the server's
model may run follow-up searches.  A numeric prefix argument is PAGES,
how many pages to read (1-20; default `cmacs-ai-research-pages').  A
run takes minutes and Emacs stays usable meanwhile."
  (interactive
   (list (read-string "Research: " nil 'cmacs-ai-research-history)
         (consp current-prefix-arg)
         (and (integerp current-prefix-arg) current-prefix-arg)))
  (when (string-empty-p (string-trim question))
    (user-error "Nothing to research"))
  (let ((pages (or pages cmacs-ai-research-pages)))
    (cmacs-ai-research--show
     "*cmacs-ai research*"
     (concat "Research: " question)
     (format "- Question :: %s\n- Mode :: %s%s\n- Server :: %s\n\n"
             (cmacs-ai-research--escape question)
             (if deep "deep" "standard")
             (if pages (format ", %d pages" pages) "")
             (cmacs-ai-libresearch-endpoint))
     'research question
     (append (and deep (list :deep t)) (and pages (list :pages pages))))))

;;;###autoload
(defun cmacs-ai-web-fetch (url &optional archive)
  "Show the readable text of the page at URL, fetched by libresearch.

ARCHIVE is `never', `fallback' or `only' -- whether the Wayback
Machine's copy may stand in for the live page; it defaults to
`cmacs-ai-research-fetch-archive', and a prefix argument asks."
  (interactive
   (list (read-string "Fetch URL: " (thing-at-point 'url t))
         (and current-prefix-arg
              (intern (completing-read "Archive: " '("never" "fallback" "only")
                                       nil t nil nil "fallback")))))
  (when (string-empty-p (string-trim url))
    (user-error "No URL"))
  (let ((archive (or archive cmacs-ai-research-fetch-archive)))
    (cmacs-ai-research--show
     "*cmacs-ai web fetch*"
     url ""
     'fetch url
     (append (list :archive archive)
             (and cmacs-ai-research-fetch-max-chars
                  (list :max-chars cmacs-ai-research-fetch-max-chars))))))

;;;###autoload
(defun cmacs-ai-lql (query &optional explain)
  "Run the LQL QUERY on the libresearch server and show it as an Org table.

LQL is libresearch's query language: `search \"glib\", category: CODE |
filter extra.stars > 100 | fields title, url', or the pipe shorthand
`gtk docs | filter site(\"docs.gtk.org\")'.  With a prefix argument,
EXPLAIN: show the plan without running it.  See
`cmacs-ai-research-environment' for what this server's queries may name."
  (interactive
   (list (read-string (if current-prefix-arg "Explain LQL: " "LQL: ")
                      nil 'cmacs-ai-research-lql-history)
         current-prefix-arg))
  (when (string-empty-p (string-trim query))
    (user-error "No query"))
  (cmacs-ai-research--show
   "*cmacs-ai lql*"
   (concat (if explain "LQL plan: " "LQL: ") query)
   ""
   'lql query
   (append (and explain (list :explain t))
           (and cmacs-ai-research-lql-max-rows
                (list :max-rows cmacs-ai-research-lql-max-rows)))))

;;;###autoload
(defun cmacs-ai-research-search (query &optional category)
  "Search the web through libresearch for QUERY; results as an Org list.
With a prefix argument, ask for CATEGORY: web, images, videos, news or
code."
  (interactive
   (list (read-string "Search: " nil 'cmacs-ai-research-history)
         (and current-prefix-arg
              (completing-read "Category: "
                               '("web" "images" "videos" "news" "code")
                               nil t))))
  (when (string-empty-p (string-trim query))
    (user-error "Nothing to search for"))
  (cmacs-ai-research--show
   "*cmacs-ai search*"
   (concat "Search: " query)
   ""
   'search query
   (and category (list :category category))))

;;;###autoload
(defun cmacs-ai-research-environment ()
  "Show what LQL may name on the libresearch server.
The server's commands, sources, functions and constants, modules
included: the authoritative list for this instance."
  (interactive)
  (cmacs-ai-research--show
   "*cmacs-ai lql environment*"
   (concat "LQL environment: " (cmacs-ai-libresearch-endpoint))
   ""
   'environment nil nil))

;;;; Chat: /research, /fetch, /lql ---------------------------------------------

(defun cmacs-ai-research-parse-command (line)
  "Parse a chat compose LINE into (KIND ARG . OPTIONS), or nil.
Understands `/research Q', `/research! Q' (deep), `/fetch URL' and
`/lql QUERY'."
  (when (string-match
         "\\`[ \t]*/\\(research!?\\|fetch\\|lql\\)[ \t]+\\(\\(?:.\\|\n\\)+\\)\\'"
         line)
    (let ((cmd (match-string 1 line))
          (arg (string-trim (match-string 2 line))))
      (unless (string-empty-p arg)
        (pcase cmd
          ("research" (list 'research arg))
          ("research!" (list 'research arg :deep t))
          ("fetch" (list 'fetch arg :archive cmacs-ai-research-fetch-archive))
          ("lql" (append (list 'lql arg)
                         (and cmacs-ai-research-lql-max-rows
                              (list :max-rows cmacs-ai-research-lql-max-rows)))))))))

(defun cmacs-ai-research--chat-insert (buf marker payload)
  "Insert the rendering of PAYLOAD at MARKER in chat BUF, then seal it."
  (when (and (buffer-live-p buf) (marker-buffer marker))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (cmacs-ai-chat--allow-history-edit t))
        (save-excursion
          (goto-char marker)
          ;; The placeholder is the rest of the body line.
          (delete-region (line-beginning-position) marker)
          (insert (string-trim-right (cmacs-ai-research-org-body payload)))))
      (set-marker marker nil)
      (when (fboundp 'cmacs-ai-chat--seal-history)
        (cmacs-ai-chat--seal-history)))))

(defun cmacs-ai-research-slash-command (line)
  "Handle LINE when it is a `/research', `/fetch' or `/lql' command.
Returns non-nil when LINE was consumed."
  (let ((parsed (cmacs-ai-research-parse-command line)))
    (when parsed
      (cmacs-ai-research--ensure)
      (pcase-let* ((`(,kind ,arg . ,options) parsed)
                   (buf (current-buffer))
                   (marker (cmacs-ai-chat--insert-heading
                            buf (symbol-name kind)
                            (format "/%s: %s .../"
                                    (pcase kind
                                      ('research "researching")
                                      ('fetch "fetching")
                                      (_ "querying"))
                                    (replace-regexp-in-string
                                     "[\n/]" " " arg)))))
        (apply #'cmacs-ai-research-request kind arg
               (lambda (payload)
                 (cmacs-ai-research--chat-insert buf marker payload))
               options))
      t)))

(with-eval-after-load 'cmacs-ai-chat
  (add-hook 'cmacs-ai-chat-slash-command-functions
            #'cmacs-ai-research-slash-command))

(provide 'cmacs-ai-research)
;;; cmacs-ai-research.el ends here
