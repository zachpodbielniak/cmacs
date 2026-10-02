;;; cmacs-gowl-grab.el --- Text and colours off the gowl screen -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The keys Super+Alt+Shift+s (OCR a region you drag) and Super+Alt+c
;; (the colour of a pixel you click) are gowl's screenshot module and
;; are interactive.  This file is the non-interactive half, for Lisp and
;; for agents: name the place, get the text or the colour back.
;;
;;   (cmacs-gowl-screen-text 200 150 400 80)     ; => "Text in that box"
;;   (cmacs-gowl-pixel-color 230 170)            ; => "#336699"
;;
;; Coordinates are gowl's layout coordinates, the ones
;; `gowl-list-monitors' and a client's geometry use.  Neither function
;; touches the clipboard unless asked to.
;;
;; OCR runs the screenshot module's own `ocr-command' and `ocr-language'
;; (tesseract, eng by default), asked for over IPC, so the key and these
;; functions cannot disagree.  The region is a private PNG in
;; $XDG_RUNTIME_DIR, deleted afterwards.  tesseract runs synchronously on
;; Emacs's thread -- a second or so for a paragraph -- which pauses
;; Emacs, not the compositor (gowl dispatches on a thread of its own).
;;
;; The MCP tools gowl_screen_text and gowl_pick_color call these.

;;; Code:

(require 'subr-x)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-screenshot-region "cmacs-gowl")
(declare-function gowl-screenshot-save-png "cmacs-gowl")
(declare-function gowl-clipboard-set "cmacs-gowl")

(defgroup cmacs-gowl-grab nil
  "Text and colours off the gowl screen."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-grab-")

(defcustom cmacs-gowl-grab-ocr-timeout 60
  "Seconds `cmacs-gowl-screen-text' lets the OCR program run."
  :type 'natnum
  :group 'cmacs-gowl-grab)

(defun cmacs-gowl-grab--running ()
  "Signal unless a gowl compositor runs in this Emacs."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running")))

;;;###autoload
(defun cmacs-gowl-command (line)
  "Run gowl IPC command LINE and return its reply without the \"OK \".
Signals an error on an \"ERROR\" reply, and when nothing answers (the
module that owns the word is not loaded)."
  (cmacs-gowl-grab--running)
  (let ((reply (gowl-run-command line)))
    (cond ((null reply)
           (error "No gowl module answers `%s'" (car (split-string line))))
          ((string-prefix-p "ERROR" reply)
           (error "%s" (string-trim (substring reply 5))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-grab--ocr-config ()
  "The screenshot module's OCR program and language, as (COMMAND . LANG).
tesseract/eng when the module is not loaded."
  (let ((reply (ignore-errors (gowl-run-command "screenshot-ocr-config"))))
    (if (and reply (string-prefix-p "OK " reply))
        (let ((cfg (json-parse-string (substring reply 3)
                                      :object-type 'alist)))
          (cons (or (alist-get 'command cfg) "tesseract")
                (or (alist-get 'language cfg) "eng")))
      (cons "tesseract" "eng"))))

;;;###autoload
(defun cmacs-gowl-screen-text (x y width height &optional language copy)
  "Read the text in a region of the gowl screen and return it.
X, Y, WIDTH and HEIGHT are layout coordinates.  LANGUAGE is a tesseract
language list (\"eng\", \"eng+deu\"); nil uses the screenshot module's
`ocr-language'.  With COPY non-nil the text also goes on the clipboard.
Returns \"\" when there is no text."
  (cmacs-gowl-grab--running)
  (unless (and (natnump x) (natnump y) (> width 0) (> height 0))
    (error "X and Y must be at least 0, WIDTH and HEIGHT positive"))
  (let* ((cfg (cmacs-gowl-grab--ocr-config))
         (shot (or (gowl-screenshot-region x y width height)
                   (error "Nothing captured at %d,%d %dx%d"
                          x y width height)))
         (dir (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
         (png (make-temp-file (expand-file-name "cmacs-ocr-" dir)
                              nil ".png")))
    (unwind-protect
        (progn
          (set-file-modes png #o600)
          (apply #'gowl-screenshot-save-png (append shot (list png)))
          (with-temp-buffer
            (let* ((argv (append (split-string-and-unquote (car cfg))
                                 (list png "stdout" "-l"
                                       (or language (cdr cfg)))))
                   (status
                    (condition-case err
                        (if (executable-find "timeout")
                            (apply #'call-process "timeout" nil
                                   (list t nil) nil
                                   (number-to-string
                                    cmacs-gowl-grab-ocr-timeout)
                                   argv)
                          (apply #'call-process (car argv) nil (list t nil)
                                 nil (cdr argv)))
                      (file-missing
                       (error "%s -- is tesseract installed? (Fedora: \
tesseract, tesseract-langpack-eng)" (error-message-string err))))))
              (unless (eql status 0)
                (error "OCR failed (%s exited %s)" (car argv) status))
              (let ((text (string-trim
                           (subst-char-in-string ?\f ?\n (buffer-string)))))
                (when (and copy (not (string-empty-p text)))
                  (gowl-clipboard-set text))
                text))))
      (delete-file png))))

;;;###autoload
(defun cmacs-gowl-pixel-color (x y)
  "The colour of the gowl screen at layout X, Y, as \"#rrggbb\".
The clipboard is left alone."
  (cmacs-gowl-grab--running)
  (let* ((shot (or (gowl-screenshot-region x y 1 1)
                   (error "Nothing captured at %d,%d" x y)))
         (data (nth 2 shot)))
    (unless (and (stringp data) (>= (length data) 4))
      (error "No pixel at %d,%d" x y))
    ;; ARGB8888 little-endian: B, G, R, A in memory
    (format "#%02x%02x%02x" (aref data 2) (aref data 1) (aref data 0))))

(provide 'cmacs-gowl-grab)

;;; cmacs-gowl-grab.el ends here
