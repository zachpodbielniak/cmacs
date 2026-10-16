;;; cmacs-ai-proofread.el --- Fix spelling and grammar with cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Correct spelling and grammar" as a first-class AI action, in three
;; shapes:
;;
;;   - `cmacs-ai-proofread' (right-click -> AI -> Ask -> Fix spelling &
;;     grammar...): the corrected text in a result window, buffer
;;     untouched -- the same shape as Rephrase.  Lives in
;;     cmacs-ai-textops.el as the `proofread' operation.
;;
;;   - `cmacs-ai-proofread-in-place' (... -> Fix spelling & grammar in
;;     place): the region is replaced when the answer arrives, as ONE
;;     undo step.  ASYNCHRONOUS, unlike `cmacs-ai-rewrite-region': under
;;     `cmacs --gowl' Emacs's thread is the compositor's, and a
;;     synchronous model call there freezes the desktop for as long as
;;     the model thinks.  If the text changed while the model was
;;     working, nothing is overwritten; the correction goes to the kill
;;     ring instead.
;;
;;   - `cmacs-ai-proofread-text': the engine both use, and what other
;;     surfaces (the gowl bar's ai-rewrite widget) call to correct a
;;     string with no buffer at all.
;;
;; Rephrase rewrites for clarity; this changes as little as possible.
;; The difference matters for text that has to stay in someone's own
;; voice, which is most text anyone proofreads.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-ai--ensure "cmacs-ai" ())
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))

(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)

(defcustom cmacs-ai-proofread-system-prompt
  "You are a careful copy editor.  Correct spelling, grammar,
punctuation and obvious typos in the text you are given, and change
NOTHING else: keep the author's wording, voice, register, formatting,
line breaks, markup, code, names and technical terms exactly as they
are.  Do not rephrase for style, do not add or remove content, do not
translate.  If the text is already correct, return it unchanged.
Output ONLY the corrected text -- no preamble, no notes on what you
changed, no quotes or fences around it."
  "System prompt for `cmacs-ai-proofread' and its in-place variant."
  :type 'string
  :group 'cmacs-ai-textops)

(defun cmacs-ai-proofread--strip-wrapping (text original)
  "Undo the wrapping models add despite being told not to.

A fenced block or a pair of quotes around TEXT that ORIGINAL did not
have is removed, as is trailing whitespace the original did not end
with.  Anything else is left exactly as the model wrote it."
  (let ((out text))
    (when (and (string-match "\\`[ \t\n]*```[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```[ \t\n]*\\'" out)
               (not (string-prefix-p "```" (string-trim-left original))))
      (setq out (match-string 1 out)))
    (when (and (string-match "\\`\"\\(\\(?:.\\|\n\\)*\\)\"\\'" out)
               (not (string-prefix-p "\"" original)))
      (setq out (match-string 1 out)))
    (unless (string-match-p "[ \t\n]\\'" original)
      (setq out (string-trim-right out)))
    out))

;;;###autoload
(defun cmacs-ai-proofread-text (text callback &optional provider model system)
  "Correct the spelling and grammar of TEXT asynchronously.

CALLBACK is called once, on Emacs's thread, as (CALLBACK RESULT ERROR):
RESULT is the corrected string and ERROR nil on success, RESULT nil and
ERROR a message string on failure.  PROVIDER and MODEL default to
`cmacs-ai-textops-provider' and `cmacs-ai-textops-model'; SYSTEM to
`cmacs-ai-proofread-system-prompt'.

Returns immediately.  Never prompts and never blocks, so it is safe to
call from an RPC surface (emacsctl, D-Bus, MCP) and under `--gowl'."
  (require 'cmacs-ai)
  (require 'cmacs-ai-textops)
  (let ((pair nil)
        (acc nil)
        (done nil))
    (cl-flet ((finish (result err)
                (unless done
                  (setq done t)
                  ;; Freed on the next turn of the loop, never from
                  ;; inside the stream callback that is still running
                  ;; on the session.
                  (when (and pair (fboundp 'cmacs-ai-free-session))
                    (let ((p pair))
                      (run-at-time 0 nil (lambda ()
                                           (ignore-errors
                                             (cmacs-ai-free-session p))))))
                  (funcall callback result err))))
      (condition-case err
          (progn
            (cmacs-ai--ensure)
            (setq pair (cmacs-ai-make-session
                        (or provider cmacs-ai-textops-provider)
                        (or model cmacs-ai-textops-model)
                        (or system cmacs-ai-proofread-system-prompt)))
            (cmacs-ai-chat-stream
             (cdr pair) text
             (lambda (payload)
               (pcase (car-safe payload)
                 (:delta (when (cadr payload) (push (cadr payload) acc)))
                 (:end
                  (let ((streamed (apply #'concat (nreverse acc)))
                        (final (plist-get (cdr payload) :text)))
                    (finish (cmacs-ai-proofread--strip-wrapping
                             (if (string-empty-p streamed)
                                 (or final "")
                               streamed)
                             text)
                            nil)))
                 (:error
                  (finish nil (or (cadr payload) "stream error")))))))
        (error (finish nil (error-message-string err)))))
    nil))

;;;###autoload
(defun cmacs-ai-proofread-in-place (beg end)
  "Fix spelling and grammar between BEG and END, replacing the text.

Asynchronous: keep working while the model answers.  The replacement is
one undo step.  If the text between BEG and END changed in the
meantime, nothing is overwritten -- the correction is put on the kill
ring and the echo area says so."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (let ((b (bounds-of-thing-at-point 'paragraph)))
       (unless b (user-error "cmacs-ai: no region or paragraph here"))
       (list (car b) (cdr b)))))
  (when buffer-read-only
    (user-error "cmacs-ai: buffer is read-only"))
  (let* ((buf (current-buffer))
         (start (copy-marker beg))
         (stop (copy-marker end t))
         (original (buffer-substring-no-properties beg end)))
    (when (string-empty-p (string-trim original))
      (user-error "cmacs-ai: nothing to proofread"))
    (message "cmacs-ai: proofreading %d characters..." (length original))
    (cmacs-ai-proofread-text
     original
     (lambda (result err)
       (cond
        (err (message "cmacs-ai: proofreading failed: %s" err))
        ((not (buffer-live-p buf))
         (kill-new result)
         (message "cmacs-ai: buffer gone; correction is on the kill ring"))
        ((string= result original)
         (message "cmacs-ai: no corrections needed"))
        (t
         (with-current-buffer buf
           (if (not (string= (buffer-substring-no-properties start stop)
                             original))
               (progn
                 (kill-new result)
                 (message "cmacs-ai: the text changed while proofreading; \
correction is on the kill ring"))
             (let ((inhibit-read-only nil))
               (save-excursion
                 (atomic-change-group
                   (goto-char start)
                   (delete-region start stop)
                   (insert result)))
               (undo-boundary)
               (message "cmacs-ai: corrected (%d -> %d chars)"
                        (length original) (length result)))))))
       (set-marker start nil)
       (set-marker stop nil)))))

(provide 'cmacs-ai-proofread)

;;; cmacs-ai-proofread.el ends here
