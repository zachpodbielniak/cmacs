;;; cmacs-secondbrain-ingest-ai.el --- Model prompts for the ingester  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The model-facing half of the second-brain ingester: what we ask, how
;; we ask it, and how we read the answer back.
;;
;; Three things live here and nothing else:
;;
;;   - The summary templates.  These are the 27 content types the old
;;     `sbi' shell pipeline knew (meeting, book, lecture, youtube, ...),
;;     rewritten to produce Org rather than Markdown and to nest under
;;     the note's `* Summary' heading.
;;
;;   - The analysis request.  One call that returns JSON: a title, a
;;     one-line description, tags, the summary type to use, and -- the
;;     part that matters -- WHERE in the PARA tree the note belongs.  The
;;     model is handed the real directory tree so it picks an existing
;;     place rather than inventing one; `cmacs-secondbrain-ingest.el'
;;     then validates the answer against the filesystem and falls back to
;;     the inbox on anything it does not trust.
;;
;;   - Redaction.  `sbi --sanitize' piped through a Perl script whose
;;     "bank account" rule was `\b\d{8,17}\b' -- every timestamp, every
;;     commit hash prefix, every phone number in a transcript.  The rules
;;     are ported, but the ones that cannot tell a secret from a number
;;     are OFF by default and have to be asked for.
;;
;; Every request goes through `cmacs-ai-make-session' +
;; `cmacs-ai-chat-stream', which is asynchronous: the ingester is driven
;; from D-Bus and MCP as well as from the keyboard, and a blocking model
;; call on the main thread would freeze a `--gowl' desktop for the
;; duration.  The default provider is `claude-code' with the `sonnet'
;; model -- a CLI provider, so no API key is needed beyond a logged-in
;; `claude'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cmacs-secondbrain-ingest-extract)

(declare-function cmacs-ai-make-session "cmacs-ai" (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c" (session prompt callback &optional executor))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-supported-p "cmacs-ai-defuns.c" ())

;;;; Provider -----------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-provider 'claude-code
  "AI provider used for analysis and summaries.

Any symbol `cmacs-ai-providers' returns.  The default is the Claude Code
CLI: it needs no API key, only a logged-in `claude', and its default
model is more than capable of summarising and filing a note.  Set to nil
to use `cmacs-ai-default-provider'."
  :type '(choice (const :tag "cmacs-ai default" nil) symbol)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-model "sonnet"
  "Model passed to the provider, or nil for the provider's own default.

For `claude-code' this is whatever `claude --model' accepts, so the short
aliases work: \"sonnet\", \"opus\", \"haiku\"."
  :type '(choice (const :tag "Provider default" nil) string)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-analysis-max-chars 16000
  "How much of the content the analysis call sees.

Placement, tags and a title do not need the whole of a two-hour
transcript; they need the beginning and the end.  Longer content is
sampled head-and-tail down to this many characters."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-summary-max-chars 150000
  "How much of the content the summary call sees.

Content beyond this is sampled head-and-tail and the summary is marked as
made from a sample.  Sonnet's window is far larger than this, so the cap
is about cost and latency rather than fit."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-ai-timeout 600
  "Seconds to wait for a model reply before treating the call as failed.

Generous, because a long transcript through a CLI provider can take a
few minutes.  The note is still written when this fires; it just says so
in place of the summary."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

;;;; Summary templates ---------------------------------------------------

(defcustom cmacs-secondbrain-ingest-summary-preamble
  "You write summaries for a personal knowledge base kept in Emacs Org mode.

Output rules, all of them mandatory:
- Pure Org markup.  Never Markdown: no `#` headings, no ``` fences, no **double asterisks**.
- Headings start at level two (`** Heading`); the note already supplies the level-one heading above you.
- Every paragraph is ONE line.  Never hard-wrap prose.
- Lists use `- `; ordered lists use `1. `.
- Emphasis is *bold* and /italic/; code is ~code~; a code block is #+begin_src LANG ... #+end_src.
- Start directly with the content.  No preamble such as \"Here is the summary\", no closing remarks.
- Do not invent facts that are not in the material.  If the material is truncated or garbled, say so in one line at the end."
  "Rules prepended to every summary system prompt.
This is what turns a general-purpose model into something whose output
can be dropped straight into an Org file."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-summary-templates
  '((general . "Summarise the material clearly and concisely.  Give a one-line *TL;DR*, then `** Key points` as a short bullet list, then `** Details` with the most important specifics, then `** Takeaways`.")
    (meeting . "Summarise this meeting transcript: `** Agenda`, `** Discussion` (major points grouped under the agenda items), `** Decisions`, `** Action items` (as `- [ ] OWNER: task`, owner named where identifiable), `** Open questions`.")
    (book . "Summarise this book.  Decide from the content whether it is fiction or non-fiction.  Fiction: `** Plot overview`, `** Themes`, `** By chapter` with the significant developments.  Non-fiction: `** Thesis`, `** By chapter` with the argument of each, `** Key takeaways`.")
    (research . "Summarise this research paper: `** Objectives` (questions or hypotheses), `** Methodology` (design and data sources), `** Findings` organised by section, `** Limitations`, `** Conclusions and future work`.")
    (lecture . "Turn this lecture transcript into an outline: `** Topic and objectives`, `** Key definitions` (/italicised/ terms with one-line explanations), `** Outline` following the talk's structure, `** Examples and case studies`, `** Questions raised`, `** Connections` to related topics.")
    (tutorial . "Turn this technical guide into a structured summary: `** Objective`, `** Prerequisites`, `** Steps` (an ordered list), `** Pitfalls and troubleshooting`, `** Further learning`.  Put every command or code sample in a #+begin_src block with the right language.")
    (interview . "Condense this interview: `** Who` (the interviewee and their background), `** Themes`, `** Notable quotes` (verbatim, as #+begin_quote blocks), `** Subtext` (tone, what was avoided), `** Takeaways`.")
    (debate . "Analyse this debate: `** The question`, `** Arguments` with a balanced subsection per side, `** Common ground`, `** Fundamental disagreements`, `** Rhetoric` (fallacies and techniques used), `** Assessment`.")
    (podcast . "Summarise this podcast episode: `** Episode` (topic, host, guests), `** Segments` with approximate timestamps where the transcript has them, `** Central ideas`, `** Resources mentioned`, `** Takeaways`.")
    (legal . "Analyse this legal document: `** Parties and dates`, `** Consequential clauses` (the three to five that matter most), `** Obligations` per party, `** Termination and penalties`, `** Risks` (clauses that deserve a second look).  This is not legal advice; say so in one line at the end.")
    (medical . "Summarise this medical case material: `** Presentation` (demographics and complaints), `** Diagnostics`, `** Treatment`, `** Outcome`, `** Learning points`.  This is not medical advice; say so in one line at the end.")
    (review . "Synthesise this product review material: `** Verdict`, `** Strengths`, `** Weaknesses`, `** Compared with alternatives` (only if the material compares), `** Best for`.")
    (project . "Structure this project material: `** Overview and objectives`, `** Stakeholders`, `** Timeline` (milestones and deliverables), `** Resources and constraints`, `** Risks`, `** Success criteria`.")
    (techdoc . "Summarise this technical documentation: `** Purpose`, `** Audience`, `** Components` (functions, endpoints, or modules), `** Setup` (prerequisites, installation, configuration), `** Use cases` with examples in #+begin_src blocks, `** Troubleshooting`.")
    (casestudy . "Condense this case study: `** Background and problem`, `** Approach`, `** Results` (with the numbers), `** Takeaways and applicability`.")
    (event . "Summarise this event: `** Event` (title, date, organiser), `** Themes` with speaker highlights, `** Notable sessions`, `** Contacts and follow-ups`, `** Next steps`.")
    (academic . "Summarise this academic paper: `** Research question`, `** Method`, `** Findings` with statistical significance where reported, `** Implications`, `** Limitations and future work`.")
    (email . "Condense this email or thread: `** Participants` and their roles, `** Topics`, `** Decisions` (with owners and deadlines), `** Open questions`, `** Timeline` of the critical exchanges.")
    (social . "Analyse this social-media material: `** Trends` (topics, hashtags, keywords with rough frequency), `** Sentiment`, `** Notable voices and posts`, `** Recommendations`.")
    (course . "Structure this course material: `** Learning objectives`, `** Modules` (topics, readings, assignments), `** Skills developed`, `** Assessment`.")
    (survey . "Summarise these survey results: `** Respondents`, `** Key insights` and response patterns, `** Notable responses` (verbatim where useful), `** Follow-up`.")
    (manual . "Extract what matters from this user manual: `** Setup checklist`, `** Safety`, `** Core functions`, `** Troubleshooting` as an Org table of symptom | cause | fix.")
    (product . "Extract the specification from this product material: `** Product`, `** Specifications` as an Org table, `** Key features`, `** Compatibility`, `** Pricing and availability`.")
    (scientific . "Summarise this scientific paper: `** Question and hypothesis`, `** Methodological innovations`, `** Findings` with the data, `** Limitations`, `** Future research`.")
    (cleanup . "Reproduce the MAIN CONTENT of this material and nothing else: keep the article's text, headings, lists, quotes, tables and code; drop navigation, sidebars, headers and footers, share buttons, adverts, cookie notices, related-article boxes, comment sections, newsletter forms and legal boilerplate.  Do not summarise or interpret -- this is reader mode, not a digest.  Convert the structure to Org.")
    (youtube . "Summarise this video transcript for someone deciding whether to watch it: `** Overview` (two or three lines: topic, purpose, creator context if stated, style -- tutorial, review, essay...), `** Topics` as bullets with [MM:SS] timestamps where the transcript has them, `** Content` (three to five one-line paragraphs of the substance, keeping technical detail, numbers and examples), `** Quotes` (two to four memorable lines), `** Remember` (three to five points), `** Mentioned` (resources, links, other videos, sponsors -- briefly).")
    (custom . "Follow the additional instructions exactly; where they leave the structure open, use a one-line *TL;DR* followed by `** Key points`."))
  "Summary TYPE -> instructions, appended to the shared preamble.

These are the content types the old shell ingester knew, kept as
symbols so `--type meeting' keeps meaning what it always did.  Add your
own by adding an entry; `cmacs-secondbrain-ingest-summary-types'
follows this list, so a new type is offered everywhere a type is
chosen."
  :type '(alist :key-type symbol :value-type string)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-principle-prompt
  "Beyond the literal content, add a final `** Principles` section: the higher-level principles this material illustrates, each as one line, and for each one the areas of a life or a practice it could be applied to.  Principles over specifics."
  "Appended to the summary instructions when `:principle' is set.
The `sbi --principle' flag, kept because it is a genuinely different
question to ask of a book or a talk."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-summary-types ()
  "Return the list of known summary type symbols, `auto' first."
  (cons 'auto (mapcar #'car cmacs-secondbrain-ingest-summary-templates)))

(defun cmacs-secondbrain-ingest-summary-system (type &optional principle extra)
  "Return the system prompt for a summary of TYPE.

TYPE is a key of `cmacs-secondbrain-ingest-summary-templates'; anything
unknown (including `auto', which should have been resolved before this
is called) falls back to `general'.  With PRINCIPLE non-nil the
principle question is appended; EXTRA is a user's own instruction
string, appended last so it wins."
  (let ((body (or (cdr (assq type cmacs-secondbrain-ingest-summary-templates))
                  (cdr (assq 'general cmacs-secondbrain-ingest-summary-templates)))))
    (string-join
     (delq nil (list cmacs-secondbrain-ingest-summary-preamble
                     body
                     (and principle cmacs-secondbrain-ingest-principle-prompt)
                     (and extra (not (string-blank-p extra))
                          (concat "Additional instructions from the user:\n" extra))))
     "\n\n")))

(defun cmacs-secondbrain-ingest-default-summary-type (kind)
  "Return the summary type to use for content KIND when the type is `auto'
and no model is available to choose one."
  (pcase kind
    ((or 'youtube 'video 'audio) 'youtube)
    ('email 'email)
    ((or 'crawl 'site-export) 'cleanup)
    ((or 'ebook) 'book)
    (_ 'general)))

;;;; Sampling ------------------------------------------------------------

(defun cmacs-secondbrain-ingest-sample (text max)
  "Return TEXT if it fits in MAX characters, else its head and tail.

The cut is marked in the text so the model knows what it is looking at;
a summary written from a sample that does not say so would confidently
describe the middle of a document it never saw."
  (if (or (null text) (<= (length text) max))
      text
    (let* ((head (floor (* max 0.7)))
           (tail (- max head)))
      (concat (substring text 0 head)
              "\n\n[... " (number-to-string (- (length text) max))
              " characters omitted from the middle of this material ...]\n\n"
              (substring text (- (length text) tail))))))

;;;; The analysis request ------------------------------------------------

(defcustom cmacs-secondbrain-ingest-placement-guide
  "The notes tree uses PARA:
- 01_projects/: time-bounded work with a defined outcome.  Use it only when the material is clearly part of an active, named project.
- 02_areas/: ongoing responsibilities with no end date -- things maintained, not finished.  Meeting notes for a recurring meeting, a person, a piece of infrastructure, a hobby.
- 03_resources/: reference material on a topic, kept for future use and not tied to a specific outcome.  Most articles, papers, talks, tutorials, documentation and book notes go here.  Pick the MOST SPECIFIC existing subdirectory: a Linux tip goes in 03_resources/technical/linux, not 03_resources/technical.
- 04_archives/: never a destination for new material.
- 00_inbox/: the honest answer when nothing fits; better than a wrong guess.
Each top-level has personal/ and work/ subdirectories; default to personal/ unless the material is clearly about the user's employer or job.
Only ever answer with a directory that appears in the tree you were given."
  "How the model is told to place a note in the tree.

Written from the notes repository's own placement heuristics.  Edit it
if your tree is organised differently; the model sees this text and the
real directory listing, nothing else."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defconst cmacs-secondbrain-ingest--analysis-system
  "You file incoming material into a personal Org-mode knowledge base.  You answer with ONE JSON object and nothing else -- no prose, no code fence.

The object has exactly these keys:
- \"title\": a short, specific title for the note (under 80 characters, no trailing period).
- \"description\": one sentence saying what the material is and why someone would open it.
- \"summary_type\": the best-fitting type from the list you are given.
- \"tags\": three to six lowercase tags, single words or hyphenated, the kind that would be useful for filtering; no spaces, no leading #.
- \"para\": an object with \"path\" (a directory from the tree you are given, relative to the root, e.g. \"03_resources/technical/linux\"), \"confidence\" (0.0 to 1.0: how sure you are this is the right place), and \"reason\" (one line).
- \"language\": the two-letter language code of the material.

If you are not confident where the material belongs, say so with a low confidence rather than guessing: a low-confidence answer is filed to the inbox for a human to place."
  "System prompt for the analysis call.")

(defun cmacs-secondbrain-ingest-analysis-prompt (doc tree &optional hints)
  "Return the user turn for the analysis call.

DOC is an extracted document plist (see `cmacs-secondbrain-ingest-extract')
whose :text is sampled to `cmacs-secondbrain-ingest-analysis-max-chars'.
TREE is a string listing the candidate directories, one per line.
HINTS is a plist of things the caller already knows: :para (a category
symbol the user fixed, so the model only chooses within it), :tags the
user supplied, :title the user supplied."
  (let ((kind (plist-get doc :kind))
        (source (plist-get doc :source))
        (meta (plist-get doc :meta)))
    (concat
     cmacs-secondbrain-ingest-placement-guide
     "\n\nCandidate directories (choose one of these exactly):\n"
     tree
     "\n\nSummary types to choose from: "
     (mapconcat #'symbol-name
                (mapcar #'car cmacs-secondbrain-ingest-summary-templates) ", ")
     "\n"
     (when (plist-get hints :para)
       (format "\nThe user has already decided the PARA category is %s; choose a directory inside it.\n"
               (plist-get hints :para)))
     (when (plist-get hints :tags)
       (format "\nThe user already tagged this: %s.  Add to those, do not repeat them.\n"
               (string-join (plist-get hints :tags) ", ")))
     (when (plist-get hints :title)
       (format "\nThe user already titled this \"%s\"; keep that title unless it is clearly wrong.\n"
               (plist-get hints :title)))
     (format "\nMaterial kind: %s\nSource: %s\n" kind (or source "unknown"))
     (when meta
       (concat "Known metadata:\n"
               (mapconcat (lambda (kv) (format "- %s: %s" (car kv) (cdr kv)))
                          (seq-filter (lambda (kv) (and (cdr kv)
                                                        (not (equal (cdr kv) ""))))
                                      meta)
                          "\n")
               "\n"))
     "\nThe material follows the line of dashes.\n----------\n"
     (or (cmacs-secondbrain-ingest-sample
          (plist-get doc :text) cmacs-secondbrain-ingest-analysis-max-chars)
         ""))))

;;;; Reading the answer --------------------------------------------------

(defun cmacs-secondbrain-ingest-parse-json (text)
  "Parse the first JSON object in TEXT, or return nil.

Models wrap JSON in fences and prose no matter how firmly they are told
not to, so this finds the outermost braces and parses what is between
them.  Objects come back as hash tables keyed by string, arrays as
lists (see `cmacs-secondbrain-ingest-json-parse')."
  (when (stringp text)
    (let* ((start (string-match-p "{" text))
           (end (and start (cl-position ?} text :from-end t))))
      (when (and start end (> end start))
        (cmacs-secondbrain-ingest-json-parse (substring text start (1+ end)))))))

(defun cmacs-secondbrain-ingest-slug-tag (tag)
  "Normalise TAG for `#+filetags': lowercase, no spaces, no leading #."
  (let ((s (downcase (string-trim (format "%s" tag)))))
    (setq s (string-remove-prefix "#" s))
    (setq s (replace-regexp-in-string "[^a-z0-9_@-]+" "_" s))
    (setq s (replace-regexp-in-string "_+" "_" s))
    (string-trim s "_+" "_+")))

(defun cmacs-secondbrain-ingest-normalize-analysis (obj)
  "Turn a parsed analysis OBJ (a hash table) into a validated plist.

Anything malformed is dropped rather than propagated: a missing title is
nil (the caller has a fallback), an unknown summary type is nil, tags are
slugified, confidence is clamped to [0, 1].  Returns nil when OBJ is not
an object at all."
  (when (hash-table-p obj)
    (let* ((get (lambda (&rest ks) (apply #'cmacs-secondbrain-ingest-json-get obj ks)))
           (title (funcall get "title"))
           (desc (funcall get "description"))
           (stype (funcall get "summary_type"))
           (tags (funcall get "tags"))
           (lang (funcall get "language"))
           (path (funcall get "para" "path"))
           (conf (funcall get "para" "confidence"))
           (reason (funcall get "para" "reason")))
      (list :title (and (stringp title) (not (string-blank-p title))
                        (string-trim title))
            :description (and (stringp desc) (not (string-blank-p desc))
                              (string-trim desc))
            :summary-type (and (stringp stype)
                               (let ((sym (intern (downcase (string-trim stype)))))
                                 (and (assq sym cmacs-secondbrain-ingest-summary-templates)
                                      sym)))
            :tags (and (listp tags)
                       (delete-dups
                        (delq nil (mapcar (lambda (tg)
                                            (let ((s (cmacs-secondbrain-ingest-slug-tag tg)))
                                              (and (not (string-empty-p s)) s)))
                                          tags))))
            :path (and (stringp path) (not (string-blank-p path))
                       (string-trim (string-trim path) "/+" "/+"))
            :confidence (cond ((numberp conf) (max 0.0 (min 1.0 (float conf))))
                              ((and (stringp conf) (string-match-p "\\`[0-9.]+\\'" conf))
                               (max 0.0 (min 1.0 (string-to-number conf))))
                              (t 0.0))
            :reason (and (stringp reason) reason)
            :language (and (stringp lang) (downcase (string-trim lang)))))))

;;;; Talking to the model ------------------------------------------------

(defcustom cmacs-secondbrain-ingest-cli-directory temporary-file-directory
  "Working directory for a CLI provider's subprocess.

A command-line agent resolves CLAUDE.md, the .claude directory and the
repository from where it starts, and cmacs usually starts in a source
checkout.  Run there, the summariser believes it is a coding agent in
that project -- the first live run of this file answered a JSON request
with a question about the ingest code it found around itself.  Point it
at somewhere with no project in it."
  :type 'directory
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-cli-bare nil
  "Run the Claude Code CLI with --bare.

Off by default because --bare also skips the credential source: a
`claude' started that way answers \"Not logged in\" on a machine where
`claude --print' works.  Turn it on only if your login survives it (an
API key in the environment, for instance).  The project-context problem
--bare would have solved is handled by `cmacs-secondbrain-ingest-cli-directory'
and `cmacs-secondbrain-ingest-cli-exclude-dynamic-sections' instead."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-cli-exclude-dynamic-sections t
  "Pass --exclude-dynamic-system-prompt-sections to the Claude Code CLI.
Drops the per-machine parts of its default system prompt (working
directory, environment, memory paths, git status), none of which a
summariser should be reasoning about.  Ignored by other providers."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(declare-function cmacs-ai-client-cli-p "cmacs-ai-client.c" (handle))
(declare-function cmacs-ai-client-set-working-directory "cmacs-ai-client.c" (handle directory))
(declare-function cmacs-ai-client-set-cli-option "cmacs-ai-client.c" (handle name value))

(defcustom cmacs-secondbrain-ingest-cli-disallowed-tools
  "Bash,Read,Edit,Write,MultiEdit,Glob,Grep,LS,WebFetch,WebSearch,Task,Agent,NotebookEdit,TodoWrite,Skill,KillShell,BashOutput"
  "Tools the Claude Code CLI is forbidden while summarising.

In --print mode the CLI still has its read-only tools and uses them on
its own: asked to summarise a document while started in /tmp, the first
live run listed /tmp instead.  A summariser is given the material in its
prompt and has nothing to look up.  nil leaves the CLI's defaults."
  :type '(choice (const nil) string)
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest--isolate-cli (client)
  "Keep a CLI provider CLIENT away from whatever project cmacs sits in,
and away from its tools."
  (when (and (fboundp 'cmacs-ai-client-cli-p) (ignore-errors (cmacs-ai-client-cli-p client)))
    (when (and cmacs-secondbrain-ingest-cli-directory
               (file-directory-p cmacs-secondbrain-ingest-cli-directory))
      (ignore-errors (cmacs-ai-client-set-working-directory
                      client cmacs-secondbrain-ingest-cli-directory)))
    (when (fboundp 'cmacs-ai-client-set-cli-option)
      (when cmacs-secondbrain-ingest-cli-bare
        (ignore-errors (cmacs-ai-client-set-cli-option client "bare" t)))
      (when cmacs-secondbrain-ingest-cli-exclude-dynamic-sections
        (ignore-errors (cmacs-ai-client-set-cli-option
                        client "exclude-dynamic-system-prompt-sections" t)))
      (when cmacs-secondbrain-ingest-cli-disallowed-tools
        (ignore-errors (cmacs-ai-client-set-cli-option
                        client "disallowed-tools"
                        cmacs-secondbrain-ingest-cli-disallowed-tools))))))

(defun cmacs-secondbrain-ingest-ai-available-p ()
  "Non-nil when cmacs-ai is built and a session can be made."
  (and (fboundp 'cmacs-ai-supported-p)
       (ignore-errors (cmacs-ai-supported-p))
       (or (featurep 'cmacs-ai) (require 'cmacs-ai nil t))
       (fboundp 'cmacs-ai-make-session)))

(defun cmacs-secondbrain-ingest-ai-request (system prompt callback &optional provider model)
  "Send PROMPT under SYSTEM and deliver the reply to CALLBACK.

CALLBACK is called once, with (:ok TEXT) or (:error MESSAGE).  PROVIDER
and MODEL default to `cmacs-secondbrain-ingest-provider' and
`cmacs-secondbrain-ingest-model'.  Returns a function of no arguments
that cancels the request; calling it after completion is harmless.

The session is freed on every path, including the timeout: a leaked
session is a leaked subprocess when the provider is a CLI."
  (let* ((pair nil) (done nil) (acc "") (timer nil)
         (finish
          (lambda (payload)
            (unless done
              (setq done t)
              (when (timerp timer) (cancel-timer timer))
              (when pair
                (ignore-errors (cmacs-ai-free-session pair))
                (setq pair nil))
              (funcall callback payload)))))
    (condition-case err
        (progn
          (setq pair (cmacs-ai-make-session
                      (or provider cmacs-secondbrain-ingest-provider)
                      (or model cmacs-secondbrain-ingest-model)
                      system))
          (cmacs-secondbrain-ingest--isolate-cli (car pair))
          (setq timer (run-at-time cmacs-secondbrain-ingest-ai-timeout nil
                                   (lambda ()
                                     (when (and pair (not done))
                                       (ignore-errors (cmacs-ai-chat-cancel (cdr pair))))
                                     (funcall finish
                                              (list :error
                                                    (format "model did not answer within %ds"
                                                            cmacs-secondbrain-ingest-ai-timeout))))))
          (cmacs-ai-chat-stream
           (cdr pair) prompt
           (lambda (payload)
             (pcase (car-safe payload)
               (:delta (setq acc (concat acc (or (cadr payload) ""))))
               (:end
                (let ((final (plist-get (cdr payload) :text)))
                  (when (and (stringp final)
                             (> (length (string-trim final))
                                (length (string-trim acc))))
                    (setq acc final)))
                (funcall finish (list :ok acc)))
               (:error
                (funcall finish (list :error (or (cadr payload) "stream error"))))
               (_ nil)))))
      (error (funcall finish (list :error (error-message-string err)))))
    (lambda ()
      (unless done
        (when pair (ignore-errors (cmacs-ai-chat-cancel (cdr pair))))
        (funcall finish (list :error "cancelled"))))))

;;;; Redaction -----------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-redaction-rules
  '((email       "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]\\{2,\\}\\b" t
                 "Email addresses")
    (phone       "\\(?:\\+[0-9]\\{1,2\\}[ .-]?\\)?(?[0-9]\\{3\\})?[ .-][0-9]\\{3\\}[ .-][0-9]\\{4\\}\\b" t
                 "North American phone numbers with separators")
    (ssn         "\\b[0-9]\\{3\\}-[0-9]\\{2\\}-[0-9]\\{4\\}\\b" t
                 "US Social Security numbers (hyphenated form only)")
    (credit-card "\\b\\(?:[0-9]\\{4\\}[ -]\\)\\{3\\}[0-9]\\{4\\}\\b" t
                 "Card numbers in four groups of four")
    (api-key     "\\b\\(?:api[_-]?key\\|access[_-]?token\\|secret[_-]?key\\|client[_-]?secret\\)\\b[^A-Za-z0-9\n]\\{1,4\\}[A-Za-z0-9_/+=-]\\{16,\\}" t
                 "Keys and tokens named as such")
    (aws-key     "\\b\\(?:AKIA\\|ASIA\\)[A-Z0-9]\\{16\\}\\b" t
                 "AWS access key ids")
    (openai-key  "\\bsk-[A-Za-z0-9_-]\\{20,\\}\\b" t
                 "OpenAI/Anthropic-style sk- keys")
    (github-token "\\bgh[pousr]_[A-Za-z0-9]\\{36,\\}\\b" t
                 "GitHub tokens")
    (slack-token "\\bxox[abprs]-[A-Za-z0-9-]\\{10,\\}\\b" t
                 "Slack tokens")
    (jwt         "\\beyJ[A-Za-z0-9_-]\\{8,\\}\\.[A-Za-z0-9_-]\\{8,\\}\\.[A-Za-z0-9_-]\\{8,\\}\\b" t
                 "JSON Web Tokens")
    (private-key "-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----" t
                 "PEM private key blocks")
    (url-auth    "https?://[^/:@[:space:]]+:[^@[:space:]]+@" t
                 "Credentials embedded in URLs")
    (ipv4        "\\b\\(?:[0-9]\\{1,3\\}\\.\\)\\{3\\}[0-9]\\{1,3\\}\\b" t
                 "IPv4 addresses")
    (ipv6        "\\b\\(?:[0-9a-fA-F]\\{1,4\\}:\\)\\{7\\}[0-9a-fA-F]\\{1,4\\}\\b" t
                 "Full-form IPv6 addresses")
    (mac-address "\\b\\(?:[0-9A-Fa-f]\\{2\\}[:-]\\)\\{5\\}[0-9A-Fa-f]\\{2\\}\\b" t
                 "MAC addresses")
    (bitcoin     "\\b\\(?:bc1[a-zA-HJ-NP-Z0-9]\\{25,59\\}\\|[13][a-km-zA-HJ-NP-Z1-9]\\{25,34\\}\\)\\b" nil
                 "Bitcoin addresses")
    (ethereum    "\\b0x[a-fA-F0-9]\\{40\\}\\b" nil
                 "Ethereum addresses (also matches any 40-hex-digit 0x value)")
    (gps         "\\b[-+]?[0-9]\\{1,2\\}\\.[0-9]\\{4,\\},[ ]?[-+]?[0-9]\\{1,3\\}\\.[0-9]\\{4,\\}\\b" nil
                 "Decimal GPS coordinate pairs")
    (street-address "\\b[0-9]+ [A-Za-z0-9 ]\\{2,40\\}\\(?:Avenue\\|Ave\\|Street\\|St\\|Road\\|Rd\\|Boulevard\\|Blvd\\|Drive\\|Dr\\|Lane\\|Ln\\|Court\\|Ct\\|Way\\|Parkway\\|Pkwy\\|Place\\|Pl\\)\\b" nil
                 "Street addresses")
    (bank-account "\\b[0-9]\\{8,17\\}\\b" nil
                 "Any 8-17 digit number -- matches timestamps and ids too")
    (passport    "\\b[A-Z][0-9]\\{7,8\\}\\b" nil
                 "Passport-shaped ids (one letter, seven or eight digits)")
    (date        "\\b[0-9]\\{1,2\\}[-/][0-9]\\{1,2\\}[-/][0-9]\\{2,4\\}\\b" nil
                 "Numeric dates"))
  "Redaction rules: (NAME REGEXP DEFAULT-ON DESCRIPTION).

NAME is the symbol used to pick rules; REGEXP is an Emacs regexp;
DEFAULT-ON says whether the rule runs when redaction is requested without
naming rules.  The rules that are off by default are the ones that cannot
tell a secret from an ordinary number -- `bank-account' redacts every
Unix timestamp and every eight-digit ticket id -- so they must be asked
for by name."
  :type '(repeat (list symbol regexp boolean string))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-redaction-text "<redacted>"
  "What a redacted match is replaced with.
With `cmacs-secondbrain-ingest-redaction-label-rule' it becomes
\"<redacted:email>\", which is more useful when reading the note later."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-redaction-label-rule t
  "When non-nil, the redaction marker names the rule that fired."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-redaction-rule-names (&optional all)
  "Return the names of the default-on redaction rules, or of ALL of them."
  (delq nil (mapcar (lambda (r) (and (or all (nth 2 r)) (car r)))
                    cmacs-secondbrain-ingest-redaction-rules)))

(defun cmacs-secondbrain-ingest-redact (text &optional rules)
  "Return TEXT with sensitive matches replaced.

RULES is a list of rule names from `cmacs-secondbrain-ingest-redaction-rules';
nil means the default-on set, t means every rule.  Returns TEXT unchanged
when it is nil.  The second value is not returned; use
`cmacs-secondbrain-ingest-redact-count' to learn how many matches fired."
  (car (cmacs-secondbrain-ingest-redact-count text rules)))

(defun cmacs-secondbrain-ingest-redact-count (text &optional rules)
  "Like `cmacs-secondbrain-ingest-redact' but return (TEXT . COUNT)."
  (if (not (stringp text))
      (cons text 0)
    (let* ((names (cond ((eq rules t) (cmacs-secondbrain-ingest-redaction-rule-names t))
                        ((null rules) (cmacs-secondbrain-ingest-redaction-rule-names))
                        (t rules)))
           (count 0)
           (out text))
      (dolist (name names)
        (let ((rule (assq name cmacs-secondbrain-ingest-redaction-rules)))
          (when rule
            (let ((case-fold-search (memq name '(api-key private-key)))
                  (marker (if cmacs-secondbrain-ingest-redaction-label-rule
                              (format "<redacted:%s>" name)
                            cmacs-secondbrain-ingest-redaction-text)))
              (setq out (replace-regexp-in-string
                         (nth 1 rule)
                         (lambda (_m) (cl-incf count) marker)
                         out t t))))))
      (cons out count))))

(provide 'cmacs-secondbrain-ingest-ai)
;;; cmacs-secondbrain-ingest-ai.el ends here
