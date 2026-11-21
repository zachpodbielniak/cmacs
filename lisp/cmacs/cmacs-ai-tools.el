;;; cmacs-ai-tools.el --- The cmacs-ai tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tools of cmacs/mcp/cmacs-mcp-tools-ai.c, moved onto the capability
;; table (doc_org/cmacs/cmacs-capability.org has the recipe).  The wire
;; names, parameter names and required/optional split are the C ones, so
;; nothing that called `ai_prompt' has to change.  That C file is
;; deleted; the schema these tools must keep is what it published,
;; frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; Three things differ from the C handlers, all on purpose:
;;
;;   - Nothing waits on the dispatch thread.  Every C handler here ran a
;;     model call, an image generation or a libresearch request to
;;     completion inside one synchronous eval -- minutes, for ai_research
;;     -- and under `emacs --gowl' that thread is the compositor.  Each
;;     of those is now an :async tool that starts the work through the
;;     asynchronous primitive (`cmacs-ai-chat-stream',
;;     `cmacs-ai-tools-run-async', `cmacs-ai-embed-async',
;;     `cmacs-ai-image-generate-async', `cmacs-ai-research-request') and
;;     answers from its callback.  The descriptions lost their "WARNING:
;;     this blocks the main thread" sentences for the same reason.
;;
;;   - No argument is spliced into Lisp source.  The C built
;;     "(quote %s)" from the provider name; here a provider is looked up
;;     with `intern-soft' and has to be one `cmacs-ai-providers' returns.
;;
;;   - A failure is a failure: it is signalled, or handed to `done' in
;;     the registry's "Error: ..." form, and each surface reports it in
;;     its own way.  The C returned "error: ..." as an ordinary result.
;;
;; Not here: `ai_list_models', which is cmacs-ai-models-tools.el (the
;; only primitive blocks for up to thirty seconds of network per
;; provider, so it runs in a child process), and the libresearch tools `web_research', `web_lql' and `web_search_show',
;; which cmacs-brigade-research.el already registers.
;;
;; The `ai_' tools are published to MCP, D-Bus and the CLI but not to
;; in-process agents: a model handed `ai_prompt' can call itself, which
;; is why the MCP bridge and the brigade allowlist both refuse the
;; prefix.  `generate_image' is deliberately not named `ai_...' and is on
;; every surface, as it was.

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-ai-default-provider)
(defvar cmacs-ai-default-model)

(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-client-new "cmacs-ai-client.c"
                  (provider &optional model))
(declare-function cmacs-ai-client-free "cmacs-ai-client.c" (handle))
(declare-function cmacs-ai-client-set-system-prompt "cmacs-ai-client.c"
                  (handle prompt))
(declare-function cmacs-ai-session-new "cmacs-ai-session.c" (client-handle))
(declare-function cmacs-ai-session-free "cmacs-ai-session.c" (handle))
(declare-function cmacs-ai-session-append-message "cmacs-ai-session.c"
                  (handle role text &optional images))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback &optional executor images))
(declare-function cmacs-ai-vision-refusal "cmacs-ai-vision"
                  (provider &optional model))
(declare-function cmacs-ai-image-parts "cmacs-ai-vision.c" (images))
(declare-function cmacs-project-tools--resolve "cmacs-project-tools" (path))
(declare-function cmacs-project-tools--hidden-p "cmacs-project-tools"
                  (file root))
(defvar cmacs-ai-image-max-bytes)
(declare-function cmacs-ai-tools-new "cmacs-ai-tools.c" ())
(declare-function cmacs-ai-tools-free "cmacs-ai-tools.c" (handle))
(declare-function cmacs-ai-tools-run-async "cmacs-ai-tools.c"
                  (session executor callback))
(declare-function cmacs-ai-embed-async "cmacs-ai-embed.c"
                  (texts callback &optional provider model))
(declare-function cmacs-ai-embed-cosine "cmacs-ai-embed.c" (a b))
(declare-function cmacs-ai-image-generate-async "cmacs-ai-image.c"
                  (client prompt callback &optional options))
(declare-function cmacs-ai-image--client "cmacs-ai-image"
                  (&optional provider model))
(declare-function cmacs-ai-image--place "cmacs-ai-image"
                  (images prompt buffer position))
(declare-function cmacs-ai-image-chat--parse-refs "cmacs-ai-image-chat" (raw))
(declare-function cmacs-ai-chat-open "cmacs-ai-chat"
                  (&optional provider model directory))
(declare-function cmacs-ai-chat-send-compose "cmacs-ai-chat" ())
(declare-function cmacs-ai-research-request "cmacs-ai-research"
                  (kind arg callback &rest options))


;;;; Arguments

(defun cmacs-ai-tools--text (value)
  "Return VALUE when it is a non-empty string, else nil.
An optional string a client sends as \"\" means what an absent one does,
as it did in the C handlers."
  (and (stringp value) (not (string-empty-p value)) value))

(defun cmacs-ai-tools--required (value tool what)
  "Return VALUE, or signal that TOOL is missing its WHAT argument."
  (or (cmacs-ai-tools--text value)
      (error "%s: missing '%s'" tool what)))

(defun cmacs-ai-tools--provider (provider)
  "Return PROVIDER, a name, as a provider symbol; nil when it is blank.
The name has to be one `cmacs-ai-providers' returns.  `intern-soft'
rather than `intern': an unknown name is reported, not turned into a
new symbol on the way to finding out that it names nothing."
  (when (cmacs-ai-tools--text provider)
    (let ((symbol (intern-soft provider)))
      (unless (and symbol (memq symbol (cmacs-ai-providers)))
        (error "Unknown provider `%s' (ai_list_providers lists them)"
               provider))
      symbol)))

(defun cmacs-ai-tools--failure (message)
  "Return MESSAGE in the form the registry reads as a failed call."
  (concat "Error: " (if (stringp message) message (format "%s" message))))


;;;; Images an agent names

;; `images' on ai_prompt and ai_call is an array of objects, each
;; {"path": P} or {"data": BASE64, "mime": TYPE}.  An agent reading
;; arbitrary image files off this disk and handing them to a remote model
;; is exfiltration by another name, so a path is held to exactly what
;; project_read_file would read: resolved against the workspace root,
;; refused when it escapes it (true names compared, so a symlink out
;; counts), refused when the redaction rules exclude it -- one answer for
;; "excluded" and "unreadable".  Bytes the agent sends itself are its
;; own; they pass the same size and type checks in C.

(defun cmacs-ai-tools--images (images)
  "Turn the tool argument IMAGES into image plists for the C primitives.
IMAGES is the registry's Lisp form of the JSON array: a list of alists.
Signals, naming the offending element, for anything refused."
  (let ((n 0))
    (mapcar
     (lambda (entry)
       (setq n (1+ n))
       (let ((path (alist-get 'path entry))
             (data (alist-get 'data entry))
             (mime (alist-get 'mime entry)))
         (cond
          ((and (cmacs-ai-tools--text path) (null data))
           (require 'cmacs-project-tools)
           (require 'cmacs-core-tools)
           (pcase-let ((`(,root . ,target) (cmacs-project-tools--resolve path)))
             (unless (and (file-regular-p target)
                          (file-readable-p target)
                          (not (cmacs-project-tools--hidden-p target root)))
               (error "images[%d]: file not readable: %s" n path))
             (list :file target)))
          ((and (cmacs-ai-tools--text data) (null path))
           ;; Bounded before decoding: base64 is 4 characters per 3 bytes.
           (when (> (* 3 (/ (length data) 4))
                    (if (boundp 'cmacs-ai-image-max-bytes)
                        cmacs-ai-image-max-bytes
                      (* 10 1024 1024)))
             (error "images[%d]: image over the size limit" n))
           (let ((bytes (condition-case nil
                            (base64-decode-string data)
                          (error (error "images[%d]: data is not base64" n)))))
             (append (list :data bytes)
                     (and (cmacs-ai-tools--text mime) (list :mime mime)))))
          (t (error "images[%d]: give exactly one of path and data" n)))))
     images)))

(defun cmacs-ai-tools--check-images (images provider model)
  "Signal unless IMAGES may go to PROVIDER with MODEL; return IMAGES.
Each is read and checked by the C (size, type) and the provider is
asked whether it can take pictures: refused, nothing is sent."
  (when images
    (require 'cmacs-ai-vision)
    (when-let* ((why (cmacs-ai-vision-refusal provider model)))
      (error "%s" why))
    (cmacs-ai-image-parts images))
  images)


;;;; One prompt, asynchronously

(defun cmacs-ai-tools--release (client session executor)
  "Free EXECUTOR, SESSION and CLIENT, whichever of them exist."
  (when executor (ignore-errors (cmacs-ai-tools-free executor)))
  (when session (ignore-errors (cmacs-ai-session-free session)))
  (when client (ignore-errors (cmacs-ai-client-free client))))

(defun cmacs-ai-tools--one-shot (done prompt provider system model tools
                                       &optional images)
  "Send PROMPT to a model and call DONE with its answer; return at once.
IMAGES, image plists already checked, go with PROMPT.

PROVIDER is a provider symbol or nil for `cmacs-ai-default-provider'.
SYSTEM and MODEL are strings or nil.  With TOOLS non-nil the model is
given ai-glib's built-in tools and the multi-turn tool loop runs on a
worker thread (`cmacs-ai-tools-run-async'); without, the answer is
streamed (`cmacs-ai-chat-stream') and DONE gets the whole text.

A throwaway client and session are made for the one call and freed when
it settles.  They are freed from a timer, not from inside the callback:
the callback runs while the stream that owns the session is still
unwinding."
  (require 'cmacs-ai)
  (let* ((client (cmacs-ai-client-new
                  (or provider cmacs-ai-default-provider)
                  ;; The configured default model belongs to the default
                  ;; provider; a named provider gets its own default.
                  (or model (and (null provider) cmacs-ai-default-model))))
         (session nil)
         (executor nil)
         (text "")
         (settled nil)
         (settle
          (lambda (answer)
            (unless settled
              (setq settled t)
              (run-at-time 0 nil #'cmacs-ai-tools--release
                           client session executor)
              (funcall done answer)))))
    (condition-case err
        (progn
          (when system
            (cmacs-ai-client-set-system-prompt client system))
          (setq session (cmacs-ai-session-new client))
          (if tools
              (progn
                (setq executor (cmacs-ai-tools-new))
                ;; The loop sends the session as it stands, so the
                ;; prompt has to be in it first.
                (if images
                    (cmacs-ai-session-append-message session 'user prompt
                                                     images)
                  (cmacs-ai-session-append-message session 'user prompt))
                (cmacs-ai-tools-run-async
                 session executor
                 (lambda (payload)
                   (funcall settle
                            (if (eq (car-safe payload) :text)
                                (or (cadr payload) "")
                              (cmacs-ai-tools--failure
                               (or (cadr payload) "the tool loop failed")))))))
            (apply
             #'cmacs-ai-chat-stream
             session prompt
             (lambda (payload)
               (pcase (car-safe payload)
                 (:delta (setq text (concat text (or (cadr payload) ""))))
                 (:end
                  ;; A provider that does not stream sends everything in
                  ;; :end; one that does may leave :text short.
                  (let ((final (plist-get (cdr payload) :text)))
                    (funcall settle (if (and (stringp final)
                                             (> (length final) (length text)))
                                        final
                                      text))))
                 (:error
                  (funcall settle
                           (cmacs-ai-tools--failure
                            (or (cadr payload) "the model failed"))))))
             ;; Only with images, so the call without them is the
             ;; three-argument call it always was.
             (and images (list nil images)))))
      (error
       ;; Nothing was started, or starting it failed: free now and let
       ;; the caller report the error.
       (setq settled t)
       (cmacs-ai-tools--release client session executor)
       (signal (car err) (cdr err))))))

(cmacs-brigade-deftool ai-prompt
  "Send PROMPT to an AI provider via cmacs-ai and return its answer.  \
Optional 'provider' (claude / openai / gemini / grok / ollama / \
claude-code / opencode / claude-tmux / grok-build / antigravity / \
cursor) overrides the default; optional 'system' is a system prompt; \
optional 'model' overrides the provider's default model.  Optional \
'images' sends pictures with the prompt; a provider that cannot take \
them is refused, never sent text alone."
    ((prompt string "User prompt")
     (provider string "Provider name" :optional t)
     (system string "System prompt" :optional t)
     (model string "Model name" :optional t)
     (images array "Images sent with the prompt: each {path} (a file \
in the workspace, as project_read_file reads it) or {data, mime} \
(base64 PNG/JPEG/GIF/WebP bytes)"
             :optional t
             :items (object
                     :properties
                     ((path string "Image file, relative to the workspace root"
                            :optional t)
                      (data string "Base64 image bytes" :optional t)
                      (mime string "MIME type of data, e.g. image/png"
                            :optional t)))))
  :group 'ai :surfaces '(mcp dbus cli) :async t :timeout 600
  :destructive t
  :example "emacsctl tool ai prompt --prompt 'Name three GLib main-loop sources'"
  (let ((provider (cmacs-ai-tools--provider provider))
        (model (cmacs-ai-tools--text model)))
    (cmacs-ai-tools--one-shot
     done
     (cmacs-ai-tools--required prompt "ai_prompt" "prompt")
     provider
     (cmacs-ai-tools--text system)
     model
     nil
     (cmacs-ai-tools--check-images (cmacs-ai-tools--images images)
                                   provider model))))

(cmacs-brigade-deftool ai-call
  "Send PROMPT to an AI provider and return the final answer.  Like \
ai_prompt, but with 'tools':true the model is given the built-in agent \
tools (bash/read/write/edit/glob/grep/ls/web_fetch) and runs a \
multi-turn tool loop on a worker thread.  Optional 'provider' / \
'system' / 'model' / 'images' behave as for ai_prompt."
    ((prompt string "User prompt")
     (provider string "Provider name" :optional t)
     (system string "System prompt" :optional t)
     (model string "Model name" :optional t)
     (tools boolean "Give the model the built-in agent tools" :optional t)
     (images array "Images sent with the prompt: each {path} (a file \
in the workspace, as project_read_file reads it) or {data, mime} \
(base64 PNG/JPEG/GIF/WebP bytes)"
             :optional t
             :items (object
                     :properties
                     ((path string "Image file, relative to the workspace root"
                            :optional t)
                      (data string "Base64 image bytes" :optional t)
                      (mime string "MIME type of data, e.g. image/png"
                            :optional t)))))
  :group 'ai :surfaces '(mcp dbus cli) :async t :timeout 1800
  :destructive t
  :example "emacsctl tool ai call --prompt 'What is in ./README.org?' --tools"
  (let ((provider (cmacs-ai-tools--provider provider))
        (model (cmacs-ai-tools--text model)))
    (cmacs-ai-tools--one-shot
     done
     (cmacs-ai-tools--required prompt "ai_call" "prompt")
     provider
     (cmacs-ai-tools--text system)
     model
     tools
     (cmacs-ai-tools--check-images (cmacs-ai-tools--images images)
                                   provider model))))


;;;; Images

(cmacs-brigade-deftool generate-image
  "Generate an image from a text prompt and insert it into a cmacs \
buffer.  In an Org buffer the image is attached to the current node and \
previewed inline; elsewhere it is saved under cmacs-ai-image-dir.  \
Optional 'references' is a comma-separated list of input images to \
condition on, each PATH or PATH::ROLE (e.g. \
\"logo.png::style,cat.jpg::subject\") -- roles tell the model what each \
reference is for.  Optional 'provider' (gemini / openai / grok), \
'model', 'aspect' (e.g. 16:9), 'size' (e.g. 1024x1024) and 'quality'.  \
Optional 'buffer' names the target buffer; the current one is used \
otherwise.  Generation takes tens of seconds."
    ((prompt string "What to depict")
     (references string "Comma-separated PATH or PATH::ROLE reference images"
                 :optional t)
     (provider string "gemini/openai/grok" :optional t)
     (model string "Model id" :optional t)
     (aspect string "Aspect ratio" :optional t)
     (size string "Pixel size" :optional t)
     (quality string "Quality level" :optional t)
     (buffer string "Target buffer name" :optional t))
  :group 'ai :async t :timeout 300
  :destructive t
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Ai.GenerateImage
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool ai generate-image --prompt 'a brass orrery' --aspect 16:9"
  (require 'cmacs-ai-image)
  (require 'cmacs-ai-image-chat)
  (let* ((prompt (cmacs-ai-tools--required prompt "generate_image" "prompt"))
         ;; A named buffer that does not exist falls back to the current
         ;; one, as it did in C.
         (target (or (and (cmacs-ai-tools--text buffer) (get-buffer buffer))
                     (current-buffer)))
         ;; A marker, not an integer: the answer arrives tens of seconds
         ;; later and the buffer may have been edited by then.
         (position (with-current-buffer target (point-marker)))
         (options
          (append
           (and (cmacs-ai-tools--text aspect) (list :aspect aspect))
           (and (cmacs-ai-tools--text size) (list :custom-size size))
           (and (cmacs-ai-tools--text quality) (list :quality quality))
           (and (cmacs-ai-tools--text references)
                (list :references
                      (cmacs-ai-image-chat--parse-refs references)))))
         (handle (cmacs-ai-image--client (cmacs-ai-tools--provider provider)
                                         (cmacs-ai-tools--text model))))
    (condition-case err
        (cmacs-ai-image-generate-async
         handle prompt
         (lambda (payload)
           (ignore-errors (cmacs-ai-client-free handle))
           (funcall
            done
            (condition-case place-err
                (cond
                 ((plist-get payload :error)
                  (cmacs-ai-tools--failure (plist-get payload :error)))
                 ((not (buffer-live-p target))
                  (cmacs-ai-tools--failure
                   "the target buffer was killed before the image arrived"))
                 (t
                  (format "Inserted %d image(s) into %s"
                          (cmacs-ai-image--place (plist-get payload :images)
                                                 prompt target position)
                          (buffer-name target))))
              (error (cmacs-ai-tools--failure
                      (error-message-string place-err)))))
           (set-marker position nil))
         options)
      (error
       (ignore-errors (cmacs-ai-client-free handle))
       (set-marker position nil)
       (signal (car err) (cdr err))))))


;;;; Providers, embeddings, chat buffers

(cmacs-brigade-deftool ai-list-providers
  "Return the list of supported cmacs-ai provider symbols."
    ()
  :group 'ai :surfaces '(mcp dbus cli)
  :example "emacsctl tool ai list-providers"
  (format "%S" (cmacs-ai-providers)))

;; Embeddings reach a caller as a similarity score, not as vectors: a
;; vector is 768 floats, ~10 kB of JSON per text, which nothing on the
;; other end of a wire can act on, and semantic search over the notes is
;; `memory_search'.
(cmacs-brigade-deftool ai-embed-similarity
  "Cosine similarity of two texts' embeddings, in [-1, 1]: 1 is the \
same direction, 0 unrelated, -1 opposite.  Use it to judge whether two \
passages mean the same thing -- near-duplicate detection, or checking \
an answer against a source.  Needs a local embedding provider \
\(ollama).  Optional 'model' overrides the default embedding model.  To \
SEARCH the notes corpus use memory_search instead; this compares two \
specific strings."
    ((a string "First text")
     (b string "Second text")
     (model string "Embedding model" :optional t))
  :group 'ai :surfaces '(mcp dbus cli) :async t
  :example "emacsctl tool ai embed-similarity --a 'a cat' --b 'a kitten'"
  (unless (and (cmacs-ai-tools--text a) (cmacs-ai-tools--text b))
    (error "ai_embed_similarity: need both 'a' and 'b'"))
  (cmacs-ai-embed-async
   (list a b)
   (lambda (payload)
     (funcall
      done
      (condition-case err
          (pcase payload
            (`(:ok ,vectors)
             (format "%.6f" (cmacs-ai-embed-cosine (nth 0 vectors)
                                                   (nth 1 vectors))))
            (_ (cmacs-ai-tools--failure
                (or (cadr payload) "embedding failed"))))
        (error (cmacs-ai-tools--failure (error-message-string err))))))
   nil (cmacs-ai-tools--text model)))

;; Synchronous, and that is correct: opening the buffer is immediate and
;; the first turn is streamed into it by the chat layer after this
;; returns.  What the tool answers with is the buffer's name.
(cmacs-brigade-deftool ai-open-chat
  "Open a cmacs-ai chat buffer.  If PROMPT is given, the prompt is sent \
as the first user turn and streamed.  Optional 'model' overrides the \
provider's default model.  Returns the buffer name."
    ((prompt string "Optional initial prompt" :optional t)
     (provider string "Provider name" :optional t)
     (model string "Model name" :optional t))
  :group 'ai :surfaces '(mcp dbus cli)
  :destructive t
  :example "emacsctl tool ai open-chat --provider claude"
  (require 'cmacs-ai-chat)
  (let ((buf (cmacs-ai-chat-open (cmacs-ai-tools--provider provider)
                                 (cmacs-ai-tools--text model))))
    (when (cmacs-ai-tools--text prompt)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert prompt)
        (cmacs-ai-chat-send-compose)))
    (buffer-name buf)))


;;;; libresearch
;;
;; The request runs on a worker thread (cmacs-ai-libresearch.c) and its
;; payload is delivered to a callback on the Lisp thread.  The C tools
;; started it and then polled for the answer inside the dispatch -- for
;; ai_research, for minutes.  These hand the callback over and return.

(defun cmacs-ai-tools--research (done kind arg &rest options)
  "Start a libresearch request of KIND for ARG; DONE gets its text.
OPTIONS are those of `cmacs-ai-research-request'."
  (require 'cmacs-ai-research)
  (apply #'cmacs-ai-research-request kind arg
         (lambda (payload)
           (funcall done
                    (pcase (car-safe payload)
                      (:ok (or (plist-get (cdr payload) :text) ""))
                      (:error (cmacs-ai-tools--failure (cadr payload)))
                      (_ (cmacs-ai-tools--failure "cancelled")))))
         options))

(cmacs-brigade-deftool ai-research
  "Research a question on the web with libresearch and return a cited \
answer: the answer with numbered citations [n], then the sources \
\(title, URL).  Needs a libresearch server (cmacs-ai-libresearch-url).  \
'deep' lets the server run follow-up searches; 'pages' (1-20) is how \
many pages it reads.  A run takes minutes."
    ((question string "The question")
     (deep boolean "Run follow-up searches" :optional t)
     (pages integer "Pages to read, 1-20" :optional t))
  ;; A little over `cmacs-ai-libresearch-research-timeout', so the
  ;; request reports its own deadline rather than the registry's.
  :group 'ai :surfaces '(mcp dbus cli) :async t :timeout 960
  :example "emacsctl tool ai research --question 'What changed in wlroots 0.20?'"
  (let ((question (cmacs-ai-tools--required question "ai_research" "question"))
        (pages (or pages 0)))
    (unless (and (integerp pages) (<= 0 pages 20))
      (error "ai_research: 'pages' must be 1-20"))
    (apply #'cmacs-ai-tools--research done 'research question
           (append (and deep (list :deep t))
                   (and (> pages 0) (list :pages pages))))))

(cmacs-brigade-deftool ai-web-fetch
  "Read a web page's text through libresearch (the server applies its \
own SSRF guard).  'archive' is never (default), fallback (use the \
Wayback Machine when the live page fails) or only; 'max_chars' \
\(100-1000000) caps the text.  Returns title, URL, the archived copy if \
one stood in, then the text."
    ((url string "Page URL")
     (archive string "Wayback Machine policy" :optional t
              :enum ("never" "fallback" "only"))
     (max_chars integer "Longest text" :optional t))
  :group 'ai :surfaces '(mcp dbus cli) :async t
  :example "emacsctl tool ai web-fetch --url https://docs.gtk.org/glib/"
  (let ((url (cmacs-ai-tools--required url "ai_web_fetch" "url"))
        (archive (cmacs-ai-tools--text archive))
        (max-chars (or max_chars 0)))
    ;; Checked here rather than left to the primitive, so the caller
    ;; gets the vocabulary back and not a Lisp error.
    (unless (member archive '(nil "never" "fallback" "only"))
      (error "ai_web_fetch: 'archive' must be never, fallback or only"))
    (unless (and (integerp max-chars)
                 (or (= max-chars 0) (<= 100 max-chars 1000000)))
      (error "ai_web_fetch: 'max_chars' must be 100-1000000"))
    (apply #'cmacs-ai-tools--research done 'fetch url
           (append (and archive (list :archive archive))
                   (and (> max-chars 0) (list :max-chars max-chars))))))

(cmacs-brigade-deftool ai-lql
  "Run an LQL query on the libresearch server and return its rows (at \
most 100 shown).  LQL pipes search results: search \"glib\", category: \
CODE | filter extra.stars > 100 | fields title, url -- or the shorthand \
gtk docs | filter site(\"docs.gtk.org\").  'explain' returns the plan \
without running it.  An invalid query reports the server's position and \
caret excerpt."
    ((query string "LQL query")
     (explain boolean "Plan without running" :optional t))
  :group 'ai :surfaces '(mcp dbus cli) :async t
  :example "emacsctl tool ai lql --query 'gtk docs | filter site(\"docs.gtk.org\")'"
  (apply #'cmacs-ai-tools--research done 'lql
         (cmacs-ai-tools--required query "ai_lql" "query")
         :max-rows 100
         (and explain (list :explain t))))

(provide 'cmacs-ai-tools)

;;; cmacs-ai-tools.el ends here
