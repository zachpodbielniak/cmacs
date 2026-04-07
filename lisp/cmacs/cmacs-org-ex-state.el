;;; cmacs-org-ex-state.el --- Sidecar state persistence  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Persists ephemeral org-ex widget state to a sidecar file so that
;; widget values survive buffer kills and Emacs restarts.
;;
;; State file: <filename>.org-ex-state
;; Format: simple elisp alist written with `prin1'.
;;
;; Hooks into `cmacs-org-ex-mode':
;;   - On enable: restore state from sidecar if it exists
;;   - On `kill-buffer-hook': save current state to sidecar

;;; Code:

(require 'cl-lib)

(defcustom cmacs-org-ex-state-enabled t
  "When non-nil, persist widget state to sidecar files."
  :type 'boolean
  :group 'cmacs-org-ex)

(defcustom cmacs-org-ex-state-suffix ".org-ex-state"
  "Suffix appended to the Org file name to form the state file path."
  :type 'string
  :group 'cmacs-org-ex)

;;; State file path

(defun cmacs-org-ex-state--file ()
  "Return the state file path for the current buffer, or nil."
  (when buffer-file-name
    (concat buffer-file-name cmacs-org-ex-state-suffix)))

;;; Saving

(defun cmacs-org-ex-state-save ()
  "Save widget state for the current buffer to the sidecar file.
Collects property values from all registered widgets and writes
them as an alist."
  (when (and cmacs-org-ex-state-enabled
             (boundp 'cmacs-org-ex--document)
             cmacs-org-ex--document
             (boundp 'cmacs-org-ex--widget-ids)
             cmacs-org-ex--widget-ids)
    (let ((state-file (cmacs-org-ex-state--file))
          (state nil))
      (when state-file
        ;; Collect state from each widget.
        (dolist (pair cmacs-org-ex--widget-ids)
          (let* ((id (car pair))
                 (widget (condition-case nil
                             (org-ex-document-get-widget
                              cmacs-org-ex--document id)
                           (error nil))))
            (when widget
              (let ((entry (cmacs-org-ex-state--collect-widget
                            id widget)))
                (when entry
                  (push entry state))))))
        ;; Also collect channel values.
        (when (and (boundp 'cmacs-org-ex--channels)
                   cmacs-org-ex--channels)
          (dolist (pair cmacs-org-ex--channels)
            (push (list 'channel (car pair)) state)))
        ;; Write state file.
        (when state
          (with-temp-file state-file
            (insert ";; org-ex state file — auto-generated\n")
            (insert ";; Do not edit manually.\n\n")
            (prin1 (nreverse state) (current-buffer))
            (insert "\n")))))))

(defun cmacs-org-ex-state--collect-widget (id widget)
  "Collect saveable state from WIDGET with ID.
Returns an alist entry (ID . PROPS), or nil if nothing to save."
  (condition-case nil
      (let ((props nil))
        ;; Try to read common widget properties.
        (dolist (prop '("value" "text" "active"))
          (condition-case nil
              (let ((val (gobject-get widget prop)))
                (when val
                  (push (cons prop val) props)))
            (error nil)))
        (when props
          (cons id (nreverse props))))
    (error nil)))

;;; Restoring

(defun cmacs-org-ex-state-restore ()
  "Restore widget state from the sidecar file, if it exists."
  (when cmacs-org-ex-state-enabled
    (let ((state-file (cmacs-org-ex-state--file)))
      (when (and state-file (file-readable-p state-file))
        (condition-case err
            (let ((state (cmacs-org-ex-state--read state-file)))
              (when state
                ;; Defer restoration until after widgets are created.
                (run-with-timer
                 0.1 nil
                 #'cmacs-org-ex-state--apply state)))
          (error
           (message "org-ex: failed to restore state: %s"
                    (error-message-string err))))))))

(defun cmacs-org-ex-state--read (file)
  "Read and return the state alist from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (condition-case nil
        (read (current-buffer))
      (end-of-file nil))))

(defun cmacs-org-ex-state--apply (state)
  "Apply saved STATE to the current buffer's widgets.
STATE is an alist as written by `cmacs-org-ex-state-save'."
  (when (and (boundp 'cmacs-org-ex--document)
             cmacs-org-ex--document)
    (dolist (entry state)
      (pcase entry
        ;; Channel entries are just markers, no state to restore.
        (`(channel ,_name) nil)
        ;; Widget entries: (ID . ((PROP . VAL) ...))
        (`(,id . ,props)
         (when (stringp id)
           (let ((widget (condition-case nil
                             (org-ex-document-get-widget
                              cmacs-org-ex--document id)
                           (error nil))))
             (when widget
               (dolist (pair props)
                 (condition-case nil
                     (gobject-set widget (car pair) (cdr pair))
                   (error nil)))))))))))

;;; Cleanup

(defun cmacs-org-ex-state-delete ()
  "Delete the sidecar state file for the current buffer."
  (interactive)
  (let ((state-file (cmacs-org-ex-state--file)))
    (when (and state-file (file-exists-p state-file))
      (delete-file state-file)
      (message "Deleted %s" state-file))))

;;; Integration with cmacs-org-ex-mode

(defun cmacs-org-ex-state--kill-buffer-hook ()
  "Save state when an org-ex buffer is killed."
  (when (and (boundp 'cmacs-org-ex-mode)
             cmacs-org-ex-mode)
    (cmacs-org-ex-state-save)))

(add-hook 'kill-buffer-hook #'cmacs-org-ex-state--kill-buffer-hook)

(provide 'cmacs-org-ex-state)
;;; cmacs-org-ex-state.el ends here
