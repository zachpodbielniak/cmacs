;;; cmacs-print-tests.el --- Tests for cmacs-print  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-print)

;;; ---------------------------------------------------------------------
;;; Title sanitisation
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-sanitise-passthrough ()
  "Already-safe strings round-trip unchanged."
  (should (equal (cmacs-print--sanitise-title "receipt-2026-05-02")
                 "receipt-2026-05-02")))

(ert-deftest cmacs-print-sanitise-spaces ()
  "Spaces collapse to single underscores."
  (should (equal (cmacs-print--sanitise-title "Q1 financial report")
                 "Q1_financial_report")))

(ert-deftest cmacs-print-sanitise-shell-metas ()
  "Shell metacharacters are stripped — they cannot survive into the
elisp form built by the CUPS backend."
  (should (equal (cmacs-print--sanitise-title "evil$(rm -rf /).pdf")
                 "evil_rm_-rf_.pdf")))

(ert-deftest cmacs-print-sanitise-leading-trailing-underscores ()
  "Leading and trailing fill chars are trimmed."
  (should (equal (cmacs-print--sanitise-title "  ★boom★  ") "boom")))

(ert-deftest cmacs-print-sanitise-empty ()
  "Empty / all-stripped input falls back to \"untitled\"."
  (should (equal (cmacs-print--sanitise-title "")           "untitled"))
  (should (equal (cmacs-print--sanitise-title "★★★★")       "untitled"))
  (should (equal (cmacs-print--sanitise-title nil)          "untitled")))

(ert-deftest cmacs-print-sanitise-length-cap ()
  "Result is capped at 80 characters."
  (let ((s (make-string 200 ?a)))
    (should (<= (length (cmacs-print--sanitise-title s)) 80))))

;;; ---------------------------------------------------------------------
;;; PNG dimension parsing
;;; ---------------------------------------------------------------------

(defconst cmacs-print-tests--png-1x1
  ;; Smallest valid PNG: 1×1 black pixel.  Hand-crafted bytes; the
  ;; parser only inspects the IHDR width/height fields, which are at
  ;; offsets 16 (W) and 20 (H), each big-endian uint32.  The CRCs and
  ;; IDAT length here are arbitrary — the parser doesn't verify them.
  (concat
   ;; signature
   "\x89PNG\r\n\x1a\n"
   ;; IHDR chunk: length=13 type="IHDR"
   "\x00\x00\x00\x0dIHDR"
   ;; width=1, height=1
   "\x00\x00\x00\x01\x00\x00\x00\x01"
   ;; bit-depth=8 colour-type=0 compression=0 filter=0 interlace=0
   "\x08\x00\x00\x00\x00"
   ;; placeholder CRC; not validated
   "\x00\x00\x00\x00")
  "24-byte PNG prefix sufficient for the dimension parser.")

(ert-deftest cmacs-print-png-dimensions-1x1 ()
  "Parser reads 1×1 IHDR fields."
  (let ((tmp (make-temp-file "cmacs-print-test-" nil ".png")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (set-buffer-multibyte nil)
            (insert cmacs-print-tests--png-1x1))
          (should (equal (cmacs-print--png-dimensions tmp) '(1 . 1))))
      (delete-file tmp))))

(ert-deftest cmacs-print-png-dimensions-1240x1754 ()
  "Parser reads canonical A4-at-150-DPI dimensions."
  (let ((tmp (make-temp-file "cmacs-print-test-" nil ".png")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (set-buffer-multibyte nil)
            (insert "\x89PNG\r\n\x1a\n")
            (insert "\x00\x00\x00\x0dIHDR")
            ;; 1240 = 0x000004D8, 1754 = 0x000006DA
            (insert "\x00\x00\x04\xd8\x00\x00\x06\xda")
            (insert "\x08\x00\x00\x00\x00\x00\x00\x00\x00"))
          (should (equal (cmacs-print--png-dimensions tmp) '(1240 . 1754))))
      (delete-file tmp))))

(ert-deftest cmacs-print-png-dimensions-bad-magic ()
  "Non-PNG file returns nil."
  (let ((tmp (make-temp-file "cmacs-print-test-")))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert "not a png file"))
          (should (null (cmacs-print--png-dimensions tmp))))
      (delete-file tmp))))

(ert-deftest cmacs-print-png-dimensions-missing-file ()
  "Missing path returns nil rather than signalling."
  (should (null (cmacs-print--png-dimensions
                 "/nonexistent/path/file.png"))))

;;; ---------------------------------------------------------------------
;;; Org doc generation (golden output)
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-write-org-shape ()
  "Generated org references siblings (page-NNN.png, source.pdf) by
bare basename — the org file lives inside the per-print directory."
  (let* ((dir (make-temp-file "cmacs-print-test-" t))
         (org-path (expand-file-name "index.org" dir))
         (cmacs-print-dpi 150))
    (unwind-protect
        (progn
          (cmacs-print--write-org org-path 2 "source.pdf" "Receipt")
          (with-temp-buffer
            (insert-file-contents org-path)
            (let ((s (buffer-string)))
              (should (string-match-p "^#\\+TITLE: Receipt$" s))
              (should (string-match-p
                       "^#\\+CMACS_PRINT_SOURCE: source\\.pdf$" s))
              (should (string-match-p "^#\\+CMACS_PRINT_DPI: 150$" s))
              (should (string-match-p "^#\\+STARTUP: showall inlineimages$" s))
              (should (string-match-p "^\\* Page 1$" s))
              (should (string-match-p "^\\* Page 2$" s))
              (should (string-match-p
                       ":CMACS_PRINT_IMAGE: page-001\\.png" s))
              (should (string-match-p
                       "\\[\\[file:page-002\\.png\\]\\]" s))
              ;; Make sure no stray <stem>/ prefix leaks back in.
              (should-not (string-match-p "/page-00" s)))))
      (delete-directory dir t))))

(ert-deftest cmacs-print-write-org-no-pdf ()
  "When source-pdf-rel is nil, no #+CMACS_PRINT_SOURCE line is emitted."
  (let* ((dir (make-temp-file "cmacs-print-test-" t))
         (org-path (expand-file-name "index.org" dir)))
    (unwind-protect
        (progn
          (cmacs-print--write-org org-path 1 nil "Only Org")
          (with-temp-buffer
            (insert-file-contents org-path)
            (let ((s (buffer-string)))
              (should-not (string-match-p "#\\+CMACS_PRINT_SOURCE" s))
              (should (string-match-p "^\\* Page 1$" s))
              (should (string-match-p
                       "\\[\\[file:page-001\\.png\\]\\]" s)))))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------
;;; Page renaming
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-rename-pages-zero-pads ()
  "Unpadded `page-1.png' files become `page-001.png'."
  (let* ((dir (make-temp-file "cmacs-print-test-" t)))
    (unwind-protect
        (progn
          (dotimes (i 12)
            (with-temp-file (expand-file-name
                             (format "page-%d.png" (1+ i)) dir)
              (insert "")))
          (cmacs-print--rename-pages dir)
          (let ((files (directory-files dir nil "\\.png\\'")))
            (should (= (length files) 12))
            (should (member "page-001.png" files))
            (should (member "page-009.png" files))
            (should (member "page-010.png" files))
            (should (member "page-012.png" files))))
      (delete-directory dir t))))

;;; ---------------------------------------------------------------------
;;; Spool-name title extraction
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-title-from-spool-name-strips-prefix ()
  "Backend-prefixed spool path collapses to the embedded title."
  (should (equal
           (cmacs-print--title-from-spool-name
            "/tmp/cmacs-print-1000/20260502-185347-job2-Receipt.pdf")
           "Receipt")))

(ert-deftest cmacs-print-title-from-spool-name-passthrough ()
  "Plain filenames (interactive M-x) keep their basename."
  (should (equal
           (cmacs-print--title-from-spool-name "/tmp/just-a-doc.pdf")
           "just-a-doc")))

(ert-deftest cmacs-print-title-from-spool-name-multi-digit-job ()
  "Multi-digit job IDs strip cleanly."
  (should (equal
           (cmacs-print--title-from-spool-name
            "/tmp/cmacs-print-1000/20260502-235959-job12345-Long_Title.pdf")
           "Long_Title")))

;;; ---------------------------------------------------------------------
;;; Defcustom defaults
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-defaults ()
  "Default option values match the documented contract."
  (should (member 'org cmacs-print-output-formats))
  (should (member 'pdf cmacs-print-output-formats))
  (should (integerp cmacs-print-dpi))
  (should (>= cmacs-print-dpi 72))
  (should (integerp cmacs-print-max-pages))
  (should (eq cmacs-print-auto-open t)))

(provide 'cmacs-print-tests)
;;; cmacs-print-tests.el ends here

;;; ---------------------------------------------------------------------
;;; Spool directory ownership
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-print-spool-dir-accepts-own-private-directory ()
  "A 0700 directory we own passes; the watcher may attach."
  (let ((dir (make-temp-file "cmacs-print-spool" t)))
    (unwind-protect
        (progn
          (set-file-modes dir #o700)
          (should (cmacs-print--spool-dir-safe-p dir))
          (let ((cmacs-print-spool-dir dir))
            (should (equal (cmacs-print--ensure-spool-dir) dir))))
      (delete-directory dir t))))

(ert-deftest cmacs-print-spool-dir-rejects-symlink-and-loose-modes ()
  "A symlink, or group/world bits, is refused rather than adopted.

/tmp is world-writable, so whoever creates /tmp/cmacs-print-<uid>
first owns it; auto-importing from a directory another user prepared
is the thing this check exists to stop."
  (let* ((real (make-temp-file "cmacs-print-real" t))
         (link (concat (make-temp-file "cmacs-print-link") "-l")))
    (unwind-protect
        (progn
          (set-file-modes real #o700)
          (make-symbolic-link real link)
          (should-not (cmacs-print--spool-dir-safe-p link))
          (let ((cmacs-print-spool-dir link))
            (should-error (cmacs-print--ensure-spool-dir)))
          (set-file-modes real #o755)
          (should-not (cmacs-print--spool-dir-safe-p real))
          (let ((cmacs-print-spool-dir real))
            (should-error (cmacs-print--ensure-spool-dir))))
      (ignore-errors (delete-file link))
      (ignore-errors (delete-file (substring link 0 -2)))
      (delete-directory real t))))
