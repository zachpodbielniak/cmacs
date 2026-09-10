;;; cmacs-clawtilla-teach.el --- Teach an agent by showing it -*- lexical-binding: t; -*-

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

;; Record yourself doing something, and have the fleet turn it into a
;; skill.
;;
;; Four steps, and they are deliberately four: start, stop, synthesize,
;; commit.  Synthesizing is where a model reads the trace and proposes
;; a procedure, and committing is what makes that procedure something
;; agents will follow -- so the proposal can be read before it becomes
;; a thing that runs.  Collapsing those two would mean a recording
;; becoming behaviour without anybody looking at it.

;;; Code:

(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar-local cmacs-clawtilla-teach--traces nil)

(defun cmacs-clawtilla-teach--send (kind payload &optional then)
  "Send KIND with PAYLOAD, then run THEN or report."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind payload
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (if then
             (funcall then data)
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-teach--load buffer))))))))

;;;###autoload
(defun cmacs-clawtilla-teach-start (name)
  "Start recording a demonstration called NAME."
  (interactive "sWhat are you about to show it? ")
  (cmacs-clawtilla-teach--send
   "teach.start" (list (cons 'name name))
   (lambda (_data)
     (message "clawtilla: recording; M-x cmacs-clawtilla-teach-stop when done"))))

;;;###autoload
(defun cmacs-clawtilla-teach-stop ()
  "Stop recording."
  (interactive)
  (cmacs-clawtilla-teach--send
   "teach.stop" nil
   (lambda (_data) (message "clawtilla: stopped recording"))))

(defun cmacs-clawtilla-teach--trace-id ()
  "Return the id of the trace at point, or signal."
  (let ((trace (cmacs-clawtilla-value-at-point 'trace)))
    (unless trace (user-error "No recording at point"))
    (or (alist-get 'id trace) (user-error "That recording has no id"))))

(defun cmacs-clawtilla-teach-show ()
  "Show the recording at point."
  (interactive)
  (let ((id (cmacs-clawtilla-teach--trace-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "teach.show" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla teach: %s*" id))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (dolist (step (cmacs-clawtilla-get data 'steps))
               (insert (format "%s\n" (or (alist-get 'text step)
                                          (format "%s" step)))))
             (goto-char (point-min))
             (special-mode))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-teach-synthesize ()
  "Have the fleet read the recording at point and propose a skill.

Proposed, not adopted.  `cmacs-clawtilla-teach-commit' is what makes it
something agents follow, and the two are separate so the procedure can
be read first."
  (interactive)
  (cmacs-clawtilla-teach--send
   "teach.synthesize" (list (cons 'id (cmacs-clawtilla-teach--trace-id)))
   (lambda (data)
     (with-current-buffer (get-buffer-create "*clawtilla skill draft*")
       (let ((inhibit-read-only t))
         (erase-buffer)
         (insert (or (cmacs-clawtilla-get data 'text)
                     (cmacs-clawtilla-get data 'skill) ""))
         (insert "\n\n" (cmacs-clawtilla-dim
                         "M-x cmacs-clawtilla-teach-commit to adopt it")
                 "\n")
         (goto-char (point-min))
         (special-mode))
       (cmacs-clawtilla-display (current-buffer))))))

(defun cmacs-clawtilla-teach-commit ()
  "Adopt the skill synthesized from the recording at point."
  (interactive)
  (cmacs-clawtilla-teach--send
   "teach.commit" (list (cons 'id (cmacs-clawtilla-teach--trace-id)))))

(defun cmacs-clawtilla-teach-remove ()
  "Delete the recording at point."
  (interactive)
  (let ((id (cmacs-clawtilla-teach--trace-id)))
    (when (yes-or-no-p (format "Delete recording %s? " id))
      (cmacs-clawtilla-teach--send "teach.remove" (list (cons 'id id))))))

(defun cmacs-clawtilla-teach--draw ()
  "Redraw the recordings buffer."
  (cmacs-clawtilla-ui-preserving
    (insert (propertize "Recordings" 'face 'cmacs-clawtilla-heading) "\n\n")
    (if (null cmacs-clawtilla-teach--traces)
        (insert "  " (cmacs-clawtilla-dim
                      "nothing recorded; `s' starts a recording")
                "\n")
      (dolist (trace cmacs-clawtilla-teach--traces)
        (cmacs-clawtilla-insert-section
         :type 'trace :value trace :level 1
         :heading (format "%-24s %-10s %s"
                          (or (alist-get 'name trace)
                              (alist-get 'id trace) "?")
                          (or (alist-get 'state trace) "")
                          (cmacs-clawtilla-dim
                           (or (cmacs-clawtilla--time-label
                                (or (alist-get 'created trace) 0))
                               ""))))))))

(defun cmacs-clawtilla-teach--load (&optional buffer)
  "Refetch the recordings into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer)))
    (cmacs-clawtilla-request
     conn "teach.list" nil
     (lambda (data err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             (setq cmacs-clawtilla-teach--traces
                   (cmacs-clawtilla-get data 'traces))
             (cmacs-clawtilla-teach--draw))))))))

(transient-define-prefix cmacs-clawtilla-teach-menu ()
  "Teaching by demonstration."
  ["Record"
   [("s" "start recording" cmacs-clawtilla-teach-start)
    ("S" "stop" cmacs-clawtilla-teach-stop)]]
  ["A recording"
   [("RET" "show it" cmacs-clawtilla-teach-show)
    ("y" "propose a skill" cmacs-clawtilla-teach-synthesize)]
   [("c" "adopt the skill" cmacs-clawtilla-teach-commit)
    ("D" "delete" cmacs-clawtilla-teach-remove)]])

(defvar cmacs-clawtilla-teach-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "s") #'cmacs-clawtilla-teach-start)
    (define-key map (kbd "S") #'cmacs-clawtilla-teach-stop)
    (define-key map (kbd "RET") #'cmacs-clawtilla-teach-show)
    (define-key map (kbd "y") #'cmacs-clawtilla-teach-synthesize)
    (define-key map (kbd "c") #'cmacs-clawtilla-teach-commit)
    (define-key map (kbd "D") #'cmacs-clawtilla-teach-remove)
    (define-key map (kbd "?") #'cmacs-clawtilla-teach-menu)
    map)
  "Keymap for `cmacs-clawtilla-teach-mode'.")

(define-derived-mode cmacs-clawtilla-teach-mode special-mode "Clawtilla-Teach"
  "Major mode for recorded demonstrations."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-teach--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-teach (&optional conn)
  "Show the recorded demonstrations on CONN."
  (interactive)
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (buffer (get-buffer-create "*clawtilla teach*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-teach-mode)
        (cmacs-clawtilla-teach-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (cmacs-clawtilla-teach--load buffer))
    (cmacs-clawtilla-display buffer)))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-teach-mode-map 'cmacs-clawtilla-teach-mode)

(provide 'cmacs-clawtilla-teach)

;;; cmacs-clawtilla-teach.el ends here
