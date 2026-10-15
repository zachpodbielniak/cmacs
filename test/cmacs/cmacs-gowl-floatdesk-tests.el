;;; cmacs-gowl-floatdesk-tests.el --- Tests for the floating desktop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl's floating desktop (the `floatdesk' module):
;; the settings it pushes (and the one it deliberately does not), the
;; commands each function sends, ERROR replies becoming user errors, the
;; module's announcements driving the changed hook, the RPC entry point
;; that never signals, the default keybinds, and the D-Bus, emacsctl and
;; bacon surfaces.  The last test runs the real module in a second cmacs
;; on gowl's headless backend.  The module's own behaviour -- which
;; windows float, the state file, the dock -- is tested in gowl
;; (tests/test-floatdesk-state.c and tests/test-floatdesk-module.c).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-floatdesk)

;; Special, so the fake-compositor `let' below binds them dynamically
;; and `add-hook' lands in the binding.
(defvar cmacs-gowl-module-event-functions)
(defvar cmacs-gowl-tag-changed-functions)
(defvar cmacs-gowl-layout-changed-functions)
(defvar cmacs-gowl-terminal-command)
(defvar cmacs-gowl-default-dropdown-terminal)

(defconst cmacs-gowl-floatdesk-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, for finding the source tree.")

(defun cmacs-gowl-floatdesk-tests--source-file (relative)
  "RELATIVE (to the source tree root) as an absolute name, or nil."
  (let ((f (expand-file-name (concat "../../" relative)
                             (file-name-directory
                              cmacs-gowl-floatdesk-tests--this-file))))
    (and (file-readable-p f) f)))

(defmacro cmacs-gowl-floatdesk-tests--with-fake-gowl (reply &rest body)
  "Run BODY with a fake running compositor answering REPLY to commands.
REPLY is a function of the command line.  Binds `enabled' (module
loads), `configured' (settings pushed) and `commands' (every line sent,
newest first)."
  (declare (indent 1))
  `(let ((enabled nil) (configured nil) (commands nil)
         (cmacs-gowl-module-event-functions nil)
         (cmacs-gowl-tag-changed-functions nil)
         (cmacs-gowl-layout-changed-functions nil)
         (cmacs-gowl-floatdesk--refresh-timer nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-enable-module)
                (lambda (&rest args) (push args enabled) t))
               ((symbol-function 'gowl-configure-module)
                (lambda (&rest args) (push args configured) t))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (push line commands)
                  (funcall ,reply line))))
       (unwind-protect
           (progn ,@body)
         (when (timerp cmacs-gowl-floatdesk--refresh-timer)
           (cancel-timer cmacs-gowl-floatdesk--refresh-timer))))))

(defun cmacs-gowl-floatdesk-tests--ok (line)
  "A module that is loaded and answers everything."
  (cond ((equal line "floatdesk-status")
         "OK view=1 view-floating=0 default=0 floating-tags= tiled-tags= minimized= dock=bottom autohide=0 pins=firefox state=/x")
        ((string-prefix-p "floatdesk-toggle" line) "OK tag 1 floating")
        (t "OK")))

;;;; Settings

(ert-deftest cmacs-gowl-floatdesk-test-settings ()
  "The options become the module's string settings."
  (let ((cmacs-gowl-floatdesk-default-floating 'saved)
        (cmacs-gowl-floatdesk-width-pct 0.5)
        (cmacs-gowl-floatdesk-titlebars nil)
        (cmacs-gowl-floatdesk-dock-position 'left)
        (cmacs-gowl-floatdesk-dock-pins '("firefox" "foot"))
        (cmacs-gowl-floatdesk-terminal "kitty"))
    (let ((s (cmacs-gowl-floatdesk--settings)))
      ;; `saved' sends nothing, so the state file's default survives a
      ;; restart; t / nil decide it.
      (should-not (assoc "default-floating" s))
      (should (equal (cdr (assoc "width-pct" s)) "0.5"))
      (should (equal (cdr (assoc "titlebars" s)) "false"))
      (should (equal (cdr (assoc "dock-position" s)) "left"))
      (should (equal (cdr (assoc "pins" s)) "firefox\nfoot"))
      (should (equal (cdr (assoc "terminal" s)) "kitty")))
    (let ((cmacs-gowl-floatdesk-default-floating t))
      (should (equal (cdr (assoc "default-floating"
                                 (cmacs-gowl-floatdesk--settings)))
                     "true")))
    (let ((cmacs-gowl-floatdesk-default-floating nil))
      (should (equal (cdr (assoc "default-floating"
                                 (cmacs-gowl-floatdesk--settings)))
                     "false")))
    ;; No pins configured: the key is left out, not sent empty.
    (let ((cmacs-gowl-floatdesk-dock-pins nil))
      (should-not (assoc "pins" (cmacs-gowl-floatdesk--settings))))))

(ert-deftest cmacs-gowl-floatdesk-test-terminal-fallback ()
  "TUIs run in the session's terminal unless told otherwise."
  (let ((cmacs-gowl-floatdesk-terminal nil)
        (cmacs-gowl-terminal-command "foot -o font=x")
        (cmacs-gowl-default-dropdown-terminal "gst"))
    (should (equal (cmacs-gowl-floatdesk--terminal) "foot -o font=x"))
    (let ((cmacs-gowl-terminal-command nil))
      (should (equal (cmacs-gowl-floatdesk--terminal) "gst")))))

;;;; Commands

(ert-deftest cmacs-gowl-floatdesk-test-start-loads-when-missing ()
  "Start loads the module only when it does not answer, then configures."
  (let ((loaded nil))
    (cmacs-gowl-floatdesk-tests--with-fake-gowl
        (lambda (line)
          (if (and (equal line "floatdesk-status") (not loaded))
              nil
            (cmacs-gowl-floatdesk-tests--ok line)))
      (cmacs-gowl-floatdesk-start)
      (should (equal enabled '(("floatdesk"))))
      (should (equal (car (car configured)) "floatdesk"))
      (should (memq #'cmacs-gowl-floatdesk--on-module-event
                    cmacs-gowl-module-event-functions))
      ;; Loaded already: not loaded twice.
      (setq loaded t enabled nil)
      (cmacs-gowl-floatdesk-start)
      (should-not enabled))))

(ert-deftest cmacs-gowl-floatdesk-test-command-lines ()
  "Each function sends the module word it names, with its arguments."
  (cmacs-gowl-floatdesk-tests--with-fake-gowl #'cmacs-gowl-floatdesk-tests--ok
    (cmacs-gowl-floatdesk-toggle)
    (cmacs-gowl-floatdesk-toggle 3)
    (cmacs-gowl-floatdesk-on 2)
    (cmacs-gowl-floatdesk-off)
    (cmacs-gowl-floatdesk-default-toggle)
    (cmacs-gowl-floatdesk-default-toggle 1)
    (cmacs-gowl-floatdesk-minimize 12)
    (cmacs-gowl-floatdesk-restore)
    (cmacs-gowl-floatdesk-maximize)
    (cmacs-gowl-floatdesk-snap 'left 12)
    (cmacs-gowl-floatdesk-dock-position 'top)
    (cmacs-gowl-floatdesk-dock-autohide -1)
    (cmacs-gowl-floatdesk-dock-pin "firefox" 0)
    (cmacs-gowl-floatdesk-dock-apps)
    (should (equal (reverse commands)
                   '("floatdesk-toggle" "floatdesk-toggle 3"
                     "floatdesk-on 2" "floatdesk-off"
                     "floatdesk-default toggle" "floatdesk-default on"
                     "floatdesk-minimize 12" "floatdesk-restore"
                     "floatdesk-maximize" "floatdesk-snap left 12"
                     "floatdesk-dock-position top"
                     "floatdesk-dock-autohide off"
                     "floatdesk-dock-pin firefox 0"
                     "floatdesk-dock-apps")))))

(ert-deftest cmacs-gowl-floatdesk-test-errors ()
  "An ERROR reply and a missing module are user errors."
  (cmacs-gowl-floatdesk-tests--with-fake-gowl
      (lambda (line)
        (if (string-suffix-p "missing" line) nil
          "ERROR the window is not on a floating desktop"))
    (should-error (cmacs-gowl-floatdesk-minimize) :type 'user-error)
    (should-error (cmacs-gowl-floatdesk--command "floatdesk-missing")
                  :type 'user-error))
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (should-error (cmacs-gowl-floatdesk-toggle) :type 'user-error)))

(ert-deftest cmacs-gowl-floatdesk-test-status-parse ()
  "Status and dock-status replies become alists and plists."
  (cmacs-gowl-floatdesk-tests--with-fake-gowl
      (lambda (line)
        (if (equal line "floatdesk-dock-status")
            "OK position=bottom autohide=0 shown=1 items=firefox:1:2:0:0;tui.btop:0:1:1:0"
          (cmacs-gowl-floatdesk-tests--ok line)))
    (let ((s (cmacs-gowl-floatdesk-status)))
      (should (equal (alist-get 'view s) "1"))
      (should (equal (alist-get 'dock s) "bottom"))
      (should (equal (alist-get 'pins s) "firefox"))
      (should (equal (alist-get 'floating-tags s) "")))
    (should (equal (cmacs-gowl-floatdesk-dock-items)
                   '((:app "firefox" :pinned t :windows 2 :minimized 0
                      :launching nil)
                     (:app "tui.btop" :pinned nil :windows 1 :minimized 1
                      :launching nil))))))

;;;; Hearing the module

(ert-deftest cmacs-gowl-floatdesk-test-module-events ()
  "The module's announcements run the changed hook, others' do not."
  (let ((seen nil)
        (cmacs-gowl-floatdesk-changed-functions nil)
        (cmacs-gowl-floatdesk--refresh-timer nil))
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) 'timer)))
      (add-hook 'cmacs-gowl-floatdesk-changed-functions
                (lambda (what detail) (push (list what detail) seen)))
      (cmacs-gowl-floatdesk--on-module-event "floatdesk" "mode 3 floating")
      (cmacs-gowl-floatdesk--on-module-event "broadcast" "on eq")
      (cmacs-gowl-floatdesk--on-module-event "floatdesk" "dock position left")
      (should (equal seen '((dock "position left") (mode "3 floating")))))))

(ert-deftest cmacs-gowl-floatdesk-test-lighter ()
  "The lighter shows only while the view floats."
  (let ((cmacs-gowl-floatdesk-lighter " Desk"))
    (let ((cmacs-gowl-floatdesk--view-floating nil))
      (should-not (cmacs-gowl-floatdesk--lighter)))
    (let ((cmacs-gowl-floatdesk--view-floating t))
      (should (equal (substring-no-properties (cmacs-gowl-floatdesk--lighter))
                     " Desk")))))

;;;; RPC

(ert-deftest cmacs-gowl-floatdesk-test-rpc-never-signals ()
  "The RPC entry point answers \"ERROR ...\" rather than signal."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (should (string-prefix-p "ERROR" (cmacs-gowl-floatdesk-rpc "status")))
    (should (string-prefix-p "ERROR" (cmacs-gowl-floatdesk-rpc "dance"))))
  (cmacs-gowl-floatdesk-tests--with-fake-gowl #'cmacs-gowl-floatdesk-tests--ok
    ;; A second command smuggled in on a new line is refused, unsent.
    (should (string-prefix-p "ERROR" (cmacs-gowl-floatdesk-rpc
                                      "toggle" "1\nfloatdesk-default on")))
    (should-not commands)
    (should (equal (cmacs-gowl-floatdesk-rpc "toggle" "3")
                   "OK tag 1 floating"))
    (should (member "floatdesk-toggle 3" commands))))

;;;; The surfaces, in the source

(ert-deftest cmacs-gowl-floatdesk-test-default-keybinds ()
  "The default binds reach the module by name on free keys, and the
module is in cmacs's default set."
  (let ((el (cmacs-gowl-floatdesk-tests--source-file "lisp/cmacs/cmacs-gowl.el"))
        (c (cmacs-gowl-floatdesk-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless (and el c))
    (with-temp-buffer
      (insert-file-contents el)
      (dolist (bind '(("Super+w" "floatdesk-toggle")
                      ("Super+n" "floatdesk-minimize")
                      ("Super+Shift+n" "floatdesk-restore")
                      ("Super+Shift+w" "floatdesk-dock-apps")))
        (goto-char (point-min))
        (should (re-search-forward
                 (format "(bind \"%s\" 'ipc-command \"%s\""
                         (regexp-quote (car bind)) (cadr bind))
                 nil t))
        ;; ... and nothing else claims the key.
        (goto-char (point-min))
        (should (= (how-many (format "(bind \"%s\" " (regexp-quote (car bind))))
                   1))))
    (with-temp-buffer
      (insert-file-contents c)
      (should (search-forward "\"floatdesk\" };" nil t)))))

(ert-deftest cmacs-gowl-floatdesk-test-dbus-source ()
  "D-Bus Floatdesk checks its verb and escapes its arguments; emacsctl
and the bacon builtin reach the same Elisp entry point."
  (let ((iface (cmacs-gowl-floatdesk-tests--source-file
                "cmacs/dbus/cmacs-dbus-iface-compositor.c"))
        (dispatch (cmacs-gowl-floatdesk-tests--source-file
                   "cmacs/glib/cmacs-eval-dispatch.c"))
        (ctl (cmacs-gowl-floatdesk-tests--source-file
              "cmacs/emacsctl/ctl-cmd-gowl.c"))
        (bacon (cmacs-gowl-floatdesk-tests--source-file
                "cmacs/bacon/modules/cmacs-gi-command.c")))
    (skip-unless (and iface dispatch ctl bacon))
    (with-temp-buffer
      (insert-file-contents iface)
      (should (search-forward "<method name='Floatdesk'>" nil t))
      (should (search-forward "cmacs_dispatch_gowl_floatdesk (verb, args"
                              nil t)))
    (with-temp-buffer
      (insert-file-contents dispatch)
      (should (re-search-forward "^cmacs_dispatch_gowl_floatdesk " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "g_strv_contains (verbs, verb)" body))
        (should (string-match-p "cmacs_dispatch_lisp_escape (args)" body))
        (should (string-match-p "cmacs-gowl-floatdesk-rpc" body))))
    (with-temp-buffer
      (insert-file-contents ctl)
      (should (search-forward "\"compositor floatdesk\"" nil t))
      (should (search-forward "\"Floatdesk\"" nil t)))
    (with-temp-buffer
      (insert-file-contents bacon)
      (should (search-forward "{ \"floatdesk\",    cmd_floatdesk," nil t))
      (goto-char (point-min))
      (should (re-search-forward "^cmd_floatdesk(" nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "cmacs_gi_lisp_escape(argv\\[2\\])" body))
        (should (string-match-p "cmacs_gi_lisp_escape(joined->str)" body))))))

;;;; Through the real module, in a second cmacs

(defun cmacs-gowl-floatdesk-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT): a private runtime and state directory, systemd
off, no parent display, pixman, fatal criticals."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-floatdesk-test-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_FLOATDESK_STATE"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        (concat "XDG_CACHE_HOME="
                                (expand-file-name "cache" runtime))
                        (concat "GOWL_MENU_FILE="
                                (expand-file-name
                                 "../../deps/gowl/data/menu.yaml"
                                 (file-name-directory
                                  cmacs-gowl-floatdesk-tests--this-file)))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "120" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defconst cmacs-gowl-floatdesk-tests--headless-form
  '(progn
     (defun test-wait (pred)
       (let ((n 0))
         (while (and (not (funcall pred)) (< n 100))
           (sit-for 0.05)
           (setq n (1+ n)))
         (funcall pred)))
     (gowl-start)
     (require 'cmacs-gowl)
     (require 'cmacs-gowl-floatdesk)
     (cmacs-gowl--install-hook-bridges)
     (setq cmacs-gowl-floatdesk-dock nil)
     (cmacs-gowl-floatdesk-start)
     (let ((events nil))
       (add-hook 'cmacs-gowl-floatdesk-changed-functions
                 (lambda (what detail) (push (cons what detail) events)))
       ;; Loaded, nothing floats.
       (unless (string-match-p "view-floating=0"
                               (gowl-run-command "floatdesk-status"))
         (error "A workspace floated before anyone asked"))
       (cmacs-gowl-floatdesk-toggle)
       (unless (equal (alist-get 'view-floating (cmacs-gowl-floatdesk-status))
                      "1")
         (error "The toggle did not float the view"))
       (unless (test-wait (lambda () (assq 'mode events)))
         (error "The module-event never reached Lisp"))
       ;; Saved where the state directory says.
       (let ((file (expand-file-name "gowl/floatdesk.yaml"
                                     (getenv "XDG_STATE_HOME"))))
         (unless (and (file-readable-p file)
                      (with-temp-buffer
                        (insert-file-contents file)
                        (search-forward "mode: floating" nil t)))
           (error "The mode was not saved to %s" file)))
       (cmacs-gowl-floatdesk-toggle)
       (unless (equal (alist-get 'view-floating (cmacs-gowl-floatdesk-status))
                      "0")
         (error "The second toggle did not tile the view"))
       ;; Minimize refuses a tiling workspace.
       (unless (string-prefix-p "ERROR" (cmacs-gowl-floatdesk-rpc "minimize"))
         (error "Minimize was not refused on a tiling workspace"))
       (unless (string-prefix-p "OK view=" (cmacs-gowl-floatdesk-rpc "status"))
         (error "rpc status did not answer"))
       (unless (string-prefix-p "ERROR" (cmacs-gowl-floatdesk-rpc "dance"))
         (error "rpc accepted an unknown verb")))
     (gowl-stop)
     (princ "cmacs-gowl-floatdesk: ok\n"))
  "What `cmacs-gowl-floatdesk-test-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-floatdesk-test-headless ()
  "The floatdesk module, driven from Elisp in a real compositor.
Loaded by default and floating nothing; the toggle floats and tiles the
view, the mode is saved under XDG_STATE_HOME, the module's announcement
reaches Lisp, minimize refuses a tiling workspace."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (let ((d (getenv "XDG_RUNTIME_DIR")))
                 (and d (file-directory-p d))))
  (let* ((result (cmacs-gowl-floatdesk-tests--run-headless
                  cmacs-gowl-floatdesk-tests--headless-form))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-match-p "cmacs-gowl-floatdesk: ok" output)))))

(provide 'cmacs-gowl-floatdesk-tests)

;;; cmacs-gowl-floatdesk-tests.el ends here
