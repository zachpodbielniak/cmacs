;;; cmacs-rig-image-tests.el --- Image input, end to end in a rig  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Image input (cmacs-ai-vision.el, cmacs/ai/cmacs-ai-vision.c) against a
;; real `cmacs --gowl' child (cmacs-rig.el): real windows, a real
;; screenshot, the real redaction rules from the child's own
;; ~/.config/cmacs/journal-filters.yaml.  The one thing replaced is the
;; model, by a function inside the child that records what it was sent.
;;
;;   images-capture-refused-under-redaction
;;     A capture of a region holding a window the rules exclude is
;;     refused, asked as a model asks (through the MCP `eval' tool, where
;;     the redaction functions act); the same capture of a public window
;;     is not refused.  Needs no new C: the guard runs before the encoder.
;;
;;   images-what-is-that
;;     Point at a window, ask "what is that"; the fake model must receive
;;     an image part -- PNG bytes of plausible size -- with the question.
;;     Needs this round's C (`cmacs-ai-png-encode', `cmacs-ai-image-parts')
;;     in the child's binary and skips, saying so, when it is not there.
;;
;; Run with
;;
;;   CMACS_RIG=1 src/emacs --batch -Q -L lisp/cmacs -L test/cmacs \
;;     --eval '(setq load-prefer-newer t)' -l ert \
;;     -l test/cmacs/cmacs-rig-image-tests.el -f ert-run-tests-batch-and-exit
;;
;; Without CMACS_RIG every test skips, so `make check-cmacs' loading this
;; file costs nothing.  The fixture is a small copy of
;; cmacs-rig-tests.el's (that file's helpers are not loadable without its
;; tests); this file owns one rig and resets what it touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs)
;; Beside this file, and named by its place: `make check' runs with
;; test/cmacs off `load-path'.
(require 'cmacs-rig
         (expand-file-name
          "cmacs-rig"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

;;;; Fixture

(defvar cmacs-rig-image-tests--rig nil
  "The rig this file's tests share.")

(defconst cmacs-rig-image-tests--secret "rigimgsecretqx"
  "A string only the excluded window's title contains.")

(defconst cmacs-rig-image-tests--rules
  (concat "filters:\n"
          "  - match: {title: '" cmacs-rig-image-tests--secret "'}\n"
          "    exclude: true\n")
  "A rule file excluding one window by title.")

(defun cmacs-rig-image-tests--rig ()
  "Return the shared rig, starting it; skip when rigs are not asked for."
  (unless (getenv "CMACS_RIG")
    (ert-skip "rig tests run only with CMACS_RIG=1"))
  (when-let* ((why (cmacs-rig-available-p)))
    (ert-skip (format "no rig here: %s" why)))
  (unless (and cmacs-rig-image-tests--rig
               (cmacs-rig-alive-p cmacs-rig-image-tests--rig))
    (setq cmacs-rig-image-tests--rig
          (condition-case err
              (cmacs-rig-start)
            (cmacs-rig-error
             (ert-skip (format "the rig would not start: %s" (cadr err)))))))
  cmacs-rig-image-tests--rig)

(defun cmacs-rig-image-tests--write-filters (rig contents)
  "Make CONTENTS the child's journal filter file (nil removes it).
Returns what `cmacs-redact-ready-p' says after the reload."
  (let ((file (expand-file-name "home/.config/cmacs/journal-filters.yaml"
                                (cmacs-rig-base rig))))
    (if (null contents)
        (when (file-exists-p file) (delete-file file))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region contents nil file nil 'silent)))
    (cmacs-rig-eval rig '(progn (require 'cmacs-redact)
                                (cmacs-journal-filters-reload)
                                (and (cmacs-redact-ready-p) t)))))

(defun cmacs-rig-image-tests--reset (rig)
  "Undo what a test here did in RIG."
  (when (cmacs-rig-alive-p rig)
    (ignore-errors
      (cmacs-rig-eval
       rig '(progn
              (dolist (f '(cmacs-ai--ensure cmacs-ai-make-session
                           cmacs-ai-chat-stream cmacs-ai-chat-cancel
                           cmacs-ai-free-session))
                (ignore-errors (advice-remove f 'cmacs-rig-fake)))
              (dolist (buffer (buffer-list))
                (when (string-match-p "\\`\\*?rig-\\|\\`\\*cmacs-ai"
                                      (buffer-name buffer))
                  (let ((kill-buffer-query-functions nil))
                    (ignore-errors (kill-buffer buffer)))))
              t)))
    (ignore-errors
      (dolist (info (cmacs-rig-clients rig))
        (unless (eql (alist-get 'pid info) (cmacs-rig-pid rig))
          (ignore-errors (cmacs-rig-close-client rig (alist-get 'id info))))))
    (ignore-errors (cmacs-rig-image-tests--write-filters rig nil))))

(defmacro cmacs-rig-image-tests--deftest (name docstring &rest body)
  "Define cmacs-rig-image-test-NAME with `rig' bound; reset afterwards."
  (declare (indent 1) (doc-string 2))
  `(ert-deftest ,(intern (format "cmacs-rig-image-test-%s" name)) ()
     ,docstring
     (let ((rig (cmacs-rig-image-tests--rig)))
       (unwind-protect (progn ,@body)
         (cmacs-rig-image-tests--reset rig))
       (should (cmacs-rig-alive-p rig)))))

(defun cmacs-rig-image-tests--geometry (rig field)
  "The layout geometry (X Y W H) of FIELD's window in RIG."
  (alist-get 'geometry (cmacs-rig-client rig (plist-get field :id))))

(defun cmacs-rig-image-tests--sleep (seconds)
  "Let SECONDS pass here, turning this Emacs's event loop."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05))))

(defun cmacs-rig-image-tests--capture-form (geometry)
  "A form capturing GEOMETRY in the child; returns what happened."
  `(progn
     (require 'cmacs-ai-vision)
     (condition-case err
         (let ((image (cmacs-ai-capture-region ,@(mapcar #'round geometry))))
           (list 'captured (length (plist-get image :data))))
       (cmacs-ai-capture-refused (list 'refused (error-message-string err)))
       (error (list 'error (error-message-string err))))))

;;;; Cases

(cmacs-rig-image-tests--deftest images-capture-refused-under-redaction
  "No picture of a region in which an excluded window is visible.
Asked through the MCP `eval' tool, i.e. as an agent asks.  The public
window beside it is not refused, so a capture that refuses everything
cannot pass."
  (skip-unless (cmacs-rig-field-client))
  (should (cmacs-rig-image-tests--write-filters
           rig cmacs-rig-image-tests--rules))
  (let* ((secret (cmacs-rig-spawn-field
                  rig :title (concat cmacs-rig-image-tests--secret "-win")
                  :app-id "rig-private-app" :text "private"))
         (public (cmacs-rig-spawn-field rig :title "rig-public-image"
                                        :app-id "rig-public-app"
                                        :text "public"))
         (refused (cmacs-rig-eval
                   rig (cmacs-rig-image-tests--capture-form
                        (cmacs-rig-image-tests--geometry rig secret)))))
    (cmacs-rig-shot rig "images-excluded-window-on-screen")
    (should (eq (car refused) 'refused))
    ;; The refusal is the fixed sentence: it names no window.
    (should-not (string-search cmacs-rig-image-tests--secret
                               (format "%s" refused)))
    ;; Close the excluded window; the public one is capturable.  On a
    ;; binary without this round's encoder that is an `error' naming the
    ;; encoder -- still not a refusal, which is the point here.
    (cmacs-rig-close-client rig (plist-get secret :id))
    (cmacs-rig-image-tests--sleep 0.3)
    (let ((public-result (cmacs-rig-eval
                          rig (cmacs-rig-image-tests--capture-form
                               (cmacs-rig-image-tests--geometry rig public)))))
      (should-not (eq (car public-result) 'refused))
      (when (eq (car public-result) 'captured)
        (should (> (cadr public-result) 100))))))

(defun cmacs-rig-image-tests--install-fake-model (rig answer)
  "Replace RIG's model by one that records its images and answers ANSWER.
What was sent is kept in the child's `cmacs-rig-child-asked' as
\(PROMPT IMAGE-SIZES IMAGE-PREFIXES)."
  (cmacs-rig-eval
   rig `(progn
          (require 'cmacs-ai)
          (require 'cmacs-ai-vision)
          (require 'cmacs-deixis-ask)
          (defvar cmacs-rig-child-asked nil)
          (setq cmacs-rig-child-asked nil
                cmacs-ai-vision-providers '((rig-fake . t))
                cmacs-deixis-ask-provider 'rig-fake
                cmacs-deixis-ask-images t
                cmacs-deixis-ask-toast nil)
          (advice-add 'cmacs-ai--ensure :override #'ignore
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-make-session :override
                      (lambda (&rest _) (cons 'rig-client 'rig-session))
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-chat-stream :override
                      (lambda (_session prompt callback &rest rest)
                        (let ((images (nth 1 rest)))
                          (push (list prompt
                                      (mapcar (lambda (i)
                                                (length (plist-get i :data)))
                                              images)
                                      (mapcar (lambda (i)
                                                (substring
                                                 (plist-get i :data) 1 4))
                                              images))
                                cmacs-rig-child-asked))
                        ;; The MCP `eval' tool evaluates with dynamic
                        ;; binding: the callback goes as the timer's
                        ;; argument rather than through a closure.
                        (run-at-time 0.1 nil
                                     (lambda (callback)
                                       (funcall callback
                                                (list :delta ,answer))
                                       (funcall callback
                                                (list :end :text ,answer)))
                                     callback)
                        t)
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-chat-cancel :override #'ignore
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-free-session :override #'ignore
                      '((name . cmacs-rig-fake)))
          t)))

(cmacs-rig-image-tests--deftest images-what-is-that
  "\"What is that\" over another window sends a PNG crop with the question."
  (skip-unless (cmacs-rig-field-client))
  (unless (cmacs-rig-eval rig '(and (fboundp 'cmacs-ai-png-encode)
                                    (fboundp 'cmacs-ai-image-parts)
                                    t))
    (ert-skip "the child's binary predates image input (no \
cmacs-ai-png-encode); rebuild and run again"))
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-image-target"
                                       :text "the quick brown fox"))
         (g (cmacs-rig-image-tests--geometry rig field)))
    (cmacs-rig-image-tests--install-fake-model rig "It is a text field.")
    ;; On the window, inside the part the client draws.
    (cmacs-rig-eval rig `(gowl-pointer-warp ,(+ (nth 0 g) 40)
                                            ,(+ (nth 1 g) 40)))
    (cmacs-rig-image-tests--sleep 0.3)
    (cmacs-rig-shot rig "images-pointer-on-target")
    ;; As the person at the keyboard asks it: the door by hand.
    (cmacs-rig-do rig '(progn (require 'cmacs-deixis-ask)
                              (cmacs-deixis-ask-at-pointer "what is that")
                              t))
    (should (cmacs-rig-wait-for rig 'cmacs-rig-child-asked 30))
    (let* ((asked (car (cmacs-rig-eval rig 'cmacs-rig-child-asked)))
           (sizes (nth 1 asked)))
      (should (string-match-p "what is that" (nth 0 asked)))
      (should (= (length sizes) 1))
      ;; A real PNG of a real crop: more than a header, less than a
      ;; full-screen raw frame.
      (should (equal (nth 2 asked) '("PNG")))
      (should (< 200 (car sizes) (* 4 1024 1024)))
      ;; The window's title stays home.
      (should-not (string-search "rig-image-target" (nth 0 asked))))))

(provide 'cmacs-rig-image-tests)

;;; cmacs-rig-image-tests.el ends here
