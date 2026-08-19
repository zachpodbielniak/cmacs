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

(ert-deftest cmacs-ai-harness-is-not-a-special-mode ()
  "Deriving from `special-mode' makes the buffer untypable under Evil.

Two things follow from that derivation and both are wrong here: the
buffer becomes read-only, and Evil gives modes derived from
`special-mode' normal state -- so every letter meant for the prompt is a
motion or an operator instead.  The transcript is protected by a text
property, which covers exactly the part that needs it.

Asserted as the derivation rather than by simulating a keystroke,
because the failure only appears with Evil loaded and the suite runs
without it."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (should-not (provided-mode-derived-p 'cmacs-ai-harness-mode 'special-mode))
  (cmacs-ai-harness-tests--with-session
    (should-not buffer-read-only)))

(ert-deftest cmacs-ai-harness-opens-in-one-window ()
  "The harness takes the window rather than splitting it.

`pop-to-buffer' splits, which is wrong for a buffer you sit in front of
and work in -- and is what this did first."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (let ((before (length (window-list))))
    (cmacs-ai-harness-tests--with-session
      (should (= (length (window-list)) before))
      (should (eq (window-buffer (selected-window)) (current-buffer))))))

(ert-deftest cmacs-ai-harness-both-exports-are-reachable ()
  "Two export keys, two commands, and neither shadows the other.

`C-c C-E' is not a key.  Emacs cannot distinguish Control-Shift-letter
from Control-letter, so (kbd \"C-c C-E\") and (kbd \"C-c C-e\") are the
same sequence -- binding both meant the second `define-key' silently ate
the first and one of the two exports could not be invoked at all.  It
looked fine in the source, which is exactly why this asserts the
resolved commands rather than reading the `define-key' calls."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (let ((org (lookup-key cmacs-ai-harness-mode-map (kbd "C-c C-e")))
        (md  (lookup-key cmacs-ai-harness-mode-map (kbd "C-c E"))))
    (should (eq org 'cmacs-ai-harness-export-org))
    (should (eq md 'cmacs-ai-harness-export-markdown))
    (should-not (eq org md))))

(ert-deftest cmacs-ai-harness-blocks-land-above-the-separator ()
  "Transcript content goes above the prompt, never into it.

The reported symptom was every reply appearing on the prompt line, so
after two turns the first line read `> >'.  The cause: the transcript-end
marker was created at the empty buffer's only position and the separator
was then inserted at that same position.  Insertion type t means a marker
advances past text inserted at it, so it ended up on the far side of the
separator and every block was inserted into the prompt.

Reproduced by inserting at the marker directly, which needs no model --
what matters is where the position is, not what goes there."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (should (< (cmacs-ai-harness--transcript-end)
               (marker-position cmacs-ai-harness--prompt-marker)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (cmacs-ai-harness--transcript-end))
        (insert "a block\n\n")))
    ;; Above the separator, so the prompt is still empty and still last.
    (should (equal (cmacs-ai-harness-prompt-string) ""))
    (should (string-prefix-p "a block" (buffer-substring-no-properties
                                        (point-min) (point-max))))
    ;; And the marker still points at the separator, ready for the next.
    (should (< (cmacs-ai-harness--transcript-end)
               (marker-position cmacs-ai-harness--prompt-marker)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (cmacs-ai-harness--transcript-end))
        (insert "second block\n\n")))
    (should (equal (cmacs-ai-harness-prompt-string) ""))
    ;; Order preserved: the second block follows the first rather than
    ;; being wedged in front of it.
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (< (string-search "a block" text)
                 (string-search "second block" text))))))

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

;;;; Tool wiring -------------------------------------------------------

(ert-deftest cmacs-ai-harness-http-provider-gets-tools ()
  "An HTTP-backed harness carries cmacs's tools, not none.

The defect this guards: `local-tools' defaults nil and nothing set it,
so the provider was sent no tools array at all.  An agent-tuned model
asked to inspect the filesystem then narrates a tool call in prose --
which is what it looks like from the buffer, and says nothing about
where the fault is."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (cmacs-ai-harness-tests--with-session
    (should-not (cmacs-ai-harness-cli-p cmacs-ai-harness--handle))
    (should (eq cmacs-ai-harness--tools 'local))
    (should (cmacs-ai-harness-local-tools-p cmacs-ai-harness--handle))
    (let ((names (cmacs-ai-tools-list
                  (cmacs-ai-harness-executor cmacs-ai-harness--handle))))
      ;; ai-glib's own built-ins ...
      (should (member "bash" names))
      ;; ... and cmacs's MCP surface on top of them.
      (should (seq-find (lambda (n) (string-prefix-p "project_" n)) names)))))

(ert-deftest cmacs-ai-harness-executor-handle-is-memoized ()
  "Asking twice returns one handle.

A fresh handle per call would register the MCP bridge's callbacks onto
the same executor again -- `ai_tool_executor_register_callback' does not
dedupe -- so the model would see every tool twice."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (cmacs-ai-harness-tests--with-session
    (should (= (cmacs-ai-harness-executor cmacs-ai-harness--handle)
               (cmacs-ai-harness-executor cmacs-ai-harness--handle)))))

(ert-deftest cmacs-ai-harness-does-not-expose-ai-tools-to-itself ()
  "The `ai_' recursion guard survives the harness path.

Without it an in-process session can call ai_prompt and drive itself."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (cmacs-ai-harness-tests--with-session
    (let ((names (cmacs-ai-tools-list
                  (cmacs-ai-harness-executor cmacs-ai-harness--handle))))
      (should-not (seq-find (lambda (n) (string-prefix-p "ai_" n)) names)))))

(ert-deftest cmacs-ai-harness-tools-can-be-turned-off ()
  "`cmacs-ai-harness-enable-tools' nil means no tools, and says so."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (let ((cmacs-ai-harness-enable-tools nil))
    (cmacs-ai-harness-tests--with-session
      (should-not cmacs-ai-harness--tools)
      (should-not (cmacs-ai-harness-local-tools-p cmacs-ai-harness--handle)))))

(ert-deftest cmacs-ai-harness-tools-builtin-is-reachable ()
  "/tools must not answer \"not available in this buffer\".

It is ai-glib's own builtin and fell through to the catch-all, so the
one command anybody would use to check whether tools are on denied they
existed."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (cmacs-ai-harness-tests--with-session
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (cmacs-ai-harness--builtin "tools" nil))
      (should-not (seq-find (lambda (m)
                              (string-match-p "not available" m))
                            messages)))
    (should (get-buffer "*cmacs-ai-harness: tools*"))
    (kill-buffer "*cmacs-ai-harness: tools*")))

(ert-deftest cmacs-ai-harness-mode-line-reports-the-tool-surface ()
  "The mode line says which mechanism is in play.

A provider that silently took no tools is invisible from the transcript,
and a one-shot startup message is not enough for a buffer open for
hours."
  (skip-unless (fboundp 'cmacs-ai-harness-executor))
  (cmacs-ai-harness-tests--with-session
    (should (string-match-p "tools" (cmacs-ai-harness--mode-line)))))

;;;; The directory a harness starts in ---------------------------------

;; The provider half of this -- that the conversation pushes the directory
;; down to a CLI client, which is what actually decides the agent's $PWD --
;; is ai-glib's contract and is asserted there
;; (tests/test-conversation-input.c, /ai-glib/input/cwd-reaches-cli).  What
;; belongs here is which directory cmacs chooses.

(ert-deftest cmacs-ai-harness-default-directory-is-the-project-root ()
  "A harness opened inside a project runs at its root, not at point.

An agent's directory is not cosmetic: CLAUDE.md, .claude and every
relative path a tool touches resolve against it, so a harness opened
from a file three levels down must not start three levels down."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (let* ((root (file-name-as-directory
                (expand-file-name (make-temp-name "harness-root")
                                  temporary-file-directory)))
         (deep (expand-file-name "a/b/" root)))
    (make-directory deep t)
    (unwind-protect
        (let ((default-directory deep))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _) (list 'transient root)))
                    ((symbol-function 'project-root)
                     (lambda (p) (nth 1 p))))
            (should (equal (file-name-as-directory
                            (cmacs-ai-harness--default-directory))
                           root))))
      (delete-directory root t))))

(ert-deftest cmacs-ai-harness-default-directory-falls-back ()
  "Outside a project the directory is where you are, not an error."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (let ((default-directory temporary-file-directory))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'vc-root-dir) (lambda (&rest _) nil)))
      (should (equal (file-name-as-directory
                      (cmacs-ai-harness--default-directory))
                     (file-name-as-directory
                      (expand-file-name temporary-file-directory)))))))

(ert-deftest cmacs-ai-harness-explicit-directory-beats-the-default ()
  "\\[cmacs-ai-harness-with-provider-in-directory] is not a suggestion."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (should (equal (file-name-as-directory
                    (cmacs-ai-harness-working-directory
                     cmacs-ai-harness--handle))
                   (file-name-as-directory
                    (expand-file-name temporary-file-directory))))))

;;;; Transcript region bookkeeping ------------------------------------

;; These drive `cmacs-ai-harness--insert-block' and `--replace-block'
;; with the renderer stubbed, because the thing under test is the marker
;; arithmetic and not the library: reaching a real block would need a
;; model to answer, and the defect these guard against is invisible until
;; a *second* block exists.

(defmacro cmacs-ai-harness-tests--with-stub-blocks (table &rest body)
  "Run BODY with `cmacs-ai-harness-block-render' answering from TABLE.
TABLE maps a block id to the text that block renders to.

The stub takes WIDTH even though `cmacs-ai-harness--insert-block' omits
it.  Natively compiled code calls a subr at its full arity, filling the
optionals with nil, so the replacement is handed three arguments here and
two when the same code runs interpreted.  A two-argument stub passes a
direct \\[ert] run and fails under `make check-cmacs'."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cmacs-ai-harness-block-render)
              (lambda (_handle id &optional _width)
                (cons (gethash id ,table) nil))))
     ,@body))

(defun cmacs-ai-harness-tests--region-text (id)
  "Buffer text of block ID's recorded region."
  (let ((r (gethash id cmacs-ai-harness--regions)))
    (buffer-substring-no-properties (car r) (cdr r))))

(defun cmacs-ai-harness-tests--draw (table ids)
  "Insert each of IDS at the transcript end, rendering from TABLE."
  (cmacs-ai-harness-tests--with-stub-blocks table
    (let ((inhibit-read-only t))
      (save-excursion
        (dolist (id ids)
          (goto-char (cmacs-ai-harness--transcript-end))
          (cmacs-ai-harness--insert-block id))))))

(ert-deftest cmacs-ai-harness-block-regions-do-not-swallow-their-successors ()
  "Each block's recorded region is that block and nothing after it.

The end marker used to be insertion type t, and the next block is
inserted at exactly that position, so every block's region grew to cover
the whole rest of the transcript.  Nothing visible broke until something
re-rendered a block, at which point `--replace-block' deleted every later
block with it -- so assert the regions, not just the buffer."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((table (make-hash-table :test 'eql)))
      (puthash 1 "AAAA" table)
      (puthash 2 "BBBB" table)
      (puthash 3 "CCCC" table)
      (cmacs-ai-harness-tests--draw table '(1 2 3))
      (should (equal (cmacs-ai-harness-tests--region-text 1) "AAAA\n\n"))
      (should (equal (cmacs-ai-harness-tests--region-text 2) "BBBB\n\n"))
      (should (equal (cmacs-ai-harness-tests--region-text 3) "CCCC\n\n")))))

(ert-deftest cmacs-ai-harness-regrowing-a-block-leaves-its-neighbours ()
  "A streaming block growing must not disturb the blocks around it.

This is the failure the user sees: the reply grows, and the block below
it disappears from the buffer.  The start marker has to be insertion type
t for a later block to survive an earlier one being replaced -- fixing
only the end marker keeps the buffer intact but leaves the later block's
region pointing at its predecessor, which breaks the next re-render and
`cmacs-ai-harness-copy-block' with it."
  (skip-unless (fboundp 'cmacs-ai-harness-new))
  (cmacs-ai-harness-tests--with-session
    (let ((table (make-hash-table :test 'eql)))
      (puthash 1 "AAAA" table)
      (puthash 2 "BBBB" table)
      (puthash 3 "CCCC" table)
      (cmacs-ai-harness-tests--draw table '(1 2 3))
      ;; Block 2 streams in more text and is re-rendered in place.
      (puthash 2 "BBBBBBBB" table)
      (cmacs-ai-harness-tests--with-stub-blocks table
        (let ((inhibit-read-only t))
          (cmacs-ai-harness--replace-block 2)))
      ;; The buffer kept every block ...
      (should (string-match-p "AAAA" (buffer-string)))
      (should (string-match-p "BBBBBBBB" (buffer-string)))
      (should (string-match-p "CCCC" (buffer-string)))
      ;; ... and each region still names exactly its own block.
      (should (equal (cmacs-ai-harness-tests--region-text 1) "AAAA\n\n"))
      (should (equal (cmacs-ai-harness-tests--region-text 2) "BBBBBBBB\n\n"))
      (should (equal (cmacs-ai-harness-tests--region-text 3) "CCCC\n\n")))))

(provide 'cmacs-ai-harness-tests)

;;; cmacs-ai-harness-tests.el ends here
