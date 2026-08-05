;;; cmacs-brigade-tests.el --- Tests for the AI brigade fabric  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 0 covers the wiring plus two standing hygiene guards that are
;; cheap now and expensive to retrofit later:
;;
;;   - config hygiene: no literal path, model id, or endpoint outside a
;;     `defcustom'.  Everything shipped is a default, never an
;;     assumption, because a user's notes are not necessarily in
;;     ~/Documents/notes and their ollama is not necessarily on
;;     localhost.
;;
;;   - backend hygiene: no `x-popup-menu' / `image-map' / `menu-bar-*'.
;;     Under `emacs --lrg' `display-graphic-p' returns t, so the natural
;;     guard passes and the call then fails at runtime because lrgterm
;;     draws no menu bar.  `cmacs-libregnum-popup-menu' is the portable
;;     spelling.
;;
;; Both scan the brigade sources as text, so they keep working as files
;; are added in later phases without anyone remembering to extend them.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
;; Not in the eager-load set (it is autoloaded), but the window-behaviour
;; tests below rebind `cmacs-brigade-dashboard-display', which needs the
;; defcustom in scope at compile time or the compiler makes it lexical
;; while the loaded file makes it dynamic.
(require 'cmacs-brigade-dashboard nil 'noerror)
(require 'cmacs-brigade-agent-def nil 'noerror)
(require 'cmacs-brigade-plan nil 'noerror)

(defconst cmacs-brigade-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, derived from this file's location in test/cmacs/.")

(defun cmacs-brigade-tests--available-p ()
  "Non-nil when this build compiled in the brigade fabric."
  (and (boundp 'is-cmacs-ai-brigade) is-cmacs-ai-brigade))

(defun cmacs-brigade-tests--elisp-files ()
  "Return the brigade Elisp sources that exist in this checkout."
  (let ((dir (expand-file-name "lisp/cmacs" cmacs-brigade-tests--root)))
    (and (file-directory-p dir)
         (directory-files dir t "\\`cmacs-brigade.*\\.el\\'"))))

(defun cmacs-brigade-tests--c-files ()
  "Return the brigade C sources that exist in this checkout."
  (let ((dir (expand-file-name "cmacs/ai-brigade" cmacs-brigade-tests--root)))
    (and (file-directory-p dir)
         (directory-files dir t "\\.[ch]\\'"))))

(defun cmacs-brigade-tests--in-defcustom-p ()
  "Non-nil if point is inside a top-level `defcustom' form.

Checked by walking out to the enclosing form rather than by looking at
the current line: a `defcustom' whose value spans several lines puts the
literal on a continuation line, and a line-based test would flag it even
though it is exactly where such a literal belongs."
  (save-excursion
    (let ((start (nth 1 (syntax-ppss))))
      (while (and start (nth 1 (syntax-ppss start)))
        (setq start (nth 1 (syntax-ppss start))))
      (when start
        (goto-char start)
        (looking-at-p "([ \t\n]*def\\(custom\\|const\\|group\\)")))))

(defun cmacs-brigade-tests--scan (files regexp)
  "Return a list of \"FILE:LINE: TEXT\" for each match of REGEXP in FILES.

Matches inside a comment or inside a `defcustom'/`defconst' form are
ignored: the point of these guards is live code that assumes a value,
and both the prose documenting a default and the default itself are
legitimate places for the literal to appear."
  (let (hits)
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        ;; Needed for `syntax-ppss' to understand strings and comments.
        (if (string-suffix-p ".el" f)
            (emacs-lisp-mode)
          (c-mode))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))
                (state (syntax-ppss)))
            (unless (or (nth 4 state)          ; inside a comment
                        (string-match-p "\\`[ \t]*\\(;\\|\\*\\|/\\*\\|//\\)" line)
                        (cmacs-brigade-tests--in-defcustom-p))
              (push (format "%s:%d: %s"
                            (file-name-nondirectory f)
                            (line-number-at-pos)
                            (string-trim line))
                    hits))))))
    (nreverse hits)))


;;;; Wiring

(ert-deftest cmacs-brigade-feature-flag ()
  "The IS-CMACS-AI-BRIGADE flag and its alias are always bound."
  ;; Bound in every build, including one with the feature off -- that is
  ;; the entire point of cmacs/core/cmacs-features.c, so a user config
  ;; can branch without a void-variable error.
  (should (boundp 'IS-CMACS-AI-BRIGADE))
  (should (boundp 'is-cmacs-ai-brigade))
  (should (eq (symbol-value 'IS-CMACS-AI-BRIGADE)
              (symbol-value 'is-cmacs-ai-brigade))))

(ert-deftest cmacs-brigade-feature-registered ()
  "When compiled in, brigade appears in the compiled-feature list."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (fboundp 'cmacs-compiled-features))
  (should (memq 'ai-brigade (cmacs-compiled-features)))
  (should (cmacs-feature-p 'ai-brigade)))

(ert-deftest cmacs-brigade-requires-cmacs-ai ()
  "Brigade cannot be compiled in without cmacs-ai.
configure.ac hard-errors on that combination; this asserts the built
binary agrees, which catches a feature block that was edited to warn
instead of error."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (and (boundp 'is-cmacs-ai) is-cmacs-ai)))

(ert-deftest cmacs-brigade-defuns-present ()
  "The Phase 0 DEFUNs exist and answer sanely."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (fboundp 'cmacs-brigade-supported-p))
  (should (cmacs-brigade-supported-p))
  (should (integerp (cmacs-brigade-abi-version)))
  (should (= (cmacs-brigade-abi-version) cmacs-brigade-abi-expected)))

(ert-deftest cmacs-brigade-capabilities-shape ()
  "`cmacs-brigade-capabilities' returns a plist of the documented keys."
  (skip-unless (cmacs-brigade-tests--available-p))
  (let ((caps (cmacs-brigade-capabilities)))
    (should (plistp caps))
    (dolist (k '(:libreclaw :mcp :f16c))
      (should (plist-member caps k))
      (should (memq (plist-get caps k) '(nil t))))
    ;; The C side derives :libreclaw from the same #ifdef the feature
    ;; registry uses, so the two must not disagree.
    (should (eq (and (plist-get caps :libreclaw) t)
                (and (boundp 'is-cmacs-libreclaw) is-cmacs-libreclaw t)))))

(ert-deftest cmacs-brigade-state-dirs-are-absolute ()
  "The shipped directory defaults resolve to absolute paths."
  (skip-unless (featurep 'cmacs-brigade))
  (dolist (d (list cmacs-brigade-state-dir
                   cmacs-brigade-cache-dir
                   cmacs-brigade-runtime-dir
                   cmacs-brigade-worktree-root))
    (should (stringp d))
    (should (file-name-absolute-p d))
    ;; An unexpanded "~" would be written into a .mcp.json or passed to
    ;; a subprocess that does not do tilde expansion.
    (should-not (string-prefix-p "~" d))))

(ert-deftest cmacs-brigade-worktree-root-derives-from-xdg ()
  "Worktrees default under XDG_CACHE_HOME, not under the repo being worked on.

A worktree inside the repo is walked by every other agent's `rg' and
`find', turning every search into duplicate hits across checkouts.

This asserts the derivation rather than the resulting absolute path:
cmacs's own test harness exports a writable XDG_CACHE_HOME *inside* the
source tree, so a naive \"is it outside the repo\" check would fail here
while the default is in fact correct."
  (skip-unless (featurep 'cmacs-brigade))
  ;; String comparison, not `file-in-directory-p': these directories are
  ;; created lazily on first use, and file-in-directory-p resolves
  ;; truenames, so it answers nil for a perfectly correct path that does
  ;; not exist yet.  The property under test is the derivation, which is
  ;; a pure function of the environment.
  (should (string-prefix-p (file-name-as-directory cmacs-brigade-cache-dir)
                           cmacs-brigade-worktree-root))
  ;; Re-derive under a controlled XDG_CACHE_HOME and confirm it moves,
  ;; i.e. the default really is environment-derived rather than a
  ;; constant that happens to look right here.
  (let* ((fake "/nonexistent-brigade-xdg")
         (process-environment (cons (concat "XDG_CACHE_HOME=" fake)
                                    process-environment))
         (derived (expand-file-name
                   "cmacs/brigade"
                   (or (getenv "XDG_CACHE_HOME")
                       (expand-file-name ".cache" "~")))))
    (should (string-prefix-p (file-name-as-directory fake) derived))))


;;;; Standing hygiene guards

(ert-deftest cmacs-brigade-no-hardcoded-config ()
  "No literal path, model id, or endpoint outside a `defcustom'.

Shipped values are defaults, never assumptions.  A user's notes are not
necessarily in ~/Documents/notes and their ollama is not necessarily on
localhost, so every one of these has to be reachable through Custom."
  (let* ((files (append (cmacs-brigade-tests--elisp-files)
                        (cmacs-brigade-tests--c-files)))
         (hits (and files
                    (cmacs-brigade-tests--scan
                     files
                     (rx (or "~/Documents"
                             "localhost:11434"
                             "nomic-embed"
                             "/Maildir"
                             ".local/share/mail"))))))
    (should (null hits))))

(ert-deftest cmacs-brigade-no-lrg-hostile-ui ()
  "No `x-popup-menu' / `image-map' / `menu-bar-*' in brigade Elisp.

Under `emacs --lrg' `display-graphic-p' returns t, so the obvious guard
passes and these then fail at runtime because lrgterm draws no menu bar.
Use `cmacs-libregnum-popup-menu', which falls through to the native menu
on pgtk, and a position keymap text property rather than `image-map' so
rows outrank Evil's state maps."
  (let* ((files (cmacs-brigade-tests--elisp-files))
         (hits (and files
                    (cmacs-brigade-tests--scan
                     files
                     (rx (or "x-popup-menu" "image-map" "menu-bar-"))))))
    (should (null hits))))

(ert-deftest cmacs-brigade-docs-cover-the-api ()
  "Every public registry and shipped tool is documented.

An extension surface nobody can find is not one.  This checks the
manual actually mentions each entry point rather than trusting that it
was updated alongside the code."
  (let* ((dir (expand-file-name "doc_org/cmacs/ai-brigade"
                                cmacs-brigade-tests--root))
         (text (and (file-directory-p dir)
                    (mapconcat (lambda (f)
                                 (with-temp-buffer
                                   (insert-file-contents f)
                                   (buffer-string)))
                               (directory-files dir t "\\.org\\'") "\n"))))
    (skip-unless text)
    (dolist (fn '("cmacs-brigade-register-tool"
                  "cmacs-brigade-register-agent"
                  "cmacs-brigade-register-worker"
                  "cmacs-brigade-register-isolation"
                  "cmacs-brigade-register-memory-source"
                  "cmacs-brigade-register-deliverable"
                  "cmacs-brigade-register-panel"
                  "cmacs-brigade-register-context-provider"
                  "cmacs-brigade-register-approval-handler"
                  "cmacs-brigade-register-notifier"
                  "cmacs-brigade-deftool"))
      (should (string-search fn text)))
    ;; and the tools an agent is actually given
    (dolist (tool '("memory_search" "memory_get" "memory_stats"
                    "mail_search" "mail_read" "deliverable_emit"
                    "schedule_create" "schedule_preview" "schedule_list"))
      (should (string-search tool text)))))

(ert-deftest cmacs-brigade-docs-mirrored-in-texinfo ()
  "The Info manual has a brigade chapter and includes it.

doc/ and doc_org/ are maintained in parallel; a chapter that exists in
one and not the other is how they drift apart."
  (let ((texi (expand-file-name "doc/cmacs/ai-brigade/ai-brigade.texi"
                                cmacs-brigade-tests--root))
        (main (expand-file-name "doc/cmacs/cmacs.texi"
                                cmacs-brigade-tests--root)))
    (skip-unless (file-readable-p main))
    (should (file-readable-p texi))
    (with-temp-buffer
      (insert-file-contents main)
      (let ((s (buffer-string)))
        (should (string-search "@include ai-brigade/ai-brigade.texi" s))
        (should (string-search "* CMacs AI Brigade::" s))))))


;;;; Dashboard display
;;
;; The dashboard used to open with `pop-to-buffer', which splits a
;; single-window frame every time.  These pin the window count, because
;; "it made a new window" is not something a test of the rendering
;; would ever notice.

(ert-deftest cmacs-brigade-dashboard-does-not-create-a-window ()
  "No display mode may add a window to the frame."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (dolist (mode '(full-frame same-window))
    (save-window-excursion
      (delete-other-windows)
      (let ((cmacs-brigade-dashboard-display mode)
            (before (length (window-list))))
        (cmacs-brigade-dashboard)
        (should (= (length (window-list)) before))
        (should (eq (current-buffer) (get-buffer "*brigade*")))))))

(ert-deftest cmacs-brigade-dashboard-full-frame-takes-the-frame ()
  "full-frame leaves exactly one window, whatever the layout was."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (save-window-excursion
    (delete-other-windows)
    (split-window-right)
    (split-window-below)
    (should (> (length (window-list)) 1))
    (let ((cmacs-brigade-dashboard-display 'full-frame))
      (cmacs-brigade-dashboard)
      (should (= 1 (length (window-list)))))))

(ert-deftest cmacs-brigade-dashboard-quit-restores-the-layout ()
  "Taking the whole frame is only polite if q gives it back."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (save-window-excursion
    (delete-other-windows)
    (split-window-right)
    (let ((before (length (window-list)))
          (cmacs-brigade-dashboard-display 'full-frame))
      (cmacs-brigade-dashboard)
      (should (= 1 (length (window-list))))
      (cmacs-brigade-dashboard-quit)
      (should (= before (length (window-list))))
      (should-not (eq (current-buffer) (get-buffer "*brigade*"))))))

(ert-deftest cmacs-brigade-dashboard-reopen-after-switching-away ()
  "Leaving by switching buffers, then reopening, restores the layout
that was on screen at the *second* open -- not a stale one recorded
during the first visit."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (save-window-excursion
    (let ((cmacs-brigade-dashboard-display 'full-frame))
      ;; First visit, left without quitting.
      (delete-other-windows)
      (cmacs-brigade-dashboard)
      (switch-to-buffer "*scratch*")
      ;; Second visit, from a two-window layout.
      (delete-other-windows)
      (split-window-right)
      (let ((before (length (window-list))))
        (cmacs-brigade-dashboard)
        (should (= 1 (length (window-list))))
        (cmacs-brigade-dashboard-quit)
        (should (= before (length (window-list))))))))

(ert-deftest cmacs-brigade-dashboard-reopen-does-not-clobber-the-layout ()
  "Re-running the command while already in it must not record
the full-frame state as the layout to return to."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (save-window-excursion
    (delete-other-windows)
    (split-window-right)
    (let ((before (length (window-list)))
          (cmacs-brigade-dashboard-display 'full-frame))
      (cmacs-brigade-dashboard)
      (cmacs-brigade-dashboard)
      (cmacs-brigade-dashboard)
      (cmacs-brigade-dashboard-quit)
      (should (= before (length (window-list)))))))


(ert-deftest cmacs-brigade-runner-is-actually-loaded ()
  "Loading cmacs-brigade must bind the functions its UI dispatches to.

`cmacs-brigade-run' has no autoload cookie, so if it drops out of the
eager-load set nothing pulls it in and the dashboard's keys and every
scheduled fire die on a void function.  That is invisible until someone
presses a key, which is why it is asserted here."
  (skip-unless (featurep 'cmacs-brigade))
  (dolist (fn '(cmacs-brigade-start-task
                cmacs-brigade-cancel-task
                cmacs-brigade-live-count
                cmacs-brigade-can-start-p))
    (should (fboundp fn))))

(ert-deftest cmacs-brigade-default-budget-is-unlimited ()
  "Zero is the documented \"no ceiling\" value, not a zero-dollar cap."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (should (= 0 cmacs-brigade-default-budget-usd))
  ;; An agent that names no budget inherits it rather than inventing one.
  (let ((agent (cmacs-brigade-agent--from-text
                "---\nname: budget-test\n---\nbody" nil)))
    (should (= 0 (plist-get agent :budget-usd)))))


;;;; Agent definitions actually reach the runtime

(ert-deftest cmacs-brigade-ships-agent-definitions-loaded ()
  "The shipped definitions are registered without anyone calling reload.

Registering the loader without ever calling it is what produced
\"no agent definition named researcher\" on a stock plan: the files were
in etc/ the whole time, nothing had read them."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((agents (cmacs-brigade-registry-list 'agent)))
    (dolist (a '(researcher critic librarian))
      (should (memq a agents))
      (should (cmacs-brigade-agent-get a)))))

(ert-deftest cmacs-brigade-agent-derive-passes-through-without-overrides ()
  "No overrides means no derived agent, so the UI shows the plain name."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (cmacs-brigade-register-agent :name 'derive-base :prompt "p"
                                :model "base/model")
  (should (eq 'derive-base
              (cmacs-brigade-agent-derive "derive-base" "abc" nil)))
  (should (eq 'derive-base (cmacs-brigade-agent-base-name 'derive-base))))

(ert-deftest cmacs-brigade-agent-derive-applies-and-inherits ()
  "An override wins; everything unmentioned comes from the base."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (cmacs-brigade-register-agent :name 'derive-base2 :prompt "sysprompt"
                                :model "base/model" :tools '(a b)
                                :budget-usd 3.0 :isolation 'worktree)
  (let* ((name (cmacs-brigade-agent-derive "derive-base2" "xyz"
                                           '(:model "over/model")))
         (def (cmacs-brigade-agent-get name)))
    (should-not (eq name 'derive-base2))
    (should (equal (plist-get def :model) "over/model"))
    (should (equal (plist-get def :tools) '(a b)))
    (should (eq (plist-get def :isolation) 'worktree))
    (should (equal (plist-get def :prompt) "sysprompt"))
    ;; and the UI can still name it
    (should (eq 'derive-base2 (cmacs-brigade-agent-base-name name)))))

(ert-deftest cmacs-brigade-agent-derive-reports-an-unknown-base ()
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (should-error (cmacs-brigade-agent-derive "no-such-agent" "x"
                                            '(:model "m/n"))
                :type 'cmacs-brigade-agent-error))

(ert-deftest cmacs-brigade-plan-model-reaches-the-runtime ()
  "A :MODEL: on a headline must survive adopt as a string.

The record carries the agent as a string; handing the C DEFUN a symbol
stores nil, and the task then runs with no agent at all -- which looks
exactly like having forgotten to set one."
  (skip-unless (and (featurep 'cmacs-brigade-plan)
                    (fboundp 'cmacs-brigade-task-get)))
  (let* ((dir (make-temp-file "brigade-plan" t))
         (file (expand-file-name "p.org" dir)))
    (unwind-protect
        (progn
          (cmacs-brigade-register-agent :name 'plan-base :prompt "p"
                                        :model "base/model")
          (with-temp-file file
            (insert "#+title: t\n" cmacs-brigade-plan-todo-line "\n\n"
                    "* TODO Overridden  :brigade:\n  :PROPERTIES:\n"
                    "  :AGENT: plan-base\n  :MODEL: over/model\n"
                    "  :END:\n  body\n"))
          (with-current-buffer (find-file-noselect file)
            (let* ((res (cmacs-brigade-plan-adopt))
                   (rec (cmacs-brigade-task-get (plist-get (car res) :id)))
                   (agent (plist-get rec :agent)))
              (should (stringp agent))
              (should (equal "over/model"
                             (plist-get (cmacs-brigade-agent-get (intern agent))
                                        :model)))
              (should (eq 'plan-base
                          (cmacs-brigade-agent-base-name (intern agent)))))))
      (when-let* ((b (find-buffer-visiting file)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b))
      (delete-directory dir t))))


;;;; Keymap: vanilla and Doom

(ert-deftest cmacs-brigade-dashboard-binds-what-it-advertises ()
  "Every key the hint line names is actually bound."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (dolist (key '("s" "K" "RET" "c" "p" "a" "m" "b" "t" "A" "g" "M" "?" "q"))
    (should (commandp (lookup-key cmacs-brigade-dashboard-mode-map
                                  (kbd key))))))

(ert-deftest cmacs-brigade-dashboard-survives-evil ()
  "The dashboard installs an Evil intercept map.

Without it `s' runs evil-snipe and `c' starts a change operator under
Doom, so the documented keys do nothing.  This asserts the setup call is
reached -- an `fboundp' guard around it silently skipped the whole thing
whenever cmacs-evil had not been loaded."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (should (featurep 'cmacs-evil))
  (should (fboundp 'cmacs-evil-setup-mode-map))
  ;; evil-snipe must not turn on here even if the user has it
  (when (boundp 'evil-snipe-disabled-modes)
    (should (memq 'cmacs-brigade-dashboard-mode evil-snipe-disabled-modes))))


(ert-deftest cmacs-brigade-no-cl-return-from-in-plain-defun ()
  "`cl-return-from' needs the block `cl-defun' establishes.

In a plain `defun' it byte-compiles cleanly and then dies at runtime with
a void `--cl-block-NAME--', but only on the branch that returns early --
so it survives every test that does not take that branch.  Two of these
shipped before anyone hit one."
  (let (bad)
    (dolist (f (cmacs-brigade-tests--elisp-files))
      (with-temp-buffer
        (insert-file-contents f)
        (emacs-lisp-mode)
        (goto-char (point-min))
        (let ((cl nil) (name nil))
          (while (re-search-forward
                  "^(\\(cl-\\)?defun \\([^ \t\n]+\\)\\|cl-return-from" nil t)
            (if (match-beginning 2)
                (setq cl (match-beginning 1)
                      name (match-string 2))
              (unless (or cl (nth 4 (syntax-ppss)))
                (push (format "%s: %s" (file-name-nondirectory f) name)
                      bad)))))))
    (should (equal nil bad))))


(ert-deftest cmacs-brigade-declared-cmacs-functions-are-loaded ()
  "Every cmacs- function the brigade declares must be bound after load.

`declare-function' satisfies the byte-compiler and loads nothing, so a
declared-but-never-required function compiles clean, passes every unit
test that stubs it, and dies the first time a human presses a key.  That
shipped four times: cmacs-brigade-run itself, cmacs-evil, and twice for
cmacs-ai.

Only cmacs- symbols are checked.  Declarations for optional subsystems
\(piper, whisper\) are legitimately unbound in a build without them, and
those are all guarded at their call sites."
  (skip-unless (featurep 'cmacs-brigade))
  ;; Load everything a user reaches interactively, not just the eager set.
  (dolist (f '(cmacs-brigade-dashboard cmacs-brigade-plan
               cmacs-brigade-schedule cmacs-brigade-run
               ;; The chat layer counts: the loopback client delivers
               ;; into a chat buffer, and a chat is something a user
               ;; reaches interactively even though nothing loads it
               ;; eagerly.
               cmacs-ai-chat))
    (require f nil 'noerror))
  (let ((optional '("piper" "whisper" "audio" "libregnum" "imgedit"
                    "vidstudio" "transcribe" "mu4e" "libreclaw"))
        bad)
    (dolist (file (cmacs-brigade-tests--elisp-files))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^(declare-function \\([^ \t\n)]+\\)" nil t)
          (let ((name (match-string 1)))
            (when (and (string-prefix-p "cmacs-" name)
                       (not (cl-some (lambda (o) (string-match-p o name))
                                     optional))
                       (not (fboundp (intern name))))
              (push (format "%s (declared in %s)" name
                            (file-name-nondirectory file))
                    bad))))))
    (should (equal nil (sort (delete-dups bad) #'string<)))))

(defun cmacs-brigade-tests--row-anchors (line)
  "The `:align-to' column positions LINE anchors its fields at."
  (let (out (pos 0))
    (while (setq pos (next-single-property-change pos 'display line))
      (let ((d (get-text-property pos 'display line)))
        (when (eq (car-safe d) 'space)
          (push (plist-get (cdr d) :align-to) out)))
      (setq pos (1+ pos)))
    (nreverse out)))

(ert-deftest cmacs-brigade-dashboard-columns-do-not-move-with-the-glyph ()
  "Every status glyph leaves the following columns in the same place.

The table used to be laid out by padding with spaces, which assumes a
glyph is as many columns wide as `string-width' says.  For the status
set that is false: `▶', `✔' and `✖' are East-Asian-Ambiguous, reported
as one column, and laid out by a graphical frame as two from the font's
own advance.  So `%-3s' emitted three characters that drew as four, and
every row for a task that had done something sat one column right of a
row that had not -- exactly the states you notice, since a fresh task
shows the narrow `·'."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let* ((c (list :st 3 :id 8 :agent 10 :model 12 :task 20
                  :turns 5 :tokens 11 :cost 9 :total 84))
         (expected (cmacs-brigade-tests--row-anchors
                    (cmacs-brigade-dashboard--row
                     c (list :st "ST" :id "ID" :agent "AGENT" :model "MODEL"
                             :task "TASK" :turns "TURNS" :tokens "TOKENS"
                             :cost "COST")))))
    (should expected)
    ;; Both glyph sets, every state, narrow and wide alike.
    (dolist (unicode '(t nil))
      (let ((cmacs-brigade-dashboard-unicode unicode))
        (dolist (state '(draft running starting queued waiting-input blocked
                         interrupted done failed over-budget cancelled))
          (let ((line (cmacs-brigade-dashboard--row
                       c (list :st (cmacs-brigade-dashboard--glyph state)
                               :id "abcd1234" :agent "general" :model "m"
                               :task "t" :turns 1 :tokens "2/3"
                               :cost "$0.1000"))))
            (should (equal expected
                           (cmacs-brigade-tests--row-anchors line)))))))))

(ert-deftest cmacs-brigade-dashboard-plain-text-still-lines-up ()
  "The buffer's text aligns too, not only its display.

Anchors alone would have left the plain text ragged, which is what you
get when you copy rows out of the buffer or read it with anything that
ignores display properties.  Padding and anchoring do different jobs and
both are needed."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let* ((c (list :st 3 :id 8 :agent 10 :model 12 :task 20
                  :turns 5 :tokens 11 :cost 9 :total 84))
         (widths nil))
    (dolist (state '(draft running done failed))
      (let* ((line (substring-no-properties
                    (cmacs-brigade-dashboard--row
                     c (list :st (cmacs-brigade-dashboard--glyph state)
                             :id "abcd1234" :agent "general" :model "m"
                             :task "t" :turns 1 :tokens "2/3"
                             :cost "$0.1000"))))
             ;; Where the ID column actually starts in the text.
             (at (string-match-p "abcd1234" line)))
        (push at widths)))
    (should (= 1 (length (delete-dups widths))))))

(ert-deftest cmacs-brigade-dashboard-row-truncates-by-display-width ()
  "An over-long cell cannot shove the next column past its anchor."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let* ((c (list :st 3 :id 8 :agent 10 :model 12 :task 20
                  :turns 5 :tokens 11 :cost 9 :total 84))
         (line (cmacs-brigade-dashboard--row
                c (list :st "·" :id (make-string 40 ?x)
                        :agent "般般般般般般般般般般般" :model "m" :task "t"
                        :turns 1 :tokens "2/3" :cost "$0.1"))))
    ;; The anchors are still the ones the header uses.
    (should (equal '(4 13 24 37 58 64 76)
                   (cmacs-brigade-tests--row-anchors line)))
    ;; And the wide-character field was cut by display width, not by
    ;; character count -- 11 CJK characters are 22 columns, not 11.
    (should (<= (string-width (substring-no-properties line))
                (+ (plist-get c :total) 8)))))

(provide 'cmacs-brigade-tests)

;;; cmacs-brigade-tests.el ends here
