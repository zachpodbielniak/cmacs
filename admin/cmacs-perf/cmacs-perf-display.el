;;; cmacs-perf-display.el --- cmacs-perf: redisplay and command-loop workloads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; Copyright (C) 2026 Eval Exec and the neomacs contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Workloads whose cost is redisplay and the interactive command loop,
;; so they run in a real `emacs -nw' frame (frontend `tui').  Ported
;; from neomacs-perf's scrolling.el, scrolling-content.el (with the
;; contract of scrolling-content-tests.el folded into the CHECK) and
;; mx-tab-completion.el (GPL-3.0-or-later), plus the invariants their
;; Rust adapters (src/harness/scenarios/scrolling.rs and mx_tab.rs)
;; enforced on the result.  The workloads and their invariants are
;; theirs, the registration form is cmacs-perf's.
;;
;; Dropped in the port: the TCP sampling gate, the result JSON and
;; SENTINEL writers, `kill-emacs' and the NEOMACS_PERF_GC_WINDOW_FILE
;; diagnostic -- the runtime (cmacs-perf.el) owns all of those.  The
;; per-run ".content.json" side file became metrics in the result.

;;; Code:

(require 'cl-lib)
(require 'cmacs-perf)

(defun cmacs-perf-display--require-frame (name)
  "Signal unless this Emacs has a real frame to redisplay.
NAME is the workload, for the message.  In batch mode `redisplay' does
nothing and there is no completion window, so a batch run would measure
something else entirely and report it under this workload's name."
  (when noninteractive
    (error "%s needs a terminal frame: run it with the tui frontend" name)))

;;;; Rich scrolling content (scrolling-content.el).

(defconst cmacs-perf-display--scroll-lines 2400
  "Scrolling buffer size in lines.
Large enough that one screenful is a tiny fraction of the buffer, so
scrolling keeps meeting rows the layout engine has not seen recently
instead of re-reading the same dozen.")

(defconst cmacs-perf-display--scroll-buffer "*cmacs-perf-scrolling*"
  "Name of the buffer the scrolling workload scrolls.")

(defconst cmacs-perf-display--font-candidates
  '("DejaVu Sans Mono" "DejaVu Serif" "DejaVu Sans"
    "Liberation Mono" "Liberation Serif" "Liberation Sans"
    "Consolas" "Arial" "Times New Roman"
    "Menlo" "Helvetica" "Times" "Georgia")
  "Font families the rich content picks its three families from, in order.")

(defun cmacs-perf-display--font-families ()
  "Return the three font families the rich content uses.
On a graphical frame they must really be installed: a silent fallback
to one font would make the workload cheaper than it claims to be.  A
terminal ignores families, so it uses the first three DejaVu names and
the summary labels the run terminal-face-attributes-only."
  (let* ((available (if (display-graphic-p)
                        (font-family-list)
                      '("DejaVu Sans Mono" "DejaVu Serif" "DejaVu Sans")))
         (families (cl-remove-if-not (lambda (family)
                                       (member family available))
                                     cmacs-perf-display--font-candidates)))
    (unless (>= (length families) 3)
      (error "rich scrolling needs three installed font families: %S"
             families))
    (cl-subseq families 0 3)))

(defun cmacs-perf-display--content-faces (families)
  "Return the six anonymous faces of the rich content over FAMILIES.
Between them they vary family, height, weight, slant, colours,
underline/overline/strike-through, a box and inverse video, so face
realisation has real work on every screenful."
  (vector
   `(:family ,(nth 0 families) :height 100 :weight normal
             :foreground "#b0c4de")
   `(:family ,(nth 1 families) :height 180 :weight bold
             :foreground "gold")
   `(:family ,(nth 2 families) :height 130 :slant italic
             :underline (:style wave :color "red"))
   `(:family ,(nth 0 families) :height 85 :weight light
             :background "#303050" :extend t)
   `(:family ,(nth 1 families) :height 150 :overline t
             :strike-through t :foreground "cyan")
   `(:family ,(nth 2 families) :height 120
             :box (:line-width 2 :color "orange") :inverse-video t)))

(defun cmacs-perf-display--content-block (faces)
  "Return a 1,000-line propertized block of text using FACES.
Each line carries a whole-line face, two nested sub-ranges with other
faces, every 7th a `line-height', every 11th a raised `display', and
every 16th a 180-column run of W that has to wrap.  The block is built
once and inserted repeatedly so setup cost does not grow with the
number of Lisp calls per character."
  (with-temp-buffer
    (dotimes (i 1000)
      (let ((start (point)))
        (insert (format "Line %03d -- buffer window layout office affinity "
                        i))
        (insert (if (= (% i 16) 0)
                    (make-string 180 ?W)
                  "café á 好好 שלום سلام"))
        (insert "\tredisplay overlay glyph cache\n")
        (put-text-property start (point) 'face (aref faces (% i 6)))
        (put-text-property (+ start 12) (+ start 26) 'face
                           (list (aref faces (% (+ i 1) 6)) '(:weight bold)))
        (put-text-property (+ start 27) (+ start 43) 'face
                           (aref faces (% (+ i 2) 6)))
        (when (= (% i 7) 0)
          (put-text-property (1- (point)) (point) 'line-height 1.3))
        (when (= (% i 11) 0)
          (put-text-property (+ start 5) (+ start 8) 'display
                             '(raise 0.2)))))
    (buffer-string)))

(defun cmacs-perf-display--insert-content (lines)
  "Insert LINES of deterministic mixed-font text and overlays at point.
Every 32 lines gets four overlays: an outer extended background over
three lines, a nested face with `mouse-face' and `help-echo', an empty
overlay carrying `before-string'/`after-string', and one that either
replaces text with a `display' string or hides it through
`buffer-invisibility-spec'.  Returns the content summary alist."
  (let* ((graphical (display-graphic-p))
         (families (cmacs-perf-display--font-families))
         (faces (cmacs-perf-display--content-faces families))
         (block (cmacs-perf-display--content-block faces))
         (overlay-count 0))
    (dotimes (_ (/ lines 1000))
      (insert block))
    ;; The remainder is a prefix of the same block, so line N always
    ;; carries the properties of line N mod 1000.
    (when (> (% lines 1000) 0)
      (insert (with-temp-buffer
                (insert block)
                (goto-char (point-min))
                (forward-line (% lines 1000))
                (buffer-substring (point-min) (point)))))
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (setq-local buffer-invisibility-spec '((cmacs-perf-scroll-fold . t)))
    (save-excursion
      (goto-char (point-min))
      (dotimes (i (/ (+ lines 31) 32))
        (let* ((start (point))
               (end (save-excursion (forward-line 3) (point)))
               (outer (make-overlay start end))
               (inner (make-overlay (+ start 12) (+ start 38)))
               (insertion (make-overlay (+ start 20) (+ start 20)))
               (special (make-overlay (+ start 40) (+ start 46))))
          (overlay-put outer 'priority 10)
          (overlay-put outer 'face '(:background "#243040" :extend t))
          (overlay-put inner 'priority 30)
          (overlay-put inner 'face (aref faces (% (+ i 3) 6)))
          (overlay-put inner 'mouse-face 'highlight)
          (overlay-put inner 'help-echo
                       "deterministic nested scrolling overlay")
          (overlay-put insertion 'before-string
                       (propertize "[before]"
                                   'face (aref faces (% (+ i 1) 6))))
          (overlay-put insertion 'after-string
                       (propertize "[after]"
                                   'face (aref faces (% (+ i 2) 6))))
          (overlay-put special 'priority 40)
          (if (= (% i 2) 0)
              (overlay-put special 'display
                           (propertize "replacement"
                                       'face (aref faces (% (+ i 4) 6))))
            (overlay-put special 'invisible 'cmacs-perf-scroll-fold))
          (setq overlay-count (+ overlay-count 4)))
        (forward-line 32)))
    `((profile . "rich-v1")
      (lines . ,lines)
      (font-families . ,(vconcat families))
      (font-selection . ,(if graphical
                             "installed"
                           "terminal-face-attributes-only"))
      (face-variants . ,(length faces))
      (overlays . ,overlay-count))))

(defun cmacs-perf-display--content-failures (summary lines)
  "Return failures of the rich-content contract for SUMMARY over LINES.
This is scrolling-content-tests.el run against the real buffer instead
of a stub: the line count, the overlay count, faces that repeat across
the 1,000-line block boundary, and every overlay property kind present.
Call it in the scrolling buffer."
  (let ((failures nil)
        (overlays (overlays-in (point-min) (point-max)))
        (expected-overlays (* 4 (/ (+ lines 31) 32))))
    (setq failures (cmacs-perf-expect failures "content line count"
                                      (count-lines (point-min) (point-max))
                                      lines))
    (setq failures (cmacs-perf-expect failures "content overlays"
                                      (length overlays) expected-overlays))
    (setq failures (cmacs-perf-expect failures "summary overlays"
                                      (alist-get 'overlays summary)
                                      expected-overlays))
    (setq failures (cmacs-perf-expect failures "summary font families"
                                      (length (alist-get 'font-families
                                                         summary))
                                      3))
    (unless (equal (alist-get 'font-selection summary)
                   (if (display-graphic-p)
                       "installed"
                     "terminal-face-attributes-only"))
      (push "font selection label does not match the frame" failures))
    ;; Line 0 and line 1000 must carry the same faces, and the whole-line
    ;; face must differ from the nested one, or the block repetition (or
    ;; the nesting) silently lost its properties.
    (when (> lines 1000)
      (save-excursion
        (let ((initial-face (get-text-property (point-min) 'face))
              (mixed-face (get-text-property (+ (point-min) 12) 'face)))
          (when (equal initial-face mixed-face)
            (push "nested face equals the line face" failures))
          (goto-char (point-min))
          (forward-line 1000)
          (unless (and (equal initial-face (get-text-property (point) 'face))
                       (equal mixed-face
                              (get-text-property (+ (point) 12) 'face)))
            (push "faces differ across the 1,000-line block boundary"
                  failures)))))
    (dolist (property '(before-string after-string display invisible
                                      priority mouse-face))
      (unless (cl-some (lambda (overlay) (overlay-get overlay property))
                       overlays)
        (push (format "no overlay carries `%s'" property) failures)))
    failures))

;;;; scrolling: C-v / M-v over the rich buffer, cold then warm.

(defun cmacs-perf-display--scroll-setup (_iterations)
  "Build and display the scrolling buffer; return the workload state.
The first frame is redisplayed here, untimed: the workload times
scrolling, not the first frame."
  (cmacs-perf-display--require-frame "scrolling")
  (let ((buffer (get-buffer-create cmacs-perf-display--scroll-buffer))
        (summary nil))
    (switch-to-buffer buffer)
    (delete-other-windows)
    (erase-buffer)
    (setq summary (cmacs-perf-display--insert-content
                   cmacs-perf-display--scroll-lines))
    (goto-char (point-min))
    (set-window-start nil (point-min))
    (redisplay t)
    (list :buffer buffer
          :summary summary
          :initial-point (point)
          :initial-checksum (cmacs-perf-checksum))))

(defun cmacs-perf-display--scroll-pass (command at-edge-p limit)
  "Run COMMAND, redisplaying after each, until AT-EDGE-P returns non-nil.
COMMAND is `scroll-up-command' or `scroll-down-command' -- what C-v
and M-v execute.  Returns the number of commands run; signals after
LIMIT of them, so a scroll that stops moving fails instead of hanging."
  (let ((count 0))
    (while (not (funcall at-edge-p))
      (when (>= count limit)
        (error "%s never reached the buffer edge in %d commands"
               command limit))
      (funcall command nil)
      (redisplay t)
      (setq count (1+ count)))
    count))

(defun cmacs-perf-display--at-end-p ()
  "Return non-nil when point is at the end of the buffer."
  (>= (point) (point-max)))

(defun cmacs-perf-display--at-start-p ()
  "Return non-nil when point is at the start of the buffer."
  (<= (point) (point-min)))

(defun cmacs-perf-display--scroll-body (state iterations)
  "Scroll the buffer cold once, then ITERATIONS warm passes down and up.
STATE is the setup's; its content summary is reported with the timings.
`scroll-error-top-bottom' is bound so the buffer-edge recovery is
window.el's own path and the loops end on position, not on an error.
The COLD pass is the first display of every line (face realisation and
first-time layout land there), so it is timed apart from the WARM
passes over rows already laid out.  One operation is one command."
  (let ((scroll-error-top-bottom t)
        (cold-commands 0)
        (warm-commands 0)
        (cold-us 0)
        (warm-us 0))
    (setq cold-us
          (cmacs-perf-time
           (lambda ()
             (setq cold-commands
                   (cmacs-perf-display--scroll-pass
                    #'scroll-up-command #'cmacs-perf-display--at-end-p
                    2000)))))
    (setq warm-us
          (cmacs-perf-time
           (lambda ()
             (dotimes (_ iterations)
               (goto-char (point-min))
               (set-window-start nil (point-min))
               (setq warm-commands
                     (+ warm-commands
                        (cmacs-perf-display--scroll-pass
                         #'scroll-up-command #'cmacs-perf-display--at-end-p
                         2000)
                        (cmacs-perf-display--scroll-pass
                         #'scroll-down-command
                         #'cmacs-perf-display--at-start-p
                         2000)))))))
    `((operations . ,(+ cold-commands warm-commands))
      (cold_scroll_commands . ,cold-commands)
      (warm_scroll_commands . ,warm-commands)
      (cold_scroll_cpu_us . ,cold-us)
      (warm_scroll_cpu_us . ,warm-us)
      (content_lines . ,(alist-get 'lines (plist-get state :summary)))
      (content_overlays . ,(alist-get 'overlays (plist-get state :summary)))
      (content_font_selection
       . ,(alist-get 'font-selection (plist-get state :summary))))))

(defun cmacs-perf-display--scroll-check (state metrics)
  "Return the scrolling invariants that failed, given STATE and METRICS.
Scrolling must not edit the buffer, must leave point and window start
where they began, and must have actually run both phases."
  (let* ((buffer (plist-get state :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (failures nil))
    (if (not (buffer-live-p buffer))
        (push "scrolling buffer was killed" failures)
      (with-current-buffer buffer
        (setq failures (cmacs-perf-expect failures "final buffer checksum"
                                          (cmacs-perf-checksum)
                                          (plist-get state :initial-checksum)))
        (setq failures (cmacs-perf-expect failures "point restored"
                                          (point)
                                          (plist-get state :initial-point)))
        (setq failures (cmacs-perf-expect failures "major mode"
                                          major-mode 'fundamental-mode))
        (setq failures
              (append (cmacs-perf-display--content-failures
                       (plist-get state :summary)
                       cmacs-perf-display--scroll-lines)
                      failures)))
      (setq failures (cmacs-perf-expect failures "window start restored"
                                        (and window (window-start window))
                                        1)))
    (dolist (key '(cold_scroll_commands warm_scroll_commands
                   cold_scroll_cpu_us warm_scroll_cpu_us))
      (unless (> (or (alist-get key metrics) 0) 0)
        (push (format "%s is not positive" key) failures)))
    failures))

(cmacs-perf-define
 "scrolling"
 :doc "C-v/M-v over a face- and overlay-rich buffer, cold then warm passes"
 :frontend 'tui
 :iterations 10
 :setup #'cmacs-perf-display--scroll-setup
 :body #'cmacs-perf-display--scroll-body
 :check #'cmacs-perf-display--scroll-check)

;;;; mx-tab-completion: M-x TAB over 1,024 controlled commands.

;; How the input reaches the command loop.  The runtime calls BODY from a
;; timer scheduled off `emacs-startup-hook', i.e. from inside the outer
;; command loop's wait for input.  `unread-command-events' would be the
;; wrong tool here: events pushed there are only read after the timer
;; returns, so the work would happen outside BODY and outside the gate.
;; `execute-kbd-macro' instead runs its own `command_loop_1' over the
;; key vector, synchronously: M-x reads the command name through a
;; recursive edit in the minibuffer, and that inner command loop also
;; takes its keys from the executing macro.  So the whole lifecycle --
;; M-x, typing, TAB, the *Completions* window, typing, RET, minibuffer
;; exit, the command itself -- runs and finishes inside one BODY call,
;; through exactly the keymaps and commands a user's keys go through.
;; (`execute-extended-command' also skips its "you can run this with"
;; suggestion timer while a macro is executing, so nothing is left
;; pending afterwards.)  This is the same mechanism the neomacs fixture
;; used from its own startup timer.

(defconst cmacs-perf-display--command-total 1024
  "How many identically shaped commands M-x TAB completes over.")

(defconst cmacs-perf-display--command-prefix "cmacs-perf-display--command-"
  "The prefix every controlled command shares, and the text typed before TAB.")

(defconst cmacs-perf-display--mx-keys
  (vconcat (kbd "M-x") cmacs-perf-display--command-prefix
           (kbd "TAB") "0000" (kbd "RET"))
  "One completion lifecycle: M-x, the prefix, TAB, a choice, RET.
Choosing the first no-op command after the completions are shown gives
every build the same normal minibuffer-exit path.")

(defconst cmacs-perf-display--mx-steady-warmup 5
  "Untimed warm-up completions run by `mx-tab-completion-steady'.")

(defvar cmacs-perf-display--mx-timed t
  "Non-nil while completions count toward the measurement.
During the warm-up pass the completion still runs in full -- caches
and the completion window machinery warm exactly as in a timed one --
but the advice records nothing.")

(defvar cmacs-perf-display--mx-stats nil
  "Plist of what the completion advice observed during the current run.")

(defvar cmacs-perf-display--mx-last-completions nil
  "Largest candidate list `completion-all-completions' produced this TAB.")

(defvar cmacs-perf-display--mx-current-count 0
  "Length of `cmacs-perf-display--mx-last-completions'.")

(defun cmacs-perf-display--controlled-command ()
  "Do nothing.  Every controlled M-x candidate is this command."
  (interactive))

(defun cmacs-perf-display--install-commands ()
  "Define the 1,024 controlled commands, PREFIX0000 to PREFIX1023."
  (dotimes (index cmacs-perf-display--command-total)
    (fset (intern (format "%s%04d" cmacs-perf-display--command-prefix index))
          #'cmacs-perf-display--controlled-command)))

(defun cmacs-perf-display--candidate-present-p (name candidates)
  "Return non-nil when NAME is an element of CANDIDATES.
CANDIDATES may be an improper list ending in a base-size integer, which
is why this walks conses instead of using `member'."
  (catch 'present
    (while (consp candidates)
      (when (equal name (car candidates))
        (throw 'present t))
      (setq candidates (cdr candidates)))
    nil))

(defun cmacs-perf-display--capture-completions (original &rest arguments)
  "Around advice on `completion-all-completions'; call ORIGINAL with ARGUMENTS.
A completion style may make nested calls, so keep the largest candidate
spine any call produced during this TAB from the minibuffer."
  (let ((completions (apply original arguments)))
    (when (and (minibufferp) (consp completions))
      (let ((count (safe-length completions)))
        (when (> count cmacs-perf-display--mx-current-count)
          (setq cmacs-perf-display--mx-current-count count
                cmacs-perf-display--mx-last-completions completions))))
    completions))

(defun cmacs-perf-display--mx-note (key value)
  "Set KEY to VALUE in `cmacs-perf-display--mx-stats'."
  (setq cmacs-perf-display--mx-stats
        (plist-put cmacs-perf-display--mx-stats key value)))

(defun cmacs-perf-display--mx-and (key value)
  "AND VALUE into the boolean KEY of `cmacs-perf-display--mx-stats'."
  (cmacs-perf-display--mx-note
   key (and (plist-get cmacs-perf-display--mx-stats key) value t)))

(defun cmacs-perf-display--around-completion-help (original &rest arguments)
  "Around advice on `minibuffer-completion-help'.
Call ORIGINAL with ARGUMENTS and `redisplay', so the time is the point
at which the completion window is presentable, not merely the end of
candidate enumeration.  That span is accumulated as
:help-cpu-us; the window, mode and candidate checks run after its clock
stops, so the oracle's list walks cannot move the measurement."
  (if (not cmacs-perf-display--mx-timed)
      (progn
        (apply original arguments)
        (redisplay t)
        (cmacs-perf-display--mx-note
         :warmup-calls
         (1+ (plist-get cmacs-perf-display--mx-stats :warmup-calls))))
    (let* ((value nil)
           (elapsed (cmacs-perf-time
                     (lambda ()
                       (setq value (apply original arguments))
                       (redisplay t))))
           (count cmacs-perf-display--mx-current-count)
           (previous (plist-get cmacs-perf-display--mx-stats
                                :candidate-count)))
      (cmacs-perf-display--mx-note
       :help-cpu-us (+ elapsed (plist-get cmacs-perf-display--mx-stats
                                          :help-cpu-us)))
      (cmacs-perf-display--mx-note
       :help-calls (1+ (plist-get cmacs-perf-display--mx-stats :help-calls)))
      (cmacs-perf-display--mx-and
       :completion-visible (get-buffer-window "*Completions*" t))
      (cmacs-perf-display--mx-and
       :completion-mode-correct
       (and (get-buffer "*Completions*")
            (with-current-buffer "*Completions*"
              (derived-mode-p 'completion-list-mode))))
      (cmacs-perf-display--mx-and
       :candidate-count-stable (or (null previous) (= previous count)))
      (cmacs-perf-display--mx-note :candidate-count count)
      (cmacs-perf-display--mx-and
       :known-commands-present
       (and (cmacs-perf-display--candidate-present-p
             (format "%s%04d" cmacs-perf-display--command-prefix 0)
             cmacs-perf-display--mx-last-completions)
            (cmacs-perf-display--candidate-present-p
             (format "%s%04d" cmacs-perf-display--command-prefix
                     (1- cmacs-perf-display--command-total))
             cmacs-perf-display--mx-last-completions)))
      value)))

(defun cmacs-perf-display--mx-complete-once ()
  "Run one M-x TAB lifecycle through the real command loop."
  (setq cmacs-perf-display--mx-last-completions nil
        cmacs-perf-display--mx-current-count 0)
  (execute-kbd-macro cmacs-perf-display--mx-keys))

(defun cmacs-perf-display--mx-setup (name warmup)
  "Return a SETUP function for M-x workload NAME with WARMUP completions.
It installs the commands and the advice, then runs WARMUP untimed
completions before the gate opens, so a profile never attributes them
to the workload."
  (lambda (_iterations)
    (cmacs-perf-display--require-frame name)
    (cmacs-perf-display--install-commands)
    (setq cmacs-perf-display--mx-stats
          (list :help-cpu-us 0 :help-calls 0 :warmup-calls 0
                :candidate-count nil
                :completion-visible t :completion-mode-correct t
                :known-commands-present t :candidate-count-stable t))
    (advice-add 'minibuffer-completion-help :around
                #'cmacs-perf-display--around-completion-help)
    (advice-add 'completion-all-completions :around
                #'cmacs-perf-display--capture-completions)
    (let ((cmacs-perf-display--mx-timed nil))
      (dotimes (_ warmup)
        (cmacs-perf-display--mx-complete-once)))
    (list :buffer (current-buffer) :warmup warmup)))

(defun cmacs-perf-display--mx-body (state iterations)
  "Run ITERATIONS M-x TAB lifecycles; STATE holds the starting buffer.
After each one the completion window must be gone, the minibuffer
exited and the original buffer current again."
  (let ((initial-buffer (plist-get state :buffer))
        (hidden t) (depth-restored t) (buffer-restored t) (completed 0))
    (dotimes (_ iterations)
      (cmacs-perf-display--mx-complete-once)
      (setq hidden (and hidden (not (get-buffer-window "*Completions*" t)))
            depth-restored (and depth-restored (zerop (minibuffer-depth)))
            buffer-restored (and buffer-restored
                                 (eq initial-buffer (current-buffer)))
            completed (1+ completed)))
    (let ((stats cmacs-perf-display--mx-stats))
      `((completed . ,completed)
        (completion_help_cpu_us . ,(plist-get stats :help-cpu-us))
        (per_completion_cpu_us
         . ,(/ (float (plist-get stats :help-cpu-us))
               (max 1 (plist-get stats :help-calls))))
        (completion_help_calls . ,(plist-get stats :help-calls))
        (warmup_completion_help_calls . ,(plist-get stats :warmup-calls))
        (completion_candidate_count
         . ,(or (plist-get stats :candidate-count) 0))
        (completion_visible . ,(plist-get stats :completion-visible))
        (completion_mode_correct
         . ,(plist-get stats :completion-mode-correct))
        (known_commands_present
         . ,(plist-get stats :known-commands-present))
        (candidate_count_stable
         . ,(plist-get stats :candidate-count-stable))
        (completion_hidden_after_exit . ,hidden)
        (minibuffer_depth_restored . ,depth-restored)
        (selected_buffer_restored . ,buffer-restored)))))

(defun cmacs-perf-display--mx-teardown (_state)
  "Remove the M-x TAB workload's advice.
Runs after CHECK and also when SETUP or BODY signalled, so a failed run
never leaves completion advised."
  (advice-remove 'minibuffer-completion-help
                 #'cmacs-perf-display--around-completion-help)
  (advice-remove 'completion-all-completions
                 #'cmacs-perf-display--capture-completions))

(defun cmacs-perf-display--mx-check (state metrics)
  "Return the M-x TAB invariants that failed, given STATE and METRICS.
One TAB must
show one completion window per lifecycle, over exactly the 1,024
controlled commands, and every lifecycle must restore the editor.  The
warm-up count tells the two rows apart: zero for the cold row, the
configured count for the steady one."
  (let ((failures nil)
        (completed (alist-get 'completed metrics)))
    (setq failures (cmacs-perf-expect failures "completion help calls"
                                      (alist-get 'completion_help_calls
                                                 metrics)
                                      completed))
    (setq failures (cmacs-perf-expect failures "warm-up completion calls"
                                      (alist-get 'warmup_completion_help_calls
                                                 metrics)
                                      (plist-get state :warmup)))
    (setq failures (cmacs-perf-expect failures "completion candidate count"
                                      (alist-get 'completion_candidate_count
                                                 metrics)
                                      cmacs-perf-display--command-total))
    (dolist (key '(completion_visible completion_mode_correct
                   known_commands_present candidate_count_stable
                   completion_hidden_after_exit minibuffer_depth_restored
                   selected_buffer_restored))
      (unless (alist-get key metrics)
        (push (format "%s does not hold" key) failures)))
    (unless (> (or (alist-get 'completion_help_cpu_us metrics) 0) 0)
      (push "completion help time is not positive" failures))
    failures))

(cmacs-perf-define
 "mx-tab-completion"
 :doc "M-x TAB over 1,024 commands through a real minibuffer, cold"
 :frontend 'tui
 :iterations 5
 :setup (cmacs-perf-display--mx-setup "mx-tab-completion" 0)
 :body #'cmacs-perf-display--mx-body
 :check #'cmacs-perf-display--mx-check
 :teardown #'cmacs-perf-display--mx-teardown
 :primary 'per_completion_cpu_us)

;; The same lifecycle after an untimed warm-up pass.  The cold row
;; measures start-up plus warm-up -- a real first completion -- and at
;; its default five calls its medians wander; this row measures the
;; steady per-completion cost that warm-up otherwise buries.  The two
;; are complementary, never substitutes.
(cmacs-perf-define
 "mx-tab-completion-steady"
 :doc "M-x TAB over 1,024 commands after an untimed warm-up pass"
 :frontend 'tui
 :iterations 50
 :setup (cmacs-perf-display--mx-setup "mx-tab-completion-steady"
                                      cmacs-perf-display--mx-steady-warmup)
 :body #'cmacs-perf-display--mx-body
 :check #'cmacs-perf-display--mx-check
 :teardown #'cmacs-perf-display--mx-teardown
 :primary 'per_completion_cpu_us)

(provide 'cmacs-perf-display)

;;; cmacs-perf-display.el ends here
