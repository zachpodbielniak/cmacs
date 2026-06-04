;;; cmacs-gsurf-downloads.el --- gsurf download manager buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Download tracking UI for cmacs-gsurf.  The C bridge
;; (cmacs/gsurf/cmacs-gsurf-downloads.c) auto-saves downloads into
;; `cmacs-gsurf-download-directory' and fires
;; `cmacs-gsurf-download-changed-functions' for each lifecycle event; this
;; file records those events and presents them in a `tabulated-list-mode'
;; buffer (`M-x cmacs-gsurf-downloads').  The recorder is added to the hook
;; on load so history is captured even when the buffer is not open.

;;; Code:

(require 'subr-x)
(require 'tabulated-list)

(declare-function cmacs-gsurf-download-cancel "cmacs-gsurf-defuns.c" (id))
(declare-function cmacs-gsurf--emit-pod "cmacs-gsurf" (event data))
;; Declared in cmacs-gsurf.el; defvar here so this file byte-compiles alone.
(defvar cmacs-gsurf-download-changed-functions)

(defgroup cmacs-gsurf-downloads nil
  "Download manager for the cmacs-gsurf embedded browser."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-download")

(defcustom cmacs-gsurf-download-directory "~/Downloads"
  "Directory gsurf downloads are auto-saved into.
Read by the C download bridge at download time; a leading \"~/\" is
expanded.  Files are de-duplicated (\"name (1).ext\") if they collide."
  :type 'directory
  :group 'cmacs-gsurf-downloads)

(defvar cmacs-gsurf--downloads nil
  "Alist of (ID . PLIST) of known downloads, newest first.
PLIST keys: :uri :dest :received :total :state :time.")

(defconst cmacs-gsurf-downloads-buffer-name "*gsurf-downloads*")

(defun cmacs-gsurf--download-record (id uri dest received total state)
  "Record a download lifecycle event (added to the C-driven hook)."
  (let ((entry (assq id cmacs-gsurf--downloads)))
    (if entry
        (setcdr entry (plist-put (plist-put (plist-put (plist-put
            (plist-put (cdr entry) :uri uri) :dest dest)
            :received received) :total total) :state state))
      (push (cons id (list :uri uri :dest dest :received received
                           :total total :state state
                           :time (current-time)))
            cmacs-gsurf--downloads)))
  ;; Emit a podomation event for lifecycle transitions (not every chunk).
  (when (and (memq state '(started finished failed cancelled))
             (fboundp 'cmacs-gsurf--emit-pod))
    (cmacs-gsurf--emit-pod
     "on_gsurf_download"
     `(("id" . ,(number-to-string id))
       ("uri" . ,(or uri "")) ("dest" . ,(or dest ""))
       ("state" . ,(format "%s" state)))))
  (cmacs-gsurf-downloads--maybe-refresh))

(defun cmacs-gsurf-mcp-download-list ()
  "Return a JSON array describing known downloads (for the MCP tool)."
  (require 'json)
  ;; vconcat -> a vector so an empty set encodes as "[]" (not "null").
  (json-encode
   (vconcat
    (mapcar (lambda (cell)
              (let ((id (car cell)) (pl (cdr cell)))
                (list (cons 'id id)
                      (cons 'uri (or (plist-get pl :uri) ""))
                      (cons 'dest (or (plist-get pl :dest) ""))
                      (cons 'received (or (plist-get pl :received) 0))
                      (cons 'total (or (plist-get pl :total) 0))
                      (cons 'state (format "%s" (plist-get pl :state))))))
            cmacs-gsurf--downloads))))

(add-hook 'cmacs-gsurf-download-changed-functions #'cmacs-gsurf--download-record)

(defun cmacs-gsurf-downloads--maybe-refresh ()
  "Refresh the downloads buffer if it is live."
  (let ((buf (get-buffer cmacs-gsurf-downloads-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((pt (point)))
          (cmacs-gsurf-downloads--refresh)
          (tabulated-list-print t)
          (goto-char (min pt (point-max))))))))

(defun cmacs-gsurf-downloads--human-size (n)
  "Format byte count N (an integer) as a human-readable size."
  (cond ((or (null n) (<= n 0)) "—")
        ((< n 1024) (format "%dB" n))
        ((< n 1048576) (format "%.1fK" (/ n 1024.0)))
        ((< n 1073741824) (format "%.1fM" (/ n 1048576.0)))
        (t (format "%.2fG" (/ n 1073741824.0)))))

(defun cmacs-gsurf-downloads--percent (pl)
  "Percent string for download PLIST."
  (let ((r (plist-get pl :received)) (tot (plist-get pl :total)))
    (cond ((member (plist-get pl :state) '(finished)) "100%")
          ((and tot (> tot 0) r) (format "%d%%" (floor (* 100.0 (/ r (float tot))))))
          (t "—"))))

(defun cmacs-gsurf-downloads--refresh ()
  "Rebuild `tabulated-list-entries' from `cmacs-gsurf--downloads'."
  (setq tabulated-list-entries
        (mapcar
         (lambda (cell)
           (let* ((id (car cell)) (pl (cdr cell))
                  (dest (plist-get pl :dest))
                  (file (if (and dest (not (string-empty-p dest)))
                            (file-name-nondirectory dest) ""))
                  (state (format "%s" (plist-get pl :state))))
             (list id
                   (vector (number-to-string id)
                           state
                           (cmacs-gsurf-downloads--percent pl)
                           (cmacs-gsurf-downloads--human-size
                            (plist-get pl :total))
                           file
                           (or (plist-get pl :uri) "")))))
         cmacs-gsurf--downloads)))

(defun cmacs-gsurf-downloads--id-at-point ()
  (or (tabulated-list-get-id) (user-error "No download on this line")))

(defun cmacs-gsurf-downloads-cancel ()
  "Cancel the download on the current line."
  (interactive)
  (cmacs-gsurf-download-cancel (cmacs-gsurf-downloads--id-at-point)))

(defun cmacs-gsurf-downloads-open-file ()
  "Open the downloaded file on the current line in Emacs."
  (interactive)
  (let* ((pl (cdr (assq (cmacs-gsurf-downloads--id-at-point)
                        cmacs-gsurf--downloads)))
         (dest (plist-get pl :dest)))
    (if (and dest (file-exists-p dest))
        (find-file dest)
      (user-error "File not available yet"))))

(defun cmacs-gsurf-downloads-open-external ()
  "Open the downloaded file on the current line with the system handler."
  (interactive)
  (let* ((pl (cdr (assq (cmacs-gsurf-downloads--id-at-point)
                        cmacs-gsurf--downloads)))
         (dest (plist-get pl :dest)))
    (if (and dest (file-exists-p dest))
        (if (fboundp 'browse-url-of-file)
            (browse-url-of-file dest)
          (start-process "gsurf-open" nil "xdg-open" dest))
      (user-error "File not available yet"))))

(defun cmacs-gsurf-downloads-delete ()
  "Remove the current line from the downloads list (does not delete the file)."
  (interactive)
  (let ((id (cmacs-gsurf-downloads--id-at-point)))
    (setq cmacs-gsurf--downloads (assq-delete-all id cmacs-gsurf--downloads))
    (cmacs-gsurf-downloads--refresh)
    (tabulated-list-print t)))

(defvar cmacs-gsurf-downloads-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "c")   #'cmacs-gsurf-downloads-cancel)
    (define-key m (kbd "RET") #'cmacs-gsurf-downloads-open-file)
    (define-key m (kbd "o")   #'cmacs-gsurf-downloads-open-file)
    (define-key m (kbd "&")   #'cmacs-gsurf-downloads-open-external)
    (define-key m (kbd "d")   #'cmacs-gsurf-downloads-delete)
    m)
  "Keymap for `cmacs-gsurf-downloads-mode'.")

(define-derived-mode cmacs-gsurf-downloads-mode tabulated-list-mode "gsurf-dl"
  "Major mode listing cmacs-gsurf downloads."
  (setq tabulated-list-format
        [("ID" 4 (lambda (a b) (< (car a) (car b))))
         ("State" 10 t)
         ("%" 5 t)
         ("Size" 8 t)
         ("File" 32 t)
         ("URL" 60 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("ID" t))
  (add-hook 'tabulated-list-revert-hook #'cmacs-gsurf-downloads--refresh nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-gsurf-downloads ()
  "Open the cmacs-gsurf download manager buffer."
  (interactive)
  (let ((buf (get-buffer-create cmacs-gsurf-downloads-buffer-name)))
    (with-current-buffer buf
      (cmacs-gsurf-downloads-mode)
      (cmacs-gsurf-downloads--refresh)
      (tabulated-list-print t))
    (pop-to-buffer buf)))

(provide 'cmacs-gsurf-downloads)
;;; cmacs-gsurf-downloads.el ends here
