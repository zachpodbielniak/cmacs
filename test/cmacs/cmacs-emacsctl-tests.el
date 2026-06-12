;;; cmacs-emacsctl-tests.el --- Tests for the emacsctl CLI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for emacsctl/cmacsctl, the standalone kubectl-style
;; control client (cmacs/emacsctl/), exercised against THIS emacs via
;; its D-Bus service.
;;
;; Conventions (see cmacs-dbus-tests.el): the binary is spawned with
;; `make-process' and the cmacs main loop is pumped while it runs ---
;; `call-process' would deadlock the inbound D-Bus dispatch.  Every
;; invocation passes --instance (emacs-pid) so a second running cmacs
;; cannot swallow the calls.

;;; Code:

(require 'ert)

(defvar cmacs-emacsctl-tests--binary
  (expand-file-name
   "../../src/emacsctl"
   (file-name-directory (or load-file-name buffer-file-name
                            default-directory)))
  "Path to the freshly built emacsctl binary.")

(defun cmacs-emacsctl-tests--available-p ()
  "Non-nil when the emacsctl binary and the D-Bus service exist."
  (and (fboundp 'cmacs-dbus-start)
       (file-executable-p cmacs-emacsctl-tests--binary)))

(defmacro cmacs-emacsctl-tests--with-service (&rest body)
  "Start the D-Bus service, run BODY, always stop."
  (declare (indent 0))
  `(unwind-protect
       (progn (cmacs-dbus-start) ,@body)
     (cmacs-dbus-stop)))

(defun cmacs-emacsctl-tests--run (&rest args)
  "Run emacsctl with ARGS; return (EXIT-CODE . OUTPUT).
Pumps the cmacs main loop while the child runs so the embedded
D-Bus service can dispatch the inbound calls."
  (let* ((buf (generate-new-buffer " *emacsctl-test*"))
         (proc (make-process
                :name "emacsctl-test"
                :command (append (list cmacs-emacsctl-tests--binary
                                       "--instance"
                                       (number-to-string (emacs-pid)))
                                 args)
                :buffer buf
                :noquery t
                :sentinel #'ignore)))
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1)
            (sit-for 0.05))
          (cons (process-exit-status proc)
                (with-current-buffer buf (buffer-string))))
      (kill-buffer buf))))

;;; Client-only behavior (no editor needed)

(ert-deftest cmacs-emacsctl-version ()
  "--version prints the client version and exits 0."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "--version")))
    (should (= 0 (car result)))
    (should (string-match-p "emacsctl" (cdr result)))))

(ert-deftest cmacs-emacsctl-help ()
  "help lists commands, groups and global flags, exits 0."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "help")))
    (should (= 0 (car result)))
    (should (string-match-p "Usage:" (cdr result)))
    (should (string-match-p "Command groups" (cdr result)))
    (should (string-match-p "--output" (cdr result)))
    (should (string-match-p "crispy" (cdr result)))))

(ert-deftest cmacs-emacsctl-group-help ()
  "GROUP --help lists the group's subcommands, exits 0."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "get" "--help")))
    (should (= 0 (car result)))
    (should (string-match-p "Subcommands of 'get'" (cdr result)))
    (should (string-match-p "content-org" (cdr result))))
  ;; A bare group prints the same listing but fails (exit 2).
  (should (= 2 (car (cmacs-emacsctl-tests--run "get")))))

(ert-deftest cmacs-emacsctl-command-help ()
  "CMD --help shows the command's own flags and the global options."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "logs" "--help")))
    (should (= 0 (car result)))
    (should (string-match-p "emacsctl logs" (cdr result)))
    (should (string-match-p "--lines" (cdr result)))
    (should (string-match-p "Global Options" (cdr result))))
  ;; help WORDS… is equivalent to WORDS… --help.
  (let ((result (cmacs-emacsctl-tests--run "help" "get"
                                           "content-org")))
    (should (= 0 (car result)))
    (should (string-match-p "--no-body" (cdr result)))))

(ert-deftest cmacs-emacsctl-unknown-flag ()
  "An unknown per-command flag exits 2 with a --help hint."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "logs" "--bogus")))
    (should (= 2 (car result)))
    (should (string-match-p "logs --help" (cdr result)))))

(ert-deftest cmacs-emacsctl-unknown-command ()
  "An unknown command exits 2."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (should (= 2 (car (cmacs-emacsctl-tests--run "frobnicate")))))

(ert-deftest cmacs-emacsctl-typo-suggestion ()
  "A typo'd verb blames the subcommand and suggests the fix."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "get" "nuffers")))
    (should (= 2 (car result)))
    (should (string-match-p "unknown subcommand 'nuffers' for 'get'"
                            (cdr result)))
    (should (string-match-p "get buffers" (cdr result)))))

(ert-deftest cmacs-emacsctl-completion-script ()
  "completion bash emits a script delegating to __complete."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let ((result (cmacs-emacsctl-tests--run "completion" "bash")))
    (should (= 0 (car result)))
    (should (string-match-p "__complete" (cdr result)))))

(ert-deftest cmacs-emacsctl-config-init-and-use-context ()
  "config init writes the boilerplate; use-context switches it."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let* ((dir (make-temp-file "emacsctl-cfg" t))
         (path (expand-file-name "emacsctl.yaml" dir)))
    (unwind-protect
        (progn
          (should (= 0 (car (cmacs-emacsctl-tests--run
                             "--config" path "config" "init" path))))
          (should (file-exists-p path))
          (should (= 0 (car (cmacs-emacsctl-tests--run
                             "--config" path "config" "view"))))
          (should (= 0 (car (cmacs-emacsctl-tests--run
                             "--config" path "config" "use-context"
                             "local"))))
          ;; The comment lines survive the rewrite.
          (with-temp-buffer
            (insert-file-contents path)
            (should (string-match-p "primary | auto" (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest cmacs-emacsctl-bad-instance-exit-code ()
  "A nonexistent --instance exits 4."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (let* ((buf (generate-new-buffer " *emacsctl-test*"))
         (proc (make-process
                :name "emacsctl-test"
                :command (list cmacs-emacsctl-tests--binary
                               "--instance" "999999999" "eval" "t")
                :buffer buf :noquery t :sentinel #'ignore)))
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1)
            (sit-for 0.05))
          (should (= 4 (process-exit-status proc))))
      (kill-buffer buf))))

;;; Round-trips against this emacs

(ert-deftest cmacs-emacsctl-eval-elisp ()
  "eval returns the printed elisp result."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((result (cmacs-emacsctl-tests--run "eval" "(+ 1 2)")))
      (should (= 0 (car result)))
      (should (equal "3\n" (cdr result))))))

(ert-deftest cmacs-emacsctl-eval-raw-byte-exact ()
  "-o raw output is byte-exact (no trailing newline added)."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((result (cmacs-emacsctl-tests--run "-o" "raw" "eval"
                                             "(* 6 7)")))
      (should (= 0 (car result)))
      (should (equal "42" (cdr result))))))

(ert-deftest cmacs-emacsctl-get-buffers-json ()
  "get buffers -o json parses and contains *scratch*."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (get-buffer-create "*scratch*")
    (let* ((result (cmacs-emacsctl-tests--run "-o" "json"
                                              "get" "buffers"))
           (parsed (json-parse-string (cdr result) :array-type 'list)))
      (should (= 0 (car result)))
      (should (member "*scratch*" parsed)))))

(ert-deftest cmacs-emacsctl-get-buffers-yaml ()
  "get buffers -o yaml emits a YAML sequence."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((result (cmacs-emacsctl-tests--run "-o" "yaml"
                                             "get" "buffers")))
      (should (= 0 (car result)))
      (should (string-match-p "^- " (cdr result))))))

(ert-deftest cmacs-emacsctl-buffer-roundtrip ()
  "buffer create/exists/kill round-trips."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((name "*emacsctl-ert-test*"))
      (should (= 0 (car (cmacs-emacsctl-tests--run
                         "buffer" "create" name))))
      (should (equal "true\n"
                     (cdr (cmacs-emacsctl-tests--run
                           "buffer" "exists" name))))
      (should (= 0 (car (cmacs-emacsctl-tests--run
                         "buffer" "kill" name))))
      (should (equal "false\n"
                     (cdr (cmacs-emacsctl-tests--run
                           "buffer" "exists" name)))))))

(ert-deftest cmacs-emacsctl-describe-instance ()
  "describe instance reports this process's pid and features."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let* ((result (cmacs-emacsctl-tests--run "-o" "json"
                                              "describe" "instance"))
           (parsed (json-parse-string (cdr result)
                                      :object-type 'alist)))
      (should (= 0 (car result)))
      (should (= (emacs-pid) (alist-get 'pid parsed))))))

(ert-deftest cmacs-emacsctl-logs ()
  "logs -n returns recent *Messages* content."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (message "emacsctl-ert-log-marker")
    (let ((result (cmacs-emacsctl-tests--run "logs" "-n" "5")))
      (should (= 0 (car result)))
      (should (string-match-p "emacsctl-ert-log-marker"
                              (cdr result))))))

(ert-deftest cmacs-emacsctl-eshell-eval ()
  "eshell eval runs a command in the editor's eshell."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((result (cmacs-emacsctl-tests--run
                   "eshell" "eval" "echo emacsctl-eshell-ok")))
      (should (= 0 (car result)))
      (should (string-match-p "emacsctl-eshell-ok" (cdr result))))))

(ert-deftest cmacs-emacsctl-bacon-eval ()
  "bacon eval returns the captured output and exit code 0."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (skip-unless (fboundp 'bacon-start))
  (cmacs-emacsctl-tests--with-service
    (let ((result (cmacs-emacsctl-tests--run
                   "bacon" "eval" "echo emacsctl-bacon-ok")))
      (should (= 0 (car result)))
      (should (string-match-p "emacsctl-bacon-ok" (cdr result))))))

(ert-deftest cmacs-emacsctl-input-command ()
  "input command runs an interactive command."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (should (= 0 (car (cmacs-emacsctl-tests--run
                       "input" "command" "ignore"))))))

(ert-deftest cmacs-emacsctl-text-buffer-flag ()
  "text insert/append/line/delete target a buffer via --buffer."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((buf "*ctl-text-ert*"))
      (unwind-protect
          (progn
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "buffer" "create" buf))))
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "text" "insert" "--buffer" buf
                               "alpha"))))
            ;; Dash-leading text needs the standard `--' separator.
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "text" "append" "-b" buf
                               "--" "-beta"))))
            (should (equal "alpha-beta"
                           (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
            (should (equal "alpha-beta\n"
                           (cdr (cmacs-emacsctl-tests--run
                                 "text" "line" "1" "--buffer" buf))))
            ;; Delete "alpha" (chars 1..6), leaving "-beta".
            (should (equal "alpha\n"
                           (cdr (cmacs-emacsctl-tests--run
                                 "text" "delete" "1" "6"
                                 "--buffer" buf))))
            (should (equal "-beta"
                           (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max))))))
        (ignore-errors (kill-buffer buf))))))

(ert-deftest cmacs-emacsctl-text-escapes ()
  "text insert -e expands backslash escapes like echo -e."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((buf "*ctl-text-esc*"))
      (unwind-protect
          (progn
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "buffer" "create" buf))))
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "text" "insert" "-e" "--buffer" buf
                               "a\\tb\\n\\x41\\0102\\\\\\q"))))
            (should (equal "a\tb\nAB\\\\q"
                           (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
            ;; Without -e the backslashes stay literal.
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "text" "insert" "--buffer" buf
                               "\\n"))))
            (should (string-suffix-p "\\n"
                                     (with-current-buffer buf
                                       (buffer-string)))))
        (ignore-errors (kill-buffer buf))))))

(ert-deftest cmacs-emacsctl-text-stdin ()
  "text insert reads from stdin when no TEXT argument is given."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (let ((buf "*ctl-text-stdin*"))
      (unwind-protect
          (progn
            (should (= 0 (car (cmacs-emacsctl-tests--run
                               "buffer" "create" buf))))
            (let* ((outbuf (generate-new-buffer " *emacsctl-stdin*"))
                   (proc (make-process
                          :name "emacsctl-stdin"
                          :command (list
                                    "sh" "-c"
                                    (format
                                     "printf 'piped-text' | %s --instance %d text insert --buffer '%s'"
                                     (shell-quote-argument
                                      cmacs-emacsctl-tests--binary)
                                     (emacs-pid) buf))
                          :buffer outbuf :noquery t
                          :sentinel #'ignore)))
              (unwind-protect
                  (progn
                    (while (process-live-p proc)
                      (accept-process-output proc 0.1)
                      (sit-for 0.05))
                    (should (= 0 (process-exit-status proc))))
                (kill-buffer outbuf)))
            (should (equal "piped-text"
                           (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max))))))
        (ignore-errors (kill-buffer buf))))))

(defun cmacs-emacsctl-tests--make-org-buffer (name)
  "Fill buffer NAME with a small org document."
  (with-current-buffer (get-buffer-create name)
    (erase-buffer)
    (insert "#+TITLE: CtlTest\n\n"
            "* TODO Top :work:\nbody one\n"
            "** DONE Child\n"
            "* Plain\n")
    (org-mode)))

(ert-deftest cmacs-emacsctl-get-content ()
  "get content returns the raw buffer text."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (cmacs-emacsctl-tests--make-org-buffer "*ctl-org-test*")
    (unwind-protect
        (let ((result (cmacs-emacsctl-tests--run
                       "get" "content" "*ctl-org-test*")))
          (should (= 0 (car result)))
          (should (string-match-p "#\\+TITLE: CtlTest" (cdr result)))
          (should (string-match-p "body one" (cdr result))))
      (kill-buffer "*ctl-org-test*"))))

(ert-deftest cmacs-emacsctl-get-content-org ()
  "get content-org returns a structured headline tree."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (cmacs-emacsctl-tests--make-org-buffer "*ctl-org-test*")
    (unwind-protect
        (let* ((result (cmacs-emacsctl-tests--run
                        "-o" "json" "get" "content-org"
                        "*ctl-org-test*"))
               (parsed (json-parse-string (cdr result)
                                          :object-type 'alist
                                          :array-type 'list))
               (headlines (alist-get 'headlines parsed))
               (top (car headlines)))
          (should (= 0 (car result)))
          (should (equal "CtlTest" (alist-get 'title parsed)))
          (should (= 2 (length headlines)))
          (should (equal "Top" (alist-get 'title top)))
          (should (equal "TODO" (alist-get 'todo top)))
          (should (equal '("work") (alist-get 'tags top)))
          (should (equal "body one" (alist-get 'body top)))
          (should (equal "Child"
                         (alist-get 'title
                                    (car (alist-get 'children top)))))
          ;; The sibling with no body/children carries neither key.
          (should-not (alist-get 'body (cadr headlines)))
          (should-not (alist-get 'children (cadr headlines))))
      (kill-buffer "*ctl-org-test*"))))

(ert-deftest cmacs-emacsctl-get-content-org-filtered ()
  "get content-org --match filters with org's agenda matcher."
  (skip-unless (cmacs-emacsctl-tests--available-p))
  (cmacs-emacsctl-tests--with-service
    (cmacs-emacsctl-tests--make-org-buffer "*ctl-org-test*")
    (unwind-protect
        (let* ((result (cmacs-emacsctl-tests--run
                        "-o" "json" "get" "content-org"
                        "*ctl-org-test*" "--match" "/TODO"
                        "--no-body"))
               (parsed (json-parse-string (cdr result)
                                          :object-type 'alist
                                          :array-type 'list))
               (headlines (alist-get 'headlines parsed)))
          (should (= 0 (car result)))
          (should (= 1 (length headlines)))
          (should (equal "Top" (alist-get 'title (car headlines))))
          (should-not (alist-get 'body (car headlines))))
      (kill-buffer "*ctl-org-test*"))))

(provide 'cmacs-emacsctl-tests)
;;; cmacs-emacsctl-tests.el ends here
