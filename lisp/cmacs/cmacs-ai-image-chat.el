;;; cmacs-ai-image-chat.el --- image generation from the chat buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two ways to get an image out of a `cmacs-ai-chat' buffer:
;;
;; - `/image PROMPT' in the compose section generates one directly, with
;;   no model turn involved.
;;
;; - the `generate_image' tool, which lets the model itself decide to
;;   draw something mid-conversation.
;;
;; The tool is deliberately *not* named `ai_...'.  The MCP bridge hides
;; every tool matching "^ai_" from in-process chat buffers, to stop the
;; model calling itself recursively -- and an in-process chat buffer is
;; exactly where this one needs to be visible.
;;
;; Generated images are attached to the chat node, so the existing
;; end-of-turn preview in `cmacs-ai-chat' renders them with no extra
;; work here.

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-image)

(declare-function cmacs-ai-chat--insert-heading "cmacs-ai-chat"
                  (buf label body &optional level))
(declare-function cmacs-ai-define-tool "cmacs-ai-call"
                  (name description params callback))
(declare-function cmacs-ai--register-tool "cmacs-ai-call" (executor spec))

(defcustom cmacs-ai-chat-enable-image-tool t
  "Whether chat buffers offer the model a `generate_image' tool.
When enabled the model can produce images itself mid-conversation;
they are attached to the chat node and previewed inline."
  :type 'boolean
  :group 'cmacs-ai-image)

;;;; The tool -----------------------------------------------------------

(defun cmacs-ai-image-chat--parse-refs (raw)
  "Split RAW, a comma-separated reference list, into a reference list.
Each item is PATH or PATH::ROLE.

The list is a string rather than structured data because the MCP
bridge's schema translator rejects nested objects, so every tool
parameter has to be flat."
  (when (and raw (stringp raw) (not (string-empty-p raw)))
    (delq nil
          (mapcar (lambda (item)
                    (let* ((s (string-trim item))
                           (bits (split-string s "::" t)))
                      (cond
                       ((string-empty-p s) nil)
                       ((cdr bits) (cons (expand-file-name (car bits))
                                         (cadr bits)))
                       (t (expand-file-name s)))))
                  (split-string raw "," t)))))

(defun cmacs-ai-image-chat--tool-callback (_name input-json _id)
  "Handle a `generate_image' call with arguments INPUT-JSON.
Returns a string describing what happened, which goes back to the
model as the tool result."
  (condition-case err
      (let* ((args   (json-parse-string input-json :object-type 'alist))
             (prompt (alist-get 'prompt args))
             (refs   (cmacs-ai-image-chat--parse-refs
                      (alist-get 'references args)))
             (opts   '())
             (buffer (current-buffer)))
        (unless (and prompt (not (string-empty-p prompt)))
          (error "generate_image: missing 'prompt'"))

        (dolist (pair '((model . :model)
                        (aspect . :aspect)
                        (size . :custom-size)
                        (quality . :quality)))
          (let ((v (alist-get (car pair) args)))
            (when (and v (stringp v) (not (string-empty-p v)))
              (setq opts (append opts (list (cdr pair) v))))))

        (when refs
          (setq opts (append opts (list :references refs))))

        ;; Synchronous: the tool loop is synchronous, and the model is
        ;; waiting on this result before it can continue.
        (let* ((handle (cmacs-ai-image--client
                        (alist-get 'provider args)))
               (payload (unwind-protect
                            (cmacs-ai-image-generate-sync
                             handle prompt opts cmacs-ai-image-timeout)
                          (ignore-errors (cmacs-ai-client-free handle))))
               (images (plist-get payload :images)))
          (if (null images)
              "generate_image: the provider returned no images"
            (let ((placed (with-current-buffer buffer
                            (save-excursion
                              (goto-char (point-max))
                              (cmacs-ai-image--place
                               images prompt buffer (point))))))
              (format "Generated and inserted %d image%s into the buffer."
                      placed (if (= placed 1) "" "s"))))))
    (error
     (format "generate_image failed: %s" (error-message-string err)))))

(defun cmacs-ai-image-chat-tool-spec ()
  "Return the `generate_image' tool spec.
Every parameter is a flat scalar; the MCP bridge rejects nested
objects, so the reference list is a comma-separated string."
  (cmacs-ai-define-tool
   "generate_image"
   (concat "Generate an image from a text prompt and insert it into the "
           "current buffer. Use this when the user asks for a picture, "
           "diagram, illustration or logo.")
   '(("prompt" "string" "What the image should depict." t)
     ("references" "string"
      (concat "Optional comma-separated reference images to condition on, "
              "each PATH or PATH::ROLE, e.g. "
              "\"logo.png::style,cat.jpg::subject\".")
      nil)
     ("provider" "string" "gemini, openai or grok. Omit for the default."
      nil)
     ("model" "string" "Model id. Omit for the provider default." nil)
     ("aspect" "string" "Aspect ratio such as 16:9. Omit for square." nil)
     ("size" "string" "Pixel size such as 1024x1024 (OpenAI models)." nil)
     ("quality" "string" "low, medium, high, standard or hd." nil))
   #'cmacs-ai-image-chat--tool-callback))

;;;###autoload
(defun cmacs-ai-image-chat-register (executor)
  "Register `generate_image' on EXECUTOR.
Called from `cmacs-ai-chat''s executor setup; a no-op when
`cmacs-ai-chat-enable-image-tool' is nil or images are unavailable."
  (when (and executor
             cmacs-ai-chat-enable-image-tool
             (cmacs-ai-image--available-p)
             (fboundp 'cmacs-ai--register-tool))
    (condition-case err
        (cmacs-ai--register-tool executor (cmacs-ai-image-chat-tool-spec))
      (error
       (message "cmacs-ai-image: could not register generate_image: %S"
                err)))))

;;;; The /image shortcut -------------------------------------------------

;;;###autoload
(defun cmacs-ai-image-chat-slash-command (line)
  "Handle LINE when it is a `/image ...' compose-buffer command.
Returns non-nil when LINE was consumed, so the caller knows not to
send it to the model."
  (when (string-match "\\`[ \t]*/image[ \t]+\\(.+\\)\\'" line)
    (let ((prompt (string-trim (match-string 1 line))))
      (cmacs-ai-image--run prompt nil (current-buffer) (point-max)
                           (cmacs-ai-image--default-done prompt))
      t)))

(with-eval-after-load 'cmacs-ai-chat
  (add-hook 'cmacs-ai-chat-slash-command-functions
            #'cmacs-ai-image-chat-slash-command))

(defvar cmacs-ai-chat-slash-command-functions)

(provide 'cmacs-ai-image-chat)
;;; cmacs-ai-image-chat.el ends here
