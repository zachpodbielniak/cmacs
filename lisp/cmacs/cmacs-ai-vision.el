;;; cmacs-ai-vision.el --- Image input for cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Pictures in, for every cmacs-ai path that builds a user message.
;; doc_org/cmacs/cmacs-ai-images.org is the whole story; in short:
;;
;;   AN IMAGE is a plist, (:file PATH) or (:data UNIBYTE-STRING :mime
;;   TYPE).  A list of them goes to `cmacs-ai-call' (:images),
;;   `cmacs-ai-chat-stream' (fifth argument),
;;   `cmacs-ai-session-append-message' (fourth), `cmacs-ai--call'
;;   (seventh) and `cmacs-ai-harness-send-input' (third).  The C reads
;;   and checks it (cmacs/ai/cmacs-ai-vision.c): the bytes decide the
;;   type, a file must be a regular file no larger than
;;   `cmacs-ai-image-max-bytes'.
;;
;;   CAN THIS MODEL SEE IT?  `cmacs-ai-vision-supported-p'.  ai-glib
;;   has no "accepts image input" capability (a future
;;   ai_provider_accepts_images (provider, model) is proposed, not
;;   built), so cmacs decides, in layers.  For an HTTP provider the C
;;   asks ai-glib's own request builder whether an image survives into
;;   the request body -- what the linked library really does, not what
;;   a table remembers.  For a CLI provider there is no body to look at,
;;   so `cmacs-ai-vision-cli-providers' says.  ollama carries images for
;;   any model, and only some models can see: there the model name has
;;   to match `cmacs-ai-vision-ollama-models', a documented guess.  You
;;   override all of it with `cmacs-ai-vision-providers' and, per
;;   model, `cmacs-ai-vision-model-overrides'.  An image is NEVER
;;   dropped silently: `cmacs-ai-vision-check' refuses before sending,
;;   naming the provider and model, the configured providers that can,
;;   and the option that says otherwise.
;;
;;   CAPTURE (`cmacs-ai-capture-region', `-client', `-frame',
;;   `-clipboard') makes PNG bytes in memory.  Every screen capture is
;;   model-facing and goes through the redaction rules first: a region
;;   is refused while a window the rules exclude is visible in it, an
;;   Emacs frame while it shows an excluded buffer.  Nothing is written
;;   to disk unless `cmacs-ai-capture-save-directory' says where.
;;
;;   IN A CHAT, `[[file:shot.png]]' links and `[[attachment:...]]' image
;;   links in the compose area are sent as images, and
;;   `cmacs-ai-chat-attach-image' (C-c C-i) adds a file, a screen region,
;;   a window, this frame or the clipboard image -- the last four as a
;;   `[[cmacs-image:N]]' link to bytes held in the buffer, never a file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar cmacs-ai-default-provider)
(defvar cmacs-ai-default-model)
(defvar cmacs-ai-acp-agents)
(defvar cmacs-ai-openai-compatible-endpoints)
(defvar cmacs-redact--as-model)
(defvar cmacs-redact-capture-refusal)
(defvar cmacs-ai-chat-provider)
(defvar cmacs-ai-chat-session-pair)
(defvar cmacs-ai-chat--compose-marker)

(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-provider-image-input "cmacs-ai-vision.c"
                  (&optional provider))
(declare-function cmacs-ai-image-parts "cmacs-ai-vision.c" (images))
(declare-function cmacs-ai-png-encode "cmacs-ai-vision.c"
                  (width height data &optional max-side))
(declare-function cmacs-ai-client-effective-model "cmacs-ai-client.c"
                  (handle))
(declare-function cmacs-redact-capture-refused-p "cmacs-redact"
                  (what &optional target))
(declare-function cmacs-gowl-tools--region-guard "cmacs-gowl-tools"
                  (x y width height))
(declare-function cmacs-gowl-tools--client-raw "cmacs-gowl-tools" (client))
(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-screenshot-region "cmacs-gowl.c"
                  (x y w h &optional monitor))
(declare-function gowl-screenshot-client "cmacs-gowl.c" (client))
(declare-function gowl-pointer-position "cmacs-gowl-pointer.c" ())
(declare-function gowl-list-clients "cmacs-gowl.c" (&rest args))
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (monitor))
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function cmacs-imgedit-clipboard-get-png "cmacs-imgedit-defuns.c" ())
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function org-attach-expand "org-attach" (file))

;;;; Options

(defgroup cmacs-ai-vision nil
  "Image input for cmacs-ai: sending pictures to a model."
  :group 'cmacs-ai
  :prefix "cmacs-ai-vision-")

(defcustom cmacs-ai-image-max-bytes (* 10 1024 1024)
  "Largest image, in bytes, that cmacs-ai will send.
A file over this is refused from its size, before it is read; the same
limit applies to image bytes handed over directly.  Providers have their
own limits (several are 5 MB or 20 MB per image) and say so in an error;
this one is about not reading something huge on the main thread."
  :type 'integer)

(defcustom cmacs-ai-image-max-count 16
  "Most images one message may carry."
  :type 'integer)

(defcustom cmacs-ai-image-max-side 1568
  "Longest side, in pixels, of a screen capture made for a model.
Captures larger than this are scaled down before they are encoded.  The
default is the size several vision models resize to anyway, so sending
more only costs bytes.  nil sends captures at full size."
  :type '(choice (const :tag "Full size" nil) integer))

(defcustom cmacs-ai-vision-providers nil
  "Per-provider answers to \"can it take images?\", ahead of any probe.
An alist of (PROVIDER . BOOLEAN): PROVIDER a provider symbol, including
a name from `cmacs-ai-openai-compatible-endpoints' or
`cmacs-ai-acp-agents'.  What is not listed is worked out (see
`cmacs-ai-vision-supported-p')."
  :type '(alist :key-type symbol :value-type boolean))

(defcustom cmacs-ai-vision-model-overrides nil
  "Per-model answers, ahead of everything else.
A list of (PROVIDER REGEXP . BOOLEAN).  PROVIDER is a provider symbol or
nil for any; REGEXP is matched against the model name.  For a text-only
model behind a client that would carry the picture -- a local
`llama3.2' through ollama, say -- add (ollama \"\\\\`llama3\\\\.2\" . nil)
and the image is refused here instead of by the server."
  :type '(repeat (cons (choice (const :tag "Any provider" nil) symbol)
                       (cons regexp boolean))))

(defcustom cmacs-ai-vision-cli-providers
  '((claude-code . t) (codex-cli . t) (antigravity . t) (acp . t)
    (opencode . nil) (claude-tmux . nil) (cursor . nil) (grok-build . nil))
  "Which CLI providers ai-glib hands images to.
A CLI client builds no request body that can be inspected, so this table
is the answer for them.  `claude-code' sends images as stream-json
content, `codex-cli' and `antigravity' as image arguments, `acp' as ACP
image blocks (whether the agent then looks is the agent's business).
`opencode', `claude-tmux', `cursor' and `grok-build' take only a text
prompt, in which ai-glib writes \"[Image: ...; binary content is not
representable]\": the model would be told an image existed and never see
it, which is why they are refused instead."
  :type '(alist :key-type symbol :value-type boolean))

(defcustom cmacs-ai-vision-http-fallback
  '((claude . t) (openai . t) (gemini . t) (ollama . t)
    (openai-compatible . t))
  "Answers for HTTP providers when the probe cannot answer.
Used only when the client could not build a request to look at.  A
provider not listed is refused, with `cmacs-ai-vision-providers' named
as the way to say otherwise.  ollama is further limited by model
\(`cmacs-ai-vision-ollama-models')."
  :type '(alist :key-type symbol :value-type boolean))

(defcustom cmacs-ai-vision-ollama-models
  (concat "llava\\|vision\\|bakllava\\|moondream\\|qwen[0-9.]*-?vl"
          "\\|gemma3\\|minicpm-v\\|llama4\\|mistral-small3")
  "Regexp of ollama model names that can see images.  A GUESS.
ollama puts an image on the request for any model, and a text-only
model then answers as though there were none, or the server errors.
ollama can say per model (its /api/show `capabilities' list holds
\"vision\"), but asking means a request per check; this regexp of the
common vision families is used instead.  A model not matching is
refused -- and a model you know better about goes in
`cmacs-ai-vision-model-overrides'.  An ollama call with no model named
\(the server's default) is refused for the same reason: which model
would answer is not known here."
  :type 'regexp)

(defcustom cmacs-ai-vision-cli-programs
  '((claude-code . "claude") (codex-cli . "codex") (opencode . "opencode")
    (antigravity . "antigravity") (cursor . "cursor-agent")
    (claude-tmux . "claude") (grok-build . "grok"))
  "The program a CLI provider runs, to tell whether it is installed.
Used only to choose which providers to SUGGEST when an image is refused:
a provider whose program is not on `exec-path' is not offered."
  :type '(alist :key-type symbol :value-type string))

(defcustom cmacs-ai-capture-save-directory nil
  "Where screen captures made for a model are also saved, or nil.
nil, the default, keeps a capture in memory only: it goes to the model
and nowhere else.  A directory name keeps a copy there too (mode 0600),
named by the time it was taken."
  :type '(choice (const :tag "Nowhere (memory only)" nil) directory))

(defcustom cmacs-ai-capture-box '(900 . 420)
  "Size, in layout pixels, of a region capture around the pointer.
`cmacs-ai-chat-attach-image' offers this box centred on the pointer, kept
inside the monitor, as the default region."
  :type '(cons integer integer))

(define-error 'cmacs-ai-capture-refused
  "a window excluded by your privacy rules is visible; nothing was captured")

(define-error 'cmacs-ai-vision-refused "This model cannot take images")

;;;; Is image input built in?

(defun cmacs-ai-vision-available-p ()
  "Non-nil when this cmacs can put images on a message at all.
False on a build older than image input, whose primitives take text
only; nothing may then be sent with images, and nothing tries."
  (and (fboundp 'cmacs-ai-image-parts)
       (fboundp 'cmacs-ai-provider-image-input)))

;;;; Which providers take images

(defun cmacs-ai-vision--provider (provider)
  "PROVIDER, or the configured default provider when it is nil."
  (or provider (bound-and-true-p cmacs-ai-default-provider) 'claude))

(defun cmacs-ai-vision--kind (provider)
  "The built-in provider PROVIDER stands for.
A name from `cmacs-ai-acp-agents' is `acp'; one from
`cmacs-ai-openai-compatible-endpoints' is `openai-compatible' (the
endpoint table wins a name both list, as the C lookup does)."
  (cond ((assq provider (bound-and-true-p cmacs-ai-openai-compatible-endpoints))
         'openai-compatible)
        ((assq provider (bound-and-true-p cmacs-ai-acp-agents)) 'acp)
        ((eq provider 'http) 'openai-compatible)
        (t provider)))

(defun cmacs-ai-vision--model-override (provider model)
  "The `cmacs-ai-vision-model-overrides' answer for PROVIDER and MODEL.
Returns (BOOLEAN) when an entry matches, nil when none does."
  (when (stringp model)
    (cl-loop for (p regexp . answer) in cmacs-ai-vision-model-overrides
             when (and (or (null p) (eq p provider))
                       (stringp regexp)
                       (string-match-p regexp model))
             return (list answer))))

(defun cmacs-ai-vision--probe (provider)
  "The C probe's plist for PROVIDER, or nil when it cannot be asked."
  (when (fboundp 'cmacs-ai-provider-image-input)
    (ignore-errors (cmacs-ai-provider-image-input provider))))

(defun cmacs-ai-vision-supported-p (provider &optional model)
  "Non-nil when PROVIDER, with MODEL, can be sent images.
PROVIDER is a provider symbol or nil for `cmacs-ai-default-provider';
MODEL a model name or nil.  In order: `cmacs-ai-vision-model-overrides',
`cmacs-ai-vision-providers', then for an HTTP provider whether ai-glib's
request builder keeps an image (asked of the C, once per client class),
and for a CLI provider `cmacs-ai-vision-cli-providers'.  Always nil on a
build without image input (`cmacs-ai-vision-available-p')."
  (let* ((provider (cmacs-ai-vision--provider provider))
         (kind (cmacs-ai-vision--kind provider)))
    (and (cmacs-ai-vision-available-p)
         (let ((by-model (cmacs-ai-vision--model-override provider model))
               (by-name (assq provider cmacs-ai-vision-providers)))
           (cond
            (by-model (car by-model))
            (by-name (cdr by-name))
            ;; The client carries an image for any ollama model; only
            ;; some models can see it.
            ((eq kind 'ollama)
             (and (stringp model)
                  (string-match-p cmacs-ai-vision-ollama-models model)
                  t))
            (t
             (let ((images (plist-get (cmacs-ai-vision--probe provider)
                                      :images)))
               (pcase images
                 ('t t)
                 ('cli (cdr (assq kind cmacs-ai-vision-cli-providers)))
                 ((guard (assq kind cmacs-ai-vision-cli-providers))
                  (cdr (assq kind cmacs-ai-vision-cli-providers)))
                 ('nil
                  ;; The probe answered no -- or there was no probe,
                  ;; which `cmacs-ai-vision-available-p' rules out.
                  nil)
                 (_ (cdr (assq kind cmacs-ai-vision-http-fallback)))))))))))

(defun cmacs-ai-vision--configured-p (provider)
  "Non-nil when PROVIDER looks usable here: credentials or a program."
  (let ((kind (cmacs-ai-vision--kind provider)))
    (cond
     ((eq kind 'acp)
      (let* ((agent (cdr (assq provider (bound-and-true-p cmacs-ai-acp-agents))))
             (command (or (plist-get agent :command) (getenv "AI_ACP_COMMAND"))))
        (and (stringp command)
             (let ((words (ignore-errors (split-string-and-unquote command))))
               (and words (executable-find (car words)))))))
     ((assq kind cmacs-ai-vision-cli-programs)
      (executable-find (cdr (assq kind cmacs-ai-vision-cli-programs))))
     (t (plist-get (cmacs-ai-vision--probe provider) :configured)))))

(defun cmacs-ai-vision-suggest (&optional except)
  "Configured providers that can take images, EXCEPT that one.
\"Configured\" is a guess, made without contacting anything: an HTTP
provider ai-glib has credentials for (or needs none), a CLI provider
whose program is installed."
  (when (and (cmacs-ai-vision-available-p) (fboundp 'cmacs-ai-providers))
    (cl-loop for p in (ignore-errors (cmacs-ai-providers))
             unless (eq p except)
             when (and (cmacs-ai-vision-supported-p p)
                       (cmacs-ai-vision--configured-p p))
             collect p)))

(defun cmacs-ai-vision-refusal (provider &optional model)
  "The sentence refusing images to PROVIDER and MODEL, or nil if they can.
PROVIDER nil is `cmacs-ai-default-provider'."
  (let ((provider (cmacs-ai-vision--provider provider)))
    (cond
     ((not (cmacs-ai-vision-available-p))
      "This cmacs was built without image input, so the image was not \
sent.")
     ((cmacs-ai-vision-supported-p provider model) nil)
     (t
      (let ((others (cmacs-ai-vision-suggest provider)))
        (format "%s%s cannot take images, so nothing was sent.  %s"
                provider
                (if (and (stringp model) (not (string-empty-p model)))
                    (concat "/" model) "")
                (concat
                 (if others
                     (format "Providers here that can: %s."
                             (mapconcat #'symbol-name others ", "))
                   "No provider configured here takes images.")
                 "  If this one can, say so in "
                 (if (eq (cmacs-ai-vision--kind provider) 'ollama)
                     "`cmacs-ai-vision-model-overrides'."
                   "`cmacs-ai-vision-providers'."))))))))

(defun cmacs-ai-vision-check (provider model images)
  "Signal unless IMAGES can be sent to PROVIDER with MODEL.
Nothing to check when IMAGES is nil.  Otherwise the images are read and
checked (`cmacs-ai-image-parts': size, type) and the provider is asked;
a refusal is a `cmacs-ai-vision-refused' error carrying
`cmacs-ai-vision-refusal''s sentence -- never a silently dropped image.
Returns IMAGES."
  (when images
    (when-let* ((why (cmacs-ai-vision-refusal provider model)))
      (signal 'cmacs-ai-vision-refused (list why)))
    (cmacs-ai-image-parts images))
  images)

;;;; Captures, in memory

(defun cmacs-ai-capture--finish (png what)
  "Return the image plist for PNG bytes, saving a copy if asked.
WHAT names the capture in a saved file's name."
  (let ((image (list :data png :mime "image/png")))
    (when cmacs-ai-capture-save-directory
      (let* ((dir (file-name-as-directory
                   (expand-file-name cmacs-ai-capture-save-directory)))
             (file (expand-file-name
                    (format "%s-%s.png" what
                            (format-time-string "%Y%m%dT%H%M%S%3N"))
                    dir)))
        (make-directory dir t)
        (with-file-modes #o600
          (let ((coding-system-for-write 'binary))
            (write-region png nil file nil 'silent)))
        (setq image (append image (list :saved file)))))
    image))

(defun cmacs-ai-capture--encode (shot)
  "PNG bytes for SHOT, a (WIDTH HEIGHT DATA) gowl capture."
  (unless (fboundp 'cmacs-ai-png-encode)
    (error "This cmacs cannot encode a PNG in memory (needs image input)"))
  (pcase-let ((`(,w ,h ,data) shot))
    (cmacs-ai-png-encode w h data cmacs-ai-image-max-side)))

(defun cmacs-ai-capture--overlaps-p (geometry x y w h)
  "Non-nil when GEOMETRY (X Y W H list) overlaps the rectangle X Y W H."
  (pcase-let ((`(,cx ,cy ,cw ,ch) geometry))
    (and (numberp cx) (numberp cy) (numberp cw) (numberp ch)
         (< cx (+ x w)) (< x (+ cx cw))
         (< cy (+ y h)) (< y (+ cy ch)))))

(defun cmacs-ai-capture-region-refused-p (x y width height)
  "Non-nil when a capture of the screen region X Y WIDTH HEIGHT is refused.
Asked as a model would ask it (the redaction functions act).  Refused
when the redaction rules are not usable, when a window they exclude is
focused or overlaps the region on a shown tag (the gowl tools' region
guard, what `gowl_screen_text' asks), and when the region overlaps one
of this Emacs's own frames while any frame shows an excluded buffer --
a frame is one window to the compositor, so the buffer rules have to be
asked separately.  Anything that goes wrong while deciding is a refusal."
  (require 'cmacs-redact)
  (let ((cmacs-redact--as-model t))
    (condition-case nil
        (progn
          (require 'cmacs-gowl-tools)
          (cmacs-gowl-tools--region-guard x y width height)
          (and (cl-some
                (lambda (client)
                  (let ((raw (cmacs-gowl-tools--client-raw client)))
                    (and (eql (plist-get raw :pid) (emacs-pid))
                         (cmacs-ai-capture--overlaps-p
                          (plist-get raw :geometry) x y width height))))
                (gowl-list-clients))
               (cmacs-redact-capture-refused-p 'frame)
               t))
      (error t))))

(defun cmacs-ai-capture-region (x y width height)
  "Capture the screen region X Y WIDTH HEIGHT for a model; return an image.
Layout pixels, as gowl gives window geometry.  The result is an image
plist (:data PNG :mime \"image/png\"), the picture scaled to
`cmacs-ai-image-max-side', held in memory (and saved only to
`cmacs-ai-capture-save-directory').  Signals `cmacs-ai-capture-refused'
while a window the redaction rules exclude is visible in the region
\(`cmacs-ai-capture-region-refused-p'): nothing is captured then."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "No compositor is running here, so there is no screen to \
capture"))
  (unless (and (natnump x) (natnump y) (integerp width) (integerp height)
               (> width 0) (> height 0))
    (error "A region is X, Y >= 0 and WIDTH, HEIGHT > 0"))
  (when (cmacs-ai-capture-region-refused-p x y width height)
    (signal 'cmacs-ai-capture-refused nil))
  (cmacs-ai-capture--finish
   (cmacs-ai-capture--encode
    (or (gowl-screenshot-region x y width height)
        (error "Nothing was captured at %d,%d %dx%d" x y width height)))
   "region"))

(defun cmacs-ai-capture-client (client)
  "Capture the window CLIENT (a gowl client) for a model; return an image.
Only that window's own pixels, not what overlaps it.  Refused
\(`cmacs-ai-capture-refused') when the rules exclude the window."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "No compositor is running here"))
  (require 'cmacs-redact)
  (when (let ((cmacs-redact--as-model t))
          (condition-case nil
              (cmacs-redact-capture-refused-p 'client client)
            (error t)))
    (signal 'cmacs-ai-capture-refused nil))
  (cmacs-ai-capture--finish
   (cmacs-ai-capture--encode
    (or (gowl-screenshot-client client)
        (error "That window could not be captured")))
   "window"))

(defun cmacs-ai-capture-frame (&optional frame)
  "Capture the Emacs FRAME (default: the selected one) for a model.
Refused (`cmacs-ai-capture-refused') while any visible frame shows a
buffer the rules exclude.  Needs a Cairo build (`x-export-frames')."
  (require 'cmacs-redact)
  (when (let ((cmacs-redact--as-model t))
          (condition-case nil
              (cmacs-redact-capture-refused-p 'frame frame)
            (error t)))
    (signal 'cmacs-ai-capture-refused nil))
  (unless (fboundp 'x-export-frames)
    (user-error "This Emacs cannot export a frame as an image"))
  (cmacs-ai-capture--finish
   (string-to-unibyte (x-export-frames (or frame (selected-frame)) 'png))
   "frame"))

(defun cmacs-ai-capture-clipboard ()
  "The image on the clipboard, as an image plist, or nil when there is none.
The clipboard is yours, so no rule is asked: you put it there.  Read
through Emacs's own GTK clipboard when cmacs-imgedit provides it, else
as the `image/png' selection target."
  (let ((png (or (and (fboundp 'cmacs-imgedit-clipboard-get-png)
                      (ignore-errors (cmacs-imgedit-clipboard-get-png)))
                 (let ((data (ignore-errors
                               (gui-get-selection 'CLIPBOARD 'image/png))))
                   (and (stringp data) (> (length data) 0)
                        (string-to-unibyte data))))))
    (and (stringp png) (> (length png) 8)
         (list :data png :mime "image/png"))))

(defun cmacs-ai-capture-pointer-box ()
  "The region (X Y W H) of `cmacs-ai-capture-box' around the pointer.
Kept inside the monitor under the pointer; nil without a compositor."
  (when-let* (((and (fboundp 'gowl-pointer-position) (gowl-running-p)))
              (at (gowl-pointer-position)))
    (let* ((px (round (car at))) (py (round (cdr at)))
           (mon (cl-find-if
                 (lambda (m)
                   (cmacs-ai-capture--overlaps-p
                    (alist-get 'geometry (gowl-monitor-info m)) px py 1 1))
                 (ignore-errors (gowl-list-monitors))))
           (g (or (and mon (alist-get 'geometry (gowl-monitor-info mon)))
                  (list 0 0 (* 2 (car cmacs-ai-capture-box))
                        (* 2 (cdr cmacs-ai-capture-box)))))
           (gx (round (nth 0 g))) (gy (round (nth 1 g)))
           (gw (round (nth 2 g))) (gh (round (nth 3 g)))
           (w (min gw (max 1 (car cmacs-ai-capture-box))))
           (h (min gh (max 1 (cdr cmacs-ai-capture-box)))))
      (list (max gx (min (- (+ gx gw) w) (- px (/ w 2))))
            (max gy (min (- (+ gy gh) h) (- py (/ h 2))))
            w h))))

;;;; Image links in a chat's compose area

(defconst cmacs-ai-vision-image-file-regexp
  "\\.\\(?:png\\|jpe?g\\|gif\\|webp\\)\\'"
  "File names that are sent as images when a chat links them.")

(defvar-local cmacs-ai-vision--held nil
  "Images this buffer holds in memory: alist of (ID . IMAGE-PLIST).
Captures attached with `cmacs-ai-chat-attach-image' live here, linked
from the compose area as [[cmacs-image:ID]], so no capture is ever a
file.  They are dropped with the buffer.")

(defvar-local cmacs-ai-vision--next-id 0
  "The next id for `cmacs-ai-vision--held'.")

(defconst cmacs-ai-vision--link-regexp
  "\\[\\[\\([^]]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]"
  "An Org bracket link; group 1 is its target.")

(defun cmacs-ai-vision--link-image (target directory)
  "The image a compose-area link TARGET stands for, or nil.
DIRECTORY resolves a relative file name."
  (cond
   ((string-match "\\`cmacs-image:\\([0-9]+\\)\\'" target)
    (or (cdr (assq (string-to-number (match-string 1 target))
                   cmacs-ai-vision--held))
        (user-error "The attached image %s is no longer held; attach it \
again" target)))
   ((string-match "\\`attachment:\\(.+\\)\\'" target)
    (let ((name (match-string 1 target)))
      (when (string-match-p cmacs-ai-vision-image-file-regexp name)
        (let ((file (and (require 'org-attach nil t)
                         (ignore-errors (org-attach-expand name)))))
          (unless (and file (file-readable-p file))
            (user-error "No attachment %s here" name))
          (list :file file)))))
   (t
    (let ((file (cond ((string-match "\\`file:\\(.+\\)\\'" target)
                       (match-string 1 target))
                      ((string-match-p "\\`[./~]" target) target))))
      (when file
        ;; A search option (file:x.png::3) is not part of the name.
        (setq file (replace-regexp-in-string "::.*\\'" "" file))
        (when (string-match-p cmacs-ai-vision-image-file-regexp file)
          (when (file-remote-p file)
            (user-error "A remote image is not read for a model: %s" file))
          (list :file (expand-file-name file directory))))))))

(defun cmacs-ai-vision-compose-images (text &optional directory)
  "The images TEXT's Org links send, in the order they appear.
`[[file:x.png]]', `[[./x.png]]', `[[attachment:x.png]]' and the
`[[cmacs-image:N]]' links `cmacs-ai-chat-attach-image' inserts.  A link
to anything that is not a PNG, JPEG, GIF or WebP name is left as text.
DIRECTORY (default `default-directory') resolves relative names."
  (let ((directory (or directory default-directory))
        (start 0) (out nil))
    (while (string-match cmacs-ai-vision--link-regexp text start)
      (setq start (match-end 0))
      (when-let* ((image (cmacs-ai-vision--link-image
                          (match-string 1 text) directory)))
        (push image out)))
    (nreverse out)))

(defun cmacs-ai-vision-hold (image)
  "Keep IMAGE in this buffer; return the link text that names it."
  (let ((id (cl-incf cmacs-ai-vision--next-id)))
    (push (cons id image) cmacs-ai-vision--held)
    (format "cmacs-image:%d" id)))

(defun cmacs-ai-vision--follow-held (path _prefix)
  "Show the held image PATH names, in a buffer of its own."
  (let ((image (cdr (assq (string-to-number path) cmacs-ai-vision--held))))
    (unless image (user-error "That image is no longer held"))
    (with-current-buffer (get-buffer-create "*cmacs-ai image*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image (create-image (plist-get image :data) nil t)))
      (pop-to-buffer (current-buffer)))))

(with-eval-after-load 'ol
  (org-link-set-parameters "cmacs-image"
                           :follow #'cmacs-ai-vision--follow-held
                           :export (lambda (_path desc _backend &rest _)
                                     (or desc "[image]"))))

;;;; Attaching an image to a chat

(defun cmacs-ai-vision--read-image (kind)
  "Return (IMAGE . DESCRIPTION) for KIND, asking what is needed.
IMAGE is a plist; for a file it is (:file NAME) and DESCRIPTION nil."
  (pcase kind
    ('file
     (let ((file (read-file-name "Image file: " nil nil t nil
                                 (lambda (f)
                                   (or (file-directory-p f)
                                       (string-match-p
                                        cmacs-ai-vision-image-file-regexp f))))))
       (cons (list :file (expand-file-name file)) nil)))
    ('region
     (let* ((box (cmacs-ai-capture-pointer-box))
            (default (and box (mapconcat #'number-to-string box " ")))
            (answer (read-string
                     (format "Region X Y W H%s: "
                             (if default (format " (default %s)" default) ""))
                     nil nil default))
            (numbers (mapcar #'string-to-number (split-string answer))))
       (unless (= (length numbers) 4)
         (user-error "A region is four numbers: X Y WIDTH HEIGHT"))
       (cons (apply #'cmacs-ai-capture-region numbers)
             (format "screen region %s" (string-join (split-string answer)
                                                    "x")))))
    ('window
     (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
       (user-error "No compositor is running here"))
     (let* ((clients (gowl-list-clients))
            (names (mapcar (lambda (c)
                             (let ((info (gowl-client-info c)))
                               (cons (format "%s  [%s] #%s"
                                             (alist-get 'title info)
                                             (alist-get 'app-id info)
                                             (alist-get 'id info))
                                     c)))
                           clients))
            (focused (gowl-focused-client))
            (choice (completing-read
                     "Window: " names nil t nil nil
                     (car (rassq focused names)))))
       (cons (cmacs-ai-capture-client (cdr (assoc choice names)))
             "a window")))
    ('frame (cons (cmacs-ai-capture-frame) "this Emacs frame"))
    ('clipboard
     (cons (or (cmacs-ai-capture-clipboard)
               (user-error "There is no image on the clipboard"))
           "clipboard image"))))

;;;###autoload
(defun cmacs-ai-chat-attach-image (kind)
  "Attach an image to this chat's next message.
KIND is asked for: a file, a region of the screen (default: the box of
`cmacs-ai-capture-box' around the pointer), a window, this Emacs frame,
or the clipboard image.  A file becomes a [[file:...]] link; anything
captured becomes a [[cmacs-image:N]] link to bytes this buffer holds in
memory, so a screenshot is never written to disk (unless
`cmacs-ai-capture-save-directory' says otherwise).  The images linked in
the compose area go with the message when it is sent.

Refused before anything is captured when the chat's model cannot take
images, and a screen capture is refused while a window your privacy
rules exclude is visible in it."
  (interactive
   (list (pcase (car (read-multiple-choice
                      "Attach "
                      '((?f "file" "an image file")
                        (?r "region" "a region of the screen")
                        (?w "window" "one window")
                        (?e "emacs frame" "this Emacs frame")
                        (?c "clipboard" "the image on the clipboard"))))
           (?f 'file) (?r 'region) (?w 'window) (?e 'frame)
           (?c 'clipboard))))
  (let ((marker (bound-and-true-p cmacs-ai-chat--compose-marker)))
    (unless marker
      (user-error "Not in a chat compose buffer"))
    ;; Before a capture is taken: there is no point holding a picture
    ;; the model will refuse.
    (let* ((client (car-safe (bound-and-true-p cmacs-ai-chat-session-pair)))
           (model (and client (fboundp 'cmacs-ai-client-effective-model)
                       (ignore-errors
                         (cmacs-ai-client-effective-model client)))))
      (when-let* ((why (cmacs-ai-vision-refusal
                        (bound-and-true-p cmacs-ai-chat-provider) model)))
        (user-error "%s" why)))
    (pcase-let* ((`(,image . ,description) (cmacs-ai-vision--read-image kind))
                 (link (if (plist-get image :file)
                           (format "[[file:%s]]"
                                   (abbreviate-file-name
                                    (plist-get image :file)))
                         (format "[[%s][%s]]"
                                 (cmacs-ai-vision-hold image)
                                 description))))
      ;; Checked now, so an oversize or non-image file is reported at
      ;; attach time rather than at send.
      (when (fboundp 'cmacs-ai-image-parts)
        (cmacs-ai-image-parts (list image)))
      (goto-char (point-max))
      (unless (or (bolp) (= (point) marker)) (insert "\n"))
      (insert link "\n")
      (message "cmacs-ai: attached %s" (or description
                                           (plist-get image :file))))))

(provide 'cmacs-ai-vision)

;;; cmacs-ai-vision.el ends here
