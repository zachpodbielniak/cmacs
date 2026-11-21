;;; cmacs-journal-daily.el --- The day's note, written from the activity journal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "What did I work on today", as an Org note in the PARA notes tree.
;;
;;   `cmacs-journal-daily'          write (or refresh) one day's note.
;;   `cmacs-journal-weekly'         the same over an ISO week.
;;   `cmacs-journal-daily-preview'  show the subtree, write nothing.
;;   `cmacs-journal-daily-mode'     opt-in: write yesterday's note at the
;;                                  first activity of a new day, and/or
;;                                  today's at a set time.
;;
;; THE NOTE HAS TWO PARTS, AND ONLY ONE OF THEM NEEDS A MODEL.
;;
;;   FACTS    computed here with no model at all, from the journal's
;;            spans: time per project, application and site, a timeline
;;            of the day's blocks, the longest stretches, files, pages,
;;            finished agent runs, first and last activity, idle time.
;;            The totals are `cmacs-journal-summarize''s -- the report
;;            and the note cannot disagree, because there is one adder.
;;
;;   SUMMARY  optional prose a model writes FROM THOSE FACTS ONLY.  Off
;;            by default (`cmacs-journal-daily-summary').  The default
;;            provider is a local one (ollama); a provider that is not
;;            local is refused unless `cmacs-journal-daily-allow-remote'
;;            says otherwise, and then asks first.  A day never leaves
;;            the machine because a default changed.
;;
;; FOUR PROPERTIES THIS FILE KEEPS:
;;
;;   * TODAY'S RULES, NOT YESTERDAY'S.  A span was filtered when it was
;;     recorded, under the rules of that moment.  Every event read here
;;     goes through `cmacs-redact-event' again before a single total is
;;     computed, and every string of the model prompt through
;;     `cmacs-redact-text' after that.  A title recorded last week,
;;     before you wrote the rule that hides it, is in neither the note
;;     nor the prompt.
;;
;;   * FAIL CLOSED.  No usable rule set, no note -- the journal's own
;;     posture.  A day with no events writes nothing either.
;;
;;   * THE FILE IS YOURS.  A daily you wrote by hand is never reordered
;;     or overwritten.  This owns exactly one subtree, marked with the
;;     property `CMACS_JOURNAL_DAILY', and replaces that subtree in
;;     place; a second run the same day changes nothing else, and
;;     nothing at all when the facts did not change.  If the file is
;;     open with unsaved edits, the subtree goes into that buffer and
;;     saving is left to you.
;;
;;   * THE PERSON AT THE KEYBOARD ONLY.  There is no agent tool.  The
;;     commands refuse to run for an agent or a remote caller
;;     (`cmacs-journal-agent-context-p'), and the mode's timer does
;;     nothing while one is being served.
;;
;; Everything automatic runs from a timer, never from a gowl hook: a
;; note is file I/O, and the compositor's hooks do none.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-journal)
(require 'cmacs-journal-report)
(require 'cmacs-para)

(declare-function cmacs-redact-event "cmacs-redact" (plist))
(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function cmacs-redact-ready-p "cmacs-redact" ())
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback &optional executor))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-config-base-url "cmacs-ai-config.c" (provider))
(declare-function cmacs-voice-define-command "cmacs-voice-commands"
                  (regexp function &optional doc append &rest props))
(declare-function org-read-date "org" (&rest args))
(declare-function org-mode "org" ())
(declare-function org-find-property "org" (property &optional value))
(declare-function org-at-heading-p "org" (&optional invisible-not-ok))
(declare-function org-end-of-subtree "org"
                  (&optional invisible-ok to-heading element))
(declare-function org-id-uuid "org-id" ())

;; Special variables of other files that are let-bound here.  Without
;; these lines the bindings would be lexical and do nothing.
(defvar cmacs-redact--as-model)
(defvar cmacs-journal-context-lookback-days)
(defvar cmacs-ai-openai-compatible-endpoints)
(defvar org-inhibit-startup)
(defvar org-mode-hook)

(defgroup cmacs-journal-daily nil
  "The day's note, written from the activity journal."
  :group 'cmacs-journal
  :prefix "cmacs-journal-daily-")

;;;; Where the note goes

(defcustom cmacs-journal-daily-directory "02_areas/dailies"
  "Directory the daily and weekly notes are written in.
A relative name is resolved against the first of `cmacs-para-roots'."
  :type 'string)

(defcustom cmacs-journal-daily-heading "Activity"
  "Heading of the subtree a daily note's facts are written under."
  :type 'string)

(defcustom cmacs-journal-daily-weekly-heading "Activity this week"
  "Heading of the subtree a weekly note's facts are written under."
  :type 'string)

(defcustom cmacs-journal-daily-author nil
  "Value of `#+authors:' in a note this creates, or nil to work it out.
Nil means `cmacs-secondbrain-ingest-author' when that is set, else
`user-full-name', else the login name."
  :type '(choice (const :tag "Work it out" nil) string))

(defcustom cmacs-journal-daily-categories "dailies"
  "Value of `#+categories:' in a note this creates."
  :type 'string)

(defcustom cmacs-journal-daily-link-notes t
  "Non-nil means a touched file that is a note is linked by its `id:'.
Only for a local `.org' file inside one of `cmacs-para-roots': the first
2000 characters of the file are read for its `:ID:'.  Every other file
is a `file:' link, and nothing else on disk is ever looked at."
  :type 'boolean)

;;;; What the facts hold

(defcustom cmacs-journal-daily-block-gap 300
  "Seconds of gap a block of the timeline may span.
Spans of one project (or one application, outside any project) closer
together than this are one block, and a look elsewhere shorter than
this in the middle of a block does not split it."
  :type 'number)

(defcustom cmacs-journal-daily-block-min 60
  "Blocks with less active time than this (seconds) are not listed.
Their time still counts in every total."
  :type 'number)

(defcustom cmacs-journal-daily-max-rows 12
  "Most rows a time table shows; the rest are summed as `(other)'."
  :type 'integer)

(defcustom cmacs-journal-daily-max-files 25
  "Most files the note lists, longest first."
  :type 'integer)

(defcustom cmacs-journal-daily-max-urls 25
  "Most pages the note lists, longest first."
  :type 'integer)

(defcustom cmacs-journal-daily-stretches 3
  "How many of the longest focus stretches the note names."
  :type 'integer)

;;;; The summary

(defcustom cmacs-journal-daily-summary nil
  "Non-nil means a model also writes a short summary from the facts.

Nil, the default, writes the facts and involves no model.  With this
set, the facts are written first and the summary is added to the same
subtree when the model answers; a failed or refused summary leaves the
facts as they are.

The model is `cmacs-journal-daily-provider' / `cmacs-journal-daily-model'.
It is given the facts -- the same lines the note shows -- and nothing
else."
  :type 'boolean)

(defcustom cmacs-journal-daily-provider 'ollama
  "The cmacs-ai provider that writes the summary.
The default is local.  One that is not local is used only as
`cmacs-journal-daily-allow-remote' permits; see
`cmacs-journal-daily-provider-local-p' for what counts."
  :type 'symbol)

(defcustom cmacs-journal-daily-model "qwen3.5:9b"
  "Model for the summary, or nil for the provider's default."
  :type '(choice (const :tag "Provider default" nil) string))

(defcustom cmacs-journal-daily-allow-remote nil
  "Whether the day's facts may be sent to a provider that is not local.

  nil       never.  With a remote provider configured, the facts are
            written and the summary is left out, with a message.
  t         yes, after a yes-or-no question naming the provider, each
            time.  A note written by `cmacs-journal-daily-mode' cannot
            ask, so it gets no summary.
  `always'  yes, without asking, automatic notes included.

This is its own option, apart from `cmacs-journal-daily-provider', so
that changing the provider can never by itself send a day anywhere."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Ask each time" t)
                 (const :tag "Without asking" always)))

(defcustom cmacs-journal-daily-local-hosts
  '("localhost" "127.0.0.1" "::1" "[::1]" "0.0.0.0")
  "Hosts a model server may be on and still count as local.
Any 127.x.y.z address counts too.  Add the name of a machine of your own
here only if a day's facts going to it is the same to you as staying
on this one."
  :type '(repeat string))

(defcustom cmacs-journal-daily-summary-timeout 600
  "Seconds to wait for the summary before giving up on it."
  :type 'number)

(defcustom cmacs-journal-daily-summary-prompt
  "You write the short summary at the top of a person's private daily note. \
You are given facts computed from their activity log: time per project, \
application and site, a timeline, files, pages and finished agent runs. \
Write three to six plain sentences, in the first person and the past tense, \
saying what the day went to and in what order. Use only the facts given: \
do not guess at intent, do not invent details, do not give advice. \
No headings, no lists, no Markdown."
  "System prompt for the summary."
  :type 'string)

;;;; When

(defcustom cmacs-journal-daily-write-yesterday t
  "Non-nil means `cmacs-journal-daily-mode' writes yesterday's note.
It does so at the first recorded activity of a new day, by which time
yesterday's last span has closed."
  :type 'boolean)

(defcustom cmacs-journal-daily-time nil
  "Time of day `cmacs-journal-daily-mode' writes today's note, or nil.
A string \"HH:MM\" (24-hour, local).  Nil writes nothing for today."
  :type '(choice (const :tag "Do not write today's note" nil) string))

(defcustom cmacs-journal-daily-check-interval 300
  "Seconds between `cmacs-journal-daily-mode''s looks at the clock."
  :type 'number)

(defconst cmacs-journal-daily--marker "CMACS_JOURNAL_DAILY"
  "The property that marks the one subtree this file owns in a note.")

(defconst cmacs-journal-daily--updated "CMACS_JOURNAL_UPDATED"
  "The property holding when the owned subtree was last written.")

;;;; Small text helpers

(defun cmacs-journal-daily--clean (string)
  "STRING on one line, trimmed; the empty string for a non-string."
  (if (stringp string)
      (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " string))
    ""))

(defun cmacs-journal-daily--link-text (string)
  "STRING made safe as the description of an Org link."
  (string-replace "]" ")" (string-replace "[" "(" (cmacs-journal-daily--clean
                                                   string))))

(defun cmacs-journal-daily--cell (string)
  "STRING made safe as an Org table cell."
  (string-replace "|" "\\vert{}" (cmacs-journal-daily--clean string)))

(defun cmacs-journal-daily--timestamp (&optional time)
  "TIME (default now) as ISO 8601 with a numeric offset."
  (format-time-string "%FT%T%z" (or time (cmacs-journal--now))))

(defun cmacs-journal-daily--clock (time)
  "TIME as HH:MM."
  (format-time-string "%H:%M" time))

;;;; Reading the journal

(defun cmacs-journal-daily--clip (event from to)
  "A copy of EVENT cut to FROM..TO, or nil when nothing of it is inside.
A span that crosses midnight belongs to both days, a part to each."
  (let* ((start (max from (plist-get event :time)))
         (end (min to (or (plist-get event :end) (plist-get event :time)))))
    (when (>= end start)
      (let ((copy (copy-sequence event)))
        (setq copy (plist-put copy :time start))
        (setq copy (plist-put copy :end end))
        (plist-put copy :duration (- end start))))))

(defun cmacs-journal-daily--events (from to)
  "The journal's events in FROM..TO as they may be shown TODAY.

Each event goes through `cmacs-redact-event' as model-facing text
does, whoever is calling: the rule set may have gained a rule since the
span was recorded, and what a note says is what every later reader of
the notes -- an index, an agent, a model -- is shown.  An event the
rules exclude now is as if it had never been recorded."
  (require 'cmacs-redact)
  (let ((out nil))
    (dolist (event (cmacs-journal-events from to))
      (let ((shown (let ((cmacs-redact--as-model t))
                     (cmacs-redact-event event))))
        (when shown
          (let ((cut (if (eq (plist-get shown :kind) 'agent)
                         ;; A finished run is a point, not a stretch.
                         (and (>= (plist-get shown :time) from)
                              (<= (plist-get shown :time) to)
                              (copy-sequence shown))
                       (cmacs-journal-daily--clip shown from to))))
            (when cut (push cut out))))))
    (nreverse out)))

;;;; Facts

(defun cmacs-journal-daily--context-before (time)
  "The named context already active at TIME, as it may be shown today.
The switch is looked for in the report's bounded lookback, and goes
through `cmacs-redact-event' like every event read here: a context a
rule now excludes is no context, and one a rule renames has its new
name."
  (require 'cmacs-redact)
  (let ((found nil))
    (dolist (event (cmacs-journal-events
                    (- time (* 86400
                               (max 0 cmacs-journal-context-lookback-days)))
                    time))
      (when (and (eq (plist-get event :kind) 'context)
                 (<= (plist-get event :time) time))
        (setq found event)))
    (and found
         (let ((shown (let ((cmacs-redact--as-model t))
                        (cmacs-redact-event found))))
           (and shown (cmacs-journal--context-label shown))))))

(defun cmacs-journal-daily--label (event)
  "What a timeline block holding EVENT is called: its project, else app."
  (let ((project (plist-get event :project))
        (app (plist-get event :app)))
    (cond ((and (stringp project) (not (string-empty-p project))) project)
          ((and (stringp app) (not (string-empty-p app))) app)
          (t "(unknown)"))))

(defun cmacs-journal-daily-blocks (events &optional gap)
  "Merge EVENTS, oldest first, into the blocks of a timeline.

A block is a plist (:start :end :label :active :context): a stretch
given to one project or application, in one named context (see
`cmacs-journal-attribute-contexts'; nil when the events carry none).
Spans with the same label no more than GAP seconds apart (default
`cmacs-journal-daily-block-gap') are one block.
So are two such spans with something else between them, when that
something else is over within GAP: a minute in a chat window in the
middle of an afternoon's work is part of the afternoon.  `:active' is
the time actually spent on the label, without the interruption."
  (let ((gap (or gap cmacs-journal-daily-block-gap))
        (stack nil))
    (dolist (event events)
      (let* ((start (plist-get event :time))
             (end (or (plist-get event :end) start))
             (duration (or (plist-get event :duration) (- end start)))
             (label (cmacs-journal-daily--label event))
             (context (plist-get event :context))
             (top (car stack))
             (under (cadr stack))
             (same (lambda (block)
                     (and block
                          (equal (plist-get block :label) label)
                          ;; A switch of context ends a block even when
                          ;; the project stays the same.
                          (equal (plist-get block :context) context)
                          (<= (- start (plist-get block :end)) gap)))))
        (cond
         ((funcall same top)
          (plist-put top :end (max end (plist-get top :end)))
          (plist-put top :active (+ duration (plist-get top :active))))
         ;; Back on what was being done before a short look elsewhere:
         ;; the look is dropped as a block of its own.
         ((funcall same under)
          (pop stack)
          (plist-put under :end (max end (plist-get under :end)))
          (plist-put under :active (+ duration (plist-get under :active))))
         (t
          (push (list :start start :end end :label label :active duration
                      :context context)
                stack)))))
    (nreverse stack)))

(defun cmacs-journal-daily--host (url)
  "The host of URL, lower-cased, or nil when it has none."
  (let ((case-fold-search t))
    (and (stringp url)
         (string-match
          "\\`[a-z][a-z0-9+.-]*://\\(?:[^/@?#]*@\\)?\\(\\[[^]]+\\]\\|[^/:?#]+\\)"
          url)
         (downcase (match-string 1 url)))))

(defun cmacs-journal-daily--top (events field limit)
  "The values of FIELD over EVENTS as (VALUE SECONDS EVENT), longest first.
EVENT is the last one seen with that value.  At most LIMIT entries."
  (let ((table (make-hash-table :test #'equal)) out)
    (dolist (event events)
      (let ((value (plist-get event field)))
        (when (and (stringp value) (not (string-empty-p value)))
          (let ((cell (gethash value table)))
            (puthash value
                     (list (+ (or (car cell) 0)
                              (or (plist-get event :duration) 0))
                           event)
                     table)))))
    (maphash (lambda (value cell) (push (cons value cell) out)) table)
    (setq out (sort out (lambda (a b)
                          (or (> (nth 1 a) (nth 1 b))
                              (and (= (nth 1 a) (nth 1 b))
                                   (string< (car a) (car b)))))))
    (seq-take out (max 0 limit))))

(defun cmacs-journal-daily-facts (from to &optional span)
  "Everything the note says about FROM..TO, as a plist.  No model.

SPAN is `day' (the default) or `week'.  The keys:

  :from :to :span   the range asked for
  :count            events seen, of every kind
  :first :last      first and last moment of activity, or nil
  :active :idle     seconds of activity and of recorded idleness
  :projects :apps :sites :days :contexts
                    ((NAME . SECONDS) ...) from `cmacs-journal-summarize';
                    :contexts is nil when no named context applies to
                    the range
  :blocks           the timeline (`cmacs-journal-daily-blocks')
  :stretches        the longest blocks
  :files :urls      ((VALUE SECONDS EVENT) ...), longest first
  :runs             the `agent' events: finished brigade runs
  :checkpoints      how many arrangement checkpoints were taken

Only kinds in `cmacs-journal-report-kinds' are activity."
  (let* ((events (cmacs-journal-daily--events from to))
         ;; Spans cut at each switch of named context and marked with
         ;; the one they fall in.  The totals do not change: a cut span
         ;; is the same seconds in two pieces.
         (active (cl-remove-if-not
                  (lambda (e)
                    (memq (plist-get e :kind) cmacs-journal-report-kinds))
                  (cmacs-journal-attribute-contexts
                   events (cmacs-journal-daily--context-before from))))
         (in-context (cl-some (lambda (e) (plist-get e :context)) active))
         (of-kind (lambda (kind)
                    (cl-remove-if-not
                     (lambda (e) (eq (plist-get e :kind) kind)) events)))
         (sites (delq nil
                      (mapcar (lambda (e)
                                (let ((host (cmacs-journal-daily--host
                                             (plist-get e :url))))
                                  (and host (append (list :site host) e))))
                              active)))
         (blocks (cmacs-journal-daily-blocks active))
         (sum (lambda (list)
                (apply #'+ (mapcar (lambda (e) (or (plist-get e :duration) 0))
                                   list)))))
    (list :from from :to to :span (or span 'day)
          :count (length events)
          :first (and active (apply #'min (mapcar (lambda (e)
                                                    (plist-get e :time))
                                                  active)))
          :last (and active (apply #'max (mapcar (lambda (e)
                                                   (or (plist-get e :end)
                                                       (plist-get e :time)))
                                                 active)))
          :active (funcall sum active)
          :idle (funcall sum (funcall of-kind 'idle))
          :projects (cmacs-journal-summarize active 'project)
          :apps (cmacs-journal-summarize active 'app)
          :sites (cmacs-journal-summarize sites 'site)
          :days (cmacs-journal-summarize active 'day)
          :contexts (and in-context
                         (cmacs-journal-summarize active 'context))
          :blocks blocks
          :stretches (seq-take
                      (sort (cl-remove-if
                             (lambda (b) (< (plist-get b :active)
                                            cmacs-journal-daily-block-min))
                             (copy-sequence blocks))
                            (lambda (a b) (> (plist-get a :active)
                                             (plist-get b :active))))
                      (max 0 cmacs-journal-daily-stretches))
          :files (cmacs-journal-daily--top active :file
                                           cmacs-journal-daily-max-files)
          :urls (cmacs-journal-daily--top active :url
                                          cmacs-journal-daily-max-urls)
          :runs (funcall of-kind 'agent)
          :checkpoints (length (funcall of-kind 'checkpoint)))))

;;;; Rendering the facts as Org

(defun cmacs-journal-daily--capped (rows)
  "ROWS ((NAME . SECONDS) ...) cut to `cmacs-journal-daily-max-rows'.
What is cut is summed into one last row."
  (let ((limit (max 1 cmacs-journal-daily-max-rows)))
    (if (<= (length rows) limit)
        rows
      (append (seq-take rows limit)
              (list (cons "(other)"
                          (apply #'+ (mapcar #'cdr (nthcdr limit rows)))))))))

(defun cmacs-journal-daily--table (head rows)
  "An aligned Org table: HEAD a list of strings, ROWS lists of strings.
Aligned here, by width, so that no Org buffer is needed to make it and
realigning it in Org changes nothing."
  (let* ((all (cons head rows))
         (widths (apply #'cl-mapcar
                        (lambda (&rest column)
                          (apply #'max 1 (mapcar #'string-width column)))
                        all))
         (line (lambda (cells)
                 (concat "| "
                         (mapconcat
                          #'identity
                          (cl-mapcar
                           (lambda (cell width)
                             (concat cell
                                     (make-string
                                      (- width (string-width cell)) ?\s)))
                           cells widths)
                          " | ")
                         " |\n"))))
    (concat (funcall line head)
            "|" (mapconcat (lambda (w) (make-string (+ w 2) ?-)) widths "+")
            "|\n"
            (mapconcat line rows ""))))

(defun cmacs-journal-daily--time-table (title rows)
  "The Org table for ROWS ((NAME . SECONDS) ...) under column TITLE."
  (let ((total (apply #'+ (mapcar #'cdr rows))))
    (cmacs-journal-daily--table
     (list title "Time" "%")
     (mapcar (lambda (row)
               (list (cmacs-journal-daily--cell (car row))
                     (cmacs-journal--format-duration (cdr row))
                     (number-to-string
                      (if (> total 0)
                          (round (* 100.0 (/ (float (cdr row)) total)))
                        0))))
             (cmacs-journal-daily--capped rows)))))

(defun cmacs-journal-daily--note-id (file)
  "The `:ID:' of FILE when it is a local note in a PARA tree, or nil."
  (when (and cmacs-journal-daily-link-notes
             (string-suffix-p ".org" file)
             (not (file-remote-p file)))
    (let ((path (expand-file-name file)))
      (when (and (cmacs-para-root-for path)
                 (file-regular-p path)
                 (file-readable-p path))
        (ignore-errors
          (with-temp-buffer
            (insert-file-contents path nil 0 2000)
            (goto-char (point-min))
            (and (re-search-forward
                  "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)" nil t)
                 (match-string 1))))))))

(defun cmacs-journal-daily--file-link (file)
  "FILE as the note shows it: an `id:' link, a `file:' link, or text.
A name a rule hashed or rewrote is no longer a path and stays text."
  (let* ((file (cmacs-journal-daily--clean file))
         (name (cmacs-journal-daily--link-text
                (file-name-nondirectory (directory-file-name file)))))
    (cond
     ((or (not (string-match-p "\\`[~/]" file))
          (string-match-p "[][]" file))
      file)
     (t (let ((id (cmacs-journal-daily--note-id file)))
          (if id
              (format "[[id:%s][%s]]" id name)
            (format "[[file:%s][%s]]" file name)))))))

(defun cmacs-journal-daily--url-link (url title)
  "URL as an Org link described by TITLE; text when it is not a URL."
  (let* ((url (cmacs-journal-daily--clean url))
         (title (cmacs-journal-daily--link-text title))
         (text (if (string-empty-p title)
                   (or (cmacs-journal-daily--host url) url)
                 title)))
    (if (and (string-match-p "\\`[A-Za-z][A-Za-z0-9+.-]*:" url)
             (not (string-match-p "[][ ]" url)))
        (format "[[%s][%s]]" url (cmacs-journal-daily--link-text text))
      (if (string-empty-p title) url (format "%s (%s)" title url)))))

(defun cmacs-journal-daily--overview (facts)
  "One paragraph, one line: when the day began and ended, and the totals."
  (let* ((first (plist-get facts :first))
         (last (plist-get facts :last))
         (active (plist-get facts :active))
         (idle (plist-get facts :idle))
         (week (eq (plist-get facts :span) 'week))
         (stamp (if week "%a %H:%M" "%H:%M"))
         (rest (and first last (max 0 (- last first active idle)))))
    (concat
     (if first
         (format "First activity %s, last %s. Active %s, idle %s, not recorded %s."
                 (format-time-string stamp first)
                 (format-time-string stamp last)
                 (cmacs-journal--format-duration active)
                 (cmacs-journal--format-duration idle)
                 (cmacs-journal--format-duration rest))
       "No activity was recorded.")
     (let ((checkpoints (plist-get facts :checkpoints)))
       (if (> checkpoints 0)
           (format " %d arrangement checkpoint%s." checkpoints
                   (if (= checkpoints 1) "" "s"))
         ""))
     " Computed from the activity journal; this subtree is rewritten when the note is regenerated and nothing else in the file is touched.")))

(defun cmacs-journal-daily--block-line (block stamp)
  "The list item for timeline BLOCK, its times formatted with STAMP."
  (format "- %s--%s (%s) %s%s\n"
          (format-time-string stamp (plist-get block :start))
          (format-time-string (if (string-prefix-p "%a" stamp) "%H:%M" stamp)
                              (plist-get block :end))
          (cmacs-journal--format-duration (plist-get block :active))
          (cmacs-journal-daily--clean (plist-get block :label))
          (let ((context (cmacs-journal-daily--clean
                          (plist-get block :context))))
            (if (string-empty-p context) "" (format " [%s]" context)))))

(defun cmacs-journal-daily--sections (facts)
  "The fact sections of the note as ((TITLE . BODY) ...), empty ones left out."
  (let* ((week (eq (plist-get facts :span) 'week))
         (stamp (if week "%a %H:%M" "%H:%M"))
         (blocks (cl-remove-if
                  (lambda (b) (< (plist-get b :active)
                                 cmacs-journal-daily-block-min))
                  (plist-get facts :blocks)))
         (sections nil)
         (add (lambda (title body)
                (when (and body (not (string-empty-p body)))
                  (push (cons title body) sections)))))
    (when (and week (plist-get facts :days))
      (funcall add "Time by day"
               (cmacs-journal-daily--time-table "Day" (plist-get facts :days))))
    (when (plist-get facts :contexts)
      (funcall add "Time by context"
               (cmacs-journal-daily--time-table "Context"
                                                (plist-get facts :contexts))))
    (when (plist-get facts :projects)
      (funcall add "Time by project"
               (cmacs-journal-daily--time-table "Project"
                                                (plist-get facts :projects))))
    (when (plist-get facts :apps)
      (funcall add "Time by application"
               (cmacs-journal-daily--time-table "Application"
                                                (plist-get facts :apps))))
    (when (plist-get facts :sites)
      (funcall add "Time by site"
               (cmacs-journal-daily--time-table "Site"
                                                (plist-get facts :sites))))
    ;; A week's timeline is seven days of lines; its longest stretches
    ;; say what a reader of a weekly note wants from it.
    (unless week
      (funcall add "Timeline"
               (mapconcat (lambda (b)
                            (cmacs-journal-daily--block-line b stamp))
                          blocks "")))
    (funcall add "Longest focus stretches"
             (mapconcat (lambda (b) (cmacs-journal-daily--block-line b stamp))
                        (plist-get facts :stretches) ""))
    (funcall add "Files touched"
             (mapconcat
              (lambda (entry)
                (format "- %s (%s)\n"
                        (cmacs-journal-daily--file-link (car entry))
                        (cmacs-journal--format-duration (nth 1 entry))))
              (plist-get facts :files) ""))
    (funcall add "Pages visited"
             (mapconcat
              (lambda (entry)
                (format "- %s (%s)\n"
                        (cmacs-journal-daily--url-link
                         (car entry) (plist-get (nth 2 entry) :title))
                        (cmacs-journal--format-duration (nth 1 entry))))
              (plist-get facts :urls) ""))
    (funcall add "Agent runs finished"
             (mapconcat
              (lambda (run)
                (let ((title (cmacs-journal-daily--clean
                              (plist-get run :title)))
                      (state (cmacs-journal-daily--clean
                              (plist-get run :detail))))
                  (format "- %s %s%s%s\n"
                          (format-time-string stamp (plist-get run :time))
                          (cmacs-journal-daily--clean
                           (or (plist-get run :app) "agent"))
                          (if (string-empty-p title) "" (concat ": " title))
                          (if (string-empty-p state) ""
                            (format " (%s)" state)))))
              (plist-get facts :runs) ""))
    (nreverse sections)))

(defun cmacs-journal-daily-render (facts &optional summary credit)
  "The Org subtree for FACTS: the one subtree this file owns in a note.

SUMMARY, when a non-empty string, is a model's prose and goes first
under its own heading, with CREDIT (who wrote it) below.  The text ends
in exactly one newline and no line of prose is wrapped."
  (concat
   "* " (cmacs-journal-daily--clean
         (if (eq (plist-get facts :span) 'week)
             cmacs-journal-daily-weekly-heading
           cmacs-journal-daily-heading))
   "\n:PROPERTIES:\n"
   ":CUSTOM_ID: cmacs-journal-daily\n"
   ":" cmacs-journal-daily--marker ": t\n"
   ":" cmacs-journal-daily--updated ": " (cmacs-journal-daily--timestamp) "\n"
   ":END:\n"
   (cmacs-journal-daily--overview facts) "\n"
   (if (and (stringp summary) (not (string-blank-p summary)))
       (concat "\n** Summary\n" (string-trim summary) "\n"
               (if credit (concat "\n" credit "\n") ""))
     "")
   (mapconcat (lambda (section)
                (concat "\n** " (car section) "\n" (cdr section)))
              (cmacs-journal-daily--sections facts) "")))

;;;; The facts as plain text, for a model

(defun cmacs-journal-daily-prompt (facts title)
  "The user-turn text a model is given for FACTS; TITLE names the range.

Built from the same sections the note shows, so the model sees nothing
the note does not.  The whole of it is composed as model-facing text:
every line goes through `cmacs-redact-text', on top of the per-event
pass the facts already had.  When the rule set is not usable that makes
every line the withheld marker -- and `cmacs-journal-daily--run' never
gets this far in that case anyway."
  (require 'cmacs-redact)
  (let ((cmacs-redact--as-model t)
        (cmacs-journal-daily-link-notes nil))
    (let* ((plain
            ;; Links back to plain text: a model needs the title and the
            ;; address, not Org's brackets.
            (lambda (text)
              (replace-regexp-in-string
               "\\[\\[\\(?:file:\\|id:\\)?\\([^]]+\\)\\]\\[\\([^]]*\\)\\]\\]"
               "\\2 <\\1>" text)))
           (lines
            (append
             (list (concat "Range: " title)
                   (car (split-string
                         (cmacs-journal-daily--overview facts)
                         " Computed from" t)))
             (cl-mapcan
              (lambda (section)
                (cons (concat "\n" (car section) ":")
                      (split-string (funcall plain (cdr section)) "\n" t)))
              (cmacs-journal-daily--sections facts)))))
      (mapconcat (lambda (line)
                   (if (string-blank-p line) line (cmacs-redact-text line)))
                 lines "\n"))))

;;;; Where a note lives

(defun cmacs-journal-daily--directory ()
  "The directory notes are written in, absolute."
  (file-name-as-directory
   (if (file-name-absolute-p cmacs-journal-daily-directory)
       (expand-file-name cmacs-journal-daily-directory)
     (expand-file-name cmacs-journal-daily-directory
                       (or (car cmacs-para-roots)
                           (user-error "`cmacs-para-roots' is empty: there is nowhere to write a note"))))))

(defun cmacs-journal-daily--author ()
  "The `#+authors:' value for a note this creates."
  (or cmacs-journal-daily-author
      (let ((ingest (bound-and-true-p cmacs-secondbrain-ingest-author)))
        (and (stringp ingest) (not (string-empty-p ingest)) ingest))
      (and (stringp user-full-name) (not (string-empty-p user-full-name))
           user-full-name)
      user-login-name
      "unknown"))

(defun cmacs-journal-daily--new-id ()
  "A fresh UUID for an `:ID:'.
`org-id-uuid' and not `org-id-new': the latter runs uuidgen as a
synchronous subprocess, and this is reached from a timer."
  (require 'org-id)
  (org-id-uuid))

(defun cmacs-journal-daily--header (id title description categories)
  "The file header of a note: its `:ID:' drawer and the house keywords."
  (let ((now (cmacs-journal-daily--timestamp)))
    (concat ":PROPERTIES:\n:ID:       " id "\n:END:\n"
            "#+title: " title "\n"
            "#+description: " description "\n"
            "#+authors: " (cmacs-journal-daily--author) "\n"
            "#+categories: " categories "\n"
            "#+created: " now "\n"
            "#+updated: " now "\n"
            "#+version: 1.0.0\n")))

;;;; Changing a file without owning it

(defun cmacs-journal-daily--apply (file compute)
  "Make one edit to FILE, through whatever buffer has it open.

COMPUTE is called with the file's whole text (the empty string when
there is no file) and returns nil for \"leave it\" or a plist
\(:beg BEG :end END :new STRING): replace the characters BEG..END
\(1-based, as buffer positions of that text) by STRING.

Where the edit lands depends on who has the file:

  * a buffer visiting it with unsaved edits gets the edit and stays
    modified -- its text is the user's latest, the disk's is not, and
    saving their half-finished edits is not ours to do;
  * a buffer visiting it that matches the disk gets the same edit and
    the file is written from it, without running save hooks, so buffer
    and disk still agree and nothing else in the file was reformatted;
  * otherwise the file itself is edited.  A buffer that was already
    out of date with the disk is left as it was.

Returns `unchanged', `written', or `buffer-unsaved'."
  (let* ((buffer (find-buffer-visiting file))
         (modified (and buffer (buffer-modified-p buffer)))
         (in-sync (and buffer (not modified)
                       (verify-visited-file-modtime buffer))))
    (if (or modified in-sync)
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (let ((edit (funcall compute (buffer-substring-no-properties
                                            (point-min) (point-max))))
                    (inhibit-read-only t))
                (cond
                 ((null edit) 'unchanged)
                 (t
                  (goto-char (plist-get edit :beg))
                  (delete-region (plist-get edit :beg) (plist-get edit :end))
                  (insert (plist-get edit :new))
                  (if modified
                      'buffer-unsaved
                    (write-region nil nil file nil 'silent)
                    (set-visited-file-modtime)
                    (set-buffer-modified-p nil)
                    'written)))))))
      (let ((exists (file-exists-p file)))
        (with-temp-buffer
          (let ((coding 'utf-8-unix))
            (when exists
              (insert-file-contents file)
              (setq coding (or last-coding-system-used coding)))
            (let ((edit (funcall compute (buffer-string))))
              (cond
               ((null edit) 'unchanged)
               (t
                (goto-char (plist-get edit :beg))
                (delete-region (plist-get edit :beg) (plist-get edit :end))
                (insert (plist-get edit :new))
                (make-directory (file-name-directory file) t)
                (let ((coding-system-for-write coding))
                  (write-region nil nil file nil 'silent))
                'written)))))))))

(defmacro cmacs-journal-daily--with-org-text (text &rest body)
  "Run BODY in a temporary Org buffer holding TEXT.
No hooks, no startup options: the buffer is for Org's parser and for
nothing the user configured."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (require 'org)
     (let ((org-inhibit-startup t)
           (org-mode-hook nil))
       (delay-mode-hooks (org-mode)))
     (goto-char (point-min))
     ,@body))

(defun cmacs-journal-daily--locate ()
  "The (BEG . END) of the owned subtree in the current Org buffer, or nil.
END is just after the subtree's last line of text: blank lines between
it and what follows are the user's and stay."
  (let ((pos (org-find-property cmacs-journal-daily--marker)))
    (when pos
      (goto-char pos)
      ;; The marker in a file-level drawer is not a subtree to replace.
      (when (org-at-heading-p)
        (let ((beg (line-beginning-position)))
          (org-end-of-subtree t t)
          (skip-chars-backward " \t\n")
          (forward-line 1)
          (cons beg (max beg (point))))))))

(defun cmacs-journal-daily--comparable (subtree)
  "SUBTREE without what changes when the facts do not.
That is the time it was written and a model's summary."
  (with-temp-buffer
    (insert subtree)
    (goto-char (point-min))
    (when (re-search-forward
           (format "^:%s:.*\n" cmacs-journal-daily--updated) nil t)
      (replace-match ""))
    (goto-char (point-min))
    (when (re-search-forward "^\\*\\* Summary[ \t]*\n" nil t)
      (let ((beg (match-beginning 0)))
        (delete-region beg (if (re-search-forward "^\\*\\{1,2\\} " nil t)
                               (match-beginning 0)
                             (point-max)))))
    (string-trim (buffer-string))))

(defun cmacs-journal-daily--splice (file subtree header &optional force)
  "Put SUBTREE into FILE; HEADER is the file header if FILE is new.

The subtree marked `CMACS_JOURNAL_DAILY' is replaced where it stands;
without one, SUBTREE is appended.  When the facts in the file are
already these facts nothing is written, unless FORCE.  Returns a plist
\(:status STATUS :created BOOL :had-summary BOOL); STATUS is as
`cmacs-journal-daily--apply' returns."
  (let* ((created nil) (had-summary nil)
         (status
          (cmacs-journal-daily--apply
           file
           (lambda (text)
             (if (string-blank-p text)
                 (progn
                   (setq created t)
                   (list :beg 1 :end (1+ (length text))
                         :new (concat header "\n" subtree)))
               (let ((range (cmacs-journal-daily--with-org-text text
                              (cmacs-journal-daily--locate))))
                 (if range
                     (let ((old (substring text (1- (car range))
                                           (1- (cdr range)))))
                       (setq had-summary
                             (and (string-match-p "^\\*\\* Summary[ \t]*$" old)
                                  t))
                       (unless (and (not force)
                                    (equal (cmacs-journal-daily--comparable old)
                                           (cmacs-journal-daily--comparable
                                            subtree)))
                         (list :beg (car range) :end (cdr range)
                               :new subtree)))
                   (let ((end (1+ (length text))))
                     (list :beg end :end end
                           :new (concat (cond ((string-suffix-p "\n\n" text) "")
                                              ((string-suffix-p "\n" text) "\n")
                                              (t "\n\n"))
                                        subtree))))))))))
    (list :status status :created created :had-summary had-summary)))

;;;; The index

(defconst cmacs-journal-daily--months
  '("January" "February" "March" "April" "May" "June" "July" "August"
    "September" "October" "November" "December")
  "Month names as the dailies index spells its headings.")

(defun cmacs-journal-daily--month-key (heading)
  "HEADING (\"November 2026\") as a number that sorts by date, or nil."
  (when (string-match "\\`\\([A-Z][a-z]+\\) \\([0-9]\\{4\\}\\)\\'" heading)
    (let ((month (cl-position (match-string 1 heading)
                              cmacs-journal-daily--months :test #'equal)))
      (and month (+ (* 12 (string-to-number (match-string 2 heading)))
                    month)))))

(defun cmacs-journal-daily--index-edit (text id title time)
  "The edit that adds a bullet for note ID, titled TITLE, to index TEXT.

Nil when the index already links ID.  The bullet goes where the index's
own layout says, in this order:

  * under a heading for TIME's month (\"November 2026\"), kept in the
    order its bullets already have (newest first unless they plainly
    run the other way);
  * else under a new heading for that month, placed among the other
    month headings, newest first;
  * else after the last `id:' bullet in the file, or at its end."
  (let* ((bullet (format "- [[id:%s][%s]]" id
                         (cmacs-journal-daily--link-text title)))
         (month (format "%s %s"
                        (nth (1- (decoded-time-month (decode-time time)))
                             cmacs-journal-daily--months)
                        (format-time-string "%Y" time)))
         (key (cmacs-journal-daily--month-key month)))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (cond
       ((search-forward (format "[[id:%s]" id) nil t) nil)
       ;; The month is there: among its bullets.
       ((progn (goto-char (point-min))
               (re-search-forward
                (format "^\\*+ %s[ \t]*$" (regexp-quote month)) nil t))
        (let* ((after-heading (line-end-position))
               (section-end (save-excursion
                              (if (re-search-forward "^\\*+ " nil t)
                                  (match-beginning 0)
                                (point-max))))
               (bullets nil))
          (while (re-search-forward
                  "^- \\[\\[id:[^]]+\\]\\[\\([^]]*\\)\\]\\].*$" section-end t)
            (push (list (match-string 1) (line-beginning-position)
                        (line-end-position))
                  bullets))
          (setq bullets (nreverse bullets))
          (let* ((ascending (and (cdr bullets)
                                 (string< (car (nth 0 bullets))
                                          (car (nth 1 bullets)))))
                 (before (cl-find-if
                          (lambda (b)
                            (if ascending
                                (string< title (car b))
                              (string< (car b) title)))
                          bullets)))
            (cond
             (before (list :beg (nth 1 before) :end (nth 1 before)
                           :new (concat bullet "\n")))
             (bullets (let ((pos (nth 2 (car (last bullets)))))
                        (list :beg pos :end pos :new (concat "\n" bullet))))
             (t (list :beg after-heading :end after-heading
                      :new (concat "\n" bullet)))))))
       ;; Other months are there: a heading for this one, in its place.
       ((let ((months nil))
          (goto-char (point-min))
          (while (re-search-forward "^\\(\\*+\\) \\(.+?\\)[ \t]*$" nil t)
            ;; Taken before `cmacs-journal-daily--month-key' matches a
            ;; string of its own and replaces the match data.
            (let* ((pos (match-beginning 0))
                   (stars (match-string 1))
                   (k (cmacs-journal-daily--month-key (match-string 2))))
              (when k
                (push (list k pos stars) months))))
          (setq months (nreverse months))
          (when (and months key)
            (let* ((stars (nth 2 (car months)))
                   (older (cl-find-if (lambda (m) (< (car m) key)) months))
                   (block (concat stars " " month "\n" bullet "\n")))
              (if older
                  (list :beg (nth 1 older) :end (nth 1 older)
                        :new (concat block "\n"))
                ;; Older than every month listed: after the last one's
                ;; section.
                (goto-char (nth 1 (car (last months))))
                (forward-line 1)
                (let ((pos (if (re-search-forward
                                (format "^\\*\\{1,%d\\} " (length stars)) nil t)
                               (match-beginning 0)
                             (point-max))))
                  (list :beg pos :end pos
                        :new (concat (if (and (> pos 1)
                                              (eq (char-before pos) ?\n))
                                         "\n" "\n\n")
                                     block))))))))
       ;; No months: after the last id bullet, or at the end.
       ((progn (goto-char (point-max))
               (re-search-backward "^- \\[\\[id:.*$" nil t))
        (let ((pos (match-end 0)))
          (list :beg pos :end pos :new (concat "\n" bullet))))
       (t (let ((pos (point-max)))
            (list :beg pos :end pos
                  :new (concat (if (string-suffix-p "\n" text) "" "\n")
                               bullet "\n"))))))))

(defun cmacs-journal-daily--register-index (file id title time)
  "Add a bullet for the new note FILE (ID, TITLE) to its `00_index.org'.
TIME places it under a month.  A directory with no index gets one."
  (let* ((dir (file-name-directory file))
         (index (expand-file-name "00_index.org" dir))
         (name (file-name-nondirectory (directory-file-name dir))))
    (cmacs-journal-daily--apply
     index
     (lambda (text)
       (if (string-blank-p text)
           (list :beg 1 :end (1+ (length text))
                 :new (concat
                       (cmacs-journal-daily--header
                        (cmacs-journal-daily--new-id)
                        (concat (capitalize
                                 (replace-regexp-in-string
                                  "_" " "
                                  (replace-regexp-in-string "\\`[0-9]+_" ""
                                                            name)))
                                " Index")
                        (format "Index of %s" name)
                        "index")
                       "\n* Contents\n"
                       (format "- [[id:%s][%s]]\n" id
                               (cmacs-journal-daily--link-text title))))
         (cmacs-journal-daily--index-edit text id title time))))))

;;;; Is the provider local

(defun cmacs-journal-daily--host-local-p (spec)
  "Non-nil when SPEC, a URL or a HOST[:PORT], names this machine."
  (let* ((spec (string-trim spec))
         (host (or (cmacs-journal-daily--host spec)
                   (and (string-match
                         "\\`\\(\\[[^]]+\\]\\|[^/:]+\\)\\(?::[0-9]+\\)?/?\\'"
                         spec)
                        (downcase (match-string 1 spec))))))
    (and host
         (or (member host (mapcar #'downcase cmacs-journal-daily-local-hosts))
             (string-match-p "\\`127\\.[0-9]+\\.[0-9]+\\.[0-9]+\\'" host))
         t)))

(defun cmacs-journal-daily-provider-local-p (&optional provider)
  "Non-nil when PROVIDER runs its model on this machine.
PROVIDER defaults to `cmacs-journal-daily-provider'.  Local are:

  * `ollama', when the server it talks to is on a local host: the base
    URL ai-glib reports when this build can report one, else what the
    OLLAMA_HOST environment variable says (unset means localhost);
  * a name in `cmacs-ai-openai-compatible-endpoints' whose `:base-url'
    is on a local host.

Everything else -- hosted APIs, and the CLI agents, which call hosted
models -- is not.  Local hosts are `cmacs-journal-daily-local-hosts'.
When in doubt the answer is nil."
  (let ((provider (or provider cmacs-journal-daily-provider)))
    (condition-case nil
        (cond
         ((eq provider 'ollama)
          (let ((url (or (and (fboundp 'cmacs-ai-config-base-url)
                              (cmacs-ai-config-base-url 'ollama))
                         (getenv "OLLAMA_HOST"))))
            (or (not (stringp url)) (string-blank-p url)
                (cmacs-journal-daily--host-local-p url))))
         ((and (symbolp provider)
               (boundp 'cmacs-ai-openai-compatible-endpoints))
          (let ((url (plist-get (cdr (assq provider
                                           cmacs-ai-openai-compatible-endpoints))
                                :base-url)))
            (and (stringp url) (cmacs-journal-daily--host-local-p url)))))
      (error nil))))

(defun cmacs-journal-daily--ai-available-p ()
  "Non-nil when this cmacs can stream a chat completion."
  (and (require 'cmacs-ai nil t)
       (fboundp 'cmacs-ai-make-session)
       (fboundp 'cmacs-ai-chat-stream)))

(defun cmacs-journal-daily--model-name ()
  "The summary's provider and model as one name."
  (format "%s/%s" cmacs-journal-daily-provider
          (or cmacs-journal-daily-model "default")))

(defun cmacs-journal-daily--summary-decision (interactive)
  "Whether to ask a model for the summary: t, or a string saying why not.
Nil when no summary is wanted at all.  INTERACTIVE non-nil means there
is someone to ask."
  (cond
   ((not cmacs-journal-daily-summary) nil)
   ((not (cmacs-journal-daily--ai-available-p))
    "no summary: this cmacs has no cmacs-ai")
   ((cmacs-journal-daily-provider-local-p) t)
   ((null cmacs-journal-daily-allow-remote)
    (format "no summary: %s is not a local model and `cmacs-journal-daily-allow-remote' is nil"
            (cmacs-journal-daily--model-name)))
   ((eq cmacs-journal-daily-allow-remote 'always) t)
   ((not interactive)
    (format "no summary: sending the facts to %s needs a yes, and nobody was asked"
            (cmacs-journal-daily--model-name)))
   ((yes-or-no-p
     (format "%s is NOT a local model.  Send this note's facts to it (`cmacs-journal-daily-allow-remote' is on)? "
             (cmacs-journal-daily--model-name)))
    t)
   (t "no summary: not sent")))

;;;; The summary, asynchronously

(defvar cmacs-journal-daily--jobs nil
  "Summaries in flight: an alist of (ID . PLIST).
The stream callback holds the ID, not the job: a job that timed out is
gone from here and its late callback finds nothing to do.")

(defvar cmacs-journal-daily--job-counter 0
  "The last job ID handed out.")

(defun cmacs-journal-daily--summary-org (text)
  "A model's TEXT as Org prose that cannot break the subtree it goes in.

Reasoning a local model printed (<think>...</think>) is removed.  Each
paragraph becomes one line.  A line that would start a heading, a
keyword or a drawer loses the characters that would make it one, and
Markdown's `**bold**' becomes Org's.  The result goes through
`cmacs-redact-text' as model-facing text: a model can repeat something
back in a form the rules did not catch on the way in."
  (require 'cmacs-redact)
  (let* ((text (replace-regexp-in-string
                "<think>\\(?:.\\|\n\\)*?</think>" "" (or text "")))
         (text (replace-regexp-in-string "\\*\\*" "*" text))
         (paragraphs
          (mapcar
           (lambda (paragraph)
             (mapconcat
              (lambda (line)
                (replace-regexp-in-string
                 "\\`\\(?:\\*+[ \t]+\\|#+[ \t]*\\+?\\|[-+][ \t]+\\|:\\)" ""
                 (string-trim line)))
              (split-string paragraph "\n" t "[ \t]+")
              " "))
           (split-string (string-trim text) "\n[ \t]*\n" t)))
         (out (string-join (cl-remove-if #'string-blank-p paragraphs)
                           "\n\n")))
    (let ((cmacs-redact--as-model t))
      (cmacs-redact-text out))))

(defun cmacs-journal-daily--finish-summary (id &optional error)
  "Job ID is over: write its summary into the note, or report ERROR."
  (let ((job (alist-get id cmacs-journal-daily--jobs)))
    (when job
      (setq cmacs-journal-daily--jobs
            (assq-delete-all id cmacs-journal-daily--jobs))
      (when (timerp (plist-get job :timer))
        (cancel-timer (plist-get job :timer)))
      (ignore-errors (cmacs-ai-free-session (plist-get job :pair)))
      (let ((summary (and (not error)
                          (cmacs-journal-daily--summary-org
                           (plist-get job :text)))))
        (cond
         ((or error (string-blank-p summary))
          (message "cmacs-journal-daily: the facts are written; no summary (%s)"
                   (or error "the model returned nothing")))
         (t
          (condition-case err
              (let ((result
                     (cmacs-journal-daily--splice
                      (plist-get job :file)
                      (cmacs-journal-daily-render
                       (plist-get job :facts) summary
                       (format "Written by %s from the facts below."
                               (plist-get job :model)))
                      (plist-get job :header) t)))
                (message "cmacs-journal-daily: summary added to %s%s"
                         (abbreviate-file-name (plist-get job :file))
                         (if (eq (plist-get result :status) 'buffer-unsaved)
                             " (in its buffer, which has your unsaved edits; saving is left to you)"
                           "")))
            (error
             (message "cmacs-journal-daily: could not write the summary: %s"
                      (error-message-string err))))))))))

(defun cmacs-journal-daily--stream-callback (id payload)
  "Handle one cmacs-ai stream PAYLOAD for job ID."
  (let ((cell (assq id cmacs-journal-daily--jobs)))
    (when cell
      (pcase (car-safe payload)
        (:delta
         (setcdr cell (plist-put (cdr cell) :text
                                 (concat (plist-get (cdr cell) :text)
                                         (or (cadr payload) "")))))
        (:end
         (let ((final (plist-get (cdr payload) :text)))
           (when (and (stringp final)
                      (> (length (string-trim final))
                         (length (string-trim (plist-get (cdr cell) :text)))))
             (setcdr cell (plist-put (cdr cell) :text final))))
         (cmacs-journal-daily--finish-summary id))
        (:error
         (cmacs-journal-daily--finish-summary
          id (format "%s" (or (cadr payload) "stream error"))))))))

(defun cmacs-journal-daily--summary-timeout (id)
  "Job ID took too long: stop it."
  (let ((job (alist-get id cmacs-journal-daily--jobs)))
    (when job
      (ignore-errors
        (when (fboundp 'cmacs-ai-chat-cancel)
          (cmacs-ai-chat-cancel (cdr (plist-get job :pair)))))
      (cmacs-journal-daily--finish-summary id "timed out"))))

(defun cmacs-journal-daily--start-summary (file facts title header)
  "Ask the model for a summary of FACTS and add it to FILE when it answers.
TITLE names the range in the prompt; HEADER is FILE's header should it
have to be created again.  Returns the job ID, or nil when the request
could not be started."
  (let ((id (cl-incf cmacs-journal-daily--job-counter)))
    (condition-case err
        (let* ((prompt (cmacs-journal-daily-prompt facts title))
               (pair (cmacs-ai-make-session cmacs-journal-daily-provider
                                            cmacs-journal-daily-model
                                            cmacs-journal-daily-summary-prompt)))
          (push (cons id (list :file file :facts facts :header header
                               :pair pair :text ""
                               :model (cmacs-journal-daily--model-name)
                               :timer (run-with-timer
                                       cmacs-journal-daily-summary-timeout nil
                                       #'cmacs-journal-daily--summary-timeout
                                       id)))
                cmacs-journal-daily--jobs)
          (cmacs-ai-chat-stream
           (cdr pair) prompt
           (lambda (payload)
             (cmacs-journal-daily--stream-callback id payload)))
          id)
      (error
       (if (assq id cmacs-journal-daily--jobs)
           (cmacs-journal-daily--finish-summary id (error-message-string err))
         (message "cmacs-journal-daily: the facts are written; no summary (%s)"
                  (error-message-string err)))
       nil))))

;;;; Writing a note

(defun cmacs-journal-daily--refuse-agents ()
  "Signal an error when the caller is an agent or a remote client."
  (when (cmacs-journal-agent-context-p)
    (error "cmacs-journal-daily is for the person at the keyboard, not for agents or remote callers")))

(defun cmacs-journal-daily--day-range (day)
  "The (FROM . TO) of DAY, a YYYY-MM-DD string: its midnight to the next.
Cut at now for today.  Through the next local midnight and not 86400
seconds on, so a day the clocks change on is still one day."
  (let* ((start (car (cmacs-journal--span-range day)))
         (end (cmacs-journal--day-start (+ start (* 36 3600)))))
    (cons start (min end (max start (cmacs-journal--now))))))

(defun cmacs-journal-daily--week-range (day)
  "The (FROM . TO) of the ISO week holding DAY: Monday to Monday."
  (let* ((start (car (cmacs-journal--span-range day)))
         ;; %u is 1 for Monday.  Noon, so that a clock change inside the
         ;; week cannot land the arithmetic on the wrong day.
         (back (1- (string-to-number (format-time-string "%u" start))))
         (monday (cmacs-journal--day-start (- (+ start (* 12 3600))
                                              (* back 86400))))
         (next (cmacs-journal--day-start (+ monday (* 7 86400) (* 12 3600)))))
    (cons monday (min next (max monday (cmacs-journal--now))))))

(defun cmacs-journal-daily--spec (day span)
  "What to write for DAY (YYYY-MM-DD) over SPAN (`day' or `week'): a plist."
  (if (eq span 'week)
      (let* ((range (cmacs-journal-daily--week-range day))
             (title (format-time-string "%G-W%V" (car range))))
        (list :span 'week :from (car range) :to (cdr range) :title title
              :description (format "Weekly note for %s (from %s), started from the activity journal."
                                   title (cmacs-journal--day (car range)))
              :file (expand-file-name (concat title ".org")
                                      (cmacs-journal-daily--directory))))
    (let ((range (cmacs-journal-daily--day-range day)))
      (list :span 'day :from (car range) :to (cdr range) :title day
            :description (format "Daily note for %s, started from the activity journal."
                                 day)
            :file (expand-file-name (concat day ".org")
                                    (cmacs-journal-daily--directory))))))

(defun cmacs-journal-daily--run (spec interactive)
  "Write the note SPEC describes; INTERACTIVE non-nil when a person asked.

Returns a plist with :status -- `not-ready' (no usable rule set; nothing
was read), `empty' (nothing recorded; nothing written), or what
`cmacs-journal-daily--apply' returned -- plus :file, :created and
:summary (t when a model was asked, a string saying why not, or nil)."
  (cmacs-journal-daily--refuse-agents)
  (require 'cmacs-redact)
  (cmacs-journal-flush)
  (if (not (cmacs-redact-ready-p))
      (list :status 'not-ready)
    (let ((facts (cmacs-journal-daily-facts (plist-get spec :from)
                                            (plist-get spec :to)
                                            (plist-get spec :span))))
      (if (zerop (plist-get facts :count))
          (list :status 'empty)
        (let* ((file (plist-get spec :file))
               (id (cmacs-journal-daily--new-id))
               (header (cmacs-journal-daily--header
                        id (plist-get spec :title)
                        (plist-get spec :description)
                        cmacs-journal-daily-categories))
               (result (cmacs-journal-daily--splice
                        file (cmacs-journal-daily-render facts) header))
               (summary nil))
          (when (plist-get result :created)
            (cmacs-journal-daily--register-index
             file id (plist-get spec :title) (plist-get spec :from)))
          ;; A person asking gets a fresh summary.  The timer only fills
          ;; in one that is missing or that the facts have outgrown --
          ;; otherwise every restart of Emacs would ask the model again.
          (when (or interactive
                    (not (eq (plist-get result :status) 'unchanged))
                    (not (plist-get result :had-summary)))
            (setq summary (cmacs-journal-daily--summary-decision interactive))
            (when (eq summary t)
              (unless (cmacs-journal-daily--start-summary
                       file facts (plist-get spec :title) header)
                (setq summary "no summary: the request could not be started"))))
          (append (list :file file :summary summary) result))))))

(defun cmacs-journal-daily--report (spec result)
  "Tell the user what RESULT, of writing SPEC, was."
  (let ((file (and (plist-get result :file)
                   (abbreviate-file-name (plist-get result :file))))
        (summary (plist-get result :summary)))
    (message
     "cmacs-journal-daily: %s%s"
     (pcase (plist-get result :status)
       ('not-ready
        "nothing written -- the privacy rules are not loaded, so the journal may not be read (see `cmacs-journal-filter-error')")
       ('empty (format "nothing recorded for %s; nothing written"
                       (plist-get spec :title)))
       ('unchanged (format "%s already has these facts" file))
       ('buffer-unsaved
        (format "updated the buffer visiting %s; it has your unsaved edits, so saving is left to you"
                file))
       (_ (format "%s %s" (if (plist-get result :created) "created" "updated")
                  file)))
     (cond ((eq summary t)
            (format "; asking %s for a summary"
                    (cmacs-journal-daily--model-name)))
           ((stringp summary) (concat "; " summary))
           (t "")))))

(defun cmacs-journal-daily--read-day (prefix prompt)
  "Today as YYYY-MM-DD; with PREFIX non-nil, a date read with PROMPT."
  (if prefix
      (progn (require 'org) (org-read-date nil nil nil prompt))
    (cmacs-journal--day (cmacs-journal--now))))

;;;###autoload
(defun cmacs-journal-daily (&optional day)
  "Write the note of what DAY went to, from the activity journal.

DAY is a YYYY-MM-DD string and defaults to today; with a prefix
argument a date is read the Org way.  The note is
`cmacs-journal-daily-directory'/DAY.org.  A file that is not there is
created with the house header, an `:ID:' and a bullet in the
directory's `00_index.org'.  One that is there keeps everything in it:
only the subtree marked `CMACS_JOURNAL_DAILY' is replaced, or added at
the end the first time.  Running this again updates that subtree in
place.

The facts need no model.  With `cmacs-journal-daily-summary' a model
then adds a few sentences written from those facts; see that option and
`cmacs-journal-daily-allow-remote'.

Nothing is written for a day with nothing recorded, or while the
privacy rules cannot be loaded.  Refuses to run for an agent or a
remote caller.  Returns the note's file name when there is a note."
  (interactive (list (cmacs-journal-daily--read-day current-prefix-arg
                                                    "Daily note for")))
  (cmacs-journal-daily--refuse-agents)
  (let* ((interactive (called-interactively-p 'interactive))
         (spec (cmacs-journal-daily--spec
                (or day (cmacs-journal--day (cmacs-journal--now))) 'day))
         (result (cmacs-journal-daily--run spec interactive)))
    (when interactive (cmacs-journal-daily--report spec result))
    (plist-get result :file)))

;;;###autoload
(defun cmacs-journal-weekly (&optional day)
  "Write the note of the ISO week holding DAY, from the activity journal.

DAY is a YYYY-MM-DD string and defaults to today; with a prefix
argument a date is read the Org way.  The note is YYYY-Www.org in
`cmacs-journal-daily-directory', written by the rules of
`cmacs-journal-daily': the same single owned subtree, with a table of
time by day where a daily note has its timeline."
  (interactive (list (cmacs-journal-daily--read-day current-prefix-arg
                                                    "Weekly note for the week of")))
  (cmacs-journal-daily--refuse-agents)
  (let* ((interactive (called-interactively-p 'interactive))
         (spec (cmacs-journal-daily--spec
                (or day (cmacs-journal--day (cmacs-journal--now))) 'week))
         (result (cmacs-journal-daily--run spec interactive)))
    (when interactive (cmacs-journal-daily--report spec result))
    (plist-get result :file)))

;;;###autoload
(defun cmacs-journal-daily-preview (&optional day week)
  "Show the subtree `cmacs-journal-daily' would write for DAY.
Nothing is written and no model is asked.  With a prefix argument a
date is read; WEEK non-nil (two prefix arguments) previews the week."
  (interactive (list (cmacs-journal-daily--read-day current-prefix-arg
                                                    "Preview the note for")
                     (equal current-prefix-arg '(16))))
  (cmacs-journal-daily--refuse-agents)
  (require 'cmacs-redact)
  (require 'org)
  (cmacs-journal-flush)
  (unless (cmacs-redact-ready-p)
    (user-error "The privacy rules are not loaded, so the journal may not be read"))
  (let* ((spec (cmacs-journal-daily--spec
                (or day (cmacs-journal--day (cmacs-journal--now)))
                (if week 'week 'day)))
         (facts (cmacs-journal-daily-facts (plist-get spec :from)
                                           (plist-get spec :to)
                                           (plist-get spec :span)))
         (buffer (get-buffer-create "*cmacs-journal-daily*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (format "#+title: %s (preview; nothing was written)\n\n"
                        (plist-get spec :title))
                (cmacs-journal-daily-render facts))
        (goto-char (point-min))
        (set-buffer-modified-p nil)))
    (pop-to-buffer buffer)
    facts))

;;;; The mode

(defvar cmacs-journal-daily--timer nil
  "The timer of `cmacs-journal-daily-mode'.")

(defvar cmacs-journal-daily--done nil
  "What `cmacs-journal-daily-mode' has dealt with this session.
A list of strings: a day for \"yesterday's note for that day\", a day
followed by `@' for \"today's note at the set time\".")

(defun cmacs-journal-daily--activity-since-p (time)
  "Non-nil when the journal has activity that started at or after TIME."
  (let ((activity (lambda (event)
                    (and event
                         (memq (plist-get event :kind)
                               cmacs-journal-report-kinds)
                         (>= (plist-get event :time) time)))))
    (or (funcall activity cmacs-journal--open)
        (cl-some activity cmacs-journal--queue)
        (cl-some activity (cmacs-journal-events time nil)))))

(defun cmacs-journal-daily--auto (day mark)
  "Write DAY's note for the mode; remember it under MARK when dealt with.
A day the rules were not ready for is not remembered: it is tried again
at the next look.  A day that failed is remembered, with one warning,
so that a broken note is not retried every few minutes for ever."
  (condition-case err
      (let* ((spec (cmacs-journal-daily--spec day 'day))
             (result (cmacs-journal-daily--run spec nil)))
        (unless (eq (plist-get result :status) 'not-ready)
          (push mark cmacs-journal-daily--done)
          (unless (memq (plist-get result :status) '(empty unchanged))
            (cmacs-journal-daily--report spec result))))
    (error
     (push mark cmacs-journal-daily--done)
     (display-warning 'cmacs-journal-daily
                      (format "Could not write the note for %s: %s" day
                              (error-message-string err))
                      :warning))))

(defun cmacs-journal-daily--tick ()
  "Timer: write what `cmacs-journal-daily-mode' is due to write."
  (condition-case nil
      ;; While an agent or a remote caller is being served this would
      ;; read the journal as that caller; the next look is soon enough.
      (unless (cmacs-journal-agent-context-p)
        (let* ((now (cmacs-journal--now))
               (start (cmacs-journal--day-start now))
               (today (cmacs-journal--day now))
               (yesterday (cmacs-journal--day (- start 3600))))
          (when (and cmacs-journal-daily-write-yesterday
                     (not (member yesterday cmacs-journal-daily--done))
                     (cmacs-journal-daily--activity-since-p start))
            (cmacs-journal-daily--auto yesterday yesterday))
          (when (and (stringp cmacs-journal-daily-time)
                     (string-match "\\`\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\'"
                                   cmacs-journal-daily-time)
                     (not (member (concat today "@")
                                  cmacs-journal-daily--done))
                     (>= now (+ start
                                (* 3600 (string-to-number
                                         (match-string
                                          1 cmacs-journal-daily-time)))
                                (* 60 (string-to-number
                                       (match-string
                                        2 cmacs-journal-daily-time))))))
            (cmacs-journal-daily--auto today (concat today "@")))))
    (error nil)))

;;;###autoload
(define-minor-mode cmacs-journal-daily-mode
  "Write the day's note from the activity journal without being asked.

Off by default.  While it is on, a timer -- never a compositor hook --
looks at the clock every `cmacs-journal-daily-check-interval' seconds
and writes

  * yesterday's note, once the journal has recorded something today
    (`cmacs-journal-daily-write-yesterday'), and
  * today's note at `cmacs-journal-daily-time', when that is set.

Each is written as `cmacs-journal-daily' writes it: one owned subtree,
nothing else in the file touched.  Nothing is written for a day with no
events, and nothing while the privacy rules cannot be loaded -- that day
is tried again later.  A summary by a model that is not local is never
asked for from here unless `cmacs-journal-daily-allow-remote' is
`always'."
  :global t
  :group 'cmacs-journal-daily
  (when (timerp cmacs-journal-daily--timer)
    (cancel-timer cmacs-journal-daily--timer))
  (setq cmacs-journal-daily--timer nil)
  (when cmacs-journal-daily-mode
    (setq cmacs-journal-daily--timer
          (run-with-timer (min 60 cmacs-journal-daily-check-interval)
                          cmacs-journal-daily-check-interval
                          #'cmacs-journal-daily--tick))))

;;;; Voice

;;;###autoload
(defun cmacs-journal-daily-voice (&optional which)
  "Voice command: write the note for today, or for WHICH.
WHICH is what was said after \"my\": \"day\", \"week\" or \"yesterday\"."
  (pcase which
    ("week" (call-interactively #'cmacs-journal-weekly))
    ("yesterday"
     (let* ((now (cmacs-journal--now))
            (day (cmacs-journal--day (- (cmacs-journal--day-start now) 3600)))
            (spec (cmacs-journal-daily--spec day 'day)))
       (cmacs-journal-daily--report
        spec (cmacs-journal-daily--run spec t))))
    (_ (call-interactively #'cmacs-journal-daily))))

;; The registration is an autoloaded function called from an autoloaded
;; form, so the phrase exists as soon as voice commands do, whether or
;; not this file is loaded.  loaddefs.el is compiled without
;; cmacs-voice-commands: naming `cmacs-voice-define-command' in the form
;; itself would be a "not known to be defined" warning in every build.
;;;###autoload
(defun cmacs-journal-daily-register-voice ()
  "Register \"write up my day\" with the voice-command registry."
  (cmacs-voice-define-command
   "write up\\(?: my\\)? \\(day\\|week\\|yesterday\\)"
   #'cmacs-journal-daily-voice
   "write up my day / week / yesterday" nil :context 'desktop))

;;;###autoload
(with-eval-after-load 'cmacs-voice-commands
  (cmacs-journal-daily-register-voice))

(provide 'cmacs-journal-daily)

;;; cmacs-journal-daily.el ends here
