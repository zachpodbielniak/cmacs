;;; cmacs-deixis.el --- "Move THAT over THERE": pointing bound to spoken words  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Deictic voice.  You say "move that over there", "summarise this",
;; "close that" while pointing -- with the mouse, a VR laser or a
;; tracked hand -- and each demonstrative is bound to what was being
;; pointed at AT THE MOMENT THE WORD WAS SPOKEN, not at the moment the
;; transcript arrives a second or two later, by when the pointer has
;; moved on to the second thing.
;;
;; Three things that already exist are joined here:
;;
;;   words with times     the recognizer's transcript, word by word
;;                        (`cmacs-deixis-result-words')
;;   a clock              the moment the utterance's audio began, on the
;;                        clock the pointer history uses
;;                        (`cmacs-voice-loop-segment-start-functions')
;;   where the pointer    a ring kept by the compositor
;;   was                  (cmacs/gowl/cmacs-gowl-pointer-history.c), or
;;                        another registered pointing device
;;                        (`cmacs-deixis-register-pointer')
;;
;; The result takes two forms.  For commands, a list of bindings, each
;; demonstrative with a REFERENT plist.  For a model, the utterance
;; annotated -- "move that [that=①] over there [there=②]" -- with a
;; legend naming what ① and ② are by id.  Like `cmacs-ai-view', the
;; legend is a pointer and never the thing: window titles, buffer names
;; and positions, never buffer text.  A model with tools fetches what it
;; needs.
;;
;; `cmacs-deixis-mode' wires this into the voice loop: simple commands
;; ("move that there", "close that", "focus there", "swap this and
;; that", "open that here") run locally with no model at all, and
;; everything else goes on to the loop's usual route, annotated.
;;
;; PRIVACY.  Pointer positions are sampled only while the mode is on AND
;; the voice loop is listening, they live in fixed rings in memory, and
;; the rings are emptied when sampling stops.  Nothing is written to
;; disk.
;;
;; TIMING.  How well a word lines up with the pointer is the sum of
;; several errors, none of which this file can measure for itself; see
;; `cmacs-deixis-latency-ms', `cmacs-deixis-calibrate' and
;; doc_org/cmacs/cmacs-deixis.org.  The design leans on a window around
;; each word and on where the pointer RESTED in it rather than on any
;; one instant, because people point a little before or after the word.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-running-p "cmacs-gowl.c")
(declare-function gowl-pointer-history-now "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-enable "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-at "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-dwell "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-enabled-p
                  "cmacs-gowl-pointer-history.c")
(declare-function gowl-client-info "cmacs-gowl.c")
(declare-function gowl-client-pid "cmacs-gowl.c")
(declare-function gowl-list-monitors "cmacs-gowl.c")
(declare-function gowl-monitor-info "cmacs-gowl.c")
(declare-function gowl-move-client-to-monitor "cmacs-gowl.c")
(declare-function gowl-client-set-geometry "cmacs-gowl.c")
(declare-function gowl-set-tags "cmacs-gowl.c")
(declare-function gowl-swap-clients "cmacs-gowl.c")
(declare-function gowl-close-client "cmacs-gowl.c")
(declare-function gowl-focus-client "cmacs-gowl.c")
(declare-function gowl-list-clients "cmacs-gowl.c")
(declare-function cmacs-handtrack-point-history-now "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-enable
                  "cmacs-handtrack-defuns.c" (enable))
(declare-function cmacs-handtrack-point-history-at
                  "cmacs-handtrack-defuns.c" (ms))
(declare-function cmacs-handtrack-point-history-dwell
                  "cmacs-handtrack-defuns.c"
                  (from-ms to-ms &optional radius min-ms))
(declare-function cmacs-lrg-vr-active-p "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-pointed-window "cmacs-lrgvr.c")
(declare-function cmacs-voice-run-later "cmacs-voice")
(declare-function cmacs-voice-confirm "cmacs-voice-commands")
(declare-function cmacs-voice-loop-state "cmacs-voice-loop")
(declare-function cmacs-voice-loop--arm "cmacs-voice-loop")

(defvar cmacs-voice-loop-mode)
(defvar cmacs-voice-loop-utterance-filter-function)
(defvar cmacs-voice-loop-segment-start-functions)
(defvar cmacs-voice-loop-state-change-functions)
(defvar cmacs-voice-loop--last-target)
(defvar cmacs-voice-confirm-seconds)
(defvar cmacs-handtrack-pointer-mode)


;;;; Customization

(defgroup cmacs-deixis nil
  "Binding spoken demonstratives to what was being pointed at."
  :group 'cmacs
  :prefix "cmacs-deixis-")

(defcustom cmacs-deixis-latency-ms -60
  "Milliseconds added to a word's time before the pointer is looked up.
A word's time is the moment the utterance's audio reached Emacs plus
the word's offset inside the transcript.  The audio was spoken a little
before it reached Emacs (microphone and pipeline buffering), so the true
moment is earlier and the correction is negative.  The default is an
assumption, not a measurement: \\[cmacs-deixis-calibrate] measures it on
your hardware.  Positive values look later."
  :type 'integer)

(defcustom cmacs-deixis-window-before-ms 150
  "How long before a word starts its pointing may have begun.
With `cmacs-deixis-window-after-ms' this is the window in which the
pointer's longest rest is taken as what the word referred to."
  :type 'integer)

(defcustom cmacs-deixis-window-after-ms 300
  "How long after a word ends its pointing may still be going on."
  :type 'integer)

(defcustom cmacs-deixis-words
  '(("this" . object) ("that" . object) ("these" . object) ("those" . object)
    ("it" . pronoun)
    ("here" . place) ("there" . place))
  "The demonstratives, as an alist of (WORD . ROLE).
ROLE is `object' (a thing: this, that), `place' (a destination: here,
there) or `pronoun' (\"it\": bound only when it can refer to something
pointed at, see `cmacs-deixis-pronoun-blockers').  Words are compared
lower-cased with punctuation removed.  Replace the list to use another
language, e.g. ((\"das\" . object) (\"dies\" . object) (\"hier\" . place)
\(\"dort\" . place) (\"da\" . place)) for German."
  :type '(alist :key-type string
                :value-type (choice (const object) (const place)
                                    (const pronoun))))

(defcustom cmacs-deixis-clause-followers
  '("i" "we" "you" "he" "she" "they" "there's" "it's" "is" "was" "would"
    "will" "should" "could" "can" "means" "said")
  "Words after which a preceding `object' word is not a demonstrative.
\"I think that we should\" and \"that is fine\" point at nothing: an
`object' word directly followed by one of these is left alone."
  :type '(repeat string))

(defcustom cmacs-deixis-pronoun-blockers
  '("is" "was" "will" "would" "can" "could" "should" "does" "did" "has"
    "had" "seems" "looks" "sounds" "might" "may" "must" "depends")
  "Words after which a `pronoun' word (\"it\") is not a demonstrative.
\"It is raining\" points at nothing."
  :type '(repeat string))

(defcustom cmacs-deixis-filler-words
  '("please" "over" "right" "just" "the" "to" "up" "in" "into" "on" "onto"
    "at" "one" "window" "buffer" "file" "link" "thing" "screen" "monitor")
  "Words dropped before an utterance is matched against the commands.
So \"please move that window over there\" is \"move <object> <place>\"."
  :type '(repeat string))

(defcustom cmacs-deixis-pointer-order '(vr hand gowl emacs)
  "The pointing devices, in order of preference.
Every device is asked, and of those with an answer the first in this
order wins -- except that a device which has been PARKED on its answer
for longer than `cmacs-deixis-parked-ms' gives way to one that came to
rest on its own answer more recently (see
`cmacs-deixis-choose-referent').  So a mouse left lying where it was
does not outvote a hand raised to point, and a hand left lying in the
pointing pose does not outvote a mouse just moved.  Names are those
given to `cmacs-deixis-register-pointer'.  A registered pointer not
listed here comes after the listed ones."
  :type '(repeat symbol))

(defcustom cmacs-deixis-parked-ms 2000
  "How long a pointer may have rested on a thing and still be pointing at it.
A pointer that came to rest on its answer more than this many
milliseconds before the word's window opened is parked: it is where it
was left, not where anyone is pointing.  A parked pointer still answers
when nothing else does."
  :type 'natnum)

(defcustom cmacs-deixis-hand-confidence 0.9
  "The most a bare hand's referent can be trusted (0..1).
One camera sees where a fingertip is in its image, not where the finger
is aimed, so a hand's answer is never as sure as a mouse's.  The
referent's confidence is this, times the confidence of the pointing
pose, times the share of the word's window the hand rested there."
  :type 'number)

(defcustom cmacs-deixis-announce-hand t
  "Whether a command run on something pointed at by hand says what that was.
A bare hand's aim is approximate, so before a deictic command acts on a
hand referent the echo area names what each word resolved to.
Destructive commands are confirmed as well, whatever pointed
\(`cmacs-deixis-confirm-destructive'), and the question says a hand did."
  :type 'boolean)

(defcustom cmacs-deixis-elsewhere-confidence 0.8
  "How sure a pointer must be to override an active region.
Explicit state beats pointing: with the region active, \"this\" is the
region -- unless the pointer rested on a different window with at least
this confidence (0..1)."
  :type 'number)

(defcustom cmacs-deixis-fallback-to-point t
  "Whether a demonstrative with nothing pointed at means point.
When non-nil, \"this\" and \"here\" said with no pointer referent and no
active region refer to point in the selected window, with low
confidence.  \"It\" never falls back."
  :type 'boolean)

(defcustom cmacs-deixis-fallback-word-ms 350
  "Assumed length of a word when a transcript carries no times at all."
  :type 'integer)

(defcustom cmacs-deixis-sample-interval 0.1
  "Seconds between samples of the pointers that are sampled from Lisp.
That is the plain Emacs mouse (no compositor) and the VR laser.  The
gowl pointer is sampled in C and is not affected."
  :type 'number)

(defcustom cmacs-deixis-confirm-destructive t
  "Whether a destructive deictic command (\"close that\") is confirmed.
When non-nil the question goes through `cmacs-voice-confirm' (a spoken
yes/no or y/n, itself subject to `cmacs-voice-confirm-destructive') when
the voice commands are loaded, else through `y-or-n-p'."
  :type 'boolean)

(defcustom cmacs-deixis-annotate-for-commands nil
  "Whether utterances on the `commands' voice route are annotated too.
The voice-command router matches plain words, so by default it gets the
utterance untouched; the bindings are still in
`cmacs-deixis-last-bindings'."
  :type 'boolean)

(defvar cmacs-deixis-resolved-functions nil
  "Abnormal hook run with (TEXT BINDINGS) after an utterance is resolved.")

(defvar cmacs-deixis-last-bindings nil
  "The bindings of the last utterance resolved, for commands to consult.")

(defvar cmacs-deixis-unclaimed-functions nil
  "Abnormal hook for an utterance with demonstratives that no command took.
Each function is called with (TEXT BINDINGS) -- the utterance and its
bindings, as `cmacs-deixis-resolve' returns them -- until one returns
non-nil, which means it has dealt with the utterance: nothing is sent on
to the voice loop's route.  When all return nil the utterance goes on,
annotated, as before.  Deictic questions (`cmacs-deixis-ask-utterance',
\"what is that?\") are recognised here, after the commands, so a
question can never take an utterance a command matches.")

(defvar cmacs-deixis-clock-function nil
  "When non-nil, a function returning the current time in milliseconds.
Replaces `cmacs-deixis-now-ms'; for tests.")


;;;; The clock

(defun cmacs-deixis-now-ms ()
  "The current time in milliseconds on the pointer history's clock.
With the compositor built in this is CLOCK_MONOTONIC, the clock its ring
stamps samples with.  Otherwise it is wall time, which is as good here:
the only samples to compare with are then the ones this file stamps
with the same function."
  (cond (cmacs-deixis-clock-function (funcall cmacs-deixis-clock-function))
        ((fboundp 'gowl-pointer-history-now) (gowl-pointer-history-now))
        (t (round (* 1000 (float-time))))))


;;;; Words and their times

(defun cmacs-deixis--norm (token)
  "TOKEN lower-cased, with everything but letters, digits and \\=' removed."
  (replace-regexp-in-string "[^[:alnum:]']" "" (downcase (or token ""))))

(defun cmacs-deixis--tokens (text)
  "The whitespace-separated tokens of TEXT."
  (split-string (or text "") "[ \t\n]+" t))

(defun cmacs-deixis--ideograph-p (token)
  "Non-nil when TOKEN begins with a character of a script without spaces."
  (and (> (length token) 0)
       (let ((c (aref token 0)))
         (and (>= c #x2E80) (/= c #x2581)))))

(defun cmacs-deixis-merge-tokens (tokens times &optional end-ms)
  "Merge subword TOKENS with start TIMES (ms) into words with times.
Returns ((WORD START-MS END-MS) ...).  A token that begins with
SentencePiece's marker (U+2581) or a space begins a word; any other
continues the word before it, so punctuation stays on the word it
follows.  A token of a script written without spaces is a word by
itself.  A word ends where the next begins, and no later than 300 ms
after its last token began; END-MS, if given, bounds the last word.

This is the Lisp twin of `build_words' in cmacs/sherpa/cmacs-sherpa-asr.c,
for engines that hand over raw tokens and times."
  (let ((words nil) (cur nil) (start nil) (last nil) (prev-ideo nil))
    (cl-flet ((flush (next)
                (let ((w (string-trim (replace-regexp-in-string
                                       "[ \u2581\t\n]+" " " (or cur "")))))
                  (unless (string-empty-p w)
                    (let ((end (+ last 300)))
                      (when (and next (> end next)) (setq end next))
                      (when (and (null next) end-ms (> end end-ms)) (setq end end-ms))
                      (push (list w start (max start end)) words))))
                (setq cur nil)))
      (cl-loop for tok in tokens
               for time in times
               for ideo = (cmacs-deixis--ideograph-p tok)
               do (when (and cur
                             (or (string-prefix-p "\u2581" tok)
                                 (string-prefix-p " " tok)
                                 ideo prev-ideo))
                    (flush time))
               (unless cur (setq start time))
               (setq cur (concat cur tok)
                     last time
                     prev-ideo ideo))
      (when cur (flush nil)))
    (nreverse words)))

(defun cmacs-deixis-interpolate-words (text start-ms end-ms)
  "Spread the words of TEXT over START-MS..END-MS in proportion to length.
Returns ((WORD START END :approx) ...): each word gets a share of the
span proportional to its length in characters plus one (the gap).  The
times are estimates and are marked so."
  (let* ((toks (cmacs-deixis--tokens text))
         (weights (mapcar (lambda (tok) (1+ (length tok))) toks))
         (total (float (max 1 (apply #'+ weights))))
         (span (max 0 (- end-ms start-ms)))
         (acc 0))
    (cl-loop for tok in toks
             for w in weights
             collect (let ((s (+ start-ms (round (* span (/ acc total)))))
                           (e (+ start-ms (round (* span (/ (+ acc w) total))))))
                       (cl-incf acc w)
                       (list tok s e :approx)))))

(defun cmacs-deixis-result-words (result)
  "The words of recognizer RESULT with times: ((WORD START-MS END-MS . FLAGS) ...).
Times count from the start of the audio the recognizer was given.
In order of preference:
  - RESULT's own :words (sherpa-onnx token-level models), exact;
  - RESULT's :tokens with :timestamps (seconds), merged here;
  - its :segments, each segment's words interpolated inside the
    segment's span and flagged :approx (whisper);
  - only :text: `cmacs-deixis-fallback-word-ms' per word, :approx."
  (let ((words (alist-get :words result))
        (tokens (alist-get :tokens result))
        (stamps (alist-get :timestamps result))
        (segments (alist-get :segments result))
        (text (alist-get :text result)))
    (cond
     ((consp words) (mapcar #'copy-sequence words))
     ((and tokens stamps (= (length tokens) (length stamps)))
      (cmacs-deixis-merge-tokens
       (append tokens nil)
       (mapcar (lambda (s) (round (* 1000 s))) (append stamps nil))
       (alist-get :duration result)))
     ((consp segments)
      (cl-loop for seg in segments
               append (cmacs-deixis-interpolate-words
                       (alist-get :text seg)
                       (or (alist-get :start seg) 0)
                       (or (alist-get :end seg) 0))))
     (text
      (cl-loop for tok in (cmacs-deixis--tokens text)
               for i from 0
               collect (list tok (* i cmacs-deixis-fallback-word-ms)
                             (* (1+ i) cmacs-deixis-fallback-word-ms)
                             :approx))))))

(defun cmacs-deixis--token-times (tokens words)
  "Give each of TOKENS its time from WORDS; a vector of (START END APPROX) or nil.
TOKENS are the words of the text being sent, WORDS the recognizer's
\(WORD START END ...) list.  The text is usually the transcript with the
wake phrase cut off the front, so the two are matched from the END,
skipping a recognizer word or two where they disagree (\"21\" against
\"twenty one\").  A token left unmatched takes a time interpolated from
its matched neighbours."
  (let* ((n (length tokens))
         (out (make-vector n nil))
         (wv (vconcat words))
         (j (1- (length wv))))
    ;; Backwards greedy match.
    (cl-loop for i downfrom (1- n) to 0
             for tok = (cmacs-deixis--norm (nth i tokens))
             do (cl-loop for k downfrom j to (max 0 (- j 3))
                         when (equal tok (cmacs-deixis--norm (car (aref wv k))))
                         return (let ((w (aref wv k)))
                                  (aset out i (list (nth 1 w) (nth 2 w)
                                                    (and (memq :approx w) t)))
                                  (setq j (1- k)))))
    ;; Fill the gaps between matched tokens by index.
    (dotimes (i n)
      (unless (aref out i)
        (let ((lo (cl-loop for a downfrom (1- i) to 0
                           when (aref out a) return a))
              (hi (cl-loop for b from (1+ i) below n
                           when (aref out b) return b)))
          (when (and lo hi)
            (let* ((t0 (nth 1 (aref out lo)))
                   (t1 (nth 0 (aref out hi)))
                   (step (/ (float (- t1 t0)) (- hi lo))))
              (aset out i (list (round (+ t0 (* step (- i lo 1))))
                                (round (+ t0 (* step (- i lo))))
                                t)))))))
    out))


;;;; Finding the demonstratives

(defun cmacs-deixis-find (text)
  "The demonstratives in TEXT: a list of plists (:index :word :token :role).
INDEX counts TEXT's whitespace-separated tokens.  See
`cmacs-deixis-words' for the vocabulary, and
`cmacs-deixis-clause-followers' / `cmacs-deixis-pronoun-blockers' for
the uses of those words that are left alone."
  (let* ((tokens (cmacs-deixis--tokens text))
         (norms (mapcar #'cmacs-deixis--norm tokens)))
    (cl-loop for tok in tokens
             for norm in norms
             for i from 0
             for role = (cdr (assoc-string norm cmacs-deixis-words t))
             for next = (nth (1+ i) norms)
             when (and role
                       (not (and (eq role 'object) next
                                 (member next cmacs-deixis-clause-followers)))
                       (not (and (eq role 'pronoun) next
                                 (member next cmacs-deixis-pronoun-blockers))))
             collect (list :index i :word norm :token tok :role role))))


;;;; Pointing devices

(defvar cmacs-deixis--pointers nil
  "Registered pointers: an alist of (NAME . PLIST).
PLIST has :function, and optionally :start and :stop.")

(defvar cmacs-deixis-lookup-window nil
  "While a pointer function runs: (FROM-MS . TO-MS) around the word, or nil.
A pointer that keeps a history should answer with where it rested
longest in this window rather than where it was at the one instant it
is called with.")

(defun cmacs-deixis-register-pointer (name function &rest props)
  "Register pointing device NAME, asked through FUNCTION.
FUNCTION is called with a time MS (on the clock of
`cmacs-deixis-now-ms') and returns a referent plist for what the device
was pointing at then, or nil.  `cmacs-deixis-lookup-window' is bound
around the call.  A referent has
  :kind        `window' (a desktop window), `buffer-position', `region',
               `point', `file', `url', `monitor', `tag' or `place'
  :label       a short human description, naming things by id --
               never buffer text
  :confidence  0..1
and the fields of its kind: :client and :client-id, :buffer :window
:position, :beg :end, :monitor, :x :y, :path, :url, :tag.

PROPS may give :start and :stop, functions of no arguments called when
sampling begins and ends (the voice loop starts and stops listening
with `cmacs-deixis-mode' on).  A pointer must hold positions only
between the two, and only in memory."
  (setf (alist-get name cmacs-deixis--pointers)
        (append (list :function function) props))
  name)

(defun cmacs-deixis-unregister-pointer (name)
  "Forget pointing device NAME."
  (setq cmacs-deixis--pointers (assq-delete-all name cmacs-deixis--pointers)))

(defun cmacs-deixis--pointer-names ()
  "Registered pointer names, `cmacs-deixis-pointer-order' first."
  (let ((known (mapcar #'car cmacs-deixis--pointers)))
    (append (cl-remove-if-not (lambda (n) (memq n known)) cmacs-deixis-pointer-order)
            (cl-remove-if (lambda (n) (memq n cmacs-deixis-pointer-order))
                          (reverse known)))))

(defun cmacs-deixis--parked-p (referent from)
  "Non-nil when REFERENT's pointer has been lying on it since long before FROM.
A referent says when its pointer came to rest there with :since (ms).
One that does not say is taken at its word: not parked."
  (let ((since (plist-get referent :since)))
    (and (numberp since) (numberp from)
         (> (- from since) cmacs-deixis-parked-ms))))

(defun cmacs-deixis-choose-referent (candidates from)
  "Choose among CANDIDATES for a word whose window opens at FROM (ms).
CANDIDATES are the referents of the pointers that had an answer, in
order of preference (`cmacs-deixis-pointer-order').  The first that is
not parked wins: one whose pointer came to rest on it no more than
`cmacs-deixis-parked-ms' before FROM, or that gives no :since at all.
When every candidate is parked, the first.  Pure: referents in, one of
them out.

The point is that the two kinds of pointer fail in opposite ways.  A
mouse always has an answer, because it is always somewhere; a hand has
one only while it holds the pointing pose.  Plain \"first answer wins\"
therefore lets whichever is listed first shadow the other for good, and
a rule about recency is what lets a deliberate gesture with either beat
the one that was merely left where it was."
  (or (cl-find-if-not (lambda (r) (cmacs-deixis--parked-p r from)) candidates)
      (car candidates)))

(defun cmacs-deixis--pointer-referent (ms from to)
  "What was being pointed at around MS, or nil.
FROM and TO bound the word's window.  Every registered pointer is
asked; `cmacs-deixis-choose-referent' picks among the answers."
  (let ((cmacs-deixis-lookup-window (and from to (cons from to))))
    (cmacs-deixis-choose-referent
     (cl-loop for name in (cmacs-deixis--pointer-names)
              for fn = (plist-get (alist-get name cmacs-deixis--pointers)
                                  :function)
              ;; A broken provider costs its own answer, not the utterance.
              for r = (and fn (condition-case err
                                  (funcall fn ms)
                                (error (message "Deixis: pointer %s: %s" name
                                                (error-message-string err))
                                       nil)))
              when r collect (if (plist-get r :device) r
                               (append r (list :device name))))
     from)))


;;;; Referents inside Emacs

(defun cmacs-deixis--buffer-label (buffer position)
  "A label for POSITION in BUFFER: its name and line, never its text."
  (with-current-buffer buffer
    (format "buffer: %s, line %d (position %d)%s"
            (buffer-name) (line-number-at-pos position t) position
            (if buffer-file-name
                (format ", file %s" (abbreviate-file-name buffer-file-name))
              ""))))

(defun cmacs-deixis--frame-referent (frame x y confidence)
  "The referent at pixel X, Y of FRAME, or nil off every window.
The lookup happens now, against the windows and buffers as they are
now, so the result is flagged :approximate."
  (when-let* (((frame-live-p frame))
              (posn (ignore-errors (posn-at-x-y (round x) (round y) frame)))
              (win (posn-window posn))
              ((windowp win))
              ((window-live-p win)))
    (let* ((buf (window-buffer win))
           (pos (or (and (integerp (posn-point posn)) (posn-point posn))
                    (window-point win))))
      (list :kind 'buffer-position :window win :buffer buf :position pos
            :frame frame :approximate t :confidence confidence
            :label (cmacs-deixis--buffer-label buf pos)
            ;; The pixel inside FRAME, for a buffer whose content is not
            ;; text at a position (a web view): `cmacs-deixis-ask' turns
            ;; it into a place on the page.
            :frame-x (round x) :frame-y (round y)))))

(defun cmacs-deixis--region-referent ()
  "The active region of the selected window's buffer as a referent, or nil."
  (with-current-buffer (window-buffer (selected-window))
    (when (use-region-p)
      (let ((beg (region-beginning)) (end (region-end)))
        (list :kind 'region :buffer (current-buffer) :window (selected-window)
              :beg beg :end end :confidence 0.9
              :label (format "region: %s, positions %d-%d (lines %d-%d)"
                             (buffer-name) beg end
                             (line-number-at-pos beg t)
                             (line-number-at-pos end t)))))))

(defun cmacs-deixis--point-referent ()
  "Point in the selected window as a low-confidence referent."
  (let* ((win (selected-window)) (buf (window-buffer win))
         (pos (window-point win)))
    (list :kind 'point :buffer buf :window win :position pos :confidence 0.3
          :label (concat "point, " (cmacs-deixis--buffer-label buf pos)))))

(defun cmacs-deixis--emacs-referent-p (r)
  "Non-nil when referent R is a live Emacs buffer (position, region, point)."
  (and (memq (plist-get r :kind) '(buffer-position region point))
       (buffer-live-p (plist-get r :buffer))))

(defun cmacs-deixis--desktop-window-p (r)
  "Non-nil when referent R is a desktop window that still exists."
  (and (eq (plist-get r :kind) 'window)
       (plist-get r :client)
       (not (plist-get r :stale))))


;;;; The gowl pointer

(defun cmacs-deixis--gowl-live-p ()
  "Non-nil when the compositor and its pointer history are there."
  (and (fboundp 'gowl-pointer-history-dwell)
       (fboundp 'gowl-running-p)
       (gowl-running-p)))

(defun cmacs-deixis--gowl-monitor-label (n x y)
  "A label for monitor index N, pointed at layout position X, Y."
  (let ((name (ignore-errors
                (alist-get 'name (gowl-monitor-info (nth n (gowl-list-monitors)))))))
    (format "monitor %d%s at %d,%d" n (if name (format " (%s)" name) "")
            (round x) (round y))))

(defun cmacs-deixis--emacs-frame-for (title)
  "The Emacs frame a gowl client titled TITLE most likely is."
  (or (cl-find-if (lambda (f) (equal (frame-parameter f 'name) title))
                  (frame-list))
      (selected-frame)))

(defun cmacs-deixis--gowl-referent (sample)
  "Turn pointer-history SAMPLE (a plist) into a referent.
A window that has closed since the sample is a `window' referent
flagged :stale, with no :client: commands refuse it and the legend says
so.  Emacs's own frame is refined to the Emacs window and buffer
position under the pointer -- looked up now, hence approximate."
  (let* ((x (plist-get sample :x)) (y (plist-get sample :y))
         (client (plist-get sample :client))
         (id (or (plist-get sample :client-id) 0))
         (monitor (plist-get sample :monitor))
         (duration (plist-get sample :duration))
         (window cmacs-deixis-lookup-window)
         ;; Half for having been there at all, the rest for how much of
         ;; the word's window the pointer spent there.
         (confidence
          (if (and duration window (> (- (cdr window) (car window)) 0))
              (min 1.0 (+ 0.5 (* 0.5 (/ (float duration)
                                        (- (cdr window) (car window))))))
            0.5))
         (where (list :x x :y y :monitor monitor)))
    (cond
     ((and (null client) (> id 0))
      (append (list :kind 'window :stale t :client-id id :confidence 0.0
                    :label (format "a window that has since closed (client %d)" id))
              where))
     (client
      (let* ((info (ignore-errors (gowl-client-info client)))
             (title (or (alist-get 'title info) ""))
             (app (or (alist-get 'app-id info) ""))
             (geom (alist-get 'geometry info))
             (emacs (and (not (alist-get 'embedded info))
                         (eql (ignore-errors (gowl-client-pid client)) (emacs-pid))))
             (inner (and emacs geom
                         (cmacs-deixis--frame-referent
                          (cmacs-deixis--emacs-frame-for title)
                          (- x (nth 0 geom)) (- y (nth 1 geom)) confidence))))
        (if inner
            (append inner (list :client client :client-id id) where)
          (append (list :kind 'window :client client :client-id id
                        :app-id app :title title
                        :embedded (alist-get 'embedded info)
                        :floating (alist-get 'floating info)
                        :confidence confidence
                        :label (format "window: %s \u2014 '%s' (client %d)"
                                       (if (string-empty-p app) "?" app) title id))
                  where))))
     (monitor
      (append (list :kind 'monitor :confidence confidence
                    :label (cmacs-deixis--gowl-monitor-label monitor x y))
              where)))))

(defun cmacs-deixis--gowl-since (sample)
  "When the pointer came to be where pointer-history SAMPLE has it (ms).
A dwell's :time is clipped to the window it was asked about; the ring
entry in force at that moment says when the pointer really got there.
A mouse nobody is touching makes no new entries, so this is how a
parked pointer is told from one that has just arrived."
  (let ((time (plist-get sample :time)))
    (or (and time (plist-get (gowl-pointer-history-at time) :time))
        time)))

(defun cmacs-deixis--gowl-pointer (ms)
  "The gowl pointer's referent around MS, from the compositor's ring."
  (when (cmacs-deixis--gowl-live-p)
    (let* ((w cmacs-deixis-lookup-window)
           (sample (or (and w (gowl-pointer-history-dwell (car w) (cdr w)))
                       (gowl-pointer-history-at ms)))
           (r (and sample (cmacs-deixis--gowl-referent sample))))
      (and r (append r (list :since (cmacs-deixis--gowl-since sample)))))))

(defun cmacs-deixis--gowl-start ()
  "Start the compositor's pointer ring."
  (when (cmacs-deixis--gowl-live-p)
    (gowl-pointer-history-enable t)))

(defun cmacs-deixis--gowl-stop ()
  "Stop the compositor's pointer ring, which empties it."
  (when (and (fboundp 'gowl-pointer-history-enable)
             (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-pointer-history-enable nil)))


;;;; Pointers sampled from Lisp: the plain Emacs mouse and the VR laser

(defconst cmacs-deixis--ring-size 128
  "Samples each Lisp-side ring keeps.")

(defvar cmacs-deixis--mouse-ring nil
  "Recent mouse samples, newest first: (MS FRAME X Y).")
(defvar cmacs-deixis--vr-ring nil
  "Recent VR laser samples, newest first: (MS WINDOW).")
(defvar cmacs-deixis--sample-timer nil
  "The timer filling the Lisp-side rings, or nil.")

(defun cmacs-deixis--ring-push (ring-symbol entry)
  "Push ENTRY (MS . STATE) on the ring in RING-SYMBOL if STATE changed.
An entry means \"from MS on\", so an unchanged state needs no new one."
  (let ((ring (symbol-value ring-symbol)))
    (unless (equal (cdr entry) (cdar ring))
      (push entry ring)
      (when (> (length ring) cmacs-deixis--ring-size)
        (setcdr (nthcdr (1- cmacs-deixis--ring-size) ring) nil))
      (set ring-symbol ring))))

(defun cmacs-deixis--ring-at (ring ms)
  "The newest entry of RING (newest first) at or before MS."
  (cl-find-if (lambda (e) (<= (car e) ms)) ring))

(defun cmacs-deixis--ring-dwell (ring from to)
  "The entry of RING whose state held longest between FROM and TO.
Returns (ENTRY . DURATION-MS), or nil."
  (let ((best nil) (best-d -1) (next-ms to))
    ;; Newest first: each entry lasts until the one after it in time.
    (cl-loop for e in ring
             for start = (max (car e) from)
             for end = (min next-ms to)
             do (when (and (<= (car e) to) (>= end start)
                           (>= (- end start) best-d))
                  (setq best e best-d (- end start)))
             (setq next-ms (car e))
             until (<= (car e) from))
    (and best (cons best best-d))))

(defun cmacs-deixis--sample ()
  "Take one sample of the pointers that have no history of their own."
  (let ((now (cmacs-deixis-now-ms)))
    ;; The Emacs mouse, only where no compositor keeps a better record.
    (unless (cmacs-deixis--gowl-live-p)
      (when-let* ((mp (ignore-errors (mouse-pixel-position)))
                  ((framep (car mp)))
                  ((numberp (cadr mp))))
        (cmacs-deixis--ring-push 'cmacs-deixis--mouse-ring
                                 (list now (car mp) (cadr mp) (cddr mp)))))
    (when (and (fboundp 'cmacs-lrg-vr-active-p) (cmacs-lrg-vr-active-p))
      (cmacs-deixis--ring-push 'cmacs-deixis--vr-ring
                               (list now (cmacs-lrg-vr-pointed-window))))))

(defun cmacs-deixis--lisp-sampling-start ()
  "Start the timer that fills the Lisp-side rings."
  (unless cmacs-deixis--sample-timer
    (setq cmacs-deixis--sample-timer
          (run-at-time 0 cmacs-deixis-sample-interval #'cmacs-deixis--sample))))

(defun cmacs-deixis--lisp-sampling-stop ()
  "Stop the timer and forget every sample."
  (when cmacs-deixis--sample-timer
    (cancel-timer cmacs-deixis--sample-timer)
    (setq cmacs-deixis--sample-timer nil))
  (setq cmacs-deixis--mouse-ring nil
        cmacs-deixis--vr-ring nil))

(defun cmacs-deixis--ring-lookup (ring ms)
  "RING's answer around MS: (ENTRY . CONFIDENCE), or nil."
  (let* ((w cmacs-deixis-lookup-window)
         (dwell (and w (cmacs-deixis--ring-dwell ring (car w) (cdr w)))))
    (cond (dwell
           (cons (car dwell)
                 (min 1.0 (+ 0.5 (* 0.5 (/ (float (cdr dwell))
                                           (max 1 (- (cdr w) (car w)))))))))
          ((cmacs-deixis--ring-at ring ms)
           (cons (cmacs-deixis--ring-at ring ms) 0.5)))))

(defun cmacs-deixis--emacs-pointer (ms)
  "The plain Emacs mouse's referent around MS."
  (when-let* ((hit (cmacs-deixis--ring-lookup cmacs-deixis--mouse-ring ms))
              (e (car hit))
              (r (cmacs-deixis--frame-referent (nth 1 e) (nth 2 e) (nth 3 e)
                                               (cdr hit))))
    ;; A ring entry means "from this time on": its time is when the
    ;; mouse came to rest here.
    (append r (list :since (car e)))))

(defun cmacs-deixis--vr-pointer (ms)
  "The VR laser's referent around MS: the Emacs window it was on.
The laser's history is the window only (`cmacs-lrg-vr-pointed-window'),
so the position is that window's point."
  (when-let* ((hit (cmacs-deixis--ring-lookup cmacs-deixis--vr-ring ms))
              (win (nth 1 (car hit)))
              ((window-live-p win)))
    (let ((buf (window-buffer win)) (pos (window-point win)))
      (list :kind 'buffer-position :window win :buffer buf :position pos
            :approximate t :confidence (cdr hit) :since (car (car hit))
            :label (cmacs-deixis--buffer-label buf pos)))))


;;;; A camera-tracked hand

;; Two cases.  With `cmacs-handtrack-pointer-mode' on, one hand IS the
;; gowl pointer and the compositor's ring already holds where it went.
;; Without it -- or for the other hand -- a hand points by holding the
;; pointing pose (index finger out, the other three curled), and
;; handtrack keeps a ring of its own of where the fingertip then was on
;; the screen (cmacs/handtrack/cmacs-handtrack-point-history.c), on the
;; compositor's clock and stamped with the camera frame's time.
;;
;; One camera cannot see where a finger is AIMED, only where its tip is
;; in the image.  So this is a cursor held in the air, mapped onto the
;; screen like the hand cursor, and every referent it yields is
;; approximate and capped at `cmacs-deixis-hand-confidence'.

(defun cmacs-deixis--hand-live-p ()
  "Non-nil when this build keeps a history of where a bare hand pointed."
  (fboundp 'cmacs-handtrack-point-history-dwell))

(defun cmacs-deixis--hand-clock-offset ()
  "Milliseconds to add to a time of `cmacs-deixis-now-ms' for the hand ring.
The hand ring is always on CLOCK_MONOTONIC.  So is `cmacs-deixis-now-ms'
whenever the compositor is built in, and then this is 0.  In a build
with hand tracking and no compositor that clock is wall time, and the
two are a constant apart, measured here."
  (if (or cmacs-deixis-clock-function
          (fboundp 'gowl-pointer-history-now)
          (not (fboundp 'cmacs-handtrack-point-history-now)))
      0
    (- (cmacs-handtrack-point-history-now) (cmacs-deixis-now-ms))))

(defun cmacs-deixis--gowl-client-by-id (id)
  "The live desktop window with client id ID, or nil.
The hand ring names a window by id, as the mouse ring does internally: a
window can close between the sample and the lookup."
  (and (integerp id) (> id 0)
       (fboundp 'gowl-list-clients)
       (cl-find-if (lambda (c)
                     (eql (alist-get 'id (ignore-errors (gowl-client-info c)))
                          id))
                   (ignore-errors (gowl-list-clients)))))

(defun cmacs-deixis--hand-frame-referent (sample confidence)
  "Resolve hand SAMPLE against Emacs's own frames, with no compositor.
The fingertip's fractions across the output (:u, :v) are laid over the
monitor the selected frame is on, and the frame whose edges contain
that point is asked what is there.  Where the window system does not
tell a frame its own position (Wayland), every frame appears to sit at
the monitor's origin, and this is as approximate as that."
  (when-let* ((u (plist-get sample :u))
              (v (plist-get sample :v))
              (geom (ignore-errors (frame-monitor-geometry (selected-frame))))
              (sx (+ (nth 0 geom) (* u (max 0 (1- (nth 2 geom))))))
              (sy (+ (nth 1 geom) (* v (max 0 (1- (nth 3 geom)))))))
    (cl-loop for frame in (frame-list)
             for e = (and (frame-visible-p frame)
                          (ignore-errors (frame-edges frame 'native-edges)))
             when (and e (<= (nth 0 e) sx) (< sx (nth 2 e))
                       (<= (nth 1 e) sy) (< sy (nth 3 e)))
             return (cmacs-deixis--frame-referent
                     frame (- sx (nth 0 e)) (- sy (nth 1 e)) confidence))))

(defun cmacs-deixis--hand-referent (sample &optional clock-offset)
  "Turn hand-history SAMPLE (a plist) into a referent, or nil.
With the compositor running and layout pixels in the sample, the
position resolves exactly as the mouse's does
\(`cmacs-deixis--gowl-referent'): a desktop window, refined inside
Emacs's own frame to the Emacs window and buffer position, else the
monitor.  Otherwise it resolves against Emacs's frames alone.
CLOCK-OFFSET is `cmacs-deixis--hand-clock-offset', taken back off the
sample's :since."
  (let* ((pose (min 1.0 (max 0.0 (or (plist-get sample :confidence) 0.5))))
         (r (if (and (plist-get sample :layout) (cmacs-deixis--gowl-live-p))
                (cmacs-deixis--gowl-referent
                 (append (list :client (cmacs-deixis--gowl-client-by-id
                                        (plist-get sample :client-id)))
                         sample))
              (cmacs-deixis--hand-frame-referent sample 1.0))))
    (when r
      ;; Leading keys shadow R's own (`plist-get' takes the first).
      (append
       (list :device 'hand
             :hand (plist-get sample :hand)
             :approximate t
             ;; R's confidence is the share of the window spent there
             ;; (0 for a window that has closed); the pose and the cap
             ;; scale it down.
             :confidence (* cmacs-deixis-hand-confidence pose
                            (or (plist-get r :confidence) 0.5))
             :since (and (plist-get sample :since)
                         (- (plist-get sample :since) (or clock-offset 0))))
       r))))

(defun cmacs-deixis--hand-bare-pointer (ms)
  "What a hand in the pointing pose rested on around MS, or nil.
With a word's window, only a rest of at least
`cmacs-handtrack-point-dwell-ms' inside it counts: a hand passing
through refers to nothing, and there is no falling back to wherever it
was at the one instant MS."
  (when (cmacs-deixis--hand-live-p)
    (let* ((off (cmacs-deixis--hand-clock-offset))
           (w cmacs-deixis-lookup-window)
           (sample (if w
                       (cmacs-handtrack-point-history-dwell (+ (car w) off)
                                                            (+ (cdr w) off))
                     (cmacs-handtrack-point-history-at (+ ms off)))))
      (and sample (cmacs-deixis--hand-referent sample off)))))

(defun cmacs-deixis--hand-pointer (ms)
  "A camera-tracked hand's referent around MS.
A bare hand holding the pointing pose comes first.  Failing that, with
`cmacs-handtrack-pointer-mode' on the hand IS the gowl pointer, and the
compositor's ring holds where it went."
  (or (cmacs-deixis--hand-bare-pointer ms)
      (when (bound-and-true-p cmacs-handtrack-pointer-mode)
        (when-let* ((r (cmacs-deixis--gowl-pointer ms)))
          (append (list :device 'hand) r)))))

(defun cmacs-deixis--hand-start ()
  "Start noting where a bare hand points."
  (when (fboundp 'cmacs-handtrack-point-history-enable)
    (cmacs-handtrack-point-history-enable t)))

(defun cmacs-deixis--hand-stop ()
  "Stop noting where a bare hand points, which empties its ring."
  (when (fboundp 'cmacs-handtrack-point-history-enable)
    (cmacs-handtrack-point-history-enable nil)))

(cmacs-deixis-register-pointer 'gowl #'cmacs-deixis--gowl-pointer
                               :start #'cmacs-deixis--gowl-start
                               :stop #'cmacs-deixis--gowl-stop)
(cmacs-deixis-register-pointer 'emacs #'cmacs-deixis--emacs-pointer
                               :start #'cmacs-deixis--lisp-sampling-start
                               :stop #'cmacs-deixis--lisp-sampling-stop)
(cmacs-deixis-register-pointer 'vr #'cmacs-deixis--vr-pointer)
(cmacs-deixis-register-pointer 'hand #'cmacs-deixis--hand-pointer
                               :start #'cmacs-deixis--hand-start
                               :stop #'cmacs-deixis--hand-stop)


;;;; Resolving

(defun cmacs-deixis--elsewhere-p (pointer region)
  "Non-nil when POINTER clearly points away from REGION's window."
  (and pointer
       (>= (or (plist-get pointer :confidence) 0)
           cmacs-deixis-elsewhere-confidence)
       (not (eq (plist-get pointer :window) (plist-get region :window)))))

(defun cmacs-deixis-referent-at (ms from to role)
  "What a word of ROLE spoken at MS (window FROM..TO) refers to, or nil.
MS nil means the word's time is unknown: no pointer is asked.
Explicit state beats pointing: for an `object' or `pronoun' word an
active region is the referent unless the pointer clearly rested
elsewhere (`cmacs-deixis-elsewhere-confidence')."
  (let ((pointer (and ms (cmacs-deixis--pointer-referent ms from to)))
        (region (and (memq role '(object pronoun))
                     (cmacs-deixis--region-referent))))
    (cond ((and region (not (cmacs-deixis--elsewhere-p pointer region))) region)
          (pointer)
          ((and cmacs-deixis-fallback-to-point (not (eq role 'pronoun)))
           (cmacs-deixis--point-referent)))))

(defun cmacs-deixis--pointer-now ()
  "What the pointer is on at this moment, as a referent, or nil.
Unlike a word's referent this needs no history: it is asked outside any
utterance, by a command.  The compositor's ring is the one place that
knows which window is under the pointer, so when it is not sampling it
is switched on for the one lookup -- which takes a sample at once -- and
off again, which empties it.  Nothing is kept."
  (let ((cmacs-deixis-lookup-window nil))
    (cond
     ((and (fboundp 'cmacs-lrg-vr-active-p) (cmacs-lrg-vr-active-p)
           (window-live-p (cmacs-lrg-vr-pointed-window)))
      (let* ((win (cmacs-lrg-vr-pointed-window))
             (buf (window-buffer win)) (pos (window-point win)))
        (list :kind 'buffer-position :window win :buffer buf :position pos
              :device 'vr :approximate t :confidence 1.0
              :label (cmacs-deixis--buffer-label buf pos))))
     ((cmacs-deixis--gowl-live-p)
      (let* ((was-on (and (fboundp 'gowl-pointer-history-enabled-p)
                          (gowl-pointer-history-enabled-p)))
             (sample (unwind-protect
                         (progn
                           (unless was-on (gowl-pointer-history-enable t))
                           (gowl-pointer-history-at (cmacs-deixis-now-ms)))
                       (unless was-on (gowl-pointer-history-enable nil))))
             (r (and sample (cmacs-deixis--gowl-referent sample))))
        ;; Leading keys shadow R's own: the pointer is there NOW, which
        ;; is as sure as a pointer gets.
        (and r (append (list :device 'gowl :confidence 1.0) r))))
     (t
      (when-let* ((mp (ignore-errors (mouse-pixel-position)))
                  ((framep (car mp)))
                  ((numberp (cadr mp)))
                  (r (cmacs-deixis--frame-referent (car mp) (cadr mp)
                                                   (cddr mp) 1.0)))
        (append (list :device 'emacs) r))))))

(defun cmacs-deixis-referent-now ()
  "What \"this\" means at this moment, with nothing spoken: a referent or nil.
The rule is `cmacs-deixis-referent-at's: an active region, unless the
pointer is on another window; else what the pointer is on; else, with
`cmacs-deixis-fallback-to-point', point in the selected window.  For
commands that act on the pointed thing from a key or a menu."
  (let ((pointer (ignore-errors (cmacs-deixis--pointer-now)))
        (region (cmacs-deixis--region-referent)))
    (cond ((and region (not (cmacs-deixis--elsewhere-p pointer region))) region)
          (pointer)
          (cmacs-deixis-fallback-to-point (cmacs-deixis--point-referent)))))

(defun cmacs-deixis--referent-key (r)
  "What makes referent R the same thing as another."
  (and r (list (plist-get r :kind) (plist-get r :client-id)
               (plist-get r :window) (plist-get r :buffer)
               (plist-get r :position) (plist-get r :beg) (plist-get r :end)
               (and (not (plist-get r :client-id)) (plist-get r :monitor))
               (plist-get r :path) (plist-get r :url) (plist-get r :tag))))

(defun cmacs-deixis-resolve (text words base-ms)
  "Bind the demonstratives of TEXT to what was pointed at.
WORDS is the recognizer's word list (`cmacs-deixis-result-words') and
BASE-MS the time, on the clock of `cmacs-deixis-now-ms', at which the
audio WORDS's times count from began.  With BASE-MS nil the words cannot
be placed in time; then the pointer is asked about now, which is right
only for a pointer still resting on the last thing said.

Returns a list of bindings in spoken order, each a plist:
  :word :token :index :role   as `cmacs-deixis-find'
  :time                       when the word was said (ms), or nil
  :approx                     non-nil when that time is an estimate
  :referent                   the referent plist, or nil
  :marker                     1, 2, ... -- bindings to the same thing
                              share one
A `pronoun' (\"it\") with nothing of its own takes the referent of the
`object' word before it; with none before it either, it is dropped."
  (let* ((tokens (cmacs-deixis--tokens text))
         (times (cmacs-deixis--token-times tokens words))
         (markers nil) (out nil) (last-object nil))
    (dolist (d (cmacs-deixis-find text))
      (let* ((role (plist-get d :role))
             (tm (aref times (plist-get d :index)))
             (start (and tm base-ms (+ base-ms (nth 0 tm) cmacs-deixis-latency-ms)))
             (end (and tm base-ms (+ base-ms (nth 1 tm) cmacs-deixis-latency-ms)))
             (ms (cond (start (/ (+ start end) 2))
                       ((null base-ms) (cmacs-deixis-now-ms))))
             (from (if start (- start cmacs-deixis-window-before-ms)
                     (and ms (- ms cmacs-deixis-window-before-ms
                                cmacs-deixis-window-after-ms))))
             (to (if end (+ end cmacs-deixis-window-after-ms) ms))
             (r (cmacs-deixis-referent-at ms from to role)))
        (when (and (eq role 'pronoun) (null r) last-object)
          (setq r last-object))
        (unless (and (eq role 'pronoun) (null r))
          (let* ((key (cmacs-deixis--referent-key r))
                 (marker (and r (or (cdr (assoc key markers))
                                    (let ((m (1+ (length markers))))
                                      (push (cons key m) markers)
                                      m)))))
            (when (and r (memq role '(object pronoun)))
              (setq last-object r))
            (push (append d (list :time (and start ms)
                                  :approx (and tm (nth 2 tm))
                                  :referent r :marker marker))
                  out)))))
    (nreverse out)))


;;;; The annotated utterance

(defun cmacs-deixis--marker-string (n)
  "Marker N as a circled digit, or (N) past twenty."
  (if (<= 1 n 20) (string (+ #x245F n)) (format "(%d)" n)))

(defun cmacs-deixis-annotate (text bindings)
  "TEXT with each bound demonstrative marked, followed by a legend.
\"move that over there\" becomes

  move that [that=①] over there [there=②]

  [Pointing: what each marked word referred to when it was spoken]
  ① window: librewolf — \\='wlroots docs\\=' (client 12)
  ② monitor 1 (DP-2) at 2900,400

A demonstrative with nothing pointed at is marked [that=?].  The legend
names things by id and never carries buffer text."
  (if (null bindings)
      text
    (let* ((tokens (cmacs-deixis--tokens text))
           (by-index (mapcar (lambda (b) (cons (plist-get b :index) b)) bindings))
           (legend nil) (seen nil) (unknown nil))
      (dolist (b bindings)
        (let ((m (plist-get b :marker)) (r (plist-get b :referent)))
          (cond ((null m) (setq unknown t))
                ((not (memq m seen))
                 (push m seen)
                 (push (format "%s %s%s" (cmacs-deixis--marker-string m)
                               (plist-get r :label)
                               (if (plist-get r :approximate)
                                   " [approximate]" ""))
                       legend)))))
      (concat
       (mapconcat
        (lambda (cell)
          (let ((b (cdr (assq (car cell) by-index))))
            (if b
                (format "%s [%s=%s]" (cdr cell) (plist-get b :word)
                        (if (plist-get b :marker)
                            (cmacs-deixis--marker-string (plist-get b :marker))
                          "?"))
              (cdr cell))))
        (cl-loop for tok in tokens for i from 0 collect (cons i tok))
        " ")
       "\n\n[Pointing: what each marked word referred to when it was spoken]\n"
       (string-join (nreverse legend) "\n")
       (if unknown
           (concat (if legend "\n" "") "? nothing was being pointed at")
         "")))))


;;;; Commands

(defvar cmacs-deixis-commands nil
  "The deictic commands: an alist of (NAME . PLIST), tried in order.
PLIST has :pattern, :function, :confirm and :doc.  See
`cmacs-deixis-define-command'.")

(defvar cmacs-deixis-command-words nil
  "While a command's body runs: the utterance in its canonical form.
For example \"kill <object>\"; a body uses it to tell its verbs apart.")

(defmacro cmacs-deixis-define-command (name pattern arglist &rest body)
  "Define deictic command NAME, run when an utterance matches PATTERN.
PATTERN is a regexp matched against the utterance's canonical form:
lower-cased words, `cmacs-deixis-filler-words' dropped, and each bound
demonstrative replaced by \"<object>\" or \"<place>\" (\"it\" is an
<object>).  \"Please move that window over there\" is
\"move <object> <place>\".  Anchor it with \\\\=` and \\\\='.

ARGLIST names the referents of the placeholders, in spoken order; BODY
runs with them bound when every placeholder has a referent (a command
is never run on something that was not pointed at).  BODY may begin
with a docstring and the keyword :confirm with a form: when the form's
value is non-nil the command is destructive and is confirmed first, the
value (a string) being the question.  BODY reports a refusal with
`user-error'.

  (cmacs-deixis-define-command my-raise
      \"\\\\=`raise <object>\\\\='\" (that)
    \"Make the pointed window urgent.\"
    (gowl-set-client-urgent (plist-get that :client) t))"
  (declare (indent 3) (doc-string 4))
  (let* ((doc (and (stringp (car body)) (cdr body) (pop body)))
         (confirm (and (eq (car body) :confirm) (progn (pop body) (pop body)))))
    `(progn
       (setf (alist-get ',name cmacs-deixis-commands)
             (list :pattern ,pattern
                   :function (lambda ,arglist ,@body)
                   :confirm ,(and confirm `(lambda ,arglist
                                             (ignore ,@arglist) ,confirm))
                   :doc ,doc))
       ',name)))

(defun cmacs-deixis-canonical (text bindings)
  "TEXT in the form command patterns match; see `cmacs-deixis-define-command'."
  (let ((roles (mapcar (lambda (b) (cons (plist-get b :index)
                                         (if (eq (plist-get b :role) 'place)
                                             "<place>" "<object>")))
                       bindings)))
    (string-join
     (cl-loop for tok in (cmacs-deixis--tokens text)
              for i from 0
              for norm = (cmacs-deixis--norm tok)
              for role = (cdr (assq i roles))
              if role collect role
              else unless (or (string-empty-p norm)
                              (member norm cmacs-deixis-filler-words))
              collect norm)
     " ")))

(defun cmacs-deixis--run-later (fn)
  "Call FN from the command loop when the voice engine can arrange it."
  (if (fboundp 'cmacs-voice-run-later)
      (cmacs-voice-run-later fn)
    (funcall fn)))

(defun cmacs-deixis--call (fn)
  "Call FN, turning a `user-error' into a message."
  (condition-case err
      (funcall fn)
    (user-error (message "Deixis: %s" (error-message-string err)))))

(defun cmacs-deixis--confirm (prompt action)
  "Run ACTION once PROMPT is answered yes."
  (cond
   ((not cmacs-deixis-confirm-destructive) (cmacs-deixis--run-later action))
   ((fboundp 'cmacs-voice-confirm)
    (cmacs-voice-confirm prompt action)
    ;; The answer needs no wake phrase.
    (when (and (bound-and-true-p cmacs-voice-loop-mode)
               (fboundp 'cmacs-voice-loop--arm))
      (cmacs-voice-loop--arm (if (boundp 'cmacs-voice-confirm-seconds)
                                 cmacs-voice-confirm-seconds
                               15))))
   (t (cmacs-deixis--run-later
       (lambda () (when (y-or-n-p (concat prompt " ")) (funcall action)))))))

(defun cmacs-deixis--by-hand (bindings)
  "The bindings of BINDINGS whose referent a bare hand pointed at."
  (cl-remove-if-not
   (lambda (b)
     (let ((r (plist-get b :referent)))
       (and (eq (plist-get r :device) 'hand) (plist-get r :approximate))))
   bindings))

(defun cmacs-deixis--hand-summary (bindings)
  "What each hand-pointed word of BINDINGS resolved to, as one line, or nil.
Labels only -- ids, titles, buffer names -- as in the legend."
  (when-let* ((by-hand (cmacs-deixis--by-hand bindings)))
    (mapconcat (lambda (b)
                 (format "%s = %s" (plist-get b :word)
                         (plist-get (plist-get b :referent) :label)))
               by-hand "; ")))

(defun cmacs-deixis-run-command (text bindings)
  "Run the deictic command TEXT with BINDINGS matches; non-nil if one did.
A command matches when its pattern matches the canonical form and every
demonstrative has a referent that still exists.  The command itself
runs from the command loop, after this returns."
  (let ((canon (cmacs-deixis-canonical text bindings))
        (referents (mapcar (lambda (b) (plist-get b :referent)) bindings))
        (case-fold-search nil))
    (when (and bindings
               (cl-every (lambda (r) (and r (not (plist-get r :stale)))) referents))
      (cl-loop
       for (name . def) in (reverse cmacs-deixis-commands)
       when (string-match-p (plist-get def :pattern) canon)
       return
       (let* ((fn (plist-get def :function))
              (action (lambda ()
                        (let ((cmacs-deixis-command-words canon))
                          (cmacs-deixis--call
                           (lambda () (apply fn referents))))))
              (question (and (plist-get def :confirm)
                             (let ((cmacs-deixis-command-words canon))
                               (ignore-errors
                                 (apply (plist-get def :confirm) referents))))))
         ;; A hand's aim is approximate: say what it was taken to mean
         ;; before anything acts on it.
         (when-let* ((cmacs-deixis-announce-hand)
                     (summary (cmacs-deixis--hand-summary bindings)))
           (message "Deixis (by hand): %s" summary))
         (if question
             (cmacs-deixis--confirm
              (concat (if (stringp question) question
                        (format "Really %s?" name))
                      (if (cmacs-deixis--by-hand bindings)
                          " (pointed at by hand)" ""))
              action)
           (cmacs-deixis--run-later action))
         name)))))


;;;; The built-in commands

(defun cmacs-deixis--monitor-object (n)
  "Monitor index N as an object, or signal."
  (or (and (integerp n) (nth n (gowl-list-monitors)))
      (user-error "No such monitor")))

(defun cmacs-deixis--move-desktop-window (that there)
  "Move desktop window THAT to where THERE points."
  (let ((client (plist-get that :client)))
    (cond
     ((plist-get that :embedded)
      (user-error "That window lives in an Emacs window; move its buffer instead"))
     ;; A tag, from a pointer that knows about tags (the bar).
     ((integerp (plist-get there :tag))
      (gowl-set-tags client (ash 1 (plist-get there :tag))))
     ;; Onto another window of the same screen: in a tiling layout the
     ;; only way to be "there" is to trade places.
     ((and (cmacs-deixis--desktop-window-p there)
           (not (eql (plist-get there :client-id) (plist-get that :client-id)))
           (eql (plist-get there :monitor) (plist-get that :monitor)))
      (gowl-swap-clients client (plist-get there :client)))
     ((integerp (plist-get there :monitor))
      (let ((mon (cmacs-deixis--monitor-object (plist-get there :monitor))))
        (unless (eql (plist-get there :monitor) (plist-get that :monitor))
          (gowl-move-client-to-monitor client mon))
        ;; A floating window can also take the half that was pointed at.
        (when-let* (((plist-get that :floating))
                    (g (alist-get 'geometry (gowl-monitor-info mon)))
                    (x (plist-get there :x)))
          (let* ((half (/ (nth 2 g) 2))
                 (left (< x (+ (nth 0 g) half))))
            (gowl-client-set-geometry client
                                      (if left (nth 0 g) (+ (nth 0 g) half))
                                      (nth 1 g) half (nth 3 g))))))
     (t (user-error "Nowhere to move that to")))))

(cmacs-deixis-define-command move
    "\\`\\(?:move\\|put\\|send\\|throw\\|bring\\|take\\) <object> <place>\\'"
    (that there)
  "\"Move that over there\": a window to the pointed screen, tag or half;
a buffer into the pointed Emacs window."
  (cond
   ((cmacs-deixis--desktop-window-p that)
    (cmacs-deixis--move-desktop-window that there))
   ((cmacs-deixis--emacs-referent-p that)
    (let ((win (plist-get there :window))
          (from (plist-get that :window)))
      (unless (window-live-p win)
        (user-error "There is no Emacs window there"))
      (set-window-buffer win (plist-get that :buffer))
      ;; Moved, not copied: the window it came from shows what it
      ;; showed before.
      (when (and (window-live-p from) (not (eq from win)))
        (switch-to-prev-buffer from))))
   (t (user-error "That cannot be moved"))))

(cmacs-deixis-define-command close
    "\\`\\(?:close\\|kill\\|quit\\|delete\\) <object>\\'" (that)
  "\"Close that\": the pointed desktop window or Emacs window; \"kill
that\" kills the buffer.  Confirmed first."
  :confirm (format "Close %s?" (plist-get that :label))
  (cond
   ((cmacs-deixis--desktop-window-p that)
    (gowl-close-client (plist-get that :client)))
   ((cmacs-deixis--emacs-referent-p that)
    (let ((win (plist-get that :window)))
      (cond ((string-prefix-p "kill" cmacs-deixis-command-words)
             (kill-buffer (plist-get that :buffer)))
            ((and (window-live-p win) (not (one-window-p t (window-frame win))))
             (delete-window win))
            (t (bury-buffer (plist-get that :buffer))))))
   (t (user-error "That cannot be closed"))))

(cmacs-deixis-define-command focus
    "\\`\\(?:focus\\|go\\|switch\\|select\\|jump\\) \\(?:<place>\\|<object>\\)\\'"
    (there)
  "\"Focus there\" / \"go there\": the pointed desktop or Emacs window."
  (cond
   ((cmacs-deixis--desktop-window-p there)
    (gowl-focus-client (plist-get there :client)))
   ((window-live-p (plist-get there :window))
    (select-frame-set-input-focus (window-frame (plist-get there :window)))
    (select-window (plist-get there :window))
    (when (integerp (plist-get there :position))
      (goto-char (plist-get there :position))))
   (t (user-error "Nothing to focus there"))))

(cmacs-deixis-define-command swap
    "\\`\\(?:swap\\|exchange\\|switch\\) <object> \\(?:and\\|with\\) <object>\\'"
    (this that)
  "\"Swap this and that\": two desktop windows, or two Emacs windows."
  (cond
   ((and (cmacs-deixis--desktop-window-p this)
         (cmacs-deixis--desktop-window-p that))
    (when (eql (plist-get this :client-id) (plist-get that :client-id))
      (user-error "Those are the same window"))
    (gowl-swap-clients (plist-get this :client) (plist-get that :client)))
   ((and (window-live-p (plist-get this :window))
         (window-live-p (plist-get that :window)))
    (when (eq (plist-get this :window) (plist-get that :window))
      (user-error "Those are the same window"))
    (window-swap-states (plist-get this :window) (plist-get that :window)))
   (t (user-error "Those two cannot be swapped"))))

(defun cmacs-deixis--target-of (r)
  "The file or URL referent R names, as (file . PATH) or (url . URL).
For a buffer position this reads the one file name or URL at that
position -- locally, to act on; it is never sent anywhere."
  (pcase (plist-get r :kind)
    ('file (cons 'file (plist-get r :path)))
    ('url (cons 'url (plist-get r :url)))
    ((or 'buffer-position 'point)
     (with-current-buffer (plist-get r :buffer)
       (save-excursion
         (goto-char (plist-get r :position))
         (if-let* ((url (thing-at-point 'url t)))
             (cons 'url url)
           (when-let* ((file (thing-at-point 'filename t))
                       ((file-exists-p (expand-file-name file))))
             (cons 'file (expand-file-name file)))))))
    ('region
     (with-current-buffer (plist-get r :buffer)
       (let ((s (string-trim (buffer-substring-no-properties
                              (plist-get r :beg) (plist-get r :end)))))
         (cond ((string-match-p "\\`[a-z][a-z0-9+.-]*://" s) (cons 'url s))
               ((file-exists-p (expand-file-name s))
                (cons 'file (expand-file-name s)))))))))

(cmacs-deixis-define-command open
    "\\`\\(?:open\\|show\\|visit\\) <object> <place>\\'" (that here)
  "\"Open that here\": the file or URL at the pointed buffer position,
in the pointed Emacs window."
  (let ((target (or (cmacs-deixis--target-of that)
                    (user-error "There is no file or link there")))
        (win (plist-get here :window)))
    (when (window-live-p win)
      (select-window win))
    (pcase target
      (`(file . ,path) (find-file path))
      (`(url . ,url) (browse-url url)))))


;;;; The voice loop

(defvar cmacs-deixis--segments nil
  "Alist of (SEGMENT-ID . START-MS): when each recent segment's audio began.")

(defvar cmacs-deixis--sampling nil
  "Non-nil while the pointers are being sampled.")

(defvar cmacs-deixis--saved-filter nil
  "The utterance filter that was installed before ours.")

(defvar cmacs-deixis--calibration nil
  "(PRESS-MS . WORD) while `cmacs-deixis-calibrate' waits for its word.")

(defun cmacs-deixis--segment-started (seg lead-ms)
  "Note when segment SEG's audio began: LEAD-MS before now."
  (push (cons seg (- (cmacs-deixis-now-ms) lead-ms)) cmacs-deixis--segments)
  ;; A final transcript can trail its segment by a few segments, no more.
  (when (> (length cmacs-deixis--segments) 8)
    (setcdr (nthcdr 7 cmacs-deixis--segments) nil)))

(defun cmacs-deixis--set-sampling (on)
  "Start (ON non-nil) or stop every pointer's sampling."
  (unless (eq (and on t) cmacs-deixis--sampling)
    (setq cmacs-deixis--sampling (and on t))
    (dolist (p cmacs-deixis--pointers)
      (when-let* ((fn (plist-get (cdr p) (if on :start :stop))))
        (condition-case err
            (funcall fn)
          (error (message "Deixis: pointer %s: %s" (car p)
                          (error-message-string err))))))
    (unless on
      (setq cmacs-deixis--segments nil
            cmacs-deixis-last-bindings nil))))

(defun cmacs-deixis--update-sampling (&rest _)
  "Sample exactly while the mode is on and the voice loop is listening."
  (cmacs-deixis--set-sampling
   (and (bound-and-true-p cmacs-deixis-mode)
        (bound-and-true-p cmacs-voice-loop-mode)
        (fboundp 'cmacs-voice-loop-state)
        (not (memq (cmacs-voice-loop-state) '(idle paused))))))

(defun cmacs-deixis--calibration-check (words base-ms)
  "Report the measured offset when the calibration word is in WORDS."
  (when-let* ((cal cmacs-deixis--calibration)
              ((numberp base-ms))
              (w (cl-find (cdr cal) words :from-end t
                          :key (lambda (w) (cmacs-deixis--norm (car w)))
                          :test #'equal)))
    (setq cmacs-deixis--calibration nil)
    (let ((offset (- (car cal) (+ base-ms (/ (+ (nth 1 w) (nth 2 w)) 2)))))
      (message "Deixis: the key came %+d ms from the word%s.  \
For that to be 0, set `cmacs-deixis-latency-ms' to %d."
               offset
               (if (memq :approx w) " (word time estimated, repeat with a \
token-timestamp model for a real figure)" "")
               offset))))

(defun cmacs-deixis-filter (text seg result)
  "The voice loop's utterance filter: resolve TEXT, act on it or annotate it.
SEG is the segment id and RESULT the recognizer's result.  Returns nil
when a deictic command took the utterance, else the text to send on:
annotated when it has demonstratives, TEXT itself when it has none."
  (let* ((base (cdr (assq seg cmacs-deixis--segments)))
         (words (cmacs-deixis-result-words (or result (list (cons :text text)))))
         (bindings (cmacs-deixis-resolve text words base)))
    (cmacs-deixis--calibration-check words base)
    (setq cmacs-deixis-last-bindings bindings)
    (run-hook-with-args 'cmacs-deixis-resolved-functions text bindings)
    (cond
     ((null bindings) text)
     ((cmacs-deixis-run-command text bindings) nil)
     ((run-hook-with-args-until-success 'cmacs-deixis-unclaimed-functions
                                        text bindings)
      nil)
     ((and (eq (bound-and-true-p cmacs-voice-loop--last-target) 'commands)
           (not cmacs-deixis-annotate-for-commands))
      text)
     (t (cmacs-deixis-annotate text bindings)))))

;;;###autoload
(define-minor-mode cmacs-deixis-mode
  "Bind spoken \"this\", \"that\", \"here\", \"there\" to what you point at.
With the voice loop (`cmacs-voice-loop-mode') listening, each
demonstrative in what you say is bound to what the pointer -- mouse, VR
laser or tracked hand -- rested on while the word was spoken.  Simple
commands run at once with no model: \"move that there\", \"close
that\", \"focus there\", \"swap this and that\", \"open that here\"
\(see `cmacs-deixis-define-command').  Anything else goes on to the
loop's route with the demonstratives marked and a legend naming what
they are.

Pointer positions are kept only while this mode is on and the loop is
listening, in memory, and are dropped when either stops."
  :global t
  :group 'cmacs-deixis
  :lighter " Deixis"
  (if cmacs-deixis-mode
      (progn
        (add-hook 'cmacs-voice-loop-segment-start-functions
                  #'cmacs-deixis--segment-started)
        (add-hook 'cmacs-voice-loop-state-change-functions
                  #'cmacs-deixis--update-sampling)
        (unless (eq (bound-and-true-p cmacs-voice-loop-utterance-filter-function)
                    #'cmacs-deixis-filter)
          (setq cmacs-deixis--saved-filter
                (bound-and-true-p cmacs-voice-loop-utterance-filter-function)))
        (setq cmacs-voice-loop-utterance-filter-function #'cmacs-deixis-filter))
    (remove-hook 'cmacs-voice-loop-segment-start-functions
                 #'cmacs-deixis--segment-started)
    (remove-hook 'cmacs-voice-loop-state-change-functions
                 #'cmacs-deixis--update-sampling)
    (when (eq (bound-and-true-p cmacs-voice-loop-utterance-filter-function)
              #'cmacs-deixis-filter)
      (setq cmacs-voice-loop-utterance-filter-function cmacs-deixis--saved-filter))
    (setq cmacs-deixis--saved-filter nil
          cmacs-deixis--calibration nil))
  (cmacs-deixis--update-sampling))

;;;###autoload
(defun cmacs-deixis-calibrate (&optional word)
  "Measure how far a spoken word's time is from a key press.
Say WORD (default \"now\") to the voice loop and press a key at the
same instant.  When the transcript arrives, the difference between the
key's time and the word's is shown, with the value of
`cmacs-deixis-latency-ms' that would make it zero.  Your own reaction
time is in that figure, so repeat it a few times and take the middle."
  (interactive)
  (unless (bound-and-true-p cmacs-deixis-mode)
    (user-error "Turn on `cmacs-deixis-mode' and the voice loop first"))
  (let ((word (cmacs-deixis--norm (or word "now"))))
    (read-event (format "Say \"%s\" and press a key at the same instant: " word))
    (setq cmacs-deixis--calibration (cons (cmacs-deixis-now-ms) word))
    (message "Deixis: waiting for the transcript...")))

(provide 'cmacs-deixis)

;;; cmacs-deixis.el ends here
