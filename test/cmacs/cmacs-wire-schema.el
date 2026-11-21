;;; cmacs-wire-schema.el --- The frozen MCP wire schema  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What an MCP client was promised, written down.
;;
;; Every MCP tool cmacs publishes used to be a hand-written C handler in
;; cmacs/mcp/, with its name, description and JSON Schema in that C.
;; 256 of them became `cmacs-brigade-deftool' forms, and each family had
;; an ERT guard that parsed its C file's text and compared the registry
;; tool against it.  Those guards were the only thing holding wire
;; compatibility, and they read the C that was then deleted.
;;
;; So the C's answer was frozen first, into
;;
;;     test/cmacs/data/mcp-wire-schema.json
;;
;; and the guards compare the registry against that file through this
;; one.  The file was not parsed out of the C text.  It is what a real
;; MCP client received from `tools/list' when the server had ONLY its C
;; tools (the Lisp registry kept from loading): name, description,
;; `inputSchema' and `annotations', byte for byte as json-glib wrote
;; them, plus two members a client never saw -- `source', the C file
;; that registered the tool, and `ifdef', the configure flags that
;; registration was compiled under.  `cmacs-wire-schema-freeze' is the
;; function that did it; it is kept because it documents the format and
;; because the 27 tools still in C can be re-frozen with it.
;;
;; THE FILE IS EDITED ON PURPOSE, NEVER REGENERATED WHOLESALE.  A tool
;; that is in it keeps its entry for as long as the name is published.
;; Changing a published tool's parameters means editing its block, in
;; the same commit, where a reviewer sees a wire change as a wire
;; change.  A NEW tool that should be held to its schema from now on is
;; added with `cmacs-wire-schema-freeze-registry-tool' (or by hand);
;; tools that were never C tools are not required to be in the file.
;;
;; Reading it:
;;
;;   (cmacs-wire-schema-tool "gowl_list_clients")   ; one entry, an alist
;;   (cmacs-wire-schema-names "cmacs-mcp-tools-gowl.c")
;;   (cmacs-wire-schema-params "calc_eval")         ; plists, schema order
;;
;; Checking a registry tool against it:
;;
;;   (cmacs-wire-schema-should-match "calc_eval" :description 'words)
;;
;; which fails with one line per difference, e.g.
;;
;;   gowl_list_clients: parameter 2 was `tag' (integer, optional), is
;;   now `tag' (string, optional)

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)

(declare-function cmacs-capability-describe-tool "cmacs-capability")
(declare-function cmacs-mcp-start "cmacs-mcp.c")
(declare-function cmacs-mcp-stop "cmacs-mcp.c")
(declare-function cmacs-mcp-socket-path "cmacs-mcp.c")

(defconst cmacs-wire-schema--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time.")

(defun cmacs-wire-schema-file ()
  "Return the name of the frozen schema file."
  (expand-file-name "data/mcp-wire-schema.json"
                    (file-name-directory cmacs-wire-schema--this-file)))

(defvar cmacs-wire-schema--cache nil
  "The parsed file, as (MTIME . HASH-TABLE of name -> entry).")

(defun cmacs-wire-schema--table ()
  "Return the frozen tools as a hash table of wire name -> entry alist.
Read again when the file changes, so editing it and re-running a test
in one session works."
  (let* ((file (cmacs-wire-schema-file))
         (mtime (file-attribute-modification-time (file-attributes file))))
    (unless (file-readable-p file)
      (error "The frozen MCP wire schema is missing: %s" file))
    (unless (equal mtime (car cmacs-wire-schema--cache))
      (let ((table (make-hash-table :test #'equal))
            (data (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object :false))))
        (dolist (tool (alist-get 'tools data))
          (let ((name (alist-get 'name tool)))
            (when (gethash name table)
              (error "%s: `%s' is frozen twice" file name))
            (puthash name tool table)))
        (setq cmacs-wire-schema--cache (cons mtime table))))
    (cdr cmacs-wire-schema--cache)))

(defun cmacs-wire-schema-tool (name)
  "Return the frozen entry of the tool with wire name NAME, or nil.
An alist with `name', `source', `ifdef', `description', `inputSchema'
and, when the C set a hint, `annotations'."
  (gethash name (cmacs-wire-schema--table)))

(defun cmacs-wire-schema-names (&optional source)
  "Return the frozen wire names, sorted.
With SOURCE, a C file's base name such as \"cmacs-mcp-tools-gowl.c\",
only the tools that file registered, in the order it registered them."
  (let ((entries nil))
    (maphash (lambda (_name tool) (push tool entries))
             (cmacs-wire-schema--table))
    (if source
        (mapcar (lambda (tool) (alist-get 'name tool))
                (sort (seq-filter (lambda (tool)
                                    (equal (alist-get 'source tool) source))
                                  entries)
                      (lambda (a b) (< (alist-get 'order a)
                                       (alist-get 'order b)))))
      (sort (mapcar (lambda (tool) (alist-get 'name tool)) entries)
            #'string<))))

(defun cmacs-wire-schema-description (name)
  "Return the frozen description of NAME."
  (alist-get 'description (cmacs-wire-schema-tool name)))

(defun cmacs-wire-schema-params (name)
  "Return NAME's frozen parameters, in schema order.
A list of plists (:name :type :required :description :enum), the same
members `cmacs-capability-describe-tool' gives a registry parameter."
  (let* ((schema (alist-get 'inputSchema (cmacs-wire-schema-tool name)))
         (required (alist-get 'required schema)))
    (mapcar (lambda (prop)
              (let ((pname (symbol-name (car prop))))
                (list :name pname
                      :type (alist-get 'type (cdr prop))
                      :required (and (member pname required) t)
                      :description (alist-get 'description (cdr prop))
                      :enum (alist-get 'enum (cdr prop)))))
            (alist-get 'properties schema))))

(defun cmacs-wire-schema-required (name)
  "Return the names of NAME's required parameters, in schema order."
  (cl-loop for p in (cmacs-wire-schema-params name)
           when (plist-get p :required) collect (plist-get p :name)))

(defun cmacs-wire-schema-read-only-p (name)
  "Return non-nil when the C published NAME with `readOnlyHint' true."
  (eq t (alist-get 'readOnlyHint
                   (alist-get 'annotations (cmacs-wire-schema-tool name)))))

(defun cmacs-wire-schema-flags (name)
  "Return the configure flags NAME's C registration was compiled under.
A list of strings such as (\"HAVE_CMACS_GOWL\"); nil for a tool every
build with an MCP server had."
  (alist-get 'ifdef (cmacs-wire-schema-tool name)))


;;;; Comparing a registry tool with its frozen entry

(defun cmacs-wire-schema--param-text (param)
  "Describe PARAM, a parameter plist, the way a failure message shows it."
  (if param
      (format "`%s' (%s, %s)" (plist-get param :name) (plist-get param :type)
              (if (plist-get param :required) "required" "optional"))
    "absent"))

(defun cmacs-wire-schema--words (text)
  "Return TEXT's words: the comparison that ignores line folding."
  (split-string (or text "")))

(cl-defun cmacs-wire-schema-differences
    (name &key description enum hints param-descriptions entry)
  "Return what differs between the registry tool NAME and its frozen entry.
A list of sentences, nil when they agree.  Always compared: that both
exist, and the parameters' names, order, types and required-ness.  On
request:

  DESCRIPTION         t for the same text, `words' for the same words
                      \(the C text was folded across string literals)
  ENUM                non-nil compares each parameter's `enum'
  HINTS               non-nil requires `readOnlyHint' in C to be exactly
                      \"not :destructive\" here
  PARAM-DESCRIPTIONS  t (same text) or `words' compares each
                      parameter's description, where the C gave one

ENTRY is the registry's description of the tool when the caller already
has it; by default `cmacs-capability-describe-tool' is asked."
  (let ((frozen (cmacs-wire-schema-tool name))
        (entry (or entry (cmacs-capability-describe-tool name)))
        (out nil))
    (cl-flet ((say (fmt &rest args)
                (push (concat name ": " (apply #'format fmt args)) out)))
      (cond
       ((null frozen)
        (say "is not in %s"
             (file-name-nondirectory (cmacs-wire-schema-file))))
       ((null entry)
        (say "is frozen (from %s) but no registry tool has that name"
             (alist-get 'source frozen)))
       (t
        (let* ((was (cmacs-wire-schema-params name))
               (now (plist-get entry :params))
               (n (max (length was) (length now))))
          (dotimes (i n)
            (let ((a (nth i was)) (b (nth i now)))
              (unless (and a b
                           (equal (plist-get a :name) (plist-get b :name))
                           (equal (plist-get a :type) (plist-get b :type))
                           (eq (and (plist-get a :required) t)
                               (and (plist-get b :required) t)))
                (say "parameter %d was %s, is now %s" (1+ i)
                     (cmacs-wire-schema--param-text a)
                     (cmacs-wire-schema--param-text b)))
              (when (and a b enum
                         (equal (plist-get a :name) (plist-get b :name))
                         (not (equal (plist-get a :enum)
                                     (plist-get b :enum))))
                (say "parameter `%s' allowed %S, now allows %S"
                     (plist-get a :name) (plist-get a :enum)
                     (plist-get b :enum)))
              (when (and a b param-descriptions
                         (plist-get a :description)
                         (not (if (eq param-descriptions 'words)
                                  (equal (cmacs-wire-schema--words
                                          (plist-get a :description))
                                         (cmacs-wire-schema--words
                                          (plist-get b :description)))
                                (equal (plist-get a :description)
                                       (plist-get b :description)))))
                (say "parameter `%s' was described as %S, is now %S"
                     (plist-get a :name) (plist-get a :description)
                     (plist-get b :description))))))
        (let ((was (alist-get 'description frozen))
              (now (plist-get entry :description)))
          (when (and description
                     (not (if (eq description 'words)
                              (equal (cmacs-wire-schema--words was)
                                     (cmacs-wire-schema--words now))
                            (equal was now))))
            (say "description was %S, is now %S" was now)))
        (when (and hints
                   (not (eq (cmacs-wire-schema-read-only-p name)
                            (not (plist-get entry :destructive)))))
          (say "was published %s, is now %s"
               (if (cmacs-wire-schema-read-only-p name)
                   "read-only" "without readOnlyHint")
               (if (plist-get entry :destructive)
                   ":destructive" "not :destructive (so read-only)"))))))
    (nreverse out)))

(defun cmacs-wire-schema-should-match (name &rest keys)
  "Fail the running test unless registry tool NAME matches its frozen entry.
KEYS are those of `cmacs-wire-schema-differences'.  The failure lists
every difference, one per line."
  (when-let* ((differences (apply #'cmacs-wire-schema-differences name keys)))
    (ert-fail (list (mapconcat #'identity differences "\n")))))


;;;; Writing the file

(defun cmacs-wire-schema--emit (value indent)
  "Insert VALUE as JSON at point, nested INDENT levels deep.
VALUE is what `json-parse-string' gives with alists and vectors.  Object
members keep their order: a parameter's position is part of the wire
schema, and a sorted object would lose it.  One member or element per
line, so a changed parameter is a changed line in a diff."
  (let ((pad (make-string (* 2 (1+ indent)) ?\s))
        (close (make-string (* 2 indent) ?\s)))
    (cond
     ((eq value t) (insert "true"))
     ((eq value :false) (insert "false"))
     ((eq value :null) (insert "null"))
     ((stringp value) (insert (json-serialize value)))
     ((numberp value) (insert (json-serialize value)))
     ((vectorp value)
      (if (zerop (length value))
          (insert "[]")
        ;; An array of scalars stays on one line: `required' and `enum'
        ;; read better that way and still diff as one line.
        (if (cl-every (lambda (v) (or (stringp v) (numberp v))) value)
            (progn
              (insert "[")
              (insert (mapconcat #'json-serialize value ", "))
              (insert "]"))
          (insert "[\n")
          (let ((first t))
            (seq-doseq (v value)
              (unless first (insert ",\n"))
              (setq first nil)
              (insert pad)
              (cmacs-wire-schema--emit v (1+ indent))))
          (insert "\n" close "]"))))
     ((listp value)                     ; an object; nil is {}
      (if (null value)
          (insert "{}")
        (insert "{\n")
        (let ((first t))
          (dolist (member value)
            (unless first (insert ",\n"))
            (setq first nil)
            (insert pad (json-serialize (symbol-name (car member))) ": ")
            (cmacs-wire-schema--emit (cdr member) (1+ indent))))
        (insert "\n" close "}")))
     (t (error "Cannot write %S as JSON" value)))))

(defconst cmacs-wire-schema--header
  ["The MCP wire schema, frozen.  Read by test/cmacs/cmacs-wire-schema.el."
   "Each block is what tools/list returned for one tool while it was a hand-written C handler: name, description, inputSchema and annotations exactly as a client received them (annotations is absent when the C set no hint, which a client reads as not read-only)."
   "`source' is the C file that registered it, `order' its position in that file, `ifdef' the configure flags the registration was compiled under.  A client never saw those three."
   "This file is edited on purpose and never regenerated wholesale.  Changing a published tool's parameters means editing its block in the same commit.  A new tool is added with cmacs-wire-schema-freeze-registry-tool, or by hand, when it should be held to its schema; tools sorted by name."]
  "The `comment' member written at the top of the file.")

(defun cmacs-wire-schema-write (tools &optional file)
  "Write TOOLS, a list of entry alists, as the frozen schema FILE.
Sorted by name, one member per line.  Entries are alists as
`cmacs-wire-schema-tool' returns them, except that arrays are vectors."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file (or file (cmacs-wire-schema-file))
      (cmacs-wire-schema--emit
       `((comment . ,cmacs-wire-schema--header)
         (version . 1)
         (tools . ,(vconcat (sort (copy-sequence tools)
                                  (lambda (a b)
                                    (string< (alist-get 'name a)
                                             (alist-get 'name b)))))))
       0)
      (insert "\n")))
  (setq cmacs-wire-schema--cache nil))

(defun cmacs-wire-schema--file-vectors ()
  "Return the file's tools with arrays as vectors, ready to write back."
  (with-temp-buffer
    (insert-file-contents (cmacs-wire-schema-file))
    (append (alist-get 'tools
                       (json-parse-buffer :object-type 'alist
                                          :array-type 'array
                                          :null-object :null
                                          :false-object :false))
            nil)))

(defun cmacs-wire-schema-freeze-registry-tool (name)
  "Add the registry tool NAME to the frozen file, or replace its entry.
This is the deliberate act the file's header asks for: run it for a new
tool that must keep its schema, or after an intended wire change, and
commit the diff.  The entry is built from the registry's own description
in the shape the MCP publisher sends (type and description for a
parameter; a structured parameter's full schema is not frozen, only its
type)."
  (interactive "sFreeze tool (wire name): ")
  (let* ((entry (or (cmacs-capability-describe-tool name)
                    (error "No registry tool is called `%s'" name)))
         (params (plist-get entry :params))
         (tool
          `((name . ,name)
            (source . "registry")
            (order . 0)
            (ifdef . [])
            (description . ,(plist-get entry :description))
            ,@(unless (plist-get entry :destructive)
                '((annotations . ((readOnlyHint . t)
                                  (destructiveHint . :false)))))
            (inputSchema
             . ((type . "object")
                (properties
                 . ,(mapcar (lambda (p)
                              (cons (intern (plist-get p :name))
                                    `((type . ,(plist-get p :type))
                                      (description
                                       . ,(or (plist-get p :description)
                                              "")))))
                            params))
                (required
                 . ,(vconcat (cl-loop for p in params
                                      when (plist-get p :required)
                                      collect (plist-get p :name)))))))))
    (cmacs-wire-schema-write
     (cons tool (seq-remove (lambda (old) (equal (alist-get 'name old) name))
                            (cmacs-wire-schema--file-vectors))))
    name))


;;;; Freezing the C (how the file was made)

(defun cmacs-wire-schema--rpc (socket requests timeout)
  "Send REQUESTS to the MCP server on SOCKET; return the replies' text.
One connection; a request with an :id is answered before the next goes.
The server may be this very Emacs: its GLib sources are dispatched from
the `accept-process-output' this waits in."
  (let* ((buffer (generate-new-buffer " *cmacs-wire-schema*" t))
         (closed nil) (replies nil)
         (proc (make-network-process
                :name "cmacs-wire-schema" :buffer buffer :family 'local
                :service socket :coding 'no-conversion :noquery t
                :sentinel (lambda (p _e)
                            (unless (process-live-p p) (setq closed t))))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (set-buffer-multibyte nil))
          (dolist (request requests)
            (process-send-string proc (concat (json-serialize request) "\n"))
            (when-let* ((id (plist-get request :id)))
              (let ((deadline (+ (float-time) timeout)) reply)
                (while (and (not reply) (not closed)
                            (< (float-time) deadline))
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (while (and (not reply) (search-forward "\n" nil t))
                      (let ((line (decode-coding-string
                                   (buffer-substring (point-min) (1- (point)))
                                   'utf-8)))
                        (delete-region (point-min) (point))
                        (goto-char (point-min))
                        (when (equal id (alist-get
                                         'id (ignore-errors
                                               (json-parse-string
                                                line :object-type 'alist))))
                          (setq reply line)))))
                  (unless reply (accept-process-output proc 0.05)))
                (unless reply
                  (error "No answer to %s" (plist-get request :method)))
                (push reply replies))))
          (nreverse replies))
      (delete-process proc)
      (kill-buffer buffer))))

(defun cmacs-wire-schema--c-origin (name root)
  "Return (FILE ORDER FLAGS) for the C registration of tool NAME under ROOT.
FILE is the base name of the cmacs/mcp file holding the name as a string
literal, ORDER the literal's position in it, FLAGS the HAVE_CMACS_*
conditions in force there together with the one the file's register
function is called under in cmacs-mcp-tools.c."
  (let ((literal (concat "\"" name "\""))
        (found nil))
    (dolist (file (directory-files (expand-file-name "cmacs/mcp" root) t
                                   "\\`cmacs-mcp-tools-.*\\.c\\'"))
      (unless (or found (string-suffix-p "-brigade.c" file))
        (with-temp-buffer
          (insert-file-contents file)
          (when (search-forward literal nil t)
            (let ((at (match-beginning 0)) (stack nil))
              (goto-char (point-min))
              (while (re-search-forward
                      "^#[ \t]*\\(ifdef\\|if\\|endif\\)\\(.*\\(?:\\\\\n.*\\)*\\)"
                      at t)
                (if (equal (match-string 1) "endif")
                    (pop stack)
                  (let ((flags nil) (text (match-string 2)) (pos 0))
                    (while (string-match "HAVE_CMACS_[A-Z0-9_]+" text pos)
                      (push (match-string 0 text) flags)
                      (setq pos (match-end 0)))
                    (push (nreverse flags) stack))))
              (setq found
                    (list (file-name-nondirectory file) at
                          (delete "HAVE_CMACS_MCP"
                                  (delete-dups
                                   (apply #'append (reverse stack)))))))))))
    (when found
      ;; The flag the whole file is registered under.
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "cmacs/mcp/cmacs-mcp-tools.c" root))
        (let ((family (and (string-match "cmacs-mcp-tools-\\(.*\\)\\.c"
                                         (car found))
                           (match-string 1 (car found)))))
          (when (re-search-forward
                 (format "^#ifdef \\(HAVE_CMACS_[A-Z0-9_]+\\)\n  cmacs_mcp_tools_%s_register"
                         (regexp-quote family))
                 nil t)
            (setf (nth 2 found)
                  (delete-dups (cons (match-string 1) (nth 2 found))))))))
    found))

(defun cmacs-wire-schema-freeze (root &optional file)
  "Freeze the C tools of this Emacs's MCP server into FILE.
ROOT is the source tree, read for each tool's `source' and `ifdef'.

Must run in a batch Emacs that has NOT loaded the tool registry, with a
private XDG_RUNTIME_DIR: it stops the registry from ever loading (so the
publisher has nothing to put in place of a C tool), starts the MCP
server, and asks it for tools/list as any client would.  What comes back
is the C's schema, as sent.

This is how test/cmacs/data/mcp-wire-schema.json was made, once, before
the migrated handlers were deleted.  Run now it sees only the tools that
are still C, so it must not be pointed at the checked-in file: pass
another FILE and compare."
  (when (or (featurep 'cmacs-brigade-registry)
            (featurep 'cmacs-brigade-tools))
    (error "The tool registry is loaded; the server would not answer as C"))
  (unless file
    (error "Name the file to write; the checked-in one is never regenerated"))
  ;; `require' of either is now a no-op, which is all the publisher does.
  (provide 'cmacs-brigade)
  (provide 'cmacs-brigade-tools)
  (cmacs-mcp-start)
  (let* ((replies
          (unwind-protect
              (cmacs-wire-schema--rpc
               (cmacs-mcp-socket-path)
               (list (list :jsonrpc "2.0" :id 1 :method "initialize"
                           :params (list :protocolVersion "2024-11-05"
                                         :capabilities (make-hash-table)
                                         :clientInfo
                                         (list :name "cmacs-wire-schema"
                                               :version "1")))
                     (list :jsonrpc "2.0"
                           :method "notifications/initialized")
                     (list :jsonrpc "2.0" :id 2 :method "tools/list"))
               60)
            (cmacs-mcp-stop)))
         (result (alist-get 'result
                            (json-parse-string
                             (nth 1 replies) :object-type 'alist
                             :array-type 'array :null-object :null
                             :false-object :false)))
         (tools nil))
    (when (alist-get 'nextCursor result)
      (error "tools/list was paginated; this reads one page"))
    (seq-doseq (tool (alist-get 'tools result))
      (let* ((name (alist-get 'name tool))
             ;; A legacy `lrg_editor_X' is registered by a loop, from
             ;; the `lrgeditor_X' row; it has no literal of its own.
             (origin (or (cmacs-wire-schema--c-origin name root)
                         (and (string-prefix-p "lrg_editor_" name)
                              (cmacs-wire-schema--c-origin
                               (concat "lrgeditor_"
                                       (substring name
                                                  (length "lrg_editor_")))
                               root))
                         (error "No C file registers `%s'" name))))
        (push `((name . ,name)
                (source . ,(nth 0 origin))
                (order . ,(nth 1 origin))
                (ifdef . ,(vconcat (nth 2 origin)))
                (description . ,(alist-get 'description tool))
                ,@(when (assq 'annotations tool)
                    `((annotations . ,(alist-get 'annotations tool))))
                (inputSchema . ,(alist-get 'inputSchema tool)))
              tools)))
    ;; `order' as a rank within the file, not a byte offset: an offset
    ;; would change with every unrelated edit to the C.
    (let ((by-file (seq-group-by (lambda (tool) (alist-get 'source tool))
                                 tools)))
      (dolist (group by-file)
        (let ((rank 0))
          (dolist (tool (sort (copy-sequence (cdr group))
                              (lambda (a b)
                                (or (< (alist-get 'order a)
                                       (alist-get 'order b))
                                    (and (= (alist-get 'order a)
                                            (alist-get 'order b))
                                         (string< (alist-get 'name a)
                                                  (alist-get 'name b)))))))
            (setf (alist-get 'order tool) (cl-incf rank))))))
    (cmacs-wire-schema-write tools file)
    (length tools)))

(provide 'cmacs-wire-schema)

;;; cmacs-wire-schema.el ends here
