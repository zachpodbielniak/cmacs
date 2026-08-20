;;; cmacs-dbexplorer-workbench.el --- The four-window layout  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `M-x cmacs-dbexplorer': the whole tool at once.
;;
;; The layout is composed from the views rather than built into them.
;; Every buffer here is one a command already opens on its own, and the
;; workbench only decides where they go -- connections and schema in side
;; windows on the left, the editor in the main area with its results
;; underneath.  Side windows specifically, because they survive the
;; `delete-other-windows' that any ordinary command may do to the main
;; area, which is what keeps the layout from dissolving the first time
;; something calls `pop-to-buffer'.
;;
;; Taking over the frame is only acceptable if it can be given back, so
;; the window configuration is saved before anything moves and `q' in any
;; explorer buffer restores it.  The saved configuration lives in the core
;; file, not here, so that a view's `q' does not have to load the
;; workbench to know whether one is open.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-dbexplorer)
(require 'cmacs-dbexplorer-connections)
(require 'cmacs-dbexplorer-schema-ui)
(require 'cmacs-dbexplorer-grid)
(require 'cmacs-dbexplorer-sql)
(require 'cmacs-dbexplorer-edit)

(defcustom cmacs-dbexplorer-side-width 0.22
  "Fraction of the frame the connection and schema side windows take."
  :type 'number
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-grid-height 0.45
  "Fraction of the main area the result grid takes."
  :type 'number
  :group 'cmacs-dbexplorer)

(defun cmacs-dbexplorer-workbench--side (buffer slot)
  "Show BUFFER in the left side window at SLOT."
  (display-buffer-in-side-window
   buffer `((side . left) (slot . ,slot)
            (window-width . ,cmacs-dbexplorer-side-width)
            ;; Pinned horizontally only: the two stack, and pinning the
            ;; height as well would stop the schema tree growing when the
            ;; connection list is short.
            (preserve-size . (t . nil)))))

(defun cmacs-dbexplorer-workbench--main-window ()
  "Return a window that is not a side window, selecting it."
  (let ((window (or (seq-find (lambda (candidate)
                                (not (window-parameter candidate 'window-side)))
                              (window-list))
                    (selected-window))))
    (select-window window)
    window))

;;;###autoload
(defun cmacs-dbexplorer ()
  "Open the database workbench.

Connections and the schema tree on the left, an editor in the middle and
its results below.  `q' in any of them puts back the windows this
replaced."
  (interactive)
  (cmacs-dbexplorer--require)
  ;; Saved before anything moves, and only once: opening the workbench
  ;; twice must not record the workbench as the thing to go back to.
  (unless cmacs-dbexplorer--saved-window-configuration
    (setq cmacs-dbexplorer--saved-window-configuration
          (current-window-configuration)))
  (cmacs-dbexplorer-connect-auto)
  (let* ((connection (car (cmacs-dbexplorer-connections)))
         (name (and connection (cmacs-dbexplorer-connection-name connection))))
    (cmacs-dbexplorer-workbench--main-window)
    (delete-other-windows)
    (cmacs-dbexplorer-workbench--side (cmacs-dbexplorer-connections-ensure) 0)
    (when connection
      (cmacs-dbexplorer-workbench--side
       (cmacs-dbexplorer-schema-ensure connection) 1))
    (let ((main (cmacs-dbexplorer-workbench--main-window)))
      (when name
        (set-window-buffer main (cmacs-dbexplorer-sql-ensure name))
        ;; Negative size: it is the height of the NEW window, so the grid
        ;; gets its fraction rather than the editor keeping it.
        (let ((grid (split-window main
                                  (- (round (* (window-height main)
                                               cmacs-dbexplorer-grid-height)))
                                  'below)))
          (set-window-buffer grid (cmacs-dbexplorer-grid-ensure name))))
      (select-window main))
    (unless connection
      (message "cmacs-dbexplorer: nothing connected -- press RET on a \
connection to open it"))))

(defun cmacs-dbexplorer-grid-ensure (name)
  "Return the grid buffer for the connection called NAME, drawn."
  (let ((buffer (cmacs-dbexplorer-grid--buffer name)))
    (with-current-buffer buffer
      (unless cmacs-dbexplorer-grid--result (cmacs-dbexplorer-grid-refresh)))
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-open-view (name &optional connection)
  "Open the registered view called NAME on CONNECTION.

Completes over every registered view, so a view a user or another
subsystem registered is reachable the moment it registers -- which is the
point of the registry."
  (interactive
   (let ((views (cmacs-dbexplorer-views)))
     (unless views (user-error "cmacs-dbexplorer: no views are registered"))
     (list (intern
            (completing-read
             "View: "
             (mapcar (lambda (entry)
                       (or (plist-get (cdr entry) :label)
                           (symbol-name (car entry))))
                     views)
             nil nil))
           nil)))
  (cmacs-dbexplorer--require)
  (let* ((view (or (cmacs-dbexplorer-view name)
                   ;; Completion offered labels, so a label is a legal
                   ;; answer and has to be resolvable back to a name.
                   (cdr (seq-find (lambda (entry)
                                    (equal (symbol-name name)
                                           (plist-get (cdr entry) :label)))
                                  (cmacs-dbexplorer-views)))))
         (open (and view (plist-get view :open))))
    (unless open (user-error "cmacs-dbexplorer: no view called %s" name))
    (funcall open (or connection
                      (cmacs-dbexplorer-read-connection-name "Connection: " t)))))

(provide 'cmacs-dbexplorer-workbench)
;;; cmacs-dbexplorer-workbench.el ends here
