;;; cmacs-dbus-forward.el --- Legacy D-Bus methods served from the capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; cmacs has two generations of D-Bus surface.  The newer one is a
;; single interface, org.cmacs.Editor1.Tools, which calls any tool in
;; the registry (`cmacs-brigade-deftool') by name.  The older one is a
;; method per capability on a per-subsystem interface -- Compositor,
;; BufferManager, Gsurf, Edit, ... -- each of which used to carry its own
;; copy of the work: a Lisp form built with printf in C, evaluated, and
;; its printed value sent back.
;;
;; That second copy had drifted from the first.  A window the redaction
;; rules exclude was hidden from `gowl_list_clients' over MCP and listed
;; by Compositor.ListClients; BufferManager.List named buffers
;; `list_buffers' leaves out; several methods called functions that are
;; not loaded and simply errored.
;;
;; This file is the Lisp half of the cure.  The C half
;; (cmacs/dbus/cmacs-dbus-forward.c) holds one table, in
;; cmacs-dbus-forward-table.h, with a row per legacy method:
;;
;;   interface, method, target, argument map, reply, flags
;;
;; and one function every interface calls first.  For a method with a
;; row the C builds a JSON object from the method's typed arguments,
;; parks the invocation under an integer token and evaluates
;;
;;   (cmacs-dbus-forward-call TOKEN TARGET JSON REPLY SIGNATURE FLAGS)
;;
;; which is `cmacs-dbus-forward-call' below.  TARGET is one of
;;
;;   a tool's wire name   the call goes through the same gates as
;;                        Tools.Call: surface, argument validation,
;;                        the before-call hooks, the confirmation
;;                        policy, the redaction a tool applies, and an
;;                        :async tool is answered later, without the
;;                        main thread ever waiting;
;;
;;   @NAME                the function `cmacs-dbus-method-NAME' in this
;;                        file: a method that has no tool, or whose
;;                        legacy reply cannot be made from a tool's
;;                        text.  Every one that shows what is on the
;;                        person's screen asks cmacs-redact.el first.
;;
;; REPLY names how the result becomes the method's declared reply (see
;; `cmacs-dbus-forward--adapt'), so the wire signature of every legacy
;; method is what it always was.
;;
;; Two flags keep the legacy names working where the table's own
;; defaults would refuse:
;;
;;   legacy-reach (1)   A :destructive tool is, by default, not on the
;;                      `dbus' surface.  A legacy method that has always
;;                      performed that action keeps doing so: its row
;;                      carries this flag, which grants that one named
;;                      method -- not Tools.Call, not `emacsctl tool' --
;;                      the reach it has always had.  Nothing new is
;;                      opened: the method existed and did this before.
;;                      A row may carry it only when its tool is in
;;                      fact off `dbus'; the test suite refuses any
;;                      other, so the list of flagged rows is exactly
;;                      the list of legacy grants.
;;
;;   approve (2)        org.cmacs.Editor1.Brigade has always approved
;;                      its own calls (a D-Bus caller is the session's
;;                      owner).  Its rows keep that: the confirmation
;;                      policy is answered "yes" for the one call.
;;
;; Redaction.  A D-Bus dispatch binds `inhibit-interaction', which is
;; what `cmacs-redact-active-p' takes to mean "an RPC caller, assume a
;; program": everything here runs redacted, the person's own scripts
;; included, exactly as doc_org/cmacs/cmacs-redact.org says of
;; `emacsctl'.  Nothing in this file decides who is asking.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'cmacs-capability)

(declare-function cmacs-dbus-forward--reply "cmacs-dbus-forward.c"
                  (token kind text))
(declare-function cmacs-brigade--tool-by-wire "cmacs-brigade-registry"
                  (wire-name))
(declare-function cmacs-redact-buffer-p "cmacs-redact" (buffer-or-name))
(declare-function cmacs-redact-file-p "cmacs-redact" (file))
(declare-function cmacs-redact-file "cmacs-redact" (file))
(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function cmacs-redact-variable-p "cmacs-redact" (symbol))
(declare-function cmacs-redact-capture-guard "cmacs-redact"
                  (what &optional target))
(declare-function gowl-find-client "cmacs-gowl.c" (pattern &optional by))
(declare-function gowl-screenshot "cmacs-gowl.c" (&rest args))
(declare-function gowl-screenshot-client "cmacs-gowl.c" (client))
(declare-function gowl-screenshot-save-png "cmacs-gowl.c" (&rest args))
(declare-function cmacs-redact-capture-refused-p "cmacs-redact"
                  (what &optional target))
(declare-function project-files "project" (project &optional dirs))
(declare-function project-current "project" (&optional maybe-prompt dir))

;; Bound dynamically below; special only if this file knows it is.
(defvar cmacs-brigade-confirm-function)
(defvar cmacs-redact-variable-refusal)
(defvar recentf-list)
(defvar bookmark-alist)
(defvar package-alist)

(defconst cmacs-dbus-forward-flag-legacy-reach 1
  "Row flag: this legacy method may reach a tool that is off `dbus'.
The value is CMACS_DBUS_FWD_LEGACY in cmacs-dbus-forward.c.")

(defconst cmacs-dbus-forward-flag-approve 2
  "Row flag: answer the confirmation policy \"yes\" for this call.
The value is CMACS_DBUS_FWD_APPROVE in cmacs-dbus-forward.c.")

(defconst cmacs-dbus-forward-unavailable
  "No such buffer, or it is not available"
  "What a method says of a buffer it will not touch.
One message for a buffer that does not exist and one the redaction
rules exclude, so the answer cannot be used to tell them apart.")


;;;; Replies

(defun cmacs-dbus-forward--unprint (text)
  "Return TEXT as `cmacs_dispatch_eval_string' would have returned it.
Many migrated tools answer in the shape their MCP handler had, which is
the value printed by `prin1': the string \"focused\" arrives with its
quotes.  The D-Bus methods of the same name sent strings verbatim.
When TEXT is exactly one printed Lisp string its value is returned;
anything else is returned unchanged."
  (if (and (stringp text)
           (> (length text) 1)
           (eq (aref text 0) ?\")
           (eq (aref text (1- (length text))) ?\"))
      (condition-case nil
          (let ((read (read-from-string text)))
            (if (and (stringp (car read)) (= (cdr read) (length text)))
                (car read)
              text))
        (error text))
    text))

(defun cmacs-dbus-forward--adapt (reply kind value)
  "Turn a result into what the legacy method replies; return (KIND . VALUE).

REPLY is the row's reply name.  KIND is nil for a result and an error
kind (\"ToolFailed\", \"BadArguments\", ...) otherwise; VALUE is the
tool's text, a method function's value, or the error message.

  text    the value as it is
  raw     a printed Lisp string is un-printed (see
          `cmacs-dbus-forward--unprint'): for methods that always sent
          raw text where the tool sends it printed
  prin1   the value printed: for methods that always sent it printed
          (they replied through cmacs_dbus_eval_to_reply)
  lines   the un-printed text split into its non-empty lines, for a
          method whose reply is an array of strings
  ok      true when the call succeeded and FALSE when the tool
          failed, for a method whose reply is one boolean: \"did it
          happen\".  A missing buffer, an excluded one and a refused
          confirmation are all \"it did not\", which is what these
          methods have always said of a missing buffer.  Bad arguments
          and a timeout stay errors."
  (pcase reply
    ("ok"
     (cond ((null kind) (cons nil t))
           ((equal kind "ToolFailed") (cons nil nil))
           (t (cons kind value))))
    ((guard kind) (cons kind value))
    ("raw" (cons nil (cmacs-dbus-forward--unprint value)))
    ("prin1" (cons nil (prin1-to-string value)))
    ("lines" (cons nil (split-string (cmacs-dbus-forward--unprint
                                      (if (stringp value) value ""))
                                     "\n" t)))
    (_ (cons nil value))))

(defun cmacs-dbus-forward--gvariant-string (string)
  "Return STRING as a string literal in GVariant text format."
  (concat
   "\""
   (replace-regexp-in-string
    "[\"\\\\[:cntrl:]]"
    (lambda (ch)
      (pcase (aref ch 0)
        (?\" "\\\"")
        (?\\ "\\\\")
        (?\n "\\n")
        (?\t "\\t")
        (?\r "\\r")
        (c (format "\\u%04x" c))))
    string t t)
   "\""))

(defun cmacs-dbus-forward--encode (value signature)
  "Return VALUE as text the C side turns into a reply of type SIGNATURE.

SIGNATURE is the method's out signature as a tuple, \"(s)\" or \"(as)\".
For \"(s)\" the text is the string itself and is sent verbatim.  For
every other type it is GVariant text for the whole tuple, which the C
side parses against SIGNATURE -- so a value of the wrong shape is a
failed call, never a reply of the wrong type."
  (pcase signature
    ("(s)" (cond ((stringp value) value)
                 ((null value) "")
                 (t (format "%s" value))))
    ("(b)" (if (and value (not (eq value :false))) "(true,)" "(false,)"))
    ((or "(i)" "(u)" "(x)" "(t)" "(n)" "(q)" "(y)")
     (unless (integerp value)
       (error "the reply must be an integer, got %S" value))
     (format "(%d,)" value))
    ("(d)"
     (unless (numberp value)
       (error "the reply must be a number, got %S" value))
     (format "(%s,)" (float value)))
    ("(as)"
     (unless (and (listp value) (cl-every #'stringp value))
       (error "the reply must be a list of strings"))
     (format "([%s],)"
             (mapconcat #'cmacs-dbus-forward--gvariant-string value ", ")))
    (_ (error "no conversion to the D-Bus type %s" signature))))

(defun cmacs-dbus-forward--answer (token reply signature kind value)
  "Answer the invocation parked under TOKEN.
REPLY and SIGNATURE are the row's; KIND and VALUE are as in
`cmacs-dbus-forward--adapt'.  An invocation is answered once: the C
side ignores a second answer, so a tool that calls `done' twice or
after its timeout reaches the caller the first time only."
  (condition-case err
      (pcase-let ((`(,kind . ,value)
                   (cmacs-dbus-forward--adapt reply kind value)))
        (if kind
            (cmacs-dbus-forward--reply
             token kind (if (stringp value) value (format "%s" value)))
          (cmacs-dbus-forward--reply
           token nil (cmacs-dbus-forward--encode value signature))))
    (error
     (cmacs-dbus-forward--reply token "ToolFailed"
                                (error-message-string err)))))


;;;; Calling

(defun cmacs-dbus-forward--call-tool (name json-args flags answer)
  "Call the tool NAME with JSON-ARGS for a legacy method; report to ANSWER.

The gates are those of `cmacs-capability-call', in its order, with the
two differences a row's FLAGS may ask for (see the commentary): the
surface gate lets a legacy-reach row through to a tool that is off
`dbus', and an approve row answers the confirmation policy.  ANSWER
receives (KIND TEXT) exactly once, later for an :async tool.  Never
signals and never waits."
  (condition-case err
      (let ((tool (cmacs-brigade--tool-by-wire
                   (cmacs-brigade-wire-name name)))
            (reach (/= 0 (logand flags
                                 cmacs-dbus-forward-flag-legacy-reach)))
            (approve (/= 0 (logand flags cmacs-dbus-forward-flag-approve))))
        (unless tool
          (signal 'cmacs-capability-error
                  (list (format "no tool named %s" name) "NoSuchTool")))
        (unless (or reach (cmacs-brigade-tool-on-surface-p tool 'dbus))
          (signal 'cmacs-capability-error
                  (list (format "%s is not published on dbus"
                                (cmacs-brigade-tool-wire-name tool))
                        "NotOnSurface")))
        (let ((alist (cmacs-capability-parse-args tool json-args))
              ;; The policy is consulted before the handler starts, so
              ;; this binding is in force for exactly the question it
              ;; is meant to answer, async tool or not.
              (cmacs-brigade-confirm-function
               (if approve #'always cmacs-brigade-confirm-function)))
          (cmacs-brigade-call-tool-async
           (cmacs-brigade-tool-wire-name tool) alist
           (lambda (status text)
             (funcall answer
                      (pcase status
                        ('ok nil)
                        ('timeout "Timeout")
                        (_ "ToolFailed"))
                      text))
           "dbus")))
    (cmacs-capability-error
     (funcall answer (or (nth 2 err) "ToolFailed") (nth 1 err)))
    (error
     (funcall answer "ToolFailed" (error-message-string err))))
  nil)

(defun cmacs-dbus-forward--call-method (name json-args answer)
  "Run `cmacs-dbus-method-NAME' on JSON-ARGS; report to ANSWER.
The function receives the arguments as an alist with symbol keys and
returns the reply value.  A signal is a failed call."
  (condition-case err
      (let ((fn (intern-soft (concat "cmacs-dbus-method-" name))))
        (unless (and fn (fboundp fn))
          (signal 'cmacs-capability-error
                  (list (format "no D-Bus method function named %s" name)
                        "NoSuchTool")))
        (funcall answer nil
                 (funcall fn (json-parse-string
                              (if (string-blank-p json-args) "{}" json-args)
                              :object-type 'alist :array-type 'list
                              :null-object nil :false-object nil))))
    (cmacs-capability-error
     (funcall answer (or (nth 2 err) "ToolFailed") (nth 1 err)))
    (error
     (funcall answer "ToolFailed" (error-message-string err))))
  nil)

(defun cmacs-dbus-forward-call (token target json-args reply signature flags)
  "Serve one legacy D-Bus method invocation from the capability table.

Called by `cmacs_dbus_forward' (cmacs/dbus/cmacs-dbus-forward.c) for a
method that has a row in the forwarding table.  TOKEN is the integer
the invocation is parked under; TARGET a tool's wire name, or @NAME
for the function `cmacs-dbus-method-NAME'; JSON-ARGS the JSON object
built from the method's typed arguments; REPLY the row's reply name;
SIGNATURE the method's out signature; FLAGS the row's flags.

Returns nil at once.  The answer goes back through
`cmacs-dbus-forward--reply', before this returns for a synchronous
target and when the tool finishes for an :async one, so the main
thread -- under `--gowl' the compositor's -- is never held."
  (let ((answer (lambda (kind value)
                  (cmacs-dbus-forward--answer token reply signature
                                              kind value))))
    (if (string-prefix-p "@" target)
        (cmacs-dbus-forward--call-method (substring target 1)
                                         json-args answer)
      (cmacs-dbus-forward--call-tool target json-args
                                     (if (integerp flags) flags 0)
                                     answer)))
  nil)


;;;; Methods with no tool
;;
;; Each is the body of one legacy method, with its arguments as values
;; (never spliced into a form) and its reply as a Lisp value the row's
;; signature types.  The redaction functions are called, never
;; second-guessed: they are the identity for a caller that is not
;; model-facing, and a D-Bus caller always is.

(defmacro cmacs-dbus-forward-defmethod (name params docstring &rest body)
  "Define `cmacs-dbus-method-NAME', the body of a legacy D-Bus method.
PARAMS are symbols bound to the members of the same name in the JSON
object the forwarding table's argument map built; a member that was
omitted is nil.  DOCSTRING names the method served.  The value of BODY
is the reply."
  (declare (indent 2) (doc-string 3))
  (let ((args (make-symbol "args")))
    `(defun ,(intern (format "cmacs-dbus-method-%s" name)) (,args)
       ,docstring
       (ignore ,args)
       (let ,(mapcar (lambda (p) `(,p (alist-get ',p ,args))) params)
         ,@body))))

(defun cmacs-dbus-forward--hidden-buffer-p (buffer-or-name)
  "Non-nil when the redaction rules exclude BUFFER-OR-NAME."
  (require 'cmacs-redact)
  (and (cmacs-redact-buffer-p buffer-or-name) t))

(defun cmacs-dbus-forward--hidden-file-p (file)
  "Non-nil when the redaction rules exclude FILE."
  (require 'cmacs-redact)
  (and (cmacs-redact-file-p file) t))

(defun cmacs-dbus-forward--text (string)
  "Return STRING with the free-text redaction rules applied."
  (if (or (null string) (string-empty-p string))
      ""
    (require 'cmacs-redact)
    (cmacs-redact-text string)))

(defun cmacs-dbus-forward--buffer (name)
  "Return the live buffer NAME a caller may be shown, or nil.
An empty NAME is the current buffer.  The rules are asked of the name
first and of the buffer after, since they also look at its file, mode
and project."
  (let ((buffer (if (or (null name) (string-empty-p name))
                    (current-buffer)
                  (and (not (cmacs-dbus-forward--hidden-buffer-p name))
                       (get-buffer name)))))
    (and (buffer-live-p buffer)
         (not (cmacs-dbus-forward--hidden-buffer-p buffer))
         buffer)))

(defun cmacs-dbus-forward--buffer-or-signal (name)
  "Return the buffer NAME as `cmacs-dbus-forward--buffer', or signal."
  (or (cmacs-dbus-forward--buffer name)
      (error "%s: %s" cmacs-dbus-forward-unavailable (or name ""))))

;;;;; org.cmacs.Editor1.BufferManager

(cmacs-dbus-forward-defmethod buffer-list ()
  "BufferManager.List: the names of the buffers a caller may be shown."
  (mapcar #'buffer-name
          (seq-remove #'cmacs-dbus-forward--hidden-buffer-p (buffer-list))))

(cmacs-dbus-forward-defmethod buffer-find (name)
  "BufferManager.Find: whether the buffer NAME exists, as far as shown."
  (and (stringp name) (not (string-empty-p name))
       (cmacs-dbus-forward--buffer name)
       t))

(cmacs-dbus-forward-defmethod buffer-current ()
  "BufferManager.Current: the current buffer's name, or \"\" if withheld."
  (if (cmacs-dbus-forward--hidden-buffer-p (current-buffer))
      ""
    (buffer-name (current-buffer))))

(cmacs-dbus-forward-defmethod buffer-filename (name)
  "BufferManager.FilenameFor: the file NAME visits, or \"\"."
  (let* ((buffer (and (stringp name) (not (string-empty-p name))
                      (cmacs-dbus-forward--buffer name)))
         (file (and buffer (buffer-file-name buffer))))
    (require 'cmacs-redact)
    ;; The name is shown as the rules rewrite it, like a listing.
    (or (and file (cmacs-redact-file file)) "")))

(cmacs-dbus-forward-defmethod buffer-point (name)
  "BufferManager.PointFor: point in NAME, or -1."
  (let ((buffer (and (stringp name) (not (string-empty-p name))
                     (cmacs-dbus-forward--buffer name))))
    (if buffer (with-current-buffer buffer (point)) -1)))

(cmacs-dbus-forward-defmethod buffer-modified-p (name)
  "BufferManager.ModifiedP: whether NAME has unsaved changes."
  (let ((buffer (and (stringp name) (not (string-empty-p name))
                     (cmacs-dbus-forward--buffer name))))
    (and buffer (buffer-modified-p buffer) t)))

(cmacs-dbus-forward-defmethod buffer-save-current ()
  "BufferManager.SaveCurrent: save the current buffer."
  ;; A prompt here would be a recursive edit under the dispatch; the
  ;; dispatch already binds this, and saying so costs nothing.
  (let ((inhibit-interaction t))
    (save-buffer))
  t)

(cmacs-dbus-forward-defmethod buffer-switch (name)
  "BufferManager.Switch: show the existing buffer NAME in this window.
Unlike the `switch_to_buffer' tool this never creates a buffer, which
is why it is not forwarded to it: the method has always answered false
for a name that is not open."
  (let ((buffer (and (stringp name) (not (string-empty-p name))
                     (cmacs-dbus-forward--buffer name))))
    (and buffer (progn (switch-to-buffer buffer) t))))

;;;;; org.cmacs.Editor1.FrameManager

(defun cmacs-dbus-forward--frame-shown-p (frame)
  "Non-nil when FRAME's selected window shows a buffer a caller may see."
  (not (cmacs-dbus-forward--hidden-buffer-p
        (window-buffer (frame-selected-window frame)))))

(cmacs-dbus-forward-defmethod frame-list ()
  "FrameManager.List: the frames' names.
A frame is named after the buffer its selected window shows unless the
person named it, so a frame showing an excluded buffer is left out and
the others go through the free-text rules -- what `list_frames' does.
\(The method used to format each name with %d and so always failed.)"
  (delq nil
        (mapcar (lambda (frame)
                  (and (cmacs-dbus-forward--frame-shown-p frame)
                       (let ((name (frame-parameter frame 'name)))
                         (and (stringp name) (not (string-empty-p name))
                              (cmacs-dbus-forward--text name)))))
                (frame-list))))

(cmacs-dbus-forward-defmethod frame-selected ()
  "FrameManager.Selected: the selected frame's index in `frame-list'."
  (or (cl-position (selected-frame) (frame-list)) -1))

(cmacs-dbus-forward-defmethod frame-count ()
  "FrameManager.Count: how many frames there are."
  (length (frame-list)))

(cmacs-dbus-forward-defmethod frame-raise-all ()
  "FrameManager.RaiseAll: raise every frame."
  (mapc #'raise-frame (frame-list))
  t)

;;;;; org.cmacs.Editor1.WindowManager

(cmacs-dbus-forward-defmethod window-list ()
  "WindowManager.List: one id per window (win-WIDTH, as it always was)."
  (mapcar (lambda (w) (format "win-%d" (window-total-width w)))
          (window-list)))

(cmacs-dbus-forward-defmethod window-selected ()
  "WindowManager.Selected: the selected window's id."
  (format "win-%d" (window-total-width (selected-window))))

(cmacs-dbus-forward-defmethod window-count ()
  "WindowManager.Count: how many windows the selected frame has."
  (length (window-list)))

(cmacs-dbus-forward-defmethod window-select-by-buffer (buffer)
  "WindowManager.SelectByBuffer: select a window showing BUFFER.
False for a buffer no window shows, and for one the rules exclude."
  (let* ((target (and (stringp buffer) (not (string-empty-p buffer))
                      (cmacs-dbus-forward--buffer buffer)))
         (window (and target (get-buffer-window target t))))
    (and window (progn (select-window window) t))))

;;;;; org.cmacs.Editor1.Project

(cmacs-dbus-forward-defmethod project-list-files ()
  "Project.ListFiles: the current project's files, one per line."
  (require 'project)
  (let ((project (project-current)))
    (unless project
      (error "no project here"))
    (mapconcat #'identity
               (seq-remove #'cmacs-dbus-forward--hidden-file-p
                           (project-files project))
               "\n")))

(cmacs-dbus-forward-defmethod project-read-file (path)
  "Project.ReadFile: the contents of the file PATH.
Not confined to a workspace, as it never was; an excluded file reads
as one that is not there."
  (unless (and (stringp path) (not (string-empty-p path)))
    (error "Missing required argument: path"))
  (let ((file (expand-file-name path)))
    (when (or (cmacs-dbus-forward--hidden-file-p file)
              (not (file-readable-p file))
              (file-directory-p file))
      (error "file not readable: %s" path))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(cmacs-dbus-forward-defmethod project-find (filename dir)
  "Project.Find: files named FILENAME under DIR, as find(1) prints them.
Runs find(1) and waits for it, as the method always has; what is new is
that a path the rules exclude is dropped from the answer."
  (let* ((dir (if (and (stringp dir) (not (string-empty-p dir))) dir "."))
         (output (with-temp-buffer
                   (call-process "find" nil t nil dir "-name"
                                 (or filename ""))
                   (buffer-string)))
         (kept (seq-remove
                (lambda (line)
                  (cmacs-dbus-forward--hidden-file-p
                   (expand-file-name line)))
                (split-string output "\n" t))))
    (if kept
        (concat (mapconcat #'identity kept "\n") "\n")
      "")))

;;;;; org.cmacs.Editor1.Search, .Text, .File

(cmacs-dbus-forward-defmethod search-occur (pattern)
  "Search.Occur: LINE:TEXT for each match of PATTERN in the current buffer."
  (with-current-buffer (cmacs-dbus-forward--buffer-or-signal nil)
    (save-excursion
      (goto-char (point-min))
      (let (out)
        (while (re-search-forward pattern nil t)
          (push (format "%d:%s" (line-number-at-pos)
                        (buffer-substring-no-properties
                         (line-beginning-position)
                         (line-end-position)))
                out)
          (forward-line 1))
        (mapconcat #'identity (nreverse out) "\n")))))

(cmacs-dbus-forward-defmethod text-line (n buffer)
  "Text.Line: the text of line N of BUFFER (\"\" is the current one)."
  (with-current-buffer (cmacs-dbus-forward--buffer-or-signal buffer)
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- (or n 1)))
      (buffer-substring-no-properties (line-beginning-position)
                                      (line-end-position)))))

(cmacs-dbus-forward-defmethod text-delete (start end buffer)
  "Text.Delete: delete START..END in BUFFER and return what was there."
  (with-current-buffer (cmacs-dbus-forward--buffer-or-signal buffer)
    (let ((text (buffer-substring-no-properties start end)))
      (delete-region start end)
      text)))

(cmacs-dbus-forward-defmethod file-recent (n)
  "File.Recent: the N most recent files, joined with |||."
  (require 'recentf)
  (require 'cmacs-redact)
  (mapconcat #'identity
             (seq-take (delq nil (mapcar #'cmacs-redact-file recentf-list))
                       (if (and (integerp n) (> n 0)) n 20))
             "|||"))

;;;;; org.cmacs.Editor1.Clipboard

(defun cmacs-dbus-forward--selection (selection)
  "Return the text of SELECTION, a symbol, or nil."
  (and (fboundp 'gui-get-selection)
       (condition-case nil
           (gui-get-selection selection 'STRING)
         (error nil))))

(cmacs-dbus-forward-defmethod clipboard-list ()
  "Clipboard.List: the first 80 characters of each kill, joined with |||."
  (mapconcat (lambda (kill)
               (let ((text (cmacs-dbus-forward--text
                            (substring-no-properties kill))))
                 (substring text 0 (min 80 (length text)))))
             kill-ring "|||"))

(cmacs-dbus-forward-defmethod clipboard-get ()
  "Clipboard.Get: the system clipboard, else the newest kill."
  (cmacs-dbus-forward--text
   (or (cmacs-dbus-forward--selection 'CLIPBOARD)
       (and kill-ring (substring-no-properties (car kill-ring)))
       "")))

(cmacs-dbus-forward-defmethod clipboard-get-selection (selection)
  "Clipboard.GetSelection: the text of PRIMARY, SECONDARY or CLIPBOARD."
  (unless (member selection '("PRIMARY" "SECONDARY" "CLIPBOARD"))
    (error "selection must be PRIMARY, SECONDARY or CLIPBOARD"))
  (cmacs-dbus-forward--text
   (or (cmacs-dbus-forward--selection (intern selection)) "")))

;;;;; org.cmacs.Editor1.Bookmark, .Config, .Package

(cmacs-dbus-forward-defmethod bookmark-list ()
  "Bookmark.List: the bookmark names, joined with |||.
A bookmark into a file the rules exclude is left out; a name usually
says what it points at."
  (require 'bookmark)
  (mapconcat
   #'identity
   (delq nil
         (mapcar (lambda (entry)
                   (let ((file (ignore-errors
                                 (alist-get 'filename (cdr entry)))))
                     (and (stringp (car entry))
                          (not (and (stringp file)
                                    (cmacs-dbus-forward--hidden-file-p
                                     (expand-file-name file))))
                          (cmacs-dbus-forward--text (car entry)))))
                 bookmark-alist))
   "|||"))

(cmacs-dbus-forward-defmethod config-get (var)
  "Config.Get: the printed value of the variable VAR."
  (require 'cmacs-redact)
  (let ((symbol (and (stringp var) (intern-soft var))))
    (cond
     ((cmacs-redact-variable-p var)
      cmacs-redact-variable-refusal)
     ((and symbol (boundp symbol))
      (cmacs-dbus-forward--text (format "%S" (symbol-value symbol))))
     (t (error "Symbol's value as variable is void: %s" var)))))

(cmacs-dbus-forward-defmethod package-list ()
  "Package.List: the installed packages' names, joined with |||.
\(The method used to read `package-alist' without loading package.el,
and so failed in any session that had not.)"
  (require 'package)
  (mapconcat (lambda (entry) (symbol-name (car entry)))
             (and (boundp 'package-alist) package-alist)
             "|||"))

;;;;; org.cmacs.Editor1.Compositor

(cmacs-dbus-forward-defmethod compositor-screenshot (mode client by file)
  "Compositor.Screenshot: save a PNG of the desktop or one window to FILE.
MODE is desktop, window or all; CLIENT, when given, is a pattern
matched against app-ids, or titles when BY is \"title\".  Refused, in
the words every capture is refused in, while something the redaction
rules exclude would be in the picture."
  (require 'cmacs-redact)
  (unless (and (stringp file) (not (string-empty-p file)))
    (error "Missing required argument: file"))
  (if (and (stringp client) (not (string-empty-p client)))
      (let ((found (gowl-find-client client
                                     (if (equal by "title") 'title 'app-id))))
        ;; A window the caller may not see is a pattern that matched
        ;; nothing: the refusal must not say that it is there.
        (when (or (null found)
                  (cmacs-redact-capture-refused-p 'client found))
          (error "no client matching pattern"))
        (let ((shot (gowl-screenshot-client found)))
          (unless shot
            (error "screenshot capture produced no image"))
          (apply #'gowl-screenshot-save-png (append shot (list file)))
          file))
    (let ((what (pcase mode
                  ("window" 'window)
                  ("all" 'all)
                  (_ 'desktop))))
      (cmacs-redact-capture-guard what)
      (gowl-screenshot what file t)
      file)))

(provide 'cmacs-dbus-forward)

;;; cmacs-dbus-forward.el ends here
