;;; cmacs-ai-image-block.el --- ai-image org babel block  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An org-babel "ai-image" backend, so a figure can live in the document
;; that describes it:
;;
;;   #+BEGIN_SRC ai-image :provider gemini :aspect 16:9 :resolution 2k
;;   A hyacinth macaw perched on a brass telescope, cinematic lighting
;;   #+END_SRC
;;
;; `C-c C-c' generates the image and puts a link in #+RESULTS:, so
;; re-evaluating regenerates the figure in place.  Unlike the interactive
;; commands this path is synchronous, because org-babel has no async
;; protocol -- expect it to block for tens of seconds.
;;
;; Header args mirror the request surface; see the docstring of
;; `org-babel-execute:ai-image'.

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-image)
(require 'ob)

(defvar org-babel-default-header-args:ai-image
  '((:results . "raw") (:exports . "results"))
  "Default header args for ai-image blocks.
`raw' keeps the emitted link a live Org link rather than wrapping it
in an example block, which is what makes it render as an image.")

(defconst cmacs-ai-image-block--params
  '((:model       . :model)
    (:aspect      . :aspect)
    (:size        . :custom-size)
    (:resolution  . :resolution)
    (:count       . :count)
    (:quality     . :quality)
    (:style       . :style)
    (:background  . :background)
    (:format      . :format)
    (:compression . :compression)
    (:negative    . :negative)
    (:seed        . :seed)
    (:strength    . :strength)
    (:guidance    . :guidance)
    (:steps       . :steps)
    (:moderation  . :moderation)
    (:fidelity    . :fidelity)
    (:operation   . :operation))
  "Header arg to `cmacs-ai-image-generate-sync' option key.")

(defconst cmacs-ai-image-block--numeric
  '(:count :compression :seed :steps)
  "Options that must be integers.")

(defconst cmacs-ai-image-block--float
  '(:strength :guidance)
  "Options that must be floats.")

(defun cmacs-ai-image-block--coerce (key value)
  "Coerce header-arg VALUE for option KEY.
Org hands everything over as a string or a symbol, but the C layer
type-checks, so numbers have to be made numbers here."
  (let ((s (format "%s" value)))
    (cond
     ((memq key cmacs-ai-image-block--numeric) (truncate (string-to-number s)))
     ((memq key cmacs-ai-image-block--float)   (float (string-to-number s)))
     (t s))))

(defun cmacs-ai-image-block--references (params)
  "Collect :ref header args from PARAMS into a reference list.
Repeated `:ref' args accumulate, and each may be PATH or PATH::ROLE:

  :ref logo.png::style :ref subject.jpg::subject"
  (let (refs)
    (dolist (cell params)
      (when (eq (car cell) :ref)
        (let* ((raw (format "%s" (cdr cell)))
               (bits (split-string raw "::" t)))
          (push (if (cdr bits)
                    (cons (expand-file-name (car bits)) (cadr bits))
                  (expand-file-name raw))
                refs))))
    (nreverse refs)))

(defun cmacs-ai-image-block--options (params)
  "Build the option plist for `cmacs-ai-image-generate-sync' from PARAMS."
  (let ((opts '())
        (refs (cmacs-ai-image-block--references params)))
    (dolist (cell cmacs-ai-image-block--params)
      (let ((value (cdr (assq (car cell) params))))
        (when (and value (not (equal value "")))
          (setq opts (append opts (list (cdr cell)
                                        (cmacs-ai-image-block--coerce
                                         (cdr cell) value)))))))
    (when refs
      (setq opts (append opts (list :references refs))))
    opts))

(defun org-babel-execute:ai-image (body params)
  "Generate an image from BODY and return a link to it.

PARAMS header args:

  :provider    gemini / openai / grok
  :model       model id
  :file        write here instead of attaching to the node
  :ref         reference image, as PATH or PATH::ROLE; repeatable
  :aspect      aspect ratio, e.g. 16:9
  :size        pixel size, e.g. 1024x1024
  :resolution  1k / 2k / 4k
  :count       how many images
  :quality :style :background :format :compression
  :negative :seed :guidance :steps :strength
  :moderation :fidelity :operation

With no `:file', the image is attached to the enclosing Org node and the
result is an attachment link, so the figure travels with the document.

This blocks until the image arrives -- org-babel offers no async
protocol.  `cmacs-ai-image-timeout' bounds the wait."
  (cmacs-ai-image--ensure)
  (let* ((provider (cdr (assq :provider params)))
         (prov     (and provider (intern (format "%s" provider))))
         (file     (cdr (assq :file params)))
         (model    (cdr (assq :model params)))
         (opts     (cmacs-ai-image-block--options params))
         (handle   (cmacs-ai-image--client prov (and model (format "%s" model))))
         (payload  nil))
    (unwind-protect
        (setq payload (cmacs-ai-image-generate-sync
                       handle body opts cmacs-ai-image-timeout))
      (ignore-errors (cmacs-ai-client-free handle)))
    (let* ((images (plist-get payload :images))
           (first  (car images)))
      (cond
       ((null first) (error "cmacs-ai-image: no images returned"))
       ((null (plist-get first :data))
        (error "cmacs-ai-image: image bytes could not be retrieved"))
       (t
        (let* ((mime (or (plist-get first :mime) "image/png"))
               (tmp  (cmacs-ai-image--write-temp
                      (plist-get first :data) mime 0 1)))
          (if file
              ;; An explicit :file is the caller taking charge of where
              ;; the image lives, so honour it exactly.
              (let ((dest (expand-file-name file)))
                (make-directory (file-name-directory dest) t)
                (rename-file tmp dest t)
                (format "[[file:%s]]" file))
            (cmacs-ai-image--link-for tmp))))))))

;;;###autoload
(defun cmacs-ai-image-block-register ()
  "Register the ai-image org-babel backend.  Safe to call repeatedly."
  (interactive)
  (add-to-list 'org-babel-load-languages '(ai-image . t))
  (org-babel-do-load-languages 'org-babel-load-languages
                               org-babel-load-languages))

(provide 'cmacs-ai-image-block)
;;; cmacs-ai-image-block.el ends here
