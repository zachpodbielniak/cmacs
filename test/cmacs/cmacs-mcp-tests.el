;;; cmacs-mcp-tests.el --- Tests for the MCP server  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The listening socket is a real file in $XDG_RUNTIME_DIR, and for a
;; long time nothing removed it: stopping the server closed the listener
;; and left the inode, so a machine collected one dead
;; cmacs-mcp-<pid>.sock per session ever run.  One real directory had 97.
;;
;; There are three ways they are left behind and three ways they are
;; cleaned, so all three are tested: a clean stop, an exit that never
;; stopped, and a crash that reached neither.

;;; Code:

(require 'ert)

(defconst cmacs-mcp-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, captured at load: `load-file-name' is nil by the
time a test body runs.")

(defun cmacs-mcp-tests--available-p ()
  (and (fboundp 'cmacs-mcp-start) (fboundp 'cmacs-mcp-socket-path)))

(ert-deftest cmacs-mcp-stop-removes-its-socket ()
  "A clean stop takes the file with it, not just the listener."
  (skip-unless (cmacs-mcp-tests--available-p))
  (cmacs-mcp-start)
  (let ((path (cmacs-mcp-socket-path)))
    (should (stringp path))
    (should (file-exists-p path))
    (cmacs-mcp-stop)
    (should-not (file-exists-p path))))

(ert-deftest cmacs-mcp-restart-reuses-a-clean-path ()
  "Starting again after a stop works, and leaves one socket behind it."
  (skip-unless (cmacs-mcp-tests--available-p))
  (cmacs-mcp-start)
  (let ((first (cmacs-mcp-socket-path)))
    (cmacs-mcp-stop)
    (cmacs-mcp-start)
    (let ((second (cmacs-mcp-socket-path)))
      ;; same pid, so the same path -- which is exactly the case that
      ;; fails if the previous inode was left lying around
      (should (equal first second))
      (should (file-exists-p second))
      (cmacs-mcp-stop)
      (should-not (file-exists-p second)))))

(ert-deftest cmacs-mcp-start-sweeps-sockets-of-dead-processes ()
  "A start clears sockets whose owning process is gone.

The crash path reaches neither the stop nor the atexit handler, so the
sweep is the only thing that ever removes those -- and the only thing
that clears a machine which has already accumulated them."
  (skip-unless (cmacs-mcp-tests--available-p))
  (let* ((dir (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
         ;; A pid that cannot be running: above the system maximum.
         (dead (expand-file-name "cmacs-mcp-4194303.sock" dir))
         ;; Not ours to remove: right prefix, wrong shape.
         (decoy (expand-file-name "cmacs-mcp-notapid.sock" dir))
         (unrelated (expand-file-name "cmacs-mcp-4194303.sock.bak" dir)))
    (unwind-protect
        (progn
          (dolist (f (list dead decoy unrelated))
            (with-temp-file f (insert "")))
          (cmacs-mcp-start)
          (should-not (file-exists-p dead))
          ;; only the exact cmacs-mcp-<digits>.sock shape is swept
          (should (file-exists-p decoy))
          (should (file-exists-p unrelated))
          ;; and the live one it just made is untouched
          (should (file-exists-p (cmacs-mcp-socket-path)))
          (cmacs-mcp-stop))
      (dolist (f (list dead decoy unrelated))
        (ignore-errors (delete-file f))))))

(ert-deftest cmacs-mcp-sweep-keeps-a-live-instance ()
  "Another running cmacs is a normal thing to find, and is left alone."
  (skip-unless (cmacs-mcp-tests--available-p))
  (let* ((dir (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
         ;; This process is certainly alive.
         (live (expand-file-name (format "cmacs-mcp-%d.sock.keep" (emacs-pid))
                                 dir))
         (other (expand-file-name "cmacs-mcp-1.sock" dir)))
    (unwind-protect
        (progn
          (with-temp-file live (insert ""))
          ;; pid 1 is init: alive on any system this runs on
          (with-temp-file other (insert ""))
          (cmacs-mcp-start)
          (should (file-exists-p other))
          (cmacs-mcp-stop))
      (dolist (f (list live other))
        (ignore-errors (delete-file f))))))


;;;; Missing tool arguments

(ert-deftest cmacs-mcp-missing-argument-is-an-error-not-a-critical ()
  "A tool called without a required argument answers, quietly.

Arguments come from a model, so a missing one is ordinary input, not a
programming error.  `json_object_get_string_member' asserts when the
member is absent -- it still returns NULL, so the handlers behaved
correctly, but every such call logged a Json-CRITICAL, which is fatal
under G_DEBUG=fatal-criticals.  The handlers now use the with-default
form, which returns NULL for an absent *or* null member without
complaining."
  (skip-unless (cmacs-mcp-tests--available-p))
  (let ((file (expand-file-name "cmacs/mcp" cmacs-mcp-tests--root)))
    (skip-unless (file-directory-p file))
    ;; Asserted against the sources: the criticals happen in a live
    ;; session against a running server, which ERT cannot observe.
    (let ((offenders nil))
      (dolist (f (directory-files file t "\\.c\\'"))
        (with-temp-buffer
          (insert-file-contents f)
          (goto-char (point-min))
          (while (re-search-forward
                  "json_object_get_string_member ([^)]*\"" nil t)
            ;; A literal key with no has_member guard on the same line is
            ;; the shape that logs.
            (let ((line (buffer-substring (line-beginning-position)
                                          (line-end-position))))
              (unless (string-match-p "has_member" line)
                (push (format "%s: %s" (file-name-nondirectory f)
                              (string-trim line))
                      offenders))))))
      (should (equal nil offenders)))))

(provide 'cmacs-mcp-tests)

;;; cmacs-mcp-tests.el ends here
