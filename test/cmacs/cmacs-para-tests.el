;;; cmacs-para-tests.el --- ERT tests for the shared PARA taxonomy  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Pure classification: no display, no C subsystem, no filesystem access.
;; `cmacs-para-classify' works on the path string, so every case here is a
;; literal path and the whole file runs anywhere.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs-para)
;; Best-effort: the delegation tests below assert that roamgraph's
;; grouping IS this module.  Without the require they would skip, which
;; is the failure mode that hid twenty suites -- a skip reads as
;; success.  `noerror' so a build without roamgraph still runs the rest.
(require 'cmacs-roamgraph-db nil 'noerror)

(defmacro cmacs-para-tests--with-roots (roots &rest body)
  "Run BODY with `cmacs-para-roots' bound to ROOTS."
  (declare (indent 1) (debug t))
  `(let ((cmacs-para-roots ,roots)) ,@body))

;;;; Roots

(ert-deftest cmacs-para-test-outside-every-root-is-nil ()
  "A path outside the trees classifies as nil rather than guessing."
  (cmacs-para-tests--with-roots '("/notes")
    (should-not (cmacs-para-classify "/elsewhere/x.org"))
    (should-not (cmacs-para-bucket "/elsewhere/x.org"))
    (should-not (cmacs-para-classify nil))))

(ert-deftest cmacs-para-test-longest-root-wins ()
  "A tree nested inside another classifies against the inner one.

Otherwise the outer root would claim the file and report the inner
tree's own top level as a category name."
  (cmacs-para-tests--with-roots '("/notes" "/notes/sub")
    (let ((c (cmacs-para-classify "/notes/sub/01_projects/x.org")))
      (should (eq (plist-get c :category) 'projects))
      (should (equal (plist-get c :rel) "01_projects/x.org")))))

;;;; Categories

(ert-deftest cmacs-para-test-every-category ()
  "Each PARA top level maps to its symbol and its directory."
  (cmacs-para-tests--with-roots '("/n")
    (pcase-dolist (`(,dir . ,sym)
                   '(("00_inbox" . inbox)
                     ("01_projects" . projects)
                     ("02_areas" . areas)
                     ("03_resources" . resources)
                     ("04_archives" . archives)))
      (let ((c (cmacs-para-classify (format "/n/%s/x.org" dir))))
        (should (eq (plist-get c :category) sym))
        (should (equal (plist-get c :dir) dir))
        (should (equal (plist-get c :bucket) dir))))))

(ert-deftest cmacs-para-test-unknown-top-level ()
  "A directory that is not a PARA bucket reports no category.

The file is still inside a root, so it classifies -- it simply has no
bucket, and picks up the fallback colour."
  (cmacs-para-tests--with-roots '("/n")
    (let ((c (cmacs-para-classify "/n/scratch/x.org")))
      (should c)
      (should-not (plist-get c :category))
      (should-not (plist-get c :bucket)))))

;;;; The dailies split

(ert-deftest cmacs-para-test-dailies-is-its-own-bucket ()
  "`02_areas/dailies' reports as \"dailies\", not as areas.

It is roughly 40% of a mature tree; folded into areas it swamps that
colour and the map stops being readable."
  (cmacs-para-tests--with-roots '("/n")
    (let ((c (cmacs-para-classify "/n/02_areas/dailies/2026-01-01.org")))
      (should (equal (plist-get c :bucket) "dailies"))
      (should (eq (plist-get c :special) 'dailies))
      ;; Still an area underneath -- only the grouping differs.
      (should (eq (plist-get c :category) 'areas)))
    ;; A non-dailies area is unaffected.
    (should (equal (cmacs-para-bucket "/n/02_areas/study/x.org") "02_areas"))))

;;;; Scope

(ert-deftest cmacs-para-test-personal-and-work-scope ()
  "The personal/work split is reported alongside the category."
  (cmacs-para-tests--with-roots '("/n")
    (should (eq (plist-get (cmacs-para-classify "/n/01_projects/personal/x.org")
                           :scope)
                'personal))
    (should (eq (plist-get (cmacs-para-classify "/n/01_projects/work/x.org")
                           :scope)
                'work))
    ;; Neither is not an error; plenty of files sit directly in a bucket.
    (should-not (plist-get (cmacs-para-classify "/n/01_projects/x.org")
                           :scope))))

(ert-deftest cmacs-para-test-archives-preserve-inner-scope ()
  "Archives mirror the original tree, so scope sits one level deeper.

An archived project is still a project's worth of context; reading the
first component after `04_archives' as the scope would report nil for
every archived file."
  (cmacs-para-tests--with-roots '("/n")
    (let ((c (cmacs-para-classify "/n/04_archives/01_projects/work/x.org")))
      (should (eq (plist-get c :category) 'archives))
      (should (eq (plist-get c :scope) 'work)))))

;;;; Index files

(ert-deftest cmacs-para-test-index-files-are-marked ()
  "`00_index.org' is flagged, at any depth."
  (cmacs-para-tests--with-roots '("/n")
    (should (eq (plist-get (cmacs-para-classify "/n/01_projects/00_index.org")
                           :special)
                'index))
    (should (eq (plist-get (cmacs-para-classify "/n/03_resources/a/b/00_index.org")
                           :special)
                'index))
    (should-not (plist-get (cmacs-para-classify "/n/01_projects/other.org")
                           :special))))

;;;; Colours

(ert-deftest cmacs-para-test-colours-are-stable-and-distinct ()
  "Every bucket has its own colour, and unknown input still renders.

The palette is fixed rather than hashed precisely so a colour means the
same thing in every session."
  (let ((seen (make-hash-table :test 'eql)))
    (dolist (bucket '("00_inbox" "01_projects" "02_areas" "dailies"
                      "03_resources" "04_archives"))
      (let ((c (cmacs-para-color bucket)))
        (should (integerp c))
        (should-not (gethash c seen))
        (puthash c t seen))))
  ;; A file outside the trees must still get a colour, not nil.
  (should (integerp (cmacs-para-color nil)))
  (should (= (cmacs-para-color "nonsense") cmacs-para-default-color)))

;;;; roamgraph delegates here

(ert-deftest cmacs-para-test-roamgraph-delegates ()
  "roamgraph's grouping is this module, so the two cannot drift."
  (skip-unless (fboundp 'cmacs-roamgraph-db--group))
  (cmacs-para-tests--with-roots '("/n")
    (let ((cmacs-roamgraph-directory "/n"))
      (should (equal (cmacs-roamgraph-db--group "/n/01_projects/x.org")
                     "01_projects"))
      (should (equal (cmacs-roamgraph-db--group "/n/02_areas/dailies/d.org")
                     "dailies"))
      (should (= (cmacs-roamgraph-db--color "01_projects")
                 (cmacs-para-color "01_projects"))))))

(ert-deftest cmacs-para-test-roamgraph-directory-outside-shared-roots ()
  "roamgraph still classifies when pointed outside `cmacs-para-roots'.

Its directory may be a scratch tree or a second graph; reporting nil
for every node there would silently drop the colouring."
  (skip-unless (fboundp 'cmacs-roamgraph-db--group))
  (cmacs-para-tests--with-roots '("/notes")
    (let ((cmacs-roamgraph-directory "/other"))
      (should (equal (cmacs-roamgraph-db--group "/other/01_projects/x.org")
                     "01_projects")))))

(provide 'cmacs-para-tests)

;;; cmacs-para-tests.el ends here
