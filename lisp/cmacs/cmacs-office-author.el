;;; cmacs-office-author.el --- write org out as an Office document -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Turning an org file into a .docx or .odt, so that org can be the
;; place you write and Word format merely the thing you hand over.
;;
;; The template-donor approach.  Nothing here synthesises styles.xml,
;; theme1.xml or the twenty other parts a Word document carries.  It
;; copies a real document and replaces its body.  That is far less code
;; than generating a stylesheet, and the output inherits styling someone
;; actually designed -- headings that look like headings, in a document
;; Word does not complain about.  Point `cmacs-office-author-template'
;; at your own house-style document and everything you export adopts it.
;;
;; Scope, stated plainly.  Word documents (.docx) are generated
;; natively, and OpenDocument text (.odt) goes through org's own
;; `ox-odt', which already does the whole job and would be silly to
;; duplicate.  Spreadsheets and presentations are NOT generated from
;; org: a deck is not an outline and a workbook is not prose.  Those are
;; authored by editing a real document -- see `cmacs-office-set-cell'
;; and `cmacs-office-set-slide-text' -- which is both more honest and
;; more useful than pretending a heading tree is a slide deck.

;;; Code:

(require 'org)
(require 'org-element)
(require 'subr-x)

(declare-function cmacs-office-open "src/cmacs-office-defuns.c" (path))
(declare-function cmacs-office-close "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-save "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-main-part "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-set-part-bytes "src/cmacs-office-defuns.c"
                  (handle name bytes))
(declare-function org-odt-export-to-odt "ox-odt")

(defgroup cmacs-office-author nil
  "Authoring Office documents from org."
  :group 'cmacs-office
  :prefix "cmacs-office-author-")

(defcustom cmacs-office-author-template nil
  "Document to use as the style donor when writing a .docx.

nil means the minimal template shipped with cmacs, which defines
Heading 1 through 3 and a body style.  Point this at a document of your
own and everything exported adopts its styles, page setup and fonts --
that is the whole point of copying a document rather than generating
one."
  :type '(choice (const :tag "Shipped minimal template" nil) file)
  :group 'cmacs-office-author)

(defconst cmacs-office-author--wordml
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  "The WordprocessingML namespace.")

(defun cmacs-office-author-template-file ()
  "Return the .docx to use as the style donor."
  (or cmacs-office-author-template
      (let ((shipped (expand-file-name "cmacs/office/template.docx" data-directory)))
        (if (file-exists-p shipped)
            shipped
          ;; Running from the build tree, where data-directory is not
          ;; yet the installed etc/.
          (let ((in-tree (expand-file-name
                          "../etc/cmacs/office/template.docx"
                          (file-name-directory (or load-file-name
                                                   buffer-file-name
                                                   default-directory)))))
            (if (file-exists-p in-tree)
                in-tree
              (user-error
               "No .docx template found; set `cmacs-office-author-template'")))))))

;;; Reading org

(defun cmacs-office-author--blocks (&optional buffer)
  "Return BUFFER's content as a list of (LEVEL . TEXT).

LEVEL is the heading depth, or 0 for a body paragraph.  Deliberately
flat: it is what the document model on the other side accepts, and a
tree would only have to be flattened there instead."
  (with-current-buffer (or buffer (current-buffer))
    (let ((tree (org-element-parse-buffer))
          (out nil))
      (org-element-map tree '(headline paragraph)
        (lambda (el)
          (pcase (org-element-type el)
            ('headline
             (push (cons (org-element-property :level el)
                         (substring-no-properties
                          (or (org-element-property :raw-value el) "")))
                   out))
            ('paragraph
             ;; A headline's own paragraphs are separate elements, so
             ;; taking the interpreted text here does not duplicate the
             ;; title.
             (let ((text (string-trim
                          (substring-no-properties
                           (org-element-interpret-data
                            (org-element-contents el))))))
               (unless (string-empty-p text)
                 (push (cons 0 text) out)))))))
      (nreverse out))))

;;; Writing WordprocessingML

(defun cmacs-office-author--escape (text)
  "Return TEXT escaped for XML character data."
  (replace-regexp-in-string
   "&" "&amp;"
   (replace-regexp-in-string
    "<" "&lt;"
    (replace-regexp-in-string ">" "&gt;" (or text "")))))

(defun cmacs-office-author--paragraph (level text)
  "Return the WordprocessingML for one paragraph."
  (concat
   "<w:p>"
   (when (> level 0)
     ;; Style by NAME, resolved against the donor's styles.xml.  Word
     ;; has no structural heading element -- the style is the heading.
     (format "<w:pPr><w:pStyle w:val=\"Heading%d\"/></w:pPr>"
             (min level 9)))
   ;; xml:space is required or Word discards leading and trailing
   ;; whitespace, which quietly runs words together.
   (format "<w:r><w:t xml:space=\"preserve\">%s</w:t></w:r>"
           (cmacs-office-author--escape text))
   "</w:p>"))

(defun cmacs-office-author--document-xml (blocks)
  "Return a complete word/document.xml rendering BLOCKS."
  (concat
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   (format "<w:document xmlns:w=\"%s\"><w:body>" cmacs-office-author--wordml)
   (mapconcat (lambda (b) (cmacs-office-author--paragraph (car b) (cdr b)))
              blocks "")
   ;; A section marker closes the body.  Word tolerates its absence but
   ;; writes one back in immediately; supplying it keeps the first save
   ;; from rewriting the document.
   "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
   "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/>"
   "</w:sectPr>"
   "</w:body></w:document>"))

;;; Entry points

;;;###autoload
(defun cmacs-office-author-docx (output &optional buffer template)
  "Write BUFFER's org content to OUTPUT as a Word document.

BUFFER defaults to the current buffer and TEMPLATE to
`cmacs-office-author-template'.  The template is copied and its body
replaced, so the result carries the template's styles, fonts and page
setup."
  (interactive
   (list (read-file-name "Write .docx to: " nil nil nil
                         (concat (file-name-base (or buffer-file-name "document"))
                                 ".docx"))))
  (let* ((donor (or template (cmacs-office-author-template-file)))
         (blocks (cmacs-office-author--blocks buffer))
         (output (expand-file-name output)))
    (when (null blocks)
      (user-error "Nothing to write: no headings or paragraphs found"))
    (copy-file donor output t)
    (let ((h (cmacs-office-open output)))
      (unwind-protect
          (progn
            (cmacs-office-set-part-bytes
             h (or (cmacs-office-main-part h) "word/document.xml")
             (encode-coding-string
              (cmacs-office-author--document-xml blocks) 'utf-8))
            (cmacs-office-save h))
        (cmacs-office-close h)))
    (when (called-interactively-p 'any)
      (message "Wrote %s (%d blocks)" output (length blocks)))
    output))

;;;###autoload
(defun cmacs-office-author-odt (&optional _output buffer)
  "Write BUFFER's org content out as an OpenDocument text file.

Delegates to org's own `ox-odt', which already produces a complete ODT
and would be pointless to reimplement."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (require 'ox-odt)
    (org-odt-export-to-odt)))

;;;###autoload
(defun cmacs-office-author (output &optional buffer)
  "Write BUFFER's org content to OUTPUT, choosing a writer by extension.

`.docx' is generated natively from a template; `.odt' goes through
org's `ox-odt'.  Spreadsheets and presentations are not generated from
org -- edit a real document instead, with `cmacs-office-set-cell' or
`cmacs-office-set-slide-text'."
  (interactive
   (list (read-file-name "Write document to: " nil nil nil
                         (concat (file-name-base (or buffer-file-name "document"))
                                 ".docx"))))
  (pcase (downcase (or (file-name-extension output) ""))
    ("docx" (cmacs-office-author-docx output buffer))
    ("odt" (cmacs-office-author-odt output buffer))
    (ext (user-error
          "cmacs-office authors .docx and .odt, not .%s%s" ext
          (if (member ext '("xlsx" "ods" "pptx" "odp"))
              "; edit an existing document instead"
            "")))))

(provide 'cmacs-office-author)
;;; cmacs-office-author.el ends here
