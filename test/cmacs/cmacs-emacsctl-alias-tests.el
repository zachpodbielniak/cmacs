;;; cmacs-emacsctl-alias-tests.el --- emacsctl's verb aliases name real tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `emacsctl calc eval', `emacsctl gsurf open' and about a hundred more
;; verbs are aliases: a row in cmacs/emacsctl/ctl-cmd-alias.c names the
;; registry tool the verb calls and the tool parameter each positional
;; argument becomes.  emacsctl runs an alias without asking the editor
;; what its tools are, so nothing at run time notices a row that names a
;; tool that was renamed, a parameter that was dropped, or a tool that
;; was taken off the `cli' surface -- the verb would quietly fall back
;; to its old D-Bus method for ever.
;;
;; The C unit tests (cmacs/emacsctl/tests/test-ctl.c) check everything
;; about a row that needs no registry.  This file is the half they
;; cannot do: it reads the table out of the C source as text and holds
;; each row against the generated capability reference,
;; doc_org/cmacs/cmacs-capability-reference.org -- the same file
;; admin/cmacs-capability-audit.sh reads, kept current by
;; `cmacs-capability-test-reference-is-current'.
;;
;; Nothing here starts emacsctl or talks to an editor.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(defun cmacs-emacsctl-alias-tests--root ()
  "Return the top of the cmacs source tree, or nil when not in one."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "cmacs/emacsctl/ctl-cmd-alias.c")))
    (and dir (expand-file-name dir))))

(defun cmacs-emacsctl-alias-tests--file (relative)
  "Return the text of RELATIVE, a file under the source tree."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name relative (cmacs-emacsctl-alias-tests--root)))
    (buffer-string)))

(defun cmacs-emacsctl-alias-tests--c-string (text)
  "Return the value of TEXT, one or more adjacent C string literals.
NULL is nil."
  (unless (string-match-p "\\`[ \t\n]*NULL[ \t\n]*\\'" text)
    (let ((start 0) (parts nil))
      (while (string-match "\"\\(\\(?:[^\"\\\\]\\|\\\\.\\)*\\)\"" text start)
        (push (match-string 1 text) parts)
        (setq start (match-end 0)))
      (apply #'concat (nreverse parts)))))

(defun cmacs-emacsctl-alias-tests--rows ()
  "Return the alias table as a list of plists, parsed from the C source.
Each is (:tool :params :defaults :format :timeout :verb :iface :method
:argspec).  The row layout this reads is the one the comment at the top
of ctl-cmd-alias.c promises to keep."
  (let ((text (cmacs-emacsctl-alias-tests--file
               "cmacs/emacsctl/ctl-cmd-alias.c"))
        (start 0)
        (rows nil))
    (while (string-match
            (concat
             ;; { "tool", PARAMS, DEFAULTS, CTL_ALIAS_X, SECONDS,
             "^  { \"\\([a-z0-9_]+\\)\", \\(\"[^\"]*\"\\|NULL\\), "
             "\\(\"[^\"]*\"\\|NULL\\), CTL_ALIAS_\\([A-Z_]+\\), "
             "\\([0-9]+\\),\n"
             ;;   { "verb", "summary" ...,
             "    { \"\\([a-z0-9 _-]+\\)\",\\(?:.\\|\n\\)*?"
             ;;     CTL_IFACE_X, "Method", ARGSPEC, CTL_REPLY_Y } },
             "\\(CTL_IFACE_[A-Z_]+\\),[ \n]*\"\\([A-Za-z0-9]+\\)\","
             "\\(\\(?:.\\|\n\\)*?\\),[ \n]*CTL_REPLY_[A-Z_]+ } },")
            text start)
      ;; Everything out of the match data first: the helper below
      ;; matches too.
      (let ((next (match-end 0))
            (m (mapcar (lambda (n) (match-string n text))
                       (number-sequence 0 9))))
        (cl-flet ((words (n)
                    (split-string
                     (or (cmacs-emacsctl-alias-tests--c-string (nth n m))
                         "")
                     " " t)))
          (push (list :tool (nth 1 m)
                      :params (words 2)
                      :defaults (words 3)
                      :format (nth 4 m)
                      :timeout (string-to-number (nth 5 m))
                      :verb (nth 6 m)
                      :iface (nth 7 m)
                      :method (nth 8 m)
                      :argspec (words 9))
                rows))
        (setq start next)))
    (nreverse rows)))

(defun cmacs-emacsctl-alias-tests--reference ()
  "Return the capability reference as a hash table: wire name -> plist.
Each plist is (:surfaces LIST :async-timeout SECONDS-OR-NIL :params
ALIST), :params mapping a parameter name to (TYPE . REQUIRED)."
  (let ((table (make-hash-table :test #'equal))
        (name nil)
        (entry nil))
    (cl-flet ((flush ()
                (when name
                  (puthash name entry table))))
      (dolist (line (split-string
                     (cmacs-emacsctl-alias-tests--file
                      "doc_org/cmacs/cmacs-capability-reference.org")
                     "\n"))
        (cond
         ((string-match "\\`\\*\\* \\([a-z0-9_]+\\)\\'" line)
          (flush)
          (setq name (match-string 1 line)
                entry (list :surfaces nil :async-timeout nil :params nil)))
         ((null name))
         ((string-match "\\`- Surfaces :: \\(.*\\)\\'" line)
          (setq entry (plist-put entry :surfaces
                                 (split-string (match-string 1 line)
                                               ", *" t))))
         ((string-match "\\`- Flags :: .*async (timeout \\([0-9]+\\)s)" line)
          (setq entry (plist-put entry :async-timeout
                                 (string-to-number (match-string 1 line)))))
         ((string-match
           "\\`| =\\([a-z0-9_]+\\)= | \\([^|]*?\\) | \\(yes\\|no\\) |" line)
          (setq entry
                (plist-put entry :params
                           (append (plist-get entry :params)
                                   (list (cons (match-string 1 line)
                                               (cons (match-string 2 line)
                                                     (equal (match-string
                                                             3 line)
                                                            "yes"))))))))))
      (flush))
    table))

(defmacro cmacs-emacsctl-alias-tests--with-tables (&rest body)
  "Run BODY with `rows' and `reference' bound, or skip outside a tree."
  (declare (indent 0))
  `(progn
     (skip-unless (cmacs-emacsctl-alias-tests--root))
     (skip-unless (file-readable-p
                   (expand-file-name
                    "doc_org/cmacs/cmacs-capability-reference.org"
                    (cmacs-emacsctl-alias-tests--root))))
     (let ((rows (cmacs-emacsctl-alias-tests--rows))
           (reference (cmacs-emacsctl-alias-tests--reference)))
       (ignore rows reference)
       ,@body)))

(ert-deftest cmacs-emacsctl-alias-test-table-parses ()
  "The row layout is still the one this file reads.
A reformatted table would otherwise turn every test below into a loop
over nothing."
  (cmacs-emacsctl-alias-tests--with-tables
    (should (> (length rows) 100))
    (should (> (hash-table-count reference) 250))
    ;; Every row the C compiler sees is a row this parser sees: count
    ;; the `CTL_ALIAS_' enum uses in the table.
    (let* ((text (cmacs-emacsctl-alias-tests--file
                  "cmacs/emacsctl/ctl-cmd-alias.c"))
           (table (substring
                   text
                   (string-match "^static const CtlAliasSpec alias_specs"
                                 text)
                   (string-match "^/\\* ── Verbs that stay hand-written"
                                 text)))
           (count 0)
           (start 0))
      (while (string-match ", CTL_ALIAS_[A-Z_]+, [0-9]+,$" table start)
        (setq count (1+ count)
              start (match-end 0)))
      (should (= count (length rows))))
    ;; A known row, field by field.
    (let ((row (cl-find "calc units" rows
                        :key (lambda (r) (plist-get r :verb))
                        :test #'equal)))
      (should row)
      (should (equal (plist-get row :tool) "calc_convert_units"))
      (should (equal (plist-get row :params) '("expression" "units")))
      (should (equal (plist-get row :argspec) '("s:expression" "s?:units")))
      (should (equal (plist-get row :method) "ConvertUnits")))))

(ert-deftest cmacs-emacsctl-alias-test-tools-exist-on-cli ()
  "Every alias names a registry tool that is published on the cli surface.
A tool that is not would be refused by Tools.Call (NotOnSurface) and
the verb would fall back to its old D-Bus method on every run."
  (cmacs-emacsctl-alias-tests--with-tables
    (dolist (row rows)
      (let* ((tool (plist-get row :tool))
             (entry (gethash tool reference)))
        (ert-info ((format "alias `%s' -> tool `%s'"
                           (plist-get row :verb) tool))
          (should entry)
          (should (member "cli" (plist-get entry :surfaces)))
          ;; `cli' travels over D-Bus.
          (should (member "dbus" (plist-get entry :surfaces))))))))

(ert-deftest cmacs-emacsctl-alias-test-parameters-match ()
  "Each positional maps to a parameter the tool has, of a type it takes.
And every parameter the tool requires is one the alias always sends."
  (cmacs-emacsctl-alias-tests--with-tables
    (dolist (row rows)
      (let* ((entry (gethash (plist-get row :tool) reference))
             (tool-params (plist-get entry :params))
             (params (plist-get row :params))
             (argspec (plist-get row :argspec))
             (defaults (mapcar (lambda (pair)
                                 (car (split-string pair "=")))
                               (plist-get row :defaults)))
             (always nil))
        (ert-info ((format "alias `%s' -> tool `%s'"
                           (plist-get row :verb) (plist-get row :tool)))
          (should entry)
          (should (= (length params) (length argspec)))
          (should (equal params (delete-dups (copy-sequence params))))
          (cl-mapc
           (lambda (param spec)
             (let* ((declared (assoc param tool-params))
                    (type (cadr declared))
                    (letter (aref spec 0))
                    (optional (and (> (length spec) 1)
                                   (eq (aref spec 1) ??))))
               (ert-info ((format "positional %s -> parameter `%s'"
                                  spec param))
                 (should declared)
                 ;; The argspec letter decides what JSON the client
                 ;; sends, so it has to be something the parameter's
                 ;; strict D-Bus validation accepts.
                 (should
                  (pcase letter
                    ;; A string of digits is accepted for an integer.
                    (?s (member type '("string" "integer" "number")))
                    ((or ?i ?u ?x ?t) (member type '("integer" "number")))
                    (?d (equal type "number"))
                    (?b (equal type "boolean"))))
                 (when (or (not optional) (member param defaults))
                   (push param always)))))
           params argspec)
          ;; A default only makes sense for a parameter that is sent.
          (dolist (name defaults)
            (should (member name params)))
          (dolist (declared tool-params)
            (when (cddr declared)
              (ert-info ((format "required parameter `%s'" (car declared)))
                (should (member (car declared) always))))))))))

(ert-deftest cmacs-emacsctl-alias-test-async-timeouts-cover-the-tool ()
  "An alias of an asynchronous tool carries at least the tool's timeout.
emacsctl does not fetch the tool list to run an alias, so the row is
the only place the allowance can come from; too small a number and the
client gives up while the tool is still inside its own."
  (cmacs-emacsctl-alias-tests--with-tables
    (dolist (row rows)
      (let ((need (plist-get (gethash (plist-get row :tool) reference)
                             :async-timeout)))
        (ert-info ((format "alias `%s' -> tool `%s'"
                           (plist-get row :verb) (plist-get row :tool)))
          (if need
              (should (>= (plist-get row :timeout) need))
            (should (= (plist-get row :timeout) 0))))))))

(ert-deftest cmacs-emacsctl-alias-test-markers-and-rows-agree ()
  "Each CTL_ALIAS_ROW in a verb table has a row, and each row a marker.
The marker is what registers the verb; a row without one is dead, and a
marker without a row aborts emacsctl at start-up."
  (cmacs-emacsctl-alias-tests--with-tables
    (let ((markers nil)
          (verbs (mapcar (lambda (r) (plist-get r :verb)) rows)))
      (dolist (file (directory-files
                     (expand-file-name "cmacs/emacsctl"
                                       (cmacs-emacsctl-alias-tests--root))
                     t "\\`ctl-cmd-.*\\.c\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (while (re-search-forward
                  "^ *CTL_ALIAS_ROW (\"\\([a-z0-9 _-]+\\)\")," nil t)
            (push (match-string 1) markers))))
      (should (equal (sort (copy-sequence markers) #'string<)
                     (sort (copy-sequence verbs) #'string<)))
      ;; No verb twice, on either side.
      (should (= (length verbs) (length (delete-dups (copy-sequence verbs))))))))

(ert-deftest cmacs-emacsctl-alias-test-fallback-methods-exist ()
  "The D-Bus method an alias falls back to is one cmacs still serves.
The fallback is for a cmacs without the tool, which is an older one --
but a method name that was never served at all is a typo, and this is
the tree where that can be told."
  (cmacs-emacsctl-alias-tests--with-tables
    (let* ((ifaces (cmacs-emacsctl-alias-tests--file
                    "cmacs/emacsctl/ctl-ifaces.h"))
           (served (make-hash-table :test #'equal))
           (root (cmacs-emacsctl-alias-tests--root)))
      ;; Interface.Method for every method in an introspection string.
      (dolist (dir '("cmacs/dbus" "cmacs/glib"))
        (dolist (file (directory-files (expand-file-name dir root) t
                                       "\\.c\\'"))
          (with-temp-buffer
            (insert-file-contents file)
            (let ((iface nil))
              (while (re-search-forward
                      "<\\(interface\\|method\\) name=['\"]\\([A-Za-z0-9.]+\\)"
                      nil t)
                (if (equal (match-string 1) "interface")
                    (setq iface (match-string 2))
                  (when iface
                    (puthash (concat iface "." (match-string 2)) t
                             served))))))))
      (skip-unless (> (hash-table-count served) 100))
      (dolist (row rows)
        (let ((constant (plist-get row :iface)))
          (ert-info ((format "alias `%s'" (plist-get row :verb)))
            (should (string-match
                     (concat "^#define " (regexp-quote constant)
                             "[ \t]+\"\\([^\"]+\\)\"")
                     ifaces))
            (should (gethash (concat (match-string 1 ifaces) "."
                                     (plist-get row :method))
                             served))))))))

(provide 'cmacs-emacsctl-alias-tests)

;;; cmacs-emacsctl-alias-tests.el ends here
