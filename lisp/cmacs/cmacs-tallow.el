;;; cmacs-tallow.el --- Tallow, out of the box: mode, LSP, REPL, debugging  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: languages, tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tallow (deps/tallow) is built with cmacs and installed alongside it.
;; This file makes a .tlw file work with no configuration:
;;
;;  - `tallow-mode' (upstream, deps/tallow/editors/emacs) for syntax,
;;    indentation and imenu; eglot runs `tallow lsp' for everything else
;;    -- completion, types on hover, inlay hints, diagnostics, rename,
;;    references, call hierarchy, code actions, semantic tokens -- and
;;    formats on save.  `completion-preview-mode' gives as-you-type
;;    completion when no corfu/company popup is around, and
;;    `cmacs-tallow-include-dirs' / `cmacs-tallow-gir-dirs' (usually
;;    from .dir-locals.el) reach the server and every command.
;;  - `cmacs-tallow-command-map' (C-c C-a, and SPC m under Doom): build,
;;    run (C or suet, --watch), check, test, fuzz, explain, caps, verify.
;;  - `cmacs-tallow-repl': a comint REPL over `tallow repl --json'.  It
;;    is a subprocess on purpose: a panicking program cannot take the
;;    editor (or, under --gowl, the session) down with it.
;;  - Debugging through dape: a `tallow' config (gdb under the hood,
;;    built with -g) and a `tallow-suet' config, the time-travel
;;    debugger, with step back and reverse continue.
;;  - Run, test, check, explain, new project; tallow.yaml is a project
;;    root for project.el.
;;
;; The toolchain is found in the tree this cmacs was built from first,
;; then on PATH.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'comint)
(require 'compile)

(declare-function cmacs-lsp--setup-doc-frame "cmacs-lsp" ())
(declare-function project-root "project" (project))
(declare-function eglot-managed-p "eglot" ())
(declare-function eglot-format-buffer "eglot" ())
(declare-function tallow-mode "tallow-mode" ())
(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape--config-eval "dape" (key options &optional skip-functions))
(defvar eglot-server-programs)
(defvar dape-configs)
(defvar tallow-register-with-eglot)
(defvar tallow-program)
(defvar tallow-mode-map)
(defvar project-vc-extra-root-markers)

(defgroup cmacs-tallow nil
  "Tallow language support in cmacs."
  :group 'cmacs
  :prefix "cmacs-tallow-")

(defcustom cmacs-tallow-format-on-save t
  "Non-nil means format .tlw buffers with `tallow fmt' (via eglot) on save."
  :type 'boolean)

(defcustom cmacs-tallow-auto-eglot t
  "Non-nil means .tlw buffers start eglot (`tallow lsp') automatically."
  :type 'boolean)

(defcustom cmacs-tallow-repl-buffer-name "*Tallow*"
  "Name of the Tallow REPL buffer."
  :type 'string)

(defcustom cmacs-tallow-repl-prompt "tallow> "
  "The Tallow REPL prompt."
  :type 'string)

(defcustom cmacs-tallow-repl-backend "suet"
  "Which program serves the REPL: \"suet\" (the bytecode VM, no C
compiler needed) runs `tallow-suet repl --json'; \"tallow\" runs
`tallow repl --json'."
  :type '(choice (const "suet") (const "tallow")))

(defcustom cmacs-tallow-completion-preview t
  "Non-nil means .tlw buffers get as-you-type completion out of the box.
This turns on the built-in `completion-preview-mode' (the language
server's candidates, shown inline; TAB accepts, M-i completes) unless
the buffer already has a completion UI of its own (corfu, company).
\\[completion-at-point] always lists every candidate."
  :type 'boolean)

(defcustom cmacs-tallow-include-dirs nil
  "Extra Tallow module directories (-I) for the language server and commands.
Relative entries are under the project root (the directory of
tallow.yaml, else the project.el root).  A project with a tallow.yaml
usually needs none: its `sources' are searched already.  Set per
directory, e.g. in .dir-locals.el:

  ((tallow-mode . ((cmacs-tallow-include-dirs . (\"src\" \"lib\")))))"
  :type '(repeat directory)
  :safe (lambda (v) (and (listp v) (cl-every #'stringp v))))

(defcustom cmacs-tallow-gir-dirs nil
  "Extra directories of .gir files, prepended to TALLOW_GIR_PATH.
Used by the language server and every tallow command run from a
buffer, e.g. for a project's generated GIRs.  Relative entries are
under the project root, like `cmacs-tallow-include-dirs'."
  :type '(repeat directory)
  :safe (lambda (v) (and (listp v) (cl-every #'stringp v))))

;;;; Finding the toolchain

(defun cmacs-tallow--dep-dir ()
  "The deps/tallow checkout this cmacs was built from, or nil."
  (let ((dir (and (bound-and-true-p source-directory)
                  (expand-file-name "deps/tallow" source-directory))))
    (and dir (file-directory-p dir) dir)))

(defun cmacs-tallow-program (&optional name)
  "Absolute file name of the Tallow program NAME (default \"tallow\")."
  (let ((name (or name "tallow")))
    (or (when-let* ((dep (cmacs-tallow--dep-dir)))
          (cl-loop for d in (list (getenv "CMACS_TALLOW_DIR")
                                  (expand-file-name "build/debug" dep)
                                  (expand-file-name "build/release" dep))
                   for f = (and d (expand-file-name name d))
                   when (and f (file-executable-p f)) return f))
        (executable-find name))))

(defun cmacs-tallow--ensure-program (&optional name)
  "The Tallow program NAME, or a `user-error' saying how to get it."
  (or (cmacs-tallow-program name)
      (user-error "cmacs-tallow: no `%s' (build cmacs --with-cmacs-tallow)"
                  (or name "tallow"))))

(defun cmacs-tallow--load-mode ()
  "Load the upstream `tallow-mode', from site-lisp or the dep checkout."
  (or (featurep 'tallow-mode)
      (progn
        ;; cmacs registers the server itself, with the tree's binary.
        (setq tallow-register-with-eglot nil)
        (or (require 'tallow-mode nil t)
            (when-let* ((dep (cmacs-tallow--dep-dir))
                        (dir (expand-file-name "editors/emacs" dep)))
              (when (file-readable-p (expand-file-name "tallow-mode.el" dir))
                (add-to-list 'load-path dir)
                (require 'tallow-mode nil t)))))))

;;;; Language server

(defun cmacs-tallow--root ()
  "The directory relative search dirs are under.
The nearest tallow.yaml's directory, else the project.el root, else
`default-directory'."
  (or (cmacs-tallow--project-root)
      (and (fboundp 'project-current)
           (when-let* ((pr (project-current nil)))
             (expand-file-name (project-root pr))))
      default-directory))

(defun cmacs-tallow--expand-dirs (dirs)
  "DIRS made absolute against `cmacs-tallow--root'."
  (let ((root (cmacs-tallow--root)))
    (mapcar (lambda (d) (expand-file-name d root)) dirs)))

(defun cmacs-tallow--gir-path ()
  "TALLOW_GIR_PATH with `cmacs-tallow-gir-dirs' first, or nil if unchanged."
  (when cmacs-tallow-gir-dirs
    (string-join (append (cmacs-tallow--expand-dirs cmacs-tallow-gir-dirs)
                         (and (getenv "TALLOW_GIR_PATH")
                              (list (getenv "TALLOW_GIR_PATH"))))
                 path-separator)))

(defun cmacs-tallow--include-args ()
  "The -I options for `cmacs-tallow-include-dirs'."
  (mapcan (lambda (d) (list "-I" d))
          (cmacs-tallow--expand-dirs cmacs-tallow-include-dirs)))

(defun cmacs-tallow-server-contact (&optional _interactive)
  "Command line of the Tallow language server, for eglot.
`cmacs-tallow-include-dirs' become the server's includeDirs
initialization option; `cmacs-tallow-gir-dirs' are put on its
TALLOW_GIR_PATH (through env(1), since eglot has no per-server
environment)."
  (let ((gir (cmacs-tallow--gir-path)))
    (append (and gir (list "env" (concat "TALLOW_GIR_PATH=" gir)))
            (list (or (cmacs-tallow-program) "tallow") "lsp")
            (list :initializationOptions
                  (list :includeDirs
                        (vconcat (cmacs-tallow--expand-dirs
                                  cmacs-tallow-include-dirs)))))))

(with-eval-after-load 'eglot
  (setq eglot-server-programs
        (cons '(tallow-mode . cmacs-tallow-server-contact)
              (cl-remove-if (lambda (e) (eq (car-safe e) 'tallow-mode))
                            eglot-server-programs))))

(defun cmacs-tallow--format-before-save ()
  "Format through the language server, when it manages this buffer."
  (when (and cmacs-tallow-format-on-save
             (fboundp 'eglot-managed-p) (eglot-managed-p))
    (ignore-errors (eglot-format-buffer))))

(defun cmacs-tallow--start-eglot ()
  "Start eglot (`tallow lsp') in this buffer.
Not `cmacs-lsp-ensure': that one is for the servers compiled into
the cmacs binary and does nothing in a build without them, while
`tallow lsp' is an ordinary program.  The at-point doc frame of
cmacs-lsp is still used when it is there."
  ;; Load eglot outside the mode hook first: on Emacs 30 its autoload
  ;; firing under `delay-mode-hooks' recursively expands macros.
  (unless (featurep 'eglot)
    (with-temp-buffer (require 'eglot nil t)))
  (when (fboundp 'eglot-ensure)
    (when (and (require 'cmacs-lsp nil t)
               (fboundp 'cmacs-lsp--setup-doc-frame))
      (cmacs-lsp--setup-doc-frame))
    ;; eglot-ensure connects after this command, so .dir-locals.el
    ;; values (include and GIR dirs) are in place by then.
    (eglot-ensure)))

(defun cmacs-tallow--completion-ui-p ()
  "Non-nil when the buffer already has a completion popup of its own.
The global modes count too: they turn the buffer's mode on only
after the major mode's hooks have run."
  (or (bound-and-true-p corfu-mode)
      (bound-and-true-p global-corfu-mode)
      (bound-and-true-p company-mode)
      (bound-and-true-p global-company-mode)
      (bound-and-true-p completion-preview-mode)))

(defun cmacs-tallow--mode-setup ()
  "Make a `tallow-mode' buffer work out of the box."
  (add-hook 'before-save-hook #'cmacs-tallow--format-before-save nil t)
  (when (and cmacs-tallow-completion-preview
             (not (cmacs-tallow--completion-ui-p))
             (require 'completion-preview nil t))
    (completion-preview-mode 1))
  (when (and cmacs-tallow-auto-eglot buffer-file-name
             (cmacs-tallow-program))
    (cmacs-tallow--start-eglot)))

;;;; Running, testing, checking

(defun cmacs-tallow--project-root ()
  "The directory holding tallow.yaml above the current file, or nil."
  (when-let* ((dir (locate-dominating-file default-directory "tallow.yaml")))
    (expand-file-name dir)))

(defun cmacs-tallow--compile (args &optional name comint)
  "Run the tallow program with ARGS in a compilation buffer named NAME.
`cmacs-tallow-gir-dirs' are put on TALLOW_GIR_PATH.  COMINT non-nil
makes the buffer interactive, for programs that read stdin."
  (let* ((gir (cmacs-tallow--gir-path))
         (compilation-environment
          (append (and gir (list (concat "TALLOW_GIR_PATH=" gir)))
                  compilation-environment))
         (default-directory (or (cmacs-tallow--project-root) default-directory))
         (compilation-buffer-name-function
          (lambda (_) (or name "*tallow*"))))
    (compile (mapconcat #'shell-quote-argument
                        (cons (cmacs-tallow--ensure-program) args) " ")
             comint)))

(defun cmacs-tallow--file-or-error ()
  "The buffer's file, saved first; a `user-error' when there is none."
  (unless buffer-file-name
    (user-error "cmacs-tallow: this buffer visits no file"))
  (when (buffer-modified-p)
    (save-buffer))
  buffer-file-name)

(defcustom cmacs-tallow-c-dependencies nil
  "C dependencies of Tallow code that calls C, for build, run, test and fuzz.

A plist, the four settings a project's tallow.yaml gives (tallow 0.32.3+
passes them for a single FILE too; in a project they come after the
manifest's):

  :include  list of directories      --c-include DIR (-IDIR)
  :pkg      list of pkg-config names --pkg NAME
  :cflags   string                   --cflags FLAGS
  :libs     string                   --libs FLAGS (-lfoo, -Ldir, a .a or .c)

Usually set per directory, e.g. in .dir-locals.el:

  ((tallow-mode . ((cmacs-tallow-c-dependencies
                    . (:include (\"csrc\") :libs \"csrc/twice.c\")))))

These become compiler and linker flags, so a value from a
.dir-locals.el is asked about before it is used."
  :type '(plist :options ((:include (repeat directory))
                          (:pkg (repeat string))
                          (:cflags string)
                          (:libs string))))
(put 'cmacs-tallow-c-dependencies 'risky-local-variable t)

(defun cmacs-tallow--c-dep-args ()
  "Command-line options for `cmacs-tallow-c-dependencies'."
  (let ((deps cmacs-tallow-c-dependencies))
    (append (mapcan (lambda (d) (list "--c-include" d)) (plist-get deps :include))
            (mapcan (lambda (p) (list "--pkg" p)) (plist-get deps :pkg))
            (and (plist-get deps :cflags) (list "--cflags" (plist-get deps :cflags)))
            (and (plist-get deps :libs) (list "--libs" (plist-get deps :libs))))))

(defun cmacs-tallow--file-arg ()
  "The current file as a FILE argument, unless it is part of a project."
  (and buffer-file-name (not (cmacs-tallow--project-root)) (list buffer-file-name)))

(defun cmacs-tallow-run (&optional args)
  "Run the current Tallow file (or project) with `tallow run'.
With a prefix argument, read extra program ARGS."
  (interactive (list (and current-prefix-arg
                          (split-string-and-unquote (read-string "Arguments: ")))))
  (cmacs-tallow--compile (append (list "run")
                                 (cmacs-tallow--include-args)
                                 (cmacs-tallow--c-dep-args)
                                 (cmacs-tallow--file-arg)
                                 (and args (cons "--" args)))
                         "*tallow run*" t))

(defun cmacs-tallow-test ()
  "Run the tests of the project, or of the current file, with `tallow test'."
  (interactive)
  (cmacs-tallow--compile (append '("test") (cmacs-tallow--include-args)
                                 (cmacs-tallow--c-dep-args)
                                 (cmacs-tallow--file-arg))
                         "*tallow test*"))

;;;###autoload
(defun cmacs-tallow-fuzz (&optional seed)
  "Fuzz the contracts of the current file (or project) with `tallow fuzz'.
Every function with a contract gets generated inputs; a failure is
shrunk to a minimal call with a reproduce: line.  With a prefix
argument, read the SEED to replay."
  (interactive (list (and current-prefix-arg (read-number "Seed: "))))
  (cmacs-tallow--compile (append '("fuzz")
                                 (and seed (list "--seed" (number-to-string seed)))
                                 (cmacs-tallow--include-args)
                                 (cmacs-tallow--c-dep-args)
                                 (cmacs-tallow--file-arg))
                         "*tallow fuzz*"))

(defun cmacs-tallow-check ()
  "Type-check the current file (or project) with `tallow check'."
  (interactive)
  (cmacs-tallow--compile (append '("check")
                                 (cmacs-tallow--include-args)
                                 (and buffer-file-name (list buffer-file-name)))
                         "*tallow check*"))

(defun cmacs-tallow-build ()
  "Build the project of the nearest tallow.yaml, else the current file.
A single file is built with -g (gdb and `tallow dap' step its .tlw
lines) into the program next to it, named without the extension."
  (interactive)
  (if (cmacs-tallow--project-root)
      (cmacs-tallow--compile (append '("build") (cmacs-tallow--include-args)
                                     (cmacs-tallow--c-dep-args))
                             "*tallow build*")
    (let ((file (cmacs-tallow--file-or-error)))
      (cmacs-tallow--compile (append '("build" "-g")
                                     (cmacs-tallow--include-args)
                                     (cmacs-tallow--c-dep-args)
                                     (list file "-o" (file-name-sans-extension file)))
                             "*tallow build*"))))

(defun cmacs-tallow-run-suet (&optional args)
  "Run the current file on suet, the bytecode VM (no C compiler).
With a prefix argument, read extra program ARGS."
  (interactive (list (and current-prefix-arg
                          (split-string-and-unquote (read-string "Arguments: ")))))
  (cmacs-tallow--compile (append '("run" "--backend=suet")
                                 (cmacs-tallow--include-args)
                                 (list (cmacs-tallow--file-or-error))
                                 args)
                         "*tallow run*" t))

(defun cmacs-tallow-run-watch ()
  "Run the current file and hot-reload it whenever it or an import changes."
  (interactive)
  (cmacs-tallow--compile (append '("run" "--watch")
                                 (cmacs-tallow--include-args)
                                 (list (cmacs-tallow--file-or-error)))
                         "*tallow watch*" t))

(defun cmacs-tallow-explain-item ()
  "Show the item at point beside the C it lowers to (`tallow explain -l')."
  (interactive)
  (cmacs-tallow--compile (append '("explain")
                                 (cmacs-tallow--include-args)
                                 (list "-l" (number-to-string (line-number-at-pos))
                                       (cmacs-tallow--file-or-error)))
                         "*tallow explain*"))

(defun cmacs-tallow-caps ()
  "List the capabilities the current program needs, as YAML."
  (interactive)
  (cmacs-tallow--compile (append '("check" "--caps")
                                 (cmacs-tallow--include-args)
                                 (list (cmacs-tallow--file-or-error)))
                         "*tallow caps*"))

(defun cmacs-tallow-verify ()
  "Prove the contracts of the current file with z3 or cvc5 (`tallow verify')."
  (interactive)
  (cmacs-tallow--compile (append '("verify")
                                 (cmacs-tallow--include-args)
                                 (list (cmacs-tallow--file-or-error)))
                         "*tallow verify*"))

(defun cmacs-tallow-explain (code)
  "Explain the diagnostic CODE (the one at point by default)."
  (interactive
   (list (read-string "Explain diagnostic: "
                      (let ((sym (thing-at-point 'symbol t)))
                        (and sym (string-match-p "\\`[A-Z][0-9]+\\'" sym) sym)))))
  (let ((out (with-output-to-string
               (with-current-buffer standard-output
                 (call-process (cmacs-tallow--ensure-program) nil t nil
                               "explain" code)))))
    (with-help-window "*tallow explain*" (princ out))))

;;;###autoload
(defun cmacs-tallow-new (directory)
  "Create a new Tallow project in DIRECTORY with `tallow new'."
  (interactive "FNew Tallow project directory: ")
  (let ((dir (expand-file-name directory)))
    (let ((default-directory (file-name-directory (directory-file-name dir))))
      (unless (zerop (call-process (cmacs-tallow--ensure-program) nil "*tallow new*" nil
                                   "new" (file-name-nondirectory (directory-file-name dir))))
        (pop-to-buffer "*tallow new*")
        (user-error "tallow new failed")))
    (dired dir)))

;;;; REPL over `tallow repl --json'

(defface cmacs-tallow-repl-value '((t :inherit font-lock-constant-face))
  "Face of REPL values.")
(defface cmacs-tallow-repl-type '((t :inherit font-lock-type-face))
  "Face of REPL value types.")

(defvar-local cmacs-tallow-repl--next-id 1 "Next request id.")
(defvar-local cmacs-tallow-repl--partial "" "An incomplete output line.")
(defvar-local cmacs-tallow-repl--waiters nil
  "Alist of (ID . RESPONSE-OR-nil) for synchronous requests (completion).")
(defvar-local cmacs-tallow-repl--source nil
  "(BUFFER . POSITION) of code sent from a source buffer, for error links.")

(defun cmacs-tallow-repl--request (proc op &rest fields)
  "Send request OP with FIELDS (a plist) to PROC; return its id."
  (with-current-buffer (process-buffer proc)
    (let ((id cmacs-tallow-repl--next-id))
      (setq cmacs-tallow-repl--next-id (1+ id))
      (process-send-string
       proc (concat (json-serialize
                     (append (list :id id :op op)
                             (cl-loop for (k v) on fields by #'cddr
                                      append (list k v))))
                    "\n"))
      id)))

(defun cmacs-tallow-repl--render (msg)
  "Text for one REPL response MSG (a plist), or nil for none."
  (pcase (plist-get msg :kind)
    ("ready" (format "Tallow %s\n%s" (or (plist-get msg :version) "")
                     cmacs-tallow-repl-prompt))
    ("output" (if (equal (plist-get msg :stream) "stderr")
                  (propertize (plist-get msg :text) 'face 'warning)
                (plist-get msg :text)))
    ("value"
     ;; An item or a statement answers with an empty value of type ().
     (if (and (equal (plist-get msg :value) "") (equal (plist-get msg :type) "()"))
         cmacs-tallow-repl-prompt
       (concat (propertize (format "%s" (plist-get msg :value)) 'face 'cmacs-tallow-repl-value)
               (when-let* ((type (plist-get msg :type)))
                 (concat " " (propertize (concat ": " type) 'face 'cmacs-tallow-repl-type)))
               "\n" cmacs-tallow-repl-prompt)))
    ("type"
     (concat (propertize (format "%s" (plist-get msg :type)) 'face 'cmacs-tallow-repl-type)
             "\n" cmacs-tallow-repl-prompt))
    ("exit" (format "[program exited with status %s]\n" (plist-get msg :code)))
    ("error"
     (concat (propertize (format "error%s: %s"
                                 (if (plist-get msg :code)
                                     (format "[%s]" (plist-get msg :code)) "")
                                 (plist-get msg :message))
                         'face 'error)
             (when-let* ((span (plist-get msg :span)))
               (format " (%s:%s)" (plist-get span :line) (plist-get span :col)))
             "\n" cmacs-tallow-repl-prompt))
    ("incomplete" "....> ")
    ("items" (concat (mapconcat (lambda (i) (format "%s" i))
                                (plist-get msg :items) "\n")
                     "\n" cmacs-tallow-repl-prompt))
    ("ok" cmacs-tallow-repl-prompt)
    (_ nil)))

(defun cmacs-tallow-repl--preoutput (string)
  "Turn the REPL's JSON lines in STRING into display text."
  (let* ((all (concat cmacs-tallow-repl--partial string))
         (lines (split-string all "\n"))
         (out ""))
    (setq cmacs-tallow-repl--partial (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (let ((msg (condition-case nil
                       (json-parse-string line :object-type 'plist :array-type 'list
                                          :null-object nil :false-object nil)
                     (error nil))))
          (cond
           ((null msg) (setq out (concat out line "\n")))
           ((assq (plist-get msg :id) cmacs-tallow-repl--waiters)
            (setcdr (assq (plist-get msg :id) cmacs-tallow-repl--waiters) msg))
           (t (setq out (concat out (or (cmacs-tallow-repl--render msg) ""))))))))
    out))

(defun cmacs-tallow-repl--input-sender (proc input)
  "Send INPUT to the REPL PROC as an eval (or a colon command) request."
  (let ((code (string-trim-right input)))
    (cond
     ((string-match "\\`:\\(reset\\|items\\)\\'" (string-trim code))
      (cmacs-tallow-repl--request proc (match-string 1 (string-trim code))))
     ((string-match "\\`:type +\\(.*\\)\\'" (string-trim code))
      (cmacs-tallow-repl--request proc "type" :code (match-string 1 (string-trim code))))
     (t (cmacs-tallow-repl--request proc "eval" :code code)))))

(defun cmacs-tallow-repl--sync (proc op &rest fields)
  "Send OP with FIELDS to PROC and wait (briefly) for its response."
  (let ((buf (process-buffer proc))
        id (deadline (+ (float-time) 2)) resp)
    (with-current-buffer buf
      (setq id (apply #'cmacs-tallow-repl--request proc op fields))
      (push (cons id nil) cmacs-tallow-repl--waiters))
    (while (and (not (setq resp (cdr (assq id (buffer-local-value
                                               'cmacs-tallow-repl--waiters buf)))))
                (< (float-time) deadline))
      (accept-process-output proc 0.05))
    (with-current-buffer buf
      (setq cmacs-tallow-repl--waiters (assq-delete-all id cmacs-tallow-repl--waiters)))
    resp))

(defun cmacs-tallow-repl--capf ()
  "Complete Tallow at point in the REPL through the REPL's `complete' op."
  (when-let* ((proc (get-buffer-process (current-buffer)))
              ((process-live-p proc))
              ((>= (point) (process-mark proc))))
    (let* ((bounds (or (bounds-of-thing-at-point 'symbol) (cons (point) (point))))
           (prefix (buffer-substring-no-properties (car bounds) (cdr bounds)))
           (resp (cmacs-tallow-repl--sync proc "complete"
                                          :prefix prefix
                                          :code (buffer-substring-no-properties
                                                 (process-mark proc) (point-max)))))
      (when resp
        (list (car bounds) (cdr bounds)
              (mapcar (lambda (c) (propertize (format "%s" (plist-get c :label))
                                              'cmacs-tallow-kind (plist-get c :kind)
                                              'cmacs-tallow-detail (plist-get c :detail)))
                      (plist-get resp :items))
              :exclusive 'no
              :annotation-function
              (lambda (c) (when-let* ((k (get-text-property 0 'cmacs-tallow-kind c)))
                            (concat " " k)))
              :company-docsig
              (lambda (c) (get-text-property 0 'cmacs-tallow-detail c)))))))

(defvar-keymap cmacs-tallow-repl-mode-map
  :doc "Keymap for `cmacs-tallow-repl-mode'."
  :parent comint-mode-map
  "TAB"     #'completion-at-point
  "C-c C-z" #'cmacs-tallow-repl-switch-back)

(define-derived-mode cmacs-tallow-repl-mode comint-mode "Tallow-REPL"
  "Major mode for the Tallow REPL.

Colon commands: :reset, :items, :type EXPR.

\\{cmacs-tallow-repl-mode-map}"
  :group 'cmacs-tallow
  (setq-local comint-prompt-regexp
              (concat "^\\(?:" (regexp-quote cmacs-tallow-repl-prompt) "\\|\\.\\.\\.\\.> \\)"))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'cmacs-tallow-repl--input-sender)
  (setq-local comint-process-echoes nil)
  (add-hook 'comint-preoutput-filter-functions #'cmacs-tallow-repl--preoutput nil t)
  (add-hook 'completion-at-point-functions #'cmacs-tallow-repl--capf nil t)
  (when (cmacs-tallow--load-mode)
    (setq-local font-lock-defaults
                (and (boundp 'tallow-font-lock-keywords)
                     (list (symbol-value 'tallow-font-lock-keywords))))))

(defvar cmacs-tallow-repl--return-buffer nil
  "The source buffer `cmacs-tallow-repl-switch-back' returns to.")

;;;###autoload
(defun cmacs-tallow-repl ()
  "Open (or switch to) the Tallow REPL."
  (interactive)
  (setq cmacs-tallow-repl--return-buffer (current-buffer))
  (let ((buf (get-buffer-create cmacs-tallow-repl-buffer-name)))
    (unless (comint-check-proc buf)
      (let* ((suet (equal cmacs-tallow-repl-backend "suet"))
             (program (cmacs-tallow--ensure-program (if suet "tallow-suet" "tallow"))))
        (with-current-buffer buf
          (cmacs-tallow-repl-mode)
          (setq cmacs-tallow-repl--partial "" cmacs-tallow-repl--next-id 1)
          (let ((proc (make-process :name "tallow-repl" :buffer buf
                                    :command (list program "repl" "--json")
                                    :connection-type 'pipe
                                    :noquery t
                                    :filter #'comint-output-filter)))
            (set-marker (process-mark proc) (point-max))))))
    (pop-to-buffer buf)))

(defun cmacs-tallow-repl-switch-back ()
  "Return to the source buffer the REPL was opened from."
  (interactive)
  (when (buffer-live-p cmacs-tallow-repl--return-buffer)
    (pop-to-buffer cmacs-tallow-repl--return-buffer)))

(defun cmacs-tallow--repl-process ()
  "The live REPL process, starting the REPL if needed."
  (let ((proc (get-buffer-process (get-buffer-create cmacs-tallow-repl-buffer-name))))
    (unless (and proc (process-live-p proc))
      (save-window-excursion (cmacs-tallow-repl))
      (setq proc (get-buffer-process cmacs-tallow-repl-buffer-name)))
    proc))

(defun cmacs-tallow-send-region (start end)
  "Evaluate the region from START to END in the Tallow REPL."
  (interactive "r")
  (let ((proc (cmacs-tallow--repl-process))
        (code (buffer-substring-no-properties start end)))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (comint-output-filter proc (concat (propertize code 'face 'shadow) "\n")))
    (cmacs-tallow-repl--request proc "eval" :code code)
    (display-buffer (process-buffer proc))))

(defun cmacs-tallow-send-defun ()
  "Evaluate the top-level form at point in the Tallow REPL."
  (interactive)
  (save-excursion
    (let ((end (progn (end-of-defun) (point)))
          (start (progn (beginning-of-defun) (point))))
      (cmacs-tallow-send-region start end))))

(defun cmacs-tallow-send-buffer ()
  "Evaluate the whole buffer in the Tallow REPL."
  (interactive)
  (cmacs-tallow-send-region (point-min) (point-max)))

;;;; Debugging through dape

(defun cmacs-tallow--program-for-debug ()
  "The program to debug: the project's output, else the current file."
  (or buffer-file-name (cmacs-tallow--project-root) default-directory))

(defun cmacs-tallow--dape-configs ()
  "The dape configurations for Tallow."
  (let ((tallow (or (cmacs-tallow-program) "tallow")))
    `((tallow
       modes (tallow-mode)
       ensure (lambda (_config)
                (unless (executable-find "gdb")
                  (user-error "tallow dap needs gdb")))
       command ,tallow
       command-args ("dap")
       command-cwd (lambda () (or (cmacs-tallow--project-root) default-directory))
       :type "tallow"
       :request "launch"
       :program (lambda () (cmacs-tallow--program-for-debug))
       :args []
       :stopOnEntry nil)
      (tallow-suet
       modes (tallow-mode)
       command ,tallow
       command-args ("dap")
       command-cwd (lambda () (or (cmacs-tallow--project-root) default-directory))
       :type "tallow"
       :request "launch"
       :backend "suet"
       :program (lambda () (cmacs-tallow--program-for-debug))
       :args []
       :stopOnEntry t))))

(with-eval-after-load 'dape
  (dolist (cfg (cmacs-tallow--dape-configs))
    (setq dape-configs (cons cfg (assq-delete-all (car cfg) dape-configs)))))

;;;###autoload
(defun cmacs-tallow-debug (&optional time-travel)
  "Debug the current Tallow program with dape.
With a prefix argument (TIME-TRAVEL), use the suet time-travel
debugger, which can step backwards."
  (interactive "P")
  (unless (require 'dape nil t)
    (user-error "cmacs-tallow: debugging needs the `dape' package (M-x package-install RET dape)"))
  (dape (dape--config-eval (if time-travel 'tallow-suet 'tallow) nil)))

;;;; Mode wiring

(defvar-keymap cmacs-tallow-command-map
  :doc "Every Tallow command on one letter: C-c C-a in `tallow-mode',
and the localleader (SPC m) under Doom Emacs."
  "b" #'cmacs-tallow-build
  "r" #'cmacs-tallow-run
  "s" #'cmacs-tallow-run-suet
  "w" #'cmacs-tallow-run-watch
  "c" #'cmacs-tallow-check
  "t" #'cmacs-tallow-test
  "u" #'cmacs-tallow-fuzz
  "e" #'cmacs-tallow-explain-item
  "E" #'cmacs-tallow-explain
  "k" #'cmacs-tallow-caps
  "v" #'cmacs-tallow-verify
  "R" #'cmacs-tallow-repl
  "d" #'cmacs-tallow-debug
  "n" #'cmacs-tallow-new)

(defvar doom-localleader-key)
(defvar doom-localleader-alt-key)
(declare-function general-define-key "general" (&rest args))

(defvar cmacs-tallow--localleader-bound nil
  "Non-nil once Doom's localleader carries `cmacs-tallow-command-map'.")

(defun cmacs-tallow--bind-doom-localleader ()
  "Put `cmacs-tallow-command-map' on Doom's localleader in `tallow-mode'.
Does what Doom's `map! :localleader' does, as a function call, so
this file needs neither Doom nor general.el to compile or load."
  (when (and (fboundp 'general-define-key) (boundp 'doom-localleader-alt-key))
    (let ((binds (let (acc)
                   (map-keymap (lambda (ev cmd)
                                 (push (key-description (vector ev)) acc)
                                 (push cmd acc))
                               cmacs-tallow-command-map)
                   (nreverse acc))))
      (apply #'general-define-key
             :keymaps 'tallow-mode-map
             :major-modes t
             (append (if (featurep 'evil)
                         (list :states '(normal visual motion emacs insert)
                               :prefix doom-localleader-key
                               :non-normal-prefix doom-localleader-alt-key)
                       (list :prefix doom-localleader-alt-key))
                     binds))
      t)))

(defun cmacs-tallow--install ()
  "Load `tallow-mode' and bind cmacs's commands in it."
  (when (cmacs-tallow--load-mode)
    (when-let* ((prog (cmacs-tallow-program)))
      (setq tallow-program prog))
    (define-key tallow-mode-map (kbd "C-c C-z") #'cmacs-tallow-repl)
    (define-key tallow-mode-map (kbd "C-c C-r") #'cmacs-tallow-send-region)
    (define-key tallow-mode-map (kbd "C-M-x") #'cmacs-tallow-send-defun)
    (define-key tallow-mode-map (kbd "C-c C-b") #'cmacs-tallow-send-buffer)
    (define-key tallow-mode-map (kbd "C-c C-c") #'cmacs-tallow-run)
    (define-key tallow-mode-map (kbd "C-c C-t") #'cmacs-tallow-test)
    (define-key tallow-mode-map (kbd "C-c C-v") #'cmacs-tallow-check)
    (define-key tallow-mode-map (kbd "C-c C-u") #'cmacs-tallow-fuzz)
    (define-key tallow-mode-map (kbd "C-c C-e") #'cmacs-tallow-explain)
    (define-key tallow-mode-map (kbd "C-c C-d") #'cmacs-tallow-debug)
    (define-key tallow-mode-map (kbd "C-c C-a") cmacs-tallow-command-map)
    (unless cmacs-tallow--localleader-bound
      (setq cmacs-tallow--localleader-bound
            (cmacs-tallow--bind-doom-localleader)))
    (add-hook 'tallow-mode-hook #'cmacs-tallow--mode-setup)
    t))

;;;###autoload
(defun cmacs-tallow-mode-autoload ()
  "Enter `tallow-mode' with cmacs's setup (the .tlw `auto-mode-alist' entry)."
  (if (cmacs-tallow--install)
      (tallow-mode)
    (prog-mode)
    (message "cmacs-tallow: tallow-mode not found (deps/tallow/editors/emacs)")))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tlw\\'" . cmacs-tallow-mode-autoload))

;; tallow.yaml marks a project root for project.el.
(with-eval-after-load 'project
  (when (boundp 'project-vc-extra-root-markers)
    (add-to-list 'project-vc-extra-root-markers "tallow.yaml")))

(with-eval-after-load 'org
  (when (cmacs-tallow--load-mode)
    (require 'ob-tallow nil t)))

(provide 'cmacs-tallow)

;;; cmacs-tallow.el ends here
