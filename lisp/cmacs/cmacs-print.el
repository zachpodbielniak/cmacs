;;; cmacs-print.el --- Print to cmacs virtual printer + PDF intake  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Print to cmacs" — OneNote-style virtual printer.  A small CUPS
;; backend (`cmacs/print/cmacs-print') routes any application's print
;; job to a D-Bus call that lands here as `cmacs-print-import-pdf'.
;; The PDF is split into per-page PNGs and emitted as an annotatable
;; org document.  Annotation rides on the existing ink subsystem:
;; cmacs-ink-region for pixel-anchored overlay strokes, plus the user's
;; Doom annotation stack (pdf-tools, org-noter, org-remark, org-roam).
;;
;; Output naming: one directory per print job under
;; `cmacs-print-target-dir', containing all artefacts:
;;
;;   <YYYYMMDD-HHMMSS>-<title>/
;;     index.org      ; if 'org in formats
;;     source.pdf     ; if 'pdf in formats
;;     page-001.png   ; if 'org (one per page)
;;     page-002.png
;;     ...
;;
;; `cmacs-print-output-formats' selects which artefacts are produced.
;; Default produces both an org doc (with inline page images) and a
;; full copy of the PDF, so org-noter can pair the two.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'subr-x)

(defgroup cmacs-print nil
  "Print to cmacs virtual printer and PDF intake."
  :group 'cmacs
  :prefix "cmacs-print-")

;; ---------------------------------------------------------------------
;; User-facing options
;; ---------------------------------------------------------------------

(defcustom cmacs-print-target-dir
  (expand-file-name "Documents/notes/03_resources/cmacs-print" "~")
  "Directory where imported prints are stored.
Created on demand.  All artefacts (org docs, PDF copies, page-image
subdirs, the inbox fallback) live directly inside this directory."
  :type 'directory
  :safe #'stringp)

(defcustom cmacs-print-output-formats '(org pdf)
  "Which artefacts to produce per print job.
A list containing any of the symbols `org' (rasterise the PDF and
generate an annotatable index.org with inline page images) and
`pdf' (keep a full copy of the original PDF alongside the org).
Both is the OneNote-style default — the org doc is the annotation
canvas and the PDF stays available for `org-noter' / `pdf-tools'."
  :type '(set (const :tag "Org doc with page images" org)
              (const :tag "Full PDF copy" pdf))
  :safe (lambda (v) (and (listp v) (cl-every #'symbolp v))))

(defcustom cmacs-print-dpi 150
  "DPI passed to the rasteriser (`pdftocairo -r N').
150 yields ~1240×1754 px for A4 / ~1275×1650 for US Letter — comfortable
annotation density at modest file size.  Increase for sharper output."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-print-max-pages 200
  "Reject (with confirmation) PDFs larger than this number of pages.
Guards against accidentally rasterising a 1000-page document."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-print-auto-open t
  "If non-nil, open the imported document after rasterisation completes."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-print-rasterizer-program "pdftocairo"
  "External program used to rasterise PDFs to PNGs.
Must accept `-png -r DPI INPUT OUTSTEM' and produce one PNG per page
named `OUTSTEM-N.png' (no zero-padding).  poppler-utils ships this."
  :type 'string
  :safe #'stringp)

(defcustom cmacs-print-pdfinfo-program "pdfinfo"
  "External program used to read PDF metadata (title, page count)."
  :type 'string
  :safe #'stringp)

(defcustom cmacs-print-debug nil
  "If non-nil, log import steps to *Messages* / *cmacs-print-log*."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-print-spool-dir
  (format "/tmp/cmacs-print-%d" (user-uid))
  "Directory the system CUPS backend writes incoming PDFs to.
Cmacs file-notify-watches this path and auto-imports new files.  The
backend writes to /tmp/ rather than /run/user/<uid>/ because the
cupsd_t SELinux domain cannot manage user_tmp_t files, but it can
manage tmp_t files freely.  Per-uid subdirectory + mode 0700 keeps
prints private on multi-user systems."
  :type 'directory
  :safe #'stringp)

(defcustom cmacs-print-watch-spool t
  "If non-nil, automatically watch `cmacs-print-spool-dir' on load.
New PDFs that appear there are passed to `cmacs-print-import-pdf'
without manual intervention — this is how the system CUPS backend
delivers print jobs to the running cmacs."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-print-poll-interval 30
  "Seconds between belt-and-suspenders spool drains, or nil to disable.
file-notify is the primary delivery mechanism, but in pure-daemon mode
without any frame attached the inotify event loop can lag.  A periodic
`cmacs-print-drain-spool' catches anything missed."
  :type '(choice (const :tag "Disabled" nil) integer)
  :safe (lambda (v) (or (null v) (integerp v))))

;; ---------------------------------------------------------------------
;; Logging
;; ---------------------------------------------------------------------

(defun cmacs-print--log (fmt &rest args)
  "Emit a `*cmacs-print-log*' line (and `*Messages*' when debug is on)."
  (let ((line (apply #'format (concat "[cmacs-print] " fmt) args)))
    (with-current-buffer (get-buffer-create "*cmacs-print-log*")
      (goto-char (point-max))
      (insert (format-time-string "%H:%M:%S ") line "\n"))
    (when cmacs-print-debug
      (message "%s" line))))

;; ---------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------

(defun cmacs-print--timestamp ()
  "Filename-safe local timestamp: \"YYYYMMDD-HHMMSS\"."
  (format-time-string "%Y%m%d-%H%M%S"))

(defun cmacs-print--sanitise-title (s)
  "Reduce S to a filename-safe stem.
Replaces every char outside [A-Za-z0-9._-] with underscore, collapses
runs of underscores, and caps at 80 chars.  Mirrors the same filter
the CUPS backend applies, so the on-disk name is stable regardless
of which side does the sanitisation."
  (let* ((s (or s ""))
         (s (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" s))
         (s (replace-regexp-in-string "_+" "_" s))
         (s (replace-regexp-in-string "\\`_+\\|_+\\'" "" s)))
    (if (string-empty-p s)
        "untitled"
      (substring s 0 (min (length s) 80)))))

(defun cmacs-print--ensure-target-dir ()
  "Create `cmacs-print-target-dir' if absent and return its expansion."
  (let ((d (expand-file-name cmacs-print-target-dir)))
    (unless (file-directory-p d)
      (make-directory d t))
    d))

(defun cmacs-print--inbox-dir ()
  "Path of the inbox subdirectory under `cmacs-print-target-dir'."
  (file-name-concat (cmacs-print--ensure-target-dir) "inbox"))

(defun cmacs-print--png-dimensions (path)
  "Return the (WIDTH . HEIGHT) of a PNG at PATH, or nil on failure.
Reads the 8-byte IHDR width/height fields directly (PNG offsets 16-23)
without spawning any subprocess."
  (when (and (stringp path) (file-readable-p path))
    (condition-case _err
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally path nil 0 24)
          (when (and (>= (buffer-size) 24)
                     (string= (buffer-substring-no-properties 1 9)
                              "\x89PNG\r\n\x1a\n"))
            (let* ((b (buffer-substring-no-properties 17 25))
                   (w (logior (ash (aref b 0) 24)
                              (ash (aref b 1) 16)
                              (ash (aref b 2) 8)
                              (aref b 3)))
                   (h (logior (ash (aref b 4) 24)
                              (ash (aref b 5) 16)
                              (ash (aref b 6) 8)
                              (aref b 7))))
              (cons w h))))
      (error nil))))

(defun cmacs-print--pdf-info (path)
  "Run `pdfinfo' on PATH; return an alist with :title and :pages.
Returns nil if `pdfinfo' is missing or fails."
  (when (executable-find cmacs-print-pdfinfo-program)
    (with-temp-buffer
      (let ((rc (call-process cmacs-print-pdfinfo-program nil t nil
                              (expand-file-name path))))
        (when (zerop rc)
          (goto-char (point-min))
          (let (title pages)
            (when (re-search-forward "^Title:[ \t]+\\(.*\\)$" nil t)
              (setq title (string-trim (match-string 1))))
            (goto-char (point-min))
            (when (re-search-forward "^Pages:[ \t]+\\([0-9]+\\)" nil t)
              (setq pages (string-to-number (match-string 1))))
            (list (cons :title (and (stringp title)
                                    (not (string-empty-p title))
                                    title))
                  (cons :pages pages))))))))

(defun cmacs-print--page-count (out-dir)
  "Count `page-*.png' files in OUT-DIR."
  (length (directory-files out-dir nil "\\`page-[0-9]+\\.png\\'")))

(defun cmacs-print--rename-pages (out-dir)
  "Rename `page-N.png' to zero-padded `page-NNN.png' in OUT-DIR.
poppler's `pdftocairo' emits unpadded names; this normalises the pad
width to 3 (sufficient for up to 999 pages — `cmacs-print-max-pages'
defaults to 200, so the bound holds in practice)."
  (let ((files (directory-files out-dir t "\\`page-[0-9]+\\.png\\'")))
    (dolist (old files)
      (when (string-match "page-\\([0-9]+\\)\\.png\\'" old)
        (let* ((n (string-to-number (match-string 1 old)))
               (new (file-name-concat
                     out-dir (format "page-%03d.png" n))))
          (unless (string= old new)
            (rename-file old new t)))))))

;; ---------------------------------------------------------------------
;; Org doc generation
;; ---------------------------------------------------------------------

(defun cmacs-print--org-page-block (n image-rel)
  "Emit a `* Page N' heading + inline image link for IMAGE-REL."
  (concat
   (format "* Page %d\n" n)
   ":PROPERTIES:\n"
   (format ":CMACS_PRINT_PAGE: %d\n" n)
   (format ":CMACS_PRINT_IMAGE: %s\n" image-rel)
   ":END:\n\n"
   (format "[[file:%s]]\n\n" image-rel)))

(defun cmacs-print--write-org (org-path page-count source-pdf-rel title)
  "Write the import org document to ORG-PATH.
The org file lives inside the per-print directory alongside the
page PNGs and the optional source PDF, so all paths in the org are
bare basenames (e.g. `page-001.png', `source.pdf').  PAGE-COUNT
is the rasterised page count.  SOURCE-PDF-REL is a sibling PDF
filename (typically \"source.pdf\") or nil when `pdf' is not in
`cmacs-print-output-formats'.  TITLE seeds the `#+TITLE' line."
  (with-temp-file org-path
    (insert (format "#+TITLE: %s\n" (or title "Untitled print")))
    (when source-pdf-rel
      (insert (format "#+CMACS_PRINT_SOURCE: %s\n" source-pdf-rel)))
    (insert (format "#+CMACS_PRINT_TIMESTAMP: %s\n"
                    (format-time-string "%FT%T")))
    (insert (format "#+CMACS_PRINT_DPI: %d\n" cmacs-print-dpi))
    (insert "#+STARTUP: showall inlineimages\n")
    (insert "#+OPTIONS: ^:nil\n\n")
    (cl-loop for n from 1 to page-count
             do (insert (cmacs-print--org-page-block
                         n (format "page-%03d.png" n))))))

;; ---------------------------------------------------------------------
;; Rasterisation (async)
;; ---------------------------------------------------------------------

(defun cmacs-print--rasterize-async (pdf out-dir on-done on-error)
  "Spawn `pdftocairo' on PDF into OUT-DIR; call ON-DONE or ON-ERROR.
ON-DONE is called with the page count.  ON-ERROR is called with a
descriptive string."
  (if (not (executable-find cmacs-print-rasterizer-program))
      (funcall on-error
               (format "%s not found on PATH"
                       cmacs-print-rasterizer-program))
    (cmacs-print--rasterize-async-1 pdf out-dir on-done on-error)))

(defun cmacs-print--rasterize-async-1 (pdf out-dir on-done on-error)
  "Inner helper for `cmacs-print--rasterize-async' assuming the binary exists."
  (let* ((stem (file-name-concat out-dir "page"))
         (proc-buf (generate-new-buffer " *cmacs-print-rasterize*"))
         (proc (make-process
                :name "cmacs-print-rasterize"
                :buffer proc-buf
                :command (list cmacs-print-rasterizer-program
                               "-png"
                               "-r" (number-to-string cmacs-print-dpi)
                               (expand-file-name pdf)
                               stem)
                :noquery t
                :sentinel
                (lambda (proc _event)
                  (when (memq (process-status proc) '(exit signal))
                    (let* ((rc (process-exit-status proc))
                           (out (with-current-buffer (process-buffer proc)
                                  (buffer-string))))
                      (kill-buffer (process-buffer proc))
                      (if (and (eq (process-status proc) 'exit)
                               (zerop rc))
                          (let ((n (cmacs-print--page-count out-dir)))
                            (cmacs-print--rename-pages out-dir)
                            (funcall on-done n))
                        (funcall on-error
                                 (format "rasterise failed (rc=%s): %s"
                                         rc (string-trim out))))))))))
    (cmacs-print--log "rasterise pid=%d %s -> %s"
                      (process-id proc) pdf out-dir)))

;; ---------------------------------------------------------------------
;; Main dispatch
;; ---------------------------------------------------------------------

(defun cmacs-print--open (org-or-pdf-path)
  "If `cmacs-print-auto-open', open ORG-OR-PDF-PATH and focus the frame."
  (when cmacs-print-auto-open
    (find-file org-or-pdf-path)
    (when (display-graphic-p)
      (select-frame-set-input-focus (selected-frame)))))

;;;###autoload
(defun cmacs-print-import-pdf (pdf-path &optional title)
  "Import PDF-PATH per `cmacs-print-output-formats'.
TITLE seeds the doc filename and `#+TITLE' line.  When TITLE is nil
or blank, use the PDF's metadata title (via `pdfinfo'), falling back
to the file's basename.

Called by the CUPS backend over D-Bus; also `M-x'-able directly."
  (interactive (list (read-file-name "PDF: " nil nil t nil
                                     (lambda (n)
                                       (or (file-directory-p n)
                                           (string-suffix-p ".pdf" n t))))))
  (setq pdf-path (expand-file-name pdf-path))
  (unless (file-readable-p pdf-path)
    (user-error "cmacs-print: cannot read %s" pdf-path))
  (let* ((info (cmacs-print--pdf-info pdf-path))
         (info-title (cdr (assq :title info)))
         (pages (cdr (assq :pages info)))
         (effective-title
          (cmacs-print--sanitise-title
           (or (and (stringp title) (not (string-empty-p title)) title)
               info-title
               (file-name-base pdf-path))))
         (doc-title (or (and (stringp title) (not (string-empty-p title))
                             title)
                        info-title
                        (file-name-base pdf-path)))
         (target (cmacs-print--ensure-target-dir))
         (stem (concat (cmacs-print--timestamp) "-" effective-title))
         ;; One directory per print job; everything goes inside it.
         (job-dir  (file-name-concat target stem))
         (org-path (file-name-concat job-dir "index.org"))
         (pdf-dst  (file-name-concat job-dir "source.pdf"))
         (formats cmacs-print-output-formats))
    (cmacs-print--log
     "import %s pages=%s title=%S formats=%S"
     pdf-path (or pages "?") doc-title formats)
    ;; Page-count guard.
    (when (and pages
               (> pages cmacs-print-max-pages)
               (not (yes-or-no-p
                     (format "PDF has %d pages (> %d).  Continue? "
                             pages cmacs-print-max-pages))))
      (user-error "cmacs-print: aborted (page count > max-pages)"))
    ;; Always create the job dir — both PDF copy and org pages live inside.
    (when (or (memq 'pdf formats) (memq 'org formats))
      (make-directory job-dir t))
    ;; PDF copy (sibling of the org / page PNGs).
    (when (memq 'pdf formats)
      (copy-file pdf-path pdf-dst t))
    ;; Org rasterise + write + open.
    (cond
     ((memq 'org formats)
      (cmacs-print--rasterize-async
       pdf-path job-dir
       (lambda (page-count)
         (cmacs-print--write-org
          org-path page-count
          (and (memq 'pdf formats) "source.pdf")
          doc-title)
         (cmacs-print--log "wrote %s (%d pages)" org-path page-count)
         (cmacs-print--cleanup-spool pdf-path)
         (cmacs-print--open org-path))
       (lambda (err)
         (cmacs-print--log "rasterise error: %s" err)
         (message "cmacs-print: %s" err)
         (cmacs-print--cleanup-spool pdf-path))))
     ;; PDF-only (no org).
     ((memq 'pdf formats)
      (cmacs-print--cleanup-spool pdf-path)
      (cmacs-print--open pdf-dst))
     (t
      (cmacs-print--log "no formats selected; nothing to do")))
    org-path))

(defun cmacs-print--cleanup-spool (spool-pdf)
  "Remove SPOOL-PDF if it lives under one of the spool directories.
- System CUPS backend spools to /tmp/cmacs-print-<uid>/.
- Per-user IPP handler spools to $XDG_RUNTIME_DIR/cmacs-print/.
Interactive callers (`M-x') typically pass a PDF path outside any
spool, in which case we leave it alone."
  (when (and (stringp spool-pdf)
             (file-exists-p spool-pdf)
             (string-match-p
              "\\(?:/cmacs-print-[0-9]+/\\|/cmacs-print/\\)"
              spool-pdf))
    (ignore-errors (delete-file spool-pdf))
    (cmacs-print--log "cleaned spool %s" spool-pdf)))

;;;###autoload
(defun cmacs-print-reprocess-inbox ()
  "Process every PDF currently sitting in the inbox dir.
Useful after starting cmacs when prints arrived while it was down —
the CUPS backend's fallback path drops PDFs there."
  (interactive)
  (let* ((inbox (cmacs-print--inbox-dir))
         (pdfs (and (file-directory-p inbox)
                    (directory-files inbox t "\\.pdf\\'"))))
    (cond
     ((null pdfs)
      (message "cmacs-print: inbox is empty"))
     (t
      (dolist (pdf pdfs)
        (cmacs-print-import-pdf pdf)
        ;; Move the inbox PDF aside; cmacs-print-import-pdf has either
        ;; copied it to `<stem>.pdf' (when 'pdf in formats) or rendered
        ;; it (when 'org).  Either way the inbox copy is now redundant.
        (ignore-errors (delete-file pdf)))
      (message "cmacs-print: processed %d inbox PDF(s)" (length pdfs))))))

;; ---------------------------------------------------------------------
;; Spool watcher
;; ---------------------------------------------------------------------
;;
;; The system CUPS backend (cmacs/print/cmacs-print) writes incoming
;; PDFs to /tmp/cmacs-print-<uid>/.  We can't deliver via D-Bus from
;; the cupsd_t SELinux domain (denied by stock refpolicy), and we can't
;; transition to the user via su either — so the backend just drops the
;; file and we pull from here.
;;
;; The backend writes atomically (cat to .tmp.<...>.pdf, then mv to
;; <...>.pdf), so file-notify's `renamed' event fires only after the
;; file is fully on disk.  We additionally tolerate `created' events
;; (different file-notify backends report differently) and recover from
;; missed events with `cmacs-print-drain-spool' on load.

(defvar cmacs-print--watch-descriptor nil
  "file-notify descriptor watching `cmacs-print-spool-dir', or nil.")

(defvar cmacs-print--poll-timer nil
  "Belt-and-suspenders periodic drain timer, or nil.")

(defvar cmacs-print--processed-files (make-hash-table :test 'equal)
  "Filenames already handed to `cmacs-print-import-pdf', as a set.
Prevents double-import when both `created' and `renamed' events fire
for the same file, or when the drain races with the watcher.")

(defun cmacs-print--spool-dir-safe-p (dir)
  "Non-nil when DIR is a directory we own, not a symlink, and private.

The spool lives under /tmp, which anyone on the machine can write to.
Whoever creates /tmp/cmacs-print-<uid> first owns it, so before
watching -- and auto-importing whatever appears there -- check that it
really is ours: a real directory (not a symlink into someone else's
tree), owned by this uid, with no group or world bits.  Anything else
is refused rather than adopted."
  (let ((attrs (file-attributes dir 'integer)))
    (and attrs
         (eq (file-attribute-type attrs) t)          ; a directory, not a symlink
         (not (file-symlink-p dir))
         (eql (file-attribute-user-id attrs) (user-uid))
         (zerop (logand (file-modes dir) #o077)))))

(defun cmacs-print--ensure-spool-dir ()
  "Create `cmacs-print-spool-dir' with mode 0700 if absent.  Returns the path.
The CUPS backend creates this too (with the user as owner via
`install -d -o USER'), but cmacs may start before the first print job
fires the backend, in which case the watcher needs a target to attach to.

Signals an error instead of returning a directory that fails
`cmacs-print--spool-dir-safe-p', so the watcher never attaches to a
path another local user pre-created."
  (let ((dir (expand-file-name cmacs-print-spool-dir)))
    (unless (file-exists-p dir)
      (with-file-modes #o700
        (make-directory dir t)))
    (unless (cmacs-print--spool-dir-safe-p dir)
      (error "cmacs-print: refusing spool directory %s: not a private directory owned by uid %d (symlink, foreign owner, or group/world bits) -- remove it or set `cmacs-print-spool-dir'"
             dir (user-uid)))
    dir))

(defun cmacs-print--spool-pdf-p (path)
  "Return non-nil if PATH is a finished spool PDF (not a .tmp stage)."
  (and (stringp path)
       (string-suffix-p ".pdf" path)
       (not (string-prefix-p "." (file-name-nondirectory path)))))

(defun cmacs-print--title-from-spool-name (path)
  "Recover the original document title from a spool PATH.
The CUPS backend names spool files <TS>-job<ID>-<sanitised-title>.pdf;
strip the <TS>-job<ID>- prefix and the .pdf suffix to get back to
something close to the user-provided title.  Falls back to the bare
basename when the prefix doesn't match."
  (let* ((base (file-name-base (file-name-nondirectory path))))
    (if (string-match
         "\\`[0-9]\\{8\\}-[0-9]\\{6\\}-job[0-9]+-\\(.+\\)\\'"
         base)
        (match-string 1 base)
      base)))

(defun cmacs-print--handle-spool-event (event)
  "file-notify callback: import PDFs that appear in the spool dir."
  ;; EVENT shape: (descriptor action file [target-file]).
  (let* ((action (nth 1 event))
         (file   (nth 2 event))
         (target (nth 3 event))
         ;; For `renamed', the target is the new name we care about.
         (path   (or (and (eq action 'renamed) target) file)))
    (when (and path
               (cmacs-print--spool-pdf-p path)
               (memq action '(created renamed changed))
               (file-readable-p path)
               (not (gethash path cmacs-print--processed-files)))
      (puthash path t cmacs-print--processed-files)
      (cmacs-print--log "spool watcher: %s -> %s" action path)
      ;; Import asynchronously via run-at-time so the file-notify
      ;; callback returns quickly and any subsequent events for the
      ;; same path don't pile up behind a long-running rasterise.
      (let ((title (cmacs-print--title-from-spool-name path)))
        (run-at-time 0 nil
                     (lambda ()
                       (condition-case err
                           (cmacs-print-import-pdf path title)
                         (error
                          (cmacs-print--log
                           "import failed: %s -- %S" path err)))))))))

;;;###autoload
(defun cmacs-print-drain-spool ()
  "Process every finished PDF currently sitting in `cmacs-print-spool-dir'.
Runs once at load time to catch prints that arrived before cmacs
started.  Safe to call any time."
  (interactive)
  (let* ((dir (cmacs-print--ensure-spool-dir))
         (pdfs (cl-remove-if-not
                #'cmacs-print--spool-pdf-p
                (directory-files dir t "\\.pdf\\'"))))
    (dolist (pdf pdfs)
      (unless (gethash pdf cmacs-print--processed-files)
        (puthash pdf t cmacs-print--processed-files)
        (cmacs-print--log "drain: %s" pdf)
        (condition-case err
            (cmacs-print-import-pdf
             pdf (cmacs-print--title-from-spool-name pdf))
          (error
           (cmacs-print--log "drain failed: %s -- %S" pdf err)))))
    (when (called-interactively-p 'interactive)
      (message "cmacs-print: drained %d spool PDF(s)" (length pdfs)))))

;;;###autoload
(defun cmacs-print-start-watcher ()
  "Begin watching `cmacs-print-spool-dir' for new PDFs.
Idempotent.  Called automatically on load when
`cmacs-print-watch-spool' is non-nil.  Also starts a periodic
`cmacs-print-poll-interval' drain as a redundancy net for daemon
mode without an attached frame."
  (interactive)
  (cmacs-print-stop-watcher)
  (let ((dir (cmacs-print--ensure-spool-dir)))
    (setq cmacs-print--watch-descriptor
          (file-notify-add-watch
           dir '(change) #'cmacs-print--handle-spool-event))
    (when (and cmacs-print-poll-interval
               (> cmacs-print-poll-interval 0))
      (setq cmacs-print--poll-timer
            (run-at-time cmacs-print-poll-interval
                         cmacs-print-poll-interval
                         #'cmacs-print-drain-spool)))
    (cmacs-print--log "watching %s (poll every %ss)"
                      dir cmacs-print-poll-interval)
    (cmacs-print-drain-spool)))

(defun cmacs-print-stop-watcher ()
  "Stop watching `cmacs-print-spool-dir' and cancel the poll timer."
  (interactive)
  (when cmacs-print--watch-descriptor
    (file-notify-rm-watch cmacs-print--watch-descriptor)
    (setq cmacs-print--watch-descriptor nil))
  (when cmacs-print--poll-timer
    (cancel-timer cmacs-print--poll-timer)
    (setq cmacs-print--poll-timer nil))
  (cmacs-print--log "watcher stopped"))

;; Auto-start on load when configured.  Wrapped in `with-eval-after-load'
;; to defer until the daemon is past `--daemon' init (where file-notify
;; backends may not yet be available on some setups).
(when cmacs-print-watch-spool
  (if after-init-time
      (cmacs-print-start-watcher)
    (add-hook 'after-init-hook #'cmacs-print-start-watcher)))

(provide 'cmacs-print)
;;; cmacs-print.el ends here
