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

(defun cmacs-vidstudio-import (file seconds)
  "Import FILE (image or video) for SECONDS onto the active track.
Video clips decode in the background; the timeline is usable immediately
and the preview pops in when the decode finishes."
  (interactive (list (read-file-name "Import clip: ")
                     (read-number "Duration (seconds): " 3.0)))
  (let* ((frames (cmacs-vidstudio--secs-to-frames seconds))
         (ext (downcase (or (file-name-extension file) "")))
         (imagep (member ext '("png" "jpg" "jpeg" "bmp" "gif" "tga")))
         (id (if imagep
                 (cmacs-vidstudio-add-image-clip cmacs-vidstudio--handle
                                                 cmacs-vidstudio--active-track
                                                 (expand-file-name file) frames)
               (cmacs-vidstudio-add-video-clip cmacs-vidstudio--handle
                                               cmacs-vidstudio--active-track
                                               (expand-file-name file) frames))))
    (cmacs-vidstudio--render)
    (if imagep
        (message "Imported clip #%d" id)
      (message "Imported clip #%d (decoding in background…)" id)
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

(defun cmacs-vidstudio-add-transition-cmd (clip-id type overlap)
  "Set CLIP-ID's leading TYPE transition with OVERLAP seconds."
  (interactive
   (list (read-number "Clip id: ")
         (cdr (assoc (completing-read "Transition: "
                                      cmacs-vidstudio-transition-alist nil t)
                     cmacs-vidstudio-transition-alist))
         (read-number "Overlap (seconds): " 1.0)))
  (cmacs-vidstudio-set-transition cmacs-vidstudio--handle clip-id type
                                  (cmacs-vidstudio--secs-to-frames overlap) 0)
  (cmacs-vidstudio--render))

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
  "Stop playback."
  (interactive)
  (when cmacs-vidstudio--play-timer
    (cancel-timer cmacs-vidstudio--play-timer)
    (setq cmacs-vidstudio--play-timer nil)))

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

(defun cmacs-vidstudio--menu ()
  "Return the video-editor context-menu alist (shared native + viewport)."
  '("Video editor"
            ("Add"
             ("Import clip…" . cmacs-vidstudio-import)
             ("Solid colour…" . cmacs-vidstudio-add-color)
             ("Title…" . cmacs-vidstudio-add-title)
             ("New track" . cmacs-vidstudio-add-track-cmd))
            ("Clip"
             ("Transition…" . cmacs-vidstudio-add-transition-cmd)
             ("Effect…" . cmacs-vidstudio-add-effect-cmd)
             ("Split at playhead…" . cmacs-vidstudio-split-at-playhead)
             ("Active track…" . cmacs-vidstudio-set-active-track))
            ("Transport"
             ("Play/pause" . cmacs-vidstudio-play)
             ("Step forward" . cmacs-vidstudio-step-forward)
             ("Step back" . cmacs-vidstudio-step-back)
             ("Go to frame…" . cmacs-vidstudio-set-playhead-cmd))
            ("Export"
             ("Video (MP4)…" . cmacs-vidstudio-export-video-cmd)
             ("Animated GIF…" . cmacs-vidstudio-export-gif-cmd))))

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
