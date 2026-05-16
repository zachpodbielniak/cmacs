;;; cmacs-video-org.el --- #+BEGIN_VIDEO blocks for Org-Ex  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Embeds GStreamer-rendered video inline in Org buffers via the
;; `#+BEGIN_VIDEO' ... `#+END_VIDEO' block.  Mirrors the existing
;; `#+BEGIN_INK' integration in `cmacs-org-ex-ink.el' but uses a
;; transparent stretch-glyph placeholder (no librsvg dependency) to
;; reserve the pixel rectangle the C overlay paints into.
;;
;; Block syntax:
;;
;;   #+BEGIN_VIDEO :src "rtsps://nvr.lan:7441/AbC?enableSrtp" :width 640 :height 360 :insecure t :latency 200
;;   Front-door camera               ; body is reserved for caption/notes
;;   #+END_VIDEO
;;
;; Recognised keywords:
;;   :src       string, REQUIRED  -- URI
;;   :width     int                -- display width  (default cmacs-video-default-width)
;;   :height    int                -- display height (default cmacs-video-default-height)
;;   :autoplay  bool               -- default t
;;   :loop      bool               -- default nil
;;   :start     float              -- initial seek seconds
;;   :audio     bool               -- default nil (muted)
;;   :volume    float              -- 0.0..1.0
;;   :insecure  bool               -- RTSPS: skip TLS validation
;;   :latency   int                -- RTSP buffer ms

;;; Code:

(require 'cl-lib)
(require 'cmacs-video)

(defconst cmacs-video-org--begin-rx
  "^[ \t]*#\\+BEGIN_VIDEO\\(?:[ \t]+\\(.*\\)\\)?$"
  "Match `#+BEGIN_VIDEO' header.  Group 1 is the keyword args.")

(defconst cmacs-video-org--end-rx
  "^[ \t]*#\\+END_VIDEO[ \t]*$"
  "Match `#+END_VIDEO' line.")

(cl-defstruct cmacs-video-org--block
  begin-bol end-bol body-begin body-end
  src width height autoplay loop start audio volume insecure latency)

(defun cmacs-video-org--parse-args (s)
  "Parse keyword/value arg string S into a plist.
Supports `:key value', `:flag' (sets to t), `:key \"quoted\"',
and bare integers / floats / bools / strings."
  (let ((case-fold-search nil)
        plist
        (i 0)
        (n (length s)))
    (while (< i n)
      ;; skip whitespace
      (while (and (< i n) (memq (aref s i) '(?\s ?\t)))
        (cl-incf i))
      (when (and (< i n) (eq (aref s i) ?:))
        (let ((key-start i))
          (cl-incf i)
          (while (and (< i n)
                      (not (memq (aref s i) '(?\s ?\t))))
            (cl-incf i))
          (let* ((key (intern (substring s key-start i)))
                 value)
            ;; skip whitespace
            (while (and (< i n) (memq (aref s i) '(?\s ?\t)))
              (cl-incf i))
            (cond
             ;; flag with no value (followed by another keyword or end)
             ((or (>= i n)
                  (and (eq (aref s i) ?:)
                       (or (>= (1+ i) n)
                           (not (eq (aref s (1+ i)) ?\")))))
              (setq value t))
             ;; quoted string
             ((eq (aref s i) ?\")
              (cl-incf i)
              (let ((v-start i))
                (while (and (< i n) (not (eq (aref s i) ?\")))
                  (when (and (eq (aref s i) ?\\) (< (1+ i) n))
                    (cl-incf i))
                  (cl-incf i))
                (setq value (substring s v-start i))
                (when (< i n) (cl-incf i))))
             (t
              (let ((v-start i))
                (while (and (< i n)
                            (not (memq (aref s i) '(?\s ?\t))))
                  (cl-incf i))
                (let ((token (substring s v-start i)))
                  (setq value
                        (cond
                         ((string= token "t")   t)
                         ((string= token "nil") nil)
                         ((string-match-p "\\`-?[0-9]+\\'" token)
                          (string-to-number token))
                         ((string-match-p "\\`-?[0-9]*\\.[0-9]+\\'" token)
                          (string-to-number token))
                         (t token)))))))
            (setq plist (plist-put plist key value))))))
    plist))

(defun cmacs-video-org--block-at-point ()
  "Return the `cmacs-video-org--block' surrounding point, or nil."
  (save-excursion
    (let ((p (point)) start args)
      (beginning-of-line)
      (cond
       ((looking-at cmacs-video-org--begin-rx)
        (setq start (point) args (or (match-string 1) "")))
       (t
        (when (re-search-backward cmacs-video-org--begin-rx nil t)
          (setq start (point) args (or (match-string 1) "")))))
      (when start
        (forward-line 1)
        (let ((body-begin (point))
              end body-end)
          (when (re-search-forward cmacs-video-org--end-rx nil t)
            (setq body-end (line-beginning-position)
                  end      (line-beginning-position))
            (when (and (<= start p) (<= p (line-end-position)))
              (let* ((plist (cmacs-video-org--parse-args args)))
                (make-cmacs-video-org--block
                 :begin-bol  start
                 :end-bol    end
                 :body-begin body-begin
                 :body-end   body-end
                 :src      (plist-get plist :src)
                 :width    (or (plist-get plist :width)  cmacs-video-default-width)
                 :height   (or (plist-get plist :height) cmacs-video-default-height)
                 :autoplay (if (plist-member plist :autoplay)
                               (plist-get plist :autoplay) t)
                 :loop     (plist-get plist :loop)
                 :start    (plist-get plist :start)
                 :audio    (plist-get plist :audio)
                 :volume   (plist-get plist :volume)
                 :insecure (plist-get plist :insecure)
                 :latency  (or (plist-get plist :latency)
                               cmacs-video-default-latency-ms))))))))))

(defun cmacs-video-org--map-blocks (fn)
  "Call FN with each `#+BEGIN_VIDEO' block in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward cmacs-video-org--begin-rx nil t)
      (when-let* ((blk (cmacs-video-org--block-at-point)))
        (funcall fn blk)
        (goto-char (cmacs-video-org--block-end-bol blk))))))

(defun cmacs-video-org--placeholder (w h)
  "Return a `space' display spec reserving W×H pixels."
  (propertize " " 'display `(space :width (,w) :height (,h))))

(defun cmacs-video-org--make-overlay (blk)
  "Construct a video overlay for `cmacs-video-org--block' BLK.
Opens the stream, registers it in buffer-local
`cmacs-video--streams', sets up cleanup hooks."
  (when-let* ((src (cmacs-video-org--block-src blk)))
    (let* ((w  (cmacs-video-org--block-width  blk))
           (h  (cmacs-video-org--block-height blk))
           (plist (list :width    w
                        :height   h
                        :audio    (cmacs-video-org--block-audio blk)
                        :volume   (cmacs-video-org--block-volume blk)
                        :loop     (cmacs-video-org--block-loop blk)
                        :autoplay (cmacs-video-org--block-autoplay blk)
                        :start    (cmacs-video-org--block-start blk)
                        :insecure (cmacs-video-org--block-insecure blk)
                        :latency  (cmacs-video-org--block-latency blk)))
           (handle (apply #'cmacs-video-open src plist))
           (marker (copy-marker (cmacs-video-org--block-body-begin blk) t))
           (ov (make-overlay (cmacs-video-org--block-body-begin blk)
                             (cmacs-video-org--block-body-end blk)
                             nil t nil)))
      (overlay-put ov 'cmacs-video t)
      (overlay-put ov 'cmacs-video-handle handle)
      (overlay-put ov 'display (cmacs-video-org--placeholder w h))
      (overlay-put ov 'evaporate t)
      (overlay-put ov 'modification-hooks
                   (list (lambda (o _after _beg _end &rest _)
                           (let ((handle (overlay-get o 'cmacs-video-handle)))
                             (when handle
                               (ignore-errors (cmacs-video-close handle))
                               (setq cmacs-video--streams
                                     (cl-delete handle cmacs-video--streams
                                                :key #'car)))
                             (delete-overlay o)))))
      (cmacs-video-attach-buffer handle marker)
      (push (list handle :marker marker :w w :h h) cmacs-video--streams)
      ov)))

(defun cmacs-video-org--clear-overlays ()
  "Remove all cmacs-video overlays from the current buffer."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'cmacs-video)
      (let ((h (overlay-get ov 'cmacs-video-handle)))
        (when h (ignore-errors (cmacs-video-close h))))
      (delete-overlay ov)))
  (setq cmacs-video--streams nil))

;;;###autoload
(defun cmacs-video-org-render-buffer ()
  "Render every `#+BEGIN_VIDEO' block in the current buffer.

Tears down any pre-existing cmacs-video overlays first, then
re-renders from scratch.  Safe to call on a buffer with no
matching blocks (no-op)."
  (interactive)
  (cmacs-video-org--clear-overlays)
  (when (display-graphic-p)
    (cmacs-video-org--map-blocks #'cmacs-video-org--make-overlay)))

;;;###autoload
(defun cmacs-video-org-unrender-buffer ()
  "Tear down cmacs-video overlays in the current buffer."
  (interactive)
  (cmacs-video-org--clear-overlays))

(defun cmacs-video-org--maybe-render ()
  "Render in the current buffer if it's an org buffer with a VIDEO block."
  (when (and (derived-mode-p 'org-mode)
             (display-graphic-p)
             (save-excursion
               (goto-char (point-min))
               (re-search-forward cmacs-video-org--begin-rx nil t)))
    (cmacs-video-org-render-buffer)))

(add-hook 'find-file-hook  #'cmacs-video-org--maybe-render)
(add-hook 'after-save-hook #'cmacs-video-org--maybe-render)

(provide 'cmacs-video-org)

;;; cmacs-video-org.el ends here
