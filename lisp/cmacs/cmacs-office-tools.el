;;; cmacs-office-tools.el --- Office documents for agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Publishes the Office subsystem to the brigade tool bus, which reaches
;; in-process agents, CLI agents over the MCP relay, external MCP
;; clients, and the AI context menu -- one definition each, no per-
;; surface plumbing.
;;
;; Two constraints shape the API here, both from ai-glib's tool model:
;; parameters are flat scalars (no nested objects or arrays), and a
;; handler returns a string.  So documents are addressed by PATH rather
;; than by handle -- an agent has no session to hold a handle across --
;; and ranges travel as strings like "Sheet1!A1:D20".
;;
;; Every tool opens, acts, and closes.  That costs a reopen per call and
;; buys the thing that matters: an agent cannot leak a document handle,
;; and cannot act on stale state from a file that changed underneath it.
;;
;; Mutating tools are marked destructive and default to asking.  These
;; edit real documents in place, and the round-trip guarantee protects
;; the parts nobody touched -- not the part an agent was wrong about.

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(declare-function cmacs-office-open "src/cmacs-office-defuns.c" (path))
(declare-function cmacs-office-close "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-format "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-kind "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-metadata "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-blocks "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-cells "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-sheet-names "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-set-cell "src/cmacs-office-defuns.c"
                  (handle sheet row col &optional text formula))
(declare-function cmacs-office-set-block "src/cmacs-office-defuns.c"
                  (handle id index text))
(declare-function cmacs-office-set-slide-text "src/cmacs-office-defuns.c"
                  (handle slide index text))
(declare-function cmacs-office-save "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-text "cmacs-office" (handle))
(declare-function cmacs-brigade-deftool "cmacs-brigade-registry")

(defcustom cmacs-office-tools-max-chars 40000
  "Longest document text a tool will return in one call.

Agents pay for every character, and a hundred-page report answers no
question a truncated one does not.  Output past this is cut with a
marker saying so, rather than silently."
  :type 'integer
  :safe #'integerp
  :group 'cmacs-office)

(defmacro cmacs-office-tools--with (path handle &rest body)
  "Open PATH, bind HANDLE, run BODY, and always close."
  (declare (indent 2))
  `(let ((,handle (cmacs-office-open (expand-file-name ,path))))
     (unwind-protect (progn ,@body)
       (cmacs-office-close ,handle))))

(defun cmacs-office-tools--cap (text)
  "Return TEXT, truncated to `cmacs-office-tools-max-chars' if needed."
  (if (<= (length text) cmacs-office-tools-max-chars)
      text
    (concat (substring text 0 cmacs-office-tools-max-chars)
            (format "\n\n[truncated: %d of %d characters shown]"
                    cmacs-office-tools-max-chars (length text)))))

(defun cmacs-office-tools--parse-ref (ref)
  "Parse REF like \"Sheet1!B7\" or \"B7\" into (SHEET ROW COL)."
  (let* ((bang (string-search "!" ref))
         (sheet (and bang (substring ref 0 bang)))
         (cell (upcase (if bang (substring ref (1+ bang)) ref))))
    (unless (string-match "\\`\\$?\\([A-Z]+\\)\\$?\\([0-9]+\\)\\'" cell)
      (error "Not a cell reference: %s" ref))
    (let ((letters (match-string 1 cell))
          (row (string-to-number (match-string 2 cell)))
          (col 0))
      (dotimes (i (length letters))
        (setq col (+ (* col 26) (- (aref letters i) ?A -1))))
      (list sheet row col))))

;; Registration is guarded rather than assumed: the Office subsystem
;; can be built without the AI fabric, and a missing macro at load time
;; should leave the rest of the subsystem working.
(when (and (fboundp 'cmacs-office-supported-p)
           (cmacs-office-supported-p)
           (require 'cmacs-brigade-registry nil t)
           (fboundp 'cmacs-brigade-deftool))

  (cmacs-brigade-deftool office-read
    "Read the text of a Word document, spreadsheet or presentation --
.docx, .xlsx, .pptx, .odt, .ods or .odp.  Returns the readable content:
paragraphs for documents, tab-separated rows for spreadsheets, slide
text for presentations.  Use this instead of guessing at a file you
cannot open."
    ((path string "Absolute path to the document"))
    :group 'office
    (require 'cmacs-office)
    (cmacs-office-tools--with path h
      (cmacs-office-tools--cap (cmacs-office-text h))))

  (cmacs-brigade-deftool office-info
    "Describe a document without reading all of it: its format, what
kind of document it is, its sheet or slide count, and its properties
\(title, author, dates).  Cheap; prefer it before office_read when you
only need to know what something is."
    ((path string "Absolute path to the document"))
    :group 'office
    (cmacs-office-tools--with path h
      (let* ((kind (cmacs-office-kind h))
             (meta (cmacs-office-metadata h))
             (extra
              (pcase kind
                ('sheet (format "sheets: %s"
                                (string-join (cmacs-office-sheet-names h) ", ")))
                ('slides (format "slides: %d"
                                 (length (delete-dups
                                          (mapcar (lambda (b) (plist-get b :slide))
                                                  (cmacs-office-blocks h))))))
                ('text (format "blocks: %d" (length (cmacs-office-blocks h))))
                (_ "unrecognised package"))))
        (concat (format "format: %s\nkind: %s\n%s\n"
                        (cmacs-office-format h) kind extra)
                (if (null meta)
                    ""
                  (concat "properties:\n"
                          (cl-loop for (k v) on meta by #'cddr
                                   concat (format "  %s: %s\n"
                                                  (substring (symbol-name k) 1)
                                                  v))))))))

  (cmacs-brigade-deftool office-outline
    "List a document's blocks with the anchors needed to edit them.

Each line is INDEX, then the heading level or slide number, then the
text.  Pass an INDEX back to office_set_text to change that block --
this is how you locate what to edit."
    ((path string "Absolute path to the document"))
    :group 'office
    (cmacs-office-tools--with path h
      (let ((blocks (cmacs-office-blocks h)))
        (if (null blocks)
            "No text blocks (a spreadsheet? use office_cells)."
          (cmacs-office-tools--cap
           (mapconcat
            (lambda (b)
              (format "%-4d %-10s %s"
                      (plist-get b :index)
                      (cond ((> (plist-get b :slide) 0)
                             (format "slide %d" (plist-get b :slide)))
                            ((> (plist-get b :level) 0)
                             (format "h%d" (plist-get b :level)))
                            (t "para"))
                      (string-trim (plist-get b :text))))
            blocks "\n"))))))

  (cmacs-brigade-deftool office-cells
    "Read a spreadsheet's non-empty cells as ADDRESS<TAB>VALUE lines.

Empty cells are omitted.  A cell holding a formula shows its value and
then the formula in brackets."
    ((path string "Absolute path to the spreadsheet")
     (sheet string "Sheet name; omit for every sheet" :optional t))
    :group 'office
    (cmacs-office-tools--with path h
      (let ((cells (cmacs-office-cells h)))
        (when (and sheet (not (string-empty-p sheet)))
          (setq cells (seq-filter (lambda (c) (equal sheet (plist-get c :sheet)))
                                  cells)))
        (if (null cells)
            "No cells (not a spreadsheet, or no such sheet)."
          (cmacs-office-tools--cap
           (mapconcat (lambda (c)
                        (format "%s!%s\t%s%s"
                                (plist-get c :sheet) (plist-get c :ref)
                                (plist-get c :text)
                                (if (plist-get c :formula)
                                    (format "  [=%s]" (plist-get c :formula))
                                  "")))
                      cells "\n"))))))

  (cmacs-brigade-deftool office-set-cell
    "Set one spreadsheet cell and save the file.

REF is like \"Sheet1!B7\", or just \"B7\" for the first sheet.  A VALUE
beginning with `=' is stored as a formula.  Everything else in the
document is preserved byte-for-byte."
    ((path string "Absolute path to the spreadsheet")
     (ref string "Cell reference, e.g. Sheet1!B7")
     (value string "New value; a leading = makes it a formula"))
    :group 'office
    :destructive t
    :confirm 'ask
    (cmacs-office-tools--with path h
      (pcase-let ((`(,sheet ,row ,col) (cmacs-office-tools--parse-ref ref)))
        (if (string-prefix-p "=" value)
            (cmacs-office-set-cell h sheet row col nil (substring value 1))
          (cmacs-office-set-cell h sheet row col value nil))
        (cmacs-office-save h)
        (format "Set %s to %s in %s" ref value (file-name-nondirectory path)))))

  (cmacs-brigade-deftool office-set-text
    "Replace the text of one block in a document, and save.

INDEX comes from office_outline.  For a presentation, pass the slide
number as SLIDE too and INDEX is the shape's position on that slide.

The block keeps its style; formatting that varied inside it is
flattened.  Nothing else in the document changes."
    ((path string "Absolute path to the document")
     (index integer "Block index from office_outline")
     (text string "Replacement text")
     (slide integer "Slide number, for presentations only" :optional t))
    :group 'office
    :destructive t
    :confirm 'ask
    (cmacs-office-tools--with path h
      (if (and slide (> slide 0))
          (cmacs-office-set-slide-text h slide index text)
        (let ((block (seq-find (lambda (b) (= index (plist-get b :index)))
                               (cmacs-office-blocks h))))
          (cmacs-office-set-block h (and block (plist-get block :id))
                                  index text)))
      (cmacs-office-save h)
      (format "Replaced block %d in %s" index (file-name-nondirectory path)))))

(provide 'cmacs-office-tools)
;;; cmacs-office-tools.el ends here
