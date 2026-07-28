;;; cmacs-gsurf-bookmarks.el --- tagged bookmarks for gsurf  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A small standalone, tagged bookmark store for the cmacs-gsurf browser,
;; browsed in a `tabulated-list-mode' buffer (`M-x cmacs-gsurf-bookmarks').
;; Each entry is (URL TITLE TAGS ADDED); the store is persisted to
;; `cmacs-gsurf-bookmarks-file' with `prin1'/`read'.  RET opens a bookmark
;; in gsurf.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence
(require 'tabulated-list)

(declare-function cmacs-gsurf "cmacs-gsurf" (&optional url))
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))

(defgroup cmacs-gsurf-bookmarks nil
  "Tagged bookmarks for the cmacs-gsurf browser."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-bookmark")

(defcustom cmacs-gsurf-bookmarks-file
  (expand-file-name "cmacs/gsurf-bookmarks.el"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name "~/.config")))
  "File where gsurf bookmarks are persisted."
  :type 'file
  :group 'cmacs-gsurf-bookmarks)

(defvar cmacs-gsurf--bookmarks 'unset
  "In-memory bookmark list, or `unset' before the store is loaded.
Each element is (URL TITLE TAGS ADDED).")

(defconst cmacs-gsurf-bookmarks-buffer-name "*gsurf-bookmarks*")

(defvar-local cmacs-gsurf-bookmarks--filter nil
  "When non-nil, only show bookmarks carrying this tag.")

(defun cmacs-gsurf-bookmarks--ensure ()
  "Load the store from disk on first use."
  (when (eq cmacs-gsurf--bookmarks 'unset)
    (setq cmacs-gsurf--bookmarks
          (and (file-exists-p cmacs-gsurf-bookmarks-file)
               (with-temp-buffer
                 (insert-file-contents cmacs-gsurf-bookmarks-file)
                 (ignore-errors (read (current-buffer)))))))
  cmacs-gsurf--bookmarks)

(defun cmacs-gsurf-bookmarks--save ()
  "Persist the store to `cmacs-gsurf-bookmarks-file'."
  (make-directory (file-name-directory cmacs-gsurf-bookmarks-file) t)
  (with-temp-file cmacs-gsurf-bookmarks-file
    (let ((print-length nil) (print-level nil))
      (prin1 cmacs-gsurf--bookmarks (current-buffer))
      (insert "\n"))))

(defun cmacs-gsurf-bookmarks--all-tags ()
  (delete-dups (apply #'append (mapcar (lambda (b) (copy-sequence (nth 2 b)))
                                       (cmacs-gsurf-bookmarks--ensure)))))

;;;###autoload
(defun cmacs-gsurf-bookmark-add (url title tags)
  "Add a bookmark for URL with TITLE and TAGS (a list of strings).
Interactively, defaults URL/TITLE from the current gsurf buffer and reads
comma-separated tags."
  (interactive
   (let ((u (and (ignore-errors (cmacs-gsurf-attached-p (current-buffer)))
                 (ignore-errors (cmacs-gsurf-get-uri (current-buffer)))))
         (ti (and (ignore-errors (cmacs-gsurf-attached-p (current-buffer)))
                  (ignore-errors (cmacs-gsurf-get-title (current-buffer))))))
     (list (read-string "Bookmark URL: " u)
           (read-string "Title: " ti)
           (completing-read-multiple
            "Tags (comma-separated): " (cmacs-gsurf-bookmarks--all-tags)))))
  (cmacs-gsurf-bookmarks--ensure)
  (setq cmacs-gsurf--bookmarks
        (cons (list url title tags (format-time-string "%Y-%m-%d %H:%M"))
              (cl-remove-if (lambda (b) (equal (car b) url))
                            cmacs-gsurf--bookmarks)))
  (cmacs-gsurf-bookmarks--save)
  (when (get-buffer cmacs-gsurf-bookmarks-buffer-name)
    (with-current-buffer cmacs-gsurf-bookmarks-buffer-name
      (revert-buffer)))
  (message "gsurf: bookmarked %s" url))

(defun cmacs-gsurf-bookmarks--refresh ()
  "Rebuild `tabulated-list-entries' from the (filtered) store."
  (cmacs-gsurf-bookmarks--ensure)
  (setq tabulated-list-entries
        (delq nil
              (mapcar
               (lambda (b)
                 (cl-destructuring-bind (url title tags added) b
                   (when (or (null cmacs-gsurf-bookmarks--filter)
                             (member cmacs-gsurf-bookmarks--filter tags))
                     (list url
                           (vector (or title "")
                                   (or url "")
                                   (mapconcat #'identity tags ",")
                                   (or added ""))))))
               cmacs-gsurf--bookmarks))))

(defun cmacs-gsurf-bookmarks--url-at-point ()
  (or (tabulated-list-get-id) (user-error "No bookmark on this line")))

(defun cmacs-gsurf-bookmarks-open ()
  "Open the bookmark on the current line in gsurf."
  (interactive)
  (cmacs-gsurf (cmacs-gsurf-bookmarks--url-at-point)))

(defun cmacs-gsurf-bookmarks-delete ()
  "Delete the bookmark on the current line."
  (interactive)
  (let ((url (cmacs-gsurf-bookmarks--url-at-point)))
    (setq cmacs-gsurf--bookmarks
          (cl-remove-if (lambda (b) (equal (car b) url)) cmacs-gsurf--bookmarks))
    (cmacs-gsurf-bookmarks--save)
    (revert-buffer)
    (message "gsurf: deleted bookmark %s" url)))

(defun cmacs-gsurf-bookmarks-edit-tags ()
  "Edit the tags of the bookmark on the current line."
  (interactive)
  (let* ((url (cmacs-gsurf-bookmarks--url-at-point))
         (entry (assoc url cmacs-gsurf--bookmarks))
         (tags (completing-read-multiple
                "Tags: " (cmacs-gsurf-bookmarks--all-tags) nil nil
                (mapconcat #'identity (nth 2 entry) ","))))
    (setf (nth 2 entry) tags)
    (cmacs-gsurf-bookmarks--save)
    (revert-buffer)))

(defun cmacs-gsurf-bookmarks-filter (tag)
  "Show only bookmarks tagged TAG (empty input clears the filter)."
  (interactive (list (completing-read "Filter by tag (empty = all): "
                                      (cmacs-gsurf-bookmarks--all-tags))))
  (setq cmacs-gsurf-bookmarks--filter (if (string-empty-p tag) nil tag))
  (revert-buffer))

(defvar cmacs-gsurf-bookmarks-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-gsurf-bookmarks-open)
    (define-key m (kbd "o")   #'cmacs-gsurf-bookmarks-open)
    (define-key m (kbd "d")   #'cmacs-gsurf-bookmarks-delete)
    (define-key m (kbd "e")   #'cmacs-gsurf-bookmarks-edit-tags)
    (define-key m (kbd "/")   #'cmacs-gsurf-bookmarks-filter)
    (define-key m (kbd "a")   #'cmacs-gsurf-bookmark-add)
    m)
  "Keymap for `cmacs-gsurf-bookmarks-mode'.")

(define-derived-mode cmacs-gsurf-bookmarks-mode tabulated-list-mode "gsurf-bm"
  "Major mode listing cmacs-gsurf bookmarks."
  (setq tabulated-list-format
        [("Title" 30 t) ("URL" 48 t) ("Tags" 18 t) ("Added" 16 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("Added" t))
  (add-hook 'tabulated-list-revert-hook #'cmacs-gsurf-bookmarks--refresh nil t)
  (tabulated-list-init-header))

;; Under Evil (Doom) the state maps outrank the major-mode map, so `o'/`d'
;; /`e'/`a' ran Evil commands instead of the list actions.  Install the map
;; as an Evil intercept map (see cmacs-evil.el).
(cmacs-evil-setup-mode-map cmacs-gsurf-bookmarks-mode-map
                           'cmacs-gsurf-bookmarks-mode)

;;;###autoload
(defun cmacs-gsurf-bookmarks ()
  "Open the cmacs-gsurf bookmarks buffer."
  (interactive)
  (let ((buf (get-buffer-create cmacs-gsurf-bookmarks-buffer-name)))
    (with-current-buffer buf
      (cmacs-gsurf-bookmarks-mode)
      (cmacs-gsurf-bookmarks--refresh)
      (tabulated-list-print t))
    (pop-to-buffer buf)))

(provide 'cmacs-gsurf-bookmarks)
;;; cmacs-gsurf-bookmarks.el ends here
