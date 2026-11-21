;;; cmacs-redact-variables-tests.el --- Sensitive variables stay unprinted  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The rig found `describe_variable cmacs-journal-filter--rules' printing
;; the privacy rule set to an agent.  cmacs-redact.el now keeps a
;; registry of sensitive variables, and these tests hold three things:
;;
;;   - the registry: the rule-set variables and the secret holders are
;;     in it, an alias is as sensitive as its target, a broken entry
;;     makes everything sensitive;
;;   - every registry tool that prints a variable's value asks it, and
;;     its answer for a sensitive variable is the same whether the
;;     variable is bound, void or was never interned;
;;   - a source guard: a tool family file that prints `symbol-value'
;;     must mention `cmacs-redact-variable-p', so the next tool written
;;     cannot forget.
;;
;; The tools are called through the registry's own marshalling
;; (`cmacs-brigade--invoke'), with the real redaction functions and a
;; real rule set.  The wire path (MCP, D-Bus) is not exercised here.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-redact)
(require 'cmacs-brigade-registry)

(defvar cmacs-brigade--registries)
(defvar cmacs-brigade-tool-registered-functions)
(defvar cmacs-brigade-before-tool-call-functions)
(defvar cmacs-brigade-after-tool-call-functions)
(defvar cmacs-brigade-confirm-function)
(defvar cmacs-brigade-auto-approve)
(declare-function cmacs-brigade--invoke "cmacs-brigade-tools")
(declare-function cmacs-brigade--tool-by-wire "cmacs-brigade-registry")

(defvar cmacs-redact-variables-tests-probe-hook nil
  "A hook-named variable for `list_hooks'; made sensitive in a test.")
(defvar cmacs-redact-variables-tests-plain "plain-value-7341"
  "A variable nothing calls sensitive.")
(defvaralias 'cmacs-redact-variables-tests-alias
  'cmacs-redact-variables-tests-target)
(defvar cmacs-redact-variables-tests-target "target-value-9907"
  "A variable a test lists as sensitive.")

(defun cmacs-redact-variables-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-redact.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defmacro cmacs-redact-variables-tests--as-model (&rest body)
  "Run BODY as a model-facing caller under a small, loaded rule set."
  (declare (indent 0) (debug t))
  `(let* ((cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters
           '((:match ((:app . "rule-marker-keepass-5512")) :exclude t)))
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter--signature nil)
          (cmacs-journal-filter-hash-key "hash-key-marker-0123456789abcdef")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-redact-mode t)
          (cmacs-redact-surfaces '(tool rpc prompt))
          (cmacs-redact-sensitive-variables nil)
          (cmacs-redact--as-model t)
          (cmacs-redact--in-tool-call nil)
          (cmacs-redact--pending nil)
          (cmacs-redact--last-check (+ (float-time) 3600.0))
          (inhibit-interaction nil)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (cmacs-journal-filters-reload)
     ,@body))

(defmacro cmacs-redact-variables-tests--with-tools (&rest body)
  "Run BODY as a model with the describe and debug families registered."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t)
         (root (cmacs-redact-variables-tests--root)))
     (skip-unless root)
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (let ((load-prefer-newer t))
         (dolist (file '("cmacs-core-tools" "cmacs-describe-tools"
                         "cmacs-debug-tools"))
           (load (expand-file-name (concat "lisp/cmacs/" file) root)
                 nil t)))
       (cmacs-redact-variables-tests--as-model ,@body))))

(defun cmacs-redact-variables-tests--call (wire &rest args)
  "Call the registered tool WIRE with ARGS, a plist of name and value.
Returns the result with the dispatch's `prin1' layer read back off."
  (let ((tool (cmacs-brigade--tool-by-wire wire))
        (alist nil))
    (should tool)
    (while args
      (push (cons (pop args) (pop args)) alist))
    (car (read-from-string
          (cmacs-brigade--invoke tool (nreverse alist))))))

;;;; The registry

(ert-deftest cmacs-redact-variables-test-rule-set-is-sensitive ()
  "Every variable holding the rule set, as written or compiled, is listed."
  (dolist (name '(cmacs-journal-filter--rules
                  cmacs-journal-filter--error
                  cmacs-journal-filter--signature
                  cmacs-journal-filters
                  cmacs-journal-default-filters
                  cmacs-journal-filter-files
                  cmacs-journal-filter-hash-key
                  cmacs-redact--rules-seen
                  cmacs-redact--session-key
                  cmacs-redact-sensitive-variables
                  cmacs-redact-default-sensitive-variables))
    (should (cmacs-redact-sensitive-variable-p name))
    (should (cmacs-redact-sensitive-variable-p (symbol-name name)))))

(ert-deftest cmacs-redact-variables-test-every-rule-variable-is-covered ()
  "No `defvar' or `defcustom' of the filter engine holds rules unlisted.
Read from the source, so a variable added there later is caught here."
  (let ((root (cmacs-redact-variables-tests--root)))
    (skip-unless root)
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "lisp/cmacs/cmacs-journal-filter.el" root))
      (goto-char (point-min))
      (let ((seen 0))
        (while (re-search-forward
                "^(def\\(?:var\\|custom\\) \\(cmacs-journal-\\(?:default-\\)?filter[^ \n]*\\)"
                nil t)
          (let ((name (match-string 1)))
            ;; Two settings say nothing about what a person hides.
            (unless (member name '("cmacs-journal-filter-case-fold"
                                   "cmacs-journal-filter-changed-functions"))
              (setq seen (1+ seen))
              (should (cmacs-redact-sensitive-variable-p name)))))
        (should (> seen 5))))))

(ert-deftest cmacs-redact-variables-test-secret-holders-are-sensitive ()
  "Shipped secret holders and secret-shaped names are sensitive."
  (dolist (name '("cmacs-ai-search-api-key"
                  "cmacs-ai-openai-compatible-endpoints"
                  "cmacs-gnuseye--keys"
                  "cmacs-gnuseye--secret-memo"
                  "process-environment"
                  "initial-environment"
                  "auth-sources"
                  "auth-source-netrc-cache"
                  "password-data"
                  "my-service-password"
                  "some-oauth-access-token"
                  "smtp-credentials"
                  "a-name-never-interned-api-key"))
    (should (cmacs-redact-sensitive-variable-p name))))

(ert-deftest cmacs-redact-variables-test-ordinary-variables-are-not ()
  "The name regexps do not swallow ordinary options."
  (dolist (name '(load-path fill-column cmacs-gowl-prefix-keys
                  cmacs-context-key cmacs-ai-max-tokens
                  cmacs-brigade-token-ttl cmacs-gowl-default-keybindings
                  cmacs-redact-variables-tests-plain))
    (should-not (cmacs-redact-sensitive-variable-p name))))

(ert-deftest cmacs-redact-variables-test-user-list-and-alias ()
  "The user's list is consulted; an alias is as sensitive as its target."
  (let ((cmacs-redact-sensitive-variables nil))
    (should-not (cmacs-redact-sensitive-variable-p
                 'cmacs-redact-variables-tests-target))
    (should-not (cmacs-redact-sensitive-variable-p
                 'cmacs-redact-variables-tests-alias)))
  (let ((cmacs-redact-sensitive-variables
         '(cmacs-redact-variables-tests-target)))
    (should (cmacs-redact-sensitive-variable-p
             'cmacs-redact-variables-tests-target))
    (should (cmacs-redact-sensitive-variable-p
             "cmacs-redact-variables-tests-alias")))
  (let ((cmacs-redact-sensitive-variables '("-tests-pla[i]n\\'")))
    (should (cmacs-redact-sensitive-variable-p
             'cmacs-redact-variables-tests-plain))))

(ert-deftest cmacs-redact-variables-test-broken-entry-fails-closed ()
  "A list entry that cannot be used makes every variable sensitive."
  (let ((cmacs-redact-sensitive-variables '("\\(unbalanced")))
    (should (cmacs-redact-sensitive-variable-p 'load-path)))
  (let ((cmacs-redact-sensitive-variables '(42)))
    (should (cmacs-redact-sensitive-variable-p 'load-path)))
  (let ((cmacs-redact-sensitive-variables 'not-a-list))
    (should (cmacs-redact-sensitive-variable-p 'load-path))))

(ert-deftest cmacs-redact-variables-test-only-for-a-model ()
  "The user's own Lisp is refused nothing."
  (let ((cmacs-redact-mode t)
        (cmacs-redact-surfaces '(tool rpc prompt))
        (cmacs-redact--as-model nil)
        (cmacs-redact--in-tool-call nil)
        (cmacs-redact--pending nil)
        (inhibit-interaction nil))
    (should-not (cmacs-redact-variable-p 'cmacs-journal-filter--rules))
    (should-not (cmacs-redact-variable-guard 'cmacs-journal-filter--rules))
    (let ((cmacs-redact--in-tool-call t))
      (should (cmacs-redact-variable-p 'cmacs-journal-filter--rules))
      (should-not (cmacs-redact-variable-p 'load-path))
      (should (equal (cadr (should-error
                            (cmacs-redact-variable-guard
                             "cmacs-journal-filters")))
                     cmacs-redact-variable-refusal)))
    (let ((cmacs-redact-mode nil) (cmacs-redact--in-tool-call t))
      (should-not (cmacs-redact-variable-p 'cmacs-journal-filter--rules)))))

;;;; The surfaces

(ert-deftest cmacs-redact-variables-test-resource-guard ()
  "`variable://' is refused for a sensitive variable and for no other.
cmacs-mcp-resources.c asks `cmacs-redact-resource-guard' before reading."
  (cmacs-redact-variables-tests--as-model
    (should-not (cmacs-redact-resource-guard "variable" "load-path"))
    (dolist (name '("cmacs-journal-filter--rules" "cmacs-journal-filters"
                    "cmacs-journal-filter-hash-key" "process-environment"
                    "a-name-never-interned-api-key"))
      (let ((err (should-error
                  (cmacs-redact-resource-guard "variable" name))))
        ;; The words of every other refused resource: nothing says this
        ;; one was a variable on a list.
        (should (equal (error-message-string err)
                       "This resource is withheld by your privacy rules"))))))

(ert-deftest cmacs-redact-variables-test-describe-variable ()
  "`describe_variable' prints no rule, no key, and no binding status."
  (cmacs-redact-variables-tests--with-tools
    ;; An ordinary variable is still described.
    (let ((text (cmacs-redact-variables-tests--call
                 "describe_variable"
                 "symbol" "cmacs-redact-variables-tests-plain")))
      (should (string-match-p "plain-value-7341" text))
      (should (string-match-p "nothing calls sensitive" text)))
    ;; The rule set, its key, the user's lists: one sentence, the same
    ;; for a bound variable, a void one and a name never interned.
    (should (boundp 'cmacs-journal-filter--rules))
    (should-not (intern-soft "cmacs-journal-filter--never-defined-xyzzy"))
    (dolist (name '("cmacs-journal-filter--rules"
                    "cmacs-journal-filters"
                    "cmacs-journal-default-filters"
                    "cmacs-journal-filter-files"
                    "cmacs-journal-filter-hash-key"
                    "cmacs-redact--rules-seen"
                    "cmacs-journal-filter--never-defined-xyzzy"))
      (let ((text (cmacs-redact-variables-tests--call
                   "describe_variable" "symbol" name)))
        (should (equal text cmacs-redact-variable-refusal))
        (should-not (string-match-p "rule-marker\\|hash-key-marker" text))))
    (should-not (intern-soft "cmacs-journal-filter--never-defined-xyzzy"))
    ;; A user's own entry, and an alias of it.
    (let ((cmacs-redact-sensitive-variables
           '(cmacs-redact-variables-tests-target)))
      (dolist (name '("cmacs-redact-variables-tests-target"
                      "cmacs-redact-variables-tests-alias"))
        (should (equal (cmacs-redact-variables-tests--call
                        "describe_variable" "symbol" name)
                       cmacs-redact-variable-refusal))))))

(ert-deftest cmacs-redact-variables-test-list-hooks ()
  "`list_hooks' prints values, so a sensitive hook is not in it."
  (cmacs-redact-variables-tests--with-tools
    (let ((cmacs-redact-variables-tests-probe-hook '(hook-marker-2290)))
      (should (string-match-p
               "hook-marker-2290"
               (cmacs-redact-variables-tests--call "list_hooks")))
      (let* ((cmacs-redact-sensitive-variables
              '(cmacs-redact-variables-tests-probe-hook))
             (text (cmacs-redact-variables-tests--call "list_hooks")))
        (should-not (string-match-p "hook-marker-2290" text))
        (should-not (string-match-p "tests-probe-hook" text))))))

;;;; Source guard

(ert-deftest cmacs-redact-variables-test-value-printing-tools-ask ()
  "A tool family file that reads `symbol-value' consults the registry.
The registry only protects a surface that asks it.  A file that reads
a variable chosen at run time and prints nothing of it goes in the
exemptions below, with the reason."
  (let ((root (cmacs-redact-variables-tests--root))
        (exempt nil)
        (checked 0))
    (skip-unless root)
    (dolist (file (directory-files (expand-file-name "lisp/cmacs" root) t
                                   "\\`cmacs-.*-tools\\.el\\'"))
      (unless (member (file-name-nondirectory file) exempt)
        (with-temp-buffer
          (insert-file-contents file)
          (when (re-search-forward
                 ;; A variable chosen at run time.  Reading one fixed,
                 ;; quoted variable of the tool's own is not the hazard.
                 "(\\(?:symbol-value\\|default-value\\|buffer-local-value\\) [^']"
                 nil t)
            (setq checked (1+ checked))
            (goto-char (point-min))
            (unless (search-forward "cmacs-redact-variable-p" nil t)
              (ert-fail (format "%s prints variable values without asking `cmacs-redact-variable-p'"
                                (file-name-nondirectory file))))))))
    (should (>= checked 2))))

(provide 'cmacs-redact-variables-tests)

;;; cmacs-redact-variables-tests.el ends here
