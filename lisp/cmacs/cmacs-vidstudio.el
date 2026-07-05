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
(defvar-local cmacs-vidstudio--play-timer nil)
(defvar-local cmacs-vidstudio--preview-scale 0.5)
(defcustom cmacs-vidstudio-playback-scale 0.4
  "Preview scale used WHILE playing (a low-res proxy for near-real-time
playback); the full-resolution frame is rendered when playback pauses.
1.0 disables the proxy."
  :type 'number)
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

(defvar cmacs-vidstudio--canvas-map (make-sparse-keymap)
  "Keymap applied as a text property over the rendered preview/timeline.
A position `keymap' property outranks Evil state maps and
`context-menu-mode', so right-click reaches the editor menu under Doom.")
;; Bound on every load, mutating the same object (reload-safe).
(let ((map cmacs-vidstudio--canvas-map))
  (define-key map [down-mouse-3] #'cmacs-vidstudio-context-menu)
  (define-key map [mouse-3] #'ignore))

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
              (ignore-errors
                (cmacs-vidstudio-viewport-render
                 cmacs-vidstudio--handle (current-buffer)
                 cmacs-vidstudio--playhead))
            (ignore-errors (cmacs-libregnum-redraw (current-buffer))))
        (cmacs-vidstudio--render-native total)))))

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
                          (cmacs-vidstudio-render-ppm
                           cmacs-vidstudio--handle cmacs-vidstudio--playhead
                           (max 64 (floor (* (cmacs-vidstudio-width
                                              cmacs-vidstudio--handle)
                                             cmacs-vidstudio--preview-scale))))
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

(defun cmacs-vidstudio--watch-decode (id)
  "Poll clip ID until its background decode finishes, then re-render.
Video clips decode on a worker thread (the preview composites a dark
placeholder meanwhile), so import returns instantly."
  (when (and (fboundp 'cmacs-vidstudio-clip-ready-p)
             (not (cmacs-vidstudio-clip-ready-p cmacs-vidstudio--handle id)))
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
                     (cmacs-vidstudio--render)
                     (message "vidstudio: clip #%d decoded" id))
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

(defun cmacs-vidstudio--read-clip ()
  "Read a clip id, defaulting to the clip under the playhead."
  (let ((def (cmacs-vidstudio--clip-at-playhead)))
    (read-number "Clip id: " (or def 0))))

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
              (cmacs-vidstudio-add-audio-file
               handle src (or (cmacs-vidstudio--sx 'from seg) 0)
               (or (cmacs-vidstudio--sx 'volume seg) 1.0)
               (or (cmacs-vidstudio--sx 'trim-start seg) 0.0)
               (or (cmacs-vidstudio--sx 'trim-end seg) 0.0)))))))
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
  '(("linear" . 0) ("ease-in-quad" . 1) ("ease-out-quad" . 2)
    ("ease-in-out-cubic" . 9) ("ease-out-back" . 20) ("ease-out-bounce" . 30))
  "A useful subset of LrgEasingType names -> codes.")

(defun cmacs-vidstudio-add-transition-cmd (clip-id type overlap easing)
  "Set CLIP-ID's leading TYPE transition, OVERLAP seconds, EASING curve."
  (interactive
   (list (cmacs-vidstudio--read-clip)
         (cdr (assoc (completing-read "Transition: "
                                      cmacs-vidstudio-transition-alist nil t)
                     cmacs-vidstudio-transition-alist))
         (read-number "Overlap (seconds): " 1.0)
         (cdr (assoc (completing-read "Easing: "
                                      cmacs-vidstudio-easing-alist nil t "linear")
                     cmacs-vidstudio-easing-alist))))
  (cmacs-vidstudio-set-transition cmacs-vidstudio--handle clip-id type
                                  (cmacs-vidstudio--secs-to-frames overlap)
                                  (or easing 0))
  (cmacs-vidstudio--render))

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
  (setq cmacs-vidstudio--playhead frame)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-step-forward ()
  "Advance the playhead by one frame."
  (interactive)
  (cl-incf cmacs-vidstudio--playhead)
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-step-back ()
  "Move the playhead back one frame."
  (interactive)
  (setq cmacs-vidstudio--playhead (max 0 (1- cmacs-vidstudio--playhead)))
  (cmacs-vidstudio--render))

(defun cmacs-vidstudio-pause ()
  "Stop playback and re-render the full-resolution frame."
  (interactive)
  (when cmacs-vidstudio--play-timer
    (cancel-timer cmacs-vidstudio--play-timer)
    (setq cmacs-vidstudio--play-timer nil)
    ;; restore the full-res preview and repaint the current frame crisply
    (when cmacs-vidstudio--paused-scale
      (setq cmacs-vidstudio--preview-scale cmacs-vidstudio--paused-scale
            cmacs-vidstudio--paused-scale nil)
      (cmacs-vidstudio--render))))

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
      (let ((buf (current-buffer))
            (fps (max 1.0 (cmacs-vidstudio-fps cmacs-vidstudio--handle)))
            (start-frame cmacs-vidstudio--playhead)
            (t0 (float-time))
            (tick (/ 1.0 (max 1 cmacs-vidstudio-preview-fps))))
        (setq cmacs-vidstudio--play-timer
              (run-at-time
               tick tick
               (lambda ()
                 (if (not (buffer-live-p buf))
                     nil
                   (with-current-buffer buf
                     (let* ((now-total (cmacs-vidstudio-total-frames
                                        cmacs-vidstudio--handle))
                            (target (+ start-frame
                                       (floor (* (- (float-time) t0) fps)))))
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

(defun cmacs-vidstudio-export-video-cmd (path)
  "Export the project to PATH (H.264 mp4)."
  (interactive "FExport video to: ")
  (message "Exporting...")
  (cmacs-vidstudio-export-video cmacs-vidstudio--handle (expand-file-name path) 0)
  (message "Wrote %s" path))

(defun cmacs-vidstudio-export-gif-cmd (path)
  "Export the project to PATH as an animated GIF."
  (interactive "FExport GIF to: ")
  (message "Exporting...")
  (cmacs-vidstudio-export-gif cmacs-vidstudio--handle (expand-file-name path))
  (message "Wrote %s" path))

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

(defun cmacs-vidstudio--menu ()
  "Return the video-editor context-menu alist (shared native + viewport)."
  '("Video editor"
            ("Add"
             ("Import clip…" . cmacs-vidstudio-import)
             ("Solid colour…" . cmacs-vidstudio-add-color)
             ("Title…" . cmacs-vidstudio-add-title)
             ("Gradient…" . cmacs-vidstudio-add-gradient)
             ("Rectangle…" . cmacs-vidstudio-add-rectangle)
             ("Captions (SRT)…" . cmacs-vidstudio-add-captions)
             ("New track" . cmacs-vidstudio-add-track-cmd))
            ("Clip"
             ("Transition…" . cmacs-vidstudio-add-transition-cmd)
             ("Effect…" . cmacs-vidstudio-add-effect-cmd)
             ("Effect parameter…" . cmacs-vidstudio-set-effect-parameter)
             ("Opacity…" . cmacs-vidstudio-set-clip-opacity)
             ("Blend mode…" . cmacs-vidstudio-set-clip-blend)
             ("Transform (pos/scale)…" . cmacs-vidstudio-set-clip-transform)
             ("Playback speed…" . cmacs-vidstudio-set-clip-speed)
             ("Add keyframe…" . cmacs-vidstudio-add-keyframe-cmd)
             ("Clear keyframes…" . cmacs-vidstudio-clear-keyframes-cmd)
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

(defvar cmacs-vidstudio-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-vidstudio-mode'.")

;; Bind on every load (reload-safe; the defvar above is a no-op once bound).
(let ((map cmacs-vidstudio-mode-map))
    (define-key map (kbd "i") #'cmacs-vidstudio-import)
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
    (define-key map (kbd "<mouse-3>") #'cmacs-vidstudio-context-menu))

(defun cmacs-vidstudio--viewport-available-p ()
  "Non-nil when a live libregnum GL viewport can be used for the preview."
  (and (fboundp 'cmacs-vidstudio-viewport-render)
       (fboundp 'cmacs-libregnum-supported-p)
       (cmacs-libregnum-supported-p)
       (or (display-graphic-p) (eq (framep-on-display) 'lrg))))

(defun cmacs-vidstudio--vp-context-menu (buffer _dx _dy fx fy)
  "Pop the video-editor context menu for a viewport right-click at (FX FY)."
  (run-at-time
   0 nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (let ((choice (cmacs-libregnum-popup-menu
                        (list (list fx fy) (selected-window))
                        (cmacs-vidstudio--menu))))
           (when (commandp choice) (call-interactively choice))))))))

(defun cmacs-vidstudio--maybe-attach-viewport (buffer)
  "Attach a live libregnum viewport to BUFFER, if available.
Sets `cmacs-vidstudio--live'; leaves it nil (native path) on failure."
  (when (cmacs-vidstudio--viewport-available-p)
    (condition-case _err
        (let ((win (get-buffer-window buffer)))
          (cmacs-libregnum-attach
           buffer
           (max 64 (if win (window-pixel-width win) 640))
           (max 64 (if win (window-pixel-height win) 480)))
          (cmacs-libregnum-image-enter buffer t)
          (cmacs-libregnum-image-set-checker buffer nil)
          (with-current-buffer buffer
            (setq cmacs-libregnum-image-context-menu-function
                  #'cmacs-vidstudio--vp-context-menu
                  cmacs-vidstudio--live t)))
      (error (setq cmacs-vidstudio--live nil)))))

(defun cmacs-vidstudio--cleanup ()
  "Stop playback and free the project when the buffer dies."
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
    ;; Try the live GL viewport (native PPM preview is the fallback).
    (cmacs-vidstudio--maybe-attach-viewport buffer)
    (with-current-buffer buffer (cmacs-vidstudio--render))
    buffer))

;; Under Evil (Doom) the state maps shadow the mode map's transport/editing
;; keys (SPC, i, s, g, …).  Give this mode's map precedence in every state.
(with-eval-after-load 'evil
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map cmacs-vidstudio-mode-map)))

(provide 'cmacs-vidstudio)
;;; cmacs-vidstudio.el ends here
