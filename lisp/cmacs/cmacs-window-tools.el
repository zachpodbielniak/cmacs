;;; cmacs-window-tools.el --- The window tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The six tools of cmacs/mcp/cmacs-mcp-tools-window.c, written once
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Same wire names,
;; same parameters, same `prin1'-printed result text.
;;
;; Redaction (cmacs-redact.el): a window showing an excluded buffer is
;; left out of `list_windows' and `current_view'; a frame whose selected
;; window shows one keeps its row in `list_frames' -- the frame is no
;; secret -- but loses its name, which is normally that buffer's name.
;; `select_window' reports the buffer it landed on, and reports nothing
;; when that buffer is excluded.
;;
;; `split_window' and `delete_window' rearrange the user's frame, so they
;; are :destructive: a read-only agent is not handed them, and they stay
;; off D-Bus and emacsctl until a configuration names those surfaces.
;; `delete_window' carried the destructive hint in C already.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-text "cmacs-core-tools" (string))
(declare-function cmacs-core-tools-buffer-hidden-p "cmacs-core-tools"
                  (buffer-or-name))
(declare-function cmacs-ai-view-report "cmacs-ai-view"
                  (&optional include-content))
(declare-function windmove-up "windmove" (&optional arg))
(declare-function windmove-down "windmove" (&optional arg))
(declare-function windmove-left "windmove" (&optional arg))
(declare-function windmove-right "windmove" (&optional arg))

(defvar cmacs-ai-view-exclude-name-regexps)

(defun cmacs-window-tools--shown (window)
  "Non-nil when WINDOW shows a buffer the redaction rules let through."
  (not (cmacs-core-tools-buffer-hidden-p (window-buffer window))))

(cmacs-brigade-deftool list-windows
  "List all windows with buffer, point, dimensions, and position."
    ()
  :group 'window
  :example "emacsctl tool window list-windows"
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat
    (lambda (w)
      (format "%s|%s|%d|%d|%d|%d"
              (window-buffer w)
              (window-point w)
              (window-total-height w)
              (window-total-width w)
              (nth 0 (window-edges w))
              (nth 1 (window-edges w))))
    (seq-filter #'cmacs-window-tools--shown (window-list))
    "\n")))

(cmacs-brigade-deftool current-view
  "What the user is looking at right now: the visible buffers, most \
recently selected first, with the AI chat surfaces excluded. \
Call this when the user refers to \"here\", \"this\" or \"the \
above\" without naming a buffer."
    ((include-content boolean "Also return the buffers' text \
\(default false: the listing alone is usually enough, and \
get_buffer_content fetches just the one you want)" :optional t))
  :group 'window
  (require 'cmacs-core-tools)
  (require 'cmacs-ai-view nil t)
  (cmacs-core-tools-print
   (if (fboundp 'cmacs-ai-view-report)
       ;; The view layer has its own list of buffers never to report.
       ;; Excluded buffers are added to it for this one call, by exact
       ;; name, so the inventory and the content both leave them out and
       ;; nothing here has to second-guess how the report is built.
       (let ((cmacs-ai-view-exclude-name-regexps
              (append
               (mapcar (lambda (b)
                         (concat "\\`" (regexp-quote (buffer-name b)) "\\'"))
                       (seq-filter #'cmacs-core-tools-buffer-hidden-p
                                   (buffer-list)))
               (and (boundp 'cmacs-ai-view-exclude-name-regexps)
                    cmacs-ai-view-exclude-name-regexps))))
         (cmacs-ai-view-report include-content))
     (mapconcat (lambda (w)
                  (format "%s | %s"
                          (buffer-name (window-buffer w))
                          (or (buffer-file-name (window-buffer w)) "")))
                (seq-filter #'cmacs-window-tools--shown (window-list))
                "\n"))))

(cmacs-brigade-deftool list-frames
  "List all frames with name, dimensions, and selection status."
    ()
  :group 'window
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat
    (lambda (f)
      (format "%s|%dx%d|%s"
              ;; A frame is named after what its selected window shows
              ;; unless the user named it, so the name is withheld with
              ;; the buffer and redacted as free text otherwise.
              (if (cmacs-window-tools--shown (frame-selected-window f))
                  (let ((name (frame-parameter f 'name)))
                    (if (stringp name) (cmacs-core-tools-text name) name))
                "")
              (frame-width f)
              (frame-height f)
              (if (eq f (selected-frame)) "selected" "other")))
    (frame-list) "\n")))

(cmacs-brigade-deftool split-window
  "Split the current window vertically or horizontally."
    ((direction string "Split direction (default: vertical)"
                :optional t :enum ("vertical" "horizontal")))
  :group 'window :destructive t
  :undo 'cmacs-brigade-undo-capture-windows
  (require 'cmacs-core-tools)
  ;; Anything but "horizontal" is the default, as in the C handler.  The
  ;; printed value is the new window, `#<window N on BUFFER>', which
  ;; names the buffer the split window shows; an excluded one is not
  ;; named.
  (let ((new (split-window nil nil (if (equal direction "horizontal")
                                       'right
                                     'below))))
    (if (cmacs-window-tools--shown new)
        (cmacs-core-tools-print new)
      (cmacs-core-tools-print t))))

(cmacs-brigade-deftool delete-window
  "Delete (close) the currently selected window."
    ()
  :group 'window :destructive t
  :undo 'cmacs-brigade-undo-capture-windows
  (require 'cmacs-core-tools)
  (delete-window)
  ;; "(delete-window) t" in C, of which the dispatch evaluated only the
  ;; first form and so printed "nil"; t is what was meant.
  (cmacs-core-tools-print t))

(cmacs-brigade-deftool select-window
  "Select another window by direction (up/down/left/right) or cycle."
    ((direction string "Direction to move (omit to cycle)"
                :optional t :enum ("up" "down" "left" "right")))
  :group 'window
  :destructive t
  :undo 'cmacs-brigade-undo-capture-windows
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.WindowManager.Other
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  (require 'cmacs-core-tools)
  (pcase direction
    ("up" (windmove-up))
    ("down" (windmove-down))
    ("left" (windmove-left))
    ("right" (windmove-right))
    ;; No direction, or one that is none of the four: cycle.
    (_ (other-window 1)))
  ;; The C handler submitted two forms, "(other-window 1) (buffer-name)",
  ;; to a dispatch that reads and evaluates only the first, so it always
  ;; answered "nil".  This answers what the second form was there for:
  ;; the buffer the selection landed on.
  (let ((landed (window-buffer (selected-window))))
    (cmacs-core-tools-print
     (if (cmacs-core-tools-buffer-hidden-p landed)
         ""
       (buffer-name landed)))))

(provide 'cmacs-window-tools)

;;; cmacs-window-tools.el ends here
