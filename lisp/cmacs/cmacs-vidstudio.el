;;; cmacs-vidstudio.el --- Reel-based video editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A video editor built on the cmacs-vidstudio-* C primitives (a libregnum
;; Reel timeline: tracks of clip segments joined by transitions, with effects,
;; rendered on the CPU and exported through the ffmpeg-backed reel exporters).
;;
;; `cmacs-vidstudio-mode' shows the composited preview frame as a native Emacs
;; image, with a textual timeline, a playhead, transport, and editing commands.
;; The model is also fully scriptable / MCP-driveable via the `cmacs-vidstudio-*'
;; primitives.  An in-engine libregnum timeline strip + right-click menus are a
;; planned follow-on layer.

;;; Code:

(require 'cl-lib)
(require 'cmacs-libregnum)  ; for cmacs-libregnum-popup-menu (GTK vs --lrg routing)
(require 'cmacs-evil)       ; Evil/Doom keymap precedence
(require 'transient)        ; `?' -> keybinding cheat-sheet menu

(defgroup cmacs-vidstudio nil
  "Reel-based video editor."
  :group 'cmacs
  :prefix "cmacs-vidstudio-")

(defcustom cmacs-vidstudio-default-width 1280
  "Default project width."
  :type 'integer)
(defcustom cmacs-vidstudio-default-height 720
  "Default project height."
  :type 'integer)
(defcustom cmacs-vidstudio-default-fps 30.0
  "Default project frame rate."
  :type 'number)

(defcustom cmacs-vidstudio-preview-fps 12
  "Maximum preview render rate (redraws per second) during playback.
The playhead itself advances at the full project fps from the wall
clock; this only caps how often the preview image is re-rendered, so
slow renders skip frames instead of stalling Emacs."
  :type 'integer)

(defvar-local cmacs-vidstudio--handle nil)
(defvar-local cmacs-vidstudio--live nil
  "Non-nil when the preview renders through a live libregnum GL viewport
instead of a native Emacs image.  Set when a display + libregnum are
available; nil falls back to the PPM/PNG insert-image preview.")
(defvar-local cmacs-vidstudio--playhead 0)
(defvar-local cmacs-vidstudio--active-track 0)
(defvar-local cmacs-vidstudio--selected-clip nil
  "Clip id selected on the viewport timeline strip, or nil.")
(defvar-local cmacs-vidstudio--tl-trim nil
  "Clip id currently being trimmed by a timeline edge-drag, or nil.")
(defvar-local cmacs-vidstudio--play-timer nil)
(defvar-local cmacs-vidstudio--audio-proc nil
  "External audio-playback process during preview, or nil.")
(defvar-local cmacs-vidstudio--audio-wav nil
  "Temp WAV of the mixed project audio for preview playback.")
(defvar-local cmacs-vidstudio--play-start-frame 0
  "Wall-clock play anchor: the frame play (re)started from.")
(defvar-local cmacs-vidstudio--play-t0 0.0
  "Wall-clock play anchor: `float-time' when play (re)started.")
(defvar-local cmacs-vidstudio--preview-scale 0.5)
(defcustom cmacs-vidstudio-playback-scale 0.4
  "Preview scale used WHILE playing (a low-res proxy for near-real-time
playback); the full-resolution frame is rendered when playback pauses.
1.0 disables the proxy."
  :type 'number)
(defcustom cmacs-vidstudio-prefetch-frames 16
  "How many frames ahead of the playhead to pre-render during playback.
A background idle timer renders these into a frame cache so the play
timer displays a ready frame instead of rendering synchronously."
  :type 'integer)
(defvar-local cmacs-vidstudio--frame-cache nil
  "Hash of FRAME -> pre-rendered PPM string during playback, or nil.
Live only between play and pause (playback is read-only), so it never
goes stale against an edit.")
(defvar-local cmacs-vidstudio--prefetch-timer nil
  "Idle timer that fills `cmacs-vidstudio--frame-cache' ahead of the playhead.")
(defvar-local cmacs-vidstudio--paused-scale nil
  "The preview scale to restore when playback stops.")
(defvar-local cmacs-vidstudio--decode-timer nil
  "Poll timer that re-renders once an imported clip finishes decoding.")
(defvar-local cmacs-vidstudio--last-image nil
  "Previous preview image spec; flushed on each redraw.
Every playback frame is a distinct image, so without an explicit
`image-flush' the image cache would grow by one full frame per redraw.")

(defconst cmacs-vidstudio-transition-alist
  '(("none" . -1) ("fade" . 0) ("dissolve" . 1) ("wipe" . 2) ("slide" . 3)
    ("zoom" . 4) ("iris" . 5) ("flip" . 6) ("push" . 7) ("clock-wipe" . 8))
  "Transition names -> type codes.")

(defconst cmacs-vidstudio-effect-alist
  '(("blur" . 0) ("bloom" . 1) ("color-grade" . 2) ("vignette" . 3)
    ("grain" . 4))
  "Effect names -> type codes.")

;; --------------------------------------------------------------------------
;; Rendering
;; --------------------------------------------------------------------------

(defun cmacs-vidstudio--timeline-string ()
  "A one-line-per-track textual view of the timeline."
  (let ((n (cmacs-vidstudio-n-tracks cmacs-vidstudio--handle))
        (lines '()))
    (dotimes (tr n)
      (let ((nclips (cmacs-vidstudio-track-clip-count cmacs-vidstudio--handle tr))
            (cells '()))
        (dotimes (ci nclips)
          (let* ((id (cmacs-vidstudio-clip-at cmacs-vidstudio--handle tr ci))
                 (start (cmacs-vidstudio-clip-start-frame cmacs-vidstudio--handle id))
                 (dur (cmacs-vidstudio-clip-duration cmacs-vidstudio--handle id))
                 (decoding (and (fboundp 'cmacs-vidstudio-clip-ready-p)
                                (not (cmacs-vidstudio-clip-ready-p
                                      cmacs-vidstudio--handle id)))))
            (push (format "[#%d %d+%d%s]" id start dur
                          (if decoding " decoding…" ""))
                  cells)))
        (push (format "%s track %d: %s"
                      (if (= tr cmacs-vidstudio--active-track) "*" " ")
                      tr (string-join (nreverse cells) " "))
              lines)))
    (string-join (nreverse lines) "\n")))

;; --------------------------------------------------------------------------
;; Clip-list side window (like imgedit's layers panel)
;; --------------------------------------------------------------------------
(defvar-local cmacs-vidstudio--clips-panel nil
  "The clip-list side-window buffer for this project, or nil.")

(defun cmacs-vidstudio--build-clips-panel (project-buf)
  "Fill the current buffer with PROJECT-BUF's clip list (one line per clip).
Each clip is a button that selects it (highlighting it on the timeline)."
  (let ((inhibit-read-only t) handle sel active)
    (when (buffer-live-p project-buf)
      (with-current-buffer project-buf
        (setq handle cmacs-vidstudio--handle
              sel    cmacs-vidstudio--selected-clip
              active cmacs-vidstudio--active-track)))
    (erase-buffer)
    (when handle
      (insert (propertize " Clips\n" 'face 'bold))
      (dotimes (tr (cmacs-vidstudio-n-tracks handle))
        (insert (propertize (format " Track %d%s\n" tr
                                    (if (= tr active) "  (active)" ""))
                            'face 'font-lock-keyword-face))
        (let ((nclips (cmacs-vidstudio-track-clip-count handle tr)))
          (if (zerop nclips)
              (insert "   (empty)\n")
            (dotimes (ci nclips)
              (let* ((id (cmacs-vidstudio-clip-at handle tr ci))
                     (start (cmacs-vidstudio-clip-start-frame handle id))
                     (dur (cmacs-vidstudio-clip-duration handle id))
                     (decoding (and (fboundp 'cmacs-vidstudio-clip-ready-p)
                                    (not (cmacs-vidstudio-clip-ready-p
                                          handle id)))))
                (insert " ")
                (insert-text-button
                 (format "#%-3d %5d-%-5d %4dfr%s"
                         id start (+ start dur) dur
                         (if decoding " ..." ""))
                 'face (cond ((eql id sel) 'highlight)
                             (decoding 'shadow)
                             (t 'default))
                 'follow-link t
                 'help-echo "Select this clip"
                 'action (let ((cid id) (pb project-buf))
                           (lambda (_)
                             (when (buffer-live-p pb)
                               (with-current-buffer pb
                                 (setq cmacs-vidstudio--selected-clip cid)
                                 (cmacs-vidstudio--render))))))
                (insert "\n"))))))
      ;; Audio lane
      (when (and (fboundp 'cmacs-vidstudio-audio-count)
                 (> (cmacs-vidstudio-audio-count handle) 0))
        (insert (propertize " Audio\n" 'face 'font-lock-keyword-face))
        (dotimes (ai (cmacs-vidstudio-audio-count handle))
          (let ((info (cmacs-vidstudio-audio-at handle ai)))
            (when info
              (insert
               (format "  #%-3d %5d-%-5d %4dfr%s\n"
                       (nth 0 info) (nth 1 info)
                       (+ (nth 1 info) (nth 2 info)) (nth 2 info)
                       (if (nth 3 info) " (from video)" "")))))))
      (goto-char (point-min)))))

(defun cmacs-vidstudio--refresh-clips-panel ()
  "Rebuild the clips side panel from the current project, if it is shown."
  (when (and cmacs-vidstudio--clips-panel
             (buffer-live-p cmacs-vidstudio--clips-panel)
             (get-buffer-window cmacs-vidstudio--clips-panel))
    (let ((pb (current-buffer)))
      (with-current-buffer cmacs-vidstudio--clips-panel
        (cmacs-vidstudio--build-clips-panel pb)))))

(defun cmacs-vidstudio--open-clips-panel ()
  "Create + show the clips side window for the current project buffer."
  (let* ((pb (current-buffer))
         (buf (get-buffer-create
               (format "*vidstudio-clips[%s]*" (buffer-name pb)))))
    (setq cmacs-vidstudio--clips-panel buf)
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode))
      (setq-local cursor-type nil)
      (cmacs-vidstudio--build-clips-panel pb))
    (display-buffer-in-side-window
     buf '((side . right) (window-width . 30) (slot . 0)))))

(defun cmacs-vidstudio-toggle-clips-panel ()
  "Toggle a right side window listing the project's clips and their IDs."
  (interactive)
  (if (and cmacs-vidstudio--clips-panel
           (get-buffer-window cmacs-vidstudio--clips-panel))
      (delete-window (get-buffer-window cmacs-vidstudio--clips-panel))
    (cmacs-vidstudio--open-clips-panel)))

(defvar cmacs-vidstudio--canvas-map (make-sparse-keymap)
  "Keymap applied as a text property over the rendered preview/timeline.
A position `keymap' property outranks Evil state maps and
`context-menu-mode', so right-click reaches the editor menu under Doom.")
;; Bound on every load, mutating the same object (reload-safe).
(let ((map cmacs-vidstudio--canvas-map))
  (define-key map [down-mouse-3] #'cmacs-vidstudio-context-menu)
  (define-key map [mouse-3] #'ignore))

(defconst cmacs-vidstudio--track-colors
  '((80 140 220) (220 120 80) (120 200 120) (200 180 90) (180 120 200))
  "Cycling clip-block colours for the in-viewport timeline strip.")

(defun cmacs-vidstudio--timeline-clips ()
  "Build the (ID TRACK START DUR R G B) list for the viewport timeline strip."
  (let ((clips '()) (ntr (cmacs-vidstudio-n-tracks cmacs-vidstudio--handle)))
    (dotimes (tr ntr)
      (dotimes (ci (cmacs-vidstudio-track-clip-count cmacs-vidstudio--handle tr))
        (let* ((id (cmacs-vidstudio-clip-at cmacs-vidstudio--handle tr ci))
               (start (cmacs-vidstudio-clip-start-frame
                       cmacs-vidstudio--handle id))
               (dur (cmacs-vidstudio-clip-duration cmacs-vidstudio--handle id))
               (sel (if (eq id cmacs-vidstudio--selected-clip) 60 0))
               (col (nth (mod id (length cmacs-vidstudio--track-colors))
                         cmacs-vidstudio--track-colors)))
          ;; Brighten the selected clip's block so the selection is visible.
          (push (list id tr start dur
                      (min 255 (+ (nth 0 col) sel))
                      (min 255 (+ (nth 1 col) sel))
                      (min 255 (+ (nth 2 col) sel)))
                clips))))
    ;; Audio lane: one extra row (track = ntr) so audio shows in parallel
    ;; with the video, teal-coloured.
    (when (fboundp 'cmacs-vidstudio-audio-count)
      (dotimes (ai (cmacs-vidstudio-audio-count cmacs-vidstudio--handle))
        (let ((info (cmacs-vidstudio-audio-at cmacs-vidstudio--handle ai)))
          (when info
            (let ((id (nth 0 info)) (from (nth 1 info)) (frames (nth 2 info))
                  (sel (if (eql (nth 0 info) cmacs-vidstudio--selected-clip)
                           60 0)))
              (push (list id ntr from (max 2 frames)
                          (min 255 (+ 70 sel)) (min 255 (+ 190 sel))
                          (min 255 (+ 160 sel)))
                    clips))))))
    (nreverse clips)))

(defun cmacs-vidstudio--update-timeline ()
  "Push the timeline strip data to the live viewport."
  (when (and cmacs-vidstudio--live (fboundp 'cmacs-libregnum-image-timeline))
    (ignore-errors
      (cmacs-libregnum-image-timeline
       (current-buffer) cmacs-vidstudio--playhead
       (cmacs-vidstudio-total-frames cmacs-vidstudio--handle)
       (cmacs-vidstudio--timeline-clips)))))

(defun cmacs-vidstudio--render ()
  "Redraw the preview + timeline."
  (when cmacs-vidstudio--handle
    (let ((total (cmacs-vidstudio-total-frames cmacs-vidstudio--handle)))
      (when (and (> total 0) (>= cmacs-vidstudio--playhead total))
        (setq cmacs-vidstudio--playhead (1- total)))
      (when (< cmacs-vidstudio--playhead 0)
        (setq cmacs-vidstudio--playhead 0))
      (if cmacs-vidstudio--live
          ;; Live GL viewport: render the playhead frame into the FBO (no
          ;; PPM-through-Emacs).  The in-viewport timeline strip is a later
          ;; phase; the header line shows frame/total meanwhile.
          (if (> total 0)
              (progn
                (ignore-errors
                  (cmacs-vidstudio-viewport-render
                   cmacs-vidstudio--handle (current-buffer)
                   cmacs-vidstudio--playhead))
                (cmacs-vidstudio--update-timeline))
            (ignore-errors (cmacs-libregnum-redraw (current-buffer))))
        (cmacs-vidstudio--render-native total)))
    ;; keep the clips side panel in sync (skip mid-playback churn)
    (unless cmacs-vidstudio--play-timer
      (cmacs-vidstudio--refresh-clips-panel))))

(defun cmacs-vidstudio--preview-width ()
  "Preview render width in pixels at the current preview scale."
  (max 64 (floor (* (cmacs-vidstudio-width cmacs-vidstudio--handle)
                    cmacs-vidstudio--preview-scale))))

(defun cmacs-vidstudio--cache-ppm (frame)
  "PPM bytes for FRAME: from the playback cache if present, else render (and
cache when a playback cache is active)."
  (or (and cmacs-vidstudio--frame-cache
           (gethash frame cmacs-vidstudio--frame-cache))
      (let ((ppm (cmacs-vidstudio-render-ppm
                  cmacs-vidstudio--handle frame (cmacs-vidstudio--preview-width))))
        (when cmacs-vidstudio--frame-cache
          (puthash frame ppm cmacs-vidstudio--frame-cache))
        ppm)))

(defun cmacs-vidstudio--prefetch-tick ()
  "Pre-render a few upcoming uncached frames; evict frames behind the playhead."
  (when (and cmacs-vidstudio--frame-cache cmacs-vidstudio--play-timer
             (fboundp 'cmacs-vidstudio-render-ppm)
             (not (input-pending-p)))
    (let ((total (cmacs-vidstudio-total-frames cmacs-vidstudio--handle))
          (done 0))
      (cl-loop for f from cmacs-vidstudio--playhead
               below (min total (+ cmacs-vidstudio--playhead
                                   cmacs-vidstudio-prefetch-frames))
               while (and (< done 3) (not (input-pending-p)))
               unless (gethash f cmacs-vidstudio--frame-cache)
               do (cmacs-vidstudio--cache-ppm f) (setq done (1+ done)))
      ;; Bound memory: drop frames well behind the playhead.
      (maphash (lambda (k _v)
                 (when (< k (- cmacs-vidstudio--playhead 2))
                   (remhash k cmacs-vidstudio--frame-cache)))
               cmacs-vidstudio--frame-cache))))

(defun cmacs-vidstudio--cache-start ()
  "Begin a fresh playback frame cache + background prefetch."
  (setq cmacs-vidstudio--frame-cache (make-hash-table :test 'eq))
  (when (timerp cmacs-vidstudio--prefetch-timer)
    (cancel-timer cmacs-vidstudio--prefetch-timer))
  (setq cmacs-vidstudio--prefetch-timer
        (run-with-idle-timer 0.02 t #'cmacs-vidstudio--prefetch-tick)))

(defun cmacs-vidstudio--audio-player-command (wav offset)
  "Command list to play WAV from OFFSET seconds with no window, or nil if no
suitable player is on PATH."
  (let ((off (format "%.3f" (max 0.0 offset))))
    (cond
     ((executable-find "ffplay")
      (list (executable-find "ffplay") "-nodisp" "-autoexit"
            "-loglevel" "quiet" "-ss" off wav))
     ((executable-find "mpv")
      (list (executable-find "mpv") "--no-video" "--really-quiet"
            (concat "--start=" off) wav))
     ;; paplay/aplay cannot seek -- only usable from the very start.
     ((and (< offset 0.05) (executable-find "paplay"))
      (list (executable-find "paplay") wav))
     ((and (< offset 0.05) (executable-find "aplay"))
      (list (executable-find "aplay") "-q" wav))
     (t nil))))

(defun cmacs-vidstudio--audio-stop ()
  "Stop any preview audio playback."
  (when (process-live-p cmacs-vidstudio--audio-proc)
    (delete-process cmacs-vidstudio--audio-proc))
  (setq cmacs-vidstudio--audio-proc nil))

(defun cmacs-vidstudio--audio-start (offset)
  "Mix the project audio and start playing it from OFFSET seconds, synced to
the wall-clock playhead.  No-op when the project has no audio."
  (cmacs-vidstudio--audio-stop)
  (when (and (fboundp 'cmacs-vidstudio-audio-count)
             (> (cmacs-vidstudio-audio-count cmacs-vidstudio--handle) 0))
    (condition-case err
        (let ((wav (or cmacs-vidstudio--audio-wav
                       (setq cmacs-vidstudio--audio-wav
                             (make-temp-file "cmvs-preview" nil ".wav")))))
          ;; WAV (format 0) is a direct sample write -- no ffmpeg, fast.
          (cmacs-vidstudio-export-audio cmacs-vidstudio--handle wav 0)
          (let ((cmd (cmacs-vidstudio--audio-player-command wav offset)))
            (if cmd
                (setq cmacs-vidstudio--audio-proc
                      (make-process :name "vidstudio-audio" :command cmd
                                    :noquery t :buffer nil
                                    :sentinel #'ignore))
              (message "vidstudio: no audio player found (install ffplay or mpv) -- preview is silent"))))
      (error (message "vidstudio: audio preview unavailable: %s"
                      (error-message-string err))))))

(defun cmacs-vidstudio--seek (frame &optional quiet-audio)
  "Move the playhead to FRAME (clamped >= 0).  When playing, re-anchor the
wall-clock reference so the video follows, and -- unless QUIET-AUDIO --
restart preview audio at the new position so seeking stays in sync.  Pass
QUIET-AUDIO for per-motion drag scrubs (restarting ffplay every motion would
churn processes); do a final non-quiet seek on release.  Then re-render."
  (setq cmacs-vidstudio--playhead (max 0 frame))
  (when cmacs-vidstudio--play-timer
    (setq cmacs-vidstudio--play-start-frame cmacs-vidstudio--playhead
          cmacs-vidstudio--play-t0 (float-time))
    (unless quiet-audio
      (cmacs-vidstudio--audio-start
       (/ cmacs-vidstudio--playhead
          (max 1.0 (cmacs-vidstudio-fps cmacs-vidstudio--handle))))))
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio--cache-stop ()
  "Tear down the playback frame cache + prefetch."
  (when (timerp cmacs-vidstudio--prefetch-timer)
    (cancel-timer cmacs-vidstudio--prefetch-timer))
  (setq cmacs-vidstudio--prefetch-timer nil
        cmacs-vidstudio--frame-cache nil))

(defun cmacs-vidstudio--render-native (total)
  "Native insert-image preview + textual timeline (TOTAL frames)."
  (let ((inhibit-read-only t))
    (erase-buffer)
      (if (and (> total 0) (image-type-available-p 'pbm))
          (condition-case err
              ;; Preview via uncompressed PPM rendered AT preview size in C
              ;; (PNG round-trips zlib on every frame — far too slow for
              ;; playback); :scale 1 so display does no rescaling either.
              (let ((image
                     (if (fboundp 'cmacs-vidstudio-render-ppm)
                         (create-image
                          ;; Through the playback frame cache: a hit is
                          ;; instant, a miss renders (and caches, if playing).
                          (cmacs-vidstudio--cache-ppm cmacs-vidstudio--playhead)
                          'pbm t :scale 1 :ascent 'center)
                       (create-image     ; old binary: PNG fallback
                        (cmacs-vidstudio-render-png cmacs-vidstudio--handle
                                                    cmacs-vidstudio--playhead)
                        'png t :scale cmacs-vidstudio--preview-scale
                        :ascent 'center))))
                (insert-image image)
                (when cmacs-vidstudio--last-image
                  (image-flush cmacs-vidstudio--last-image))
                (setq cmacs-vidstudio--last-image image))
            (error (insert (format "[render error: %s]"
                                   (error-message-string err)))))
        (insert "[empty timeline — import or add a clip]"))
      (insert (format "\n\nframe %d / %d\n\n" cmacs-vidstudio--playhead total))
      (insert (cmacs-vidstudio--timeline-string))
      (insert "\n")
      ;; Claim mouse-3 over the whole buffer: a position keymap outranks
      ;; Evil states and context-menu-mode (Doom), which otherwise shadow
      ;; the mode map's context menu.
      (add-text-properties (point-min) (point-max)
                           (list 'keymap cmacs-vidstudio--canvas-map))))

;; --------------------------------------------------------------------------
;; Building the timeline
;; --------------------------------------------------------------------------

(defun cmacs-vidstudio--secs-to-frames (secs)
  "Convert SECS to frames at the project fps."
  (max 1 (round (* secs (cmacs-vidstudio-fps cmacs-vidstudio--handle)))))

(defun cmacs-vidstudio-add-track-cmd ()
  "Add a track and make it active."
  (interactive)
  (setq cmacs-vidstudio--active-track
        (cmacs-vidstudio-add-track cmacs-vidstudio--handle))
  (cmacs-vidstudio--render)
  (message "Active track: %d" cmacs-vidstudio--active-track))

(defun cmacs-vidstudio-set-active-track (track)
  "Set the active TRACK."
  (interactive (list (read-number "Active track: " cmacs-vidstudio--active-track)))
  (setq cmacs-vidstudio--active-track track)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio--resolve-duration (id)
  "Resolve clip ID's whole-video length from its decoded frame count.
A no-op unless the import could not determine the duration (no ffprobe)."
  (when (fboundp 'cmacs-vidstudio-refresh-video-duration)
    (ignore-errors
      (cmacs-vidstudio-refresh-video-duration cmacs-vidstudio--handle id))))

(defun cmacs-vidstudio--watch-decode (id)
  "Poll clip ID until its background decode finishes, then resolve its
whole-video length and re-render.  Video clips decode on a worker thread
(the preview composites a dark placeholder meanwhile), so import returns
instantly; the on-timeline length snaps to the real value once decoded
(needed when ffprobe could not probe the duration at import)."
  (if (and (fboundp 'cmacs-vidstudio-clip-ready-p)
           (cmacs-vidstudio-clip-ready-p cmacs-vidstudio--handle id))
      (progn (cmacs-vidstudio--resolve-duration id)
             (cmacs-vidstudio--render))
    (let ((buf (current-buffer))
          (deadline (+ (float-time) 120.0)))
      (when cmacs-vidstudio--decode-timer
        (cancel-timer cmacs-vidstudio--decode-timer))
      (setq cmacs-vidstudio--decode-timer
            (run-at-time
             0.25 0.25
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (cond
                    ((cmacs-vidstudio-clip-ready-p cmacs-vidstudio--handle id)
                     (cancel-timer cmacs-vidstudio--decode-timer)
                     (setq cmacs-vidstudio--decode-timer nil)
                     (cmacs-vidstudio--resolve-duration id)
                     (cmacs-vidstudio--render)
                     (message "vidstudio: clip #%d decoded (%d frames)" id
                              (cmacs-vidstudio-clip-duration
                               cmacs-vidstudio--handle id)))
                    ((> (float-time) deadline)
                     (cancel-timer cmacs-vidstudio--decode-timer)
                     (setq cmacs-vidstudio--decode-timer nil)
                     (message "vidstudio: clip #%d decode timed out" id)))))))))))

(defun cmacs-vidstudio--maybe-secs (str)
  "Parse STR as seconds, or nil when blank."
  (and (stringp str) (not (string-empty-p (string-trim str)))
       (string-to-number str)))

;; ── Per-clip transform / effect / export commands ──────────────────────

(defun cmacs-vidstudio--clip-at-playhead ()
  "Clip id at the playhead on the active track, or nil."
  (let ((n (cmacs-vidstudio-track-clip-count cmacs-vidstudio--handle
                                             cmacs-vidstudio--active-track)))
    (catch 'hit
      (dotimes (i n)
        (let* ((id (cmacs-vidstudio-clip-at cmacs-vidstudio--handle
                                            cmacs-vidstudio--active-track i))
               (s (cmacs-vidstudio-clip-start-frame cmacs-vidstudio--handle id))
               (d (cmacs-vidstudio-clip-duration cmacs-vidstudio--handle id)))
          (when (and (>= cmacs-vidstudio--playhead s)
                     (< cmacs-vidstudio--playhead (+ s d)))
            (throw 'hit id))))
      nil)))

(defvar cmacs-vidstudio--context-clip nil
  "When non-nil, the clip id a right-clicked menu command acts on WITHOUT
prompting.  Dynamically bound for the duration of a context-menu pop from the
clip the user right-clicked on the timeline strip.")

(defun cmacs-vidstudio--read-clip ()
  "Clip id: the right-clicked clip when a menu supplies one, else prompt
\(defaulting to the clip under the playhead)."
  (or cmacs-vidstudio--context-clip
      (let ((def (cmacs-vidstudio--clip-at-playhead)))
        (read-number "Clip id: " (or def 0)))))

(defun cmacs-vidstudio-set-clip-opacity (clip o)
  "Set CLIP's opacity to O (0..1)."
  (interactive (list (cmacs-vidstudio--read-clip)
                     (read-number "Opacity (0..1): " 1.0)))
  (cmacs-vidstudio-set-opacity cmacs-vidstudio--handle clip o)
  (cmacs-vidstudio--render))

(defconst cmacs-vidstudio--blend-alist
  '(("normal" . 0) ("multiply" . 1) ("screen" . 2) ("overlay" . 3)
    ("soft-light" . 4) ("add" . 5) ("color-dodge" . 6) ("color-burn" . 7)))

(defun cmacs-vidstudio-set-clip-blend (clip mode)
  "Set CLIP's blend MODE (completing-read)."
  (interactive
   (list (cmacs-vidstudio--read-clip)
         (cdr (assoc (completing-read "Blend: " cmacs-vidstudio--blend-alist
                                      nil t)
                     cmacs-vidstudio--blend-alist))))
  (cmacs-vidstudio-set-blend-mode cmacs-vidstudio--handle clip mode)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-set-clip-transform (clip x y scale)
  "Position CLIP at (X Y) with uniform SCALE."
  (interactive (list (cmacs-vidstudio--read-clip)
                     (read-number "X offset: " 0)
                     (read-number "Y offset: " 0)
                     (read-number "Scale: " 1.0)))
  (cmacs-vidstudio-set-transform cmacs-vidstudio--handle clip x y scale scale)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-set-clip-speed (clip rate)
  "Set video CLIP's playback RATE (2.0 = double speed, 0.5 = slow-mo)."
  (interactive (list (cmacs-vidstudio--read-clip)
                     (read-number "Playback rate: " 1.0)))
  (unless (cmacs-vidstudio-set-video-rate cmacs-vidstudio--handle clip rate)
    (message "Clip %d is not a video clip" clip))
  (cmacs-vidstudio--render))

(defconst cmacs-vidstudio--effect-param-alist
  '(("blur radius" 0 . "radius")
    ("grade brightness" 2 . "brightness")
    ("grade contrast" 2 . "contrast")
    ("grade saturation" 2 . "saturation")
    ("vignette intensity" 3 . "intensity")
    ("grain amount" 4 . "amount"))
  "Human name -> (EFFECT-INDEX . PROP) for common effect parameters.")

(defun cmacs-vidstudio-set-effect-parameter (clip name value)
  "Set effect parameter NAME on CLIP to VALUE."
  (interactive
   (let* ((k (completing-read "Effect param: "
                              cmacs-vidstudio--effect-param-alist nil t))
          (e (cdr (assoc k cmacs-vidstudio--effect-param-alist))))
     (list (cmacs-vidstudio--read-clip) k
           (read-number (format "%s value: " k) 1.0))))
  (let ((e (cdr (assoc name cmacs-vidstudio--effect-param-alist))))
    (when e
      (cmacs-vidstudio-set-effect-param cmacs-vidstudio--handle clip (car e)
                                        (cons (cdr e) value))
      (cmacs-vidstudio--render))))

(defun cmacs-vidstudio-export-still-cmd (path)
  "Export the playhead frame to PATH (PNG/JPG)."
  (interactive (list (read-file-name "Export still to: " nil "still.png")))
  (cmacs-vidstudio-export-still cmacs-vidstudio--handle
                                cmacs-vidstudio--playhead
                                (expand-file-name path))
  (message "Wrote %s" path))

(defun cmacs-vidstudio-set-export-quality-cmd (crf)
  "Set the next export's CRF quality (lower = better, 18-28 typical)."
  (interactive (list (read-number "CRF (18 best..28): " 23)))
  (cmacs-vidstudio-set-export-quality cmacs-vidstudio--handle crf nil)
  (message "Export CRF set to %d" crf))

;; ── Save / load (.vstudio) ─────────────────────────────────────────────

(defvar-local cmacs-vidstudio--file nil
  "Path this project was loaded from / last saved to.")

(defcustom cmacs-vidstudio-autosave-interval 60
  "Seconds of idle before autosaving a named project to FILE~ (nil disables)."
  :type '(choice (const :tag "Off" nil) integer))

(defun cmacs-vidstudio--sx (key data)
  "Value of (KEY VALUE) in the tail of DATA, or nil."
  (cadr (assq key (cdr data))))

(defun cmacs-vidstudio--replay-clip (handle track clip)
  "Rebuild one CLIP sexp onto TRACK of HANDLE."
  (let* ((kind (cmacs-vidstudio--sx 'kind clip))
         (dur (cmacs-vidstudio--sx 'dur clip))
         (asset (cmacs-vidstudio--sx 'asset clip))
         (color (cdr (assq 'color (cdr clip))))
         (id (pcase kind
               (0 (apply #'cmacs-vidstudio-add-solid-clip handle track dur
                         color))
               (1 (cmacs-vidstudio-add-image-clip handle track asset dur))
               (2 (cmacs-vidstudio-add-video-clip
                   handle track asset nil
                   (cmacs-vidstudio--sx 'in clip)
                   (cmacs-vidstudio--sx 'out clip)))
               (3 (apply #'cmacs-vidstudio-add-text-clip handle track asset dur
                         color))
               (_ nil))))
    (when (and id (>= id 0))
      ;; Re-apply a video clip's on-timeline duration when it diverges from the
      ;; in/out slice (e.g. extended into a freeze-hold); add-video-clip derived
      ;; it from the slice alone.
      (when (and (= kind 2) dur (> dur 0)
                 (/= dur (cmacs-vidstudio-clip-duration handle id)))
        (cmacs-vidstudio-set-clip-duration handle id dur))
      (let ((tr (assq 'transition (cdr clip))))
        (when tr
          (cmacs-vidstudio-set-transition handle id (nth 1 tr) (nth 2 tr)
                                          (nth 3 tr))))
      (when (cmacs-vidstudio--sx 'opacity clip)
        (cmacs-vidstudio-set-opacity handle id
                                     (cmacs-vidstudio--sx 'opacity clip)))
      (when (cmacs-vidstudio--sx 'blend clip)
        (cmacs-vidstudio-set-blend-mode handle id
                                        (cmacs-vidstudio--sx 'blend clip)))
      (let ((tf (assq 'transform (cdr clip))))
        (when tf   ; (transform X Y SX SY ROT)
          (cmacs-vidstudio-set-transform handle id (nth 1 tf) (nth 2 tf)
                                         (nth 3 tf) (nth 4 tf) (nth 5 tf))))
      (let ((bx (assq 'box (cdr clip))))
        (when (and bx (fboundp 'cmacs-vidstudio-set-clip-box))  ; (box X Y W H)
          (cmacs-vidstudio-set-clip-box handle id (nth 1 bx) (nth 2 bx)
                                        (nth 3 bx) (nth 4 bx))))
      (let ((eidx 0))
        (dolist (fx (cdr (assq 'effects (cdr clip))))
          ;; fx = (TYPE (PROP VAL) (PROP VAL)...)
          (cmacs-vidstudio-add-effect handle id (car fx))
          (dolist (pv (cdr fx))
            (cmacs-vidstudio-set-effect-param
             handle id eidx (cons (symbol-name (car pv)) (cadr pv))))
          (setq eidx (1+ eidx))))
      (dolist (k (cdr (assq 'keyframes (cdr clip))))
        ;; k = (PARAM EIDX FRAME VALUE EASING [PROP])
        (cmacs-vidstudio-add-keyframe handle id (nth 0 k) (nth 2 k) (nth 3 k)
                                      (nth 4 k) (nth 1 k) (nth 5 k))))))

(defun cmacs-vidstudio--build-from-sexp (data)
  "Create a project HANDLE from parsed DATA; unknown keys are ignored."
  (let* ((w (cmacs-vidstudio--sx 'width data))
         (h (cmacs-vidstudio--sx 'height data))
         (fps (cmacs-vidstudio--sx 'fps data))
         (handle (cmacs-vidstudio-new (or w 1280) (or h 720) (or fps 30.0)))
         (ti 0))
    (dolist (tr (cdr (assq 'tracks (cdr data))))
      (when (eq (car-safe tr) 'track)
        (when (> ti 0) (cmacs-vidstudio-add-track handle))
        (dolist (clip (cdr tr))
          (when (eq (car-safe clip) 'clip)
            (ignore-errors (cmacs-vidstudio--replay-clip handle ti clip))))
        (setq ti (1+ ti))))
    (dolist (seg (cdr (assq 'audio (cdr data))))
      (when (eq (car-safe seg) 'seg)
        (let ((src (cmacs-vidstudio--sx 'source seg)))
          (when src
            (ignore-errors
              (if (cmacs-vidstudio--sx 'extract seg)
                  ;; audio was extracted from a video: re-extract on load
                  (cmacs-vidstudio-add-audio-extract-file
                   handle src (or (cmacs-vidstudio--sx 'from seg) 0)
                   (or (cmacs-vidstudio--sx 'volume seg) 1.0))
                (cmacs-vidstudio-add-audio-file
                 handle src (or (cmacs-vidstudio--sx 'from seg) 0)
                 (or (cmacs-vidstudio--sx 'volume seg) 1.0)
                 (or (cmacs-vidstudio--sx 'trim-start seg) 0.0)
                 (or (cmacs-vidstudio--sx 'trim-end seg) 0.0))))))))
    handle))

(defun cmacs-vidstudio-save-as (file)
  "Write the project to FILE as a .vstudio S-expression."
  (interactive (list (read-file-name "Save .vstudio: " nil nil nil
                                     (or cmacs-vidstudio--file "project.vstudio"))))
  (with-temp-file file
    (insert ";; -*- mode: lisp-data -*- cmacs vidstudio project\n")
    (insert (cmacs-vidstudio-serialize cmacs-vidstudio--handle) "\n"))
  (setq cmacs-vidstudio--file file)
  (message "Saved %s" file))

(defun cmacs-vidstudio-save ()
  "Save the project to its file, or prompt if unsaved."
  (interactive)
  (if cmacs-vidstudio--file
      (cmacs-vidstudio-save-as cmacs-vidstudio--file)
    (call-interactively #'cmacs-vidstudio-save-as)))

;;;###autoload
(defun cmacs-vidstudio-open (file)
  "Open a .vstudio project FILE in a new editor buffer."
  (interactive "fOpen .vstudio: ")
  (unless (and (fboundp 'cmacs-vidstudio-supported-p)
               (cmacs-vidstudio-supported-p))
    (user-error "cmacs was not built with --with-cmacs-vidstudio"))
  (let* ((data (with-temp-buffer
                 (insert-file-contents file)
                 (goto-char (point-min))
                 (read (current-buffer))))
         (handle (cmacs-vidstudio--build-from-sexp data))
         (buffer (generate-new-buffer
                  (format "*vidstudio %s*" (file-name-nondirectory file)))))
    (with-current-buffer buffer
      (cmacs-vidstudio-mode)
      (setq cmacs-vidstudio--handle handle
            cmacs-vidstudio--file file
            cmacs-vidstudio--playhead 0
            cmacs-vidstudio--active-track 0)
      (setq header-line-format
            '(:eval (format " vidstudio %dx%d @%.0ffps  frame %d/%d  track %d"
                            (cmacs-vidstudio-width cmacs-vidstudio--handle)
                            (cmacs-vidstudio-height cmacs-vidstudio--handle)
                            (cmacs-vidstudio-fps cmacs-vidstudio--handle)
                            cmacs-vidstudio--playhead
                            (cmacs-vidstudio-total-frames cmacs-vidstudio--handle)
                            cmacs-vidstudio--active-track)))
      (cmacs-vidstudio--render))
    (switch-to-buffer buffer)
    ;; Auto-open the clip-list side window (like imgedit's panels) BEFORE the
    ;; viewport attaches, so the FBO sizes to the reduced main window.
    (with-current-buffer buffer (cmacs-vidstudio--open-clips-panel))
    (cmacs-vidstudio--maybe-attach-viewport buffer)
    (with-current-buffer buffer (cmacs-vidstudio--render))
    (message "Opened %s" file)
    buffer))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.vstudio\\'" . cmacs-vidstudio--open-file))
(defun cmacs-vidstudio--open-file ()
  "`auto-mode-alist' entry: open the visited .vstudio via the editor."
  (let ((file buffer-file-name))
    (when file
      (kill-buffer (current-buffer))
      (cmacs-vidstudio-open file))))

;; ── Keyframe commands ──────────────────────────────────────────────────

(defconst cmacs-vidstudio--kf-param-alist
  '(("opacity" . 0) ("x" . 1) ("y" . 2) ("scale" . 3) ("rotation" . 4))
  "Animatable parameter names -> codes.")

(defun cmacs-vidstudio-add-keyframe-cmd (clip param value)
  "Add a keyframe for PARAM = VALUE on CLIP at the playhead.
The keyframe frame is the playhead minus the clip's start."
  (interactive
   (let* ((c (cmacs-vidstudio--read-clip))
          (pk (completing-read "Parameter: " cmacs-vidstudio--kf-param-alist
                               nil t "opacity")))
     (list c (cdr (assoc pk cmacs-vidstudio--kf-param-alist))
           (read-number (format "%s value: " pk) 1.0))))
  (let* ((start (cmacs-vidstudio-clip-start-frame cmacs-vidstudio--handle clip))
         (local (max 0 (- cmacs-vidstudio--playhead start))))
    (cmacs-vidstudio-add-keyframe cmacs-vidstudio--handle clip param local value)
    (message "Keyframe: clip %d param %d @local %d = %s"
             clip param local value)
    (cmacs-vidstudio--render)))

(defun cmacs-vidstudio-clear-keyframes-cmd (clip)
  "Clear all keyframes on CLIP."
  (interactive (list (cmacs-vidstudio--read-clip)))
  (cmacs-vidstudio-clear-keyframes cmacs-vidstudio--handle clip)
  (message "Cleared keyframes on clip %d" clip)
  (cmacs-vidstudio--render))

;; ── Audio commands ─────────────────────────────────────────────────────

(defun cmacs-vidstudio-add-audio (file start volume)
  "Add audio FILE at START seconds with VOLUME onto the audio lane."
  (interactive (list (read-file-name "Audio file: ")
                     (read-number "Start (seconds): " 0.0)
                     (read-number "Volume (0..1): " 1.0)))
  (let ((id (cmacs-vidstudio-add-audio-file
             cmacs-vidstudio--handle (expand-file-name file)
             (cmacs-vidstudio--secs-to-frames start) volume 0.0 0.0)))
    (message "Added audio #%d" id)
    (cmacs-vidstudio--render)))

(defun cmacs-vidstudio-extract-audio (clip)
  "Extract CLIP's audio onto the audio lane."
  (interactive (list (cmacs-vidstudio--read-clip)))
  (condition-case e
      (let ((id (cmacs-vidstudio-add-audio-from-clip
                 cmacs-vidstudio--handle clip 0 1.0)))
        (message "Extracted audio #%d from clip %d" id clip))
    (error (message "%s" (error-message-string e))))
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-set-audio-gain (id volume)
  "Set audio clip ID's VOLUME."
  (interactive (list (read-number "Audio clip id: " 0)
                     (read-number "Volume (0..1): " 1.0)))
  (cmacs-vidstudio-set-audio-volume cmacs-vidstudio--handle id volume)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-export-audio-cmd (path format)
  "Export the mixed audio to PATH in FORMAT (wav/mp3/aac/flac)."
  (interactive
   (list (read-file-name "Export audio to: " nil "audio.wav")
         (completing-read "Format: " '("wav" "mp3" "aac" "flac") nil t "wav")))
  (let ((fmt (or (cdr (assoc format '(("wav" . 0) ("mp3" . 1)
                                      ("aac" . 2) ("flac" . 3)))) 0)))
    (cmacs-vidstudio-export-audio cmacs-vidstudio--handle
                                  (expand-file-name path) fmt)
    (message "Wrote %s" path)))

(defun cmacs-vidstudio-import (file &optional in-str out-str seconds)
  "Import FILE (image or video) onto the active track.
For a video, IN-STR/OUT-STR are the source in/out points in seconds (blank
IN = start, blank OUT = the whole video); for an image, SECONDS is its
duration.  Video clips decode in the background; the timeline is usable
immediately and the preview pops in when the decode finishes."
  (interactive
   (let* ((f (read-file-name "Import clip: "))
          (ext (downcase (or (file-name-extension f) "")))
          (imagep (member ext '("png" "jpg" "jpeg" "bmp" "gif" "tga"))))
     (if imagep
         (list f nil nil (read-number "Duration (seconds): " 3.0))
       (list f
             (read-string "In point seconds (blank = start): ")
             (read-string "Out point seconds (blank = whole video): ")
             nil))))
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (imagep (member ext '("png" "jpg" "jpeg" "bmp" "gif" "tga")))
         (in (cmacs-vidstudio--maybe-secs in-str))
         (out (cmacs-vidstudio--maybe-secs out-str))
         (id (if imagep
                 (cmacs-vidstudio-add-image-clip
                  cmacs-vidstudio--handle cmacs-vidstudio--active-track
                  (expand-file-name file)
                  (cmacs-vidstudio--secs-to-frames (or seconds 3.0)))
               (cmacs-vidstudio-add-video-clip
                cmacs-vidstudio--handle cmacs-vidstudio--active-track
                (expand-file-name file) nil in out))))
    (cmacs-vidstudio--render)
    (if imagep
        (message "Imported clip #%d" id)
      (message "Imported clip #%d (%s; decoding in background…)" id
               (if (or in out)
                   (format "slice %s..%s" (or in "start") (or out "end"))
                 "whole video"))
      (cmacs-vidstudio--watch-decode id))))

(defun cmacs-vidstudio-add-color (color seconds)
  "Append a solid COLOR clip of SECONDS to the active track."
  (interactive (list (read-color "Colour: ") (read-number "Seconds: " 2.0)))
  (let* ((rgb (color-values color))
         (frames (cmacs-vidstudio--secs-to-frames seconds))
         (id (cmacs-vidstudio-add-solid-clip
              cmacs-vidstudio--handle cmacs-vidstudio--active-track frames
              (/ (nth 0 rgb) 256) (/ (nth 1 rgb) 256) (/ (nth 2 rgb) 256) 255)))
    (cmacs-vidstudio--render)
    (message "Added solid clip #%d" id)))

(defun cmacs-vidstudio-add-title (text seconds)
  "Append a TEXT title clip of SECONDS to the active track."
  (interactive (list (read-string "Title text: ") (read-number "Seconds: " 3.0)))
  (let* ((frames (cmacs-vidstudio--secs-to-frames seconds))
         (id (cmacs-vidstudio-add-text-clip
              cmacs-vidstudio--handle cmacs-vidstudio--active-track text frames
              255 255 255 255)))
    (cmacs-vidstudio--render)
    (message "Added title clip #%d" id)))

(defconst cmacs-vidstudio-easing-alist
  '(("linear" . 0)
    ("ease-in-quad" . 1)  ("ease-out-quad" . 2)  ("ease-in-out-quad" . 3)
    ("ease-in-cubic" . 4) ("ease-out-cubic" . 5) ("ease-in-out-cubic" . 6)
    ("ease-in-quart" . 7) ("ease-out-quart" . 8) ("ease-in-out-quart" . 9)
    ("ease-in-quint" . 10) ("ease-out-quint" . 11) ("ease-in-out-quint" . 12)
    ("ease-in-sine" . 13) ("ease-out-sine" . 14) ("ease-in-out-sine" . 15)
    ("ease-in-expo" . 16) ("ease-out-expo" . 17) ("ease-in-out-expo" . 18)
    ("ease-in-circ" . 19) ("ease-out-circ" . 20) ("ease-in-out-circ" . 21)
    ("ease-in-back" . 22) ("ease-out-back" . 23) ("ease-in-out-back" . 24)
    ("ease-in-elastic" . 25) ("ease-out-elastic" . 26)
    ("ease-in-out-elastic" . 27)
    ("ease-in-bounce" . 28) ("ease-out-bounce" . 29)
    ("ease-in-out-bounce" . 30))
  "All 31 LrgEasingType curve names -> codes (matches lrg-enums.h order).")

(defun cmacs-vidstudio-add-transition-cmd (clip-id type overlap easing)
  "Set CLIP-ID's leading TYPE transition, OVERLAP seconds, EASING curve."
  (interactive
   (list (cmacs-vidstudio--read-clip)
         (cdr (assoc (completing-read "Transition: "
                                      cmacs-vidstudio-transition-alist nil t)
                     cmacs-vidstudio-transition-alist))
         (read-number "Overlap (seconds): " 1.0)
         (cdr (assoc (completing-read "Easing: " cmacs-vidstudio-easing-alist
                                      nil t nil nil "linear")
                     cmacs-vidstudio-easing-alist))))
  (cmacs-vidstudio-set-transition cmacs-vidstudio--handle clip-id type
                                  (cmacs-vidstudio--secs-to-frames overlap)
                                  (or easing 0))
  (cmacs-vidstudio--render))

;; --------------------------------------------------------------------------
;; Picture-in-picture / video overlays (video-in-video)
;; --------------------------------------------------------------------------

(defconst cmacs-vidstudio-overlay-position-alist
  '(("bottom-right" . br) ("bottom-left" . bl) ("top-right" . tr)
    ("top-left" . tl) ("center" . center))
  "Picture-in-picture overlay position presets.")

(defun cmacs-vidstudio--overlay-box (position scale)
  "Return (X Y W H) for a PiP POSITION preset at SCALE (0..1) of the frame."
  (let* ((pw (cmacs-vidstudio-width cmacs-vidstudio--handle))
         (ph (cmacs-vidstudio-height cmacs-vidstudio--handle))
         (w (max 2 (round (* pw scale))))
         (h (max 2 (round (* ph scale))))
         (m (round (* pw 0.03)))
         (x (pcase position
              ((or 'tr 'br) (- pw w m))
              ('center (/ (- pw w) 2))
              (_ m)))
         (y (pcase position
              ((or 'bl 'br) (- ph h m))
              ('center (/ (- ph h) 2))
              (_ m))))
    (list (max 0 x) (max 0 y) w h)))

(defun cmacs-vidstudio-add-video-overlay (path position scale)
  "Import video PATH as a picture-in-picture overlay on a NEW track.
POSITION is a corner/center preset; SCALE is the overlay size as a fraction of
the frame (e.g. 0.3 = 30%).  Think webcam over gameplay: the overlay clip
composites over the video on the tracks below it."
  (interactive
   (list (read-file-name "Overlay video: " nil nil t)
         (cdr (assoc (completing-read "Position: "
                                      cmacs-vidstudio-overlay-position-alist
                                      nil t nil nil "bottom-right")
                     cmacs-vidstudio-overlay-position-alist))
         (read-number "Size (fraction of frame, 0..1): " 0.3)))
  (let* ((track (cmacs-vidstudio-add-track cmacs-vidstudio--handle))
         (id (cmacs-vidstudio-add-video-clip cmacs-vidstudio--handle track
                                             (expand-file-name path) nil))
         (box (cmacs-vidstudio--overlay-box position scale)))
    (apply #'cmacs-vidstudio-set-clip-box cmacs-vidstudio--handle id box)
    (setq cmacs-vidstudio--selected-clip id)
    (cmacs-vidstudio--render)
    (message "Added PiP overlay clip #%d on track %d (%s, %d%%)"
             id track position (round (* scale 100)))))

(defun cmacs-vidstudio-set-clip-box-cmd (clip position scale)
  "Make CLIP a picture-in-picture overlay at POSITION preset + SCALE, or clear
it (choose a scale of 0)."
  (interactive
   (list (cmacs-vidstudio--read-clip)
         (cdr (assoc (completing-read "Position: "
                                      cmacs-vidstudio-overlay-position-alist
                                      nil t nil nil "bottom-right")
                     cmacs-vidstudio-overlay-position-alist))
         (read-number "Size (fraction 0..1, 0 = full frame): " 0.3)))
  (if (<= scale 0.0)
      (progn (cmacs-vidstudio-set-clip-box cmacs-vidstudio--handle clip 0 0 0 0)
             (message "Cleared PiP box on clip #%s (full frame)" clip))
    (apply #'cmacs-vidstudio-set-clip-box cmacs-vidstudio--handle clip
           (cmacs-vidstudio--overlay-box position scale))
    (message "Clip #%s is now a PiP overlay (%s, %d%%)" clip position
             (round (* scale 100))))
  (cmacs-vidstudio--render))

;; --------------------------------------------------------------------------
;; Post-import length / offset editing (in/out slice + on-timeline duration)
;; --------------------------------------------------------------------------

(defun cmacs-vidstudio--frames-to-secs (frames)
  "Convert FRAMES to seconds at the project frame rate."
  (/ frames (max 1.0 (cmacs-vidstudio-fps cmacs-vidstudio--handle))))

(defun cmacs-vidstudio-set-clip-trim-cmd (clip in-sec out-sec)
  "Set video CLIP's source IN-SEC..OUT-SEC slice -- which part of the original
video plays -- recomputing its on-timeline length.  Defaults show the current
slice; OUT-SEC of 0 means the source end."
  (interactive
   (let* ((clip (cmacs-vidstudio--read-clip))
          (sl (cmacs-vidstudio-clip-slice cmacs-vidstudio--handle clip)))
     (unless sl
       (user-error "Clip #%s is not a video clip (no source slice)" clip))
     (list clip
           (read-number
            (format "In point (sec; source is %.2fs): " (nth 2 sl))
            (nth 0 sl))
           (read-number "Out point (sec; 0 = source end): " (nth 1 sl)))))
  (if (cmacs-vidstudio-set-clip-trim cmacs-vidstudio--handle clip in-sec out-sec)
      (let ((sl (cmacs-vidstudio-clip-slice cmacs-vidstudio--handle clip)))
        (cmacs-vidstudio--render)
        (message "Clip #%s slice -> %.2f..%.2fs (%.2fs on timeline)"
                 clip (nth 0 sl) (nth 1 sl)
                 (cmacs-vidstudio--frames-to-secs
                  (cmacs-vidstudio-clip-duration cmacs-vidstudio--handle clip))))
    (user-error "Clip #%s has no source slice to trim" clip)))

(defun cmacs-vidstudio-set-clip-duration-cmd (clip seconds)
  "Set CLIP's on-timeline length to SECONDS (how long it occupies the
timeline).  For a video this holds the last frame when extended past its
source slice; to change which part of the source plays use \[cmacs-vidstudio-set-clip-trim-cmd]."
  (interactive
   (let ((clip (cmacs-vidstudio--read-clip)))
     (list clip
           (read-number "On-timeline duration (seconds): "
                        (cmacs-vidstudio--frames-to-secs
                         (cmacs-vidstudio-clip-duration
                          cmacs-vidstudio--handle clip))))))
  (cmacs-vidstudio-set-clip-duration cmacs-vidstudio--handle clip
                                     (cmacs-vidstudio--secs-to-frames seconds))
  (cmacs-vidstudio--render)
  (message "Clip #%s on-timeline duration -> %.2fs" clip seconds))

(defun cmacs-vidstudio-add-gradient (a b seconds)
  "Append a gradient clip from colour A to B of SECONDS to the active track."
  (interactive (list (read-color "From: ") (read-color "To: ")
                     (read-number "Seconds: " 2.0)))
  (let ((ca (color-values a)) (cb (color-values b)))
    (cmacs-vidstudio-add-gradient-clip
     cmacs-vidstudio--handle cmacs-vidstudio--active-track
     (cmacs-vidstudio--secs-to-frames seconds)
     (list (/ (nth 0 ca) 256) (/ (nth 1 ca) 256) (/ (nth 2 ca) 256) 255)
     (list (/ (nth 0 cb) 256) (/ (nth 1 cb) 256) (/ (nth 2 cb) 256) 255))
    (cmacs-vidstudio--render)))

(defun cmacs-vidstudio-add-effect-cmd (clip-id type)
  "Append effect TYPE to CLIP-ID."
  (interactive
   (list (read-number "Clip id: ")
         (cdr (assoc (completing-read "Effect: "
                                      cmacs-vidstudio-effect-alist nil t)
                     cmacs-vidstudio-effect-alist))))
  (cmacs-vidstudio-add-effect cmacs-vidstudio--handle clip-id type)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-split-at-playhead (clip-id)
  "Split CLIP-ID at the current playhead (relative to its start)."
  (interactive (list (read-number "Clip id: ")))
  (let* ((start (cmacs-vidstudio-clip-start-frame cmacs-vidstudio--handle clip-id))
         (at (- cmacs-vidstudio--playhead start)))
    (if (cmacs-vidstudio-split-clip cmacs-vidstudio--handle clip-id at)
        (cmacs-vidstudio--render)
      (message "Cannot split there"))))

;; --------------------------------------------------------------------------
;; Transport
;; --------------------------------------------------------------------------

(defun cmacs-vidstudio-set-playhead-cmd (frame)
  "Set the playhead to FRAME."
  (interactive (list (read-number "Frame: " cmacs-vidstudio--playhead)))
  (cmacs-vidstudio--seek frame))

(defun cmacs-vidstudio-step-forward ()
  "Advance the playhead by one frame."
  (interactive)
  (cmacs-vidstudio--seek (1+ cmacs-vidstudio--playhead)))

(defun cmacs-vidstudio-step-back ()
  "Move the playhead back one frame."
  (interactive)
  (cmacs-vidstudio--seek (1- cmacs-vidstudio--playhead)))

(defun cmacs-vidstudio-pause ()
  "Stop playback and re-render the full-resolution frame."
  (interactive)
  (when cmacs-vidstudio--play-timer
    (cancel-timer cmacs-vidstudio--play-timer)
    (setq cmacs-vidstudio--play-timer nil)
    (cmacs-vidstudio--audio-stop)         ; stop preview audio
    (cmacs-vidstudio--cache-stop)         ; drop the playback frame cache
    ;; restore the full-res preview and repaint the current frame crisply
    (when cmacs-vidstudio--paused-scale
      (setq cmacs-vidstudio--preview-scale cmacs-vidstudio--paused-scale
            cmacs-vidstudio--paused-scale nil))
    (cmacs-vidstudio--render)))

(defun cmacs-vidstudio-play ()
  "Play from the playhead (toggles with pause).

The playhead is advanced from the wall clock, so slow frames are SKIPPED
rather than stretched, and no frame is rendered while user input is
pending — playback never freezes the editor.  Each rendered frame is
followed by an explicit `redisplay': when a render takes longer than the
timer period, due timers otherwise run back-to-back and Emacs never
reaches its normal redisplay, leaving the screen frozen while the buffer
silently updates.  Starting play at the end of the timeline rewinds."
  (interactive)
  (if cmacs-vidstudio--play-timer
      (cmacs-vidstudio-pause)
    (let ((total (cmacs-vidstudio-total-frames cmacs-vidstudio--handle)))
      (when (<= total 0)
        (user-error "vidstudio: empty timeline — import a clip first (i)"))
      (when (>= cmacs-vidstudio--playhead (1- total))
        (setq cmacs-vidstudio--playhead 0))
      ;; Drop to a low-res proxy while playing (near-real-time); restored on
      ;; pause.  The live viewport path renders full frames but still benefits
      ;; from the frame-skip loop below.
      (unless (>= cmacs-vidstudio-playback-scale 1.0)
        (setq cmacs-vidstudio--paused-scale cmacs-vidstudio--preview-scale
              cmacs-vidstudio--preview-scale cmacs-vidstudio-playback-scale))
      ;; Background frame cache: prefetch upcoming frames so the play tick
      ;; displays a ready frame instead of rendering synchronously.
      (cmacs-vidstudio--cache-start)
      (let ((buf (current-buffer))
            (fps (max 1.0 (cmacs-vidstudio-fps cmacs-vidstudio--handle)))
            (tick (/ 1.0 (max 1 cmacs-vidstudio-preview-fps))))
        (setq cmacs-vidstudio--play-start-frame cmacs-vidstudio--playhead
              cmacs-vidstudio--play-t0 (float-time))
        (cmacs-vidstudio--audio-start
         (/ cmacs-vidstudio--play-start-frame fps))
        (setq cmacs-vidstudio--play-timer
              (run-at-time
               tick tick
               (lambda ()
                 (if (not (buffer-live-p buf))
                     nil
                   (with-current-buffer buf
                     (let* ((now-total (cmacs-vidstudio-total-frames
                                        cmacs-vidstudio--handle))
                            (target (+ cmacs-vidstudio--play-start-frame
                                       (floor (* (- (float-time)
                                                    cmacs-vidstudio--play-t0)
                                                 fps)))))
                       (cond
                        ((>= target now-total)
                         (setq cmacs-vidstudio--playhead (max 0 (1- now-total)))
                         (cmacs-vidstudio-pause)
                         (cmacs-vidstudio--render)
                         (redisplay)
                         (message "vidstudio: reached the end"))
                        ;; The user comes first: skip this tick, catch up
                        ;; on the next (the wall-clock target self-corrects).
                        ((input-pending-p))
                        ((/= target cmacs-vidstudio--playhead)
                         (setq cmacs-vidstudio--playhead target)
                         (cmacs-vidstudio--render)
                         ;; Force the repaint NOW — see the docstring.
                         (redisplay)))))))))
        (message "vidstudio: playing (press %s again to pause)"
                 (if (fboundp 'evil-mode) "p" "SPC/p"))))))

;; --------------------------------------------------------------------------
;; Export
;; --------------------------------------------------------------------------

(defvar-local cmacs-vidstudio--export-process nil
  "The running background export process for this project, or nil.")

(defun cmacs-vidstudio--export-async (path export-form what)
  "Export the current project to PATH in a background Emacs subprocess.
EXPORT-FORM is a Lisp-form string run in the subprocess with `h' bound to the
reloaded project handle and `out' to PATH.  WHAT names the format for
messages.  The heavy render + ffmpeg run out-of-process via a `make-process'
sentinel (so the editor stays responsive), and the ffmpeg progress line is
echoed to the *Messages* buffer every 30 seconds while it runs."
  (unless (fboundp 'cmacs-vidstudio-serialize)
    (user-error "This build cannot serialize projects for background export"))
  (when (process-live-p cmacs-vidstudio--export-process)
    (user-error "An export is already running for this project"))
  (let* ((path (expand-file-name path))
         (sexp (cmacs-vidstudio-serialize cmacs-vidstudio--handle))
         (tmp (make-temp-file "cmvs-export" nil ".vstudio"))
         (lispdir (file-name-directory (locate-library "cmacs-vidstudio")))
         (bin (expand-file-name invocation-name invocation-directory))
         (buf (generate-new-buffer " *vidstudio-export-log*"))
         (pbuf (current-buffer))
         (name (file-name-nondirectory path))
         (progress nil)     ; latest ffmpeg stats line (shared by filter+timer)
         (ptimer nil)
         (proc nil))
    (with-temp-file tmp (insert sexp))
    (setq proc
          (make-process
           :name "vidstudio-export" :buffer buf :noquery t
           :command
           (list bin "-Q" "-batch" "-L" lispdir "-l" "cmacs-vidstudio" "--eval"
                 (format "(let* ((data (with-temp-buffer (insert-file-contents %S) (read (current-buffer)))) (h (cmacs-vidstudio--build-from-sexp data)) (out %S)) %s)"
                         tmp path export-form))
           :filter
           (lambda (p chunk)
             ;; keep the full log for debugging
             (when (buffer-live-p (process-buffer p))
               (with-current-buffer (process-buffer p)
                 (goto-char (point-max)) (insert chunk)))
             ;; ffmpeg -stats lines arrive \r-separated: keep the last one
             (dolist (ln (split-string chunk "[\r\n]+" t))
               (when (string-match-p "frame=.*time=" ln)
                 (setq progress (string-trim ln)))))
           :sentinel
           (lambda (p _event)
             (when (memq (process-status p) '(exit signal))
               (when (timerp ptimer) (cancel-timer ptimer))
               (ignore-errors (delete-file tmp))
               (let ((ok (and (eq (process-status p) 'exit)
                              (zerop (process-exit-status p))
                              (file-exists-p path))))
                 (when (buffer-live-p pbuf)
                   (with-current-buffer pbuf
                     (setq cmacs-vidstudio--export-process nil)))
                 (if ok
                     (progn (message "vidstudio: exported %s -> %s" what
                                     (abbreviate-file-name path))
                            (kill-buffer buf))
                   (message "vidstudio: %s export FAILED (see %s)"
                            what (buffer-name buf))))))))
    (setq cmacs-vidstudio--export-process proc)
    ;; Echo ffmpeg progress to *Messages* every 30s while the export runs.
    (setq ptimer
          (run-at-time
           30 30
           (lambda ()
             (if (process-live-p proc)
                 (when progress
                   (message "vidstudio export %s: %s" name progress))
               (when (timerp ptimer) (cancel-timer ptimer))))))
    (message "vidstudio: exporting %s to %s in the background (progress every 30s)"
             what name)))

(defconst cmacs-vidstudio-codec-alist
  '(("H.264  (libx264, .mp4)" . 0)
    ("H.265  (libx265, .mp4)" . 2)
    ("AV1    (libsvtav1, .mp4)" . 4)
    ("VP9    (libvpx-vp9, .webm)" . 1)
    ("ProRes (prores_ks, .mov)" . 3))
  "Export codec names -> codec codes (see cmacs-vidstudio-export-video).")

(defconst cmacs-vidstudio-preset-list
  '("ultrafast" "superfast" "veryfast" "faster" "fast" "medium" "slow"
    "slower" "veryslow")
  "x264/x265 encoder presets, fastest -> slowest.")

(defun cmacs-vidstudio-export-video-cmd (path codec preset)
  "Export the project to PATH in the background using CODEC + PRESET.
CODEC picks the encoder; PRESET (x264/x265) trades speed for size -- the
default `veryfast' is much quicker than ffmpeg's slow `medium' default."
  (interactive
   (list (read-file-name "Export video to: ")
         (cdr (assoc (completing-read "Codec: " cmacs-vidstudio-codec-alist
                                      nil t nil nil "H.264  (libx264, .mp4)")
                     cmacs-vidstudio-codec-alist))
         (completing-read "Preset (speed/size): " cmacs-vidstudio-preset-list
                          nil t nil nil "veryfast")))
  (cmacs-vidstudio--export-async
   path
   (format "(progn (cmacs-vidstudio-set-export-preset h %S) (cmacs-vidstudio-export-video h out %d))"
           (or preset "veryfast") (or codec 0))
   "video"))

(defun cmacs-vidstudio-export-gif-cmd (path)
  "Export the project to PATH as an animated GIF in the background."
  (interactive "FExport GIF to: ")
  (cmacs-vidstudio--export-async
   path "(cmacs-vidstudio-export-gif h out)" "GIF"))

;; --------------------------------------------------------------------------
;; Right-click context menu (GTK under pgtk, in-engine under --lrg)
;; --------------------------------------------------------------------------

(defun cmacs-vidstudio-add-rectangle (x y w h color seconds)
  "Add a filled rectangle shape clip."
  (interactive (list (read-number "X: " 0) (read-number "Y: " 0)
                     (read-number "W: " 200) (read-number "H: " 100)
                     (read-color "Fill: ") (read-number "Seconds: " 2.0)))
  (let ((c (color-values color)))
    (cmacs-vidstudio-add-shape-rect
     cmacs-vidstudio--handle cmacs-vidstudio--active-track
     (cmacs-vidstudio--secs-to-frames seconds) x y w h
     (list (/ (nth 0 c) 256) (/ (nth 1 c) 256) (/ (nth 2 c) 256) 255))
    (cmacs-vidstudio--render)))

(defun cmacs-vidstudio-add-captions (srt seconds)
  "Add captions from an SRT file."
  (interactive (list (read-file-name "SRT file: " nil nil t)
                     (read-number "Seconds: " 5.0)))
  (cmacs-vidstudio-add-caption cmacs-vidstudio--handle
                               cmacs-vidstudio--active-track
                               (cmacs-vidstudio--secs-to-frames seconds)
                               (expand-file-name srt))
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-add-loop (path seconds loop-secs)
  "Loop video PATH for SECONDS, repeating every LOOP-SECS (0 = whole)."
  (interactive (list (read-file-name "Video: " nil nil t)
                     (read-number "Duration (seconds): " 4.0)
                     (read-number "Loop period (seconds, 0=whole): " 0.0)))
  (cmacs-vidstudio-add-loop-clip cmacs-vidstudio--handle
                                 cmacs-vidstudio--active-track
                                 (expand-file-name path)
                                 (cmacs-vidstudio--secs-to-frames seconds)
                                 loop-secs)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-add-freeze (path seconds freeze-at)
  "Freeze video PATH at FREEZE-AT seconds, held for SECONDS."
  (interactive (list (read-file-name "Video: " nil nil t)
                     (read-number "Duration (seconds): " 2.0)
                     (read-number "Freeze at (seconds): " 0.0)))
  (cmacs-vidstudio-add-freeze-clip cmacs-vidstudio--handle
                                   cmacs-vidstudio--active-track
                                   (expand-file-name path)
                                   (cmacs-vidstudio--secs-to-frames seconds)
                                   freeze-at)
  (cmacs-vidstudio--render))

(defconst cmacs-vidstudio-text-effect-alist
  '(("none" . 0) ("shake" . 1) ("wave" . 2) ("rainbow" . 3)
    ("typewriter" . 4) ("fade-in" . 5) ("pulse" . 6))
  "Per-character text-effect names -> LrgTextEffectType codes.")

(defun cmacs-vidstudio-add-animated-text (text seconds font-size effect)
  "Add an animated text clip: TEXT with a per-character EFFECT."
  (interactive
   (list (read-string "Text: " "Hello")
         (read-number "Seconds: " 3.0)
         (read-number "Font size: " 32)
         (cdr (assoc (completing-read "Effect: "
                                      cmacs-vidstudio-text-effect-alist nil t "wave")
                     cmacs-vidstudio-text-effect-alist))))
  (cmacs-vidstudio-add-rich-text cmacs-vidstudio--handle
                                 cmacs-vidstudio--active-track text
                                 (cmacs-vidstudio--secs-to-frames seconds)
                                 font-size (or effect 0))
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio--menu ()
  "Return the video-editor context-menu alist (shared native + viewport)."
  '("Video editor"
            ("Add"
             ("Import clip…" . cmacs-vidstudio-import)
             ("Solid colour…" . cmacs-vidstudio-add-color)
             ("Title…" . cmacs-vidstudio-add-title)
             ("Animated text…" . cmacs-vidstudio-add-animated-text)
             ("Gradient…" . cmacs-vidstudio-add-gradient)
             ("Rectangle…" . cmacs-vidstudio-add-rectangle)
             ("Captions (SRT)…" . cmacs-vidstudio-add-captions)
             ("Loop video…" . cmacs-vidstudio-add-loop)
             ("Freeze frame…" . cmacs-vidstudio-add-freeze)
             ("Video overlay / PiP…" . cmacs-vidstudio-add-video-overlay)
             ("New track" . cmacs-vidstudio-add-track-cmd))
            ("Clip"
             ("Transition…" . cmacs-vidstudio-add-transition-cmd)
             ("Effect…" . cmacs-vidstudio-add-effect-cmd)
             ("Effect parameter…" . cmacs-vidstudio-set-effect-parameter)
             ("Opacity…" . cmacs-vidstudio-set-clip-opacity)
             ("Blend mode…" . cmacs-vidstudio-set-clip-blend)
             ("Transform (pos/scale)…" . cmacs-vidstudio-set-clip-transform)
             ("Make PiP overlay…" . cmacs-vidstudio-set-clip-box-cmd)
             ("Playback speed…" . cmacs-vidstudio-set-clip-speed)
             ("Add keyframe…" . cmacs-vidstudio-add-keyframe-cmd)
             ("Clear keyframes…" . cmacs-vidstudio-clear-keyframes-cmd)
             ("Trim in/out (source slice)…" . cmacs-vidstudio-set-clip-trim-cmd)
             ("Set on-timeline duration…" . cmacs-vidstudio-set-clip-duration-cmd)
             ("Split at playhead…" . cmacs-vidstudio-split-at-playhead)
             ("Active track…" . cmacs-vidstudio-set-active-track))
            ("Transport"
             ("Play/pause" . cmacs-vidstudio-play)
             ("Step forward" . cmacs-vidstudio-step-forward)
             ("Step back" . cmacs-vidstudio-step-back)
             ("Go to frame…" . cmacs-vidstudio-set-playhead-cmd))
            ("Project"
             ("Save" . cmacs-vidstudio-save)
             ("Save as…" . cmacs-vidstudio-save-as)
             ("Open…" . cmacs-vidstudio-open))
            ("Audio"
             ("Add audio file…" . cmacs-vidstudio-add-audio)
             ("Extract from clip…" . cmacs-vidstudio-extract-audio)
             ("Set volume…" . cmacs-vidstudio-set-audio-gain)
             ("Export audio…" . cmacs-vidstudio-export-audio-cmd))
            ("Export"
             ("Video (MP4)…" . cmacs-vidstudio-export-video-cmd)
             ("Animated GIF…" . cmacs-vidstudio-export-gif-cmd)
             ("Still frame…" . cmacs-vidstudio-export-still-cmd)
             ("Quality (CRF)…" . cmacs-vidstudio-set-export-quality-cmd))))

(defun cmacs-vidstudio-context-menu (event)
  "Pop the video-editor context menu for mouse EVENT (native path).
Routes through `cmacs-libregnum-popup-menu' (native GTK under pgtk,
in-engine libregnum menu under --lrg)."
  (interactive "e")
  ;; A mouse command runs with the SELECTED window's buffer current, which
  ;; may not be the clicked editor buffer — select the event's window so the
  ;; menu commands see this buffer's project handle.
  (let ((win (posn-window (event-start event))))
    (when (and (windowp win) (window-live-p win))
      (select-window win)
      (set-buffer (window-buffer win))))
  (unless cmacs-vidstudio--handle
    (user-error "vidstudio: this click did not land on an editor buffer"))
  (let ((choice (cmacs-libregnum-popup-menu event (cmacs-vidstudio--menu))))
    (when (commandp choice)
      (call-interactively choice))))

;; --------------------------------------------------------------------------
;; Mode
;; --------------------------------------------------------------------------

(transient-define-prefix cmacs-vidstudio-help ()
  "Keybinding cheat-sheet for `cmacs-vidstudio-mode'.
Press a key to run its command, or q / C-g to dismiss."
  [:description "cmacs-vidstudio — video editor  (right-click for the full menu)"
   ["Add"
    ("i" "Import clip…" cmacs-vidstudio-import)
    ("o" "Video overlay / PiP…" cmacs-vidstudio-add-video-overlay)
    ("C" "Colour clip…" cmacs-vidstudio-add-color)
    ("T" "Title…" cmacs-vidstudio-add-title)
    ("n" "New track" cmacs-vidstudio-add-track-cmd)]
   ["Clip / length"
    ("r" "Trim in/out (source)…" cmacs-vidstudio-set-clip-trim-cmd)
    ("d" "Set on-timeline duration…" cmacs-vidstudio-set-clip-duration-cmd)
    ("t" "Transition…" cmacs-vidstudio-add-transition-cmd)
    ("e" "Effect…" cmacs-vidstudio-add-effect-cmd)
    ("s" "Split at playhead" cmacs-vidstudio-split-at-playhead)
    ("k" "Keyframe…" cmacs-vidstudio-add-keyframe-cmd)]
   ["Timeline"
    ("a" "Active track…" cmacs-vidstudio-set-active-track)
    ("g" "Go to frame…" cmacs-vidstudio-set-playhead-cmd)]
   ["Audio"
    ("A" "Add audio…" cmacs-vidstudio-add-audio)
    ("V" "Audio gain…" cmacs-vidstudio-set-audio-gain)]]
  [["Transport"
    ("p" "Play / pause  (or SPC)" cmacs-vidstudio-play)
    ("<right>" "Step forward" cmacs-vidstudio-step-forward)
    ("<left>" "Step back" cmacs-vidstudio-step-back)]
   ["Project"
    ("w" "Save  (C-x C-s)" cmacs-vidstudio-save)
    ("E" "Export video…" cmacs-vidstudio-export-video-cmd)
    ("G" "Export GIF…" cmacs-vidstudio-export-gif-cmd)]
   ["View"
    ("L" "Clip list panel" cmacs-vidstudio-toggle-clips-panel)]])

(defvar cmacs-vidstudio-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-vidstudio-mode'.")

;; Bind on every load (reload-safe; the defvar above is a no-op once bound).
(let ((map cmacs-vidstudio-mode-map))
    (define-key map (kbd "i") #'cmacs-vidstudio-import)
    (define-key map (kbd "o") #'cmacs-vidstudio-add-video-overlay)
    (define-key map (kbd "C") #'cmacs-vidstudio-add-color)
    (define-key map (kbd "T") #'cmacs-vidstudio-add-title)
    (define-key map (kbd "n") #'cmacs-vidstudio-add-track-cmd)
    (define-key map (kbd "a") #'cmacs-vidstudio-set-active-track)
    (define-key map (kbd "t") #'cmacs-vidstudio-add-transition-cmd)
    (define-key map (kbd "e") #'cmacs-vidstudio-add-effect-cmd)
    (define-key map (kbd "s") #'cmacs-vidstudio-split-at-playhead)
    (define-key map (kbd "g") #'cmacs-vidstudio-set-playhead-cmd)
    ;; `p' is the primary play toggle: under Doom, SPC is the leader key
    ;; (a general.el override map that outranks even an evil-overriding
    ;; mode map), so SPC only works in vanilla Emacs.
    (define-key map (kbd "p") #'cmacs-vidstudio-play)
    (define-key map (kbd "SPC") #'cmacs-vidstudio-play)
    (define-key map (kbd "<right>") #'cmacs-vidstudio-step-forward)
    (define-key map (kbd "<left>") #'cmacs-vidstudio-step-back)
    (define-key map (kbd "C-x C-s") #'cmacs-vidstudio-save)
    (define-key map (kbd "k") #'cmacs-vidstudio-add-keyframe-cmd)
    (define-key map (kbd "A") #'cmacs-vidstudio-add-audio)
    (define-key map (kbd "V") #'cmacs-vidstudio-set-audio-gain)
    (define-key map (kbd "E") #'cmacs-vidstudio-export-video-cmd)
    (define-key map (kbd "G") #'cmacs-vidstudio-export-gif-cmd)
    (define-key map (kbd "L") #'cmacs-vidstudio-toggle-clips-panel)
    (define-key map (kbd "?") #'cmacs-vidstudio-help)
    (define-key map (kbd "<mouse-3>") #'cmacs-vidstudio-context-menu))

(defun cmacs-vidstudio--viewport-available-p ()
  "Non-nil when a live libregnum GL viewport can be used for the preview."
  (and (fboundp 'cmacs-vidstudio-viewport-render)
       (fboundp 'cmacs-libregnum-supported-p)
       (cmacs-libregnum-supported-p)
       (or (display-graphic-p) (eq (framep-on-display) 'lrg))))

(defun cmacs-vidstudio--vp-context-menu (buffer _dx _dy fx fy &optional clip-id)
  "Pop the video-editor context menu for a viewport right-click at (FX FY).
CLIP-ID is the timeline clip under the cursor (-1/nil = none); when set, menu
commands act on it without prompting for a clip id."
  (let ((cid (and (integerp clip-id) (>= clip-id 0) clip-id)))
    (when cid
      (with-current-buffer buffer
        (setq cmacs-vidstudio--selected-clip cid)
        (cmacs-vidstudio--render)))
    (run-at-time
     0 nil
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((cmacs-vidstudio--context-clip cid)
                 (choice (cmacs-libregnum-popup-menu
                          (list (list fx fy) (selected-window))
                          (cmacs-vidstudio--menu))))
             (when (commandp choice) (call-interactively choice)))))))))

(defun cmacs-vidstudio--label-font-file ()
  "Resolve the Emacs default face's font family to a TTF/OTF file path.
Used so the timeline clip-id labels are drawn in the same font as the
editor.  Returns nil when it cannot be resolved (falls back to the
built-in font)."
  (ignore-errors
    (let ((family (face-attribute 'default :family nil t)))
      (when (and (stringp family)
                 (not (string-empty-p family))
                 (executable-find "fc-match"))
        (let ((f (string-trim
                  (shell-command-to-string
                   (format "fc-match -f '%%{file}' %s"
                           (shell-quote-argument family))))))
          (and (stringp f) (> (length f) 0) (file-readable-p f) f))))))

(defun cmacs-vidstudio--maybe-attach-viewport (buffer)
  "Attach a live libregnum viewport to BUFFER, if available.
Sets `cmacs-vidstudio--live'; leaves it nil (native path) on failure."
  (when (cmacs-vidstudio--viewport-available-p)
    (condition-case _err
        (let ((win (get-buffer-window buffer)))
          ;; Size the FBO to the window BODY (text area), not the full window:
          ;; the paint + click-mapping use window-body dimensions, so an FBO
          ;; sized to window-pixel-height is taller than its paint region and
          ;; the bottom timeline strip spills onto the modeline.
          (cmacs-libregnum-attach
           buffer
           (max 64 (if win (window-body-width win t) 640))
           (max 64 (if win (window-body-height win t) 480)))
          (cmacs-libregnum-image-enter buffer t)
          (cmacs-libregnum-image-set-checker buffer nil)
          ;; Draw the timeline clip-id labels in the Emacs UI font (so the
          ;; strip ids match the editor), not raylib's default bitmap font.
          (when (fboundp 'cmacs-libregnum-image-set-label-font)
            (let ((ff (cmacs-vidstudio--label-font-file)))
              (when ff
                (ignore-errors
                  (cmacs-libregnum-image-set-label-font buffer ff)))))
          (with-current-buffer buffer
            (setq cmacs-libregnum-image-context-menu-function
                  #'cmacs-vidstudio--vp-context-menu
                  cmacs-libregnum-image-timeline-press-function
                  #'cmacs-vidstudio--tl-press
                  cmacs-libregnum-image-timeline-drag-function
                  #'cmacs-vidstudio--tl-drag
                  cmacs-libregnum-image-timeline-release-function
                  #'cmacs-vidstudio--tl-release
                  cmacs-vidstudio--live t)))
      (error (setq cmacs-vidstudio--live nil)))))

;; -- Interactive timeline strip: click to scrub + select, drag a clip's right
;;    edge to trim its duration (state vars declared near the top). --
(defun cmacs-vidstudio--tl-press (buffer frame clip-id edge)
  "Timeline press: select CLIP-ID, scrub to FRAME, arm a right-edge trim when
EDGE is 1 (the cursor is on the clip's right/out edge)."
  (with-current-buffer buffer
    (setq cmacs-vidstudio--selected-clip (and (>= clip-id 0) clip-id)
          cmacs-vidstudio--tl-trim (and (>= clip-id 0) (= edge 1) clip-id))
    (cmacs-vidstudio--seek frame t)))

(defun cmacs-vidstudio--tl-drag (buffer frame _clip-id _edge)
  "Timeline drag: trim the armed clip's right edge to FRAME, else scrub.
For a video clip this moves the source out-point (showing more/less of the
original, capped at the source end); for other clips it sets the on-timeline
length.  Numeric in/out editing is on \[cmacs-vidstudio-set-clip-trim-cmd]."
  (with-current-buffer buffer
    (if cmacs-vidstudio--tl-trim
        (let* ((id cmacs-vidstudio--tl-trim)
               (start (cmacs-vidstudio-clip-start-frame
                       cmacs-vidstudio--handle id))
               (newdur (max 1 (- frame start)))
               (sl (cmacs-vidstudio-clip-slice cmacs-vidstudio--handle id)))
          (ignore-errors
            (if sl
                ;; video: set the out-point so the clip shows NEWDUR frames
                (cmacs-vidstudio-set-clip-trim
                 cmacs-vidstudio--handle id (nth 0 sl)
                 (+ (nth 0 sl)
                    (/ newdur (float (cmacs-vidstudio-fps
                                      cmacs-vidstudio--handle)))))
              (cmacs-vidstudio-set-clip-duration
               cmacs-vidstudio--handle id newdur)))
          (cmacs-vidstudio--render))
      ;; scrub: --seek re-anchors the video; audio restarts on release (not
      ;; every motion) so the player process is not churned.
      (cmacs-vidstudio--seek frame t))))

(defun cmacs-vidstudio--tl-release (buffer _frame _clip-id _edge)
  "Timeline release: end a trim gesture, or re-sync preview audio to the final
playhead after a scrub."
  (with-current-buffer buffer
    (if cmacs-vidstudio--tl-trim
        (progn
          (setq cmacs-vidstudio--tl-trim nil)
          (message "Trimmed clip #%s" cmacs-vidstudio--selected-clip)
          (cmacs-vidstudio--render))
      ;; a scrub just ended -- restart audio at where it landed
      (if cmacs-vidstudio--play-timer
          (cmacs-vidstudio--seek cmacs-vidstudio--playhead)
        (cmacs-vidstudio--render)))))

(defun cmacs-vidstudio--cleanup ()
  "Stop playback and free the project when the buffer dies."
  (cmacs-vidstudio--cache-stop)
  (cmacs-vidstudio--audio-stop)
  (when (and cmacs-vidstudio--audio-wav
             (file-exists-p cmacs-vidstudio--audio-wav))
    (ignore-errors (delete-file cmacs-vidstudio--audio-wav)))
  (when cmacs-vidstudio--play-timer
    (cancel-timer cmacs-vidstudio--play-timer))
  (when cmacs-vidstudio--decode-timer
    (cancel-timer cmacs-vidstudio--decode-timer))
  ;; Autosave a named project to FILE~ on kill (cheap crash-recovery point).
  (when (and cmacs-vidstudio--file cmacs-vidstudio--handle
             (fboundp 'cmacs-vidstudio-serialize))
    (ignore-errors
      (with-temp-file (concat cmacs-vidstudio--file "~")
        (insert (cmacs-vidstudio-serialize cmacs-vidstudio--handle) "\n"))))
  ;; Detach the viewport before freeing the project (avoid a dangling ctx).
  (when (and cmacs-vidstudio--live
             (fboundp 'cmacs-libregnum-attached-p)
             (cmacs-libregnum-attached-p (current-buffer)))
    (ignore-errors (cmacs-libregnum-detach (current-buffer))))
  (when (and cmacs-vidstudio--handle (fboundp 'cmacs-vidstudio-free))
    (ignore-errors (cmacs-vidstudio-free cmacs-vidstudio--handle))
    (setq cmacs-vidstudio--handle nil)))

(define-derived-mode cmacs-vidstudio-mode special-mode "VidStudio"
  "Major mode for the Reel-based video editor."
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'cmacs-vidstudio--cleanup nil t))

;;;###autoload
(defun cmacs-vidstudio (width height fps)
  "Create a new WIDTH x HEIGHT video project at FPS frames/second."
  (interactive (list (read-number "Width: " cmacs-vidstudio-default-width)
                     (read-number "Height: " cmacs-vidstudio-default-height)
                     (read-number "FPS: " cmacs-vidstudio-default-fps)))
  (unless (and (fboundp 'cmacs-vidstudio-supported-p)
               (cmacs-vidstudio-supported-p))
    (user-error "cmacs was not built with --with-cmacs-vidstudio"))
  (let ((handle (cmacs-vidstudio-new width height fps))
        (buffer (generate-new-buffer "*vidstudio*")))
    (with-current-buffer buffer
      (cmacs-vidstudio-mode)
      (setq cmacs-vidstudio--handle handle
            cmacs-vidstudio--playhead 0
            cmacs-vidstudio--active-track 0)
      (setq header-line-format
            '(:eval (format " vidstudio %dx%d @%.0ffps  frame %d/%d  track %d"
                            (cmacs-vidstudio-width cmacs-vidstudio--handle)
                            (cmacs-vidstudio-height cmacs-vidstudio--handle)
                            (cmacs-vidstudio-fps cmacs-vidstudio--handle)
                            cmacs-vidstudio--playhead
                            (cmacs-vidstudio-total-frames cmacs-vidstudio--handle)
                            cmacs-vidstudio--active-track)))
      (cmacs-vidstudio--render))
    (switch-to-buffer buffer)
    ;; Auto-open the clip-list side window (like imgedit's panels) BEFORE the
    ;; viewport attaches, so the FBO sizes to the reduced main window.
    (with-current-buffer buffer (cmacs-vidstudio--open-clips-panel))
    ;; Try the live GL viewport (native PPM preview is the fallback).
    (cmacs-vidstudio--maybe-attach-viewport buffer)
    (with-current-buffer buffer (cmacs-vidstudio--render))
    buffer))

;; Under Evil (Doom) the state maps shadow the mode map's transport/editing
;; keys (SPC, i, s, g, …), and an Evil *overriding* map is not enough: it
;; still loses to Evil's minor-mode maps, and evil-snipe owns `s' (split) in
;; normal state plus `t'/`T' (transition / title) in motion state.  Install
;; the map as an Evil intercept map instead.  SPC stays the Doom leader
;; regardless -- general.el's override map outranks every Evil keymap -- so
;; `p' is the play toggle there, as noted in the keymap above.
(cmacs-evil-setup-mode-map cmacs-vidstudio-mode-map 'cmacs-vidstudio-mode)

(provide 'cmacs-vidstudio)
;;; cmacs-vidstudio.el ends here
