;;; cmacs-secondbrain-ingest-tests.el --- Tests for the second-brain ingester  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three tiers.
;;
;;   - Pure transforms: classification, slugs, the Markdown and CSV
;;     readers, caption parsing, the HTML reader on a fixture, redaction,
;;     the analysis JSON reader, option normalisation, robots.txt.  No
;;     network, no model, no notes tree.
;;
;;   - The pipeline on a temporary notes tree with the model disabled:
;;     every fixture format goes in and an Org node comes out with an id,
;;     a header, an index bullet and the right placement; collisions,
;;     appends, explicit directories, dry runs and cancellation.
;;
;;   - The surfaces: the D-Bus interface (Tree, Ingest, IngestStatus,
;;     Doctor) through the live service, and `emacsctl sb'.  Skipped
;;     when the build lacks them.
;;
;; Nothing here reaches the network or a model.  The YouTube and web
;; fetch paths are exercised up to their command builders and response
;; handling; the live paths were verified by hand and are documented as
;; such rather than tested against a service that may be down.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'cmacs-secondbrain-ingest-extract)
(require 'cmacs-secondbrain-ingest-ai)
(require 'cmacs-secondbrain-ingest)

(defconst cmacs-secondbrain-ingest-tests--fixtures
  (expand-file-name "fixtures/ingest"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "Where the fixture files live.")

(defconst cmacs-secondbrain-ingest-tests--office-fixtures
  (expand-file-name "fixtures/office"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory))))

(defun cmacs-secondbrain-ingest-tests--fixture (name)
  (expand-file-name name cmacs-secondbrain-ingest-tests--fixtures))

(defun cmacs-secondbrain-ingest-tests--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro cmacs-secondbrain-ingest-tests--with-root (var &rest body)
  "Run BODY with VAR bound to a fresh PARA tree, the ingester pointed at it,
the model off and related-note search off."
  (declare (indent 1) (debug t))
  `(let* ((,var (file-name-as-directory (make-temp-file "sbi-test-root-" t)))
          (cmacs-secondbrain-ingest-root ,var)
          (cmacs-secondbrain-ingest-link-related nil)
          (cmacs-secondbrain-ingest-refresh-view nil)
          (cmacs-secondbrain-ingest-update-roam-db nil)
          (cmacs-secondbrain-ingest-placement 'inbox)
          (cmacs-secondbrain-ingest-verbose nil)
          (cmacs-secondbrain-ingest--jobs nil))
     (dolist (d '("00_inbox" "01_projects/personal" "01_projects/work"
                  "02_areas/personal" "02_areas/dailies" "03_resources/personal"
                  "03_resources/technical/linux" "04_archives/01_projects"))
       (make-directory (expand-file-name d ,var) t))
     (with-temp-file (expand-file-name "00_index.org" ,var)
       (insert ":PROPERTIES:\n:ID:       root-index\n:END:\n#+title: Notes\n\n* Contents\n- [[id:x][Existing]]\n"))
     (with-temp-file (expand-file-name "03_resources/technical/linux/00_index.org" ,var)
       (insert ":PROPERTIES:\n:ID:       linux-index\n:END:\n#+title: Linux Index\n\n- [[id:y][Some note]]\n"))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory ,var t)))))

(defun cmacs-secondbrain-ingest-tests--run (input &rest opts)
  "Ingest INPUT with OPTS and the model off; wait; return the job."
  (let ((jobs (apply #'cmacs-secondbrain-ingest-run input :no-ai t opts)))
    (cmacs-secondbrain-ingest-wait jobs 30)
    (car jobs)))

;;;; Classification -------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-classify-urls ()
  "YouTube in all its spellings, plain URLs, and files by extension."
  (dolist (u '("https://youtu.be/dQw4w9WgXcQ"
               "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"
               "https://youtube.com/shorts/abc123"
               "https://m.youtube.com/watch?v=abc"
               "https://music.youtube.com/watch?v=abc"
               "https://www.youtube.com/live/abc"))
    (should (eq 'youtube (plist-get (cmacs-secondbrain-ingest-classify u) :kind))))
  (should (eq 'url (plist-get (cmacs-secondbrain-ingest-classify "https://example.com/x") :kind)))
  (should (plist-get (cmacs-secondbrain-ingest-classify "https://example.com/x") :url-p))
  (should (eq 'pdf (plist-get (cmacs-secondbrain-ingest-classify "/no/such/file.PDF") :kind)))
  (should (eq 'office (plist-get (cmacs-secondbrain-ingest-classify "a.docx") :kind)))
  (should (eq 'office-legacy (plist-get (cmacs-secondbrain-ingest-classify "a.doc") :kind)))
  (should (eq 'email (plist-get (cmacs-secondbrain-ingest-classify "a.eml") :kind)))
  (should (eq 'audio (plist-get (cmacs-secondbrain-ingest-classify "a.opus") :kind)))
  (should (eq 'video (plist-get (cmacs-secondbrain-ingest-classify "a.mkv") :kind)))
  (should (eq 'data (plist-get (cmacs-secondbrain-ingest-classify "a.yaml") :kind)))
  (should (eq 'markdown (plist-get (cmacs-secondbrain-ingest-classify "x" "md") :kind)))
  (should (eq 'org (plist-get (cmacs-secondbrain-ingest-classify "x" 'org) :kind))))

(ert-deftest cmacs-secondbrain-ingest-test-classify-sniffs-extensionless ()
  "A file with no extension is classified by its bytes."
  (let ((pdf (make-temp-file "sbi-sniff-"))
        (org (make-temp-file "sbi-sniff-"))
        (txt (make-temp-file "sbi-sniff-")))
    (unwind-protect
        (progn
          (with-temp-file pdf (set-buffer-multibyte nil) (insert "%PDF-1.4\n%garbage"))
          (with-temp-file org (insert "#+title: Hello\n\n* Body\n"))
          (with-temp-file txt (insert "just words\n"))
          (should (eq 'pdf (plist-get (cmacs-secondbrain-ingest-classify pdf) :kind)))
          (should (eq 'org (plist-get (cmacs-secondbrain-ingest-classify org) :kind)))
          (should (eq 'text (plist-get (cmacs-secondbrain-ingest-classify txt) :kind))))
      (dolist (f (list pdf org txt)) (ignore-errors (delete-file f))))))

;;;; Slugs and names ----------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-slugify ()
  (should (equal "cafe_how_to_x_2026" (cmacs-secondbrain-ingest-slugify "  Café: How-To X! (2026) ")))
  (should (equal "untitled" (cmacs-secondbrain-ingest-slugify "!!!")))
  (should (equal "abc" (cmacs-secondbrain-ingest-slugify "abc_def" 4)))
  (should (equal "dont_stop" (cmacs-secondbrain-ingest-slugify "Don't Stop"))))

(ert-deftest cmacs-secondbrain-ingest-test-filename-from-url ()
  (should (equal "how_to_x" (cmacs-secondbrain-ingest-filename-from-url
                             "https://example.com/blog/how-to-x.html?a=1#frag")))
  (should (equal "example_com" (cmacs-secondbrain-ingest-filename-from-url "https://www.example.com/")))
  (should (equal "example_com" (cmacs-secondbrain-ingest-filename-from-url "https://example.com/index.php"))))

(ert-deftest cmacs-secondbrain-ingest-test-slug-tag ()
  (should (equal "foo_bar" (cmacs-secondbrain-ingest-slug-tag "#Foo Bar")))
  (should (equal "" (cmacs-secondbrain-ingest-slug-tag "###"))))

;;;; Readers --------------------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-markdown-native ()
  "The no-pandoc Markdown reader handles the constructs notes actually use."
  (let ((org (cmacs-secondbrain-ingest-markdown->org
              (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-tests--fixture "sample.md")))))
    (should (string-match-p "^\\* Systemd Timers$" org))
    (should (string-match-p "^\\*\\* Steps$" org))
    (should (string-match-p "\\*timers\\*" org))
    (should (string-match-p "~code~" org))
    (should (string-match-p "\\[\\[https://example.com\\]\\[link\\]\\]" org))
    (should (string-match-p "^- \\[ \\] follow up" org))
    (should (string-match-p "~\\.timer~" org)))
  (let ((org (cmacs-secondbrain-ingest-markdown->org
              "a **b** and _c_ and snake_case_name\n\n```sh\necho hi\n#+end_src\n```\n\n| x | y |\n|---|:-:|\n| 1 | 2 |\n\n> q\n")))
    (should (string-match-p "\\*b\\*" org))
    (should (string-match-p "/c/" org))
    (should (string-match-p "snake_case_name" org))
    ;; A line that would close the block early is escaped with a comma.
    (should (string-match-p "#\\+begin_src sh\necho hi\n,#\\+end_src\n#\\+end_src" org))
    (should (string-match-p "|---\\+---|" org))
    (should (string-match-p "#\\+begin_quote\nq\n#\\+end_quote" org))))

(ert-deftest cmacs-secondbrain-ingest-test-csv ()
  "Quoted fields, doubled quotes and embedded delimiters survive."
  (let ((rows (cmacs-secondbrain-ingest-parse-csv
               (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-tests--fixture "sample.csv")))))
    (should (= 3 (length rows)))
    (should (equal '("name" "role" "notes") (car rows)))
    (should (equal "Owns the \"budget\" question" (nth 2 (nth 1 rows))))
    (should (equal "Likes commas, apparently" (nth 2 (nth 2 rows)))))
  (let ((table (cmacs-secondbrain-ingest-data->org "a,b\n1,x|y\n" "csv")))
    (should (string-match-p "^| a | b |\n|---\\+---|\n| 1 | x\\\\vert{}y |$" table)))
  (should (string-match-p "#\\+begin_src json" (cmacs-secondbrain-ingest-data->org "{\"a\":1}" "json")))
  (should (equal "\t" (cmacs-secondbrain-ingest--csv-delimiter "a\tb\tc\n1\t2\t3"))))

(ert-deftest cmacs-secondbrain-ingest-test-vtt ()
  "Rolling YouTube captions collapse to one line each with real end times."
  (let ((segs (cmacs-secondbrain-ingest-parse-vtt
               (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-tests--fixture "sample.vtt")))))
    (should (equal '("welcome to the talk" "today we cover" "systemd & timers" "thanks for watching")
                   (mapcar (lambda (s) (cdr (assq :text s))) segs)))
    (should (= 0 (cdr (assq :start (car segs)))))
    (should (= 2500 (cdr (assq :end (car segs)))))
    (should (= 68 (cmacs-secondbrain-ingest-segments-duration segs)))
    (let ((cmacs-secondbrain-ingest-transcript-paragraph-seconds 60))
      (let ((paras (cmacs-secondbrain-ingest-segments->paragraphs segs t)))
        (should (string-prefix-p "[0:00] welcome to the talk" paras))
        (should (string-match-p "\n\n\\[1:05\\] thanks for watching\\'" paras))))))

(ert-deftest cmacs-secondbrain-ingest-test-clock ()
  (should (equal "0:05" (cmacs-secondbrain-ingest-ms->clock 5000)))
  (should (equal "1:01:05" (cmacs-secondbrain-ingest-ms->clock 3665000))))

(ert-deftest cmacs-secondbrain-ingest-test-html-reader ()
  "The article is found, the chrome dropped, the metadata read."
  (skip-unless (fboundp 'libxml-parse-html-region))
  (let* ((html (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-tests--fixture "sample.html")))
         (doc (cmacs-secondbrain-ingest-html->doc html "https://example.com/posts/hello")))
    (should (equal "Hello Post" (plist-get doc :title)))
    (should (equal "A post about greetings." (plist-get doc :description)))
    (should (equal "Alice Example" (cdr (assoc "Author" (plist-get doc :meta)))))
    (should (string-match-p "first paragraph" (plist-get doc :text)))
    (should-not (string-match-p "Subscribe" (plist-get doc :text)))
    (should-not (string-match-p "Copyright" (plist-get doc :text)))
    (should-not (string-match-p "About" (plist-get doc :body)))
    ;; With a working pandoc the heading is an Org heading; the shr
    ;; fallback keeps it as text.  The test runner's HOME is
    ;; /nonexistent, which breaks a distrobox-exported pandoc, so the
    ;; fallback is what usually runs here.  Either way the heading is
    ;; present and the navigation is not.
    (should (string-match-p "Hello Post" (plist-get doc :body)))
    (when (equal (plist-get doc :extractor) 'libxml+pandoc)
      (unless (plist-get doc :warnings)
        (should (string-match-p "^\\* Hello Post" (plist-get doc :body)))))
    (should (equal "https://example.com/posts/hello"
                   (cmacs-secondbrain-ingest-html-saved-from html)))
    (should (equal '("https://example.com/other")
                   (cmacs-secondbrain-ingest-html-links
                    "<a href='/other'>x</a><a href='#f'>y</a><a href='mailto:a'>z</a><a href='/other#x'>w</a>"
                    "https://example.com/p")))))

(ert-deftest cmacs-secondbrain-ingest-test-eml-reader ()
  "Headers decode, the text part is taken, attachments are listed not inlined."
  (let ((doc (cmacs-secondbrain-ingest-eml->doc (cmacs-secondbrain-ingest-tests--fixture "sample.eml"))))
    (should (equal "Quarterly plan – draft" (plist-get doc :title)))
    (should (equal "Alice Example <alice@example.com>" (cdr (assoc "From" (plist-get doc :meta)))))
    (should (string-match-p "plan.pdf (application/pdf)" (cdr (assoc "Attachments" (plist-get doc :meta)))))
    (should (string-match-p "hiring freeze" (plist-get doc :body)))
    (should-not (string-match-p "JVBERi" (plist-get doc :body)))))

(ert-deftest cmacs-secondbrain-ingest-test-org-header-strip ()
  (let ((r (cmacs-secondbrain-ingest-strip-org-header
            ":PROPERTIES:\n:ID:       abc-1\n:END:\n#+title: T\n#+filetags: :a:b:\n\n* Body\ntext")))
    (should (equal "abc-1" (cdr (assoc "id" (car r)))))
    (should (equal "T" (cdr (assoc "title" (car r)))))
    (should (equal "* Body\ntext" (cdr r)))))

(ert-deftest cmacs-secondbrain-ingest-test-prose-heuristic ()
  (should (cmacs-secondbrain-ingest-looks-like-prose-p
           "This is a sentence that is long enough and ends with a full stop.\nAnother sentence follows it and also ends properly."))
  (should-not (cmacs-secondbrain-ingest-looks-like-prose-p "{\n  \"a\": 1,\n  \"b\": 2\n}"))
  (should (equal "one two\n\nthree" (cmacs-secondbrain-ingest-paragraphs->org "one\ntwo\n\nthree")))
  (should (equal "- a\n- b" (cmacs-secondbrain-ingest-paragraphs->org "- a\n- b"))))

(ert-deftest cmacs-secondbrain-ingest-test-demote-and-custom-ids ()
  (should (equal "** A\n*** B" (cmacs-secondbrain-ingest-demote "* A\n** B")))
  (should (equal "* A\ntext\n" (cmacs-secondbrain-ingest-strip-custom-ids
                                "* A\n:PROPERTIES:\n:CUSTOM_ID: a\n:END:\ntext\n"))))

;;;; Commands the pipeline would run ------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-ytdlp-commands ()
  (skip-unless (cmacs-secondbrain-ingest-tool-p 'yt-dlp))
  (let ((cmd (cmacs-secondbrain-ingest-ytdlp-subtitles-command "https://youtu.be/x" "/tmp/d")))
    (should (member "--write-auto-subs" cmd))
    (should (member "--skip-download" cmd))
    (should (equal "https://youtu.be/x" (car (last cmd))))
    (should (member "--" cmd)))
  (should (member "-J" (cmacs-secondbrain-ingest-ytdlp-metadata-command "u")))
  (let ((cmd (cmacs-secondbrain-ingest-ytdlp-audio-command "u" "/tmp/d")))
    (should (member "bestaudio/best" cmd))))

(ert-deftest cmacs-secondbrain-ingest-test-ytdlp-metadata ()
  (let ((meta (cmacs-secondbrain-ingest-ytdlp-meta->alist
               "{\"id\":\"abc\",\"title\":\"T\",\"channel\":\"C\",\"duration\":3725,\"upload_date\":\"20260101\",\"webpage_url\":\"https://youtu.be/abc\",\"chapters\":[{\"start_time\":0,\"title\":\"Intro\"}]}")))
    (should (equal "T" (cdr (assoc "title" meta))))
    (should (equal "1:02:05" (cdr (assoc "Duration" meta))))
    (should (equal "2026-01-01" (cdr (assoc "Uploaded" meta))))
    (should (equal '((0 . "Intro")) (cdr (assoc "chapters" meta))))))

(ert-deftest cmacs-secondbrain-ingest-test-ffmpeg-command ()
  (skip-unless (cmacs-secondbrain-ingest-tool-p 'ffmpeg))
  (let ((cmd (cmacs-secondbrain-ingest-ffmpeg-wav-command "/in.mp3" "/out.wav")))
    (should (member "16000" cmd))
    (should (member "pcm_s16le" cmd))
    (should (equal "/out.wav" (car (last cmd))))))

(ert-deftest cmacs-secondbrain-ingest-test-robots ()
  (let ((rules (cmacs-secondbrain-ingest-parse-robots
                (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-tests--fixture "robots.txt")))))
    (should (equal '("/admin/" "/tmp/") rules))
    (should (cmacs-secondbrain-ingest--robots-allow-p "https://x.com/blog/a" rules))
    (should-not (cmacs-secondbrain-ingest--robots-allow-p "https://x.com/admin/x" rules)))
  (should (cmacs-secondbrain-ingest--same-site-p "https://www.x.com/a" "https://x.com/b"))
  (should-not (cmacs-secondbrain-ingest--same-site-p "https://x.com/a" "https://y.com/b")))

;;;; Redaction ------------------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-redaction-defaults ()
  "Default rules catch secrets and leave ordinary numbers alone."
  (let ((r (cmacs-secondbrain-ingest-redact-count
            "mail a@b.co, call 555-123-4567, ts 1700000000, ip 10.0.0.1, AKIAABCDEFGHIJKLMNOP, order 12345678")))
    (should (= 4 (cdr r)))
    (should (string-match-p "<redacted:email>" (car r)))
    (should (string-match-p "<redacted:phone>" (car r)))
    (should (string-match-p "<redacted:ipv4>" (car r)))
    (should (string-match-p "<redacted:aws-key>" (car r)))
    (should (string-match-p "1700000000" (car r)))
    (should (string-match-p "12345678" (car r)))))

(ert-deftest cmacs-secondbrain-ingest-test-redaction-named-rules ()
  (should (= 1 (cdr (cmacs-secondbrain-ingest-redact-count "n 12345678" '(bank-account)))))
  (should (= 0 (cdr (cmacs-secondbrain-ingest-redact-count "n 12345678" '(email)))))
  (let ((cmacs-secondbrain-ingest-redaction-label-rule nil))
    (should (equal "<redacted>" (cmacs-secondbrain-ingest-redact "x@y.zz"))))
  (should (string-match-p "<redacted:private-key>"
                          (cmacs-secondbrain-ingest-redact
                           "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"))))

;;;; The model's answer -------------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-analysis-json ()
  "Fenced, chatty JSON still parses; fields are validated and slugified."
  (let ((a (cmacs-secondbrain-ingest-normalize-analysis
            (cmacs-secondbrain-ingest-parse-json
             "Sure! ```json\n{\"title\":\" A Title \",\"description\":\"d\",\"summary_type\":\"Meeting\",\"tags\":[\"Foo Bar\",\"#baz\",\"foo_bar\"],\"para\":{\"path\":\"/03_resources/technical/linux/\",\"confidence\":\"0.8\",\"reason\":\"r\"},\"language\":\"EN\"}\n```"))))
    (should (equal "A Title" (plist-get a :title)))
    (should (eq 'meeting (plist-get a :summary-type)))
    (should (equal '("foo_bar" "baz") (plist-get a :tags)))
    (should (equal "03_resources/technical/linux" (plist-get a :path)))
    (should (= 0.8 (plist-get a :confidence)))
    (should (equal "en" (plist-get a :language))))
  (let ((a (cmacs-secondbrain-ingest-normalize-analysis
            (cmacs-secondbrain-ingest-parse-json "{\"summary_type\":\"nonsense\",\"para\":{\"confidence\":7}}"))))
    (should-not (plist-get a :summary-type))
    (should (= 1.0 (plist-get a :confidence))))
  (should-not (cmacs-secondbrain-ingest-parse-json "no json here"))
  (should-not (cmacs-secondbrain-ingest-normalize-analysis nil)))

(ert-deftest cmacs-secondbrain-ingest-test-summary-system ()
  (should (memq 'youtube (cmacs-secondbrain-ingest-summary-types)))
  (should (eq 'auto (car (cmacs-secondbrain-ingest-summary-types))))
  (let ((s (cmacs-secondbrain-ingest-summary-system 'meeting t "Be brief.")))
    (should (string-match-p "Action items" s))
    (should (string-match-p "Principles" s))
    (should (string-match-p "Be brief" s)))
  (should (string-match-p "TL;DR" (cmacs-secondbrain-ingest-summary-system 'no-such-type)))
  (should (eq 'youtube (cmacs-secondbrain-ingest-default-summary-type 'video)))
  (should (eq 'email (cmacs-secondbrain-ingest-default-summary-type 'email))))

(ert-deftest cmacs-secondbrain-ingest-test-sample ()
  (let ((s (cmacs-secondbrain-ingest-sample (make-string 1000 ?a) 100)))
    (should (string-match-p "characters omitted" s))
    (should (< (length s) 200)))
  (should (equal "abc" (cmacs-secondbrain-ingest-sample "abc" 100))))

(ert-deftest cmacs-secondbrain-ingest-test-analysis-prompt-mentions-tree ()
  (let ((p (cmacs-secondbrain-ingest-analysis-prompt
            (list :kind 'markdown :source "/x.md" :text "hello")
            "03_resources/technical (3 notes)"
            (list :para "03_resources" :tags '("linux")))))
    (should (string-match-p "03_resources/technical (3 notes)" p))
    (should (string-match-p "already decided the PARA category is 03_resources" p))
    (should (string-match-p "already tagged this: linux" p))
    (should (string-match-p "hello" p))))

;;;; Options and placement --------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-normalize-options ()
  (let ((o (cmacs-secondbrain-ingest-normalize-options
            '(:para "resource" :tags "a, B,c" :type "meeting" :sanitize "email,phone" :depth "2"))))
    (should (eq 'resources (plist-get o :para)))
    (should (equal '("a" "b" "c") (plist-get o :tags)))
    (should (eq 'meeting (plist-get o :type)))
    (should (equal '(email phone) (plist-get o :sanitize)))
    (should (= 2 (plist-get o :depth))))
  (should (eq 'detect (plist-get (cmacs-secondbrain-ingest-normalize-options '(:para "auto")) :para)))
  (should (eq t (plist-get (cmacs-secondbrain-ingest-normalize-options '(:sanitize "true")) :sanitize)))
  (should-error (cmacs-secondbrain-ingest-normalize-options '(:para "nonsense")))
  (should-error (cmacs-secondbrain-ingest-normalize-options '(:type "nonsense"))))

(ert-deftest cmacs-secondbrain-ingest-test-options-from-json ()
  (let ((o (cmacs-secondbrain-ingest-options-from-json
            "{\"para\":\"areas\",\"no_summary\":true,\"tags\":[\"x\",\"y\"],\"bogus\":1,\"max_pages\":5}")))
    (should (eq 'areas (plist-get o :para)))
    (should (eq t (plist-get o :no-summary)))
    (should (equal '("x" "y") (plist-get o :tags)))
    (should (= 5 (plist-get o :max-pages)))
    (should-not (plist-member o :bogus)))
  (should (null (cmacs-secondbrain-ingest-options-from-json "")))
  (should-error (cmacs-secondbrain-ingest-options-from-json "[1]")))

(ert-deftest cmacs-secondbrain-ingest-test-validate-path ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (should (cmacs-secondbrain-ingest-validate-path root "03_resources/technical/linux"))
    (should (cmacs-secondbrain-ingest-validate-path root "/03_resources/technical/linux/"))
    (should-not (cmacs-secondbrain-ingest-validate-path root "03_resources/technical/nope"))
    (should (cmacs-secondbrain-ingest-validate-path root "03_resources/technical/nope" t))
    (should-not (cmacs-secondbrain-ingest-validate-path root "../etc"))
    (should-not (cmacs-secondbrain-ingest-validate-path root "/etc"))
    (should-not (cmacs-secondbrain-ingest-validate-path root "04_archives/01_projects"))
    (should (cmacs-secondbrain-ingest-validate-path root "04_archives/01_projects" nil t))
    (should-not (cmacs-secondbrain-ingest-validate-path root "02_areas/dailies"))
    (should-not (cmacs-secondbrain-ingest-validate-path root "random/dir"))))

(ert-deftest cmacs-secondbrain-ingest-test-candidate-dirs ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((dirs (cmacs-secondbrain-ingest-candidate-dirs root)))
      (should (member "03_resources/technical/linux" dirs))
      (should (member "00_inbox" dirs))
      (should-not (cl-some (lambda (d) (string-prefix-p "04_archives" d)) dirs))
      (should-not (member "02_areas/dailies" dirs))
      ;; Shallowest first.
      (should (< (cl-position "03_resources" dirs :test #'equal)
                 (cl-position "03_resources/technical/linux" dirs :test #'equal))))
    (let ((dirs (cmacs-secondbrain-ingest-candidate-dirs root "01_projects")))
      (should (equal '("01_projects" "01_projects/personal" "01_projects/work") dirs)))))

(ert-deftest cmacs-secondbrain-ingest-test-tree ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((tree (cmacs-secondbrain-ingest-tree root)))
      (should (member "03_resources/technical/linux/" tree))
      (should (member "04_archives/" tree)))
    (should (equal '("03_resources/personal/" "03_resources/technical/" "03_resources/technical/linux/")
                   (cmacs-secondbrain-ingest-tree root 'resources)))
    (should-error (cmacs-secondbrain-ingest-tree root 'resources "nope"))
    (with-temp-file (expand-file-name "03_resources/technical/linux/a_note.org" root) (insert "x"))
    (should (member "03_resources/technical/linux/a_note.org"
                    (cmacs-secondbrain-ingest-tree root 'resources "technical" t)))
    (should-not (member "03_resources/technical/linux/00_index.org"
                        (cmacs-secondbrain-ingest-tree root 'resources "technical" t)))))

(ert-deftest cmacs-secondbrain-ingest-test-placement-fallbacks ()
  "A model answer below confidence, outside the tree, or in the archive goes to the inbox."
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((job (cmacs-secondbrain-ingest-job--create :id "t" :input "x" :kind 'text :options nil)))
      (cl-flet ((place (a) (setf (cmacs-secondbrain-ingest-job-analysis job) a)
                       (setf (cmacs-secondbrain-ingest-job-warnings job) nil)
                       (cmacs-secondbrain-ingest--resolve-target-dir job)))
        (should (equal (expand-file-name "03_resources/technical/linux/" root)
                       (place '(:path "03_resources/technical/linux" :confidence 0.9))))
        (should (equal (expand-file-name "00_inbox/" root)
                       (place '(:path "03_resources/technical/linux" :confidence 0.3))))
        (should (cmacs-secondbrain-ingest-job-warnings job))
        (should (equal (expand-file-name "00_inbox/" root)
                       (place '(:path "03_resources/technical/made_up" :confidence 0.99))))
        (should (equal (expand-file-name "00_inbox/" root)
                       (place '(:path "04_archives/01_projects" :confidence 0.99))))
        (should (equal (expand-file-name "00_inbox/" root) (place nil)))))))

(ert-deftest cmacs-secondbrain-ingest-test-explicit-dirs ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (cl-flet ((dir-for (&rest opts)
                (cmacs-secondbrain-ingest--explicit-dir
                 (cmacs-secondbrain-ingest-job--create
                  :id "t" :input "x" :kind 'text
                  :options (cmacs-secondbrain-ingest-normalize-options opts)))))
      (should (equal (expand-file-name "03_resources/personal/" root) (dir-for :para "resources")))
      (should (equal (expand-file-name "00_inbox/" root) (dir-for :para "inbox")))
      (should (equal (expand-file-name "03_resources/technical/linux/" root)
                     (dir-for :para "resources" :category "technical/linux")))
      (should (equal (expand-file-name "01_projects/work/" root) (dir-for :directory "01_projects/work")))
      (should-not (dir-for :para "detect"))
      (should-not (dir-for))
      (let ((cmacs-secondbrain-ingest-create-directories nil))
        (should-error (dir-for :para "resources" :category "does/not/exist")))
      (should-error (dir-for :directory "/etc")))))

;;;; The pipeline, model off -------------------------------------------------------------

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-markdown-explicit ()
  "A Markdown file lands where asked, as a node, in the index, with tags."
  (cmacs-secondbrain-ingest-tests--with-root root
    (let* ((job (cmacs-secondbrain-ingest-tests--run
                 (cmacs-secondbrain-ingest-tests--fixture "sample.md")
                 :para "resources" :category "technical/linux" :tags "linux, Systemd"))
           (file (cmacs-secondbrain-ingest-job-note-file job))
           (text (and file (cmacs-secondbrain-ingest-tests--read file))))
      (should (eq 'done (cmacs-secondbrain-ingest-job-stage job)))
      (should (equal (expand-file-name "03_resources/technical/linux/systemd_timers.org" root) file))
      (should (string-match-p "\\`:PROPERTIES:\n:ID:       [0-9a-f-]+\n:END:\n#\\+title: Systemd Timers\n" text))
      (should (string-match-p "^#\\+filetags: :linux:systemd:$" text))
      (should (string-match-p "^#\\+categories: resources, technical, linux, markdown$" text))
      (should (string-match-p "^#\\+created: [0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:]\\{8\\}[-+][0-9]\\{4\\}$" text))
      (should (string-match-p "^\\* Metadata$" text))
      (should (string-match-p "^\\* Content\n\\*\\* Systemd Timers" text))
      (should-not (string-match-p "^\\* Summary" text))
      ;; The index gained a bullet, after the existing one.
      (let ((index (cmacs-secondbrain-ingest-tests--read
                    (expand-file-name "03_resources/technical/linux/00_index.org" root))))
        (should (string-match-p (format "- \\[\\[id:y\\]\\[Some note\\]\\]\n- \\[\\[id:%s\\]\\[Systemd Timers\\]\\]"
                                        (cmacs-secondbrain-ingest-job-note-id job))
                                index))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-text-creates-directory ()
  "A new category gets an index of its own, linked from the parent index."
  (cmacs-secondbrain-ingest-tests--with-root root
    (let* ((job (cmacs-secondbrain-ingest-tests--run
                 nil :text "* Hello\nSome org text here." :para "areas"
                 :category "personal/newtopic" :title "Custom Title"))
           (file (cmacs-secondbrain-ingest-job-note-file job)))
      (should (eq 'done (cmacs-secondbrain-ingest-job-stage job)))
      (should (equal (expand-file-name "02_areas/personal/newtopic/custom_title.org" root) file))
      (let ((new-index (expand-file-name "02_areas/personal/newtopic/00_index.org" root))
            (parent-index (expand-file-name "02_areas/personal/00_index.org" root)))
        (should (file-exists-p new-index))
        (should (file-exists-p parent-index))
        (should (cmacs-secondbrain-ingest-file-id new-index))
        (should (string-match-p "Custom Title" (cmacs-secondbrain-ingest-tests--read new-index)))
        (should (string-match-p (format "\\[\\[id:%s\\]\\[Newtopic Index\\]\\]"
                                        (cmacs-secondbrain-ingest-file-id new-index))
                                (cmacs-secondbrain-ingest-tests--read parent-index)))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-collision-modes ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((f (cmacs-secondbrain-ingest-tests--fixture "sample.md")))
      (cmacs-secondbrain-ingest-tests--run f :para "inbox")
      (let ((second (cmacs-secondbrain-ingest-tests--run f :para "inbox")))
        (should (equal (expand-file-name "00_inbox/systemd_timers_2.org" root)
                       (cmacs-secondbrain-ingest-job-note-file second))))
      (let ((third (cmacs-secondbrain-ingest-tests--run f :para "inbox" :append t)))
        (should (equal (expand-file-name "00_inbox/systemd_timers.org" root)
                       (cmacs-secondbrain-ingest-job-note-file third)))
        (should (cmacs-secondbrain-ingest-job-appended third))
        (should (string-match-p "^\\* Ingested "
                                (cmacs-secondbrain-ingest-tests--read
                                 (cmacs-secondbrain-ingest-job-note-file third)))))
      (let ((cmacs-secondbrain-ingest-on-collision 'error))
        (let ((fourth (cmacs-secondbrain-ingest-tests--run f :para "inbox")))
          (should (eq 'failed (cmacs-secondbrain-ingest-job-stage fourth)))
          (should (string-match-p "already exists" (cmacs-secondbrain-ingest-job-error fourth))))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-every-fixture ()
  "Every fixture format becomes a node with a body."
  (cmacs-secondbrain-ingest-tests--with-root root
    (dolist (f '("sample.eml" "sample.csv" "sample.html" "sample.json" "sample.md"))
      (let* ((job (cmacs-secondbrain-ingest-tests--run (cmacs-secondbrain-ingest-tests--fixture f)))
             (text (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-job-note-file job))))
        (should (eq 'done (cmacs-secondbrain-ingest-job-stage job)))
        (should (string-match-p "^#\\+title: .+" text))
        (should (string-match-p "^#\\+description: .+" text))
        (should-not (string-match-p "^#\\+description: .*\n.*\n#\\+authors" text))
        (should (string-match-p "^\\* \\(?:Content\\|Message\\|Data\\)$" text))))
    (let ((job (cmacs-secondbrain-ingest-tests--run (cmacs-secondbrain-ingest-tests--fixture "sample.eml"))))
      (should (equal "Quarterly plan – draft" (cmacs-secondbrain-ingest-job-title job)))
      (should (string-match-p "\\`Email from Alice" (cmacs-secondbrain-ingest-job-description job))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-office ()
  (skip-unless (and (fboundp 'cmacs-office-supported-p) (cmacs-office-supported-p)))
  (cmacs-secondbrain-ingest-tests--with-root root
    (dolist (f '("sample.docx" "sample.xlsx" "sample.pptx" "sample.odt"))
      (let* ((job (cmacs-secondbrain-ingest-tests--run
                   (expand-file-name f cmacs-secondbrain-ingest-tests--office-fixtures)))
             (text (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-job-note-file job))))
        (should (eq 'done (cmacs-secondbrain-ingest-job-stage job)))
        (should (string-match-p "Extractor :: cmacs-office" text))
        (should (string-match-p "cmacs office fixture\\|widget" text))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-sanitize ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let* ((job (cmacs-secondbrain-ingest-tests--run
                 nil :text "Contact me at someone@example.com or 555-123-4567 tomorrow."
                 :sanitize t :title "Contact"))
           (text (cmacs-secondbrain-ingest-tests--read (cmacs-secondbrain-ingest-job-note-file job))))
      (should-not (string-match-p "someone@example.com" text))
      (should (string-match-p "<redacted:email>" text))
      (should (string-match-p "Redactions :: 2" text)))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-hooks-and-status ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((infos nil) (finished nil))
      (let ((cmacs-secondbrain-ingest-after-note-functions (list (lambda (info) (push info infos))))
            (cmacs-secondbrain-ingest-after-job-functions (list (lambda (job) (push job finished)))))
        (let* ((job (cmacs-secondbrain-ingest-tests--run
                     (cmacs-secondbrain-ingest-tests--fixture "sample.md") :para "inbox"))
               (status (json-parse-string (cmacs-secondbrain-ingest-status-json
                                           (cmacs-secondbrain-ingest-job-id job))
                                          :object-type 'hash-table)))
          (should (= 1 (length infos)))
          (should (equal (cmacs-secondbrain-ingest-job-note-file job) (plist-get (car infos) :file)))
          (should (eq 'markdown (plist-get (car infos) :kind)))
          (should (memq job finished))
          (should (equal "done" (gethash "stage" status)))
          (should (eq t (gethash "done" status)))
          (should (equal (cmacs-secondbrain-ingest-job-note-file job) (gethash "note_file" status)))
          (should (string-match-p "\\`\\[{" (cmacs-secondbrain-ingest-list-json))))))))

(ert-deftest cmacs-secondbrain-ingest-test-pipeline-failure-is-contained ()
  "An unreadable input fails its job and nothing else."
  (cmacs-secondbrain-ingest-tests--with-root root
    (should-error (cmacs-secondbrain-ingest-run "/no/such/file.pdf"))
    (let ((bad (make-temp-file "sbi-bad-" nil ".pdf")))
      (unwind-protect
          (progn
            (with-temp-file bad (insert "not a pdf"))
            (let ((job (cmacs-secondbrain-ingest-tests--run bad :para "inbox")))
              (should (eq 'failed (cmacs-secondbrain-ingest-job-stage job)))
              (should (stringp (cmacs-secondbrain-ingest-job-error job)))))
        (ignore-errors (delete-file bad))))))

(ert-deftest cmacs-secondbrain-ingest-test-cancel ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let* ((job (cmacs-secondbrain-ingest-enqueue (cmacs-secondbrain-ingest-tests--fixture "sample.md") :para "inbox")))
      (should (eq 'queued (cmacs-secondbrain-ingest-job-stage job)))
      (cmacs-secondbrain-ingest-cancel job)
      (should (eq 'cancelled (cmacs-secondbrain-ingest-job-stage job)))
      (should (eq job (cmacs-secondbrain-ingest-job (cmacs-secondbrain-ingest-job-id job))))
      (should-error (cmacs-secondbrain-ingest-cancel "sbi-nope")))))

(ert-deftest cmacs-secondbrain-ingest-test-plan-and-dry-run ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((plan (cmacs-secondbrain-ingest-plan (cmacs-secondbrain-ingest-tests--fixture "sample.md")
                                               '(:para "resources" :category "technical/linux"))))
      (should (equal "markdown" (plist-get plan :kind)))
      (should (string-suffix-p "03_resources/technical/linux/" (plist-get plan :target)))
      (should (plist-get plan :strategies)))
    (should (equal "inbox" (progn (setq cmacs-secondbrain-ingest-placement 'inbox)
                                  (and (string-match-p "00_inbox"
                                                       (plist-get (cmacs-secondbrain-ingest-plan
                                                                   (cmacs-secondbrain-ingest-tests--fixture "sample.md") nil)
                                                                  :target))
                                       "inbox"))))
    (let ((cmacs-secondbrain-ingest-placement 'detect))
      (should (equal "detect" (plist-get (cmacs-secondbrain-ingest-plan
                                          (cmacs-secondbrain-ingest-tests--fixture "sample.md") nil)
                                         :target))))
    (let ((out (json-parse-string
                (cmacs-secondbrain-ingest-from-json
                 (json-serialize (vector (cmacs-secondbrain-ingest-tests--fixture "sample.md")))
                 "{\"dry_run\": true, \"para\": \"inbox\"}")
                :object-type 'hash-table :array-type 'list)))
      (should (= 1 (length out)))
      (should (equal "markdown" (gethash "kind" (car out))))
      ;; A dry run queues nothing.
      (should (null cmacs-secondbrain-ingest--jobs)))))

(ert-deftest cmacs-secondbrain-ingest-test-from-json-runs ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let* ((out (json-parse-string
                 (cmacs-secondbrain-ingest-from-json
                  (json-serialize (vector (cmacs-secondbrain-ingest-tests--fixture "sample.md")))
                  "{\"para\": \"inbox\", \"no_ai\": true}")
                 :object-type 'hash-table :array-type 'list))
           (id (gethash "id" (car out))))
      (should (stringp id))
      (cmacs-secondbrain-ingest-wait id 30)
      (should (equal "done" (gethash "stage" (json-parse-string (cmacs-secondbrain-ingest-status-json id)
                                                                :object-type 'hash-table)))))))

(ert-deftest cmacs-secondbrain-ingest-test-text-guess ()
  (should (eq 'org (cmacs-secondbrain-ingest-guess-text-format "#+title: x\n* h")))
  (should (eq 'markdown (cmacs-secondbrain-ingest-guess-text-format "# Title\n\nsome **bold**")))
  (should (eq 'data (cmacs-secondbrain-ingest-guess-text-format "{\"a\": 1}")))
  (should (eq 'html (cmacs-secondbrain-ingest-guess-text-format "<!DOCTYPE html><html>")))
  (should (eq 'text (cmacs-secondbrain-ingest-guess-text-format "plain words"))))

(ert-deftest cmacs-secondbrain-ingest-test-register-in-index-idempotent ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (let ((dir (expand-file-name "03_resources/technical/linux" root)))
      (cmacs-secondbrain-ingest-register-in-index dir "zzz" "Zed" root)
      (cmacs-secondbrain-ingest-register-in-index dir "zzz" "Zed" root)
      (let ((text (cmacs-secondbrain-ingest-tests--read (expand-file-name "00_index.org" dir))))
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "id:zzz" l)) (split-string text "\n"))))))
    ;; The root index has a Contents heading; the bullet goes under it.
    (cmacs-secondbrain-ingest-register-in-index root "qqq" "Queue [x]" root)
    (let ((text (cmacs-secondbrain-ingest-tests--read (expand-file-name "00_index.org" root))))
      (should (string-match-p "\\* Contents\n- \\[\\[id:x\\]\\[Existing\\]\\]\n- \\[\\[id:qqq\\]\\[Queue x\\]\\]" text)))))

(ert-deftest cmacs-secondbrain-ingest-test-doctor-shape ()
  (let ((d (cmacs-secondbrain-ingest-doctor)))
    (should (assq 'pandoc d))
    (should (assq 'cmacs-ai d))
    (should (cl-every (lambda (e) (and (symbolp (car e)) (stringp (nth 2 e)))) d))))

(ert-deftest cmacs-secondbrain-ingest-test-queue-buffer-renders ()
  (cmacs-secondbrain-ingest-tests--with-root root
    (cmacs-secondbrain-ingest-tests--run (cmacs-secondbrain-ingest-tests--fixture "sample.md") :para "inbox")
    (save-window-excursion
      (cmacs-secondbrain-ingest-queue)
      (with-current-buffer cmacs-secondbrain-ingest-buffer-name
        (should (derived-mode-p 'cmacs-secondbrain-ingest-mode))
        (should (string-match-p "sbi-[0-9]+ +done" (buffer-string)))
        (should (string-match-p "Systemd Timers" (buffer-string)))))
    (kill-buffer cmacs-secondbrain-ingest-buffer-name)))

;;;; Surfaces -----------------------------------------------------------------------

(defun cmacs-secondbrain-ingest-tests--pid-name ()
  (format "org.cmacs.Editor.Pid%d" (emacs-pid)))

(defun cmacs-secondbrain-ingest-tests--wait-for-name ()
  "Pump the loop until this instance owns its per-PID bus name.
`cmacs-dbus-start' returns before `g_bus_own_name_on_connection' has
acquired the name; the first call after it raced that and got
ServiceUnknown."
  (let ((deadline (time-add (current-time) 5)))
    (while (and (not (ignore-errors (dbus-ping :session (cmacs-secondbrain-ingest-tests--pid-name) 200)))
                (time-less-p (current-time) deadline))
      (accept-process-output nil 0.05)
      (sit-for 0.02))))

(defmacro cmacs-secondbrain-ingest-tests--with-service (&rest body)
  (declare (indent 0))
  `(unwind-protect (progn (cmacs-dbus-start)
                          (cmacs-secondbrain-ingest-tests--wait-for-name)
                          ,@body)
     (cmacs-dbus-stop)))

(defun cmacs-secondbrain-ingest-tests--dbus-p ()
  (and (fboundp 'cmacs-dbus-start) (fboundp 'cmacs-feature-p)
       (cmacs-feature-p 'glib) (cmacs-feature-p 'secondbrain)
       (require 'dbus nil t)))

(defun cmacs-secondbrain-ingest-tests--call (method &rest args)
  "Call METHOD on THIS instance's SecondBrain interface over the session bus.
Addressed by the per-PID name: the well-known `org.cmacs.Editor' may be
owned by the user's live session, whose build could predate this
interface -- and a test must never drive that session anyway."
  (let ((name (cmacs-secondbrain-ingest-tests--pid-name)))
    (apply #'dbus-call-method :session name "/org/cmacs/Editor"
           "org.cmacs.Editor1.SecondBrain" method :timeout 20000 args)))

(ert-deftest cmacs-secondbrain-ingest-test-dbus-tree-and-doctor ()
  (skip-unless (cmacs-secondbrain-ingest-tests--dbus-p))
  (cmacs-secondbrain-ingest-tests--with-root root
    (cmacs-secondbrain-ingest-tests--with-service
      (let ((tree (json-parse-string (cmacs-secondbrain-ingest-tests--call "Tree" "resources" "" nil)
                                     :array-type 'list)))
        (should (member "03_resources/technical/linux/" tree)))
      (let ((doc (json-parse-string (cmacs-secondbrain-ingest-tests--call "Doctor")
                                    :object-type 'hash-table :array-type 'list)))
        (should (cl-some (lambda (e) (equal "pandoc" (gethash "name" e))) doc))))))

(ert-deftest cmacs-secondbrain-ingest-test-dbus-ingest-roundtrip ()
  (skip-unless (cmacs-secondbrain-ingest-tests--dbus-p))
  (cmacs-secondbrain-ingest-tests--with-root root
    (cmacs-secondbrain-ingest-tests--with-service
      (let* ((jobs (json-parse-string
                    (cmacs-secondbrain-ingest-tests--call
                     "Ingest" (json-serialize (vector (cmacs-secondbrain-ingest-tests--fixture "sample.md")))
                     "{\"para\":\"inbox\",\"no_ai\":true}")
                    :object-type 'hash-table :array-type 'list))
             (id (gethash "id" (car jobs))))
        (should (stringp id))
        (cmacs-secondbrain-ingest-wait id 30)
        (let ((status (json-parse-string (cmacs-secondbrain-ingest-tests--call "IngestStatus" id)
                                         :object-type 'hash-table)))
          (should (equal "done" (gethash "stage" status)))
          (should (file-exists-p (gethash "note_file" status))))
        (should (string-match-p "\\`\\[" (cmacs-secondbrain-ingest-tests--call "IngestList")))
        (should-error (cmacs-secondbrain-ingest-tests--call "IngestStatus" "sbi-nope"))))))

(defvar cmacs-secondbrain-ingest-tests--emacsctl
  (expand-file-name "../../src/emacsctl"
                    (file-name-directory (or load-file-name buffer-file-name default-directory))))

(defun cmacs-secondbrain-ingest-tests--emacsctl (&rest args)
  "Run emacsctl against this instance; return (EXIT . OUTPUT)."
  (let* ((buf (generate-new-buffer " *emacsctl-sb-test*"))
         (proc (make-process :name "emacsctl-sb" :buffer buf :noquery t :sentinel #'ignore
                             :command (append (list cmacs-secondbrain-ingest-tests--emacsctl
                                                    "--instance" (number-to-string (emacs-pid)))
                                              args))))
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1)
            (sit-for 0.05))
          (cons (process-exit-status proc)
                (with-current-buffer buf (buffer-string))))
      (kill-buffer buf))))

(ert-deftest cmacs-secondbrain-ingest-test-emacsctl-help-and-aliases ()
  (skip-unless (and (file-executable-p cmacs-secondbrain-ingest-tests--emacsctl)
                    (fboundp 'cmacs-dbus-start)))
  (let ((help (cmacs-secondbrain-ingest-tests--emacsctl "sb" "--help")))
    (should (= 0 (car help)))
    (should (string-match-p "ingest" (cdr help)))
    (should (string-match-p "tree" (cdr help))))
  (let ((alias (cmacs-secondbrain-ingest-tests--emacsctl "second-brain" "--help")))
    (should (= 0 (car alias)))
    (should (string-match-p "ingest" (cdr alias))))
  (let ((verb (cmacs-secondbrain-ingest-tests--emacsctl "secondbrain" "ingest" "--help")))
    (should (= 0 (car verb)))
    (should (string-match-p "--para" (cdr verb)))
    (should (string-match-p "--wait" (cdr verb)))))

(ert-deftest cmacs-secondbrain-ingest-test-emacsctl-tree-and-ingest ()
  (skip-unless (cmacs-secondbrain-ingest-tests--dbus-p))
  (skip-unless (file-executable-p cmacs-secondbrain-ingest-tests--emacsctl))
  (cmacs-secondbrain-ingest-tests--with-root root
    (cmacs-secondbrain-ingest-tests--with-service
      (let ((tree (cmacs-secondbrain-ingest-tests--emacsctl "sb" "tree" "-p" "resources" "-o" "raw")))
        (should (= 0 (car tree)))
        (should (string-match-p "03_resources/technical/linux/" (cdr tree))))
      (let ((dry (cmacs-secondbrain-ingest-tests--emacsctl
                  "sb" "ingest" "--dry-run" "-p" "inbox" "-o" "json"
                  (cmacs-secondbrain-ingest-tests--fixture "sample.md"))))
        (should (= 0 (car dry)))
        (should (string-match-p "\"kind\" *: *\"markdown\"" (cdr dry))))
      (let ((run (cmacs-secondbrain-ingest-tests--emacsctl
                  "sb" "ingest" "-N" "-p" "inbox" "-w" "-o" "json"
                  (cmacs-secondbrain-ingest-tests--fixture "sample.md"))))
        (should (= 0 (car run)))
        (should (string-match-p "\"stage\" *: *\"done\"" (cdr run)))
        (should (string-match-p "systemd_timers.org" (cdr run))))
      (let ((jobs (cmacs-secondbrain-ingest-tests--emacsctl "sb" "jobs" "-o" "json")))
        (should (= 0 (car jobs)))
        (should (string-match-p "sbi-" (cdr jobs)))))))

(provide 'cmacs-secondbrain-ingest-tests)
;;; cmacs-secondbrain-ingest-tests.el ends here
