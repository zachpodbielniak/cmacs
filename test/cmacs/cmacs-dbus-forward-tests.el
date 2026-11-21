;;; cmacs-dbus-forward-tests.el --- Tests for the D-Bus forwarding table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The legacy D-Bus interfaces (org.cmacs.Editor1.Compositor, .Gsurf,
;; .BufferManager, ...) are served from one table,
;; cmacs/dbus/cmacs-dbus-forward-table.h, by cmacs-dbus-forward.c and
;; lisp/cmacs/cmacs-dbus-forward.el.  These tests need no D-Bus and no
;; rebuilt binary.  They read the table and the interfaces'
;; introspection XML as text, the registry as it is in this Emacs, and
;; check that the three agree:
;;
;;   - every row names a real method, a real tool or method function,
;;     arguments the tool has, and a reply the method's signature can
;;     carry;
;;   - the legacy-reach flag is on exactly the rows that need it;
;;   - every method of every interface is either a row or on the
;;     reviewed list below, with a reason -- so a method that shows
;;     what is on the person's screen cannot be added, or left behind,
;;     without someone deciding how it is redacted.
;;
;; The Lisp half is tested directly, with the C reply primitive stubbed.
;; What is NOT tested here is the wire: that is test/cmacs/cmacs-rig-tests.el
;; (`redaction-dbus-*', `dbus-forward-*'), which needs a built binary.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-capability)
(require 'cmacs-dbus-forward)

(defvar cmacs-brigade-auto-approve)
(defvar cmacs-brigade-confirm-function)
(defvar cmacs-redact-variable-refusal)

(defconst cmacs-dbus-forward-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name
                                 default-directory)))
  "The source tree these tests read.")

(defun cmacs-dbus-forward-tests--file (relative)
  "Return the text of the source file RELATIVE to the tree's root."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name relative cmacs-dbus-forward-tests--root))
    (buffer-string)))

;;;; Reading the table and the interfaces

(defun cmacs-dbus-forward-tests--rows ()
  "Return the forwarding table as a list of plists, from its text.
Each has :iface :method :target :args :reply :flags, the last a list
drawn from `legacy' and `approve'."
  (let ((text (cmacs-dbus-forward-tests--file
               "cmacs/dbus/cmacs-dbus-forward-table.h"))
        (start 0)
        (rows nil))
    (while (string-match
            (concat "^FWD (\"\\([^\"]*\\)\", \"\\([^\"]*\\)\", "
                    "\"\\([^\"]*\\)\", \"\\([^\"]*\\)\", "
                    "\"\\([^\"]*\\)\", \\([A-Z0 |]+\\))$")
            text start)
      (setq start (match-end 0))
      (let ((flags (match-string 6 text)))
        (push (list :iface (match-string 1 text)
                    :method (match-string 2 text)
                    :target (match-string 3 text)
                    :args (match-string 4 text)
                    :reply (match-string 5 text)
                    :flags (append
                            (and (string-match-p "LEGACY" flags) '(legacy))
                            (and (string-match-p "APPROVE" flags)
                                 '(approve))))
              rows)))
    (nreverse rows)))

(defun cmacs-dbus-forward-tests--row-lines ()
  "Return how many lines of the table begin a row."
  (let ((count 0))
    (dolist (line (split-string
                   (cmacs-dbus-forward-tests--file
                    "cmacs/dbus/cmacs-dbus-forward-table.h")
                   "\n"))
      (when (string-prefix-p "FWD (" line)
        (cl-incf count)))
    count))

(defun cmacs-dbus-forward-tests--string-literals (text)
  "Return the contents of every C string literal in TEXT, joined."
  (let ((start 0) (parts nil))
    (while (string-match "\"\\(\\(?:[^\"\\\n]\\|\\\\.\\)*\\)\"" text start)
      (setq start (match-end 0))
      (push (match-string 1 text) parts))
    (apply #'concat (nreverse parts))))

(defvar cmacs-dbus-forward-tests--methods-cache nil)

(defun cmacs-dbus-forward-tests--methods ()
  "Return every D-Bus method cmacs declares, from the introspection XML.
An alist of (\"Iface.Method\" :in TYPES :out TYPES :file NAME), Iface
being what follows \"org.cmacs.Editor1.\" (the root interface's methods
are \".Method\")."
  (or cmacs-dbus-forward-tests--methods-cache
      (setq
       cmacs-dbus-forward-tests--methods-cache
       (let ((methods nil))
         (dolist (file (append
                        (file-expand-wildcards
                         (expand-file-name "cmacs/dbus/*.c"
                                           cmacs-dbus-forward-tests--root))
                        (file-expand-wildcards
                         (expand-file-name "cmacs/glib/*.c"
                                           cmacs-dbus-forward-tests--root))))
           (let ((xml (cmacs-dbus-forward-tests--string-literals
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string))))
                 (start 0))
             (while (string-match
                     (concat "<interface name='org\\.cmacs\\.Editor1"
                             "\\.?\\([A-Za-z0-9]*\\)'>")
                     xml start)
               (let* ((iface (match-string 1 xml))
                      (body-start (match-end 0))
                      (body-end (or (string-match "</interface>" xml
                                                  body-start)
                                    (length xml)))
                      (body (substring xml body-start body-end))
                      (at 0))
                 (setq start body-end)
                 (while (string-match "<method name='\\([A-Za-z0-9]+\\)'>"
                                      body at)
                   (let* ((name (match-string 1 body))
                          (m-start (match-end 0))
                          (m-end (or (string-match "</method>" body m-start)
                                     (length body)))
                          (inner (substring body m-start m-end))
                          (in nil) (out nil) (pos 0))
                     (setq at m-end)
                     (while (string-match "<arg\\([^>]*\\)>" inner pos)
                       (let ((attrs (match-string 1 inner)))
                         (setq pos (match-end 0))
                         (when (string-match "type='\\([^']+\\)'" attrs)
                           (let ((type (match-string 1 attrs)))
                             (if (string-match-p "direction='out'" attrs)
                                 (push type out)
                               (push type in))))))
                     (push (list (concat iface "." name)
                                 :in (nreverse in) :out (nreverse out)
                                 :file (file-name-nondirectory file))
                           methods)))))))
         (nreverse methods)))))

(defun cmacs-dbus-forward-tests--method (row)
  "Return the XML entry of the method ROW serves, or nil."
  (cdr (assoc (concat (plist-get row :iface) "." (plist-get row :method))
              (cmacs-dbus-forward-tests--methods))))

(defun cmacs-dbus-forward-tests--map (row)
  "Return ROW's argument map as a list of plists.
Each has :name, and :skip, :constant, :optional or :fallback as the
item says."
  (mapcar
   (lambda (item)
     (cond
      ((equal item "-") (list :name nil :skip t))
      ((string-match "\\`\\([a-z_0-9]+\\)=\\(.*\\)\\'" item)
       (list :name (match-string 1 item) :constant (match-string 2 item)))
      ((string-match "\\`\\([a-z_0-9]+\\)\\?:\\(.*\\)\\'" item)
       (list :name (match-string 1 item) :optional t
             :fallback (match-string 2 item)))
      ((string-match "\\`\\([a-z_0-9]+\\)\\?\\'" item)
       (list :name (match-string 1 item) :optional t))
      ((string-match-p "\\`[a-z_0-9]+\\'" item)
       (list :name item))
      (t (list :name item :bad t))))
   (split-string (plist-get row :args) "," t)))

(defconst cmacs-dbus-forward-tests--iface-flags
  '(("Compositor" . IS-CMACS-GOWL) ("Monitor" . IS-CMACS-GOWL)
    ("Gsurf" . IS-CMACS-GSURF) ("GnusEye" . IS-CMACS-GNUSEYE)
    ("Lrg" . IS-CMACS-LIBREGNUM) ("Calc" . IS-CMACS-CALCULATOR)
    ("Podomation" . IS-CMACS-PODOMATION) ("Ai" . IS-CMACS-AI)
    ("Brigade" . IS-CMACS-AI-BRIGADE)
    ("DbExplorer" . IS-CMACS-DBEXPLORER)
    ("SecondBrain" . IS-CMACS-SECONDBRAIN) ("Video" . IS-CMACS-VIDEO))
  "The build flag each optional interface's tools are registered under.
An interface not listed belongs to the always-built core.")

(defun cmacs-dbus-forward-tests--built-p (row)
  "Non-nil when the subsystem behind ROW's interface is in this build."
  (let ((flag (cdr (assoc (plist-get row :iface)
                          cmacs-dbus-forward-tests--iface-flags))))
    (or (null flag) (and (boundp flag) (symbol-value flag)))))

(defun cmacs-dbus-forward-tests--tool (row)
  "Return the registry tool ROW forwards to, or nil."
  (let ((target (plist-get row :target)))
    (and (not (string-prefix-p "@" target))
         (cmacs-brigade--tool-by-wire target))))

(defun cmacs-dbus-forward-tests--tool-rows ()
  "Return the rows that forward to a tool of a subsystem built here."
  (cl-remove-if-not
   (lambda (row)
     (and (not (string-prefix-p "@" (plist-get row :target)))
          (cmacs-dbus-forward-tests--built-p row)))
   (cmacs-dbus-forward-tests--rows)))

(defun cmacs-dbus-forward-tests--name (row)
  "Return ROW as \"Iface.Method\" for a failure message."
  (concat (plist-get row :iface) "." (plist-get row :method)))

;;;; The table against the interfaces and the registry

(ert-deftest cmacs-dbus-forward-test-table-parses ()
  "Every row line of the table is in the documented format, once."
  (let ((rows (cmacs-dbus-forward-tests--rows)))
    (should (> (length rows) 150))
    ;; A line that begins a row and does not parse would silently drop
    ;; a method from every test below.
    (should (= (length rows) (cmacs-dbus-forward-tests--row-lines)))
    (should-not
     (cl-remove-if
      (lambda (row)
        (member (plist-get row :reply) '("text" "raw" "prin1" "lines" "ok")))
      rows))
    (let ((names (mapcar #'cmacs-dbus-forward-tests--name rows)))
      (should (equal (length names)
                     (length (delete-dups (copy-sequence names))))))
    (should-not
     (cl-loop for row in rows
              when (cl-some (lambda (item) (plist-get item :bad))
                            (cmacs-dbus-forward-tests--map row))
              collect (cmacs-dbus-forward-tests--name row)))))

(ert-deftest cmacs-dbus-forward-test-rows-name-real-methods ()
  "Every row serves a method some interface declares."
  (should-not
   (cl-remove-if #'cmacs-dbus-forward-tests--method
                 (cmacs-dbus-forward-tests--rows)
                 :key #'identity)))

(ert-deftest cmacs-dbus-forward-test-rows-name-registered-tools ()
  "Every tool row names a tool the registry has."
  (skip-unless (fboundp 'cmacs-brigade--tool-by-wire))
  (should-not
   (cl-loop for row in (cmacs-dbus-forward-tests--tool-rows)
            unless (cmacs-dbus-forward-tests--tool row)
            collect (format "%s -> %s"
                            (cmacs-dbus-forward-tests--name row)
                            (plist-get row :target)))))

(ert-deftest cmacs-dbus-forward-test-method-rows-name-functions ()
  "Every @NAME row has its function, and every function has a row."
  (let ((used nil))
    (dolist (row (cmacs-dbus-forward-tests--rows))
      (let ((target (plist-get row :target)))
        (when (string-prefix-p "@" target)
          (let ((fn (intern-soft (concat "cmacs-dbus-method-"
                                         (substring target 1)))))
            (should (and fn (fboundp fn)))
            (push fn used)))))
    (let ((orphans nil))
      (mapatoms
       (lambda (sym)
         (when (and (fboundp sym)
                    (string-prefix-p "cmacs-dbus-method-" (symbol-name sym))
                    (not (memq sym used)))
           (push sym orphans))))
      (should-not orphans))))

(defun cmacs-dbus-forward-tests--type-fits-p (dbus-type param-type)
  "Non-nil when a D-Bus argument of DBUS-TYPE can be the tool's PARAM-TYPE.
A string can be any scalar: the argument validation converts \"3\" and
\"true\", which is how the all-string Brigade methods work."
  (pcase dbus-type
    ("s" (member param-type '("string" "integer" "number" "boolean")))
    ("b" (equal param-type "boolean"))
    ("d" (equal param-type "number"))
    ((or "y" "n" "q" "i" "u" "x" "t")
     (member param-type '("integer" "number")))
    ("as" (equal param-type "array"))
    ("a{ss}" (equal param-type "object"))))

(ert-deftest cmacs-dbus-forward-test-argument-maps-fit ()
  "Each argument map fits its method's arguments and its tool's parameters.
One item per D-Bus input argument; every named member is a parameter of
the tool, of a type the D-Bus argument can be; and every parameter the
tool requires is always sent."
  (skip-unless (fboundp 'cmacs-brigade--tool-by-wire))
  (let ((problems nil))
    (dolist (row (cmacs-dbus-forward-tests--rows))
      (let* ((name (cmacs-dbus-forward-tests--name row))
             (method (cmacs-dbus-forward-tests--method row))
             (map (cmacs-dbus-forward-tests--map row))
             (consuming (cl-remove-if (lambda (i) (plist-get i :constant))
                                      map))
             (in (plist-get method :in)))
        (unless (= (length consuming) (length in))
          (push (format "%s: %d map items for %d arguments"
                        name (length consuming) (length in))
                problems))
        ;; Only the types the C side can turn into JSON.
        (dolist (type in)
          (unless (member type '("s" "b" "d" "y" "n" "q" "i" "u" "x" "t"
                                 "as" "a{ss}"))
            (push (format "%s: argument type %s cannot be carried"
                          name type)
                  problems)))
        (let ((tool (and (cmacs-dbus-forward-tests--built-p row)
                         (cmacs-dbus-forward-tests--tool row))))
          (when tool
            (let ((params (cmacs-brigade-tool-params tool))
                  (always nil))
              (cl-loop
               for item in consuming
               for type in in
               do (let* ((pname (plist-get item :name))
                         (param (and pname
                                     (cl-find pname params :test #'equal
                                              :key (lambda (p)
                                                     (plist-get p :name))))))
                    (cond
                     ((plist-get item :skip) nil)
                     ((null param)
                      (push (format "%s: %s has no parameter %s"
                                    name (plist-get row :target) pname)
                            problems))
                     ((not (cmacs-dbus-forward-tests--type-fits-p
                            type (plist-get param :type)))
                      (push (format "%s: %s is %s, the argument is %s"
                                    name pname (plist-get param :type) type)
                            problems)))
                    (when (and pname
                               (or (not (plist-get item :optional))
                                   (plist-get item :fallback)))
                      (push pname always))))
              (dolist (item map)
                (when (plist-get item :constant)
                  (unless (cl-find (plist-get item :name) params
                                   :test #'equal
                                   :key (lambda (p) (plist-get p :name)))
                    (push (format "%s: %s has no parameter %s"
                                  name (plist-get row :target)
                                  (plist-get item :name))
                          problems))
                  (push (plist-get item :name) always)))
              (dolist (param params)
                (when (and (plist-get param :required)
                           (not (plist-get param :default))
                           (not (member (plist-get param :name) always)))
                  (push (format "%s: required parameter %s of %s is not \
always sent"
                                name (plist-get param :name)
                                (plist-get row :target))
                        problems))))))))
    (should-not (nreverse problems))))

(ert-deftest cmacs-dbus-forward-test-method-functions-take-the-map ()
  "A method function's parameters are its row's argument map."
  (let ((defined nil)
        (problems nil))
    (with-temp-buffer
      (insert (cmacs-dbus-forward-tests--file
               "lisp/cmacs/cmacs-dbus-forward.el"))
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (eq (car-safe form) 'cmacs-dbus-forward-defmethod)
                (push (cons (symbol-name (nth 1 form))
                            (mapcar #'symbol-name (nth 2 form)))
                      defined))))
        (end-of-file nil)))
    (dolist (row (cmacs-dbus-forward-tests--rows))
      (let ((target (plist-get row :target)))
        (when (string-prefix-p "@" target)
          (let ((params (cdr (assoc (substring target 1) defined)))
                (names (delq nil (mapcar (lambda (i) (plist-get i :name))
                                         (cmacs-dbus-forward-tests--map
                                          row)))))
            (unless (equal (sort (copy-sequence params) #'string<)
                           (sort (copy-sequence names) #'string<))
              (push (format "%s: the map sends %S, %s takes %S"
                            (cmacs-dbus-forward-tests--name row)
                            names target params)
                    problems))))))
    (should-not (nreverse problems))))

(ert-deftest cmacs-dbus-forward-test-replies-fit-signatures ()
  "Each row's reply can be sent as the method's declared out signature."
  (let ((problems nil))
    (dolist (row (cmacs-dbus-forward-tests--rows))
      (let* ((out (plist-get (cmacs-dbus-forward-tests--method row) :out))
             (reply (plist-get row :reply))
             (lisp (string-prefix-p "@" (plist-get row :target)))
             (ok (and (= (length out) 1)
                      (pcase reply
                        ("ok" (equal out '("b")))
                        ("lines" (equal out '("as")))
                        ((or "raw" "prin1") (equal out '("s")))
                        ;; A tool's text is a string; a method function
                        ;; returns a value of the reply's own type.
                        ("text" (if lisp
                                    (member (car out)
                                            '("s" "b" "i" "u" "x" "t" "d"
                                              "as"))
                                  (equal out '("s"))))))))
        (unless ok
          (push (format "%s: reply %s for signature %S"
                        (cmacs-dbus-forward-tests--name row) reply out)
                problems))))
    (should-not (nreverse problems))))

(ert-deftest cmacs-dbus-forward-test-legacy-reach-is-exact ()
  "LEGACY is on exactly the rows whose tool is off the `dbus' surface.
Not on a row that does not need it -- the flagged rows are the list of
what D-Bus may do beyond the registry's defaults, and it must not grow
by accident -- and on every row that does, or the method stops working."
  (skip-unless (fboundp 'cmacs-brigade--tool-by-wire))
  (let ((problems nil))
    (dolist (row (cmacs-dbus-forward-tests--rows))
      (let ((legacy (memq 'legacy (plist-get row :flags)))
            (approve (memq 'approve (plist-get row :flags)))
            (tool (and (cmacs-dbus-forward-tests--built-p row)
                       (cmacs-dbus-forward-tests--tool row)))
            (name (cmacs-dbus-forward-tests--name row)))
        (when (and (string-prefix-p "@" (plist-get row :target))
                   (plist-get row :flags))
          (push (format "%s: a method function takes no flags" name)
                problems))
        (when tool
          (let ((on (cmacs-brigade-tool-on-surface-p tool 'dbus)))
            (when (and legacy on)
              (push (format "%s: LEGACY, but %s is on dbus" name
                            (plist-get row :target))
                    problems))
            (when (and (not legacy) (not on))
              (push (format "%s: %s is off dbus and the row has no LEGACY"
                            name (plist-get row :target))
                    problems)))
          (when (and approve (null (cmacs-brigade-tool-confirm tool)))
            (push (format "%s: APPROVE, but %s asks for no confirmation"
                          name (plist-get row :target))
                  problems)))
        (when (and approve
                   (not (equal (plist-get row :iface) "Brigade")))
          (push (format "%s: APPROVE is the Brigade interface's alone" name)
                problems))))
    (should-not (nreverse problems))))

;;;; Every method is accounted for

(defconst cmacs-dbus-forward-tests--hand-written
  '(;; Runs code or types input a caller supplied.  Redaction is not a
    ;; sandbox, and says so; these are the documented exception.
    (privileged
     ".Eval" ".GiCall" ".GiRequire" ".GiListFunctions" ".Message"
     ".FindFile"
     "Bacon.Eval" "Bacon.EvalC" "Bacon.Complete"
     "Crispy.Eval" "Crispy.EvalString" "Eshell.Eval"
     "Input.ExecuteCommand" "Input.SendKeys"
     "Podomation.EvalDsl" "Podomation.ReplEval"
     "Compositor.RunMacro" "Compositor.RunKeybind" "Compositor.Hotkey"
     "Cpatch.PatchDefun" "Cpatch.PatchList" "Cpatch.UnpatchAll"
     "Cpatch.UnpatchDefun"
     "Cintrospect.AddrToSource" "Cintrospect.DefunInfo"
     "Cintrospect.FunctionSource" "Cintrospect.List"
     "Cintrospect.ListDefuns" "Cintrospect.ListObjects"
     "Cintrospect.StackTrace" "Cintrospect.SymbolInfo"
     "Cintrospect.TypeInfo")
    ;; The generic interface itself.
    (generic "Tools.List" "Tools.Describe" "Tools.Call")
    ;; Compositor state that is not a window's: configuration, layout
    ;; numbers, modes, outputs.  Most go straight to gowl in C under
    ;; the compositor lock.
    (compositor
     "Compositor.AddKeybind" "Compositor.AddKeybindFull"
     "Compositor.AddRule" "Compositor.Broadcast" "Compositor.ConfigGet"
     "Compositor.Floatdesk" "Compositor.FocusDirection"
     "Compositor.FocusLast" "Compositor.FocusUrgent" "Compositor.KeyMode"
     "Compositor.KeyboardLayout" "Compositor.Lock"
     "Compositor.OutputPower" "Compositor.PointerConfine"
     "Compositor.ReloadConfig" "Compositor.SetKeyMode"
     "Compositor.SetMfact" "Compositor.SetNmaster"
     "Compositor.SwitchKeyboardLayout" "Compositor.Unlock"
     "Compositor.ViewTags"
     "Monitor.Info" "Monitor.Modes" "Monitor.Position"
     "Monitor.SetEnabled" "Monitor.SetMode" "Monitor.SetPosition"
     "Monitor.SetScale")
    ;; Acts and answers with an acknowledgement, a count or a number:
    ;; nothing of the screen is in the reply.
    (acts
     "Bookmark.Set" "Bookmark.Jump" "Bookmark.Delete"
     "Clipboard.Copy" "Clipboard.Cut" "Clipboard.Paste" "Clipboard.Put"
     "Clipboard.PutSelection"
     "Config.Set" "Config.Theme" "Config.Font" "Config.Mode"
     "Edit.SetContent" "Edit.InsertOrg"
     "File.Open" "File.Save" "File.Close"
     "Nav.Goto" "Nav.Point"
     "Package.Install" "Package.Remove" "Package.Refresh"
     "Project.Compile" "Project.NextError" "Project.PrevError"
     "Project.WriteFile"
     "Search.Search" "Search.Replace"
     "Text.Insert" "Text.Append"
     "ProcessManager.Kill" "ProcessManager.Pid" "ProcessManager.SendTo"
     "ProcessManager.Status" "ProcessManager.List"
     "SecondBrain.Ingest" "SecondBrain.Migrate" "SecondBrain.Watch"
     "Audio.Record"
     "Speech.Components" "Speech.ListVoices" "Speech.ListWhisperModels"
     "Speech.Models" "Speech.SetComponent" "Speech.Synthesize"
     "Speech.Transcribe" "Speech.WhoSpoke"
     "Brigade.Agents"
     "Instance.Features" "Instance.Info"
     "Events.Categories" "Events.EventTypes"
     "Watch.Add" "Watch.List" "Watch.Remove")
    ;; Shows the screen, and asks the redaction contract in the form it
    ;; evaluates (the C names the function; see the source guard below).
    (redacted-in-c
     "Lql.Query" "Lql.QueryJson" "Lql.Explain" "Lql.Sources"
     "Video.Snapshot")
    ;; Known gaps, listed in doc_org/cmacs/cmacs-redact.org as not
    ;; covered.  Adding to this group is a decision to leave something
    ;; unredacted: say so in that table too.
    (not-covered
     "VC.Status" "VC.Diff" "VC.Log" "VC.Blame"
     "Events.Recent"))
  "Every D-Bus method that is NOT a row of the forwarding table, and why.
`cmacs-dbus-forward-test-every-method-is-accounted-for' fails for a
method that is neither a row nor here.")

(ert-deftest cmacs-dbus-forward-test-every-method-is-accounted-for ()
  "Each D-Bus method is forwarded, or reviewed and listed with a reason.
This is the guard against a method that shows what is on the screen
being added -- or left -- outside both the capability table and the
redaction contract: it cannot be done without editing the list above,
which is where the decision is made."
  (let* ((rows (mapcar #'cmacs-dbus-forward-tests--name
                       (cmacs-dbus-forward-tests--rows)))
         (listed (apply #'append
                        (mapcar #'cdr
                                cmacs-dbus-forward-tests--hand-written)))
         (all (mapcar #'car (cmacs-dbus-forward-tests--methods))))
    (should (> (length all) 250))
    ;; Neither forwarded nor reviewed.
    (should-not (cl-remove-if (lambda (m) (or (member m rows)
                                              (member m listed)))
                              all))
    ;; Reviewed, but gone or since forwarded: the list is stale.
    (should-not (cl-remove-if (lambda (m) (and (member m all)
                                               (not (member m rows))))
                              listed))
    (should (equal (length listed)
                   (length (delete-dups (copy-sequence listed)))))))

(defconst cmacs-dbus-forward-tests--screen-primitives
  '("(buffer-list)" "buffer-name" "buffer-file-name" "window-buffer"
    "buffer-substring" "(buffer-string)" "kill-ring" "gui-get-selection"
    "recentf-list" "bookmark-alist" "project-files"
    ;; A variable's value: the sensitive-variable registry
    ;; (`cmacs-redact-variable-guard') must be asked first.
    "symbol-value" "default-value" "describe-variable"
    "insert-file-contents" "gowl-screenshot" "gowl-list-clients"
    "gowl-focused-client" "gowl-client-info"
    "gowl_client_get_title" "gowl_client_get_app_id"
    "cmacs_dispatch_gowl_list_clients" "cmacs_dispatch_gowl_focused_client"
    "cmacs_dispatch_gowl_find_client")
  "Text that, in hand-written D-Bus C, means a reply may show the screen.")

(defconst cmacs-dbus-forward-tests--screen-allowed
  '(;; Asks cmacs-redact in the same form.
    ("cmacs-dbus-search-provider.c" . "cmacs-redact-buffer-p")
    ("cmacs-dbus-mpris.c" . "cmacs-redact-buffer-p")
    ("cmacs-dbus-iface-log.c" . "cmacs-redact-text")
    ;; Output of a command the caller supplied (privileged), and git's
    ;; output (the not-covered group above).
    ("cmacs-dbus-iface-lang.c" . nil)
    ("cmacs-dbus-iface-vc.c" . nil)
    ;; `kill-ring-save' and comments about the kill ring: writes.
    ("cmacs-dbus-iface-clipboard.c" . nil))
  "Files whose use of a screen primitive has been reviewed.
\(FILE . WORD): the file must also contain WORD -- the redaction call
that makes the use safe -- or, with nil, is an accepted exception named
in `cmacs-dbus-forward-tests--hand-written'.")

(ert-deftest cmacs-dbus-forward-test-no-unredacted-screen-state-in-c ()
  "Hand-written D-Bus C does not read the screen without the contract.
A form that lists buffers, reads one, reads the clipboard or names a
window belongs in a tool or in cmacs-dbus-forward.el, where redaction
is; the C that is left may only do so in a file reviewed above."
  (let ((problems nil))
    (dolist (file (file-expand-wildcards
                   (expand-file-name "cmacs/dbus/*.c"
                                     cmacs-dbus-forward-tests--root)))
      (let* ((name (file-name-nondirectory file))
             (text (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))
             (hits (cl-remove-if-not
                    (lambda (word) (string-search word text))
                    cmacs-dbus-forward-tests--screen-primitives))
             (allowed (assoc name cmacs-dbus-forward-tests--screen-allowed)))
        (when (and hits
                   ;; The forwarder's own file names none of them, and
                   ;; its table is not C that runs.
                   (not (equal name "cmacs-dbus-forward.c")))
          (cond
           ((null allowed)
            (push (format "%s uses %S" name hits) problems))
           ((and (cdr allowed) (not (string-search (cdr allowed) text)))
            (push (format "%s uses %S without %s" name hits (cdr allowed))
                  problems))))))
    (should-not (nreverse problems))))

(ert-deftest cmacs-dbus-forward-test-variables-go-through-the-guard ()
  "The methods that print a variable's value ask the sensitive registry.
Config.Get, Debug.DescribeVariable and Debug.ListHooks used to format
`symbol-value' in C.  Each must be a row whose target asks
cmacs-redact: the registry tools do, and so must the method function."
  (let ((rows (cmacs-dbus-forward-tests--rows)))
    (dolist (want '(("Config" "Get" "@config-get")
                    ("Debug" "DescribeVariable" "describe_variable")
                    ("Debug" "ListHooks" "list_hooks")))
      (let ((row (cl-find-if (lambda (r)
                               (and (equal (plist-get r :iface) (nth 0 want))
                                    (equal (plist-get r :method)
                                           (nth 1 want))))
                             rows)))
        (should row)
        (should (equal (plist-get row :target) (nth 2 want))))))
  ;; The tools' files and the method function name the guard.
  (dolist (file '("lisp/cmacs/cmacs-describe-tools.el"
                  "lisp/cmacs/cmacs-debug-tools.el"
                  "lisp/cmacs/cmacs-dbus-forward.el"))
    (should (string-search "cmacs-redact-variable-p"
                           (cmacs-dbus-forward-tests--file file))))
  ;; And the function refuses, in the fixed words, without the value.
  (skip-unless (require 'cmacs-redact nil t))
  (skip-unless (fboundp 'cmacs-redact-variable-p))
  (defvar cmacs-dbus-forward-tests--sensitive)
  (let ((cmacs-dbus-forward-tests--sensitive "the-secret-value"))
    (cl-letf (((symbol-function 'cmacs-redact-variable-p)
               (lambda (&rest _) t)))
      (let ((answer (cmacs-dbus-method-config-get
                     '((var . "cmacs-dbus-forward-tests--sensitive")))))
        (should (equal answer cmacs-redact-variable-refusal))
        (should-not (string-search "the-secret-value" answer))))
    (cl-letf (((symbol-function 'cmacs-redact-variable-p)
               (lambda (&rest _) nil))
              ((symbol-function 'cmacs-dbus-forward--text) #'identity))
      (should (string-search
               "the-secret-value"
               (cmacs-dbus-method-config-get
                '((var . "cmacs-dbus-forward-tests--sensitive"))))))))

;;;; The Lisp half

(defmacro cmacs-dbus-forward-tests--with-replies (var &rest body)
  "Run BODY with the C reply primitive recording into VAR.
VAR is bound to the list of (TOKEN KIND TEXT) answers, newest first.
Like the real primitive, a token is answered once."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-function 'cmacs-dbus-forward--reply)
                (lambda (&rest args)
                  (unless (assq (car args) ,var)
                    (push args ,var)
                    t))))
       ,@body)))

(ert-deftest cmacs-dbus-forward-test-unprint ()
  "A printed string is un-printed; anything else is left alone."
  (should (equal (cmacs-dbus-forward--unprint "\"focused\"") "focused"))
  (should (equal (cmacs-dbus-forward--unprint
                  (prin1-to-string "a \"quoted\" line\nand \\ more"))
                 "a \"quoted\" line\nand \\ more"))
  (should (equal (cmacs-dbus-forward--unprint "plain text") "plain text"))
  (should (equal (cmacs-dbus-forward--unprint "") ""))
  (should (equal (cmacs-dbus-forward--unprint "\"") "\""))
  ;; Two printed strings are not one.
  (should (equal (cmacs-dbus-forward--unprint "\"a\" \"b\"") "\"a\" \"b\""))
  ;; JSON that happens to start and end with a quote character.
  (should (equal (cmacs-dbus-forward--unprint "[\"a\"]") "[\"a\"]")))

(ert-deftest cmacs-dbus-forward-test-adapt ()
  "Each reply name turns a result into the method's value."
  (should (equal (cmacs-dbus-forward--adapt "text" nil "x") '(nil . "x")))
  (should (equal (cmacs-dbus-forward--adapt "raw" nil "\"x\"") '(nil . "x")))
  (should (equal (cmacs-dbus-forward--adapt "prin1" nil "x")
                 '(nil . "\"x\"")))
  (should (equal (cmacs-dbus-forward--adapt "lines" nil "\"a\nb\n\"")
                 '(nil "a" "b")))
  (should (equal (cmacs-dbus-forward--adapt "ok" nil "t") '(nil . t)))
  ;; "It did not happen" is false; a broken call is still an error.
  (should (equal (cmacs-dbus-forward--adapt "ok" "ToolFailed" "no buffer")
                 '(nil)))
  (should (equal (cmacs-dbus-forward--adapt "ok" "BadArguments" "bad")
                 '("BadArguments" . "bad")))
  (should (equal (cmacs-dbus-forward--adapt "raw" "Timeout" "late")
                 '("Timeout" . "late"))))

(ert-deftest cmacs-dbus-forward-test-encode ()
  "A value is written as the reply type's GVariant text."
  (should (equal (cmacs-dbus-forward--encode "as it is\n" "(s)")
                 "as it is\n"))
  (should (equal (cmacs-dbus-forward--encode nil "(s)") ""))
  (should (equal (cmacs-dbus-forward--encode t "(b)") "(true,)"))
  (should (equal (cmacs-dbus-forward--encode nil "(b)") "(false,)"))
  (should (equal (cmacs-dbus-forward--encode -1 "(x)") "(-1,)"))
  (should (equal (cmacs-dbus-forward--encode 3 "(i)") "(3,)"))
  (should (equal (cmacs-dbus-forward--encode nil "(as)") "([],)"))
  (should (equal (cmacs-dbus-forward--encode '("a" "b \"c\" \\ d\n") "(as)")
                 "([\"a\", \"b \\\"c\\\" \\\\ d\\n\"],)"))
  ;; A value of the wrong shape is a failed call, not a wrong reply.
  (should-error (cmacs-dbus-forward--encode "three" "(i)"))
  (should-error (cmacs-dbus-forward--encode '(1 2) "(as)"))
  (should-error (cmacs-dbus-forward--encode "x" "(a{sv})")))

(ert-deftest cmacs-dbus-forward-test-method-call ()
  "A method function gets its arguments as values and answers once."
  (cmacs-dbus-forward-tests--with-replies replies
    (cl-letf (((symbol-function 'cmacs-dbus-method-rig-echo)
               (lambda (args) (list (alist-get 'a args)
                                    (format "%s" (alist-get 'n args))))))
      (cmacs-dbus-forward-call 7 "@rig-echo" "{\"a\":\"x\\\"y\",\"n\":3}"
                               "text" "(as)" 0))
    (should (equal replies '((7 nil "([\"x\\\"y\", \"3\"],)")))))
  ;; A signal is a failed call with the message, not a crash.
  (cmacs-dbus-forward-tests--with-replies replies
    (cl-letf (((symbol-function 'cmacs-dbus-method-rig-fail)
               (lambda (_args) (error "nope"))))
      (cmacs-dbus-forward-call 8 "@rig-fail" "{}" "text" "(s)" 0))
    (should (equal replies '((8 "ToolFailed" "nope")))))
  (cmacs-dbus-forward-tests--with-replies replies
    (cmacs-dbus-forward-call 9 "@no-such-method-function" "{}" "text"
                             "(s)" 0)
    (should (equal (nth 1 (car replies)) "NoSuchTool"))))

(defmacro cmacs-dbus-forward-tests--with-tool (form &rest body)
  "Register the tool FORM, a `cmacs-brigade-deftool' form, around BODY."
  (declare (indent 1))
  `(unwind-protect
       (progn ,form ,@body)
     (cmacs-brigade-unregister-tool ',(nth 1 form))))

(ert-deftest cmacs-dbus-forward-test-tool-call ()
  "A tool row goes through validation and answers with the tool's text."
  (skip-unless (fboundp 'cmacs-brigade-call-tool-async))
  (cmacs-dbus-forward-tests--with-tool
      (cmacs-brigade-deftool dbus-forward-test-echo
        "Echo."
        ((text string "Text") (times integer "Times" :optional t))
        (prin1-to-string (format "%s x%s" text (or times 1))))
    (cmacs-dbus-forward-tests--with-replies replies
      (cmacs-dbus-forward-call 1 "dbus_forward_test_echo"
                               "{\"text\":\"hi\",\"times\":2}" "raw" "(s)" 0)
      (should (equal replies '((1 nil "hi x2")))))
    ;; A member that is not a parameter is refused before anything runs.
    (cmacs-dbus-forward-tests--with-replies replies
      (cmacs-dbus-forward-call 2 "dbus_forward_test_echo"
                               "{\"text\":\"hi\",\"tmies\":2}" "raw" "(s)" 0)
      (should (equal (nth 1 (car replies)) "BadArguments")))
    (cmacs-dbus-forward-tests--with-replies replies
      (cmacs-dbus-forward-call 3 "dbus_forward_test_absent" "{}" "raw"
                               "(s)" 0)
      (should (equal (nth 1 (car replies)) "NoSuchTool")))))

(ert-deftest cmacs-dbus-forward-test-legacy-reach ()
  "A destructive tool is reached by a LEGACY row and by no other."
  (skip-unless (fboundp 'cmacs-brigade-call-tool-async))
  (cmacs-dbus-forward-tests--with-tool
      (cmacs-brigade-deftool dbus-forward-test-destroy
        "Destroy."
        ()
        :destructive t
        "t")
    (should-not (cmacs-brigade-tool-on-surface-p
                 (cmacs-brigade--tool-by-wire "dbus_forward_test_destroy")
                 'dbus))
    (cmacs-dbus-forward-tests--with-replies replies
      (cmacs-dbus-forward-call 1 "dbus_forward_test_destroy" "{}" "ok"
                               "(b)" 0)
      (should (equal (nth 1 (car replies)) "NotOnSurface")))
    (cmacs-dbus-forward-tests--with-replies replies
      (cmacs-dbus-forward-call 2 "dbus_forward_test_destroy" "{}" "ok" "(b)"
                               cmacs-dbus-forward-flag-legacy-reach)
      (should (equal replies '((2 nil "(true,)")))))
    ;; The grant is the row's: the generic interface still refuses.
    (let ((seen nil))
      (cmacs-capability-call "dbus_forward_test_destroy" "{}" 'dbus
                             (lambda (kind _text) (setq seen kind)))
      (should (equal seen "NotOnSurface")))))

(ert-deftest cmacs-dbus-forward-test-approve ()
  "The confirmation policy applies, except to an APPROVE row."
  (skip-unless (fboundp 'cmacs-brigade-call-tool-async))
  (cmacs-dbus-forward-tests--with-tool
      (cmacs-brigade-deftool dbus-forward-test-confirm
        "Confirm."
        ()
        :confirm 'ask
        "done")
    (let ((cmacs-brigade-auto-approve nil)
          (cmacs-brigade-confirm-function nil)
          ;; As inside a dispatch: nobody to ask.
          (inhibit-interaction t))
      (cl-letf (((symbol-function 'cmacs-brigade-registry-list)
                 (let ((real (symbol-function 'cmacs-brigade-registry-list)))
                   (lambda (kind &rest more)
                     (if (eq kind 'approval-handler)
                         nil
                       (apply real kind more))))))
        (cmacs-dbus-forward-tests--with-replies replies
          (cmacs-dbus-forward-call 1 "dbus_forward_test_confirm" "{}" "text"
                                   "(s)" 0)
          (should (equal (nth 1 (car replies)) "ToolFailed")))
        (cmacs-dbus-forward-tests--with-replies replies
          (cmacs-dbus-forward-call 2 "dbus_forward_test_confirm" "{}" "text"
                                   "(s)" cmacs-dbus-forward-flag-approve)
          (should (equal replies '((2 nil "done")))))))))

(ert-deftest cmacs-dbus-forward-test-async-tool-answers-later ()
  "An :async tool's reply is sent when it calls `done', and only once."
  (skip-unless (fboundp 'cmacs-brigade-call-tool-async))
  (let ((finish nil))
    (cmacs-dbus-forward-tests--with-tool
        (cmacs-brigade-deftool dbus-forward-test-later
          "Later."
          ()
          :async t :timeout 30
          (setq finish done)
          nil)
      (cmacs-dbus-forward-tests--with-replies replies
        (should-not (cmacs-dbus-forward-call 5 "dbus_forward_test_later"
                                             "{}" "text" "(s)" 0))
        ;; Returned, and nothing was sent: nothing waited.
        (should-not replies)
        (should (functionp finish))
        (funcall finish "finished")
        (should (equal replies '((5 nil "finished"))))
        (funcall finish "again")
        (should (= (length replies) 1))))))

(ert-deftest cmacs-dbus-forward-test-buffer-methods-redact ()
  "The BufferManager methods treat an excluded buffer as absent."
  (let ((public (generate-new-buffer "dbus-forward-test-public"))
        (secret (generate-new-buffer "dbus-forward-test-secret")))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-dbus-forward--hidden-buffer-p)
                   (lambda (buffer-or-name)
                     (string-search
                      "secret"
                      (if (bufferp buffer-or-name)
                          (buffer-name buffer-or-name)
                        buffer-or-name)))))
          (let ((names (cmacs-dbus-method-buffer-list nil)))
            (should (member (buffer-name public) names))
            (should-not (member (buffer-name secret) names)))
          (should (cmacs-dbus-method-buffer-find
                   `((name . ,(buffer-name public)))))
          (should-not (cmacs-dbus-method-buffer-find
                       `((name . ,(buffer-name secret)))))
          (should (= -1 (cmacs-dbus-method-buffer-point
                         `((name . ,(buffer-name secret))))))
          (should (equal "" (cmacs-dbus-method-buffer-filename
                             `((name . ,(buffer-name secret))))))
          (should-not (cmacs-dbus-method-buffer-switch
                       `((name . ,(buffer-name secret)))))
          (should-not (cmacs-dbus-method-window-select-by-buffer
                       `((buffer . ,(buffer-name secret)))))
          (with-current-buffer secret
            (should (equal "" (cmacs-dbus-method-buffer-current nil)))
            (insert "content of the excluded buffer")
            ;; The refusal is the one a missing buffer gets.
            (let ((refused (cadr (should-error
                                  (cmacs-dbus-method-text-line
                                   `((n . 1)
                                     (buffer . ,(buffer-name secret)))))))
                  (missing (cadr (should-error
                                  (cmacs-dbus-method-text-line
                                   '((n . 1)
                                     (buffer . "dbus-forward-test-absent")))))))
              (should (equal (replace-regexp-in-string
                              "dbus-forward-test-[a-z]+" "NAME" refused)
                             (replace-regexp-in-string
                              "dbus-forward-test-[a-z]+" "NAME" missing))))))
      (kill-buffer public)
      (kill-buffer secret))))

(ert-deftest cmacs-dbus-forward-test-clipboard-methods-redact ()
  "Clipboard text goes through the free-text rules."
  (let ((kill-ring (list "token sk-12345 here" "plain")))
    (cl-letf (((symbol-function 'cmacs-dbus-forward--text)
               (lambda (text)
                 (replace-regexp-in-string "sk-[0-9]+" "[key]" (or text ""))))
              ((symbol-function 'cmacs-dbus-forward--selection)
               (lambda (&rest _) nil)))
      (should (equal (cmacs-dbus-method-clipboard-list nil)
                     "token [key] here|||plain"))
      (should (equal (cmacs-dbus-method-clipboard-get nil)
                     "token [key] here"))
      (should-error (cmacs-dbus-method-clipboard-get-selection
                     '((selection . "x) (shell-command \"id\")")))))))

(provide 'cmacs-dbus-forward-tests)

;;; cmacs-dbus-forward-tests.el ends here
