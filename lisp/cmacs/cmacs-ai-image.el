;;; cmacs-ai-image.el --- AI image generation into buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Generate images with `cmacs-ai-image' and put them where you are
;; working.  In an Org buffer the bytes are attached to the current node
;; with `org-attach', an [[attachment:...]] link is inserted, and the
;; image is previewed inline -- so the file travels with the node, is
;; found by Org export, and survives the buffer being moved.
;;
;; Outside Org, or wherever attaching is not possible, the image lands in
;; `cmacs-ai-image-dir' and a plain file link is inserted instead.
;;
;; The C layer (cmacs/ai/cmacs-ai-image.c) hands back raw bytes whichever
;; form the provider used, so nothing here has to know that Gemini
;; answers inline while DALL-E returns a URL.

;;; Code:

(require 'cmacs-ai)
(require 'org)
(require 'org-attach)
(require 'seq)

;; Only ever called after a `derived-mode-p' check, so Dired need not be
;; loaded for this file to compile.
(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))

(defgroup cmacs-ai-image nil
  "AI image generation."
  :group 'cmacs-ai
  :prefix "cmacs-ai-image-")

;;;; Options ----------------------------------------------------------

(defcustom cmacs-ai-image-provider 'gemini
  "Provider used for image generation.
Only `openai', `gemini' and `grok' implement image generation; the
other providers have no image API at all."
  :type '(choice (const gemini) (const openai) (const grok) symbol)
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-model nil
  "Model used for image generation, or nil for the provider default.
See `cmacs-ai-image-list-models' for what each one supports."
  :type '(choice (const :tag "Provider default" nil) string)
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-aspect nil
  "Default aspect ratio, e.g. \"16:9\", or nil to leave it to the model.
Honoured by the Gemini family; OpenAI models use pixel sizes instead
and ignore this."
  :type '(choice (const :tag "Model default" nil) string)
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-size nil
  "Default pixel size, e.g. \"1024x1024\", or nil for the model default.
Honoured by the OpenAI family; Gemini models use aspect ratios."
  :type '(choice (const :tag "Model default" nil) string)
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-resolution nil
  "Default resolution tier: nil, \"1k\", \"2k\" or \"4k\".
Only Nano Banana Pro and Imagen honour tiers above 1K."
  :type '(choice (const :tag "Model default" nil)
                 (const "1k") (const "2k") (const "4k"))
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-count 1
  "How many images to request per generation."
  :type 'integer
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-quality nil
  "Default quality, or nil for the model default.
The value is translated to whichever vocabulary the chosen model
accepts, so \"hd\" reaches a GPT Image model as \"high\"."
  :type '(choice (const :tag "Model default" nil)
                 (const "low") (const "medium") (const "high")
                 (const "standard") (const "hd"))
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-background nil
  "Default background: nil, \"transparent\" or \"opaque\".
Transparency needs an output format with an alpha channel."
  :type '(choice (const :tag "Model default" nil)
                 (const "transparent") (const "opaque"))
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-format nil
  "Default output encoding: nil, \"png\", \"jpeg\" or \"webp\"."
  :type '(choice (const :tag "Model default" nil)
                 (const "png") (const "jpeg") (const "webp"))
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-negative nil
  "Default negative prompt, or nil.
Only some models expose this; elsewhere it is dropped."
  :type '(choice (const nil) string)
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-dir
  (expand-file-name "cmacs-ai/images/"
                    (or (getenv "XDG_DATA_HOME")
                        (expand-file-name "~/.local/share")))
  "Where images go when they cannot be attached to an Org node.
Used for non-Org buffers, and as the fallback when attaching fails."
  :type 'directory
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-attach-method 'mv
  "How `org-attach' takes ownership of a generated image.
Generated images start life in a temporary file, so moving is both
correct and cheaper than copying."
  :type '(choice (const :tag "Move" mv) (const :tag "Copy" cp))
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-file-name-format "cmacs-ai-%Y%m%d-%H%M%S"
  "`format-time-string' pattern for generated file names.
The extension is appended from the image's MIME type, and a numeric
suffix is added when a single generation returns several images."
  :type 'string
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-insert-caption t
  "Whether to insert a #+CAPTION line above the image link.
The caption records the prompt, which is what makes
`cmacs-ai-image-regenerate' possible."
  :type 'boolean
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-preview t
  "Whether to preview the image inline after inserting it."
  :type 'boolean
  :group 'cmacs-ai-image)

(defcustom cmacs-ai-image-timeout 180
  "Seconds to allow a synchronous generation before giving up.
Only applies to the org-babel path; interactive commands are async."
  :type 'integer
  :group 'cmacs-ai-image)

;;;; Provider plumbing ------------------------------------------------

(defun cmacs-ai-image--available-p ()
  "Return non-nil when the C image layer is compiled in."
  (fboundp 'cmacs-ai-image-generate-async))

(defun cmacs-ai-image--ensure ()
  (unless (cmacs-ai-image--available-p)
    (user-error "cmacs was built without ai-glib image support")))

(defun cmacs-ai-image--client (&optional provider model)
  "Return a fresh client handle for PROVIDER, model MODEL.
The caller owns it and must `cmacs-ai-client-free' it."
  (cmacs-ai-image--ensure)
  (let ((p (or provider cmacs-ai-image-provider))
        (m (or model cmacs-ai-image-model)))
    (condition-case err
        (cmacs-ai-client-new p m)
      (error
       (user-error "Cannot create a %s client: %s" p
                   (error-message-string err))))))

(defun cmacs-ai-image--options (&optional overrides)
  "Build the option plist from the defcustoms, then OVERRIDES.
Keys whose value is nil are omitted entirely, which is what leaves
the provider on its own default rather than on ours."
  (let ((base (list :model      cmacs-ai-image-model
                    :aspect     cmacs-ai-image-aspect
                    :custom-size cmacs-ai-image-size
                    :resolution cmacs-ai-image-resolution
                    :count      cmacs-ai-image-count
                    :quality    cmacs-ai-image-quality
                    :background cmacs-ai-image-background
                    :format     cmacs-ai-image-format
                    :negative   cmacs-ai-image-negative))
        (out '()))
    ;; OVERRIDES wins, including for keys absent from BASE.
    (while overrides
      (setq base (plist-put base (car overrides) (cadr overrides)))
      (setq overrides (cddr overrides)))
    (while base
      (when (cadr base)
        (setq out (append out (list (car base) (cadr base)))))
      (setq base (cddr base)))
    out))

;;;; Files -------------------------------------------------------------

(defconst cmacs-ai-image--mime-extensions
  '(("image/png"  . ".png")
    ("image/jpeg" . ".jpg")
    ("image/webp" . ".webp")
    ("image/gif"  . ".gif"))
  "MIME type to file extension.")

(defun cmacs-ai-image--extension (mime)
  "Return the file extension to save MIME under."
  (or (cdr (assoc mime cmacs-ai-image--mime-extensions)) ".png"))

(defun cmacs-ai-image--basename (mime index total)
  "Return a file name for image INDEX of TOTAL with type MIME."
  (concat (format-time-string cmacs-ai-image-file-name-format)
          (if (> total 1) (format "-%d" (1+ index)) "")
          (cmacs-ai-image--extension mime)))

(defun cmacs-ai-image--write-temp (bytes mime index total)
  "Write BYTES to a temporary file named for MIME and return its path."
  (let* ((name (cmacs-ai-image--basename mime index total))
         (dir  (file-name-as-directory (make-temp-file "cmacs-ai-image-" t)))
         (path (expand-file-name name dir)))
    ;; A directory of its own, so the basename survives into org-attach
    ;; -- `make-temp-file' alone would give the attachment a name like
    ;; cmacs-ai-image-Ab12Cd.
    (let ((coding-system-for-write 'binary))
      (write-region bytes nil path nil 'silent))
    path))

(defun cmacs-ai-image--fallback-store (path)
  "Move PATH into `cmacs-ai-image-dir' and return the new path."
  (make-directory cmacs-ai-image-dir t)
  (let ((dest (expand-file-name (file-name-nondirectory path)
                                cmacs-ai-image-dir)))
    (rename-file path dest t)
    dest))

;;;; Insertion ---------------------------------------------------------

(defun cmacs-ai-image--attachable-p ()
  "Return non-nil when the current position can take an Org attachment.
Attaching needs an Org buffer, a writable one, and a node to hang the
attachment directory off."
  (and (derived-mode-p 'org-mode)
       (not buffer-read-only)
       (or (org-before-first-heading-p) (org-at-heading-p) t)))

(defun cmacs-ai-image--attach (path)
  "Attach PATH to the current Org node and return an attachment link.
Returns nil if attaching is not possible, leaving PATH untouched."
  (when (cmacs-ai-image--attachable-p)
    (condition-case err
        (save-excursion
          ;; org-attach needs an entry; before the first heading there is
          ;; nothing to attach to.
          (when (org-before-first-heading-p)
            (signal 'error '("no Org node at point")))
          (org-back-to-heading t)
          (let ((org-attach-method cmacs-ai-image-attach-method))
            (org-attach-attach path nil cmacs-ai-image-attach-method))
          (format "[[attachment:%s]]" (file-name-nondirectory path)))
      (error
       (message "cmacs-ai-image: attaching failed (%s); using %s"
                (error-message-string err) cmacs-ai-image-dir)
       nil))))

(defun cmacs-ai-image--link-for (path)
  "Store PATH somewhere durable and return the reference to insert.
Prefers an Org attachment; falls back to `cmacs-ai-image-dir'.

Outside Org the result is a bare path rather than a bracket link,
since Org syntax in a plain buffer is just noise."
  (or (cmacs-ai-image--attach path)
      (let ((dest (cmacs-ai-image--fallback-store path)))
        (if (derived-mode-p 'org-mode)
            (format "[[file:%s]]" (file-relative-name dest default-directory))
          dest))))

(defun cmacs-ai-image--preview-region (beg end)
  "Preview image links between BEG and END.
Uses the same Org preview path as the chat buffer, with remote
fetching skipped -- everything here is local by the time it is
inserted."
  (when (and cmacs-ai-image-preview
             (derived-mode-p 'org-mode)
             (display-images-p)
             (fboundp 'org-link-preview-region))
    (let ((org-display-remote-inline-images 'skip))
      (ignore-errors (org-link-preview-region nil nil beg end)))))

(defun cmacs-ai-image--insert (link caption)
  "Insert LINK at point, with CAPTION above it when configured."
  (let ((beg (point)))
    (unless (bolp) (insert "\n"))
    (when (and cmacs-ai-image-insert-caption caption
               (derived-mode-p 'org-mode))
      (insert (format "#+CAPTION: %s\n"
                      (replace-regexp-in-string "\n+" " " caption))))
    (insert link "\n")
    (cmacs-ai-image--preview-region beg (point))))

(defun cmacs-ai-image--place (images prompt buffer position)
  "Store IMAGES and insert links for them in BUFFER at POSITION.
IMAGES is the list from the C layer.  Entries without `:data' are
skipped: those are images whose bytes could not be retrieved."
  (let ((total (length images))
        (index 0)
        (placed 0))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (min position (point-max)))
          (dolist (img images)
            (let ((bytes (plist-get img :data))
                  (mime  (or (plist-get img :mime) "image/png")))
              (when bytes
                (let* ((tmp  (cmacs-ai-image--write-temp bytes mime index total))
                       (link (cmacs-ai-image--link-for tmp)))
                  (cmacs-ai-image--insert
                   link (or (plist-get img :revised) prompt))
                  (setq placed (1+ placed)))))
            (setq index (1+ index))))))
    placed))

;;;; Generation --------------------------------------------------------

(defun cmacs-ai-image--run (prompt options buffer position on-done)
  "Generate PROMPT with OPTIONS, then call ON-DONE with the images.
The client is freed whichever way the request ends."
  (cmacs-ai-image--ensure)
  (let* ((handle (cmacs-ai-image--client (plist-get options :provider)
                                         (plist-get options :model)))
         (opts   (cmacs-ai-image--options
                  (org-plist-delete (copy-sequence options) :provider))))
    (message "cmacs-ai-image: generating...")
    (condition-case err
        (cmacs-ai-image-generate-async
         handle prompt
         (lambda (payload)
           (unwind-protect
               (cond
                ((plist-get payload :error)
                 (message "cmacs-ai-image: %s" (plist-get payload :error)))
                (t
                 (let ((images (plist-get payload :images)))
                   (if (null images)
                       (message "cmacs-ai-image: no images returned")
                     (funcall on-done images buffer position)))))
             (ignore-errors (cmacs-ai-client-free handle))))
         opts)
      (error
       (ignore-errors (cmacs-ai-client-free handle))
       (signal (car err) (cdr err))))))

(defun cmacs-ai-image--default-done (prompt)
  "Return a completion handler that places images for PROMPT."
  (lambda (images buffer position)
    (let ((n (cmacs-ai-image--place images prompt buffer position)))
      (message "cmacs-ai-image: inserted %d image%s"
               n (if (= n 1) "" "s")))))

;;;; Reading arguments -------------------------------------------------

(defun cmacs-ai-image--read-prompt (&optional initial)
  "Read a prompt, defaulting to the region when one is active."
  (or (and (use-region-p)
           (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Image prompt: " initial)))

(defun cmacs-ai-image--capabilities (provider model)
  "Return the capability symbols for PROVIDER's MODEL, or nil."
  (let ((handle (ignore-errors (cmacs-ai-image--client provider model))))
    (when handle
      (unwind-protect
          (let* ((models (ignore-errors (cmacs-ai-image-models handle)))
                 (want   (or model
                             (plist-get (car models) :id)))
                 (hit    (seq-find (lambda (m)
                                     (equal (plist-get m :id) want))
                                   models)))
            (plist-get hit :capabilities))
        (ignore-errors (cmacs-ai-client-free handle))))))

(defun cmacs-ai-image--read-options ()
  "Prompt for provider, model and the options that model supports.
Only options the chosen model honours are offered, so a prefix-arg
generation cannot ask for something that will be silently dropped."
  (let* ((provider (intern (completing-read
                            "Provider: " '("gemini" "openai" "grok")
                            nil t nil nil
                            (symbol-name cmacs-ai-image-provider))))
         (handle   (cmacs-ai-image--client provider nil))
         (models   (unwind-protect
                       (ignore-errors (cmacs-ai-image-models handle))
                     (ignore-errors (cmacs-ai-client-free handle))))
         (ids      (mapcar (lambda (m) (plist-get m :id)) models))
         (model    (and ids (completing-read "Model: " ids nil t)))
         (info     (seq-find (lambda (m) (equal (plist-get m :id) model))
                             models))
         (caps     (plist-get info :capabilities))
         (opts     (list :provider provider :model model)))
    (when (memq 'aspect-ratio caps)
      (let ((ratios (plist-get info :aspect-ratios)))
        (setq opts (plist-put opts :aspect
                              (completing-read "Aspect ratio: " ratios
                                               nil nil
                                               cmacs-ai-image-aspect)))))
    (when (memq 'pixel-size caps)
      (let ((sizes (plist-get info :sizes)))
        (setq opts (plist-put opts :custom-size
                              (completing-read "Size: " sizes nil nil
                                               cmacs-ai-image-size)))))
    (when (memq 'resolution-tier caps)
      (setq opts (plist-put opts :resolution
                            (completing-read "Resolution: "
                                             '("1k" "2k" "4k") nil t))))
    (when (memq 'quality caps)
      (let ((qualities (plist-get info :qualities)))
        (setq opts (plist-put opts :quality
                              (completing-read "Quality: " qualities
                                               nil nil)))))
    (when (memq 'multi-count caps)
      (setq opts (plist-put opts :count
                            (read-number "Count: "
                                         (or cmacs-ai-image-count 1)))))
    ;; Drop the ones left empty by just hitting RET.
    (let (clean)
      (while opts
        (let ((k (car opts)) (v (cadr opts)))
          (when (and v (not (equal v "")))
            (setq clean (append clean (list k v)))))
        (setq opts (cddr opts)))
      clean)))

;;;; Commands ----------------------------------------------------------

;;;###autoload
(defun cmacs-ai-image (prompt &optional options)
  "Generate an image for PROMPT and insert it at point.
In an Org buffer the image is attached to the current node and shown
inline; elsewhere it is saved under `cmacs-ai-image-dir'.

With a prefix argument, prompt for the provider, model and the
options that model supports.  Interactively the active region is used
as the prompt when there is one.

Generation is asynchronous -- Emacs stays responsive, and the image
appears when it arrives.  OPTIONS is a plist as accepted by
`cmacs-ai-image-generate-async', plus `:provider'."
  (interactive
   (let ((opts (when current-prefix-arg (cmacs-ai-image--read-options))))
     (list (cmacs-ai-image--read-prompt) opts)))
  (cmacs-ai-image--run prompt options (current-buffer) (point)
                       (cmacs-ai-image--default-done prompt)))

;;;###autoload
(defun cmacs-ai-image-edit (prompt references &optional options)
  "Generate an image from PROMPT conditioned on REFERENCES.
REFERENCES is a list of file paths, or of (PATH . ROLE) pairs.  Roles
such as \"style\" or \"subject\" tell the model what each reference is
for, which is what makes multi-image conditioning work -- the wire
format has no field for it, so ai-glib folds the labels into the
prompt.

Interactively the references come from the image at point, from the
marked files in Dired, or are read one at a time.  With a prefix
argument you are also asked for a role for each.

Not every model accepts references, and those that do have limits;
`cmacs-ai-image-list-models' shows both."
  (interactive
   (let* ((refs (cmacs-ai-image--read-references))
          (prompt (cmacs-ai-image--read-prompt)))
     (list prompt refs nil)))
  (unless references
    (user-error "No reference images given"))
  (cmacs-ai-image--run
   prompt
   (plist-put (copy-sequence options) :references references)
   (current-buffer) (point)
   (cmacs-ai-image--default-done prompt)))

(defun cmacs-ai-image--dired-marked ()
  "Return the marked files in Dired, or nil when not in Dired."
  (when (derived-mode-p 'dired-mode)
    (ignore-errors (dired-get-marked-files))))

(defun cmacs-ai-image--at-point ()
  "Return the file behind the Org link at point, or nil."
  (when (derived-mode-p 'org-mode)
    (let ((ctx (ignore-errors (org-element-context))))
      (when (and ctx (eq (org-element-type ctx) 'link))
        (let ((type (org-element-property :type ctx))
              (path (org-element-property :path ctx)))
          (cond
           ((equal type "file") (expand-file-name path))
           ((equal type "attachment")
            (ignore-errors
              (expand-file-name path (org-attach-dir))))))))))

(defun cmacs-ai-image--read-references ()
  "Collect reference image paths interactively.
Prefers the image at point, then Dired marks, then prompts.  With a
prefix argument each reference is also given a role."
  (let* ((want-roles current-prefix-arg)
         (found (or (cmacs-ai-image--dired-marked)
                    (let ((one (cmacs-ai-image--at-point)))
                      (and one (list one)))))
         (refs '()))
    (if found
        (setq refs found)
      (let ((more t))
        (while more
          (let ((f (read-file-name
                    (format "Reference image %d (RET to stop): "
                            (1+ (length refs)))
                    nil nil nil)))
            (if (or (null f) (equal f "") (not (file-regular-p f)))
                (setq more nil)
              (push f refs))))
        (setq refs (nreverse refs))))
    (if want-roles
        (mapcar (lambda (f)
                  (cons f (read-string
                           (format "Role for %s (e.g. style): "
                                   (file-name-nondirectory f)))))
                refs)
      refs)))

;;;###autoload
(defun cmacs-ai-image-regenerate ()
  "Regenerate the image at point from its #+CAPTION prompt.
The new image replaces the link in place, keeping whatever caption
was there.  Only works where `cmacs-ai-image-insert-caption' recorded
the prompt in the first place."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((prompt nil) (lbeg nil) (lend nil))
    (save-excursion
      (beginning-of-line)
      (unless (looking-at-p org-link-bracket-re)
        (when (re-search-forward org-link-bracket-re (line-end-position) t)
          (goto-char (match-beginning 0))))
      (beginning-of-line)
      (setq lbeg (point) lend (line-end-position))
      (forward-line -1)
      (when (looking-at "^#\\+CAPTION: *\\(.*\\)$")
        (setq prompt (match-string-no-properties 1))))
    (unless prompt
      (user-error "No #+CAPTION above point to regenerate from"))
    (delete-region lbeg (min (1+ lend) (point-max)))
    (cmacs-ai-image--run prompt nil (current-buffer) lbeg
                         (cmacs-ai-image--default-done prompt))))

;;;###autoload
(defun cmacs-ai-image-variations (prompt count)
  "Generate COUNT images for PROMPT and insert them all.
A count above the model's maximum is clamped rather than refused."
  (interactive
   (list (cmacs-ai-image--read-prompt)
         (read-number "How many: " (max 2 (or cmacs-ai-image-count 1)))))
  (cmacs-ai-image--run prompt (list :count count)
                       (current-buffer) (point)
                       (cmacs-ai-image--default-done prompt)))

;;;###autoload
(defun cmacs-ai-image-save-as (destination)
  "Copy the image at point to DESTINATION."
  (interactive "FSave image to: ")
  (let ((src (cmacs-ai-image--at-point)))
    (unless (and src (file-exists-p src))
      (user-error "No image file at point"))
    (copy-file src destination 1)
    (message "cmacs-ai-image: saved %s" destination)))

;;;###autoload
(defun cmacs-ai-image-list-models (&optional provider)
  "Show the image models PROVIDER offers, with their capabilities.
Interactively, PROVIDER defaults to `cmacs-ai-image-provider'; with a
prefix argument you are asked which."
  (interactive
   (list (if current-prefix-arg
             (intern (completing-read "Provider: "
                                      '("gemini" "openai" "grok") nil t))
           cmacs-ai-image-provider)))
  (cmacs-ai-image--ensure)
  (let* ((handle (cmacs-ai-image--client provider nil))
         (models (unwind-protect
                     (cmacs-ai-image-models handle)
                   (ignore-errors (cmacs-ai-client-free handle)))))
    (with-current-buffer (get-buffer-create "*cmacs-ai image models*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (format "#+TITLE: %s image models\n\n" provider))
        (dolist (m models)
          (insert (format "* %s\n" (plist-get m :id)))
          (when (plist-get m :notes)
            (insert (format "  %s\n" (plist-get m :notes))))
          (insert (format "  - max references : %d\n"
                          (plist-get m :max-references)))
          (insert (format "  - max count      : %d\n"
                          (plist-get m :max-count)))
          (when (plist-get m :aspect-ratios)
            (insert (format "  - aspect ratios  : %s\n"
                            (string-join (plist-get m :aspect-ratios) " "))))
          (when (plist-get m :sizes)
            (insert (format "  - sizes          : %s\n"
                            (string-join (plist-get m :sizes) " "))))
          (when (plist-get m :qualities)
            (insert (format "  - qualities      : %s\n"
                            (string-join (plist-get m :qualities) " "))))
          (insert (format "  - capabilities   : %s\n\n"
                          (mapconcat #'symbol-name
                                     (plist-get m :capabilities) " "))))
        (goto-char (point-min)))
      (display-buffer (current-buffer)))))

(provide 'cmacs-ai-image)

;;; cmacs-ai-image.el ends here
