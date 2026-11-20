;;; cmacs-journal-tests.el --- ERT tests for the activity journal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The journal is Elisp over hooks, so all of it runs here without a
;; compositor: events are fed to `cmacs-journal--observe' against a
;; clock the test owns, and the hook functions are called directly.
;;
;; Every test runs in a private journal directory with no filter files
;; and no shipped default rules unless it asks for them, so a rule in
;; the developer's own ~/.config never decides a result.
;;
;; The YAML reader is the C primitive `cmacs-yaml-parse-file'.  The rule
;; compiler is tested on the alist `json-parse-string' makes of a parsed
;; document, which needs no primitive; the file path is tested with a
;; stub that returns JSON text, and -- on a binary without the primitive
;; -- as the fail-closed case it is.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-journal)
(require 'cmacs-journal-report)

(defvar cmacs-journal-tests--clock 1000000.0
  "The time the journal sees during a test.")

(defmacro cmacs-journal-tests--with-journal (&rest body)
  "Run BODY with the journal on, in a temporary directory, on a test clock."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "cmacs-journal-test" t))
          (cmacs-journal-directory (expand-file-name "state/journal" root))
          (cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters nil)
          (cmacs-journal-min-span 2)
          (cmacs-journal-merge-gap 1.0)
          (cmacs-journal-retention-days nil)
          (cmacs-journal-expose-to-agents nil)
          (cmacs-journal-idle-threshold nil)
          (cmacs-journal-tests--clock 1000000.0)
          (cmacs-journal-time-function (lambda () cmacs-journal-tests--clock))
          (cmacs-journal--open nil)
          (cmacs-journal--queue nil)
          (cmacs-journal--paused nil)
          (cmacs-journal--locked nil)
          (cmacs-journal--pending nil)
          (cmacs-journal--external-focus nil)
          (cmacs-journal--focus-id nil)
          (cmacs-journal--in-tool-call nil)
          (cmacs-journal--file-cache (make-hash-table :test #'equal))
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-journal-mode t)
          (inhibit-interaction nil)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (unwind-protect
         (progn (cmacs-journal-filters-reload) ,@body)
       (delete-directory root t))))

(defun cmacs-journal-tests--advance (seconds)
  "Move the test clock on by SECONDS."
  (setq cmacs-journal-tests--clock (+ cmacs-journal-tests--clock seconds)))

(defun cmacs-journal-tests--focus (app title &rest more)
  "Observe a focused window of APP titled TITLE (plus MORE fields)."
  (cmacs-journal--observe
   (append (list :kind 'focus :app app :title title) more)))

(defun cmacs-journal-tests--reload (&rest bindings)
  "Reload the filters, returning non-nil when usable.  BINDINGS unused."
  (ignore bindings)
  (cmacs-journal-filters-reload))

;;;; Spans

(ert-deftest cmacs-journal-test-identical-observations-are-one-span ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 20)
    (cmacs-journal-tests--focus "firefox" "News")
    (should (null cmacs-journal--queue))
    (cmacs-journal-tests--advance 5)
    (cmacs-journal-tests--focus "foot" "shell")
    (should (= (length cmacs-journal--queue) 1))
    (let ((span (car cmacs-journal--queue)))
      (should (equal (plist-get span :app) "firefox"))
      (should (= (plist-get span :time) 1000000.0))
      (should (= (plist-get span :end) 1000035.0))
      (should (= (plist-get span :duration) 35.0)))))

(ert-deftest cmacs-journal-test-a-changed-title-starts-a-new-span ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "firefox" "Weather")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (should (equal (mapcar (lambda (e) (plist-get e :title))
                           (reverse cmacs-journal--queue))
                   '("News" "Weather")))))

(ert-deftest cmacs-journal-test-short-spans-are-dropped ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 1.5)
    (cmacs-journal-tests--focus "foot" "shell")
    (should (null cmacs-journal--queue))
    (cmacs-journal-tests--advance 2)
    (cmacs-journal--observe nil)
    (should (equal (mapcar (lambda (e) (plist-get e :app)) cmacs-journal--queue)
                   '("foot")))))

(ert-deftest cmacs-journal-test-a-span-reopened-at-once-is-rejoined ()
  ;; Focus is nowhere for a moment while a workspace switches.
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (should (= (length cmacs-journal--queue) 1))
    (cmacs-journal-tests--advance 0.3)
    (cmacs-journal-tests--focus "firefox" "News")
    (should (null cmacs-journal--queue))
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (should (= (length cmacs-journal--queue) 1))
    (should (< (abs (- (plist-get (car cmacs-journal--queue) :duration) 20.3))
               0.001))))

(ert-deftest cmacs-journal-test-nothing-is-recorded-while-off-or-paused ()
  (cmacs-journal-tests--with-journal
    (let ((cmacs-journal-mode nil))
      (cmacs-journal-tests--focus "firefox" "News")
      (should (null cmacs-journal--open)))
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-pause)
    (should (null cmacs-journal--open))
    (should (= (length cmacs-journal--queue) 1))
    (cmacs-journal-tests--focus "foot" "shell")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "firefox" "News")
    (should (null cmacs-journal--open))
    (should (= (length cmacs-journal--queue) 1))))

;;;; Lock

(ert-deftest cmacs-journal-test-lock-closes-the-span-and-stops-recording ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 30)
    (cmacs-journal--on-lock t)
    (should (null cmacs-journal--open))
    (should (= (length cmacs-journal--queue) 1))
    (should (= (plist-get (car cmacs-journal--queue) :end) 1000030.0))
    ;; Locked: whatever the compositor reports is not attention.
    (cmacs-journal-tests--advance 600)
    (cmacs-journal-tests--focus "gowl-lock" "Locked")
    (cmacs-journal--on-window-change)
    (should (null cmacs-journal--open))
    (should (null cmacs-journal--pending))
    (should (= (length cmacs-journal--queue) 1))
    (should-not (cmacs-journal-recording-p))
    ;; Unlocked: recording again, and the locked stretch is a gap.
    (cl-letf (((symbol-function 'gowl-focused-client) (lambda (&rest _) nil)))
      (cmacs-journal--on-lock nil))
    (should (cmacs-journal-recording-p))
    (cmacs-journal-tests--focus "firefox" "News")
    (should (= (plist-get cmacs-journal--open :time) 1000630.0))))

(ert-deftest cmacs-journal-test-hooks-never-signal ()
  (cmacs-journal-tests--with-journal
    (cl-letf (((symbol-function 'gowl-client-info)
               (lambda (&rest _) (error "The client is gone")))
              ((symbol-function 'gowl-client-pid)
               (lambda (&rest _) (error "The client is gone")))
              ((symbol-function 'gowl-focused-client)
               (lambda (&rest _) (error "No compositor"))))
      (cmacs-journal-tests--focus "firefox" "News")
      (cmacs-journal-tests--advance 10)
      (cmacs-journal--on-focus 'a-client)
      ;; Unknown focus is recorded as no focus, not as the old window.
      (should (null cmacs-journal--open))
      (cmacs-journal--on-title 'a-client)
      (cmacs-journal--refocus 'a-monitor)
      (cmacs-journal--on-lock nil)
      (cmacs-journal--on-agent-run 7 'done "output")
      (cmacs-journal--on-gsurf-change (current-buffer) "x"))))

(ert-deftest cmacs-journal-test-a-gowl-client-becomes-a-focus-span ()
  (cmacs-journal-tests--with-journal
    (cl-letf (((symbol-function 'gowl-client-info)
               (lambda (&rest _)
                 '((id . 12) (title . "Inbox") (app-id . "thunderbird")
                   (tags . 5) (floating . nil) (embedded . nil)
                   (geometry 0 0 10 10))))
              ((symbol-function 'gowl-client-pid) (lambda (&rest _) 4242))
              ((symbol-function 'gowl-monitor-info)
               (lambda (&rest _) '((name . "DP-1")))))
      (cmacs-journal--on-focus 'a-client)
      (should (equal (plist-get cmacs-journal--open :kind) 'focus))
      (should (equal (plist-get cmacs-journal--open :app) "thunderbird"))
      (should (equal (plist-get cmacs-journal--open :title) "Inbox"))
      (should (equal (plist-get cmacs-journal--open :pid) 4242))
      (should (equal (plist-get cmacs-journal--open :tags) '(1 3)))
      (should (equal (plist-get cmacs-journal--open :monitor) "DP-1"))
      (should cmacs-journal--external-focus)
      ;; A buffer changing inside Emacs is not attention meanwhile.
      (cmacs-journal--on-window-change)
      (should (null cmacs-journal--pending)))))

(ert-deftest cmacs-journal-test-emacs-own-frame-is-a-buffer-not-a-focus ()
  (cmacs-journal-tests--with-journal
    (cl-letf (((symbol-function 'gowl-client-info)
               (lambda (&rest _) '((id . 3) (title . "emacs") (app-id . "emacs")
                                   (tags . 1))))
              ((symbol-function 'gowl-client-pid)
               (lambda (&rest _) (emacs-pid)))
              ((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
      (cmacs-journal--on-focus 'a-client)
      (should-not cmacs-journal--external-focus)
      (should cmacs-journal--pending)
      (with-temp-buffer
        (rename-buffer "journal-test-buffer" t)
        (setq buffer-file-name "/tmp/journal-test/notes.org")
        (cl-letf (((symbol-function 'cmacs-journal--selected-buffer)
                   (let ((b (current-buffer))) (lambda () b))))
          (cmacs-journal--resolve-buffer))
        (setq buffer-file-name nil))
      (should (eq (plist-get cmacs-journal--open :kind) 'buffer))
      (should (equal (plist-get cmacs-journal--open :file)
                     "/tmp/journal-test/notes.org"))
      (should (equal (plist-get cmacs-journal--open :mode) "fundamental-mode")))))

;;;; Filters, from Elisp

(ert-deftest cmacs-journal-test-exclude-leaves-a-gap-and-no-residue ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters
          '((:match ((:app . "keepassxc")) :exclude t)))
    (should (cmacs-journal-filters-reload))
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "org.keepassxc.KeePassXC" "Bank login - KeePassXC")
    ;; The open span closed; nothing took its place.
    (should (null cmacs-journal--open))
    (cmacs-journal-tests--advance 60)
    (cmacs-journal-tests--focus "firefox" "News")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (should (= (length cmacs-journal--queue) 2))
    (let ((spans (reverse cmacs-journal--queue)))
      (should (= (plist-get (nth 0 spans) :end) 1000010.0))
      (should (= (plist-get (nth 1 spans) :time) 1000070.0)))
    ;; Not a trace of it, in memory or on disk.
    (should-not (string-match-p "eepass\\|Bank"
                                (format "%S %S" cmacs-journal--queue
                                        cmacs-journal--open)))
    (cmacs-journal-flush)
    (dolist (file (directory-files cmacs-journal-directory t "\\.jsonl\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (string-match-p "eepass\\|Bank\\|exclu\\|rule\\|filter"
                                    (buffer-string)))))))

(ert-deftest cmacs-journal-test-drop-blanks-fields ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters '((:match ((:url . "bank")) :drop (:url :title))))
    (should (cmacs-journal-filters-reload))
    (let ((out (cmacs-journal-filter-apply
                (list :kind 'url :app "gsurf" :title "My Bank"
                      :url "https://bank.example/accounts"))))
      (should out)
      (should (null (plist-get out :url)))
      (should (null (plist-get out :title)))
      (should (equal (plist-get out :app) "gsurf")))
    ;; Case is ignored by default: missing a title costs more than
    ;; losing one.
    (should (null (plist-get (cmacs-journal-filter-apply
                              (list :kind 'url :title "x"
                                    :url "https://BANK.example/"))
                             :url)))))

(ert-deftest cmacs-journal-test-replace-sanitises-part-of-a-field ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters
          '((:match ((:title . "Invoice"))
             :replace ((:title "[0-9]\\{6,\\}" "***")))
            (:match ((:kind . "url"))
             :replace ((:url "\\?.*\\'" "")))))
    (should (cmacs-journal-filters-reload))
    (should (equal (plist-get (cmacs-journal-filter-apply
                               (list :kind 'focus :app "evince"
                                     :title "Invoice 20261120 for 12345"))
                              :title)
                   "Invoice *** for 12345"))
    (should (equal (plist-get (cmacs-journal-filter-apply
                               (list :kind 'url
                                     :url "https://example.org/a?token=abc"))
                              :url)
                   "https://example.org/a"))))

(ert-deftest cmacs-journal-test-hash-hides-text-but-still-aggregates ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters '((:match ((:app . "evince")) :hash (:title :file))))
    (should (cmacs-journal-filters-reload))
    (let ((a (cmacs-journal-filter-apply
              (list :kind 'focus :app "evince" :title "Contract.pdf")))
          (b (cmacs-journal-filter-apply
              (list :kind 'focus :app "evince" :title "Contract.pdf")))
          (c (cmacs-journal-filter-apply
              (list :kind 'focus :app "evince" :title "Other.pdf"))))
      (should (string-match-p "\\`#[0-9a-f]\\{12\\}\\'" (plist-get a :title)))
      (should (equal (plist-get a :title) (plist-get b :title)))
      (should-not (equal (plist-get a :title) (plist-get c :title)))
      ;; A different install hashes differently.
      (let ((cmacs-journal-filter-hash-key "another-key-entirely-0123456789ab"))
        (should-not (equal (plist-get a :title)
                           (plist-get (cmacs-journal-filter-apply
                                       (list :kind 'focus :app "evince"
                                             :title "Contract.pdf"))
                                      :title))))
      ;; No key: blank, never the text.
      (let ((cmacs-journal-filter-hash-key nil))
        (should (null (plist-get (cmacs-journal-filter-apply
                                  (list :kind 'focus :app "evince"
                                        :title "Contract.pdf"))
                                 :title)))))
    ;; Hashed titles coalesce like any other.
    (cmacs-journal-tests--focus "evince" "Contract.pdf")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "evince" "Contract.pdf")
    (should (null cmacs-journal--queue))))

(ert-deftest cmacs-journal-test-a-predicate-may-be-the-match ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters
          (list (list :match (lambda (event)
                               (equal (plist-get event :monitor) "HDMI-A-1"))
                      :exclude t)))
    (should (cmacs-journal-filters-reload))
    (should-not (cmacs-journal-filter-apply
                 (list :kind 'focus :app "mpv" :monitor "HDMI-A-1")))
    (should (cmacs-journal-filter-apply
             (list :kind 'focus :app "mpv" :monitor "DP-1")))))

(ert-deftest cmacs-journal-test-an-exclude-sees-the-event-before-any-drop ()
  ;; Rule order must not let one rule's `drop' blind another's `exclude'.
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters
          '((:match ((:app . "firefox")) :drop (:title))
            (:match ((:title . "secret")) :exclude t)))
    (should (cmacs-journal-filters-reload))
    (should-not (cmacs-journal-filter-apply
                 (list :kind 'focus :app "firefox" :title "a secret page")))))

(ert-deftest cmacs-journal-test-a-signalling-rule-drops-the-event ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filters
          (list (list :match (lambda (_) (error "Boom")) :drop '(:title))))
    (should (cmacs-journal-filters-reload))
    (should-not (cmacs-journal-filter-apply
                 (list :kind 'focus :app "firefox" :title "x")))))

(ert-deftest cmacs-journal-test-shipped-defaults-cover-the-obvious ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-default-filters
          ;; The shipped value; the macro has let-bound the variable.
          (eval (car (get 'cmacs-journal-default-filters 'standard-value)) t))
    (should (cmacs-journal-filters-reload))
    (dolist (event (list
                    (list :kind 'focus :app "org.keepassxc.KeePassXC" :title "x")
                    (list :kind 'focus :app "Bitwarden" :title "Vault")
                    (list :kind 'focus :app "firefox"
                          :title "Example - Mozilla Firefox Private Browsing")
                    (list :kind 'focus :app "pinentry-gnome3" :title "x")
                    (list :kind 'focus :app "polkit-gnome-authentication-agent-1")
                    (list :kind 'url :app "gsurf" :url "https://example.org/"
                          :detail "container:temporary")
                    (list :kind 'buffer :app "emacs" :file "~/.authinfo.gpg")))
      (should-not (cmacs-journal-filter-apply event)))
    (should (cmacs-journal-filter-apply
             (list :kind 'focus :app "firefox" :title "Example - Mozilla Firefox")))
    (should (cmacs-journal-filter-apply
             (list :kind 'url :app "gsurf" :url "https://example.org/"
                   :detail "container:work")))))

;;;; Filters, from YAML

(defconst cmacs-journal-tests--yaml-data
  ;; What `json-parse-string' (alists, lists) makes of the documented file.
  '((filters
     . (((match . ((app . "^org\\.keepassxc"))) (exclude . t))
        ((match . ((url . "bank"))) (drop . ("url" "title")))
        ((match . ((title . "Invoice")))
         (replace . (((field . "title") (regexp . "\\d{6,}") (with . "***"))))
         (hash . ("file"))))))
  "The example from the documentation, as parsed YAML.")

(ert-deftest cmacs-journal-test-yaml-rules-do-what-elisp-rules-do ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filter--rules
          (cmacs-journal-filter--rules-from-yaml-data
           cmacs-journal-tests--yaml-data "test.yaml"))
    ;; exclude
    (should-not (cmacs-journal-filter-apply
                 (list :kind 'focus :app "org.keepassxc.KeePassXC" :title "x")))
    ;; drop
    (let ((out (cmacs-journal-filter-apply
                (list :kind 'url :url "https://bank.example/" :title "Bank"))))
      (should (and out (null (plist-get out :url)) (null (plist-get out :title)))))
    ;; replace (a Perl-style \d{6,}) and hash
    (let ((out (cmacs-journal-filter-apply
                (list :kind 'buffer :title "Invoice 20261120"
                      :file "~/Documents/invoice.pdf"))))
      (should (equal (plist-get out :title) "Invoice ***"))
      (should (string-match-p "\\`#[0-9a-f]\\{12\\}\\'" (plist-get out :file))))
    ;; untouched
    (should (equal (cmacs-journal-filter-apply (list :kind 'focus :app "foot"))
                   (list :kind 'focus :app "foot")))))

(ert-deftest cmacs-journal-test-yaml-regexps-are-translated ()
  (should (equal (cmacs-journal-filter--pcre-to-emacs "\\d{6,}") "[0-9]\\{6,\\}"))
  (should (equal (cmacs-journal-filter--pcre-to-emacs "^(foo|bar)\\.baz$")
                 "^\\(foo\\|bar\\)\\.baz$"))
  (should (equal (cmacs-journal-filter--pcre-to-emacs "(?:a|b)\\(x\\)")
                 "\\(?:a\\|b\\)(x)"))
  (should (equal (cmacs-journal-filter--pcre-to-emacs "[\\d\\s_-]+") "[0-9[:space:]_-]+"))
  (should (equal (cmacs-journal-filter--pcre-to-emacs "[^\\]x]") "[^]x]"))
  (should (equal (cmacs-journal-filter--pcre-to-emacs "(?i)Bank\\b") "Bank\\b"))
  (should (string-match-p (cmacs-journal-filter--pcre-to-emacs "acct \\d{4}-\\d{4}")
                          "acct 1234-5678"))
  ;; No Emacs equivalent: an error, which the loader turns into a refusal.
  (should-error (cmacs-journal-filter--pcre-to-emacs "(?=look)ahead"))
  (should-error (cmacs-journal-filter--pcre-to-emacs "\\p{L}+"))
  (should-error (cmacs-journal-filter--pcre-to-emacs "[abc")))

(ert-deftest cmacs-journal-test-yaml-rejects-what-it-does-not-understand ()
  (dolist (data '(((filterz . nil))                                   ; top-level key
                  ((filters . (((match . ((app . "x"))) (exclud . t))))) ; rule key
                  ((filters . (((match . ((window . "x"))) (exclude . t))))) ; field
                  ((filters . (((match . ((app . "x"))) (drop . ("kind")))))) ; action field
                  ((filters . (((match . ((app . "x")))))))            ; no action
                  ((filters . (((exclude . t)))))                      ; no match
                  ((filters . (((match . ((app . "(")))  (exclude . t))))) ; bad regexp
                  ((filters . (((match . ((app . "x"))) (exclude . "maybe")))))
                  ((filters . (((match . ((app . "x")))
                                (replace . (((field . "title") (regex . "a"))))))))
                  ((filters . "everything"))
                  "just a string"))
    (should-error (cmacs-journal-filter--rules-from-yaml-data data "bad.yaml")))
  ;; An empty document is no rules, which is fine.
  (should (null (cmacs-journal-filter--rules-from-yaml-data nil "empty.yaml")))
  (should (null (cmacs-journal-filter--rules-from-yaml-data
                 '((filters . nil)) "empty.yaml"))))

(ert-deftest cmacs-journal-test-elisp-rejects-a-bad-rule-too ()
  (cmacs-journal-tests--with-journal
    (dolist (rules '(((:match ((:app . "x")) :exclud t))
                     ((:match ((:nope . "x")) :exclude t))
                     ((:match ((:app . "\\(")) :exclude t))
                     ((:match ((:app . "x"))))
                     ((:exclude t))))
      (setq cmacs-journal-filters rules)
      (should-not (cmacs-journal-filters-reload))
      (should-not (cmacs-journal-filter-ready-p))
      (should-not (cmacs-journal-filter-apply (list :kind 'focus :app "foot"))))))

(ert-deftest cmacs-journal-test-a-missing-filter-file-is-fine ()
  (cmacs-journal-tests--with-journal
    (setq cmacs-journal-filter-files
          (list (expand-file-name "nope.yaml" cmacs-journal-directory)))
    (should (cmacs-journal-filters-reload))
    (should (cmacs-journal-filter-ready-p))))

(ert-deftest cmacs-journal-test-a-bad-filter-file-fails-closed ()
  (cmacs-journal-tests--with-journal
    (add-hook 'cmacs-journal-filter-changed-functions
              #'cmacs-journal--filters-changed)
    (let ((file (expand-file-name "filters.yaml" root)))
      (setq cmacs-journal-filter-files (list file))
      (cmacs-journal-tests--focus "firefox" "News")
      (cmacs-journal-tests--advance 10)
      (with-temp-file file (insert "filters:\n  - match: {app: 'x'}\n    exclud: true\n"))
      ;; Whatever reads the file -- the real primitive on a new binary,
      ;; nothing at all on an old one, this stub in between -- an
      ;; unknown key must stop the recording.
      (cl-letf (((symbol-function 'cmacs-yaml-parse-file)
                 (lambda (&rest _)
                   "{\"filters\":[{\"match\":{\"app\":\"x\"},\"exclud\":true}]}")))
        (should-not (cmacs-journal-filters-reload)))
      (should-not (cmacs-journal-filter-ready-p))
      (should (cmacs-journal-filter-error))
      (should-not (cmacs-journal-recording-p))
      (should (eq cmacs-journal--paused 'filter))
      ;; The span that was open closed, and nothing new is taken.
      (should (null cmacs-journal--open))
      (cmacs-journal-tests--focus "firefox" "More news")
      (should (null cmacs-journal--open))
      (should-not (cmacs-journal-filter-apply (list :kind 'focus :app "foot")))
      ;; A reader that signals (invalid YAML) is the same refusal.
      (cl-letf (((symbol-function 'cmacs-yaml-parse-file)
                 (lambda (&rest _) (error "Line 3: mapping values are not allowed"))))
        (should-not (cmacs-journal-filters-reload)))
      (should-not (cmacs-journal-recording-p))
      ;; Fixed: recording starts again by itself.
      (cl-letf (((symbol-function 'cmacs-yaml-parse-file)
                 (lambda (&rest _)
                   "{\"filters\":[{\"match\":{\"app\":\"x\"},\"exclude\":true}]}"))
                ((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
        (should (cmacs-journal-filters-reload)))
      (should (cmacs-journal-recording-p))
      (should-not (cmacs-journal-filter-apply (list :kind 'focus :app "x")))
      (should (cmacs-journal-filter-apply (list :kind 'focus :app "foot"))))))

(ert-deftest cmacs-journal-test-a-present-file-with-no-yaml-reader-fails-closed ()
  ;; Present but unreadable must never mean "no rules".
  (cmacs-journal-tests--with-journal
    (let ((file (expand-file-name "filters.yaml" root)))
      (with-temp-file file (insert "filters: []\n"))
      (setq cmacs-journal-filter-files (list file))
      (cl-letf (((symbol-function 'cmacs-yaml-parse-file) nil))
        (should-not (fboundp 'cmacs-yaml-parse-file))
        (should-not (cmacs-journal-filters-reload))
        (should-not (cmacs-journal-filter-ready-p))))))

(ert-deftest cmacs-journal-test-a-changed-filter-file-is-noticed ()
  (cmacs-journal-tests--with-journal
    (let ((file (expand-file-name "filters.yaml" root))
          (json "{\"filters\":[]}"))
      (setq cmacs-journal-filter-files (list file))
      (cl-letf (((symbol-function 'cmacs-yaml-parse-file) (lambda (&rest _) json)))
        (should (cmacs-journal-filters-reload))
        (should (cmacs-journal-filter-apply (list :kind 'focus :app "x")))
        ;; The file appears; the mtime fallback picks it up.
        (with-temp-file file (insert "filters: [...]\n"))
        (setq json "{\"filters\":[{\"match\":{\"app\":\"x\"},\"exclude\":true}]}")
        (cmacs-journal-filter-check)
        (should-not (cmacs-journal-filter-apply (list :kind 'focus :app "x")))))))

(ert-deftest cmacs-journal-test-the-yaml-primitive-reads-a-real-file ()
  (skip-unless (fboundp 'cmacs-yaml-parse-file))
  (cmacs-journal-tests--with-journal
    (let ((file (expand-file-name "filters.yaml" root)))
      (with-temp-file file
        (insert "filters:\n"
                "  - match: {app: '^org\\.keepassxc'}\n"
                "    exclude: true\n"
                "  - match: {url: 'bank'}\n"
                "    drop: [url, title]\n"
                "  - match: {title: 'Invoice'}\n"
                "    replace: [{field: title, regexp: '\\d{6,}', with: '***'}]\n"
                "    hash: [file]\n"))
      (setq cmacs-journal-filter-files (list file))
      (should (cmacs-journal-filters-reload))
      (should (= (length cmacs-journal-filter--rules) 3))
      (should-not (cmacs-journal-filter-apply
                   (list :kind 'focus :app "org.keepassxc.KeePassXC")))
      (with-temp-file file (insert "filters:\n  - match: [unterminated\n"))
      (should-not (cmacs-journal-filters-reload)))))

;;;; Files

(ert-deftest cmacs-journal-test-files-are-private-json-lines ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "Nachrichten \"heute\" — ünïcode"
                                :tags '(1 3) :pid 99 :monitor "DP-1")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "foot" "shell")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (cmacs-journal-flush)
    (should (null cmacs-journal--queue))
    (should (= (logand (file-modes cmacs-journal-directory) #o777) #o700))
    (let ((files (directory-files cmacs-journal-directory t "\\.jsonl\\'")))
      (should (= (length files) 1))
      (should (string-match-p "/[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\.jsonl\\'"
                              (car files)))
      (should (= (logand (file-modes (car files)) #o777) #o600))
      (with-temp-buffer
        (insert-file-contents (car files))
        (should (= (count-lines (point-min) (point-max)) 2))
        (goto-char (point-min))
        (let ((object (json-parse-string
                       (buffer-substring (point) (line-end-position))
                       :object-type 'alist)))
          (should (equal (alist-get 'kind object) "focus"))
          (should (equal (alist-get 'app object) "firefox"))
          (should (equal (alist-get 'tags object) [1 3]))
          (should (= (alist-get 'duration object) 10.0))
          (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]T"
                                  (alist-get 'time object))))))
    ;; A later flush appends, and what is read back is what was written.
    (cmacs-journal-tests--focus "foot" "shell")
    (cmacs-journal-tests--advance 5)
    (cmacs-journal--observe nil)
    (cmacs-journal-flush)
    (let ((events (cmacs-journal-events)))
      (should (= (length events) 3))
      (should (equal (plist-get (car events) :title)
                     "Nachrichten \"heute\" — ünïcode"))
      (should (eq (plist-get (car events) :kind) 'focus))
      (should (equal (plist-get (car events) :tags) '(1 3)))
      (should (= (plist-get (car events) :time) 1000000.0))
      (should (= (plist-get (car events) :end) 1000010.0)))))

(ert-deftest cmacs-journal-test-the-hash-key-is-private-and-stable ()
  (cmacs-journal-tests--with-journal
    (let ((cmacs-journal-filter-hash-key nil))
      (cmacs-journal--load-secret)
      (let ((key cmacs-journal-filter-hash-key)
            (file (expand-file-name "secret" cmacs-journal-directory)))
        (should (>= (length key) 32))
        (should (= (logand (file-modes file) #o777) #o600))
        (setq cmacs-journal-filter-hash-key nil)
        (cmacs-journal--load-secret)
        (should (equal cmacs-journal-filter-hash-key key))))))

(ert-deftest cmacs-journal-test-old-day-files-are-pruned ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal--ensure-directory)
    (let ((old (cmacs-journal--day-file
                (cmacs-journal--day (- cmacs-journal-tests--clock (* 40 86400)))))
          (new (cmacs-journal--day-file
                (cmacs-journal--day (- cmacs-journal-tests--clock 86400)))))
      (write-region "" nil old nil 'silent)
      (write-region "" nil new nil 'silent)
      (cmacs-journal--prune)
      (should (file-exists-p old))
      (let ((cmacs-journal-retention-days 30))
        (cmacs-journal--prune))
      (should-not (file-exists-p old))
      (should (file-exists-p new)))))

;;;; Forgetting

(defun cmacs-journal-tests--three-spans ()
  "Record firefox, foot and evince for ten seconds each, and flush."
  (cmacs-journal-tests--focus "firefox" "News")
  (cmacs-journal-tests--advance 10)
  (cmacs-journal-tests--focus "foot" "ssh bastion")
  (cmacs-journal-tests--advance 10)
  (cmacs-journal-tests--focus "evince" "Contract.pdf")
  (cmacs-journal-tests--advance 10)
  (cmacs-journal--observe nil)
  (cmacs-journal-flush))

(ert-deftest cmacs-journal-test-forget-a-time-range ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--three-spans)
    (should (= (cmacs-journal-forget 1000012.0 1000018.0) 1))
    (should (equal (mapcar (lambda (e) (plist-get e :app)) (cmacs-journal-events))
                   '("firefox" "evince")))
    (let ((file (car (directory-files cmacs-journal-directory t "\\.jsonl\\'"))))
      (should (= (logand (file-modes file) #o777) #o600))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (string-match-p "bastion" (buffer-string)))
        (should (= (count-lines (point-min) (point-max)) 2))))
    ;; No temporary file left beside it.
    (should (equal (directory-files cmacs-journal-directory nil "tmp") nil))))

(ert-deftest cmacs-journal-test-forget-by-regexp-everywhere ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--three-spans)
    ;; One more in the queue, and one still open.
    (cmacs-journal-tests--focus "foot" "ssh bastion")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal-tests--focus "foot" "ssh bastion again")
    (cmacs-journal-tests--advance 10)
    (should (= (cmacs-journal-forget nil nil "bastion") 2))
    (should (null cmacs-journal--open))
    (should (null cmacs-journal--queue))
    (should (equal (mapcar (lambda (e) (plist-get e :app)) (cmacs-journal-events))
                   '("firefox" "evince")))))

(ert-deftest cmacs-journal-test-forgetting-everything-removes-the-file ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--three-spans)
    (should (= (cmacs-journal-forget 0 2000000.0) 3))
    (should (null (directory-files cmacs-journal-directory t "\\.jsonl\\'")))
    (should (null (cmacs-journal-events)))
    (should-error (cmacs-journal-forget nil nil nil))))

;;;; LQL and agents

(ert-deftest cmacs-journal-test-lql-row-shape ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--focus "firefox" "News" :tags '(2) :monitor "DP-1")
    (cmacs-journal-tests--advance 10)
    (cmacs-journal--observe nil)
    (cmacs-journal-flush)
    ;; One stored, one still queued: the source reads both.
    (cmacs-journal--observe (list :kind 'buffer :app "emacs" :buffer "notes.org"
                                  :file "~/notes.org" :mode "org-mode"
                                  :project "notes"))
    (cmacs-journal-tests--advance 30)
    (cmacs-journal--observe nil)
    (let ((rows (cmacs-journal--lql-rows)))
      (should (= (length rows) 2))
      (dolist (row rows)
        ;; Exactly the declared columns, in keyword form.
        (should (equal (cl-loop for (k _) on row by #'cddr
                                collect (substring (symbol-name k) 1))
                       (mapcar #'car cmacs-journal--lql-columns)))
        (should (floatp (plist-get row :time)))
        (should (floatp (plist-get row :end)))
        (should (numberp (plist-get row :duration)))
        (should (symbolp (plist-get row :kind)))
        (should (vectorp (plist-get row :tags))))
      (should (equal (plist-get (car rows) :tags) [2]))
      (should (= (plist-get (car rows) :duration) 10.0))
      (should (equal (plist-get (cadr rows) :project) "notes"))
      (should (= (plist-get (cadr rows) :duration) 30.0))
      ;; Every row serialises the way cmacs-lql will serialise it.
      (should (stringp (json-serialize
                        (vconcat
                         (mapcar (lambda (row)
                                   (cl-loop for (k v) on row by #'cddr
                                            collect
                                            (cons (intern (substring (symbol-name k) 1))
                                                  (cond ((null v) :null)
                                                        ((eq k :kind) (symbol-name v))
                                                        (t v)))))
                                 rows))))))
    ;; Older than the window: not read.
    (let ((cmacs-journal-lql-days 1))
      (cmacs-journal-tests--advance (* 3 86400))
      (should (null (cmacs-journal--lql-rows))))))

(ert-deftest cmacs-journal-test-agents-get-no-rows-unless-allowed ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--three-spans)
    (should (= (length (cmacs-journal--lql-rows)) 3))
    (let ((mine (cmacs-journal--lql-generation)))
      ;; A brigade tool call.
      (let ((cmacs-journal--in-tool-call t))
        (should (cmacs-journal-agent-context-p))
        (should (null (cmacs-journal--lql-rows)))
        (should (null (cmacs-journal-events)))
        ;; The cached snapshot made for the user must not be reused.
        (should-not (equal mine (cmacs-journal--lql-generation)))
        (let ((cmacs-journal-expose-to-agents t))
          (should (= (length (cmacs-journal--lql-rows)) 3))))
      ;; Anything over the RPC dispatch (MCP, D-Bus, emacsctl).
      (let ((inhibit-interaction t))
        (should (cmacs-journal-agent-context-p))
        (should (null (cmacs-journal--lql-rows))))
      (should (equal mine (cmacs-journal--lql-generation))))
    ;; The advice is what sets the flag for a real tool call.
    (should (eq (cmacs-journal--around-tool-call
                 (lambda (&rest _) (cmacs-journal-agent-context-p)))
                t))
    (should-not (cmacs-journal-agent-context-p))))

(declare-function cmacs-brigade-call-tool "cmacs-brigade-tools"
                  (wire-name json-args &optional agent allowlist task))
(declare-function cmacs-brigade-unregister-tool "cmacs-brigade-registry"
                  (name))

(ert-deftest cmacs-journal-test-a-tool-call-with-a-task-is-still-an-agents ()
  "A tool call attributed to a task is an agent's call like any other.

An MCP call on a scoped socket now reaches `cmacs-brigade-call-tool'
with the task its scope was opened for.  That is the same advised
function with one more argument, not a second way in: the MCP handler
must go on naming that function and nothing beside it, and a call made
with a task must still find the journal closed."
  (skip-unless (require 'cmacs-brigade-tools nil t))
  (skip-unless (fboundp 'cmacs-brigade-unregister-tool))
  (should (advice-member-p #'cmacs-journal--around-tool-call
                           'cmacs-brigade-call-tool))
  (unwind-protect
      (progn
        (eval '(cmacs-brigade-deftool journal-test-probe
                   "Report whether the journal sees an agent." ()
                 (if (cmacs-journal-agent-context-p) "agent" "user"))
              t)
        (dolist (task '(nil "task-1"))
          (should (equal (cmacs-brigade-call-tool "journal_test_probe" "{}"
                                                  "mcp" nil task)
                         "agent")))
        (should-not (cmacs-journal-agent-context-p)))
    (cmacs-brigade-unregister-tool 'journal-test-probe))
  ;; The C half: every Lisp entry point the handler can generate.
  (let ((source (expand-file-name "cmacs/mcp/cmacs-mcp-tools-brigade.c"
                                  (or (bound-and-true-p source-directory)
                                      default-directory))))
    (skip-unless (file-readable-p source))
    (with-temp-buffer
      (insert-file-contents source)
      (let ((body (buffer-substring
                   (progn (search-forward "\nhandle_brigade_tool (")
                          (point))
                   (progn (search-forward "\n}\n") (point))))
            (start 0) (heads nil))
        (while (string-match "g_strdup_printf (\"(\\([a-z-]+\\)" body start)
          (push (match-string 1 body) heads)
          (setq start (match-end 0)))
        (should heads)
        (should (equal (delete-dups heads) '("cmacs-brigade-call-tool")))))))

(ert-deftest cmacs-journal-test-an-agent-run-is-a-point-event-without-output ()
  (cmacs-journal-tests--with-journal
    (cl-letf (((symbol-function 'cmacs-brigade-task-get)
               (lambda (&rest _) '(:agent "reviewer" :title "Review the diff"))))
      (cmacs-journal--on-agent-run "task-1" 'done "the whole transcript"))
    (should (= (length cmacs-journal--queue) 1))
    (let ((event (car cmacs-journal--queue)))
      (should (eq (plist-get event :kind) 'agent))
      (should (equal (plist-get event :app) "reviewer"))
      (should (equal (plist-get event :detail) "done"))
      (should-not (string-match-p "transcript" (format "%S" event))))))

;;;; Reports

(ert-deftest cmacs-journal-test-summarize-by-project-and-app ()
  (let ((events (list (list :kind 'buffer :app "emacs" :project "cmacs"
                            :time 100.0 :end 700.0 :duration 600.0)
                      (list :kind 'focus :app "firefox"
                            :time 700.0 :end 1000.0 :duration 300.0)
                      (list :kind 'buffer :app "emacs" :project "cmacs"
                            :time 1000.0 :end 1300.0 :duration 300.0)
                      (list :kind 'idle :time 1300.0 :end 9000.0 :duration 7700.0))))
    (should (equal (cmacs-journal-summarize events 'project)
                   '(("cmacs" . 900.0) ("(firefox)" . 300.0))))
    (should (equal (cmacs-journal-summarize events 'app)
                   '(("emacs" . 900.0) ("firefox" . 300.0))))
    (should (equal (cmacs-journal--format-duration 5400) "1:30"))))

(ert-deftest cmacs-journal-test-dynamic-block-writes-a-table ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal--observe (list :kind 'buffer :app "emacs" :project "cmacs"))
    (cmacs-journal-tests--advance 1800)
    (cmacs-journal--observe nil)
    (with-temp-buffer
      (org-dblock-write:cmacs-journal '(:span today :by project))
      (should (string-match-p "| *cmacs *| *0:30 *| *100 *|" (buffer-string)))
      (should (string-match-p "| *Total *| *0:30" (buffer-string)))
      (should-not (eq (char-before (point-max)) ?\n)))))

(ert-deftest cmacs-journal-test-clock-lines-merge-nearby-spans ()
  (let* ((cmacs-journal-clock-merge-gap 300)
         (ranges (cmacs-journal--clock-ranges
                  (list (list :time 0.0 :end 600.0)
                        (list :time 660.0 :end 1200.0)
                        (list :time 5000.0 :end 5020.0)))))
    (should (equal ranges '((0.0 . 1200.0) (5000.0 . 5020.0))))
    (should (string-match-p "\\`CLOCK: \\[.*\\]--\\[.*\\] =>  0:20\n\\'"
                            (cmacs-journal--clock-line 0.0 1200.0)))
    ;; Under a minute is not a clock line.
    (should (null (cmacs-journal--clock-line 5000.0 5020.0)))))

(ert-deftest cmacs-journal-test-at-finds-the-moment ()
  (cmacs-journal-tests--with-journal
    (cmacs-journal-tests--three-spans)
    (let ((events (cmacs-journal--around 1000015.0)))
      (should (= (length events) 3))
      (should (equal (plist-get (cl-find-if
                                 (lambda (e) (and (<= (plist-get e :time) 1000015.0)
                                                  (>= (plist-get e :end) 1000015.0)))
                                 events)
                                :app)
                     "foot")))))

(provide 'cmacs-journal-tests)

;;; cmacs-journal-tests.el ends here
