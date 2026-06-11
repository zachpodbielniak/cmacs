;;; cmacs-crispy.el --- Crispy C scripting elisp layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for Crispy, the runtime C scripting engine.
;;
;; C primitives available:
;;   `crispy-eval'             -- compile and execute inline C code
;;   `crispy-eval-string'      -- execute C code, return stdout as string
;;   `crispy-compile'          -- compile a .c file, return cached binary
;;   `crispy-run'              -- compile and execute a .c script with args
;;   `crispy-repl-eval'        -- evaluate C code in persistent REPL
;;   `crispy-repl-eval-string' -- persistent REPL eval, capture output
;;   `crispy-repl-preamble'    -- return the accumulated REPL preamble
;;   `crispy-repl-reset'       -- reset the persistent REPL state
;;   `crispy-cache-status'     -- return the cache directory path
;;
;; This file provides:
;;   - `crispy-repl-mode'   -- comint major mode for the interactive C
;;     REPL with GHCi-style colon commands (:help, :type, :info, ...)
;;   - `crispy-eval-region' -- evaluate selected C code
;;   - `crispy-eval-buffer' -- evaluate current buffer as C
;;   - `M-x crispy-repl'    -- open the REPL

;;; Code:

(require 'comint)
(require 'seq)

(declare-function crispy-eval-string "cmacs-crispy.c")
(declare-function crispy-repl-eval-string "cmacs-crispy.c")
(declare-function crispy-repl-preamble "cmacs-crispy.c")
(declare-function crispy-repl-reset "cmacs-crispy.c")
(declare-function crispy-cache-status "cmacs-crispy.c")
(declare-function crispy-run "cmacs-crispy.c")
(declare-function cmacs-c-type-info "cmacs-cintrospect.c")
(declare-function cmacs-c-symbol-info "cmacs-cintrospect.c")
(declare-function cmacs-c-defun-info "cmacs-cintrospect.c")
(declare-function cmacs-c-function-source "cmacs-cintrospect.c")
(declare-function cmacs-c-list "cmacs-cintrospect.c")
(declare-function bacon-running-p "cmacs-bacon.c")
(declare-function bacon-eval "cmacs-bacon.c")

(defgroup crispy nil
  "Crispy C scripting integration."
  :group 'cmacs
  :prefix "crispy-")

(defcustom crispy-repl-buffer-name "*crispy*"
  "Name of the Crispy REPL buffer."
  :type 'string
  :group 'crispy)

(defcustom crispy-repl-prompt "crispy> "
  "Prompt string for the Crispy REPL."
  :type 'string
  :group 'crispy)

;;; Evaluation plumbing

(defun crispy-repl--eval-c (code)
  "Evaluate CODE in the persistent crispy REPL, returning its output.
Falls back to the stateless `crispy-eval-string' on binaries that
lack `crispy-repl-eval-string'."
  (if (fboundp 'crispy-repl-eval-string)
      (crispy-repl-eval-string code)
    (crispy-eval-string code)))

;;; Colon commands

(defvar crispy-repl-commands
  ;; (NAME ALIASES HANDLER ARG-HINT HELP)
  '((":help"     (":h" ":?") crispy-repl--cmd-help     nil
     "Show this help")
    (":type"     (":t")      crispy-repl--cmd-type     "EXPR"
     "Show the C type of EXPR (preamble in scope)")
    (":info"     (":i")      crispy-repl--cmd-info     "NAME"
     "cintrospect info for a C type/symbol/DEFUN")
    (":def"      (":d")      crispy-repl--cmd-def      "NAME"
     "Show file:line of C function NAME and visit it")
    (":doc"      ()          crispy-repl--cmd-doc      "NAME"
     "Docstring of Lisp function or variable NAME")
    (":browse"   (":b")      crispy-repl--cmd-browse   "GLOB"
     "List C symbols matching GLOB")
    (":preamble" (":p")      crispy-repl--cmd-preamble nil
     "Show the accumulated preamble")
    (":load"     (":l")      crispy-repl--cmd-load     "FILE"
     "Load a C file into the preamble")
    (":reset"    (":r")      crispy-repl--cmd-reset    nil
     "Reset REPL state (clear the preamble)")
    (":clear"    ()          crispy-repl--cmd-clear    nil
     "Clear the REPL buffer")
    (":cache"    ()          crispy-repl--cmd-cache    nil
     "Show the crispy cache directory")
    (":elisp"    (":e")      crispy-repl--cmd-elisp    "EXPR"
     "Evaluate EXPR as Emacs Lisp")
    (":bacon"    (":!")      crispy-repl--cmd-bacon    "CMD"
     "Run CMD in bacon (or shell fallback)")
    (":quit"     (":q")      crispy-repl--cmd-quit     nil
     "Bury the REPL buffer"))
  "Colon commands for the crispy REPL.
Each entry is (NAME ALIASES HANDLER ARG-HINT HELP).  HANDLER is
called with the argument string (or nil) and returns the output
string to insert into the REPL.")

(defun crispy-repl--parse-command (input)
  "Parse colon-command INPUT into (NAME . ARG), or nil if malformed.
ARG is nil when no argument was given.  \":!CMD\" with no space is
normalized to (\":!\" . \"CMD\")."
  (cond
   ((string-match "\\`:!\\(.*\\)\\'" input)
    (let ((arg (string-trim (match-string 1 input))))
      (cons ":!" (unless (string-empty-p arg) arg))))
   ((string-match "\\`\\(:[a-z?]+\\)\\(?:[ \t]+\\(.*\\)\\)?\\'" input)
    (cons (match-string 1 input)
          (let ((arg (match-string 2 input)))
            (when arg
              (setq arg (string-trim arg))
              (unless (string-empty-p arg) arg)))))))

(defun crispy-repl--lookup-command (name)
  "Return the `crispy-repl-commands' entry for NAME (or an alias)."
  (seq-find (lambda (entry)
              (or (string= name (car entry))
                  (member name (cadr entry))))
            crispy-repl-commands))

(defun crispy-repl--dispatch-command (input)
  "Dispatch colon-command INPUT, returning the output string."
  (pcase (crispy-repl--parse-command input)
    (`(,name . ,arg)
     (let ((entry (crispy-repl--lookup-command name)))
       (if entry
           (funcall (nth 2 entry) arg)
         (format "unknown command %s — :help lists commands" name))))
    (_ (format "malformed command %S — :help lists commands" input))))

;;; Colon command handlers

(defun crispy-repl--cmd-help (_arg)
  "Return the :help text, generated from `crispy-repl-commands'."
  (concat
   "Commands:\n"
   (mapconcat
    (lambda (entry)
      (pcase-let ((`(,name ,aliases ,_fn ,hint ,help) entry))
        (format "  %-17s%-10s%s"
                (concat name (if hint (concat " " hint) ""))
                (mapconcat #'identity aliases " ")
                help)))
    crispy-repl-commands "\n")
   "\n\nUsage:\n"
   "  Expressions (no trailing `;') are auto-printed:  1 + 2  =>  3\n"
   "  Statements execute as-is:  g_print(\"hi\\n\");\n"
   "  #include/#define, functions, and types accumulate in the preamble.\n"
   "  RET evaluates when braces balance; C-j forces a continuation line.\n"))

(defvar crispy-repl--type-candidates
  '("int" "unsigned int" "long" "unsigned long" "short" "char"
    "float" "double" "char *" "const char *" "void *"
    "gint" "guint" "gboolean" "gchar *" "gsize" "gint64")
  "C types `crispy-repl--type-probe' can identify, in match order.")

(defun crispy-repl--type-probe (expr)
  "Return a crispy block statement that prints the static C type of EXPR.
Same trick as the terminal crispy REPL: `__builtin_types_compatible_p'
classifies the expression at compile time.  A block statement is
neither preamble material nor an expression, so it executes with the
preamble in scope and does not persist into it."
  (concat "{ __typeof__(" expr ") _cmacs_type_probe;"
          " (void)_cmacs_type_probe;\n"
          "printf(\"%s\\n\",\n"
          (mapconcat
           (lambda (type)
             (format
              "__builtin_types_compatible_p(__typeof__(%s), %s) ? \"%s\" :\n"
              expr type type))
           crispy-repl--type-candidates "")
          "\"(other type)\"); }"))

(defun crispy-repl--cmd-type (arg)
  "Handle :type ARG."
  (if (not arg)
      "usage: :type EXPR"
    (condition-case nil
        (crispy-repl--eval-c (crispy-repl--type-probe arg))
      (crispy-error (format "error: cannot determine type of %s" arg)))))

(defun crispy-repl--format-plist (header plist)
  "Format HEADER and a flat cintrospect PLIST as aligned lines."
  (let (lines)
    (while plist
      (let ((key (car plist))
            (val (cadr plist)))
        (unless (or (null val) (memq key '(:fields :values)))
          (push (format "  %-12s %s"
                        (substring (symbol-name key) 1)
                        (if (and (eq key :addr) (integerp val))
                            (format "%#x" val)
                          val))
                lines)))
      (setq plist (cddr plist)))
    (concat header "\n" (mapconcat #'identity (nreverse lines) "\n"))))

(defun crispy-repl--format-type (name info)
  "Format `cmacs-c-type-info' result INFO for type NAME."
  (concat
   (crispy-repl--format-plist (format "type %s" name) info)
   (let ((fields (plist-get info :fields)))
     (when fields
       (concat "\n  fields:\n"
               (mapconcat
                (lambda (f)
                  (format "    +%-5d %-8s %-24s %s"
                          (or (plist-get f :addr) 0)
                          (format "(%d)" (or (plist-get f :size) 0))
                          (or (plist-get f :symbol-name) "?")
                          (or (plist-get f :type-name)
                              (plist-get f :type) "")))
                fields "\n"))))
   (let ((values (plist-get info :values)))
     (when values
       (concat "\n  values:\n"
               (mapconcat (lambda (v) (format "    %s" v))
                          values "\n"))))))

(defun crispy-repl--cmd-info (arg)
  "Handle :info ARG via cintrospect."
  (cond
   ((not arg) "usage: :info NAME")
   ((not (fboundp 'cmacs-c-type-info))
    "cintrospect not available (rebuild with --with-cmacs-cintrospect)")
   (t
    (let ((type (cmacs-c-type-info arg)))
      (if type
          (crispy-repl--format-type arg type)
        (let ((sym (cmacs-c-symbol-info arg)))
          (if sym
              (crispy-repl--format-plist (format "symbol %s" arg) sym)
            (let* ((lisp-sym (intern-soft arg))
                   (info (and lisp-sym (cmacs-c-defun-info lisp-sym))))
              (if info
                  (crispy-repl--format-plist (format "DEFUN %s" arg) info)
                (format "no C type, symbol, or DEFUN named %s" arg))))))))))

(defun crispy-repl--cmd-def (arg)
  "Handle :def ARG — show and visit the source of C function ARG."
  (cond
   ((not arg) "usage: :def NAME")
   ((not (fboundp 'cmacs-c-function-source))
    "cintrospect not available (rebuild with --with-cmacs-cintrospect)")
   (t
    (let ((loc (cmacs-c-function-source arg)))
      (if (not loc)
          (format "no source location for %s" arg)
        (let ((file (car loc))
              (line (cdr loc)))
          (when (file-readable-p file)
            (save-selected-window
              (with-current-buffer (find-file-other-window file)
                (goto-char (point-min))
                (forward-line (1- line)))))
          (format "%s → %s:%d" arg file line)))))))

(defun crispy-repl--cmd-doc (arg)
  "Handle :doc ARG — docstring of a Lisp function or variable."
  (if (not arg)
      "usage: :doc NAME"
    (let ((sym (intern-soft arg)))
      (cond
       ((null sym) (format "no Lisp symbol named %s" arg))
       ((fboundp sym)
        (or (documentation sym)
            (format "%s is a function with no documentation" arg)))
       ((boundp sym)
        (or (documentation-property sym 'variable-documentation)
            (format "%s is a variable with no documentation" arg)))
       (t (format "%s is neither a function nor a variable" arg))))))

(defun crispy-repl--cmd-browse (arg)
  "Handle :browse ARG — list C symbols matching a glob."
  (cond
   ((not arg) "usage: :browse GLOB")
   ((not (fboundp 'cmacs-c-list))
    "cintrospect not available (rebuild with --with-cmacs-cintrospect)")
   (t
    (let ((syms (cmacs-c-list 'symbol arg 200)))
      (if (not syms)
          (format "no C symbols match %s" arg)
        (concat
         (mapconcat
          (lambda (s)
            (format "  %-40s %-8s %s"
                    (or (plist-get s :symbol-name) "?")
                    (or (plist-get s :kind) "")
                    (or (plist-get s :object) "")))
          syms "\n")
         (when (>= (length syms) 200)
           "\n  ... (truncated at 200)")))))))

(defun crispy-repl--cmd-preamble (_arg)
  "Handle :preamble — show the accumulated REPL preamble."
  (let ((preamble (if (fboundp 'crispy-repl-preamble)
                      (crispy-repl-preamble)
                    "")))
    (if (string-empty-p preamble)
        "(preamble is empty)"
      (concat "--- preamble ---\n" preamble
              (if (string-suffix-p "\n" preamble) "" "\n")
              "--- end ---"))))

(defun crispy-repl--cmd-load (arg)
  "Handle :load ARG — load a C file into the REPL preamble."
  (if (not arg)
      "usage: :load FILE"
    (let ((file (expand-file-name arg)))
      (if (not (file-readable-p file))
          (format "cannot read %s" file)
        (let ((contents (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string))))
          (condition-case err
              (progn
                ;; A leading `#' makes the REPL classify the whole blob
                ;; as preamble; #if 1 / #endif is semantically a no-op.
                (crispy-repl--eval-c
                 (concat "#if 1\n" contents
                         (if (string-suffix-p "\n" contents) "" "\n")
                         "#endif\n"))
                (format "loaded %s into preamble" file))
            (crispy-error
             (format "error loading %s: %s" file (cadr err)))))))))

(defun crispy-repl--cmd-reset (_arg)
  "Handle :reset — clear the persistent REPL state."
  (crispy-repl-reset)
  "REPL state reset.")

(defun crispy-repl--cmd-clear (_arg)
  "Handle :clear — erase the REPL buffer."
  (let ((inhibit-read-only t))
    (delete-region (point-min) (point-max)))
  "")

(defun crispy-repl--cmd-cache (_arg)
  "Handle :cache — show the crispy cache directory."
  (or (crispy-cache-status) "(no cache directory)"))

(defun crispy-repl--cmd-elisp (arg)
  "Handle :elisp ARG — evaluate ARG as Emacs Lisp."
  (if (not arg)
      "usage: :elisp EXPR"
    (condition-case err
        (format "=> %S" (eval (read arg) t))
      (error (format "error: %S" err)))))

(defun crispy-repl--cmd-bacon (arg)
  "Handle :bacon ARG — run a shell command via bacon when available."
  (cond
   ((not arg) "usage: :bacon CMD  (alias :!)")
   ((and (fboundp 'bacon-running-p) (bacon-running-p))
    (pcase-let ((`(,rc . ,output) (bacon-eval arg)))
      (concat output
              (when (and (integerp rc) (/= rc 0))
                (format "%s[exit %d]"
                        (if (string-suffix-p "\n" (or output "")) "" "\n")
                        rc)))))
   (t
    (concat (shell-command-to-string arg)
            "(bacon not running — used shell-command)\n"))))

(defun crispy-repl--cmd-quit (_arg)
  "Handle :quit — bury the REPL buffer."
  (bury-buffer)
  "")

;;; Multiline input

(defun crispy-repl--depth-delta (code)
  "Net {([ vs })] depth of CODE, ignoring literals and comments.
Elisp port of the terminal REPL's compute_depth_delta: skips string
and character literals (with backslash escapes), // line comments,
and /* */ block comments."
  (let ((depth 0)
        (i 0)
        (n (length code))
        (state nil))
    (while (< i n)
      (let ((c (aref code i)))
        (pcase state
          ('string
           (cond ((eq c ?\\) (setq i (1+ i)))
                 ((eq c ?\") (setq state nil))))
          ('char
           (cond ((eq c ?\\) (setq i (1+ i)))
                 ((eq c ?\') (setq state nil))))
          ('line-comment
           (when (eq c ?\n) (setq state nil)))
          ('block-comment
           (when (and (eq c ?*) (< (1+ i) n)
                      (eq (aref code (1+ i)) ?/))
             (setq state nil)
             (setq i (1+ i))))
          (_
           (cond
            ((eq c ?\") (setq state 'string))
            ((eq c ?\') (setq state 'char))
            ((and (eq c ?/) (< (1+ i) n) (eq (aref code (1+ i)) ?/))
             (setq state 'line-comment)
             (setq i (1+ i)))
            ((and (eq c ?/) (< (1+ i) n) (eq (aref code (1+ i)) ?*))
             (setq state 'block-comment)
             (setq i (1+ i)))
            ((memq c '(?{ ?\( ?\[)) (setq depth (1+ depth)))
            ((memq c '(?} ?\) ?\])) (setq depth (1- depth)))))))
      (setq i (1+ i)))
    depth))

(defun crispy-repl-return ()
  "Send the input if its delimiters balance, else continue on a new line."
  (interactive)
  (let* ((proc (get-buffer-process (current-buffer)))
         (input (and proc
                     (buffer-substring-no-properties
                      (process-mark proc) (point-max))))
         (depth (if input (crispy-repl--depth-delta input) 0)))
    (if (> depth 0)
        (insert "\n" (make-string (* 2 depth) ?\s))
      (comint-send-input))))

(defun crispy-repl-newline ()
  "Insert a continuation newline without sending the input."
  (interactive)
  (insert "\n"))

;;; Completion

(defun crispy-repl--completion-at-point ()
  "Complete colon-command names at the start of the REPL input."
  (let ((start (comint-line-beginning-position)))
    (when (save-excursion
            (goto-char start)
            (looking-at ":[a-z!?]*"))
      (let ((end (match-end 0)))
        (when (and (>= (point) start) (<= (point) end))
          (list start end
                (append (mapcar #'car crispy-repl-commands)
                        (apply #'append
                               (mapcar #'cadr crispy-repl-commands)))
                :exclusive 'no
                :annotation-function
                (lambda (cand)
                  (let ((entry (crispy-repl--lookup-command cand)))
                    (when entry
                      (concat "  " (nth 4 entry)))))))))))

;;; REPL mode

(defvar crispy-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "RET") #'crispy-repl-return)
    (define-key map (kbd "M-RET") #'crispy-repl-send-input)
    (define-key map (kbd "C-c C-c") #'crispy-repl-send-input)
    (define-key map (kbd "C-j") #'crispy-repl-newline)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "C-c C-r") #'crispy-repl-reset-state)
    (define-key map (kbd "C-c C-z") #'bury-buffer)
    map)
  "Keymap for `crispy-repl-mode'.")

(define-derived-mode crispy-repl-mode comint-mode "Crispy"
  "Major mode for the Crispy C REPL.

This mode provides an interactive C evaluation environment powered
by the Crispy runtime compiler.  C code entered at the prompt is
compiled and executed on the fly in a persistent REPL: #include
directives, function definitions, and type declarations accumulate
in a preamble that stays in scope, and bare expressions are
auto-printed as \"=> VALUE\".

GHCi-style colon commands are available; type :help for the list.

\\{crispy-repl-mode-map}"
  :group 'crispy
  (setq-local comint-prompt-regexp
              (concat "^" (regexp-quote crispy-repl-prompt)))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'crispy-repl--input-sender)
  (setq-local comint-process-echoes nil)
  (add-hook 'completion-at-point-functions
            #'crispy-repl--completion-at-point nil t))

(defun crispy-repl--send-output (string)
  "Send STRING plus a fresh prompt through comint's output filter.
This is the only insertion path into the REPL buffer: routing
through `comint-output-filter' is what applies
`comint-prompt-read-only' to the trailing prompt."
  (let ((proc (get-buffer-process (current-buffer))))
    (comint-output-filter
     proc
     (concat string
             (if (or (string-empty-p string)
                     (string-suffix-p "\n" string))
                 ""
               "\n")
             crispy-repl-prompt))))

(defun crispy-repl--input-sender (proc input)
  "Evaluate INPUT (C code or a colon command) and print the result.
PROC is the dummy comint process; evaluation happens in-process."
  (let* ((input (string-trim input))
         (output
          (cond
           ((string-empty-p input) "")
           ((string-prefix-p ":" input)
            (crispy-repl--dispatch-command input))
           (t
            (condition-case err
                (crispy-repl--eval-c input)
              (crispy-error (format "error: %s" (cadr err)))
              (error (format "error: %S" err)))))))
    (with-current-buffer (process-buffer proc)
      (crispy-repl--send-output (or output "")))))

(defun crispy-repl-send-input ()
  "Send the current input to the Crispy REPL unconditionally."
  (interactive)
  (comint-send-input))

(defun crispy-repl-reset-state ()
  "Reset the persistent crispy REPL state (clear the preamble)."
  (interactive)
  (crispy-repl-reset)
  (message "crispy REPL state reset"))

;;;###autoload
(defun crispy-repl ()
  "Open (or switch to) the Crispy C REPL buffer."
  (interactive)
  (unless (fboundp 'crispy-eval-string)
    (user-error "Crispy not available — rebuild with --with-cmacs-crispy"))
  (let ((buf (get-buffer-create crispy-repl-buffer-name)))
    (unless (comint-check-proc buf)
      (with-current-buffer buf
        ;; Start a dummy process for comint to hang its state on.
        ;; Actual evaluation goes through crispy-repl-eval-string.
        (let ((proc (start-process "crispy-repl" buf "cat")))
          (set-process-query-on-exit-flag proc nil)
          (crispy-repl-mode)
          (insert
           (propertize
            (concat
             (format "Crispy C REPL [CMacs %s] — persistent preamble; \
expressions auto-print.\n"
                     (if (boundp 'cmacs-version) cmacs-version "0.1.0"))
             "Type :help for commands.  RET evaluates when braces \
balance.\n\n")
            'font-lock-face 'font-lock-comment-face))
          (set-marker (process-mark proc) (point))
          (crispy-repl--send-output ""))))
    (pop-to-buffer buf)))

;;; Evaluation commands

;;;###autoload
(defun crispy-eval-region (start end)
  "Evaluate the region from START to END as C code via Crispy.
Displays the result in the echo area."
  (interactive "r")
  (let* ((code (buffer-substring-no-properties start end))
         (result (crispy-eval-string code)))
    (if (string-empty-p result)
        (message "(crispy: no output)")
      (message "%s" result))))

;;;###autoload
(defun crispy-eval-buffer ()
  "Evaluate the current buffer as a C script via Crispy.
If the buffer is visiting a file, uses `crispy-run' on the file.
Otherwise, sends the buffer contents to `crispy-eval-string'."
  (interactive)
  (if buffer-file-name
      (let ((rc (crispy-run buffer-file-name)))
        (message "crispy: exit code %d" rc))
    (let ((result (crispy-eval-string
                   (buffer-substring-no-properties
                    (point-min) (point-max)))))
      (if (string-empty-p result)
          (message "(crispy: no output)")
        (message "%s" result)))))

;;;###autoload
(defun crispy-eval-defun ()
  "Evaluate the C function at point.
Attempts to find the enclosing function definition and evaluate it."
  (interactive)
  (save-excursion
    (let (start end)
      ;; Find function start: line matching a return type + name pattern
      ;; or an opening brace at column 0.
      (beginning-of-defun)
      (setq start (point))
      (end-of-defun)
      (setq end (point))
      (crispy-eval-region start end))))

;;; Minor mode for C buffers

(defvar crispy-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'crispy-eval-defun)
    (define-key map (kbd "C-c C-r") #'crispy-eval-region)
    (define-key map (kbd "C-c C-b") #'crispy-eval-buffer)
    (define-key map (kbd "C-c C-z") #'crispy-repl)
    map)
  "Keymap for `crispy-minor-mode'.")

;;;###autoload
(define-minor-mode crispy-minor-mode
  "Minor mode for evaluating C code via Crispy.

Provides keybindings for sending C code from the current buffer
to the Crispy runtime compiler.

\\{crispy-minor-mode-map}"
  :lighter " Crispy"
  :keymap crispy-minor-mode-map
  :group 'crispy)

(provide 'cmacs-crispy)
;;; cmacs-crispy.el ends here
