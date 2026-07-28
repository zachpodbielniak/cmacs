;;; cmacs-video.el --- GStreamer-backed video embedding for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lisp layer for the cmacs-video subsystem.  Wraps the C DEFUNs with
;; defcustoms, the standalone `cmacs-video-mode' major mode, helpful
;; M-x entry points, lifecycle hooks (kill-buffer / kill-emacs /
;; delete-frame) and convenience wrappers.
;;
;; Compositor-agnostic: works under any Wayland or X11 compositor that
;; hosts the pgtk client.  Does NOT require `--with-cmacs-gowl' nor
;; running cmacs in `--gowl' (compositor) mode.
;;
;; The standard use case:
;;
;;   (cmacs-video-open-file "~/clip.mp4")
;;   (cmacs-video-open-url  "rtsps://nvr.lan:7441/abc?enableSrtp")
;;
;; or, embedded in an org buffer, via `cmacs-video-org' /
;; `#+BEGIN_VIDEO' blocks (see lisp/cmacs/cmacs-video-org.el).
;;
;; The full Lisp API exposes enough surface that third-party packages
;; (e.g. `unifi-cam.el') can wrap rich camera-feed UIs entirely in
;; Elisp without touching C.

;;; Code:

(require 'cl-lib)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence

(defgroup cmacs-video nil
  "GStreamer-backed inline video embedding."
  :group 'cmacs
  :prefix "cmacs-video-")

;;;; ────────────────────── User-tunable knobs ──────────────────────

(defcustom cmacs-video-default-width 640
  "Default display width in pixels for new streams."
  :type 'integer
  :group 'cmacs-video)

(defcustom cmacs-video-default-height 360
  "Default display height in pixels for new streams."
  :type 'integer
  :group 'cmacs-video)

(defcustom cmacs-video-default-latency-ms 200
  "Default RTSP jitterbuffer in milliseconds.
200 is appropriate for LAN cameras; bump to 500–1000 for WAN."
  :type 'integer
  :group 'cmacs-video)

(defcustom cmacs-video-rtsps-insecure-by-default nil
  "When non-nil, rtsps:// streams default to :insecure t.
DANGEROUS: skips all TLS certificate validation.  Set this only
in a per-package context (e.g. unifi-cam.el) — never globally."
  :type 'boolean
  :group 'cmacs-video)

(defcustom cmacs-video-pause-when-hidden nil
  "When non-nil, automatically pause streams whose overlay scrolls off-screen.
Default nil because the primary use case is security-camera
monitoring, where continuous capture matters more than CPU."
  :type 'boolean
  :group 'cmacs-video)

(defcustom cmacs-video-promote-hardware-decoders nil
  "Set non-nil to call `cmacs-video-promote-hardware-decoders' at load.
Promotes VAAPI / V4L2 / NVDEC H.264 + H.265 decoders so playbin3
prefers hardware over the libav software decoders.  Saves
8–15% CPU per 720p stream on hardware that supports it; may
expose flaky vendor drivers as black frames.  Roll back by
setting nil and restarting cmacs."
  :type 'boolean
  :group 'cmacs-video
  :set (lambda (sym val)
         (set-default sym val)
         (when (and val (fboundp 'cmacs-video-promote-hardware-decoders)
                    (fboundp 'cmacs-video-supported-p)
                    (cmacs-video-supported-p))
           (cmacs-video-promote-hardware-decoders))))

(defcustom cmacs-video-buffer-name-prefix "*cmacs-video: "
  "Prefix for buffer names created by `cmacs-video-open-file' etc."
  :type 'string
  :group 'cmacs-video)

;;;; ────────────────────── Buffer-local state ──────────────────────

(defvar-local cmacs-video--streams nil
  "List of (HANDLE :marker M :w W :h H) entries.
Read every redisplay by the C paint hook (`cmacs_video_overlay_paint').
Do not edit directly except via the helpers in this file or its
companion `cmacs-video-org.el'.")

(defvar-local cmacs-video--standalone-handle nil
  "Single handle anchored to this buffer's window when in `cmacs-video-mode'.")

(defvar-local cmacs-video--mode-line-state "starting…"
  "Mode-line status string maintained by the state-handler callback.")

;;;; ────────────────────── Core wrappers ──────────────────────

;;;###autoload
(defun cmacs-video-open (uri &rest plist)
  "Open URI for playback and return an opaque handle.
URI is a string (file://, http(s)://, rtsp://, rtsps://, etc.).
PLIST is a property list of options:
  :width W :height H              display size in pixels
  :audio BOOL                     enable audio (default nil = muted)
  :volume FLOAT                   0.0..1.0
  :loop BOOL                      restart on EOS (file URIs only)
  :autoplay BOOL                  set state to PLAYING (default t)
  :start FLOAT                    initial seek seconds
  :insecure BOOL                  RTSPS: skip TLS validation
  :latency INT                    RTSP buffer in ms
  :on-state FN                    state-change handler

This wrapper applies these user defaults before calling the C
primitive `cmacs-video--open-1':
  - rtsps:// URIs get :insecure t when
    `cmacs-video-rtsps-insecure-by-default' is non-nil.
  - :latency falls back to `cmacs-video-default-latency-ms'."
  (when (and (stringp uri)
             (string-prefix-p "rtsps://" uri)
             cmacs-video-rtsps-insecure-by-default
             (not (plist-member plist :insecure)))
    (setq plist (plist-put plist :insecure t)))
  (unless (plist-member plist :latency)
    (setq plist (plist-put plist :latency cmacs-video-default-latency-ms)))
  (apply #'cmacs-video--open-1 uri plist))

;;;###autoload
(defun cmacs-video-toggle-play (handle)
  "Toggle HANDLE between PLAYING and PAUSED."
  (interactive (list (cmacs-video--read-handle)))
  (pcase (cmacs-video-state handle)
    ('playing (cmacs-video-pause handle))
    ((or 'paused 'ready 'initializing 'buffering)
     (cmacs-video-play handle))
    (_ (cmacs-video-play handle))))

;;;###autoload
(defun cmacs-video-seek-interactive (handle seconds)
  "Prompt for SECONDS, seek HANDLE."
  (interactive
   (let* ((h (cmacs-video--read-handle))
          (pos (cmacs-video-position h)))
     (list h
           (read-number "Seek to (seconds): "
                        (if pos (/ (car pos) 1e9) 0)))))
  (cmacs-video-seek handle seconds))

;;;###autoload
(defun cmacs-video-step-forward-frame (handle)
  "Step HANDLE one frame forward."
  (interactive (list (cmacs-video--read-handle)))
  (cmacs-video-step handle 1))

;;;###autoload
(defun cmacs-video-step-backward-frame (handle)
  "Step HANDLE one frame backward (approximate, keyframe-based)."
  (interactive (list (cmacs-video--read-handle)))
  (cmacs-video-step handle -1))

(defmacro cmacs-video--define-seek-helper (suffix delta-seconds doc)
  "Generate a seek-by-DELTA-SECONDS interactive function."
  `(defun ,(intern (format "cmacs-video-seek-%s" suffix)) (handle)
     ,doc
     (interactive (list (cmacs-video--read-handle)))
     (let ((pos (cmacs-video-position handle)))
       (when pos
         (cmacs-video-seek handle
                           (max 0 (+ (/ (car pos) 1e9) ,delta-seconds)))))))

(cmacs-video--define-seek-helper back-5    -5  "Seek HANDLE back 5 seconds.")
(cmacs-video--define-seek-helper forward-5  5  "Seek HANDLE forward 5 seconds.")
(cmacs-video--define-seek-helper back-30  -30  "Seek HANDLE back 30 seconds.")
(cmacs-video--define-seek-helper forward-30 30 "Seek HANDLE forward 30 seconds.")

;;;###autoload
(defun cmacs-video-seek-start (handle)
  "Seek HANDLE to start of stream."
  (interactive (list (cmacs-video--read-handle)))
  (cmacs-video-seek handle 0))

;;;###autoload
(defun cmacs-video-toggle-mute (handle)
  "Toggle audio mute of HANDLE."
  (interactive (list (cmacs-video--read-handle)))
  (let ((muted (not (or (eq (cmacs-video--get-meta handle :muted) t)
                        (eq (cmacs-video--get-meta handle :muted) nil)))))
    (cmacs-video-set-mute handle (not muted))))

;;;###autoload
(defun cmacs-video-volume-up (handle)
  "Increase volume of HANDLE by 0.05."
  (interactive (list (cmacs-video--read-handle)))
  (let ((v (or (cmacs-video--get-meta handle :volume) 1.0)))
    (cmacs-video-set-volume handle (min 1.0 (+ v 0.05)))))

;;;###autoload
(defun cmacs-video-volume-down (handle)
  "Decrease volume of HANDLE by 0.05."
  (interactive (list (cmacs-video--read-handle)))
  (let ((v (or (cmacs-video--get-meta handle :volume) 1.0)))
    (cmacs-video-set-volume handle (max 0.0 (- v 0.05)))))

;;;###autoload
(defun cmacs-video-show-info (handle)
  "Echo state / position / dimensions of HANDLE."
  (interactive (list (cmacs-video--read-handle)))
  (let* ((state  (cmacs-video-state handle))
         (pos    (cmacs-video-position handle))
         (size   (cmacs-video-frame-size handle))
         (frames (cmacs-video-frames-decoded handle)))
    (message "cmacs-video[%d]: state=%s frames=%d pos=%s size=%s"
             handle state frames
             (if pos
                 (format "%.2fs%s" (/ (car pos) 1e9)
                         (if (cdr pos)
                             (format "/%.2fs" (/ (cdr pos) 1e9))
                           ""))
               "?")
             (if size (format "%dx%d" (car size) (cdr size)) "?"))))

;;;###autoload
(defun cmacs-video-snapshot-interactive (handle path)
  "Write current frame of HANDLE to PATH as PNG."
  (interactive
   (list (cmacs-video--read-handle)
         (read-file-name "Save snapshot to: " nil nil nil ".png")))
  (if (cmacs-video-snapshot-to-file handle path)
      (message "Snapshot saved: %s" path)
    (message "Snapshot failed: no frame available yet.")))

(defun cmacs-video--get-meta (handle key)
  "Look up a memoised metadata value for HANDLE.
Returns the value stored under KEY in the buffer-local meta table,
or nil if absent.  Used for client-side volume/mute caching since
GStreamer's `volume' property is read-only-after-set."
  (let ((tbl (alist-get handle cmacs-video--meta-table)))
    (and tbl (plist-get tbl key))))

(defvar cmacs-video--meta-table nil
  "Per-handle plist cache (volume, mute) maintained by Elisp wrappers.")

;;;; ────────────────────── Handle selection ──────────────────────

(defun cmacs-video--read-handle ()
  "Return a handle: the standalone-mode handle of the current buffer
if any, else prompt from the live list."
  (or cmacs-video--standalone-handle
      (let* ((live (cmacs-video-list))
             (default (car live)))
        (cond
         ((null live) (user-error "No live cmacs-video streams"))
         ((null (cdr live)) default)
         (t (let ((s (completing-read
                      (format "Stream handle (default %d): " default)
                      (mapcar #'number-to-string live)
                      nil t nil nil (number-to-string default))))
              (string-to-number s)))))))

;;;; ────────────────────── Standalone mode ──────────────────────

(defvar cmacs-video-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "SPC")  #'cmacs-video-toggle-play)
    (define-key m (kbd "q")    #'kill-current-buffer)
    (define-key m (kbd "s")    #'cmacs-video-seek-interactive)
    (define-key m (kbd "f")    #'cmacs-video-step-forward-frame)
    (define-key m (kbd "b")    #'cmacs-video-step-backward-frame)
    (define-key m (kbd ",")    #'cmacs-video-seek-back-5)
    (define-key m (kbd ".")    #'cmacs-video-seek-forward-5)
    (define-key m (kbd "<")    #'cmacs-video-seek-back-30)
    (define-key m (kbd ">")    #'cmacs-video-seek-forward-30)
    (define-key m (kbd "0")    #'cmacs-video-seek-start)
    (define-key m (kbd "m")    #'cmacs-video-toggle-mute)
    (define-key m (kbd "+")    #'cmacs-video-volume-up)
    (define-key m (kbd "=")    #'cmacs-video-volume-up)
    (define-key m (kbd "-")    #'cmacs-video-volume-down)
    (define-key m (kbd "p")    #'cmacs-video-snapshot-interactive)
    (define-key m (kbd "i")    #'cmacs-video-show-info)
    m)
  "Keymap for `cmacs-video-mode'.")

;; Under Evil (Doom) the state maps outrank the major-mode map, so every
;; transport key here would run an Evil command instead (`s' snipe, `f'
;; find-char, `b' back-word, `i' insert, `0' beginning-of-line, ...).
;; Install the map as an Evil intercept map so playback control works in
;; normal and motion state.  SPC (play/pause) is the one exception: under
;; Doom the leader's override map outranks every Evil keymap, so SPC stays
;; the leader there and play/pause needs a user binding or M-x.
(cmacs-evil-setup-mode-map cmacs-video-mode-map 'cmacs-video-mode)

(define-derived-mode cmacs-video-mode special-mode "CMacs-Video"
  "Major mode for full-window standalone video playback.

The buffer text is essentially blank; the C paint hook draws the
video frame at the geometry registered via
`cmacs-video-attach-frame', which is recomputed on every
`window-configuration-change-hook'.

\\{cmacs-video-mode-map}"
  (setq buffer-read-only t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format
              '(" %b   " cmacs-video--mode-line-state))
  (setq-local cmacs-video--mode-line-state "starting…")
  (add-hook 'window-configuration-change-hook
            #'cmacs-video--standalone-recompute-geometry nil t)
  (add-hook 'kill-buffer-hook #'cmacs-video--cleanup-buffer nil t))

(defun cmacs-video--standalone-state-cb (handle state &optional _detail)
  "Update the mode-line state string for HANDLE."
  (when-let* ((buf (cmacs-video--buffer-for-handle handle)))
    (with-current-buffer buf
      (setq cmacs-video--mode-line-state (format "%s" state))
      (force-mode-line-update))))

(defun cmacs-video--buffer-for-handle (handle)
  "Return the buffer (if any) whose standalone handle is HANDLE."
  (cl-loop for b in (buffer-list)
           when (and (buffer-local-boundp 'cmacs-video--standalone-handle b)
                     (eq (buffer-local-value 'cmacs-video--standalone-handle b)
                         handle))
           return b))

(defun cmacs-video--standalone-recompute-geometry ()
  "Recompute the standalone overlay geometry for the current buffer."
  (when-let* ((h cmacs-video--standalone-handle)
              (win (get-buffer-window (current-buffer)))
              (edges (window-body-pixel-edges win))
              (w (- (nth 2 edges) (nth 0 edges)))
              (h-px (- (nth 3 edges) (nth 1 edges))))
    (when (and (> w 0) (> h-px 0))
      (cmacs-video-set-size h w h-px)
      (cmacs-video-attach-frame h (window-frame win)
                                (nth 0 edges) (nth 1 edges)
                                w h-px))))

(defun cmacs-video--cleanup-buffer ()
  "kill-buffer-hook helper: close any streams owned by this buffer."
  (when cmacs-video--standalone-handle
    (ignore-errors
      (cmacs-video-close cmacs-video--standalone-handle))
    (setq cmacs-video--standalone-handle nil))
  (dolist (entry cmacs-video--streams)
    (ignore-errors (cmacs-video-close (car entry))))
  (setq cmacs-video--streams nil))

(defun cmacs-video--standalone-open (uri title)
  "Open URI in a new `cmacs-video-mode' buffer titled TITLE."
  (let* ((buf (generate-new-buffer
               (concat cmacs-video-buffer-name-prefix title "*")))
         (handle nil))
    (with-current-buffer buf
      (cmacs-video-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n"))
      (setq handle (cmacs-video-open uri
                                     :width  cmacs-video-default-width
                                     :height cmacs-video-default-height
                                     :autoplay t
                                     :on-state #'cmacs-video--standalone-state-cb))
      (setq cmacs-video--standalone-handle handle))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (cmacs-video--standalone-recompute-geometry))
    handle))

;;;###autoload
(defun cmacs-video-open-file (path)
  "Open local video file PATH in a new `cmacs-video-mode' buffer."
  (interactive "fVideo file: ")
  (let* ((abs (expand-file-name path))
         (uri (concat "file://" abs)))
    (cmacs-video--standalone-open uri (file-name-nondirectory abs))))

;;;###autoload
(defun cmacs-video-open-url (uri)
  "Open a URI (rtsp://, rtsps://, http(s)://, file://) standalone."
  (interactive "sVideo URI: ")
  (cmacs-video--standalone-open uri uri))

;;;###autoload
(defun cmacs-video-attach-to-point (handle &optional pixel-width pixel-height)
  "Register HANDLE in the current buffer at point as an inline overlay.

Pushes an entry onto buffer-local `cmacs-video--streams' so the
C paint hook draws HANDLE on every redisplay.  Caller is
responsible for creating an overlay whose `display' property
reserves the rectangle.

Returns the marker the stream is anchored on."
  (let* ((marker (copy-marker (point) t))
         (w (or pixel-width  cmacs-video-default-width))
         (h (or pixel-height cmacs-video-default-height)))
    (cmacs-video-attach-buffer handle marker)
    (push (list handle :marker marker :w w :h h) cmacs-video--streams)
    marker))

;;;; ────────────────────── Process / frame shutdown ──────────────────────

(defun cmacs-video--shutdown-all ()
  "Close every live stream.  Called from `kill-emacs-hook'."
  (dolist (h (ignore-errors (cmacs-video-list)))
    (ignore-errors (cmacs-video-close h))))

(defun cmacs-video--on-delete-frame (frame)
  "delete-frame-functions helper: close standalone streams on FRAME."
  (dolist (b (buffer-list))
    (when (buffer-local-boundp 'cmacs-video--standalone-handle b)
      (let ((h (buffer-local-value 'cmacs-video--standalone-handle b))
            (win (get-buffer-window b frame)))
        (when (and h win)
          (ignore-errors (cmacs-video-close h))
          (with-current-buffer b
            (setq cmacs-video--standalone-handle nil)))))))

(add-hook 'kill-emacs-hook        #'cmacs-video--shutdown-all)
(add-hook 'delete-frame-functions #'cmacs-video--on-delete-frame)

;;;; ────────────────────── Provide feature ──────────────────────

(provide 'cmacs-video)

;;; cmacs-video.el ends here
