;;; cmacs-project-tools.el --- The workspace tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The five tools of cmacs/mcp/cmacs-mcp-tools-project.c and the
;; `project_grep' of cmacs-mcp-tools-edit.c, written once
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Same wire names,
;; same parameters, same result text, same limits: a file over 2 MB is
;; refused, `project_find_files' returns 500 paths, `project_grep' 200
;; hits.
;;
;; The confinement is the C's, form for form
;; (`cmacs-project-tools--resolve'): a path is resolved against the
;; workspace root -- `cmacs-mcp-workspace-root', else the project.el
;; root, else `default-directory' -- and refused when its true name is
;; not under the root's true name, unless `cmacs-mcp-workspace-confine'
;; has been set to nil.  `project_grep' takes a directory of its own and
;; was never confined; it still is not.
;;
;; What differs, on purpose:
;;
;;   - `project_grep' ran `call-process' and waited.  A tool call under
;;     `emacs --gowl' runs on the compositor's thread, where a grep over
;;     a slow mount is a frozen desktop, so it is an :async tool here:
;;     grep runs as a subprocess and the answer is delivered from its
;;     sentinel.  It refuses a remote directory rather than start a
;;     Tramp connection from a tool call.
;;
;;   - Redaction (cmacs-redact.el).  A file the rules exclude is not
;;     read, not listed, not found and not grepped.  `project_read_file'
;;     answers it with the message an unreadable file gets.
;;
;;   - `project_write_file' is :destructive (it was in C) and :confirm
;;     'ask, which is how `cmacs-brigade-auto-approve' has always
;;     described it.  It will not write a file the rules exclude either:
;;     overwriting something is no safer than reading it.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-file-hidden-p "cmacs-core-tools"
                  (file &optional project))
(declare-function project-root "project" (project))

(defconst cmacs-project-tools-read-limit 2000000
  "Bytes above which `project_read_file' refuses a file.")

(defconst cmacs-project-tools-find-limit 500
  "The most paths `project_find_files' returns.")

(defconst cmacs-project-tools-grep-limit 200
  "The most hits `project_grep' returns.")

(defcustom cmacs-project-tools-grep-timeout 60
  "Seconds `project_grep' lets grep run before stopping it.
What was found by then is returned."
  :type 'integer
  :group 'cmacs)

(defun cmacs-project-tools--root ()
  "Return the workspace root as a directory name.
`cmacs-mcp-workspace-root' when set, else the project.el root of the
current project, else `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (bound-and-true-p cmacs-mcp-workspace-root)
        (and (fboundp 'project-current)
             (let ((p (ignore-errors (project-current nil))))
               (and p (project-root p))))
        default-directory))))

(defun cmacs-project-tools--resolve (path)
  "Resolve PATH against the workspace root; return (ROOT . TARGET).
Signals when TARGET escapes ROOT, unless `cmacs-mcp-workspace-confine'
is bound and nil.  True names are compared, so a symlink inside the
workspace that points out of it is an escape."
  (let* ((root (cmacs-project-tools--root))
         (target (expand-file-name path root)))
    (unless (and (boundp 'cmacs-mcp-workspace-confine)
                 (null (symbol-value 'cmacs-mcp-workspace-confine)))
      (let ((rt (file-truename root))
            (tt (file-truename target)))
        (unless (or (string-prefix-p rt tt)
                    (string= (directory-file-name rt)
                             (directory-file-name tt)))
          (error "path escapes workspace root"))))
    (cons root target)))

(defun cmacs-project-tools--hidden-p (file root)
  "Non-nil when the redaction rules exclude FILE of the workspace ROOT."
  (cmacs-core-tools-file-hidden-p file root))

(cmacs-brigade-deftool project-root
  "Return the absolute path of the workspace root (the open \
project directory) that the other project_* tools resolve \
paths against."
    ()
  :group 'project
  :example "emacsctl tool project root"
  (cmacs-project-tools--root))

(cmacs-brigade-deftool project-read-file
  "Read a file from the workspace. The path is relative to the \
workspace root (absolute paths must still resolve inside it). \
Returns the raw file contents."
    ((path string "File path relative to the workspace root"))
  :group 'project
  :example "emacsctl tool project read-file --path README.org"
  (require 'cmacs-core-tools)
  (unless (stringp path)
    (error "Missing required argument: path"))
  (pcase-let ((`(,root . ,target) (cmacs-project-tools--resolve path)))
    ;; Excluded and unreadable are one answer.
    (unless (and (file-readable-p target)
                 (not (cmacs-project-tools--hidden-p target root)))
      (error "file not readable: %s" target))
    (let ((sz (file-attribute-size (file-attributes target))))
      (when (and sz (> sz cmacs-project-tools-read-limit))
        (error "file too large: %d bytes" sz))
      (with-temp-buffer
        (insert-file-contents target)
        (buffer-substring-no-properties (point-min) (point-max))))))

(cmacs-brigade-deftool project-write-file
  "Write a file in the workspace, creating parent directories as \
needed. The path is resolved against the workspace root and \
cannot escape it. Overwrites any existing file."
    ((path string "File path relative to the workspace root")
     (content string "Full new file contents"))
  :group 'project :destructive t :confirm 'ask
  (require 'cmacs-core-tools)
  (unless (and (stringp path) (stringp content))
    (error "Missing required arguments: path, content"))
  (pcase-let ((`(,root . ,target) (cmacs-project-tools--resolve path)))
    (when (cmacs-project-tools--hidden-p target root)
      (error "file not writable: %s" target))
    (make-directory (file-name-directory target) t)
    (with-temp-buffer
      (insert content)
      (let ((bytes (string-bytes (buffer-string))))
        (write-region (point-min) (point-max) target nil 'quiet)
        (cmacs-core-tools-print
         (format "wrote %d bytes to %s"
                 bytes (file-relative-name target root)))))))

(cmacs-brigade-deftool project-list-files
  "List the immediate entries of a workspace directory (defaults \
to the workspace root). Directories are suffixed with '/'; \
files are followed by a tab and their size in bytes."
    ((directory string "Directory relative to the workspace root \
\(optional)" :optional t))
  :group 'project
  (require 'cmacs-core-tools)
  (pcase-let ((`(,root . ,target)
               (cmacs-project-tools--resolve (or directory "."))))
    (unless (and (file-directory-p target)
                 (not (cmacs-project-tools--hidden-p target root)))
      (error "not a directory: %s" target))
    (let ((entries
           (seq-remove
            (lambda (f)
              (or (member f '("." ".."))
                  (cmacs-project-tools--hidden-p
                   (expand-file-name f target) root)))
            (directory-files target))))
      (if entries
          (mapconcat
           (lambda (f)
             (let ((full (expand-file-name f target)))
               (if (file-directory-p full)
                   (concat f "/")
                 (format "%s\t%d" f
                         (or (file-attribute-size (file-attributes full))
                             0)))))
           (sort entries #'string<) "\n")
        "(empty directory)"))))

(cmacs-brigade-deftool project-find-files
  "Recursively find files in the workspace whose name matches an \
Emacs regexp (e.g. \"\\\\.c\\\\'\" for C files). The .git \
directory is skipped; up to 500 paths are returned relative \
to the workspace root."
    ((pattern string "Emacs regexp matched against file names"))
  :group 'project
  (require 'cmacs-core-tools)
  (unless (stringp pattern)
    (error "Missing required argument: pattern"))
  (pcase-let ((`(,root . ,_target) (cmacs-project-tools--resolve ".")))
    (let ((hits (seq-remove
                 (lambda (f) (cmacs-project-tools--hidden-p f root))
                 (directory-files-recursively
                  root pattern nil
                  (lambda (d)
                    ;; Not descended into: the repository's own store,
                    ;; and any directory the rules exclude.
                    (not (or (string-match-p "\\.git\\'" d)
                             (cmacs-project-tools--hidden-p d root))))))))
      (if hits
          (mapconcat (lambda (f) (file-relative-name f root))
                     (seq-take hits cmacs-project-tools-find-limit) "\n")
        "(no matches)"))))


;;;; project_grep

(defun cmacs-project-tools--grep-result (output directory)
  "Turn grep's OUTPUT, run in DIRECTORY, into the tool's answer.
Hits in files the redaction rules exclude are dropped before the limit
is applied, so they do not use up the 200 a caller is given."
  (let ((lines nil) (n 0))
    (dolist (line (split-string output "\n" t))
      (when (< n cmacs-project-tools-grep-limit)
        ;; "-rn" prints FILE:LINE:TEXT.  A line that is not of that
        ;; shape (grep's own "Binary file ..." notes are suppressed by
        ;; -I, but be exact) names no file and is kept as it is.
        (let ((file (and (string-match "\\`\\(.+?\\):[0-9]+:" line)
                         (match-string 1 line))))
          (unless (and file
                       (cmacs-core-tools-file-hidden-p
                        (expand-file-name file directory) directory))
            (push line lines)
            (setq n (1+ n))))))
    (cmacs-core-tools-print
     (if lines
         (mapconcat #'identity (nreverse lines) "\n")
       "(no matches)"))))

(defun cmacs-project-tools--grep (done regexp directory file-glob)
  "Run grep for REGEXP under DIRECTORY and call DONE with the answer.
FILE-GLOB, when non-nil, restricts the files searched.  Never waits:
the answer is delivered from the process sentinel, and a failure after
this function has returned is delivered as an \"Error: ...\" string,
which is how an :async tool reports one."
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         ;; Dynamic, for `make-process' alone.  The sentinel runs later
         ;; under whatever `default-directory' is current then, which is
         ;; why it uses DIR.
         (default-directory dir)
         (output (generate-new-buffer " *cmacs-project-grep*" t))
         (timer nil)
         (process
          (condition-case err
              (make-process
               :name "cmacs-project-grep"
               :buffer output
               :noquery t
               :connection-type 'pipe
               ;; Arguments are a list: nothing is passed through a
               ;; shell, and "-e" keeps a pattern that begins with a
               ;; dash from being read as an option.
               :command (append (list "grep" "-rIn" "--exclude-dir=.git")
                                (and file-glob
                                     (list (concat "--include=" file-glob)))
                                (list "-e" regexp "."))
               :sentinel
               (lambda (proc _event)
                 (unless (process-live-p proc)
                   (when (timerp timer) (cancel-timer timer))
                   (unwind-protect
                       (funcall
                        done
                        (condition-case err
                            (cmacs-project-tools--grep-result
                             (if (buffer-live-p output)
                                 (with-current-buffer output
                                   (buffer-string))
                               "")
                             dir)
                          (error (format "Error: %s"
                                         (error-message-string err)))))
                     (when (buffer-live-p output)
                       (kill-buffer output))))))
            ;; grep missing, or no process to be had: nothing was
            ;; started, so this is still an ordinary signalled error.
            (error (kill-buffer output)
                   (signal (car err) (cdr err))))))
    ;; A search that outlives the timeout is stopped; its sentinel then
    ;; answers with what had been found.
    (setq timer (run-at-time cmacs-project-tools-grep-timeout nil
                             (lambda ()
                               (when (process-live-p process)
                                 (delete-process process)))))
    nil))

(cmacs-brigade-deftool project-grep
  "Recursively grep for a pattern under a directory (defaults to \
the current default-directory; .git is excluded). Returns up to \
200 'file:line:text' hits."
    ((regexp string "Basic grep regexp")
     (directory string "Root directory to search (optional)" :optional t)
     (file-glob string "Restrict to files matching this glob (optional)"
                :optional t))
  :group 'project :async t :timeout 90
  :example "emacsctl tool project grep --regexp TODO --file-glob '*.el'"
  (require 'cmacs-core-tools)
  (unless (stringp regexp)
    (error "Missing required argument: regexp"))
  (let ((root (expand-file-name (or directory default-directory))))
    (when (file-remote-p root)
      (error "project_grep does not search remote directories"))
    (unless (file-directory-p root)
      (error "not a directory: %s" root))
    (cmacs-project-tools--grep done regexp root file-glob)))

(provide 'cmacs-project-tools)

;;; cmacs-project-tools.el ends here
