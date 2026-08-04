;;; cmacs-imgedit-ai.el --- AI editing for imgedit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Make this warmer and crop to the subject", in an image buffer.
;;
;; imgedit's model layer is already handle-based and headless -- every
;; operation is a DEFUN taking a document handle -- so this adds no
;; engine code at all.  It exposes the operations the model may use,
;; hands them to a tool loop, and lets the model compose them.
;;
;; The whole instruction is one undo step.  "Make it warmer" that turns
;; into six calls should cost one `u' to reverse, not six; anything else
;; makes an AI edit something you are reluctant to try.
;;
;; Guarded at load: with cmacs-ai absent the file simply provides
;; nothing, and imgedit is unaffected.  No configure flag, no C
;; dependency.

;;; Code:

(require 'cmacs-imgedit nil 'noerror)
(require 'cmacs-ai-call nil 'noerror)
;; For `cmacs-brigade-deftool' below.  Soft: the direct commands work
;; without the brigade, they simply are not published as agent tools.
(require 'cmacs-brigade-registry nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

;; Soft dependencies: this file works without them (the commands that
;; need them refuse), so they are declared rather than required.
(declare-function cmacs-ai-image--run "cmacs-ai-image"
                  (prompt options buffer position on-done))
(declare-function cmacs-imgedit-add-layer-from-file "cmacs-imgedit"
                  (handle file))

(defgroup cmacs-imgedit-ai nil
  "Prompt-driven image editing."
  :group 'cmacs-imgedit
  :prefix "cmacs-imgedit-ai-")

(defcustom cmacs-imgedit-ai-model nil
  "Model used for image editing instructions.  nil means the default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-imgedit-ai)

(defcustom cmacs-imgedit-ai-max-turns 12
  "Most tool calls one instruction may make.

A cap rather than a guideline: a model that misreads an image can adjust
brightness forever, and each attempt costs money and moves the document
further from what the user had."
  :type 'integer
  :group 'cmacs-imgedit-ai)

(defconst cmacs-imgedit-ai-system-prompt
  "You edit an image the user has open in their editor.

You cannot see the image unless you call describe_image.  Do that first
when the instruction depends on what is actually there -- \"crop to the
subject\" is meaningless otherwise, and guessing produces a crop of
nothing.

Prefer few, decisive operations.  Six small brightness nudges are worse
than one correct one: each is a step the user has to understand when
they look at the result.

When you are done, say briefly what you changed.  If the instruction was
ambiguous, say which reading you took."
  "System prompt for `cmacs-imgedit-ai-prompt'.")


;;;; The operations a model may perform

(defun cmacs-imgedit-ai--tools (handle)
  "Return tool specs operating on HANDLE."
  (list
   (cmacs-ai-define-tool
    "describe_image"
    "Look at the image.  Returns its size, layer count, and a description
of what is visible.  Call this before any instruction that depends on
the content."
    nil
    (lambda (_name _json _id)
      (cmacs-imgedit-ai--describe handle)))

   (cmacs-ai-define-tool
    "adjust_brightness"
    "Change brightness.  DELTA is -100 (much darker) to 100 (much
brighter); 0 does nothing."
    '(("delta" "integer" "Brightness change, -100 to 100" t))
    (lambda (_name json _id)
      (let ((d (cmacs-imgedit-ai--arg json "delta" 0)))
        (cmacs-imgedit-brightness handle d)
        (format "brightness %+d" d))))

   (cmacs-ai-define-tool
    "adjust_contrast"
    "Change contrast.  DELTA is -100 to 100."
    '(("delta" "integer" "Contrast change, -100 to 100" t))
    (lambda (_name json _id)
      (let ((d (cmacs-imgedit-ai--arg json "delta" 0)))
        (cmacs-imgedit-contrast handle d)
        (format "contrast %+d" d))))

   (cmacs-ai-define-tool
    "crop"
    "Crop to a rectangle, in pixels from the top-left."
    '(("x" "integer" "Left edge" t)
      ("y" "integer" "Top edge" t)
      ("width" "integer" "Width" t)
      ("height" "integer" "Height" t))
    (lambda (_name json _id)
      (cmacs-imgedit-ai--crop handle json)))

   (cmacs-ai-define-tool
    "grayscale"
    "Remove all colour."
    nil
    (lambda (_name _json _id)
      (cmacs-imgedit-grayscale handle)
      "converted to grayscale"))

   (cmacs-ai-define-tool
    "invert"
    "Invert the colours."
    nil
    (lambda (_name _json _id)
      (cmacs-imgedit-invert handle)
      "inverted"))

   (cmacs-ai-define-tool
    "blur"
    "Blur the image.  RADIUS is in pixels."
    '(("radius" "integer" "Blur radius in pixels" t))
    (lambda (_name json _id)
      (let ((r (cmacs-imgedit-ai--arg json "radius" 1)))
        (cmacs-imgedit-blur handle r)
        (format "blurred by %d" r))))

   (cmacs-ai-define-tool
    "flip"
    "Flip the image.  DIRECTION is \"horizontal\" or \"vertical\"."
    '(("direction" "string" "horizontal or vertical" t))
    (lambda (_name json _id)
      (let ((d (cmacs-imgedit-ai--arg-string json "direction" "horizontal")))
        (cmacs-imgedit-flip handle (if (string-prefix-p "v" d) 1 0))
        (format "flipped %s" d))))))

(defun cmacs-imgedit-ai--arg (json key default)
  "Read integer KEY from JSON."
  (let ((v (cmacs-imgedit-ai--parse json key)))
    (cond ((integerp v) v)
          ((floatp v) (truncate v))
          ((and (stringp v) (string-match-p "\\`-?[0-9]+\\'" v))
           (string-to-number v))
          (t default))))

(defun cmacs-imgedit-ai--arg-string (json key default)
  (let ((v (cmacs-imgedit-ai--parse json key)))
    (if (stringp v) v default)))

(defun cmacs-imgedit-ai--parse (json key)
  (condition-case nil
      (let ((obj (json-parse-string json :object-type 'alist
                                    :array-type 'list :null-object nil
                                    :false-object nil)))
        (alist-get (intern key) obj nil nil #'eq))
    (error nil)))

(defun cmacs-imgedit-ai--crop (handle json)
  "Crop HANDLE per JSON, clamped to the image."
  (let* ((w (cmacs-imgedit-width handle))
         (h (cmacs-imgedit-height handle))
         (x (max 0 (min (1- w) (cmacs-imgedit-ai--arg json "x" 0))))
         (y (max 0 (min (1- h) (cmacs-imgedit-ai--arg json "y" 0))))
         (cw (cmacs-imgedit-ai--arg json "width" (- w x)))
         (ch (cmacs-imgedit-ai--arg json "height" (- h y))))
    ;; Clamped rather than refused.  A model working from a description
    ;; routinely proposes a rectangle a few pixels past the edge, and
    ;; failing the call sends it round the loop again to produce the same
    ;; thing; trimming it gives the crop it plainly meant.
    (setq cw (max 1 (min cw (- w x)))
          ch (max 1 (min ch (- h y))))
    (cmacs-imgedit-crop handle x y cw ch)
    (format "cropped to %dx%d at %d,%d" cw ch x y)))

(defun cmacs-imgedit-ai--describe (handle)
  "Describe HANDLE's image, using a vision model when one is configured."
  (let ((w (cmacs-imgedit-width handle))
        (h (cmacs-imgedit-height handle))
        (layers (if (fboundp 'cmacs-imgedit-layer-count)
                    (cmacs-imgedit-layer-count handle) 1)))
    (format "Image is %dx%d pixels with %d layer(s).%s"
            w h layers
            ;; A histogram is a poor substitute for seeing the picture,
            ;; but it is honest about brightness and saturation, which is
            ;; most of what a "make it warmer" instruction needs.
            (if (fboundp 'cmacs-imgedit-histogram)
                (condition-case nil
                    (format "  Tone summary: %s"
                            (cmacs-imgedit-ai--tone handle))
                  (error ""))
              ""))))

(defun cmacs-imgedit-ai--tone (handle)
  "Summarise HANDLE's tonal distribution in words."
  (let* ((hist (cmacs-imgedit-histogram handle))
         (n (length hist)))
    (if (or (null hist) (zerop n)) "unavailable"
      (let* ((total (cl-reduce #'+ (append hist nil) :initial-value 0))
             (dark (cl-reduce #'+ (seq-take (append hist nil) (/ n 3))
                              :initial-value 0))
             (bright (cl-reduce #'+ (last (append hist nil) (/ n 3))
                                :initial-value 0)))
        (cond ((zerop total) "unavailable")
              ((> dark (* 2 bright)) "mostly dark")
              ((> bright (* 2 dark)) "mostly bright")
              (t "evenly exposed"))))))


;;;; Commands

;;;###autoload
(defun cmacs-imgedit-ai-prompt (instruction)
  "Apply INSTRUCTION to the image in this buffer.

The whole instruction is one undo step, however many operations it
turns into."
  (interactive "sEdit instruction: ")
  (unless (and (boundp 'cmacs-imgedit--handle) cmacs-imgedit--handle)
    (user-error "Not in an imgedit buffer"))
  (unless (fboundp 'cmacs-ai-call)
    (user-error "cmacs-ai is not available in this build"))
  (let ((handle cmacs-imgedit--handle)
        (buffer (current-buffer)))
    (message "cmacs-imgedit: thinking...")
    ;; One undo boundary around everything the model does.  Six small
    ;; adjustments should cost one `u', not six.
    (with-current-buffer buffer
      (undo-boundary))
    (let ((answer
           (condition-case err
               (cmacs-ai-call
                instruction
                :system cmacs-imgedit-ai-system-prompt
                :model cmacs-imgedit-ai-model
                :tools (cmacs-imgedit-ai--tools handle))
             (error (format "Error: %s" (error-message-string err))))))
      (with-current-buffer buffer
        (undo-boundary)
        (when (fboundp 'cmacs-imgedit--render) (cmacs-imgedit--render)))
      (message "%s" answer)
      answer)))

;;;###autoload
(defun cmacs-imgedit-ai-generate-layer (prompt)
  "Generate an image from PROMPT and add it as a new layer.

Asynchronous, because generation takes tens of seconds and blocking the
editor for it is unreasonable -- and under `emacs --gowl' it would block
the whole desktop."
  (interactive "sGenerate layer: ")
  (unless (and (boundp 'cmacs-imgedit--handle) cmacs-imgedit--handle)
    (user-error "Not in an imgedit buffer"))
  (unless (fboundp 'cmacs-ai-image--run)
    (user-error "Image generation is not available in this build"))
  (let* ((doc cmacs-imgedit--handle)
         (buffer (current-buffer))
         (w (cmacs-imgedit-width doc))
         (h (cmacs-imgedit-height doc)))
    ;; Goes through cmacs-ai-image's own runner rather than the C
    ;; primitive: that is where client creation, the option plist and
    ;; freeing the client on every exit path already live.
    (cmacs-ai-image--run
     prompt
     (list :custom-size (format "%dx%d" w h))
     buffer nil
     (lambda (images _buf _pos)
       (let ((path (plist-get (car images) :path)))
         (if (not (and path (file-readable-p path)))
             (message "cmacs-imgedit: generation returned no usable image")
           (with-current-buffer buffer
             (undo-boundary)
             (cmacs-imgedit-add-layer-from-file doc path)
             (undo-boundary)
             (when (fboundp 'cmacs-imgedit--render) (cmacs-imgedit--render)))
           (message "cmacs-imgedit: added generated layer")))))))

;;;###autoload
(defun cmacs-imgedit-ai-describe ()
  "Describe the current image, for an alt text or a caption."
  (interactive)
  (unless (and (boundp 'cmacs-imgedit--handle) cmacs-imgedit--handle)
    (user-error "Not in an imgedit buffer"))
  (message "%s" (cmacs-imgedit-ai--describe cmacs-imgedit--handle)))


;;;; Brigade tools
;;
;; The same operations, published so an agent can edit an open document.
;; Registered through the public API like anything else.

(when (fboundp 'cmacs-brigade-deftool)
  (cmacs-brigade-deftool imgedit-prompt
    "Edit the image the user currently has open, by instruction.  For
example: \"crop to the subject and increase contrast slightly\"."
    ((instruction string "What to do to the image"))
    :group 'imgedit :destructive t
    (let ((buf (cl-find-if (lambda (b)
                             (with-current-buffer b
                               (and (boundp 'cmacs-imgedit--handle)
                                    cmacs-imgedit--handle)))
                           (buffer-list))))
      (if (not buf) "Error: no image is open."
        (with-current-buffer buf
          (cmacs-imgedit-ai-prompt instruction)))))

  (cmacs-brigade-deftool imgedit-describe
    "Describe the image the user currently has open."
    ()
    :group 'imgedit
    (let ((buf (cl-find-if (lambda (b)
                             (with-current-buffer b
                               (and (boundp 'cmacs-imgedit--handle)
                                    cmacs-imgedit--handle)))
                           (buffer-list))))
      (if (not buf) "No image is open."
        (with-current-buffer buf
          (cmacs-imgedit-ai--describe cmacs-imgedit--handle))))))

(provide 'cmacs-imgedit-ai)

;;; cmacs-imgedit-ai.el ends here
