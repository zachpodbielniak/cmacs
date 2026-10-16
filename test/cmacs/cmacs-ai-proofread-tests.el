;;; cmacs-ai-proofread-tests.el --- Tests for the proofread AI action  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Fix spelling & grammar": the textops operation, its two menu
;; actions, and the asynchronous in-place variant.  No model is called:
;; the cmacs-ai C entry points are stubbed, and the stub of
;; `cmacs-ai-chat-stream' hands its callback back to the test, so a
;; test decides when -- and whether -- the answer "arrives".
;;
;; What would break silently without these:
;;
;;   - the action not being registered (a right-click menu with no
;;     spelling entry looks exactly like one that was never written);
;;   - the in-place variant overwriting text the user edited while the
;;     model was thinking;
;;   - a model's fences or quotes being pasted into someone's prose;
;;   - a failure signalling out of a stream callback instead of
;;     reaching the caller.
;;
;; Stubs of C DEFUNs take &rest (see the ERT stub arity trap).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-ai-target)
(require 'cmacs-ai-actions)
(require 'cmacs-ai-menu)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-proofread)

(defmacro cmacs-ai-proofread-tests--with-model (var &rest body)
  "Run BODY with cmacs-ai stubbed; VAR collects (CALLBACK PROMPT SYSTEM).
The stream callback is NOT called by the stub: BODY calls it, which is
how a test controls when the answer lands."
  (declare (indent 1))
  `(let ((,var nil)
         (system-seen nil))
     (cl-letf (((symbol-function 'cmacs-ai--ensure) (lambda (&rest _) t))
               ((symbol-function 'cmacs-ai-make-session)
                (lambda (&rest args)
                  (setq system-seen (nth 2 args))
                  (cons 'client 'session)))
               ((symbol-function 'cmacs-ai-free-session) (lambda (&rest _) nil))
               ((symbol-function 'cmacs-ai-chat-stream)
                (lambda (&rest args)
                  (push (list (nth 2 args) (nth 1 args) system-seen) ,var)
                  nil)))
       ,@body)))

(defun cmacs-ai-proofread-tests--answer (call &rest deltas)
  "Deliver DELTAS then :end through the stubbed stream CALL."
  (let ((cb (car call)))
    (dolist (d deltas) (funcall cb (list :delta d)))
    (funcall cb (list :end))))

;;;; Registration -------------------------------------------------------

(ert-deftest cmacs-ai-proofread-test-is-a-textops-operation ()
  "The operation exists and reads its prompt through the defcustom."
  (let ((spec (alist-get 'proofread cmacs-ai-textops--specs)))
    (should spec)
    (should (eq (plist-get spec :system) 'cmacs-ai-proofread-system-prompt))
    (should (string-match-p "spelling" (plist-get spec :instruction))))
  (should (string-match-p "change[ \n]NOTHING[ \n]else"
                          cmacs-ai-proofread-system-prompt))
  (should (commandp #'cmacs-ai-proofread))
  (should (commandp #'cmacs-ai-proofread-in-place)))

(ert-deftest cmacs-ai-proofread-test-both-actions-are-on-the-menu ()
  "Right-click -> AI offers both, for prose in an editable buffer."
  (should (gethash 'cmacs-ai-proofread cmacs-ai--actions))
  (should (gethash 'cmacs-ai-proofread-in-place cmacs-ai--actions))
  (cl-letf (((symbol-function 'cmacs-ai-supported-p) (lambda (&rest _) t)))
   (with-temp-buffer
    (insert "Thsi sentnce has erors.")
    (let* ((target (cmacs-ai-target-create
                    :kind 'region :label "region"
                    :text (buffer-string)
                    :buffer (current-buffer)
                    :bounds (cons (point-min) (point-max))))
           (names (mapcar (lambda (a) (plist-get a :name))
                          (apply #'append
                                 (mapcar #'cdr
                                         (cmacs-ai-actions-for target))))))
      (should (memq 'cmacs-ai-proofread names))
      (should (memq 'cmacs-ai-proofread-in-place names))
      ;; Read-only: the result-window one still applies, the in-place
      ;; one does not.
      (setq buffer-read-only t)
      (let ((ro-names (mapcar (lambda (a) (plist-get a :name))
                              (apply #'append
                                     (mapcar #'cdr
                                             (cmacs-ai-actions-for target))))))
        (should (memq 'cmacs-ai-proofread ro-names))
        (should-not (memq 'cmacs-ai-proofread-in-place ro-names)))))))

(ert-deftest cmacs-ai-proofread-test-keys ()
  "f shows the correction, F applies it.
The map is an autoloaded defvar, so a dumped Emacs carries the copy
from loaddefs, which a later `require' does not replace.  Read the
definition from THIS tree's source and evaluate its value instead."
  (let ((map nil))
    (with-temp-buffer
      (insert-file-contents (locate-library "cmacs-ai-menu.el"))
      (goto-char (point-min))
      (re-search-forward "^(defvar cmacs-ai-menu-command-map")
      (goto-char (match-beginning 0))
      (setq map (eval (nth 2 (read (current-buffer))) t)))
    (should (eq (lookup-key map (kbd "f")) #'cmacs-ai-proofread))
    (should (eq (lookup-key map (kbd "F")) #'cmacs-ai-proofread-in-place))))

;;;; The engine ---------------------------------------------------------

(ert-deftest cmacs-ai-proofread-test-text-streams-to-the-callback ()
  "Deltas are joined and handed over once, on :end."
  (cmacs-ai-proofread-tests--with-model calls
    (let (got)
      (cmacs-ai-proofread-text "teh cat" (lambda (r e) (push (list r e) got)))
      (should (= 1 (length calls)))
      (should (equal (nth 1 (car calls)) "teh cat"))
      (should (equal (nth 2 (car calls)) cmacs-ai-proofread-system-prompt))
      (should-not got)                  ; nothing until the model answers
      (cmacs-ai-proofread-tests--answer (car calls) "the " "cat")
      (should (equal got '(("the cat" nil))))
      ;; A second :end must not call back twice.
      (funcall (car (car calls)) '(:end))
      (should (= 1 (length got))))))

(ert-deftest cmacs-ai-proofread-test-non-streaming-provider ()
  "A provider that only answers in :end is still heard."
  (cmacs-ai-proofread-tests--with-model calls
    (let (got)
      (cmacs-ai-proofread-text "teh" (lambda (r _e) (setq got r)))
      (funcall (car (car calls)) '(:end :text "the"))
      (should (equal got "the")))))

(ert-deftest cmacs-ai-proofread-test-failures-reach-the-caller ()
  "A stream error and a failure to start are both callbacks, not signals."
  (cmacs-ai-proofread-tests--with-model calls
    (let (got)
      (cmacs-ai-proofread-text "x" (lambda (r e) (setq got (list r e))))
      (funcall (car (car calls)) '(:error "rate limited"))
      (should (equal got '(nil "rate limited")))))
  (cl-letf (((symbol-function 'cmacs-ai--ensure)
             (lambda (&rest _) (user-error "cmacs-ai not built"))))
    (let (got)
      (should-not (cmacs-ai-proofread-text "x"
                                           (lambda (r e) (setq got (list r e)))))
      (should (null (car got)))
      (should (string-match-p "not built" (cadr got))))))

(ert-deftest cmacs-ai-proofread-test-strips-what-models-add ()
  "Fences and quotes the original did not have are removed."
  (should (equal (cmacs-ai-proofread--strip-wrapping
                  "```\nThe cat sat.\n```" "Teh cat sat.")
                 "The cat sat."))
  (should (equal (cmacs-ai-proofread--strip-wrapping
                  "```text\nThe cat sat.\n```\n" "Teh cat sat.")
                 "The cat sat."))
  (should (equal (cmacs-ai-proofread--strip-wrapping
                  "\"The cat sat.\"" "Teh cat sat.")
                 "The cat sat."))
  ;; ...but kept when the original had them.
  (should (equal (cmacs-ai-proofread--strip-wrapping
                  "\"Quoted,\" she said." "\"Qouted,\" she said.")
                 "\"Quoted,\" she said."))
  ;; Trailing newline only when the original ended with one.
  (should (equal (cmacs-ai-proofread--strip-wrapping "Fixed.\n\n" "Fxied.")
                 "Fixed."))
  (should (equal (cmacs-ai-proofread--strip-wrapping "Fixed.\n" "Fxied.\n")
                 "Fixed.\n")))

;;;; In place -----------------------------------------------------------

(ert-deftest cmacs-ai-proofread-test-in-place-is-one-undo-step ()
  "The region is replaced when the answer lands, and one undo restores it."
  (cmacs-ai-proofread-tests--with-model calls
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "Before. Teh cat sat. After.")
      (undo-boundary)
      (cmacs-ai-proofread-in-place 9 21)
      ;; Asynchronous: nothing has changed yet.
      (should (equal (buffer-string) "Before. Teh cat sat. After."))
      (cmacs-ai-proofread-tests--answer (car calls) "The cat sat.")
      (should (equal (buffer-string) "Before. The cat sat. After."))
      ;; One change group: skip the boundary at the head of the list
      ;; and undo exactly one record.
      (let ((list buffer-undo-list))
        (while (and list (null (car list))) (setq list (cdr list)))
        (primitive-undo 1 list))
      (should (equal (buffer-string) "Before. Teh cat sat. After.")))))

(ert-deftest cmacs-ai-proofread-test-in-place-never-overwrites-new-edits ()
  "Text edited while the model worked is left alone; the fix is killed."
  (cmacs-ai-proofread-tests--with-model calls
    (with-temp-buffer
      (insert "Teh cat sat.")
      (let ((kill-ring nil))
        (cmacs-ai-proofread-in-place (point-min) (point-max))
        (goto-char (point-min))
        (insert "My own edit. ")
        (cmacs-ai-proofread-tests--answer (car calls) "The cat sat.")
        (should (equal (buffer-string) "My own edit. Teh cat sat."))
        (should (equal (car kill-ring) "The cat sat."))))))

(ert-deftest cmacs-ai-proofread-test-in-place-follows-the-text ()
  "Edits elsewhere in the buffer do not stop or misplace the fix."
  (cmacs-ai-proofread-tests--with-model calls
    (with-temp-buffer
      (insert "Head. Teh end.")
      (cmacs-ai-proofread-in-place 7 15)
      (goto-char (point-min))
      (insert "New first line.\n")
      (cmacs-ai-proofread-tests--answer (car calls) "The end.")
      (should (equal (buffer-string) "New first line.\nHead. The end.")))))

(ert-deftest cmacs-ai-proofread-test-in-place-refuses-read-only ()
  "A read-only buffer is refused before the model is asked."
  (cmacs-ai-proofread-tests--with-model calls
    (with-temp-buffer
      (insert "Teh")
      (setq buffer-read-only t)
      (should-error (cmacs-ai-proofread-in-place (point-min) (point-max))
                    :type 'user-error)
      (should-not calls))))

(provide 'cmacs-ai-proofread-tests)

;;; cmacs-ai-proofread-tests.el ends here
