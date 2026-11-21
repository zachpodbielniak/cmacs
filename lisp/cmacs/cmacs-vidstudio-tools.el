;;; cmacs-vidstudio-tools.el --- The video editor as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The eleven `vidstudio_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-vidstudio.c
;; that evaluated a printf-built Lisp form.  Here they are
;; `cmacs-brigade-deftool' forms (doc_org/cmacs/cmacs-capability.org has
;; the recipe), reaching in-process agents, MCP clients,
;; org.cmacs.Editor1.Tools and `emacsctl tool vidstudio ...' from one
;; definition.  Wire names, parameter names and the required/optional
;; split are the C ones.  The C file is deleted; the schema it
;; published is frozen in test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; Every tool works on a project HANDLE, the integer `vidstudio_new'
;; returned, so the model layer is driven headlessly.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - `vidstudio_export' does not block.  The C handler called the
;;     export primitive in the dispatch, which rendered every frame and
;;     ran ffmpeg on the main thread -- under `emacs --gowl' that is the
;;     compositor, frozen for the length of the encode.  Here the
;;     project is serialized and exported by a child Emacs, the way
;;     `cmacs-vidstudio-export-video-cmd' already does it for a person,
;;     and the tool answers from the process sentinel.
;;
;;   - No argument is spliced into Lisp source -- including the child's:
;;     its form is a constant, and the paths reach it through the
;;     environment.
;;
;;   - A failure is a failure: a split that did not happen and a
;;     keyframe that was refused were "tail clip nil" and "nil".
;;
;;   - A string result is the string, not its `prin1' form in quotes.
;;
;; `vidstudio_render_frame' is still one synchronous composite of one
;; frame: there is no asynchronous primitive for it, and it writes the
;; PNG to the PATH it was given and answers in text, so it is not an
;; image-returning tool.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-vidstudio-new "cmacs-vidstudio-defuns.c"
                  (width height fps))
(declare-function cmacs-vidstudio-width "cmacs-vidstudio-defuns.c" (handle))
(declare-function cmacs-vidstudio-height "cmacs-vidstudio-defuns.c" (handle))
(declare-function cmacs-vidstudio-fps "cmacs-vidstudio-defuns.c" (handle))
(declare-function cmacs-vidstudio-total-frames "cmacs-vidstudio-defuns.c"
                  (handle))
(declare-function cmacs-vidstudio-n-tracks "cmacs-vidstudio-defuns.c"
                  (handle))
(declare-function cmacs-vidstudio-track-clip-count "cmacs-vidstudio-defuns.c"
                  (handle track))
(declare-function cmacs-vidstudio-clip-at "cmacs-vidstudio-defuns.c"
                  (handle track index))
(declare-function cmacs-vidstudio-clip-start-frame "cmacs-vidstudio-defuns.c"
                  (handle clip-id))
(declare-function cmacs-vidstudio-clip-duration "cmacs-vidstudio-defuns.c"
                  (handle clip-id))
(declare-function cmacs-vidstudio-clip-ready-p "cmacs-vidstudio-defuns.c"
                  (handle clip-id))
(declare-function cmacs-vidstudio-add-track "cmacs-vidstudio-defuns.c"
                  (handle))
(declare-function cmacs-vidstudio-add-video-clip "cmacs-vidstudio-defuns.c"
                  (handle track path duration &optional trim-start trim-end))
(declare-function cmacs-vidstudio-add-image-clip "cmacs-vidstudio-defuns.c"
                  (handle track path duration))
(declare-function cmacs-vidstudio-add-solid-clip "cmacs-vidstudio-defuns.c"
                  (handle track duration r g b a))
(declare-function cmacs-vidstudio-add-text-clip "cmacs-vidstudio-defuns.c"
                  (handle track text duration r g b a))
(declare-function cmacs-vidstudio-set-transition "cmacs-vidstudio-defuns.c"
                  (handle clip-id type overlap easing))
(declare-function cmacs-vidstudio-add-effect "cmacs-vidstudio-defuns.c"
                  (handle clip-id type))
(declare-function cmacs-vidstudio-add-keyframe "cmacs-vidstudio-defuns.c"
                  (handle clip-id param frame value
                          &optional easing effect-index prop))
(declare-function cmacs-vidstudio-add-audio-file "cmacs-vidstudio-defuns.c"
                  (handle path &optional from-frame volume trim-start
                          trim-end))
(declare-function cmacs-vidstudio-split-clip "cmacs-vidstudio-defuns.c"
                  (handle clip-id at-frame))
(declare-function cmacs-vidstudio-render-png "cmacs-vidstudio-defuns.c"
                  (handle frame))
(declare-function cmacs-vidstudio-serialize "cmacs-vidstudio-defuns.c"
                  (handle))

(defconst cmacs-vidstudio-tools--export-timeout 3600
  "Seconds `vidstudio_export' may run before its child is killed.
An encode is minutes of work for a long timeline, so this is far above
`cmacs-brigade-tool-default-timeout'.")

(defconst cmacs-vidstudio-tools--export-form
  "(let* ((src (getenv \"CMACS_VIDSTUDIO_EXPORT_SRC\")) \
\(out (getenv \"CMACS_VIDSTUDIO_EXPORT_OUT\")) \
\(gif (equal (getenv \"CMACS_VIDSTUDIO_EXPORT_FORMAT\") \"gif\")) \
\(data (with-temp-buffer (insert-file-contents src) \
\(read (current-buffer)))) \
\(h (cmacs-vidstudio--build-from-sexp data))) \
\(if gif (cmacs-vidstudio-export-gif h out) \
\(cmacs-vidstudio-export-video h out 0)))"
  "What the export child evaluates.
A constant: the project file, the destination and the format reach the
child through its environment, so no caller-supplied text is ever read
as Lisp.")

(defun cmacs-vidstudio-tools--int (value what &optional default)
  "Return VALUE as an integer, DEFAULT when it is nil, else signal for WHAT."
  (cond ((integerp value) value)
        ((and (null value) default) default)
        (t (error "%s must be an integer" what))))

(defun cmacs-vidstudio-tools--num (value what &optional default)
  "Return VALUE as a number, DEFAULT when it is nil, else signal for WHAT."
  (cond ((numberp value) value)
        ((and (null value) default) default)
        (t (error "%s must be a number" what))))

(defun cmacs-vidstudio-tools--path (path what)
  "Return PATH expanded, or signal that WHAT is missing."
  (when (or (null path) (string-empty-p path))
    (error "%s is required" what))
  (expand-file-name path))

(cmacs-brigade-deftool vidstudio-new
    "Create a WIDTHxHEIGHT video project at FPS; returns its handle."
    ((width integer "Frame width in pixels")
     (height integer "Frame height in pixels")
     (fps number "Frames per second (default 30)" :optional t))
  :group 'vidstudio
  :example "emacsctl tool vidstudio new --width 1920 --height 1080 --fps 30"
  (format "handle %d"
          (cmacs-vidstudio-new
           (cmacs-vidstudio-tools--int width "width")
           (cmacs-vidstudio-tools--int height "height")
           (cmacs-vidstudio-tools--num fps "fps" 30.0))))

(cmacs-brigade-deftool vidstudio-info
    "Describe the project: size, fps, total frames, per-track clip \
layout."
    ((handle integer "Project handle"))
  :group 'vidstudio
  :example "emacsctl tool vidstudio info --handle 1"
  (let ((h (cmacs-vidstudio-tools--int handle "handle"))
        (lines nil))
    (dotimes (tr (cmacs-vidstudio-n-tracks h))
      (let ((cells nil))
        (dotimes (ci (cmacs-vidstudio-track-clip-count h tr))
          (let ((id (cmacs-vidstudio-clip-at h tr ci)))
            (push (format "[#%d %d+%d%s]" id
                          (cmacs-vidstudio-clip-start-frame h id)
                          (cmacs-vidstudio-clip-duration h id)
                          (if (cmacs-vidstudio-clip-ready-p h id)
                              "" " decoding"))
                  cells)))
        (push (format "track %d: %s" tr (string-join (nreverse cells) " "))
              lines)))
    (format "%dx%d @%gfps total %d frames | %s"
            (cmacs-vidstudio-width h) (cmacs-vidstudio-height h)
            (cmacs-vidstudio-fps h) (cmacs-vidstudio-total-frames h)
            (string-join (nreverse lines) " || "))))

(cmacs-brigade-deftool vidstudio-add-track
    "Append a track (composites above lower tracks); returns its index."
    ((handle integer "Project handle"))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio add-track --handle 1"
  (format "track %d"
          (cmacs-vidstudio-add-track
           (cmacs-vidstudio-tools--int handle "handle"))))

(cmacs-brigade-deftool vidstudio-add-clip
    "Append a clip to TRACK.  KIND: video|image (PATH), solid (R G B), \
text (TEXT).  DURATION_FRAMES at project fps.  Video clips decode on a \
worker thread (see vidstudio_info's 'decoding' marker)."
    ((handle integer "Project handle")
     (track integer "Track index")
     (kind string "video, image, solid or text")
     (path string "Media file, for a video or image clip" :optional t)
     (text string "The text, for a text clip" :optional t)
     (duration-frames integer "Length in frames (default 90)" :optional t)
     (r integer "Red 0-255, for a solid clip (default 128)" :optional t)
     (g integer "Green 0-255, for a solid clip (default 128)" :optional t)
     (b integer "Blue 0-255, for a solid clip (default 128)" :optional t))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio add-clip --handle 1 --track 0 \
--kind video --path ~/Videos/take1.mp4"
  (let ((h (cmacs-vidstudio-tools--int handle "handle"))
        (track (cmacs-vidstudio-tools--int track "track"))
        (dur (cmacs-vidstudio-tools--int duration-frames "duration_frames"
                                         90)))
    (format
     "clip %d"
     (pcase kind
       ;; The video clip starts decoding on a worker thread and returns
       ;; its id at once; nothing here waits for the decode.
       ("video" (cmacs-vidstudio-add-video-clip
                 h track (cmacs-vidstudio-tools--path path "path") dur))
       ("image" (cmacs-vidstudio-add-image-clip
                 h track (cmacs-vidstudio-tools--path path "path") dur))
       ("solid" (cmacs-vidstudio-add-solid-clip
                 h track dur
                 (cmacs-vidstudio-tools--int r "r" 128)
                 (cmacs-vidstudio-tools--int g "g" 128)
                 (cmacs-vidstudio-tools--int b "b" 128)
                 255))
       ("text" (cmacs-vidstudio-add-text-clip
                h track (or text "") dur 255 255 255 255))
       (_ (error "kind must be video|image|solid|text"))))))

(cmacs-brigade-deftool vidstudio-set-transition
    "Set CLIP's leading transition.  TYPE: 0 fade,1 dissolve,2 wipe,\
3 slide,4 zoom,5 iris,6 flip,7 push,8 clock-wipe; -1 removes."
    ((handle integer "Project handle")
     (clip integer "Clip id")
     (type integer "Transition type, -1 to 8")
     (overlap-frames integer "Frames the transition overlaps (default 15)"
                     :optional t))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio set-transition --handle 1 --clip 2 \
--type 1"
  (cmacs-vidstudio-set-transition
   (cmacs-vidstudio-tools--int handle "handle")
   (cmacs-vidstudio-tools--int clip "clip")
   (cmacs-vidstudio-tools--int type "type")
   (cmacs-vidstudio-tools--int overlap-frames "overlap_frames" 15)
   0)
  "ok")

(cmacs-brigade-deftool vidstudio-add-effect
    "Append an effect to CLIP.  TYPE: 0 blur,1 bloom,2 color-grade,\
3 vignette,4 grain."
    ((handle integer "Project handle")
     (clip integer "Clip id")
     (type integer "Effect type, 0-4"))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio add-effect --handle 1 --clip 2 --type 3"
  (cmacs-vidstudio-add-effect
   (cmacs-vidstudio-tools--int handle "handle")
   (cmacs-vidstudio-tools--int clip "clip")
   (cmacs-vidstudio-tools--int type "type"))
  "ok")

(cmacs-brigade-deftool vidstudio-add-keyframe
    "Add a keyframe on CLIP_ID: PARAM (0 opacity,1 x,2 y,3 scale,4 \
rotation) at FRAME (clip-relative) = VALUE, optional EASING."
    ((handle integer "Project handle")
     (clip-id integer "Clip id")
     (param integer "Which parameter, 0-4")
     (frame number "Frame, relative to the clip's start")
     (value number "Value of the parameter at that frame")
     (easing integer "Easing type (default 0, linear)" :optional t))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio add-keyframe --handle 1 --clip-id 2 \
--param 0 --frame 0 --value 0"
  (unless (cmacs-vidstudio-add-keyframe
           (cmacs-vidstudio-tools--int handle "handle")
           (cmacs-vidstudio-tools--int clip-id "clip_id")
           (cmacs-vidstudio-tools--int param "param")
           (cmacs-vidstudio-tools--num frame "frame")
           (cmacs-vidstudio-tools--num value "value")
           (cmacs-vidstudio-tools--int easing "easing" 0))
    (error "Could not add the keyframe"))
  ;; What the C handler printed for success.
  "t")

(cmacs-brigade-deftool vidstudio-add-audio
    "Add an audio file to the lane at FROM_FRAME with VOLUME."
    ((handle integer "Project handle")
     (path string "Audio file")
     (from-frame integer "Frame the audio starts at (default 0)" :optional t)
     (volume number "Gain, 1.0 = unchanged (default 1.0)" :optional t))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio add-audio --handle 1 \
--path ~/Music/bed.flac --volume 0.6"
  ;; The primitive returns the new audio clip's id.
  (format "%s"
          (cmacs-vidstudio-add-audio-file
           (cmacs-vidstudio-tools--int handle "handle")
           (cmacs-vidstudio-tools--path path "path")
           (cmacs-vidstudio-tools--int from-frame "from_frame" 0)
           (cmacs-vidstudio-tools--num volume "volume" 1.0))))

(cmacs-brigade-deftool vidstudio-split
    "Split CLIP at AT_FRAME (relative to the clip start)."
    ((handle integer "Project handle")
     (clip integer "Clip id")
     (at-frame integer "Frame to split at, relative to the clip's start"))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "the vidstudio project model has no undo")
  :example "emacsctl tool vidstudio split --handle 1 --clip 2 --at-frame 45"
  (let* ((clip (cmacs-vidstudio-tools--int clip "clip"))
         (at (cmacs-vidstudio-tools--int at-frame "at_frame"))
         (tail (cmacs-vidstudio-split-clip
                (cmacs-vidstudio-tools--int handle "handle") clip at)))
    (unless tail
      (error "Could not split clip %d at frame %d" clip at))
    (format "tail clip %S" tail)))

(cmacs-brigade-deftool vidstudio-render-frame
    "Composite FRAME and write it to PATH as PNG (agent-viewable \
preview)."
    ((handle integer "Project handle")
     (frame integer "Frame to composite")
     (path string "Destination PNG file"))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "a rendered frame is written to a file")
  :example "emacsctl tool vidstudio render-frame --handle 1 --frame 30 \
--path /tmp/frame.png"
  (let ((path (cmacs-vidstudio-tools--path path "path"))
        (png (cmacs-vidstudio-render-png
              (cmacs-vidstudio-tools--int handle "handle")
              (cmacs-vidstudio-tools--int frame "frame")))
        (coding-system-for-write 'binary))
    (write-region png nil path nil 'silent)
    (format "wrote %d bytes" (length png))))

(defun cmacs-vidstudio-tools--export (done handle path gif)
  "Export project HANDLE to PATH in a child Emacs, then call DONE.
GIF non-nil exports an animated GIF, otherwise H.264.  DONE receives
\"exported\", or a string starting \"Error: \" -- the registry's
convention for a failure reported from a callback."
  (unless (fboundp 'cmacs-vidstudio-serialize)
    (error "This build cannot serialize projects for a background export"))
  (require 'cmacs-vidstudio)
  (let* ((sexp (cmacs-vidstudio-serialize handle))
         (src (make-temp-file "cmvs-export" nil ".vstudio"))
         (log (generate-new-buffer " *vidstudio-export-log*"))
         (lispdir (file-name-directory (locate-library "cmacs-vidstudio")))
         (bin (expand-file-name invocation-name invocation-directory))
         (timer nil)
         (finished nil)
         (finish
          (lambda (text)
            ;; The sentinel and the timeout can both get here; the
            ;; caller is answered by whichever is first.
            (unless finished
              (setq finished t)
              (when (timerp timer) (cancel-timer timer))
              (ignore-errors (delete-file src))
              (when (buffer-live-p log) (kill-buffer log))
              (funcall done text))))
         (proc nil))
    (with-temp-file src (insert sexp))
    (condition-case err
        (let ((process-environment
               (append (list (concat "CMACS_VIDSTUDIO_EXPORT_SRC=" src)
                             (concat "CMACS_VIDSTUDIO_EXPORT_OUT=" path)
                             (concat "CMACS_VIDSTUDIO_EXPORT_FORMAT="
                                     (if gif "gif" "mp4")))
                       process-environment)))
          (setq proc
                (make-process
                 :name "vidstudio-export" :buffer log :noquery t
                 :command (list bin "-Q" "-batch" "-L" lispdir
                                "-l" "cmacs-vidstudio"
                                "--eval" cmacs-vidstudio-tools--export-form)
                 :sentinel
                 (lambda (p _event)
                   (when (memq (process-status p) '(exit signal))
                     (if (and (eq (process-status p) 'exit)
                              (zerop (process-exit-status p))
                              (file-exists-p path))
                         (funcall finish "exported")
                       (funcall
                        finish
                        (format "Error: export failed: %s"
                                (if (buffer-live-p log)
                                    (with-current-buffer log
                                      (string-trim
                                       (buffer-substring-no-properties
                                        (max (point-min)
                                             (- (point-max) 400))
                                        (point-max))))
                                  "no log")))))))))
      (error
       (funcall finish (format "Error: could not start the export: %s"
                               (error-message-string err)))))
    (when (process-live-p proc)
      ;; Slightly inside the registry's own timeout, so the child is
      ;; killed by the answer that reports it rather than left encoding
      ;; for a caller that has already been told it timed out.
      (setq timer
            (run-at-time
             (- cmacs-vidstudio-tools--export-timeout 10) nil
             (lambda ()
               (when (process-live-p proc) (delete-process proc))
               (funcall finish "Error: export timed out")))))))

(cmacs-brigade-deftool vidstudio-export
    "Export the timeline.  FORMAT mp4 (H.264) or gif.  Waits for any \
in-flight clip decodes, so output always has real frames."
    ((handle integer "Project handle")
     (path string "Destination file")
     (format string "mp4 (the default) or gif" :optional t))
  :group 'vidstudio
  :destructive t
  :undo '(irreversible "an export is written by ffmpeg after the call")
  :async t
  :timeout cmacs-vidstudio-tools--export-timeout
  :example "emacsctl tool vidstudio export --handle 1 --path ~/Videos/out.mp4"
  (let ((fmt (if (or (null format) (string-empty-p format)) "mp4" format)))
    (unless (member fmt '("mp4" "gif"))
      (error "format must be mp4|gif"))
    (cmacs-vidstudio-tools--export
     done
     (cmacs-vidstudio-tools--int handle "handle")
     (cmacs-vidstudio-tools--path path "path")
     (equal fmt "gif"))))

(provide 'cmacs-vidstudio-tools)

;;; cmacs-vidstudio-tools.el ends here
