;;; cmacs-ai-image-menu.el --- transient menu for image generation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `M-x cmacs-ai-image-menu' opens a transient for composing an image
;; request a piece at a time: provider and model, geometry, appearance,
;; output encoding, sampling, and as many reference images as you like,
;; each with its own role.
;;
;; The menu is capability-aware.  Every choice is offered against the
;; model actually selected -- aspect ratios come from that model's own
;; list, quality words from its own vocabulary -- and options it cannot
;; honour are hidden rather than shown and silently dropped.  Switching
;; model re-reads all of it.
;;
;; State lives in one plist rather than in transient's own argument
;; parsing, because two of the requirements do not fit an argument list:
;; the choices depend on a value chosen elsewhere in the same menu, and
;; reference images accumulate as an ordered list of (PATH . ROLE).

;;; Code:

(require 'transient)
(require 'cmacs-ai-image)

;;;; State --------------------------------------------------------------

(defvar cmacs-ai-image-menu--state nil
  "Plist of the request being composed.
Keys mirror the options of `cmacs-ai-image-generate-async', plus
`:provider' and `:prompt'.  A key is absent when unset, which is what
leaves the provider on its own default.")

(defvar cmacs-ai-image-menu--models-cache nil
  "Alist of PROVIDER to its model list, so redisplay costs nothing.
Model tables are static, so one lookup per provider per session.")

(defun cmacs-ai-image-menu--get (key)
  (plist-get cmacs-ai-image-menu--state key))

(defun cmacs-ai-image-menu--put (key value)
  "Set KEY to VALUE, or remove it when VALUE is nil."
  (if value
      (setq cmacs-ai-image-menu--state
            (plist-put cmacs-ai-image-menu--state key value))
    (setq cmacs-ai-image-menu--state
          (org-plist-delete cmacs-ai-image-menu--state key)))
  value)

;;;; Model introspection -------------------------------------------------

(defun cmacs-ai-image-menu--provider ()
  (or (cmacs-ai-image-menu--get :provider) cmacs-ai-image-provider))

(defun cmacs-ai-image-menu--models (&optional provider)
  "Return the model plists PROVIDER offers, cached."
  (let ((p (or provider (cmacs-ai-image-menu--provider))))
    (or (cdr (assq p cmacs-ai-image-menu--models-cache))
        (let ((models
               (when (cmacs-ai-image--available-p)
                 (let ((handle (ignore-errors (cmacs-ai-image--client p nil))))
                   (when handle
                     (unwind-protect
                         (ignore-errors (cmacs-ai-image-models handle))
                       (ignore-errors (cmacs-ai-client-free handle))))))))
          (push (cons p models) cmacs-ai-image-menu--models-cache)
          models))))

(defun cmacs-ai-image-menu--info ()
  "Return the plist for the selected model, or the provider default's."
  (let* ((models (cmacs-ai-image-menu--models))
         (want (cmacs-ai-image-menu--get :model)))
    (or (and want (seq-find (lambda (m) (equal (plist-get m :id) want)) models))
        ;; No model chosen yet: describe the first, which is the
        ;; provider's default, so the menu is useful before you pick one.
        (car models))))

(defun cmacs-ai-image-menu--supports-p (capability)
  "Whether the selected model honours CAPABILITY.
An unknown model reports non-nil: the library passes unknown models
through untouched, so the menu should not hide options for one."
  (let ((info (cmacs-ai-image-menu--info)))
    (if (null info)
        t
      (and (memq capability (plist-get info :capabilities)) t))))

;;;; Reading values ------------------------------------------------------

(defun cmacs-ai-image-menu--read (prompt choices key)
  "Read a value for KEY, completing over CHOICES.
Empty input clears the key, which is how you get back to the model's
own default."
  (let* ((current (cmacs-ai-image-menu--get key))
         (value (completing-read
                 (format "%s%s (empty clears): "
                         prompt
                         (if current (format " [now: %s]" current) ""))
                 choices nil nil nil nil)))
    (cmacs-ai-image-menu--put key (if (string-empty-p value) nil value))))

(defun cmacs-ai-image-menu--read-number (prompt key)
  (let* ((current (cmacs-ai-image-menu--get key))
         (value (read-string
                 (format "%s%s (empty clears): " prompt
                         (if current (format " [now: %s]" current) "")))))
    (cmacs-ai-image-menu--put
     key (unless (string-empty-p value) (string-to-number value)))))

(defun cmacs-ai-image-menu--label (text key)
  "Menu label TEXT showing the current value of KEY."
  (let ((v (cmacs-ai-image-menu--get key)))
    (if v
        (format "%-14s %s" text (propertize (format "%s" v) 'face 'transient-value))
      (format "%-14s %s" text (propertize "—" 'face 'transient-inactive-value)))))

;;;; Suffixes: model -----------------------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-provider ()
  "Choose the provider."
  :transient t
  :description (lambda () (cmacs-ai-image-menu--label "provider" :provider))
  (interactive)
  (let ((p (intern (completing-read
                    "Provider: " '("gemini" "openai" "grok") nil t nil nil
                    (symbol-name (cmacs-ai-image-menu--provider))))))
    (cmacs-ai-image-menu--put :provider p)
    ;; The old model belongs to the old provider; drop it and everything
    ;; that was chosen from its vocabulary.
    (cmacs-ai-image-menu--put :model nil)
    (cmacs-ai-image-menu--put :aspect nil)
    (cmacs-ai-image-menu--put :custom-size nil)
    (cmacs-ai-image-menu--put :quality nil)))

(transient-define-suffix cmacs-ai-image-menu-set-model ()
  "Choose the model."
  :transient t
  :description (lambda () (cmacs-ai-image-menu--label "model" :model))
  (interactive)
  (let* ((models (cmacs-ai-image-menu--models))
         (ids (mapcar (lambda (m) (plist-get m :id)) models)))
    (unless ids
      (user-error "No image models available for %s"
                  (cmacs-ai-image-menu--provider)))
    (cmacs-ai-image-menu--read "Model" ids :model)
    ;; Geometry and quality vocabularies are per model.
    (cmacs-ai-image-menu--put :aspect nil)
    (cmacs-ai-image-menu--put :custom-size nil)
    (cmacs-ai-image-menu--put :quality nil)))

;;;; Suffixes: geometry --------------------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-aspect ()
  "Choose the aspect ratio, from the ones this model accepts."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'aspect-ratio))
  :description (lambda () (cmacs-ai-image-menu--label "aspect" :aspect))
  (interactive)
  (cmacs-ai-image-menu--read
   "Aspect ratio" (plist-get (cmacs-ai-image-menu--info) :aspect-ratios)
   :aspect))

(transient-define-suffix cmacs-ai-image-menu-set-size ()
  "Choose the pixel size, from the ones this model accepts."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'pixel-size))
  :description (lambda () (cmacs-ai-image-menu--label "size" :custom-size))
  (interactive)
  (cmacs-ai-image-menu--read
   "Size" (plist-get (cmacs-ai-image-menu--info) :sizes) :custom-size))

(transient-define-suffix cmacs-ai-image-menu-set-resolution ()
  "Choose the resolution tier."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'resolution-tier))
  :description (lambda () (cmacs-ai-image-menu--label "resolution" :resolution))
  (interactive)
  (cmacs-ai-image-menu--read "Resolution" '("1k" "2k" "4k") :resolution))

;;;; Suffixes: appearance ------------------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-quality ()
  "Choose the quality, in this model's own vocabulary."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'quality))
  :description (lambda () (cmacs-ai-image-menu--label "quality" :quality))
  (interactive)
  (cmacs-ai-image-menu--read
   "Quality"
   (or (plist-get (cmacs-ai-image-menu--info) :qualities)
       '("low" "medium" "high" "standard" "hd"))
   :quality))

(transient-define-suffix cmacs-ai-image-menu-set-style ()
  "Choose the style, or type a provider-specific preset."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'style))
  :description (lambda () (cmacs-ai-image-menu--label "style" :style))
  (interactive)
  (cmacs-ai-image-menu--read "Style" '("vivid" "natural") :style))

(transient-define-suffix cmacs-ai-image-menu-set-background ()
  "Choose the background treatment."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'transparency))
  :description (lambda () (cmacs-ai-image-menu--label "background" :background))
  (interactive)
  (cmacs-ai-image-menu--read "Background" '("transparent" "opaque")
                             :background))

;;;; Suffixes: output ----------------------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-format ()
  "Choose the output encoding."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'output-format))
  :description (lambda () (cmacs-ai-image-menu--label "format" :format))
  (interactive)
  (cmacs-ai-image-menu--read "Format" '("png" "jpeg" "webp") :format)
  ;; Transparency needs an alpha channel; JPEG has none, and the request
  ;; would be refused later.  Say so now instead.
  (when (and (equal (cmacs-ai-image-menu--get :format) "jpeg")
             (equal (cmacs-ai-image-menu--get :background) "transparent"))
    (cmacs-ai-image-menu--put :background nil)
    (message "cmacs-ai-image: JPEG has no alpha channel; cleared transparent background")))

(transient-define-suffix cmacs-ai-image-menu-set-compression ()
  "Set the compression level for lossy formats."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'output-format))
  :description (lambda () (cmacs-ai-image-menu--label "compression" :compression))
  (interactive)
  (cmacs-ai-image-menu--read-number "Compression 0-100" :compression))

(transient-define-suffix cmacs-ai-image-menu-set-count ()
  "Set how many images to generate."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'multi-count))
  :description (lambda () (cmacs-ai-image-menu--label "count" :count))
  (interactive)
  (let ((max (or (plist-get (cmacs-ai-image-menu--info) :max-count) 1)))
    (cmacs-ai-image-menu--read-number (format "Count (max %d)" max) :count)
    (let ((n (cmacs-ai-image-menu--get :count)))
      (when (and n (> n max))
        (cmacs-ai-image-menu--put :count max)
        (message "cmacs-ai-image: %s caps at %d image(s)"
                 (plist-get (cmacs-ai-image-menu--info) :id) max)))))

;;;; Suffixes: prompt shaping --------------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-negative ()
  "Set the negative prompt."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'negative-prompt))
  :description (lambda () (cmacs-ai-image-menu--label "negative" :negative))
  (interactive)
  (cmacs-ai-image-menu--read "Keep out of the image" nil :negative))

(transient-define-suffix cmacs-ai-image-menu-set-seed ()
  "Set the sampling seed."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'seed))
  :description (lambda () (cmacs-ai-image-menu--label "seed" :seed))
  (interactive)
  (cmacs-ai-image-menu--read-number "Seed" :seed))

;;;; Suffixes: references ------------------------------------------------

(defconst cmacs-ai-image-menu--roles
  '("style" "subject" "background" "character" "composition" "palette"
    "pose" "texture" "lighting")
  "Suggested reference roles.  Any string is accepted.")

(defun cmacs-ai-image-menu--references ()
  (cmacs-ai-image-menu--get :references))

(defun cmacs-ai-image-menu--reference-label (ref)
  (if (consp ref)
      (format "%s [%s]" (file-name-nondirectory (car ref)) (cdr ref))
    (file-name-nondirectory ref)))

(transient-define-suffix cmacs-ai-image-menu-add-reference ()
  "Add a reference image, with an optional role."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'reference-images))
  :description
  (lambda ()
    (let* ((refs (cmacs-ai-image-menu--references))
           (n (length refs))
           (max (or (plist-get (cmacs-ai-image-menu--info) :max-references) 0)))
      (format "%-14s %s" "add reference"
              (propertize (if (zerop n)
                              (format "none (max %d)" max)
                            (format "%d of %d" n max))
                          'face (if (zerop n)
                                    'transient-inactive-value
                                  'transient-value)))))
  (interactive)
  (let* ((info (cmacs-ai-image-menu--info))
         (max (or (plist-get info :max-references) 0))
         (refs (cmacs-ai-image-menu--references)))
    (when (and (> max 0) (>= (length refs) max))
      (user-error "%s accepts at most %d reference image%s"
                  (plist-get info :id) max (if (= max 1) "" "s")))
    (let* ((path (read-file-name "Reference image: " nil nil t))
           (role (completing-read
                  "Role (what is this reference for? empty for none): "
                  cmacs-ai-image-menu--roles nil nil)))
      (unless (file-regular-p path)
        (user-error "Not a file: %s" path))
      (cmacs-ai-image-menu--put
       :references
       (append refs
               (list (if (string-empty-p role)
                         (expand-file-name path)
                       (cons (expand-file-name path) role))))))))

(transient-define-suffix cmacs-ai-image-menu-set-reference-role ()
  "Change the role of one of the reference images."
  :transient t
  :if (lambda () (and (cmacs-ai-image-menu--references) t))
  :description "set a reference's role"
  (interactive)
  (let* ((refs (cmacs-ai-image-menu--references))
         (labels (mapcar #'cmacs-ai-image-menu--reference-label refs))
         (pick (completing-read "Which reference: " labels nil t))
         (index (seq-position labels pick))
         (role (completing-read "Role (empty for none): "
                                cmacs-ai-image-menu--roles nil nil))
         (entry (nth index refs))
         (path (if (consp entry) (car entry) entry)))
    (setf (nth index refs)
          (if (string-empty-p role) path (cons path role)))
    (cmacs-ai-image-menu--put :references refs)))

(transient-define-suffix cmacs-ai-image-menu-remove-reference ()
  "Remove one of the reference images."
  :transient t
  :if (lambda () (and (cmacs-ai-image-menu--references) t))
  :description "remove a reference"
  (interactive)
  (let* ((refs (cmacs-ai-image-menu--references))
         (labels (mapcar #'cmacs-ai-image-menu--reference-label refs))
         (pick (completing-read "Remove which: " labels nil t))
         (index (seq-position labels pick)))
    (cmacs-ai-image-menu--put
     :references (append (seq-take refs index) (seq-drop refs (1+ index))))))

(transient-define-suffix cmacs-ai-image-menu-set-mask ()
  "Choose an edit mask."
  :transient t
  :if (lambda () (cmacs-ai-image-menu--supports-p 'mask))
  :description (lambda () (cmacs-ai-image-menu--label "mask" :mask))
  (interactive)
  (let ((path (read-file-name "Mask (empty clears): " nil "" nil)))
    (cmacs-ai-image-menu--put
     :mask (unless (string-empty-p path) (expand-file-name path)))
    (when (and (cmacs-ai-image-menu--get :mask)
               (null (cmacs-ai-image-menu--references)))
      (message "cmacs-ai-image: a mask needs a reference image to apply it to"))))

;;;; Suffixes: prompt and actions ----------------------------------------

(transient-define-suffix cmacs-ai-image-menu-set-prompt ()
  "Set the prompt."
  :transient t
  :description (lambda () (cmacs-ai-image-menu--label "prompt" :prompt))
  (interactive)
  (cmacs-ai-image-menu--put
   :prompt (read-string "Prompt: "
                        (or (cmacs-ai-image-menu--get :prompt)
                            (and (use-region-p)
                                 (buffer-substring-no-properties
                                  (region-beginning) (region-end)))))))

(transient-define-suffix cmacs-ai-image-menu-reset ()
  "Clear everything composed so far."
  :transient t
  :description "reset"
  (interactive)
  (setq cmacs-ai-image-menu--state nil)
  (message "cmacs-ai-image: menu reset"))

(defun cmacs-ai-image-menu--options ()
  "Return the composed state as options for the generator.
`:prompt' is stripped: it is the prompt argument, not an option."
  (org-plist-delete (copy-sequence cmacs-ai-image-menu--state) :prompt))

(defun cmacs-ai-image-menu--prompt ()
  "Return the prompt to use, asking for one if none was set."
  (or (cmacs-ai-image-menu--get :prompt)
      (cmacs-ai-image-menu--put
       :prompt (read-string "Prompt: "
                            (and (use-region-p)
                                 (buffer-substring-no-properties
                                  (region-beginning) (region-end)))))))

(transient-define-suffix cmacs-ai-image-menu-generate ()
  "Generate and insert at point."
  :description "generate at point"
  (interactive)
  (let ((prompt (cmacs-ai-image-menu--prompt)))
    (when (string-empty-p prompt)
      (user-error "A prompt is required"))
    (cmacs-ai-image--run prompt (cmacs-ai-image-menu--options)
                         (current-buffer) (copy-marker (point))
                         (cmacs-ai-image--default-done prompt))))

(transient-define-suffix cmacs-ai-image-menu-generate-after-region ()
  "Generate from the selected text, inserting after it."
  :if (lambda () (use-region-p))
  :description "generate from selection, insert after it"
  (interactive)
  (let ((prompt (string-trim (buffer-substring-no-properties
                              (region-beginning) (region-end))))
        (anchor (copy-marker (region-end))))
    (when (string-empty-p prompt)
      (set-marker anchor nil)
      (user-error "The selected text is empty"))
    (deactivate-mark)
    (cmacs-ai-image--run prompt (cmacs-ai-image-menu--options)
                         (current-buffer) anchor
                         (cmacs-ai-image--default-done prompt))))

;;;; The menu ------------------------------------------------------------

(defun cmacs-ai-image-menu--summary ()
  "Header describing the model in play and what it will accept."
  (let* ((info (cmacs-ai-image-menu--info))
         (id (or (cmacs-ai-image-menu--get :model)
                 (and info (plist-get info :id))
                 "(none)"))
         (notes (and info (plist-get info :notes)))
         (maxref (and info (plist-get info :max-references))))
    (concat
     (propertize "Compose an image request" 'face 'transient-heading)
     "\n"
     (format " %s / %s" (cmacs-ai-image-menu--provider) id)
     (if (and maxref (> maxref 0))
         (format "   up to %d reference%s" maxref (if (= maxref 1) "" "s"))
       "   no reference images")
     (if notes (format "\n %s" notes) ""))))

;;;###autoload
(transient-define-prefix cmacs-ai-image-menu ()
  "Compose an image generation request step by step.

Only the options the selected model actually honours are shown, and the
values offered for each come from that model -- aspect ratios from its
own list, quality words from its own vocabulary.  Changing the model
re-reads all of it.

Reference images accumulate; each can carry a role saying what it is
for, which is how a model told to combine several knows which is the
style and which is the subject."
  [:description cmacs-ai-image-menu--summary
   ["Model"
    ("p" cmacs-ai-image-menu-set-provider)
    ("m" cmacs-ai-image-menu-set-model)]
   ["Geometry"
    ("a" cmacs-ai-image-menu-set-aspect)
    ("s" cmacs-ai-image-menu-set-size)
    ("R" cmacs-ai-image-menu-set-resolution)]
   ["Appearance"
    ("q" cmacs-ai-image-menu-set-quality)
    ("y" cmacs-ai-image-menu-set-style)
    ("b" cmacs-ai-image-menu-set-background)]]
  [["Output"
    ("f" cmacs-ai-image-menu-set-format)
    ("c" cmacs-ai-image-menu-set-compression)
    ("n" cmacs-ai-image-menu-set-count)]
   ["Prompt"
    ("t" cmacs-ai-image-menu-set-prompt)
    ("N" cmacs-ai-image-menu-set-negative)
    ("S" cmacs-ai-image-menu-set-seed)]
   ["References"
    ("r" cmacs-ai-image-menu-add-reference)
    ("e" cmacs-ai-image-menu-set-reference-role)
    ("d" cmacs-ai-image-menu-remove-reference)
    ("k" cmacs-ai-image-menu-set-mask)]]
  [["Generate"
    ("g" cmacs-ai-image-menu-generate)
    ("G" cmacs-ai-image-menu-generate-after-region)]
   [""
    ("M" "list models" cmacs-ai-image-list-models :transient t)
    ("C-k" cmacs-ai-image-menu-reset)]]
  (interactive)
  (unless (cmacs-ai-image--available-p)
    (user-error "cmacs was built without ai-glib image support"))
  (transient-setup 'cmacs-ai-image-menu))

(provide 'cmacs-ai-image-menu)
;;; cmacs-ai-image-menu.el ends here
