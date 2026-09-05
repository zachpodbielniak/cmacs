;;; cmacs-secondbrain-filter.el --- filter the map by tag and category  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Show me only the notes about X."
;;
;; The map's other narrowing tools are structural: a ring, a department,
;; the selection's neighbourhood.  Tags and categories are the one axis
;; that cuts ACROSS the structure -- a `finance' tag lives in projects,
;; areas and resources at once -- and it is the axis the author chose,
;; note by note, so it is the most deliberate signal the notes carry.
;;
;; Three parts:
;;
;;   - An index, built once per graph: tag -> ids, category -> ids, and
;;     id -> parent so a department's hub stays lit when any of its
;;     members survive the filter.
;;   - The filter itself: a set of active tags and categories, `any' or
;;     `all', reduced to a KEEP SET of ids and handed to the scene in
;;     one call.  The scene dims what is not in the set at paint time --
;;     the same mechanism as the ring filter, deliberately, so it
;;     composes with search (a match still lights through) and never
;;     fights the search over the DIM flag.
;;   - Two ways to drive it: a palette pane beside the map, where every
;;     tag is a row with a coloured bar for its weight and a click or
;;     RET toggles it; and a quick picker on `completing-read-multiple'
;;     for when you already know the name.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'cmacs-secondbrain-panes)

(defvar cmacs-secondbrain--graph)
(defvar cmacs-secondbrain-buffer-name)

(declare-function cmacs-secondbrain-set-keep-set "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-node-count "cmacs-secondbrain-defuns")

;;;; Settings ---------------------------------------------------------

(defcustom cmacs-secondbrain-filter-mode 'any
  "How several active tags combine: `any' of them, or `all' of them.

`any' is the default because it is the additive reading of a palette --
each tag you switch on brings more of the map back -- and because with
`all' two unrelated tags almost always keep nothing, which reads as the
filter being broken rather than as an honest empty answer."
  :type '(choice (const :tag "Any active tag" any)
                 (const :tag "Every active tag" all))
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-tags-width 0.24
  "Width of the tag palette pane, as a fraction of the frame."
  :type 'number
  :group 'cmacs-secondbrain)

(defface cmacs-secondbrain-tag-on-face '((t :weight bold))
  "Face for an active tag's name in the palette."
  :group 'cmacs-secondbrain)

(defface cmacs-secondbrain-tag-off-face '((t :inherit shadow))
  "Face for an inactive tag's name in the palette."
  :group 'cmacs-secondbrain)

(defface cmacs-secondbrain-tag-count-face '((t :inherit font-lock-comment-face))
  "Face for the node count beside a tag."
  :group 'cmacs-secondbrain)

;;;; State ------------------------------------------------------------

(defvar-local cmacs-secondbrain--tag-index nil
  "Hash: tag string -> list of node ids carrying it.")

(defvar-local cmacs-secondbrain--category-index nil
  "Hash: category string -> list of node ids in it.")

(defvar-local cmacs-secondbrain--parent-of nil
  "Hash: node id -> its parent's id, for lighting the hubs above a match.")

(defvar-local cmacs-secondbrain--filter-tags nil
  "Active tags, as strings, newest first.")

(defvar-local cmacs-secondbrain--filter-categories nil
  "Active categories, as strings, newest first.")

;;;; Index ------------------------------------------------------------

(defun cmacs-secondbrain-filter-build-index (nodes)
  "Index NODES by tag, by category and by parent for the filter.

Built once per graph so a toggle in the palette is a few hash lookups,
not a walk over four thousand plists.  Tags are compared as strings
exactly as written: `Finance' and `finance' are two tags, because org
treats them as two."
  (setq cmacs-secondbrain--tag-index (make-hash-table :test 'equal)
        cmacs-secondbrain--category-index (make-hash-table :test 'equal)
        cmacs-secondbrain--parent-of (make-hash-table :test 'equal))
  (dolist (n nodes)
    (let ((id (plist-get n :id)))
      (when id
        (dolist (tg (plist-get n :tags))
          (when (and (stringp tg) (not (equal tg "")))
            (puthash tg (cons id (gethash tg cmacs-secondbrain--tag-index))
                     cmacs-secondbrain--tag-index)))
        (let ((cat (plist-get n :category)))
          (when (and (stringp cat) (not (equal cat "")))
            (puthash cat (cons id (gethash cat cmacs-secondbrain--category-index))
                     cmacs-secondbrain--category-index)))
        (when (plist-get n :parent)
          (puthash id (plist-get n :parent) cmacs-secondbrain--parent-of))))))

(defun cmacs-secondbrain-filter-tags ()
  "Every tag, as (NAME . COUNT), most used first."
  (cmacs-secondbrain--index-counts cmacs-secondbrain--tag-index))

(defun cmacs-secondbrain-filter-categories ()
  "Every category, as (NAME . COUNT), most used first."
  (cmacs-secondbrain--index-counts cmacs-secondbrain--category-index))

(defun cmacs-secondbrain--index-counts (index)
  "Return INDEX's keys as (NAME . COUNT), by count then name."
  (let (out)
    (when index
      (maphash (lambda (k v) (push (cons k (length v)) out)) index))
    (sort out (lambda (a b)
                (if (= (cdr a) (cdr b))
                    (string< (car a) (car b))
                  (> (cdr a) (cdr b)))))))

(defun cmacs-secondbrain-filter-active-p ()
  "Non-nil when any tag or category is switched on."
  (or cmacs-secondbrain--filter-tags cmacs-secondbrain--filter-categories))

;;;; The keep set -----------------------------------------------------

(defun cmacs-secondbrain--filter-combine (sets)
  "Reduce SETS (lists of ids) per `cmacs-secondbrain-filter-mode'."
  (cond
   ((null sets) nil)
   ((eq cmacs-secondbrain-filter-mode 'all)
    (let ((acc (car sets)))
      (dolist (s (cdr sets) acc)
        (setq acc (cl-intersection acc s :test #'equal)))))
   (t (delete-dups (apply #'append (mapcar #'copy-sequence sets))))))

(defun cmacs-secondbrain-filter-keep-ids ()
  "The ids the current filter keeps, or nil when no filter is active.

Tags combine per `cmacs-secondbrain-filter-mode'; categories always
combine as `any' among themselves; and when both kinds are active a
node must satisfy both, because switching on a category on top of a tag
can only mean \"and within this category\".

Every ancestor of a kept node is kept too, so the department a survivor
lives in stays lit and the filtered map still shows WHERE the matches
are -- a lone bright dot in a dim ring says less than a lit wedge does."
  (when (cmacs-secondbrain-filter-active-p)
    (let* ((by-tag (and cmacs-secondbrain--filter-tags
                        (cmacs-secondbrain--filter-combine
                         (mapcar (lambda (tg)
                                   (gethash tg cmacs-secondbrain--tag-index))
                                 cmacs-secondbrain--filter-tags))))
           (by-cat (and cmacs-secondbrain--filter-categories
                        (let ((cmacs-secondbrain-filter-mode 'any))
                          (cmacs-secondbrain--filter-combine
                           (mapcar (lambda (c)
                                     (gethash c cmacs-secondbrain--category-index))
                                   cmacs-secondbrain--filter-categories)))))
           (ids (cond ((and cmacs-secondbrain--filter-tags
                            cmacs-secondbrain--filter-categories)
                       (cl-intersection by-tag by-cat :test #'equal))
                      (cmacs-secondbrain--filter-tags by-tag)
                      (t by-cat)))
           (seen (make-hash-table :test 'equal)))
      (dolist (id ids)
        (puthash id t seen)
        ;; Up the parent chain, bounded: a cycle is refused when the
        ;; graph is built, but this must not be the thing that finds out.
        (let ((cur id) (guard 0))
          (while (and cur (< guard 64)
                      (setq cur (and cmacs-secondbrain--parent-of
                                     (gethash cur cmacs-secondbrain--parent-of))))
            (puthash cur t seen)
            (cl-incf guard))))
      (hash-table-keys seen))))

(defun cmacs-secondbrain-filter-apply (&optional buf)
  "Push the current filter into BUF's scene, and refresh the palette.

Passes a VECTOR, never a list: an active filter that matches nothing
must reach the scene as an empty set, and in Lisp the empty list is
nil, which the scene would read as \"lift the filter\"."
  (let ((buf (or buf (cmacs-secondbrain--origin) (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (fboundp 'cmacs-secondbrain-set-keep-set)
          (ignore-errors
            (cmacs-secondbrain-set-keep-set
             buf (and (cmacs-secondbrain-filter-active-p)
                      (vconcat (cmacs-secondbrain-filter-keep-ids))))))
        (force-mode-line-update)))
    ;; Whenever the palette EXISTS, not only when it is showing: a
    ;; hidden pane that comes back stale would show the wrong toggles.
    (when (get-buffer "*second brain: tags*")
      (cmacs-secondbrain-tags-render))))

(defun cmacs-secondbrain-filter-toggle-tag (tag)
  "Switch TAG on or off and apply."
  (cmacs-secondbrain--in-origin
    (setq cmacs-secondbrain--filter-tags
          (if (member tag cmacs-secondbrain--filter-tags)
              (delete tag cmacs-secondbrain--filter-tags)
            (cons tag cmacs-secondbrain--filter-tags)))
    (cmacs-secondbrain-filter-apply origin)))

(defun cmacs-secondbrain-filter-toggle-category (category)
  "Switch CATEGORY on or off and apply."
  (cmacs-secondbrain--in-origin
    (setq cmacs-secondbrain--filter-categories
          (if (member category cmacs-secondbrain--filter-categories)
              (delete category cmacs-secondbrain--filter-categories)
            (cons category cmacs-secondbrain--filter-categories)))
    (cmacs-secondbrain-filter-apply origin)))

(defun cmacs-secondbrain-filter-clear (&optional quiet)
  "Switch every tag and category off.  QUIET suppresses the message."
  (interactive)
  (cmacs-secondbrain--in-origin
    (setq cmacs-secondbrain--filter-tags nil
          cmacs-secondbrain--filter-categories nil)
    (cmacs-secondbrain-filter-apply origin))
  (unless quiet (message "Tag filter cleared")))

(defun cmacs-secondbrain-filter-toggle-mode ()
  "Flip between keeping nodes with ANY active tag and with ALL of them."
  (interactive)
  (cmacs-secondbrain--in-origin
    (setq-local cmacs-secondbrain-filter-mode
                (if (eq cmacs-secondbrain-filter-mode 'all) 'any 'all))
    (cmacs-secondbrain-filter-apply origin)
    (message "Tags: keep nodes with %s of the active tags"
             (if (eq cmacs-secondbrain-filter-mode 'all) "ALL" "ANY"))))

(defun cmacs-secondbrain-filter-summary ()
  "A short description of the active filter, for the mode line."
  (let ((parts (append (mapcar (lambda (tg) (concat "#" tg))
                               (reverse cmacs-secondbrain--filter-tags))
                       (mapcar (lambda (c) (concat "@" c))
                               (reverse cmacs-secondbrain--filter-categories)))))
    (when parts
      (concat (mapconcat #'identity parts
                         (if (eq cmacs-secondbrain-filter-mode 'all) "&" " "))))))

;;;; Quick picker -----------------------------------------------------

(defun cmacs-secondbrain-filter-pick ()
  "Choose the active tags by name, with completion.

The palette is for browsing; this is for when you already know the
name.  Categories are offered too, prefixed `@'.  An empty choice clears
the filter."
  (interactive)
  (cmacs-secondbrain--in-origin
    (let* ((tags (cmacs-secondbrain-filter-tags))
           (cats (cmacs-secondbrain-filter-categories))
           (counts (make-hash-table :test 'equal))
           (cands (append (mapcar (lambda (tc) (puthash (car tc) (cdr tc) counts)
                                    (car tc))
                                  tags)
                          (mapcar (lambda (cc)
                                    (let ((k (concat "@" (car cc))))
                                      (puthash k (cdr cc) counts) k))
                                  cats)))
           (current (append cmacs-secondbrain--filter-tags
                            (mapcar (lambda (c) (concat "@" c))
                                    cmacs-secondbrain--filter-categories)))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (c)
                    (let ((n (gethash c counts)))
                      (and n (propertize (format "  %d" n)
                                         'face 'cmacs-secondbrain-tag-count-face))))))
           (chosen (completing-read-multiple
                    (format "Keep nodes tagged (%s of): "
                            (if (eq cmacs-secondbrain-filter-mode 'all) "all" "any"))
                    cands nil t (mapconcat #'identity current ","))))
      (setq cmacs-secondbrain--filter-tags nil
            cmacs-secondbrain--filter-categories nil)
      (dolist (c chosen)
        (if (string-prefix-p "@" c)
            (push (substring c 1) cmacs-secondbrain--filter-categories)
          (push c cmacs-secondbrain--filter-tags)))
      (cmacs-secondbrain-filter-apply origin)
      (message "%s" (or (cmacs-secondbrain-filter-summary) "Tag filter cleared")))))

;;;; The palette pane -------------------------------------------------

(defvar cmacs-secondbrain-tags-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-secondbrain-tags-toggle)
    (define-key m (kbd "SPC") #'cmacs-secondbrain-tags-toggle)
    (define-key m [mouse-1] #'cmacs-secondbrain-tags-toggle-mouse)
    (define-key m "a" #'cmacs-secondbrain-filter-toggle-mode)
    (define-key m "c" #'cmacs-secondbrain-filter-clear)
    (define-key m "g" #'cmacs-secondbrain-tags-render)
    (define-key m "n" #'cmacs-secondbrain-tags-next)
    (define-key m "p" #'cmacs-secondbrain-tags-prev)
    (define-key m "j" #'cmacs-secondbrain-tags-next)
    (define-key m "k" #'cmacs-secondbrain-tags-prev)
    (define-key m "/" #'isearch-forward)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-secondbrain-tags-mode'.")

(define-derived-mode cmacs-secondbrain-tags-mode special-mode "SBTags"
  "The tag palette: every tag and category in the map, as toggles.

\\{cmacs-secondbrain-tags-mode-map}"
  (setq-local truncate-lines t
              cursor-type 'bar)
  (buffer-disable-undo))

(defun cmacs-secondbrain--tag-color (name)
  "A stable, pleasant colour for tag NAME.

Hashed onto the hue wheel at fixed saturation and lightness, so a tag
keeps its colour across sessions and every tag is legible on a dark or
light background alike.  Two tags may share a hue; that is fine -- the
colour is a handle for the eye, not an identity."
  (let* ((h (mod (abs (sxhash-equal name)) 360))
         (rgb (color-hsl-to-rgb (/ h 360.0) 0.58 0.62)))
    (apply #'color-rgb-to-hex (append rgb '(2)))))

(defun cmacs-secondbrain--tags-bar (count max color)
  "A bar of block glyphs for COUNT out of MAX, in COLOR.

Logarithmic: the counts span three orders of magnitude, and on a linear
scale every tag but the biggest is one cell wide."
  (let* ((w (if (<= max 1) 1
              (max 1 (round (* 10 (/ (log (1+ count)) (log (1+ max))))))))
         (bar (make-string w ?▇)))
    (concat (propertize bar 'face (list :foreground color))
            (propertize (make-string (- 10 w) ?\s) 'face 'default))))

(defun cmacs-secondbrain--tags-section (title rows active max kind)
  "Insert a palette section TITLE listing ROWS of (NAME . COUNT).
ACTIVE is the list of switched-on names; KIND tags each row for toggle."
  (insert (propertize (format "%s (%d)\n" title (length rows))
                      'face 'cmacs-secondbrain-heading-face))
  (if (null rows)
      (insert (propertize "  none\n" 'face 'cmacs-secondbrain-label-face))
    (dolist (row rows)
      (let* ((name (car row)) (count (cdr row))
             (on (member name active))
             (color (cmacs-secondbrain--tag-color name))
             (start (point)))
        (insert (if on
                    (propertize "● " 'face (list :foreground color))
                  (propertize "○ " 'face 'cmacs-secondbrain-tag-off-face))
                (cmacs-secondbrain--tags-bar count max color)
                " "
                (propertize name 'face (if on 'cmacs-secondbrain-tag-on-face
                                         'cmacs-secondbrain-tag-off-face))
                (propertize (format " %d" count)
                            'face 'cmacs-secondbrain-tag-count-face)
                "\n")
        (add-text-properties start (point)
                             (list 'sb-filter (cons kind name)
                                   'mouse-face 'highlight
                                   'help-echo "RET or click: toggle")))))
  (insert "\n"))

(defun cmacs-secondbrain-tags-render ()
  "Redraw the palette from the origin viewport's index and filter."
  (interactive)
  (let* ((origin (cmacs-secondbrain--origin))
         (buf (get-buffer-create "*second brain: tags*"))
         (line (with-current-buffer buf (line-number-at-pos))))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-secondbrain-tags-mode)
        (cmacs-secondbrain-tags-mode))
      (setq cmacs-secondbrain--pane-origin origin)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (not origin)
            (insert (propertize "No second-brain viewport\n"
                                'face 'cmacs-secondbrain-label-face))
          (let* ((tags (with-current-buffer origin
                         (cmacs-secondbrain-filter-tags)))
                 (cats (with-current-buffer origin
                         (cmacs-secondbrain-filter-categories)))
                 (on-tags (buffer-local-value 'cmacs-secondbrain--filter-tags origin))
                 (on-cats (buffer-local-value 'cmacs-secondbrain--filter-categories
                                              origin))
                 (mode (buffer-local-value 'cmacs-secondbrain-filter-mode origin))
                 (max (apply #'max 1 (mapcar #'cdr (append tags cats)))))
            (insert (propertize "Filter" 'face 'cmacs-secondbrain-heading-face)
                    "  keep nodes with "
                    (propertize (if (eq mode 'all) "all" "any")
                                'face 'help-key-binding)
                    " of the active tags\n"
                    (propertize "  RET/click toggle   a any/all   c clear   q close\n\n"
                                'face 'cmacs-secondbrain-label-face))
            (cmacs-secondbrain--tags-section "Tags" tags on-tags max 'tag)
            (cmacs-secondbrain--tags-section "Categories" cats on-cats max
                                             'category)))
        (goto-char (point-min))
        (forward-line (max 0 (1- line))))
      (setq header-line-format
            (when origin
              (let ((summary (buffer-local-value
                              'cmacs-secondbrain--filter-tags origin)))
                (format " %s"
                        (if (or summary
                                (buffer-local-value
                                 'cmacs-secondbrain--filter-categories origin))
                            (with-current-buffer origin
                              (format "%s  ·  %d kept"
                                      (cmacs-secondbrain-filter-summary)
                                      (length (cmacs-secondbrain-filter-keep-ids))))
                          "no filter  ·  everything shown"))))))
    buf))

;;;###autoload
(defun cmacs-secondbrain-tags ()
  "Show the tag palette beside the map."
  (interactive)
  (let ((buf (cmacs-secondbrain-tags-render)))
    (select-window
     (cmacs-secondbrain--show-pane buf 'right 1 cmacs-secondbrain-tags-width))))

(defun cmacs-secondbrain--tags-at (&optional pos)
  "The (KIND . NAME) under POS, or nil."
  (get-text-property (or pos (point)) 'sb-filter))

(defun cmacs-secondbrain-tags-toggle (&optional pos)
  "Toggle the tag or category on the line at POS (default point)."
  (interactive)
  (pcase (cmacs-secondbrain--tags-at pos)
    (`(tag . ,name) (cmacs-secondbrain-filter-toggle-tag name))
    (`(category . ,name) (cmacs-secondbrain-filter-toggle-category name))
    (_ (user-error "No tag on this line"))))

(defun cmacs-secondbrain-tags-toggle-mouse (event)
  "Toggle the tag clicked in EVENT."
  (interactive "e")
  (let ((posn (event-start event)))
    (with-selected-window (posn-window posn)
      (cmacs-secondbrain-tags-toggle (posn-point posn)))))

(defun cmacs-secondbrain-tags-next ()
  "Move to the next tag row."
  (interactive)
  (let ((p (next-single-property-change (line-end-position) 'sb-filter)))
    (when p (goto-char p) (beginning-of-line))))

(defun cmacs-secondbrain-tags-prev ()
  "Move to the previous tag row."
  (interactive)
  (let ((p (previous-single-property-change (line-beginning-position) 'sb-filter)))
    (when p (goto-char p) (beginning-of-line))))

(provide 'cmacs-secondbrain-filter)

;;; cmacs-secondbrain-filter.el ends here
