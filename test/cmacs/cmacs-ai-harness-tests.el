;;; cmacs-ai-harness-tests.el --- Tests for cmacs-ai-harness -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What can be asserted without a model behind it: that the bridge builds
;; and tears down, that the buffer's prompt region behaves, that the
;; export naming is what it claims, and that completion comes from the
;; library rather than from a regexp here.
;;
;; Guarded with `fboundp' rather than `cmacs-feature-p', which is void in
;; a per-file test run and would skip the whole suite silently.

;;; Code:

(require 'ert)
(require 'cl-lib)

(when (locate-library "cmacs-ai-harness")
  (require 'cmacs-ai-harness nil t))

(defmacro cmacs-ai-harness-tests--with-session (&rest body)
  "Run BODY in a live harness buffer, freed afterwards.

Uses `ollama' because building the client must not need a key or a
network: nothing here sends anything, and a provider that refused to be
constructed would make every test below skip for the wrong reason."
  (declare (indent 0))
  `(let ((buf (cmacs-ai-harness--start 'ollama nil temporary-file-directory)))
     (unwind-protect
         (with-current-buffer buf ,@body)
       (with-current-buffer buf
         (when cmacs-ai-harness--handle
           (ignore-errors (cmacs-ai-harness-free cmacs-ai-harness--handle))
           (setq cmacs-ai-harness--handle nil)))
       (kill-buffer buf))))

(ert-deftest cmacs-ai-harness-entry-points-are-commands ()
  "The three M-x entry points exist and are interactive."
  (skip-unless (fboundp 'cmacs-ai-harness))
  (should (commandp 'cmacs-ai-harness))
  (should (commandp 'cmacs-ai-harness-with-provider))
  (should (commandp 'cmacs-ai-harness-with-provider-in-directory)))

(ert-deftest cmacs-ai-harness-bridge-is-bound ()
  "Every DEFUN the Elisp side calls is actually compiled in.

A `declare-function' satisfies the byte-compiler and loads nothing, so a
missing DEFUN is a void-function at the first keystroke rather than a
build error."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (dolist (f '(cmacs-ai-harness-new
               cmacs-ai-harness-free
               cmacs-ai-harness-set-callback
               cmacs-ai-harness-send-input
               cmacs-ai-harness-cancel
               cmacs-ai-harness-clear
               cmacs-ai-harness-busy-p
               cmacs-ai-harness-activity
               cmacs-ai-harness-block-count
               cmacs-ai-harness-block-at
               cmacs-ai-harness-block-render
               cmacs-ai-harness-set-expanded
               cmacs-ai-harness-export
               cmacs-ai-harness-export-extension
               cmacs-ai-harness-complete
               cmacs-ai-harness-commands
               cmacs-ai-harness-working-directory
               cmacs-ai-harness-set-working-directory
               cmacs-ai-harness-provider-name
               cmacs-ai-harness-model))
    (should (fboundp f))))

(ert-deftest cmacs-ai-harness-rejects-an-unknown-provider ()
  "A typo is an error, not a silent fallback to Claude.

ai_provider_type_from_string() defaults rather than failing, which for a
typed provider name means the run happens -- and bills -- somewhere the
user did not ask for."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (should-error (cmacs-ai-harness-new 'cluade nil nil)))

(ert-deftest cmacs-ai-harness-starts-in-the-directory-it-was-given ()
  "The working directory is the agent's project, so it must be exact."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (should (equal (file-name-as-directory
                    (cmacs-ai-harness-working-directory
                     cmacs-ai-harness--handle))
                   (file-name-as-directory
                    (expand-file-name temporary-file-directory))))))

(ert-deftest cmacs-ai-harness-prompt-region-round-trips ()
  "The prompt region is editable and reads back what was put in it.

The transcript above it is read-only by text property, so a set/get that
worked by `buffer-string' would pass while the user could not type."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (cmacs-ai-harness-set-prompt "refactor the parser")
    (should (equal (cmacs-ai-harness-prompt-string) "refactor the parser"))
    (cmacs-ai-harness-set-prompt "")
    (should (equal (cmacs-ai-harness-prompt-string) ""))))

(ert-deftest cmacs-ai-harness-prompt-boundary-is-where-it-claims ()
  "The separator is read-only; the prompt after it is not.

Asserted as the text property rather than by trying an insertion: with no
blocks yet, `point-min' sits *before* the protected run, and inserting
there is allowed by ordinary front-stickiness -- so an insertion test
passes for a reason that has nothing to do with the boundary.  What
matters is that the marker glyph cannot be edited and the character after
it can, which is exactly what these two lookups say.

The `rear-nonsticky' half is the load-bearing one: without it the prompt
inherits read-only from the separator and the buffer cannot be typed in
at all."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((marker-pos (1- (marker-position cmacs-ai-harness--prompt-marker))))
      (should (get-text-property marker-pos 'read-only))
      (should (get-text-property marker-pos 'rear-nonsticky)))
    ;; Typing at the prompt works.
    (goto-char (point-max))
    (insert "typed")
    (should (equal (cmacs-ai-harness-prompt-string) "typed"))))

(ert-deftest cmacs-ai-harness-kill-clears-the-prompt-when-idle ()
  "One key for cancel-or-clear, and idle means clear."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (cmacs-ai-harness-set-prompt "half a thought")
    (should-not (cmacs-ai-harness-busy-p cmacs-ai-harness--handle))
    (cmacs-ai-harness-kill)
    (should (equal (cmacs-ai-harness-prompt-string) ""))))

(ert-deftest cmacs-ai-harness-export-name-says-harness ()
  "The export file name mirrors a chat's, with `harness' in it.

The point of matching the chat format is that the two sort together in
one directory; the point of the word is telling them apart."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((name (cmacs-ai-harness--default-export-name 'org)))
      (should (string-match-p "harness" name))
      (should (string-suffix-p ".org" name))
      ;; YYMMDD-HHMMSS-harness-PROVIDER.org
      (should (string-match-p "\\`[0-9]\\{6\\}-[0-9]\\{6\\}-harness-" name)))
    (should (string-suffix-p
             ".md" (cmacs-ai-harness--default-export-name 'markdown)))))

(ert-deftest cmacs-ai-harness-export-extension-comes-from-the-library ()
  "So an Org export and ai-tui's /export org cannot disagree."
  (skip-unless (fboundp 'cmacs-ai-harness-export-extension))
  (should (equal (cmacs-ai-harness-export-extension 'markdown) "md"))
  (should (equal (cmacs-ai-harness-export-extension 'org) "org"))
  (should (equal (cmacs-ai-harness-export-extension 'text) "txt"))
  (should-error (cmacs-ai-harness-export-extension 'mardkown)))

(ert-deftest cmacs-ai-harness-completion-range-comes-from-the-library ()
  "Not from a regexp here.

Recomputing the range in Elisp -- \"the word before point\" -- disagrees
the first time somebody completes @src/co, where the token has a slash
in it.  Asserting the range, not just the candidates, is what catches
that."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((result (cmacs-ai-harness-complete cmacs-ai-harness--handle "/he" 3)))
      (should result)
      (pcase-let ((`(,start ,end ,candidates) result))
        ;; Byte offsets bounding "he", after the slash.
        (should (= start 1))
        (should (= end 3))
        (should (cl-find "help" candidates
                         :key #'car :test #'equal))))))

(ert-deftest cmacs-ai-harness-knows-the-builtin-commands ()
  "The built-ins are the library's, so /help can be answered here."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((names (mapcar #'car (cmacs-ai-harness-commands
                                cmacs-ai-harness--handle))))
      (dolist (n '("help" "clear" "export" "cwd"))
        (should (member n names))))))

(ert-deftest cmacs-ai-harness-actions-are-scoped-to-the-mode ()
  "The Harness menu group costs nothing in any other buffer."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (skip-unless (fboundp 'cmacs-ai-register-action))
  (with-temp-buffer
    (should-not (cmacs-ai-harness--live-p)))
  (cmacs-ai-harness-tests--with-session
    (should (cmacs-ai-harness--live-p))))

(ert-deftest cmacs-ai-harness-freeing-twice-is-not-an-error ()
  "The kill-buffer hook and an explicit free must not fight."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (let ((h (cmacs-ai-harness-new 'ollama nil temporary-file-directory)))
    (should (cmacs-ai-harness-free h))
    (should-not (cmacs-ai-harness-free h))))

(provide 'cmacs-ai-harness-tests)

;;; cmacs-ai-harness-tests.el ends here
