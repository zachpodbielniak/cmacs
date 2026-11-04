;;; cmacs-perf.el --- cmacs-perf workload runtime  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The in-editor half of cmacs-perf, the whole-editor performance
;; harness driven by admin/cmacs-perf.sh.  The method is ported from
;; neomacs-perf (https://github.com/eval-exec/neomacs, crates/neomacs-perf):
;; replay a fixed, deterministic workload inside a real editor, prove the
;; workload did what it claims, and only then believe its numbers.
;;
;; A workload is a registration (`cmacs-perf-define'), not a file: the
;; workload files under admin/cmacs-perf/ each register one or more, and
;; this runtime runs whichever one CMACS_PERF_WORKLOAD names.  Every run
;; has the same shape:
;;
;;   1. SETUP   -- untimed: build buffers, install commands, warm caches.
;;   2. GC      -- a full `garbage-collect', so the window does not start
;;                 by paying for setup's garbage.
;;   3. ENABLE  -- open the sampling gate (perf stat / perf record start
;;                 counting only now) and start the CPU and wall clocks.
;;   4. BODY    -- the timed work.  Returns an alist of extra metrics.
;;   5. DISABLE -- stop the clocks, close the gate.
;;   6. CHECK   -- correctness invariants.  Any failure turns the sample
;;                 into a `mismatch', which the driver refuses to use.
;;   7. RESULT  -- one JSON object at CMACS_PERF_RESULT, then exit.
;;
;; The gate is perf's own control FIFO pair (`perf stat --control
;; fifo:CTL,ACK -D -1').  The runtime writes "enable"/"disable" to CTL and
;; waits for perf's acknowledgement on ACK, so counters cover exactly the
;; BODY and nothing of startup, setup or result writing.  With no
;; CMACS_PERF_CTL in the environment the gate is a no-op and the run
;; reports clocks only.
;;
;; Environment (all set by the driver):
;;
;;   CMACS_PERF_WORKLOAD    the registered workload name (required)
;;   CMACS_PERF_RESULT      where to write the result JSON (required)
;;   CMACS_PERF_ITERATIONS  override the workload's iteration count
;;   CMACS_PERF_CTL         perf control FIFO (optional)
;;   CMACS_PERF_ACK         perf acknowledgement FIFO (optional)
;;   CMACS_PERF_DATA        directory of read-only workload inputs
;;   CMACS_PERF_PRIME       set: a priming run -- wait for native
;;                          compilation to drain before exiting
;;
;; Exit status: 0 ok, 3 correctness mismatch, 2 infrastructure error.

;;; Code:

(require 'cl-lib)

(defconst cmacs-perf-schema-version 1
  "Version of the result JSON written by `cmacs-perf-main'.
Bump it when a field changes meaning; the driver refuses to compare
samples of different versions.")

(defvar cmacs-perf-workloads nil
  "Registered workloads: an alist of (NAME . PLIST), newest first.
See `cmacs-perf-define' for the plist keys.")

(cl-defun cmacs-perf-define (name &key doc (frontend 'batch) (iterations 1)
                                  setup body check teardown primary
                                  (budget 8))
  "Register the workload NAME (a string).

DOC is a one-line description for `cmacs-perf.sh list'.  FRONTEND is
`batch' (no display: Lisp, buffers, search) or `tui' (a real
`emacs -nw' frame in a pseudo-terminal, for anything whose cost is
redisplay).  ITERATIONS is the default iteration count.  BUDGET is the
largest regression, in percent, `cmacs-perf.sh suite' accepts.
PRIMARY names the metric (a key of BODY's alist, a number) that
summarises the workload when the gated window also holds harness work
the workload does not want judged -- a latency percentile, one
phase's time; the suite then gates on it.  Without PRIMARY the driver
gates on cycles (or CPU time when perf cannot count).

SETUP is called as (SETUP ITERATIONS) before the gate opens and returns a
state object handed to the other two functions (nil if omitted).
BODY is called as (BODY STATE ITERATIONS) inside the gate; it returns an
alist of extra metrics -- (operations . N) among them when one
iteration is not one operation.  CHECK is called as
\(CHECK STATE METRICS) after the gate closes and returns a list of
failure strings; nil means every invariant held.  TEARDOWN, when
given, is called as (TEARDOWN STATE) after CHECK, even when SETUP, BODY
or CHECK signalled -- for advice, hooks and timers that must not
outlive the measurement."
  (unless (functionp body)
    (error "cmacs-perf workload %s has no body" name))
  (setq cmacs-perf-workloads
        (cons (cons name (list :doc doc :frontend frontend
                               :iterations iterations :budget budget
                               :setup setup :body body :check check
                               :teardown teardown :primary primary))
              (assoc-delete-all name cmacs-perf-workloads))))

(defun cmacs-perf-workload (name)
  "Return the plist registered for workload NAME, or signal."
  (or (cdr (assoc name cmacs-perf-workloads))
      (error "unknown cmacs-perf workload %S" name)))

;;;; Helpers shared by the workload files.

(defun cmacs-perf-getenv (name)
  "Return the environment variable NAME, signalling when it is unset."
  (or (getenv name)
      (error "required environment variable %s is not set" name)))

(defun cmacs-perf-data-file (file)
  "Return FILE inside the driver's read-only workload data directory."
  (expand-file-name file (cmacs-perf-getenv "CMACS_PERF_DATA")))

(defun cmacs-perf-cpu-us ()
  "Return this process's CPU time in microseconds."
  (car (current-cpu-time)))

(defun cmacs-perf-time (function)
  "Call FUNCTION and return the CPU microseconds it took (at least 1)."
  (let ((started (cmacs-perf-cpu-us)))
    (funcall function)
    (max 1 (- (cmacs-perf-cpu-us) started))))

(defun cmacs-perf-wall-time (function)
  "Call FUNCTION and return the wall-clock microseconds it took (at least 1)."
  (let ((started (float-time)))
    (funcall function)
    (max 1 (round (* 1000000 (- (float-time) started))))))

(defun cmacs-perf-checksum ()
  "Return the SHA-256 of the current buffer's text."
  (secure-hash 'sha256 (current-buffer)))

(defun cmacs-perf-frontend-name ()
  "Return the frontend this Emacs is running as, as a string.
\"batch\" with no display, \"tui\" on a terminal frame, and otherwise
the window system's name -- \"lrg\" for the libregnum backend
\(`emacs --lrg'), \"pgtk\" for GTK.  The driver checks this against
the frontend it launched."
  (cond (noninteractive "batch")
        ((display-graphic-p) (symbol-name window-system))
        (t "tui")))

(defun cmacs-perf-native-compiling-p ()
  "Return non-nil while an asynchronous native compilation is queued or running.
Those compilations are child processes, so perf counts them, and they
compete for the CPU besides.  A run during which one is active did not
measure the workload alone."
  (and (featurep 'native-compile)
       (or (bound-and-true-p comp-files-queue)
           (and (fboundp 'comp--async-runnings)
                (> (comp--async-runnings) 0)))))

(defun cmacs-perf--wait-for-native-compilation (timeout)
  "Wait until no native compilation has been active for two seconds.
Give up after TIMEOUT seconds.  Used by priming runs, which exist to
fill the eln-cache that the measured runs then load from."
  (let ((deadline (+ (float-time) timeout))
        (quiet-since nil))
    (while (and (< (float-time) deadline)
                (not (and quiet-since (> (- (float-time) quiet-since) 2.0))))
      (if (cmacs-perf-native-compiling-p)
          (setq quiet-since nil)
        (setq quiet-since (or quiet-since (float-time))))
      (accept-process-output nil 0.2))))

(defun cmacs-perf-compiled-p (&rest symbols)
  "Return non-nil when every function in SYMBOLS is byte- or native-compiled.
A workload that silently ran interpreted measures the interpreter, so
every Lisp-loop workload checks this in its CHECK function."
  (cl-every (lambda (symbol) (compiled-function-p (symbol-function symbol)))
            symbols))

(defun cmacs-perf-expect (failures label actual expected)
  "Return FAILURES with a message prepended when ACTUAL is not EXPECTED.
Comparison is `equal'.  LABEL names the invariant in the message."
  (if (equal actual expected)
      failures
    (cons (format "%s: got %S, expected %S" label actual expected) failures)))

(defun cmacs-perf-percentile (values fraction)
  "Return the FRACTION percentile of the list of numbers VALUES.
Nearest-rank on a sorted copy; nil for an empty list."
  (when values
    (let* ((sorted (sort (copy-sequence values) #'<))
           (rank (max 0 (1- (ceiling (* fraction (length sorted)))))))
      (nth rank sorted))))

;;;; The sampling gate.

(defvar cmacs-perf--ack-process nil
  "The `cat' process reading perf's acknowledgement FIFO.")

(defvar cmacs-perf--ack-output ""
  "What `cmacs-perf--ack-process' has read since the last command.")

(defun cmacs-perf--gate-open-reader ()
  "Start the acknowledgement reader, when the driver asked for a gate.
It runs as a child process for the whole run and is started before the
gate opens; perf counts children, but a reader blocked in read(2)
executes almost nothing, and both builds in a comparison pay the same."
  (let ((ack (getenv "CMACS_PERF_ACK")))
    (when (and ack (not (process-live-p cmacs-perf--ack-process)))
      (setq cmacs-perf--ack-process
            (make-process
             :name "cmacs-perf-ack"
             :command (list "cat" ack)
             :connection-type 'pipe
             :coding 'binary
             :noquery t
             :filter (lambda (_process output)
                       (setq cmacs-perf--ack-output
                             (concat cmacs-perf--ack-output output))))))))

(defun cmacs-perf--gate (command)
  "Send COMMAND (\"enable\" or \"disable\") to perf and wait for its ack.
A no-op when the driver gave no control FIFO.  Perf terminates its
acknowledgement with a NUL after the newline, so the reply is matched
as a substring, never as an exact string."
  (let ((ctl (getenv "CMACS_PERF_CTL")))
    (when ctl
      (cmacs-perf--gate-open-reader)
      (setq cmacs-perf--ack-output "")
      (write-region (concat command "\n") nil ctl t 'silent)
      (let ((deadline (+ (float-time) 30.0)))
        (while (not (string-search "ack\n" cmacs-perf--ack-output))
          (unless (process-live-p cmacs-perf--ack-process)
            (error "perf acknowledgement reader died during %s" command))
          (when (> (float-time) deadline)
            (error "perf did not acknowledge %s within 30 s" command))
          (accept-process-output cmacs-perf--ack-process 0.05))))))

(defun cmacs-perf--gate-close ()
  "Stop the acknowledgement reader."
  (when (processp cmacs-perf--ack-process)
    (delete-process cmacs-perf--ack-process)
    (setq cmacs-perf--ack-process nil)))

;;;; Running one workload.

(defun cmacs-perf--json-value (value)
  "Turn VALUE into something `json-serialize' accepts.
Symbols become strings, nil stays JSON null, t stays true, lists of
non-pairs become vectors."
  (cond ((memq value '(nil t)) value)
        ((keywordp value) value)
        ((symbolp value) (symbol-name value))
        ((and (consp value) (consp (car value)))
         (mapcar (lambda (pair)
                   (cons (car pair) (cmacs-perf--json-value (cdr pair))))
                 value))
        ((consp value) (vconcat (mapcar #'cmacs-perf--json-value value)))
        (t value)))

(defun cmacs-perf--write-result (path result)
  "Write the alist RESULT as JSON to PATH."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path
      (insert (json-serialize (cmacs-perf--json-value result)
                              :null-object nil :false-object :json-false))
      (insert "\n"))))

(defun cmacs-perf--run (name)
  "Run workload NAME and return its result alist.  Never signals."
  (let* ((spec nil) (iterations 0) (state nil) (metrics nil)
         (failures nil) (status "error") (error-message nil)
         (cpu-us 0) (wall-us 0) (gcs 0) (gc-us 0) (gate-open nil))
    (condition-case err
        (progn
          (setq spec (cmacs-perf-workload name)
                iterations (let ((override (getenv "CMACS_PERF_ITERATIONS")))
                             (if (and override (> (length override) 0))
                                 (string-to-number override)
                               (plist-get spec :iterations))))
          (unless (and (integerp iterations) (> iterations 0))
            (error "iterations must be a positive integer, got %S" iterations))
          ;; 1. Untimed setup.
          (when (plist-get spec :setup)
            (setq state (funcall (plist-get spec :setup) iterations)))
          ;; 2. Start the window with an empty young heap.
          (garbage-collect)
          (cmacs-perf--gate-open-reader)
          ;; 3-5. The gated, timed body.
          (let ((gcs-start gcs-done)
                (gc-start gc-elapsed)
                (cpu-start nil)
                (wall-start nil))
            ;; A native compilation running in the window is a child
            ;; process the counters include: refuse the run outright.
            (when (and (not (getenv "CMACS_PERF_PRIME"))
                         (cmacs-perf-native-compiling-p))
              (error "Native compilation is running as the window opens"))
            (cmacs-perf--gate "enable")
            (setq gate-open t)
            (unwind-protect
                (progn
                  (setq cpu-start (cmacs-perf-cpu-us)
                        wall-start (float-time))
                  (setq metrics (funcall (plist-get spec :body)
                                         state iterations))
                  (setq cpu-us (- (cmacs-perf-cpu-us) cpu-start)
                        wall-us (round (* 1000000 (- (float-time)
                                                    wall-start)))))
              (when gate-open
                (setq gate-open nil)
                (cmacs-perf--gate "disable")))
            (setq gcs (- gcs-done gcs-start)
                  gc-us (round (* 1000000 (- gc-elapsed gc-start)))))
          (when (and (not (getenv "CMACS_PERF_PRIME"))
                       (cmacs-perf-native-compiling-p))
            (error "Native compilation started inside the window"))
          ;; 6. Correctness: a fast wrong answer is not a sample.
          (when (plist-get spec :check)
            (setq failures (funcall (plist-get spec :check) state metrics)))
          (setq status (if failures "mismatch" "ok")))
      (error
       (setq error-message (error-message-string err))
       (message "cmacs-perf: %s failed: %s" name error-message)))
    ;; Teardown runs whatever happened above; a teardown that fails
    ;; leaves the editor in an unknown state, so the sample is void.
    (when (plist-get spec :teardown)
      (condition-case err
          (funcall (plist-get spec :teardown) state)
        (error
         (setq status "error"
               error-message (format "teardown: %s"
                                     (error-message-string err))))))
    (cmacs-perf--gate-close)
    ;; A declared primary metric the body did not report is a broken
    ;; workload, not a sample.
    (let ((primary (plist-get spec :primary)))
      (when (and primary (equal status "ok")
                 (not (numberp (alist-get primary metrics))))
        (setq failures (cons (format "primary metric %s was not reported"
                                     primary)
                             failures)
              status "mismatch")))
    (let ((operations (or (alist-get 'operations metrics) iterations))
          (primary (plist-get spec :primary)))
      `((schema . ,cmacs-perf-schema-version)
        (workload . ,name)
        (status . ,status)
        (frontend . ,(cmacs-perf-frontend-name))
        (iterations . ,iterations)
        (operations . ,operations)
        (cpu_us . ,cpu-us)
        (wall_us . ,wall-us)
        (cpu_ns_per_op . ,(if (> operations 0)
                              (round (/ (* 1000.0 cpu-us) operations))
                            0))
        (gcs_done . ,gcs)
        (gc_us . ,gc-us)
        (primary_metric . ,(and primary (symbol-name primary)))
        (primary . ,(and primary (alist-get primary metrics)))
        (metrics . ,(assq-delete-all 'operations (copy-alist metrics)))
        (failures . ,(vconcat (reverse failures)))
        (error . ,error-message)
        (emacs_version . ,emacs-version)
        (system_configuration . ,system-configuration)
        ;; How the harness itself was loaded, which the driver checks
        ;; against what it compiled: a run that silently fell back to
        ;; bytecode (or to the .el) measured a different program.
        (compiled . ,(let ((definition (symbol-function 'cmacs-perf--run)))
                       (cond ((and (fboundp 'native-comp-function-p)
                                   (native-comp-function-p definition))
                              "native")
                             ((byte-code-function-p definition) "bytecode")
                             (t "interpreted"))))
        (native_comp . ,(and (fboundp 'native-comp-available-p)
                             (native-comp-available-p)
                             t))
        (window_system . ,(and window-system (symbol-name window-system)))
        ;; The grid the workload ran in: frontends compared against each
        ;; other must agree on it, or they did different amounts of work.
        (frame . ,(unless noninteractive
                    `((columns . ,(frame-width))
                      (lines . ,(frame-height))
                      (pixel_width . ,(frame-pixel-width))
                      (pixel_height . ,(frame-pixel-height))
                      (font . ,(face-attribute 'default :family)))))))))

(defun cmacs-perf-main ()
  "Run the workload named by CMACS_PERF_WORKLOAD and exit.
In a TUI run this is scheduled from `emacs-startup-hook', so the first
frame exists and has been displayed before setup starts."
  (let* ((name (getenv "CMACS_PERF_WORKLOAD"))
         (path (getenv "CMACS_PERF_RESULT"))
         (result (if name
                     (cmacs-perf--run name)
                   '((status . "error")
                     (error . "CMACS_PERF_WORKLOAD is not set"))))
         (status (alist-get 'status result)))
    (condition-case err
        (if path
            (cmacs-perf--write-result path result)
          (message "%s" (json-serialize (cmacs-perf--json-value result))))
      (error (message "cmacs-perf: cannot write result: %s"
                      (error-message-string err))
             (setq status "error")))
    ;; A priming run only fills the eln-cache: let every compilation it
    ;; started finish, or the measured runs would compile it again.
    (when (getenv "CMACS_PERF_PRIME")
      (cmacs-perf--wait-for-native-compilation 600))
    (kill-emacs (pcase status ("ok" 0) ("mismatch" 3) (_ 2)))))

(defvar cmacs-perf--settle-state nil
  "Polling state of `cmacs-perf-main-when-settled': (DEADLINE SIZE STABLE).")

(defun cmacs-perf-main-when-settled ()
  "Run `cmacs-perf-main' once the selected frame has settled.
A terminal frame is ready when startup ends, but a window-system frame
is still being mapped and resized by the compositor for a while after,
and a workload that starts then measures the window manager -- or
fails, finding point outside a window that has not reached its size.
So on a graphical frame this polls every 50 ms until the frame is
visible and its pixel size has held for five polls in a row (a quarter
second), giving up after ten seconds and running anyway; the
workload's own checks then decide whether the result is usable."
  (if (not (display-graphic-p))
      (cmacs-perf-main)
    (redisplay t)
    (let* ((state (or cmacs-perf--settle-state
                      (list (+ (float-time) 10.0) nil 0)))
           (size (list (frame-pixel-width) (frame-pixel-height)))
           (stable (if (and (eq (frame-visible-p (selected-frame)) t)
                            (equal size (nth 1 state)))
                       (1+ (nth 2 state))
                     0)))
      (setq cmacs-perf--settle-state (list (nth 0 state) size stable))
      (if (or (>= stable 5) (> (float-time) (nth 0 state)))
          (cmacs-perf-main)
        (run-at-time 0.05 nil #'cmacs-perf-main-when-settled)))))

(defun cmacs-perf-list ()
  "Print every registered workload as one tab-separated line and exit.
Columns: name, frontend, default iterations, budget, primary metric
(\"-\" when none), description."
  (dolist (entry (sort (copy-sequence cmacs-perf-workloads)
                       (lambda (a b) (string< (car a) (car b)))))
    (let ((spec (cdr entry)))
      (princ (format "%s\t%s\t%d\t%s\t%s\t%s\n"
                     (car entry) (plist-get spec :frontend)
                     (plist-get spec :iterations) (plist-get spec :budget)
                     (or (plist-get spec :primary) "-")
                     (or (plist-get spec :doc) "")))))
  (kill-emacs 0))

(defun cmacs-perf-frontend (name)
  "Print workload NAME's default frontend and exit."
  (princ (format "%s\n" (plist-get (cmacs-perf-workload name) :frontend)))
  (kill-emacs 0))

(provide 'cmacs-perf)

;;; cmacs-perf.el ends here
