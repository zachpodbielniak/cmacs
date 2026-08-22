;;; cmacs-ai-send.el --- Send the thing at point, answer lands in the buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The one AI command that writes back where you were looking.
;;
;; Everything else in cmacs-ai either replaces a region wholesale
;; (`cmacs-ai-rewrite-region') or answers in a window off to the side
;; (`cmacs-ai-ask' and the rest of cmacs-ai-textops).  Neither is what you
;; want when you are writing a document and have a question in the middle
;; of it.  Then you want to type the question where it belongs, press a
;; key, and have the answer appear underneath it -- in the file, in the
;; file's own notation, staying there when you save.
;;
;; Three decisions make that work.
;;
;; 1. The instruction and the context are different things.
;;
;;    gptel conflates them: everything above point *is* the conversation.
;;    That is right for a chat scratchpad and wrong for a .c file, where
;;    the text above point is a thousand lines of code you are not asking
;;    about.  So here the *instruction* is small and local -- the region,
;;    else the line at point, else the paragraph -- and the *document* is
;;    sent separately, explicitly labelled as context, with a marker
;;    substituted at the exact character where the answer will be
;;    inserted.  "Your output replaces this marker" is a far stronger
;;    specification than "respond to line 40", and it costs one string.
;;
;;    Note that the document window is centred on point, unlike
;;    `cmacs-ai-target-truncate', which elides middle-out.  Middle-out is
;;    right for "summarise this file" and exactly backwards here: the part
;;    it throws away is the part surrounding the question.
;;
;; 2. The answer has to be valid in the file it lands in.
;;
;;    A Markdown fence in a .c file is a syntax error.  A `**bold**' in an
;;    Org file renders as literal asterisks.  So the buffer's format is
;;    resolved to a `cmacs-ai-send-format' -- markup, source or prose --
;;    which supplies both the delimiters written around the response and
;;    the format contract handed to the model.
;;
;;    The source profile is *derived*, not tabulated: `comment-start' and
;;    `comment-end' already say how to write prose in C (`/* ... */'),
;;    Python (`#'), Elisp (`;;') and everything else with a major mode, so
;;    a new language costs zero lines here.  The registry exists for the
;;    cases where the generic answer is wrong -- Org, Markdown, and point
;;    sitting inside an Org `#+begin_src c' block, where the correct reply
;;    is C and not Org.
;;
;; 3. Delimiters are visible, and that is what buys the rest.
;;
;;    A text property would keep the buffer tidier and would not survive
;;    the first save.  Written delimiters do, which means a response can
;;    still be found tomorrow: `cmacs-ai-send-delete-response' and
;;    `cmacs-ai-send-regenerate' work by finding the block around point,
;;    and -- in a markup buffer -- so does history.  Prior exchanges are
;;    parsed straight back out of the document (prose between blocks is a
;;    user turn, block contents are the assistant's) and replayed into the
;;    session, so a .org file behaves like a real conversation without
;;    storing conversation state anywhere but the file you are editing.
;;
;;    They are format-appropriate, so they are not eyesores: an Org
;;    special block, an HTML comment in Markdown, an ordinary comment in
;;    source.
;;
;; The response streams in, but is recorded as a single undo step: the
;; commit-message path (`cmacs-ai-commit--stream-to-point') learned the
;; hard way that text arriving in pieces under a live cursor wrecks both
;; point and the undo history.  Inhibiting undo recording during the
;; stream and pushing one entry at the end gets the live feedback without
;; the mess -- `undo' once removes the whole answer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-ai)
(require 'cmacs-ai-target)

(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback &optional executor))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-session-append-message "cmacs-ai-session.c"
                  (session role text))
(declare-function cmacs-ai-client-effective-model "cmacs-ai-client.c" (client))
(declare-function cmacs-ai-client-provider-name "cmacs-ai-client.c" (client))
(declare-function org-current-level "org" ())
(declare-function org-element-type "org-element" (element))
(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-babel-get-src-block-info "ob-core" (&optional no-eval datum))
(declare-function org-src-get-lang-mode "org-src" (lang))

;;;; Customisation ------------------------------------------------------

(defgroup cmacs-ai-send nil
  "Send the text at point to a model and insert the answer in place."
  :group 'cmacs
  :prefix "cmacs-ai-send-")

(defcustom cmacs-ai-send-provider nil
  "Provider for `cmacs-ai-send', or nil for `cmacs-ai-default-provider'.

nil is the useful default: this command is the one you reach for while
writing, so it should follow whatever model you have selected globally
rather than pinning its own.  Set it only if you specifically want
in-buffer answers to come from somewhere other than your default --
a local ollama model, say, for a machine that is offline a lot."
  :type '(choice (const :tag "Follow `cmacs-ai-default-provider'" nil)
                 symbol))

(defcustom cmacs-ai-send-model nil
  "Model string for `cmacs-ai-send', or nil for `cmacs-ai-default-model'."
  :type '(choice (const :tag "Follow `cmacs-ai-default-model'" nil) string))

(defcustom cmacs-ai-send-instruction-unit 'line
  "What `cmacs-ai-send' treats as the instruction when no region is active.

`line'            the line at point (a blank line falls back to the
                  paragraph above it, since a blank line is never an
                  instruction)
`paragraph'       the paragraph at point -- for multi-line questions
`buffer-to-point' everything from the start of the buffer to point,
                  which is gptel's model; useful in a scratch buffer,
                  wasteful in a source file

An active region always wins over all three."
  :type '(choice (const :tag "The line at point" line)
                 (const :tag "The paragraph at point" paragraph)
                 (const :tag "Buffer start to point" buffer-to-point)))

(defcustom cmacs-ai-send-context 'document
  "How much of the buffer `cmacs-ai-send' sends as context.

`document' sends the surrounding document (windowed -- see
`cmacs-ai-send-context-max-chars') with a marker at the insertion point.
`none' sends only the instruction, which is cheaper and occasionally what
you want for a self-contained question."
  :type '(choice (const :tag "The surrounding document" document)
                 (const :tag "Instruction only" none)))

(defcustom cmacs-ai-send-context-max-chars 12000
  "Maximum characters of surrounding document sent as context.

This fires on every send, so an unbounded buffer is a recurring bill, not
a one-off one.  Over the limit the document is windowed around the
insertion point -- head of the file, then as much as fits either side of
where the answer goes -- because that is where the relevant material is.

nil means send the whole buffer however large it is."
  :type '(choice (const :tag "No limit" nil) integer)
  :safe #'integerp)

(defcustom cmacs-ai-send-context-head-chars 800
  "Characters from the start of the file always kept in windowed context.

The head of a file is disproportionately informative -- includes,
imports, the package header, the Org `#+title' -- and is usually nowhere
near point, so it is reserved rather than left to chance."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-send-history t
  "Whether prior exchanges in this buffer are replayed as conversation.

Only applies to markup buffers (Org, Markdown), where the document
genuinely is a transcript: prose between response blocks is read as your
turns, block contents as the model's.  In a source file it stays off
regardless -- the code between two responses is not a conversation.

When history applies, the document is not re-sent as context: it is
already in the replayed turns, and sending both pays for everything
twice."
  :type 'boolean)

(defcustom cmacs-ai-send-history-max-turns 20
  "Most recent conversation turns replayed from the buffer.
Counts individual turns, not exchanges, so 20 is ten round trips."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-send-stream t
  "Whether the answer appears as it arrives.

Either way the whole response is a single undo step.  nil waits and
inserts once, which is marginally less distracting if you keep typing
while a request is in flight."
  :type 'boolean)

(defcustom cmacs-ai-send-tag "ai"
  "Word used in the delimiters written around a response.

Changing this orphans existing blocks: `cmacs-ai-send-regenerate',
`cmacs-ai-send-delete-response' and history replay all find blocks by
this tag, so responses written under the old one become ordinary text."
  :type 'string)

(defcustom cmacs-ai-send-annotate-model t
  "Whether the opening delimiter records which provider and model answered.
Costs a few characters per block and tells you, months later, whether a
paragraph came from a frontier model or a 3B local one."
  :type 'boolean)

(defcustom cmacs-ai-send-insertion-marker "<<<CMACS-AI-RESPOND-HERE>>>"
  "Placeholder substituted into the context at the insertion point.

The model is told its output replaces this.  If a buffer legitimately
contains this string the model will see two of them and may pick the
wrong one; change it if you write about cmacs-ai in cmacs-ai."
  :type 'string)

(defcustom cmacs-ai-send-blank-line-before t
  "Whether to leave a blank line between the instruction and the response."
  :type 'boolean)

;;;; The format profile -------------------------------------------------

(cl-defstruct (cmacs-ai-send-format
               (:constructor cmacs-ai-send-format-create)
               (:copier cmacs-ai-send-format-copy))
  "How a response should be written into one particular buffer.

NAME is a human name for the format (\"Org\", \"C\", \"plain text\"), used
in prompts.  KIND is `markup', `source' or `prose'; actions branch on it
rather than on the major mode.  LANG is the language name for the model.

BEGIN and END are the literal delimiter lines written around a response;
BEGIN is a format string with one %s for the provider/model annotation.
BEGIN-RE and END-RE find them again -- for history, regeneration and
deletion -- and must match what BEGIN and END produce.

CONTRACT is the format half of the system prompt: what markup, or what
comment syntax, the answer has to use to be valid in this buffer.

REMINDER is a one-line restatement of it, appended after the instruction
in every user message.  Both are needed.  A system prompt alone does not
hold a model to a markup it has weaker habits in -- Org especially, where
models fall back to Markdown -- which is the same finding that made
`cmacs-ai-pre-prompt' a per-turn pre-prompt rather than part of
`cmacs-ai-system-prompt'.  The reminder goes last because that is the
position a model weights most.

HISTORY is non-nil when prior blocks in this buffer should be replayed as
conversation."
  name kind lang begin end begin-re end-re contract reminder history)

;;;; Comment syntax -----------------------------------------------------

(defvar cmacs-ai-send--comment-cache (make-hash-table :test 'eq)
  "Cache of MODE -> (START . END) comment syntax, or the symbol `none'.")

(defun cmacs-ai-send--comment-syntax ()
  "Return (START . END) comment syntax for the current buffer, or nil.

Trimmed of the padding modes put in `comment-start' for insertion, since
these are being pasted into a delimiter that supplies its own spacing."
  (when (and (stringp comment-start) (not (string-empty-p comment-start)))
    (let ((start (string-trim comment-start))
          (end   (string-trim (or comment-end ""))))
      ;; Emacs Lisp sets `comment-start' to a single ";", which is correct
      ;; for a trailing comment and wrong for one on its own line -- the
      ;; convention, and what every Lisp file in this tree does, is ";;".
      (when (string= start ";") (setq start ";;"))
      (cons start end))))

(defun cmacs-ai-send--comment-syntax-for-mode (mode)
  "Return (START . END) comment syntax for MODE, or nil.

Instantiates MODE in a temporary buffer once and caches the answer: there
is no way to ask a major mode about its comment syntax without entering
it, and modes are not free to enter."
  (let ((hit (gethash mode cmacs-ai-send--comment-cache)))
    (cond
     ((eq hit 'none) nil)
     (hit hit)
     (t
      (let ((syntax (condition-case nil
                        (with-temp-buffer
                          (delay-mode-hooks (funcall mode))
                          (cmacs-ai-send--comment-syntax))
                      (error nil))))
        (puthash mode (or syntax 'none) cmacs-ai-send--comment-cache)
        syntax)))))

;;;; Delimiters ---------------------------------------------------------
;;
;; Every profile builds its delimiters through one of these, so the pair
;; of literals and the pair of regexps cannot drift apart -- which they
;; would, written out per format, the first time the tag changed.

(defun cmacs-ai-send--delimiters (open-prefix open-suffix close)
  "Return (BEGIN END BEGIN-RE END-RE) for a delimiter shape.

BEGIN is OPEN-PREFIX, a %s for the annotation, then OPEN-SUFFIX; END is
CLOSE.  The regexps tolerate leading whitespace and anything trailing on
the opening line, so a hand-edited block is still recognised."
  (list (concat open-prefix "%s" open-suffix)
        close
        (concat "^[ \t]*" (regexp-quote (string-trim-right open-prefix))
                ".*$")
        (concat "^[ \t]*" (regexp-quote close) "[ \t]*$")))

(defun cmacs-ai-send--comment-delimiters (syntax)
  "Delimiters written as comments, from SYNTAX, a (START . END) cons."
  (let* ((start (car syntax))
         (end   (cdr syntax))
         (tail  (if (string-empty-p end) "" (concat " " end))))
    (cmacs-ai-send--delimiters
     (format "%s %s: " start cmacs-ai-send-tag)
     tail
     (format "%s /%s%s" start cmacs-ai-send-tag tail))))

;;;; Format contracts ---------------------------------------------------
;;
;; Kept as defcustoms rather than inline strings for the same reason the
;; textops prompts are: what a model needs to be told to behave is a
;; matter of taste and of which model, and both change.

(defcustom cmacs-ai-send-allow-headings nil
  "Whether a response may introduce headings in a markup buffer.

Off by default, and that is the right default: the answer is inserted
into the *middle* of a document you are already writing, so a heading
does not decorate it, it restructures it.  A single `* Title' emitted at
the top of a reply silently re-parents every heading below the insertion
point into a new section.

With this on, headings are permitted but constrained to one level below
the heading the answer lands under, so at least they nest rather than
break out.  Either way the model is told to use a bolded line when it
wants to label a section, which reads the same and changes no outline."
  :type 'boolean)

(defcustom cmacs-ai-send-org-contract
  "This is an Org-mode document.  Respond in pure Org markup, never
Markdown.  Concretely:

- Bold is *single asterisks*, never double.  Italic is /slashes/, never
  underscores.  Inline code is ~tildes~ or =equals signs=, never
  backticks.
- Code blocks open with #+BEGIN_SRC lang on its own line and close with
  #+END_SRC.  Never triple-backtick fences.  The language name is
  lowercase -- #+BEGIN_SRC c, not #+BEGIN_SRC C -- because Org looks up
  a babel language by that exact string, and a capitalised one neither
  fontifies nor runs.
- Lists start with a dash and a space, or 1. -- Org reads both.
- Tables are pipe-delimited rows with a |---+---| rule.
- Links are [[target][label]].
- %s

Markdown does not render in Org.  It appears as literal punctuation and
looks broken."
  "Format contract for Org buffers.  %s is the heading clause.

Deliberately written in Org markup rather than about it: a contract that
demonstrates the wrong syntax while forbidding it -- \"respond in
**pure Org markup**\" -- primes the model toward exactly what it is
being told to avoid, which is a mistake this text used to make."
  :type 'string)

(defcustom cmacs-ai-send-markdown-contract
  "This is a Markdown document.  Respond in Markdown:

- Code blocks: triple-backtick fences with the language tag.
- Emphasis: `**bold**', `_italic_', `` `code` ``.
- %s"
  "Format contract for Markdown buffers.  %s is the heading clause."
  :type 'string)

(defcustom cmacs-ai-send-source-contract
  "Your answer is being inserted directly into a %s source file, at the
marker, and nothing rewrites it afterwards.  It must be valid %s:

- Code goes in bare, exactly as it should appear in the file.  Match the
  surrounding indentation, naming and style -- you can see it in the
  context.
- Any prose, explanation or caveat MUST be a comment: %s
- NEVER use Markdown fences, Org blocks, or bare prose.  In a %s file
  they are syntax errors, and this file has to still compile."
  "Format contract for source buffers.
Receives four `format' arguments: the language, the language again, a
description of the comment syntax, and the language once more."
  :type 'string)

(defcustom cmacs-ai-send-org-reminder
  "Reply in Org markup, not Markdown: *bold*, /italic/, ~code~, and
#+BEGIN_SRC lang ... #+END_SRC for code blocks, with lang lowercase."
  "Per-turn format reminder for Org buffers.
Phrased positively on purpose -- it names the syntax to use rather than
the syntax to avoid, so it cannot prime what it is meant to prevent."
  :type 'string)

(defun cmacs-ai-send--markup-reminder (base char)
  "BASE reminder for a markup format using CHAR, plus the heading rule.

The heading rule is repeated here and not only in the contract because
this is the text that goes last, and a heading in the middle of a
document is the single most disruptive thing a reply can do."
  (if cmacs-ai-send-allow-headings
      base
    (concat base "  No headings -- label a section with a "
            (if (eq char ?*) "*bolded line*" "**bolded line**") ".")))

(defcustom cmacs-ai-send-markdown-reminder
  "Reply in Markdown."
  "Per-turn format reminder for Markdown buffers."
  :type 'string)

(defcustom cmacs-ai-send-source-reminder
  "Reply with valid %s only.  Code bare, all prose as %s comments, no
Markdown fences and no Org blocks."
  "Per-turn format reminder for source buffers.
Receives the language name and a description of the comment syntax."
  :type 'string)

(defcustom cmacs-ai-send-prose-reminder
  "Reply in plain text -- no Markdown, no Org markup, no code fences."
  "Per-turn format reminder for plain-text buffers."
  :type 'string)

(defcustom cmacs-ai-send-prose-contract
  "This is a plain text document.  Respond in plain prose -- no Markdown,
no Org markup, no code fences.  Indent or offset anything code-like the
way a plain text file would."
  "Format contract for plain-text buffers."
  :type 'string)

(defun cmacs-ai-send--heading-clause (char)
  "The contract's heading rule for a markup format using CHAR (?* or ?#).

Honours `cmacs-ai-send-allow-headings'.  The refusal names the reason and
offers the substitute, rather than only prohibiting: a model told merely
\"no headings\" tends to emit one anyway when it wants a section label,
whereas one handed an alternative uses it."
  (if (not cmacs-ai-send-allow-headings)
      (format "Do not use headings at all.  Your answer is inserted into the middle of an\n  existing document, where a heading restructures it.  Label a section with a\n  %s instead."
              (if (eq char ?*) "*bolded line*" "**bolded line**"))
    (format "Headings, if you need any, start at %s -- one level below the heading\n  your answer is being inserted under."
            (cmacs-ai-send--heading-prefix char))))

(defun cmacs-ai-send--heading-prefix (char)
  "The heading prefix one level below the heading enclosing point.
CHAR is ?* for Org or ?# for Markdown."
  (let* ((level
          (if (eq char ?*)
              (or (and (fboundp 'org-current-level) (org-current-level)) 0)
            (save-excursion
              (if (re-search-backward "^\\(#+\\)[ \t]" nil t)
                  (length (match-string 1))
                0))))
         ;; A document with no headings above point gets a top-level one;
         ;; otherwise nest, so an answer never breaks out of the section
         ;; it was asked in.
         (want (max 1 (1+ level))))
    (make-string want char)))

;;;; Format registry ----------------------------------------------------

(defvar cmacs-ai-send--formats (make-hash-table :test 'eq)
  "Registered format resolvers, keyed by name symbol.")

(defun cmacs-ai-send-register-format (&rest plist)
  "Register a format resolver from PLIST.

Recognised keys:

  :name      symbol identifying the resolver (required; re-registering
             the same name replaces it, so reloading is safe)
  :modes     list of major modes it applies to, or nil for any
  :predicate optional (lambda () bool), run at point in the buffer
  :build     (lambda () -> `cmacs-ai-send-format' or nil) (required)
  :order     sort key, ascending; lower wins.  Default 50.

BUILD runs at point in the target buffer and may return nil to decline,
so a resolver can claim a mode and still hand back to the generic path
for positions it does not understand."
  (let ((name (plist-get plist :name)))
    (unless name (error "cmacs-ai-send: format needs a :name"))
    (unless (plist-get plist :build)
      (error "cmacs-ai-send: format %s needs a :build" name))
    (puthash name plist cmacs-ai-send--formats)
    name))

(defun cmacs-ai-send-unregister-format (name)
  "Remove the format resolver called NAME."
  (remhash name cmacs-ai-send--formats))

(defun cmacs-ai-send-formats ()
  "Registered format resolvers, in resolution order."
  (let (all)
    (maphash (lambda (_k v) (push v all)) cmacs-ai-send--formats)
    (sort all (lambda (a b) (< (or (plist-get a :order) 50)
                               (or (plist-get b :order) 50))))))

(defun cmacs-ai-send--applies-p (resolver)
  "Non-nil when RESOLVER applies to the current buffer at point."
  (let ((modes (plist-get resolver :modes))
        (pred  (plist-get resolver :predicate)))
    (and (or (null modes) (apply #'derived-mode-p modes))
         (or (null pred) (funcall pred)))))

(defun cmacs-ai-send-format-at-point ()
  "Resolve the `cmacs-ai-send-format' for point in the current buffer."
  (or (cl-loop for resolver in (cmacs-ai-send-formats)
               when (cmacs-ai-send--applies-p resolver)
               thereis (condition-case err
                           (funcall (plist-get resolver :build))
                         (error
                          (message "cmacs-ai-send: format %s failed: %s"
                                   (plist-get resolver :name)
                                   (error-message-string err))
                          nil)))
      (cmacs-ai-send--generic-format)))

;;;; Built-in formats ---------------------------------------------------

(defun cmacs-ai-send--source-format (&optional mode lang syntax)
  "Build a source format for MODE (default `major-mode').

LANG and SYNTAX override the language name and the (START . END) comment
syntax, which is how an Org src block borrows this for its own language.
Returns nil when the mode has no comment syntax -- that is a prose
buffer, not a source one."
  (let* ((mode (or mode major-mode))
         (syntax (or syntax
                     (if (eq mode major-mode)
                         (cmacs-ai-send--comment-syntax)
                       (cmacs-ai-send--comment-syntax-for-mode mode))))
         (lang (or lang (cmacs-ai-target-lang-of-mode mode))))
    (when syntax
      (cl-destructuring-bind (begin end begin-re end-re)
          (cmacs-ai-send--comment-delimiters syntax)
        (cmacs-ai-send-format-create
         :name lang :kind 'source :lang lang
         :begin begin :end end :begin-re begin-re :end-re end-re
         :history nil
         :contract
         (format cmacs-ai-send-source-contract
                 lang lang
                 (if (string-empty-p (cdr syntax))
                     (format "lines starting with `%s'." (car syntax))
                   (format "wrapped in `%s' ... `%s'."
                           (car syntax) (cdr syntax)))
                 lang)
         :reminder
         (format cmacs-ai-send-source-reminder
                 lang
                 (if (string-empty-p (cdr syntax))
                     (car syntax)
                   (format "%s ... %s" (car syntax) (cdr syntax)))))))))

(defun cmacs-ai-send--prose-format ()
  "Build the plain-prose format, for buffers with no comment syntax."
  (cl-destructuring-bind (begin end begin-re end-re)
      (cmacs-ai-send--delimiters
       (format "--- %s: " cmacs-ai-send-tag) " ---"
       (format "--- /%s ---" cmacs-ai-send-tag))
    (cmacs-ai-send-format-create
     :name "plain text" :kind 'prose :lang "text"
     :begin begin :end end :begin-re begin-re :end-re end-re
     :history nil
     :contract cmacs-ai-send-prose-contract
     :reminder cmacs-ai-send-prose-reminder)))

(defun cmacs-ai-send--generic-format ()
  "The fallback: a source format if the mode comments, else prose.

This is where every language cmacs has never heard of is handled, and it
is the reason there is no table of languages in this file."
  (or (cmacs-ai-send--source-format) (cmacs-ai-send--prose-format)))

(defun cmacs-ai-send--org-src-format ()
  "A source format for the Org src block at point, or nil if not in one."
  (when (and (fboundp 'org-element-at-point)
             (fboundp 'org-babel-get-src-block-info))
    (let ((element (ignore-errors (org-element-at-point))))
      (when (and element (eq (org-element-type element) 'src-block))
        (let* ((info (ignore-errors (org-babel-get-src-block-info t element)))
               (lang (and info (car info)))
               ;; Org's own mapping, not (intern (concat lang "-mode")):
               ;; the block languages people actually write -- elisp,
               ;; cpp, shell, bash -- are exactly the ones whose mode is
               ;; NOT lang + "-mode", and guessing wrong here silently
               ;; falls back to the Org markup profile, whose special
               ;; block would terminate the src block it lands in.
               (mode (and lang
                          (if (fboundp 'org-src-get-lang-mode)
                              (org-src-get-lang-mode lang)
                            (intern-soft (concat lang "-mode"))))))
          (when (and mode (fboundp mode))
            (cmacs-ai-send--source-format mode lang)))))))

(cmacs-ai-send-register-format
 :name 'org
 :modes '(org-mode)
 :order 10
 :build
 (lambda ()
   ;; Inside `#+begin_src c' the correct answer is C, not Org: an Org
   ;; special block written there would end the source block.
   (or (cmacs-ai-send--org-src-format)
       (cl-destructuring-bind (begin end begin-re end-re)
           (cmacs-ai-send--delimiters
            (format "#+begin_%s " cmacs-ai-send-tag) ""
            (format "#+end_%s" cmacs-ai-send-tag))
         (cmacs-ai-send-format-create
          :name "Org" :kind 'markup :lang "org"
          :begin begin :end end :begin-re begin-re :end-re end-re
          :history t
          :contract (format cmacs-ai-send-org-contract
                            (cmacs-ai-send--heading-clause ?*))
          :reminder (cmacs-ai-send--markup-reminder
                     cmacs-ai-send-org-reminder ?*))))))

(cmacs-ai-send-register-format
 :name 'markdown
 :modes '(markdown-mode gfm-mode)
 :order 10
 :build
 (lambda ()
   ;; HTML comments: visible in the file, invisible in anything that
   ;; renders it, and legal everywhere in Markdown.
   (cl-destructuring-bind (begin end begin-re end-re)
       (cmacs-ai-send--delimiters
        (format "<!-- %s: " cmacs-ai-send-tag) " -->"
        (format "<!-- /%s -->" cmacs-ai-send-tag))
     (cmacs-ai-send-format-create
      :name "Markdown" :kind 'markup :lang "markdown"
      :begin begin :end end :begin-re begin-re :end-re end-re
      :history t
      :contract (format cmacs-ai-send-markdown-contract
                        (cmacs-ai-send--heading-clause ?#))
      :reminder (cmacs-ai-send--markup-reminder
                 cmacs-ai-send-markdown-reminder ?#)))))

;;;; What is being asked ------------------------------------------------

(defun cmacs-ai-send--paragraph-bounds ()
  "Bounds of the paragraph at point as (BEG . END)."
  (save-excursion
    (let ((end (progn (forward-paragraph) (point)))
          (beg (progn (backward-paragraph) (point))))
      (cons (save-excursion (goto-char beg)
                            (skip-chars-forward " \t\n")
                            (line-beginning-position))
            end))))

(defun cmacs-ai-send--instruction-bounds ()
  "Bounds of the instruction as (BEG . END), honouring the region.

A region always wins.  Otherwise `cmacs-ai-send-instruction-unit'
decides, except that a blank line falls back to the paragraph -- point
resting on the empty line under a question is the common case, and
sending an empty instruction is never what was meant."
  (cond
   ((use-region-p) (cons (region-beginning) (region-end)))
   ((eq cmacs-ai-send-instruction-unit 'buffer-to-point)
    (cons (point-min) (point)))
   ((eq cmacs-ai-send-instruction-unit 'paragraph)
    (cmacs-ai-send--paragraph-bounds))
   ;; Point resting on the empty line *under* a question is the common
   ;; case -- you typed it, pressed RET, then reached for the key.  The
   ;; instruction is then the paragraph above: `forward-paragraph' from a
   ;; blank line would find the one below instead.
   ;;
   ;; The blank test is `looking-at' rather than `thing-at-point', which
   ;; reports the *previous* line at end of buffer and so mistakes the
   ;; single most common position for this command -- end of an empty
   ;; final line -- for a non-empty one.
   ((save-excursion (beginning-of-line) (looking-at-p "[ \t]*$"))
    (save-excursion
      (skip-chars-backward " \t\n")
      (cmacs-ai-send--paragraph-bounds)))
   (t (cons (line-beginning-position) (line-end-position)))))

(defun cmacs-ai-send--insertion-point (end)
  "Where the response block starts, given instruction END.

Always the beginning of the line after the instruction, so a block never
begins halfway along a line of code or prose."
  (save-excursion
    (goto-char end)
    (if (eolp) (min (point-max) (1+ (point))) (line-beginning-position 2))))

;;;; Context ------------------------------------------------------------

(defun cmacs-ai-send--context (pos)
  "The document as context, with the insertion marker at POS.

Windowed around POS when it exceeds `cmacs-ai-send-context-max-chars':
the head of the file, then as much as fits either side of the insertion
point.  Elisions are marked, so the model knows it is seeing an extract
and does not assume a symbol is undefined merely because it cannot see
it."
  (let* ((marker cmacs-ai-send-insertion-marker)
         (before (buffer-substring-no-properties (point-min) pos))
         (after  (buffer-substring-no-properties pos (point-max)))
         (budget cmacs-ai-send-context-max-chars))
    (if (or (null budget) (<= (+ (length before) (length after)) budget))
        (concat before marker after)
      (let* ((head-n (min (length before)
                          (max 0 cmacs-ai-send-context-head-chars)))
             (head (substring before 0 head-n))
             (rest (max 0 (- budget head-n)))
             (near-n (min (- (length before) head-n) (/ rest 2)))
             (near (substring before (- (length before) near-n)))
             (tail-n (min (length after) (- rest near-n)))
             (tail (substring after 0 tail-n))
             (gap (- (length before) head-n near-n))
             (dropped (- (length after) tail-n)))
        (concat head
                (if (> gap 0)
                    (format "\n[... %d characters of this file elided ...]\n"
                            gap)
                  "")
                near marker tail
                (if (> dropped 0)
                    (format "\n[... %d characters of this file elided ...]\n"
                            dropped)
                  ""))))))

;;;; History ------------------------------------------------------------

(defun cmacs-ai-send--coalesce (turns)
  "Collapse consecutive same-role TURNS so roles strictly alternate.
Claude and others reject two user messages in a row, and a hand-deleted
block is enough to produce one."
  (let (acc)
    (dolist (turn turns)
      (if (and acc (eq (caar acc) (car turn)))
          (setcdr (car acc) (concat (cdar acc) "\n\n" (cdr turn)))
        (push (cons (car turn) (cdr turn)) acc)))
    (nreverse acc)))

(defun cmacs-ai-send--history-turns (fmt limit)
  "Parse conversation turns from the buffer up to LIMIT, for format FMT.

Returns (TURNS . TAIL): TURNS is an alternating list of (ROLE . TEXT)
ending on an assistant turn, and TAIL is the position just after the last
complete response block -- everything between there and LIMIT is the turn
you are sending now.

The rule is simply that a response block is the model and anything
between blocks is you.  An unterminated block stops the scan: whatever
follows is being written, not remembered."
  (let ((turns nil)
        (cursor (point-min)))
    (save-excursion
      (goto-char (point-min))
      (catch 'done
        (while (re-search-forward (cmacs-ai-send-format-begin-re fmt) limit t)
          (let* ((block-beg (match-beginning 0))
                 (body-beg (min limit (line-beginning-position 2)))
                 (body-end
                  (save-excursion
                    (goto-char body-beg)
                    (if (re-search-forward (cmacs-ai-send-format-end-re fmt)
                                           limit t)
                        (match-beginning 0)
                      ;; Opened but never closed before the insertion
                      ;; point: stop here rather than swallow the rest of
                      ;; the document as one assistant turn.
                      (throw 'done nil))))
                 (user (string-trim
                        (buffer-substring-no-properties cursor block-beg)))
                 (assistant (string-trim
                             (buffer-substring-no-properties body-beg
                                                             body-end))))
            (unless (string-empty-p user) (push (cons 'user user) turns))
            (unless (string-empty-p assistant)
              (push (cons 'assistant assistant) turns))
            (goto-char body-end)
            (forward-line 1)
            (setq cursor (min limit (point)))))))
    (let* ((all (cmacs-ai-send--coalesce (nreverse turns)))
           ;; Drop a trailing user turn: the current message is appended
           ;; by `cmacs-ai-chat-stream', and two user turns in a row is a
           ;; provider error.
           (all (if (and all (eq (car (car (last all))) 'user))
                    (butlast all)
                  all))
           (limit-n cmacs-ai-send-history-max-turns)
           (kept (if (and limit-n (> (length all) limit-n))
                     (nthcdr (- (length all) limit-n) all)
                   all))
           ;; Keeping the most recent N can decapitate the list into a
           ;; leading assistant turn, which providers also reject.
           (kept (if (and kept (eq (car (car kept)) 'assistant))
                     (cdr kept)
                   kept)))
      (cons kept cursor))))

;;;; Prompts ------------------------------------------------------------

(defun cmacs-ai-send--system-prompt (fmt)
  "The system prompt for format FMT."
  (concat
   "You are answering inside a live Emacs buffer.  Your reply is inserted\n"
   "into the file verbatim, at the marker "
   cmacs-ai-send-insertion-marker ", with no\n"
   "post-processing of any kind.\n\n"
   "Always:\n"
   "- Answer the instruction directly.  No preamble, no restating the\n"
   "  question, no sign-off, no \"here is\".\n"
   "- Do not repeat text that is already in the document.\n"
   "- Do not emit the marker, and do not emit the delimiter lines\n"
   "  (`" (format (cmacs-ai-send-format-begin fmt) "...") "' / `"
   (cmacs-ai-send-format-end fmt) "') -- cmacs writes those itself.\n"
   "- If you cannot answer from what you were given, say so in one line\n"
   "  rather than inventing something.\n\n"
   (cmacs-ai-send-format-contract fmt)))

(defun cmacs-ai-send--user-prompt (fmt instruction context tail)
  "Assemble the user message.

INSTRUCTION is what was asked.  CONTEXT, when non-nil, is the marked-up
document.  TAIL, when non-nil, is the remainder of the document below the
insertion point, sent in the history case where CONTEXT is not.  Each
part is labelled: models do better with provenance, and so does a human
reading the transcript afterwards.

FMT\='s reminder is appended after the instruction.  The format contract is
in the system prompt as well, and the duplication is deliberate: a system
prompt on its own does not reliably hold a model to Org, which every
provider has far more Markdown training behind."
  (let* ((where (or (buffer-file-name) (buffer-name)))
         (parts (list (format "[document: %s | %s]"
                              (if (buffer-file-name)
                                  (abbreviate-file-name where)
                                where)
                              (cmacs-ai-send-format-name fmt)))))
    (when context
      (push (concat "\n[the document, with " cmacs-ai-send-insertion-marker
                    " where your answer will be inserted]\n\n" context)
            parts))
    (when tail
      (push (concat "\n[the rest of the document, below your insertion "
                    "point]\n\n" tail)
            parts))
    (push (concat "\n[instruction]\n\n" instruction) parts)
    ;; Last, because last is the position a model weights most, and the
    ;; format is the constraint most often dropped.
    (when-let* ((reminder (cmacs-ai-send-format-reminder fmt)))
      (push (concat "\n[format]\n\n" reminder) parts))
    (string-join (nreverse parts) "\n")))

(defun cmacs-ai-send--request (fmt pos instruction &optional region)
  "Build the request for FMT at POS with INSTRUCTION.

Returns a plist (:history TURNS :prompt STRING).  This is where the two
context strategies are chosen between, and they are exclusive: when there
are prior exchanges to replay, the document is already in them, and
sending it again as context pays for the whole conversation twice.

REGION non-nil means INSTRUCTION came from an active region.  That has
to win even on the history path: normally the current turn is everything
typed since the last response, but selecting a region is an explicit
statement of scope, and \"the region always wins\" must not silently stop
being true in the one buffer kind where history applies."
  (let* ((history-p (and cmacs-ai-send-history
                         (cmacs-ai-send-format-history fmt)))
         (parsed (and history-p (cmacs-ai-send--history-turns fmt pos)))
         (turns (car parsed)))
    (if turns
        (let* ((pending (string-trim
                         (buffer-substring-no-properties (cdr parsed) pos)))
               (tail (string-trim
                      (cmacs-ai-target-truncate
                       (buffer-substring-no-properties pos (point-max))))))
          (list :history turns
                :prompt (cmacs-ai-send--user-prompt
                         fmt
                         (cond (region instruction)
                               ((string-empty-p pending) instruction)
                               (t pending))
                         nil
                         (unless (string-empty-p tail) tail))))
      (list :history nil
            :prompt (cmacs-ai-send--user-prompt
                     fmt instruction
                     (when (eq cmacs-ai-send-context 'document)
                       (cmacs-ai-send--context pos))
                     nil)))))

;;;; In-flight requests -------------------------------------------------

(defvar-local cmacs-ai-send--inflight nil
  "In-flight sends into this buffer: a list of (PAIR . END-MARKER).")

(defun cmacs-ai-send--forget (pair)
  "Drop PAIR from `cmacs-ai-send--inflight'.
The entries are keyed by the (CLIENT . SESSION) pair cons itself, not by
the client: keying on `(car pair)' here would never match anything, and
every completed request would stay \"in flight\" forever."
  (setq cmacs-ai-send--inflight
        (assq-delete-all pair cmacs-ai-send--inflight)))

;;;###autoload
(defun cmacs-ai-send-cancel ()
  "Cancel every `cmacs-ai-send' still streaming into this buffer."
  (interactive)
  (if (null cmacs-ai-send--inflight)
      (message "cmacs-ai-send: nothing in flight here")
    (let ((n (length cmacs-ai-send--inflight)))
      (dolist (entry cmacs-ai-send--inflight)
        (ignore-errors (cmacs-ai-chat-cancel (cdr (car entry)))))
      (message "cmacs-ai-send: cancelled %d request%s"
               n (if (= n 1) "" "s")))))

(defun cmacs-ai-send--kill-hook ()
  "Cancel in-flight sends when their buffer dies."
  (dolist (entry cmacs-ai-send--inflight)
    (ignore-errors (cmacs-ai-chat-cancel (cdr (car entry))))
    (ignore-errors (cmacs-ai-free-session (car entry)))))

;;;; Insertion ----------------------------------------------------------

(defun cmacs-ai-send--annotation (pair)
  "Provider/model annotation for PAIR's opening delimiter."
  (if (not cmacs-ai-send-annotate-model)
      ""
    (let* ((client (car pair))
           (provider (or (ignore-errors
                           (cmacs-ai-client-provider-name client))
                         (format "%s" (or cmacs-ai-send-provider
                                          cmacs-ai-default-provider))))
           (model (ignore-errors (cmacs-ai-client-effective-model client))))
      (if (and model (not (string-empty-p model)))
          (format "%s/%s" provider model)
        (format "%s" provider)))))

(defun cmacs-ai-send--open-block (fmt pos annotation)
  "Insert FMT's opening delimiter at POS.

Returns (BLOCK-BEG . BODY-MARKER): where the whole insertion starts, for
the single undo entry, and where response text goes, advancing as it
arrives."
  (save-excursion
    (goto-char pos)
    (let ((beg (point)))
      ;; A block that starts mid-line, or hard against the instruction, is
      ;; unreadable in every one of the three formats.
      (unless (bolp) (insert "\n"))
      (when (and cmacs-ai-send-blank-line-before
                 (not (save-excursion (forward-line -1) (looking-at "^[ \t]*$"))))
        (insert "\n"))
      (insert (format (cmacs-ai-send-format-begin fmt) annotation) "\n")
      (let ((body (point-marker)))
        (set-marker-insertion-type body t)
        (cons beg body)))))

(defun cmacs-ai-send--close-block (fmt body)
  "Insert FMT's closing delimiter after BODY.  Returns the end position."
  (save-excursion
    (goto-char body)
    (unless (bolp) (insert "\n"))
    (insert (cmacs-ai-send-format-end fmt) "\n")
    (point)))

(defmacro cmacs-ai-send--silently (&rest body)
  "Run BODY with undo recording off in the current buffer.

Pair it with `cmacs-ai-send--record-undo', which pushes the whole
response as one entry once it is complete, so `undo' removes an answer
in one step instead of forty.  The two cannot be combined: the binding
here is a `let', so a `setq' of `buffer-undo-list' inside BODY would be
thrown away when it unwinds."
  (declare (indent 0) (debug t))
  `(let ((buffer-undo-list t)
         (inhibit-read-only t))
     ,@body))

(defun cmacs-ai-send--record-undo (beg end)
  "Record BEG..END as a single undoable insertion.

Silently does nothing where undo is disabled -- a temporary buffer, or
one that has had `buffer-disable-undo' called on it -- because
`buffer-undo-list' is then the symbol t and consing onto it produces an
improper list that breaks undo for the whole buffer."
  (when (listp buffer-undo-list)
    (undo-boundary)
    (setq buffer-undo-list (cons (cons beg end) buffer-undo-list))
    (undo-boundary)))

;;;; The command --------------------------------------------------------

(defun cmacs-ai-send--settle (fmt beg body acc streamed)
  "Close the response block and make it one undo step.

ACC is everything the model produced and STREAMED how much of it is
already in the buffer -- non-streaming providers, and
`cmacs-ai-send-stream' set to nil, leave that at zero and deliver
everything at the end.  ACC can also be *longer* than what streamed:
the :end payload carries the provider's authoritative full text, and
when that outruns the deltas the missing tail still has to reach the
buffer, not just the byte count in the completion message.  An empty
answer leaves no empty block behind."
  (let ((end (cmacs-ai-send--silently
               (cond
                ((zerop streamed)
                 (save-excursion
                   (goto-char body)
                   (insert (string-trim acc))))
                ((> (length acc) streamed)
                 (save-excursion
                   (goto-char body)
                   (insert (substring acc streamed)))))
               (cmacs-ai-send--close-block fmt body))))
    (if (string-empty-p (string-trim acc))
        (cmacs-ai-send--silently (delete-region beg end))
      (cmacs-ai-send--record-undo beg end))
    ;; The marker has done its job; a marker left pointing into the
    ;; buffer taxes every subsequent edit in it.
    (set-marker body nil)))

(defun cmacs-ai-send--stream (fmt pair request buffer pos)
  "Stream REQUEST for FMT into BUFFER at POS using session PAIR."
  (let* ((annotation (cmacs-ai-send--annotation pair))
         (opened (with-current-buffer buffer
                   (cmacs-ai-send--silently
                     (cmacs-ai-send--open-block fmt pos annotation))))
         (beg (car opened))
         (body (cdr opened))
         (acc "")
         (streamed 0))
    (with-current-buffer buffer
      (push (cons pair body) cmacs-ai-send--inflight)
      (add-hook 'kill-buffer-hook #'cmacs-ai-send--kill-hook nil t))
    ;; Replay first: the session must carry the conversation before the
    ;; new turn is appended to it.
    (dolist (turn (plist-get request :history))
      (cmacs-ai-session-append-message (cdr pair) (car turn) (cdr turn)))
    (cmacs-ai-chat-stream
     (cdr pair) (plist-get request :prompt)
     (lambda (payload)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (pcase (car-safe payload)
             (:start nil)
             (:delta
              (let ((chunk (cadr payload)))
                (when chunk
                  (setq acc (concat acc chunk))
                  (when cmacs-ai-send-stream
                    (setq streamed (+ streamed (length chunk)))
                    (cmacs-ai-send--silently
                      (save-excursion (goto-char body) (insert chunk)))))))
             (:tool-use nil)
             (:end
              ;; Non-streaming providers deliver everything here; so does
              ;; the whole answer when `cmacs-ai-send-stream' is nil.
              (let ((final (or (plist-get (cdr payload) :text) "")))
                (when (> (length (string-trim final))
                         (length (string-trim acc)))
                  (setq acc final)))
              (cmacs-ai-send--settle fmt beg body acc streamed)
              (cmacs-ai-send--forget pair)
              (ignore-errors (cmacs-ai-free-session pair))
              (message "cmacs-ai-send: %d characters inserted"
                       (length (string-trim acc))))
             (:error
              ;; Whatever arrived before the failure is kept: a truncated
              ;; answer is often still worth reading, and deleting text
              ;; the user has already seen appear is worse than leaving it.
              (cmacs-ai-send--settle fmt beg body acc streamed)
              (cmacs-ai-send--forget pair)
              (ignore-errors (cmacs-ai-free-session pair))
              (message "cmacs-ai-send: failed: %s"
                       (or (cadr payload) "stream error"))))))))))

;;;###autoload
(defun cmacs-ai-send (&optional arg)
  "Send the instruction at point to a model; the answer lands below it.

The instruction is the active region, or -- per
`cmacs-ai-send-instruction-unit' -- the line or paragraph at point.  The
answer is written into this buffer, wrapped in delimiters appropriate to
the file's format, as one undo step.

What the model is told depends on the buffer.  In every format it is
given the file's markup or comment syntax and required to produce output
valid in it, so a reply in a .c file is C with C comments and a reply in
a .org file is Org.  In Org and Markdown, prior exchanges in the document
are replayed as conversation (see `cmacs-ai-send-history'); everywhere
else the surrounding document is sent as context with a marker at the
insertion point.

With prefix ARG, choose the provider and model for this one send."
  (interactive "P")
  (cmacs-ai--ensure)
  (when buffer-read-only
    (user-error "cmacs-ai-send: this buffer is read-only"))
  (let* ((fmt (cmacs-ai-send-format-at-point))
         (bounds (cmacs-ai-send--instruction-bounds))
         (instruction (string-trim
                       (buffer-substring-no-properties (car bounds)
                                                       (cdr bounds)))))
    (when (string-empty-p instruction)
      (user-error "cmacs-ai-send: nothing to send here"))
    (let* ((pos (cmacs-ai-send--insertion-point (cdr bounds)))
           (request (cmacs-ai-send--request fmt pos instruction
                                            (use-region-p)))
           (provider (if arg
                         (cmacs-ai--read-provider "Send with provider: ")
                       (or cmacs-ai-send-provider cmacs-ai-default-provider)))
           (model (if arg
                      (cmacs-ai--read-model provider)
                    (or cmacs-ai-send-model cmacs-ai-default-model)))
           (pair (cmacs-ai-make-session provider model
                                        (cmacs-ai-send--system-prompt fmt))))
      (deactivate-mark)
      (message "cmacs-ai-send: asking %s (%s)..."
               provider (cmacs-ai-send-format-name fmt))
      (cmacs-ai-send--stream fmt pair request (current-buffer) pos))))

;;;; Working with responses already in the buffer ------------------------

(defun cmacs-ai-send-response-at-point (&optional fmt)
  "Bounds of the response block around or before point, as (BEG . END).

Returns nil when there is none.  FMT defaults to the format at point.
\"Around or before\" because after reading an answer point is usually
below it, and that still means \"this one\"."
  (let* ((fmt (or fmt (cmacs-ai-send-format-at-point)))
         (begin-re (cmacs-ai-send-format-begin-re fmt))
         (end-re (cmacs-ai-send-format-end-re fmt)))
    (save-excursion
      (let ((here (line-end-position)))
        (goto-char here)
        (when (re-search-backward begin-re nil t)
          (let ((beg (match-beginning 0)))
            (goto-char beg)
            (when (re-search-forward end-re nil t)
              (let ((end (min (point-max) (1+ (match-end 0))))
                    (close-beg (match-beginning 0)))
                ;; A second opening line before that close means the
                ;; block at BEG was never terminated (hand-edited, or a
                ;; kill mid-stream) and the close belongs to the *next*
                ;; block.  Returning that span would hand
                ;; `cmacs-ai-send-delete-response' two blocks plus the
                ;; user's own text between them.
                (goto-char beg)
                (forward-line 1)
                (unless (re-search-forward begin-re close-beg t)
                  (cons beg end))))))))))

;;;###autoload
(defun cmacs-ai-send-delete-response ()
  "Delete the response block around or before point."
  (interactive)
  (let ((bounds (cmacs-ai-send-response-at-point)))
    (unless bounds
      (user-error "cmacs-ai-send: no response block here"))
    (delete-region (car bounds) (cdr bounds))
    (message "cmacs-ai-send: response deleted")))

;;;###autoload
(defun cmacs-ai-send-regenerate (&optional arg)
  "Delete the response block around or before point and ask again.

Point is left on the instruction that produced it, so a regenerate is
exactly a delete plus a send -- including the history replay, which now
sees one fewer exchange.  ARG is passed to `cmacs-ai-send'."
  (interactive "P")
  (let ((bounds (cmacs-ai-send-response-at-point)))
    (unless bounds
      (user-error "cmacs-ai-send: no response block here to regenerate"))
    (delete-region (car bounds) (cdr bounds))
    (goto-char (car bounds))
    ;; The instruction is whatever precedes the block; the blank line the
    ;; block was separated by is not it.
    (skip-chars-backward " \t\n")
    (cmacs-ai-send arg)))

(provide 'cmacs-ai-send)
;;; cmacs-ai-send.el ends here
