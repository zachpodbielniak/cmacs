;;; cmacs-roamgraph-panes.el --- side panes for the roam graph -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The dashboard around the viewport: a node list, an inspector, and a
;; tag filter.  The viewport shows you the shape of your notes; these
;; tell you what you are actually looking at.
;;
;;   +----------------+---------------------------+--------------+
;;   |  tags          |                           |  inspector   |
;;   +----------------+       viewport            |              |
;;   |  nodes         |                           |              |
;;   +----------------+---------------------------+--------------+
;;
;; The inspector's numbered forward links and lettered backlinks are
;; live keys: [1] moves the graph selection to that link.  Combined with
;; `o' in the viewport, that solves a forty-link hub from both
;; directions.
;;
;; Every pane keys on the org-roam id string, never on a scene index --
;; scene indices churn on every rebuild.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'cmacs-roamgraph)

(declare-function org-fold-show-entry "org-fold")
(declare-function org-show-entry "org")
(declare-function evil-define-key* "evil-core")
(declare-function cmacs-evil-intercept-mode-map "cmacs-evil")
(declare-function cmacs-roamgraph-search "cmacs-roamgraph-search")
(declare-function cmacs-roamgraph-jump "cmacs-roamgraph-search")

(defcustom cmacs-roamgraph-list-max 500
  "How many rows the node list paints at once.
The header says how many were dropped; a list of several thousand rows
is slow to repaint and nobody scrolls it."
  :type 'integer
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-preview-lines 12
  "Lines of the note's body shown in the inspector."
  :type 'integer
  :group 'cmacs-roamgraph)

(defconst cmacs-roamgraph-list-buffer "*org-roam graph: nodes*")
(defconst cmacs-roamgraph-inspector-buffer "*org-roam graph: inspector*")
(defconst cmacs-roamgraph-tags-buffer "*org-roam graph: tags*")

(defvar-local cmacs-roamgraph--pane-origin nil
  "The viewport buffer a pane belongs to.")
(defvar-local cmacs-roamgraph--inspector-id nil
  "Id currently displayed in the inspector.
Kept separate from the selection so the inspector can show a node that
is not selected.")
(defvar-local cmacs-roamgraph--inspector-timer nil)
(defvar-local cmacs-roamgraph--link-keys nil
  "Alist of KEY-STRING to node id for the inspector's live link keys.")

;;;; Faces ---------------------------------------------------------------

(defface cmacs-roamgraph-title-face
  '((t :inherit font-lock-function-name-face :height 1.15 :weight bold))
  "Face for the inspected note's title."
  :group 'cmacs-roamgraph)

(defface cmacs-roamgraph-field-face
  '((t :inherit font-lock-constant-face))
  "Face for inspector field names."
  :group 'cmacs-roamgraph)

(defface cmacs-roamgraph-link-key-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the inspector's live link keys."
  :group 'cmacs-roamgraph)

(defface cmacs-roamgraph-tag-face
  '((t :inherit font-lock-type-face))
  "Face for tags."
  :group 'cmacs-roamgraph)

;;;; Shared helpers ------------------------------------------------------

(defun cmacs-roamgraph--origin ()
  "Return the viewport buffer this pane belongs to, or nil.

Called both from a pane (where the origin is recorded) and from the
viewport itself (where it is the current buffer).  Falling back to the
canonical buffer name alone would break any viewport that is not the
one named `cmacs-roamgraph-buffer-name'."
  (let ((b (cond ((derived-mode-p 'cmacs-roamgraph-mode) (current-buffer))
                 ((buffer-live-p cmacs-roamgraph--pane-origin)
                  cmacs-roamgraph--pane-origin)
                 (t (get-buffer cmacs-roamgraph-buffer-name)))))
    (and (buffer-live-p b) b)))

(defmacro cmacs-roamgraph--in-origin (&rest body)
  "Run BODY in the viewport buffer this pane belongs to."
  (declare (indent 0) (debug t))
  `(let ((origin (cmacs-roamgraph--origin)))
     (unless origin (user-error "No roamgraph viewport"))
     (with-current-buffer origin ,@body)))

(defun cmacs-roamgraph--show-pane (buf side slot width)
  "Display BUF in a side window and return it."
  (display-buffer-in-side-window
   buf `((side . ,side) (slot . ,slot) (window-width . ,width)
         (preserve-size . (t . nil)))))

;;;; Inspector -----------------------------------------------------------

(defvar cmacs-roamgraph-inspector-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-roamgraph-inspector-visit)
    (define-key m "O" #'cmacs-roamgraph-inspector-visit-other-window)
    (define-key m "f" #'cmacs-roamgraph-inspector-fly)
    (define-key m "y" #'cmacs-roamgraph-inspector-copy-link)
    (define-key m "g" #'cmacs-roamgraph-inspector-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-roamgraph-inspector-mode'.")

(define-derived-mode cmacs-roamgraph-inspector-mode special-mode "RoamInspect"
  "Details of the selected org-roam note.

The numbered forward links and lettered backlinks are live: pressing
one moves the graph selection to it.

\\{cmacs-roamgraph-inspector-mode-map}"
  (setq-local truncate-lines nil)
  (buffer-disable-undo))

;;;; Inspector actions (extension point) ---------------------------------

(defvar cmacs-roamgraph-inspector-actions nil
  "Extra inspector actions, as (KEY LABEL FUNCTION &optional PREDICATE).
FUNCTION is called with the inspected node's id.")

(defun cmacs-roamgraph-register-inspector-action (key label fn &optional pred)
  "Add an inspector action bound to KEY, shown as LABEL, running FN.

FN receives the inspected node's id.  PRED, when given, decides whether
the action applies to a given id.  The binding is installed for Evil's
normal and motion states as well -- without that half, a registered `a'
would just be `evil-append' under Doom."
  (setq cmacs-roamgraph-inspector-actions
        (cons (list key label fn pred)
              (assoc-delete-all key cmacs-roamgraph-inspector-actions)))
  (define-key cmacs-roamgraph-inspector-mode-map (kbd key)
              (lambda () (interactive)
                (when cmacs-roamgraph--inspector-id
                  (funcall fn cmacs-roamgraph--inspector-id))))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) cmacs-roamgraph-inspector-mode-map
      (kbd key) (lambda () (interactive)
                  (when cmacs-roamgraph--inspector-id
                    (funcall fn cmacs-roamgraph--inspector-id))))))

(defun cmacs-roamgraph--insp-row (label value &optional face)
  "Insert a LABEL/VALUE row, skipping empty values."
  (when (and value (not (equal value "")))
    (insert (propertize (format "  %-9s " label) 'face 'cmacs-roamgraph-field-face)
            (if face (propertize value 'face face) value)
            "\n")))

(defun cmacs-roamgraph--preview (node)
  "Return the first lines of NODE's body, org-fontified."
  (let ((file (plist-get node :file))
        (pos (or (plist-get node :pos) 1)))
    (when (and file (file-readable-p file))
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (min pos (point-max)))
          ;; Skip the heading itself and any property drawer, so the
          ;; preview is the note's prose rather than its plumbing.
          (forward-line 1)
          (while (and (not (eobp))
                      (looking-at-p
                       "^[ \t]*\\(:[A-Za-z_]+:\\|#\\+\\|$\\)"))
            (forward-line 1))
          (let ((start (point)))
            (forward-line cmacs-roamgraph-preview-lines)
            (let ((text (buffer-substring-no-properties start (point))))
              (with-temp-buffer
                (insert text)
                (delay-mode-hooks (org-mode))
                (ignore-errors (font-lock-ensure))
                (buffer-string)))))))))

(defun cmacs-roamgraph--insp-links (ids keys heading)
  "Insert HEADING and the link list IDS, keyed by KEYS.
Returns the alist of key to id that was consumed."
  (let ((used '()))
    (when ids
      (insert "\n" (propertize (format "%s (%d)\n" heading (length ids))
                               'face 'bold))
      (cl-loop for id in ids
               for i from 0
               do (let ((key (nth i keys)))
                    (insert "  "
                            (if key
                                (propertize (format "[%s]" key)
                                            'face 'cmacs-roamgraph-link-key-face)
                              "   ")
                            " "
                            (cmacs-roamgraph--title id)
                            "\n")
                    (when key (push (cons key id) used)))))
    (nreverse used)))

(defun cmacs-roamgraph--inspector-render (id)
  "Render node ID into the inspector buffer."
  (let* ((origin (cmacs-roamgraph--origin))
         (node (and origin (with-current-buffer origin
                             (cmacs-roamgraph--node id))))
         (out (and origin (with-current-buffer origin
                            (cmacs-roamgraph--out id))))
         (in (and origin (with-current-buffer origin
                           (cmacs-roamgraph--in id))))
         (buf (get-buffer-create cmacs-roamgraph-inspector-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-roamgraph-inspector-mode)
        (cmacs-roamgraph-inspector-mode))
      (setq cmacs-roamgraph--pane-origin origin
            cmacs-roamgraph--inspector-id id
            cmacs-roamgraph--link-keys nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null node)
            (insert "  Nothing selected.\n")
          (insert (propertize (or (plist-get node :title) id)
                              'face 'cmacs-roamgraph-title-face)
                  "\n"
                  (make-string 48 ?─) "\n\n")
          (cmacs-roamgraph--insp-row "id" id)
          (let ((file (plist-get node :file)))
            (cmacs-roamgraph--insp-row
             "file" (and file
                         (format "%s%s"
                                 (file-relative-name
                                  file (expand-file-name
                                        cmacs-roamgraph-directory))
                                 (if (> (or (plist-get node :level) 0) 0)
                                     (format ":%s" (plist-get node :pos))
                                   "")))))
          (cmacs-roamgraph--insp-row
           "tags" (and (plist-get node :tags)
                       (mapconcat (lambda (tg) (concat ":" tg))
                                  (plist-get node :tags) ""))
           'cmacs-roamgraph-tag-face)
          (cmacs-roamgraph--insp-row
           "aliases" (and (plist-get node :aliases)
                          (string-join (plist-get node :aliases) ", ")))
          (cmacs-roamgraph--insp-row
           "refs" (and (plist-get node :refs)
                       (string-join (plist-get node :refs) ", ")))
          (cmacs-roamgraph--insp-row "group" (plist-get node :group))
          (cmacs-roamgraph--insp-row
           "degree" (format "%d out / %d in" (length out) (length in)))

          (setq cmacs-roamgraph--link-keys
                (append
                 (cmacs-roamgraph--insp-links
                  out (mapcar #'number-to-string (number-sequence 1 9))
                  "Forward links")
                 (cmacs-roamgraph--insp-links
                  in (mapcar #'char-to-string
                             (number-sequence ?a ?z))
                  "Backlinks")))

          (let ((preview (cmacs-roamgraph--preview node)))
            (when (and preview (not (string-blank-p preview)))
              (insert "\n" (propertize "Preview\n" 'face 'bold))
              (insert preview)))

          (insert "\n" (make-string 48 ?─) "\n"
                  (propertize
                   (concat "  [RET] visit   [O] other window   [f] fly\n"
                           "  [y] copy id link   [g] refresh   [q] close\n")
                   'face 'shadow))
          (dolist (a cmacs-roamgraph-inspector-actions)
            (insert (propertize (format "  [%s] %s\n" (nth 0 a) (nth 1 a))
                                'face 'shadow))))
        (goto-char (point-min))))
    ;; Install the live link keys for this render.
    (cmacs-roamgraph--install-link-keys buf)
    buf))

(defun cmacs-roamgraph--install-link-keys (buf)
  "Bind the inspector's numbered/lettered link keys in BUF."
  (with-current-buffer buf
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map cmacs-roamgraph-inspector-mode-map)
      (dolist (cell cmacs-roamgraph--link-keys)
        (let ((id (cdr cell)))
          (define-key map (kbd (car cell))
                      (lambda () (interactive)
                        (cmacs-roamgraph--in-origin
                          (cmacs-roamgraph--select id t 'inspector))))))
      (use-local-map map))))

(defun cmacs-roamgraph--inspector-soon ()
  "Refresh the inspector after a short idle pause.

Debounced because rendering it reads the note from disk: holding down a
navigation key must not mean reading forty files."
  (let ((id cmacs-roamgraph--selected))
    (when (timerp cmacs-roamgraph--inspector-timer)
      (cancel-timer cmacs-roamgraph--inspector-timer))
    (setq cmacs-roamgraph--inspector-timer
          (run-with-idle-timer
           0.15 nil
           (lambda ()
             (when (get-buffer cmacs-roamgraph-inspector-buffer)
               (ignore-errors (cmacs-roamgraph--inspector-render id))))))))

;;;###autoload
(defun cmacs-roamgraph-inspector ()
  "Show the inspector for the selected note."
  (interactive)
  (let ((id (cmacs-roamgraph--in-origin cmacs-roamgraph--selected)))
    (select-window
     (cmacs-roamgraph--show-pane (cmacs-roamgraph--inspector-render id)
                                 'right 0 0.32))))

(defun cmacs-roamgraph-inspector-refresh ()
  "Re-render the inspector."
  (interactive)
  (cmacs-roamgraph--inspector-render cmacs-roamgraph--inspector-id))

(defun cmacs-roamgraph-inspector-visit ()
  "Open the inspected note."
  (interactive)
  (let ((id cmacs-roamgraph--inspector-id))
    (cmacs-roamgraph--in-origin (cmacs-roamgraph--visit id))))

(defun cmacs-roamgraph-inspector-visit-other-window ()
  "Open the inspected note in another window."
  (interactive)
  (let ((id cmacs-roamgraph--inspector-id))
    (cmacs-roamgraph--in-origin (cmacs-roamgraph--visit id t))))

(defun cmacs-roamgraph-inspector-fly ()
  "Centre the viewport on the inspected note."
  (interactive)
  (let ((id cmacs-roamgraph--inspector-id))
    (cmacs-roamgraph--in-origin (cmacs-roamgraph--select id t 'inspector))))

(defun cmacs-roamgraph-inspector-copy-link ()
  "Copy an org id link to the inspected note."
  (interactive)
  (let ((id cmacs-roamgraph--inspector-id))
    (cmacs-roamgraph--in-origin
      (let ((s (format "[[id:%s][%s]]" id (cmacs-roamgraph--title id))))
        (kill-new s)
        (message "Copied %s" s)))))

;;;; Node list -----------------------------------------------------------

(defvar cmacs-roamgraph-list-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-roamgraph-list-select)
    (define-key m (kbd "TAB") #'cmacs-roamgraph-list-peek)
    (define-key m "o" #'cmacs-roamgraph-list-visit-other-window)
    (define-key m "/" #'cmacs-roamgraph-search)
    (define-key m "s" #'cmacs-roamgraph-jump)
    (define-key m "f" #'cmacs-roamgraph-filter-tag)
    (define-key m "c" #'cmacs-roamgraph-filter-clear)
    (define-key m "g" #'cmacs-roamgraph-list-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-roamgraph-list-mode'.")

(define-derived-mode cmacs-roamgraph-list-mode tabulated-list-mode "RoamNodes"
  "Tabulated list of the notes in the graph.

\\{cmacs-roamgraph-list-mode-map}"
  (setq tabulated-list-format
        [("Title" 42 t)
         ("Tags" 16 t)
         ("→" 4 (lambda (a b) (< (cmacs-roamgraph--list-num a 2)
                                 (cmacs-roamgraph--list-num b 2))))
         ("←" 4 (lambda (a b) (< (cmacs-roamgraph--list-num a 3)
                                 (cmacs-roamgraph--list-num b 3))))
         ("Group" 14 t)]
        tabulated-list-sort-key '("Title" . nil)
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun cmacs-roamgraph--list-num (entry col)
  "Numeric value of column COL in a tabulated-list ENTRY."
  (string-to-number (aref (cadr entry) col)))

(defun cmacs-roamgraph--list-entries (origin)
  "Build the tabulated-list entries from ORIGIN's graph."
  (with-current-buffer origin
    (let* ((nodes (append (plist-get cmacs-roamgraph--graph :nodes) nil))
           (rows '())
           (n 0))
      (dolist (node nodes)
        (let ((id (plist-get node :id)))
          (when (< n cmacs-roamgraph-list-max)
            (push (list id
                        (vector (or (plist-get node :title) id)
                                (mapconcat #'identity
                                           (plist-get node :tags) ",")
                                (number-to-string
                                 (length (cmacs-roamgraph-neighbors
                                          origin id 'out)))
                                (number-to-string
                                 (length (cmacs-roamgraph-neighbors
                                          origin id 'in)))
                                (or (plist-get node :group) "")))
                  rows))
          (setq n (1+ n))))
      (cons (nreverse rows) (length nodes)))))

;;;###autoload
(defun cmacs-roamgraph-nodes ()
  "Show the node list pane."
  (interactive)
  (let ((origin (cmacs-roamgraph--origin)))
    (unless origin (user-error "No roamgraph viewport"))
    (select-window
     (cmacs-roamgraph--show-pane (cmacs-roamgraph--list-render origin)
                                 'left 1 0.26))))

(defun cmacs-roamgraph--list-render (origin)
  "Populate and return the node list buffer for ORIGIN."
  (let* ((buf (get-buffer-create cmacs-roamgraph-list-buffer))
         (data (cmacs-roamgraph--list-entries origin))
         (rows (car data))
         (total (cdr data)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-roamgraph-list-mode)
        (cmacs-roamgraph-list-mode))
      (setq cmacs-roamgraph--pane-origin origin
            tabulated-list-entries rows
            header-line-format
            (if (> total (length rows))
                (format "  %d of %d notes (raise cmacs-roamgraph-list-max)"
                        (length rows) total)
              (format "  %d notes" total)))
      (tabulated-list-print t))
    buf))

(defun cmacs-roamgraph-list-refresh ()
  "Rebuild the node list."
  (interactive)
  (cmacs-roamgraph--list-render (cmacs-roamgraph--origin)))

(defun cmacs-roamgraph-list-select ()
  "Select the note at point and centre the viewport on it."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id (cmacs-roamgraph--in-origin (cmacs-roamgraph--select id t 'list)))))

(defun cmacs-roamgraph-list-peek ()
  "Select the note at point without moving the camera."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id (cmacs-roamgraph--in-origin (cmacs-roamgraph--select id nil 'list)))))

(defun cmacs-roamgraph-list-visit-other-window ()
  "Open the note at point in another window."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id (cmacs-roamgraph--in-origin (cmacs-roamgraph--visit id t)))))

(defun cmacs-roamgraph--list-goto (id)
  "Move point to ID in the node list, if that pane is showing."
  (let ((buf (get-buffer cmacs-roamgraph-list-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((win (get-buffer-window buf t))
              (found nil))
          (save-excursion
            (goto-char (point-min))
            (while (and (not found) (not (eobp)))
              (if (equal (tabulated-list-get-id) id)
                  (setq found (point))
                (forward-line 1))))
          (when found
            (if (window-live-p win)
                (with-selected-window win (goto-char found)
                                      (beginning-of-line))
              (goto-char found))))))))

;;;; Tags pane -----------------------------------------------------------

(defvar cmacs-roamgraph-tags-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-roamgraph-tags-toggle)
    ;; NOT SPC: in a pane under Evil that is the Doom leader key.
    (define-key m "x" #'cmacs-roamgraph-tags-toggle)
    (define-key m "c" #'cmacs-roamgraph-filter-clear)
    (define-key m "g" #'cmacs-roamgraph-tags-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-roamgraph-tags-mode'.")

(define-derived-mode cmacs-roamgraph-tags-mode tabulated-list-mode "RoamTags"
  "Tags in the graph, with counts.  RET or `x' filters by the tag at point.

\\{cmacs-roamgraph-tags-mode-map}"
  (setq tabulated-list-format [("" 2 nil) ("Tag" 22 t) ("N" 5 t)]
        tabulated-list-sort-key '("N" . t)
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun cmacs-roamgraph--tag-counts (origin)
  "Return an alist of tag to count over ORIGIN's graph."
  (with-current-buffer origin
    (let ((h (make-hash-table :test #'equal)))
      (mapc (lambda (n)
              (dolist (tg (plist-get n :tags))
                (puthash tg (1+ (gethash tg h 0)) h)))
            (plist-get cmacs-roamgraph--graph :nodes))
      (let (out) (maphash (lambda (k v) (push (cons k v) out)) h) out))))

;;;###autoload
(defun cmacs-roamgraph-tags ()
  "Show the tag pane."
  (interactive)
  (let ((origin (cmacs-roamgraph--origin)))
    (unless origin (user-error "No roamgraph viewport"))
    (select-window
     (cmacs-roamgraph--show-pane (cmacs-roamgraph--tags-render origin)
                                 'left 0 0.26))))

(defun cmacs-roamgraph--tags-render (origin)
  "Populate and return the tags buffer for ORIGIN."
  (let ((buf (get-buffer-create cmacs-roamgraph-tags-buffer))
        (counts (cmacs-roamgraph--tag-counts origin))
        (active (with-current-buffer origin cmacs-roamgraph--filter-tags)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-roamgraph-tags-mode)
        (cmacs-roamgraph-tags-mode))
      (setq cmacs-roamgraph--pane-origin origin
            tabulated-list-entries
            (mapcar (lambda (cell)
                      (list (car cell)
                            (vector (if (member (car cell) active) "✓" " ")
                                    (propertize (car cell)
                                                'face 'cmacs-roamgraph-tag-face)
                                    (number-to-string (cdr cell)))))
                    counts)
            header-line-format
            (if active
                (format "  filter: %s" (string-join active " + "))
              "  RET to filter"))
      (tabulated-list-print t))
    buf))

(defun cmacs-roamgraph-tags-refresh ()
  "Rebuild the tag pane."
  (interactive)
  (cmacs-roamgraph--tags-render (cmacs-roamgraph--origin)))

(defun cmacs-roamgraph-tags-toggle ()
  "Add or remove the tag at point from the active filter."
  (interactive)
  (let ((tag (tabulated-list-get-id))
        (origin (cmacs-roamgraph--origin)))
    (when tag
      (with-current-buffer origin
        (setq cmacs-roamgraph--filter-tags
              (if (member tag cmacs-roamgraph--filter-tags)
                  (delete tag cmacs-roamgraph--filter-tags)
                (cons tag cmacs-roamgraph--filter-tags)))
        (cmacs-roamgraph--apply-filter))
      (cmacs-roamgraph--tags-render origin))))

;;;; Dashboard -----------------------------------------------------------

;;;###autoload
(defun cmacs-roamgraph-dashboard ()
  "Show the viewport with the tags, node list and inspector panes."
  (interactive)
  (let ((origin (cmacs-roamgraph--origin)))
    (unless origin (user-error "No roamgraph viewport"))
    (delete-other-windows (get-buffer-window origin t))
    (cmacs-roamgraph--show-pane (cmacs-roamgraph--tags-render origin) 'left 0 0.24)
    (cmacs-roamgraph--show-pane (cmacs-roamgraph--list-render origin) 'left 1 0.24)
    (cmacs-roamgraph--show-pane
     (cmacs-roamgraph--inspector-render
      (with-current-buffer origin cmacs-roamgraph--selected))
     'right 0 0.30)
    (select-window (get-buffer-window origin t))
    (cmacs-roamgraph--fit-window-now origin)))

(defun cmacs-roamgraph-close-panes ()
  "Close every roamgraph side pane."
  (interactive)
  (dolist (name (list cmacs-roamgraph-tags-buffer
                      cmacs-roamgraph-list-buffer
                      cmacs-roamgraph-inspector-buffer))
    (let ((buf (get-buffer name)))
      (when buf
        (dolist (win (get-buffer-window-list buf nil t))
          (ignore-errors (delete-window win))))))
  (let ((origin (cmacs-roamgraph--origin)))
    (when origin (cmacs-roamgraph--fit-window-now origin))))

;;;; Evil ----------------------------------------------------------------

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-roamgraph-list-mode 'motion)
    (evil-set-initial-state 'cmacs-roamgraph-tags-mode 'motion)
    (evil-set-initial-state 'cmacs-roamgraph-inspector-mode 'normal))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-roamgraph-list-mode-map
      (kbd "RET") #'cmacs-roamgraph-list-select
      (kbd "TAB") #'cmacs-roamgraph-list-peek
      "o" #'cmacs-roamgraph-list-visit-other-window
      "/" #'cmacs-roamgraph-search       ; else evil-search-forward
      "s" #'cmacs-roamgraph-jump         ; else evil-snipe-s
      "f" #'cmacs-roamgraph-filter-tag   ; else evil-snipe-f
      "c" #'cmacs-roamgraph-filter-clear
      "g" #'cmacs-roamgraph-list-refresh
      "q" #'quit-window)
    (evil-define-key* 'motion cmacs-roamgraph-tags-mode-map
      (kbd "RET") #'cmacs-roamgraph-tags-toggle
      "x" #'cmacs-roamgraph-tags-toggle
      "c" #'cmacs-roamgraph-filter-clear
      "g" #'cmacs-roamgraph-tags-refresh
      "q" #'quit-window)
    (evil-define-key* '(normal motion) cmacs-roamgraph-inspector-mode-map
      (kbd "RET") #'cmacs-roamgraph-inspector-visit
      "O" #'cmacs-roamgraph-inspector-visit-other-window
      "f" #'cmacs-roamgraph-inspector-fly
      "y" #'cmacs-roamgraph-inspector-copy-link
      "g" #'cmacs-roamgraph-inspector-refresh
      "q" #'quit-window)))

;; Promote the auxiliary maps so evil-snipe's minor-mode bindings stop
;; shadowing s/f/t.  Intercept, not setup: these are tabulated-list and
;; special-mode derivatives, and copying their inherited keys to
;; intercept precedence would shadow the Doom leader.  The VIEWPORT map
;; is deliberately not promoted -- it lives in Emacs state, where Evil
;; binds nothing, and promoting it would break C-z.
(when (fboundp 'cmacs-evil-intercept-mode-map)
  (cmacs-evil-intercept-mode-map cmacs-roamgraph-list-mode-map
                                 'cmacs-roamgraph-list-mode)
  (cmacs-evil-intercept-mode-map cmacs-roamgraph-tags-mode-map
                                 'cmacs-roamgraph-tags-mode)
  (cmacs-evil-intercept-mode-map cmacs-roamgraph-inspector-mode-map
                                 'cmacs-roamgraph-inspector-mode))

(provide 'cmacs-roamgraph-panes)

;;; cmacs-roamgraph-panes.el ends here
