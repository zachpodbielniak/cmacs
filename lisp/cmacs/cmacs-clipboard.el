;;; cmacs-clipboard.el --- clipboard history as an editable buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The gowl `clipboard' module keeps a history of everything that has
;; been on the clipboard.  This is the Emacs view of it: one line per
;; entry in a real file buffer, so the way you remove something is the
;; way you remove anything in Emacs -- kill the line and save.
;;
;; That is the whole design.  A dedicated command to delete an entry
;; would be another thing to remember; `C-k C-x C-s' is not.  Deleting
;; a password out of the history is exactly the case this exists for,
;; so it should be reflexive rather than special.
;;
;; The buffer is generated, and saving compares it against what the
;; store holds: ids present before and absent now are deleted.  Editing
;; a line's text has no effect -- the preview is a rendering of the
;; content, not the content -- and that is said in the header rather
;; than silently ignored.
;;
;; Images are entries like any other.  `RET' on one shows it inline, and
;; yanking one puts the image back on the clipboard, not its path.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-clipboard nil
  "The gowl clipboard history, as a buffer."
  :group 'cmacs
  :prefix "cmacs-clipboard-")

(defcustom cmacs-clipboard-buffer "*clipboard history*"
  "Name of the buffer listing clipboard entries."
  :type 'string
  :group 'cmacs-clipboard)

(defcustom cmacs-clipboard-preview-width 96
  "Columns of preview text shown per entry."
  :type 'integer
  :group 'cmacs-clipboard)

(defvar cmacs-clipboard--ids nil
  "Ids present when the buffer was last generated, newest first.
Saving deletes whatever is in here and no longer in the buffer.")
(make-variable-buffer-local 'cmacs-clipboard--ids)

(defun cmacs-clipboard--dir ()
  "Directory the gowl clipboard module stores its history in."
  (expand-file-name "gowl/clipboard"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~"))))

(defun cmacs-clipboard--index-file ()
  (expand-file-name "index" (cmacs-clipboard--dir)))

(defun cmacs-clipboard--blob (id)
  "Path of the blob holding entry ID's bytes."
  (expand-file-name (format "%s.bin" id) (cmacs-clipboard--dir)))

(defun cmacs-clipboard--entries ()
  "Parse the store's index into a list of plists, newest first."
  (let ((file (cmacs-clipboard--index-file))
        entries)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((line (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
                 (f (split-string line "\t")))
            ;; id, mime, bytes, preview.  A short line is a partially
            ;; written index, not an entry: skip it rather than showing
            ;; half of one.
            (when (>= (length f) 4)
              (push (list :id (nth 0 f)
                          :mime (nth 1 f)
                          :bytes (string-to-number (nth 2 f))
                          :preview (nth 3 f))
                    entries)))
          (forward-line 1))))
    (nreverse entries)))

(defun cmacs-clipboard--command (fmt &rest args)
  "Run a clipboard command in the compositor.
Returns the reply, or nil when gowl is not running -- every caller
treats that as \"nothing happened\" rather than an error, because the
buffer is still readable without a compositor."
  (when (fboundp 'gowl-run-command)
    (ignore-errors (gowl-run-command (apply #'format fmt args)))))

(defun cmacs-clipboard--render (entries)
  "Insert one line per entry in ENTRIES."
  (insert
   ";; Clipboard history.  Kill a line and save (C-x C-s) to delete that\n"
   ";; entry.  RET shows an entry, y puts it back on the clipboard.\n"
   ";; Editing the text of a line does nothing: it is a preview of the\n"
   ";; content, not the content.\n\n")
  (dolist (e entries)
    (insert (format "%-8s %-14s %s\n"
                    (plist-get e :id)
                    (if (string-prefix-p "image/" (or (plist-get e :mime) ""))
                        (format "image %dk"
                                (/ (plist-get e :bytes) 1024))
                      (format "%d bytes" (plist-get e :bytes)))
                    (truncate-string-to-width
                     (plist-get e :preview)
                     cmacs-clipboard-preview-width nil nil t)))))

(defun cmacs-clipboard--id-at-point ()
  "The entry id on the current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\([0-9]+\\)[ \t]")
      (match-string 1))))

(defun cmacs-clipboard--buffer-ids ()
  "Every id still present in the buffer."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (cmacs-clipboard--id-at-point)))
          (push id ids))
        (forward-line 1)))
    (nreverse ids)))

(defun cmacs-clipboard--save ()
  "Delete from the store every id that has left the buffer.
Installed as the buffer's `write-contents-functions', so `C-x C-s' does
this instead of writing a file: the buffer is a view, and writing it
back over the index would be writing a rendering over the data."
  (let* ((remaining (cmacs-clipboard--buffer-ids))
         (gone (cl-remove-if (lambda (id) (member id remaining))
                             cmacs-clipboard--ids)))
    (dolist (id gone)
      (cmacs-clipboard--command "clipboard-delete %s" id))
    (setq cmacs-clipboard--ids remaining)
    (set-buffer-modified-p nil)
    (message "%d entr%s deleted" (length gone)
             (if (= (length gone) 1) "y" "ies")))
  t)

;;;###autoload
(defun cmacs-clipboard-copy ()
  "Put the entry on the current line back on the clipboard."
  (interactive)
  (if-let* ((id (cmacs-clipboard--id-at-point)))
      (progn (cmacs-clipboard--command "clipboard-copy %s" id)
             (message "Copied entry %s" id))
    (message "No entry on this line")))

;;;###autoload
(defun cmacs-clipboard-show ()
  "Show the full content of the entry on the current line.
An image is displayed; anything else is shown as text."
  (interactive)
  (let* ((id (cmacs-clipboard--id-at-point))
         (blob (and id (cmacs-clipboard--blob id))))
    (cond
     ((null id) (message "No entry on this line"))
     ((not (file-readable-p blob)) (message "Entry %s has no data" id))
     (t
      (let ((buf (get-buffer-create (format "*clipboard %s*" id))))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            ;; Literally: the blob is bytes, and decoding an image as
            ;; text then re-encoding it would corrupt what is shown.
            (insert-file-contents-literally blob)
            (if (image-type-available-p (ignore-errors (image-type blob)))
                (progn (erase-buffer)
                       (insert-image (create-image blob)))
              (decode-coding-region (point-min) (point-max) 'utf-8))
            (goto-char (point-min))
            (view-mode 1)))
        (pop-to-buffer buf))))))

(defvar cmacs-clipboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y")   #'cmacs-clipboard-copy)
    (define-key map (kbd "RET") #'cmacs-clipboard-show)
    (define-key map (kbd "g")   #'cmacs-clipboard)
    map)
  "Keymap for `cmacs-clipboard-mode'.
Deliberately small: deleting is `C-k' and saving, because those are the
keys for deleting and saving everywhere else.")

(define-derived-mode cmacs-clipboard-mode fundamental-mode "Clipboard"
  "Major mode for the clipboard history buffer."
  (setq-local truncate-lines t)
  ;; Saving deletes; it never writes a file.  Without this, C-x C-s
  ;; would prompt for a filename and then write a rendering of the
  ;; store over whatever was named.
  (add-hook 'write-contents-functions #'cmacs-clipboard--save nil t))

;;;###autoload
(defun cmacs-clipboard ()
  "Show the clipboard history, one entry per line.
Kill a line and save to delete that entry."
  (interactive)
  (let ((entries (cmacs-clipboard--entries))
        (buf (get-buffer-create cmacs-clipboard-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cmacs-clipboard--render entries))
      (cmacs-clipboard-mode)
      (setq cmacs-clipboard--ids (mapcar (lambda (e) (plist-get e :id))
                                         entries))
      (set-buffer-modified-p nil)
      (goto-char (point-min))
      (forward-line 5))
    (pop-to-buffer buf)))

;;;###autoload
(defun cmacs-clipboard-clear ()
  "Forget the whole clipboard history."
  (interactive)
  (when (yes-or-no-p "Forget every clipboard entry? ")
    (cmacs-clipboard--command "clipboard-clear")
    (when (get-buffer cmacs-clipboard-buffer)
      (with-current-buffer cmacs-clipboard-buffer
        (cmacs-clipboard)))
    (message "Clipboard history cleared")))

(provide 'cmacs-clipboard)

;;; cmacs-clipboard.el ends here
