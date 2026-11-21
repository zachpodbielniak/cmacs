;;; cmacs-gowl-tools-tests.el --- The gowl tool family on the capability table -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-gowl-tools.el against two things.
;;
;; The C it stands in for: every migrated tool is compared with the text
;; of cmacs/mcp/cmacs-mcp-tools-gowl.c -- name, description, parameter
;; names in order, types, required-ness, enums, and whether the C called
;; it read-only.  The C stays as the fallback, so the two must not drift;
;; and a `gowl_' tool added to the C without a decision here (migrated,
;; or skipped with a reason) fails the suite.
;;
;; Its own behaviour, with every `gowl-*' primitive and the redaction
;; contract stubbed: no compositor is needed and none is touched.  The
;; redaction cases are the point -- a window the rules exclude must be
;; absent, must not be actable on, and must not be discoverable by
;; pattern, id, pixel or OCR.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)
(require 'cmacs-gowl-tools)
;; The redaction contract is another file's.  Loaded now when it exists:
;; a first load from inside a test would redefine the functions the test
;; has stubbed, and `cl-letf' would then restore them to nothing.
(require 'cmacs-redact nil t)
;; The subsystem files the tool bodies `require'.  Loaded here so the
;; stubs below replace real definitions rather than racing a later load.
(require 'cmacs-gowl-grab nil t)
(require 'cmacs-gowl-macro nil t)
(require 'cmacs-gowl-broadcast nil t)
(require 'cmacs-gowl-hotkey nil t)

(defconst cmacs-gowl-tools-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time.")

(defun cmacs-gowl-tools-tests--c-file ()
  "Return the gowl MCP C file's name, or nil when the tree is not here."
  (let ((root (locate-dominating-file
               (or cmacs-gowl-tools-tests--this-file default-directory)
               "cmacs/mcp/cmacs-mcp-tools-gowl.c")))
    (and root (expand-file-name "cmacs/mcp/cmacs-mcp-tools-gowl.c" root))))


;;;; The C file, read as text

(defun cmacs-gowl-tools-tests--literals (text)
  "Return the C string literals in TEXT, concatenated and unescaped."
  (let ((pos 0) (parts nil))
    (while (string-match "\"\\(\\(?:[^\"\\\\\n]\\|\\\\.\\)*\\)\"" text pos)
      (push (match-string 1 text) parts)
      (setq pos (match-end 0)))
    (replace-regexp-in-string
     "\\\\\\(.\\)" "\\1" (apply #'concat (nreverse parts)))))

(defun cmacs-gowl-tools-tests--schema (text)
  "Return the JSON schema among the C literals of TEXT, as an alist, or nil."
  (let ((joined (cmacs-gowl-tools-tests--literals text)))
    (when (string-match "{\"type\":\"object\"" joined)
      (with-temp-buffer
        (insert (substring joined (match-beginning 0)))
        (goto-char (point-min))
        (json-parse-buffer :object-type 'alist :array-type 'list)))))

(defun cmacs-gowl-tools-tests--c-tools ()
  "Return the `gowl_' tools the C file registers.
A list of plists (:name :description :read-only :params), :params being
\(NAME TYPE REQUIRED ENUM) lists in schema order.  The file registers
tools two ways -- a `mcp_tool_new' block each, and a table -- and both
are read."
  (with-temp-buffer
    (insert-file-contents (cmacs-gowl-tools-tests--c-file))
    (goto-char (point-min))
    (search-forward "cmacs_mcp_tools_gowl_register (McpServer")
    (let ((starts nil) (out nil))
      (while (re-search-forward
              "\\(mcp_tool_new (\\|{ \\)\"\\([a-z_]+\\)\"\\(, \\(TRUE\\|FALSE\\),\\)?"
              nil t)
        ;; A table row is `{ "name", TRUE,'; anything else beginning
        ;; `{ "' is not a tool.
        (when (or (string-prefix-p "mcp_tool_new" (match-string 1))
                  (match-string 3))
          (push (list (match-beginning 0) (match-end 2) (match-string 2)
                      (and (match-string 3) (match-string 4)))
                starts)))
      (setq starts (nreverse starts))
      (cl-loop
       for (start) on starts
       for next = (cadr (memq start starts))
       do
       (pcase-let* ((`(,_beg ,after-name ,name ,flag) start)
                    (end (if next (car next) (point-max)))
                    (block (buffer-substring-no-properties after-name end))
                    (table (and flag t))
                    (schema (cmacs-gowl-tools-tests--schema block))
                    (required (alist-get 'required schema))
                    (description
                     (cmacs-gowl-tools-tests--literals
                      (if table
                          ;; { NAME, FLAG, SCHEMA, HANDLER, DESCRIPTION }
                          (and (string-match
                                "handle_[a-z_]+,\\([^}]*?\\)}[,\n ]" block)
                               (match-string 1 block))
                        ;; mcp_tool_new (NAME, DESCRIPTION);
                        (substring block 0 (string-match ");" block))))))
         (when (string-prefix-p "gowl_" name)
           (push
            (list :name name
                  :description description
                  :read-only
                  (if table
                      (equal flag "TRUE")
                    (and (string-match-p
                          "mcp_tool_set_read_only_hint (tool, TRUE)" block)
                         t))
                  :params
                  (mapcar (lambda (prop)
                            (list (symbol-name (car prop))
                                  (alist-get 'type (cdr prop))
                                  (and (member (symbol-name (car prop))
                                               required)
                                       t)
                                  (alist-get 'enum (cdr prop))))
                          (alist-get 'properties schema)))
            out))))
      (nreverse out))))

(defconst cmacs-gowl-tools-tests--skipped
  '(("gowl_screenshot" . "returns an image")
    ("gowl_reload_config" . "no DEFUN reloads from gowl's search path")
    ("gowl_macro_run" . "array parameter; runs arbitrary C")
    ("gowl_broadcast_add_team" . "object parameter")
    ("gowl_broadcast_add_rule" . "object parameter")
    ("gowl_hotkey_add" . "object parameter")
    ("gowl_hotkey_send" . "types into the focused window: privileged"))
  "The C `gowl_' tools deliberately left in C, each with its reason.")

(ert-deftest cmacs-gowl-tools-test-family-matches-c ()
  "Every migrated tool is the C one: name, schema, description, hint."
  (skip-unless (cmacs-gowl-tools-tests--c-file))
  (let* ((c (cmacs-gowl-tools-tests--c-tools))
         (names (mapcar (lambda (tool) (plist-get tool :name)) c))
         (migrated 0))
    ;; The parser found the family, not a fragment of it.
    (should (= (length c) 47))
    (should (equal (length names) (length (delete-dups (copy-sequence names)))))
    (dolist (tool c)
      (let* ((name (plist-get tool :name))
             (entry (cmacs-capability-describe-tool name)))
        (ert-info ((format "tool %s" name))
          (if (assoc name cmacs-gowl-tools-tests--skipped)
              ;; Left in C on purpose, and so not half-migrated.
              (should-not entry)
            ;; Anything else in the C must be here: a new C tool needs a
            ;; decision, not a silent gap.
            (should entry)
            (cl-incf migrated)
            (should (equal (plist-get entry :description)
                           (plist-get tool :description)))
            (should (equal (mapcar (lambda (p)
                                     (list (plist-get p :name)
                                           (plist-get p :type)
                                           (and (plist-get p :required) t)
                                           (plist-get p :enum)))
                                   (plist-get entry :params))
                           (plist-get tool :params)))
            ;; Read-only in C is exactly not-destructive here.
            (should (eq (and (plist-get entry :destructive) t)
                        (not (plist-get tool :read-only))))
            (should (memq 'mcp (plist-get entry :surfaces)))))))
    (should (= migrated 40))
    ;; And nothing is registered here that the C never had.
    (dolist (entry (cmacs-capability-describe))
      (when (string-prefix-p "gowl_" (plist-get entry :name))
        (should (member (plist-get entry :name) names))))))


;;;; A stubbed compositor

(defvar cmacs-gowl-tools-tests--running t
  "What the stubbed `gowl-running-p' answers.")
(defvar cmacs-gowl-tools-tests--clients nil
  "The stubbed client list: plists standing in for client objects.")
(defvar cmacs-gowl-tools-tests--focused nil
  "The stubbed focused client, one of the above, or nil.")
(defvar cmacs-gowl-tools-tests--monitors nil
  "The stubbed monitors: `gowl-monitor-info' alists.")
(defvar cmacs-gowl-tools-tests--calls nil
  "What the stubs were asked to do, newest first.")
(defvar cmacs-gowl-tools-tests--replies nil
  "Function from a module command line to its reply.")

(defun cmacs-gowl-tools-tests--client (id app title &rest more)
  "Return a stub client ID with APP and TITLE; MORE overrides fields."
  (append more (list :id id :app app :title title :tags 1 :floating nil
                     :pid (+ 1000 id) :geometry (list 0 0 800 600))))

(defun cmacs-gowl-tools-tests--glob (pattern text)
  "Non-nil when TEXT matches the glob PATTERN (gowl's own search)."
  (string-match-p (wildcard-to-regexp pattern) text))

(defmacro cmacs-gowl-tools-tests--with-gowl (&rest body)
  "Run BODY with gowl and the redaction contract stubbed.
The rules of the stub: app-id \"keepassxc\" is excluded; a title
containing \"secret\" is shown as \"[redacted]\"; \"hunter2\" in free
text becomes \"****\"."
  (declare (indent 0) (debug t))
  `(let ((cmacs-gowl-tools-tests--calls nil))
     ;; cmacs-redact.el is another file's to provide; the bodies
     ;; `require' it, and here its functions are the stubs below.
     ;; `cl-progv' because the binding has to be dynamic in compiled
     ;; code too.
     (cl-progv '(features) (list (cons 'cmacs-redact features))
      (cl-letf*
         (((symbol-function 'gowl-running-p)
           (lambda (&rest _) cmacs-gowl-tools-tests--running))
          ((symbol-function 'gowl-list-clients)
           (lambda (&rest _) cmacs-gowl-tools-tests--clients))
          ((symbol-function 'gowl-focused-client)
           (lambda (&rest _) cmacs-gowl-tools-tests--focused))
          ((symbol-function 'gowl-client-info)
           (lambda (c &rest _)
             (list (cons 'id (plist-get c :id))
                   (cons 'title (plist-get c :title))
                   (cons 'app-id (plist-get c :app))
                   (cons 'tags (plist-get c :tags))
                   (cons 'floating (plist-get c :floating))
                   (cons 'embedded nil)
                   (cons 'geometry (plist-get c :geometry)))))
          ((symbol-function 'gowl-client-pid)
           (lambda (c &rest _) (plist-get c :pid)))
          ((symbol-function 'gowl-client-sticky-p)
           (lambda (c &rest _) (plist-get c :sticky)))
          ((symbol-function 'gowl-find-client)
           (lambda (pattern &optional by &rest _)
             (unless cmacs-gowl-tools-tests--running
               (error "Gowl compositor not running"))
             (cl-find-if
              (lambda (c)
                (cmacs-gowl-tools-tests--glob
                 pattern (plist-get c (if (eq by 'title) :title :app))))
              cmacs-gowl-tools-tests--clients)))
          ((symbol-function 'gowl-focus-client)
           (lambda (c &rest _)
             (push (list 'focus (plist-get c :id))
                   cmacs-gowl-tools-tests--calls)
             t))
          ((symbol-function 'gowl-close-client)
           (lambda (c &rest _)
             (push (list 'close (plist-get c :id))
                   cmacs-gowl-tools-tests--calls)
             nil))
          ((symbol-function 'gowl-client-set-geometry)
           (lambda (c &rest box)
             (push (cons 'geometry (cons (plist-get c :id) box))
                   cmacs-gowl-tools-tests--calls)
             t))
          ((symbol-function 'gowl-list-monitors)
           (lambda (&rest _) cmacs-gowl-tools-tests--monitors))
          ((symbol-function 'gowl-monitor-info)
           (lambda (&optional m &rest _) m))
          ((symbol-function 'gowl-run-command)
           (lambda (line &rest _)
             (push (list 'command line) cmacs-gowl-tools-tests--calls)
             (and cmacs-gowl-tools-tests--replies
                  (funcall cmacs-gowl-tools-tests--replies line))))
          ((symbol-function 'gowl-clipboard-set)
           (lambda (text &rest _)
             (push (list 'clipboard text) cmacs-gowl-tools-tests--calls)
             t))
          ((symbol-function 'cmacs-redact-window)
           (lambda (app title &rest _)
             (unless (equal app "keepassxc")
               (cons app
                     (if (and title (string-match-p "secret" title))
                         "[redacted]"
                       title)))))
          ((symbol-function 'cmacs-redact-text)
           (lambda (text &rest _)
             (replace-regexp-in-string "hunter2" "****" text t t))))
        ,@body))))

(defun cmacs-gowl-tools-tests--call (name &rest args)
  "Call the tool NAME with ARGS, a plist of wire names and values.
Returns its result string; a failure is \"Error: ...\"."
  (cmacs-brigade-call-tool
   name
   (if args
       (json-serialize
        (cl-loop for (key value) on args by #'cddr
                 collect (cons (intern key) value)))
     "{}")))

(defun cmacs-gowl-tools-tests--error-p (result message)
  "Non-nil when RESULT is the failure MESSAGE."
  (equal result (concat "Error: " message)))


;;;; No compositor

(ert-deftest cmacs-gowl-tools-test-no-compositor ()
  "Without a compositor every tool fails with the C's message."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--running nil))
      (pcase-dolist (`(,name . ,args)
                     '(("gowl_list_clients")
                       ("gowl_focused_client")
                       ("gowl_list_monitors")
                       ("gowl_list_keybinds")
                       ("gowl_recording_status")
                       ("gowl_find_client" "pattern" "foot")
                       ("gowl_focus_client" "pattern" "foot")
                       ("gowl_close_client" "pattern" "foot")
                       ("gowl_spawn" "command" "foot")
                       ("gowl_set_layout" "layout" "tile")
                       ("gowl_workspace_switch" "id" 1)
                       ("gowl_set_monitor_transform"
                        "name" "eDP-1" "transform" 1)
                       ("gowl_drain_recording" "token" "x")
                       ("gowl_pick_color" "x" 1 "y" 1)
                       ("gowl_screen_text"
                        "x" 0 "y" 0 "width" 10 "height" 10)))
        (ert-info ((format "tool %s" name))
          (should (cmacs-gowl-tools-tests--error-p
                   (apply #'cmacs-gowl-tools-tests--call name args)
                   "Gowl compositor not running"))))
      ;; The C's workspace list answered nil here, printed twice.
      (cl-letf (((symbol-function 'gowl-workspace-list) (lambda (&rest _) nil)))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_workspace_list")
                       "\"nil\""))))))


;;;; Clients

(ert-deftest cmacs-gowl-tools-test-list-clients ()
  "The client list is the C's JSON, minus what the rules withhold."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--clients
           (list (cmacs-gowl-tools-tests--client 1 "foot" "sh \"x\"")
                 (cmacs-gowl-tools-tests--client 2 "keepassxc" "Passwords")
                 (cmacs-gowl-tools-tests--client
                  3 "librewolf" "my secret plan" :floating t :tags 4
                  :geometry '(10 20 300 200)))))
      (let ((text (cmacs-gowl-tools-tests--call "gowl_list_clients")))
        ;; No DEFUN reads the fullscreen flag yet, so the key is absent
        ;; rather than invented; every other key is the C's, in order.
        (should (equal text
                       (concat
                        "[{\"id\":1,\"title\":\"sh \\\"x\\\"\","
                        "\"app-id\":\"foot\",\"tags\":1,\"floating\":false,"
                        "\"pid\":1001,\"geometry\":[0,0,800,600]},"
                        "{\"id\":3,\"title\":\"[redacted]\","
                        "\"app-id\":\"librewolf\",\"tags\":4,"
                        "\"floating\":true,\"pid\":1003,"
                        "\"geometry\":[10,20,300,200]}]")))
        (should-not (string-match-p "keepassxc\\|Passwords\\|secret" text))
        (should (= (length (json-parse-string text)) 2)))
      ;; The day `gowl-client-info' carries the flag, so does the JSON.
      (cl-letf (((symbol-function 'gowl-client-info)
                 (lambda (c &rest _)
                   (list (cons 'id (plist-get c :id)) (cons 'title "t")
                         (cons 'app-id "a") (cons 'tags 1)
                         (cons 'floating nil) (cons 'fullscreen t)
                         (cons 'geometry '(0 0 1 1))))))
        (should (string-match-p
                 "\"floating\":false,\"fullscreen\":true,\"pid\":1001,"
                 (cmacs-gowl-tools-tests--call "gowl_list_clients")))))
    (let ((cmacs-gowl-tools-tests--clients nil))
      (should (equal (cmacs-gowl-tools-tests--call "gowl_list_clients")
                     "[]")))))

(ert-deftest cmacs-gowl-tools-test-focused-client ()
  "The focused client, \"nil\" for none, and \"nil\" for a withheld one."
  (cmacs-gowl-tools-tests--with-gowl
    (should (equal (cmacs-gowl-tools-tests--call "gowl_focused_client") "nil"))
    (let ((cmacs-gowl-tools-tests--focused
           (cmacs-gowl-tools-tests--client 7 "foot" "sh")))
      (should (equal (cmacs-gowl-tools-tests--call "gowl_focused_client")
                     (concat "{\"id\":7,\"title\":\"sh\",\"app-id\":\"foot\","
                             "\"tags\":1,\"floating\":false,\"pid\":1007,"
                             "\"geometry\":[0,0,800,600]}"))))
    (let ((cmacs-gowl-tools-tests--focused
           (cmacs-gowl-tools-tests--client 8 "keepassxc" "Passwords")))
      (should (equal (cmacs-gowl-tools-tests--call "gowl_focused_client")
                     "nil")))))

(ert-deftest cmacs-gowl-tools-test-find-client ()
  "Finding matches what the caller is shown, never what it is not."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--clients
           (list (cmacs-gowl-tools-tests--client 1 "keepassxc" "Vault - bank")
                 (cmacs-gowl-tools-tests--client 2 "librewolf" "my secret plan")
                 (cmacs-gowl-tools-tests--client 3 "foot" "Vault notes"))))
      ;; An ordinary hit, in the C's `find' shape (no floating, no pid).
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_find_client" "pattern" "foot")
                     (concat "{\"id\":3,\"title\":\"Vault notes\","
                             "\"app-id\":\"foot\",\"tags\":1,"
                             "\"geometry\":[0,0,800,600]}")))
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_find_client" "pattern" "nothing*")
                     "nil"))
      ;; An excluded window is not found by app-id ...
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_find_client" "pattern" "keepass*")
                     "nil"))
      ;; ... nor by its title, though gowl's own search hits it first;
      ;; the visible window further down the list is the answer.
      (should (string-prefix-p
               "{\"id\":3,"
               (cmacs-gowl-tools-tests--call
                "gowl_find_client" "pattern" "Vault*" "by" "title")))
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_find_client" "pattern" "*bank" "by" "title")
                     "nil"))
      ;; A rewritten title: the hidden words match nothing, the shown
      ;; ones do.  Otherwise the pattern is an oracle for the title.
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_find_client" "pattern" "*secret*" "by" "title")
                     "nil"))
      (should (string-match-p
               "\\`{\"id\":2,\"title\":\"\\[redacted\\]\","
               (cmacs-gowl-tools-tests--call
                "gowl_find_client" "pattern" "[redacted]" "by" "title")))
      ;; Still found by the app-id, which is shown as it is.
      (should (string-match-p
               "\\`{\"id\":2,\"title\":\"\\[redacted\\]\","
               (cmacs-gowl-tools-tests--call
                "gowl_find_client" "pattern" "librewolf"))))))

(ert-deftest cmacs-gowl-tools-test-act-on-client ()
  "Focus, close and move act on a visible window and refuse a withheld one."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--clients
           (list (cmacs-gowl-tools-tests--client 1 "keepassxc" "Passwords")
                 (cmacs-gowl-tools-tests--client 2 "foot" "sh"))))
      ;; The C printed its answer, so the quotes are part of it.
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_focus_client" "pattern" "foot")
                     "\"focused\""))
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_close_client" "pattern" "sh" "by" "title")
                     "\"closed\""))
      (should (equal (cmacs-gowl-tools-tests--call
                      "gowl_set_client_geometry" "pattern" "foot"
                      "x" 1 "y" 2 "width" 30 "height" 40)
                     "\"geometry set\""))
      (should (equal (reverse cmacs-gowl-tools-tests--calls)
                     '((focus 2) (close 2) (geometry 2 1 2 30 40))))
      (setq cmacs-gowl-tools-tests--calls nil)
      ;; The excluded window: the same answer as no window, and no act.
      (let ((absent (cmacs-gowl-tools-tests--call
                     "gowl_focus_client" "pattern" "no-such-app")))
        (should (cmacs-gowl-tools-tests--error-p
                 absent "no client matching pattern"))
        (dolist (result
                 (list (cmacs-gowl-tools-tests--call
                        "gowl_focus_client" "pattern" "keepassxc")
                       (cmacs-gowl-tools-tests--call
                        "gowl_close_client" "pattern" "Pass*" "by" "title")
                       (cmacs-gowl-tools-tests--call
                        "gowl_set_client_geometry" "pattern" "keepass*"
                        "x" 0 "y" 0 "width" 1 "height" 1)))
          (should (equal result absent))))
      (should-not cmacs-gowl-tools-tests--calls))))

(ert-deftest cmacs-gowl-tools-test-glob ()
  "The pattern language is GLib's simple one, whole-string."
  (should (cmacs-gowl-tools--glob-p "foot" "foot"))
  (should-not (cmacs-gowl-tools--glob-p "foo" "foot"))
  (should (cmacs-gowl-tools--glob-p "f*t" "foo\nt"))
  (should (cmacs-gowl-tools--glob-p "f??t" "foot"))
  (should (cmacs-gowl-tools--glob-p "*" ""))
  ;; Brackets and dots are literal, unlike a shell glob or a regexp.
  (should (cmacs-gowl-tools--glob-p "[a].b" "[a].b"))
  (should-not (cmacs-gowl-tools--glob-p "[a].b" "axb"))
  (should-not (cmacs-gowl-tools--glob-p "Foot" "foot")))


;;;; Monitors, keybinds, layout, workspaces

(ert-deftest cmacs-gowl-tools-test-list-monitors ()
  "The monitor list is the C's JSON, digit for digit."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--monitors
           (list '((name . "eDP-1") (geometry 0 0 1920 1200) (mfact . 0.55)
                   (nmaster . 1) (tags . 1) (layout-symbol . "[]=")
                   (enabled . t) (scale . 1.5) (transform . 0)
                   (current-mode 1920 1200 60000) (modes))
                 '((name . "DP-2") (geometry 1920 0 0 0) (mfact . 0.5)
                   (nmaster . 2) (tags . 0) (layout-symbol)
                   (enabled) (scale . 1.0) (transform . 3)
                   (current-mode) (modes)))))
      (should (equal
               (cmacs-gowl-tools-tests--call "gowl_list_monitors")
               (concat
                "[{\"name\":\"eDP-1\",\"mfact\":0.55,\"nmaster\":1,"
                "\"tags\":1,\"layout\":\"[]=\",\"enabled\":true,"
                "\"scale\":1.50,\"transform\":0,"
                "\"current_mode\":{\"width\":1920,\"height\":1200,"
                "\"refresh_mhz\":60000},\"geometry\":[0,0,1920,1200]},"
                "{\"name\":\"DP-2\",\"mfact\":0.50,\"nmaster\":2,"
                "\"tags\":0,\"layout\":\"\",\"enabled\":false,"
                "\"scale\":1.00,\"transform\":3,\"current_mode\":null,"
                "\"geometry\":[1920,0,0,0]}]"))))))

(ert-deftest cmacs-gowl-tools-test-set-monitor-transform ()
  "The transform is set on the named monitor; the C's three refusals."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--monitors (list '((name . "eDP-1"))))
          (ok t) (seen nil))
      (cl-letf (((symbol-function 'gowl-set-monitor-transform)
                 (lambda (transform &optional monitor &rest _)
                   (setq seen (list transform monitor))
                   ok)))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_set_monitor_transform"
                        "name" "eDP-1" "transform" 2)
                       "t"))
        (should (equal seen '(2 ((name . "eDP-1")))))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_set_monitor_transform" "name" "HDMI-9" "transform" 2)
                 "No monitor named \"HDMI-9\""))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_set_monitor_transform" "name" "eDP-1" "transform" 8)
                 "Invalid transform 8 (must be 0-7)"))
        (setq ok nil)
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_set_monitor_transform" "name" "eDP-1" "transform" 1)
                 "Failed to set transform 1 on \"eDP-1\""))))))

(ert-deftest cmacs-gowl-tools-test-list-keybinds ()
  "Keybinds: the action's nick or its number, a null description."
  (cmacs-gowl-tools-tests--with-gowl
    (cl-letf (((symbol-function 'gowl-list-keybinds)
               (lambda (&rest _)
                 '(((key . "Super+Return") (action . spawn)
                    (arg . "gst") (desc . "Terminal") (mode) (locked))
                   ((key . "Super+q") (action . 99) (arg) (desc))))))
      (should (equal
               (cmacs-gowl-tools-tests--call "gowl_list_keybinds")
               (concat
                "[{\"key\":\"Super+Return\",\"action\":\"spawn\","
                "\"arg\":\"gst\",\"desc\":\"Terminal\"},"
                "{\"key\":\"Super+q\",\"action\":99,\"arg\":\"\","
                "\"desc\":null}]"))))))

(ert-deftest cmacs-gowl-tools-test-layout-and-workspaces ()
  "Layout and workspace tools keep the C's printed answers."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((known '("tile")) (switched nil))
      (cl-letf (((symbol-function 'gowl-set-layout)
                 (lambda (layout &rest _) (and (member layout known) t)))
                ((symbol-function 'gowl-workspace-list)
                 (lambda (&rest _) '((:id 1 :name "a b" :tag-mask 1))))
                ((symbol-function 'gowl-workspace-switch)
                 (lambda (id &rest _) (setq switched id) (= id 1)))
                ((symbol-function 'gowl-spawn)
                 (lambda (command &rest _)
                   (push (list 'spawn command) cmacs-gowl-tools-tests--calls)
                   4242)))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_set_layout" "layout" "tile")
                       "\"layout set\""))
        ;; The C said "layout set" for a name gowl refused.
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_set_layout" "layout" "spiral")
                 "No layout named \"spiral\""))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_workspace_list")
                       (prin1-to-string
                        "((:id 1 :name \"a b\" :tag-mask 1))")))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_workspace_switch" "id" 1)
                       "\"switched\""))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_workspace_switch" "id" 9)
                       "\"workspace unchanged or unknown id\""))
        (should (= switched 9))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_spawn" "command" "gst -e sh")
                       "4242"))
        (should (equal (car cmacs-gowl-tools-tests--calls)
                       '(spawn "gst -e sh")))))))


;;;; Recording

(ert-deftest cmacs-gowl-tools-test-recording ()
  "The recorder DEFUNs get the limits and the token; JSON comes back raw."
  (cmacs-gowl-tools-tests--with-gowl
    (let ((seen nil))
      (cl-letf (((symbol-function 'gowl-start-recording)
                 (lambda (&rest args) (setq seen args) "{\"token\":\"t1\"}"))
                ((symbol-function 'gowl-drain-recording)
                 (lambda (token &rest _) (format "{\"drained\":\"%s\"}" token)))
                ((symbol-function 'gowl-stop-recording)
                 (lambda (&rest args) (setq seen args) "{\"events\":[]}"))
                ((symbol-function 'gowl-recording-status)
                 (lambda (&rest _) "{\"active\":false}")))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_start_recording")
                       "{\"token\":\"t1\"}"))
        (should (equal seen '(nil nil)))
        ;; Zero and negatives mean the default, as in C.
        (cmacs-gowl-tools-tests--call "gowl_start_recording"
                                      "max_seconds" 30 "max_events" 0)
        (should (equal seen '(30 nil)))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_drain_recording" "token" "t1")
                       "{\"drained\":\"t1\"}"))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_stop_recording" "token" "t1")
                       "{\"events\":[]}"))
        (should (equal seen '("t1")))
        ;; No token must never become the DEFUN's "stop whatever runs".
        (setq seen 'untouched)
        (should (string-prefix-p
                 "Error: "
                 (cmacs-gowl-tools-tests--call "gowl_stop_recording")))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_stop_recording" "token" "")
                 "Missing required argument: token"))
        (should (eq seen 'untouched))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_recording_status")
                       "{\"active\":false}"))))))


;;;; Macros, broadcast, hotkeys

(ert-deftest cmacs-gowl-tools-test-macros ()
  "Macro tools send the C's command lines, quoted as GLib quotes."
  (skip-unless (featurep 'cmacs-gowl-macro))
  (cmacs-gowl-tools-tests--with-gowl
    (let ((lines nil) (record nil) (voice nil))
      (cl-letf (((symbol-function 'cmacs-gowl-macro-command)
                 (lambda (line &rest _) (push line lines) "[]"))
                ((symbol-function 'cmacs-gowl-macro-record-command)
                 (lambda (&rest args) (setq record args) "recording"))
                ((symbol-function 'cmacs-gowl-macro-voice-text)
                 (lambda (&rest args) (setq voice args) "{}")))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_macro_list") "[]"))
        (cmacs-gowl-tools-tests--call "gowl_macro_status")
        (cmacs-gowl-tools-tests--call "gowl_macro_voice_status")
        (cmacs-gowl-tools-tests--call "gowl_macro_stop")
        (cmacs-gowl-tools-tests--call "gowl_macro_stop" "which" "it's; rm")
        (should (equal (reverse lines)
                       '("macro-list" "macro-status" "macro-voice status"
                         "macro-stop" "macro-stop 'it'\\''s; rm'")))
        ;; An agent asking always goes through the consent gate.
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_macro_record" "action" "start" "name" "demo")
                       "recording"))
        (should (equal record '("start" "demo" t)))
        (cmacs-gowl-tools-tests--call "gowl_macro_record" "action" "status")
        (should (equal record '("status" nil t)))
        (cmacs-gowl-tools-tests--call
         "gowl_macro_voice_match" "text" "pip corner" "dry_run" t)
        (should (equal voice '("pip corner" t)))
        (cmacs-gowl-tools-tests--call
         "gowl_macro_voice_match" "text" "pip corner" "dry_run" :false)
        (should (equal voice '("pip corner" nil)))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_macro_voice_match" "text" "")
                 "Missing required argument: text"))))))

(ert-deftest cmacs-gowl-tools-test-broadcast ()
  "Broadcast tools: the C's lines, its refusals, and ERROR as an error."
  (skip-unless (featurep 'cmacs-gowl-broadcast))
  (cmacs-gowl-tools-tests--with-gowl
    (let ((lines nil) (reply "ok"))
      (cl-letf (((symbol-function 'cmacs-gowl-broadcast-command)
                 (lambda (line &rest _) (push line lines) reply)))
        (cmacs-gowl-tools-tests--call "gowl_broadcast_set" "state" "panic")
        (cmacs-gowl-tools-tests--call "gowl_broadcast_set" "strict" "toggle")
        (cmacs-gowl-tools-tests--call
         "gowl_broadcast_remove" "kind" "rule" "name" "heal")
        (cmacs-gowl-tools-tests--call
         "gowl_broadcast_assign" "team" "raid" "slot" "tank")
        (cmacs-gowl-tools-tests--call
         "gowl_broadcast_assign" "team" "raid" "slot" "tank" "client_id" 0)
        (cmacs-gowl-tools-tests--call
         "gowl_broadcast_assign" "team" "raid" "slot" "tank" "client_id" 5)
        (cmacs-gowl-tools-tests--call "gowl_broadcast_focus_slot" "slot" "tank")
        (cmacs-gowl-tools-tests--call
         "gowl_broadcast_focus_slot" "team" "raid" "slot" "tank")
        (should (equal (reverse lines)
                       '("broadcast-panic" "broadcast-strict toggle"
                         "broadcast-remove-rule heal"
                         "broadcast-assign raid tank"
                         "broadcast-unassign raid tank"
                         "broadcast-assign raid tank 5"
                         "broadcast-focus-slot tank"
                         "broadcast-focus-slot raid tank")))
        (setq lines nil)
        ;; Nothing that is not one word reaches the command line.
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call "gowl_broadcast_set")
                 "Missing required argument: state (on, off, toggle or panic)"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_broadcast_set" "state" "on; broadcast-panic")
                 "Missing required argument: state (on, off, toggle or panic)"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_broadcast_remove" "kind" "team" "name" "a b")
                 "Missing required argument: name"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_broadcast_assign" "team" "a\nb" "slot" "s")
                 "Missing required argument: team and slot"))
        (should-not lines)
        ;; The module's "ERROR ..." is a failure with the prefix cut.
        (setq reply "ERROR Broadcast: no such team")
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call "gowl_broadcast_status")
                 "Broadcast: no such team"))))))

(ert-deftest cmacs-gowl-tools-test-broadcast-redaction ()
  "Windows in the status JSON are redacted; excluded ones cannot be assigned."
  (skip-unless (featurep 'cmacs-gowl-broadcast))
  (cmacs-gowl-tools-tests--with-gowl
    (let* ((plain "{\"on\":false,\"teams\":[{\"name\":\"raid\",\"slots\":[{\"name\":\"a\",\"client\":{\"id\":2,\"app_id\":\"foot\",\"title\":\"sh\",\"xwayland\":false}},{\"name\":\"b\",\"client\":null}]}],\"rules\":[]}")
           (hidden (string-replace
                    "{\"id\":2,\"app_id\":\"foot\",\"title\":\"sh\",\"xwayland\":false}"
                    "{\"id\":9,\"app_id\":\"keepassxc\",\"title\":\"Passwords\",\"xwayland\":false}"
                    plain))
           (renamed (string-replace "\"title\":\"sh\""
                                    "\"title\":\"a secret\"" plain))
           (reply plain) (lines nil)
           (cmacs-gowl-tools-tests--clients
            (list (cmacs-gowl-tools-tests--client 9 "keepassxc" "Passwords")
                  (cmacs-gowl-tools-tests--client 2 "foot" "sh"))))
      (cl-letf (((symbol-function 'cmacs-gowl-broadcast-command)
                 (lambda (line &rest _) (push line lines) reply)))
        ;; Nothing to change: the module's text, byte for byte.
        (should (eq (cmacs-gowl-tools--redact-json-windows plain) plain))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_broadcast_status")
                       plain))
        ;; An excluded window is an empty slot.
        (setq reply hidden)
        (let* ((text (cmacs-gowl-tools-tests--call "gowl_broadcast_status"))
               (json (json-parse-string text :object-type 'alist)))
          (should-not (string-match-p "keepassxc\\|Passwords" text))
          (should (eq (alist-get 'on json) :false))
          (should (eq (alist-get
                       'client
                       (aref (alist-get 'slots (aref (alist-get 'teams json) 0))
                             0))
                      :null))
          (should (equal (alist-get 'rules json) [])))
        ;; A rewritten title is rewritten there too.
        (setq reply renamed)
        (let ((text (cmacs-gowl-tools-tests--call "gowl_broadcast_status")))
          (should-not (string-match-p "secret" text))
          (should (string-match-p "\"title\":\"\\[redacted\\]\"" text))
          (should (string-match-p "\"app_id\":\"foot\"" text)))
        ;; A plain-text reply is not JSON and is left alone.
        (should (equal (cmacs-gowl-tools--redact-json-windows "broadcast on")
                       "broadcast on"))
        ;; By id: the excluded window gets the module's own "no such
        ;; window", and the module is never asked.
        (setq reply "assigned" lines nil)
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_broadcast_assign" "team" "raid" "slot" "a"
                  "client_id" 9)
                 "Broadcast: no window with id 9"))
        (should-not lines)
        ;; And as the focused window, when no id is given.
        (let ((cmacs-gowl-tools-tests--focused
               (car cmacs-gowl-tools-tests--clients)))
          (should (cmacs-gowl-tools-tests--error-p
                   (cmacs-gowl-tools-tests--call
                    "gowl_broadcast_assign" "team" "raid" "slot" "a")
                   "Broadcast: no window has focus; give an id")))
        (should-not lines)
        ;; An id gowl does not have is the module's to refuse.
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_broadcast_assign" "team" "raid" "slot" "a"
                        "client_id" 77)
                       "assigned"))
        (should (equal lines '("broadcast-assign raid a 77")))))))

(ert-deftest cmacs-gowl-tools-test-hotkeys ()
  "Hotkey tools: the C's lines and refusals; the reply keeps its \"OK\"."
  (skip-unless (featurep 'cmacs-gowl-hotkey))
  (cmacs-gowl-tools-tests--with-gowl
    (let ((lines nil) (reply "OK {\"suspended\":false}"))
      (cl-letf (((symbol-function 'cmacs-gowl-hotkey-command)
                 (lambda (line &rest _) (push line lines) reply)))
        (should (equal (cmacs-gowl-tools-tests--call "gowl_hotkey_status")
                       "OK {\"suspended\":false}"))
        (cmacs-gowl-tools-tests--call "gowl_hotkey_list")
        (cmacs-gowl-tools-tests--call "gowl_hotkey_history")
        (cmacs-gowl-tools-tests--call "gowl_hotkey_remove" "id" "h1")
        (cmacs-gowl-tools-tests--call "gowl_hotkey_fire" "id" "h1")
        (cmacs-gowl-tools-tests--call
         "gowl_hotkey_set" "id" "h1" "enabled" "on")
        (cmacs-gowl-tools-tests--call
         "gowl_hotkey_set" "id" "h1" "enabled" "off")
        (cmacs-gowl-tools-tests--call
         "gowl_hotkey_set" "id" "h1" "enabled" "toggle")
        (cmacs-gowl-tools-tests--call "gowl_hotkey_set" "suspended" "on")
        (cmacs-gowl-tools-tests--call "gowl_hotkey_set" "mode" "resize")
        (should (equal (reverse lines)
                       '("hotkey-status" "hotkey-list" "hotkey-history"
                         "hotkey-remove h1" "hotkey-fire h1"
                         "hotkey-enable h1" "hotkey-disable h1"
                         "hotkey-toggle h1" "hotkey-suspend on"
                         "hotkey-mode resize")))
        (setq lines nil)
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call "gowl_hotkey_set")
                 "Missing required argument: enabled (with id), suspended or mode"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_hotkey_set" "enabled" "on")
                 "Missing required argument: id, with enabled"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_hotkey_set" "mode" "a b")
                 "Missing required argument: mode (one word)"))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_hotkey_fire" "id" "h1\nhotkey-send x")
                 "Missing required argument: id"))
        (should-not lines)
        (setq reply "ERROR Hotkey: no hotkey h1")
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call "gowl_hotkey_fire" "id" "h1")
                 "Hotkey: no hotkey h1"))))))


;;;; The screen

(defun cmacs-gowl-tools-tests--async (name &rest args)
  "Call the tool NAME with ARGS without blocking; wait for its one answer.
Returns (STATUS TEXT)."
  (let ((answer nil)
        (deadline (+ (float-time) 20)))
    (cmacs-brigade-call-tool-async
     name
     (json-serialize (cl-loop for (key value) on args by #'cddr
                              collect (cons (intern key) value)))
     (lambda (status text) (setq answer (list status text))))
    (while (and (null answer) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    answer))

(ert-deftest cmacs-gowl-tools-test-region-guard ()
  "Screen text and pixel colours refuse a region showing a withheld window."
  (skip-unless (featurep 'cmacs-gowl-grab))
  (cmacs-gowl-tools-tests--with-gowl
    (let* ((vault (cmacs-gowl-tools-tests--client
                   1 "keepassxc" "Passwords" :geometry '(100 100 200 200)))
           (term (cmacs-gowl-tools-tests--client
                  2 "foot" "sh" :geometry '(0 0 50 50)))
           (cmacs-gowl-tools-tests--clients (list vault term))
           (cmacs-gowl-tools-tests--monitors (list '((name . "eDP-1")
                                                     (tags . 1))))
           (refusal "That part of the screen shows a window the \
redaction rules withhold")
           (captured nil))
      (cl-letf (((symbol-function 'gowl-screenshot-region)
                 (lambda (&rest box)
                   (push box captured)
                   (list 1 1 (unibyte-string 3 2 1 255)))))
        ;; Away from the excluded window: answered.
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_pick_color" "x" 10 "y" 10)
                       "#010203"))
        (should (equal captured '((10 10 1 1))))
        (setq captured nil)
        ;; On it: refused before anything is captured.
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_pick_color" "x" 150 "y" 150)
                 refusal))
        (should (equal (cmacs-gowl-tools-tests--async
                        "gowl_screen_text"
                        "x" 0 "y" 0 "width" 101 "height" 101)
                       (list 'error refusal)))
        (should-not captured)
        ;; The same window on a tag nobody is viewing is not on screen.
        (setf (plist-get vault :tags) 2)
        (setq cmacs-gowl-tools-tests--clients (list vault term))
        (should (equal (cmacs-gowl-tools-tests--call
                        "gowl_pick_color" "x" 150 "y" 150)
                       "#010203"))
        ;; Unless it is sticky, which is every tag.
        (setf (plist-get vault :sticky) t)
        (setq cmacs-gowl-tools-tests--clients (list vault term))
        (should (cmacs-gowl-tools-tests--error-p
                 (cmacs-gowl-tools-tests--call
                  "gowl_pick_color" "x" 150 "y" 150)
                 refusal))
        ;; Focused and excluded: refused wherever the region is.
        (let ((cmacs-gowl-tools-tests--focused vault))
          (should (cmacs-gowl-tools-tests--error-p
                   (cmacs-gowl-tools-tests--call
                    "gowl_pick_color" "x" 10 "y" 10)
                   refusal)))))))

(ert-deftest cmacs-gowl-tools-test-ocr-result ()
  "OCR output is trimmed, redacted, and it is the redacted text that is copied."
  (cmacs-gowl-tools-tests--with-gowl
    (should (equal (cmacs-gowl-tools--ocr-result "  pw: hunter2\f\n" nil)
                   "pw: ****"))
    (should-not cmacs-gowl-tools-tests--calls)
    (should (equal (cmacs-gowl-tools--ocr-result "pw: hunter2" t) "pw: ****"))
    (should (equal cmacs-gowl-tools-tests--calls '((clipboard "pw: ****"))))
    (setq cmacs-gowl-tools-tests--calls nil)
    ;; Nothing read: "" and the clipboard is left alone.
    (should (equal (cmacs-gowl-tools--ocr-result " \n" t) ""))
    (should-not cmacs-gowl-tools-tests--calls)))

(ert-deftest cmacs-gowl-tools-test-screen-text-is-async ()
  "The OCR program runs as a process; the handler returns before it ends."
  (skip-unless (featurep 'cmacs-gowl-grab))
  (skip-unless (executable-find "echo"))
  (cmacs-gowl-tools-tests--with-gowl
    (let ((cmacs-gowl-tools-tests--replies
           (lambda (line)
             (and (equal line "screenshot-ocr-config")
                  "OK {\"command\":\"echo\",\"language\":\"eng\"}")))
          (saved nil))
      (cl-letf (((symbol-function 'gowl-screenshot-region)
                 (lambda (&rest _) (list 1 1 (unibyte-string 0 0 0 255))))
                ((symbol-function 'gowl-screenshot-save-png)
                 (lambda (&rest args) (setq saved (car (last args))) t)))
        ;; `echo' stands in for tesseract: it prints its arguments, which
        ;; are PNG stdout -l LANGUAGE.
        (let ((returned nil) (answer nil))
          (cmacs-brigade-call-tool-async
           "gowl_screen_text"
           "{\"x\":0,\"y\":0,\"width\":4,\"height\":4,\"language\":\"hunter2\"}"
           (lambda (status text) (setq answer (list status text))))
          ;; Back already, with the capture written and no answer yet --
          ;; or the process was waited for, which is the bug.
          (setq returned (null answer))
          (should returned)
          (should (stringp saved))
          (let ((deadline (+ (float-time) 20)))
            (while (and (null answer) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (eq (car answer) 'ok))
          (should (equal (cadr answer)
                         (format "%s stdout -l ****" saved)))
          ;; The capture does not outlive the call.
          (should-not (file-exists-p saved)))
        ;; A program that fails is a failure, with the C's wording.
        (setq cmacs-gowl-tools-tests--replies
              (lambda (_line) "OK {\"command\":\"false\",\"language\":\"eng\"}"))
        (when (executable-find "false")
          (should (equal (cmacs-gowl-tools-tests--async
                          "gowl_screen_text"
                          "x" 0 "y" 0 "width" 4 "height" 4)
                         '(error "OCR failed (false exited 1)"))))
        ;; A program that is not there is reported before any waiting.
        (setq cmacs-gowl-tools-tests--replies
              (lambda (_line)
                "OK {\"command\":\"/nonexistent/cmacs-ocr\",\"language\":\"eng\"}"))
        (unless (executable-find "timeout")
          (let ((answer (cmacs-gowl-tools-tests--async
                         "gowl_screen_text"
                         "x" 0 "y" 0 "width" 4 "height" 4)))
            (should (eq (car answer) 'error))
            (should (string-match-p "is tesseract installed" (cadr answer)))))
        ;; Bad geometry never reaches the capture.
        (should (equal (cmacs-gowl-tools-tests--async
                        "gowl_screen_text"
                        "x" -1 "y" 0 "width" 4 "height" 4)
                       '(error "X and Y must be at least 0, WIDTH and \
HEIGHT positive")))))))


;;;; The clipboard history

(ert-deftest cmacs-gowl-tools-test-clipboard ()
  "Previews are redacted; a path is given only for an entry shown unchanged."
  (skip-unless (featurep 'cmacs-gowl-grab))
  (cmacs-gowl-tools-tests--with-gowl
    (let* ((dir (make-temp-file "cmacs-gowl-tools-" t))
           (clean (expand-file-name "1" dir))
           (secret (expand-file-name "2" dir))
           (deep (expand-file-name "3" dir))
           (image (expand-file-name "4" dir))
           (index (concat "4\timage/png\t9\t[image]\n"
                          "3\ttext/plain\t40\tnotes for the\n"
                          "2\ttext/plain\t7\thunter2\n"
                          "1\ttext/plain\t5\thello\tworld\n"))
           (cmacs-gowl-tools-tests--replies
            (lambda (line)
              (pcase line
                ("clipboard-list" index)
                ("clipboard-path 1" (concat clean "\n"))
                ("clipboard-path 2" (concat secret "\n"))
                ("clipboard-path 3" (concat deep "\n"))
                ("clipboard-path 4" (concat image "\n"))
                ("clipboard-path 5" "ERROR no such entry")
                ("clipboard-copy 1" "OK copied")
                (_ nil)))))
      (unwind-protect
          (progn
            (write-region "hello\tworld" nil clean nil 'silent)
            (write-region "hunter2" nil secret nil 'silent)
            ;; The preview is innocent; the rest of the entry is not.
            (write-region "notes for the bank: hunter2" nil deep nil 'silent)
            (write-region "\211PNG hunter2" nil image nil 'silent)
            (should (equal (cmacs-gowl-tools-tests--call "gowl_clipboard_list")
                           (concat "4\timage/png\t9\t[image]\n"
                                   "3\ttext/plain\t40\tnotes for the\n"
                                   "2\ttext/plain\t7\t****\n"
                                   "1\ttext/plain\t5\thello\tworld\n")))
            (should (equal (cmacs-gowl-tools-tests--call
                            "gowl_clipboard_entry" "id" 1)
                           (concat clean "\n")))
            (should (cmacs-gowl-tools-tests--error-p
                     (cmacs-gowl-tools-tests--call
                      "gowl_clipboard_entry" "id" 2)
                     "Clipboard entry 2 is withheld by the redaction rules"))
            (should (cmacs-gowl-tools-tests--error-p
                     (cmacs-gowl-tools-tests--call
                      "gowl_clipboard_entry" "id" 3)
                     "Clipboard entry 3 is withheld by the redaction rules"))
            ;; Media has no text to judge; it stands on its preview.
            (should (equal (cmacs-gowl-tools-tests--call
                            "gowl_clipboard_entry" "id" 4)
                           (concat image "\n")))
            (should (cmacs-gowl-tools-tests--error-p
                     (cmacs-gowl-tools-tests--call
                      "gowl_clipboard_entry" "id" 5)
                     "no such entry"))
            (should (cmacs-gowl-tools-tests--error-p
                     (cmacs-gowl-tools-tests--call
                      "gowl_clipboard_entry" "id" 0)
                     "Missing required argument: id (a positive entry id)"))
            (should (equal (cmacs-gowl-tools-tests--call
                            "gowl_clipboard_copy" "id" 1)
                           "copied"))
            (should (cmacs-gowl-tools-tests--error-p
                     (cmacs-gowl-tools-tests--call
                      "gowl_clipboard_copy" "id" -3)
                     "Missing required argument: id (a positive entry id)")))
        (delete-directory dir t)))))

(provide 'cmacs-gowl-tools-tests)

;;; cmacs-gowl-tools-tests.el ends here
