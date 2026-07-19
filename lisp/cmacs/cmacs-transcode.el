;;; cmacs-transcode.el --- Native ffmpeg video/audio transcoder -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A native cmacs reimplementation of the author's `compress_video' and
;; `compress_audio' shell scripts: batch-transcode media with ffmpeg,
;; preferring a podman/docker `linuxserver/ffmpeg' container (guaranteed
;; full codec set) and falling back to a host ffmpeg binary.
;;
;; Emacs itself spawns and supervises the ffmpeg processes (a bounded
;; parallel pool -- no GNU parallel) and streams live per-job status into a
;; dedicated `*cmacs-transcode*' queue buffer that redraws on a timer.
;;
;; The queue buffer (`cmacs-transcode-mode') is both the control panel and
;; the status view: add files/dirs, tune options (codec, CRF/QP, format,
;; hwaccel, parallelism, process-missing/existing), then press RET to run.
;; Every knob is a `defcustom' so users can set their own defaults in their
;; init file; the buffer seeds each session from those and overrides them
;; per-session without mutating the customs.
;;
;; Full fidelity to the scripts: all codecs, CRF/QP + quality presets,
;; formats, subtitle copy, ffprobe colour-metadata preservation, and the
;; VAAPI/Vulkan hardware-acceleration paths.  Excluded (by design): the
;; media-database integration and the Redis job queue of the scripts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'files-x)                      ;`with-connection-local-variables'

(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function vc-root-dir "vc" ())
(declare-function dired-get-marked-files "dired" (&optional localp arg filter distinguish-one-marked error))

(defgroup cmacs-transcode nil
  "Native ffmpeg video/audio transcoder (podman/docker container or host)."
  :group 'cmacs
  :prefix "cmacs-transcode-")

;;; ---------------------------------------------------------------------
;;; Customization -- general / backend
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcode-backend 'auto
  "Preferred ffmpeg backend.
`auto' tries podman, then docker, then a host ffmpeg binary; the symbols
`podman', `docker', and `host' force a specific backend (falling back to
whatever is available if the requested one is missing).  The
CMACS_TRANSCODE_CONTAINER_RUNTIME environment variable overrides this."
  :type '(choice (const :tag "Auto (podman -> docker -> host)" auto)
                 (const :tag "podman" podman)
                 (const :tag "docker" docker)
                 (const :tag "host ffmpeg binary" host))
  :safe #'symbolp)

(defcustom cmacs-transcode-execution 'auto
  "Where ffmpeg runs for a job, relative to the input file.
`auto' (the default) runs on the input's own host: a remote (TRAMP/SSH)
input transcodes on that remote host's hardware, a local input runs
locally.  `remote' forces the input's remote host (an error for a local
input).  `local' forces the local machine, copying a remote input down to
a temporary file first (a potentially large transfer).

This is connection-local-overridable, so a profile can force e.g. `local'
for one slow host while `auto' stays the global default.  The queue
buffer's `E' key cycles it per session."
  :type '(choice (const :tag "Auto (follow the file's host)" auto)
                 (const :tag "Force local" local)
                 (const :tag "Force remote" remote))
  :safe #'symbolp)

(defcustom cmacs-transcode-container-image "docker.io/linuxserver/ffmpeg:latest"
  "Container image used for the podman/docker backend.
The linuxserver/ffmpeg image ships a full codec set that a stock host
ffmpeg may lack.  Its entrypoint is ffmpeg; ffprobe runs via
\"--entrypoint ffprobe\"."
  :type 'string
  :safe #'stringp)

(defcustom cmacs-transcode-output-dir nil
  "Default output directory, or nil for \"output/\" under the project root."
  :type '(choice (const :tag "output/ under project root" nil) directory))

(defcustom cmacs-transcode-parallel-jobs 1
  "Number of ffmpeg processes to run at once.
1 means sequential (the default).  The queue buffer's `p'/`P' keys toggle
and set this per session."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-transcode-poll-interval 2
  "Seconds between live redraws of the queue buffer while jobs run.
nil or 0 disables the timer (the buffer still redraws on every state
change)."
  :type '(choice (const :tag "Disabled" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

(defcustom cmacs-transcode-overwrite t
  "If non-nil, pass ffmpeg -y to overwrite existing output files."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-transcode-max-retries 3
  "Maximum attempts per video job before it is marked failed.
Audio jobs are attempted once."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-transcode-process-filter nil
  "Optional pre-run filter over the queue.
`missing' only processes files whose output does not yet exist;
`existing' only reprocesses files whose output already exists; nil
processes everything."
  :type '(choice (const :tag "Process all" nil)
                 (const :tag "Only missing outputs" missing)
                 (const :tag "Only existing outputs" existing))
  :safe #'symbolp)

(defcustom cmacs-transcode-hwaccel-device "/dev/dri/renderD128"
  "DRI render node used for VAAPI hardware acceleration."
  :type 'string
  :safe #'stringp)

;;; ---------------------------------------------------------------------
;;; Customization -- video
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcode-video-codec "h265"
  "Default video codec (a key in `cmacs-transcode-video-codec-map')."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-video-audio-codec "vorbis"
  "Default audio codec for video output.
A key in `cmacs-transcode-video-audio-codec-map'."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-video-format "mkv"
  "Default container format for video output (mkv, mp4, webm)."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-quality "medium"
  "Default named quality preset (see `cmacs-transcode-crf-presets').
Only used when `cmacs-transcode-crf' is nil."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-crf 26
  "Default CRF for software/VAAPI video encoding (0-51, lower = better).
Overrides `cmacs-transcode-quality' when non-nil.  nil falls back to the
named quality preset."
  :type '(choice (const :tag "Use quality preset" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

(defcustom cmacs-transcode-qp nil
  "Optional QP value for GPU (VAAPI) video encoding (0-51)."
  :type '(choice (const :tag "None" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

(defcustom cmacs-transcode-hwaccel 'off
  "Hardware-acceleration mode for video.
`off' (the author's default) forces software encoding; `auto' uses VAAPI
when a device is present; `force' errors if no device is available."
  :type '(choice (const :tag "Off (software)" off)
                 (const :tag "Auto" auto)
                 (const :tag "Force" force))
  :safe #'symbolp)

(defcustom cmacs-transcode-prefer-vulkan nil
  "If non-nil, prefer the Vulkan hwaccel path over VAAPI when accelerating."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-prefer-software nil
  "If non-nil, always encode in software even when a hwaccel device exists."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-auto-quality nil
  "If non-nil, pick CRF/QP automatically from the input video width."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-resolution nil
  "Optional output scaling, e.g. \"1280x720\", or nil to keep source size."
  :type '(choice (const :tag "Source size" nil) string))

(defcustom cmacs-transcode-bitrate nil
  "Optional target video bitrate, e.g. \"5M\", overriding CRF/QP."
  :type '(choice (const :tag "None" nil) string))

(defcustom cmacs-transcode-preset nil
  "Optional ffmpeg encoder preset (ultrafast .. veryslow), or nil."
  :type '(choice (const :tag "Encoder default" nil) string))

(defcustom cmacs-transcode-subtitles t
  "If non-nil, copy subtitle streams into mkv/mp4 output."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-preserve-color-metadata t
  "If non-nil, probe and re-emit colour metadata to avoid tint shifts."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-color-primaries nil
  "Override for output color primaries (e.g. \"bt709\"), or nil to auto-detect."
  :type '(choice (const nil) string))

(defcustom cmacs-transcode-color-trc nil
  "Override for output transfer characteristics, or nil to auto-detect."
  :type '(choice (const nil) string))

(defcustom cmacs-transcode-colorspace nil
  "Override for output color matrix, or nil to auto-detect."
  :type '(choice (const nil) string))

(defcustom cmacs-transcode-color-range nil
  "Override for output color range (\"tv\" or \"pc\"), or nil to auto-detect."
  :type '(choice (const nil) (const "tv") (const "pc")))

;;; ---------------------------------------------------------------------
;;; Customization -- audio
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcode-audio-format "mp3"
  "Default audio output format (key in `cmacs-transcode-audio-codec-map')."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-audio-quality "veryhigh"
  "Default named audio quality preset (low/medium/high/veryhigh).
The default `veryhigh' is the maximum quality each lossy format supports:
MP3 320 kbps, Vorbis/OGG -q:a 10 (~500 kbps), Opus 256 kbps, AAC 320 kbps."
  :type 'string :safe #'stringp)

(defcustom cmacs-transcode-audio-bitrate nil
  "Optional custom audio bitrate, e.g. \"320k\", overriding the preset."
  :type '(choice (const :tag "Use preset" nil) string))

(defcustom cmacs-transcode-recursive nil
  "If non-nil, adding a directory searches it recursively for media.
Each output mirrors the input's relative subdirectory tree under the
session output directory, so e.g. transcoding a parent of per-album (or
per-season) folders yields output/album_01/..., output/album_02/..., etc.
Applies to both video and audio sessions.  Off by default; toggle it per
session with `R' in the queue buffer."
  :type 'boolean :safe #'booleanp)

(defcustom cmacs-transcode-audio-recursive nil
  "If non-nil, added directories are searched recursively for audio.
Obsolete: use the kind-agnostic `cmacs-transcode-recursive' instead.  Still
honoured for audio sessions when set, for backward compatibility."
  :type 'boolean :safe #'booleanp)
(make-obsolete-variable 'cmacs-transcode-audio-recursive
                        'cmacs-transcode-recursive "cmacs")

(defcustom cmacs-transcode-audio-input-format nil
  "Optional input extension filter for audio directory adds (e.g. \"flac\")."
  :type '(choice (const :tag "All audio" nil) string))

;;; ---------------------------------------------------------------------
;;; Customization -- tunable tables
;;; ---------------------------------------------------------------------

(defcustom cmacs-transcode-video-codec-map
  '(("h264" . "libx264") ("h265" . "libx265")
    ("vp9" . "libvpx-vp9") ("av1" . "libaom-av1"))
  "Map of video codec key -> software ffmpeg encoder name."
  :type '(alist :key-type string :value-type string))

(defcustom cmacs-transcode-video-audio-codec-map
  '(("vorbis" . "libvorbis") ("opus" . "libopus") ("aac" . "aac")
    ("mp3" . "libmp3lame") ("copy" . "copy"))
  "Map of video-audio codec key -> ffmpeg encoder name."
  :type '(alist :key-type string :value-type string))

(defcustom cmacs-transcode-audio-codec-map
  '(("mp3" . "libmp3lame") ("vorbis" . "libvorbis") ("ogg" . "libvorbis")
    ("opus" . "libopus") ("aac" . "aac") ("flac" . "flac") ("copy" . "copy"))
  "Map of audio output format key -> ffmpeg encoder name."
  :type '(alist :key-type string :value-type string))

(defcustom cmacs-transcode-crf-presets
  '(("low" . 28) ("medium" . 24) ("high" . 18) ("veryhigh" . 15))
  "Named quality preset -> CRF value for software video encoding."
  :type '(alist :key-type string :value-type integer))

(defcustom cmacs-transcode-vulkan-bitrate-presets
  '(("low" . "2M") ("medium" . "5M") ("high" . "10M") ("veryhigh" . "20M"))
  "Named quality preset -> target bitrate for the Vulkan encoder."
  :type '(alist :key-type string :value-type string))

(defcustom cmacs-transcode-mp3-presets
  '(("low" . 128) ("medium" . 192) ("high" . 320) ("veryhigh" . 320))
  "Named quality preset -> MP3 bitrate in kbps."
  :type '(alist :key-type string :value-type integer))

(defcustom cmacs-transcode-vorbis-presets
  '(("low" . 3) ("medium" . 5) ("high" . 7) ("veryhigh" . 10))
  "Named quality preset -> Vorbis quality scale (0-10)."
  :type '(alist :key-type string :value-type integer))

(defcustom cmacs-transcode-opus-presets
  '(("low" . 96) ("medium" . 160) ("high" . 224) ("veryhigh" . 256))
  "Named quality preset -> Opus target bitrate in kbps."
  :type '(alist :key-type string :value-type integer))

(defcustom cmacs-transcode-aac-presets
  '(("low" . 128) ("medium" . 192) ("high" . 256) ("veryhigh" . 320))
  "Named quality preset -> AAC target bitrate in kbps."
  :type '(alist :key-type string :value-type integer))

(defcustom cmacs-transcode-video-extensions
  '("mp4" "mkv" "webm" "mov" "avi" "m4v" "mpg" "mpeg" "wmv" "flv" "ts" "m2ts")
  "Input file extensions recognised as video."
  :type '(repeat string))

(defcustom cmacs-transcode-audio-extensions
  '("mp3" "ogg" "oga" "wav" "flac" "m4a" "aac" "opus" "wma" "ape" "wv")
  "Input file extensions recognised as audio."
  :type '(repeat string))

;;; ---------------------------------------------------------------------
;;; Session state (buffer-local) + job struct
;;; ---------------------------------------------------------------------

(cl-defstruct (cmacs-transcode-job
               (:constructor cmacs-transcode-job-create)
               (:copier nil))
  input                 ; absolute input path (may be a TRAMP path)
  output                ; absolute output path (final destination)
  subdir                ; relative output subdir (recursive audio), or nil/""
  (status 'queued)      ; queued running done failed skipped
  (progress "")         ; latest ffmpeg stats line
  process               ; the running process, or nil
  container             ; container name (for podman/docker force-kill), or nil
  exec-dir              ; dir to bind as `default-directory' (remote), or nil
  staged-input          ; local temp copy of a remote input (local mode), or nil
  staged-output         ; local temp for the output before copy-up, or nil
  (tries 0)             ; attempts so far
  cancelled             ; non-nil when the user killed it (no retry)
  note)                 ; extra note for the status line

(defvar cmacs-transcode--name-counter 0
  "Monotonic counter for unique per-run container names.")

(defun cmacs-transcode--gen-container-name ()
  "Return a fresh, unique container name for a transcode job."
  (format "cmacs-transcode-%d-%d"
          (emacs-pid) (cl-incf cmacs-transcode--name-counter)))

(defvar-local cmacs-transcode--kind 'video
  "Media kind of this session: `video' or `audio'.")
(defvar-local cmacs-transcode--options nil
  "Session options plist, seeded from the defcustoms.")
(defvar-local cmacs-transcode--jobs nil
  "List of `cmacs-transcode-job' structs in this session.")
(defvar-local cmacs-transcode--queue nil
  "Jobs still waiting to be launched during the current run.")
(defvar-local cmacs-transcode--backend nil
  "Backend resolved for the current run: `podman', `docker', or `host'.")
(defvar-local cmacs-transcode--timer nil
  "The live-redraw poll timer for this session, or nil.")

;;; ---------------------------------------------------------------------
;;; Backend resolution
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--env-runtime ()
  "Return the CMACS_TRANSCODE_CONTAINER_RUNTIME override symbol, or nil."
  (let ((v (getenv "CMACS_TRANSCODE_CONTAINER_RUNTIME")))
    (and v (not (string-empty-p v)) (intern v))))

(defun cmacs-transcode--available-backends ()
  "Return the available backends in preference order (podman docker host).
Probes the host of `default-directory' -- so binding `default-directory'
to a remote (TRAMP) directory resolves the remote host's backends."
  (let ((remote (and (file-remote-p default-directory) t)))
    (delq nil (list (and (executable-find "podman" remote) 'podman)
                    (and (executable-find "docker" remote) 'docker)
                    (and (executable-find "ffmpeg" remote) 'host)))))

(defun cmacs-transcode--exec-dir (input &optional mode)
  "Return the directory whose host should run the tools for INPUT, or nil.
nil means the local machine.  A non-nil value is a (possibly remote)
directory to bind as `default-directory' around the process calls, chosen
from MODE (default `cmacs-transcode-execution') and whether INPUT is remote."
  (let ((mode (or mode cmacs-transcode-execution))
        (remote (file-remote-p input)))
    (pcase mode
      ('local nil)
      ('remote (if remote
                   (file-name-directory (expand-file-name input))
                 (user-error
                  "cmacs-transcode: execution is `remote' but %s is local"
                  (abbreviate-file-name input))))
      (_ (and remote (file-name-directory (expand-file-name input)))))))

(defun cmacs-transcode--stage-in-p (input &optional mode)
  "Non-nil when INPUT must be copied to the local machine before running.
True only under `local' MODE for a remote input."
  (and (eq (or mode cmacs-transcode-execution) 'local) (file-remote-p input)))

(defun cmacs-transcode--session-execution ()
  "Return this session's execution mode (`auto'/`local'/`remote')."
  (or (plist-get cmacs-transcode--options :execution) cmacs-transcode-execution))

(defun cmacs-transcode--resolve (&optional noerror)
  "Return the backend to use: `podman', `docker', or `host'.
Honours the CMACS_TRANSCODE_CONTAINER_RUNTIME override and
`cmacs-transcode-backend', falling back to whatever is available.  With
NOERROR return nil instead of signalling when nothing is available."
  (let* ((avail (cmacs-transcode--available-backends))
         (pref (or (cmacs-transcode--env-runtime) cmacs-transcode-backend 'auto))
         (chosen (if (and (memq pref '(podman docker host)) (memq pref avail))
                     pref
                   (car avail))))
    (or chosen
        (unless noerror
          (user-error
           "cmacs-transcode: no backend available (install podman, docker, or ffmpeg)")))))

;;;###autoload
(defun cmacs-transcode-supported-p ()
  "Return non-nil if a transcode backend (podman, docker, or ffmpeg) exists."
  (and (cmacs-transcode--resolve t) t))

;;; ---------------------------------------------------------------------
;;; Path mapping + command assembly
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--io (kind in-file &optional out-file)
  "Return an IO plist mapping IN-FILE/OUT-FILE for backend KIND.
Keys: :in :out (paths to embed in ffmpeg args), :in-dir :out-dir (host
dirs to mount) and :same (input and output share a directory).

Every path that ends up in the ffmpeg command line or a container `-v'
mount is the LOCAL name on the execution host (`file-local-name' strips
any TRAMP `/ssh:host:' prefix); for a local path this is a no-op, so local
behaviour is unchanged."
  (let* ((in-file (expand-file-name in-file))
         (in-dir (file-name-directory in-file))
         (out-file (and out-file (expand-file-name out-file)))
         (out-dir (and out-file (file-name-directory out-file)))
         (in-local (file-local-name in-file))
         (out-local (and out-file (file-local-name out-file)))
         (in-dir-local (file-local-name in-dir))
         (out-dir-local (and out-dir (file-local-name out-dir)))
         ;; For a remote path compare local names by string (no SSH round-trip
         ;; and safe when the host is unreachable); locally use file-truename
         ;; so symlinked same-dirs still collapse to one /config mount.
         (same (and out-dir
                    (if (file-remote-p in-file)
                        (string= (directory-file-name in-dir-local)
                                 (directory-file-name out-dir-local))
                      (string= (file-truename in-dir) (file-truename out-dir))))))
    (if (eq kind 'host)
        (list :in in-local :out out-local
              :in-dir in-dir-local :out-dir out-dir-local :same same)
      (let ((inm (if same "/config" "/input"))
            (outm (if same "/config" "/output")))
        (list :in (concat inm "/" (file-name-nondirectory in-local))
              :out (and out-local (concat outm "/" (file-name-nondirectory out-local)))
              :in-dir in-dir-local :out-dir out-dir-local :same same)))))

(defun cmacs-transcode--hw-run-args (hw)
  "Container run args for hwaccel device passthrough.  HW is (TYPE . VENDOR)."
  (pcase (car-safe hw)
    ('vaapi (list (format "--device=%s:%s"
                          cmacs-transcode-hwaccel-device
                          cmacs-transcode-hwaccel-device)))
    ('vulkan (append (list "--device=/dev/dri:/dev/dri")
                     (pcase (cdr hw)
                       ("intel" (list "-e" "ANV_VIDEO_DECODE=1"))
                       ("amd" (list "-e" "RADV_PERFTEST=video_decode"))
                       (_ nil))))
    (_ nil)))

(defun cmacs-transcode--hw-host-env (vendor)
  "Return process-environment additions for host Vulkan of VENDOR."
  (pcase vendor
    ("intel" (list "ANV_VIDEO_DECODE=1"))
    ("amd" (list "RADV_PERFTEST=video_decode"))
    (_ nil)))

(defun cmacs-transcode--command (kind tool io hw ffmpeg-args &optional name)
  "Assemble the full process command list.
KIND is `host', `podman', or `docker'.  TOOL is `ffmpeg' or `ffprobe'.
IO is a plist from `cmacs-transcode--io'.  HW is (TYPE . VENDOR) or nil.
FFMPEG-ARGS already reference the paths in IO.  For a container backend,
NAME (when non-nil) is passed as \"--name\" so the container can later be
force-removed --- SIGKILL to the client alone does not reach ffmpeg
inside the container."
  (let ((prog (if (eq tool 'ffprobe) "ffprobe" "ffmpeg")))
    (if (eq kind 'host)
        ;; Resolve on the execution host (remote when `default-directory' is
        ;; a TRAMP dir); fall back to the bare name, which process-file /
        ;; make-process :file-handler resolve via the remote PATH.
        (cons (or (executable-find prog (and (file-remote-p default-directory) t))
                  prog)
              ffmpeg-args)
      (let* ((runner (symbol-name kind))
             (same (plist-get io :same))
             (in-dir (directory-file-name (plist-get io :in-dir)))
             (out-dir (and (plist-get io :out-dir)
                           (directory-file-name (plist-get io :out-dir)))))
        (append
         (list runner "run" "--rm")
         (when name (list "--name" name))
         (list "--security-opt" "label=disable")
         (when (eq tool 'ffprobe) (list "--entrypoint" "ffprobe"))
         (cmacs-transcode--hw-run-args hw)
         (if same
             (list "-v" (format "%s:/config:z" in-dir))
           (append (list "-v" (format "%s:/input:z" in-dir))
                   (when out-dir (list "-v" (format "%s:/output:z" out-dir)))))
         (list cmacs-transcode-container-image)
         ffmpeg-args)))))

;;; ---------------------------------------------------------------------
;;; ffprobe helpers (colour metadata, width) + hwaccel selection
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--ffprobe (kind in-file &rest probe-args)
  "Run ffprobe on IN-FILE via KIND with PROBE-ARGS; return stdout or nil."
  (let* ((io (cmacs-transcode--io kind in-file))
         (cmd (cmacs-transcode--command
               kind 'ffprobe io nil
               (append probe-args (list (plist-get io :in))))))
    (with-temp-buffer
      ;; `process-file' runs on the host of `default-directory' (remote when
      ;; the caller bound it to a TRAMP dir), unlike `call-process'.
      (when (ignore-errors
              (eq 0 (apply #'process-file (car cmd) nil t nil (cdr cmd))))
        (buffer-string)))))

(defun cmacs-transcode--probe-width (kind in-file)
  "Return the video width of IN-FILE probed via KIND, or nil."
  (let ((out (cmacs-transcode--ffprobe
              kind in-file "-v" "error" "-select_streams" "v:0"
              "-show_entries" "stream=width"
              "-of" "default=noprint_wrappers=1:nokey=1")))
    (when (and out (string-match "\\([0-9]+\\)" out))
      (string-to-number (match-string 1 out)))))

(defun cmacs-transcode--probe-color (kind in-file)
  "Return (PRIMARIES TRC SPACE RANGE) probed from IN-FILE via KIND, or nil.
Missing HD fields are inferred as bt709 (range defaults to tv), matching
the compress_video script."
  (let ((out (cmacs-transcode--ffprobe
              kind in-file "-v" "quiet" "-select_streams" "v:0"
              "-show_entries"
              "stream=color_primaries,color_transfer,color_space,color_range,width"
              "-of" "default=noprint_wrappers=1")))
    (when out
      (let (p trc sp rng width)
        (dolist (ln (split-string out "[\r\n]+" t))
          (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" ln)
            (let ((k (match-string 1 ln)) (v (match-string 2 ln)))
              (pcase k
                ("color_primaries" (setq p v))
                ("color_transfer" (setq trc v))
                ("color_space" (setq sp v))
                ("color_range" (setq rng v))
                ("width" (setq width (string-to-number v)))))))
        (let ((hd (and width (>= width 1280))))
          (when (and hd (member p '(nil "" "unknown"))) (setq p "bt709"))
          (when (and hd (member trc '(nil "" "unknown"))) (setq trc "bt709"))
          (when (and hd (member sp '(nil "" "unknown"))) (setq sp "bt709"))
          (when (member rng '(nil "" "unknown")) (setq rng "tv")))
        (list p trc sp rng)))))

(defun cmacs-transcode--auto-quality (width gpu)
  "Return an automatic CRF/QP value from video WIDTH (GPU adds +2)."
  (let ((base 24) (w1280 26) (w1920 28))
    (when gpu (setq base (+ base 2) w1280 (+ w1280 2) w1920 (+ w1920 2)))
    (cond ((not (integerp width)) base)
          ((> width 1920) w1920)
          ((> width 1280) w1280)
          (t base))))

(defun cmacs-transcode--hwaccel-device-p ()
  "Non-nil if the configured VAAPI render node is a character device."
  (let* ((dev cmacs-transcode-hwaccel-device)
         (attrs (and dev (file-attributes dev)))
         (modes (and attrs (file-attribute-modes attrs))))
    (and modes (eq (aref modes 0) ?c))))

(defun cmacs-transcode--gpu-vendor ()
  "Return \"intel\", \"amd\", \"nvidia\", or nil from the DRI render node."
  (let ((f "/sys/class/drm/renderD128/device/vendor"))
    (when (file-readable-p f)
      (pcase (string-trim (with-temp-buffer (insert-file-contents f)
                                            (buffer-string)))
        ("0x8086" "intel") ("0x1002" "amd") ("0x10de" "nvidia") (_ nil)))))

(defun cmacs-transcode--hw-type (opts)
  "Return (TYPE . VENDOR) for OPTS: TYPE is `none', `vaapi', or `vulkan'.
Signals when hwaccel is forced but no device is available."
  (let ((mode (plist-get opts :hwaccel)))
    (if (or (eq mode 'off) (plist-get opts :prefer-software))
        (cons 'none nil)
      (let ((type 'none) (vendor nil))
        (when (and (plist-get opts :prefer-vulkan) (file-directory-p "/dev/dri"))
          (setq type 'vulkan vendor (cmacs-transcode--gpu-vendor)))
        (when (and (eq type 'none) (cmacs-transcode--hwaccel-device-p))
          (setq type 'vaapi))
        (when (and (eq mode 'force) (eq type 'none))
          (user-error "cmacs-transcode: hwaccel forced but no device available"))
        (cons type vendor)))))

;;; ---------------------------------------------------------------------
;;; ffmpeg argument builders (pure functions)
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--color-overridden-p (opts)
  "Non-nil if any explicit colour override is set in OPTS."
  (or (plist-get opts :color-primaries) (plist-get opts :color-trc)
      (plist-get opts :colorspace) (plist-get opts :color-range)))

(defun cmacs-transcode--video-args (opts io meta)
  "Return the ffmpeg argument list for a video job.
OPTS is the session options plist, IO a `cmacs-transcode--io' plist, and
META a plist with :hw (TYPE . VENDOR), :width, and :color (a
\(PRIMARIES TRC SPACE RANGE) list).  Pure and directly unit-testable."
  (let* ((in (plist-get io :in))
         (out (plist-get io :out))
         (hw (plist-get meta :hw))
         (hwtype (or (car-safe hw) 'none))
         (gpu (memq hwtype '(vaapi vulkan)))
         (vcodec (plist-get opts :video-codec))
         (acodec (plist-get opts :audio-codec))
         (fmt (plist-get opts :format))
         (res (plist-get opts :resolution))
         (crf nil) (qp nil)
         args)
    (cl-flet ((add (&rest xs) (setq args (nconc args xs))))
      ;; Resolve CRF/QP.
      (cond
       ((plist-get opts :auto-quality)
        (let ((auto (cmacs-transcode--auto-quality (plist-get meta :width) gpu)))
          (if gpu (setq qp (or (plist-get opts :qp) auto))
            (setq crf (or (plist-get opts :crf) auto)))))
       ((and gpu (plist-get opts :qp)) (setq qp (plist-get opts :qp)))
       (t (setq crf (or (plist-get opts :crf)
                        (cdr (assoc (plist-get opts :quality)
                                    cmacs-transcode-crf-presets))))))
      ;; -y
      (when (plist-get opts :overwrite) (add "-y"))
      ;; Hardware device init (before -i).
      (pcase hwtype
        ('vulkan (add "-init_hw_device" "vulkan=vk:0"
                      "-hwaccel" "vulkan" "-hwaccel_output_format" "vulkan"))
        ('vaapi (add "-vaapi_device" cmacs-transcode-hwaccel-device)))
      ;; Input.
      (add "-i" in)
      ;; Video codec + scaling filter.
      (pcase hwtype
        ('vulkan
         (add "-c:v" (if (equal vcodec "h265") "hevc_vulkan" "h264_vulkan"))
         (if res
             (add "-vf" (format "format=nv12,hwupload,scale_vulkan=%s" res))
           (add "-vf" "format=nv12,hwupload")))
        ('vaapi
         (add "-c:v" (if (equal vcodec "h265") "hevc_vaapi" "h264_vaapi"))
         (if res
             (let ((wh (split-string res "x")))
               (add "-vf" (format "format=nv12|vaapi,hwupload,scale_vaapi=w=%s:h=%s"
                                  (nth 0 wh) (nth 1 wh))))
           (add "-vf" "format=nv12|vaapi,hwupload")))
        (_
         (add "-c:v" (or (cdr (assoc vcodec cmacs-transcode-video-codec-map))
                         "libx265"))
         (when res (add "-vf" (format "scale=%s" res)))))
      ;; Quality.
      (cond
       ((plist-get opts :bitrate) (add "-b:v" (plist-get opts :bitrate)))
       ((eq hwtype 'vulkan)
        (add "-b:v" (or (cdr (assoc (plist-get opts :quality)
                                    cmacs-transcode-vulkan-bitrate-presets))
                        "5M")))
       ((and (eq hwtype 'vaapi) qp) (add "-qp" (number-to-string qp)))
       (crf (add "-crf" (number-to-string crf))))
      ;; Encoder preset.
      (when (plist-get opts :preset) (add "-preset" (plist-get opts :preset)))
      ;; Colour metadata preservation.
      (when (plist-get opts :preserve-color)
        (let* ((any (cmacs-transcode--color-overridden-p opts))
               (probed (plist-get meta :color))
               (p (or (plist-get opts :color-primaries)
                      (and (not any) (nth 0 probed))))
               (trc (or (plist-get opts :color-trc) (and (not any) (nth 1 probed))))
               (sp (or (plist-get opts :colorspace) (and (not any) (nth 2 probed))))
               (rng (or (plist-get opts :color-range) (and (not any) (nth 3 probed)))))
          (when (and p (not (equal p "unknown"))) (add "-color_primaries" p))
          (when (and trc (not (equal trc "unknown"))) (add "-color_trc" trc))
          (when (and sp (not (equal sp "unknown"))) (add "-colorspace" sp))
          (when (and rng (not (equal rng "unknown"))) (add "-color_range" rng))
          ;; For software H.265 also embed via x265-params.
          (when (and (equal vcodec "h265") (eq hwtype 'none))
            (let (xp)
              (when (and p (not (equal p "unknown")))
                (push (format "colorprim=%s" p) xp))
              (when (and trc (not (equal trc "unknown")))
                (push (format "transfer=%s" trc) xp))
              (when (and sp (not (equal sp "unknown")))
                (push (format "colormatrix=%s" sp) xp))
              (when xp
                (add "-x265-params" (mapconcat #'identity (nreverse xp) ":")))))))
      ;; Audio.
      (if (equal acodec "copy")
          (add "-c:a" "copy")
        (add "-c:a" (or (cdr (assoc acodec cmacs-transcode-video-audio-codec-map))
                        "libvorbis"))
        (cond ((equal acodec "vorbis") (add "-q:a" "4"))
              ((equal acodec "opus") (add "-b:a" "128k"))))
      ;; Stream mapping + subtitles.
      (add "-map" "0:v" "-map" "0:a?")
      (when (and (plist-get opts :subtitles) (member fmt '("mkv" "mp4")))
        (add "-map" "0:s?" "-c:s" "copy"))
      ;; Output.
      (add out))
    args))

(defun cmacs-transcode--audio-args (opts io)
  "Return the ffmpeg argument list for an audio job.
OPTS is the session options plist and IO a `cmacs-transcode--io' plist."
  (let* ((in (plist-get io :in))
         (out (plist-get io :out))
         (fmt (plist-get opts :audio-format))
         (quality (plist-get opts :audio-quality))
         (codec (or (cdr (assoc fmt cmacs-transcode-audio-codec-map)) "libmp3lame"))
         args)
    (cl-flet ((add (&rest xs) (setq args (nconc args xs))))
      (when (plist-get opts :overwrite) (add "-y"))
      (add "-i" in)
      (add "-c:a" codec)
      (cond
       ((plist-get opts :audio-bitrate) (add "-b:a" (plist-get opts :audio-bitrate)))
       ((equal fmt "mp3")
        (add "-b:a" (format "%sk"
                            (or (cdr (assoc quality cmacs-transcode-mp3-presets)) 320))))
       ((member fmt '("vorbis" "ogg"))
        (add "-q:a" (number-to-string
                     (or (cdr (assoc quality cmacs-transcode-vorbis-presets)) 7))))
       ((equal fmt "opus")
        (add "-b:a" (format "%sk"
                            (or (cdr (assoc quality cmacs-transcode-opus-presets)) 256))))
       ((equal fmt "aac")
        (add "-b:a" (format "%sk"
                            (or (cdr (assoc quality cmacs-transcode-aac-presets)) 320)))))
      (add "-vn" "-map" "0:a" "-map_metadata" "0")
      (add out))
    args))

;;; ---------------------------------------------------------------------
;;; Options seeding + output paths
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--default-options (kind)
  "Return a fresh options plist for media KIND, seeded from the defcustoms."
  (append
   (list :parallel cmacs-transcode-parallel-jobs
         :process-filter cmacs-transcode-process-filter
         :overwrite cmacs-transcode-overwrite
         :output-dir cmacs-transcode-output-dir
         ;; Recurse+mirror when enabled (either the kind-agnostic option or,
         ;; for audio, the obsolete audio-only one for backward compatibility).
         :recursive (or cmacs-transcode-recursive
                        (and (eq kind 'audio)
                             (with-suppressed-warnings
                                 ((obsolete cmacs-transcode-audio-recursive))
                               cmacs-transcode-audio-recursive)))
         ;; Read under connection-local so a remote buffer picks up that host's
         ;; default execution mode; the `E' key overrides it per session.
         :execution (with-connection-local-variables cmacs-transcode-execution))
   (if (eq kind 'video)
       (list :video-codec cmacs-transcode-video-codec
             :audio-codec cmacs-transcode-video-audio-codec
             :format cmacs-transcode-video-format
             :quality cmacs-transcode-quality
             :crf cmacs-transcode-crf
             :qp cmacs-transcode-qp
             :bitrate cmacs-transcode-bitrate
             :preset cmacs-transcode-preset
             :resolution cmacs-transcode-resolution
             :subtitles cmacs-transcode-subtitles
             :auto-quality cmacs-transcode-auto-quality
             :hwaccel cmacs-transcode-hwaccel
             :prefer-vulkan cmacs-transcode-prefer-vulkan
             :prefer-software cmacs-transcode-prefer-software
             :preserve-color cmacs-transcode-preserve-color-metadata
             :color-primaries cmacs-transcode-color-primaries
             :color-trc cmacs-transcode-color-trc
             :colorspace cmacs-transcode-colorspace
             :color-range cmacs-transcode-color-range)
     (list :audio-format cmacs-transcode-audio-format
           :audio-quality cmacs-transcode-audio-quality
           :audio-bitrate cmacs-transcode-audio-bitrate
           :input-format cmacs-transcode-audio-input-format))))

(defun cmacs-transcode--reseed (kind)
  "Reseed `cmacs-transcode--options' for KIND, keeping shared session keys."
  (let ((carry '()))
    (dolist (k '(:parallel :process-filter :overwrite :output-dir :execution
                 :recursive))
      (setq carry (plist-put carry k (plist-get cmacs-transcode--options k))))
    (setq cmacs-transcode--options
          (append carry (cmacs-transcode--default-options kind)))))

(defun cmacs-transcode--project-root ()
  "Return the project root for the current buffer, else `default-directory'."
  (or (and (fboundp 'project-current)
           (let ((p (project-current))) (and p (project-root p))))
      (and (fboundp 'vc-root-dir) (ignore-errors (vc-root-dir)))
      default-directory))

(defun cmacs-transcode--resolve-output-dir ()
  "Return the absolute output directory for this session."
  (file-name-as-directory
   (expand-file-name
    (or (plist-get cmacs-transcode--options :output-dir)
        (expand-file-name "output/" (cmacs-transcode--project-root))))))

(defun cmacs-transcode--output-for (in-file &optional subdir)
  "Return the output path for IN-FILE, optionally under relative SUBDIR."
  (let* ((dir (cmacs-transcode--resolve-output-dir))
         (base (file-name-base in-file))
         (ext (if (eq cmacs-transcode--kind 'video)
                  (plist-get cmacs-transcode--options :format)
                (let ((f (plist-get cmacs-transcode--options :audio-format)))
                  (if (equal f "vorbis") "ogg" f)))))
    (expand-file-name (concat base "." ext)
                      (if (and subdir (not (string-empty-p subdir)))
                          (expand-file-name subdir dir)
                        dir))))

;;; ---------------------------------------------------------------------
;;; Input expansion + enqueue
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--extensions ()
  "Return the input extension list for the current session kind."
  (if (eq cmacs-transcode--kind 'video)
      cmacs-transcode-video-extensions
    (let ((filt (plist-get cmacs-transcode--options :input-format)))
      (if (and filt (not (string-empty-p filt)))
          (list (downcase filt))
        cmacs-transcode-audio-extensions))))

(defun cmacs-transcode--media-file-p (file exts)
  "Non-nil if FILE is a regular file with an extension in EXTS."
  (and (file-regular-p file)
       (member (downcase (or (file-name-extension file) "")) exts)))

(defun cmacs-transcode--expand-input (path &optional recursive)
  "Return a list of (FILE . SUBDIR) media entries for PATH.
A file yields itself; a directory yields its media files (recursively
with RECURSIVE, preserving the relative subdir)."
  (let ((exts (cmacs-transcode--extensions)))
    (cond
     ((file-directory-p path)
      (let* ((base (file-name-as-directory (expand-file-name path)))
             (files (if recursive
                        (directory-files-recursively
                         base (concat "\\.\\(?:"
                                      (mapconcat #'regexp-quote exts "\\|")
                                      "\\)\\'")
                         nil)
                      (cl-remove-if-not
                       (lambda (f) (cmacs-transcode--media-file-p f exts))
                       (directory-files base t)))))
        (delq nil
              (mapcar
               (lambda (f)
                 (when (file-regular-p f)
                   (cons f (if recursive
                               (let ((rel (file-relative-name
                                           (file-name-directory f) base)))
                                 (if (member rel '("./" "" "."))
                                     ""
                                   (directory-file-name rel)))
                             ""))))
               files))))
     ((cmacs-transcode--media-file-p (expand-file-name path) exts)
      (list (cons (expand-file-name path) "")))
     (t (user-error "Not a %s file or directory: %s"
                    cmacs-transcode--kind path)))))

(defun cmacs-transcode--filter-status (out)
  "Return the initial job status for output OUT under the process filter."
  (pcase (plist-get cmacs-transcode--options :process-filter)
    ('missing (if (file-exists-p out) 'skipped 'queued))
    ('existing (if (file-exists-p out) 'queued 'skipped))
    (_ 'queued)))

(defun cmacs-transcode--enqueue-file (in-file &optional subdir)
  "Add IN-FILE (under relative SUBDIR) as a job unless already queued."
  (setq in-file (expand-file-name in-file))
  (unless (cl-find in-file cmacs-transcode--jobs
                   :key #'cmacs-transcode-job-input :test #'string=)
    (let ((out (cmacs-transcode--output-for in-file subdir)))
      (setq cmacs-transcode--jobs
            (append cmacs-transcode--jobs
                    (list (cmacs-transcode-job-create
                           :input in-file :output out :subdir subdir
                           :status (cmacs-transcode--filter-status out))))))))

(defun cmacs-transcode--recompute-outputs ()
  "Recompute outputs + filter status for all not-yet-running jobs."
  (dolist (j cmacs-transcode--jobs)
    (unless (memq (cmacs-transcode-job-status j) '(running done))
      (let ((out (cmacs-transcode--output-for
                  (cmacs-transcode-job-input j) (cmacs-transcode-job-subdir j))))
        (setf (cmacs-transcode-job-output j) out
              (cmacs-transcode-job-status j) (cmacs-transcode--filter-status out))))))

;;; ---------------------------------------------------------------------
;;; Logging + poll timer
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--log-buffer ()
  "Return the shared transcode log buffer, creating it in `special-mode'."
  (let ((buf (get-buffer-create "*cmacs-transcode-log*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode)))
    buf))

(defun cmacs-transcode--log (fmt &rest args)
  "Append a timestamped line (FMT ARGS) to the transcode log buffer."
  (let ((line (apply #'format fmt args)))
    (with-current-buffer (cmacs-transcode--log-buffer)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "%H:%M:%S ") line "\n")))))

(defun cmacs-transcode--start-timer (buffer)
  "Start the live-redraw poll timer for BUFFER (idempotent)."
  (cmacs-transcode--stop-timer buffer)
  (when (and cmacs-transcode-poll-interval (> cmacs-transcode-poll-interval 0))
    (with-current-buffer buffer
      (setq cmacs-transcode--timer
            (run-at-time cmacs-transcode-poll-interval
                         cmacs-transcode-poll-interval
                         (lambda ()
                           (if (buffer-live-p buffer)
                               (cmacs-transcode--render buffer)
                             (cmacs-transcode--stop-timer buffer))))))))

(defun cmacs-transcode--stop-timer (buffer)
  "Cancel BUFFER's poll timer."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (timerp cmacs-transcode--timer)
          (cancel-timer cmacs-transcode--timer)
          (setq cmacs-transcode--timer nil)))
    ;; buffer already gone: the timer closure self-cancels via this path
    (ignore)))

;;; ---------------------------------------------------------------------
;;; Bounded parallel pool
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--max-tries ()
  "Attempts allowed per job (video retries, audio once)."
  (if (eq cmacs-transcode--kind 'video) (max 1 cmacs-transcode-max-retries) 1))

(defun cmacs-transcode--make-filter (job)
  "Return a process filter that logs output and tracks JOB progress."
  (lambda (p chunk)
    (when (buffer-live-p (process-buffer p))
      (with-current-buffer (process-buffer p)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert chunk))))
    (dolist (ln (split-string chunk "[\r\n]+" t))
      (when (string-match-p "time=" ln)
        (setf (cmacs-transcode-job-progress job) (string-trim ln))))))

(defun cmacs-transcode--make-sentinel (buffer job)
  "Return a process sentinel finishing JOB and pumping BUFFER's pool."
  (lambda (p _event)
    (when (memq (process-status p) '(exit signal))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let* ((staged-out (cmacs-transcode-job-staged-output job))
                 (out (cmacs-transcode-job-output job))
                 (ok (and (eq (process-status p) 'exit)
                          (zerop (process-exit-status p))
                          (file-exists-p (or staged-out out)))))
            (cond
             ((cmacs-transcode-job-cancelled job)
              (cmacs-transcode--cleanup-staged job)
              (setf (cmacs-transcode-job-status job) 'failed
                    (cmacs-transcode-job-progress job) "killed")
              (cmacs-transcode--advance buffer))
             (ok
              (condition-case err
                  (progn
                    ;; Under `local' staging, publish the local output to its
                    ;; final (possibly remote) destination.
                    (when staged-out
                      (make-directory (file-name-directory out) t)
                      (copy-file staged-out out t))
                    (cmacs-transcode--cleanup-staged job)
                    (setf (cmacs-transcode-job-status job) 'done
                          (cmacs-transcode-job-progress job) "done")
                    (cmacs-transcode--log "done %s" (file-name-nondirectory out))
                    (cmacs-transcode--advance buffer))
                (error
                 (cmacs-transcode--cleanup-staged job)
                 (setf (cmacs-transcode-job-status job) 'failed
                       (cmacs-transcode-job-progress job) "copy-up failed"
                       (cmacs-transcode-job-note job) (error-message-string err))
                 (cmacs-transcode--log "FAILED copy-up %s: %s"
                                       (file-name-nondirectory out)
                                       (error-message-string err))
                 (cmacs-transcode--advance buffer))))
             ((< (cl-incf (cmacs-transcode-job-tries job))
                 (cmacs-transcode--max-tries))
              (cmacs-transcode--log
               "retry %s (attempt %d)"
               (file-name-nondirectory (cmacs-transcode-job-input job))
               (cmacs-transcode-job-tries job))
              (cmacs-transcode--spawn buffer job))
             (t
              (cmacs-transcode--cleanup-staged job)
              (setf (cmacs-transcode-job-status job) 'failed
                    (cmacs-transcode-job-progress job) "failed")
              (cmacs-transcode--log
               "FAILED %s (exit %s)"
               (file-name-nondirectory (cmacs-transcode-job-input job))
               (if (eq (process-status p) 'exit)
                   (process-exit-status p) "signal"))
              (cmacs-transcode--advance buffer)))
            (cmacs-transcode--render buffer)))))))

(defun cmacs-transcode--spawn (buffer job)
  "Launch (or relaunch) the ffmpeg process for JOB in BUFFER's session.
Runs on JOB's execution host: locally, or -- when the input is remote and
execution is `auto'/`remote' -- on that remote host over TRAMP
(`make-process :file-handler t', bound `default-directory').  Under `local'
execution a remote input is staged to a local temp first and the output
copied back on success.  Remote settings honour connection-local profiles."
  (with-current-buffer buffer
    (let* ((real-in (cmacs-transcode-job-input job))
           (real-out (cmacs-transcode-job-output job))
           (mode (cmacs-transcode--session-execution))
           (exec-dir (cmacs-transcode--exec-dir real-in mode))
           (stage (and (eq mode 'local) (file-remote-p real-in))))
      (setf (cmacs-transcode-job-exec-dir job) exec-dir)
      ;; local execution on a remote input: bring the input down and write the
      ;; output to a local temp, copied up on success.
      (when (and stage (not (cmacs-transcode-job-staged-input job)))
        (let ((tin (make-temp-file "cmacs-transcode-in-" nil
                                   (concat "." (or (file-name-extension real-in) "dat"))))
              (tout (make-temp-file "cmacs-transcode-out-" nil
                                    (concat "." (file-name-extension real-out)))))
          (cmacs-transcode--log "stage %s -> local" (file-name-nondirectory real-in))
          (copy-file real-in tin t)
          (delete-file tout)          ;keep only the name; ffmpeg -y writes it
          (setf (cmacs-transcode-job-staged-input job) tin
                (cmacs-transcode-job-staged-output job) tout)))
      (let* ((in (or (cmacs-transcode-job-staged-input job) real-in))
             (out (or (cmacs-transcode-job-staged-output job) real-out))
             (default-directory (or exec-dir default-directory)))
        (with-connection-local-variables
         (let* ((kind cmacs-transcode--backend)
                (opts cmacs-transcode--options)
                (media cmacs-transcode--kind)
                (remote (and exec-dir t))
                (io (cmacs-transcode--io kind in out))
                ;; Remote GPU auto-detection reads LOCAL device nodes, so a
                ;; remote job is software-only for v1 (explicit remote hwaccel
                ;; passthrough is a follow-on).
                (hw (if remote (cons 'none nil)
                      (and (eq media 'video)
                           (if (member (plist-get opts :video-codec) '("h264" "h265"))
                               (cmacs-transcode--hw-type opts)
                             (cons 'none nil)))))
                (meta (list :hw hw
                            :width (when (and (eq media 'video)
                                              (plist-get opts :auto-quality))
                                     (cmacs-transcode--probe-width kind in))
                            :color (when (and (eq media 'video)
                                              (plist-get opts :preserve-color)
                                              (not (cmacs-transcode--color-overridden-p opts)))
                                     (cmacs-transcode--probe-color kind in))))
                (fargs (if (eq media 'video)
                           (cmacs-transcode--video-args opts io meta)
                         (cmacs-transcode--audio-args opts io)))
                (cname (and (memq kind '(podman docker))
                            (cmacs-transcode--gen-container-name)))
                (cmd (cmacs-transcode--command kind 'ffmpeg io hw fargs cname))
                (process-environment
                 (if (and (eq kind 'host) (eq (car-safe hw) 'vulkan))
                     (append (cmacs-transcode--hw-host-env (cdr hw)) process-environment)
                   process-environment)))
           (make-directory (file-name-directory out) t)
           (setf (cmacs-transcode-job-status job) 'running
                 (cmacs-transcode-job-progress job) "starting"
                 (cmacs-transcode-job-container job) cname)
           (cmacs-transcode--log "start %s -> %s%s"
                                 (file-name-nondirectory real-in)
                                 (file-name-nondirectory real-out)
                                 (if remote (format " (on %s)" (file-remote-p exec-dir)) ""))
           (cmacs-transcode--log "  $ %s" (mapconcat #'identity cmd " "))
           (setf (cmacs-transcode-job-process job)
                 (make-process
                  :name (concat "cmacs-transcode:" (file-name-nondirectory real-in))
                  :buffer (cmacs-transcode--log-buffer)
                  :noquery t
                  :file-handler t
                  :command cmd
                  :filter (cmacs-transcode--make-filter job)
                  :sentinel (cmacs-transcode--make-sentinel buffer job)))
           (cmacs-transcode--render buffer)))))))

(defun cmacs-transcode--launch-next (buffer)
  "Pop and launch the next queued job in BUFFER, if any."
  (with-current-buffer buffer
    (when cmacs-transcode--queue
      (cmacs-transcode--spawn buffer (pop cmacs-transcode--queue)))))

(defun cmacs-transcode--advance (buffer)
  "Launch the next job, then check whether the session finished."
  (cmacs-transcode--launch-next buffer)
  (cmacs-transcode--maybe-finish buffer))

(defun cmacs-transcode--maybe-finish (buffer)
  "If BUFFER's pool is drained, stop the timer and report a summary."
  (with-current-buffer buffer
    (when (and (null cmacs-transcode--queue)
               (not (cl-some (lambda (j) (eq (cmacs-transcode-job-status j) 'running))
                             cmacs-transcode--jobs)))
      (cmacs-transcode--stop-timer buffer)
      (let ((done (cl-count 'done cmacs-transcode--jobs
                            :key #'cmacs-transcode-job-status))
            (failed (cl-count 'failed cmacs-transcode--jobs
                              :key #'cmacs-transcode-job-status))
            (skipped (cl-count 'skipped cmacs-transcode--jobs
                               :key #'cmacs-transcode-job-status)))
        (cmacs-transcode--log "session complete: %d done, %d failed, %d skipped"
                              done failed skipped)
        (cmacs-transcode--render buffer)
        (message "cmacs-transcode: %d done, %d failed, %d skipped"
                 done failed skipped)))))

(defun cmacs-transcode--run (buffer)
  "Start processing BUFFER's queued jobs with the configured concurrency."
  (with-current-buffer buffer
    (let* ((queued (cl-remove-if-not
                    (lambda (j) (eq (cmacs-transcode-job-status j) 'queued))
                    cmacs-transcode--jobs))
           (n (max 1 (or (plist-get cmacs-transcode--options :parallel) 1))))
      (setq cmacs-transcode--queue queued)
      (cmacs-transcode--start-timer buffer)
      (dotimes (_ (min n (length queued)))
        (cmacs-transcode--launch-next buffer))
      (cmacs-transcode--render buffer))))

(defun cmacs-transcode--cleanup-staged (job)
  "Delete JOB's local staging temp files (`local'-execution mode), if any."
  (dolist (f (list (cmacs-transcode-job-staged-input job)
                   (cmacs-transcode-job-staged-output job)))
    (when (and f (file-exists-p f)) (ignore-errors (delete-file f))))
  (setf (cmacs-transcode-job-staged-input job) nil
        (cmacs-transcode-job-staged-output job) nil))

(defun cmacs-transcode--force-kill-job (job)
  "Forcibly stop JOB's ffmpeg, including a container backend's container.
SIGKILL to a podman/docker client does not reach ffmpeg running inside the
container (conmon keeps it alive), so the container is force-removed by name
with `<runtime> rm -f'; the client process is also SIGKILLed.  The `rm -f'
runs on the job's execution host (remote via TRAMP when the job is remote)."
  (let ((proc (cmacs-transcode-job-process job))
        (cname (cmacs-transcode-job-container job))
        (default-directory (or (cmacs-transcode-job-exec-dir job) default-directory)))
    (when (and cname (memq cmacs-transcode--backend '(podman docker)))
      ;; `process-file' runs on the execution host; destination 0 = async /
      ;; discard output, so a slow `rm -f' never blocks the UI.
      (ignore-errors
        (process-file (symbol-name cmacs-transcode--backend) nil 0 nil
                      "rm" "-f" cname)))
    (when (process-live-p proc)
      (ignore-errors (signal-process proc 9)) ; SIGKILL the client too
      (ignore-errors (delete-process proc)))
    (cmacs-transcode--cleanup-staged job)))

;;; ---------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--truncate (s n)
  "Truncate string S to at most N characters with an ellipsis."
  (if (> (length s) n) (concat (substring s 0 (1- n)) "…") s))

(defun cmacs-transcode--status-icon (status)
  "Return a glyph for job STATUS."
  (pcase status
    ('queued "…") ('running "▶") ('done "✔") ('failed "✗") ('skipped "–")
    (_ "?")))

(defun cmacs-transcode--hwaccel-label (o)
  "Return a short hwaccel label string for options plist O."
  (cond ((eq (plist-get o :hwaccel) 'off) "off")
        ((plist-get o :prefer-vulkan) "vulkan")
        ((eq (plist-get o :hwaccel) 'force) "vaapi!")
        (t "vaapi")))

(defun cmacs-transcode--header-lines ()
  "Return the header lines for the current session as a list of strings."
  (let* ((o cmacs-transcode--options)
         (kind cmacs-transcode--kind)
         (par (or (plist-get o :parallel) 1))
         (backend (or cmacs-transcode--backend (cmacs-transcode--resolve t) 'none))
         (exec (cmacs-transcode--session-execution))
         (host (file-remote-p default-directory 'host))
         (exec-label (pcase exec
                       ('local "local")
                       ('remote (concat "remote" (if host (concat "@" host) "")))
                       (_ (if host (concat "auto@" host) "auto")))))
    (list
     (format " cmacs-transcode — %s" (upcase (symbol-name kind)))
     (if (eq kind 'video)
         (format " backend:%s  parallel:%s  crf:%s  codec:%s  fmt:%s  hwaccel:%s%s"
                 backend (if (> par 1) par "OFF")
                 (or (plist-get o :crf)
                     (format "preset:%s" (plist-get o :quality)))
                 (plist-get o :video-codec) (plist-get o :format)
                 (cmacs-transcode--hwaccel-label o)
                 (if (plist-get o :recursive) "  recursive" ""))
       (format " backend:%s  parallel:%s  fmt:%s  quality:%s%s"
               backend (if (> par 1) par "OFF")
               (plist-get o :audio-format)
               (or (plist-get o :audio-bitrate) (plist-get o :audio-quality))
               (if (plist-get o :recursive) "  recursive" "")))
     (format " output:%s%s  exec:%s"
             (abbreviate-file-name (cmacs-transcode--resolve-output-dir))
             (pcase (plist-get o :process-filter)
               ('missing "  [only-missing]")
               ('existing "  [only-existing]")
               (_ ""))
             exec-label))))

(defun cmacs-transcode--job-line (i n job)
  "Return a propertized status line for JOB (index I of N)."
  (let* ((st (cmacs-transcode-job-status job))
         (line (format " [%d/%d] %s  %-42s  %s"
                       i n (cmacs-transcode--status-icon st)
                       (cmacs-transcode--truncate
                        (file-name-nondirectory (cmacs-transcode-job-input job)) 42)
                       (pcase st
                         ('running (cmacs-transcode-job-progress job))
                         ('done "done")
                         ('failed (or (cmacs-transcode-job-note job) "failed"))
                         ('skipped "skipped")
                         (_ "queued")))))
    (propertize line 'cmacs-transcode-job job)))

(defconst cmacs-transcode--hint-lines
  '(" hjkl:move  a:add  A:add-dir  d:del  K:kill  RET:start"
    " p:parallel P:jobs  c:codec Q:crf/bitrate f:format H:hwaccel  o:out"
    " m:missing x:existing  R:recursive  M:kind  E:exec(local/remote)  L:log  g:refresh  q:quit  ?:help")
  "Key hint lines shown at the bottom of the queue buffer.")

(defun cmacs-transcode--render (buffer)
  "Redraw the queue BUFFER from session state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (line (line-number-at-pos)))
        (erase-buffer)
        (dolist (h (cmacs-transcode--header-lines)) (insert h "\n"))
        (insert (make-string 64 ?─) "\n")
        (if (null cmacs-transcode--jobs)
            (insert "\n  (no files queued — press `a' to add media)\n")
          (let ((i 0) (n (length cmacs-transcode--jobs)))
            (dolist (job cmacs-transcode--jobs)
              (insert (cmacs-transcode--job-line (cl-incf i) n job) "\n"))))
        (insert "\n")
        (dolist (h cmacs-transcode--hint-lines) (insert h "\n"))
        (goto-char (point-min))
        (forward-line (1- line))))))

;;; ---------------------------------------------------------------------
;;; Mode + keymap
;;; ---------------------------------------------------------------------

(defvar cmacs-transcode-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-transcode-mode'.")

;; Bind on every load (reload-safe; the defvar above is a no-op once bound).
(let ((map cmacs-transcode-mode-map))
  ;; hjkl + arrow navigation.  The mode map is made an Evil overriding map
  ;; below, so under Doom/Evil the motion keys must be bound here explicitly
  ;; (and the action commands avoid h/j/k/l -- kill is `K', log is `L').
  (define-key map (kbd "j") #'next-line)
  (define-key map (kbd "k") #'previous-line)
  (define-key map (kbd "h") #'backward-char)
  (define-key map (kbd "l") #'forward-char)
  (define-key map (kbd "a") #'cmacs-transcode-add)
  (define-key map (kbd "A") #'cmacs-transcode-add-directory)
  (define-key map (kbd "d") #'cmacs-transcode-remove)
  (define-key map (kbd "K") #'cmacs-transcode-kill)
  (define-key map (kbd "RET") #'cmacs-transcode-start)
  (define-key map (kbd "p") #'cmacs-transcode-toggle-parallel)
  (define-key map (kbd "P") #'cmacs-transcode-set-parallel)
  (define-key map (kbd "c") #'cmacs-transcode-set-codec)
  (define-key map (kbd "Q") #'cmacs-transcode-set-quality)
  (define-key map (kbd "f") #'cmacs-transcode-set-format)
  (define-key map (kbd "H") #'cmacs-transcode-cycle-hwaccel)
  (define-key map (kbd "o") #'cmacs-transcode-set-output-dir)
  (define-key map (kbd "m") #'cmacs-transcode-toggle-missing)
  (define-key map (kbd "x") #'cmacs-transcode-toggle-existing)
  (define-key map (kbd "R") #'cmacs-transcode-toggle-recursive)
  (define-key map (kbd "M") #'cmacs-transcode-set-kind)
  (define-key map (kbd "E") #'cmacs-transcode-cycle-execution)
  (define-key map (kbd "L") #'cmacs-transcode-show-log)
  (define-key map (kbd "g") #'cmacs-transcode-refresh)
  (define-key map (kbd "q") #'quit-window)
  (define-key map (kbd "?") #'cmacs-transcode-help))

(defun cmacs-transcode--cleanup ()
  "Kill-buffer hook: cancel the timer and force-stop running jobs.
Container jobs are removed by name so closing the buffer never orphans
ffmpeg inside a container."
  (when (timerp cmacs-transcode--timer) (cancel-timer cmacs-transcode--timer))
  (dolist (j cmacs-transcode--jobs)
    (when (or (eq (cmacs-transcode-job-status j) 'running)
              (process-live-p (cmacs-transcode-job-process j)))
      (setf (cmacs-transcode-job-cancelled j) t)
      (cmacs-transcode--force-kill-job j))))

(define-derived-mode cmacs-transcode-mode special-mode "Transcode"
  "Major mode for the cmacs media transcoder queue.
\\{cmacs-transcode-mode-map}"
  (buffer-disable-undo)
  (setq-local cmacs-transcode--kind (or cmacs-transcode--kind 'video))
  (setq-local cmacs-transcode--options
              (or cmacs-transcode--options
                  (cmacs-transcode--default-options cmacs-transcode--kind)))
  (add-hook 'kill-buffer-hook #'cmacs-transcode--cleanup nil t))

(defun cmacs-transcode--ensure-mode ()
  "Signal unless the current buffer is a transcode queue buffer."
  (unless (derived-mode-p 'cmacs-transcode-mode)
    (user-error "Not in a cmacs-transcode buffer")))

;;; ---------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--read-inputs ()
  "Return input files: dired marks, else a single prompted file/dir (or nil)."
  (cond
   ((derived-mode-p 'dired-mode) (dired-get-marked-files))
   (t (let ((p (read-file-name
                "Transcode file or directory (empty to add later): "
                nil "" t)))
        (and p (not (string-empty-p p)) (list p))))))

(defun cmacs-transcode--open (kind files)
  "Open (or reuse) the queue buffer for KIND, adding FILES, and switch to it.
Displays the queue in the current window rather than a new split."
  (let ((dir default-directory)
        (buf (get-buffer-create "*cmacs-transcode*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-transcode-mode)
        (setq default-directory dir)
        (cmacs-transcode-mode))
      (when (and kind (not (eq kind cmacs-transcode--kind)))
        (setq cmacs-transcode--kind kind)
        (cmacs-transcode--reseed kind)
        (cmacs-transcode--recompute-outputs))
      (dolist (f files)
        (dolist (e (cmacs-transcode--expand-input
                    f (plist-get cmacs-transcode--options :recursive)))
          (cmacs-transcode--enqueue-file (car e) (cdr e))))
      (cmacs-transcode--render buf))
    (switch-to-buffer buf)))

;;;###autoload
(defun cmacs-transcode ()
  "Open the cmacs media transcoder queue buffer."
  (interactive)
  (cmacs-transcode--open nil nil))

;;;###autoload
(defun cmacs-transcode-video (&optional files)
  "Open the transcoder on FILES as a video session.
Interactively, uses the marked files in dired or prompts for a file/dir."
  (interactive (list (cmacs-transcode--read-inputs)))
  (cmacs-transcode--open 'video files))

;;;###autoload
(defun cmacs-transcode-audio (&optional files)
  "Open the transcoder on FILES as an audio session.
Interactively, uses the marked files in dired or prompts for a file/dir."
  (interactive (list (cmacs-transcode--read-inputs)))
  (cmacs-transcode--open 'audio files))

;;; ---------------------------------------------------------------------
;;; Queue-buffer commands
;;; ---------------------------------------------------------------------

(defun cmacs-transcode--empty-add-hint (path rec entries)
  "Return a diagnostic string for why adding directory PATH queued nothing.
REC is whether the add recursed; ENTRIES is what the current kind matched.
Diagnoses the two common causes: recursion off with nested files, and the
wrong session kind (e.g. a directory of .flac in a video session)."
  (let* ((kind cmacs-transcode--kind)
         (other (if (eq kind 'video) 'audio 'video))
         ;; Would recursion under the CURRENT kind have found anything?
         (rec-n (if rec (length entries)
                  (ignore-errors (length (cmacs-transcode--expand-input path t)))))
         ;; Are there files of the OTHER kind here (searched recursively)?
         (other-n (let ((cmacs-transcode--kind other))
                    (ignore-errors (length (cmacs-transcode--expand-input path t))))))
    (concat
     (format "no %s files added from %s" kind
             (abbreviate-file-name (directory-file-name path)))
     (cond ((and (not rec) rec-n (> rec-n 0))
            (format " — %d are in subdirs; press R (or A) to recurse" rec-n))
           ((and other-n (> other-n 0))
            (format " — but %d %s file(s) are here; press M to switch to %s"
                    other-n other other))
           (t "")))))

(defun cmacs-transcode-add (path &optional recursive)
  "Add media file or directory PATH to the queue.
Directories recurse when RECURSIVE (the prefix argument) is non-nil or the
session recursive setting is on (toggle it with `R')."
  (interactive (list (read-file-name "Add media file or directory: " nil nil t)
                     current-prefix-arg))
  (cmacs-transcode--ensure-mode)
  (let* ((rec (or recursive (plist-get cmacs-transcode--options :recursive)))
         (entries (cmacs-transcode--expand-input path rec))
         (before (length cmacs-transcode--jobs)))
    (dolist (e entries) (cmacs-transcode--enqueue-file (car e) (cdr e)))
    (cmacs-transcode--render (current-buffer))
    (let ((added (- (length cmacs-transcode--jobs) before)))
      (cond
       ((> added 0)
        (message "cmacs-transcode: added %d %s file(s)%s"
                 added cmacs-transcode--kind (if rec " (recursive)" "")))
       ;; A directory that matched nothing: explain why (wrong kind / no recurse).
       ((and (file-directory-p path) (null entries))
        (message "cmacs-transcode: %s"
                 (cmacs-transcode--empty-add-hint path rec entries)))
       (t (message "cmacs-transcode: added 0 (%d already queued)"
                   (length entries)))))))

(defun cmacs-transcode-add-directory (dir)
  "Add all media files under directory DIR (recursively) to the queue.
Recurses regardless of the session recursive setting.  Matches only the
current session kind's extensions, so switch to audio with `M' (or open with
`\\[cmacs-transcode-audio]') before adding a music-library directory."
  (interactive (list (read-directory-name "Add directory (recursive): ")))
  (cmacs-transcode-add dir t))

(defun cmacs-transcode--job-at-point ()
  "Return the job on the current line, or nil."
  (get-text-property (line-beginning-position) 'cmacs-transcode-job))

(defun cmacs-transcode-remove ()
  "Remove the job on the current line from the queue."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((job (cmacs-transcode--job-at-point)))
    (cond
     ((null job) (user-error "No job on this line"))
     ((eq (cmacs-transcode-job-status job) 'running)
      (user-error "Job is running; press `k' to kill it first"))
     (t (setq cmacs-transcode--jobs (delq job cmacs-transcode--jobs))
        (cmacs-transcode--render (current-buffer))))))

(defun cmacs-transcode-kill ()
  "Kill the running job on the current line (SIGKILL, no retry).
For a container backend this force-removes the container, so ffmpeg
running inside it is actually stopped."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((job (cmacs-transcode--job-at-point)))
    (if (and job (or (eq (cmacs-transcode-job-status job) 'running)
                     (process-live-p (cmacs-transcode-job-process job))))
        (progn (setf (cmacs-transcode-job-cancelled job) t
                     (cmacs-transcode-job-note job) "killed")
               (cmacs-transcode--force-kill-job job)
               (cmacs-transcode--log
                "killed %s"
                (file-name-nondirectory (cmacs-transcode-job-input job))))
      (user-error "No running job on this line"))))

(defun cmacs-transcode-start ()
  "Begin transcoding the queued jobs."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((queued (cl-find-if (lambda (j) (eq (cmacs-transcode-job-status j) 'queued))
                            cmacs-transcode--jobs)))
    (unless queued (user-error "No queued jobs to transcode"))
    ;; Resolve the backend on the execution host (remote when the input is
    ;; remote and execution is auto/remote); `--exec-dir' also validates
    ;; execution=remote against a local input.
    (let* ((mode (cmacs-transcode--session-execution))
           (exec-dir (cmacs-transcode--exec-dir (cmacs-transcode-job-input queued) mode))
           (default-directory (or exec-dir default-directory)))
      (setq cmacs-transcode--backend
            (with-connection-local-variables (cmacs-transcode--resolve)))
      (cmacs-transcode--log "run: backend=%s parallel=%d kind=%s exec=%s%s"
                            cmacs-transcode--backend
                            (max 1 (or (plist-get cmacs-transcode--options :parallel) 1))
                            cmacs-transcode--kind mode
                            (if exec-dir (format " (%s)" (file-remote-p exec-dir)) ""))
      (cmacs-transcode--run (current-buffer)))))

(defun cmacs-transcode-toggle-parallel ()
  "Toggle parallelism between sequential and the configured job count."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((cur (or (plist-get cmacs-transcode--options :parallel) 1)))
    (setq cmacs-transcode--options
          (plist-put cmacs-transcode--options :parallel
                     (if (> cur 1) 1
                       (if (> cmacs-transcode-parallel-jobs 1)
                           cmacs-transcode-parallel-jobs
                         (max 2 (read-number "Parallel jobs: " 4))))))
    (cmacs-transcode--render (current-buffer))))

(defun cmacs-transcode-set-parallel (n)
  "Set the number N of concurrent jobs."
  (interactive "nParallel jobs: ")
  (cmacs-transcode--ensure-mode)
  (setq cmacs-transcode--options
        (plist-put cmacs-transcode--options :parallel (max 1 n)))
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-set-codec ()
  "Set the video codec (or, in audio sessions, the audio format/codec)."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (if (eq cmacs-transcode--kind 'video)
      (setq cmacs-transcode--options
            (plist-put cmacs-transcode--options :video-codec
                       (completing-read
                        "Video codec: "
                        (mapcar #'car cmacs-transcode-video-codec-map) nil t)))
    (setq cmacs-transcode--options
          (plist-put cmacs-transcode--options :audio-format
                     (completing-read
                      "Audio codec/format: "
                      (mapcar #'car cmacs-transcode-audio-codec-map) nil t)))
    (cmacs-transcode--recompute-outputs))
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-set-quality ()
  "Set the CRF (video) or the custom bitrate (audio)."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (if (eq cmacs-transcode--kind 'video)
      (setq cmacs-transcode--options
            (plist-put cmacs-transcode--options :crf
                       (read-number "CRF (0-51, lower = better): "
                                    (or (plist-get cmacs-transcode--options :crf) 26))))
    (let ((b (read-string "Audio bitrate (e.g. 320k, empty = preset): "
                          (or (plist-get cmacs-transcode--options :audio-bitrate) ""))))
      (setq cmacs-transcode--options
            (plist-put cmacs-transcode--options :audio-bitrate
                       (and (not (string-empty-p b)) b)))))
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-set-format ()
  "Set the output container/format."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let* ((video (eq cmacs-transcode--kind 'video))
         (choices (if video '("mkv" "mp4" "webm")
                    (mapcar #'car cmacs-transcode-audio-codec-map)))
         (key (if video :format :audio-format)))
    (setq cmacs-transcode--options
          (plist-put cmacs-transcode--options key
                     (completing-read "Format: " choices nil t)))
    (cmacs-transcode--recompute-outputs)
    (cmacs-transcode--render (current-buffer))))

(defun cmacs-transcode-cycle-hwaccel ()
  "Cycle the video hwaccel state off -> auto -> force -> vulkan -> off."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (unless (eq cmacs-transcode--kind 'video)
    (user-error "Hardware acceleration applies to video only"))
  (let* ((o cmacs-transcode--options)
         (state (cond ((eq (plist-get o :hwaccel) 'off) 'off)
                      ((plist-get o :prefer-vulkan) 'vulkan)
                      ((eq (plist-get o :hwaccel) 'force) 'force)
                      (t 'auto)))
         (next (pcase state ('off 'auto) ('auto 'force)
                       ('force 'vulkan) ('vulkan 'off))))
    (setq o (plist-put o :prefer-vulkan (eq next 'vulkan)))
    (setq o (plist-put o :hwaccel (pcase next
                                    ('off 'off) ('force 'force) (_ 'auto))))
    (setq cmacs-transcode--options o)
    (cmacs-transcode--render (current-buffer))))

(defun cmacs-transcode-set-output-dir (dir)
  "Set the session output directory to DIR."
  (interactive (list (read-directory-name
                      "Output directory: " (cmacs-transcode--resolve-output-dir))))
  (cmacs-transcode--ensure-mode)
  (setq cmacs-transcode--options (plist-put cmacs-transcode--options :output-dir dir))
  (cmacs-transcode--recompute-outputs)
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-cycle-execution ()
  "Cycle where ffmpeg runs: auto -> local -> remote -> auto.
`auto' follows the input's host (remote files transcode on the remote
host); `local' forces the local machine (copying a remote input down);
`remote' forces the input's remote host."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((next (pcase (cmacs-transcode--session-execution)
                ('auto 'local) ('local 'remote) (_ 'auto))))
    (setq cmacs-transcode--options (plist-put cmacs-transcode--options :execution next))
    (cmacs-transcode--render (current-buffer))
    (message "cmacs-transcode: execution = %s" next)))

(defun cmacs-transcode-toggle-missing ()
  "Toggle the process-missing filter (only encode files without an output)."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (setq cmacs-transcode--options
        (plist-put cmacs-transcode--options :process-filter
                   (if (eq (plist-get cmacs-transcode--options :process-filter) 'missing)
                       nil 'missing)))
  (cmacs-transcode--recompute-outputs)
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-toggle-existing ()
  "Toggle the process-existing filter (only re-encode files with an output)."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (setq cmacs-transcode--options
        (plist-put cmacs-transcode--options :process-filter
                   (if (eq (plist-get cmacs-transcode--options :process-filter) 'existing)
                       nil 'existing)))
  (cmacs-transcode--recompute-outputs)
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-toggle-recursive ()
  "Toggle recursive directory-mirroring for directories added from here on.
When on, adding a directory searches it recursively and mirrors its
subdirectory tree under the output directory.  Recursion happens at add
time, so this only affects directories added after toggling."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((on (not (plist-get cmacs-transcode--options :recursive))))
    (setq cmacs-transcode--options
          (plist-put cmacs-transcode--options :recursive on))
    (cmacs-transcode--render (current-buffer))
    (message "cmacs-transcode: recursive adds %s%s"
             (if on "ON" "OFF")
             (if on " (mirrors subdir tree; affects subsequent adds)" ""))))

(defun cmacs-transcode-set-kind ()
  "Switch the session between video and audio media kinds."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (let ((k (intern (completing-read "Media kind: " '("video" "audio") nil t
                                    (symbol-name cmacs-transcode--kind)))))
    (unless (eq k cmacs-transcode--kind)
      (setq cmacs-transcode--kind k)
      (cmacs-transcode--reseed k)
      (cmacs-transcode--recompute-outputs)
      (cmacs-transcode--render (current-buffer)))))

(defun cmacs-transcode-show-log ()
  "Display the transcode log buffer."
  (interactive)
  (display-buffer (cmacs-transcode--log-buffer)))

(defun cmacs-transcode-refresh ()
  "Redraw the queue buffer."
  (interactive)
  (cmacs-transcode--ensure-mode)
  (cmacs-transcode--render (current-buffer)))

(defun cmacs-transcode-help ()
  "Describe the transcode queue keybindings."
  (interactive)
  (message
   "%s"
   (mapconcat #'string-trim cmacs-transcode--hint-lines "  |  ")))

;; Under Evil (Doom) the state maps shadow single-key bindings; give this
;; mode's map precedence in every state.
(with-eval-after-load 'evil
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map cmacs-transcode-mode-map)))

(provide 'cmacs-transcode)
;;; cmacs-transcode.el ends here
