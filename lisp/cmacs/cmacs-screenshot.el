;;; cmacs-screenshot.el --- open a capture for annotation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where a screenshot goes after it is taken.
;;
;; The gowl bar's screenshot widget saves a PNG and can hand the path
;; here, which is the "send it to cmacs" half of annotating: the
;; capture lands in an Emacs buffer instead of a separate application.
;;
;; `cmacs-imgedit' is used when the build has it, and is deliberately
;; NOT required.  imgedit is an optional subsystem, and a screenshot
;; that cannot be opened at all on a build without it would be a worse
;; outcome than one opened read-only.  So this degrades in one step:
;; the image editor if it is there, an ordinary image buffer if it is
;; not.  Either way the file is already saved and already on the
;; clipboard -- annotation is the extra, not the deliverable.

;;; Code:

(defgroup cmacs-screenshot nil
  "What happens to a screenshot after it is captured."
  :group 'cmacs
  :prefix "cmacs-screenshot-")

(defcustom cmacs-screenshot-directory "~/Pictures/Screenshots"
  "Where the compositor saves captures.
Only used to offer a sensible default when opening one by hand; the
compositor's own `save-directory' is what actually decides."
  :type 'directory
  :group 'cmacs-screenshot)

(defcustom cmacs-screenshot-annotate-function nil
  "Function called with a capture's path to annotate it.
When nil, `cmacs-screenshot-annotate' picks the best available: the
image editor on a build that has it, an image buffer otherwise.

Set this to route captures somewhere else entirely --- an external
annotator, an org capture, a upload."
  :type '(choice (const :tag "Best available" nil) function)
  :group 'cmacs-screenshot)

(defun cmacs-screenshot--imgedit-available-p ()
  "Non-nil when this build can edit images."
  (and (fboundp 'cmacs-imgedit-supported-p)
       (fboundp 'cmacs-imgedit-open-file)
       (ignore-errors (cmacs-imgedit-supported-p))))

;;;###autoload
(defun cmacs-screenshot-annotate (path)
  "Open the capture at PATH for annotation.

Uses `cmacs-screenshot-annotate-function' when set.  Otherwise the
image editor if this build has one, and a plain image buffer if it does
not --- imgedit is optional, and refusing to show the capture at all on
a build without it helps nobody."
  (interactive
   (list (read-file-name "Annotate capture: "
                         (file-name-as-directory
                          (expand-file-name cmacs-screenshot-directory)))))
  (let ((file (expand-file-name path)))
    (unless (file-readable-p file)
      (user-error "No such capture: %s" file))
    (cond
     (cmacs-screenshot-annotate-function
      (funcall cmacs-screenshot-annotate-function file))
     ((cmacs-screenshot--imgedit-available-p)
      (cmacs-imgedit-open-file file))
     (t
      ;; Not an error, and not silent about the difference: the image
      ;; is here and viewable, it just cannot be drawn on.
      (find-file file)
      (message "Viewing %s -- build with --with-cmacs-imgedit to annotate"
               (file-name-nondirectory file))))))

;;;###autoload
(defun cmacs-screenshot-annotate-latest ()
  "Open the most recent capture for annotation."
  (interactive)
  (let* ((dir (expand-file-name cmacs-screenshot-directory))
         (files (and (file-directory-p dir)
                     (directory-files dir t "\\.png\\'" t))))
    (unless files
      (user-error "No captures in %s" dir))
    ;; Newest by mtime rather than by name: the filename format is a
    ;; setting, and sorting by it breaks the moment somebody changes it.
    (cmacs-screenshot-annotate
     (car (sort files
                (lambda (a b)
                  (time-less-p (file-attribute-modification-time
                                (file-attributes b))
                               (file-attribute-modification-time
                                (file-attributes a)))))))))

(provide 'cmacs-screenshot)

;;; cmacs-screenshot.el ends here
