;;; cmacs-perf-editing.el --- cmacs-perf: editor workloads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; Copyright (C) 2026 Eval Exec and the neomacs contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Whole-editor workloads: typing, fontification, search, indentation,
;; Org, redisplay, subprocess output, file opening and JSON-RPC, each
;; replayed over a deterministic buffer and restored after every
;; iteration.  Ported from neomacs-perf's fixtures/editor-workloads.el
;; (GPL-3.0-or-later), with the invariants its Rust side checks
;; (src/harness/scenarios/editor_workload.rs) and the frontend and
;; iteration defaults from its catalogue (src/catalog.rs).  The
;; workloads and their invariants are theirs, the registration form is
;; cmacs-perf's.
;;
;; Every workload has the same shape, built by `cmacs-perf-edit--define':
;;
;;   SETUP  fills a fresh buffer (PREPARE), fontifies all of it, shows it
;;          in the selected window when the workload measures redisplay
;;          of the edited text, settles it (WARM) and records the
;;          buffer's checksum, point and major mode.
;;   BODY   runs STEP once per iteration.  Each iteration snapshots the
;;          text and point first and restores both afterwards; that
;;          snapshot/restore is the harness's own work inside the
;;          window, so it is reported separately as `bookkeeping_us'.
;;          Phases a step times become `<phase>_phase_us' metrics.
;;   CHECK  insists on what neomacs insists on: one operation per
;;          iteration, the buffer text and point restored, the major
;;          mode unchanged, every phase the workload claims to time
;;          actually timed, one positive latency sample per iteration
;;          for a latency workload -- plus the workload's own invariant
;;          (a match count, an output size, a JSON round trip).
;;
;; Differences from neomacs, all deliberate:
;;
;;   - Phase metrics are named for what they time.  neomacs reuses its
;;     `type' and `regex' slots for unrelated work; here org-editing and
;;     sustained-editing time `edit', process-output `process', file-open
;;     `insert' (+ `fontify') and lsp-json-rpc `json'.
;;   - gui-input-latency is `input-latency' on the TUI frontend, and its
;;     buffer is displayed: neomacs edits a hidden temporary buffer, so
;;     its forced redisplay never draws the keystroke it is timing.
;;   - neomacs's NEOMACS_PERF_SUSTAINED_VISIBLE and
;;     NEOMACS_PERF_SUSTAINED_EDIT_CASE knobs are separate workloads
;;     (`sustained-editing-visible', `-join', `-text-scale-join',
;;     `-text-scale-typing'); plain `sustained-editing' keeps neomacs's
;;     default hidden buffer, so its series stays comparable.
;;   - startup runs on the TUI, where `redisplay' does something; its
;;     headline number (process wall time) belongs to the driver, and the
;;     workload adds the editor's own `emacs_init_us'.
;;   - large-file-editing builds its 8x source in SETUP from source.el
;;     instead of reading a pre-built file.
;;   - magit-status (needs MELPA) and the latency trace / GC-window
;;     diagnostics (neomacs-only plumbing) are not ported.

;;; Code:

(require 'cl-lib)
(require 'cmacs-perf)

(declare-function org-todo "org" (&optional arg))
(declare-function org-table-align "org-table" ())
(declare-function text-scale-set "face-remap" (level))

(defconst cmacs-perf-edit--latency-budget-us 1000
  "Input-to-redisplay budget in microseconds.
Samples above it are counted in `over_budget' (neomacs's
INPUT_LATENCY_BUDGET_US).")

;;;; Run scaffolding.

(defvar cmacs-perf-edit--source nil
  "Absolute path of the workload source file, resolved in SETUP.
Resolved before the window opens so no iteration pays for the
environment lookup.")

(defun cmacs-perf-edit--source ()
  "Resolve, remember and return the workload source file."
  (setq cmacs-perf-edit--source (cmacs-perf-data-file "source.el")))

(defun cmacs-perf-edit--elapsed-us (started)
  "Return the wall microseconds since the `float-time' STARTED."
  (max 0 (round (* 1000000 (- (float-time) started)))))

(defun cmacs-perf-edit--timed (phases name function)
  "Call FUNCTION, add its CPU microseconds to phase NAME in PHASES.
PHASES is a hash table of phase name to accumulated microseconds.
Return FUNCTION's value, so a step can keep a phase's result."
  (let ((result nil))
    (puthash name
             (+ (gethash name phases 0)
                (cmacs-perf-time (lambda () (setq result (funcall function)))))
             phases)
    result))

(defun cmacs-perf-edit--restore (text point)
  "Make the buffer TEXT again and put point back at POINT.
The text is only rewritten when it differs, as neomacs does, so a step
that left the buffer intact pays one comparison and no reinsertion."
  (unless (equal text (buffer-substring-no-properties (point-min) (point-max)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)))
  (goto-char (min point (point-max))))

(defun cmacs-perf-edit--execute (step iterations latency)
  "Run STEP ITERATIONS times in the current buffer; return the metrics.
STEP is called with the phase table (see `cmacs-perf-edit--timed').
With LATENCY, each STEP call returns one wall-clock sample in
microseconds, and the samples are reported with their percentiles."
  (let ((phases (make-hash-table :test #'eq))
        (samples nil)
        (bookkeeping-us 0)
        (completed 0))
    (dotimes (_ iterations)
      ;; The snapshot is harness work, not workload work: charge it to
      ;; `bookkeeping_us' so a reader can tell the two apart.
      (let* ((started (float-time))
             (text (buffer-substring-no-properties (point-min) (point-max)))
             (saved-point (point)))
        (setq bookkeeping-us (+ bookkeeping-us
                                (cmacs-perf-edit--elapsed-us started)))
        (let ((sample (funcall step phases)))
          (when latency
            (push sample samples)))
        (setq started (float-time))
        (cmacs-perf-edit--restore text saved-point)
        (setq bookkeeping-us (+ bookkeeping-us
                                (cmacs-perf-edit--elapsed-us started))
              completed (1+ completed))))
    (let ((metrics (list (cons 'bookkeeping_us bookkeeping-us)
                         (cons 'operations completed))))
      (maphash (lambda (name us)
                 (push (cons (intern (format "%s_phase_us" name)) us) metrics))
               phases)
      (when latency
        (setq samples (nreverse samples))
        (push (cons 'latency_samples_us (vconcat samples)) metrics)
        (push (cons 'latency_p50_us (cmacs-perf-percentile samples 0.50))
              metrics)
        (push (cons 'latency_p95_us (cmacs-perf-percentile samples 0.95))
              metrics)
        (push (cons 'latency_p99_us (cmacs-perf-percentile samples 0.99))
              metrics)
        (push (cons 'over_budget
                    (cl-count-if (lambda (sample)
                                   (and (numberp sample)
                                        (> sample
                                           cmacs-perf-edit--latency-budget-us)))
                                 samples))
              metrics))
      (nreverse metrics))))

(defun cmacs-perf-edit--window-failures (failures buffer when)
  "Return FAILURES plus one message per broken display invariant.
The selected window must be live and show BUFFER with point visible.
WHEN (\"before\" or \"after\") names the moment in the message."
  (let ((window (selected-window)))
    (unless (window-live-p window)
      (push (format "selected window is dead %s the loop" when) failures))
    (unless (eq (window-buffer window) buffer)
      (push (format "selected window does not show the edited buffer %s \
the loop" when)
            failures))
    (unless (pos-visible-in-window-p (point) window)
      (push (format "point is not visible %s the loop" when) failures))
    failures))

(cl-defun cmacs-perf-edit--define (name &key doc (frontend 'batch) iterations
                                        (budget 8) prepare warm step phases
                                        display latency inspect report
                                        extra-check primary)
  "Register the editor workload NAME with `cmacs-perf-define'.
PRIMARY is passed through: the metric the suite gates on.

DOC, FRONTEND, ITERATIONS and BUDGET are passed through.  PREPARE fills
the fresh, current workload buffer and sets its major mode; the whole
buffer is then fontified, as neomacs does for every workload.  With
DISPLAY, the buffer is shown in the selected window and the window
invariants are checked before and after the loop.  WARM, when given,
settles the buffer (point, window start, modes) after that.  INSPECT,
when given, is called in the settled buffer and its value is kept in
the state as :inspect for EXTRA-CHECK.

STEP, a symbol, is one iteration: called with the phase table, it times
its phases with `cmacs-perf-edit--timed' and, with LATENCY, returns one
wall-clock sample.  PHASES lists the phase names that must have been
timed.  REPORT, when given, is called with the state after the loop and
returns more metrics.  EXTRA-CHECK is called as (EXTRA-CHECK STATE
METRICS) in the buffer and returns more failure strings."
  (cmacs-perf-define
   name
   :doc doc
   :frontend frontend
   :iterations iterations
   :budget budget
   :primary primary
   :setup
   (lambda (iterations)
     (let ((buffer (generate-new-buffer " *cmacs-perf-edit*" t)))
       (with-current-buffer buffer
         (funcall prepare)
         (font-lock-ensure (point-min) (point-max))
         (when display
           (set-window-buffer (selected-window) buffer))
         (when warm
           (funcall warm))
         ;; Realize the frame and its faces now, so cold display setup
         ;; stays outside the window (neomacs's prepare-sampling).
         (redisplay t)
         (when display
           (let ((failures (cmacs-perf-edit--window-failures
                            nil buffer "before")))
             (when failures
               (error "%s" (string-join failures "; ")))))
         (list :buffer buffer
               :iterations iterations
               :checksum (cmacs-perf-checksum)
               :point (point)
               :mode major-mode
               :inspect (and inspect (funcall inspect))))))
   :body
   (lambda (state iterations)
     (with-current-buffer (plist-get state :buffer)
       (append (cmacs-perf-edit--execute step iterations latency)
               (and report (funcall report state)))))
   :check
   (lambda (state metrics)
     (let ((buffer (plist-get state :buffer))
           (failures nil))
       (if (not (buffer-live-p buffer))
           (push "the workload buffer was killed" failures)
         (with-current-buffer buffer
           (unless (cmacs-perf-compiled-p step 'cmacs-perf-edit--execute)
             (push (format "%s is not compiled" step) failures))
           (setq failures (cmacs-perf-expect failures "operation count"
                                             (alist-get 'operations metrics)
                                             (plist-get state :iterations)))
           (setq failures (cmacs-perf-expect failures "final buffer checksum"
                                             (cmacs-perf-checksum)
                                             (plist-get state :checksum)))
           (setq failures (cmacs-perf-expect failures "final point"
                                             (point) (plist-get state :point)))
           (setq failures (cmacs-perf-expect failures "major mode"
                                             major-mode
                                             (plist-get state :mode)))
           (when display
             (setq failures (cmacs-perf-edit--window-failures
                             failures buffer "after")))
           ;; A phase that was never timed would silently stop guarding
           ;; the code it exists for.
           (dolist (phase phases)
             (let ((us (alist-get (intern (format "%s_phase_us" phase))
                                  metrics)))
               (unless (and (integerp us) (> us 0))
                 (push (format "phase %s was not timed" phase) failures))))
           (when latency
             (let ((samples (append (alist-get 'latency_samples_us metrics)
                                    nil)))
               (setq failures (cmacs-perf-expect failures "latency sample count"
                                                 (length samples)
                                                 (plist-get state :iterations)))
               (unless (cl-every (lambda (sample)
                                   (and (integerp sample) (> sample 0)))
                                 samples)
                 (push "a latency sample is not a positive integer"
                       failures))))
           (when extra-check
             (setq failures (append (funcall extra-check state metrics)
                                    failures))))
         (kill-buffer buffer))
       failures))))

;;;; Buffer preparation.

(defun cmacs-perf-edit--prepare-source ()
  "Fill the buffer with the workload source file in `emacs-lisp-mode'."
  (insert-file-contents (cmacs-perf-edit--source))
  (emacs-lisp-mode))

(defun cmacs-perf-edit--prepare-large ()
  "Fill the buffer with eight copies of the source, in `emacs-lisp-mode'.
neomacs writes the 8x file on disk before the run; building it here is
the same text and needs no extra input file."
  (let ((source (cmacs-perf-edit--source)))
    (dotimes (_ 8)
      (goto-char (point-max))
      (insert-file-contents source)))
  (goto-char (point-min))
  (emacs-lisp-mode))

(defun cmacs-perf-edit--prepare-empty ()
  "Leave the buffer empty, in `fundamental-mode'.
For workloads whose step builds its own buffer (file-open,
process-output) or edits none (startup, lsp-json-rpc)."
  (cmacs-perf-edit--source)
  (fundamental-mode))

(defun cmacs-perf-edit--prepare-org ()
  "Fill the buffer with 150 plain Org sections, in `org-mode'.
Headings, property drawers and tables and nothing else; see
`cmacs-perf-edit--insert-org-document' for what that leaves out."
  (require 'org)
  (dotimes (section 150)
    (insert (format "* TODO Section %d\n:PROPERTIES:\n:ID: item-%d\n:END:\n"
                    section section)
            "| Name | Value |\n|------+-------|\n| alpha | 1 |\n\n"))
  (org-mode))

(defconst cmacs-perf-edit--org-subjects
  ["release prep" "design review" "reading log" "bug hunt" "pairing session"
   "refactor pass" "research spike" "profiling notes" "triage" "retro"]
  "Heading subjects, cycled so the Org document is deterministic.")

(defun cmacs-perf-edit--insert-org-document (sections)
  "Insert SECTIONS of Org markup of the kind a real Org file carries.
The plain org-editing buffer has no links, emphasis, `#+' lines, list
items or timestamps, so its fontification never reaches Org's
expensive matchers.  This emits the same TODO headings and tables plus
tags, a scheduled timestamp, links, emphasis, a checkbox item and a
source block in every section: an upper bound where the plain buffer
is the lower one.  Cycled from constants, so it is byte-identical on
every machine."
  (dotimes (section sections)
    (insert
     (format "* TODO %s %d  :work:proj%d:\n"
             (aref cmacs-perf-edit--org-subjects
                   (mod section (length cmacs-perf-edit--org-subjects)))
             section (mod section 7))
     (format "SCHEDULED: <2026-09-%02d Sat>\n" (1+ (mod section 28)))
     (format ":PROPERTIES:\n:ID: item-%d\n:END:\n" section)
     (format (concat "See [[file:notes.org::*Section %d][the note]] and"
                     " [[https://example.invalid/%d][upstream]] for *context*;"
                     " the /interesting/ part is ~code~ plus =verbatim=.\n")
             section section)
     (format "- [ ] follow up on *item %d* with the \
[[https://example.invalid/a][owner]]\n"
             section)
     (format "#+BEGIN_SRC emacs-lisp\n(defun sim--section-%d (x) (* x x))\n\
#+END_SRC\n"
             section)
     "| Name | Value |\n|------+-------|\n| alpha | 1 |\n\n")))

(defun cmacs-perf-edit--prepare-org-heavy ()
  "Fill the buffer with 150 markup-heavy Org sections, in `org-mode'."
  (require 'org)
  (cmacs-perf-edit--insert-org-document 150)
  (org-mode))

;;;; Phases (neomacs's, unchanged).

(defvar cmacs-perf-edit--matches nil
  "Match count of the last `cmacs-perf-edit--regex-phase' a step kept.")

(defun cmacs-perf-edit--type-phase ()
  "Type a six-line defun at the end, fontifying the line per character."
  (goto-char (point-max))
  (dolist (line '("(defun sim--generated (x y)"
                  "  \"Docstring for the generated function.\""
                  "  (let ((acc nil))"
                  "    (dotimes (i (+ x y))"
                  "      (push (* i i) acc))"
                  "    (nreverse acc)))"))
    (dolist (character (string-to-list line))
      (insert character)
      (font-lock-ensure (line-beginning-position) (line-end-position)))
    (insert "\n")))

(defun cmacs-perf-edit--comment-phase ()
  "Comment and uncomment lines 300-400."
  (goto-char (point-min))
  (forward-line 300)
  (let ((start (line-beginning-position)))
    (forward-line 100)
    (comment-region start (point))
    (uncomment-region start (point))))

(defun cmacs-perf-edit--kill-yank-phase ()
  "Twenty times, kill 50 lines from line 100 and yank them at the end."
  (goto-char (point-min))
  (dotimes (_ 20)
    (goto-char (point-min))
    (forward-line 100)
    (let ((start (point)))
      (forward-line 50)
      (kill-region start (point))
      (goto-char (point-max))
      (yank))))

(defun cmacs-perf-edit--indent-phase ()
  "Indent the 400 lines from line 200."
  (goto-char (point-min))
  (forward-line 200)
  (let ((start (point)))
    (forward-line 400)
    (indent-region start (point))))

(defun cmacs-perf-edit--regex-phase ()
  "Return how many `(defun NAME' forms the buffer holds."
  (goto-char (point-min))
  (let ((matches 0))
    (while (re-search-forward "(defun \\([-a-z0-9]+\\)" nil t)
      (setq matches (1+ matches)))
    matches))

(defun cmacs-perf-edit--search-phase ()
  "Run `cmacs-perf-edit--regex-phase' 50 times."
  (dotimes (_ 50)
    (cmacs-perf-edit--regex-phase)))

(defun cmacs-perf-edit--replace-phase ()
  "Replace every `byte-compile' symbol with itself, then fontify."
  (goto-char (point-min))
  (while (re-search-forward "\\_<byte-compile\\_>" nil t)
    (replace-match "byte-compile" t t))
  (font-lock-ensure (point-min) (point-max)))

(defun cmacs-perf-edit--undo-redo-phase ()
  "Ten times, insert two lines, delete them, and undo both changes."
  (buffer-enable-undo)
  (dotimes (_ 10)
    (goto-char (point-max))
    (let ((start (point)))
      (dolist (line '("(defun sim--undo-probe (n)" "  (* n n))"))
        (insert line "\n"))
      (undo-boundary)
      (delete-region start (point-max))
      (undo-boundary))
    (primitive-undo 2 buffer-undo-list)))

(defun cmacs-perf-edit--isearch-phase ()
  "Search incremental prefixes of \"defun \" across the whole buffer."
  (let ((needles '("d" "de" "def" "defu" "defun" "defun ")))
    (dotimes (_ 5)
      (dolist (needle needles)
        (goto-char (point-min))
        (while (search-forward needle nil t))))))

(defun cmacs-perf-edit--buffer-switch-phase ()
  "Make eight small Lisp buffers and move point in each 200 times."
  (let ((buffers
         (cl-loop for index below 8
                  collect
                  (let ((buffer (generate-new-buffer
                                 (format " sim-buf-%d" index))))
                    (with-current-buffer buffer
                      (insert (format ";; buffer %d\n(defvar sim-var-%d %d)\n"
                                      index index index))
                      (emacs-lisp-mode))
                    buffer))))
    (unwind-protect
        (dotimes (_ 200)
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 1)
              (end-of-line))))
      (mapc #'kill-buffer buffers))))

(defun cmacs-perf-edit--how-many-phase ()
  "Scan the buffer for every `let' and `let*' symbol."
  (goto-char (point-min))
  (while (re-search-forward "\\_<let\\*?\\_>" nil t)))

(defun cmacs-perf-edit--motion-phase ()
  "Walk every line: next line, end of line, beginning of line."
  (goto-char (point-min))
  (while (not (eobp))
    (forward-line 1)
    (end-of-line)
    (beginning-of-line)))

(defun cmacs-perf-edit--edit-cycle ()
  "Self-insert one character at the end and delete it, redisplaying each."
  (goto-char (point-max))
  (let ((last-command-event ?x))
    (call-interactively #'self-insert-command))
  (font-lock-ensure (line-beginning-position) (line-end-position))
  (redisplay t)
  (delete-char -1)
  (redisplay t))

(defun cmacs-perf-edit--join-cycle ()
  "Delete the newline ending this line and reinsert it, redisplaying each.
A pure deletion near the lower visible rows and its exact inverse."
  (end-of-line)
  (unless (eq (char-after) ?\n)
    (error "join fixture lacks a line boundary"))
  (delete-char 1)
  (redisplay t)
  (insert "\n")
  (redisplay t))

;;;; Warm-ups for the displayed workloads.

(defun cmacs-perf-edit--warm-typing ()
  "Put point at the end, where the typing cycle edits."
  (goto-char (point-max)))

(defun cmacs-perf-edit--warm-join ()
  "Put point at the end of line 25 with the window starting at the top.
Font Lock is turned off so the damage stays a pure deletion:
fontification's widened property spans are a separate case."
  (font-lock-mode -1)
  (goto-char (point-min))
  (forward-line 24)
  (end-of-line)
  (set-window-start (selected-window) (point-min)))

(defun cmacs-perf-edit--warm-text-scale-join ()
  "Scale the text up one step, then `cmacs-perf-edit--warm-join'."
  (require 'face-remap)
  (text-scale-set 1)
  (cmacs-perf-edit--warm-join))

(defun cmacs-perf-edit--warm-text-scale-typing ()
  "Scale the text up one step, then `cmacs-perf-edit--warm-typing'."
  (require 'face-remap)
  (text-scale-set 1)
  (cmacs-perf-edit--warm-typing))

;;;; Steps: one iteration of each workload.

(defun cmacs-perf-edit--simulation-step (phases)
  "One editing-simulation iteration: every phase, timed apart, in PHASES."
  (cmacs-perf-edit--timed phases 'mode #'emacs-lisp-mode)
  (cmacs-perf-edit--timed phases 'fontify
                          (lambda () (font-lock-ensure (point-min) (point-max))))
  (cmacs-perf-edit--timed phases 'regex #'cmacs-perf-edit--search-phase)
  (cmacs-perf-edit--timed phases 'type #'cmacs-perf-edit--type-phase)
  (cmacs-perf-edit--timed phases 'replace #'cmacs-perf-edit--replace-phase)
  (cmacs-perf-edit--timed phases 'indent #'cmacs-perf-edit--indent-phase)
  (cmacs-perf-edit--timed phases 'kill_yank #'cmacs-perf-edit--kill-yank-phase)
  (cmacs-perf-edit--timed phases 'undo_redo #'cmacs-perf-edit--undo-redo-phase)
  (cmacs-perf-edit--timed phases 'isearch #'cmacs-perf-edit--isearch-phase)
  (cmacs-perf-edit--timed phases 'buffer_switch
                          #'cmacs-perf-edit--buffer-switch-phase)
  (cmacs-perf-edit--timed phases 'comment #'cmacs-perf-edit--comment-phase)
  (cmacs-perf-edit--timed phases 'how_many #'cmacs-perf-edit--how-many-phase)
  (cmacs-perf-edit--timed phases 'motion #'cmacs-perf-edit--motion-phase)
  nil)

(defun cmacs-perf-edit--startup-step (phases)
  "One startup iteration: a forced redisplay, timed in PHASES."
  (cmacs-perf-edit--timed phases 'redisplay (lambda () (redisplay t)))
  nil)

(defun cmacs-perf-edit--sustained-step (phases)
  "One sustained-editing iteration: the typing cycle, timed in PHASES."
  (cmacs-perf-edit--timed phases 'edit #'cmacs-perf-edit--edit-cycle)
  nil)

(defun cmacs-perf-edit--join-step (phases)
  "One sustained-editing join iteration: the join cycle, timed in PHASES."
  (cmacs-perf-edit--timed phases 'edit #'cmacs-perf-edit--join-cycle)
  nil)

(defun cmacs-perf-edit--input-latency-step (_phases)
  "One keystroke: return its input-to-redisplay wall microseconds.
The deletion and its redisplay restore the screen outside the sample."
  (prog1 (cmacs-perf-wall-time
          (lambda ()
            (goto-char (point-max))
            (let ((last-command-event ?x))
              (call-interactively #'self-insert-command))
            (font-lock-ensure (line-beginning-position) (line-end-position))
            (redisplay t)))
    (delete-char -1)
    (redisplay t)))

(defun cmacs-perf-edit--org-step (phases)
  "One Org iteration: mark the first TODO done, align a table, fontify.
Timed in PHASES as `edit'."
  (cmacs-perf-edit--timed
   phases 'edit
   (lambda ()
     (goto-char (point-min))
     (re-search-forward "^\\* TODO ")
     (org-todo "DONE")
     (re-search-forward "^| Name |")
     (org-table-align)
     (font-lock-ensure (point-min) (point-max))))
  nil)

(defun cmacs-perf-edit--large-file-step (phases)
  "One large-file iteration: type, count defuns, walk lines, in PHASES."
  (cmacs-perf-edit--timed phases 'type #'cmacs-perf-edit--type-phase)
  (setq cmacs-perf-edit--matches
        (cmacs-perf-edit--timed phases 'regex #'cmacs-perf-edit--regex-phase))
  (cmacs-perf-edit--timed phases 'motion #'cmacs-perf-edit--motion-phase)
  nil)

(defun cmacs-perf-edit--indentation-step (phases)
  "One indentation iteration: indent 400 lines, timed in PHASES."
  (cmacs-perf-edit--timed phases 'indent #'cmacs-perf-edit--indent-phase)
  nil)

(defun cmacs-perf-edit--regex-step (phases)
  "One regex-search iteration: count defuns, timed in PHASES."
  (setq cmacs-perf-edit--matches
        (cmacs-perf-edit--timed phases 'regex #'cmacs-perf-edit--regex-phase))
  nil)

(defvar cmacs-perf-edit--last-output nil
  "(STATUS . SIZE) of the last subprocess read or file insert a step did.")

(defun cmacs-perf-edit--read-process-output ()
  "Read `cat' of the source into a temporary buffer.
Return (EXIT-STATUS . BUFFER-SIZE).  `call-process' rather than an
asynchronous filter because a benchmark has to be deterministic; it
reaches the same spawn/read/decode/insert path, not filter dispatch."
  (with-temp-buffer
    (let ((status (call-process "cat" nil t nil cmacs-perf-edit--source)))
      (cons status (buffer-size)))))

(defun cmacs-perf-edit--process-output-step (phases)
  "One process-output iteration, timed in PHASES as `process'."
  (setq cmacs-perf-edit--last-output
        (cmacs-perf-edit--timed phases 'process
                                #'cmacs-perf-edit--read-process-output))
  nil)

(defun cmacs-perf-edit--file-open-step (phases)
  "Open the source into a fresh buffer, timed in PHASES in two halves.
`insert' is decode plus buffer insert, on the path of every file a
session opens; `fontify' is the major mode plus ONE screenful of
fontification, because `jit-lock' fontifies what a window shows and
defers the rest -- the whole buffer would bury the first half."
  (with-temp-buffer
    (cmacs-perf-edit--timed phases 'insert
                            (lambda ()
                              (insert-file-contents cmacs-perf-edit--source)))
    (setq cmacs-perf-edit--last-output (cons major-mode (buffer-size)))
    (cmacs-perf-edit--timed phases 'fontify
                            (lambda ()
                              (emacs-lisp-mode)
                              (font-lock-ensure
                               (point-min)
                               (save-excursion
                                 (goto-char (point-min))
                                 (forward-line 60)
                                 (point)))))
    (setcar cmacs-perf-edit--last-output major-mode))
  nil)

;;;; lsp-json-rpc.

(defun cmacs-perf-edit--lsp-message (count)
  "Build one `textDocument/publishDiagnostics' plist with COUNT diagnostics.
Shaped like what a language server sends -- nested ranges, a message
per item, related information -- because payload size and shape are
what this workload holds fixed."
  (list :jsonrpc "2.0"
        :method "textDocument/publishDiagnostics"
        :params
        (list :uri "file:///tmp/neomacs-perf/main.cpp"
              :diagnostics
              (vconcat
               (let (items)
                 (dotimes (i count)
                   (push (list :range (list :start (list :line i :character 4)
                                            :end (list :line i :character 32))
                               :severity 1
                               :code "no_member"
                               :source "clang"
                               :message (format "no member named 'field_%d' \
in 'Widget'" i)
                               :relatedInformation
                               (vector
                                (list :location
                                      (list :uri "file:///tmp/neomacs-perf/widget.h"
                                            :range (list :start (list :line i
                                                                      :character 0)
                                                         :end (list :line i
                                                                    :character 9)))
                                      :message "declared here")))
                         items))
                 (nreverse items))))))

(defvar cmacs-perf-edit--lsp-payload nil
  "The diagnostics plist lsp-json-rpc round-trips, built in SETUP.")

(defvar cmacs-perf-edit--lsp-last nil
  "What the last lsp-json-rpc round trip parsed back.")

(defun cmacs-perf-edit--lsp-round-trip ()
  "Serialize the payload and parse it back; return the parsed plist."
  (json-parse-string
   (json-serialize cmacs-perf-edit--lsp-payload
                   :null-object nil :false-object :json-false)
   :object-type 'plist :null-object nil :false-object :json-false))

(defun cmacs-perf-edit--lsp-step (phases)
  "One jsonrpc round trip, the eglot per-keystroke path, timed in PHASES."
  (setq cmacs-perf-edit--lsp-last
        (cmacs-perf-edit--timed phases 'json #'cmacs-perf-edit--lsp-round-trip))
  nil)

;;;; Registrations.

(cmacs-perf-edit--define
 "editing-simulation"
 :doc "composite Lisp editing session with thirteen timed phases"
 :iterations 10
 :prepare #'cmacs-perf-edit--prepare-source
 :step 'cmacs-perf-edit--simulation-step
 :phases '(mode fontify regex type replace indent kill_yank undo_redo
                isearch buffer_switch comment how_many motion))

(cmacs-perf-edit--define
 "startup"
 :doc "forced redisplay of a freshly started frame"
 :frontend 'tui
 :iterations 1
 :prepare #'cmacs-perf-edit--prepare-empty
 :step 'cmacs-perf-edit--startup-step
 :phases '(redisplay)
 :report (lambda (_state)
           ;; The editor's own view of how long init took; the process
           ;; wall time neomacs ranks on is the driver's to measure.
           `((emacs_init_us
              . ,(if (and before-init-time after-init-time)
                     (round (* 1000000 (float-time
                                        (time-subtract after-init-time
                                                       before-init-time))))
                   0)))))

(cmacs-perf-edit--define
 "sustained-editing"
 :doc "insert, fontify, redisplay, delete, redisplay (hidden buffer)"
 :frontend 'tui
 :iterations 100
 :prepare #'cmacs-perf-edit--prepare-source
 :step 'cmacs-perf-edit--sustained-step
 :phases '(edit)
 :primary 'edit_phase_us
 :report (lambda (state)
           `((edits . ,(* 2 (plist-get state :iterations))))))

(dolist (variant
         '(("sustained-editing-visible"
            "sustained typing cycle in the displayed buffer"
            cmacs-perf-edit--sustained-step cmacs-perf-edit--warm-typing)
           ("sustained-editing-join"
            "join and split a visible line, redisplaying each"
            cmacs-perf-edit--join-step cmacs-perf-edit--warm-join)
           ("sustained-editing-text-scale-join"
            "join and split a visible line under text-scale 1"
            cmacs-perf-edit--join-step cmacs-perf-edit--warm-text-scale-join)
           ("sustained-editing-text-scale-typing"
            "sustained typing cycle in the displayed buffer under text-scale 1"
            cmacs-perf-edit--sustained-step
            cmacs-perf-edit--warm-text-scale-typing)))
  (pcase-let ((`(,name ,doc ,step ,warm) variant))
    (cmacs-perf-edit--define
     name
     :doc doc
     :frontend 'tui
     :iterations 100
     :prepare #'cmacs-perf-edit--prepare-source
     :display t
     :warm warm
     :step step
     :phases '(edit)
     :primary 'edit_phase_us
     :report (lambda (state)
               `((edits . ,(* 2 (plist-get state :iterations))))))))

(cmacs-perf-edit--define
 "input-latency"
 :doc "self-insert-command to forced redisplay, p50/p95/p99 wall"
 :frontend 'tui
 :iterations 1000
 :budget 15
 :prepare #'cmacs-perf-edit--prepare-source
 :display t
 :warm #'cmacs-perf-edit--warm-typing
 :step 'cmacs-perf-edit--input-latency-step
 :latency t
 :primary 'latency_p99_us)

(cmacs-perf-edit--define
 "org-editing"
 :doc "Org TODO state, table alignment and fontification (plain markup)"
 :iterations 20
 :prepare #'cmacs-perf-edit--prepare-org
 :step 'cmacs-perf-edit--org-step
 :phases '(edit))

(cmacs-perf-edit--define
 "org-editing-heavy"
 :doc "Org editing over links, emphasis, source blocks and lists"
 :iterations 20
 :prepare #'cmacs-perf-edit--prepare-org-heavy
 :step 'cmacs-perf-edit--org-step
 :phases '(edit))

(defun cmacs-perf-edit--count-defuns ()
  "Return the defun count of the buffer, leaving point where it was."
  (save-excursion (cmacs-perf-edit--regex-phase)))

(defun cmacs-perf-edit--matches-failures (expected)
  "Return a failure list unless the last kept match count is EXPECTED."
  (cmacs-perf-expect nil "defun match count" cmacs-perf-edit--matches
                     expected))

(cmacs-perf-edit--define
 "large-file-editing"
 :doc "typing, regex search and line motion in an 8x source file"
 :iterations 20
 :prepare #'cmacs-perf-edit--prepare-large
 :step 'cmacs-perf-edit--large-file-step
 :phases '(type regex motion)
 :inspect #'cmacs-perf-edit--count-defuns
 ;; The type phase runs first and adds one `(defun sim--generated'.
 :extra-check (lambda (state _metrics)
                (cmacs-perf-edit--matches-failures
                 (1+ (plist-get state :inspect)))))

(cmacs-perf-edit--define
 "indentation"
 :doc "indent-region over 400 lines of Emacs Lisp"
 :iterations 50
 :prepare #'cmacs-perf-edit--prepare-source
 :step 'cmacs-perf-edit--indentation-step
 :phases '(indent))

(cmacs-perf-edit--define
 "regex-search"
 :doc "count every defun in the source with re-search-forward"
 :iterations 50
 :prepare #'cmacs-perf-edit--prepare-source
 :step 'cmacs-perf-edit--regex-step
 :phases '(regex)
 :inspect #'cmacs-perf-edit--count-defuns
 :extra-check (lambda (state _metrics)
                (let ((failures (cmacs-perf-edit--matches-failures
                                 (plist-get state :inspect))))
                  (unless (> (plist-get state :inspect) 0)
                    (push "the source holds no defuns" failures))
                  failures)))

(cmacs-perf-edit--define
 "process-output"
 :doc "call-process cat of the source: spawn, read, decode, insert"
 :iterations 20
 :prepare #'cmacs-perf-edit--prepare-empty
 :step 'cmacs-perf-edit--process-output-step
 :phases '(process)
 ;; One untimed read gives the size every timed read must reproduce,
 ;; decoded under the same process coding system.
 :inspect (lambda ()
            (unless (executable-find "cat")
              (error "process-output needs cat on PATH"))
            (cmacs-perf-edit--read-process-output))
 :extra-check (lambda (state _metrics)
                (let ((expected (plist-get state :inspect))
                      (failures nil))
                  (unless (and (eql (car expected) 0) (> (cdr expected) 0))
                    (push (format "untimed cat read returned %S" expected)
                          failures))
                  (cmacs-perf-expect failures "last cat read"
                                     cmacs-perf-edit--last-output expected))))

(cmacs-perf-edit--define
 "file-open"
 :doc "insert-file-contents, then mode + one screenful of fontification"
 :iterations 20
 :prepare #'cmacs-perf-edit--prepare-empty
 :step 'cmacs-perf-edit--file-open-step
 :phases '(insert fontify)
 :inspect (lambda ()
            (with-temp-buffer
              (insert-file-contents cmacs-perf-edit--source)
              (cons 'emacs-lisp-mode (buffer-size))))
 :extra-check (lambda (state _metrics)
                (cmacs-perf-expect nil "last opened buffer (mode . size)"
                                   cmacs-perf-edit--last-output
                                   (plist-get state :inspect))))

(cmacs-perf-edit--define
 "lsp-json-rpc"
 :doc "json-serialize + json-parse-string of 120 LSP diagnostics"
 :iterations 200
 :prepare (lambda ()
            ;; Build the payload once: the workload times the round
            ;; trip, not the construction of the object graph.
            (setq cmacs-perf-edit--lsp-payload
                  (cmacs-perf-edit--lsp-message 120))
            (fundamental-mode))
 :step 'cmacs-perf-edit--lsp-step
 :phases '(json)
 :extra-check (lambda (_state _metrics)
                (cmacs-perf-expect nil "parsed payload equals the sent one"
                                   (equal cmacs-perf-edit--lsp-last
                                          cmacs-perf-edit--lsp-payload)
                                   t)))

(provide 'cmacs-perf-editing)

;;; cmacs-perf-editing.el ends here
