;;; cmacs-gsurf-lrg-cad-media-tools-tests.el --- Tests for seven migrated tool families  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The gsurf, gnuseye, lrgeditor, lrgterm, cad, imgedit and vidstudio
;; tools as registered capabilities (lisp/cmacs/cmacs-*-tools.el).
;;
;; Two kinds of test:
;;
;;   - A wire-compatibility guard per family.  The hand-written C tools
;;     in cmacs/mcp/ stay as the fallback for a build without the
;;     brigade, so both definitions exist and must not drift.  The guard
;;     parses the C file's registration table and compares every tool's
;;     name, description, parameter names, order, types and
;;     required-ness with the registry entry.
;;
;;   - Behaviour tests, with the subsystem's functions stubbed so no
;;     browser, globe, editor or slicer is needed: they check what each
;;     tool passes on, what it refuses, and -- for gsurf -- the
;;     redaction contract.
;;
;; Nothing here needs a primitive this binary may lack: every subsystem
;; function a tool calls is replaced with `cl-letf', and the `require's
;; inside the tool bodies are satisfied by a let-bound `features'.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)

(declare-function cmacs-gnuseye--make-layer "cmacs-gnuseye" (&rest slots))

(defvar cmacs-gsurf--downloads)
(defvar cmacs-gsurf-lite--buffers)
(defvar cmacs-gsurf-lite--base-url)
(defvar cmacs-gnuseye--layers)
(defvar cmacs-gnuseye--id-index)
(defvar cmacs-gnuseye-buffer)
(defvar cmacs-vidstudio-tools--export-form)


;;;; Scaffolding

(defmacro cmacs-ftools-tests--with-registry (&rest body)
  "Run BODY with an empty tool registry and the C mirror stubbed out."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       ,@body)))

(defun cmacs-ftools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-capability.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-ftools-tests--load (family)
  "Load lisp/cmacs/cmacs-FAMILY-tools.el from the source tree.
Returns nil when the file cannot be found."
  (let* ((root (cmacs-ftools-tests--root))
         (file (and root
                    (expand-file-name
                     (format "lisp/cmacs/cmacs-%s-tools.el" family) root))))
    (when (and file (file-readable-p file))
      ;; The source, not a stale .elc of it.
      (load file nil t t)
      t)))

(defmacro cmacs-ftools-tests--with-family (family provided &rest body)
  "Run BODY with FAMILY's tools registered in a scratch registry.
PROVIDED lists the features the tool bodies `require'; they are made to
look loaded so nothing real is pulled in, which means BODY must stub
every subsystem function the tools it calls reach."
  (declare (indent 2) (debug t))
  `(cmacs-ftools-tests--with-registry
     (skip-unless (cmacs-ftools-tests--load ,family))
     ;; `features' is deliberately not a special variable (fns.c makes
     ;; it non-special so code may use the name lexically), so a `let'
     ;; would bind a lexical nobody reads.  `cl-progv' binds the value
     ;; cell `require' looks at.
     (cl-progv '(features)
         (list (append ,provided (symbol-value 'features)))
       ,@body)))

(defun cmacs-ftools-tests--call (name &rest args)
  "Call the tool NAME with ARGS, a plist of wire names and values.
Returns the result string; a failure is a string starting \"Error: \"."
  (cmacs-brigade-call-tool
   name (cl-loop for (k v) on args by #'cddr collect (cons k v))))

(defun cmacs-ftools-tests--call-async (name &rest args)
  "Start the tool NAME with ARGS; return a cell that gets (STATUS TEXT)."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     name (cl-loop for (k v) on args by #'cddr collect (cons k v))
     (lambda (status text) (setcar cell (list status text))))
    cell))


;;;; Reading a C registration table
;;
;; The seven C files all register from a table: one call per tool to a
;; local helper -- `add_tool (server, "name", "description", ...)' or
;; `xx_add (server, "name", "description", ...)' -- with the input schema
;; as a JSON string literal.  The literals are split across lines and two
;; files build schemas from a macro, so the text is normalised first:
;; macros expanded, adjacent literals joined.

(defun cmacs-ftools-tests--c-tools (file)
  "Return ((NAME DESCRIPTION PARAMS FLAGS)...) from the C tool FILE.
PARAMS is a list of (NAME TYPE REQUIRED DESCRIPTION); FLAGS the list of
TRUE/FALSE arguments of the registration call, in order."
  (with-temp-buffer
    (insert-file-contents file)
    ;; 1. Expand the schema macros (BUF_PROP, PATH_SCHEMA).
    (goto-char (point-min))
    (let (macros)
      (while (re-search-forward "^#define \\([A-Z_]+\\) \\\\\n" nil t)
        (let ((name (match-string 1)) (start (match-beginning 0)) (body ""))
          (while (looking-at "\\(.*?\\)\\(\\\\\\)?\n")
            (let ((cont (match-beginning 2))
                  (text (match-string 1))
                  (after (match-end 0)))
              (setq body (concat body " " (string-trim text)))
              (goto-char (if cont after (point-max)))))
          (push (cons name (string-trim body)) macros)
          (goto-char start)
          (forward-line 1)))
      (pcase-dolist (`(,name . ,body) macros)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "^#define " name " \\\\\n\\(?:.*\\\\\n\\)*.*\n") nil t)
          (replace-match ""))
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (while (re-search-forward (concat "\\_<" name "\\_>") nil t)
            (replace-match body t t)))))
    ;; 2. Join adjacent string literals.
    (goto-char (point-min))
    (while (re-search-forward "\"[ \t\n]+\"" nil t)
      (replace-match "")
      (goto-char (match-beginning 0)))
    ;; 3. The registration calls.
    (goto-char (point-min))
    (let ((re (concat "\\_<\\(?:[a-z]+_add\\|add_tool\\) (server, "
                      "\"\\([a-z0-9_]+\\)\",[ \t\n]*"
                      "\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\""))
          hits out)
      (while (re-search-forward re nil t)
        (push (list (match-string 1) (match-string 2) (match-end 0)) hits))
      (setq hits (nreverse hits))
      (cl-loop
       for (h next) on hits
       do (let* ((name (nth 0 h))
                 (desc (replace-regexp-in-string "\\\\\\(.\\)" "\\1"
                                                 (nth 1 h)))
                 (beg (nth 2 h))
                 (end (if next (- (nth 2 next) 1) (point-max)))
                 (region (buffer-substring beg end))
                 ;; This call ends at its handler argument.
                 (call (substring region 0
                                  (string-match "handle_[a-z0-9_]+)" region)))
                 (required nil) (params nil) (flags nil))
            (when (string-match "\\\\\"required\\\\\":\\[\\([^]]*\\)\\]" call)
              (let ((r (match-string 1 call)) (i 0))
                (while (string-match "\\\\\"\\([a-z0-9_]+\\)\\\\\"" r i)
                  (push (match-string 1 r) required)
                  (setq i (match-end 0)))))
            (let ((i 0))
              (while (string-match
                      (concat "\\\\\"\\([a-z0-9_]+\\)\\\\\":{\\\\\"type\\\\\":"
                              "\\\\\"\\([a-z]+\\)\\\\\""
                              "\\(?:,\\\\\"description\\\\\":"
                              "\\\\\"\\([^\\\\]*\\)\\\\\"\\)?}")
                      call i)
                (push (list (match-string 1 call)
                            (match-string 2 call)
                            (and (member (match-string 1 call) required) t)
                            (match-string 3 call))
                      params)
                (setq i (match-end 0))))
            (let ((i 0) (case-fold-search nil))
              (while (string-match "\\_<\\(TRUE\\|FALSE\\)\\_>" call i)
                (push (equal (match-string 1 call) "TRUE") flags)
                (setq i (match-end 0))))
            (push (list name desc (nreverse params) (nreverse flags)) out)))
      (nreverse out))))

(defconst cmacs-ftools-tests--families
  ;; FAMILY  C-FILE  COUNT-IN-C  NOT-MIGRATED  READ-ONLY-FLAG-INDEX
  '(("gsurf" "cmacs-mcp-tools-gsurf.c" 29 nil 0)
    ("gnuseye" "cmacs-mcp-tools-gnuseye.c" 11 nil 0)
    ("libregnum" "cmacs-mcp-tools-libregnum.c" 13 nil 0)
    ("lrgterm" "cmacs-mcp-tools-lrgterm.c" 11 ("lrgterm_dump_screen") 0)
    ("cad" "cmacs-mcp-tools-cad.c" 18 ("cad_snapshot") 0)
    ("imgedit" "cmacs-mcp-tools-imgedit.c" 12 nil 0)
    ("vidstudio" "cmacs-mcp-tools-vidstudio.c" 11 nil 0))
  "The migrated families and what the guard expects of each.
NOT-MIGRATED are the image-returning tools that keep their C handler.")

(defun cmacs-ftools-tests--check-family (family)
  "Assert that FAMILY's registry tools are its C tools."
  (pcase-let* ((`(,_ ,c-file ,count ,skipped ,ro-index)
                (assoc family cmacs-ftools-tests--families))
               (root (cmacs-ftools-tests--root))
               (path (and root (expand-file-name
                                (concat "cmacs/mcp/" c-file) root))))
    ;; `skip-unless' only exists inside an `ert-deftest' body.
    (unless (and path (file-readable-p path))
      (ert-skip "The C tool file is not in this tree"))
    (cmacs-ftools-tests--with-registry
      (unless (cmacs-ftools-tests--load family)
        (ert-skip "The tool file is not in this tree"))
      (let* ((c (cmacs-ftools-tests--c-tools path))
             (migrated (cl-remove-if (lambda (tool)
                                       (member (car tool) skipped))
                                     c)))
        ;; The parser found the whole table: a C tool it missed would
        ;; otherwise pass by not being compared.
        (should (= (length c) count))
        (dolist (name skipped)
          (should (assoc name c))
          (should-not (cmacs-capability-describe-tool name)))
        ;; Same set of names: nothing missing, nothing invented.
        (should (equal (sort (mapcar #'car migrated) #'string<)
                       (mapcar (lambda (e) (plist-get e :name))
                               (cmacs-capability-describe))))
        (pcase-dolist (`(,name ,desc ,params ,flags) migrated)
          (let ((entry (cmacs-capability-describe-tool name)))
            (ert-info (name :prefix "tool: ")
              (should entry)
              (should (equal (plist-get entry :description) desc))
              (should (equal (mapcar (lambda (p) (plist-get p :name))
                                     (plist-get entry :params))
                             (mapcar #'car params)))
              (cl-loop
               for ours in (plist-get entry :params)
               for (pname type required pdesc) in params
               do (ert-info (pname :prefix "param: ")
                    (should (equal (plist-get ours :type) type))
                    (should (eq (and (plist-get ours :required) t) required))
                    ;; Where C documents a parameter, the words are C's.
                    (when pdesc
                      (should (equal (plist-get ours :description) pdesc)))))
              ;; What C calls read-only must not have become destructive.
              (when (nth ro-index flags)
                (should-not (plist-get entry :destructive))))))))))

(ert-deftest cmacs-ftools-test-gsurf-family-matches-c ()
  "The registry gsurf tools are the C ones."
  (cmacs-ftools-tests--check-family "gsurf"))

(ert-deftest cmacs-ftools-test-gnuseye-family-matches-c ()
  "The registry gnuseye tools are the C ones."
  (cmacs-ftools-tests--check-family "gnuseye"))

(ert-deftest cmacs-ftools-test-lrgterm-family-matches-c ()
  "The registry lrgterm tools are the C ones, bar the screen dump."
  (cmacs-ftools-tests--check-family "lrgterm"))

(ert-deftest cmacs-ftools-test-cad-family-matches-c ()
  "The registry cad tools are the C ones, bar the snapshot."
  (cmacs-ftools-tests--check-family "cad"))

(ert-deftest cmacs-ftools-test-imgedit-family-matches-c ()
  "The registry imgedit tools are the C ones."
  (cmacs-ftools-tests--check-family "imgedit"))

(ert-deftest cmacs-ftools-test-vidstudio-family-matches-c ()
  "The registry vidstudio tools are the C ones."
  (cmacs-ftools-tests--check-family "vidstudio"))

(ert-deftest cmacs-ftools-test-libregnum-family-matches-c ()
  "The registry lrgeditor tools are the C ones, old names included.
C registers a tool twice when its `legacy_too' argument is TRUE; here
that is one tool with the `lrg_editor_*' name as an alias."
  (cmacs-ftools-tests--check-family "libregnum")
  (let* ((root (cmacs-ftools-tests--root))
         (path (expand-file-name
                "cmacs/mcp/cmacs-mcp-tools-libregnum.c" root))
         (legacy 0))
    (cmacs-ftools-tests--with-registry
      (skip-unless (cmacs-ftools-tests--load "libregnum"))
      (pcase-dolist (`(,name ,_ ,_ ,flags)
                     (cmacs-ftools-tests--c-tools path))
        (let ((entry (cmacs-capability-describe-tool name))
              (old (concat "lrg_editor_"
                           (string-remove-prefix "lrgeditor_" name))))
          (ert-info (name :prefix "tool: ")
            ;; lrg_add (server, name, desc, schema, read_only, legacy_too, ..)
            (if (nth 1 flags)
                (progn
                  (setq legacy (1+ legacy))
                  (should (equal (plist-get entry :aliases) (list old)))
                  ;; The alias reaches the same tool, not a second one.
                  (should (equal (plist-get
                                  (cmacs-capability-describe-tool old) :name)
                                 name)))
              (should-not (plist-get entry :aliases))
              (should-not (cmacs-capability-describe-tool old))))))
      (should (= legacy 10))
      ;; Thirteen entries, not twenty-three.
      (should (= (length (cmacs-capability-describe)) 13)))))


;;;; gsurf: the redaction contract

(defconst cmacs-ftools-tests--refusal "Error: No gsurf buffer is available"
  "What every gsurf tool answers when it has no view it may use.")

(defmacro cmacs-ftools-tests--with-gsurf (views calls &rest body)
  "Run BODY with fake gsurf VIEWS and the redaction rules stubbed.

VIEWS is a list of (NAME URL TITLE), most recent first; each becomes a
real buffer.  A URL containing \"secret\" is excluded, \"?sid=...\" is
rewritten away, and \"hunter2\" is redacted from free text.  CALLS is a
variable that collects (HELPER . ARGS) for every `cmacs-gsurf-mcp-*'
helper and primitive the tools reach."
  (declare (indent 2) (debug t))
  `(cmacs-ftools-tests--with-family "gsurf"
       '(cmacs-gsurf cmacs-gsurf-lite cmacs-gsurf-downloads cmacs-redact)
     (let* ((specs ,views)
            (buffers (mapcar (lambda (s) (generate-new-buffer (car s)))
                             specs))
            (spec-of (lambda (b)
                       (nth (cl-position (get-buffer b) buffers) specs)))
            (record (lambda (helper result)
                      (lambda (&rest args)
                        (push (cons helper args) ,calls)
                        result))))
       (unwind-protect
           (cl-letf (((symbol-function 'cmacs-redact-url)
                      (lambda (url &rest _)
                        (cond ((not (stringp url)) nil)
                              ((string-match-p "secret" url) nil)
                              (t (replace-regexp-in-string
                                  "\\?sid=[a-z0-9]+" "" url)))))
                     ((symbol-function 'cmacs-redact-text)
                      (lambda (s &rest _)
                        (replace-regexp-in-string "hunter2" "[redacted]" s)))
                     ((symbol-function 'cmacs-redact-capture-refused-p)
                      (lambda (&rest _) nil))
                     ((symbol-function 'cmacs-gsurf--live-buffers)
                      (lambda (&rest _) buffers))
                     ((symbol-function 'cmacs-gsurf-get-uri)
                      (lambda (b &rest _) (nth 1 (funcall spec-of b))))
                     ((symbol-function 'cmacs-gsurf-get-title)
                      (lambda (b &rest _) (nth 2 (funcall spec-of b))))
                     ((symbol-function 'cmacs-gsurf-get-progress)
                      (lambda (&rest _) 1.0))
                     ((symbol-function 'cmacs-gsurf-mcp-navigate)
                      (funcall record 'navigate "https://example.org/"))
                     ((symbol-function 'cmacs-gsurf-mcp-back)
                      (funcall record 'back "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-forward)
                      (funcall record 'forward "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-reload)
                      (funcall record 'reload "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-stop)
                      (funcall record 'stop "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-eval-js)
                      (funcall record 'eval-js "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-set-zoom)
                      (funcall record 'set-zoom "1.5"))
                     ((symbol-function 'cmacs-gsurf-mcp-click)
                      (funcall record 'click "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-type-text)
                      (funcall record 'type-text "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-press-key)
                      (funcall record 'press-key "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-click-element)
                      (funcall record 'click-element "started"))
                     ((symbol-function 'cmacs-gsurf-mcp-set-cookie)
                      (funcall record 'set-cookie "ok"))
                     ((symbol-function 'cmacs-gsurf-mcp-run-action)
                      (funcall record 'run-action "performed"))
                     ((symbol-function 'cmacs-gsurf-mcp-permission-policy)
                      (funcall record 'permission-policy "ok"))
                     ((symbol-function 'cmacs-gsurf-snapshot)
                      (funcall record 'snapshot t))
                     ((symbol-function 'cmacs-gsurf-print-to-pdf)
                      (funcall record 'print-to-pdf t))
                     ((symbol-function 'cmacs-gsurf-download-cancel)
                      (funcall record 'download-cancel t)))
             ,@body)
         (mapc #'kill-buffer buffers)))))

(defconst cmacs-ftools-tests--views
  '(("*gsurf: bank*" "https://secret.example/account" "My account")
    ("*gsurf: docs*" "https://docs.example/page?sid=abc123"
     "Docs for hunter2")
    ("*gsurf: news*" "https://news.example/" "News"))
  "Three views, most recent first; the first is one the rules exclude.")

(ert-deftest cmacs-ftools-test-gsurf-list-omits-excluded ()
  "An excluded view is not listed; what is listed is redacted."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (let ((rows (json-parse-string (cmacs-ftools-tests--call "gsurf_list")
                                     :object-type 'alist :array-type 'list)))
        (should (equal (mapcar (lambda (r) (alist-get 'buffer r)) rows)
                       '("*gsurf: docs*" "*gsurf: news*")))
        ;; The URL as the rules rewrote it, the title as free text.
        (should (equal (alist-get 'uri (car rows))
                       "https://docs.example/page"))
        (should (equal (alist-get 'title (car rows)) "Docs for [redacted]"))
        ;; Same keys the C helper's JSON had.
        (should (equal (mapcar #'car (car rows)) '(buffer uri title)))))))

(ert-deftest cmacs-ftools-test-gsurf-list-empty-is-an-array ()
  "No visible views is \"[]\", never \"null\"."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf
        '(("*gsurf: bank*" "https://secret.example/" "x")) calls
      (should (equal (cmacs-ftools-tests--call "gsurf_list") "[]")))))

(ert-deftest cmacs-ftools-test-gsurf-default-skips-excluded ()
  "The \"most recent\" view a tool defaults to is the most recent visible."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (should (equal (cmacs-ftools-tests--call "gsurf_get_uri")
                     "https://docs.example/page"))
      (should (equal (cmacs-ftools-tests--call "gsurf_get_title")
                     "Docs for [redacted]"))
      (let ((cur (json-parse-string (cmacs-ftools-tests--call "gsurf_current")
                                    :object-type 'alist)))
        (should (equal (alist-get 'buffer cur) "*gsurf: docs*"))
        (should (equal (alist-get 'uri cur) "https://docs.example/page"))
        (should (equal (mapcar #'car cur) '(buffer uri title progress))))
      ;; An acting tool with no name acts on that same view.
      (should (equal (cmacs-ftools-tests--call "gsurf_reload") "ok"))
      (should (equal calls '((reload "*gsurf: docs*")))))))

(ert-deftest cmacs-ftools-test-gsurf-refusal-is-no-oracle ()
  "Excluded, unknown and absent all get the same fixed words."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      ;; A view the rules exclude ...
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_get_uri" "buffer" "*gsurf: bank*")
                     cmacs-ftools-tests--refusal))
      ;; ... a name that matches nothing ...
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_get_uri" "buffer" "*gsurf: nope*")
                     cmacs-ftools-tests--refusal))
      ;; ... and a live buffer that is not a gsurf view at all.
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_get_uri" "buffer" "*scratch*")
                     cmacs-ftools-tests--refusal))
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_get_title" "buffer" "*gsurf: bank*")
                     cmacs-ftools-tests--refusal)))
    ;; No view open at all.
    (cmacs-ftools-tests--with-gsurf nil calls
      (should (equal (cmacs-ftools-tests--call "gsurf_get_uri")
                     cmacs-ftools-tests--refusal))
      (should (equal (cmacs-ftools-tests--call "gsurf_current")
                     cmacs-ftools-tests--refusal)))))

(ert-deftest cmacs-ftools-test-gsurf-acting-tools-refuse-excluded ()
  "Acting on an excluded view is refused, and nothing reaches the page."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (pcase-dolist
          (`(,tool . ,args)
           '(("gsurf_click" "x" 10 "y" 20)
             ("gsurf_type_text" "text" "hello")
             ("gsurf_press_key" "key" "Enter")
             ("gsurf_eval_js" "script" "document.title")
             ("gsurf_click_element" "selector" "#go")
             ("gsurf_set_cookie" "name" "a" "value" "b" "domain" "x.example")
             ("gsurf_set_zoom" "level" 1.5)
             ("gsurf_run_action" "action" "dark-mode-toggle")
             ("gsurf_back") ("gsurf_forward") ("gsurf_reload")
             ("gsurf_stop")))
        (ert-info (tool :prefix "tool: ")
          (should (equal (apply #'cmacs-ftools-tests--call tool
                                (append args '("buffer" "*gsurf: bank*")))
                         cmacs-ftools-tests--refusal))))
      (should-not calls)
      ;; The two capturing tools are asynchronous; same answer.
      (dolist (tool '("gsurf_snapshot" "gsurf_print_pdf"))
        (should (equal (car (cmacs-ftools-tests--call-async
                             tool "file" "/tmp/x" "buffer" "*gsurf: bank*"))
                       '(error "No gsurf buffer is available"))))
      (should-not calls))))

(ert-deftest cmacs-ftools-test-gsurf-acting-tools-pass-through ()
  "On a visible view the tools hand the C helpers what C handed them."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_click" "x" 10 "y" 20.5 "buffer" "*gsurf: news*")
                     "ok"))
      ;; Button defaults to 1, and anything out of range is 1 too.
      (should (equal (pop calls) '(click 10 20.5 1 "*gsurf: news*")))
      (cmacs-ftools-tests--call "gsurf_click" "x" 1 "y" 2 "button" 9)
      (should (equal (pop calls) '(click 1 2 1 "*gsurf: docs*")))
      (cmacs-ftools-tests--call "gsurf_press_key" "key" "a"
                                "modifiers" "ctrl+shift")
      (should (equal (pop calls)
                     '(press-key "a" "ctrl+shift" "*gsurf: docs*")))
      (cmacs-ftools-tests--call "gsurf_press_key" "key" "Tab" "modifiers" "")
      (should (equal (pop calls) '(press-key "Tab" nil "*gsurf: docs*")))
      (cmacs-ftools-tests--call "gsurf_set_cookie" "name" "n" "value" "v"
                                "domain" ".example.com" "secure" t)
      (should (equal (pop calls)
                     '(set-cookie "n" "v" ".example.com" nil t nil 0
                                  "*gsurf: docs*")))
      ;; A missing required string is said so, before anything runs.
      (should (string-prefix-p
               "Error: "
               (cmacs-ftools-tests--call "gsurf_press_key" "key" "")))
      (should-not calls))))

(ert-deftest cmacs-ftools-test-gsurf-navigate-away-is-allowed ()
  "`gsurf_navigate' may send an excluded view somewhere else."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_navigate" "url" "example.org"
                      "buffer" "*gsurf: bank*")
                     "https://example.org/"))
      (should (equal calls '((navigate "example.org" "*gsurf: bank*"))))
      ;; But a name that is not a view is still refused.
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_navigate" "url" "example.org"
                      "buffer" "*scratch*")
                     cmacs-ftools-tests--refusal)))))

(ert-deftest cmacs-ftools-test-gsurf-capture-is-async-and-guarded ()
  "Snapshot and print answer from the primitive's callback."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (let* ((cell (cmacs-ftools-tests--call-async
                    "gsurf_snapshot" "file" "/tmp/shot.png" "full_page" t))
             (call (car calls)))
        ;; Started, not answered: nothing waits for the render.
        (should-not (car cell))
        (should (eq (nth 0 call) 'snapshot))
        (should (equal (buffer-name (nth 1 call)) "*gsurf: docs*"))
        (should (equal (nth 2 call) "/tmp/shot.png"))
        (should (eq (nth 4 call) t))
        ;; The primitive reports the file written.
        (funcall (nth 3 call) "/tmp/shot.png")
        (should (equal (car cell) '(ok "/tmp/shot.png"))))
      ;; A capture that failed is a failure.
      (setq calls nil)
      (let ((cell (cmacs-ftools-tests--call-async
                   "gsurf_print_pdf" "file" "/tmp/page.pdf")))
        (funcall (nth 3 (car calls)) nil)
        (should (eq (car (car cell)) 'error)))
      ;; The capture rule (URL and title) refuses in the same words.
      (setq calls nil)
      (cl-letf (((symbol-function 'cmacs-redact-capture-refused-p)
                 (lambda (what target)
                   (and (eq what 'gsurf) (equal target "*gsurf: docs*")))))
        (should (equal (car (cmacs-ftools-tests--call-async
                             "gsurf_snapshot" "file" "/tmp/shot.png"))
                       '(error "No gsurf buffer is available"))))
      (should-not calls))))

(ert-deftest cmacs-ftools-test-gsurf-extract-text ()
  "Page text is redacted; an excluded lite buffer is refused."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf nil calls
      (let* ((open (generate-new-buffer "*gsurf-lite: open*"))
             (hidden (generate-new-buffer "*gsurf-lite: hidden*"))
             (cmacs-gsurf-lite--buffers (list hidden open)))
        (unwind-protect
            (cl-letf (((symbol-function 'cmacs-gsurf-lite-mcp-extract-text)
                       (lambda (name &rest _)
                         (push (list 'extract name) calls)
                         "the password is hunter2")))
              (with-current-buffer open
                (setq-local cmacs-gsurf-lite--base-url
                            "https://docs.example/"))
              (with-current-buffer hidden
                (setq-local cmacs-gsurf-lite--base-url
                            "https://secret.example/"))
              ;; The newest VISIBLE lite buffer, its text redacted.
              (should (equal (cmacs-ftools-tests--call "gsurf_extract_text")
                             "the password is [redacted]"))
              (should (equal calls '((extract "*gsurf-lite: open*"))))
              (setq calls nil)
              (should (equal (cmacs-ftools-tests--call
                              "gsurf_extract_text"
                              "buffer" "*gsurf-lite: hidden*")
                             cmacs-ftools-tests--refusal))
              (should-not calls))
          (kill-buffer open)
          (kill-buffer hidden))))))

(ert-deftest cmacs-ftools-test-gsurf-downloads ()
  "A download from an excluded page is neither listed nor cancellable."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf nil calls
      (let ((cmacs-gsurf--downloads
             '((2 :uri "https://secret.example/statement.pdf"
                  :dest "/home/u/statement.pdf" :state finished)
               (1 :uri "https://files.example/a.iso?sid=zz9"
                  :dest "/home/u/hunter2.iso" :received 5 :total 10
                  :state started))))
        (let ((rows (json-parse-string
                     (cmacs-ftools-tests--call "gsurf_download_list")
                     :object-type 'alist :array-type 'list)))
          (should (= (length rows) 1))
          (should (equal (car rows)
                         '((id . 1) (uri . "https://files.example/a.iso")
                           (dest . "/home/u/[redacted].iso")
                           (received . 5) (total . 10)
                           (state . "started")))))
        (should (equal (cmacs-ftools-tests--call "gsurf_download_cancel"
                                                 "id" 1)
                       "ok"))
        (should (equal calls '((download-cancel 1))))
        (setq calls nil)
        ;; Excluded and unknown are told apart by nothing.
        (should (equal (cmacs-ftools-tests--call "gsurf_download_cancel"
                                                 "id" 2)
                       "Error: No such download"))
        (should (equal (cmacs-ftools-tests--call "gsurf_download_cancel"
                                                 "id" 77)
                       "Error: No such download"))
        (should-not calls)))))

(ert-deftest cmacs-ftools-test-gsurf-powerful-tools-are-declared ()
  "The tools that drive a logged-in session go through the shared policy."
  (let ((calls nil))
    (cmacs-ftools-tests--with-gsurf cmacs-ftools-tests--views calls
      (dolist (name '("gsurf_eval_js" "gsurf_type_text" "gsurf_press_key"
                      "gsurf_set_cookie" "gsurf_permission_policy"
                      "gsurf_snapshot" "gsurf_print_pdf"))
        (let ((entry (cmacs-capability-describe-tool name)))
          (ert-info (name :prefix "tool: ")
            (should (plist-get entry :destructive))
            (should (eq (plist-get entry :confirm) 'ask))
            ;; Not one `gdbus call' away: the bus cannot be scoped.
            (should-not (memq 'dbus (plist-get entry :surfaces))))))
      ;; The readers stay everywhere.
      (should (memq 'dbus (plist-get (cmacs-capability-describe-tool
                                      "gsurf_list")
                                     :surfaces)))
      ;; With nobody to ask and no standing approval, the call is
      ;; declined before the page is touched.
      (let ((cmacs-brigade-auto-approve nil))
        (should (string-match-p
                 "\\`Error: .*gsurf_eval_js needs approval"
                 (cmacs-ftools-tests--call "gsurf_eval_js" "script" "1")))
        (should-not calls))
      ;; The verdict the helper interns is one of the two it documents.
      (should (string-prefix-p
               "Error: verdict must be"
               (cmacs-ftools-tests--call
                "gsurf_permission_policy" "origin" "https://x.example"
                "type" "geolocation" "verdict" "sudo")))
      (should-not calls)
      (should (equal (cmacs-ftools-tests--call
                      "gsurf_permission_policy" "origin" "https://x.example"
                      "type" "geolocation" "verdict" "deny")
                     "ok")))))


;;;; gnuseye

(ert-deftest cmacs-ftools-test-gnuseye-toggle-layer ()
  "A layer is flipped; an unknown one is an error and interns nothing."
  (cmacs-ftools-tests--with-family "gnuseye" '(cmacs-gnuseye)
    ;; The layer is a `cl-defstruct'.  When the globe's library happens
    ;; to be loaded, the tool file's accessor calls were inlined on load
    ;; and no stub of the accessor is consulted, so the layer has to be
    ;; a real one whose slot the stubs set; when it is not loaded, any
    ;; object does and the stubbed accessor answers.  Both are covered.
    (let* ((cmacs-gnuseye--layers (make-hash-table :test 'eq))
           (real (fboundp 'cmacs-gnuseye--make-layer))
           (layer (if real
                      (funcall 'cmacs-gnuseye--make-layer :name 'quakes)
                    'layer))
           (state nil)
           (set (lambda (value)
                  (setq state value)
                  ;; By offset, through `funcall': naming the struct
                  ;; in a form the macroexpander sees would be an error
                  ;; in the session where it is not defined.
                  (when real
                    (aset layer
                          (funcall 'cl-struct-slot-offset
                                   'cmacs-gnuseye-layer 'enabled)
                          value)))))
      (puthash 'quakes layer cmacs-gnuseye--layers)
      (cl-letf (((symbol-function 'cmacs-gnuseye--load-layers)
                 (lambda (&rest _) nil))
                ((symbol-function 'cmacs-gnuseye-layer-enabled)
                 (lambda (&rest _) state))
                ((symbol-function 'cmacs-gnuseye--enable-layer)
                 (lambda (&rest _) (funcall set t)))
                ((symbol-function 'cmacs-gnuseye--disable-layer)
                 (lambda (&rest _) (funcall set nil))))
        (should (equal (cmacs-ftools-tests--call "gnuseye_toggle_layer"
                                                 "name" "quakes")
                       "quakes on"))
        (should (equal (cmacs-ftools-tests--call "gnuseye_toggle_layer"
                                                 "name" "quakes")
                       "quakes off"))
        (should (equal (cmacs-ftools-tests--call
                        "gnuseye_toggle_layer"
                        "name" "cmacs-ftools-no-such-layer-zz")
                       "Error: Unknown layer: cmacs-ftools-no-such-layer-zz"))
        (should-not (intern-soft "cmacs-ftools-no-such-layer-zz"))))))

(ert-deftest cmacs-ftools-test-gnuseye-query-and-fly ()
  "The entity query filters and returns JSON; flying needs a globe."
  (cmacs-ftools-tests--with-family "gnuseye" '(cmacs-gnuseye json)
    (let ((cmacs-gnuseye--id-index (make-hash-table :test 'equal))
          (cmacs-gnuseye-buffer nil)
          (flown nil))
      (puthash "a1" '(:kind aircraft :label "A1" :lat 10.0 :lon 20.0)
               cmacs-gnuseye--id-index)
      (puthash "v1" '(:kind vessel :label "V1" :lat -40.0 :lon 100.0)
               cmacs-gnuseye--id-index)
      ;; No rows is an empty array, not "null".
      (should (equal (cmacs-ftools-tests--call "gnuseye_query_entities"
                                               "kind" "cmacs-ftools-no-kind")
                     "[]"))
      (let ((rows (json-parse-string
                   (cmacs-ftools-tests--call "gnuseye_query_entities"
                                             "kind" "aircraft")
                   :object-type 'alist :array-type 'list)))
        (should (= (length rows) 1))
        (should (equal (alist-get 'id (car rows)) "a1"))
        (should (equal (mapcar #'car (car rows)) '(id kind label lat lon))))
      ;; The bounding box alone.
      (let ((rows (json-parse-string
                   (cmacs-ftools-tests--call "gnuseye_query_entities"
                                             "north" 0)
                   :object-type 'alist :array-type 'list)))
        (should (equal (mapcar (lambda (r) (alist-get 'id r)) rows) '("v1"))))
      (should (equal (cmacs-ftools-tests--call "gnuseye_brief")
                     "2 entities indexed; by kind: aircraft:1, vessel:1"))
      (cl-letf (((symbol-function 'cmacs-gnuseye-fly-to)
                 (lambda (&rest args) (setq flown args))))
        (should (equal (cmacs-ftools-tests--call "gnuseye_fly_to"
                                                 "lat" 51.5 "lon" -0.12)
                       "Error: No globe open"))
        (should-not flown)
        (with-temp-buffer
          (setq cmacs-gnuseye-buffer (current-buffer))
          (should (equal (cmacs-ftools-tests--call "gnuseye_fly_to"
                                                   "lat" 51.5 "lon" -0.12)
                         "flew to 51.5,-0.12"))
          ;; RANGE defaults to what the C handler used.
          (should (equal flown
                         (list (current-buffer) 51.5 -0.12 14.0 t))))))))


;;;; lrgeditor

(ert-deftest cmacs-ftools-test-lrgeditor-needs-an-editor ()
  "With no editor open every node tool fails, as a failure."
  (cmacs-ftools-tests--with-family "libregnum" '(cmacs-lrgeditor)
    (cl-letf (((symbol-function 'cmacs-libregnum-editor-active-p)
               (lambda (&rest _) nil)))
      (dolist (call '(("lrgeditor_object_tree")
                      ("lrgeditor_select" "id" 1)
                      ("lrg_editor_select" "id" 1)
                      ("lrgeditor_play")))
        (should (equal (apply #'cmacs-ftools-tests--call call)
                       "Error: No libregnum editor open \
(M-x cmacs-lrgeditor)"))))))

(ert-deftest cmacs-ftools-test-lrgeditor-shell-and-panel ()
  "The shell's own actions are preferred when the shell is the editor."
  (cmacs-ftools-tests--with-family "libregnum" '(cmacs-lrgeditor)
    (let ((shell (get-buffer-create "*lrgeditor*"))
          (attached nil)
          (calls nil))
      (unwind-protect
          (cl-letf (((symbol-function 'cmacs-lrgeditor-attached-p)
                     (lambda (&rest _) attached))
                    ((symbol-function 'cmacs-libregnum-editor-active-p)
                     (lambda (&rest _) t))
                    ((symbol-function 'cmacs-lrgeditor-activate-action)
                     (lambda (_buf id &rest _)
                       (push (list 'action id) calls)
                       (not (equal id "no.such"))))
                    ((symbol-function 'cmacs-libregnum-editor-play)
                     (lambda (&rest _) (push '(play) calls) t))
                    ((symbol-function 'cmacs-libregnum-editor-select)
                     (lambda (_buf id &rest _) (push (list 'select id) calls)))
                    ((symbol-function 'cmacs-libregnum-editor-add-primitive)
                     (lambda (_buf prim name &rest _)
                       (push (list 'prim prim name) calls) 7)))
            ;; The older panel editor: there is no shell to ask.
            (let ((panel (get-buffer-create "*cmacs-libregnum editor*")))
              (unwind-protect
                  (progn
                    (should (equal (cmacs-ftools-tests--call "lrgeditor_play")
                                   "playing"))
                    (should (equal calls '((play))))
                    (should (string-prefix-p
                             "Error: The lrgeditor shell is not open"
                             (cmacs-ftools-tests--call "lrgeditor_action"
                                                       "id" "edit.undo"))))
                (kill-buffer panel)))
            ;; The embedded shell.
            (setq attached t calls nil)
            (should (equal (cmacs-ftools-tests--call "lrgeditor_play")
                           "playing"))
            (should (equal calls '((action "play.start"))))
            (should (equal (cmacs-ftools-tests--call "lrgeditor_action"
                                                     "id" "no.such")
                           "Error: Unknown or disabled action: no.such"))
            ;; The old name is the same tool.
            (setq calls nil)
            (should (equal (cmacs-ftools-tests--call "lrg_editor_select"
                                                     "id" 4)
                           "selected"))
            (should (equal calls '((select 4))))
            ;; NAME defaults as it did in C.
            (should (equal (cmacs-ftools-tests--call
                            "lrgeditor_add_primitive" "primitive" 1)
                           "added node 7"))
            (should (equal (car calls) '(prim 1 "Object"))))
        (kill-buffer shell)))))


;;;; lrgterm

(ert-deftest cmacs-ftools-test-lrgterm-frames ()
  "No lrg frame is an error; a flat frame refuses the 3D tools."
  (cmacs-ftools-tests--with-family "lrgterm" nil
    ;; A batch Emacs has no output_lrg frame.
    (should (equal (cmacs-ftools-tests--call "lrgterm_3d_state")
                   "Error: No lrg frame (start Emacs with --lrg)"))
    (let ((set nil) (three-d t))
      (cl-letf (((symbol-function 'cmacs-lrgterm-tools--frame)
                 (lambda () (selected-frame)))
                ((symbol-function 'cmacs-lrg-3d-arrangement)
                 (lambda (&rest _) "per-window"))
                ((symbol-function 'cmacs-lrg-3d-set-arrangement)
                 (lambda (name &rest _) (setq set name) three-d))
                ((symbol-function 'cmacs-lrg-3d-environment)
                 (lambda (&rest _) "cockpit"))
                ((symbol-function 'cmacs-lrg-3d-set-environment)
                 (lambda (name &rest _) (setq set name) three-d)))
        (should (equal (cmacs-ftools-tests--call
                        "lrgterm_3d_cycle_arrangement")
                       "arrangement -> free"))
        (should (equal set "free"))
        ;; The cycle wraps.
        (should (equal (cmacs-ftools-tests--call
                        "lrgterm_3d_cycle_environment")
                       "environment -> void"))
        (setq three-d nil)
        (should (equal (cmacs-ftools-tests--call
                        "lrgterm_3d_cycle_arrangement")
                       "Error: Not a 3D lrg frame"))))))


;;;; cad

(ert-deftest cmacs-ftools-test-cad-errors-and-checks ()
  "A helper's \"error:\" string is a failure; names are checked first."
  (cmacs-ftools-tests--with-family "cad" '(cmacs-cad-mcp cmacs-cad-slicer)
    (let ((calls nil))
      (cl-letf (((symbol-function 'cmacs-cad-mcp-eval)
                 (lambda (&rest _) "error: Wrong type argument: numberp"))
                ((symbol-function 'cmacs-cad-mcp-params)
                 (lambda (&rest _) "width = 10"))
                ((symbol-function 'cmacs-cad-mcp-export)
                 (lambda (&rest args) (push (cons 'export args) calls)
                   "exported x (stl)"))
                ((symbol-function 'cmacs-cad-mcp-section)
                 (lambda (&rest args) (push (cons 'section args) calls)
                   "section"))
                ((symbol-function 'cmacs-cad-mcp-print)
                 (lambda (&rest args) (push (cons 'print args) calls)
                   "uploaded to p (print NOT started)")))
        (should (equal (cmacs-ftools-tests--call "cad_eval" "path" "/p.cad")
                       "Error: Wrong type argument: numberp"))
        (should (equal (cmacs-ftools-tests--call "cad_params"
                                                 "path" "/p.cad")
                       "width = 10"))
        ;; FORMAT defaults to stl, and is never interned unchecked.
        (cmacs-ftools-tests--call "cad_export" "path" "/p.cad" "out" "/o")
        (should (equal (pop calls) '(export "/p.cad" "/o" "stl")))
        (should (string-prefix-p
                 "Error: format must be"
                 (cmacs-ftools-tests--call "cad_export" "path" "/p.cad"
                                           "out" "/o" "format" "exe")))
        (should-not calls)
        ;; AXIS and OFFSET default as they did in C.
        (cmacs-ftools-tests--call "cad_section" "path" "/p.cad")
        (should (equal (pop calls) '(section "/p.cad" "z" 0.0)))
        (should (string-prefix-p
                 "Error: axis must be"
                 (cmacs-ftools-tests--call "cad_section" "path" "/p.cad"
                                           "axis" "w")))
        ;; The print gate's two flags reach the helper as given.
        (cmacs-ftools-tests--call "cad_print" "printer" "p" "gcode" "/g"
                                  "start" t)
        (should (equal (pop calls) '(print "p" "/g" t nil)))
        (should (plist-get (cmacs-capability-describe-tool "cad_print")
                           :destructive))))))

(ert-deftest cmacs-ftools-test-cad-slice-is-async ()
  "`cad_slice' answers from the slicer's callback, never by waiting."
  (cmacs-ftools-tests--with-family "cad" '(cmacs-cad-mcp cmacs-cad-slicer)
    (let ((callback nil) (exported nil))
      (cl-letf (((symbol-function 'cmacs-cad-export)
                 (lambda (&rest args) (setq exported args)))
                ((symbol-function 'cmacs-cad-slice)
                 (lambda (_stl _out _extra cb &rest _) (setq callback cb))))
        (should (plist-get (cmacs-capability-describe-tool "cad_slice")
                           :async))
        (let ((cell (cmacs-ftools-tests--call-async "cad_slice"
                                                    "path" "/p.cad")))
          ;; Started and returned: the slicer has not finished.
          (should-not (car cell))
          (should (equal (car exported) "/p.cad"))
          (should (eq (nth 2 exported) 'stl))
          (funcall callback 'done "/stage/p.gcode")
          (should (equal (car cell) '(ok "sliced: /stage/p.gcode")))
          ;; A second report cannot answer twice.
          (funcall callback 'error "late")
          (should (equal (car cell) '(ok "sliced: /stage/p.gcode"))))
        (let ((cell (cmacs-ftools-tests--call-async "cad_slice"
                                                    "path" "/p.cad")))
          (funcall callback 'error "exit 1")
          (should (equal (car cell) '(error "slice failed (exit 1)"))))
        ;; The tool's own TIMEOUT ends a slicer that never reports.
        (let ((cell (cmacs-ftools-tests--call-async
                     "cad_slice" "path" "/p.cad" "timeout" 0.05)))
          (should-not (car cell))
          (sleep-for 0.2)
          (should (equal (car cell) '(error "slice timed out"))))))))


;;;; imgedit

(ert-deftest cmacs-ftools-test-imgedit-draw-and-adjust ()
  "Shapes and adjustments reach the primitive the C handler chose."
  (cmacs-ftools-tests--with-family "imgedit" nil
    (let ((calls nil))
      (cl-letf (((symbol-function 'cmacs-imgedit-push-undo)
                 (lambda (h &rest _) (push (list 'undo h) calls)))
                ((symbol-function 'cmacs-imgedit-draw-rect)
                 (lambda (&rest args) (push (cons 'rect args) calls)))
                ((symbol-function 'cmacs-imgedit-draw-circle)
                 (lambda (&rest args) (push (cons 'circle args) calls)))
                ((symbol-function 'cmacs-imgedit-brightness)
                 (lambda (&rest args) (push (cons 'brightness args) calls)))
                ((symbol-function 'cmacs-imgedit-contrast)
                 (lambda (&rest args) (push (cons 'contrast args) calls)))
                ((symbol-function 'cmacs-imgedit-set-color)
                 (lambda (&rest args) (push (cons 'color args) calls)))
                ((symbol-function 'cmacs-imgedit-undo)
                 (lambda (&rest _) nil)))
        ;; Two corners in, a corner and a size out; one undo step first.
        (should (equal (cmacs-ftools-tests--call
                        "imgedit_draw_shape" "handle" 3 "shape" "rect"
                        "x1" 10 "y1" 20 "x2" 110 "y2" 70 "filled" t)
                       "drawn"))
        (should (equal (reverse calls)
                       '((undo 3) (rect 3 10 20 100 50 t 1))))
        (setq calls nil)
        ;; x2 is the radius; thickness is passed through.
        (cmacs-ftools-tests--call "imgedit_draw_shape" "handle" 3
                                  "shape" "circle" "x1" 5 "y1" 6 "x2" 9
                                  "thickness" 2)
        (should (equal (car calls) '(circle 3 5 6 9 nil 2)))
        (setq calls nil)
        ;; An unknown shape costs no undo step.
        (should (equal (cmacs-ftools-tests--call
                        "imgedit_draw_shape" "handle" 3 "shape" "blob"
                        "x1" 0 "y1" 0)
                       "Error: shape must be line|arrow|rect|circle|ellipse"))
        (should-not calls)
        ;; Brightness takes whole steps, contrast a factor.
        (cmacs-ftools-tests--call "imgedit_adjust" "handle" 3
                                  "kind" "brightness" "amount" 12.7)
        (should (equal (car calls) '(brightness 3 12)))
        (cmacs-ftools-tests--call "imgedit_adjust" "handle" 3
                                  "kind" "contrast" "amount" 1.2)
        (should (equal (car calls) '(contrast 3 1.2)))
        ;; Alpha defaults to opaque.
        (cmacs-ftools-tests--call "imgedit_set_color" "handle" 3
                                  "r" 1 "g" 2 "b" 3)
        (should (equal (car calls) '(color 3 1 2 3 255)))
        ;; An empty undo stack is an answer.
        (should (equal (cmacs-ftools-tests--call "imgedit_undo" "handle" 3)
                       "nothing"))))))


;;;; vidstudio

(ert-deftest cmacs-ftools-test-vidstudio-clips ()
  "Each clip kind reaches its primitive; a failed split is a failure."
  (cmacs-ftools-tests--with-family "vidstudio" '(cmacs-vidstudio)
    (let ((calls nil))
      (cl-letf (((symbol-function 'cmacs-vidstudio-add-video-clip)
                 (lambda (&rest args) (push (cons 'video args) calls) 11))
                ((symbol-function 'cmacs-vidstudio-add-solid-clip)
                 (lambda (&rest args) (push (cons 'solid args) calls) 12))
                ((symbol-function 'cmacs-vidstudio-add-text-clip)
                 (lambda (&rest args) (push (cons 'text args) calls) 13))
                ((symbol-function 'cmacs-vidstudio-split-clip)
                 (lambda (_h _clip at &rest _) (and (> at 0) 21))))
        (should (equal (cmacs-ftools-tests--call
                        "vidstudio_add_clip" "handle" 1 "track" 0
                        "kind" "video" "path" "/v/take.mp4")
                       "clip 11"))
        (should (equal (pop calls) '(video 1 0 "/v/take.mp4" 90)))
        (should (equal (cmacs-ftools-tests--call
                        "vidstudio_add_clip" "handle" 1 "track" 2
                        "kind" "solid" "duration_frames" 30 "r" 255)
                       "clip 12"))
        (should (equal (pop calls) '(solid 1 2 30 255 128 128 255)))
        (cmacs-ftools-tests--call "vidstudio_add_clip" "handle" 1 "track" 0
                                  "kind" "text" "text" "Hi")
        (should (equal (pop calls) '(text 1 0 "Hi" 90 255 255 255 255)))
        (should (equal (cmacs-ftools-tests--call
                        "vidstudio_add_clip" "handle" 1 "track" 0
                        "kind" "hologram")
                       "Error: kind must be video|image|solid|text"))
        (should (string-prefix-p
                 "Error: path is required"
                 (cmacs-ftools-tests--call "vidstudio_add_clip" "handle" 1
                                           "track" 0 "kind" "video")))
        (should-not calls)
        (should (equal (cmacs-ftools-tests--call
                        "vidstudio_split" "handle" 1 "clip" 4 "at_frame" 30)
                       "tail clip 21"))
        (should (equal (cmacs-ftools-tests--call
                        "vidstudio_split" "handle" 1 "clip" 4 "at_frame" 0)
                       "Error: Could not split clip 4 at frame 0"))))))

(ert-deftest cmacs-ftools-test-vidstudio-export-is-out-of-process ()
  "The export runs in a child, and no caller text reaches its Lisp."
  (cmacs-ftools-tests--with-family "vidstudio" '(cmacs-vidstudio)
    (let ((spawned nil) (sources nil))
      (cl-letf (((symbol-function 'cmacs-vidstudio-serialize)
                 (lambda (&rest _) "(vstudio)"))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq spawned (list args (copy-sequence
                                             process-environment)))
                   (push (cl-find-if
                          (lambda (e)
                            (string-prefix-p "CMACS_VIDSTUDIO_EXPORT_SRC=" e))
                          process-environment)
                         sources)
                   nil)))
        (unwind-protect
            (progn
              (should (plist-get (cmacs-capability-describe-tool
                                  "vidstudio_export")
                                 :async))
              ;; A format that is neither is refused before anything runs.
              (should (equal (car (cmacs-ftools-tests--call-async
                                   "vidstudio_export" "handle" 1
                                   "path" "/tmp/o.avi" "format" "avi"))
                             '(error "format must be mp4|gif")))
              (should-not spawned)
              (let* ((evil "/tmp/a\") (kill-emacs) (\"")
                     (cell (cmacs-ftools-tests--call-async
                            "vidstudio_export" "handle" 1 "path" evil
                            "format" "gif"))
                     (command (plist-get (car spawned) :command))
                     (env (cadr spawned)))
                ;; Started, not answered: the sentinel answers.
                (should-not (car cell))
                ;; The child's form is the constant ...
                (should (equal (car (last command))
                               cmacs-vidstudio-tools--export-form))
                (should-not (cl-some (lambda (a) (string-search "kill-emacs" a))
                                     command))
                ;; ... and the path travels in the environment.
                (should (member (concat "CMACS_VIDSTUDIO_EXPORT_OUT=" evil)
                                env))
                (should (member "CMACS_VIDSTUDIO_EXPORT_FORMAT=gif" env))))
          ;; The serialized project the tool wrote for the child.
          (dolist (s sources)
            (when s
              (ignore-errors
                (delete-file (substring s (length
                                           "CMACS_VIDSTUDIO_EXPORT_SRC=")))))))))))

(provide 'cmacs-gsurf-lrg-cad-media-tools-tests)

;;; cmacs-gsurf-lrg-cad-media-tools-tests.el ends here
