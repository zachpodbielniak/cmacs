;;; cmacs-secondbrain-ingest-extract.el --- Formats the ingester reads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Everything the second-brain ingester knows about file formats, and
;; nothing about notes, PARA or models.  Each format is turned into one
;; shape, a "document" plist:
;;
;;   :kind       what it was (`pdf', `youtube', `email', ...)
;;   :source     the path or URL it came from
;;   :title      a title if the material carried one
;;   :body       the content as Org markup, headings starting at `*'
;;   :text       the content as plain text, for the model
;;   :meta       an alist of (LABEL . VALUE) worth recording in the note
;;   :extractor  which strategy produced it
;;   :warnings   what went wrong along the way, without being fatal
;;
;; A format is handled by an ordered list of STRATEGIES, tried until one
;; produces a document.  The order is deliberate: cmacs-native readers
;; first (cmacs-office for the six Office formats, libxml + shr for HTML,
;; the embedded whisper for speech), pandoc second (it writes Org
;; natively and never hard-wraps when told not to), and the narrower
;; external tools last.  A strategy whose program is missing is skipped,
;; and when every strategy is skipped the error says which programs would
;; have helped -- which on an immutable host is the useful answer.
;;
;; The old `sbi' shell script handled the same formats with a different
;; philosophy: reach for `markitdown', fall back through pandoc, then
;; distrobox, then `sed s/<[^>]*>//g'.  Two of its habits are
;; deliberately not reproduced.  It hard-wrapped everything, because
;; pandoc does unless asked not to; every conversion here passes
;; `--wrap=none'.  And it downloaded YouTube audio and transcribed it
;; with whisper even when the video had captions; here the captions are
;; asked for first and whisper is the fallback.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dom)
(require 'shr)
(require 'url-parse)
(require 'url-util)
(require 'json)

(declare-function cmacs-office-open "cmacs-office-defuns.c" (path))
(declare-function cmacs-office-close "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-kind "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-metadata "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-blocks "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-sheet-names "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-cells "cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-supported-p "cmacs-office-defuns.c" ())
(declare-function cmacs-office--sheet-rows "cmacs-office" (cells sheet))
(declare-function mm-dissect-buffer "mm-decode" (&optional no-strict-mime loose-mime from))
(declare-function mm-destroy-parts "mm-decode" (handles))
(declare-function mm-handle-media-type "mm-decode" (handle))
(declare-function mm-get-part "mm-decode" (handle &optional no-cache))
(declare-function mm-handle-filename "mm-decode" (handle))
(declare-function mm-handle-media-supertype "mm-decode" (handle))
(declare-function mail-fetch-field "mail-utils" (field-name &optional last all list delete))
(declare-function mail-narrow-to-head "mail-utils" ())
(declare-function mail-decode-encoded-word-string "mail-parse" (string))
(declare-function rfc2047-decode-string "rfc2047" (string &optional address-mime))

(defgroup cmacs-secondbrain-ingest nil
  "Ingest anything -- files, URLs, media, mail, text -- into the second brain."
  :group 'cmacs-secondbrain
  :prefix "cmacs-secondbrain-ingest-")

;;;; External programs ---------------------------------------------------

(defcustom cmacs-secondbrain-ingest-programs
  '((pandoc . "pandoc")
    (pdftotext . "pdftotext")
    (mutool . "mutool")
    (yt-dlp . "yt-dlp")
    (ffmpeg . "ffmpeg")
    (ffprobe . "ffprobe")
    (unzip . "unzip")
    (tar . "tar")
    (msgconvert . "msgconvert")
    (ebook-convert . "ebook-convert")
    (libreoffice . "libreoffice")
    (file . "file"))
  "External programs the extractors may call, as (NAME . EXECUTABLE).

EXECUTABLE is looked up on PATH; give an absolute path to pin one.  A
missing program disables the strategies that need it and nothing else --
the doctor (`cmacs-secondbrain-ingest-doctor') lists what is missing and
what it would have enabled.

Fedora package names, for layering into an image: pandoc, poppler-utils
\(pdftotext), mupdf (mutool), yt-dlp, ffmpeg, unzip, tar, perl-Email-
Outlook-Message (msgconvert).  calibre and LibreOffice are found as
flatpaks too; see `cmacs-secondbrain-ingest-flatpak-apps'."
  :type '(alist :key-type symbol :value-type string)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-flatpak-apps
  '((ebook-convert "com.calibre_ebook.calibre" "ebook-convert")
    (libreoffice "org.libreoffice.LibreOffice" "libreoffice")
    (libreoffice "com.collaboraoffice.Office" "soffice"))
  "Flatpak fallbacks for programs, as (NAME APP-ID COMMAND).

When NAME is not on PATH and APP-ID is installed, the program runs as
`flatpak run --command=COMMAND APP-ID'.  The command differs by
packaging: LibreOffice's flatpak exports `libreoffice', Collabora's
exports `soffice', and using the wrong one fails with a bare execvp
error -- the same trap `cmacs-office-preview' documents."
  :type '(repeat (list symbol string string))
  :group 'cmacs-secondbrain-ingest)

(defvar cmacs-secondbrain-ingest--flatpak-cache (make-hash-table :test 'equal)
  "APP-ID -> t/nil, so `flatpak info' runs once per app per session.")

(defun cmacs-secondbrain-ingest--flatpak-installed-p (app-id)
  "Non-nil when flatpak APP-ID is installed (cached)."
  (let ((cached (gethash app-id cmacs-secondbrain-ingest--flatpak-cache 'unknown)))
    (if (not (eq cached 'unknown))
        cached
      (puthash app-id
               (and (executable-find "flatpak")
                    (eq 0 (ignore-errors
                            (call-process "flatpak" nil nil nil "info" app-id))))
               cmacs-secondbrain-ingest--flatpak-cache))))

(defun cmacs-secondbrain-ingest-tool-command (name)
  "Return the argv prefix that runs program NAME, or nil when unavailable.

A plain program is (\"/path/to/prog\"); a flatpak fallback is the
four-word `flatpak run' prefix.  Callers append their own arguments."
  (let* ((exe (or (cdr (assq name cmacs-secondbrain-ingest-programs))
                  (symbol-name name)))
         (found (executable-find exe)))
    (cond
     (found (list found))
     (t (cl-loop for (n app cmd) in cmacs-secondbrain-ingest-flatpak-apps
                 when (and (eq n name)
                           (cmacs-secondbrain-ingest--flatpak-installed-p app))
                 return (list "flatpak" "run" (concat "--command=" cmd) app))))))

(defun cmacs-secondbrain-ingest-tool-p (name)
  "Non-nil when program NAME can be run."
  (and (cmacs-secondbrain-ingest-tool-command name) t))

(defun cmacs-secondbrain-ingest--run (argv &optional input-file)
  "Run ARGV synchronously; return (EXIT . OUTPUT).
INPUT-FILE, when given, is fed to stdin.  stderr is discarded into the
output only on failure, so a successful conversion is not polluted by a
tool's chatter."
  (with-temp-buffer
    (let* ((err-file (make-temp-file "cmacs-sbi-err-"))
           (code (condition-case e
                     (apply #'call-process (car argv) input-file
                            (list (current-buffer) err-file) nil (cdr argv))
                   (error (insert (error-message-string e)) 1)))
           (out (buffer-string)))
      (when (and (not (eq code 0)) (file-exists-p err-file))
        (setq out (concat out
                          (with-temp-buffer
                            (insert-file-contents err-file)
                            (buffer-string)))))
      (ignore-errors (delete-file err-file))
      (cons code out))))

;;;; Classification ------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-extension-kinds
  '(("org" . org)
    ("md" . markdown) ("markdown" . markdown) ("mdown" . markdown) ("mkd" . markdown)
    ("txt" . text) ("text" . text) ("rst" . rst) ("adoc" . asciidoc) ("asciidoc" . asciidoc)
    ("tex" . latex) ("latex" . latex) ("rtf" . rtf)
    ("html" . html) ("htm" . html) ("xhtml" . html) ("mhtml" . html)
    ("pdf" . pdf)
    ("epub" . ebook) ("mobi" . ebook) ("azw" . ebook) ("azw3" . ebook) ("fb2" . ebook)
    ("docx" . office) ("odt" . office) ("pptx" . office) ("odp" . office)
    ("xlsx" . office) ("ods" . office)
    ("doc" . office-legacy) ("xls" . office-legacy) ("ppt" . office-legacy)
    ("xlsm" . office) ("xlsb" . office-legacy) ("xltx" . office) ("xltm" . office)
    ("csv" . data) ("tsv" . data) ("json" . data) ("jsonl" . data) ("xml" . data)
    ("yaml" . data) ("yml" . data) ("toml" . data)
    ("eml" . email) ("msg" . email) ("mbox" . email)
    ("mp3" . audio) ("wav" . audio) ("ogg" . audio) ("oga" . audio) ("flac" . audio)
    ("m4a" . audio) ("aac" . audio) ("wma" . audio) ("opus" . audio) ("ape" . audio)
    ("mp4" . video) ("mkv" . video) ("avi" . video) ("mov" . video) ("wmv" . video)
    ("flv" . video) ("webm" . video) ("m4v" . video) ("mpg" . video) ("mpeg" . video)
    ("ts" . video) ("m2ts" . video) ("3gp" . video)
    ("zip" . archive) ("tar" . archive) ("tgz" . archive) ("gz" . archive))
  "File extension (lowercase, no dot) -> content kind."
  :type '(alist :key-type string :value-type symbol)
  :group 'cmacs-secondbrain-ingest)

(defconst cmacs-secondbrain-ingest-kinds
  '(url youtube org markdown text rst asciidoc latex rtf html pdf ebook
        office office-legacy data email audio video archive site-export crawl)
  "Every content kind the ingester distinguishes.")

(defun cmacs-secondbrain-ingest-url-p (string)
  "Non-nil when STRING is an http(s) URL."
  (and (stringp string)
       (string-match-p "\\`https?://[^[:space:]]+\\'" (string-trim string))))

(defcustom cmacs-secondbrain-ingest-youtube-regexp
  "\\`https?://\\(?:www\\.\\|m\\.\\|music\\.\\)?\\(?:youtube\\.com/\\(?:watch\\|shorts/\\|live/\\|embed/\\|v/\\)\\|youtu\\.be/\\)"
  "URLs matching this are treated as YouTube videos."
  :type 'regexp
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-youtube-url-p (url)
  "Non-nil when URL is a YouTube video (watch, shorts, live, embed, youtu.be)."
  (and (stringp url)
       (string-match-p cmacs-secondbrain-ingest-youtube-regexp (string-trim url))))

(defun cmacs-secondbrain-ingest--magic-kind (file)
  "Guess FILE's kind from its first bytes; nil when nothing is recognised."
  (when (and (file-readable-p file) (file-regular-p file))
    (let ((head (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally file nil 0 4096)
                  (buffer-string))))
      (cond
       ((string-prefix-p "%PDF" head) 'pdf)
       ((string-prefix-p "PK\003\004" head)
        ;; A zip: Office and EPUB both are.  The first member of an EPUB
        ;; is `mimetype'; an OOXML package starts with [Content_Types].
        (cond ((string-match-p "mimetypeapplication/epub" head) 'ebook)
              ((string-match-p "\\[Content_Types\\]\\|word/\\|xl/\\|ppt/" head) 'office)
              ((string-match-p "mimetypeapplication/vnd\\.oasis" head) 'office)
              (t 'archive)))
       ((string-match-p "\\`\\(?:\\(?:%PDF\\)\\|\\(?:ID3\\)\\|\\(?:OggS\\)\\|\\(?:fLaC\\)\\|\\(?:RIFF....WAVE\\)\\)" head)
        (if (string-prefix-p "%PDF" head) 'pdf 'audio))
       ((string-match-p "\\`\\(?:\032E\337\243\\|....ftyp\\)" head) 'video)
       ((string-match-p "\\`[ \t\n]*\\(?:<!DOCTYPE html\\|<html\\|<HTML\\)" head) 'html)
       ((string-match-p "\\`\\(?:From \\|\\(?:[A-Za-z-]+: .*\n\\)\\{2,\\}\\)" head)
        (and (string-match-p "^\\(?:From\\|Subject\\|Received\\|Message-ID\\): " head) 'email))
       ((string-match-p "\\`[ \t\n]*\\(?:#\\+\\(?:title\\|TITLE\\):\\|:PROPERTIES:\\|\\* \\)" head) 'org)
       ((string-match-p "\\`[ \t\n]*[{[]" head) 'data)
       ((string-match-p "\\`[ \t\n]*<\\?xml" head) 'data)
       ((string-match-p "\\`\\(?:\\`\\|\n\\)#\\{1,6\\} \\|^```" head) 'markdown)
       ((string-match-p "\\`WEBVTT" head) 'text)
       (t nil)))))

(defun cmacs-secondbrain-ingest-classify (input &optional format)
  "Classify INPUT, a path or URL, as a content kind.

Returns a plist (:kind KIND :input INPUT :url-p BOOL).  FORMAT, when
given, is a kind symbol or extension string that overrides detection --
this is how stdin text arrives with `--format markdown'.  A file with no
recognised extension is sniffed by its first bytes, and anything still
unknown is treated as `text' if it decodes as text, else signals."
  (let ((in (string-trim input)))
    (cond
     ((cmacs-secondbrain-ingest-url-p in)
      (list :kind (if (cmacs-secondbrain-ingest-youtube-url-p in) 'youtube 'url)
            :input in :url-p t))
     (format
      (let ((kind (if (symbolp format) format
                    (or (cdr (assoc (downcase (string-remove-prefix "." format))
                                    cmacs-secondbrain-ingest-extension-kinds))
                        'text))))
        (list :kind kind :input in :url-p nil)))
     (t
      (let* ((file (expand-file-name in))
             (ext (downcase (or (file-name-extension file) "")))
             (kind (cdr (assoc ext cmacs-secondbrain-ingest-extension-kinds))))
        ;; A `gz' or `ts' is ambiguous by name; let the bytes decide when
        ;; they can.
        (when (or (null kind) (memq kind '(archive)) (equal ext "ts"))
          (setq kind (or (cmacs-secondbrain-ingest--magic-kind file) kind)))
        (unless kind
          (setq kind (if (cmacs-secondbrain-ingest--text-file-p file) 'text 'unknown)))
        (list :kind kind :input file :url-p nil))))))

(defun cmacs-secondbrain-ingest--text-file-p (file)
  "Non-nil when FILE's first 4 KiB contains no NUL byte."
  (and (file-readable-p file)
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (insert-file-contents-literally file nil 0 4096)
         (not (string-match-p "\0" (buffer-string))))))

;;;; JSON ---------------------------------------------------------------------

(defun cmacs-secondbrain-ingest-json-parse (string)
  "Parse JSON STRING into hash tables and lists, or return nil.
Objects are hash tables keyed by string, arrays lists, null and false nil."
  (and (stringp string)
       (ignore-errors
         (json-parse-string string :object-type 'hash-table :array-type 'list
                            :null-object nil :false-object nil))))

(defun cmacs-secondbrain-ingest-json-get (obj &rest keys)
  "Walk OBJ (from `cmacs-secondbrain-ingest-json-parse') through KEYS."
  (let ((cur obj))
    (dolist (k keys)
      (setq cur (and (hash-table-p cur) (gethash k cur))))
    cur))

;;;; Text helpers ---------------------------------------------------------

(defun cmacs-secondbrain-ingest-slugify (string &optional max)
  "Return STRING as a filename slug: lowercase, [a-z0-9_], at most MAX chars.

The rules of the notes repository: underscores, never spaces or hyphens
in the body of a name.  Accents are stripped rather than dropped so
\"Café\" becomes \"cafe\"."
  (let* ((s (downcase (or string "")))
         (s (replace-regexp-in-string "[àáâãäå]" "a" s))
         (s (replace-regexp-in-string "[èéêë]" "e" s))
         (s (replace-regexp-in-string "[ìíîï]" "i" s))
         (s (replace-regexp-in-string "[òóôõöø]" "o" s))
         (s (replace-regexp-in-string "[ùúûü]" "u" s))
         (s (replace-regexp-in-string "[ýÿ]" "y" s))
         (s (replace-regexp-in-string "[çñß]" (lambda (m) (pcase m ("ç" "c") ("ñ" "n") (_ "ss"))) s))
         (s (replace-regexp-in-string "['’`\"]" "" s))
         (s (replace-regexp-in-string "[^a-z0-9]+" "_" s))
         (s (replace-regexp-in-string "_+" "_" s))
         (s (string-trim s "_+" "_+")))
    (when (and max (> (length s) max))
      (setq s (substring s 0 max))
      (setq s (string-trim s "_+" "_+")))
    (if (string-empty-p s) "untitled" s)))

(defun cmacs-secondbrain-ingest-filename-from-url (url)
  "Return a slug for URL: its last path component, or the host for a bare domain.

\"https://example.com/blog/how-to-x.html?a=1\" -> \"how_to_x\";
\"https://example.com/\" -> \"example_com\"."
  (let* ((u (url-generic-parse-url url))
         (host (or (url-host u) ""))
         (path (or (car (url-path-and-query u)) ""))
         (path (string-trim path "/+" "/+"))
         (last (car (last (split-string path "/" t)))))
    (when last
      (setq last (replace-regexp-in-string "\\.\\(?:x?html?\\|php\\|aspx?\\)\\'" "" last)))
    (cmacs-secondbrain-ingest-slugify
     (if (or (null last) (string-empty-p last)
             (member last '("index" "default" "home")))
         (string-remove-prefix "www." host)
       last)
     80)))

(defun cmacs-secondbrain-ingest-demote (org-text &optional levels)
  "Demote every Org heading in ORG-TEXT by LEVELS (default 1).
Content bodies are written with `*' as their top level and nest under
the note's own `* Content' heading."
  (let ((stars (make-string (or levels 1) ?*)))
    (replace-regexp-in-string "^\\(\\*+\\) " (concat stars "\\1 ") (or org-text ""))))

(defun cmacs-secondbrain-ingest-strip-custom-ids (org-text)
  "Remove the :CUSTOM_ID: property drawers pandoc puts under every heading.
They carry nothing the note needs and double the length of a table of
contents."
  (replace-regexp-in-string
   "^[ \t]*:PROPERTIES:\n\\(?:[ \t]*:CUSTOM_ID:[^\n]*\n\\)+[ \t]*:END:\n?" ""
   (or org-text "")))

(defun cmacs-secondbrain-ingest-strip-org-header (org-text)
  "Return (KEYWORDS . BODY) for ORG-TEXT.

KEYWORDS is an alist of the file-level `#+key: value' lines and the top
property drawer's `:ID:' (as (\"id\" . VALUE)); BODY is the text after
them.  The note writer supplies its own header, so an ingested Org file's
is read for its title and then replaced."
  (let ((keywords nil) (pos 0) (text (or org-text "")))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (catch 'body
        (while (not (eobp))
          (cond
           ((looking-at "^[ \t]*:PROPERTIES:[ \t]*\n")
            (let ((start (point)))
              (if (re-search-forward "^[ \t]*:END:[ \t]*\n?" nil t)
                  (let ((drawer (buffer-substring start (point))))
                    (when (string-match ":ID:[ \t]+\\([^\n]+\\)" drawer)
                      (push (cons "id" (string-trim (match-string 1 drawer))) keywords)))
                (throw 'body nil))))
           ((looking-at "^#\\+\\([A-Za-z_]+\\):[ \t]*\\(.*\\)$")
            (push (cons (downcase (match-string 1)) (string-trim (match-string 2))) keywords)
            (forward-line 1))
           ((looking-at "^[ \t]*$") (forward-line 1))
           (t (throw 'body nil))))
        nil)
      (setq pos (point)))
    (cons (nreverse keywords) (string-trim-left (substring text (1- pos))))))

(defun cmacs-secondbrain-ingest-org-text (org-text)
  "Return ORG-TEXT reduced to plain text for a model: no drawers, no keywords."
  (let ((s (or org-text "")))
    (setq s (replace-regexp-in-string "^[ \t]*:PROPERTIES:\n\\(?:.*\n\\)*?[ \t]*:END:\n?" "" s))
    (setq s (replace-regexp-in-string "^#\\+[A-Za-z_]+:.*\n" "" s))
    (setq s (replace-regexp-in-string "\\[\\[[^]]*\\]\\[\\([^]]*\\)\\]\\]" "\\1" s))
    (setq s (replace-regexp-in-string "^\\*+ " "" s))
    (string-trim s)))

(defun cmacs-secondbrain-ingest-paragraphs->org (text)
  "Turn plain TEXT into one-line Org paragraphs.

Blank lines separate paragraphs; the lines inside a paragraph are joined
with spaces, because a PDF or a transcript arrives wrapped at whatever
width its producer liked and the notes repository writes one paragraph
per line.  Lines that look like list items keep their breaks."
  (let ((out nil))
    (dolist (para (split-string (or text "") "\n[ \t]*\n+" t))
      (let ((lines (split-string para "\n" t "[ \t]+")))
        (if (cl-some (lambda (l) (string-match-p "\\`\\(?:[-*+•] \\|[0-9]+[.)] \\)" l)) lines)
            (push (string-join lines "\n") out)
          (push (string-join lines " ") out))))
    (string-join (nreverse out) "\n\n")))

(defun cmacs-secondbrain-ingest-looks-like-prose-p (text)
  "Non-nil when TEXT reads as prose rather than code or a log.
Prose has long lines that end in punctuation; a log has short lines and
a lot of digits and symbols."
  (let* ((lines (seq-filter (lambda (l) (not (string-blank-p l)))
                            (split-string (or text "") "\n")))
         (n (max 1 (length lines)))
         (long (cl-count-if (lambda (l) (> (length l) 60)) lines))
         (punct (cl-count-if (lambda (l) (string-match-p "[.!?:]\\s-*\\'" l)) lines))
         (symbolic (cl-count-if (lambda (l) (string-match-p "\\`[ \t]*[{}<>#$/\\[|=;]\\|[{};]\\s-*\\'" l))
                                lines)))
    (and (> (/ (float (+ long punct)) n) 0.4)
         (< (/ (float symbolic) n) 0.2))))

(defun cmacs-secondbrain-ingest-src-block (lang text)
  "Wrap TEXT in an Org source block for LANG, escaping stray block delimiters."
  (format "#+begin_src %s\n%s\n#+end_src"
          (or lang "text")
          (replace-regexp-in-string "^\\(\\s-*\\)\\(#\\+\\(?:begin\\|end\\)_\\)" "\\1,\\2"
                                    (string-trim-right (or text "")))))

;;;; Markdown -> Org (the no-pandoc fallback) ----------------------------

(defun cmacs-secondbrain-ingest-markdown->org (markdown)
  "Convert MARKDOWN to Org without pandoc.

Handles what appears in notes and READMEs: headings, fenced and inline
code, emphasis, links and images, block quotes, rules, lists, task boxes,
strike-through and pipe tables.  Pandoc does this better and is preferred
when installed; this exists so a missing pandoc downgrades the result
rather than the ingest."
  (let ((lines (split-string (or markdown "") "\n"))
        (out nil) (in-fence nil) (in-quote nil) (fence-lang nil))
    (cl-flet ((close-quote ()
                (when in-quote (push "#+end_quote" out) (setq in-quote nil))))
      (dolist (line lines)
        (cond
         ;; Fences.
         ((and (not in-fence) (string-match "\\`[ \t]*\\(?:```\\|~~~\\)[ \t]*\\([A-Za-z0-9_+-]*\\)" line))
          (close-quote)
          (setq in-fence t fence-lang (match-string 1 line))
          (push (format "#+begin_src %s" (if (string-empty-p fence-lang) "text" fence-lang)) out))
         ((and in-fence (string-match-p "\\`[ \t]*\\(?:```\\|~~~\\)[ \t]*\\'" line))
          (setq in-fence nil)
          (push "#+end_src" out))
         (in-fence
          (push (replace-regexp-in-string "^\\(\\s-*\\)\\(#\\+\\)" "\\1,\\2" line) out))
         ;; Block quotes.
         ((string-match "\\`>[ ]?\\(.*\\)\\'" line)
          (unless in-quote (push "#+begin_quote" out) (setq in-quote t))
          (push (cmacs-secondbrain-ingest--md-inline (match-string 1 line)) out))
         (t
          (close-quote)
          (cond
           ;; Headings.
           ((string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t#]*\\'" line)
            (push (concat (make-string (length (match-string 1 line)) ?*) " "
                          (cmacs-secondbrain-ingest--md-inline (match-string 2 line)))
                  out))
           ;; Setext headings are handled by the following line.
           ((and out (string-match-p "\\`=\\{3,\\}[ \t]*\\'" line)
                 (not (string-blank-p (car out)))
                 (not (string-prefix-p "*" (car out))))
            (setcar out (concat "* " (car out))))
           ((and out (string-match-p "\\`-\\{3,\\}[ \t]*\\'" line)
                 (not (string-blank-p (car out)))
                 (not (string-prefix-p "*" (car out)))
                 (not (string-prefix-p "|" (car out))))
            (setcar out (concat "** " (car out))))
           ;; Rules.
           ((string-match-p "\\`[ \t]*\\(?:\\*[ \t]*\\)\\{3,\\}\\'\\|\\`[ \t]*\\(?:-[ \t]*\\)\\{3,\\}\\'\\|\\`[ \t]*\\(?:_[ \t]*\\)\\{3,\\}\\'" line)
            (push "-----" out))
           ;; Table separator rows.
           ((string-match-p "\\`[ \t]*|?[ \t:-]*-[ \t:|-]*\\'" line)
            (when (string-match-p "|" line)
              (push (concat "|" (mapconcat (lambda (_) "---")
                                           (split-string (string-trim line "|" "|") "|")
                                           "+")
                            "|")
                    out)))
           ;; Task boxes and bullets.
           ((string-match "\\`\\([ \t]*\\)[-*+][ \t]+\\[\\([ xX]\\)\\][ \t]+\\(.*\\)\\'" line)
            (push (format "%s- [%s] %s" (match-string 1 line)
                          (if (equal (match-string 2 line) " ") " " "X")
                          (cmacs-secondbrain-ingest--md-inline (match-string 3 line)))
                  out))
           ((string-match "\\`\\([ \t]*\\)[*+][ \t]+\\(.*\\)\\'" line)
            (push (format "%s- %s" (match-string 1 line)
                          (cmacs-secondbrain-ingest--md-inline (match-string 2 line)))
                  out))
           (t (push (cmacs-secondbrain-ingest--md-inline line) out))))))
      (close-quote)
      (when in-fence (push "#+end_src" out)))
    (string-join (nreverse out) "\n")))

(defun cmacs-secondbrain-ingest--md-inline (line)
  "Convert Markdown inline markup in LINE to Org."
  (let ((s line) (saved nil))
    (cl-flet ((stash (text)
                (push text saved)
                (format "\0%d\0" (1- (length saved)))))
      ;; Protect inline code first: nothing inside it is markup.
      (setq s (replace-regexp-in-string
               "`\\([^`\n]+\\)`"
               (lambda (m) (stash (concat "~" (match-string 1 m) "~")))
               s t t))
      (setq s (replace-regexp-in-string "!\\[\\([^]]*\\)\\](\\([^) ]+\\)[^)]*)" "[[\\2]]" s))
      (setq s (replace-regexp-in-string "\\[\\([^]]+\\)\\](\\([^) ]+\\)[^)]*)" "[[\\2][\\1]]" s))
      ;; Bold is stashed as Org bold before italics run, or `*x*' would be
      ;; read as Markdown italics on the second pass.
      (setq s (replace-regexp-in-string
               "\\*\\*\\([^*\n]+\\)\\*\\*"
               (lambda (m) (stash (concat "*" (match-string 1 m) "*"))) s t t))
      (setq s (replace-regexp-in-string
               "__\\([^_\n]+\\)__"
               (lambda (m) (stash (concat "*" (match-string 1 m) "*"))) s t t))
      (setq s (replace-regexp-in-string "~~\\([^~\n]+\\)~~" "+\\1+" s))
      ;; Italics only when word-bounded, so snake_case identifiers survive.
      (setq s (replace-regexp-in-string
               "\\(\\`\\|[ (]\\)_\\([^_\n]+\\)_\\(\\'\\|[ ).,;:!?]\\)" "\\1/\\2/\\3" s))
      (setq s (replace-regexp-in-string
               "\\(\\`\\|[ (]\\)\\*\\([^*\n]+\\)\\*\\(\\'\\|[ ).,;:!?]\\)" "\\1/\\2/\\3" s))
      ;; Restore.
      (let ((i 0))
        (dolist (c (nreverse saved))
          (setq s (replace-regexp-in-string (format "\0%d\0" i) c s t t))
          (cl-incf i))))
    s))

;;;; Tabular data --------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-table-max-rows 200
  "Rows beyond which a CSV is stored as a source block rather than a table.
An Org table with thousands of rows is unreadable and slow to align;
past this the first rows are shown as a table and the rest kept verbatim."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest--csv-delimiter (text)
  "Guess the delimiter of TEXT: the candidate splitting the header most."
  (let ((head (car (split-string text "\n" t))))
    (car (seq-sort-by (lambda (d) (- (length (split-string head (regexp-quote d)))))
                      #'<
                      (list "," "\t" ";" "|")))))

(defun cmacs-secondbrain-ingest-parse-csv (text &optional delimiter)
  "Parse CSV TEXT into a list of rows, each a list of field strings.
Quoted fields may contain the delimiter, doubled quotes and newlines."
  (let* ((delim (or delimiter (cmacs-secondbrain-ingest--csv-delimiter text)))
         (dch (aref delim 0))
         (rows nil) (row nil) (field nil) (i 0) (n (length text)) (quoted nil))
    (while (< i n)
      (let ((c (aref text i)))
        (cond
         (quoted
          (cond ((and (eq c ?\") (< (1+ i) n) (eq (aref text (1+ i)) ?\"))
                 (push ?\" field) (cl-incf i))
                ((eq c ?\") (setq quoted nil))
                (t (push c field))))
         ((eq c ?\") (setq quoted t))
         ((eq c dch) (push (concat (nreverse field)) row) (setq field nil))
         ((eq c ?\n)
          (push (concat (nreverse field)) row)
          (push (nreverse row) rows)
          (setq row nil field nil))
         ((eq c ?\r) nil)
         (t (push c field))))
      (cl-incf i))
    (when (or field row)
      (push (concat (nreverse field)) row)
      (push (nreverse row) rows))
    (nreverse (seq-remove (lambda (r) (and (= (length r) 1) (string-empty-p (car r)))) rows))))

(defun cmacs-secondbrain-ingest-rows->org-table (rows &optional header)
  "Render ROWS (lists of strings) as an Org table.
With HEADER non-nil the first row is separated from the rest by a rule.
Pipes inside cells are escaped as \\vert{}; newlines become spaces."
  (let ((cell (lambda (s)
                (replace-regexp-in-string
                 "|" "\\\\vert{}"
                 (replace-regexp-in-string "[\n\r]+" " " (string-trim (or s "")))))))
    (string-join
     (cl-loop for row in rows
              for i from 0
              collect (concat "| " (mapconcat cell row " | ") " |")
              when (and header (= i 0) (cdr rows))
              collect (concat "|" (mapconcat (lambda (_) "---") row "+") "|"))
     "\n")))

(defun cmacs-secondbrain-ingest-data->org (text ext)
  "Render data TEXT of type EXT (csv, json, xml, yaml, toml, ...) as Org."
  (pcase (downcase (or ext ""))
    ((or "csv" "tsv")
     (let* ((rows (cmacs-secondbrain-ingest-parse-csv
                   text (and (equal (downcase ext) "tsv") "\t")))
            (n (length rows)))
       (if (<= n cmacs-secondbrain-ingest-table-max-rows)
           (cmacs-secondbrain-ingest-rows->org-table rows t)
         (concat (cmacs-secondbrain-ingest-rows->org-table
                  (seq-take rows cmacs-secondbrain-ingest-table-max-rows) t)
                 (format "\n\n%d more rows follow verbatim.\n\n" (- n cmacs-secondbrain-ingest-table-max-rows))
                 (cmacs-secondbrain-ingest-src-block ext text)))))
    ((or "json" "jsonl")
     (cmacs-secondbrain-ingest-src-block
      "json"
      (or (ignore-errors
            (with-temp-buffer
              (insert text)
              (json-pretty-print-buffer)
              (buffer-string)))
          text)))
    ((or "yaml" "yml") (cmacs-secondbrain-ingest-src-block "yaml" text))
    ("toml" (cmacs-secondbrain-ingest-src-block "toml" text))
    ("xml" (cmacs-secondbrain-ingest-src-block "xml" text))
    (_ (cmacs-secondbrain-ingest-src-block ext text))))

;;;; Pandoc --------------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-pandoc-args '("--wrap=none")
  "Extra arguments for every pandoc conversion.
`--wrap=none' is the whole reason pandoc is usable here: the notes are
written one paragraph per line, and pandoc's default wraps at 72."
  :type '(repeat string)
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-pandoc (from &optional file text)
  "Convert FILE, or TEXT on stdin, from format FROM to Org with pandoc.
Returns the Org string, cleaned of CUSTOM_ID drawers and leading
metadata keywords, or signals when pandoc is missing or fails."
  (let ((cmd (cmacs-secondbrain-ingest-tool-command 'pandoc)))
    (unless cmd (error "pandoc is not installed"))
    (let* ((tmp (and text (not file)
                     (let ((f (make-temp-file "cmacs-sbi-pandoc-")))
                       (with-temp-file f (insert text)) f)))
           (res (cmacs-secondbrain-ingest--run
                 (append cmd (list "-f" from "-t" "org")
                         cmacs-secondbrain-ingest-pandoc-args
                         (list (or file tmp))))))
      (when tmp (ignore-errors (delete-file tmp)))
      (unless (eq (car res) 0)
        (error "pandoc failed (%s): %s" (car res) (string-trim (cdr res))))
      (let ((org (cmacs-secondbrain-ingest-strip-custom-ids (cdr res))))
        ;; pandoc emits a metadata block of #+keyword lines for docx and
        ;; epub; the note writer has its own.
        (setq org (replace-regexp-in-string "\\`\\(?:#\\+[A-Za-z_]+:.*\n\\|[ \t]*\n\\)+" "" org))
        ;; HTML ids become <<targets>>; a page has hundreds and nothing
        ;; links to them.
        (setq org (replace-regexp-in-string
                   "^[ \t]*<<[^>\n]+>>[ \t]*\n\(?:[ \t]*\n\)?" "" org))
        (setq org (replace-regexp-in-string "\n\{3,\}" "\n\n" org))
        (string-trim org)))))

;;;; HTML ----------------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-html-strip-tags
  '(script style noscript template nav header footer aside form iframe
           svg canvas button input select textarea object embed video audio
           menu dialog)
  "Elements removed from a page before its content is read."
  :type '(repeat symbol)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-html-strip-regexp
  "\\(?:^\\|[ _-]\\)\\(?:nav\\|menu\\|sidebar\\|footer\\|header\\|comments?\\|share\\|sharing\\|social\\|cookie\\|banner\\|advert\\|ads?\\|promo\\|related\\|subscribe\\|newsletter\\|breadcrumbs?\\|popup\\|modal\\|toolbar\\|widget\\|recommend\\)\\(?:$\\|[ _-]\\)"
  "Elements whose class or id matches this are removed as page chrome.
Applied case-insensitively, and never to the element chosen as the
article itself."
  :type 'regexp
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest--dom-meta (dom name-or-prop)
  "Return the content of the first <meta> in DOM named NAME-OR-PROP.
Both the `name' and the `property' attributes are checked."
  (cl-loop for m in (dom-by-tag dom 'meta)
           when (or (equal (dom-attr m 'property) name-or-prop)
                    (equal (dom-attr m 'name) name-or-prop))
           return (let ((c (dom-attr m 'content)))
                    (and c (not (string-blank-p c)) (string-trim c)))))

(defun cmacs-secondbrain-ingest--dom-text (node)
  "Return the text under NODE, on whichever dom.el this Emacs has."
  (or (ignore-errors
        (if (fboundp 'dom-inner-text)
            (dom-inner-text node)
          (with-no-warnings (dom-texts node " "))))
      ""))

(defun cmacs-secondbrain-ingest--dom-text-length (node)
  "Approximate visible text length of NODE."
  (length (replace-regexp-in-string "[ \t\n]+" " "
                                    (cmacs-secondbrain-ingest--dom-text node))))

(defun cmacs-secondbrain-ingest--dom-strip (dom keep)
  "Destructively remove chrome from DOM, never removing KEEP.
Returns DOM."
  (let ((victims nil)
        (case-fold-search t))
    (cl-labels ((walk (node)
                  (when (and (consp node) (symbolp (car node)))
                    (let ((tag (dom-tag node))
                          (cls (concat (or (dom-attr node 'class) "") " "
                                       (or (dom-attr node 'id) "")))
                          (role (or (dom-attr node 'role) "")))
                      (if (and (not (eq node keep))
                               (or (memq tag cmacs-secondbrain-ingest-html-strip-tags)
                                   (member role '("navigation" "banner" "contentinfo"
                                                  "complementary" "dialog" "search"))
                                   (and (not (string-blank-p cls))
                                        (not (memq tag '(html body main article)))
                                        (string-match-p cmacs-secondbrain-ingest-html-strip-regexp cls))))
                          (push node victims)
                        (dolist (child (dom-children node))
                          (walk child)))))))
      (walk dom))
    (dolist (v victims)
      (ignore-errors (dom-remove-node dom v)))
    dom))

(defun cmacs-secondbrain-ingest--dom-main (dom)
  "Return the node in DOM most likely to be the article, else the body."
  (let* ((body (or (car (dom-by-tag dom 'body)) dom))
         (candidates (append (dom-by-tag dom 'article)
                             (dom-by-tag dom 'main)
                             (cl-loop for n in (dom-search dom (lambda (n) (and (consp n) (dom-attr n 'role))))
                                      when (equal (dom-attr n 'role) "main") collect n)
                             (cl-loop for n in (dom-search
                                                dom (lambda (n)
                                                      (and (consp n) (symbolp (car n))
                                                           (let ((id (or (dom-attr n 'id) ""))
                                                                 (cls (or (dom-attr n 'class) "")))
                                                             (string-match-p
                                                              "\\`\\(?:content\\|main-content\\|post\\|entry\\|article\\|story\\)\\(?:-body\\|-content\\|__body\\)?\\'"
                                                              (concat id " " cls))))))
                                      collect n)))
         (best nil) (best-len 0)
         (body-len (cmacs-secondbrain-ingest--dom-text-length body)))
    (dolist (c candidates)
      (let ((len (cmacs-secondbrain-ingest--dom-text-length c)))
        (when (> len best-len) (setq best c best-len len))))
    ;; A candidate has to hold a real share of the page; a 200-character
    ;; <article> on a 20 000-character page is a teaser, not the article.
    (if (and best (> best-len 200) (> (* best-len 4) body-len))
        best
      body)))

(defun cmacs-secondbrain-ingest--dom->text (node)
  "Return the readable text of NODE with paragraphs separated by blank lines."
  (let ((text (with-temp-buffer
                (let ((shr-width 100000) (shr-use-fonts nil) (shr-inhibit-images t)
                      (shr-external-rendering-functions nil))
                  (ignore-errors (shr-insert-document node)))
                (buffer-substring-no-properties (point-min) (point-max)))))
    (setq text (replace-regexp-in-string "[ \t]+\n" "\n" text))
    (setq text (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text))
    (string-trim text)))

(defun cmacs-secondbrain-ingest--dom->html (node)
  "Serialise NODE back to an HTML string."
  (with-temp-buffer
    (dom-print node)
    (buffer-string)))

(defun cmacs-secondbrain-ingest-html-saved-from (html)
  "Return the URL a SingleFile/browser-saved HTML was saved from, or nil."
  (when (stringp html)
    (cond
     ((string-match "<!--[ \t]*saved from url=([0-9]+)\\([^ \t>]+\\)" html)
      (match-string 1 html))
     ((string-match "<!--[^>]*?\\burl:[ \t]*\\(https?://[^ \t\n>]+\\)" html)
      (match-string 1 html)))))

(defun cmacs-secondbrain-ingest-html->doc (html &optional base-url source)
  "Read an HTML page into a document plist.

HTML is the page as a string, BASE-URL the URL it was fetched from (used
for the metadata and for resolving links), SOURCE what to record as the
document's source.  The article is found heuristically, the page chrome
removed, and the result converted with pandoc when available and shr
otherwise."
  (let* ((dom (with-temp-buffer
                (insert (or html ""))
                (libxml-parse-html-region (point-min) (point-max) nil)))
         (title (or (cmacs-secondbrain-ingest--dom-meta dom "og:title")
                    (let ((tt (car (dom-by-tag dom 'title))))
                      (and tt (string-trim (cmacs-secondbrain-ingest--dom-text tt))))))
         (description (or (cmacs-secondbrain-ingest--dom-meta dom "og:description")
                          (cmacs-secondbrain-ingest--dom-meta dom "description")))
         (author (or (cmacs-secondbrain-ingest--dom-meta dom "author")
                     (cmacs-secondbrain-ingest--dom-meta dom "article:author")))
         (published (or (cmacs-secondbrain-ingest--dom-meta dom "article:published_time")
                        (cmacs-secondbrain-ingest--dom-meta dom "date")
                        (cmacs-secondbrain-ingest--dom-meta dom "datePublished")))
         (site (cmacs-secondbrain-ingest--dom-meta dom "og:site_name"))
         (canonical (or (cl-loop for l in (dom-by-tag dom 'link)
                                 when (equal (dom-attr l 'rel) "canonical")
                                 return (dom-attr l 'href))
                        (cmacs-secondbrain-ingest--dom-meta dom "og:url")))
         (main (cmacs-secondbrain-ingest--dom-main dom))
         (_ (cmacs-secondbrain-ingest--dom-strip dom main))
         (text (cmacs-secondbrain-ingest--dom->text main))
         (warnings nil)
         (body (if (cmacs-secondbrain-ingest-tool-p 'pandoc)
                   (condition-case err
                       (cmacs-secondbrain-ingest-pandoc
                        "html" nil (cmacs-secondbrain-ingest--dom->html main))
                     (error (push (format "pandoc: %s" (error-message-string err)) warnings)
                            (cmacs-secondbrain-ingest-paragraphs->org text)))
                 (push "pandoc not installed: page converted with shr (text only)" warnings)
                 (cmacs-secondbrain-ingest-paragraphs->org text))))
    (when (equal title "") (setq title nil))
    (list :kind 'url
          :source (or source base-url)
          :title title
          :body body
          :text (if (string-empty-p text) (cmacs-secondbrain-ingest-org-text body) text)
          :meta (delq nil
                      (list (and (or base-url source) (cons "URL" (or base-url source)))
                            (and canonical (not (equal canonical base-url))
                                 (cons "Canonical" canonical))
                            (and site (cons "Site" site))
                            (and author (cons "Author" author))
                            (and published (cons "Published" published))
                            (and description (cons "Description" description))))
          :description description
          :extractor (if (cmacs-secondbrain-ingest-tool-p 'pandoc) 'libxml+pandoc 'libxml+shr)
          :warnings warnings)))

(defun cmacs-secondbrain-ingest-html-links (html base-url)
  "Return the absolute http(s) URLs linked from HTML, resolved against BASE-URL.
Fragments are dropped and duplicates removed; used by the crawler."
  (let* ((dom (with-temp-buffer
                (insert (or html ""))
                (libxml-parse-html-region (point-min) (point-max) nil)))
         (out nil))
    (dolist (a (dom-by-tag dom 'a))
      (let ((href (dom-attr a 'href)))
        (when (and href (not (string-prefix-p "#" href))
                   (not (string-match-p "\\`\\(?:mailto\\|javascript\\|tel\\|data\\):" href)))
          (let ((abs (ignore-errors (url-expand-file-name href base-url))))
            (when (and abs (string-match-p "\\`https?://" abs))
              (push (car (split-string abs "#")) out))))))
    (delete-dups (nreverse out))))

;;;; Fetching a URL -------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-user-agent
  "Mozilla/5.0 (X11; Linux x86_64) cmacs-secondbrain-ingest/1.0"
  "User-Agent sent when fetching pages."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-fetch-timeout 45
  "Seconds before a page fetch is abandoned."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-fetch-max-bytes (* 20 1024 1024)
  "Largest response body accepted, in bytes."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest--header-charset (content-type html-head)
  "Return the coding system named by CONTENT-TYPE or a <meta charset> in HTML-HEAD."
  (let ((name (cond
               ((and content-type (string-match "charset=\"?\\([A-Za-z0-9_-]+\\)" content-type))
                (match-string 1 content-type))
               ((and html-head (string-match "<meta[^>]+charset=[\"']?\\([A-Za-z0-9_-]+\\)" html-head))
                (match-string 1 html-head)))))
    (or (and name (ignore-errors (check-coding-system (intern (downcase name)))))
        'utf-8)))

(defcustom cmacs-secondbrain-ingest-allow-private-hosts nil
  "Whether a URL may point at this machine or the local network.

nil, the default, refuses to fetch loopback, link-local and RFC 1918
addresses, \"localhost\" and \".local\"/\".internal\" names.  The ingester
is reachable from chat surfaces and from agents, and \"ingest this
URL\" must not become a way to read an internal service into the notes
repo.  Set to t to ingest from a local wiki or a LAN server; the check
is by name and literal address, so it is a guard against mistakes and
casual misuse, not a substitute for network policy."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-private-host-p (host)
  "Non-nil when HOST names this machine or a private network address."
  (when (stringp host)
    (let ((h (downcase (string-trim host "\\[" "\\]"))))
      (or (member h '("localhost" "localhost.localdomain" "0.0.0.0" "::" "::1"))
          (string-suffix-p ".localhost" h)
          (string-suffix-p ".local" h)
          (string-suffix-p ".internal" h)
          (string-suffix-p ".home.arpa" h)
          ;; IPv4 literals: loopback, link-local, RFC 1918, CGNAT, "this".
          (and (string-match-p "\\`[0-9]+\\(\\.[0-9]+\\)\\{3\\}\\'" h)
               (let* ((o (mapcar #'string-to-number (split-string h "\\.")))
                      (a (nth 0 o)) (b (nth 1 o)))
                 (or (= a 127) (= a 10) (= a 0)
                     (and (= a 169) (= b 254))
                     (and (= a 172) (<= 16 b 31))
                     (and (= a 192) (= b 168))
                     (and (= a 100) (<= 64 b 127)))))
          ;; IPv6 literals: loopback, unique-local, link-local, v4-mapped.
          (and (string-match-p ":" h)
               (or (string-prefix-p "fc" h) (string-prefix-p "fd" h)
                   (string-prefix-p "fe8" h) (string-prefix-p "fe9" h)
                   (string-prefix-p "fea" h) (string-prefix-p "feb" h)
                   (string-prefix-p "::ffff:" h)))))))

(cl-defun cmacs-secondbrain-ingest-fetch-url (url callback)
  "Fetch URL asynchronously and call CALLBACK with the result.

CALLBACK receives a plist: (:ok t :status N :content-type STRING :body
STRING :url FINAL-URL) on success, where :body is decoded text for a
text type and raw unibyte bytes otherwise, or (:ok nil :error MESSAGE).
Returns a function that cancels the fetch.

Refuses private hosts unless `cmacs-secondbrain-ingest-allow-private-hosts'."
  (let ((host (url-host (url-generic-parse-url url))))
    (when (and (not cmacs-secondbrain-ingest-allow-private-hosts)
               (cmacs-secondbrain-ingest-private-host-p host))
      (funcall callback
               (list :ok nil
                     :error (format "refusing to fetch private host %s (see `cmacs-secondbrain-ingest-allow-private-hosts')"
                                    host)))
      (cl-return-from cmacs-secondbrain-ingest-fetch-url #'ignore)))
  (let* ((url-request-extra-headers
          (list (cons "User-Agent" cmacs-secondbrain-ingest-user-agent)
                (cons "Accept" "text/html,application/xhtml+xml,application/pdf,text/plain,*/*;q=0.8")))
         (url-user-agent cmacs-secondbrain-ingest-user-agent)
         (done nil) (timer nil) (buf nil)
         (finish (lambda (result)
                   (unless done
                     (setq done t)
                     (when (timerp timer) (cancel-timer timer))
                     (when (buffer-live-p buf)
                       (let ((p (get-buffer-process buf)))
                         (when p (ignore-errors (delete-process p))))
                       (kill-buffer buf))
                     (funcall callback result)))))
    (condition-case err
        (progn
          (setq buf
                (url-retrieve
                 url
                 (lambda (status)
                   (let ((err (plist-get status :error)))
                     (if err
                         (funcall finish (list :ok nil
                                               :error (format "fetch failed: %S" (cdr err))))
                       (condition-case e
                           (let* ((http-status (bound-and-true-p url-http-response-status))
                                  (ctype nil) (final (or (car (last (plist-get status :redirect)))
                                                         url))
                                  (body nil))
                             ;; `url-retrieve' follows redirects itself, so
                             ;; the host that answered may not be the host
                             ;; that was asked: a public URL bouncing to
                             ;; 127.0.0.1 is the classic way round a check
                             ;; on the original.
                             (when (and (not cmacs-secondbrain-ingest-allow-private-hosts)
                                        (cmacs-secondbrain-ingest-private-host-p
                                         (url-host (url-generic-parse-url final))))
                               (error "redirected to private host %s (see `cmacs-secondbrain-ingest-allow-private-hosts')"
                                      (url-host (url-generic-parse-url final))))
                             (goto-char (point-min))
                             (when (re-search-forward "^content-type:[ \t]*\\(.*\\)$" nil t)
                               (setq ctype (downcase (string-trim (match-string 1)))))
                             (goto-char (point-min))
                             (re-search-forward "\r?\n\r?\n" nil 'move)
                             (setq body (buffer-substring-no-properties (point) (point-max)))
                             (when (> (length body) cmacs-secondbrain-ingest-fetch-max-bytes)
                               (error "response larger than %d bytes"
                                      cmacs-secondbrain-ingest-fetch-max-bytes))
                             (when (or (null ctype)
                                       (string-match-p "\\`\\(?:text/\\|application/\\(?:xhtml\\|xml\\|json\\|javascript\\)\\)" ctype))
                               (setq body (decode-coding-string
                                           body
                                           (cmacs-secondbrain-ingest--header-charset
                                            ctype (substring body 0 (min 4096 (length body)))))))
                             (funcall finish (list :ok t :status (or http-status 200)
                                                   :content-type (or ctype "")
                                                   :body body :url final)))
                         (error (funcall finish (list :ok nil :error (error-message-string e))))))))
                 nil t t))
          (setq timer (run-at-time cmacs-secondbrain-ingest-fetch-timeout nil
                                   (lambda ()
                                     (funcall finish (list :ok nil
                                                           :error (format "timed out after %ds"
                                                                          cmacs-secondbrain-ingest-fetch-timeout)))))))
      (error (funcall finish (list :ok nil :error (error-message-string err)))))
    (lambda () (funcall finish (list :ok nil :error "cancelled")))))

;;;; yt-dlp --------------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-subtitle-languages '("en" "en-orig" "en.*")
  "Subtitle languages asked of yt-dlp, in preference order."
  :type '(repeat string)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-ytdlp-extra-args nil
  "Extra arguments for every yt-dlp invocation (cookies, proxies, ...)."
  :type '(repeat string)
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-ytdlp-metadata-command (url)
  "Return the yt-dlp argv that prints URL's metadata as one JSON object."
  (append (cmacs-secondbrain-ingest-tool-command 'yt-dlp)
          (list "--no-playlist" "--skip-download" "--no-warnings" "-J")
          cmacs-secondbrain-ingest-ytdlp-extra-args
          (list "--" url)))

(defun cmacs-secondbrain-ingest-ytdlp-subtitles-command (url dir)
  "Return the yt-dlp argv that writes URL's captions (VTT) into DIR."
  (append (cmacs-secondbrain-ingest-tool-command 'yt-dlp)
          (list "--no-playlist" "--skip-download" "--no-warnings"
                "--write-subs" "--write-auto-subs"
                "--sub-langs" (string-join cmacs-secondbrain-ingest-subtitle-languages ",")
                "--sub-format" "vtt/srt/best"
                "-o" (expand-file-name "%(id)s.%(ext)s" dir))
          cmacs-secondbrain-ingest-ytdlp-extra-args
          (list "--" url)))

(defun cmacs-secondbrain-ingest-ytdlp-audio-command (url dir)
  "Return the yt-dlp argv that downloads URL's best audio into DIR."
  (append (cmacs-secondbrain-ingest-tool-command 'yt-dlp)
          (list "--no-playlist" "--no-warnings" "-f" "bestaudio/best"
                "-o" (expand-file-name "%(id)s.%(ext)s" dir))
          cmacs-secondbrain-ingest-ytdlp-extra-args
          (list "--" url)))

(defun cmacs-secondbrain-ingest-ytdlp-meta->alist (json)
  "Pick the interesting fields out of yt-dlp's JSON string.
Returns an alist of (LABEL . VALUE) plus (\"id\" . ID), (\"title\" . T)
and (\"description\" . D) for the caller."
  (let* ((obj (cmacs-secondbrain-ingest-json-parse json))
         (get (lambda (k) (cmacs-secondbrain-ingest-json-get obj k)))
         (dur (funcall get "duration"))
         (date (funcall get "upload_date"))
         (chapters (funcall get "chapters")))
    (when obj
      (delq nil
            (list (cons "id" (funcall get "id"))
                  (cons "title" (funcall get "title"))
                  (cons "description" (funcall get "description"))
                  (cons "URL" (or (funcall get "webpage_url") (funcall get "original_url")))
                  (cons "Channel" (or (funcall get "channel") (funcall get "uploader")))
                  (and (funcall get "channel_url") (cons "Channel URL" (funcall get "channel_url")))
                  (and (numberp dur)
                       (cons "Duration" (format "%d:%02d:%02d" (/ dur 3600) (% (/ dur 60) 60) (% dur 60))))
                  (and (stringp date) (= (length date) 8)
                       (cons "Uploaded" (format "%s-%s-%s" (substring date 0 4)
                                                (substring date 4 6) (substring date 6 8))))
                  (and (numberp (funcall get "view_count"))
                       (cons "Views" (number-to-string (funcall get "view_count"))))
                  (and (listp (funcall get "tags")) (funcall get "tags")
                       (cons "tags" (funcall get "tags")))
                  (and (listp chapters) chapters
                       (cons "chapters"
                             (mapcar (lambda (c)
                                       (cons (cmacs-secondbrain-ingest-json-get c "start_time")
                                             (cmacs-secondbrain-ingest-json-get c "title")))
                                     chapters))))))))

;;;; Captions and transcripts -------------------------------------------

(defun cmacs-secondbrain-ingest--vtt-ms (stamp)
  "Parse a WebVTT/SRT timestamp STAMP into milliseconds."
  (when (string-match "\\(?:\\([0-9]+\\):\\)?\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)[.,]\\([0-9]\\{1,3\\}\\)" stamp)
    (+ (* 3600000 (string-to-number (or (match-string 1 stamp) "0")))
       (* 60000 (string-to-number (match-string 2 stamp)))
       (* 1000 (string-to-number (match-string 3 stamp)))
       (string-to-number (format "%-3s" (match-string 4 stamp)) 10))))

(defun cmacs-secondbrain-ingest-parse-vtt (text)
  "Parse WebVTT or SRT TEXT into segments.
Each is an alist ((:start . MS) (:end . MS) (:text . STR)).

YouTube's automatic captions repeat each line across two cues as they
scroll, so consecutive duplicate lines are dropped; a segment whose text
is entirely repeated is dropped with them."
  (let ((cues nil) (last-line nil))
    (dolist (block (split-string (replace-regexp-in-string "\r" "" (or text "")) "\n[ \t]*\n+" t))
      (let* ((lines (split-string block "\n" t))
             (ts-idx (cl-position-if (lambda (l) (string-match-p "-->" l)) lines)))
        (when ts-idx
          (let* ((ts (nth ts-idx lines))
                 (stamps (and (string-match "\\([0-9:.,]+\\)[ \t]+-->[ \t]+\\([0-9:.,]+\\)" ts)
                              (cons (match-string 1 ts) (match-string 2 ts))))
                 (start (and stamps (cmacs-secondbrain-ingest--vtt-ms (car stamps))))
                 (end (and stamps (cmacs-secondbrain-ingest--vtt-ms (cdr stamps))))
                 (raw (nthcdr (1+ ts-idx) lines))
                 (kept nil))
            (dolist (l raw)
              (let ((clean (string-trim
                            (replace-regexp-in-string
                             "&amp;" "&"
                             (replace-regexp-in-string
                              "&nbsp;" " "
                              (replace-regexp-in-string
                               "&gt;" ">"
                               (replace-regexp-in-string
                                "&lt;" "<"
                                (replace-regexp-in-string "<[^>]*>" "" l))))))))
                (when (and (not (string-empty-p clean))
                           (not (equal clean last-line)))
                  (push clean kept)
                  (setq last-line clean))))
            (when (and start kept)
              (push (list (cons :start start) (cons :end (or end start))
                          (cons :text (string-join (nreverse kept) " ")))
                    cues))))))
    (nreverse cues)))

(defcustom cmacs-secondbrain-ingest-transcript-paragraph-seconds 60
  "Transcript segments are grouped into paragraphs of about this many seconds."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-transcript-timestamps t
  "When non-nil each transcript paragraph starts with a [H:MM:SS] stamp.
The stamps are what let the youtube summary template cite times."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-ms->clock (ms)
  "Format MS milliseconds as M:SS or H:MM:SS."
  (let* ((s (/ (or ms 0) 1000)) (h (/ s 3600)) (m (% (/ s 60) 60)) (sec (% s 60)))
    (if (> h 0) (format "%d:%02d:%02d" h m sec) (format "%d:%02d" m sec))))

(defun cmacs-secondbrain-ingest-segments->paragraphs (segments &optional stamps)
  "Join SEGMENTS into timestamped paragraphs; return the text.
STAMPS defaults to `cmacs-secondbrain-ingest-transcript-timestamps'."
  (let ((stamps (if (eq stamps 'default) cmacs-secondbrain-ingest-transcript-timestamps stamps))
        (span (* 1000 cmacs-secondbrain-ingest-transcript-paragraph-seconds))
        (paras nil) (cur nil) (cur-start nil))
    (dolist (seg segments)
      (let ((start (cdr (assq :start seg)))
            (txt (string-trim (or (cdr (assq :text seg)) ""))))
        (unless (string-empty-p txt)
          (when (and cur-start (>= (- start cur-start) span))
            (push (cons cur-start (string-join (nreverse cur) " ")) paras)
            (setq cur nil cur-start nil))
          (unless cur-start (setq cur-start start))
          (push txt cur))))
    (when cur (push (cons cur-start (string-join (nreverse cur) " ")) paras))
    (string-join (mapcar (lambda (p)
                           (if stamps
                               (format "[%s] %s" (cmacs-secondbrain-ingest-ms->clock (car p)) (cdr p))
                             (cdr p)))
                         (nreverse paras))
                 "\n\n")))

(defun cmacs-secondbrain-ingest-segments-duration (segments)
  "Return the duration of SEGMENTS in seconds, from the last end stamp."
  (let ((last (car (last segments))))
    (if last (/ (or (cdr (assq :end last)) 0) 1000) 0)))

;;;; ffmpeg ------------------------------------------------------------------

(defun cmacs-secondbrain-ingest-ffmpeg-wav-command (input wav)
  "Return the ffmpeg argv converting INPUT to WAV.
16 kHz mono S16LE, which is the only shape whisper.cpp reads."
  (append (cmacs-secondbrain-ingest-tool-command 'ffmpeg)
          (list "-y" "-nostdin" "-loglevel" "error" "-i" input
                "-vn" "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le" "-f" "wav" wav)))

(defun cmacs-secondbrain-ingest-ffprobe (file)
  "Return an alist of media facts about FILE from ffprobe, or nil."
  (let ((cmd (cmacs-secondbrain-ingest-tool-command 'ffprobe)))
    (when cmd
      (let ((res (cmacs-secondbrain-ingest--run
                  (append cmd (list "-v" "error" "-show_format" "-show_streams"
                                    "-print_format" "json" file)))))
        (when (eq (car res) 0)
          (let* ((obj (cmacs-secondbrain-ingest-json-parse (cdr res)))
                 (jg #'cmacs-secondbrain-ingest-json-get)
                 (fmt (funcall jg obj "format"))
                 (tags (funcall jg fmt "tags"))
                 (dur (funcall jg fmt "duration"))
                 (streams (funcall jg obj "streams")))
            (when obj
              (delq nil
                    (list (and dur (cons "Duration"
                                         (cmacs-secondbrain-ingest-ms->clock
                                          (round (* 1000 (string-to-number dur))))))
                          (and (funcall jg tags "title") (cons "title" (funcall jg tags "title")))
                          (and (funcall jg tags "artist") (cons "Artist" (funcall jg tags "artist")))
                          (and (funcall jg tags "album") (cons "Album" (funcall jg tags "album")))
                          (and (funcall jg tags "date") (cons "Date" (funcall jg tags "date")))
                          (cons "Streams"
                                (mapconcat (lambda (st)
                                             (format "%s/%s" (funcall jg st "codec_type")
                                                     (funcall jg st "codec_name")))
                                           streams ", ")))))))))))

;;;; Email ---------------------------------------------------------------

(defun cmacs-secondbrain-ingest--decode-header (s)
  "RFC 2047-decode header S."
  (when s
    (require 'rfc2047)
    (string-trim (rfc2047-decode-string s))))

(defun cmacs-secondbrain-ingest-eml->doc (file &optional text)
  "Read the RFC 822 message in FILE (or TEXT) into a document plist.
The text/plain part is preferred; an HTML-only message goes through the
HTML reader.  Attachments are listed, never inlined."
  (require 'mm-decode)
  (require 'mail-utils)
  (with-temp-buffer
    (if text (insert text) (insert-file-contents file))
    (let* ((from (save-restriction (mail-narrow-to-head)
                                   (cmacs-secondbrain-ingest--decode-header (mail-fetch-field "from"))))
           (to (save-restriction (mail-narrow-to-head)
                                 (cmacs-secondbrain-ingest--decode-header (mail-fetch-field "to"))))
           (cc (save-restriction (mail-narrow-to-head)
                                 (cmacs-secondbrain-ingest--decode-header (mail-fetch-field "cc"))))
           (date (save-restriction (mail-narrow-to-head) (mail-fetch-field "date")))
           (subject (save-restriction (mail-narrow-to-head)
                                      (cmacs-secondbrain-ingest--decode-header (mail-fetch-field "subject"))))
           (msgid (save-restriction (mail-narrow-to-head) (mail-fetch-field "message-id")))
           (handles (ignore-errors (mm-dissect-buffer t)))
           (plain nil) (html nil) (attachments nil))
      (cl-labels ((walk (h)
                    (cond
                     ((null h) nil)
                     ((bufferp (car h))
                      (let ((type (mm-handle-media-type h))
                            (name (mm-handle-filename h)))
                        (cond
                         ((and (equal type "text/plain") (not plain) (not name))
                          (setq plain (ignore-errors (mm-get-part h))))
                         ((and (equal type "text/html") (not html) (not name))
                          (setq html (ignore-errors (mm-get-part h))))
                         (t (push (format "%s (%s)" (or name "unnamed part") type)
                                  attachments)))))
                     ((listp h) (dolist (c (cdr h)) (walk c))))))
        (walk handles))
      (when handles (ignore-errors (mm-destroy-parts handles)))
      (let* ((body-text (cond (plain (string-trim (replace-regexp-in-string "\r" "" plain)))
                              (html (plist-get (cmacs-secondbrain-ingest-html->doc html) :text))
                              (t "")))
             (body (cond
                    (plain (cmacs-secondbrain-ingest-paragraphs->org body-text))
                    (html (plist-get (cmacs-secondbrain-ingest-html->doc html) :body))
                    (t "")))
             (meta (delq nil (list (and from (cons "From" from))
                                   (and to (cons "To" to))
                                   (and cc (cons "Cc" cc))
                                   (and date (cons "Date" (string-trim date)))
                                   (and msgid (cons "Message-ID" (string-trim msgid)))
                                   (and attachments
                                        (cons "Attachments" (string-join (nreverse attachments) ", ")))))))
        (list :kind 'email :source file :title subject
              :body body
              :text (concat (mapconcat (lambda (kv) (format "%s: %s" (car kv) (cdr kv))) meta "\n")
                            "\n\n" body-text)
              :meta meta
              :extractor 'mm-decode
              :warnings (and (string-empty-p body) '("message had no readable text part")))))))

(defun cmacs-secondbrain-ingest-mbox-split (text)
  "Split mbox TEXT into message strings on `From ' separator lines."
  (let ((parts (split-string text "^From [^\n]*\n" t)))
    (mapcar #'string-trim-right parts)))

(defun cmacs-secondbrain-ingest-mbox->doc (file)
  "Read every message in mbox FILE into one document with a section per message."
  (let* ((text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (msgs (cmacs-secondbrain-ingest-mbox-split text))
         (docs (mapcar (lambda (m) (cmacs-secondbrain-ingest-eml->doc nil m)) msgs)))
    (list :kind 'email :source file
          :title (format "%s (%d messages)" (file-name-base file) (length docs))
          :body (mapconcat (lambda (d)
                             (concat "* " (or (plist-get d :title) "(no subject)") "\n"
                                     (mapconcat (lambda (kv) (format "- %s :: %s" (car kv) (cdr kv)))
                                                (plist-get d :meta) "\n")
                                     "\n\n"
                                     (cmacs-secondbrain-ingest-demote (plist-get d :body))))
                           docs "\n\n")
          :text (mapconcat (lambda (d) (plist-get d :text)) docs "\n\n-----\n\n")
          :meta (list (cons "Messages" (number-to-string (length docs))))
          :extractor 'mm-decode)))

;;;; Office ------------------------------------------------------------------

(defun cmacs-secondbrain-ingest-office->doc (file)
  "Read an OOXML or OpenDocument FILE with cmacs-office."
  (unless (and (fboundp 'cmacs-office-supported-p) (cmacs-office-supported-p))
    (error "cmacs was built without --with-cmacs-office"))
  (require 'cmacs-office)
  (let ((h (cmacs-office-open file)))
    (unwind-protect
        (let* ((kind (cmacs-office-kind h))
               (meta (cmacs-office-metadata h))
               (title (plist-get meta :title))
               (body nil) (text nil))
          (pcase kind
            ('sheet
             (let ((cells (cmacs-office-cells h)) (parts nil) (plain nil))
               (dolist (sheet (cmacs-office-sheet-names h))
                 (let* ((rows (mapcar (lambda (r) (mapcar (lambda (c) (cdr c)) (cdr r)))
                                      (cmacs-office--sheet-rows cells sheet)))
                        (n (length rows)))
                   (push (concat "* " sheet "\n"
                                 (if (<= n cmacs-secondbrain-ingest-table-max-rows)
                                     (cmacs-secondbrain-ingest-rows->org-table rows t)
                                   (concat (cmacs-secondbrain-ingest-rows->org-table
                                            (seq-take rows cmacs-secondbrain-ingest-table-max-rows) t)
                                           (format "\n\n%d more rows not shown." (- n cmacs-secondbrain-ingest-table-max-rows)))))
                         parts)
                   (push (concat sheet "\n"
                                 (mapconcat (lambda (r) (string-join r "\t")) (seq-take rows 500) "\n"))
                         plain)))
               (setq body (string-join (nreverse parts) "\n\n")
                     text (string-join (nreverse plain) "\n\n"))))
            (_
             (let ((blocks (cmacs-office-blocks h)) (out nil) (plain nil) (slide 0))
               (dolist (b blocks)
                 (let ((lvl (or (plist-get b :level) 0))
                       (s (or (plist-get b :slide) 0))
                       (txt (string-trim (or (plist-get b :text) ""))))
                   (when (and (> s 0) (/= s slide))
                     (setq slide s)
                     (push (format "* Slide %d" s) out))
                   (unless (string-empty-p txt)
                     (push (if (> lvl 0)
                               (concat (make-string (if (> slide 0) (1+ lvl) lvl) ?*) " " txt)
                             txt)
                           out)
                     (push txt plain))))
               (setq body (string-join (nreverse out) "\n\n")
                     text (string-join (nreverse plain) "\n")))))
          (list :kind 'office :source file :title title
                :body body :text text
                :meta (delq nil (list (and (plist-get meta :creator) (cons "Author" (plist-get meta :creator)))
                                      (and (plist-get meta :created) (cons "Created" (plist-get meta :created)))
                                      (and (plist-get meta :modified) (cons "Modified" (plist-get meta :modified)))
                                      (and (plist-get meta :subject) (cons "Subject" (plist-get meta :subject)))
                                      (and (plist-get meta :keywords) (cons "Keywords" (plist-get meta :keywords)))
                                      (cons "Format" (format "%s" kind))))
                :extractor 'cmacs-office))
      (ignore-errors (cmacs-office-close h)))))

;;;; The strategy registry -----------------------------------------------

(defvar cmacs-secondbrain-ingest--strategies (make-hash-table :test 'eq)
  "STRATEGY -> plist (:needs PROGRAMS :run FN :doc STRING).")

(defun cmacs-secondbrain-ingest-register-strategy (name &rest plist)
  "Register extraction strategy NAME.

PLIST keys: :needs, a list of program symbols that must be runnable (see
`cmacs-secondbrain-ingest-programs') or a predicate function; :run, a
function (FILE KIND) returning a document plist or nil; :doc, one line."
  (unless (functionp (plist-get plist :run))
    (error "strategy %s needs a :run function" name))
  (puthash name plist cmacs-secondbrain-ingest--strategies)
  name)

(defun cmacs-secondbrain-ingest-strategy-available-p (name)
  "Non-nil when strategy NAME can run right now."
  (let* ((s (gethash name cmacs-secondbrain-ingest--strategies))
         (needs (plist-get s :needs)))
    (and s
         (cond ((functionp needs) (ignore-errors (funcall needs)))
               ((listp needs) (cl-every #'cmacs-secondbrain-ingest-tool-p needs))
               (t t)))))

(defcustom cmacs-secondbrain-ingest-strategies
  '((org . (org-native))
    (markdown . (pandoc-gfm markdown-native))
    (text . (text-native))
    (rst . (pandoc-rst text-native))
    (asciidoc . (text-native))
    (latex . (pandoc-latex text-native))
    (rtf . (pandoc-rtf libreoffice-convert))
    (html . (html-native))
    (pdf . (pdftotext mutool))
    (ebook . (pandoc-epub epub-unzip calibre-convert))
    (office . (cmacs-office pandoc-docx libreoffice-convert))
    (office-legacy . (libreoffice-convert))
    (data . (data-native))
    (email . (email-native msgconvert)))
  "Content KIND -> ordered list of strategies to try.

The first available strategy that returns a document wins.  Media (audio,
video, youtube), URLs, crawls and archives are handled by the pipeline
itself because they are asynchronous."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest--read-file (file)
  "Return FILE's contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun cmacs-secondbrain-ingest--file-doc (file kind body text &rest extra)
  "Build a document plist for FILE of KIND with BODY and TEXT plus EXTRA keys."
  (append (list :kind kind :source file
                :title (plist-get extra :title)
                :body body :text text
                :meta (plist-get extra :meta))
          extra))

(defun cmacs-secondbrain-ingest--strategy-org (file _kind)
  (let* ((raw (cmacs-secondbrain-ingest--read-file file))
         (parsed (cmacs-secondbrain-ingest-strip-org-header raw))
         (kws (car parsed))
         (body (cdr parsed)))
    (cmacs-secondbrain-ingest--file-doc
     file 'org body (cmacs-secondbrain-ingest-org-text body)
     :title (cdr (assoc "title" kws))
     :description (cdr (assoc "description" kws))
     :id (cdr (assoc "id" kws))
     :filetags (cdr (assoc "filetags" kws))
     :meta nil
     :extractor 'org-native)))

(defun cmacs-secondbrain-ingest--strategy-text (file _kind)
  (let* ((raw (cmacs-secondbrain-ingest--read-file file))
         (prose (cmacs-secondbrain-ingest-looks-like-prose-p raw)))
    (cmacs-secondbrain-ingest--file-doc
     file 'text
     (if prose (cmacs-secondbrain-ingest-paragraphs->org raw)
       (cmacs-secondbrain-ingest-src-block "text" raw))
     raw :extractor 'text-native)))

(defun cmacs-secondbrain-ingest--md-title (markdown)
  "Return the first level-one heading of MARKDOWN, or nil."
  (and (string-match "^# +\\(.+?\\)[ \t#]*$" markdown) (match-string 1 markdown)))

(defun cmacs-secondbrain-ingest--strategy-pandoc (format)
  "Return a strategy function converting FORMAT with pandoc."
  (lambda (file kind)
    (let ((org (cmacs-secondbrain-ingest-pandoc format file)))
      (cmacs-secondbrain-ingest--file-doc
       file kind org (cmacs-secondbrain-ingest-org-text org)
       :title (and (eq kind 'markdown)
                   (cmacs-secondbrain-ingest--md-title (cmacs-secondbrain-ingest--read-file file)))
       :extractor (intern (format "pandoc-%s" format))))))

(defun cmacs-secondbrain-ingest--strategy-markdown-native (file kind)
  (let ((raw (cmacs-secondbrain-ingest--read-file file)))
    (cmacs-secondbrain-ingest--file-doc
     file kind (cmacs-secondbrain-ingest-markdown->org raw) raw
     :title (cmacs-secondbrain-ingest--md-title raw)
     :extractor 'markdown-native
     :warnings '("pandoc not installed: converted with the built-in Markdown reader"))))

(defun cmacs-secondbrain-ingest--strategy-html (file kind)
  (let* ((html (cmacs-secondbrain-ingest--read-file file))
         (saved (cmacs-secondbrain-ingest-html-saved-from html))
         (doc (cmacs-secondbrain-ingest-html->doc html saved file)))
    (plist-put doc :kind kind)
    (plist-put doc :source file)
    (when saved
      (plist-put doc :meta (cons (cons "Saved from" saved)
                                 (assoc-delete-all "URL" (plist-get doc :meta)))))
    doc))

(defun cmacs-secondbrain-ingest--strategy-pdftotext (file kind)
  (let ((res (cmacs-secondbrain-ingest--run
              (append (cmacs-secondbrain-ingest-tool-command 'pdftotext)
                      (list "-enc" "UTF-8" file "-")))))
    (unless (eq (car res) 0) (error "pdftotext failed: %s" (string-trim (cdr res))))
    (cmacs-secondbrain-ingest--pdf-doc file kind (cdr res) 'pdftotext)))

(defun cmacs-secondbrain-ingest--strategy-mutool (file kind)
  (let ((res (cmacs-secondbrain-ingest--run
              (append (cmacs-secondbrain-ingest-tool-command 'mutool)
                      (list "draw" "-q" "-F" "txt" "-o" "-" file)))))
    (unless (eq (car res) 0) (error "mutool failed: %s" (string-trim (cdr res))))
    (cmacs-secondbrain-ingest--pdf-doc file kind (cdr res) 'mutool)))

(defun cmacs-secondbrain-ingest--pdf-doc (file kind text extractor)
  "Build a PDF document from extracted TEXT.  Pages are split on form feeds."
  (let* ((pages (split-string text "\f" t "[ \t\n]+"))
         (npages (length pages))
         (clean (replace-regexp-in-string "\f" "\n\n" text))
         (empty (string-blank-p clean)))
    (cmacs-secondbrain-ingest--file-doc
     file kind
     (if empty
         "This PDF has no extractable text; it is probably scanned images.  OCR it first (ocrmypdf) and ingest the result."
       (cmacs-secondbrain-ingest-paragraphs->org clean))
     clean
     :meta (list (cons "Pages" (number-to-string npages)))
     :extractor extractor
     :warnings (and empty '("no text layer in this PDF")))))

(defun cmacs-secondbrain-ingest--strategy-epub-unzip (file kind)
  "Read an EPUB with unzip alone: container.xml -> OPF -> spine."
  (let* ((unzip (cmacs-secondbrain-ingest-tool-command 'unzip))
         (cat (lambda (member)
                (let ((r (cmacs-secondbrain-ingest--run (append unzip (list "-p" file member)))))
                  (and (eq (car r) 0) (cdr r)))))
         (container (or (funcall cat "META-INF/container.xml") (error "no container.xml in %s" file)))
         (opf-path (and (string-match "full-path=\"\\([^\"]+\\)\"" container) (match-string 1 container)))
         (opf (or (and opf-path (funcall cat opf-path)) (error "no OPF in %s" file)))
         (opf-dir (file-name-directory opf-path))
         (manifest (make-hash-table :test 'equal))
         (title (and (string-match "<dc:title[^>]*>\\([^<]+\\)</dc:title>" opf) (match-string 1 opf)))
         (author (and (string-match "<dc:creator[^>]*>\\([^<]+\\)</dc:creator>" opf) (match-string 1 opf)))
         (spine nil) (parts nil) (texts nil) (pos 0))
    (while (string-match "<item [^>]*>" opf pos)
      (let ((item (match-string 0 opf)) (id nil))
        (setq pos (match-end 0))
        (when (string-match "id=\"\\([^\"]+\\)\"" item)
          (setq id (match-string 1 item)))
        (when (and id (string-match "href=\"\\([^\"]+\\)\"" item))
          (puthash id (match-string 1 item) manifest))))
    (setq pos 0)
    (while (string-match "<itemref [^>]*idref=\"\\([^\"]+\\)\"" opf pos)
      (push (match-string 1 opf) spine)
      (setq pos (match-end 0)))
    (dolist (id (nreverse spine))
      (let* ((href (gethash id manifest))
             (html (and href (string-match-p "\\.x?html?\\'" href)
                        (funcall cat (concat (or opf-dir "") (url-unhex-string href))))))
        (when html
          (let ((d (cmacs-secondbrain-ingest-html->doc html nil file)))
            (push (plist-get d :body) parts)
            (push (plist-get d :text) texts)))))
    (cmacs-secondbrain-ingest--file-doc
     file kind (string-join (nreverse parts) "\n\n") (string-join (nreverse texts) "\n\n")
     :title title
     :meta (delq nil (list (and author (cons "Author" author))))
     :extractor 'epub-unzip)))

(defun cmacs-secondbrain-ingest--convert-with (tool args-fn file kind next-kind)
  "Convert FILE with TOOL into a temp dir and re-extract as NEXT-KIND.
ARGS-FN receives (FILE OUT-DIR) and returns the argv tail; the converted
file is whatever appears in OUT-DIR."
  (let* ((dir (make-temp-file "cmacs-sbi-convert-" t))
         (res (cmacs-secondbrain-ingest--run
               (append (cmacs-secondbrain-ingest-tool-command tool)
                       (funcall args-fn file dir)))))
    (unless (eq (car res) 0)
      (ignore-errors (delete-directory dir t))
      (error "%s failed: %s" tool (string-trim (cdr res))))
    (let ((out (car (directory-files dir t "\\`[^.]"))))
      (unless out
        (ignore-errors (delete-directory dir t))
        (error "%s produced no output" tool))
      (unwind-protect
          (let ((doc (cmacs-secondbrain-ingest-extract-file out next-kind)))
            (plist-put doc :source file)
            (plist-put doc :kind kind)
            (plist-put doc :extractor (intern (format "%s+%s" tool (plist-get doc :extractor))))
            doc)
        (ignore-errors (delete-directory dir t))))))

(defun cmacs-secondbrain-ingest--strategy-calibre (file kind)
  (cmacs-secondbrain-ingest--convert-with
   'ebook-convert
   (lambda (f dir) (list f (expand-file-name "book.epub" dir)))
   file kind 'ebook))

(defun cmacs-secondbrain-ingest--strategy-libreoffice (file kind)
  (let ((target (pcase (downcase (or (file-name-extension file) ""))
                  ((or "xls" "xlsb" "xlsm") "xlsx")
                  ((or "ppt" "pps") "pptx")
                  (_ "docx"))))
    (cmacs-secondbrain-ingest--convert-with
     'libreoffice
     (lambda (f dir) (list "--headless" "--convert-to" target "--outdir" dir f))
     file kind 'office)))

(defun cmacs-secondbrain-ingest--strategy-data (file kind)
  (let* ((raw (cmacs-secondbrain-ingest--read-file file))
         (ext (downcase (or (file-name-extension file) "txt"))))
    (cmacs-secondbrain-ingest--file-doc
     file kind (cmacs-secondbrain-ingest-data->org raw ext)
     (cmacs-secondbrain-ingest-sample-lines raw 400)
     :meta (list (cons "Format" ext)
                 (cons "Size" (format "%d bytes" (string-bytes raw))))
     :extractor 'data-native)))

(defun cmacs-secondbrain-ingest-sample-lines (text n)
  "Return the first N lines of TEXT."
  (string-join (seq-take (split-string (or text "") "\n") n) "\n"))

(defun cmacs-secondbrain-ingest--strategy-email (file kind)
  (let ((ext (downcase (or (file-name-extension file) ""))))
    (cond
     ((equal ext "msg") (error "Outlook .msg needs msgconvert"))
     ((or (equal ext "mbox")
          (with-temp-buffer (insert-file-contents file nil 0 5) (looking-at "From ")))
      (let ((d (cmacs-secondbrain-ingest-mbox->doc file))) (plist-put d :kind kind) d))
     (t (let ((d (cmacs-secondbrain-ingest-eml->doc file))) (plist-put d :kind kind) d)))))

(defun cmacs-secondbrain-ingest--strategy-msgconvert (file kind)
  (cmacs-secondbrain-ingest--convert-with
   'msgconvert
   (lambda (f dir) (list "--outfile" (expand-file-name "message.eml" dir) f))
   file kind 'email))

(defun cmacs-secondbrain-ingest--office-strategy (file kind)
  (let ((d (cmacs-secondbrain-ingest-office->doc file))) (plist-put d :kind kind) d))

;; Registrations.  Kept together so the table of what exists is readable.
(cmacs-secondbrain-ingest-register-strategy 'org-native
  :run #'cmacs-secondbrain-ingest--strategy-org :doc "Org files, header re-read")
(cmacs-secondbrain-ingest-register-strategy 'text-native
  :run #'cmacs-secondbrain-ingest--strategy-text :doc "Plain text as paragraphs or a block")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-gfm
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "gfm") :doc "Markdown via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'markdown-native
  :run #'cmacs-secondbrain-ingest--strategy-markdown-native :doc "Markdown via the built-in reader")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-rst
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "rst") :doc "reStructuredText via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-latex
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "latex") :doc "LaTeX via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-rtf
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "rtf") :doc "RTF via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-epub
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "epub") :doc "EPUB via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'pandoc-docx
  :needs '(pandoc) :run (cmacs-secondbrain-ingest--strategy-pandoc "docx") :doc ".docx via pandoc")
(cmacs-secondbrain-ingest-register-strategy 'html-native
  :run #'cmacs-secondbrain-ingest--strategy-html :doc "HTML via libxml, pandoc or shr")
(cmacs-secondbrain-ingest-register-strategy 'pdftotext
  :needs '(pdftotext) :run #'cmacs-secondbrain-ingest--strategy-pdftotext :doc "PDF via poppler")
(cmacs-secondbrain-ingest-register-strategy 'mutool
  :needs '(mutool) :run #'cmacs-secondbrain-ingest--strategy-mutool :doc "PDF via mupdf")
(cmacs-secondbrain-ingest-register-strategy 'epub-unzip
  :needs '(unzip) :run #'cmacs-secondbrain-ingest--strategy-epub-unzip :doc "EPUB via unzip + libxml")
(cmacs-secondbrain-ingest-register-strategy 'calibre-convert
  :needs '(ebook-convert) :run #'cmacs-secondbrain-ingest--strategy-calibre :doc "MOBI/AZW via calibre to EPUB")
(cmacs-secondbrain-ingest-register-strategy 'cmacs-office
  :needs (lambda () (and (fboundp 'cmacs-office-supported-p) (cmacs-office-supported-p)))
  :run #'cmacs-secondbrain-ingest--office-strategy :doc "Office packages via cmacs-office")
(cmacs-secondbrain-ingest-register-strategy 'libreoffice-convert
  :needs '(libreoffice) :run #'cmacs-secondbrain-ingest--strategy-libreoffice :doc "Legacy Office via LibreOffice")
(cmacs-secondbrain-ingest-register-strategy 'data-native
  :run #'cmacs-secondbrain-ingest--strategy-data :doc "CSV/JSON/XML/YAML/TOML as tables and blocks")
(cmacs-secondbrain-ingest-register-strategy 'email-native
  :run #'cmacs-secondbrain-ingest--strategy-email :doc "RFC 822 and mbox via mm-decode")
(cmacs-secondbrain-ingest-register-strategy 'msgconvert
  :needs '(msgconvert) :run #'cmacs-secondbrain-ingest--strategy-msgconvert :doc "Outlook .msg via msgconvert")

(defun cmacs-secondbrain-ingest-extract-file (file kind)
  "Extract FILE of content KIND into a document plist, trying each strategy.

Signals with a message naming the missing programs when no strategy could
run, or the last error when they all failed."
  (let ((strategies (cdr (assq kind cmacs-secondbrain-ingest-strategies)))
        (warnings nil) (missing nil) (result nil))
    (unless strategies
      (error "no extractor for content kind `%s'" kind))
    (cl-loop for name in strategies
             until result
             do (if (not (cmacs-secondbrain-ingest-strategy-available-p name))
                    (push name missing)
                  (condition-case err
                      (let ((doc (funcall (plist-get (gethash name cmacs-secondbrain-ingest--strategies) :run)
                                          file kind)))
                        (when doc
                          (setq result doc)
                          (unless (plist-get doc :extractor) (plist-put doc :extractor name))))
                    (error (push (format "%s: %s" name (error-message-string err)) warnings)))))
    (unless result
      (error "could not read %s: %s"
             (file-name-nondirectory file)
             (string-join
              (append (nreverse warnings)
                      (and missing
                           (list (format "unavailable strategies: %s (%s)"
                                         (mapconcat #'symbol-name (nreverse missing) ", ")
                                         (cmacs-secondbrain-ingest--needs-summary missing)))))
              "; ")))
    (plist-put result :warnings (append (plist-get result :warnings) (nreverse warnings)))
    result))

(defun cmacs-secondbrain-ingest--needs-summary (strategies)
  "Return a string naming the programs STRATEGIES would need."
  (let ((progs nil))
    (dolist (s strategies)
      (let ((needs (plist-get (gethash s cmacs-secondbrain-ingest--strategies) :needs)))
        (cond ((listp needs) (dolist (p needs) (cl-pushnew p progs)))
              ((functionp needs) (cl-pushnew 'cmacs-office progs)))))
    (if progs (format "install %s" (mapconcat #'symbol-name (nreverse progs) " or ")) "")))

;;;; Archives and site exports --------------------------------------------

(defun cmacs-secondbrain-ingest-unpack-archive (file)
  "Extract archive FILE into a fresh temp directory and return its path."
  (let ((dir (make-temp-file "cmacs-sbi-export-" t))
        (ext (downcase (or (file-name-extension file) ""))))
    (let ((res (pcase ext
                 ("zip" (cmacs-secondbrain-ingest--run
                         (append (or (cmacs-secondbrain-ingest-tool-command 'unzip)
                                     (error "unzip is not installed"))
                                 (list "-q" "-o" file "-d" dir))))
                 (_ (cmacs-secondbrain-ingest--run
                     (append (or (cmacs-secondbrain-ingest-tool-command 'tar)
                                 (error "tar is not installed"))
                             (list "-xf" file "-C" dir)))))))
      (unless (eq (car res) 0)
        (ignore-errors (delete-directory dir t))
        (error "could not unpack %s: %s" (file-name-nondirectory file) (string-trim (cdr res))))
      dir)))

(defun cmacs-secondbrain-ingest-find-html-files (dir)
  "Return every .html/.htm under DIR, index pages first."
  (let ((files (directory-files-recursively dir "\\.x?html?\\'")))
    (sort files (lambda (a b)
                  (let ((ai (string-match-p "/index\\.x?html?\\'" a))
                        (bi (string-match-p "/index\\.x?html?\\'" b)))
                    (cond ((and ai (not bi)) t)
                          ((and bi (not ai)) nil)
                          (t (string< a b))))))))

;;;; Doctor ----------------------------------------------------------------

(defun cmacs-secondbrain-ingest-doctor ()
  "Return what the ingester can and cannot do on this machine.

An alist of (NAME AVAILABLE-P DETAIL): every external program with the
path it resolved to, and every cmacs feature the pipeline can use."
  (append
   (mapcar (lambda (entry)
             (let* ((name (car entry))
                    (cmd (cmacs-secondbrain-ingest-tool-command name)))
               (list name (and cmd t)
                     (if cmd (string-join cmd " ")
                       (format "not found (%s)" (cdr entry))))))
           cmacs-secondbrain-ingest-programs)
   (list (list 'cmacs-office (and (fboundp 'cmacs-office-supported-p)
                                  (ignore-errors (cmacs-office-supported-p)) t)
               "native .docx/.xlsx/.pptx/.odt/.ods/.odp")
         (list 'cmacs-whisper (and (fboundp 'cmacs-whisper-supported-p)
                                   (ignore-errors (funcall 'cmacs-whisper-supported-p)) t)
               "embedded speech-to-text for audio, video and caption-less videos")
         (list 'cmacs-ai (and (fboundp 'cmacs-ai-supported-p)
                              (ignore-errors (funcall 'cmacs-ai-supported-p)) t)
               "summaries, titles, tags and PARA placement")
         (list 'cmacs-gsurf (and (fboundp 'cmacs-gsurf-supported-p)
                                 (ignore-errors (funcall 'cmacs-gsurf-supported-p)) t)
               "JavaScript-rendered pages")
         (list 'libxml (fboundp 'libxml-parse-html-region) "HTML parsing")
         (list 'sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p))
               "org-roam database lookups"))))

(provide 'cmacs-secondbrain-ingest-extract)
;;; cmacs-secondbrain-ingest-extract.el ends here
