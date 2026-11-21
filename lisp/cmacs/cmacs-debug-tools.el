;;; cmacs-debug-tools.el --- The debug tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The nine tools of cmacs/mcp/cmacs-mcp-tools-debug.c, written once
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Same wire names,
;; same parameters, same `prin1'-printed result text.
;;
;; Two results differ from what the C actually produced, because the C
;; did not produce what it was written to.  `profiler_start' and
;; `profiler_stop' submitted two forms -- "(profiler-start 'cpu)
;; \"Profiler started\"" -- to a dispatch that reads and evaluates only
;; the first, so the message never came back.  Here it does.
;;
;; Redaction (cmacs-redact.el): `recent_messages' is free text the user
;; did not write for a model -- file names, URLs, whatever a command
;; echoed -- and goes through the text rules.
;;
;; `memory_info' runs a garbage collection and `list_hooks' walks the
;; obarray, exactly as before.  Both are bounded but not instant; neither
;; prompts or waits on anything outside the process.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-text "cmacs-core-tools" (string))
(declare-function cmacs-redact-variable-p "cmacs-redact" (symbol))
(declare-function profiler-start "profiler" (mode))
(declare-function profiler-stop "profiler" ())
(declare-function profiler-report-cpu "profiler" ())

(defconst cmacs-debug-tools-default-lines 50
  "How many lines `recent_messages' returns when it is not told.")

(cmacs-brigade-deftool backtrace
  "Get the current Lisp backtrace."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print (with-output-to-string (backtrace))))

(cmacs-brigade-deftool memory-info
  "Get GC statistics and memory usage counts."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (format "GC stats: %S\nMemory use counts: %S"
           (garbage-collect) (memory-use-counts))))

(cmacs-brigade-deftool process-status
  "Get Emacs process info: PID, uptime, version, system type."
    ()
  :group 'debug
  :example "emacsctl tool debug process-status"
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (format "PID: %d\nUptime: %s\nEmacs version: %s\n\
System: %s\nFeatures: %d loaded"
           (emacs-pid)
           (emacs-uptime)
           emacs-version
           system-type
           (length features))))

(cmacs-brigade-deftool recent-messages
  "Get recent entries from the *Messages* buffer."
    ((lines integer "Number of lines to retrieve (default: 50)"
            :optional t :default 50))
  :group 'debug
  (require 'cmacs-core-tools)
  (let ((count (if (integerp lines) lines cmacs-debug-tools-default-lines))
        (messages (get-buffer "*Messages*")))
    (unless messages
      (error "No such buffer: *Messages*"))
    (with-current-buffer messages
      (save-excursion
        (goto-char (point-max))
        (forward-line (- count))
        (cmacs-core-tools-print
         (cmacs-core-tools-text
          (buffer-substring-no-properties (point) (point-max))))))))

(cmacs-brigade-deftool describe-mode
  "Get the current major mode and active minor modes."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  ;; `minor-mode-list' is every minor mode that is defined, not the ones
  ;; switched on, despite what the description says.  It is what the C
  ;; tool returned, and a client may be reading it.
  (cmacs-core-tools-print
   (format "Major mode: %s\nMinor modes: %s"
           (symbol-name major-mode)
           (mapconcat #'symbol-name minor-mode-list " "))))

(cmacs-brigade-deftool list-hooks
  "List all non-nil hook variables and their values."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (require 'cmacs-redact)
  (let (hooks)
    (mapatoms
     (lambda (sym)
       (when (and (boundp sym)
                  (string-suffix-p "-hook" (symbol-name sym))
                  (symbol-value sym)
                  ;; A sensitive variable is not listed at all, value
                  ;; or name: this tool prints values.
                  (not (cmacs-redact-variable-p sym)))
         (push (format "%s: %S" sym (symbol-value sym)) hooks))))
    (cmacs-core-tools-print
     (mapconcat #'identity (sort hooks #'string<) "\n"))))

(cmacs-brigade-deftool profiler-start
  "Start the Emacs CPU profiler."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (require 'profiler)
  ;; Bound because nothing a tool calls may reach a prompt, and this
  ;; call does not always arrive through the dispatch that binds it.
  (let ((inhibit-interaction t))
    (profiler-start 'cpu))
  (cmacs-core-tools-print "Profiler started"))

(cmacs-brigade-deftool profiler-stop
  "Stop the Emacs CPU profiler."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (require 'profiler)
  (profiler-stop)
  (cmacs-core-tools-print "Profiler stopped"))

(cmacs-brigade-deftool profiler-report
  "Get the CPU profiler report."
    ()
  :group 'debug
  (require 'cmacs-core-tools)
  (require 'profiler)
  ;; `profiler-report-cpu' renders the report into a buffer of its own
  ;; and selects it in another window, which is how the text read here
  ;; is the report and not the (empty) temporary buffer.  The window
  ;; configuration is put back afterwards: reading a report is not a
  ;; reason to rearrange the user's frame.
  (save-window-excursion
    (with-temp-buffer
      (profiler-report-cpu)
      (cmacs-core-tools-print
       (buffer-substring-no-properties (point-min) (point-max))))))

(provide 'cmacs-debug-tools)

;;; cmacs-debug-tools.el ends here
