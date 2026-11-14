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
;;    formats on save.
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

(declare-function cmacs-lsp-ensure "cmacs-lsp" ())
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

(defun cmacs-tallow-server-contact (&optional _interactive)
  "Command line of the Tallow language server."
  (list (or (cmacs-tallow-program) "tallow") "lsp"))

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

(defun cmacs-tallow--mode-setup ()
  "Make a `tallow-mode' buffer work out of the box."
  (add-hook 'before-save-hook #'cmacs-tallow--format-before-save nil t)
  (when (and cmacs-tallow-auto-eglot buffer-file-name
             (cmacs-tallow-program)
             (require 'cmacs-lsp nil t))
    (cmacs-lsp-ensure)))

;;;; Running, testing, checking

(defun cmacs-tallow--project-root ()
  "The directory holding tallow.yaml above the current file, or nil."
  (when-let* ((dir (locate-dominating-file default-directory "tallow.yaml")))
    (expand-file-name dir)))

(defun cmacs-tallow--compile (args &optional name)
  "Run the tallow program with ARGS in a compilation buffer named NAME."
  (let ((default-directory (or (cmacs-tallow--project-root) default-directory))
        (compilation-buffer-name-function
         (lambda (_) (or name "*tallow*"))))
    (compile (mapconcat #'shell-quote-argument
                        (cons (cmacs-tallow--ensure-program) args) " "))))

(defun cmacs-tallow-run (&optional args)
  "Run the current Tallow file (or project) with `tallow run'.
With a prefix argument, read extra program ARGS."
  (interactive (list (and current-prefix-arg
                          (split-string-and-unquote (read-string "Arguments: ")))))
  (cmacs-tallow--compile (append (list "run")
                                 (and buffer-file-name (not (cmacs-tallow--project-root))
                                      (list buffer-file-name))
                                 (and args (cons "--" args)))
                         "*tallow run*"))

(defun cmacs-tallow-test ()
  "Run the project's tests with `tallow test'."
  (interactive)
  (cmacs-tallow--compile '("test") "*tallow test*"))

(defun cmacs-tallow-check ()
  "Type-check the current file (or project) with `tallow check'."
  (interactive)
  (cmacs-tallow--compile (append '("check")
                                 (and buffer-file-name (list buffer-file-name)))
                         "*tallow check*"))

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
    (define-key tallow-mode-map (kbd "C-c C-e") #'cmacs-tallow-explain)
    (define-key tallow-mode-map (kbd "C-c C-d") #'cmacs-tallow-debug)
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
