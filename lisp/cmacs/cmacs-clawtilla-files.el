;;; cmacs-clawtilla-files.el --- The files sent in a conversation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A conversation's Files page: every file sent in it, by you or the
;; agent, with a preview of each.
;;
;; `attachment.list' reads the room's whole history for attachment
;; blocks -- the format `cmacs-clawtilla-chat-attach' writes through
;; libclawt -- and answers one item per file: its `id' (the daemon's own
;; copy), its `name', `kind' (image, pdf, text or other), who sent it and
;; when, and whether the copy still `exists'.
;;
;; A preview is the picture itself for an image, the first page for a
;; PDF and the first lines for a text file.  The last two are the
;; daemon's work (`attachment.thumbnail'): rendering a PDF is not
;; something every client should have to be able to do.  Each preview is
;; a request, so only the first `cmacs-clawtilla-files-previews' are
;; fetched, and each is fetched once -- the bytes are cached under the
;; user's cache directory, by id, exactly where the GTK client keeps
;; them, so a file opened in one is already there for the other.
;;
;; Everything is asynchronous: the page draws at once with names, and
;; the previews arrive into it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)

(defcustom cmacs-clawtilla-files-previews 60
  "How many files of a conversation get a preview.

Each is a request made while the page opens: the picture itself for an
image, a thumbnail for a PDF or a text file.  The rest are listed by
name and open like any other."
  :type 'integer
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-files-thumbnail-size 160
  "The size, in pixels, a preview is asked for and drawn at."
  :type 'integer
  :group 'cmacs-clawtilla)

(defun cmacs-clawtilla-files--cache-directory ()
  "Return where fetched attachments are kept, creating it private.

`$XDG_CACHE_HOME/clawtilla/attachments', the GTK client's own cache: a
file fetched by one client is there for the other."
  (let ((dir (expand-file-name
              "clawtilla/attachments"
              (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))))
    (unless (file-directory-p dir)
      (with-file-modes #o700 (make-directory dir t)))
    dir))

(defun cmacs-clawtilla-files--cache-path (id)
  "Return where the attachment ID is cached.

ID comes from the daemon, so it is reduced to a file name first: an id
with a slash in it must not name a file outside the cache."
  (expand-file-name (file-name-nondirectory (format "%s" id))
                    (cmacs-clawtilla-files--cache-directory)))

(defun cmacs-clawtilla-files-fetch (conn id callback)
  "Fetch the attachment ID from CONN and call CALLBACK with its local path.

CALLBACK receives (PATH ERROR).  Served from the cache when it is there
already; otherwise `attachment.get' brings the bytes -- they travel
rather than a path, because the daemon may be on another machine."
  (let ((path (cmacs-clawtilla-files--cache-path id)))
    (if (file-exists-p path)
        (funcall callback path nil)
      (cmacs-clawtilla-request
       conn "attachment.get" (list (cons 'id id))
       (lambda (data err)
         (let ((encoded (cmacs-clawtilla-get data 'base64)))
           (cond
            (err (funcall callback nil err))
            ((not (stringp encoded))
             (funcall callback nil "that file is not available here"))
            (t
             (let ((coding-system-for-write 'binary))
               (with-file-modes #o600
                 (with-temp-file path
                   (set-buffer-multibyte nil)
                   (insert (base64-decode-string encoded)))))
             (funcall callback path nil)))))))))


;;;; Previews.

(defun cmacs-clawtilla-files--image (data-or-file &optional file-p)
  "Return DATA-OR-FILE as an image scaled to the preview size, or nil.

FILE-P non-nil says it is a path rather than the bytes.  nil where
this Emacs cannot draw the format, or draws no images at all -- the row
then keeps its name and its kind, which is the truth about it."
  (when (and (display-images-p) data-or-file)
    (ignore-errors
      (create-image data-or-file nil (not file-p)
                    :max-width cmacs-clawtilla-files-thumbnail-size
                    :max-height cmacs-clawtilla-files-thumbnail-size))))

(defun cmacs-clawtilla-files--previews ()
  "Return this page's preview table: id to an image or a string."
  (or (cmacs-clawtilla-page-state :previews)
      (let ((table (make-hash-table :test 'equal)))
        (cmacs-clawtilla-page-set-state :previews table)
        table)))

(defvar-local cmacs-clawtilla-files--redraw nil
  "The timer of a redraw this page has waiting, or nil.")

(defun cmacs-clawtilla-files--preview-arrived (buffer id preview)
  "Record PREVIEW for the file ID in BUFFER and redraw it, shortly.

Shortly, and once: a cached file answers at once -- from inside the
draw that asked for it, which a redraw must not be started from -- and
sixty previews arriving together are one redraw, not sixty."
  (when (and preview (buffer-live-p buffer))
    (with-current-buffer buffer
      (puthash id preview (cmacs-clawtilla-files--previews))
      (unless cmacs-clawtilla-files--redraw
        (setq cmacs-clawtilla-files--redraw
              (run-at-time
               0.05 nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq cmacs-clawtilla-files--redraw nil)
                     (cmacs-clawtilla-page--draw))))))))))

(defun cmacs-clawtilla-files--fetch-preview (buffer conn item)
  "Ask CONN for a preview of ITEM and draw it into BUFFER when it arrives."
  (let ((id (alist-get 'id item))
        (kind (or (alist-get 'kind item) "other")))
    (cond
     ((equal kind "image")
      ;; The picture itself, scaled here.
      (cmacs-clawtilla-files-fetch
       conn id
       (lambda (path _err)
         (cmacs-clawtilla-files--preview-arrived
          buffer id (and path (cmacs-clawtilla-files--image path t))))))
     ((member kind '("pdf" "text"))
      (cmacs-clawtilla-request
       conn "attachment.thumbnail"
       ;; `size' is an integer, which is how the daemon reads it.
       (list (cons 'id id)
             (cons 'size cmacs-clawtilla-files-thumbnail-size))
       (lambda (data err)
         (unless err
           (let ((text (cmacs-clawtilla-get data 'text))
                 (encoded (cmacs-clawtilla-get data 'base64)))
             (cmacs-clawtilla-files--preview-arrived
              buffer id
              (cond ((stringp text) text)
                    ((stringp encoded)
                     (cmacs-clawtilla-files--image
                      (ignore-errors
                        (base64-decode-string encoded))))))))))))))

(defun cmacs-clawtilla-files--want-previews ()
  "Fetch the previews this page has not asked for yet."
  (let ((asked (or (cmacs-clawtilla-page-state :asked)
                   (let ((table (make-hash-table :test 'equal)))
                     (cmacs-clawtilla-page-set-state :asked table)
                     table)))
        (conn cmacs-clawtilla-connection)
        (buffer (current-buffer))
        (left cmacs-clawtilla-files-previews))
    (dolist (item (cmacs-clawtilla-page-data 'items 'items))
      (let ((id (alist-get 'id item)))
        (when (and id (> left 0) (eq t (alist-get 'exists item)))
          (setq left (1- left))
          (unless (gethash id asked)
            (puthash id t asked)
            (cmacs-clawtilla-files--fetch-preview buffer conn item)))))))


;;;; Drawing.

(defun cmacs-clawtilla-files--meta (item)
  "Return who sent ITEM and when."
  (let ((sender (or (alist-get 'sender item) ""))
        (ts (alist-get 'ts item)))
    (concat (if (equal sender "user") "you" sender)
            (if (and (numberp ts) (> ts 0))
                (concat " · " (format-time-string "%Y-%m-%d %H:%M"
                                                  (seconds-to-time ts)))
              ""))))

(defun cmacs-clawtilla-files--draw ()
  "Draw the Files page."
  (let ((items (cmacs-clawtilla-page-data 'items 'items))
        (previews (cmacs-clawtilla-files--previews)))
    (if (null items)
        (cmacs-clawtilla-page-insert-note
         "No files yet"
         "Files sent in this conversation, by you or the agent, appear here.")
      (dolist (item items)
        (let* ((id (alist-get 'id item))
               (exists (eq t (alist-get 'exists item)))
               (preview (and id (gethash id previews))))
          (cmacs-clawtilla-insert-section
           :type 'file :value item :level 1
           :heading (concat
                     (propertize (or (alist-get 'name item) "file")
                                 'face (if exists 'cmacs-clawtilla-agent
                                         'cmacs-clawtilla-dim))
                     "  "
                     (cmacs-clawtilla-dim
                      (concat (or (alist-get 'kind item) "other") " · "
                              (cmacs-clawtilla-files--meta item)
                              (if exists "" " · no longer kept"))))
           :body (lambda ()
                   (cond
                    ((stringp preview)
                     (dolist (line (split-string preview "\n"))
                       (insert "      " (cmacs-clawtilla-dim line) "\n")))
                    (preview
                     (insert "      ")
                     (insert-image preview "[preview]")
                     (insert "\n")))))))
      ;; After drawing, never before: the previews arrive into a page
      ;; that is already showing every name.
      (cmacs-clawtilla-files--want-previews))))


;;;; Acting.

(defun cmacs-clawtilla-files--with-local (item callback)
  "Call CALLBACK with a local path for the file ITEM.

An item with an id is the daemon's copy and is fetched; an old
message's item has only a host path, which is used if this is that
host."
  (let ((id (alist-get 'id item))
        (path (alist-get 'path item)))
    (cond
     (id (cmacs-clawtilla-files-fetch
          (cmacs-clawtilla-current) id
          (lambda (local err)
            (if local
                (funcall callback local)
              (message "clawtilla: %s"
                       (or err "that file is not available here"))))))
     ((and (stringp path) (file-readable-p path)) (funcall callback path))
     (t (user-error "That file is not available here")))))

(defun cmacs-clawtilla-files-open ()
  "Open the file at point."
  (interactive)
  (cmacs-clawtilla-files--with-local
   (cmacs-clawtilla-page-row 'file)
   (lambda (path)
     ;; A copy under the file's own name: the cache names files by id,
     ;; and a buffer called by an id says nothing, nor does it pick the
     ;; mode its extension would.
     (let* ((item (cmacs-clawtilla-page-row 'file))
            (name (file-name-nondirectory (or (alist-get 'name item) "file")))
            (dir (make-temp-file "clawtilla-file" t))
            (copy (expand-file-name name dir)))
       (copy-file path copy t)
       (find-file copy)))))

(defun cmacs-clawtilla-files-save (target)
  "Save a copy of the file at point as TARGET."
  (interactive
   (let ((item (cmacs-clawtilla-page-row 'file)))
     (list (read-file-name "Save a copy as: " nil nil nil
                           (file-name-nondirectory
                            (or (alist-get 'name item) "file"))))))
  (cmacs-clawtilla-files--with-local
   (cmacs-clawtilla-page-row 'file)
   (lambda (path)
     (copy-file path target 1)
     (message "clawtilla: saved %s" target))))

(defun cmacs-clawtilla-files-copy-path ()
  "Copy a local path to the file at point."
  (interactive)
  (cmacs-clawtilla-files--with-local
   (cmacs-clawtilla-page-row 'file)
   (lambda (path)
     (kill-new path)
     (message "clawtilla: %s" path))))

(cmacs-clawtilla-define-page "files"
  :title "Files"
  :intro "Every file sent in this conversation, by you or the agent."
  :fetch '((items "attachment.list"))
  :draw #'cmacs-clawtilla-files--draw
  :verbs '(("RET" "open" cmacs-clawtilla-files-open)
           ("s" "save a copy" cmacs-clawtilla-files-save)
           ("y" "copy path" cmacs-clawtilla-files-copy-path)))

;;;###autoload
(defun cmacs-clawtilla-files (&optional conn agent room)
  "Show the files sent in the conversation with AGENT, or in ROOM, on CONN.

A room when there is one -- a group, or a peer exchange -- and otherwise
the agent, whose conversation with you the daemon then looks in."
  (interactive
   (list (cmacs-clawtilla-current)
         (cmacs-clawtilla-read-agent "Files sent with: ")))
  (if room
      (cmacs-clawtilla-page-open "files" conn nil room)
    (cmacs-clawtilla-page-open "files" conn agent)))

(provide 'cmacs-clawtilla-files)

;;; cmacs-clawtilla-files.el ends here
