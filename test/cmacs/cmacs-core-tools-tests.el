;;; cmacs-core-tools-tests.el --- Tests for the editor-core tool families  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The buffer, window, edit, process, debug, project, gi and describe
;; tool families (lisp/cmacs/cmacs-<family>-tools.el) are the editor-core
;; MCP tools moved onto the capability table.  Two things are held here:
;;
;;   - Wire compatibility.  While the C handlers remain as the fallback
;;     for a build without the brigade, every migrated tool must have the
;;     name, the parameters, the parameter types and the required set its
;;     C registration declares.  The C files are parsed as text.
;;
;;   - Behaviour, with the redaction contract (cmacs-redact.el) stubbed:
;;     an excluded buffer or file is left out of listings and is answered
;;     exactly like one that does not exist.
;;
;; Nothing here needs a C primitive that a build might lack, a display,
;; or the network.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)

;; The tool bodies `require' cmacs-redact, and every test stubs its
;; functions.  Load it here, once, before any stub goes in: a load from
;; inside a stub's extent would put the real functions back, and one
;; from inside a test's private registry could register into it.  In a
;; tree that does not have the file, say it is loaded, so the stubs are
;; all there is.
(unless (require 'cmacs-redact nil t)
  (provide 'cmacs-redact))

(defvar cmacs-mcp-workspace-root)
(defvar cmacs-mcp-workspace-confine)
(defvar org-todo-keywords)
(defvar cmacs-ai-view-exclude-name-regexps)

(declare-function cmacs-edit-tools-org-content "cmacs-edit-tools")
(declare-function cmacs-project-tools--resolve "cmacs-project-tools")


;;;; What was migrated

(defconst cmacs-core-tools-tests--families
  '(("buffer"   "cmacs-mcp-tools-buffer.c"
     "list_buffers" "get_buffer_content" "set_buffer_content"
     "create_buffer" "kill_buffer" "switch_to_buffer" "save_buffer"
     "find_file")
    ("window"   "cmacs-mcp-tools-window.c"
     "list_windows" "current_view" "list_frames" "split_window"
     "delete_window" "select_window")
    ("edit"     "cmacs-mcp-tools-edit.c"
     "get_org_content" "insert_org" "edit_buffer" "replace_in_buffer"
     "search_buffer" "goto_line")
    ;; `project_grep' is registered by the edit C file and lives with
    ;; the other workspace tools in Lisp.
    ("project"  "cmacs-mcp-tools-edit.c" "project_grep")
    ("project"  "cmacs-mcp-tools-project.c"
     "project_root" "project_read_file" "project_write_file"
     "project_list_files" "project_find_files")
    ("process"  "cmacs-mcp-tools-process.c" "list_processes")
    ("debug"    "cmacs-mcp-tools-debug.c"
     "backtrace" "memory_info" "process_status" "recent_messages"
     "describe_mode" "list_hooks" "profiler_start" "profiler_stop"
     "profiler_report")
    ("gi"       "cmacs-mcp-tools-gi.c"
     "gi_list_namespaces" "gi_describe" "gi_list_functions")
    ("describe" "cmacs-mcp-tools-eval.c"
     "describe_function" "describe_variable" "apropos" "completions"))
  "Rows of (FAMILY C-FILE WIRE-NAME...): what each Lisp file took over.")

(defconst cmacs-core-tools-tests--left-in-c
  '("eval" "send_to_process" "gi_call")
  "Tools of the same C files that stay there: the privileged set.")

(defconst cmacs-core-tools-tests--writers
  '("set_buffer_content" "create_buffer" "kill_buffer" "save_buffer"
    "find_file" "insert_org" "edit_buffer" "replace_in_buffer"
    "project_write_file")
  "Tools that change text or files: :destructive and :confirm \\='ask.")

(defconst cmacs-core-tools-tests--layout
  '("split_window" "delete_window")
  "Tools that rearrange the frame: :destructive, no confirmation.")

(defun cmacs-core-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-core-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-core-tools-tests--family-files ()
  "Return the distinct family names, in table order."
  (delete-dups (mapcar #'car cmacs-core-tools-tests--families)))


;;;; Harness

(defvar cmacs-core-tools-tests--hidden nil
  "Buffer names the stubbed redaction rules exclude.")

(defun cmacs-core-tools-tests--hidden-p (buffer-or-name)
  "Stub of `cmacs-redact-buffer-p': exclusion by name."
  (let ((name (if (bufferp buffer-or-name)
                  (buffer-name buffer-or-name)
                buffer-or-name)))
    (and (member name cmacs-core-tools-tests--hidden) t)))

(defmacro cmacs-core-tools-tests--with-tools (&rest body)
  "Run BODY with the eight families freshly registered and redaction stubbed.

The registry is empty apart from them and the C mirror is stubbed out.
The stubbed rules exclude the buffers named in
`cmacs-core-tools-tests--hidden', any file whose name contains
\"secret\", and rewrite the text \"hunter2\"."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t)
         (cmacs-core-tools-tests--hidden nil)
         (root (cmacs-core-tools-tests--root)))
     (skip-unless root)
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-redact-buffer-p)
                (lambda (&rest args)
                  (cmacs-core-tools-tests--hidden-p (car args))))
               ((symbol-function 'cmacs-redact-text)
                (lambda (&rest args)
                  (replace-regexp-in-string "hunter2" "[redacted]"
                                            (car args) t t)))
               ((symbol-function 'cmacs-redact-event)
                (lambda (&rest args)
                  (let ((file (plist-get (car args) :file)))
                    (and (not (and file (string-match-p "secret" file)))
                         (car args))))))
       (let ((load-prefer-newer t))
         (load (expand-file-name "lisp/cmacs/cmacs-core-tools" root) nil t)
         (dolist (family (cmacs-core-tools-tests--family-files))
           (load (expand-file-name
                  (format "lisp/cmacs/cmacs-%s-tools" family) root)
                 nil t)))
       ,@body)))

(defun cmacs-core-tools-tests--tool (wire)
  "Return the registered tool struct with wire name WIRE, or nil."
  (cmacs-brigade--tool-by-wire wire))

(defun cmacs-core-tools-tests--call (wire &rest args)
  "Call the tool WIRE with ARGS, a plist of wire parameter name and value.
Goes through the registry's own argument marshalling, so defaults and
required parameters behave as they do for a real caller.  Errors are
signalled, not turned into text."
  (let ((tool (cmacs-core-tools-tests--tool wire))
        (alist nil))
    (should tool)
    (while args
      (push (cons (pop args) (pop args)) alist))
    (cmacs-brigade--invoke tool (nreverse alist))))

(defun cmacs-core-tools-tests--error (wire &rest args)
  "Call WIRE with ARGS expecting an error; return its message."
  (let ((err (should-error
              (apply #'cmacs-core-tools-tests--call wire args))))
    (error-message-string err)))

(defmacro cmacs-core-tools-tests--with-buffer (name text &rest body)
  "Run BODY with a buffer called NAME holding TEXT; kill it afterwards."
  (declare (indent 2) (debug t))
  `(let ((buffer (get-buffer-create ,name)))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert ,text))
             (set-buffer-modified-p nil))
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer)))))


;;;; Wire compatibility

(defun cmacs-core-tools-tests--c-tools (file)
  "Parse the MCP C FILE; return ((NAME PARAMS REQUIRED)...).
PARAMS is a list of (PARAM-NAME . JSON-TYPE) in schema order and
REQUIRED the list of required parameter names."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((out nil))
      (while (re-search-forward "mcp_tool_new (\"\\([a-z_]+\\)\"" nil t)
        (let* ((name (match-string 1))
               (end (save-excursion
                      (re-search-forward "g_object_unref (tool)" nil t)))
               (params nil)
               (required nil))
          (save-excursion
            (when (re-search-forward "\\\\\"properties\\\\\":{" end t)
              (while (re-search-forward
                      "\\\\\"\\([a-z_]+\\)\\\\\":{\\\\\"type\\\\\":\\\\\"\\([a-z]+\\)\\\\\""
                      end t)
                (push (cons (match-string 1) (match-string 2)) params))))
          (save-excursion
            (when (re-search-forward
                   "\\\\\"required\\\\\":\\[\\([^]]*\\)\\]" end t)
              (let ((text (match-string 1)) (start 0))
                (while (string-match "\\\\\"\\([a-z_]+\\)\\\\\"" text start)
                  (push (match-string 1 text) required)
                  (setq start (match-end 0))))))
          (push (list name (nreverse params) (nreverse required)) out)))
      (nreverse out))))

(ert-deftest cmacs-core-tools-test-families-match-c ()
  "Every migrated tool has its C registration's name, params and types."
  (cmacs-core-tools-tests--with-tools
    (let ((seen nil))
      (pcase-dolist (`(,_family ,c-file . ,names)
                     cmacs-core-tools-tests--families)
        (let* ((path (expand-file-name (concat "cmacs/mcp/" c-file) root))
               (c (progn (should (file-readable-p path))
                         (cmacs-core-tools-tests--c-tools path))))
          (dolist (name names)
            (let ((decl (assoc name c))
                  (tool (cmacs-core-tools-tests--tool name)))
              (ert-info ((format "tool %s (%s)" name c-file))
                ;; Still registered by the C file under this name...
                (should decl)
                ;; ...and by exactly one Lisp family.
                (should tool)
                (should (equal (cmacs-brigade-tool-wire-name tool) name))
                (should-not (member name seen))
                (push name seen)
                (let ((params (cmacs-brigade-tool-params tool)))
                  (should (equal (mapcar (lambda (p)
                                           (cons (plist-get p :name)
                                                 (plist-get p :type)))
                                         params)
                                 (nth 1 decl)))
                  (should (equal (mapcar (lambda (p) (plist-get p :name))
                                         (seq-filter
                                          (lambda (p)
                                            (plist-get p :required))
                                          params))
                                 (nth 2 decl)))))))))
      ;; Nothing was registered that the table above does not name: a
      ;; tool added to a family file has to be added here, and so be
      ;; checked against the C.
      (should (equal (sort (copy-sequence seen) #'string<)
                     (sort (mapcar (lambda (n)
                                     (cmacs-brigade-tool-wire-name
                                      (cmacs-brigade-registry-get 'tool n)))
                                   (cmacs-brigade-registry-list 'tool))
                           #'string<))))))

(ert-deftest cmacs-core-tools-test-descriptions-match-c ()
  "Each migrated tool's description is the C one, word for word.
The C text is split across string literals, so the comparison is on the
words alone."
  (cmacs-core-tools-tests--with-tools
    (pcase-dolist (`(,_family ,c-file . ,names)
                   cmacs-core-tools-tests--families)
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name (concat "cmacs/mcp/" c-file) root))
        (dolist (name names)
          (goto-char (point-min))
          (should (re-search-forward
                   (format "mcp_tool_new (\"%s\",[ \n]*" name) nil t))
          (let ((start (point))
                (words nil))
            ;; Concatenate the adjacent literals up to the closing paren.
            (re-search-forward ");" nil t)
            (let ((text (buffer-substring-no-properties start (point)))
                  (pos 0))
              (while (string-match "\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\""
                                   text pos)
                (push (match-string 1 text) words)
                (setq pos (match-end 0))))
            (let ((c-text (replace-regexp-in-string
                           "\\\\\\(.\\)" "\\1"
                           (apply #'concat (nreverse words))))
                  (lisp-text (cmacs-brigade-tool-description
                              (cmacs-core-tools-tests--tool name))))
              (ert-info ((format "tool %s" name))
                (should (equal (split-string lisp-text)
                               (split-string c-text)))))))))))

(ert-deftest cmacs-core-tools-test-privileged-stay-in-c ()
  "The privileged tools of these C files are not on the table."
  (cmacs-core-tools-tests--with-tools
    (dolist (name cmacs-core-tools-tests--left-in-c)
      (should-not (cmacs-core-tools-tests--tool name)))
    ;; And they are still where they were.
    (dolist (pair '(("eval" . "cmacs-mcp-tools-eval.c")
                    ("send_to_process" . "cmacs-mcp-tools-process.c")
                    ("gi_call" . "cmacs-mcp-tools-gi.c")))
      (should (assoc (car pair)
                     (cmacs-core-tools-tests--c-tools
                      (expand-file-name (concat "cmacs/mcp/" (cdr pair))
                                        root)))))))

(ert-deftest cmacs-core-tools-test-writers-are-declared ()
  "Writing tools are destructive and confirmed; reading tools are neither."
  (cmacs-core-tools-tests--with-tools
    (dolist (n (cmacs-brigade-registry-list 'tool))
      (let* ((tool (cmacs-brigade-registry-get 'tool n))
             (wire (cmacs-brigade-tool-wire-name tool)))
        (ert-info ((format "tool %s" wire))
          (cond
           ((member wire cmacs-core-tools-tests--writers)
            (should (cmacs-brigade-tool-destructive tool))
            (should (eq (cmacs-brigade-tool-confirm tool) 'ask))
            ;; Off the unscoped surfaces unless someone asks for them.
            (should-not (cmacs-brigade-tool-on-surface-p tool 'dbus))
            (should (cmacs-brigade-tool-on-surface-p tool 'mcp)))
           ((member wire cmacs-core-tools-tests--layout)
            (should (cmacs-brigade-tool-destructive tool))
            (should-not (cmacs-brigade-tool-confirm tool)))
           (t
            (should-not (cmacs-brigade-tool-destructive tool))
            (should-not (cmacs-brigade-tool-confirm tool))
            (should (cmacs-brigade-tool-on-surface-p tool 'dbus)))))))
    ;; The one tool that starts a subprocess does not wait for it.
    (should (cmacs-brigade-tool-async
             (cmacs-core-tools-tests--tool "project_grep")))))

(ert-deftest cmacs-core-tools-test-confirmation-policy-applies ()
  "A writing tool is declined when the policy does not pre-approve it."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-confirm" "keep"
      (let ((cmacs-brigade-auto-approve '("list_buffers")))
        ;; Batch: nobody to ask, so "ask" is "no".
        (should (string-prefix-p
                 "Error: "
                 (cmacs-brigade-call-tool
                  "set_buffer_content"
                  "{\"buffer\":\"cct-confirm\",\"content\":\"gone\"}")))
        (should (equal (with-current-buffer "cct-confirm" (buffer-string))
                       "keep")))
      (let ((cmacs-brigade-auto-approve t))
        (should (equal (cmacs-brigade-call-tool
                        "set_buffer_content"
                        "{\"buffer\":\"cct-confirm\",\"content\":\"new\"}")
                       "t"))
        (should (equal (with-current-buffer "cct-confirm" (buffer-string))
                       "new"))))))


;;;; Buffers

(ert-deftest cmacs-core-tools-test-list-buffers ()
  "One printed row per buffer, with excluded buffers left out."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-shown" "abc"
      (let ((shown buffer))
        (cmacs-core-tools-tests--with-buffer "cct-hidden" "xyz"
          (setq cmacs-core-tools-tests--hidden '("cct-hidden"))
          (let* ((printed (cmacs-core-tools-tests--call "list_buffers"))
                 (text (car (read-from-string printed))))
            ;; The C handler returned the `prin1' form of the listing.
            (should (stringp text))
            (should (string-match-p
                     "^cct-shown||unmodified|fundamental-mode|3$" text))
            (should-not (string-match-p "cct-hidden" text))
            (should (buffer-live-p shown))))))))

(ert-deftest cmacs-core-tools-test-get-buffer-content ()
  "Content is printed as the C printed it; a range needs both ends."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-get" "say \"hi\"\nbye"
      (should (equal (cmacs-core-tools-tests--call
                      "get_buffer_content" "buffer" "cct-get")
                     (prin1-to-string "say \"hi\"\nbye")))
      (should (equal (cmacs-core-tools-tests--call
                      "get_buffer_content" "buffer" "cct-get"
                      "start" 1 "end" 4)
                     "\"say\""))
      ;; One end alone is the whole buffer, as in C.
      (should (equal (cmacs-core-tools-tests--call
                      "get_buffer_content" "buffer" "cct-get" "start" 5)
                     (prin1-to-string "say \"hi\"\nbye"))))))

(ert-deftest cmacs-core-tools-test-excluded-buffer-is-no-oracle ()
  "An excluded buffer is refused with the message a missing one gets."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-secret" "the secret"
      (setq cmacs-core-tools-tests--hidden '("cct-secret"))
      (let ((missing (cmacs-core-tools-tests--error
                      "get_buffer_content" "buffer" "cct-absent")))
        (should-not (get-buffer "cct-absent"))
        (should (string-match-p "cct-absent" missing))
        (dolist (call '(("get_buffer_content")
                        ("search_buffer" "regexp" "secret")
                        ("get_org_content")
                        ("goto_line" "line" 1)
                        ("set_buffer_content" "content" "x")
                        ("edit_buffer" "old_string" "secret"
                         "new_string" "x")
                        ("replace_in_buffer" "regexp" "secret"
                         "replacement" "x")
                        ("insert_org" "text" "x")
                        ("kill_buffer")
                        ("save_buffer")
                        ("switch_to_buffer")))
          (ert-info ((format "tool %s" (car call)))
            (let ((hidden (apply #'cmacs-core-tools-tests--error
                                 (car call) "buffer" "cct-secret"
                                 (cdr call))))
              ;; Identical but for the name that was asked about.
              (should (equal (replace-regexp-in-string
                              "cct-secret" "cct-absent" hidden t t)
                             missing)))))
        ;; `create_buffer' would otherwise insert into the open buffer.
        (should (equal (replace-regexp-in-string
                        "cct-secret" "cct-absent"
                        (cmacs-core-tools-tests--error
                         "create_buffer" "name" "cct-secret"
                         "content" "x")
                        t t)
                       missing))
        ;; Nothing was touched, and it is still there.
        (should (buffer-live-p buffer))
        (should (equal (with-current-buffer buffer (buffer-string))
                       "the secret"))))))

(ert-deftest cmacs-core-tools-test-set-buffer-content ()
  "Whole-buffer and ranged replacement; a read-only buffer refuses."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-set" "0123456789"
      (should (equal (cmacs-core-tools-tests--call
                      "set_buffer_content" "buffer" "cct-set"
                      "content" "AB" "start" 1 "end" 4)
                     "t"))
      (should (equal (with-current-buffer buffer (buffer-string))
                     "AB3456789"))
      (should (equal (cmacs-core-tools-tests--call
                      "set_buffer_content" "buffer" "cct-set"
                      "content" "new")
                     "t"))
      (should (equal (with-current-buffer buffer (buffer-string)) "new"))
      (with-current-buffer buffer (setq buffer-read-only t))
      (should-error (cmacs-core-tools-tests--call
                     "set_buffer_content" "buffer" "cct-set"
                     "content" "nope")
                    :type 'buffer-read-only)
      (should-error (cmacs-core-tools-tests--call
                     "edit_buffer" "buffer" "cct-set"
                     "old_string" "new" "new_string" "x")
                    :type 'buffer-read-only)
      (should (equal (with-current-buffer buffer (buffer-string)) "new")))))

(ert-deftest cmacs-core-tools-test-create-and-kill-buffer ()
  "A buffer is created with content, reported by name, and killed."
  (cmacs-core-tools-tests--with-tools
    (unwind-protect
        (progn
          (should (equal (cmacs-core-tools-tests--call
                          "create_buffer" "name" "cct-made"
                          "content" "hello")
                         "\"cct-made\""))
          (should (equal (with-current-buffer "cct-made" (buffer-string))
                         "hello"))
          (with-current-buffer "cct-made" (set-buffer-modified-p nil))
          (should (equal (cmacs-core-tools-tests--call
                          "kill_buffer" "buffer" "cct-made")
                         "t"))
          (should-not (get-buffer "cct-made")))
      (when (get-buffer "cct-made")
        (with-current-buffer "cct-made" (set-buffer-modified-p nil))
        (kill-buffer "cct-made")))))

(ert-deftest cmacs-core-tools-test-find-file ()
  "A file is opened and its path echoed; an excluded file is not opened."
  (cmacs-core-tools-tests--with-tools
    (let* ((dir (make-temp-file "cct-find" t))
           (plain (expand-file-name "plain.txt" dir))
           (secret (expand-file-name "secret.txt" dir)))
      (unwind-protect
          (progn
            (write-region "p" nil plain nil 'quiet)
            (write-region "s" nil secret nil 'quiet)
            (save-window-excursion
              (should (equal (cmacs-core-tools-tests--call
                              "find_file" "path" plain)
                             plain))
              (should (get-file-buffer plain))
              (should (string-match-p
                       "\\`Cannot open file"
                       (cmacs-core-tools-tests--error
                        "find_file" "path" secret)))
              (should-not (get-file-buffer secret))))
        (when (get-file-buffer plain) (kill-buffer (get-file-buffer plain)))
        (delete-directory dir t)))))


;;;; Windows

(ert-deftest cmacs-core-tools-test-list-windows ()
  "A window showing an excluded buffer is not listed."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-win" "window text"
      (save-window-excursion
        (set-window-buffer (selected-window) buffer)
        (let ((text (car (read-from-string
                          (cmacs-core-tools-tests--call "list_windows")))))
          (should (string-match-p "^cct-win|[0-9]+|[0-9]+|[0-9]+|[0-9]+|[0-9]+$"
                                  text)))
        (setq cmacs-core-tools-tests--hidden '("cct-win"))
        (should-not (string-match-p
                     "cct-win"
                     (cmacs-core-tools-tests--call "list_windows")))
        ;; The frame stays listed; its row is still three fields.
        (let ((text (car (read-from-string
                          (cmacs-core-tools-tests--call "list_frames")))))
          (should (string-match-p "^|[0-9]+x[0-9]+|selected$" text)))
        ;; And cycling onto it does not report its name.
        (should (equal (cmacs-core-tools-tests--call "select_window")
                       "\"\""))))))

(ert-deftest cmacs-core-tools-test-current-view-hides-excluded ()
  "The view report is asked to leave excluded buffers out, by name."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-view.secret" "x"
      (setq cmacs-core-tools-tests--hidden '("cct-view.secret"))
      ;; Loaded first: the tool body requires it, and a load from inside
      ;; the stub's extent would put the real function back.
      (skip-unless (require 'cmacs-ai-view nil t))
      (let ((seen nil) (content nil))
        (cl-letf (((symbol-function 'cmacs-ai-view-report)
                   (lambda (&rest args)
                     (setq content (car args)
                           seen cmacs-ai-view-exclude-name-regexps)
                     "the view")))
          (should (equal (cmacs-core-tools-tests--call
                          "current_view" "include_content" t)
                         "\"the view\""))
          (should (eq content t))
          ;; Quoted and anchored: the dot is not a wildcard.
          (should (cl-some (lambda (re)
                             (and (string-match-p re "cct-view.secret")
                                  (not (string-match-p
                                        re "cct-viewXsecret"))
                                  (not (string-match-p
                                        re "a cct-view.secret"))))
                           seen)))))))


;;;; Editing

(ert-deftest cmacs-core-tools-test-edit-buffer ()
  "An exact edit must be unambiguous unless replace_all is passed."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-edit" "one two two Two"
      (should (equal (cmacs-core-tools-tests--call
                      "edit_buffer" "buffer" "cct-edit"
                      "old_string" "one" "new_string" "1")
                     "\"replaced 1 occurrence(s)\""))
      (should (string-match-p
               "matches 2 times"
               (cmacs-core-tools-tests--error
                "edit_buffer" "buffer" "cct-edit"
                "old_string" "two" "new_string" "2")))
      (should (string-match-p
               "not found"
               (cmacs-core-tools-tests--error
                "edit_buffer" "buffer" "cct-edit"
                "old_string" "three" "new_string" "3")))
      ;; Nothing changed by the two refusals; case is significant.
      (should (equal (with-current-buffer buffer (buffer-string))
                     "1 two two Two"))
      (should (equal (cmacs-core-tools-tests--call
                      "edit_buffer" "buffer" "cct-edit"
                      "old_string" "two" "new_string" "\\&"
                      "replace_all" t)
                     "\"replaced 2 occurrence(s)\""))
      ;; The replacement is literal text.
      (should (equal (with-current-buffer buffer (buffer-string))
                     "1 \\& \\& Two"))
      (should (equal (cmacs-core-tools-tests--call
                      "replace_in_buffer" "buffer" "cct-edit"
                      "regexp" "\\(T\\)wo" "replacement" "\\1-")
                     "\"replaced 1 match(es)\""))
      (should (equal (with-current-buffer buffer (buffer-string))
                     "1 \\& \\& T-")))))

(ert-deftest cmacs-core-tools-test-search-buffer ()
  "Hits come back as LINE: TEXT, at most 200 of them."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-search"
        (mapconcat (lambda (i) (format "row %d" i))
                   (number-sequence 1 250) "\n")
      (let ((lines (split-string
                    (car (read-from-string
                          (cmacs-core-tools-tests--call
                           "search_buffer" "buffer" "cct-search"
                           "regexp" "row")))
                    "\n")))
        (should (= (length lines) 200))
        (should (equal (car lines) "1: row 1"))
        (should (equal (car (last lines)) "200: row 200")))
      (should (equal (cmacs-core-tools-tests--call
                      "search_buffer" "buffer" "cct-search"
                      "regexp" "nothing-here")
                     "\"(no matches)\""))
      (should (equal (cmacs-core-tools-tests--call
                      "goto_line" "buffer" "cct-search" "line" 3)
                     "\"line 3 at point 13\"")))))

(ert-deftest cmacs-core-tools-test-org-content ()
  "An org buffer becomes the nested JSON document, verbatim."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-org"
        (concat "#+TITLE: Notes\n"
                "* TODO Top :work:\n"
                ":PROPERTIES:\n:OWNER: me\n:END:\n"
                "top body\n"
                "** Child\nchild body\n"
                "* Other\n")
      (with-current-buffer buffer
        (let ((org-todo-keywords '((sequence "TODO" "DONE"))))
          (org-mode)))
      (let* ((json (cmacs-core-tools-tests--call
                    "get_org_content" "buffer" "cct-org"))
             (doc (json-parse-string json :object-type 'alist
                                     :array-type 'list))
             (top (car (alist-get 'headlines doc))))
        (should (equal (alist-get 'buffer doc) "cct-org"))
        (should (equal (alist-get 'title doc) "Notes"))
        (should (= (length (alist-get 'headlines doc)) 2))
        (should (equal (alist-get 'title top) "Top"))
        (should (equal (alist-get 'todo top) "TODO"))
        (should (equal (alist-get 'tags top) '("work")))
        (should (equal (alist-get 'body top) "top body"))
        (should (equal (alist-get 'OWNER (alist-get 'properties top))
                       "me"))
        (should (equal (alist-get 'title (car (alist-get 'children top)))
                       "Child")))
      ;; The defaults are "include"; false switches each off, and
      ;; max_depth prunes.
      (let* ((doc (json-parse-string
                   (cmacs-core-tools-tests--call
                    "get_org_content" "buffer" "cct-org"
                    "max_depth" 1 "include_body" :false
                    "include_properties" :false)
                   :object-type 'alist :array-type 'list))
             (top (car (alist-get 'headlines doc))))
        (should-not (alist-get 'body top))
        (should-not (alist-get 'properties top))
        (should-not (alist-get 'children top)))
      (should (string-match-p
               "not an org-mode buffer"
               (progn
                 (with-current-buffer buffer (fundamental-mode))
                 (cmacs-core-tools-tests--error
                  "get_org_content" "buffer" "cct-org")))))))

(ert-deftest cmacs-core-tools-test-org-insert ()
  "Text is filed under a heading, as a child, wrapped, or at the end."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-orgins"
        "* Log\nold\n** Sub\n* Other\n"
      (with-current-buffer buffer (org-mode))
      (should (equal (cmacs-core-tools-tests--call
                      "insert_org" "buffer" "cct-orgins"
                      "text" "fresh\n\n" "heading" "Log")
                     "inserted 5 chars under Log"))
      ;; Bottom of the entry's own body: before the child heading.
      (should (equal (with-current-buffer buffer (buffer-string))
                     "* Log\nold\nfresh\n** Sub\n* Other\n"))
      (cmacs-core-tools-tests--call
       "insert_org" "buffer" "cct-orgins" "text" "(car x)"
       "heading" "Other" "wrap" "src" "lang" "elisp"
       "child" "Snippet" "todo" "TODO" "tags" "a:b")
      (should (string-suffix-p
               (concat "* Other\n** TODO Snippet :a:b:\n"
                       "#+begin_src elisp\n(car x)\n#+end_src\n")
               (with-current-buffer buffer (buffer-string))))
      (should (string-match-p
               "heading not found"
               (cmacs-core-tools-tests--error
                "insert_org" "buffer" "cct-orgins" "text" "x"
                "heading" "Nope/Deeper")))
      (cmacs-core-tools-tests--call
       "insert_org" "buffer" "cct-orgins" "text" "made"
       "heading" "Nope/Deeper" "create" t)
      (should (string-suffix-p
               "* Nope\n** Deeper\nmade\n"
               (with-current-buffer buffer (buffer-string)))))))

(ert-deftest cmacs-core-tools-test-org-json-keys-match-c ()
  "The transcribed org walker emits the keys the C template emits.
The template in cmacs-eval-dispatch.c still serves the D-Bus interface,
so the two copies must not come to disagree about the document."
  (let ((root (cmacs-core-tools-tests--root)))
    (skip-unless root)
    (let ((c (expand-file-name "cmacs/glib/cmacs-eval-dispatch.c" root))
          (el (expand-file-name "lisp/cmacs/cmacs-edit-tools.el" root))
          (keys (lambda (file)
                  (with-temp-buffer
                    (insert-file-contents file)
                    (let (out)
                      (while (re-search-forward
                              "(cons[ \n\"]+'\\([a-z]+\\)" nil t)
                        (push (match-string 1) out))
                      (sort (delete-dups out) #'string<))))))
      (skip-unless (file-readable-p c))
      (let ((c-keys (funcall keys c)))
        (should (member "headlines" c-keys))
        (should (equal (funcall keys el) c-keys))))))


;;;; Processes and debugging

(ert-deftest cmacs-core-tools-test-list-processes ()
  "A process row hides an excluded buffer and survives a pipe process."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-buffer "cct-proc" ""
      (let ((proc (make-pipe-process :name "cct-pipe" :buffer buffer
                                     :noquery t)))
        (unwind-protect
            (progn
              (should (string-match-p
                       "^cct-pipe|open|cct-proc|$"
                       (car (read-from-string
                             (cmacs-core-tools-tests--call
                              "list_processes")))))
              (setq cmacs-core-tools-tests--hidden '("cct-proc"))
              (should (string-match-p
                       "^cct-pipe|open||$"
                       (car (read-from-string
                             (cmacs-core-tools-tests--call
                              "list_processes"))))))
          (delete-process proc))))))

(ert-deftest cmacs-core-tools-test-list-processes-redacts-command ()
  "A command line goes through the free-text rules."
  (skip-unless (executable-find "sh"))
  (cmacs-core-tools-tests--with-tools
    (let ((proc (make-process :name "cct-cmd" :noquery t
                              :connection-type 'pipe
                              :command '("sh" "-c" "read line"
                                         "me:hunter2"))))
      (unwind-protect
          (let ((text (car (read-from-string
                            (cmacs-core-tools-tests--call
                             "list_processes")))))
            (should (string-match-p
                     "^cct-cmd|run||sh -c read line me:\\[redacted\\]$"
                     text))
            (should-not (string-match-p "hunter2" text)))
        (delete-process proc)))))

(ert-deftest cmacs-core-tools-test-recent-messages ()
  "The tail of *Messages*, through the free-text rules."
  (cmacs-core-tools-tests--with-tools
    (let ((message-log-max t))
      (message "cct line one")
      (message "cct password hunter2")
      (message "cct line three"))
    (let ((two (car (read-from-string
                     (cmacs-core-tools-tests--call
                      "recent_messages" "lines" 2)))))
      (should (equal two "cct password [redacted]\ncct line three\n")))
    ;; Fifty lines when not told.
    (let ((default (car (read-from-string
                         (cmacs-core-tools-tests--call
                          "recent_messages")))))
      (should (string-suffix-p "cct line three\n" default))
      (should (<= (length (split-string default "\n" t)) 50))
      (should-not (string-match-p "hunter2" default)))))

(ert-deftest cmacs-core-tools-test-debug-reports ()
  "The fixed-shape debug reports keep their shape."
  (cmacs-core-tools-tests--with-tools
    (should (string-match-p
             "\\`PID: [0-9]+\nUptime: .*\nEmacs version: .*\nSystem: .*\n\
Features: [0-9]+ loaded\\'"
             (car (read-from-string
                   (cmacs-core-tools-tests--call "process_status")))))
    (should (string-prefix-p
             "Major mode: "
             (car (read-from-string
                   (cmacs-core-tools-tests--call "describe_mode")))))
    (let ((cct-probe-hook '(ignore)))
      (ignore cct-probe-hook))
    (should (stringp (car (read-from-string
                           (cmacs-core-tools-tests--call "list_hooks")))))
    (should (stringp (car (read-from-string
                           (cmacs-core-tools-tests--call "backtrace")))))))


;;;; Describing

(ert-deftest cmacs-core-tools-test-describe ()
  "Functions and variables are described; asking does not intern."
  (cmacs-core-tools-tests--with-tools
    (let ((text (car (read-from-string
                      (cmacs-core-tools-tests--call
                       "describe_function" "symbol" "car")))))
      (should (string-prefix-p "car\n\nArgs: (list)\n\n" text)))
    (should-not (intern-soft "cct-no-such-symbol-anywhere"))
    (should (equal (cmacs-core-tools-tests--call
                    "describe_function"
                    "symbol" "cct-no-such-symbol-anywhere")
                   "\"cct-no-such-symbol-anywhere is not a known function\""))
    (should (equal (cmacs-core-tools-tests--call
                    "describe_variable"
                    "symbol" "cct-no-such-symbol-anywhere")
                   "\"cct-no-such-symbol-anywhere is void\""))
    (should-not (intern-soft "cct-no-such-symbol-anywhere"))
    (defvar cmacs-core-tools-tests--probe)
    (let ((cmacs-core-tools-tests--probe "token hunter2"))
      (let ((text (car (read-from-string
                        (cmacs-core-tools-tests--call
                         "describe_variable"
                         "symbol" "cmacs-core-tools-tests--probe")))))
        (should (string-prefix-p
                 "cmacs-core-tools-tests--probe\n\nValue: \"token [redacted]\""
                 text))))
    (should (member "car-safe"
                    (split-string
                     (car (read-from-string
                           (cmacs-core-tools-tests--call
                            "apropos" "pattern" "\\`car-")))
                     "\n")))
    (let ((names (split-string
                  (car (read-from-string
                        (cmacs-core-tools-tests--call
                         "completions" "prefix" "c")))
                  "\n")))
      (should (= (length names) 100))
      (should (cl-every (lambda (n) (string-prefix-p "c" n)) names)))))


;;;; The workspace

(defmacro cmacs-core-tools-tests--with-workspace (&rest body)
  "Run BODY in a temporary workspace bound to `dir'.
It holds plain.txt, secret.txt, sub/inner.el and sub/secret.el."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory
                (file-truename (make-temp-file "cct-ws" t))))
          (cmacs-mcp-workspace-root dir)
          (cmacs-mcp-workspace-confine t)
          (default-directory dir))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "sub" dir))
           (write-region "needle plain\n" nil
                         (expand-file-name "plain.txt" dir) nil 'quiet)
           (write-region "needle secret\n" nil
                         (expand-file-name "secret.txt" dir) nil 'quiet)
           (write-region "(needle inner)\n" nil
                         (expand-file-name "sub/inner.el" dir) nil 'quiet)
           (write-region "(needle hidden)\n" nil
                         (expand-file-name "sub/secret.el" dir) nil 'quiet)
           ,@body)
       (delete-directory dir t))))

(ert-deftest cmacs-core-tools-test-project-read ()
  "Files are read raw; escapes and excluded files are refused."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (should (equal (cmacs-core-tools-tests--call "project_root") dir))
      ;; Verbatim, not printed: this one went through eval_string in C.
      (should (equal (cmacs-core-tools-tests--call
                      "project_read_file" "path" "plain.txt")
                     "needle plain\n"))
      (should (equal (cmacs-core-tools-tests--error
                      "project_read_file" "path" "../outside")
                     "path escapes workspace root"))
      (should (equal (cmacs-core-tools-tests--error
                      "project_read_file" "path" "/etc/hostname")
                     "path escapes workspace root"))
      ;; A symlink out of the workspace is an escape too.
      (make-symbolic-link "/etc" (expand-file-name "out" dir))
      (should (equal (cmacs-core-tools-tests--error
                      "project_read_file" "path" "out/hostname")
                     "path escapes workspace root"))
      ;; Excluded reads exactly like absent.
      (should (equal (replace-regexp-in-string
                      "secret\\.txt" "absent.txt"
                      (cmacs-core-tools-tests--error
                       "project_read_file" "path" "secret.txt")
                      t t)
                     (cmacs-core-tools-tests--error
                      "project_read_file" "path" "absent.txt")))
      ;; The confinement is a setting, as it was.
      (let ((cmacs-mcp-workspace-confine nil)
            (outside (make-temp-file "cct-outside")))
        (unwind-protect
            (progn
              (write-region "out" nil outside nil 'quiet)
              (should (equal (cmacs-core-tools-tests--call
                              "project_read_file" "path" outside)
                             "out")))
          (delete-file outside))))))

(ert-deftest cmacs-core-tools-test-project-read-size-limit ()
  "A file over the limit is refused, as in C."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (write-region (make-string 2000001 ?a) nil
                    (expand-file-name "big.txt" dir) nil 'quiet)
      (should (equal (cmacs-core-tools-tests--error
                      "project_read_file" "path" "big.txt")
                     "file too large: 2000001 bytes")))))

(ert-deftest cmacs-core-tools-test-project-listings ()
  "Listings and searches leave excluded files out."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (should (equal (cmacs-core-tools-tests--call "project_list_files")
                     "plain.txt\t13\nsub/"))
      (should (equal (cmacs-core-tools-tests--call
                      "project_list_files" "directory" "sub")
                     "inner.el\t15"))
      (should (string-prefix-p
               "not a directory"
               (cmacs-core-tools-tests--error
                "project_list_files" "directory" "plain.txt")))
      (should (equal (cmacs-core-tools-tests--call
                      "project_find_files" "pattern" "\\.el\\'")
                     "sub/inner.el"))
      (should (equal (cmacs-core-tools-tests--call
                      "project_find_files" "pattern" "secret")
                     "(no matches)")))))

(ert-deftest cmacs-core-tools-test-project-write ()
  "A file is written inside the workspace and nowhere else."
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (should (equal (cmacs-core-tools-tests--call
                      "project_write_file" "path" "new/deep/file.txt"
                      "content" "héllo")
                     "\"wrote 6 bytes to new/deep/file.txt\""))
      (should (equal (cmacs-core-tools-tests--call
                      "project_read_file" "path" "new/deep/file.txt")
                     "héllo"))
      (should (equal (cmacs-core-tools-tests--error
                      "project_write_file" "path" "../escaped.txt"
                      "content" "x")
                     "path escapes workspace root"))
      (should-not (file-exists-p
                   (expand-file-name "../escaped.txt" dir)))
      ;; An excluded file is not overwritten.
      (should-error (cmacs-core-tools-tests--call
                     "project_write_file" "path" "secret.txt"
                     "content" "x"))
      (should (equal (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name "secret.txt" dir))
                       (buffer-string))
                     "needle secret\n")))))

(ert-deftest cmacs-core-tools-test-project-grep ()
  "grep runs as a subprocess; hits in excluded files are dropped."
  (skip-unless (executable-find "grep"))
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (let ((hits (split-string
                   (car (read-from-string
                         (cmacs-core-tools-tests--call
                          "project_grep" "regexp" "needle")))
                   "\n")))
        (should (equal (sort hits #'string<)
                       '("./plain.txt:1:needle plain"
                         "./sub/inner.el:1:(needle inner)"))))
      (should (equal (cmacs-core-tools-tests--call
                      "project_grep" "regexp" "needle"
                      "directory" (expand-file-name "sub" dir)
                      "file_glob" "*.el")
                     "\"./inner.el:1:(needle inner)\""))
      ;; A pattern that looks like an option is still a pattern.
      (should (equal (cmacs-core-tools-tests--call
                      "project_grep" "regexp" "--version")
                     "\"(no matches)\""))
      (should (string-prefix-p
               "not a directory"
               (cmacs-core-tools-tests--error
                "project_grep" "regexp" "x"
                "directory" (expand-file-name "nowhere" dir))))
      ;; No output buffer is left behind.
      (should-not (cl-some (lambda (b)
                             (string-prefix-p " *cmacs-project-grep*"
                                              (buffer-name b)))
                           (buffer-list))))))

(ert-deftest cmacs-core-tools-test-project-grep-does-not-block ()
  "The handler returns before grep has finished."
  (skip-unless (executable-find "grep"))
  (cmacs-core-tools-tests--with-tools
    (cmacs-core-tools-tests--with-workspace
      (let* ((tool (cmacs-core-tools-tests--tool "project_grep"))
             (answer nil))
        (funcall (cmacs-brigade-tool-handler tool)
                 (lambda (text) (setq answer text))
                 "needle" nil nil)
        ;; Started, not waited for.
        (should-not answer)
        (with-timeout (20 (ert-fail "grep never answered"))
          (while (not answer)
            (accept-process-output nil 0.05)))
        (should (string-match-p "plain.txt:1:needle plain" answer))))))


;;;; GObject Introspection

(ert-deftest cmacs-core-tools-test-gi ()
  "The GI tools call the primitives the C named, or say what is missing."
  (cmacs-core-tools-tests--with-tools
    (cl-letf (((symbol-function 'gi-list-functions)
               (lambda (&rest args)
                 (and (equal (car args) "GLib")
                      '("get_user_name" "get_home_dir")))))
      ;; Verbatim, one per line, as the C joined them.
      (should (equal (cmacs-core-tools-tests--call
                      "gi_list_functions" "namespace" "GLib")
                     "get_user_name\nget_home_dir"))
      (should (equal (cmacs-core-tools-tests--call
                      "gi_list_functions" "namespace" "Nothing")
                     "(no functions)"))
      (should-error (cmacs-core-tools-tests--call
                     "gi_list_functions" "namespace" "G Lib\")")))
    (cl-letf (((symbol-function 'gi-loaded-namespaces)
               (lambda (&rest _) '("GLib" "Gio")))
              ((symbol-function 'gi-describe)
               (lambda (&rest args) (format "%s.%s" (car args)
                                            (cadr args)))))
      (should (equal (cmacs-core-tools-tests--call "gi_list_namespaces")
                     "\"GLib\nGio\""))
      (should (equal (cmacs-core-tools-tests--call
                      "gi_describe" "namespace" "Gio" "symbol" "File")
                     "\"Gio.File\"")))
    ;; Neither function exists in the tree today; the tool says so.
    (unless (fboundp 'gi-describe)
      (should (string-match-p
               "gi-describe.* is not defined"
               (cmacs-core-tools-tests--error
                "gi_describe" "namespace" "Gio" "symbol" "File"))))))

(provide 'cmacs-core-tools-tests)

;;; cmacs-core-tools-tests.el ends here
