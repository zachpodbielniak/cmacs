;;; cmacs-transcode-tests.el --- Tests for the native transcoder -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-transcode'.  The ffmpeg argument builders, backend
;; command assembly, path mapping, and output-filename logic are pure
;; functions, so these tests need no real ffmpeg/podman -- they run in any
;; build where cmacs-transcode.el loaded.

;;; Code:

(require 'ert)
(require 'cmacs-transcode nil t)

(defmacro cmacs-transcode-tests--skip-unless-loaded ()
  "Skip the test unless `cmacs-transcode' loaded."
  '(skip-unless (featurep 'cmacs-transcode)))

;;; ---------------------------------------------------------------------
;;; Video argument builder
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-video-default ()
  "Default video opts reproduce the --no-hwaccel --crf 26 h265/vorbis/mkv run."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:video-codec "h265" :audio-codec "vorbis" :format "mkv"
                :quality "medium" :crf 26 :overwrite t :subtitles t
                :preserve-color nil))
        (io '(:in "/in/a.mp4" :out "/out/a.mkv" :same nil)))
    (should (equal (cmacs-transcode--video-args opts io '(:hw (none)))
                   '("-y" "-i" "/in/a.mp4" "-c:v" "libx265" "-crf" "26"
                     "-c:a" "libvorbis" "-q:a" "4"
                     "-map" "0:v" "-map" "0:a?" "-map" "0:s?" "-c:s" "copy"
                     "/out/a.mkv")))))

(ert-deftest cmacs-transcode-test-video-no-subtitles-webm ()
  "webm output and disabled subtitles omit the subtitle mapping."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:video-codec "vp9" :audio-codec "opus" :format "webm"
                :crf 30 :overwrite nil :subtitles nil :preserve-color nil
                :resolution "1280x720"))
        (io '(:in "/in/a.mkv" :out "/out/a.webm" :same nil)))
    (should (equal (cmacs-transcode--video-args opts io '(:hw (none)))
                   '("-i" "/in/a.mkv" "-c:v" "libvpx-vp9" "-vf" "scale=1280x720"
                     "-crf" "30" "-c:a" "libopus" "-b:a" "128k"
                     "-map" "0:v" "-map" "0:a?" "/out/a.webm")))))

(ert-deftest cmacs-transcode-test-video-quality-preset ()
  "A nil CRF falls back to the named quality preset."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:video-codec "h264" :audio-codec "copy" :format "mp4"
                :quality "high" :crf nil :overwrite t :subtitles nil
                :preserve-color nil))
        (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil)))
    (should (member "-crf" (cmacs-transcode--video-args opts io '(:hw (none)))))
    (should (member "18"                 ; high => CRF 18
                    (cmacs-transcode--video-args opts io '(:hw (none)))))
    (should (member "copy"
                    (cmacs-transcode--video-args opts io '(:hw (none)))))))

(ert-deftest cmacs-transcode-test-video-vaapi ()
  "VAAPI uses the hevc_vaapi encoder + hwupload filter + device init."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:video-codec "h265" :audio-codec "aac" :format "mp4"
                :crf 26 :overwrite t :subtitles nil :preserve-color nil))
        (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil)))
    (should (equal (cmacs-transcode--video-args opts io '(:hw (vaapi)))
                   '("-y" "-vaapi_device" "/dev/dri/renderD128" "-i" "/in/a.mp4"
                     "-c:v" "hevc_vaapi" "-vf" "format=nv12|vaapi,hwupload"
                     "-crf" "26" "-c:a" "aac"
                     "-map" "0:v" "-map" "0:a?" "/out/a.mp4")))))

(ert-deftest cmacs-transcode-test-video-vaapi-qp ()
  "VAAPI with a QP value emits -qp instead of -crf."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h264" :audio-codec "aac" :format "mp4"
                 :qp 24 :overwrite t :subtitles nil :preserve-color nil))
         (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil))
         (args (cmacs-transcode--video-args opts io '(:hw (vaapi)))))
    (should (member "-qp" args))
    (should (member "24" args))
    (should-not (member "-crf" args))
    (should (member "h264_vaapi" args))))

(ert-deftest cmacs-transcode-test-video-vulkan ()
  "Vulkan uses hevc_vulkan + a bitrate from the quality preset."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h265" :audio-codec "aac" :format "mp4"
                 :quality "high" :crf 26 :overwrite t :subtitles nil
                 :preserve-color nil))
         (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil))
         (args (cmacs-transcode--video-args opts io '(:hw (vulkan . "intel")))))
    (should (member "hevc_vulkan" args))
    (should (member "-init_hw_device" args))
    (should (member "-b:v" args))
    (should (member "10M" args))          ; high => 10M
    (should-not (member "-crf" args))))

(ert-deftest cmacs-transcode-test-video-color-probed ()
  "Preserved colour metadata emits colour flags and x265-params for sw h265."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h265" :audio-codec "vorbis" :format "mkv"
                 :crf 26 :overwrite t :subtitles nil :preserve-color t))
         (io '(:in "/in/a.mp4" :out "/out/a.mkv" :same nil))
         (args (cmacs-transcode--video-args
                opts io '(:hw (none) :color ("bt709" "bt709" "bt709" "tv")))))
    (should (member "-color_primaries" args))
    (should (member "bt709" args))
    (should (member "-color_range" args))
    (should (member "tv" args))
    (should (member "-x265-params" args))
    (should (member "colorprim=bt709:transfer=bt709:colormatrix=bt709" args))))

(ert-deftest cmacs-transcode-test-video-color-override ()
  "Explicit colour overrides take precedence over probed metadata."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h264" :audio-codec "aac" :format "mp4"
                 :crf 26 :overwrite t :subtitles nil :preserve-color t
                 :color-primaries "bt2020"))
         (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil))
         (args (cmacs-transcode--video-args
                opts io '(:hw (none) :color ("bt709" "bt709" "bt709" "tv")))))
    (should (member "bt2020" args))       ; override wins
    (should-not (member "bt709" args))    ; probed ignored when any override set
    (should-not (member "-x265-params" args)))) ; x265-params only for h265

(ert-deftest cmacs-transcode-test-video-bitrate ()
  "An explicit bitrate overrides CRF/QP."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h265" :audio-codec "aac" :format "mp4"
                 :crf 26 :bitrate "8M" :overwrite t :subtitles nil
                 :preserve-color nil))
         (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil))
         (args (cmacs-transcode--video-args opts io '(:hw (none)))))
    (should (member "-b:v" args))
    (should (member "8M" args))
    (should-not (member "-crf" args))))

(ert-deftest cmacs-transcode-test-video-auto-quality ()
  "Auto-quality picks a CRF from the probed width."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:video-codec "h265" :audio-codec "aac" :format "mp4"
                 :auto-quality t :crf nil :overwrite t :subtitles nil
                 :preserve-color nil))
         (io '(:in "/in/a.mp4" :out "/out/a.mp4" :same nil))
         (args (cmacs-transcode--video-args opts io '(:hw (none) :width 3840))))
    (should (member "-crf" args))
    (should (member "28" args))))          ; width > 1920 => CRF 28

;;; ---------------------------------------------------------------------
;;; Audio argument builder
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-audio-mp3 ()
  "Default audio opts produce a 320k MP3 (high preset)."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:audio-format "mp3" :audio-quality "high" :overwrite t))
        (io '(:in "/in/a.wav" :out "/out/a.mp3" :same nil)))
    (should (equal (cmacs-transcode--audio-args opts io)
                   '("-y" "-i" "/in/a.wav" "-c:a" "libmp3lame" "-b:a" "320k"
                     "-vn" "-map" "0:a" "-map_metadata" "0" "/out/a.mp3")))))

(ert-deftest cmacs-transcode-test-audio-ogg ()
  "OGG output uses the Vorbis quality scale."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((opts '(:audio-format "ogg" :audio-quality "high" :overwrite t))
        (io '(:in "/in/a.flac" :out "/out/a.ogg" :same nil)))
    (should (equal (cmacs-transcode--audio-args opts io)
                   '("-y" "-i" "/in/a.flac" "-c:a" "libvorbis" "-q:a" "7"
                     "-vn" "-map" "0:a" "-map_metadata" "0" "/out/a.ogg")))))

(ert-deftest cmacs-transcode-test-audio-custom-bitrate ()
  "A custom bitrate overrides the preset."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((opts '(:audio-format "mp3" :audio-quality "high"
                 :audio-bitrate "256k" :overwrite nil))
         (io '(:in "/in/a.wav" :out "/out/a.mp3" :same nil))
         (args (cmacs-transcode--audio-args opts io)))
    (should (member "256k" args))
    (should-not (member "320k" args))
    (should-not (member "-y" args))))

(ert-deftest cmacs-transcode-test-audio-flac-opus-aac ()
  "flac/opus/aac map to the right encoders."
  (cmacs-transcode-tests--skip-unless-loaded)
  (dolist (case '(("flac" "flac") ("opus" "libopus") ("aac" "aac")))
    (let* ((opts (list :audio-format (car case) :audio-quality "high" :overwrite t))
           (io '(:in "/in/a.wav" :out "/out/a.x" :same nil))
           (args (cmacs-transcode--audio-args opts io)))
      (should (member (cadr case) args)))))

;;; ---------------------------------------------------------------------
;;; Path mapping + command assembly
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-io-host ()
  "Host IO keeps real paths."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((io (cmacs-transcode--io 'host "/media/a.mp4" "/out/a.mkv")))
    (should (equal (plist-get io :in) "/media/a.mp4"))
    (should (equal (plist-get io :out) "/out/a.mkv"))
    (should-not (plist-get io :same))))

(ert-deftest cmacs-transcode-test-io-container-diff ()
  "Container IO with distinct dirs maps to /input and /output."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((io (cmacs-transcode--io 'podman "/media/x/a.mp4" "/media/out/a.mkv")))
    (should (equal (plist-get io :in) "/input/a.mp4"))
    (should (equal (plist-get io :out) "/output/a.mkv"))
    (should-not (plist-get io :same))))

(ert-deftest cmacs-transcode-test-io-container-same ()
  "Container IO with a shared dir maps both sides to /config."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((io (cmacs-transcode--io 'docker "/media/a.mp4" "/media/a.mkv")))
    (should (equal (plist-get io :in) "/config/a.mp4"))
    (should (equal (plist-get io :out) "/config/a.mkv"))
    (should (plist-get io :same))))

(ert-deftest cmacs-transcode-test-command-podman ()
  "The podman command mounts both dirs and appends the ffmpeg args."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((io (cmacs-transcode--io 'podman "/media/x/a.mp4" "/media/out/a.mkv"))
         (cmd (cmacs-transcode--command
               'podman 'ffmpeg io nil '("-i" "/input/a.mp4" "/output/a.mkv"))))
    (should (equal (seq-take cmd 5)
                   '("podman" "run" "--rm" "--security-opt" "label=disable")))
    (should (member "/media/x:/input:z" cmd))
    (should (member "/media/out:/output:z" cmd))
    (should (member "docker.io/linuxserver/ffmpeg:latest" cmd))
    (should (equal (last cmd 3) '("-i" "/input/a.mp4" "/output/a.mkv")))
    (should-not (member "--entrypoint" cmd))))

(ert-deftest cmacs-transcode-test-command-name ()
  "A container name is threaded through as --name for later force-removal."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((io (cmacs-transcode--io 'podman "/media/a.mp4" "/media/a.mkv"))
         (cmd (cmacs-transcode--command
               'podman 'ffmpeg io nil '("-i" "x") "cmacs-transcode-1-2")))
    (should (member "--name" cmd))
    (should (member "cmacs-transcode-1-2" cmd))
    ;; --name comes right after `run --rm'.
    (should (equal (seq-take cmd 5)
                   '("podman" "run" "--rm" "--name" "cmacs-transcode-1-2"))))
  ;; No name => no --name flag (backwards compatible).
  (let* ((io (cmacs-transcode--io 'podman "/media/a.mp4" "/media/a.mkv"))
         (cmd (cmacs-transcode--command 'podman 'ffmpeg io nil '("-i" "x"))))
    (should-not (member "--name" cmd))))

(ert-deftest cmacs-transcode-test-command-ffprobe ()
  "ffprobe under a container sets --entrypoint ffprobe."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((io (cmacs-transcode--io 'podman "/media/a.mp4"))
         (cmd (cmacs-transcode--command 'podman 'ffprobe io nil '("-show_streams"))))
    (should (member "--entrypoint" cmd))
    (should (member "ffprobe" cmd))
    (should (member "/media:/input:z" cmd))))

(ert-deftest cmacs-transcode-test-command-host ()
  "The host command is the program followed by the raw ffmpeg args."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let* ((io (cmacs-transcode--io 'host "/media/a.mp4" "/out/a.mkv"))
         (cmd (cmacs-transcode--command 'host 'ffmpeg io nil '("-i" "x" "y"))))
    (should (stringp (car cmd)))
    (should (equal (cdr cmd) '("-i" "x" "y")))))

(ert-deftest cmacs-transcode-test-hw-run-args ()
  "Hwaccel device passthrough args match the requested type."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should (equal (cmacs-transcode--hw-run-args '(vaapi))
                 '("--device=/dev/dri/renderD128:/dev/dri/renderD128")))
  (should (equal (cmacs-transcode--hw-run-args '(vulkan . "intel"))
                 '("--device=/dev/dri:/dev/dri" "-e" "ANV_VIDEO_DECODE=1")))
  (should (equal (cmacs-transcode--hw-run-args '(vulkan . "amd"))
                 '("--device=/dev/dri:/dev/dri" "-e" "RADV_PERFTEST=video_decode")))
  (should (null (cmacs-transcode--hw-run-args '(none)))))

;;; ---------------------------------------------------------------------
;;; Auto-quality + backend resolution
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-auto-quality ()
  "Auto-quality maps widths to CRF (GPU adds +2)."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should (= (cmacs-transcode--auto-quality 3840 nil) 28))
  (should (= (cmacs-transcode--auto-quality 1921 nil) 28))
  (should (= (cmacs-transcode--auto-quality 1920 nil) 26)) ; > 1280
  (should (= (cmacs-transcode--auto-quality 1500 nil) 26))
  (should (= (cmacs-transcode--auto-quality 1280 nil) 24)) ; not > 1280
  (should (= (cmacs-transcode--auto-quality nil nil) 24))
  (should (= (cmacs-transcode--auto-quality 1000 t) 26))) ; base 24 +2

(ert-deftest cmacs-transcode-test-env-runtime ()
  "The container-runtime env override is read as a symbol."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((process-environment
         (cons "CMACS_TRANSCODE_CONTAINER_RUNTIME=docker" process-environment)))
    (should (eq (cmacs-transcode--env-runtime) 'docker)))
  (let ((process-environment
         (cons "CMACS_TRANSCODE_CONTAINER_RUNTIME=" process-environment)))
    (should (null (cmacs-transcode--env-runtime)))))

(ert-deftest cmacs-transcode-test-resolve-range ()
  "Backend resolution returns a known backend or nil."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should (memq (cmacs-transcode--resolve t) '(nil podman docker host))))

(ert-deftest cmacs-transcode-test-color-overridden-p ()
  "`cmacs-transcode--color-overridden-p' detects any override."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should-not (cmacs-transcode--color-overridden-p '(:preserve-color t)))
  (should (cmacs-transcode--color-overridden-p '(:color-trc "bt709")))
  (should (cmacs-transcode--color-overridden-p '(:color-range "pc"))))

;;; ---------------------------------------------------------------------
;;; Output filename + process filter (needs a session buffer)
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-output-for ()
  "Output paths use the session output dir and format extension."
  (cmacs-transcode-tests--skip-unless-loaded)
  (with-temp-buffer
    (setq-local cmacs-transcode--kind 'video)
    (setq-local cmacs-transcode--options '(:format "mkv" :output-dir "/tmp/tc-out"))
    (should (equal (cmacs-transcode--output-for "/in/movie.mp4")
                   "/tmp/tc-out/movie.mkv"))
    (should (equal (cmacs-transcode--output-for "/in/movie.mp4" "season1")
                   "/tmp/tc-out/season1/movie.mkv")))
  (with-temp-buffer
    (setq-local cmacs-transcode--kind 'audio)
    (setq-local cmacs-transcode--options '(:audio-format "vorbis" :output-dir "/tmp/tc-out"))
    (should (equal (cmacs-transcode--output-for "/in/song.wav")
                   "/tmp/tc-out/song.ogg"))))

(ert-deftest cmacs-transcode-test-filter-status ()
  "process-missing/existing filters classify jobs by output existence."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((existing (make-temp-file "cmacs-tc-existing"))
        (missing "/tmp/cmacs-tc-does-not-exist.mkv"))
    (unwind-protect
        (with-temp-buffer
          (setq-local cmacs-transcode--kind 'video)
          ;; No filter: everything queued.
          (setq-local cmacs-transcode--options '(:process-filter nil))
          (should (eq (cmacs-transcode--filter-status existing) 'queued))
          (should (eq (cmacs-transcode--filter-status missing) 'queued))
          ;; Missing-only: skip files whose output already exists.
          (setq-local cmacs-transcode--options '(:process-filter missing))
          (should (eq (cmacs-transcode--filter-status existing) 'skipped))
          (should (eq (cmacs-transcode--filter-status missing) 'queued))
          ;; Existing-only: skip files whose output is absent.
          (setq-local cmacs-transcode--options '(:process-filter existing))
          (should (eq (cmacs-transcode--filter-status existing) 'queued))
          (should (eq (cmacs-transcode--filter-status missing) 'skipped)))
      (ignore-errors (delete-file existing)))))

;;; ---------------------------------------------------------------------
;;; TRAMP / remote execution helpers
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcode-test-io-strips-tramp ()
  "`--io' strips the TRAMP prefix from command + container-mount paths."
  (cmacs-transcode-tests--skip-unless-loaded)
  (let ((h (cmacs-transcode--io 'host "/ssh:box:/a/in.mp4" "/ssh:box:/a/out.mkv")))
    (should (equal (plist-get h :in) "/a/in.mp4"))
    (should (equal (plist-get h :out) "/a/out.mkv"))
    (should (equal (plist-get h :in-dir) "/a/"))
    (should (plist-get h :same)))
  (let ((c (cmacs-transcode--io 'podman "/ssh:box:/a/in.mp4" "/ssh:box:/b/out.mkv")))
    (should (equal (plist-get c :in) "/input/in.mp4"))
    (should (equal (plist-get c :out) "/output/out.mkv"))
    (should (equal (plist-get c :in-dir) "/a/"))
    (should (equal (plist-get c :out-dir) "/b/"))
    (should-not (plist-get c :same))))

(ert-deftest cmacs-transcode-test-exec-dir ()
  "`--exec-dir' resolves the execution host from MODE x input remoteness."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should (null (cmacs-transcode--exec-dir "/home/u/a.mp4" 'auto)))
  (should (null (cmacs-transcode--exec-dir "/home/u/a.mp4" 'local)))
  (should (null (cmacs-transcode--exec-dir "/ssh:box:/a/f.mp4" 'local)))
  (should-error (cmacs-transcode--exec-dir "/home/u/a.mp4" 'remote) :type 'user-error)
  (dolist (mode '(auto remote))
    (let ((d (cmacs-transcode--exec-dir "/ssh:box:/a/f.mp4" mode)))
      (should (equal (file-remote-p d 'method) "ssh"))
      (should (equal (file-remote-p d 'host) "box"))
      (should (equal (file-remote-p d 'localname) "/a/")))))

(ert-deftest cmacs-transcode-test-stage-in-p ()
  "`--stage-in-p' is true only for a remote input under `local' execution."
  (cmacs-transcode-tests--skip-unless-loaded)
  (should (cmacs-transcode--stage-in-p "/ssh:box:/a/f.mp4" 'local))
  (should-not (cmacs-transcode--stage-in-p "/ssh:box:/a/f.mp4" 'auto))
  (should-not (cmacs-transcode--stage-in-p "/home/u/f.mp4" 'local)))

(provide 'cmacs-transcode-tests)
;;; cmacs-transcode-tests.el ends here
