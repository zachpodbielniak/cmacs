;;; cmacs-para.el --- The PARA taxonomy, as a shared contract  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; PARA -- Projects, Areas, Resources, Archives, plus an Inbox -- is how
;; the notes tree is organised, and more than one cmacs subsystem needs to
;; agree about it: roamgraph colours nodes by bucket, and the second-brain
;; visualiser groups its Memory ring by department.  Two independent
;; implementations of "which bucket is this file in?" would disagree at the
;; edges, so there is one, here.
;;
;; The shape it expects, which is the shape the notes repo actually has:
;;
;;   00_inbox/          unprocessed captures
;;   01_projects/       time-bounded work with an outcome
;;   02_areas/          ongoing responsibilities
;;   03_resources/      topic reference
;;   04_archives/       inactive, preserving the original path
;;
;; Most top levels carry `personal/' and `work/' beneath them, and each
;; directory has a `00_index.org'.
;;
;; Two deliberate refinements over a naive first-path-component split:
;;
;;   - `02_areas/dailies' is reported as its own bucket.  It is roughly 40%
;;     of a mature tree and would otherwise swamp the areas colour.
;;   - The scope (`personal' / `work') and the index/daily role are returned
;;     alongside the category rather than folded into it, so a caller can
;;     group by whichever it actually wants.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-para nil
  "The PARA taxonomy shared by cmacs subsystems."
  :group 'cmacs
  :prefix "cmacs-para-")

;;;; Roots ------------------------------------------------------------

(defcustom cmacs-para-roots '("~/Documents/notes")
  "Roots of the PARA-organised notes trees.

A list, because a file is classified against whichever root contains it
and there is no reason to assume one.  The longest matching root wins, so
nesting one tree inside another still classifies correctly.

This exists as its own defcustom because the two subsystems that needed a
notes root had drifted apart: `cmacs-roamgraph-directory' defaulted to
`org-roam-directory' (often \"~/org\") while `cmacs-brigade-memory-roots'
defaulted to \"~/Documents/notes\".  On a default install that made PARA
colouring silently inert -- no error, just every node the fallback
colour.  Both now consult this."
  :type '(repeat directory)
  :group 'cmacs-para)

(defconst cmacs-para-categories
  '("00_inbox" "01_projects" "02_areas" "03_resources" "04_archives")
  "The PARA top-level directories, in their canonical order.")

(defconst cmacs-para-category-symbols
  '(("00_inbox"     . inbox)
    ("01_projects"  . projects)
    ("02_areas"     . areas)
    ("03_resources" . resources)
    ("04_archives"  . archives))
  "Directory name to category symbol.")

(defconst cmacs-para-colors
  ;; A fixed palette rather than a hash of the name: the colours then mean
  ;; the same thing every session, which is the only way they become
  ;; readable at a glance.  0xRRGGBBAA.
  '(("00_inbox"     . #xE8A33DFF)
    ("01_projects"  . #x5FB3E8FF)
    ("02_areas"     . #x6FD98AFF)
    ("dailies"      . #x9C8FE0FF)
    ("03_resources" . #xE0C24BFF)
    ("04_archives"  . #x8A8F9AFF))
  "PARA bucket to node colour, as 0xRRGGBBAA.")

(defconst cmacs-para-default-color #xB0B8C8FF
  "Colour for a file outside any known PARA bucket.")

;;;; Classification ---------------------------------------------------

(defun cmacs-para-root-for (file)
  "Return the root in `cmacs-para-roots' containing FILE, or nil.

The longest match wins, so a tree nested inside another is classified
against the inner one."
  (when (stringp file)
    (let ((abs (expand-file-name file))
          (best nil) (best-len -1))
      (dolist (root cmacs-para-roots)
        (let* ((r (file-name-as-directory (expand-file-name root)))
               (len (length r)))
          (when (and (string-prefix-p r abs) (> len best-len))
            (setq best r best-len len))))
      best)))

(defun cmacs-para-relative (file)
  "Return FILE relative to its PARA root, or nil when it is outside one."
  (let ((root (cmacs-para-root-for file)))
    (when root
      (substring (expand-file-name file) (length root)))))

(defun cmacs-para-classify (file)
  "Classify FILE within the PARA trees.

Returns a plist, or nil when FILE is outside every root in
`cmacs-para-roots'.  Keys:

  :category  symbol -- inbox, projects, areas, resources or archives,
             or nil for a file directly under a root
  :dir       the category directory name, e.g. \"01_projects\"
  :scope     symbol `personal' or `work', or nil when neither
  :special   symbol `dailies' or `index', or nil
  :bucket    the grouping string a colour is keyed on -- the category
             directory, except that `02_areas/dailies' reports
             \"dailies\" so it does not swamp the areas colour
  :rel       FILE relative to its root

Note that :scope is reported even under `04_archives', which preserves
the original path beneath it -- an archived project is still a project's
worth of context."
  (let ((rel (cmacs-para-relative file)))
    (when rel
      (let* ((parts (split-string rel "/" t))
             (dir (car parts))
             (category (cdr (assoc dir cmacs-para-category-symbols)))
             ;; Archives mirror the original tree, so the interesting
             ;; scope sits one level deeper there.
             (tail (if (and (equal dir "04_archives")
                            (assoc (cadr parts) cmacs-para-category-symbols))
                       (cddr parts)
                     (cdr parts)))
             (scope (cond ((equal (car tail) "personal") 'personal)
                          ((equal (car tail) "work") 'work)))
             (special (cond ((and (equal dir "02_areas")
                                  (equal (cadr parts) "dailies"))
                             'dailies)
                            ((equal (file-name-nondirectory rel) "00_index.org")
                             'index)))
             (bucket (cond ((eq special 'dailies) "dailies")
                           (category dir))))
        (list :category category
              :dir (and category dir)
              :scope scope
              :special special
              :bucket bucket
              :rel rel)))))

(defun cmacs-para-bucket (file)
  "Return the PARA grouping bucket for FILE, or nil.

This is the string a colour is keyed on: a category directory, or
\"dailies\" for `02_areas/dailies'."
  (plist-get (cmacs-para-classify file) :bucket))

(defun cmacs-para-color (bucket)
  "Return the 0xRRGGBBAA colour for BUCKET.
Falls back to `cmacs-para-default-color' for anything unrecognised, so a
file outside the trees still renders."
  (or (cdr (assoc bucket cmacs-para-colors))
      cmacs-para-default-color))

(defun cmacs-para-category-label (category)
  "Return a human-readable label for CATEGORY, a symbol from `:category'."
  (pcase category
    ('inbox     "Inbox")
    ('projects  "Projects")
    ('areas     "Areas")
    ('resources "Resources")
    ('archives  "Archives")
    (_          "Other")))

(provide 'cmacs-para)

;;; cmacs-para.el ends here
