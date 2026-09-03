;;; cmacs-ai-view-tests.el --- Tests for the screen-context layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What the model is told about the user's screen (cmacs-ai-view.el).
;;
;; Everything here is pure Elisp: no display beyond batch's own frame, no
;; model call, no build flags.  The interesting assertions are the
;; negative ones -- that the AI surfaces never appear in their own
;; context, and that the inventory does NOT carry buffer text, which is
;; the entire cost argument for the feature working the way it does.
;;
;; Note the deliberate absence of `cmacs-feature-p' guards: these tests
;; must run in a per-file batch run where that function is not defined
;; (see the ERT skip trap in the cmacs notes).

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'cmacs-ai-view)
;; Required, not merely declared: tests `let'-bind defcustoms from
;; these, and without the definitions known to be special at compile
;; time the bindings are lexical and silently do nothing.
(require 'cmacs-ai-target nil t)
(require 'cmacs-ai-targets nil t)

;;;; Helpers -----------------------------------------------------------

(defvar cmacs-ai-view-tests--buffers nil)

(defun cmacs-ai-view-tests--buffer (name text &optional mode)
  "Make a temporary buffer NAME holding TEXT in MODE, killed after the test."
  (let ((buf (generate-new-buffer name)))
    (push buf cmacs-ai-view-tests--buffers)
    (with-current-buffer buf
      (insert text)
      (goto-char (point-min))
      (when mode (funcall mode)))
    buf))

(defmacro cmacs-ai-view-tests--with-screen (specs &rest body)
  "Show each (NAME TEXT [MODE]) in SPECS in its own window, then run BODY.

The LAST spec ends up in the selected window, standing in for the chat
the caller would be typing into -- which is the arrangement every one
of these functions is actually used in."
  (declare (indent 1) (debug t))
  `(let ((cmacs-ai-view-tests--buffers nil)
         (cmacs-ai-view--last nil)
         (height (frame-height)))
     (unwind-protect
         (save-window-excursion
           ;; Batch starts on a frame too short to split more than a
           ;; couple of times, and several of these need four windows.
           (ignore-errors (set-frame-height (selected-frame) 60))
           (delete-other-windows)
           (let ((bufs (mapcar (lambda (spec)
                                 (apply #'cmacs-ai-view-tests--buffer spec))
                               ,specs))
                 (first t))
             (dolist (buf bufs)
               (unless first
                 (select-window (split-window-below)))
               (setq first nil)
               (switch-to-buffer buf))
             (ignore bufs)
             ,@body))
       (ignore-errors (set-frame-height (selected-frame) height))
       (mapc #'kill-buffer
             (seq-filter #'buffer-live-p cmacs-ai-view-tests--buffers)))))

(define-derived-mode cmacs-ai-view-tests--fake-chat-mode fundamental-mode
  "FakeChat"
  "Stands in for a chat surface without loading one.")

;;;; Which buffers -----------------------------------------------------

(ert-deftest cmacs-ai-view-sees-the-other-windows ()
  "Every visible buffer is reported, and the caller's own is not.

The caller is the chat asking the question; a chat that listed itself
would answer questions about the question."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "alpha body") ("beta.txt" "beta body") ("chat" "chat"))
    (let ((names (mapcar #'buffer-name (cmacs-ai-view-buffers))))
      (should (member "alpha.txt" names))
      (should (member "beta.txt" names))
      (should-not (member "chat" names)))))

(ert-deftest cmacs-ai-view-include-current-keeps-the-caller ()
  "The MCP tool wants the whole screen, including whatever is selected."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "alpha") ("chat" "chat"))
    (should (member "chat" (mapcar #'buffer-name (cmacs-ai-view-buffers t))))))

(ert-deftest cmacs-ai-view-ignores-buffers-nobody-can-see ()
  (cmacs-ai-view-tests--with-screen '(("alpha.txt" "alpha") ("chat" "chat"))
    (let ((hidden (cmacs-ai-view-tests--buffer "hidden.txt" "hidden")))
      (should-not (memq hidden (cmacs-ai-view-buffers t))))))

(ert-deftest cmacs-ai-view-excludes-ai-surfaces-by-mode ()
  "An AI surface is never context, however it got on screen."
  (let ((cmacs-ai-view-exclude-modes '(cmacs-ai-view-tests--fake-chat-mode)))
    (cmacs-ai-view-tests--with-screen
        '(("alpha.txt" "alpha")
          ("pretend-chat" "chat" cmacs-ai-view-tests--fake-chat-mode)
          ("caller" "caller"))
      (let ((names (mapcar #'buffer-name (cmacs-ai-view-buffers))))
        (should (member "alpha.txt" names))
        (should-not (member "pretend-chat" names))))))

(ert-deftest cmacs-ai-view-excludes-by-name-regexp ()
  (let ((cmacs-ai-view-exclude-name-regexps '("\\`secret")))
    (cmacs-ai-view-tests--with-screen
        '(("secret.txt" "shhh") ("alpha.txt" "alpha") ("caller" "caller"))
      (let ((names (mapcar #'buffer-name (cmacs-ai-view-buffers))))
        (should (member "alpha.txt" names))
        (should-not (member "secret.txt" names))))))

(ert-deftest cmacs-ai-view-one-entry-per-buffer ()
  "The same file in two windows is one thing the user is looking at."
  (cmacs-ai-view-tests--with-screen '(("alpha.txt" "alpha") ("caller" "caller"))
    (let ((alpha (get-buffer "alpha.txt")))
      (select-window (split-window-below))
      (switch-to-buffer alpha)
      (select-window (get-buffer-window "caller"))
      (should (= 1 (cl-count alpha (cmacs-ai-view-buffers)))))))

(ert-deftest cmacs-ai-view-falls-back-to-the-last-selected ()
  "A chat filling the frame still knows what it was opened from.

Without this the common laptop case -- one window, chat in it -- has no
context at all, which is exactly when the user is most likely to say
\"here\"."
  (let ((cmacs-ai-view-exclude-modes '(cmacs-ai-view-tests--fake-chat-mode))
        (cmacs-ai-view-tests--buffers nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((alpha (cmacs-ai-view-tests--buffer "alpha.txt" "alpha"))
                (chat (cmacs-ai-view-tests--buffer
                       "pretend-chat" "chat"
                       #'cmacs-ai-view-tests--fake-chat-mode)))
            (switch-to-buffer alpha)
            ;; The hook is what a real session runs; call it directly
            ;; because batch does not redisplay.
            (cmacs-ai-view--record-selection)
            (switch-to-buffer chat)
            (cmacs-ai-view--record-selection)
            (should (eq alpha cmacs-ai-view--last))
            (should (equal (list alpha) (cmacs-ai-view-buffers)))))
      (mapc #'kill-buffer
            (seq-filter #'buffer-live-p cmacs-ai-view-tests--buffers)))))

(ert-deftest cmacs-ai-view-never-remembers-an-ai-surface ()
  (let ((cmacs-ai-view-exclude-modes '(cmacs-ai-view-tests--fake-chat-mode))
        (cmacs-ai-view--last nil))
    (with-temp-buffer
      (cmacs-ai-view-tests--fake-chat-mode)
      (cmacs-ai-view--record-selection)
      (should-not cmacs-ai-view--last))))

;;;; The inventory -----------------------------------------------------

(ert-deftest cmacs-ai-view-inventory-names-what-is-visible ()
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "one\ntwo\nthree\n") ("caller" "caller"))
    (let ((text (cmacs-ai-view-inventory)))
      (should text)
      (should (string-match-p "alpha\\.txt" text))
      (should (string-match-p "lines" text))
      (should (string-match-p "point on line" text)))))

(ert-deftest cmacs-ai-view-inventory-carries-no-buffer-text ()
  "The listing is a listing.  The text is what a tool fetches.

This is the whole cost argument: an inventory rides every turn, so it
has to stay a few hundred bytes however large the file is."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "DISTINCTIVE-BODY-TEXT\n") ("caller" "caller"))
    (should-not (string-match-p "DISTINCTIVE-BODY-TEXT"
                                (cmacs-ai-view-inventory)))))

(ert-deftest cmacs-ai-view-inventory-notes-an-active-region ()
  "A highlighted region is the strongest possible statement of \"this\".

`transient-mark-mode' is bound explicitly because batch turns it off
and `region-active-p' -- which is the right predicate in a real
session -- is nil without it."
  (let ((transient-mark-mode t))
    (cmacs-ai-view-tests--with-screen
        '(("alpha.txt" "one\ntwo\nthree\n") ("caller" "caller"))
      (with-current-buffer "alpha.txt"
        (goto-char (point-min))
        (push-mark (point-max) t t))
      (should (string-match-p "REGION ACTIVE" (cmacs-ai-view-inventory))))))

(ert-deftest cmacs-ai-view-inventory-is-bounded ()
  "Past a handful of windows the listing stops telling anyone anything.
The excess is counted, not silently dropped."
  (let ((cmacs-ai-view-max-buffers 2))
    (cmacs-ai-view-tests--with-screen
        '(("a.txt" "a") ("b.txt" "b") ("c.txt" "c") ("d.txt" "d")
          ("caller" "caller"))
      (let* ((text (cmacs-ai-view-inventory))
             (entries (seq-filter (lambda (line)
                                    (string-match-p "\\`[0-9]+\\. " line))
                                  (split-string text "\n"))))
        (should (string-match-p "2 more visible buffer" text))
        (should (= 2 (length entries)))))))

(ert-deftest cmacs-ai-view-inventory-is-nil-with-nothing-to-say ()
  (let ((cmacs-ai-view-exclude-name-regexps '("")))
    (cmacs-ai-view-tests--with-screen '(("alpha.txt" "a") ("caller" "caller"))
      (should-not (cmacs-ai-view-inventory)))))

;;;; The standing hint --------------------------------------------------

(ert-deftest cmacs-ai-view-hint-differs-by-tool-access ()
  "Telling a model to use tools it does not have is worse than silence.

The `tools' hint names the tools; the `inline' hint says the text is
attached instead.  Getting this backwards is the difference between the
feature working and a polite refusal."
  (let ((tools (cmacs-ai-view-hint 'tools))
        (inline (cmacs-ai-view-hint 'inline)))
    (should (string-match-p "get_buffer_content" tools))
    (should (string-match-p "current_view" tools))
    (should-not (string-match-p "get_buffer_content" inline))
    (should (string-match-p "included below" inline))
    ;; Both have to say the thing the whole feature exists to say.
    (dolist (text (list tools inline))
      (should (string-match-p "here" text))
      (should (string-match-p "not this conversation" text)))))

(ert-deftest cmacs-ai-view-hint-respects-the-off-switch ()
  "One check in one place, rather than a condition at every call site."
  (let ((cmacs-ai-view-attach-mode 'off))
    (should-not (cmacs-ai-view-hint 'tools))
    (should-not (cmacs-ai-view-hint 'inline))))

;;;; The per-turn block -------------------------------------------------

(ert-deftest cmacs-ai-view-turn-block-is-silent-when-off ()
  (let ((cmacs-ai-view-attach-mode 'off))
    (cmacs-ai-view-tests--with-screen '(("alpha.txt" "a") ("caller" "caller"))
      (should-not (car (cmacs-ai-view-turn-block 'tools))))))

(ert-deftest cmacs-ai-view-turn-block-repeats-itself-only-once ()
  "An unchanged screen collapses to one line.

The model still needs to know the context is standing; it does not
need to be told twice, and a listing re-sent every turn is a listing
paid for every turn."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "one\ntwo\n") ("caller" "caller"))
    (let* ((first (cmacs-ai-view-turn-block 'tools))
           (again (cmacs-ai-view-turn-block 'tools (cdr first))))
      (should (string-match-p "alpha\\.txt" (car first)))
      (should (string-match-p "unchanged" (car again)))
      (should-not (string-match-p "alpha\\.txt" (car again))))))

(ert-deftest cmacs-ai-view-turn-block-notices-an-edit ()
  "Same windows, changed text: the model has to be told again.

Keying on the window layout alone would leave it reasoning about a
version of the file that no longer exists."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "one\ntwo\n") ("caller" "caller"))
    (let ((first (cmacs-ai-view-turn-block 'tools)))
      (with-current-buffer "alpha.txt"
        (goto-char (point-max))
        (insert "three\n"))
      (should (string-match-p "alpha\\.txt"
                              (car (cmacs-ai-view-turn-block
                                    'tools (cdr first))))))))

(ert-deftest cmacs-ai-view-turn-block-inlines-only-without-tools ()
  (skip-unless (fboundp 'cmacs-ai-target-at))
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "DISTINCTIVE-BODY-TEXT\n") ("caller" "caller"))
    (should-not (string-match-p "DISTINCTIVE-BODY-TEXT"
                                (car (cmacs-ai-view-turn-block 'tools))))
    (should (string-match-p "DISTINCTIVE-BODY-TEXT"
                            (car (cmacs-ai-view-turn-block 'inline))))))

(ert-deftest cmacs-ai-view-inline-is-bounded ()
  (skip-unless (fboundp 'cmacs-ai-target-at))
  (let ((cmacs-ai-view-inline-max-chars 200))
    (cmacs-ai-view-tests--with-screen
        `(("big.txt" ,(make-string 5000 ?x)) ("caller" "caller"))
      (let ((text (car (cmacs-ai-view-turn-block 'inline))))
        (should (< (length text) 1500))
        (should (string-match-p "elided" text))))))

;;;; Full context -------------------------------------------------------

(ert-deftest cmacs-ai-view-context-goes-through-the-resolvers ()
  "An active region wins over the buffer, which proves the target layer
is reached rather than reimplemented -- and with it every surface the
menu already understands."
  (skip-unless (fboundp 'cmacs-ai-target-at))
  (let ((transient-mark-mode t))
    (cmacs-ai-view-tests--with-screen
        '(("alpha.txt" "KEEP-THIS\nDROP-THAT\n") ("caller" "caller"))
      (with-current-buffer "alpha.txt"
        (goto-char (point-min))
        (push-mark (line-end-position) t t))
      (let ((text (cmacs-ai-view-context)))
        (should (string-match-p "KEEP-THIS" text))
        (should-not (string-match-p "DROP-THAT" text))))))

(ert-deftest cmacs-ai-view-report-covers-the-whole-screen ()
  "The MCP tool answers about the screen, not about a caller's window."
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "alpha") ("caller" "caller"))
    (let ((text (cmacs-ai-view-report)))
      (should (string-match-p "alpha\\.txt" text))
      (should (string-match-p "caller" text)))))

(ert-deftest cmacs-ai-view-report-says-so-when-there-is-nothing ()
  (let ((cmacs-ai-view-exclude-name-regexps '("")))
    (should (string-match-p "Nothing is visible" (cmacs-ai-view-report)))))

;;;; Forcing it ---------------------------------------------------------

(ert-deftest cmacs-ai-view-attach-refuses-outside-a-compose-buffer ()
  (with-temp-buffer
    (should-error (cmacs-ai-view-attach) :type 'user-error)))

(ert-deftest cmacs-ai-view-attach-writes-into-the-compose-region ()
  "Visible and editable, so it can be trimmed before it is sent."
  (skip-unless (fboundp 'cmacs-ai-target-at))
  (cmacs-ai-view-tests--with-screen
      '(("alpha.txt" "DISTINCTIVE-BODY-TEXT\n") ("caller" "caller"))
    (with-current-buffer "caller"
      (setq-local cmacs-ai-chat--compose-marker (point-max-marker))
      (let ((before (marker-position cmacs-ai-chat--compose-marker)))
        (cmacs-ai-view-attach)
        (let ((added (buffer-substring-no-properties before (point-max))))
          (should (string-match-p "DISTINCTIVE-BODY-TEXT" added))
          (should (string-match-p "begin_example" added)))))))

(provide 'cmacs-ai-view-tests)

;;; cmacs-ai-view-tests.el ends here
