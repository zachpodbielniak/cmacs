;;; cmacs-rig-tests.el --- End-to-end tests against a private cmacs --gowl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Every test here drives a RIG (cmacs-rig.el): a second cmacs running
;; `--gowl' on the headless backend with its own MCP server, D-Bus bus
;; and Wayland clients.  Nothing is stubbed.  A tool is called over the
;; socket, a text field is a real text-input-v3 client, a window is a
;; window.  The one thing replaced is the language model, by a
;; deterministic function installed INSIDE the child, because a test
;; must not depend on the network.
;;
;; These do NOT run under `make -C test check-cmacs'.  They are slower
;; than the unit suites (a compositor starts, programs are compiled and
;; launched) and they need gcc, wayland-scanner and a D-Bus daemon.
;; Every test skips unless CMACS_RIG is set in the environment, which
;; is what `just test-rig' does:
;;
;;   CMACS_RIG=1 src/emacs --batch -Q -L lisp/cmacs -L test/cmacs \
;;     --eval '(setq load-prefer-newer t)' -l ert \
;;     -l test/cmacs/cmacs-rig-tests.el -f ert-run-tests-batch-and-exit
;;
;; ONE RIG FOR THE FILE.  A compositor takes seconds to start, so the
;; tests share one (`cmacs-rig-tests--rig'), each cleaning up after
;; itself (`cmacs-rig-tests--reset').  ERT runs tests in name order and
;; any one may be run alone: none depends on another.  A test that
;; finds the child dead reports it and the next test starts a new rig.
;;
;; ADDING A CASE.  Write
;;
;;   (cmacs-rig-deftest my-feature ()
;;     "What must be true."
;;     (let ((field (cmacs-rig-spawn-field rig :text "hello")))
;;       (cmacs-rig-do rig '(my-command))
;;       (cmacs-rig-wait-field-text rig field "HELLO")))
;;
;; `rig' is bound in the body.  Use `cmacs-rig-do' for a command as the
;; person at the keyboard runs it and `cmacs-rig-eval' / the tool
;; helpers for what an agent sees: they are different callers, and the
;; redaction and journal code treats them differently on purpose.  The
;; child never waits: poll from here (`cmacs-rig-wait-for').
;;
;; A test for a bug that is not fixed yet is marked
;; `:expected-result :failed' with a comment naming the bug, so the
;; file stays green and turns red -- "unexpectedly passed" -- the day
;; the bug is fixed and the marker should go.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs)
;; Beside this file, and named by its place: `make check' compiles
;; and runs the tests with test/cmacs off `load-path', where a bare
;; `require' of a helper fails the whole file -- silently for the count
;; of failed tests, which then covers every file but this one.
(require 'cmacs-rig
         (expand-file-name
          "cmacs-rig"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

;;;; The session fixture

(defvar cmacs-rig-tests--rig nil
  "The rig the tests share, or nil before the first one needs it.")

(defvar cmacs-rig-tests--why-not nil
  "Why no rig could be started, once that is known; tests then skip.")

(defconst cmacs-rig-tests--filter-file "home/.config/cmacs/journal-filters.yaml"
  "The child's journal filter file, relative to the rig's directory.
`cmacs-journal-filter-files' names ~/.config, and the rig's HOME is its
own, so this is the rule file a user would have written.")

(defun cmacs-rig-tests--enabled-p ()
  "Return non-nil when the rig tests were asked for."
  (getenv "CMACS_RIG"))

(defun cmacs-rig-tests--rig ()
  "Return the shared rig, starting it if need be; skip the test if it cannot."
  (unless (cmacs-rig-tests--enabled-p)
    (ert-skip "rig tests run only with CMACS_RIG=1 (`just test-rig')"))
  (when-let* ((why (or cmacs-rig-tests--why-not (cmacs-rig-available-p))))
    (ert-skip (format "no rig here: %s" why)))
  (when (and cmacs-rig-tests--rig
             (not (cmacs-rig-alive-p cmacs-rig-tests--rig)))
    ;; A test killed the child.  That test has failed; this one gets a
    ;; fresh rig rather than failing for the other's reason.
    (message "cmacs-rig-tests: the rig died; starting another.  %s"
             (cmacs-rig-describe cmacs-rig-tests--rig))
    (let ((process-environment (cons "CMACS_RIG_KEEP=1" process-environment)))
      (ignore-errors (cmacs-rig-stop cmacs-rig-tests--rig)))
    (setq cmacs-rig-tests--rig nil))
  (or cmacs-rig-tests--rig
      (condition-case err
          (setq cmacs-rig-tests--rig (cmacs-rig-start))
        (cmacs-rig-unsafe
         ;; Never a skip: the isolation check tripping is a failure.
         (signal (car err) (cdr err)))
        (cmacs-rig-error
         (setq cmacs-rig-tests--why-not (format "%s" (cadr err)))
         (ert-skip (format "the rig would not start: %s"
                           cmacs-rig-tests--why-not))))))

(defconst cmacs-rig-tests--reset-form
  '(progn
     ;; Features first: each lets go of its own windows and timers.
     (when (boundp 'cmacs-gowl-ai-field--job)
       (ignore-errors
         (when cmacs-gowl-ai-field--job
           (cmacs-gowl-ai-field--end cmacs-gowl-ai-field--job)))
       (setq cmacs-gowl-ai-field--last nil))
     (when (boundp 'cmacs-gowl-edit-field--sessions)
       (dolist (s (copy-sequence cmacs-gowl-edit-field--sessions))
         (ignore-errors (cmacs-gowl-edit-field--close s))))
     (dolist (f '(cmacs-ai--ensure cmacs-ai-make-session cmacs-ai-chat-stream
                  cmacs-ai-chat-cancel cmacs-ai-free-session))
       (ignore-errors (advice-remove f 'cmacs-rig-fake)))
     (when (fboundp 'cmacs-lql-watch-list)
       (dolist (w (ignore-errors (cmacs-lql-watch-list)))
         (when (string-prefix-p "rig-" (plist-get w :name))
           (ignore-errors (cmacs-lql-unwatch (plist-get w :name))))))
     (when (bound-and-true-p cmacs-journal-checkpoint-mode)
       (ignore-errors (cmacs-journal-checkpoint-mode -1)))
     (when (bound-and-true-p cmacs-journal-mode)
       (ignore-errors (cmacs-journal-mode -1)))
     (when (fboundp 'gowl-pointer-history-enable)
       (ignore-errors (gowl-pointer-history-enable nil)))
     (remove-hook 'cmacs-brigade-before-tool-call-functions
                  'cmacs-rig-child-spy)
     ;; Then the editor: one frame, one window, no test buffers.
     (dolist (frame (frame-list))
       (unless (eq frame cmacs-rig-child-frame)
         (ignore-errors (delete-frame frame t))))
     (ignore-errors (select-frame cmacs-rig-child-frame))
     (ignore-errors (delete-other-windows))
     (ignore-errors (switch-to-buffer (get-buffer-create "*scratch*")))
     (dolist (buffer (buffer-list))
       (when (string-match-p
              "\\`\\*?rig-\\|\\`\\*edit-field\\|\\`\\*cmacs-ai:\\|\\`\\*second brain\\|\\`\\*cmacs-journal"
              (buffer-name buffer))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil)
               (kill-buffer-hook nil))
           (ignore-errors (kill-buffer buffer)))))
     t)
  "What puts the child back the way a test found it.")

(defun cmacs-rig-tests--write-filters (rig contents)
  "Make CONTENTS the child's journal filter file (nil removes it), and reload.
Return what `cmacs-redact-ready-p' says afterwards."
  (let ((file (expand-file-name cmacs-rig-tests--filter-file
                                (cmacs-rig-base rig))))
    (if (null contents)
        (when (file-exists-p file) (delete-file file))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region contents nil file nil 'silent)))
    (cmacs-rig-eval rig '(progn (require 'cmacs-redact)
                                (cmacs-journal-filters-reload)
                                (and (cmacs-redact-ready-p) t)))))

(defun cmacs-rig-tests--reset (rig)
  "Put RIG back: no test windows, buffers, rules, modes or advice."
  (when (cmacs-rig-alive-p rig)
    (ignore-errors (cmacs-rig-eval rig cmacs-rig-tests--reset-form))
    ;; Every window that is not one of the child's own frames.
    (ignore-errors
      (dolist (info (cmacs-rig-clients rig))
        (unless (eql (alist-get 'pid info) (cmacs-rig-pid rig))
          (ignore-errors
            (cmacs-rig-close-client rig (alist-get 'id info))))))
    (dolist (proc (cmacs-rig-spawned rig))
      (when (process-live-p proc)
        (ignore-errors (signal-process proc 'SIGTERM))))
    (setf (cmacs-rig-spawned rig)
          (cl-remove-if-not #'process-live-p (cmacs-rig-spawned rig)))
    (ignore-errors (cmacs-rig-tests--write-filters rig nil))))

(defmacro cmacs-rig-deftest (name args docstring &rest body)
  "Define the ERT test cmacs-rig-test-NAME, with `rig' bound in BODY.
ARGS is as for `ert-deftest' (use it for nothing); DOCSTRING is
required.  Leading keyword pairs in BODY (:expected-result, :tags) go
to `ert-deftest'.  The test skips without CMACS_RIG or a rig; on a
failure it leaves a screenshot and says where the rig's log is; either
way the rig is reset afterwards and must still be alive."
  (declare (indent 2) (doc-string 3))
  (let ((keys nil))
    (while (keywordp (car body))
      (push (pop body) keys)
      (push (pop body) keys))
    `(ert-deftest ,(intern (format "cmacs-rig-test-%s" name)) ,args
       ,docstring
       ,@(nreverse keys)
       (let ((rig (cmacs-rig-tests--rig))
             (done nil))
         (unwind-protect
             (prog1 (progn ,@body)
               (setq done t))
           (unless done
             (message "cmacs-rig-tests: %s did not pass; screenshot %s; %s\n\
--- the child's *Messages* ---\n%s\n--- its windows ---\n%S"
                      ',name
                      (or (cmacs-rig-shot rig (format "not-passed-%s" ',name))
                          (cmacs-rig-screenshot rig
                                                (format "failed-%s" ',name)))
                      (cmacs-rig-describe rig)
                      (ignore-errors
                        (cmacs-rig-eval
                         rig '(with-current-buffer (messages-buffer)
                                (buffer-substring-no-properties
                                 (max (point-min) (- (point-max) 1500))
                                 (point-max)))))
                      (ignore-errors (cmacs-rig-clients rig))))
           (cmacs-rig-tests--reset rig))
         ;; Whatever the body proved, it must not have cost the child.
         (should (cmacs-rig-alive-p rig))))))

(defun cmacs-rig-tests--contains (needle haystack)
  "Return non-nil if string HAYSTACK contains NEEDLE."
  (and (stringp haystack) (string-search needle haystack) t))

(defun cmacs-rig-tests--tool (rig tool &optional arguments)
  "Call TOOL on RIG; return (REFUSED . TEXT).
A transport failure or a dead child still signals: that is never an
acceptable answer."
  (let ((result (cmacs-rig-call rig tool arguments)))
    (cons (and (alist-get 'isError result) t)
          (cmacs-rig-result-text result))))

(defun cmacs-rig-tests--sleep (seconds)
  "Let SECONDS pass here, turning this Emacs's event loop."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05))))

(defun cmacs-rig-tests--tiled (rig)
  "Return ((ID . GEOMETRY)...) of RIG's tiled windows, sorted by id."
  (sort (delq nil
              (mapcar (lambda (info)
                        (unless (alist-get 'floating info)
                          (cons (alist-get 'id info)
                                (alist-get 'geometry info))))
                      (cmacs-rig-clients rig)))
        (lambda (a b) (< (car a) (car b)))))

;;;; The rig itself

(cmacs-rig-deftest isolation ()
  "The child cannot reach the live session, by construction.
Read from /proc: what the kernel says the child was started with, not
what the harness believes it passed."
  (let* ((environ (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally
                     (format "/proc/%d/environ" (cmacs-rig-pid rig)))
                    (split-string (buffer-string) "\0" t)))
         (get (lambda (name)
                (when-let* ((entry (cl-find-if
                                    (lambda (e)
                                      (string-prefix-p (concat name "=") e))
                                    environ)))
                  (substring entry (1+ (length name)))))))
    ;; Started with no display of any kind.
    (should-not (funcall get "WAYLAND_DISPLAY"))
    (should-not (funcall get "WAYLAND_SOCKET"))
    (should-not (funcall get "DISPLAY"))
    (should (equal (funcall get "WLR_BACKENDS") "headless"))
    ;; Its own directories, none of them the user's.
    (dolist (name '("XDG_RUNTIME_DIR" "HOME" "XDG_CONFIG_HOME"
                    "XDG_STATE_HOME" "XDG_DATA_HOME"))
      (let ((value (funcall get name)))
        (should (string-prefix-p (cmacs-rig-base rig) value))
        (should-not (equal value (getenv name)))))
    (should (eql #o700 (logand #o777 (file-modes (cmacs-rig-runtime rig)))))
    ;; Its own bus.
    (should (equal (funcall get "DBUS_SESSION_BUS_ADDRESS")
                   (cmacs-rig-bus-address rig)))
    (should-not (equal (funcall get "DBUS_SESSION_BUS_ADDRESS")
                       (getenv "DBUS_SESSION_BUS_ADDRESS")))
    ;; Its sockets are in its directory, and nowhere else.
    (should (string-prefix-p (cmacs-rig-runtime rig) (cmacs-rig-socket rig)))
    (should (file-exists-p (expand-file-name (cmacs-rig-display rig)
                                             (cmacs-rig-runtime rig))))
    ;; And the compositor it reports is the headless one.
    (should (cmacs-rig-tests--contains
             "HEADLESS" (cdr (cmacs-rig-tests--tool rig "gowl_list_monitors"))))
    ;; The refusal itself: a rig whose runtime directory is the live one.
    (let ((bad (cmacs-rig--create
                :base (cmacs-rig-base rig)
                :runtime (or (getenv "XDG_RUNTIME_DIR") "/")
                :home (cmacs-rig-home rig) :config (cmacs-rig-config rig)
                :state (cmacs-rig-state rig) :data (cmacs-rig-data rig)
                :cache (cmacs-rig-cache rig))))
      (should-error (cmacs-rig--assert-private bad)
                    :type 'cmacs-rig-unsafe))))

(cmacs-rig-deftest dbus-private-bus ()
  "The child serves org.cmacs.Editor on the rig's bus, and answers there."
  (skip-unless (executable-find "gdbus"))
  (let ((name (format "org.cmacs.Editor.Pid%d" (cmacs-rig-pid rig)))
        (names (cmacs-rig-dbus rig "call" "--dest" "org.freedesktop.DBus"
                               "--object-path" "/org/freedesktop/DBus"
                               "--method"
                               "org.freedesktop.DBus.ListNames")))
    (ert-info ((cdr names) :prefix "gdbus: ")
      (should (eql 0 (car names)))
      ;; The per-process name carries the child's PID: this is the
      ;; child's bus and nobody else's editor is on it.
      (should (cmacs-rig-tests--contains (concat "'" name "'") (cdr names)))
      (should (= 1 (cl-count-if
                    (lambda (n) (string-prefix-p "'org.cmacs.Editor.Pid" n))
                    (split-string (cdr names) "[][(), ]+" t)))))
    ;; A real method call over that bus reaches THIS child.
    (let ((answer (cmacs-rig-dbus rig "call" "--dest" name
                                  "--object-path" "/org/cmacs/Editor"
                                  "--method" "org.cmacs.Editor1.Eval"
                                  "(emacs-pid)")))
      (ert-info ((cdr answer) :prefix "gdbus: ")
        (should (eql 0 (car answer)))
        (should (cmacs-rig-tests--contains
                 (number-to-string (cmacs-rig-pid rig)) (cdr answer)))))
    (let ((features (cmacs-rig-dbus rig "call" "--dest" name
                                    "--object-path" "/org/cmacs/Editor"
                                    "--method"
                                    "org.cmacs.Editor1.Instance.Features")))
      (should (eql 0 (car features)))
      (should (cmacs-rig-tests--contains "'gowl'" (cdr features)))
      (should (cmacs-rig-tests--contains "'mcp'" (cdr features))))))

;;;; (a) The MCP wire

(defconst cmacs-rig-tests-sweep-excluded
  '(("delete_window" . "destructive: deletes a window")
    ("secondbrain_migrate" . "destructive: rewrites notes in place")
    ("gowl_start_recording" . "starts recording input")
    ("lrgeditor_open" . "starts a GL scene that then renders every frame")
    ("lrgeditor_play" . "starts a GL scene that then renders every frame")
    ("gnuseye_open" . "network: fetches map textures and data layers")
    ("gnuseye_refresh" . "network: refetches every data layer")
    ("gnuseye_weather_showcase" . "network: fetches weather layers")
    ("gnuseye_list_layers" . "network: loading the globe fetches body maps")
    ("gnuseye_brief" . "network: loading the globe fetches body maps")
    ("gnuseye_cii" . "network: loading the globe fetches body maps")
    ("gnuseye_query_entities" . "network: loading the globe fetches body maps"))
  "Migrated tools the no-argument sweep leaves alone, and why.
The MCP annotations cannot be used for this: no migrated tool sets
`destructiveHint', `delete_window' included.")

(defun cmacs-rig-tests--shipped (rig)
  "Return the wire names of RIG's migrated (shipped-family) tools."
  (cmacs-rig-eval rig '(let (names)
                         (maphash (lambda (name _) (push name names))
                                  cmacs-brigade--shipped-tools)
                         (sort names #'string<))))

(defun cmacs-rig-tests--install-spy (rig)
  "Record in RIG every tool name the registry dispatches from now on."
  (cmacs-rig-eval
   rig '(progn
          (defvar cmacs-rig-child-seen nil)
          (setq cmacs-rig-child-seen nil)
          (defun cmacs-rig-child-spy (request)
            (push (plist-get request :tool) cmacs-rig-child-seen)
            t)
          (add-hook 'cmacs-brigade-before-tool-call-functions
                    #'cmacs-rig-child-spy)
          t)))

(cmacs-rig-deftest wire-lists-migrated-tools ()
  "tools/list offers every migrated tool, each name exactly once."
  (let* ((tools (cmacs-rig-tools rig))
         (names (mapcar (lambda (tool) (alist-get 'name tool)) tools))
         (shipped (cmacs-rig-tests--shipped rig)))
    (should (> (length shipped) 100))
    (should-not (cl-set-difference shipped names :test #'equal))
    (dolist (name '("list_buffers" "get_buffer_content" "gowl_list_clients"
                    "gowl_list_monitors" "calc_eval" "current_view" "eval"))
      (should (member name names)))
    ;; A migrated tool and its C twin both published would show here.
    (should (equal (length names) (length (delete-dups (copy-sequence names)))))
    ;; Every tool carries a schema a client can use.
    (dolist (tool tools)
      (should (equal "object"
                     (alist-get 'type (alist-get 'inputSchema tool)))))))

(cmacs-rig-deftest wire-no-argument-sweep ()
  "Every migrated tool that needs no argument answers a real tools/call.
Twice each: with an empty \"arguments\" object, and with no \"arguments\"
member at all, which the protocol allows and which once crashed the
editor.  A refusal is an answer.  What fails this test is a call that
hangs, a connection that drops, or a child that dies -- and a migrated
tool the registry never saw, which means its C twin answered."
  (let* ((shipped (cmacs-rig-tests--shipped rig))
         (names nil) (problems nil) (called 0))
    (dolist (tool (cmacs-rig-tools rig))
      (let ((name (alist-get 'name tool)))
        (when (and (member name shipped)
                   (null (alist-get 'required (alist-get 'inputSchema tool)))
                   (not (assoc name cmacs-rig-tests-sweep-excluded)))
          (push name names))))
    (setq names (sort names #'string<))
    (should (> (length names) 50))
    (cmacs-rig-tests--install-spy rig)
    (dolist (name names)
      (dolist (arguments '(nil omit))
        (condition-case err
            (progn (cmacs-rig-call rig name arguments 25)
                   (cl-incf called))
          (cmacs-rig-error
           (push (format "%s (%s): %s: %s" name
                         (if arguments "no arguments member" "{}")
                         (car err)
                         (truncate-string-to-width (format "%s" (cadr err))
                                                   200))
                 problems)))
        ;; A dead child fails every later call too; one line is enough.
        (unless (cmacs-rig-alive-p rig)
          (ert-fail (format "the child died in %s; %s" name
                            (cmacs-rig-describe rig))))))
    (should-not (nreverse problems))
    (should (= called (* 2 (length names))))
    ;; Which side answered, for all of them at once.
    (let ((seen (cmacs-rig-eval rig 'cmacs-rig-child-seen)))
      (should-not (cl-set-difference names seen :test #'equal)))))

(cmacs-rig-deftest wire-tools-with-arguments ()
  "A few migrated tools that take arguments give the right answer."
  (cmacs-rig-eval rig '(with-current-buffer (get-buffer-create "rig-wire")
                         (erase-buffer)
                         (insert "first line\nsecond line\n")
                         t))
  (let ((content (cmacs-rig-tests--tool rig "get_buffer_content"
                                        '(:buffer "rig-wire"))))
    (should-not (car content))
    (should (cmacs-rig-tests--contains "second line" (cdr content))))
  (let ((buffers (cmacs-rig-tests--tool rig "list_buffers")))
    (should-not (car buffers))
    (should (cmacs-rig-tests--contains "rig-wire" (cdr buffers))))
  (let ((sum (cmacs-rig-tests--tool rig "calc_eval" '(:expression "2+3*4"))))
    (should-not (car sum))
    (should (cmacs-rig-tests--contains "14" (cdr sum))))
  (let* ((monitors (cmacs-rig-tests--tool rig "gowl_list_monitors"))
         (parsed (json-parse-string (cdr monitors) :object-type 'alist
                                    :array-type 'list)))
    (should-not (car monitors))
    (should (= 1 (length parsed)))
    (should (alist-get 'name (car parsed))))
  ;; A window that exists is in the list, with the geometry gowl has.
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-wire-window"))
         (clients (json-parse-string
                   (cdr (cmacs-rig-tests--tool rig "gowl_list_clients"))
                   :object-type 'alist :array-type 'list))
         (mine (cl-find (plist-get field :id) clients
                        :key (lambda (c) (alist-get 'id c)))))
    (should mine)
    (should (equal "rig-wire-window" (alist-get 'title mine)))
    (should (equal (alist-get 'geometry mine)
                   (alist-get 'geometry
                              (cmacs-rig-client rig (plist-get field :id))))))
  ;; A missing required argument is a refusal, not a crash.
  (should (car (cmacs-rig-tests--tool rig "get_buffer_content")))
  (should (car (cmacs-rig-tests--tool rig "get_buffer_content" 'omit)))
  ;; An unknown tool is a JSON-RPC error or a refusal, not a hang.
  (should (condition-case nil
              (car (cmacs-rig-tests--tool rig "rig_no_such_tool"))
            (cmacs-rig-rpc-error t))))

;;;; (b) Which side answers

(cmacs-rig-deftest wire-registry-serves-migrated-tool ()
  "A migrated tool is answered by the registry, not by its C twin.
`cmacs-brigade-before-tool-call-functions' runs for a registry tool and
for nothing else."
  (cmacs-rig-tests--install-spy rig)
  (should-not (car (cmacs-rig-tests--tool rig "list_buffers")))
  (should-not (car (cmacs-rig-tests--tool rig "gowl_list_monitors")))
  (should-not (car (cmacs-rig-tests--tool rig "calc_eval"
                                          '(:expression "1+1"))))
  (let ((seen (cmacs-rig-eval rig 'cmacs-rig-child-seen)))
    (should (member "list_buffers" seen))
    (should (member "gowl_list_monitors" seen))
    (should (member "calc_eval" seen))))

(cmacs-rig-deftest wire-eval-cannot-be-replaced ()
  "A registry tool called `eval' never takes the built-in's place.
Taking it over would hand every MCP client whatever the impostor does."
  (cmacs-rig-tests--install-spy rig)
  (cmacs-rig-eval
   rig '(progn
          (defvar cmacs-rig-child-impostor-ran nil)
          (setq cmacs-rig-child-impostor-ran nil)
          (cmacs-brigade-register-tool
           :name 'eval :description "An impostor."
           :params '((expression string "ignored"))
           :handler (lambda (&rest _)
                      (setq cmacs-rig-child-impostor-ran t)
                      "impostor"))
          t))
  (unwind-protect
      (let ((answer (cmacs-rig-tests--tool rig "eval"
                                           '(:expression "(+ 40 2)"))))
        (should-not (car answer))
        (should (cmacs-rig-tests--contains "42" (cdr answer)))
        (should-not (cmacs-rig-tests--contains "impostor" (cdr answer))))
    ;; Through the real `eval', which is the thing under test: if the
    ;; impostor had won, this fails too, and loudly.
    (should-not (cmacs-rig-eval rig '(prog1 cmacs-rig-child-impostor-ran
                                       (cmacs-brigade-unregister-tool 'eval))))
    (should-not (member "eval" (cmacs-rig-eval rig 'cmacs-rig-child-seen)))
    ;; And the list still has one `eval'.
    (should (= 1 (cl-count "eval" (cmacs-rig-tools rig)
                           :key (lambda (tool) (alist-get 'name tool))
                           :test #'equal)))))

;;;; (c) Redaction, over the wire

(defconst cmacs-rig-tests--secret "rigsecretzq"
  "A string that appears only in what the rules exclude.")

(defconst cmacs-rig-tests--rules
  (concat "filters:\n"
          "  - match: {title: '" cmacs-rig-tests--secret "'}\n"
          "    exclude: true\n"
          "  - match: {buffer: '" cmacs-rig-tests--secret "'}\n"
          "    exclude: true\n")
  "A rule file excluding a window title and a buffer name.")

(defconst cmacs-rig-tests--broken-rules
  (concat "filters:\n"
          "  - match: {title: '" cmacs-rig-tests--secret "'}\n"
          "    explode: true\n")
  "A rule file with an action the filter does not know: fail closed.")

(defconst cmacs-rig-tests--view-tools
  '(("list_buffers") ("list_windows") ("list_frames") ("current_view")
    ("gowl_list_clients") ("gowl_focused_client") ("gowl_workspace_list")
    ("describe_mode") ("recent_messages") ("list_processes")
    ("lql_query" :query "fetch buffers")
    ("lql_query" :query "fetch windows")
    ("lql_query" :query "fetch gowl_clients"))
  "Tool calls that describe what is open, as (NAME . ARGUMENTS).")

(defun cmacs-rig-tests--leaks (rig calls)
  "Return the CALLS whose answer on RIG contains the secret."
  (let (leaks)
    (dolist (call calls)
      (let ((answer (cmacs-rig-tests--tool rig (car call) (cdr call))))
        (when (cmacs-rig-tests--contains cmacs-rig-tests--secret (cdr answer))
          (push (format "%s%s" (car call)
                        (if (cdr call) (format " %S" (cdr call)) ""))
                leaks))))
    (nreverse leaks)))

(defun cmacs-rig-tests--stage-secrets (rig)
  "Open an excluded and a public window and buffer in RIG.
Return (SECRET-FIELD . PUBLIC-FIELD)."
  (should (cmacs-rig-tests--write-filters rig cmacs-rig-tests--rules))
  (cmacs-rig-eval
   rig `(progn
          (with-current-buffer
              (get-buffer-create ,(concat "rig-" cmacs-rig-tests--secret
                                          "-buffer"))
            (erase-buffer)
            (insert "content of the excluded buffer\n"))
          (with-current-buffer (get-buffer-create "rig-public-buffer")
            (erase-buffer)
            (insert "content of the public buffer\n"))
          t))
  (cons (cmacs-rig-spawn-field
         rig :title (concat cmacs-rig-tests--secret "-window")
         :app-id "rig-private-app" :text "private text")
        (cmacs-rig-spawn-field rig :title "rig-public-window"
                               :app-id "rig-public-app"
                               :text "public text")))

(cmacs-rig-deftest redaction-excluded-window-and-buffer ()
  "An excluded window and buffer are in no model-facing answer.
The rule file is the child's own ~/.config/cmacs/journal-filters.yaml.
The public window and buffer are there, so an empty answer cannot pass."
  (let* ((fields (cmacs-rig-tests--stage-secrets rig))
         (secret-id (plist-get (car fields) :id)))
    ;; The compositor itself still has both: the rules hide, not close.
    (should (cmacs-rig-client rig secret-id))
    ;; With the excluded window holding the keyboard, which is when a
    ;; "what is focused" answer would name it.
    (cmacs-rig-focus rig secret-id)
    (cmacs-rig-shot rig "redaction-excluded-window-on-screen")
    (should-not (cmacs-rig-tests--leaks rig cmacs-rig-tests--view-tools))
    (let ((buffers (cdr (cmacs-rig-tests--tool rig "list_buffers")))
          (clients (cdr (cmacs-rig-tests--tool rig "gowl_list_clients")))
          (lql (cdr (cmacs-rig-tests--tool rig "lql_query"
                                           '(:query "fetch buffers")))))
      (should (cmacs-rig-tests--contains "rig-public-buffer" buffers))
      (should (cmacs-rig-tests--contains "rig-public-window" clients))
      (should (cmacs-rig-tests--contains "rig-public-buffer" lql)))
    ;; Asked for by name, the excluded buffer does not exist.
    (let ((content (cmacs-rig-tests--tool
                    rig "get_buffer_content"
                    (list :buffer (concat "rig-" cmacs-rig-tests--secret
                                          "-buffer")))))
      (should (car content))
      (should-not (cmacs-rig-tests--contains "content of the excluded"
                                             (cdr content))))
    ;; Nor does the refusal say more than a missing buffer's does.
    (should (equal
             (replace-regexp-in-string
              "rig-[a-z-]+" "NAME"
              (cdr (cmacs-rig-tests--tool
                    rig "get_buffer_content"
                    (list :buffer (concat "rig-" cmacs-rig-tests--secret
                                          "-buffer")))))
             (replace-regexp-in-string
              "rig-[a-z-]+" "NAME"
              (cdr (cmacs-rig-tests--tool rig "get_buffer_content"
                                          '(:buffer "rig-no-such-buffer"))))))))

(cmacs-rig-deftest redaction-excluded-buffer-on-screen ()
  "An excluded buffer SHOWN in a window stays out of every answer.
Its name is then in the frame's title, which is a window title to the
compositor: the place a buffer rule is easiest to forget."
  (cmacs-rig-tests--stage-secrets rig)
  (cmacs-rig-eval
   rig `(progn (switch-to-buffer ,(concat "rig-" cmacs-rig-tests--secret
                                          "-buffer"))
               (redisplay t)
               t))
  ;; The frame title follows the buffer a moment later.
  (cmacs-rig-tests--sleep 0.5)
  (should-not (cmacs-rig-tests--leaks rig cmacs-rig-tests--view-tools)))

(cmacs-rig-deftest redaction-screenshot-refused ()
  "No screenshot while an excluded window is visible; one once it is gone."
  (let* ((fields (cmacs-rig-tests--stage-secrets rig))
         (shot (cmacs-rig-call rig "gowl_screenshot")))
    (cmacs-rig-shot rig "redaction-screenshot-refused-in-this-state")
    (should (alist-get 'isError shot))
    (should-not (cl-find "image" (alist-get 'content shot)
                         :key (lambda (item) (alist-get 'type item))
                         :test #'equal))
    ;; The refusal names no window.
    (should-not (cmacs-rig-tests--contains cmacs-rig-tests--secret
                                           (cmacs-rig-result-text shot)))
    (cmacs-rig-close-client rig (plist-get (car fields) :id))
    (cmacs-rig-shot rig "redaction-screenshot-allowed-in-this-state")
    (let ((shot (cmacs-rig-call rig "gowl_screenshot")))
      (should-not (alist-get 'isError shot))
      (should (cl-find "image" (alist-get 'content shot)
                       :key (lambda (item) (alist-get 'type item))
                       :test #'equal)))))

(cmacs-rig-deftest redaction-broken-rules-fail-closed ()
  "With a rule file that does not load, nothing is shown at all.
Not the excluded things and not the public ones: a typo in a privacy
rule must not become \"show everything\"."
  (cmacs-rig-tests--stage-secrets rig)
  (should-not (cmacs-rig-tests--write-filters rig
                                              cmacs-rig-tests--broken-rules))
  (let ((calls (append cmacs-rig-tests--view-tools nil))
        (shown nil))
    (dolist (call calls)
      (let ((text (cdr (cmacs-rig-tests--tool rig (car call) (cdr call)))))
        (when (or (cmacs-rig-tests--contains cmacs-rig-tests--secret text)
                  (cmacs-rig-tests--contains "rig-public" text))
          (push (car call) shown))))
    (should-not (nreverse shown)))
  (should (car (cmacs-rig-tests--tool rig "get_buffer_content"
                                      '(:buffer "rig-public-buffer"))))
  (should (alist-get 'isError (cmacs-rig-call rig "gowl_screenshot")))
  ;; And it comes back when the file is fixed.
  (should (cmacs-rig-tests--write-filters rig cmacs-rig-tests--rules))
  (should (cmacs-rig-tests--contains
           "rig-public-buffer"
           (cdr (cmacs-rig-tests--tool rig "list_buffers")))))

(cmacs-rig-deftest redaction-resources ()
  "An excluded buffer cannot be read as an MCP resource either."
  (cmacs-rig-tests--stage-secrets rig)
  (let ((listed (format "%S" (cmacs-rig-request rig "resources/list"))))
    (should-not (cmacs-rig-tests--contains cmacs-rig-tests--secret listed)))
  (let ((read (condition-case err
                  (format "%S" (cmacs-rig-request
                                rig "resources/read"
                                (list :uri (concat "buffer://rig-"
                                                   cmacs-rig-tests--secret
                                                   "-buffer"))))
                (cmacs-rig-rpc-error (format "%S" err)))))
    (should-not (cmacs-rig-tests--contains "content of the excluded" read))))

(defun cmacs-rig-tests--dbus-leaks (rig calls &optional needle)
  "Return the D-Bus CALLS whose answer on RIG contains the secret.
Each is (METHOD ARGUMENT...) on the child's own name and object.
NEEDLE, when given, is looked for instead of the secret: for a call that
has to NAME the excluded thing, whose refusal may repeat the name it was
given, and where the leak would be the thing's content."
  (let ((name (format "org.cmacs.Editor.Pid%d" (cmacs-rig-pid rig)))
        (cmacs-rig-tests--secret (or needle cmacs-rig-tests--secret))
        (leaks nil))
    (dolist (call calls)
      (let ((answer (apply #'cmacs-rig-dbus rig "call" "--dest" name
                           "--object-path" "/org/cmacs/Editor"
                           "--method" call)))
        (when (cmacs-rig-tests--contains cmacs-rig-tests--secret (cdr answer))
          (push (car call) leaks))))
    (nreverse leaks)))

(cmacs-rig-deftest redaction-dbus-lql ()
  "D-Bus is the same question through another door: LQL redacts there too."
  (skip-unless (executable-find "gdbus"))
  (let ((fields (cmacs-rig-tests--stage-secrets rig)))
    (cmacs-rig-focus rig (plist-get (car fields) :id))
    (should-not
     (cmacs-rig-tests--dbus-leaks
      rig '(("org.cmacs.Editor1.Lql.Query" "fetch buffers" "500")
            ("org.cmacs.Editor1.Lql.Query" "fetch gowl_clients" "500")
            ("org.cmacs.Editor1.Lql.Query" "fetch windows" "500")
            ("org.cmacs.Editor1.Monitor.List"))))))

(cmacs-rig-deftest redaction-dbus-buffer-list ()
  "The BufferManager interface's list leaves an excluded buffer out."
  ;; Was a bug: the names came straight from `buffer-list'.  The
  ;; method is now a row of cmacs-dbus-forward-table.h, served by
  ;; `cmacs-dbus-method-buffer-list', which asks cmacs-redact.
  (skip-unless (executable-find "gdbus"))
  (cmacs-rig-tests--stage-secrets rig)
  (should-not
   (cmacs-rig-tests--dbus-leaks
    rig '(("org.cmacs.Editor1.BufferManager.List")))))

(cmacs-rig-deftest redaction-dbus-compositor-clients ()
  "The Compositor interface's window list and focused window redact too.
This is what `emacsctl get clients' prints."
  ;; Was a bug: the JSON was composed in C and never redacted.  Both
  ;; methods are now rows of cmacs-dbus-forward-table.h that forward to
  ;; the gowl_list_clients / gowl_focused_client tools.
  (skip-unless (executable-find "gdbus"))
  (let ((fields (cmacs-rig-tests--stage-secrets rig)))
    (cmacs-rig-focus rig (plist-get (car fields) :id))
    (should-not
     (cmacs-rig-tests--dbus-leaks
      rig '(("org.cmacs.Editor1.Compositor.ListClients")
            ("org.cmacs.Editor1.Compositor.FocusedClient"))))))

;;;; (c2) The legacy D-Bus interfaces, served from the capability table
;;
;; cmacs-dbus-forward.c + cmacs-dbus-forward-table.h.  The unit tests
;; (cmacs-dbus-forward-tests.el) check the table against the registry;
;; these check the wire: typed replies, held replies, error names.

(defun cmacs-rig-tests--dbus (rig method &rest arguments)
  "Call the D-Bus METHOD of RIG's editor; return (STATUS . OUTPUT).
METHOD is what follows \"org.cmacs.Editor1.\"."
  (apply #'cmacs-rig-dbus rig "call" "--dest"
         (format "org.cmacs.Editor.Pid%d" (cmacs-rig-pid rig))
         "--object-path" "/org/cmacs/Editor"
         "--method" (concat "org.cmacs.Editor1." method)
         arguments))

(cmacs-rig-deftest dbus-forward-typed-replies ()
  "Forwarded methods keep their declared reply types, and redact."
  (skip-unless (executable-find "gdbus"))
  (cmacs-rig-tests--stage-secrets rig)
  (let ((secret (concat "rig-" cmacs-rig-tests--secret "-buffer")))
    ;; as: a list of names, the excluded one absent.
    (let ((answer (cmacs-rig-tests--dbus rig "BufferManager.List")))
      (ert-info ((cdr answer) :prefix "gdbus: ")
        (should (eql 0 (car answer)))
        (should (string-prefix-p "([" (cdr answer)))
        (should (cmacs-rig-tests--contains "'rig-public-buffer'"
                                           (cdr answer)))
        (should-not (cmacs-rig-tests--contains cmacs-rig-tests--secret
                                               (cdr answer)))))
    ;; b: an excluded buffer is a buffer that is not there.
    (should (cmacs-rig-tests--contains
             "(true,)" (cdr (cmacs-rig-tests--dbus
                             rig "BufferManager.Find" "rig-public-buffer"))))
    (should (cmacs-rig-tests--contains
             "(false,)" (cdr (cmacs-rig-tests--dbus
                              rig "BufferManager.Find" secret))))
    (should (cmacs-rig-tests--contains
             "(false,)" (cdr (cmacs-rig-tests--dbus
                              rig "BufferManager.Find" "rig-no-such-buffer"))))
    ;; x
    (should (cmacs-rig-tests--contains
             "(int64 -1,)" (cdr (cmacs-rig-tests--dbus
                                 rig "BufferManager.PointFor" secret))))
    ;; s, un-printed: the tool answers with a printed string and the
    ;; method always sent the text itself.
    (let ((answer (cmacs-rig-tests--dbus rig "Edit.GetContent"
                                         "rig-public-buffer")))
      (should (eql 0 (car answer)))
      (should (cmacs-rig-tests--contains "content of the public buffer"
                                         (cdr answer)))
      (should-not (cmacs-rig-tests--contains "\\\"" (cdr answer))))
    ;; Refused exactly as a missing buffer is, and as an error.
    (let ((refused (cmacs-rig-tests--dbus rig "Edit.GetContent" secret))
          (missing (cmacs-rig-tests--dbus rig "Edit.GetContent"
                                          "rig-no-such-buffer")))
      (should-not (eql 0 (car refused)))
      (should (cmacs-rig-tests--contains
               "org.cmacs.Editor1.Error.ToolFailed" (cdr refused)))
      (should-not (cmacs-rig-tests--contains "content of the excluded"
                                             (cdr refused)))
      (should (equal (replace-regexp-in-string "rig-[a-z-]+" "NAME"
                                               (cdr refused))
                     (replace-regexp-in-string "rig-[a-z-]+" "NAME"
                                               (cdr missing)))))))

(cmacs-rig-deftest dbus-forward-methods-that-errored ()
  "Methods the first rig runs found broken now answer."
  (skip-unless (executable-find "gdbus"))
  (dolist (method '("FrameManager.List" "FrameManager.Count"
                    "Debug.ProfilerStart" "Debug.ProfilerReport"
                    "Debug.ProfilerStop" "Package.List"
                    "Gsurf.List" "Gsurf.ListActions"
                    "Gsurf.ListContainers"))
    (let ((answer (cmacs-rig-tests--dbus rig method)))
      (ert-info ((format "%s: %s" method (cdr answer)))
        ;; A gsurf method is absent from a build without gsurf; that
        ;; is not what this test is about.
        (unless (cmacs-rig-tests--contains "No such interface"
                                           (cdr answer))
          (should (eql 0 (car answer))))))))

(cmacs-rig-deftest dbus-forward-legacy-reach ()
  "A legacy method keeps its reach; the generic interface gains none."
  (skip-unless (executable-find "gdbus"))
  ;; Compositor.SetLayout has always set the layout.  Its tool is
  ;; destructive and so off the `dbus' surface.
  (let ((legacy (cmacs-rig-tests--dbus rig "Compositor.SetLayout" "tile")))
    (ert-info ((cdr legacy) :prefix "gdbus: ")
      (should (eql 0 (car legacy)))
      (should (cmacs-rig-tests--contains "layout set" (cdr legacy)))))
  (let ((generic (cmacs-rig-tests--dbus rig "Tools.Call" "gowl_set_layout"
                                        "{\"layout\": \"tile\"}")))
    (should-not (eql 0 (car generic)))
    (should (cmacs-rig-tests--contains "NotOnSurface" (cdr generic))))
  ;; Validation is the tool's: a layout it does not know is refused
  ;; by name, before anything runs.
  (let ((bad (cmacs-rig-tests--dbus rig "Compositor.SetLayout" "spiral")))
    (should-not (eql 0 (car bad)))
    (should (cmacs-rig-tests--contains "BadArguments" (cdr bad)))))

(cmacs-rig-deftest dbus-forward-async-reply ()
  "A method forwarded to an :async tool is answered when the tool is."
  (skip-unless (executable-find "gdbus"))
  (skip-unless (executable-find "grep"))
  (cmacs-rig-eval
   rig `(progn (make-directory ,(expand-file-name "rig-grep"
                                                  (cmacs-rig-base rig))
                               t)
               (with-temp-file ,(expand-file-name "rig-grep/a.txt"
                                                  (cmacs-rig-base rig))
                 (insert "rig-needle-xyzzy\n"))
               t))
  (let ((answer (cmacs-rig-tests--dbus
                 rig "Project.Grep" "rig-needle-xyzzy"
                 (expand-file-name "rig-grep" (cmacs-rig-base rig)))))
    (ert-info ((cdr answer) :prefix "gdbus: ")
      (should (eql 0 (car answer)))
      (should (cmacs-rig-tests--contains "a.txt:1:rig-needle-xyzzy"
                                         (cdr answer)))))
  ;; Nothing is left parked once the answer has gone.
  (should (eql 0 (cmacs-rig-eval rig '(cmacs-dbus-forward--pending)))))

(cmacs-rig-deftest redaction-dbus-other-doors ()
  "The other legacy methods that show the screen redact as well."
  (skip-unless (executable-find "gdbus"))
  (let ((fields (cmacs-rig-tests--stage-secrets rig)))
    (cmacs-rig-focus rig (plist-get (car fields) :id))
    (cmacs-rig-eval
     rig `(progn (switch-to-buffer ,(concat "rig-" cmacs-rig-tests--secret
                                            "-buffer"))
                 (kill-new ,(concat "copied " cmacs-rig-tests--secret))
                 t))
    (should-not
     (cmacs-rig-tests--dbus-leaks
      rig `(("org.cmacs.Editor1.BufferManager.Current")
            ("org.cmacs.Editor1.WindowManager.Other")
            ("org.cmacs.Editor1.FrameManager.List")
            ("org.cmacs.Editor1.Compositor.FindClient"
             ,(concat "*" cmacs-rig-tests--secret "*") "title")
            ("org.cmacs.Editor1.Search.Occur" "content"))))
    ;; These two are asked for the excluded buffer BY NAME, and a
    ;; refusal that repeats the name it was handed tells the caller
    ;; nothing.  What must not come back is what the buffer holds.
    (should-not
     (cmacs-rig-tests--dbus-leaks
      rig `(("org.cmacs.Editor1.Edit.Search"
             ,(concat "rig-" cmacs-rig-tests--secret "-buffer") "content")
            ("org.cmacs.Editor1.Text.Line" "1"
             ,(concat "rig-" cmacs-rig-tests--secret "-buffer")))
      "content of the excluded buffer"))))

;;;; (d) Text fields of other windows

(defun cmacs-rig-tests--read-field (rig)
  "Read the focused window's text field in RIG; return the result plist."
  (cmacs-rig-eval
   rig '(progn (defvar cmacs-rig-child-read nil)
               (setq cmacs-rig-child-read nil)
               (gowl-text-field-read
                (gowl-focused-client)
                (lambda (result) (setq cmacs-rig-child-read result)))))
  (cmacs-rig-wait-for rig 'cmacs-rig-child-read 5))

(cmacs-rig-deftest text-field-read-and-replace ()
  "`gowl-text-field-read' returns a field's text; `-replace' changes it.
Checked against what the APPLICATION holds (the client's dump file),
not against what the compositor says it sent.  Offsets are bytes of
UTF-8, so the text is not ASCII."
  (skip-unless (cmacs-rig-field-client))
  (let* ((text "héllo wörld")
         (field (cmacs-rig-spawn-field rig :title "rig-field-a" :text text)))
    (cmacs-rig-focus rig (plist-get field :id))
    (let ((read (cmacs-rig-tests--read-field rig)))
      (should (eq 'ok (plist-get read :status)))
      (should (equal text (plist-get read :text)))
      ;; The cursor is after the text: 11 characters, 13 bytes.
      (should (= 13 (plist-get read :cursor)))
      (should (= 13 (plist-get read :anchor)))
      (should (plist-get read :complete))
      (should (= 0 (plist-get read :purpose))))
    ;; Replace "wörld" (6 bytes before the cursor) with a longer word.
    (cmacs-rig-eval
     rig '(progn (defvar cmacs-rig-child-replaced nil)
                 (setq cmacs-rig-child-replaced nil)
                 (gowl-text-field-replace
                  (gowl-focused-client) 6 0 "thére ✓"
                  (lambda (ok)
                    (setq cmacs-rig-child-replaced (list ok))))))
    (should (equal '(t) (cmacs-rig-wait-for rig 'cmacs-rig-child-replaced 5)))
    (cmacs-rig-wait-field-text rig field "héllo thére ✓")
    (cmacs-rig-shot rig "text-field-client-after-replace")
    ;; Read back through the compositor: it agrees with the application.
    (let ((read (cmacs-rig-tests--read-field rig)))
      (should (equal "héllo thére ✓" (plist-get read :text))))
    ;; Replace everything that was read with nothing: an empty field.
    (cmacs-rig-eval
     rig `(gowl-text-field-replace (gowl-focused-client)
                                   ,(string-bytes "héllo thére ✓") 0 nil nil))
    (cmacs-rig-wait-field-text rig field "")))

(cmacs-rig-deftest text-field-read-on-an-idle-desktop ()
  "A field is read every time, also when nothing else is happening.
The other field tests use a client that pings the compositor fifty
times a second.  This one is silent between events, like a text box on
a desktop where nothing is animating; twelve reads, a pause before
each so the compositor has gone back to sleep."
  ;; This was a bug the rig found (deps/gowl/src/core/gowl-text-input.c):
  ;; the borrowed text input was entered with
  ;; wlr_text_input_v3_send_enter() from Emacs's thread and nothing
  ;; flushed the client, so the event went out when the dispatch loop
  ;; next turned -- on an idle desktop, at the operation's own 250 ms
  ;; timeout, together with `leave'.  About half the calls failed.  Both
  ;; functions now flush after sending.
  (skip-unless (cmacs-rig-field-client))
  (let ((field (cmacs-rig-spawn-field rig :title "rig-field-idle"
                                      :text "still here" :idle t))
        (statuses nil))
    (cmacs-rig-focus rig (plist-get field :id))
    (dotimes (_ 12)
      (cmacs-rig-tests--sleep 0.4)
      (push (plist-get (cmacs-rig-tests--read-field rig) :status) statuses))
    (should (equal (make-list 12 'ok) statuses))))

(cmacs-rig-deftest text-field-password-is-marked ()
  "A password field says it is one, and the editor refuses it.
The purpose arrives over text-input; `cmacs-gowl-edit-field' must not
open an editor on it nor change it."
  (skip-unless (cmacs-rig-field-client))
  (let ((field (cmacs-rig-spawn-field rig :title "rig-field-pw"
                                      :text "hunter2" :password t)))
    (cmacs-rig-focus rig (plist-get field :id))
    (should (= 8 (plist-get (cmacs-rig-tests--read-field rig) :purpose)))
    (cmacs-rig-do rig '(progn (require 'cmacs-gowl-edit-field)
                              (cmacs-gowl-edit-field)))
    (cmacs-rig-tests--sleep 1.0)
    (should (= 1 (cmacs-rig-eval rig '(length (frame-list)))))
    (should-not (cmacs-rig-eval
                 rig '(cl-some (lambda (b)
                                 (string-prefix-p "*edit-field" (buffer-name b)))
                               (buffer-list))))
    (should (equal "hunter2" (cmacs-rig-field-text field)))))

(cmacs-rig-deftest edit-field-end-to-end ()
  "The edit-field command: floating editor, tiled windows unmoved, write-back.
Run as a key runs it.  The editor frame must be a FLOATING window of the
compositor, and the geometry of every tiled window must be what it was
before the frame existed, while it exists, and after it is gone."
  (skip-unless (cmacs-rig-field-client))
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-field-edit"
                                       :text "first draft"))
         (other (cmacs-rig-spawn-field rig :title "rig-field-other"
                                       :text "untouched"))
         (id (plist-get field :id))
         before)
    (cmacs-rig-focus rig id)
    (setq before (cmacs-rig-tests--tiled rig))
    (should (= 3 (length before)))      ; two fields and the Emacs frame
    (cmacs-rig-shot rig "edit-field-before-two-fields-tiled")
    (cmacs-rig-do rig '(progn (require 'cmacs-gowl-edit-field)
                              (cmacs-gowl-edit-field)))
    ;; The editor buffer holds the field's text...
    (should (equal "first draft"
                   (cmacs-rig-wait-for
                    rig '(when-let* ((s (car cmacs-gowl-edit-field--sessions))
                                     (b (cmacs-gowl-edit-field--session-buffer s))
                                     ((buffer-live-p b))
                                     ((eq 'editing
                                          (cmacs-gowl-edit-field--session-state
                                           s))))
                           (with-current-buffer b
                             (buffer-substring-no-properties
                              (point-min) (point-max))))
                    10)))
    ;; ...in a frame that is a floating window of this Emacs...
    (let ((frame (cmacs-rig-wait-for
                  rig `(cl-some
                        (lambda (c)
                          (let ((info (gowl-client-info c)))
                            (and (equal (alist-get 'title info)
                                        cmacs-gowl-edit-field-frame-name)
                                 (alist-get 'floating info)
                                 info)))
                        (gowl-list-clients))
                  10)))
      (should (alist-get 'floating frame))
      (should (eql (cmacs-rig-pid rig)
                   (alist-get 'pid (cmacs-rig-client
                                    rig (alist-get 'id frame))))))
    ;; ...and nothing that was tiled has moved.
    (cmacs-rig-shot rig "edit-field-floating-editor-open")
    (should (equal before (cmacs-rig-tests--tiled rig)))
    ;; Edit, and finish.
    (cmacs-rig-do
     rig '(with-current-buffer (cmacs-gowl-edit-field--session-buffer
                                (car cmacs-gowl-edit-field--sessions))
            (erase-buffer)
            (insert "second draft, edited in Emacs")
            (cmacs-gowl-edit-field-finish)
            t))
    (cmacs-rig-wait-field-text rig field "second draft, edited in Emacs" 10)
    ;; The editor is gone, the session closed, the layout as it was,
    ;; the other field never touched, the keyboard back in the field.
    (cmacs-rig-wait-for rig '(null cmacs-gowl-edit-field--sessions) 5)
    (cmacs-rig-wait-for rig '(= 1 (length (frame-list))) 5)
    (cmacs-rig-wait-for
     rig `(not (cl-some (lambda (c)
                          (equal (alist-get 'title (gowl-client-info c))
                                 cmacs-gowl-edit-field-frame-name))
                        (gowl-list-clients)))
     5)
    (cmacs-rig-shot rig "edit-field-after-write-back")
    (should (equal before (cmacs-rig-tests--tiled rig)))
    (should (equal "untouched" (cmacs-rig-field-text other)))
    (should (eql id (cmacs-rig-eval
                     rig '(alist-get 'id (gowl-client-info
                                          (gowl-focused-client))))))))

(cmacs-rig-deftest edit-field-abort-leaves-field ()
  "Giving up closes the editor and changes nothing in the field."
  (skip-unless (cmacs-rig-field-client))
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-field-abort"
                                       :text "keep me"))
         (before nil))
    (cmacs-rig-focus rig (plist-get field :id))
    (setq before (cmacs-rig-tests--tiled rig))
    (cmacs-rig-do rig '(progn (require 'cmacs-gowl-edit-field)
                              (cmacs-gowl-edit-field)))
    (cmacs-rig-wait-for
     rig '(when-let* ((s (car cmacs-gowl-edit-field--sessions)))
            (eq 'editing (cmacs-gowl-edit-field--session-state s)))
     10)
    ;; Unmodified, so the abort has nothing to ask about.
    (cmacs-rig-do
     rig '(with-current-buffer (cmacs-gowl-edit-field--session-buffer
                                (car cmacs-gowl-edit-field--sessions))
            (set-buffer-modified-p nil)
            (cmacs-gowl-edit-field-abort)
            t))
    (cmacs-rig-wait-for rig '(null cmacs-gowl-edit-field--sessions) 5)
    (cmacs-rig-wait-for rig '(= 1 (length (frame-list))) 5)
    (cmacs-rig-tests--sleep 0.3)
    (should (equal "keep me" (cmacs-rig-field-text field)))
    (should (equal before (cmacs-rig-tests--tiled rig)))))

;;;; (e) The AI field commands, with a model that is not one

(defun cmacs-rig-tests--install-fake-model (rig answer delay)
  "Replace RIG's model call by one that answers ANSWER after DELAY seconds.
Inside the child, around the three entry points
cmacs-gowl-ai-field.el uses: the session constructor, the stream and
the cancel.  No provider is configured and no socket is opened.  What
the model was asked is kept in `cmacs-rig-child-asked'."
  (cmacs-rig-eval
   rig `(progn
          (require 'cmacs-gowl-edit-field)
          (require 'cmacs-gowl-ai-field)
          (require 'cmacs-ai)
          (defvar cmacs-rig-child-asked nil)
          (setq cmacs-rig-child-asked nil)
          ;; A toast would go to the bar; a message is enough here.
          (setq cmacs-gowl-ai-field-toast nil
                cmacs-gowl-ai-field-progress-interval nil)
          (advice-add 'cmacs-ai--ensure :override #'ignore
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-make-session :override
                      (lambda (&rest args)
                        (push (cons :session args) cmacs-rig-child-asked)
                        (cons 'cmacs-rig-client 'cmacs-rig-session))
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-chat-stream :override
                      (lambda (_session prompt callback &rest _)
                        (push (cons :prompt prompt) cmacs-rig-child-asked)
                        ;; In two pieces and then the end, later: the
                        ;; shape of a provider that streams.
                        ;; The callback goes as the timer's argument:
                        ;; the MCP `eval' tool evaluates with dynamic
                        ;; binding, so this lambda closes over nothing.
                        (run-at-time
                         ,delay nil
                         (lambda (callback)
                           (let* ((answer ,answer)
                                  (half (/ (length answer) 2)))
                             (funcall callback
                                      (list :delta (substring answer 0 half)))
                             (funcall callback
                                      (list :delta (substring answer half)))
                             (funcall callback (list :end :text answer))))
                         callback)
                        t)
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-chat-cancel :override #'ignore
                      '((name . cmacs-rig-fake)))
          (advice-add 'cmacs-ai-free-session :override #'ignore
                      '((name . cmacs-rig-fake)))
          t)))

(cmacs-rig-deftest ai-field-writes-the-answer ()
  "Field text -> action -> the field holds the model's answer.
The model is a function in the child.  What it was asked must contain
the field's text and must not contain the window's title or app id."
  (skip-unless (cmacs-rig-field-client))
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-ai-title-zz"
                                       :app-id "rig-ai-app-zz"
                                       :text "teh quick brwon fox"))
         (other (cmacs-rig-spawn-field rig :title "rig-ai-other"
                                       :text "bystander")))
    (cmacs-rig-tests--install-fake-model rig "The quick brown fox." 0.2)
    (cmacs-rig-focus rig (plist-get field :id))
    (cmacs-rig-shot rig "ai-field-before")
    (cmacs-rig-do rig '(cmacs-gowl-ai-field-run 'proofread))
    (cmacs-rig-wait-field-text rig field "The quick brown fox." 15)
    (cmacs-rig-shot rig "ai-field-after-answer-written")
    (cmacs-rig-wait-for rig '(null cmacs-gowl-ai-field--job) 5)
    (should (equal "bystander" (cmacs-rig-field-text other)))
    (let ((asked (format "%S" (cmacs-rig-eval rig 'cmacs-rig-child-asked))))
      (should (cmacs-rig-tests--contains "teh quick brwon fox" asked))
      (should-not (cmacs-rig-tests--contains "rig-ai-title-zz" asked))
      (should-not (cmacs-rig-tests--contains "rig-ai-app-zz" asked)))
    ;; Undo puts the old text back, while the window still has the keys.
    (cmacs-rig-do rig '(cmacs-gowl-ai-field-undo))
    (cmacs-rig-wait-field-text rig field "teh quick brwon fox" 10)))

(cmacs-rig-deftest ai-field-focus-moved ()
  "The keyboard moved while the model worked: nothing is typed anywhere.
Neither into the window that was asked about nor into the one that has
the keyboard now; the answer goes to the kill ring."
  (skip-unless (cmacs-rig-field-client))
  (let* ((field (cmacs-rig-spawn-field rig :title "rig-ai-asked"
                                       :text "ask about me"))
         (other (cmacs-rig-spawn-field rig :title "rig-ai-elsewhere"
                                       :text "do not touch")))
    (cmacs-rig-tests--install-fake-model rig "ANSWER THAT MUST NOT LAND" 1.5)
    (cmacs-rig-focus rig (plist-get field :id))
    (cmacs-rig-do rig '(cmacs-gowl-ai-field-run 'rewrite))
    ;; The model has been asked and has not answered yet.
    (cmacs-rig-wait-for rig '(assq :prompt cmacs-rig-child-asked) 10)
    (cmacs-rig-focus rig (plist-get other :id))
    ;; The job ends with the answer kept, not typed.
    (cmacs-rig-wait-for rig '(null cmacs-gowl-ai-field--job) 15)
    (cmacs-rig-tests--sleep 0.5)
    (should (equal "ask about me" (cmacs-rig-field-text field)))
    (should (equal "do not touch" (cmacs-rig-field-text other)))
    (cmacs-rig-shot rig "ai-field-focus-moved-nothing-typed")
    (should (equal "ANSWER THAT MUST NOT LAND"
                   (cmacs-rig-eval rig '(car kill-ring))))))

(cmacs-rig-deftest ai-field-excluded-window-is-withheld ()
  "A window the redaction rules exclude is never sent to a model.
Run as the key runs it -- from the main loop, not over RPC -- because
that is how the command is reached, and the redaction functions are
the identity for a caller they do not take to be model-facing."
  ;; This was a bug the rig found: `cmacs-gowl-ai-field--withheld-p'
  ;; asked `cmacs-redact-window' with nothing saying a model was the
  ;; reader, so from a key binding every window was "shown" and an
  ;; excluded window's field was sent.  The unit tests stubbed
  ;; `cmacs-redact-window', which hid it.
  (skip-unless (cmacs-rig-field-client))
  (should (cmacs-rig-tests--write-filters rig cmacs-rig-tests--rules))
  (let ((field (cmacs-rig-spawn-field
                rig :title (concat cmacs-rig-tests--secret "-window")
                :text "account 12345678")))
    (cmacs-rig-tests--install-fake-model rig "LEAKED AND REWRITTEN" 0.2)
    (cmacs-rig-focus rig (plist-get field :id))
    (cmacs-rig-do rig '(cmacs-gowl-ai-field-run 'proofread))
    (cmacs-rig-tests--sleep 2.0)
    (cmacs-rig-wait-for rig '(null cmacs-gowl-ai-field--job) 10)
    (should-not (cmacs-rig-eval rig '(assq :prompt cmacs-rig-child-asked)))
    (should (equal "account 12345678" (cmacs-rig-field-text field)))))

;;;; (f) The journal

(defun cmacs-rig-tests--start-journal (rig)
  "Turn RIG's journal and its checkpoints on, with short spans."
  (cmacs-rig-do
   rig '(progn (require 'cmacs-journal)
               (require 'cmacs-journal-checkpoint)
               (require 'cmacs-journal-restore)
               ;; Tunables, not internals: a span of a third of a
               ;; second counts, so the test need not sit for minutes.
               (setq cmacs-journal-min-span 0.3
                     cmacs-journal-merge-gap 0.05
                     cmacs-journal-restore-poll-interval 0.2)
               (cmacs-journal-mode 1)
               (cmacs-journal-checkpoint-mode 1)
               (cmacs-journal-recording-p))))

(defun cmacs-rig-tests--journal-events (rig)
  "Flush RIG's journal and return its events as (KIND TITLE APP TAGS)."
  (cmacs-rig-do
   rig '(progn (cmacs-journal-flush)
               (mapcar (lambda (e)
                         (list (plist-get e :kind) (plist-get e :title)
                               (plist-get e :app) (plist-get e :tags)))
                       (cmacs-journal-events)))))

(cmacs-rig-deftest journal-records-focus-spans ()
  "Focus moving between windows becomes spans in the child's own journal.
On disk, in the rig's state directory, 0700 and 0600 -- and invisible to
an agent: the same question over the MCP `eval' gets nothing."
  (skip-unless (cmacs-rig-field-client))
  (let* ((a (cmacs-rig-spawn-field rig :title "rig-journal-a"
                                   :app-id "rig-journal-app-a"))
         (b (cmacs-rig-spawn-field rig :title "rig-journal-b"
                                   :app-id "rig-journal-app-b"))
         (dir (expand-file-name "cmacs/journal" (cmacs-rig-state rig))))
    (should (cmacs-rig-tests--start-journal rig))
    (dolist (field (list a b a))
      (cmacs-rig-focus rig (plist-get field :id))
      (cmacs-rig-tests--sleep 0.8))
    ;; Close the last span by moving on.
    (cmacs-rig-focus rig (plist-get b :id))
    (cmacs-rig-tests--sleep 0.5)
    (cmacs-rig-shot rig "journal-recording-two-windows")
    (let* ((events (cmacs-rig-tests--journal-events rig))
           (titles (mapcar #'cadr
                           (cl-remove-if-not (lambda (e) (eq 'focus (car e)))
                                             events))))
      (ert-info ((format "%S" events) :prefix "events: ")
        (should (>= (cl-count "rig-journal-a" titles :test #'equal) 2))
        (should (>= (cl-count "rig-journal-b" titles :test #'equal) 1))
        (should (cl-find "rig-journal-app-a" events :key #'caddr
                         :test #'equal))))
    ;; The files: the rig's, private, and nowhere else.
    (should (file-directory-p dir))
    (should (eql #o700 (logand #o777 (file-modes dir))))
    (let ((days (directory-files dir t "\\.jsonl\\'")))
      (should days)
      (dolist (file days)
        (should (eql #o600 (logand #o777 (file-modes file)))))
      (should (cmacs-rig-tests--contains
               "rig-journal-a"
               (with-temp-buffer (insert-file-contents (car days))
                                 (buffer-string)))))
    ;; An agent asking the same thing is told nothing.
    (should-not (cmacs-rig-eval rig '(cmacs-journal-events)))
    (should-not (cmacs-rig-tests--contains
                 "rig-journal-a"
                 (cdr (cmacs-rig-tests--tool rig "lql_query"
                                             '(:query "fetch activity")))))))

(cmacs-rig-deftest journal-excluded-window-leaves-no-span ()
  "A window the rules exclude is never written to the journal's files."
  (skip-unless (cmacs-rig-field-client))
  (should (cmacs-rig-tests--write-filters rig cmacs-rig-tests--rules))
  (let ((secret (cmacs-rig-spawn-field
                 rig :title (concat cmacs-rig-tests--secret "-window")))
        (public (cmacs-rig-spawn-field rig :title "rig-journal-public"))
        (dir (expand-file-name "cmacs/journal" (cmacs-rig-state rig))))
    (should (cmacs-rig-tests--start-journal rig))
    (dolist (field (list public secret public secret public))
      (cmacs-rig-focus rig (plist-get field :id))
      (cmacs-rig-tests--sleep 0.7))
    (let ((events (cmacs-rig-tests--journal-events rig)))
      (should (cl-find "rig-journal-public" events :key #'cadr :test #'equal))
      (should-not (cmacs-rig-tests--contains cmacs-rig-tests--secret
                                             (format "%S" events))))
    (dolist (file (directory-files dir t "\\`[^.]"))
      (should-not (cmacs-rig-tests--contains
                   cmacs-rig-tests--secret
                   (with-temp-buffer (insert-file-contents-literally file)
                                     (buffer-string)))))))

(cmacs-rig-deftest journal-checkpoint-and-restore ()
  "A checkpoint lists the rig's windows; a restore relaunches a closed one.
The window is put on tag 2 before the checkpoint.  After it is closed,
the plan for \"now\" must offer to start it again, and executing the
plan must bring a window of that title back ON TAG 2."
  (skip-unless (cmacs-rig-field-client))
  (let* ((stay (cmacs-rig-spawn-field rig :title "rig-restore-stay"
                                      :app-id "rig-restore-stay"))
         (gone (cmacs-rig-spawn-field rig :title "rig-restore-gone"
                                      :app-id "rig-restore-gone"))
         (gone-id (plist-get gone :id)))
    (should (cmacs-rig-tests--start-journal rig))
    (cmacs-rig-eval
     rig `(gowl-set-tags (cl-find-if
                          (lambda (c)
                            (eql ,gone-id (alist-get 'id (gowl-client-info c))))
                          (gowl-list-clients))
                         2))
    (cmacs-rig-wait-for
     rig `(eql 2 (alist-get 'tags (gowl-client-info
                                   (cl-find-if
                                    (lambda (c)
                                      (eql ,gone-id
                                           (alist-get 'id (gowl-client-info c))))
                                    (gowl-list-clients)))))
     5)
    (cmacs-rig-focus rig (plist-get stay :id))
    (cmacs-rig-tests--sleep 0.6)
    ;; The checkpoint: both windows, with the tag and a command line.
    (let ((clients (cmacs-rig-do
                    rig '(let ((event (cmacs-journal-checkpoint-take t)))
                           (cmacs-journal-flush)
                           (mapcar (lambda (c)
                                     (list (plist-get c :title)
                                           (plist-get c :tags)
                                           (and (plist-get c :command) t)))
                                   (plist-get
                                    (cmacs-journal-checkpoint-decode event)
                                    :clients))))))
      (ert-info ((format "%S" clients) :prefix "checkpoint clients: ")
        (should (member '("rig-restore-stay" (1) t) clients))
        (should (member '("rig-restore-gone" (2) t) clients))))
    ;; While both run, the plan has nothing to start.
    (let ((items (cmacs-rig-do
                  rig '(mapcar (lambda (i)
                                 (list (plist-get i :section)
                                       (plist-get i :type)
                                       (plist-get i :label)))
                               (plist-get (cmacs-journal-restore-plan
                                           (float-time))
                                          :items)))))
      (ert-info ((format "%S" items) :prefix "plan: ")
        (should (cl-find-if (lambda (i)
                              (and (eq 'apps (car i))
                                   (cmacs-rig-tests--contains
                                    "rig-restore-stay" (caddr i))))
                            items))
        (should (cl-find-if (lambda (i)
                              (and (eq 'apps (car i))
                                   (cmacs-rig-tests--contains
                                    "rig-restore-gone" (caddr i))))
                            items))
        (should-not (cl-find 'launch items :key #'cadr))))
    ;; Close one, and the plan offers to start it; execute it.
    (cmacs-rig-close-client rig gone-id)
    (should (equal "launch"
                   (cmacs-rig-do
                    rig '(let* ((plan (cmacs-journal-restore-plan (float-time)))
                                (item (cl-find-if
                                       (lambda (i)
                                         (eq 'launch (plist-get i :type)))
                                       (plist-get plan :items))))
                           (defvar cmacs-rig-child-plan nil)
                           (setq cmacs-rig-child-plan plan)
                           (and item
                                (string-search "rig-restore-gone"
                                               (plist-get item :label))
                                (symbol-name (plist-get item :type)))))))
    (cmacs-rig-do rig '(progn (cmacs-journal-restore-show-plan
                               cmacs-rig-child-plan)
                              t))
    (cmacs-rig-shot rig "journal-restore-plan-buffer")
    (cmacs-rig-do rig '(progn (cmacs-journal-restore-execute
                               cmacs-rig-child-plan)
                              t))
    (let ((back (cmacs-rig-wait-for
                 rig '(cl-some
                       (lambda (c)
                         (let ((info (gowl-client-info c)))
                           (and (equal "rig-restore-gone"
                                       (alist-get 'title info))
                                (list (alist-get 'id info)
                                      (alist-get 'tags info)))))
                       (gowl-list-clients))
                 20)))
      (should-not (eql gone-id (car back)))
      ;; On the recorded tag -- at once or after the poll places it.
      (cmacs-rig-wait-for
       rig '(cl-some (lambda (c)
                       (let ((info (gowl-client-info c)))
                         (and (equal "rig-restore-gone"
                                     (alist-get 'title info))
                              (eql 2 (alist-get 'tags info)))))
                     (gowl-list-clients))
       10))
    ;; The relaunched window is on tag 2: look there for the picture.
    (cmacs-rig-eval rig '(progn (gowl-view-tags 2) t))
    (cmacs-rig-shot rig "journal-restore-relaunched-on-tag-2")
    (cmacs-rig-eval rig '(progn (gowl-view-tags 1) t))
    ;; An agent may not do this at all.
    (should-error
     (cmacs-rig-eval rig '(cmacs-journal-restore-execute cmacs-rig-child-plan))
     :type 'cmacs-rig-tool-error)))

;;;; (g) LQL watches

(cmacs-rig-deftest lql-watch-fires-once ()
  "A watch on `buffers' fires once when a buffer appears, and not when idle.
Three natural ticks with nothing changing, then a new buffer, then
three more ticks: one call to :on-change in all, naming the buffer."
  (skip-unless (cmacs-rig-eval rig '(progn (require 'cmacs-lql nil t)
                                           (fboundp 'cmacs-lql-run))))
  (cmacs-rig-do
   rig '(progn
          (require 'cmacs-lql)
          (require 'cmacs-lql-watch)
          (defvar cmacs-rig-child-fires nil)
          (setq cmacs-rig-child-fires nil)
          ;; A tunable: watches may poll every second here.
          (setq cmacs-lql-watch-min-interval 1
                cmacs-lql-watch-min-idle 0)
          (cmacs-lql-watch
           "rig-watch"
           "fetch buffers | filter starts_with(name, \"rig-watched\") | fields name | sort name"
           :every 1 :key "name" :depends 'always
           :on-change (lambda (new _old diff)
                        (push (list (mapcar (lambda (row)
                                              (cdr (assoc "name" row)))
                                            new)
                                    (length (plist-get diff :added)))
                              cmacs-rig-child-fires)))
          t))
  ;; The baseline arrives and fires nothing.
  (cmacs-rig-wait-for rig '(>= (or (cmacs-lql-watch-get "rig-watch" :runs) 0) 1)
                      20)
  (ert-info ((format "%S" (cmacs-rig-eval
                           rig '(car (cmacs-lql-watch-list))))
             :prefix "watch: ")
    (should-not (cmacs-rig-eval rig '(cmacs-lql-watch-get "rig-watch"
                                                          :last-error)))
    ;; Idle ticks: it keeps running, and stays quiet.
    (let ((runs (cmacs-rig-eval rig '(cmacs-lql-watch-get "rig-watch" :runs))))
      (cmacs-rig-wait-for
       rig `(>= (cmacs-lql-watch-get "rig-watch" :runs) ,(+ runs 2)) 20))
    (should-not (cmacs-rig-eval rig 'cmacs-rig-child-fires))
    ;; A buffer the query matches.
    (cmacs-rig-eval rig '(progn (get-buffer-create "rig-watched-one") t))
    (should (equal '((("rig-watched-one") 1))
                   (cmacs-rig-wait-for rig 'cmacs-rig-child-fires 20)))
    ;; More ticks with nothing new: still the one.
    (let ((runs (cmacs-rig-eval rig '(cmacs-lql-watch-get "rig-watch" :runs))))
      (cmacs-rig-wait-for
       rig `(>= (cmacs-lql-watch-get "rig-watch" :runs) ,(+ runs 2)) 20))
    (cmacs-rig-do rig '(progn (cmacs-lql-watches) t))
    (cmacs-rig-shot rig "lql-watch-list-after-one-change")
    (should (= 1 (length (cmacs-rig-eval rig 'cmacs-rig-child-fires))))
    (should (= 1 (cmacs-rig-eval rig '(cmacs-lql-watch-get "rig-watch"
                                                          :changes))))))

;;;; (h) Where the pointer was

(cmacs-rig-deftest deixis-pointer-history ()
  "The pointer ring answers \"where was it at time T\" with the window.
The pointer is moved with `gowl-pointer-warp', the injection a software
KVM uses: onto one window, then, later, onto another.  Asked about the
first moment the ring names the first window; about the second, the
second; and \"this\", asked now, is the window under the pointer."
  (skip-unless (cmacs-rig-field-client))
  (skip-unless (cmacs-rig-eval rig '(fboundp 'gowl-pointer-history-at)))
  (let* ((a (cmacs-rig-spawn-field rig :title "rig-point-a"))
         (b (cmacs-rig-spawn-field rig :title "rig-point-b"))
         (centre (lambda (field)
                   (let ((g (alist-get 'geometry
                                       (cmacs-rig-client
                                        rig (plist-get field :id)))))
                     ;; The client's buffer is smaller than its tile and
                     ;; sits at the tile's origin: stay inside it.
                     (cons (+ (nth 0 g) 40) (+ (nth 1 g) 40)))))
         (at-a (funcall centre a))
         (at-b (funcall centre b))
         t-a t-b)
    (should (cmacs-rig-eval rig '(gowl-pointer-history-enable t)))
    (cmacs-rig-eval rig `(gowl-pointer-warp ,(car at-a) ,(cdr at-a)))
    (cmacs-rig-tests--sleep 0.4)
    (setq t-a (cmacs-rig-eval rig '(gowl-pointer-history-now)))
    (cmacs-rig-tests--sleep 0.4)
    (cmacs-rig-eval rig `(gowl-pointer-warp ,(car at-b) ,(cdr at-b)))
    (cmacs-rig-tests--sleep 0.4)
    (setq t-b (cmacs-rig-eval rig '(gowl-pointer-history-now)))
    (cmacs-rig-tests--sleep 0.2)
    (cmacs-rig-shot rig "deixis-pointer-on-second-window")
    (let ((was-a (cmacs-rig-eval
                  rig `(let ((s (gowl-pointer-history-at ,t-a)))
                         (list (plist-get s :client-id)
                               (round (plist-get s :x))
                               (round (plist-get s :y))
                               (plist-get s :monitor)))))
          (was-b (cmacs-rig-eval
                  rig `(let ((s (gowl-pointer-history-at ,t-b)))
                         (list (plist-get s :client-id)
                               (round (plist-get s :x))
                               (round (plist-get s :y))
                               (plist-get s :monitor))))))
      (should (equal was-a (list (plist-get a :id) (car at-a) (cdr at-a) 0)))
      (should (equal was-b (list (plist-get b :id) (car at-b) (cdr at-b) 0))))
    ;; The longest rest in the first stretch was on the first window.
    (should (eql (plist-get a :id)
                 (cmacs-rig-eval
                  rig `(plist-get (gowl-pointer-history-dwell ,(- t-a 300)
                                                              ,t-a)
                                  :client-id))))
    ;; Before the ring began there is nothing to say.
    (should-not (cmacs-rig-eval rig `(gowl-pointer-history-at ,(- t-a 600000))))
    ;; And the deixis layer turns "now" into the window, by title.
    (let ((referent (cmacs-rig-do
                     rig '(progn (require 'cmacs-deixis)
                                 (let ((r (cmacs-deixis-referent-now)))
                                   (list (plist-get r :kind)
                                         (plist-get r :title)
                                         (plist-get r :client-id)
                                         (plist-get r :device)))))))
      (should (equal referent (list 'window "rig-point-b"
                                    (plist-get b :id) 'gowl))))
    ;; Off empties it.
    (cmacs-rig-eval rig '(gowl-pointer-history-enable nil))
    (should-not (cmacs-rig-eval rig `(gowl-pointer-history-at ,t-b)))))

;;;; The main thread after startup
;;
;; Everything above runs in a rig that has been up for a while.  This
;; one watches a session from its first second, because that is where a
;; stall was: the bar's AI widget listed models from an idle timer, and
;; one provider's "static" list was a program run that took twenty
;; seconds where the program was slow or missing.  Under --gowl the
;; main thread is the compositor's, so that was a desktop frozen for
;; twenty seconds after every login.  No test of any feature noticed:
;; each of them only ran later, or failed for a reason that read like
;; its own (a window that "never kept the keyboard").

(defconst cmacs-rig-tests--stall-limit 2.0
  "Seconds one trivial `eval' may take before the session counts as stalled.")

(ert-deftest cmacs-rig-test-startup-never-stalls ()
  "For half a minute from its start, a session answers a trivial eval promptly.
A rig of its own: the shared one is long past its startup."
  (unless (cmacs-rig-tests--enabled-p)
    (ert-skip "rig tests run only with CMACS_RIG=1 (`just test-rig')"))
  (when-let* ((why (or cmacs-rig-tests--why-not (cmacs-rig-available-p))))
    (ert-skip (format "no rig here: %s" why)))
  (let ((rig (cmacs-rig-start))
        (worst 0.0) (when-worst 0.0) (began (float-time)))
    (unwind-protect
        (progn
          (while (< (- (float-time) began) 30)
            (let* ((asked (float-time))
                   (_ (cmacs-rig-eval rig '(+ 1 1) 90))
                   (took (- (float-time) asked)))
              (when (> took worst)
                (setq worst took
                      when-worst (- asked began))))
            (accept-process-output nil 0.25))
          (message "cmacs-rig-tests: slowest eval in the first 30 s: %.2f s, %.1f s after the rig was ready" worst when-worst)
          (should (< worst cmacs-rig-tests--stall-limit)))
      (ignore-errors (cmacs-rig-stop rig)))))

(provide 'cmacs-rig-tests)

;;; cmacs-rig-tests.el ends here
