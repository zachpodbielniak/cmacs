;;; cmacs-perf-pty.el --- run a command in a sized pseudo-terminal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The TUI frontend of cmacs-perf: a TUI workload needs a real
;; `emacs -nw' frame, so it needs a terminal, and the driver runs headless.
;; This batch script is that terminal.  It starts a command on a fresh
;; pseudo-terminal of a fixed size, keeps the master side drained (an
;; undrained pty blocks the child's redisplay inside write(2) and turns
;; a benchmark into a deadlock), saves the raw byte stream for
;; inspection, and exits with the child's exit status.
;;
;; Emacs is used instead of script(1) because util-linux ships `script'
;; in a separate package that an immutable host may not have, and the
;; Emacs under test is always present.  The driver Emacs is not measured:
;; perf runs inside the pty and counts only its own child.
;;
;; Usage:
;;   emacs -Q --batch -l cmacs-perf-pty.el -- ROWS COLS LOG TIMEOUT CMD ARG...
;;
;; The `--' matters: without it the driver Emacs parses the child's own
;; options (`-Q', `-nw', an `env -u' read as `--user') as its own.
;;
;; TIMEOUT is in seconds; when it elapses the child is killed and the
;; script exits 124, like timeout(1).

;;; Code:

(defun cmacs-perf-pty--main ()
  "Run the command in `command-line-args-left' in a pseudo-terminal."
  (let* ((args (if (equal (car command-line-args-left) "--")
                   (cdr command-line-args-left)
                 command-line-args-left))
         (rows (string-to-number (pop args)))
         (cols (string-to-number (pop args)))
         (log-file (pop args))
         (timeout (string-to-number (pop args)))
         (deadline (+ (float-time) timeout))
         (log-buffer (generate-new-buffer " *cmacs-perf-pty*"))
         (process nil)
         (status 2))
    (setq command-line-args-left nil)
    (unless (and (> rows 0) (> cols 0) log-file (> timeout 0) args)
      (message "usage: cmacs-perf-pty.el ROWS COLS LOG TIMEOUT CMD ARG...")
      (kill-emacs 2))
    (with-current-buffer log-buffer
      (set-buffer-multibyte nil))
    ;; The child reads its size from the pty when it starts, which can
    ;; be before a `set-process-window-size' from this side reaches the
    ;; pty -- `emacs -nw' came up 32x65 that way.  So the size is set
    ;; from INSIDE: a shell runs stty on its own terminal, then execs
    ;; the command, which therefore always starts at ROWS x COLS.
    (setq process
          (make-process
           :name "cmacs-perf-pty-child"
           :command (append
                     (list "sh" "-c"
                           (format "stty rows %d cols %d && exec \"$@\""
                                   rows cols)
                           "cmacs-perf-pty")
                     args)
           :connection-type 'pty
           :coding 'binary
           :noquery t
           :filter (lambda (_process output)
                     (with-current-buffer log-buffer
                       (goto-char (point-max))
                       (insert output)))))
    ;; Drain until the child exits or the deadline passes.
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.5))
    (if (process-live-p process)
        (progn
          (message "cmacs-perf-pty: %s timed out after %d s"
                   (car args) timeout)
          (delete-process process)
          (setq status 124))
      ;; Collect output that arrived between the last read and the exit.
      (accept-process-output process 0.1)
      (setq status (process-exit-status process)))
    (with-current-buffer log-buffer
      (let ((coding-system-for-write 'binary))
        (write-region nil nil log-file nil 'silent)))
    (kill-emacs status)))

(cmacs-perf-pty--main)

;;; cmacs-perf-pty.el ends here
