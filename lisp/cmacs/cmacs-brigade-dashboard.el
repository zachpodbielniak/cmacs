;;; cmacs-brigade-dashboard.el --- Watching the brigade  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A live view of what the agents are doing.
;;
;; The dashboard is a *pure projection*.  It never holds state of its
;; own, and its keys call exactly the functions the org hooks call -- so
;; there are two writers (org and the runtime) and three readers, rather
;; than three things that each think they know the answer.
;;
;; Rendering is a full redraw on `special-mode' rather than
;; `tabulated-list-mode': the view is a tree with per-row progress, which
;; tabulated-list does badly, and `cmacs-transcode' already worked out
;; how to redraw without losing the cursor.
;;
;; Refresh is event-driven with a coalescing idle timer, never a poll.
;; Eight streaming agents deliver progress at tens of hertz each, and
;; redrawing per event melts the display; a 2-second heartbeat only
;; refreshes elapsed times.
;;
;; It works identically in a terminal.  Under `emacs --lrg'
;; `display-graphic-p' returns t while there is no menu bar, so anything
;; here that wants a menu uses `cmacs-libregnum-popup-menu' -- an ERT
;; test greps this file to keep it that way.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-dashboard-refresh-idle 0.15
  "Seconds of idle time before a dirty dashboard redraws."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-dashboard-heartbeat 2
  "Seconds between refreshes of elapsed times."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-dashboard-unicode 'auto
  "Whether to use Unicode status glyphs.
`auto' checks whether the display can show them."
  :type '(choice (const auto) (const t) (const nil))
  :group 'cmacs-brigade)

(defvar cmacs-brigade-dashboard--timer nil)
(defvar cmacs-brigade-dashboard--heartbeat nil)
(defvar cmacs-brigade-dashboard--dirty nil)

(defconst cmacs-brigade-dashboard--glyphs
  '((running       . ("▶" . ">"))
    (starting      . ("▶" . ">"))
    (queued        . ("⏳" . "."))
    (draft         . ("·" . "-"))
    (waiting-input . ("?" . "?"))
    (blocked       . ("⏸" . "|"))
    (interrupted   . ("⚠" . "!"))
    (done          . ("✔" . "+"))
    (failed        . ("✖" . "x"))
    (over-budget   . ("⚠" . "$"))
    (cancelled     . ("⊘" . "o")))
  "Status glyphs, Unicode and ASCII.")

(defun cmacs-brigade-dashboard--unicode-p ()
  (pcase cmacs-brigade-dashboard-unicode
    ('auto (char-displayable-p ?▶))
    (v v)))

(defun cmacs-brigade-dashboard--glyph (state)
  (let ((pair (alist-get state cmacs-brigade-dashboard--glyphs)))
    (if (cmacs-brigade-dashboard--unicode-p) (car pair) (cdr pair))))

(defun cmacs-brigade-dashboard--elapsed (record)
  "Human-readable elapsed time for RECORD."
  (let ((start (plist-get record :started-at))
        (end (plist-get record :ended-at)))
    (if (or (null start) (zerop start)) "—"
      (let ((secs (- (if (and end (> end 0)) end (floor (float-time))) start)))
        (format "%d:%02d" (/ secs 60) (% secs 60))))))

(defun cmacs-brigade-dashboard--render ()
  "Redraw the dashboard, keeping the cursor where it was."
  (let ((buf (get-buffer "*brigade*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (line (line-number-at-pos))
              (records (and (fboundp 'cmacs-brigade-task-list)
                            (cmacs-brigade-task-list))))
          (erase-buffer)
          (cmacs-brigade-dashboard--insert-header records)
          (insert (make-string 78 ?─) "\n")
          (insert (propertize
                   (format "%-3s %-10s %-12s %-26s %5s %8s %9s\n"
                           "ST" "ID" "AGENT" "TASK" "TURNS" "TOKENS" "COST")
                   'face 'bold))
          (if (null records)
              (insert "\n  No tasks.  Open a plan and "
                      "M-x cmacs-brigade-start-plan.\n")
            (dolist (r (cmacs-brigade-dashboard--sort records))
              (cmacs-brigade-dashboard--insert-row r)))
          (insert (make-string 78 ?─) "\n")
          (cmacs-brigade-dashboard--insert-panels)
          (insert "\n" (cmacs-brigade-dashboard--hints) "\n")
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun cmacs-brigade-dashboard--sort (records)
  "Live tasks first, then by id, so what is happening is at the top."
  (sort (copy-sequence records)
        (lambda (a b)
          (let ((la (memq (plist-get a :state) '(running starting waiting-input)))
                (lb (memq (plist-get b :state) '(running starting waiting-input))))
            (cond ((and la (not lb)) t)
                  ((and lb (not la)) nil)
                  (t (string< (or (plist-get a :id) "")
                              (or (plist-get b :id) ""))))))))

(defun cmacs-brigade-dashboard--insert-header (records)
  (let ((live (cl-count-if (lambda (r)
                             (memq (plist-get r :state)
                                   '(running starting waiting-input blocked)))
                           records))
        (spend (/ (cl-reduce #'+ records :key
                             (lambda (r) (or (plist-get r :cost-micros) 0))
                             :initial-value 0)
                  1000000.0)))
    (insert (format " brigade    live %d    spend $%.4f    %s\n"
                    live spend
                    (if (and (boundp 'cmacs-brigade-memory-enabled)
                             cmacs-brigade-memory-enabled)
                        (cmacs-brigade-dashboard--memory-summary)
                      "memory off")))))

(defun cmacs-brigade-dashboard--memory-summary ()
  (if (fboundp 'cmacs-brigade-memory-manifest)
      (let ((m (cmacs-brigade-memory-manifest)))
        (if m (format "idx %s chunks" (plist-get m :count)) "no index"))
    "memory unavailable"))

(defun cmacs-brigade-dashboard--insert-row (r)
  (let* ((state (plist-get r :state))
         (id (or (plist-get r :id) "?"))
         (line (format "%-3s %-10s %-12s %-26s %5s %8s %9s"
                       (cmacs-brigade-dashboard--glyph state)
                       (truncate-string-to-width id 10)
                       (truncate-string-to-width
                        (or (plist-get r :agent) "—") 12)
                       (truncate-string-to-width
                        (or (plist-get r :title) id) 26)
                       (or (plist-get r :turns) 0)
                       (format "%s/%s" (or (plist-get r :in-tokens) 0)
                               (or (plist-get r :out-tokens) 0))
                       (format "$%.4f" (/ (or (plist-get r :cost-micros) 0)
                                          1000000.0)))))
    ;; The record travels with the row, so a command acts on what the
    ;; cursor is on rather than re-deriving it from the display.
    (insert (propertize line 'cmacs-brigade-record r) "\n")
    (when (plist-get r :error)
      (insert (propertize (format "     %s\n" (plist-get r :error))
                          'face 'error)))))

(defun cmacs-brigade-dashboard--insert-panels ()
  "Render registered panels, lowest :order first."
  (dolist (name (sort (cmacs-brigade-registry-list 'panel)
                      (lambda (a b)
                        (< (or (plist-get (cmacs-brigade-registry-get 'panel a)
                                          :order) 50)
                           (or (plist-get (cmacs-brigade-registry-get 'panel b)
                                          :order) 50)))))
    (let ((p (cmacs-brigade-registry-get 'panel name)))
      (condition-case err
          (let ((lines (funcall (plist-get p :render))))
            (when lines
              (insert "\n " (propertize (or (plist-get p :title)
                                            (symbol-name name))
                                        'face 'bold) "\n")
              (dolist (l lines) (insert "   " l "\n"))))
        (error
         ;; A user panel that signals must not take the dashboard with
         ;; it -- the dashboard is how they would notice.
         (insert (propertize (format "\n [panel %s failed: %s]\n" name
                                     (error-message-string err))
                             'face 'error)))))))

(defun cmacs-brigade-dashboard--hints ()
  " s start  K cancel  RET plan  o output  g refresh  M memory  q quit")

(defun cmacs-brigade-dashboard--record-at-point ()
  (get-text-property (line-beginning-position) 'cmacs-brigade-record))


;;;; Commands
;;
;; Each one calls the same function the org side calls; the dashboard
;; has no privileged path into the runtime.

(defun cmacs-brigade-dashboard-start ()
  "Start the task on this line."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (cmacs-brigade-task-transition (plist-get r :id) 'queued)
    (cmacs-brigade-start-task (plist-get r :id))
    (cmacs-brigade-dashboard-refresh)))

(defun cmacs-brigade-dashboard-cancel ()
  "Cancel the task on this line."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (cmacs-brigade-cancel-task (plist-get r :id))
    (cmacs-brigade-dashboard-refresh)))

(defun cmacs-brigade-dashboard-visit ()
  "Jump to this task's headline in its plan."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (let ((plan (plist-get r :plan)))
      (if (and plan (file-exists-p plan))
          (progn (find-file-other-window plan)
                 (goto-char (point-min))
                 (when (fboundp 'org-id-goto)
                   (ignore-errors (org-id-goto (plist-get r :id)))))
        (user-error "No plan file for %s" (plist-get r :id))))))

(defun cmacs-brigade-dashboard-refresh ()
  "Redraw now."
  (interactive)
  (cmacs-brigade-dashboard--render))

(defun cmacs-brigade-dashboard-mark-dirty (&rest _)
  "Note that the dashboard is out of date and schedule a redraw."
  (setq cmacs-brigade-dashboard--dirty t)
  (unless cmacs-brigade-dashboard--timer
    (setq cmacs-brigade-dashboard--timer
          (run-with-idle-timer
           cmacs-brigade-dashboard-refresh-idle nil
           (lambda ()
             (setq cmacs-brigade-dashboard--timer nil)
             (when cmacs-brigade-dashboard--dirty
               (setq cmacs-brigade-dashboard--dirty nil)
               ;; Only when someone can see it: redrawing a buried
               ;; buffer eight times a second is pure waste.
               (when (get-buffer-window "*brigade*" t)
                 (cmacs-brigade-dashboard--render))))))))

(defvar cmacs-brigade-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'cmacs-brigade-dashboard-start)
    (define-key map (kbd "K") #'cmacs-brigade-dashboard-cancel)
    (define-key map (kbd "RET") #'cmacs-brigade-dashboard-visit)
    (define-key map (kbd "g") #'cmacs-brigade-dashboard-refresh)
    (define-key map (kbd "M") #'cmacs-brigade-memory-find)
    (define-key map (kbd "q") #'quit-window)
    ;; Evil's intercept map takes the buffer over completely, so motion
    ;; has to be bound explicitly to survive.
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    map)
  "Keymap for `cmacs-brigade-dashboard-mode'.
Defined at top level and mutated in place, so reloading this file
updates buffers that are already open.")

(define-derived-mode cmacs-brigade-dashboard-mode special-mode "Brigade"
  "Watch the brigade's agents."
  (buffer-disable-undo)
  (setq truncate-lines t)
  (unless cmacs-brigade-dashboard--heartbeat
    (setq cmacs-brigade-dashboard--heartbeat
          (run-at-time cmacs-brigade-dashboard-heartbeat
                       cmacs-brigade-dashboard-heartbeat
                       (lambda ()
                         (when (get-buffer-window "*brigade*" t)
                           (cmacs-brigade-dashboard--render))))))
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when cmacs-brigade-dashboard--heartbeat
                (cancel-timer cmacs-brigade-dashboard--heartbeat)
                (setq cmacs-brigade-dashboard--heartbeat nil)))
            nil t))

;; Mandatory for any single-key cmacs mode: without it s/K/g are eaten
;; by Evil's own bindings under Doom.
(when (fboundp 'cmacs-evil-setup-mode-map)
  (cmacs-evil-setup-mode-map cmacs-brigade-dashboard-mode-map
                             'cmacs-brigade-dashboard-mode))

;;;###autoload
(defun cmacs-brigade-dashboard ()
  "Show the brigade dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*brigade*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-brigade-dashboard-mode)
        (cmacs-brigade-dashboard-mode)))
    (cmacs-brigade-dashboard--render)
    (pop-to-buffer buf)))

;;;###autoload
(defalias 'cmacs-brigade #'cmacs-brigade-dashboard)

(add-hook 'cmacs-brigade-run-finished-functions
          #'cmacs-brigade-dashboard-mark-dirty)

(provide 'cmacs-brigade-dashboard)

;;; cmacs-brigade-dashboard.el ends here
