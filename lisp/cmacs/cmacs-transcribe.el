;;; cmacs-transcribe.el --- Batch speech-to-text (whisper.cpp + AI summaries) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Batch speech-to-text for cmacs, built as a sibling of `cmacs-transcode'
;; and reusing its machinery.  Each queued audio/video file runs through a
;; three-stage pipeline:
;;
;;   converting   -- ffmpeg (via cmacs-transcode's backend: podman/docker
;;                   `linuxserver/ffmpeg' container, else a host ffmpeg)
;;                   transcodes the input to a transient 16 kHz mono S16LE
;;                   WAV.  This is mandatory: the embedded whisper reader
;;                   (`cmacs-whisper-transcribe-async') only accepts that
;;                   exact PCM WAV -- it cannot decode mp3/ogg/mp4 itself.
;;   transcribing -- whisper.cpp turns the WAV into text + timestamped
;;                   segments; the temp WAV is then deleted.  The transcript
;;                   is shown in the queue buffer and saved to a text file.
;;   summarizing  -- (optional, when `cmacs-ai' is built and enabled) an
;;                   async AI call summarises the transcript into an Org
;;                   document whose final section is the full transcript.
;;
;; Emacs itself supervises the pipeline as a bounded parallel pool (no GNU
;; parallel), exactly like `cmacs-transcode', and streams live per-job
;; status into a `*cmacs-transcribe*' queue buffer that redraws on a timer.
;; Every knob is a `defcustom'; the buffer seeds each session from those and
;; overrides them per session without mutating the customs.
;;
;; Extra outputs (SubRip `.srt', WebVTT `.vtt', timestamped `.txt') are
;; produced from whisper's segment timestamps when enabled.  Two abnormal
;; hooks (`cmacs-transcribe-after-transcription-functions' and
;; `cmacs-transcribe-after-summary-functions') fire a rich INFO plist so a
;; user config can push transcriptions anywhere (e.g. a database).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-transcode)              ;reuse backend / io / command helpers
(require 'cmacs-whisper nil t)          ;model-path helpers + STT DEFUNs (soft)

;; Reused from cmacs-transcode (backend resolution + container/host command).
(declare-function cmacs-transcode--resolve "cmacs-transcode" (&optional noerror))
(declare-function cmacs-transcode--io "cmacs-transcode" (kind in-file &optional out-file))
(declare-function cmacs-transcode--command "cmacs-transcode" (kind tool io hw ffmpeg-args &optional name))
(declare-function cmacs-transcode--ffprobe "cmacs-transcode" (kind in-file &rest probe-args))
;; whisper STT (present only in a --with-cmacs-whisper build).
(declare-function cmacs-whisper-transcribe-async "cmacs-whisper-defuns.c"
                  (model-path wav-path callback &optional language threads))
(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-whisper-download-model "cmacs-whisper" (model))
(defvar cmacs-whisper-default-model)
(defvar cmacs-whisper-language)
;; cmacs-ai async streaming (present only in a --with-cmacs-ai build).
(declare-function cmacs-ai-make-session "cmacs-ai" (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c" (session prompt callback))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-supported-p "cmacs-ai-stream.c" ())
(declare-function dired-get-marked-files "dired" (&optional localp arg filter distinguish-one-marked error))

(defgroup cmacs-transcribe nil
  "Batch speech-to-text: whisper.cpp STT with optional AI summaries."
  :group 'cmacs
  :prefix "cmacs-transcribe-")

;;; ---------------------------------------------------------------------
;;; Customization -- general
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcribe-parallel-jobs 1
  "Number of files to run through the pipeline at once.
1 means sequential (the default).  The queue buffer's `p'/`P' keys toggle
and set this per session.  Note this is distinct from
`cmacs-transcribe-threads' (cores per single transcription): whisper.cpp
already uses several threads per inference and serialises jobs that share
a model, so raising this mainly parallelises the ffmpeg conversion stage
and pipelines conversion against transcription."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-transcribe-threads 4
  "CPU cores whisper.cpp uses for each transcription.
4 is whisper.cpp's own default and a sane balance.  nil or a non-positive
value means \"use all cores\".  The queue buffer's `w' key sets this per
session."
  :type '(choice (const :tag "All cores" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

(defcustom cmacs-transcribe-poll-interval 2
  "Seconds between live redraws of the queue buffer while jobs run.
nil or 0 disables the timer (the buffer still redraws on every state
change)."
  :type '(choice (const :tag "Disabled" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

(defcustom cmacs-transcribe-max-retries 2
  "Maximum attempts for the ffmpeg conversion stage before a job fails.
Transcription and summarisation are not retried."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-transcribe-process-filter nil
  "Optional pre-run filter over the queue, keyed on the transcript file.
`missing' only processes files whose \".txt\" transcript does not yet
exist; `existing' only reprocesses files whose transcript already exists;
nil processes everything."
  :type '(choice (const :tag "Process all" nil)
                 (const :tag "Only missing transcripts" missing)
                 (const :tag "Only existing transcripts" existing))
  :safe #'symbolp)

(defcustom cmacs-transcribe-model nil
  "Whisper model basename, or nil for `cmacs-whisper-default-model'.
Resolved to an absolute path via `cmacs-whisper-model-path'."
  :type '(choice (const :tag "Whisper default" nil) string))

(defcustom cmacs-transcribe-language nil
  "2-letter ISO language code, or nil for `cmacs-whisper-language'."
  :type '(choice (const :tag "Whisper default" nil) string))

(defcustom cmacs-transcribe-ffmpeg-extra-args nil
  "Extra ffmpeg arguments inserted into the audio-extraction command.
Placed just before the output WAV path, e.g. \\='(\"-af\" \"loudnorm\")."
  :type '(repeat string))

(defcustom cmacs-transcribe-sha256-program "sha256sum"
  "External program used to compute a streaming SHA-256 of each input.
Its first whitespace-delimited output token must be the hex digest (true
of coreutils `sha256sum' and BSD `shasum -a 256').  When the program is
not found, `:file-hash' falls back to an in-Emacs digest for small files
only, else nil.  See `cmacs-transcribe-compute-file-hash'."
  :type 'string)

(defcustom cmacs-transcribe-compute-file-hash t
  "If non-nil, compute a SHA-256 of each input for the hook INFO plist.
This aids database dedup (the `:file-hash' key) but reads/streams the whole
file once per job.  Set to nil to skip it and let hooks compute their own."
  :type 'boolean
  :safe #'booleanp)

;;; ---------------------------------------------------------------------
;;; Customization -- output paths + naming
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcribe-output-dir nil
  "Directory for the transcript (and extra) outputs.
nil writes each output as a sidecar next to its input file."
  :type '(choice (const :tag "Sidecar next to input" nil) directory))

(defcustom cmacs-transcribe-summary-dir nil
  "Directory for the summary Org document.
nil follows `cmacs-transcribe-output-dir' (sidecar when that is also nil).
Point this at a notes/PARA repository to file summaries there."
  :type '(choice (const :tag "Follow output-dir" nil) directory))

(defcustom cmacs-transcribe-naming 'append
  "How transcript/summary filenames are derived from the input.
`append' appends the new extension to the whole input name, so
\"talk.mp4\" yields \"talk.mp4.txt\" (matches the author's convention).
`base' replaces the extension, so \"talk.mp4\" yields \"talk.txt\"."
  :type '(choice (const :tag "Append (talk.mp4.txt)" append)
                 (const :tag "Base (talk.txt)" base))
  :safe #'symbolp)

(defcustom cmacs-transcribe-subtitle-naming 'base
  "Naming for the .srt/.vtt subtitle sidecars (`append' or `base').
Defaults to `base' (\"talk.srt\") so video players auto-load them."
  :type '(choice (const :tag "Base (talk.srt)" base)
                 (const :tag "Append (talk.mp4.srt)" append))
  :safe #'symbolp)

(defcustom cmacs-transcribe-emit-srt nil
  "If non-nil, also write a SubRip \".srt\" subtitle file per transcript."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcribe-emit-vtt nil
  "If non-nil, also write a WebVTT \".vtt\" subtitle file per transcript."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcribe-emit-timestamped-txt nil
  "If non-nil, also write a \"[HH:MM:SS] text\" timestamped transcript.
Named with a \".ts.txt\" suffix alongside the plain transcript."
  :type 'boolean :safe #'booleanp)

;;; ---------------------------------------------------------------------
;;; Customization -- summarisation (cmacs-ai)
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcribe-summarize nil
  "If non-nil, summarise each transcript with `cmacs-ai' into an Org file.
Requires a --with-cmacs-ai build with a configured provider.  Off by
default; toggled per session with the queue buffer's `s' key."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcribe-summary-type 'general
  "Default summary template key (a key in `cmacs-transcribe-summary-templates')."
  :type 'symbol :safe #'symbolp)

(defcustom cmacs-transcribe-summary-templates
  '((general . "You summarise transcripts.  Reply in concise Org-mode markup:
a one-line *TL;DR*, then \"** Key points\" as a short bullet list, then
\"** Notable quotes\" only if any stand out.  No preamble, no code fences.")
    (meeting . "You summarise meeting transcripts.  Reply in Org markup with:
a one-line *TL;DR*, \"** Decisions\", \"** Action items\" (each as
\"- [ ] OWNER: task\" when an owner is identifiable), and \"** Open
questions\".  No preamble, no code fences.")
    (lecture . "You summarise lecture/talk transcripts.  Reply in Org markup:
a one-line *TL;DR*, \"** Key concepts\" (term -- explanation bullets),
\"** Outline\" following the talk's structure, and \"** Takeaways\".
No preamble, no code fences.")
    (interview . "You summarise interview transcripts.  Reply in Org markup:
a one-line *TL;DR*, \"** Participants\" if identifiable, \"** Main themes\",
and \"** Notable exchanges\".  No preamble, no code fences.")
    (research . "You summarise research/technical transcripts.  Reply in Org
markup: a one-line *TL;DR*, \"** Problem\", \"** Approach\", \"** Findings\",
and \"** Follow-ups\".  No preamble, no code fences.")
    (podcast . "You summarise podcast/episode transcripts.  Reply in Org
markup: a one-line *TL;DR*, \"** Segments\" (rough topic list), \"** Key
points\", and \"** Recommendations/links mentioned\".  No preamble."))
  "Alist of summary TYPE -> system prompt used for AI summarisation.
The prompt should instruct Org-mode output; the transcript is sent as the
user message.  Extend this to add your own content types."
  :type '(alist :key-type symbol :value-type string))

(defcustom cmacs-transcribe-summary-provider nil
  "Provider symbol for summaries, or nil for the cmacs-ai default."
  :type '(choice (const :tag "cmacs-ai default" nil) symbol))

(defcustom cmacs-transcribe-summary-model nil
  "Model name for summaries, or nil for the provider's default."
  :type '(choice (const :tag "Provider default" nil) string))

;;; ---------------------------------------------------------------------
;;; Customization -- metadata (flows into the hook INFO plist)
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcribe-source "cmacs-transcribe"
  "Value passed as `:source' in the hook INFO plist (cf. a DB source column)."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcribe-type nil
  "Optional category string passed as `:type' in the hook INFO plist."
  :type '(choice (const :tag "None" nil) string))

(defcustom cmacs-transcribe-tags nil
  "Optional list of tag strings passed as `:tags' in the hook INFO plist."
  :type '(repeat string))

(defcustom cmacs-transcribe-media-extensions
  '("mp4" "mkv" "webm" "mov" "avi" "m4v" "mpg" "mpeg" "wmv" "flv" "ts" "m2ts"
    "mp3" "ogg" "oga" "wav" "flac" "m4a" "aac" "opus" "wma" "ape" "wv" "3gp")
  "Input file extensions recognised as transcribable media (audio or video)."
  :type '(repeat string))

(defcustom cmacs-transcribe-video-extensions
  '("mp4" "mkv" "webm" "mov" "avi" "m4v" "mpg" "mpeg" "wmv" "flv" "ts" "m2ts" "3gp")
  "Subset of `cmacs-transcribe-media-extensions' treated as video.
Used only to label a job's `:kind' in the INFO plist and the queue view."
  :type '(repeat string))

;;; ---------------------------------------------------------------------
;;; Hooks
;;; ---------------------------------------------------------------------

(defvar cmacs-transcribe-after-transcription-functions nil
  "Abnormal hook run after a transcript file is written, before summary.
Each function is called with a single INFO plist with keys:
  :input-file       absolute path of the source media
  :kind             `audio' or `video'
  :text-file        path of the written \".txt\" transcript
  :srt-file         path of the \".srt\" file, or nil
  :vtt-file         path of the timestamped/subtitle files, or nil
  :ts-file          path of the timestamped \".ts.txt\", or nil
  :text             the full transcript string
  :segments         list of ((:start . MS) (:end . MS) (:text . STR)) alists
  :duration-seconds integer duration derived from the segments
  :file-hash        SHA-256 hex of the input, or nil
  :model            whisper model basename used
  :language         language code used
  :threads          whisper thread count used
  :type             the session category, or nil
  :tags             the session tag list
  :source           `cmacs-transcribe-source'
  :transcribed-at   an ISO-8601 timestamp string
Buffer-local additions fire only for that queue buffer's jobs.")

(defvar cmacs-transcribe-after-summary-functions nil
  "Abnormal hook run after a summary Org document is written.
Called with the same INFO plist as
`cmacs-transcribe-after-transcription-functions', additionally populated
with `:summary' (the summary text), `:summary-type', and `:org-file'.")

;;; ---------------------------------------------------------------------
;;; Session state (buffer-local) + job struct
;;; ---------------------------------------------------------------------

(cl-defstruct (cmacs-transcribe-job
               (:constructor cmacs-transcribe-job-create)
               (:copier nil))
  input                 ; absolute input path
  kind                  ; `audio' or `video'
  wav                   ; transient 16 kHz mono WAV path, or nil
  txt                   ; transcript output path
  org                   ; summary Org output path
  srt                   ; .srt output path (when enabled), or nil
  vtt                   ; .vtt output path (when enabled), or nil
  ts                    ; timestamped .ts.txt path (when enabled), or nil
  (stage 'queued)       ; queued converting transcribing summarizing done failed skipped
  (progress "")         ; latest status detail
  process               ; the running ffmpeg process (convert stage), or nil
  container             ; container name (for podman/docker force-kill), or nil
  stream                ; AI (client . session) pair while summarizing, or nil
  text                  ; transcript text (set after transcribing)
  segments              ; timestamped segments (set after transcribing)
  summary               ; summary text (accumulated during summarizing)
  duration              ; integer seconds, from segments
  (tries 0)             ; conversion attempts so far
  cancelled             ; non-nil when the user killed it (no retry)
  note)                 ; extra note for the status line

(defvar cmacs-transcribe--name-counter 0
  "Monotonic counter for unique per-run container names.")

(defun cmacs-transcribe--gen-container-name ()
  "Return a fresh, unique container name for a conversion job."
  (format "cmacs-transcribe-%d-%d"
          (emacs-pid) (cl-incf cmacs-transcribe--name-counter)))

(defvar-local cmacs-transcribe--options nil
  "Session options plist, seeded from the defcustoms.")
(defvar-local cmacs-transcribe--jobs nil
  "List of `cmacs-transcribe-job' structs in this session.")
(defvar-local cmacs-transcribe--queue nil
  "Jobs still waiting to be launched during the current run.")
(defvar-local cmacs-transcribe--backend nil
  "Backend resolved for the current run: `podman', `docker', or `host'.")
(defvar-local cmacs-transcribe--timer nil
  "The live-redraw poll timer for this session, or nil.")

;;; ---------------------------------------------------------------------
;;; Availability + option resolution
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--whisper-available-p ()
  "Non-nil if the whisper STT DEFUNs are present in this build."
  (fboundp 'cmacs-whisper-transcribe-async))

(defun cmacs-transcribe--ai-available-p ()
  "Non-nil if cmacs-ai is built and reports itself supported.
Loads the cmacs-ai Lisp layer on demand so `cmacs-ai-make-session' is bound
even when no AI command has run yet this session."
  (and (or (featurep 'cmacs-ai) (require 'cmacs-ai nil t))
       (fboundp 'cmacs-ai-supported-p)
       (fboundp 'cmacs-ai-make-session)
       (ignore-errors (cmacs-ai-supported-p))))

;;;###autoload
(defun cmacs-transcribe-supported-p ()
  "Return non-nil if transcription can run (whisper built + ffmpeg backend)."
  (and (cmacs-transcribe--whisper-available-p)
       (cmacs-transcode--resolve t)
       t))

(defun cmacs-transcribe--model ()
  "Resolve the whisper model basename to an absolute path."
  (cmacs-whisper-model-path
   (or cmacs-transcribe-model
       (and (boundp 'cmacs-whisper-default-model) cmacs-whisper-default-model))))

(defun cmacs-transcribe--language ()
  "Resolve the transcription language code."
  (or cmacs-transcribe-language
      (and (boundp 'cmacs-whisper-language) cmacs-whisper-language)
      "en"))

(defun cmacs-transcribe--threads ()
  "Resolve the whisper thread count (nil = all cores)."
  (plist-get cmacs-transcribe--options :threads))

;;; ---------------------------------------------------------------------
;;; Options seeding + kind detection + output paths
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--default-options ()
  "Return a fresh options plist, seeded from the defcustoms."
  (list :parallel cmacs-transcribe-parallel-jobs
        :threads cmacs-transcribe-threads
        :process-filter cmacs-transcribe-process-filter
        :model cmacs-transcribe-model
        :language cmacs-transcribe-language
        :output-dir cmacs-transcribe-output-dir
        :summary-dir cmacs-transcribe-summary-dir
        :naming cmacs-transcribe-naming
        :subtitle-naming cmacs-transcribe-subtitle-naming
        :summarize cmacs-transcribe-summarize
        :summary-type cmacs-transcribe-summary-type
        :emit-srt cmacs-transcribe-emit-srt
        :emit-vtt cmacs-transcribe-emit-vtt
        :emit-timestamped cmacs-transcribe-emit-timestamped-txt
        :type cmacs-transcribe-type
        :tags cmacs-transcribe-tags))

(defun cmacs-transcribe--kind-of (file)
  "Return `video' or `audio' for FILE based on its extension."
  (if (member (downcase (or (file-name-extension file) ""))
              cmacs-transcribe-video-extensions)
      'video 'audio))

(defun cmacs-transcribe--dest (in-file suffix naming &optional dir)
  "Return an output path for IN-FILE with SUFFIX using NAMING.
NAMING is `append' (append SUFFIX to the whole input name) or `base'
\(replace the extension).  DIR overrides the directory; nil places the
file next to IN-FILE (a sidecar)."
  (let* ((base-dir (or dir (file-name-directory (expand-file-name in-file))))
         (name (pcase naming
                 ('base (concat (file-name-base in-file) suffix))
                 (_ (concat (file-name-nondirectory in-file) suffix)))))
    (expand-file-name name (file-name-as-directory base-dir))))

(defun cmacs-transcribe--txt-for (in-file)
  "Return the transcript path for IN-FILE."
  (cmacs-transcribe--dest in-file ".txt"
                          (plist-get cmacs-transcribe--options :naming)
                          (plist-get cmacs-transcribe--options :output-dir)))

(defun cmacs-transcribe--org-for (in-file)
  "Return the summary Org path for IN-FILE."
  (cmacs-transcribe--dest in-file ".org"
                          (plist-get cmacs-transcribe--options :naming)
                          (or (plist-get cmacs-transcribe--options :summary-dir)
                              (plist-get cmacs-transcribe--options :output-dir))))

(defun cmacs-transcribe--sub-for (in-file suffix)
  "Return a subtitle path for IN-FILE with SUFFIX (e.g. \".srt\")."
  (cmacs-transcribe--dest in-file suffix
                          (plist-get cmacs-transcribe--options :subtitle-naming)
                          (plist-get cmacs-transcribe--options :output-dir)))

;;; ---------------------------------------------------------------------
;;; Input expansion + enqueue
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--media-file-p (file)
  "Non-nil if FILE is a regular file with a transcribable extension."
  (and (file-regular-p file)
       (member (downcase (or (file-name-extension file) ""))
               cmacs-transcribe-media-extensions)))

(defun cmacs-transcribe--expand-input (path &optional recursive)
  "Return a list of media files for PATH.
A file yields itself; a directory yields its media files (recursively
with RECURSIVE)."
  (cond
   ((file-directory-p path)
    (let* ((base (file-name-as-directory (expand-file-name path))))
      (if recursive
          (directory-files-recursively
           base (concat "\\.\\(?:"
                        (mapconcat #'regexp-quote cmacs-transcribe-media-extensions "\\|")
                        "\\)\\'")
           nil)
        (cl-remove-if-not #'cmacs-transcribe--media-file-p
                          (directory-files base t)))))
   ((cmacs-transcribe--media-file-p (expand-file-name path))
    (list (expand-file-name path)))
   (t (user-error "Not a media file or directory: %s" path))))

(defun cmacs-transcribe--filter-status (txt)
  "Return the initial job stage for transcript TXT under the process filter."
  (pcase (plist-get cmacs-transcribe--options :process-filter)
    ('missing (if (file-exists-p txt) 'skipped 'queued))
    ('existing (if (file-exists-p txt) 'queued 'skipped))
    (_ 'queued)))

(defun cmacs-transcribe--enqueue-file (in-file)
  "Add IN-FILE as a job unless it is already queued."
  (setq in-file (expand-file-name in-file))
  (unless (cl-find in-file cmacs-transcribe--jobs
                   :key #'cmacs-transcribe-job-input :test #'string=)
    (let ((txt (cmacs-transcribe--txt-for in-file)))
      (setq cmacs-transcribe--jobs
            (append cmacs-transcribe--jobs
                    (list (cmacs-transcribe-job-create
                           :input in-file
                           :kind (cmacs-transcribe--kind-of in-file)
                           :txt txt
                           :stage (cmacs-transcribe--filter-status txt))))))))

(defun cmacs-transcribe--recompute-outputs ()
  "Recompute output paths + filter stage for all not-yet-started jobs."
  (dolist (j cmacs-transcribe--jobs)
    (when (memq (cmacs-transcribe-job-stage j) '(queued skipped))
      (let ((txt (cmacs-transcribe--txt-for (cmacs-transcribe-job-input j))))
        (setf (cmacs-transcribe-job-txt j) txt
              (cmacs-transcribe-job-stage j) (cmacs-transcribe--filter-status txt))))))

;;; ---------------------------------------------------------------------
;;; Segment formatters (pure) + transcript writers
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--seg (s key)
  "Return KEY (`:start' `:end' `:text') from segment alist S."
  (cdr (assq key s)))

(defun cmacs-transcribe--ms->ts (ms sep)
  "Format MS milliseconds as HH:MM:SS<SEP>mmm."
  (let* ((ms (max 0 (truncate (or ms 0))))
         (h (/ ms 3600000))
         (m (/ (% ms 3600000) 60000))
         (s (/ (% ms 60000) 1000))
         (frac (% ms 1000)))
    (format "%02d:%02d:%02d%s%03d" h m s sep frac)))

(defun cmacs-transcribe--ms->clock (ms)
  "Format MS milliseconds as HH:MM:SS."
  (let* ((ms (max 0 (truncate (or ms 0))))
         (h (/ ms 3600000))
         (m (/ (% ms 3600000) 60000))
         (s (/ (% ms 60000) 1000)))
    (format "%02d:%02d:%02d" h m s)))

(defun cmacs-transcribe--segments->srt (segments)
  "Return SubRip text for SEGMENTS."
  (with-temp-buffer
    (let ((i 0))
      (dolist (s segments)
        (insert (format "%d\n%s --> %s\n%s\n\n"
                        (cl-incf i)
                        (cmacs-transcribe--ms->ts (cmacs-transcribe--seg s :start) ",")
                        (cmacs-transcribe--ms->ts (cmacs-transcribe--seg s :end) ",")
                        (string-trim (or (cmacs-transcribe--seg s :text) ""))))))
    (buffer-string)))

(defun cmacs-transcribe--segments->vtt (segments)
  "Return WebVTT text for SEGMENTS."
  (with-temp-buffer
    (insert "WEBVTT\n\n")
    (dolist (s segments)
      (insert (format "%s --> %s\n%s\n\n"
                      (cmacs-transcribe--ms->ts (cmacs-transcribe--seg s :start) ".")
                      (cmacs-transcribe--ms->ts (cmacs-transcribe--seg s :end) ".")
                      (string-trim (or (cmacs-transcribe--seg s :text) "")))))
    (buffer-string)))

(defun cmacs-transcribe--segments->timestamped (segments)
  "Return \"[HH:MM:SS] text\" lines for SEGMENTS."
  (with-temp-buffer
    (dolist (s segments)
      (insert (format "[%s] %s\n"
                      (cmacs-transcribe--ms->clock (cmacs-transcribe--seg s :start))
                      (string-trim (or (cmacs-transcribe--seg s :text) "")))))
    (buffer-string)))

(defun cmacs-transcribe--duration (segments)
  "Return an integer-second duration from SEGMENTS (0 when empty)."
  (let ((maxend 0))
    (dolist (s segments)
      (setq maxend (max maxend (or (cmacs-transcribe--seg s :end) 0))))
    (ceiling maxend 1000)))

(defun cmacs-transcribe--write-string (path string)
  "Write STRING to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file path (insert string))))

(defun cmacs-transcribe--file-sha256 (file)
  "Return the hex SHA-256 of FILE, or nil.
Prefers a streaming external program (`cmacs-transcribe-sha256-program');
falls back to an in-Emacs digest for files under 256 MiB."
  (when cmacs-transcribe-compute-file-hash
    (let ((prog (executable-find cmacs-transcribe-sha256-program)))
      (cond
       (prog (with-temp-buffer
               (when (ignore-errors
                       (zerop (call-process prog nil t nil (expand-file-name file))))
                 (car (split-string (buffer-string))))))
       ((< (or (file-attribute-size (file-attributes file)) 0) (* 256 1024 1024))
        (ignore-errors
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (secure-hash 'sha256 (current-buffer)))))
       (t nil)))))

;;; ---------------------------------------------------------------------
;;; Logging + poll timer
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--log-buffer ()
  "Return the shared transcribe log buffer, in `special-mode'."
  (let ((buf (get-buffer-create "*cmacs-transcribe-log*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode)))
    buf))

(defun cmacs-transcribe--log (fmt &rest args)
  "Append a timestamped line (FMT ARGS) to the transcribe log buffer."
  (let ((line (apply #'format fmt args)))
    (with-current-buffer (cmacs-transcribe--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "%H:%M:%S ") line "\n")))))

(defun cmacs-transcribe--start-timer (buffer)
  "Start the live-redraw poll timer for BUFFER (idempotent)."
  (cmacs-transcribe--stop-timer buffer)
  (when (and cmacs-transcribe-poll-interval (> cmacs-transcribe-poll-interval 0))
    (with-current-buffer buffer
      (setq cmacs-transcribe--timer
            (run-at-time cmacs-transcribe-poll-interval
                         cmacs-transcribe-poll-interval
                         (lambda ()
                           (if (buffer-live-p buffer)
                               (cmacs-transcribe--render buffer)
                             (cmacs-transcribe--stop-timer buffer))))))))

(defun cmacs-transcribe--stop-timer (buffer)
  "Cancel BUFFER's poll timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp cmacs-transcribe--timer)
        (cancel-timer cmacs-transcribe--timer)
        (setq cmacs-transcribe--timer nil)))))

;;; ---------------------------------------------------------------------
;;; Conversion command (reuses cmacs-transcode's backend)
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--convert-args (io)
  "Return ffmpeg args extracting IO's input to a 16 kHz mono S16LE WAV."
  (append
   (list "-y" "-i" (plist-get io :in)
         "-vn" "-ac" "1" "-ar" "16000"
         "-c:a" "pcm_s16le" "-f" "wav")
   cmacs-transcribe-ffmpeg-extra-args
   (list (plist-get io :out))))

(defun cmacs-transcribe--force-kill-job (job)
  "Forcibly stop JOB's conversion process (and its container, if any).
Mirrors `cmacs-transcode--force-kill-job': SIGKILL to a podman/docker
client does not reach ffmpeg inside the container, so it is force-removed
by name with `<runtime> rm -f'."
  (let ((proc (cmacs-transcribe-job-process job))
        (cname (cmacs-transcribe-job-container job)))
    (when (and cname (memq cmacs-transcribe--backend '(podman docker)))
      (ignore-errors
        (call-process (symbol-name cmacs-transcribe--backend) nil 0 nil
                      "rm" "-f" cname)))
    (when (process-live-p proc)
      (ignore-errors (signal-process proc 9))
      (ignore-errors (delete-process proc)))))

(defun cmacs-transcribe--cleanup-wav (job)
  "Delete JOB's transient WAV and its dedicated temp directory, if any."
  (let ((wav (cmacs-transcribe-job-wav job)))
    (when wav
      (let ((dir (directory-file-name (file-name-directory wav))))
        (ignore-errors
          (if (string-prefix-p "cmacs-transcribe-" (file-name-nondirectory dir))
              (delete-directory dir t)   ;the whole per-job temp dir
            (when (file-exists-p wav) (delete-file wav))))))
    (setf (cmacs-transcribe-job-wav job) nil)))

;;; ---------------------------------------------------------------------
;;; Pipeline: convert -> transcribe -> (summarize) -> done
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--start-job (buffer job)
  "Begin (or retry) the conversion stage for JOB in BUFFER's session."
  (with-current-buffer buffer
    (let* ((kind cmacs-transcribe--backend)
           (in (cmacs-transcribe-job-input job))
           ;; The temp WAV lives in a dedicated per-job temp *directory*, not
           ;; directly in `temporary-file-directory'.  A container backend
           ;; bind-mounts the WAV's directory as /output with a `:z' SELinux
           ;; relabel, and podman refuses to relabel a shared dir like /tmp
           ;; wholesale ("SELinux relabeling of /tmp is not allowed").  A
           ;; private subdirectory relabels fine.
           (wav (or (cmacs-transcribe-job-wav job)
                    (expand-file-name
                     "audio.wav" (make-temp-file "cmacs-transcribe-" t))))
           (io (cmacs-transcode--io kind in wav))
           (cname (and (memq kind '(podman docker))
                       (cmacs-transcribe--gen-container-name)))
           (cmd (cmacs-transcode--command
                 kind 'ffmpeg io nil (cmacs-transcribe--convert-args io) cname)))
      (setf (cmacs-transcribe-job-wav job) wav
            (cmacs-transcribe-job-stage job) 'converting
            (cmacs-transcribe-job-progress job) "converting…"
            (cmacs-transcribe-job-container job) cname)
      (cmacs-transcribe--log "convert %s -> wav" (file-name-nondirectory in))
      (cmacs-transcribe--log "  $ %s" (mapconcat #'identity cmd " "))
      (setf (cmacs-transcribe-job-process job)
            (make-process
             :name (concat "cmacs-transcribe:" (file-name-nondirectory in))
             :buffer (cmacs-transcribe--log-buffer)
             :noquery t
             :command cmd
             :filter (cmacs-transcribe--make-convert-filter job)
             :sentinel (cmacs-transcribe--make-convert-sentinel buffer job)))
      (cmacs-transcribe--render buffer))))

(defun cmacs-transcribe--make-convert-filter (job)
  "Return a process filter logging output and tracking JOB progress."
  (lambda (p chunk)
    (when (buffer-live-p (process-buffer p))
      (with-current-buffer (process-buffer p)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert chunk))))
    (dolist (ln (split-string chunk "[\r\n]+" t))
      (when (string-match-p "time=" ln)
        (setf (cmacs-transcribe-job-progress job)
              (concat "converting " (string-trim ln)))))))

(defun cmacs-transcribe--make-convert-sentinel (buffer job)
  "Return a sentinel that advances JOB to transcription or retries/fails."
  (lambda (p _event)
    (when (memq (process-status p) '(exit signal))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((ok (and (eq (process-status p) 'exit)
                         (zerop (process-exit-status p))
                         (cmacs-transcribe-job-wav job)
                         (file-exists-p (cmacs-transcribe-job-wav job)))))
            (cond
             ((cmacs-transcribe-job-cancelled job)
              (cmacs-transcribe--cleanup-wav job)
              (setf (cmacs-transcribe-job-stage job) 'failed
                    (cmacs-transcribe-job-progress job) "killed")
              (cmacs-transcribe--advance buffer))
             (ok
              (cmacs-transcribe--on-converted buffer job))
             ((< (cl-incf (cmacs-transcribe-job-tries job))
                 (max 1 cmacs-transcribe-max-retries))
              (cmacs-transcribe--log "retry convert %s (attempt %d)"
                                     (file-name-nondirectory
                                      (cmacs-transcribe-job-input job))
                                     (cmacs-transcribe-job-tries job))
              (cmacs-transcribe--start-job buffer job))
             (t
              (cmacs-transcribe--cleanup-wav job)
              (setf (cmacs-transcribe-job-stage job) 'failed
                    (cmacs-transcribe-job-note job) "convert failed"
                    (cmacs-transcribe-job-progress job) "convert failed")
              (cmacs-transcribe--log "FAILED convert %s (exit %s)"
                                     (file-name-nondirectory
                                      (cmacs-transcribe-job-input job))
                                     (if (eq (process-status p) 'exit)
                                         (process-exit-status p) "signal"))
              (cmacs-transcribe--advance buffer)))
            (cmacs-transcribe--render buffer)))))))

(defun cmacs-transcribe--on-converted (buffer job)
  "Kick off the whisper transcription stage for JOB in BUFFER."
  (with-current-buffer buffer
    (setf (cmacs-transcribe-job-stage job) 'transcribing
          (cmacs-transcribe-job-process job) nil
          (cmacs-transcribe-job-container job) nil
          (cmacs-transcribe-job-progress job) "transcribing…")
    (cmacs-transcribe--log "transcribe %s"
                           (file-name-nondirectory (cmacs-transcribe-job-input job)))
    (let ((model (cmacs-transcribe--model))
          (lang (cmacs-transcribe--language))
          (threads (cmacs-transcribe--threads))
          (wav (cmacs-transcribe-job-wav job)))
      (cmacs-whisper-transcribe-async
       model wav
       (lambda (result)
         (cmacs-transcribe--on-transcribed buffer job result))
       lang threads))
    (cmacs-transcribe--render buffer)))

(defun cmacs-transcribe--info-plist (job)
  "Build the hook INFO plist for JOB from its current state."
  (list :input-file (cmacs-transcribe-job-input job)
        :kind (cmacs-transcribe-job-kind job)
        :text-file (cmacs-transcribe-job-txt job)
        :org-file (cmacs-transcribe-job-org job)
        :srt-file (cmacs-transcribe-job-srt job)
        :vtt-file (cmacs-transcribe-job-vtt job)
        :ts-file (cmacs-transcribe-job-ts job)
        :text (cmacs-transcribe-job-text job)
        :segments (cmacs-transcribe-job-segments job)
        :summary (cmacs-transcribe-job-summary job)
        :summary-type (plist-get cmacs-transcribe--options :summary-type)
        :duration-seconds (cmacs-transcribe-job-duration job)
        :file-hash (cmacs-transcribe--file-sha256 (cmacs-transcribe-job-input job))
        :model (file-name-nondirectory (cmacs-transcribe--model))
        :language (cmacs-transcribe--language)
        :threads (cmacs-transcribe--threads)
        :type (plist-get cmacs-transcribe--options :type)
        :tags (plist-get cmacs-transcribe--options :tags)
        :source cmacs-transcribe-source
        :transcribed-at (format-time-string "%FT%T%z")))

(defun cmacs-transcribe--on-transcribed (buffer job result)
  "Handle whisper RESULT for JOB in BUFFER: write outputs, then summary/done."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cmacs-transcribe--cleanup-wav job)
      (let ((err (cdr (assq :error result))))
        (cond
         ((cmacs-transcribe-job-cancelled job)
          (setf (cmacs-transcribe-job-stage job) 'failed
                (cmacs-transcribe-job-progress job) "killed")
          (cmacs-transcribe--advance buffer))
         (err
          (setf (cmacs-transcribe-job-stage job) 'failed
                (cmacs-transcribe-job-note job) err
                (cmacs-transcribe-job-progress job) (concat "error: " err))
          (cmacs-transcribe--log "FAILED transcribe %s: %s"
                                 (file-name-nondirectory (cmacs-transcribe-job-input job))
                                 err)
          (cmacs-transcribe--advance buffer))
         (t
          (let* ((text (string-trim (or (cdr (assq :text result)) "")))
                 (segments (cdr (assq :segments result)))
                 (opts cmacs-transcribe--options)
                 (in (cmacs-transcribe-job-input job)))
            (setf (cmacs-transcribe-job-text job) text
                  (cmacs-transcribe-job-segments job) segments
                  (cmacs-transcribe-job-duration job)
                  (cmacs-transcribe--duration segments))
            ;; Primary transcript.
            (cmacs-transcribe--write-string (cmacs-transcribe-job-txt job)
                                            (concat text "\n"))
            ;; Optional extra outputs from the timestamped segments.
            (when (and (plist-get opts :emit-srt) segments)
              (setf (cmacs-transcribe-job-srt job) (cmacs-transcribe--sub-for in ".srt"))
              (cmacs-transcribe--write-string (cmacs-transcribe-job-srt job)
                                              (cmacs-transcribe--segments->srt segments)))
            (when (and (plist-get opts :emit-vtt) segments)
              (setf (cmacs-transcribe-job-vtt job) (cmacs-transcribe--sub-for in ".vtt"))
              (cmacs-transcribe--write-string (cmacs-transcribe-job-vtt job)
                                              (cmacs-transcribe--segments->vtt segments)))
            (when (and (plist-get opts :emit-timestamped) segments)
              (setf (cmacs-transcribe-job-ts job)
                    (cmacs-transcribe--dest in ".ts.txt" (plist-get opts :naming)
                                            (plist-get opts :output-dir)))
              (cmacs-transcribe--write-string (cmacs-transcribe-job-ts job)
                                              (cmacs-transcribe--segments->timestamped segments)))
            (cmacs-transcribe--log "wrote %s (%d chars)"
                                   (file-name-nondirectory (cmacs-transcribe-job-txt job))
                                   (length text))
            ;; Fire the after-transcription hook with the INFO plist.
            (ignore-errors
              (run-hook-with-args 'cmacs-transcribe-after-transcription-functions
                                  (cmacs-transcribe--info-plist job)))
            ;; Summarise (async) or finish.
            (if (and (plist-get opts :summarize)
                     (cmacs-transcribe--ai-available-p)
                     (not (string-empty-p text)))
                (cmacs-transcribe--start-summary buffer job)
              (when (and (plist-get opts :summarize)
                         (not (cmacs-transcribe--ai-available-p)))
                (cmacs-transcribe--log
                 "summary skipped for %s (cmacs-ai unavailable)"
                 (file-name-nondirectory in)))
              (setf (cmacs-transcribe-job-stage job) 'done
                    (cmacs-transcribe-job-progress job) "done")
              (cmacs-transcribe--advance buffer)))))
        (cmacs-transcribe--render buffer)))))

;;; ---------------------------------------------------------------------
;;; Summarisation (async cmacs-ai streaming)
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--summary-prompt ()
  "Return the system prompt for the current session's summary type."
  (let* ((type (plist-get cmacs-transcribe--options :summary-type))
         (tmpl (or (cdr (assq type cmacs-transcribe-summary-templates))
                   (cdr (assq 'general cmacs-transcribe-summary-templates)))))
    (or tmpl "Summarise the transcript in concise Org-mode markup.")))

(defun cmacs-transcribe--org-document (job)
  "Assemble the summary Org document string for JOB."
  (let ((in (cmacs-transcribe-job-input job)))
    (with-temp-buffer
      (insert (format "#+TITLE: %s — Transcript & Summary\n"
                      (file-name-nondirectory in)))
      (insert (format "#+DATE: %s\n\n" (format-time-string "%FT%T%z")))
      (insert "* Summary\n")
      (insert (string-trim (or (cmacs-transcribe-job-summary job) "")) "\n\n")
      (insert "* Metadata\n")
      (insert (format "- Source file: %s\n" in))
      (insert (format "- Duration: %d s\n" (or (cmacs-transcribe-job-duration job) 0)))
      (insert (format "- Model: %s\n" (file-name-nondirectory (cmacs-transcribe--model))))
      (insert (format "- Language: %s\n" (cmacs-transcribe--language)))
      (when (plist-get cmacs-transcribe--options :type)
        (insert (format "- Type: %s\n" (plist-get cmacs-transcribe--options :type))))
      (when (plist-get cmacs-transcribe--options :tags)
        (insert (format "- Tags: %s\n"
                        (mapconcat #'identity
                                   (plist-get cmacs-transcribe--options :tags) ", "))))
      (insert "\n* Transcript\n")
      (insert (string-trim (or (cmacs-transcribe-job-text job) "")) "\n")
      (buffer-string))))

(defun cmacs-transcribe--finish-summary (buffer job &optional error-msg standalone)
  "Write JOB's summary Org (unless ERROR-MSG), free the session, finish.
With STANDALONE non-nil this was a retroactive summary (not a pipeline
stage), so the parallel pool is left untouched."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (cmacs-transcribe-job-stream job)
        (ignore-errors (cmacs-ai-free-session (cmacs-transcribe-job-stream job)))
        (setf (cmacs-transcribe-job-stream job) nil))
      (if error-msg
          (progn
            (setf (cmacs-transcribe-job-note job) (concat "summary: " error-msg))
            (cmacs-transcribe--log "summary FAILED for %s: %s"
                                   (file-name-nondirectory (cmacs-transcribe-job-input job))
                                   error-msg))
        (setf (cmacs-transcribe-job-org job)
              (cmacs-transcribe--org-for (cmacs-transcribe-job-input job)))
        (cmacs-transcribe--write-string (cmacs-transcribe-job-org job)
                                        (cmacs-transcribe--org-document job))
        (cmacs-transcribe--log "wrote %s"
                               (file-name-nondirectory (cmacs-transcribe-job-org job)))
        (ignore-errors
          (run-hook-with-args 'cmacs-transcribe-after-summary-functions
                              (cmacs-transcribe--info-plist job))))
      ;; The transcript is the primary deliverable, so the job is done even
      ;; if the summary failed.
      (setf (cmacs-transcribe-job-stage job) 'done
            (cmacs-transcribe-job-progress job) (if error-msg "done (no summary)" "done"))
      (unless standalone (cmacs-transcribe--advance buffer))
      (cmacs-transcribe--render buffer))))

(defun cmacs-transcribe--start-summary (buffer job &optional standalone)
  "Start an async AI summary of JOB's transcript in BUFFER.
With STANDALONE non-nil this is a retroactive summary rather than a
pipeline stage; the parallel pool is not advanced when it finishes."
  (with-current-buffer buffer
    (setf (cmacs-transcribe-job-stage job) 'summarizing
          (cmacs-transcribe-job-summary job) ""
          (cmacs-transcribe-job-progress job) "summarizing…")
    (cmacs-transcribe--log "summarize %s"
                           (file-name-nondirectory (cmacs-transcribe-job-input job)))
    (condition-case err
        (let* ((pair (cmacs-ai-make-session
                      cmacs-transcribe-summary-provider
                      cmacs-transcribe-summary-model
                      (cmacs-transcribe--summary-prompt)))
               (session (cdr pair)))
          (setf (cmacs-transcribe-job-stream job) pair)
          (cmacs-ai-chat-stream
           session
           (concat "Summarise the following transcript.\n\n"
                   (cmacs-transcribe-job-text job))
           (lambda (payload)
             (cmacs-transcribe--summary-callback buffer job payload standalone))))
      (error
       (cmacs-transcribe--finish-summary buffer job (error-message-string err)
                                         standalone)))
    (cmacs-transcribe--render buffer)))

(defun cmacs-transcribe--summary-callback (buffer job payload &optional standalone)
  "Handle a cmacs-ai stream PAYLOAD for JOB in BUFFER.
STANDALONE is forwarded to `cmacs-transcribe--finish-summary'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase (car-safe payload)
        (:start nil)
        (:delta
         (setf (cmacs-transcribe-job-summary job)
               (concat (or (cmacs-transcribe-job-summary job) "")
                       (or (cadr payload) ""))))
        (:tool-use nil)
        (:end
         (let ((final (plist-get (cdr payload) :text)))
           (when (and final (> (length (string-trim final))
                               (length (string-trim (or (cmacs-transcribe-job-summary job) "")))))
             (setf (cmacs-transcribe-job-summary job) final)))
         (cmacs-transcribe--finish-summary buffer job nil standalone))
        (:error
         (cmacs-transcribe--finish-summary buffer job (or (cadr payload) "stream error")
                                           standalone))))))

;;; ---------------------------------------------------------------------
;;; Bounded parallel pool
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--launch-next (buffer)
  "Pop and start the next queued job in BUFFER, if any."
  (with-current-buffer buffer
    (when cmacs-transcribe--queue
      (cmacs-transcribe--start-job buffer (pop cmacs-transcribe--queue)))))

(defun cmacs-transcribe--advance (buffer)
  "Launch the next job, then check whether the session finished."
  (cmacs-transcribe--launch-next buffer)
  (cmacs-transcribe--maybe-finish buffer))

(defun cmacs-transcribe--active-p (job)
  "Non-nil if JOB currently occupies a pool slot."
  (memq (cmacs-transcribe-job-stage job)
        '(converting transcribing summarizing)))

(defun cmacs-transcribe--maybe-finish (buffer)
  "If BUFFER's pool is drained, stop the timer and report a summary."
  (with-current-buffer buffer
    (when (and (null cmacs-transcribe--queue)
               (not (cl-some #'cmacs-transcribe--active-p cmacs-transcribe--jobs)))
      (cmacs-transcribe--stop-timer buffer)
      (let ((done (cl-count 'done cmacs-transcribe--jobs
                            :key #'cmacs-transcribe-job-stage))
            (failed (cl-count 'failed cmacs-transcribe--jobs
                              :key #'cmacs-transcribe-job-stage))
            (skipped (cl-count 'skipped cmacs-transcribe--jobs
                               :key #'cmacs-transcribe-job-stage)))
        (cmacs-transcribe--log "session complete: %d done, %d failed, %d skipped"
                               done failed skipped)
        (cmacs-transcribe--render buffer)
        (message "cmacs-transcribe: %d done, %d failed, %d skipped"
                 done failed skipped)))))

(defun cmacs-transcribe--run (buffer)
  "Start processing BUFFER's queued jobs with the configured concurrency."
  (with-current-buffer buffer
    (let* ((queued (cl-remove-if-not
                    (lambda (j) (eq (cmacs-transcribe-job-stage j) 'queued))
                    cmacs-transcribe--jobs))
           (n (max 1 (or (plist-get cmacs-transcribe--options :parallel) 1))))
      (setq cmacs-transcribe--queue queued)
      (cmacs-transcribe--start-timer buffer)
      (dotimes (_ (min n (length queued)))
        (cmacs-transcribe--launch-next buffer))
      (cmacs-transcribe--render buffer))))

;;; ---------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--truncate (s n)
  "Truncate string S to at most N characters with an ellipsis."
  (if (> (length s) n) (concat (substring s 0 (1- n)) "…") s))

(defun cmacs-transcribe--stage-icon (stage)
  "Return a glyph for job STAGE."
  (pcase stage
    ('queued "…") ('converting "⇄") ('transcribing "✎")
    ('summarizing "✦") ('done "✔") ('failed "✗") ('skipped "–")
    (_ "?")))

(defun cmacs-transcribe--extra-formats-label (o)
  "Return a compact label of enabled extra formats for options O."
  (let (parts)
    (when (plist-get o :emit-srt) (push "srt" parts))
    (when (plist-get o :emit-vtt) (push "vtt" parts))
    (when (plist-get o :emit-timestamped) (push "ts" parts))
    (if parts (mapconcat #'identity (nreverse parts) ",") "—")))

(defun cmacs-transcribe--header-lines ()
  "Return the header lines for the current session as a list of strings."
  (let* ((o cmacs-transcribe--options)
         (par (or (plist-get o :parallel) 1))
         (threads (plist-get o :threads))
         (backend (or cmacs-transcribe--backend (cmacs-transcode--resolve t) 'none)))
    (list
     " cmacs-transcribe — speech-to-text"
     (format " backend:%s  jobs:%s  threads:%s  model:%s  lang:%s"
             backend (if (> par 1) par "OFF")
             (if threads threads "all")
             (file-name-nondirectory (cmacs-transcribe--model))
             (cmacs-transcribe--language))
     (format " summary:%s  extra:%s  out:%s%s"
             (if (plist-get o :summarize)
                 (format "on(%s)" (plist-get o :summary-type)) "off")
             (cmacs-transcribe--extra-formats-label o)
             (if (plist-get o :output-dir)
                 (abbreviate-file-name (plist-get o :output-dir)) "sidecar")
             (pcase (plist-get o :process-filter)
               ('missing "  [only-missing]")
               ('existing "  [only-existing]")
               (_ ""))))))

(defvar cmacs-transcribe--line-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-2] #'cmacs-transcribe-mouse-visit)
    (define-key m [follow-link] 'mouse-face)
    m)
  "Keymap on a finished job line, making it a click-to-open button.")

(defun cmacs-transcribe--job-line (i n job)
  "Return a propertized status line for JOB (index I of N)."
  (let* ((st (cmacs-transcribe-job-stage job))
         (done-txt (and (eq st 'done)
                        (cmacs-transcribe-job-txt job)
                        (file-exists-p (cmacs-transcribe-job-txt job))))
         (line (format " [%d/%d] %s  %-42s  %s"
                       i n (cmacs-transcribe--stage-icon st)
                       (cmacs-transcribe--truncate
                        (file-name-nondirectory (cmacs-transcribe-job-input job)) 42)
                       (pcase st
                         ((or 'converting 'transcribing 'summarizing)
                          (cmacs-transcribe-job-progress job))
                         ('done (if (cmacs-transcribe-job-org job)
                                    "done — v:txt V:org" "done — v:open"))
                         ('failed (or (cmacs-transcribe-job-note job) "failed"))
                         ('skipped "skipped")
                         (_ "queued")))))
    (if done-txt
        (propertize line
                    'cmacs-transcribe-job job
                    'mouse-face 'highlight
                    'follow-link t
                    'help-echo "mouse-2 / v: open transcript  (V: summary, r: summarise)"
                    'keymap cmacs-transcribe--line-map)
      (propertize line 'cmacs-transcribe-job job))))

(defconst cmacs-transcribe--hint-lines
  '(" hjkl:move  a:add  A:add-dir  d:del  K:kill  RET:start"
    " v:open-txt  V:open-org  r:summarise-line  (done lines: click / mouse-2)"
    " p:parallel P:jobs  w:threads  c:model  n:lang  o:out  O:summary-dir"
    " s:summary S:type  f:formats  T:tags  y:type  m:missing x:existing"
    " L:log  g:refresh  q:quit  ?:help")
  "Key hint lines shown at the bottom of the queue buffer.")

(defun cmacs-transcribe--render (buffer)
  "Redraw the queue BUFFER from session state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (dolist (h (cmacs-transcribe--header-lines)) (insert h "\n"))
        (insert (make-string 64 ?─) "\n")
        (if (null cmacs-transcribe--jobs)
            (insert "\n  (no files queued — press `a' to add media)\n")
          (let ((i 0) (n (length cmacs-transcribe--jobs)))
            (dolist (job cmacs-transcribe--jobs)
              (insert (cmacs-transcribe--job-line (cl-incf i) n job) "\n"))))
        (insert "\n")
        (dolist (h cmacs-transcribe--hint-lines) (insert h "\n"))
        (goto-char (point-min))
        (forward-line (1- line))))))

;;; ---------------------------------------------------------------------
;;; Mode + keymap
;;; ---------------------------------------------------------------------

(defvar cmacs-transcribe-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-transcribe-mode'.")

;; Bind on every load (reload-safe).  hjkl are motion; action commands avoid
;; h/j/k/l so the map can be an Evil overriding map (kill is `K', log `L').
(let ((map cmacs-transcribe-mode-map))
  (define-key map (kbd "j") #'next-line)
  (define-key map (kbd "k") #'previous-line)
  (define-key map (kbd "h") #'backward-char)
  (define-key map (kbd "l") #'forward-char)
  (define-key map (kbd "a") #'cmacs-transcribe-add)
  (define-key map (kbd "A") #'cmacs-transcribe-add-directory)
  (define-key map (kbd "d") #'cmacs-transcribe-remove)
  (define-key map (kbd "K") #'cmacs-transcribe-kill)
  (define-key map (kbd "RET") #'cmacs-transcribe-start)
  (define-key map (kbd "v") #'cmacs-transcribe-visit)
  (define-key map (kbd "V") #'cmacs-transcribe-visit-summary)
  (define-key map (kbd "r") #'cmacs-transcribe-summarize-at-point)
  (define-key map (kbd "p") #'cmacs-transcribe-toggle-parallel)
  (define-key map (kbd "P") #'cmacs-transcribe-set-parallel)
  (define-key map (kbd "w") #'cmacs-transcribe-set-threads)
  (define-key map (kbd "c") #'cmacs-transcribe-set-model)
  (define-key map (kbd "n") #'cmacs-transcribe-set-language)
  (define-key map (kbd "s") #'cmacs-transcribe-toggle-summarize)
  (define-key map (kbd "S") #'cmacs-transcribe-set-summary-type)
  (define-key map (kbd "f") #'cmacs-transcribe-cycle-formats)
  (define-key map (kbd "o") #'cmacs-transcribe-set-output-dir)
  (define-key map (kbd "O") #'cmacs-transcribe-set-summary-dir)
  (define-key map (kbd "T") #'cmacs-transcribe-set-tags)
  (define-key map (kbd "y") #'cmacs-transcribe-set-type)
  (define-key map (kbd "m") #'cmacs-transcribe-toggle-missing)
  (define-key map (kbd "x") #'cmacs-transcribe-toggle-existing)
  (define-key map (kbd "L") #'cmacs-transcribe-show-log)
  (define-key map (kbd "g") #'cmacs-transcribe-refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'cmacs-transcribe-help))

(defun cmacs-transcribe--cleanup ()
  "Kill-buffer hook: cancel the timer and force-stop running jobs."
  (when (timerp cmacs-transcribe--timer) (cancel-timer cmacs-transcribe--timer))
  (dolist (j cmacs-transcribe--jobs)
    (when (cmacs-transcribe--active-p j)
      (setf (cmacs-transcribe-job-cancelled j) t)
      (when (eq (cmacs-transcribe-job-stage j) 'converting)
        (cmacs-transcribe--force-kill-job j))
      (when (and (eq (cmacs-transcribe-job-stage j) 'summarizing)
                 (cmacs-transcribe-job-stream j))
        (ignore-errors (cmacs-ai-chat-cancel (cdr (cmacs-transcribe-job-stream j))))
        (ignore-errors (cmacs-ai-free-session (cmacs-transcribe-job-stream j))))
      (cmacs-transcribe--cleanup-wav j))))

(define-derived-mode cmacs-transcribe-mode special-mode "Transcribe"
  "Major mode for the cmacs speech-to-text queue.
\\{cmacs-transcribe-mode-map}"
  (buffer-disable-undo)
  (setq-local cmacs-transcribe--options
              (or cmacs-transcribe--options (cmacs-transcribe--default-options)))
  (add-hook 'kill-buffer-hook #'cmacs-transcribe--cleanup nil t))

(defun cmacs-transcribe--ensure-mode ()
  "Signal unless the current buffer is a transcribe queue buffer."
  (unless (derived-mode-p 'cmacs-transcribe-mode)
    (user-error "Not in a cmacs-transcribe buffer")))

;;; ---------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe--read-inputs ()
  "Return input files: dired marks, else a single prompted file/dir (or nil)."
  (cond
   ((derived-mode-p 'dired-mode) (dired-get-marked-files))
   (t (let ((p (read-file-name
                "Transcribe file or directory (empty to add later): "
                nil "" t)))
        (and p (not (string-empty-p p)) (list p))))))

(defun cmacs-transcribe--open (files &optional apply-opts)
  "Open (or reuse) the queue buffer, add FILES, and switch to it.
APPLY-OPTS is an optional plist merged into the session options."
  (let ((dir default-directory)
        (buf (get-buffer-create "*cmacs-transcribe*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-transcribe-mode)
        (setq default-directory dir)
        (cmacs-transcribe-mode))
      (when apply-opts
        (cl-loop for (k v) on apply-opts by #'cddr
                 do (setq cmacs-transcribe--options
                          (plist-put cmacs-transcribe--options k v))))
      (dolist (f files)
        (dolist (e (cmacs-transcribe--expand-input f)) (cmacs-transcribe--enqueue-file e)))
      (cmacs-transcribe--recompute-outputs)
      (cmacs-transcribe--render buf))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-transcribe (&optional files)
  "Open the cmacs speech-to-text queue buffer.
Interactively, uses the marked files in dired or prompts for a file/dir."
  (interactive (list (cmacs-transcribe--read-inputs)))
  (cmacs-transcribe--open files))

;;;###autoload
(defun cmacs-transcribe-file (input &rest opts)
  "Queue INPUT for transcription, apply OPTS, and start immediately.
OPTS is a plist merged into the session options (e.g. :summarize t
:output-dir \"~/notes/\").  Returns the queue buffer.  Intended for
scripting, MCP, and `emacsctl eval'."
  (let ((buf (cmacs-transcribe--open (list input) opts)))
    (with-current-buffer buf (cmacs-transcribe-start))
    buf))

;;; ---------------------------------------------------------------------
;;; Queue-buffer commands
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe-add (path &optional recursive)
  "Add media file or directory PATH to the queue.
With prefix argument RECURSIVE, search directories recursively."
  (interactive (list (read-file-name "Add media file or directory: " nil nil t)
                     current-prefix-arg))
  (cmacs-transcribe--ensure-mode)
  (let ((before (length cmacs-transcribe--jobs)))
    (dolist (e (cmacs-transcribe--expand-input path recursive))
      (cmacs-transcribe--enqueue-file e))
    (cmacs-transcribe--render (current-buffer))
    (message "cmacs-transcribe: added %d file(s)"
             (- (length cmacs-transcribe--jobs) before))))

(defun cmacs-transcribe-add-directory (dir)
  "Add all media files under directory DIR (recursively) to the queue."
  (interactive (list (read-directory-name "Add directory (recursive): ")))
  (cmacs-transcribe-add dir t))

(defun cmacs-transcribe--job-at-point ()
  "Return the job on the current line, or nil."
  (get-text-property (line-beginning-position) 'cmacs-transcribe-job))

(defun cmacs-transcribe-remove ()
  "Remove the job on the current line from the queue."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((job (cmacs-transcribe--job-at-point)))
    (cond
     ((null job) (user-error "No job on this line"))
     ((cmacs-transcribe--active-p job)
      (user-error "Job is running; press `K' to kill it first"))
     (t (setq cmacs-transcribe--jobs (delq job cmacs-transcribe--jobs))
        (cmacs-transcribe--render (current-buffer))))))

(defun cmacs-transcribe-kill ()
  "Kill the active job on the current line (no retry).
Force-removes a conversion container, cancels an in-flight summary, and
lets an in-progress transcription finish but discards its result."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((job (cmacs-transcribe--job-at-point)))
    (if (and job (cmacs-transcribe--active-p job))
        (progn
          (setf (cmacs-transcribe-job-cancelled job) t
                (cmacs-transcribe-job-note job) "killed")
          (pcase (cmacs-transcribe-job-stage job)
            ('converting (cmacs-transcribe--force-kill-job job))
            ('summarizing
             (when (cmacs-transcribe-job-stream job)
               (ignore-errors
                 (cmacs-ai-chat-cancel (cdr (cmacs-transcribe-job-stream job)))))))
          (cmacs-transcribe--log "killed %s"
                                 (file-name-nondirectory (cmacs-transcribe-job-input job))))
      (user-error "No running job on this line"))))

(defun cmacs-transcribe-start ()
  "Begin transcribing the queued jobs (with a preflight check)."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (unless (cmacs-transcribe--whisper-available-p)
    (user-error "cmacs-whisper is not built; reconfigure with --with-cmacs-whisper"))
  (unless (cl-some (lambda (j) (eq (cmacs-transcribe-job-stage j) 'queued))
                   cmacs-transcribe--jobs)
    (user-error "No queued jobs to transcribe"))
  (let ((model (cmacs-transcribe--model)))
    (unless (file-exists-p model)
      (if (and (fboundp 'cmacs-whisper-download-model)
               (y-or-n-p (format "Whisper model %s not found; download it now? "
                                 (file-name-nondirectory model))))
          (cmacs-whisper-download-model (file-name-nondirectory model))
        (user-error "Whisper model not found: %s" model))))
  (setq cmacs-transcribe--backend (cmacs-transcode--resolve))
  (cmacs-transcribe--log "run: backend=%s parallel=%d threads=%s"
                         cmacs-transcribe--backend
                         (max 1 (or (plist-get cmacs-transcribe--options :parallel) 1))
                         (or (cmacs-transcribe--threads) "all"))
  (cmacs-transcribe--run (current-buffer)))

(defun cmacs-transcribe-visit ()
  "Open the transcript (.txt) of the finished job on the current line."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let* ((job (cmacs-transcribe--job-at-point))
         (txt (and job (cmacs-transcribe-job-txt job))))
    (cond
     ((null job) (user-error "No job on this line"))
     ((not (eq (cmacs-transcribe-job-stage job) 'done))
      (user-error "Job is not finished yet"))
     ((and txt (file-exists-p txt)) (find-file-other-window txt))
     (t (user-error "No transcript file: %s" txt)))))

(defun cmacs-transcribe-visit-summary ()
  "Open the summary Org (.org) of the job on the current line, if any."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let* ((job (cmacs-transcribe--job-at-point))
         (org (and job (cmacs-transcribe-job-org job))))
    (cond
     ((null job) (user-error "No job on this line"))
     ((and org (file-exists-p org)) (find-file-other-window org))
     (t (user-error "No summary for this job; press `r' to create one")))))

(defun cmacs-transcribe-mouse-visit (event)
  "Open the transcript for the job on the line clicked by EVENT."
  (interactive "e")
  (mouse-set-point event)
  (cmacs-transcribe-visit))

(defun cmacs-transcribe-summarize-at-point ()
  "Retroactively summarise the finished job on the current line.
Use this when summaries were off during the run.  Streams asynchronously
via `cmacs-ai' and writes the summary Org next to (or under
`cmacs-transcribe-summary-dir' of) the transcript."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((job (cmacs-transcribe--job-at-point)))
    (cond
     ((null job) (user-error "No job on this line"))
     ((not (eq (cmacs-transcribe-job-stage job) 'done))
      (user-error "Job is not finished; can only summarise a completed transcript"))
     ((not (cmacs-transcribe--ai-available-p))
      (user-error "cmacs-ai is not available; cannot summarise"))
     (t
      ;; Reload the transcript text if it is no longer in memory.
      (when (or (null (cmacs-transcribe-job-text job))
                (string-empty-p (cmacs-transcribe-job-text job)))
        (let ((txt (cmacs-transcribe-job-txt job)))
          (if (and txt (file-exists-p txt))
              (setf (cmacs-transcribe-job-text job)
                    (with-temp-buffer (insert-file-contents txt)
                                      (string-trim (buffer-string))))
            (user-error "No transcript text available for this job"))))
      (when (string-empty-p (cmacs-transcribe-job-text job))
        (user-error "Transcript is empty; nothing to summarise"))
      (cmacs-transcribe--start-summary (current-buffer) job t)
      (message "cmacs-transcribe: summarising %s…"
               (file-name-nondirectory (cmacs-transcribe-job-input job)))))))

(defun cmacs-transcribe-toggle-parallel ()
  "Toggle parallelism between sequential and the configured job count."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((cur (or (plist-get cmacs-transcribe--options :parallel) 1)))
    (setq cmacs-transcribe--options
          (plist-put cmacs-transcribe--options :parallel
                     (if (> cur 1) 1
                       (if (> cmacs-transcribe-parallel-jobs 1)
                           cmacs-transcribe-parallel-jobs
                         (max 2 (read-number "Parallel jobs: " 2))))))
    (cmacs-transcribe--render (current-buffer))))

(defun cmacs-transcribe-set-parallel (n)
  "Set the number N of concurrent jobs."
  (interactive "nParallel jobs: ")
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :parallel (max 1 n)))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-set-threads (n)
  "Set the whisper thread count N (0 = all cores)."
  (interactive (list (read-number "Whisper threads (0 = all cores): "
                                  (or (cmacs-transcribe--threads) 0))))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :threads (if (> n 0) n nil)))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-set-model ()
  "Choose the whisper model for this session."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let* ((models (and (fboundp 'cmacs-whisper-list-models)
                      (cmacs-whisper-list-models)))
         (m (completing-read "Whisper model: " models nil nil
                             (or (plist-get cmacs-transcribe--options :model) ""))))
    (setq cmacs-transcribe--options
          (plist-put cmacs-transcribe--options :model
                     (and (not (string-empty-p m)) m)))
    (cmacs-transcribe--render (current-buffer))))

(defun cmacs-transcribe-set-language (lang)
  "Set the transcription LANGUAGE code (empty = whisper default)."
  (interactive (list (read-string "Language (2-letter code, empty = default): "
                                  (or (plist-get cmacs-transcribe--options :language) ""))))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :language
                   (and (not (string-empty-p lang)) lang)))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-toggle-summarize ()
  "Toggle AI summarisation for this session."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((on (not (plist-get cmacs-transcribe--options :summarize))))
    (when (and on (not (cmacs-transcribe--ai-available-p)))
      (message "cmacs-transcribe: cmacs-ai unavailable; summaries will be skipped"))
    (setq cmacs-transcribe--options (plist-put cmacs-transcribe--options :summarize on))
    (cmacs-transcribe--render (current-buffer))))

(defun cmacs-transcribe-set-summary-type ()
  "Choose the summary content-type template for this session."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let ((type (intern (completing-read
                       "Summary type: "
                       (mapcar (lambda (c) (symbol-name (car c)))
                               cmacs-transcribe-summary-templates)
                       nil t nil nil
                       (symbol-name (plist-get cmacs-transcribe--options :summary-type))))))
    (setq cmacs-transcribe--options (plist-put cmacs-transcribe--options :summary-type type))
    (cmacs-transcribe--render (current-buffer))))

(defun cmacs-transcribe-cycle-formats ()
  "Cycle the enabled extra output formats (none/srt/+vtt/+ts/all)."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (let* ((o cmacs-transcribe--options)
         (state (list (plist-get o :emit-srt)
                      (plist-get o :emit-vtt)
                      (plist-get o :emit-timestamped)))
         (next (pcase state
                 ('(nil nil nil) '(t nil nil))
                 ('(t nil nil)   '(t t nil))
                 ('(t t nil)     '(t t t))
                 (_              '(nil nil nil)))))
    (setq o (plist-put o :emit-srt (nth 0 next)))
    (setq o (plist-put o :emit-vtt (nth 1 next)))
    (setq o (plist-put o :emit-timestamped (nth 2 next)))
    (setq cmacs-transcribe--options o)
    (cmacs-transcribe--render (current-buffer))))

(defun cmacs-transcribe-set-output-dir (dir)
  "Set the session output directory to DIR (empty = sidecar)."
  (interactive (list (read-directory-name
                      "Output directory (empty = sidecar): "
                      (or (plist-get cmacs-transcribe--options :output-dir)
                          default-directory)
                      nil nil "")))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :output-dir
                   (and (not (string-empty-p dir)) (expand-file-name dir))))
  (cmacs-transcribe--recompute-outputs)
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-set-summary-dir (dir)
  "Set the session summary Org directory to DIR (empty = follow output-dir)."
  (interactive (list (read-directory-name
                      "Summary Org directory (empty = follow output-dir): "
                      (or (plist-get cmacs-transcribe--options :summary-dir)
                          default-directory)
                      nil nil "")))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :summary-dir
                   (and (not (string-empty-p dir)) (expand-file-name dir))))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-set-tags (tags)
  "Set the session TAGS (comma-separated) for the hook INFO plist."
  (interactive (list (read-string "Tags (comma-separated): "
                                  (mapconcat #'identity
                                             (plist-get cmacs-transcribe--options :tags)
                                             ","))))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :tags
                   (delq nil (mapcar (lambda (s) (let ((s (string-trim s)))
                                                   (and (not (string-empty-p s)) s)))
                                     (split-string tags "," t)))))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-set-type (type)
  "Set the session category TYPE (empty = none) for the hook INFO plist."
  (interactive (list (read-string "Type/category (empty = none): "
                                  (or (plist-get cmacs-transcribe--options :type) ""))))
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :type
                   (and (not (string-empty-p type)) type)))
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-toggle-missing ()
  "Toggle the process-missing filter (only files without a transcript)."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :process-filter
                   (if (eq (plist-get cmacs-transcribe--options :process-filter) 'missing)
                       nil 'missing)))
  (cmacs-transcribe--recompute-outputs)
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-toggle-existing ()
  "Toggle the process-existing filter (only files with a transcript)."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (setq cmacs-transcribe--options
        (plist-put cmacs-transcribe--options :process-filter
                   (if (eq (plist-get cmacs-transcribe--options :process-filter) 'existing)
                       nil 'existing)))
  (cmacs-transcribe--recompute-outputs)
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-show-log ()
  "Display the transcribe log buffer."
  (interactive)
  (display-buffer (cmacs-transcribe--log-buffer)))

(defun cmacs-transcribe-refresh ()
  "Redraw the queue buffer."
  (interactive)
  (cmacs-transcribe--ensure-mode)
  (cmacs-transcribe--render (current-buffer)))

(defun cmacs-transcribe-help ()
  "Describe the transcribe queue keybindings."
  (interactive)
  (message "%s" (mapconcat #'string-trim cmacs-transcribe--hint-lines "  |  ")))

;; Under Evil (Doom) the state maps shadow single-key bindings; give this
;; mode's map precedence in every state.
(with-eval-after-load 'evil
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map cmacs-transcribe-mode-map)))

(provide 'cmacs-transcribe)
;;; cmacs-transcribe.el ends here
