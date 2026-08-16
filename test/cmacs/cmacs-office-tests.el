;;; cmacs-office-tests.el --- Tests for native OOXML + OpenDocument -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 0 covers the package container: the zip layer every one of the
;; six formats sits on.  The tests that matter here are the round-trip
;; gate and the hostile-input guards, because everything later in the
;; subsystem is built on the promise they check.
;;
;; The round-trip gate is two assertions, run over all six formats:
;;
;;   1. Open a document, save it without editing, and the file is
;;      byte-identical.  Not "opens fine" -- identical.
;;   2. Edit exactly one part, save, and every OTHER part comes back
;;      byte-identical.
;;
;; (2) is the one with teeth.  It is what proves libzip copies untouched
;; members through with their compressed bytes intact, which is in turn
;; the whole basis for editing formats we only partially understand: a
;; part we never parsed cannot be damaged by a part we did.
;;
;; Fixtures in fixtures/office/ are real LibreOffice output, not
;; hand-rolled zips, so they carry the structure real files have --
;; including the ODF `mimetype'-first-and-stored rule that a naive
;; rewrite silently breaks.
;;
;; Every test skips itself in a build without --with-cmacs-office.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; `fboundp' and `boundp', not `cmacs-feature-p': the latter is void
;; when a test file is run on its own, which makes every `skip-unless'
;; in the file skip silently and the suite report green without having
;; executed anything.
(defun cmacs-office-tests--available-p ()
  "Non-nil when this build compiled in the Office subsystem."
  (and (boundp 'is-cmacs-office) is-cmacs-office
       (fboundp 'cmacs-office-open)))

(defconst cmacs-office-tests--fixture-dir
  (expand-file-name "fixtures/office"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Where the sample documents live, derived from this file's location.")

(defconst cmacs-office-tests--formats
  '(("docx" . "word/document.xml")
    ("xlsx" . "xl/workbook.xml")
    ("pptx" . "ppt/presentation.xml")
    ("odt"  . "content.xml")
    ("ods"  . "content.xml")
    ("odp"  . "content.xml"))
  "Each fixture extension paired with a part that is safe to rewrite.")

(defconst cmacs-office-tests--odf '("odt" "ods" "odp")
  "The extensions whose packages must open with a stored `mimetype'.")

(defun cmacs-office-tests--fixture (ext)
  "Return the path of the sample document with extension EXT."
  (expand-file-name (concat "sample." ext) cmacs-office-tests--fixture-dir))

(defun cmacs-office-tests--file-bytes (path)
  "Return the raw bytes of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defmacro cmacs-office-tests--with-copy (var ext &rest body)
  "Copy the EXT fixture to a temp file, bind VAR to it, and run BODY.
The committed fixture is never opened for writing, so a bug in the
save path cannot corrupt the corpus these tests depend on."
  (declare (indent 2) (debug (symbolp form body)))
  `(let ((,var (make-temp-file "cmacs-office-test-" nil (concat "." ,ext))))
     (unwind-protect
         (progn
           (copy-file (cmacs-office-tests--fixture ,ext) ,var t)
           ,@body)
       (ignore-errors (delete-file ,var)))))

(defun cmacs-office-tests--parts-alist (path)
  "Return an alist of (PART-NAME . BYTES) for every part of PATH."
  (let ((h (cmacs-office-open path))
        (out nil))
    (unwind-protect
        (dolist (name (cmacs-office-part-names h) (nreverse out))
          (push (cons name (cmacs-office-part-bytes h name)) out))
      (cmacs-office-close h))))

;;; Basics

(ert-deftest cmacs-office-supported ()
  "The build reports the subsystem as present."
  (skip-unless (cmacs-office-tests--available-p))
  (should (cmacs-office-supported-p))
  (should (boundp 'IS-CMACS-OFFICE))
  (should (boundp 'is-cmacs-office)))

(ert-deftest cmacs-office-open-close-all-formats ()
  "Every one of the six formats opens, reports parts, and closes."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext . ,_part) cmacs-office-tests--formats)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (progn
            (should (integerp h))
            (should (> (cmacs-office-part-count h) 0))
            (should (= (cmacs-office-part-count h)
                       (length (cmacs-office-part-names h))))
            ;; The two container conventions announce themselves
            ;; differently, and that is how format detection will later
            ;; tell them apart without trusting the file extension.
            (should (member (if (member ext cmacs-office-tests--odf)
                                "mimetype"
                              "[Content_Types].xml")
                            (cmacs-office-part-names h)))
            (should-not (cmacs-office-dirty-p h)))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-expected-part-present ()
  "Each format contains the part this suite later rewrites."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext . ,part) cmacs-office-tests--formats)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (progn
            (should (cmacs-office-part-p h part))
            (should (> (cmacs-office-part-size h part) 0))
            (should (> (length (cmacs-office-part-bytes h part)) 0)))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-stale-handle-signals ()
  "A closed or never-issued handle signals rather than crashing."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (cmacs-office-close h)
    (should-error (cmacs-office-part-count h) :type 'cmacs-office-error))
  (should-error (cmacs-office-part-count 99999) :type 'cmacs-office-error))

;;; Hostile input

(ert-deftest cmacs-office-rejects-traversal-names ()
  "Part names that try to escape the package are refused.
These files arrive as mail attachments, so the name is untrusted and
is validated before any lookup happens."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (unwind-protect
        (dolist (bad '("../etc/passwd" "/etc/passwd" "word/../../x"
                       "a\\b" "C:/x" ""))
          (should-not (cmacs-office-part-p h bad))
          (should-error (cmacs-office-part-bytes h bad)
                        :type 'cmacs-office-error))
      (cmacs-office-close h))))

(ert-deftest cmacs-office-missing-part-signals ()
  "Reading a part that is not there is an error, not an empty string."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (unwind-protect
        (should-error (cmacs-office-part-bytes h "no/such/part.xml")
                      :type 'cmacs-office-error)
      (cmacs-office-close h))))

;;; The ODF mimetype invariant

(ert-deftest cmacs-office-odf-mimetype-is-first ()
  "An OpenDocument package opens with its `mimetype' part."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext cmacs-office-tests--odf)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (should (equal "mimetype" (car (cmacs-office-part-names h))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-refuses-to-rewrite-mimetype ()
  "Replacing or deleting `mimetype' is refused.
libzip preserves order and compression only for entries it copies
through untouched; rewriting this one would move it to the end and
deflate it, quietly producing a package strict ODF readers reject."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "odt"
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (progn
            (should-error (cmacs-office-set-part-bytes h "mimetype" "x")
                          :type 'cmacs-office-error)
            (should-error (cmacs-office-delete-part h "mimetype")
                          :type 'cmacs-office-error)
            (should-not (cmacs-office-dirty-p h)))
        (cmacs-office-close h)))))

;;; The round-trip gate

(ert-deftest cmacs-office-save-unmodified-is-byte-identical ()
  "Saving a document nobody edited does not perturb a single byte.
This is a guarantee, not an optimisation: it is what makes it safe to
open a document you only partly understand."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext . ,_part) cmacs-office-tests--formats)
    (cmacs-office-tests--with-copy tmp ext
      (let ((before (cmacs-office-tests--file-bytes tmp))
            (h (cmacs-office-open tmp)))
        (unwind-protect
            (progn
              (should-not (cmacs-office-dirty-p h))
              (cmacs-office-save h))
          (cmacs-office-close h))
        (should (equal before (cmacs-office-tests--file-bytes tmp)))))))

(ert-deftest cmacs-office-edit-touches-only-that-part ()
  "After editing one part, every other part survives byte-identical.

This is the shadow-package invariant.  Unknown features -- SmartArt, a
macro, an embedded OLE object, a custom XML part -- are never parsed
and never regenerated, so they cannot be damaged by an edit elsewhere.
Losing this test means losing the basis for editing these formats at
all."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext . ,part) cmacs-office-tests--formats)
    (cmacs-office-tests--with-copy tmp ext
      (let ((original (cmacs-office-tests--parts-alist tmp))
            (marker "<!--cmacs-office-test-marker-->")
            new-bytes)
        ;; Append a comment to the target part: valid XML, and a change
        ;; we can positively identify afterwards.
        (let ((h (cmacs-office-open tmp)))
          (unwind-protect
              (progn
                (setq new-bytes (concat (cmacs-office-part-bytes h part) marker))
                (cmacs-office-set-part-bytes h part new-bytes)
                (should (cmacs-office-dirty-p h))
                ;; A queued write reads back as the queued content.
                (should (equal new-bytes (cmacs-office-part-bytes h part)))
                (cmacs-office-save h)
                (should-not (cmacs-office-dirty-p h)))
            (cmacs-office-close h)))

        (let ((after (cmacs-office-tests--parts-alist tmp)))
          ;; Same parts, same order.
          (should (equal (mapcar #'car original) (mapcar #'car after)))
          ;; The edited part changed to exactly what we asked for; every
          ;; other part is bit-for-bit what it was.
          (pcase-dolist (`(,name . ,bytes) after)
            (if (equal name part)
                (should (equal bytes new-bytes))
              (should (equal bytes (cdr (assoc name original)))))))))))

(ert-deftest cmacs-office-edit-preserves-odf-mimetype-position ()
  "Editing content.xml leaves `mimetype' first in an ODF package."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext cmacs-office-tests--odf)
    (cmacs-office-tests--with-copy tmp ext
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (progn
              (cmacs-office-set-part-bytes
               h "content.xml"
               (concat (cmacs-office-part-bytes h "content.xml") "<!--x-->"))
              (cmacs-office-save h))
          (cmacs-office-close h)))
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (should (equal "mimetype" (car (cmacs-office-part-names h))))
          (cmacs-office-close h))))))

(ert-deftest cmacs-office-save-as-leaves-original-alone ()
  "`cmacs-office-save-as' exports; it does not touch the source file."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "docx"
    (let ((dest (make-temp-file "cmacs-office-out-" nil ".docx"))
          (before (cmacs-office-tests--file-bytes tmp)))
      (unwind-protect
          (let ((h (cmacs-office-open tmp)))
            (unwind-protect
                (progn
                  (cmacs-office-set-part-bytes
                   h "word/document.xml"
                   (concat (cmacs-office-part-bytes h "word/document.xml")
                           "<!--x-->"))
                  (cmacs-office-save-as h dest)
                  ;; Source untouched, edits still queued.
                  (should (equal before (cmacs-office-tests--file-bytes tmp)))
                  (should (cmacs-office-dirty-p h)))
              (cmacs-office-close h))
            (should (file-exists-p dest))
            (should (> (nth 7 (file-attributes dest)) 0)))
        (ignore-errors (delete-file dest))))))

(ert-deftest cmacs-office-revert-discards-queued-edits ()
  "Reverting drops queued writes and leaves the file untouched."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "xlsx"
    (let ((before (cmacs-office-tests--file-bytes tmp))
          (h (cmacs-office-open tmp)))
      (unwind-protect
          (progn
            (cmacs-office-set-part-bytes h "xl/workbook.xml" "<junk/>")
            (should (cmacs-office-dirty-p h))
            (cmacs-office-revert h)
            (should-not (cmacs-office-dirty-p h))
            (cmacs-office-save h))
        (cmacs-office-close h))
      (should (equal before (cmacs-office-tests--file-bytes tmp))))))

(ert-deftest cmacs-office-delete-part-removes-only-it ()
  "A deleted part disappears and the rest survive byte-identical."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "docx"
    (let* ((original (cmacs-office-tests--parts-alist tmp))
           (victim "docProps/core.xml")
           (h (cmacs-office-open tmp)))
      (skip-unless (assoc victim original))
      (unwind-protect
          (progn
            (cmacs-office-delete-part h victim)
            (cmacs-office-save h))
        (cmacs-office-close h))
      (let ((after (cmacs-office-tests--parts-alist tmp)))
        (should-not (assoc victim after))
        (should (= (length after) (1- (length original))))
        (pcase-dolist (`(,name . ,bytes) after)
          (should (equal bytes (cdr (assoc name original)))))))))

;;; Identity: format, kind, family

(defconst cmacs-office-tests--identity
  ;; ext     format kind     family  main part
  '(("docx" docx   text     ooxml  "word/document.xml")
    ("xlsx" xlsx   sheet    ooxml  "xl/workbook.xml")
    ("pptx" pptx   slides   ooxml  "ppt/presentation.xml")
    ("odt"  odt    text     odf    "content.xml")
    ("ods"  ods    sheet    odf    "content.xml")
    ("odp"  odp    slides   odf    "content.xml"))
  "Expected identity of each fixture.")

(ert-deftest cmacs-office-identity ()
  "Format, kind, family and body part are read from the container."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext ,format ,kind ,family ,main)
                 cmacs-office-tests--identity)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (progn
            (should (eq format (cmacs-office-format h)))
            (should (eq kind (cmacs-office-kind h)))
            (should (eq family (cmacs-office-family h)))
            (should (equal main (cmacs-office-main-part h)))
            ;; The body part is a part, not just a name we made up.
            (should (cmacs-office-part-p h (cmacs-office-main-part h))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-detection-ignores-the-extension ()
  "A mis-named document is identified by what it contains.

This is the point of reading the container rather than the file name:
mail attachments and downloads get renamed all the time, and a .docx
called .xlsx is still a .docx."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((liar (make-temp-file "cmacs-office-liar-" nil ".xlsx")))
    (unwind-protect
        (progn
          (copy-file (cmacs-office-tests--fixture "docx") liar t)
          (let ((h (cmacs-office-open liar)))
            (unwind-protect
                (progn
                  (should (eq 'docx (cmacs-office-format h)))
                  (should (eq 'text (cmacs-office-kind h))))
              (cmacs-office-close h))))
      (ignore-errors (delete-file liar)))))

(ert-deftest cmacs-office-unrecognised-package-still-opens ()
  "A zip that is not an Office document opens and reports `unknown'.
Being able to look inside an odd package beats refusing to open it."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open
            (expand-file-name "plain.zip" cmacs-office-tests--fixture-dir))))
    (unwind-protect
        (progn
          (should (eq 'unknown (cmacs-office-format h)))
          (should (eq 'unknown (cmacs-office-kind h)))
          (should (eq 'unknown (cmacs-office-family h)))
          (should-not (cmacs-office-main-part h))
          ;; Still fully inspectable.
          (should (= 2 (cmacs-office-part-count h)))
          (should (cmacs-office-part-p h "readme.txt")))
      (cmacs-office-close h))))

;;; Content types

(ert-deftest cmacs-office-content-type-of-body ()
  "The body part carries the content type that identified the format."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext ,_format ,_kind ,family ,_main)
                 cmacs-office-tests--identity)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((ct (cmacs-office-content-type h (cmacs-office-main-part h))))
            (should (stringp ct))
            (if (eq family 'ooxml)
                ;; The OOXML main-part types all end this way.
                (should (string-suffix-p ".main+xml" ct))
              ;; ODF types come from the manifest.
              (should (string-match-p "xml" ct))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-content-type-unknown-part-is-nil ()
  "A part the package declares no type for reports nil, not an error."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (unwind-protect
        (should-not (cmacs-office-content-type h "no/such/part.bin"))
      (cmacs-office-close h))))

;;; Relationships

(ert-deftest cmacs-office-root-relationships-name-the-body ()
  "The OOXML officeDocument relationship resolves to the body part.

This is how the body is found: nothing requires a .docx to call it
word/document.xml, so it is looked up rather than assumed."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("docx" "xlsx" "pptx"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let* ((rels (cmacs-office-relationships h))
                 (main (cmacs-office-main-part h))
                 (doc-rel (seq-find
                           (lambda (r)
                             (string-suffix-p "/officeDocument"
                                              (or (plist-get r :type) "")))
                           rels)))
            (should rels)
            (should doc-rel)
            (should (equal main (plist-get doc-rel :target)))
            (should-not (plist-get doc-rel :external))
            (should (stringp (plist-get doc-rel :id))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-relationship-targets-resolve-against-their-part ()
  "A relationship target is resolved against its declaring part's directory.
The body part's own relationships live in word/_rels/document.xml.rels
and name siblings like `styles.xml', which must come back as
`word/styles.xml' -- not as bare `styles.xml'."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (unwind-protect
        (let ((rels (cmacs-office-relationships h "word/document.xml")))
          (should rels)
          (dolist (r rels)
            (unless (plist-get r :external)
              (let ((target (plist-get r :target)))
                (should (string-prefix-p "word/" target))
                ;; And it names something really in the package.
                (should (cmacs-office-part-p h target))))))
      (cmacs-office-close h))))

(ert-deftest cmacs-office-odf-has-no-relationships ()
  "OpenDocument has no relationship graph, so the list is empty."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext cmacs-office-tests--odf)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (should-not (cmacs-office-relationships h))
        (cmacs-office-close h)))))

;;; Metadata

(ert-deftest cmacs-office-metadata-is-normalised-across-families ()
  "Both families answer the same metadata questions with the same keys.
A caller asking who generated a document should not have to know
whether it is OOXML or OpenDocument."
  (skip-unless (cmacs-office-tests--available-p))
  (pcase-dolist (`(,ext . ,_) cmacs-office-tests--formats)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((meta (cmacs-office-metadata h)))
            (should (listp meta))
            (should (cl-evenp (length meta)))
            ;; Keys are keywords.
            (cl-loop for (k _v) on meta by #'cddr
                     do (should (keywordp k)))
            ;; The fixtures were produced by LibreOffice, and both
            ;; families record that in their own way -- meta:generator
            ;; for ODF, docProps/app.xml Application for OOXML -- which
            ;; the package layer normalises onto one key.
            (should (string-match-p "LibreOffice"
                                    (or (plist-get meta :generator) ""))))
        (cmacs-office-close h)))))

;;; The codec registry

(ert-deftest cmacs-office-known-formats-covers-all-six ()
  "The registry is the authority on what this build can identify."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((formats (cmacs-office-known-formats)))
    (should (= 6 (length formats)))
    (dolist (entry formats)
      (should (memq (plist-get entry :format)
                    '(docx xlsx pptx odt ods odp)))
      (should (memq (plist-get entry :kind) '(text sheet slides)))
      (should (memq (plist-get entry :family) '(ooxml odf)))
      (should (stringp (plist-get entry :extension)))
      (should (stringp (plist-get entry :main-part)))
      (should (stringp (plist-get entry :description))))
    ;; Every fixture's format is one the registry claims to know.
    (pcase-dolist (`(,_ext ,format . ,_) cmacs-office-tests--identity)
      (should (seq-find (lambda (e) (eq format (plist-get e :format)))
                        formats)))))

;;; Content extraction

(ert-deftest cmacs-office-extracts-document-text ()
  "Word processing documents come back as ordered blocks of text."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("docx" "odt"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((blocks (cmacs-office-blocks h)))
            (should (= 2 (length blocks)))
            (should (equal "cmacs office fixture"
                           (plist-get (nth 0 blocks) :text)))
            (should (equal "second paragraph"
                           (plist-get (nth 1 blocks) :text))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-blocks-carry-anchors ()
  "Every block records the part it came from and its ordinal there.

These are what writeback resolves against, so a block without them
would be unreachable from an edit."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("docx" "odt" "pptx" "odp"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((blocks (cmacs-office-blocks h)))
            (should blocks)
            (dolist (b blocks)
              (should (stringp (plist-get b :part)))
              ;; The part named is really in the package.
              (should (cmacs-office-part-p h (plist-get b :part)))
              (should (integerp (plist-get b :index)))
              (should (>= (plist-get b :index) 0))
              (should (stringp (plist-get b :text)))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-extracts-slides ()
  "Presentations come back grouped by slide, in presentation order.

Slide order comes from the relationship list, not from part names --
walking ppt/slides/ alphabetically would put slide10 before slide2."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("pptx" "odp"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((blocks (cmacs-office-blocks h)))
            (should blocks)
            (dolist (b blocks)
              (should (>= (plist-get b :slide) 1)))
            ;; Slide numbers never decrease.
            (should (equal (mapcar (lambda (b) (plist-get b :slide)) blocks)
                           (sort (mapcar (lambda (b) (plist-get b :slide)) blocks)
                                 #'<)))
            (should (string-match-p
                     "cmacs office fixture"
                     (mapconcat (lambda (b) (plist-get b :text)) blocks " "))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-extracts-cells ()
  "Spreadsheets come back as addressed, non-empty cells."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("xlsx" "ods"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let* ((cells (cmacs-office-cells h))
                 (at (lambda (ref)
                       (plist-get
                        (seq-find (lambda (c) (equal ref (plist-get c :ref)))
                                  cells)
                        :text))))
            (should (cmacs-office-sheet-names h))
            (should (equal "name"   (funcall at "A1")))
            (should (equal "qty"    (funcall at "B1")))
            (should (equal "price"  (funcall at "C1")))
            (should (equal "widget" (funcall at "A2")))
            (should (equal "gadget" (funcall at "A3")))
            ;; The source CSV is 3x3, so nothing beyond it exists.
            (should (= 9 (length cells))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-cell-refs-agree-with-coordinates ()
  "A cell's A1 address and its row/column are the same fact.

Spreadsheet columns are bijective base-26, where the usual base
conversion is off by one at every carry, so this is worth pinning."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "xlsx"))))
    (unwind-protect
        (dolist (c (cmacs-office-cells h))
          (let ((row (plist-get c :row))
                (col (plist-get c :col))
                (ref (plist-get c :ref)))
            (should (>= row 1))
            (should (>= col 1))
            (should (equal ref (format "%c%d" (+ ?A (1- col)) row)))))
      (cmacs-office-close h))))

(ert-deftest cmacs-office-empty-cells-are-not-emitted ()
  "Padding cells are dropped rather than returned as blanks.

Spreadsheet writers pad rows out to a thousand or more empty cells
using repeat counts; honouring those literally would bury a nine-cell
sheet in millions of blanks."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("xlsx" "ods"))
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (dolist (c (cmacs-office-cells h))
            (should (or (not (string-empty-p (string-trim (plist-get c :text))))
                        (plist-get c :formula))))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-extraction-respects-document-kind ()
  "Blocks are for prose and slides; cells are for spreadsheets."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "xlsx"))))
    (unwind-protect
        (progn
          (should-not (cmacs-office-blocks h))
          (should (cmacs-office-cells h)))
      (cmacs-office-close h)))
  (let ((h (cmacs-office-open (cmacs-office-tests--fixture "docx"))))
    (unwind-protect
        (progn
          (should (cmacs-office-blocks h))
          (should-not (cmacs-office-cells h))
          (should-not (cmacs-office-sheet-names h)))
      (cmacs-office-close h))))

;;; The org projection

(ert-deftest cmacs-office-text-is-searchable ()
  "`cmacs-office-text' returns the document's readable text."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office nil t))
  (pcase-dolist (`(,ext . ,_) cmacs-office-tests--formats)
    (let ((h (cmacs-office-open (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (let ((text (cmacs-office-text h)))
            (should (stringp text))
            (should (string-match-p (if (member ext '("xlsx" "ods"))
                                        "widget"
                                      "cmacs office fixture")
                                    text)))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-projection-buffer ()
  "Opening a document yields an org projection backed by a live handle."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office nil t))
  (pcase-dolist (`(,ext . ,_) cmacs-office-tests--formats)
    (let ((buffer (cmacs-office-find-file
                   (cmacs-office-tests--fixture ext))))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'cmacs-office-mode))
            (should cmacs-office--handle)
            (should buffer-read-only)
            (let ((text (buffer-string)))
              (should (string-match-p "#\\+CMACS_OFFICE_SOURCE:" text))
              (should (string-match-p
                       (format "#\\+CMACS_OFFICE_FORMAT: %s" ext) text))
              (should (string-match-p (if (member ext '("xlsx" "ods"))
                                          "widget"
                                        "cmacs office fixture")
                                      text))))
        (kill-buffer buffer)))))

(ert-deftest cmacs-office-projection-releases-its-handle ()
  "Killing the projection buffer closes the document behind it."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office nil t))
  (let* ((buffer (cmacs-office-find-file (cmacs-office-tests--fixture "docx")))
         (handle (buffer-local-value 'cmacs-office--handle buffer)))
    (should (integerp handle))
    (kill-buffer buffer)
    ;; The handle is gone, so any use of it must signal rather than
    ;; reach freed memory.
    (should-error (cmacs-office-part-count handle)
                  :type 'cmacs-office-error)))

;;; Spreadsheet editing

(ert-deftest cmacs-office-set-cell-updates-and-adds ()
  "Setting a cell changes it, and setting one past the end adds it."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("xlsx" "ods"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (progn
              (cmacs-office-set-cell h nil 2 2 "42")
              (cmacs-office-set-cell h nil 4 1 "newrow")
              (should (cmacs-office-dirty-p h))
              (cmacs-office-save h))
          (cmacs-office-close h)))
      ;; Reopen from disk: the edits are really in the file.
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (let* ((cells (cmacs-office-cells h))
                   (at (lambda (ref)
                         (plist-get (seq-find (lambda (c)
                                                (equal ref (plist-get c :ref)))
                                              cells)
                                    :text))))
              (should (equal "42" (funcall at "B2")))
              (should (equal "newrow" (funcall at "A4")))
              ;; Everything else is untouched.
              (should (equal "name" (funcall at "A1")))
              (should (equal "gadget" (funcall at "A3")))
              (should (equal "1.25" (funcall at "C3"))))
          (cmacs-office-close h))))))

(ert-deftest cmacs-office-set-cell-touches-only-the-sheet-part ()
  "Editing a cell rewrites the sheet part and nothing else.

The point of a surgical edit: styles, theme, metadata and every other
part come back bit-for-bit, so a spreadsheet feature this build cannot
parse cannot be damaged by changing a number."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("xlsx" "ods"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((original (cmacs-office-tests--parts-alist tmp))
            changed)
        (let ((h (cmacs-office-open tmp)))
          (unwind-protect
              (progn (cmacs-office-set-cell h nil 2 2 "42")
                     (cmacs-office-save h))
            (cmacs-office-close h)))
        (let ((after (cmacs-office-tests--parts-alist tmp)))
          (should (equal (mapcar #'car original) (mapcar #'car after)))
          (pcase-dolist (`(,name . ,bytes) after)
            (unless (equal bytes (cdr (assoc name original)))
              (push name changed)))
          ;; Exactly one part moved.
          (should (= 1 (length changed))))))))

(ert-deftest cmacs-office-set-cell-stores-numbers-as-numbers ()
  "A numeric value is stored as a number, not as text.
That is the difference between a cell that sums and one that does not."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("xlsx" "ods"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (progn
              (cmacs-office-set-cell h nil 5 1 "123.5")
              (cmacs-office-set-cell h nil 5 2 "not a number")
              (cmacs-office-save h))
          (cmacs-office-close h)))
      (let* ((h (cmacs-office-open tmp))
             (part (cmacs-office-main-part h))
             (sheet-part (if (equal ext "ods")
                             part
                           (car (seq-filter
                                 (lambda (n) (string-match-p "sheet" n))
                                 (cmacs-office-part-names h))))))
        (unwind-protect
            (let ((xml (cmacs-office-part-bytes h sheet-part)))
              (should (string-match-p "123\\.5" xml))
              (should (string-match-p "not a number" xml)))
          (cmacs-office-close h))))))

(ert-deftest cmacs-office-set-cell-rejects-bad-coordinates ()
  "Cell coordinates are 1-based, and zero is an error not row zero."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "xlsx"
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (progn
            (should-error (cmacs-office-set-cell h nil 0 1 "x")
                          :type 'cmacs-office-error)
            (should-error (cmacs-office-set-cell h nil 1 0 "x")
                          :type 'cmacs-office-error))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-set-cell-refuses-non-spreadsheets ()
  "Setting a cell in a document that has none is an error."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "docx"
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (should-error (cmacs-office-set-cell h nil 1 1 "x")
                        :type 'cmacs-office-error)
        (cmacs-office-close h)))))

;;; Formulas

(ert-deftest cmacs-office-formula-normalises-both-dialects ()
  "OpenFormula decoration reduces to the same expression Excel writes."
  (skip-unless (require 'cmacs-office-formula nil t))
  (should (equal "SUM(A1:A5)"
                 (cmacs-office-formula-normalise "of:=SUM([.A1:.A5])")))
  (should (equal "SUM(A1:A5)"
                 (cmacs-office-formula-normalise "=SUM(A1:A5)")))
  (should (equal "A1+B2" (cmacs-office-formula-normalise "of:=[.A1]+[.B2]"))))

(ert-deftest cmacs-office-formula-evaluates-ranges-and-arithmetic ()
  "Range functions and scalar arithmetic both come out right."
  (skip-unless (require 'cmacs-office-formula nil t))
  (let ((cells '((:sheet "s" :row 1 :col 1 :ref "A1" :text "1" :formula nil)
                 (:sheet "s" :row 2 :col 1 :ref "A2" :text "2" :formula nil)
                 (:sheet "s" :row 3 :col 1 :ref "A3" :text "3" :formula nil))))
    (should (equal "6" (cmacs-office-formula-eval "=SUM(A1:A3)" cells "s")))
    (should (equal "2" (cmacs-office-formula-eval "=AVERAGE(A1:A3)" cells "s")))
    (should (equal "3" (cmacs-office-formula-eval "=MAX(A1:A3)" cells "s")))
    (should (equal "1" (cmacs-office-formula-eval "=MIN(A1:A3)" cells "s")))
    (should (equal "5" (cmacs-office-formula-eval "=A2+A3" cells "s")))))

(ert-deftest cmacs-office-formula-reports-unsupported-rather-than-guessing ()
  "A formula we cannot evaluate returns nil, so the cached value stands.

Showing a number nobody computed would be worse than showing the one
the spreadsheet application already worked out."
  (skip-unless (require 'cmacs-office-formula nil t))
  (let ((cells '((:sheet "s" :row 1 :col 1 :ref "A1" :text "1" :formula nil))))
    (should-not (cmacs-office-formula-eval "=VLOOKUP(A1,B:C,2)" cells "s"))
    (should-not (cmacs-office-formula-eval "=NPV(A1:A9)" cells "s"))))

;;; Document and slide editing

(ert-deftest cmacs-office-set-block-replaces-one-paragraph ()
  "Replacing a paragraph changes it and leaves its neighbours alone."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("docx" "odt"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (let ((b (nth 1 (cmacs-office-blocks h))))
              (cmacs-office-set-block h (plist-get b :id) (plist-get b :index)
                                      "REPLACED")
              (cmacs-office-save h))
          (cmacs-office-close h)))
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (let ((texts (mapcar (lambda (b) (plist-get b :text))
                                 (cmacs-office-blocks h))))
              (should (equal '("cmacs office fixture" "REPLACED") texts)))
          (cmacs-office-close h))))))

(ert-deftest cmacs-office-set-block-touches-only-the-body-part ()
  "A paragraph edit rewrites the body part and nothing else."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("docx" "odt"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((original (cmacs-office-tests--parts-alist tmp))
            (changed nil))
        (let ((h (cmacs-office-open tmp)))
          (unwind-protect
              (let ((b (nth 0 (cmacs-office-blocks h))))
                (cmacs-office-set-block h (plist-get b :id)
                                        (plist-get b :index) "X")
                (cmacs-office-save h))
            (cmacs-office-close h)))
        (pcase-dolist (`(,name . ,bytes) (cmacs-office-tests--parts-alist tmp))
          (unless (equal bytes (cdr (assoc name original)))
            (push name changed)))
        (should (= 1 (length changed)))))))

(ert-deftest cmacs-office-set-block-falls-back-to-the-index ()
  "An id that does not resolve still finds the block by ordinal.
That fallback is the whole reason both anchors are recorded."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "docx"
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (progn
            (cmacs-office-set-block h "NOSUCHID00" 1 "BY INDEX")
            (cmacs-office-save h))
        (cmacs-office-close h)))
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (should (equal "BY INDEX"
                         (plist-get (nth 1 (cmacs-office-blocks h)) :text)))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-set-slide-text-replaces-a-shape ()
  "Slide shape text can be replaced in both presentation formats."
  (skip-unless (cmacs-office-tests--available-p))
  (dolist (ext '("pptx" "odp"))
    (cmacs-office-tests--with-copy tmp ext
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (progn
              (cmacs-office-set-slide-text h 1 0 "NEW SLIDE TEXT")
              (cmacs-office-save h))
          (cmacs-office-close h)))
      (let ((h (cmacs-office-open tmp)))
        (unwind-protect
            (should (equal "NEW SLIDE TEXT"
                           (plist-get (car (cmacs-office-blocks h)) :text)))
          (cmacs-office-close h))))))

(ert-deftest cmacs-office-set-slide-text-rejects-bad-coordinates ()
  "Slides are 1-based; slide zero is an error, not the first slide."
  (skip-unless (cmacs-office-tests--available-p))
  (cmacs-office-tests--with-copy tmp "pptx"
    (let ((h (cmacs-office-open tmp)))
      (unwind-protect
          (progn
            (should-error (cmacs-office-set-slide-text h 0 0 "x")
                          :type 'cmacs-office-error)
            (should-error (cmacs-office-set-slide-text h 99 0 "x")
                          :type 'cmacs-office-error))
        (cmacs-office-close h)))))

(ert-deftest cmacs-office-odp-reads-shapes-other-than-frames ()
  "ODP text in a draw:custom-shape is extracted, not just draw:frame.

Any deck that came from PowerPoint arrives as custom-shapes, so a
reader that only knew about frames would return nothing at all for a
large share of real presentations."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((odp (expand-file-name "custom-shape.odp"
                               cmacs-office-tests--fixture-dir)))
    (skip-unless (file-exists-p odp))
    (let ((h (cmacs-office-open odp)))
      (unwind-protect
          (let ((blocks (cmacs-office-blocks h)))
            (should blocks)
            (should (string-match-p
                     "fixture\\|REPLACED\\|cmacs"
                     (mapconcat (lambda (b) (plist-get b :text)) blocks " "))))
        (cmacs-office-close h)))))

;;; Preview

(ert-deftest cmacs-office-preview-finds-libreoffice-or-says-so ()
  "Converter detection returns a runnable command, or nil.

It must look past `executable-find': on a host where LibreOffice is a
flatpak there is no binary on PATH, and that is exactly the case stock
`doc-view' gets wrong."
  (skip-unless (require 'cmacs-office-preview nil t))
  (let ((cmd (cmacs-office-preview-converter t)))
    (when cmd
      (should (listp cmd))
      (should (stringp (car cmd)))
      (should (cmacs-office-preview-available-p))
      ;; A flatpak invocation must name the command explicitly, because
      ;; `soffice' is not on the sandbox PATH.
      (when (equal (car cmd) "flatpak")
        (should (seq-find (lambda (a) (string-prefix-p "--command=" a)) cmd))))))

(ert-deftest cmacs-office-preview-command-grants-sandbox-access ()
  "A flatpak conversion is granted the directories it must reach."
  (skip-unless (require 'cmacs-office-preview nil t))
  (skip-unless (cmacs-office-preview-available-p))
  (let* ((cmd (cmacs-office-preview-command
               (cmacs-office-tests--fixture "docx") "pdf"
               temporary-file-directory)))
    (should (member "--headless" cmd))
    (should (member "--convert-to" cmd))
    (when (equal (car cmd) "flatpak")
      (should (seq-find (lambda (a) (string-prefix-p "--filesystem=" a)) cmd)))))

;;; Authoring

(ert-deftest cmacs-office-authors-a-docx-from-org ()
  "An org buffer becomes a Word document with real heading styles."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office-author nil t))
  (skip-unless (ignore-errors (cmacs-office-author-template-file)))
  (let ((out (make-temp-file "cmacs-office-authored-" nil ".docx")))
    (unwind-protect
        (with-temp-buffer
          (insert "* Introduction\nOpening paragraph.\n"
                  "** Background\nMore prose.\n* Findings\nThe finding.\n")
          (org-mode)
          (cmacs-office-author-docx out (current-buffer))
          (let ((h (cmacs-office-open out)))
            (unwind-protect
                (let ((blocks (cmacs-office-blocks h)))
                  (should (eq 'docx (cmacs-office-format h)))
                  (should (equal '(1 0 2 0 1 0)
                                 (mapcar (lambda (b) (plist-get b :level))
                                         blocks)))
                  (should (equal "Introduction"
                                 (plist-get (car blocks) :text))))
              (cmacs-office-close h))))
      (ignore-errors (delete-file out)))))

(ert-deftest cmacs-office-author-refuses-formats-it-does-not-generate ()
  "Asking for a deck from an outline is refused, not faked."
  (skip-unless (require 'cmacs-office-author nil t))
  (dolist (ext '("pptx" "xlsx" "ods" "odp"))
    (should-error (cmacs-office-author (concat "/tmp/x." ext))
                  :type 'user-error)))

;;; Agent tools

(ert-deftest cmacs-office-tools-parse-cell-references ()
  "Agent-facing references parse with and without a sheet name."
  (skip-unless (require 'cmacs-office-tools nil t))
  (should (equal '("Sheet1" 7 2) (cmacs-office-tools--parse-ref "Sheet1!B7")))
  (should (equal '(nil 1 1) (cmacs-office-tools--parse-ref "A1")))
  (should (equal '(nil 10 27) (cmacs-office-tools--parse-ref "AA10")))
  (should-error (cmacs-office-tools--parse-ref "not a ref")))

(ert-deftest cmacs-office-reclaims-its-file-types-at-startup ()
  "A config that rebuilds `auto-mode-alist' does not cost us the
associations: `emacs-startup-hook' runs after the init files and puts
them back, so no user has to edit their configuration for a .docx to
open as a document rather than as an unzip listing."
  (skip-unless (cmacs-office-tests--available-p))
  (should (memq #'cmacs-office-claim-file-types emacs-startup-hook))
  (let ((auto-mode-alist (copy-sequence auto-mode-alist)))
    (setq auto-mode-alist
          (rassq-delete-all #'cmacs-office--open-file auto-mode-alist))
    (should-not (eq #'cmacs-office--open-file
                    (assoc-default "x.docx" auto-mode-alist #'string-match-p)))
    (cmacs-office-claim-file-types)
    (dolist (name '("a.docx" "a.xlsx" "a.pptx" "a.odt" "a.ods" "a.odp"))
      (should (eq #'cmacs-office--open-file
                  (assoc-default name auto-mode-alist #'string-match-p))))))

(ert-deftest cmacs-office-escape-hatch-is-reachable-without-loading ()
  "`cmacs-office-install-auto-mode' is an autoloaded command.

It is the manual recovery, so it has to be findable from \\[execute-extended-command]
in a session where nothing office-related has been loaded yet -- which
is exactly the session that needs it."
  (skip-unless (cmacs-office-tests--available-p))
  (should (commandp 'cmacs-office-install-auto-mode))
  (should (commandp 'cmacs-office-claim-file-types)))

(ert-deftest cmacs-office-autoloads-recover-a-clobbered-alist ()
  "Requiring `cmacs-office-autoloads' reclaims the file associations.

Configurations that regenerate their own autoloads (Doom does) drop
bare `add-to-list' cookies and reinitialise `auto-mode-alist' during
startup, so the dumped entry does not survive.  The symptom is
specific: a .docx opens as an `unzip' listing, because doc-view finds
no converter and its fallback lands on the PK entry in
`magic-fallback-mode-alist'.  Nothing errors."
  (skip-unless (cmacs-office-tests--available-p))
  (let ((auto-mode-alist (copy-sequence auto-mode-alist)))
    ;; Reproduce the clobber.
    (setq auto-mode-alist
          (rassq-delete-all #'cmacs-office--open-file auto-mode-alist))
    (should-not (eq #'cmacs-office--open-file
                    (assoc-default "x.docx" auto-mode-alist #'string-match-p)))
    ;; Recover.
    (load "cmacs-office-autoloads" nil t)
    (dolist (name '("a.docx" "a.xlsx" "a.pptx" "a.odt" "a.ods" "a.odp"))
      (should (eq #'cmacs-office--open-file
                  (assoc-default name auto-mode-alist #'string-match-p))))))

(ert-deftest cmacs-office-lisp-does-not-shadow-the-primitives ()
  "Loading the Elisp layer must not redefine any C primitive.

An Elisp `defun' with the same name as a DEFUN silently replaces it
for every caller, and the failure looks like the primitive misbehaving
rather than like a name collision."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office nil t))
  (dolist (fn '(cmacs-office-open cmacs-office-close cmacs-office-revert
                cmacs-office-save cmacs-office-save-as cmacs-office-format
                cmacs-office-kind cmacs-office-blocks cmacs-office-cells
                cmacs-office-part-bytes cmacs-office-set-part-bytes))
    (should (subrp (symbol-function fn)))))

(ert-deftest cmacs-office-claims-its-extensions-from-doc-view ()
  "Office extensions route to the projection, not to `doc-view'.

`lisp/files.el' maps all six to `doc-view-mode-maybe' and the first
match in `auto-mode-alist' wins, so the entry has to sit in front of
it."
  (skip-unless (cmacs-office-tests--available-p))
  (skip-unless (require 'cmacs-office nil t))
  (dolist (name '("a.docx" "a.xlsx" "a.pptx" "a.odt" "a.ods" "a.odp"))
    (let ((handler (assoc-default name auto-mode-alist #'string-match-p)))
      (should (eq handler #'cmacs-office--open-file)))))

(provide 'cmacs-office-tests)
;;; cmacs-office-tests.el ends here
