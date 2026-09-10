;;; cmacs-clawtilla-ui.el --- Sections and faces for clawtilla buffers -*- lexical-binding: t; -*-

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

;; The parts every clawtilla buffer shares: collapsible sections, the
;; faces, and the redraw discipline.
;;
;; Sections are magit's interaction model rather than magit's code --
;; magit is not a dependency of Emacs and this needs to work in a bare
;; build.  A section is a run of text carrying `cmacs-clawtilla-section'
;; in its text properties: a TYPE, a VALUE the commands act on, and a
;; level.  TAB folds, and the fold state survives a redraw because it is
;; keyed on the section's identity rather than on its position.
;;
;; That last part is the whole reason this file exists.  A fleet buffer
;; redraws on every event -- an agent changing state, a message
;; arriving -- and a redraw that forgets which sections were folded, or
;; that moves point to the top, makes the buffer unusable exactly when
;; the fleet is busy.  `cmacs-clawtilla-ui-preserving' keeps both.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defface cmacs-clawtilla-heading
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a section heading."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-agent
  '((t :inherit font-lock-function-name-face))
  "Face for an agent's name."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-team
  '((t :inherit font-lock-type-face :weight bold))
  "Face for a team's name."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-dim
  '((t :inherit shadow))
  "Face for detail that should not compete with the thing it describes."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-running
  '((t :inherit success))
  "Face for an agent that is up."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-stopped
  '((t :inherit shadow))
  "Face for an agent that is not running.

Deliberately not a warning face: an agent that is switched off is the
ordinary case, and colouring it as a problem trains you to ignore the
one that is."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-busy
  '((t :inherit warning))
  "Face for an agent that is mid-turn."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-error
  '((t :inherit error))
  "Face for something that failed."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-badge
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for a role badge such as CHIEF or LEAD."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-unread
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for an unread count."
  :group 'cmacs-clawtilla)


;;;; Sections.

(defvar-local cmacs-clawtilla-ui--folded nil
  "Identities of the sections that are folded in this buffer.")

(defun cmacs-clawtilla-ui--identity (type value)
  "Return the fold key for a section of TYPE holding VALUE."
  (format "%s/%s" type
          (cond ((stringp value) value)
                ((symbolp value) (symbol-name value))
                ((and (consp value) (consp (car value)))
                 (or (alist-get 'id value) (alist-get 'name value) ""))
                (t (format "%s" value)))))

(cl-defun cmacs-clawtilla-insert-section
    (&key type value heading (level 0) foldable body)
  "Insert a section of TYPE holding VALUE.

HEADING is a string, already propertised.  BODY is a function called
with point inside the section to draw its contents.  FOLDABLE non-nil
lets TAB collapse it."
  (let* ((identity (cmacs-clawtilla-ui--identity type value))
         (folded (and foldable
                      (member identity cmacs-clawtilla-ui--folded)))
         (start (point)))
    (when heading
      (insert (make-string (* 2 level) ?\s))
      (when foldable
        (insert (propertize (if folded "▸ " "▾ ")
                            'face 'cmacs-clawtilla-dim)))
      (insert heading "\n"))
    (let ((body-start (point)))
      (when (and body (not folded))
        (funcall body))
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type type :value value :identity identity
                               :level level :foldable foldable))
      ;; The heading keeps its own property so point on a heading finds
      ;; the section it heads rather than whatever is nested inside it.
      (when heading
        (put-text-property start body-start 'cmacs-clawtilla-heading-p t)))))

(defun cmacs-clawtilla-section-at-point ()
  "Return the section at point as a plist, or nil."
  (get-text-property (point) 'cmacs-clawtilla-section))

(defun cmacs-clawtilla-value-at-point (&optional type)
  "Return the value of the section at point, requiring TYPE if given."
  (let ((section (cmacs-clawtilla-section-at-point)))
    (when (and section (or (null type) (eq (plist-get section :type) type)))
      (plist-get section :value))))

(defun cmacs-clawtilla-toggle-fold ()
  "Fold or unfold the section at point."
  (interactive)
  (let ((section (cmacs-clawtilla-section-at-point)))
    (unless (and section (plist-get section :foldable))
      (user-error "Nothing to fold here"))
    (let ((identity (plist-get section :identity)))
      (setq cmacs-clawtilla-ui--folded
            (if (member identity cmacs-clawtilla-ui--folded)
                (delete identity cmacs-clawtilla-ui--folded)
              (cons identity cmacs-clawtilla-ui--folded))))
    (cmacs-clawtilla-refresh)))

(defun cmacs-clawtilla-next-section ()
  "Move to the next section heading."
  (interactive)
  (let ((next (next-single-property-change
               (point) 'cmacs-clawtilla-section)))
    (while (and next (not (get-text-property next 'cmacs-clawtilla-heading-p)))
      (setq next (next-single-property-change
                  next 'cmacs-clawtilla-section)))
    (goto-char (or next (point-max)))))

(defun cmacs-clawtilla-previous-section ()
  "Move to the previous section heading."
  (interactive)
  (let ((prev (previous-single-property-change
               (point) 'cmacs-clawtilla-section)))
    (while (and prev (not (get-text-property prev 'cmacs-clawtilla-heading-p)))
      (setq prev (previous-single-property-change
                  prev 'cmacs-clawtilla-section)))
    (goto-char (or prev (point-min)))))


;;;; Redrawing.

(defvar-local cmacs-clawtilla-refresh-function nil
  "Function that redraws this buffer, called with no arguments.")

(defun cmacs-clawtilla-refresh ()
  "Redraw this buffer."
  (interactive)
  (when cmacs-clawtilla-refresh-function
    (funcall cmacs-clawtilla-refresh-function)))

(defmacro cmacs-clawtilla-ui-preserving (&rest body)
  "Redraw the buffer with BODY, keeping point, window start and folds.

A fleet buffer redraws on every event.  A redraw that sends point back
to the top makes the buffer unusable exactly when the fleet is busy and
you most want to read it, so position is restored by SECTION IDENTITY
rather than by character offset: the line an agent was on moves when a
team above it gains a member, and a saved offset would then land
somewhere else and look like the buffer jumped on its own."
  (declare (indent 0) (debug t))
  `(let* ((inhibit-read-only t)
          (section (cmacs-clawtilla-section-at-point))
          (identity (and section (plist-get section :identity)))
          (column (current-column))
          (window (get-buffer-window (current-buffer)))
          (start (and window (window-start window))))
     (erase-buffer)
     ,@body
     (goto-char (point-min))
     (when identity
       (let ((found nil) (pos (point-min)))
         (while (and (not found) (< pos (point-max)))
           (let ((here (get-text-property pos 'cmacs-clawtilla-section)))
             (if (and here (equal (plist-get here :identity) identity))
                 (setq found pos)
               (setq pos (or (next-single-property-change
                              pos 'cmacs-clawtilla-section)
                             (point-max))))))
         (when found
           (goto-char found)
           (move-to-column column))))
     (when (and window start (<= start (point-max)))
       (set-window-start window start t))))


;;;; Shared keymap.

(defvar cmacs-clawtilla-common-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'cmacs-clawtilla-toggle-fold)
    (define-key map (kbd "n") #'cmacs-clawtilla-next-section)
    (define-key map (kbd "p") #'cmacs-clawtilla-previous-section)
    (define-key map (kbd "g") #'cmacs-clawtilla-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keys every clawtilla list buffer has.")


;;;; Small renderers.

(defun cmacs-clawtilla-state-face (state)
  "Return the face for an agent STATE string."
  (pcase state
    ((or "running" "connected" "ready") 'cmacs-clawtilla-running)
    ((or "busy" "thinking" "starting") 'cmacs-clawtilla-busy)
    ((or "error" "failed" "crashed") 'cmacs-clawtilla-error)
    (_ 'cmacs-clawtilla-stopped)))

(defun cmacs-clawtilla-badge (text)
  "Return TEXT as a role badge."
  (propertize (upcase text) 'face 'cmacs-clawtilla-badge))

(defun cmacs-clawtilla-dim (text)
  "Return TEXT dimmed."
  (propertize (or text "") 'face 'cmacs-clawtilla-dim))

(defun cmacs-clawtilla-format-time (seconds)
  "Format SECONDS, a Unix time, the way both graphical clients do.

Today is a clock, anything older carries its date: a bare time on a
message from last week reads as one from this morning."
  (when (and seconds (numberp seconds) (> seconds 0))
    (let* ((then (seconds-to-time seconds))
           (today (format-time-string "%F"))
           (day (format-time-string "%F" then)))
      (if (equal today day)
          (format-time-string "%H:%M" then)
        (format-time-string "%b %-d %H:%M" then)))))

(provide 'cmacs-clawtilla-ui)

;;; cmacs-clawtilla-ui.el ends here
