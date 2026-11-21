;;; cmacs-deixis-ask-tests.el --- Tests for cmacs-deixis-ask  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Pure ERT.  The compositor, gsurf, the edit-field session, tesseract,
;; the model and the voice loop are all stubs (with &rest, as the stub
;; of a C DEFUN must be); the redaction functions are stubbed too, so
;; the result does not depend on whatever privacy rules the machine
;; running the suite has.  The buffer extractor, the question table, the
;; prompt and the result window's follow-up path are the real code.
;;
;; What this does NOT prove: the text-input read against a live
;; application, tesseract on real pixels, a page's JavaScript, a real
;; provider's stream, and speech.  Those need a session.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-deixis)
(require 'cmacs-deixis-ask)
(require 'cmacs-redact)
(require 'cmacs-ai-output)
;; Loaded now, so that the code under test does not load them later and
;; replace a stub with the real function.
(require 'cmacs-gowl-edit-field nil t)
(require 'cmacs-gowl-ai-field nil t)
(require 'cmacs-gowl-tools nil t)
(require 'cmacs-ai-textops nil t)

;; Variables of files this suite does not load.
(defvar cmacs-voice-loop-mode)
(defvar cmacs-voice-loop-speak)
(defvar cmacs-voice-loop--last-target)
(defvar cmacs-voice-loop--stream-open)
(defvar cmacs-voice-loop--tts-tail)
(defvar cmacs-voice-loop-barge-in-cancels-stream)
(defvar cmacs-voice-loop-state-change-functions)
(defvar cmacs-gowl-edit-field-deny)
(defvar flymake-mode)

(defconst cmacs-deixis-ask-tests--browser
  '(:kind window :client browser :client-id 12 :app-id "librewolf"
    :title "Secret plans" :monitor 0 :x 500.0 :y 400.0 :confidence 1.0
    :label "window: librewolf — 'Secret plans' (client 12)"))

(defconst cmacs-deixis-ask-tests--term
  '(:kind window :client term :client-id 7 :app-id "gst" :title "sh"
    :monitor 0 :x 1500.0 :y 300.0 :confidence 1.0
    :label "window: gst — 'sh' (client 7)"))

(defvar cmacs-deixis-ask-tests--as-model nil
  "What `cmacs-redact--as-model' was each time a redaction stub ran.")

(defmacro cmacs-deixis-ask-tests--with-redact (plist &rest body)
  "Run BODY with the redaction functions stubbed per PLIST.
:window, :buffer-p, :url and :text are functions standing in for
`cmacs-redact-window' and friends; the defaults show everything.  Each
stub notes whether it ran inside `cmacs-redact-as-model'."
  (declare (indent 1))
  `(let ((spec ,plist))
     (setq cmacs-deixis-ask-tests--as-model nil)
     (cl-letf (((symbol-function 'cmacs-redact-window)
                (lambda (app title &rest _)
                  (push cmacs-redact--as-model cmacs-deixis-ask-tests--as-model)
                  (if (plist-get spec :window)
                      (funcall (plist-get spec :window) app title)
                    (cons app title))))
               ((symbol-function 'cmacs-redact-buffer-p)
                (lambda (buffer &rest _)
                  (push cmacs-redact--as-model cmacs-deixis-ask-tests--as-model)
                  (and (plist-get spec :buffer-p)
                       (funcall (plist-get spec :buffer-p) buffer))))
               ((symbol-function 'cmacs-redact-url)
                (lambda (url &rest _)
                  (push cmacs-redact--as-model cmacs-deixis-ask-tests--as-model)
                  (if (plist-get spec :url)
                      (funcall (plist-get spec :url) url)
                    url)))
               ((symbol-function 'cmacs-redact-text)
                (lambda (text &rest _)
                  (push cmacs-redact--as-model cmacs-deixis-ask-tests--as-model)
                  (if (plist-get spec :text)
                      (funcall (plist-get spec :text) text)
                    text)))
               ;; Never the live compositor, never the bar.
               ((symbol-function 'gowl-running-p) (lambda (&rest _) nil))
               ((symbol-function 'gowl-bar-notify) (lambda (&rest _) nil))
               ((symbol-function 'gowl-client-pid) (lambda (&rest _) 4242)))
       ,@body)))

(defun cmacs-deixis-ask-tests--extract (referent &optional scope)
  "Run the extraction of REFERENT synchronously; return its result."
  (let ((out 'pending))
    (cmacs-deixis-ask-extract referent scope (lambda (r) (setq out r)))
    out))

(defmacro cmacs-deixis-ask-tests--in-buffer (mode text &rest body)
  "Run BODY in a temporary buffer in MODE holding TEXT."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (delay-mode-hooks (funcall ,mode))
     ,@body))

(defun cmacs-deixis-ask-tests--pos (string)
  "The position of the start of STRING in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward string)
    (match-beginning 0)))

(defun cmacs-deixis-ask-tests--thing-text (thing)
  "The text THING (from `cmacs-deixis-ask-buffer-thing') spans."
  (buffer-substring-no-properties (plist-get thing :beg) (plist-get thing :end)))


;;;; From referent to extractor

(ert-deftest cmacs-deixis-ask-test-extractor-selection ()
  "Each kind of referent gets its extractors, most specific first."
  (with-temp-buffer
    (let ((here (list :kind 'buffer-position :buffer (current-buffer)
                      :position 1)))
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                ((symbol-function 'cmacs-gsurf-attached-p) (lambda (&rest _) nil)))
        (should (equal (cmacs-deixis-ask-extractors-for here) '(buffer)))
        (should (equal (cmacs-deixis-ask-extractors-for
                        (list :kind 'region :buffer (current-buffer)
                              :beg 1 :end 1))
                       '(buffer)))
        ;; Another program's window: its field first, then the screen.
        (should (equal (cmacs-deixis-ask-extractors-for
                        cmacs-deixis-ask-tests--browser)
                       '(field ocr)))
        ;; "What is this window": the selection in a field is not it.
        (should (equal (cmacs-deixis-ask-extractors-for
                        cmacs-deixis-ask-tests--browser 'whole)
                       '(ocr)))
        ;; Bare desktop: nothing reads it.
        (should-not (cmacs-deixis-ask-extractors-for
                     '(:kind monitor :monitor 0 :x 1 :y 1))))
      ;; A web view is a buffer whose text is not in the buffer.
      (cl-letf (((symbol-function 'cmacs-gsurf-attached-p) (lambda (&rest _) t)))
        (should (equal (cmacs-deixis-ask-extractors-for here)
                       '(gsurf buffer))))
      ;; No compositor: a window cannot be read off the screen.
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
        (should (equal (cmacs-deixis-ask-extractors-for
                        cmacs-deixis-ask-tests--browser)
                       '(field)))))))

(ert-deftest cmacs-deixis-ask-test-registry-is-open ()
  "A registered extractor is tried in its order, and nil passes on."
  (let ((cmacs-deixis-ask--extractors (copy-alist cmacs-deixis-ask--extractors))
        (tried nil))
    (cmacs-deixis-ask-register-extractor
     'first :order 1
     :applies (lambda (r _s) (eq (plist-get r :kind) 'widget))
     :extract (lambda (_r _s done) (push 'first tried) (funcall done nil)))
    (cmacs-deixis-ask-register-extractor
     'broken :order 2
     :applies (lambda (r _s) (eq (plist-get r :kind) 'widget))
     :extract (lambda (&rest _) (push 'broken tried) (error "Boom")))
    (cmacs-deixis-ask-register-extractor
     'second :order 3
     :applies (lambda (r _s) (eq (plist-get r :kind) 'widget))
     :extract (lambda (_r _s done)
                (push 'second tried)
                (funcall done (list :source 'widget :description "a widget"
                                    :text "  dial at 7  "))))
    (should (equal (cmacs-deixis-ask-extractors-for '(:kind widget))
                   '(first broken second)))
    ;; The gate knows only windows and buffers; let this kind through.
    (cl-letf (((symbol-function 'cmacs-deixis-ask-refusal) (lambda (&rest _) nil)))
      (let ((r (cmacs-deixis-ask-tests--extract '(:kind widget))))
        (should (equal (nreverse tried) '(first broken second)))
        (should (equal (plist-get r :text) "dial at 7"))
        (should (eq (plist-get r :source) 'widget)))
      ;; Nobody answers: the last error is the reason given.
      (cmacs-deixis-ask-unregister-extractor 'second)
      (should (equal (plist-get (cmacs-deixis-ask-tests--extract '(:kind widget))
                                :failed)
                     "Boom")))))


;;;; The thing at a buffer position, and its size

(ert-deftest cmacs-deixis-ask-test-thing-defun ()
  "In code, the function around the position -- not the buffer, not the line."
  (cmacs-deixis-ask-tests--in-buffer #'emacs-lisp-mode
      "(defun one ()\n  1)\n\n(defun two ()\n  (+ 1\n     2))\n\n(defun three ()\n  3)\n"
    (let ((thing (cmacs-deixis-ask-buffer-thing
                  (current-buffer) (cmacs-deixis-ask-tests--pos "(+ 1"))))
      (should (eq (plist-get thing :what) 'defun))
      (should (string-prefix-p "(defun two ()"
                               (cmacs-deixis-ask-tests--thing-text thing)))
      (should-not (string-match-p "three\\|one"
                                  (cmacs-deixis-ask-tests--thing-text thing))))))

(ert-deftest cmacs-deixis-ask-test-thing-paragraph-and-line ()
  "In prose, the paragraph; a lone blank line is widened to its neighbours."
  (cmacs-deixis-ask-tests--in-buffer #'text-mode
      "First paragraph\nstill first.\n\nSecond paragraph here.\n\n\n\nLast one.\n"
    (let ((thing (cmacs-deixis-ask-buffer-thing
                  (current-buffer) (cmacs-deixis-ask-tests--pos "still"))))
      (should (eq (plist-get thing :what) 'paragraph))
      (should (string-match-p "First paragraph\nstill first\\."
                              (cmacs-deixis-ask-tests--thing-text thing)))
      (should-not (string-match-p "Second"
                                  (cmacs-deixis-ask-tests--thing-text thing))))
    ;; On the middle blank line there is no paragraph and no line worth
    ;; sending: take the lines around.
    (let* ((cmacs-deixis-ask-context-lines 2)
           (pos (save-excursion (goto-char (point-min)) (forward-line 5) (point)))
           (thing (cmacs-deixis-ask-buffer-thing (current-buffer) pos)))
      (should (eq (plist-get thing :what) 'lines))
      (should (string-match-p "Second paragraph"
                              (cmacs-deixis-ask-tests--thing-text thing)))
      (should (string-match-p "Last one"
                              (cmacs-deixis-ask-tests--thing-text thing))))))

(ert-deftest cmacs-deixis-ask-test-thing-org-subtree ()
  "In Org, the subtree the position is in."
  (cmacs-deixis-ask-tests--in-buffer #'org-mode
      "* Alpha\nbody a\n** Alpha child\nchild text\n* Beta\nbody b\n"
    (let ((thing (cmacs-deixis-ask-buffer-thing
                  (current-buffer) (cmacs-deixis-ask-tests--pos "child text"))))
      (should (eq (plist-get thing :what) 'subtree))
      (should (equal (string-trim (cmacs-deixis-ask-tests--thing-text thing))
                     "** Alpha child\nchild text")))
    (let ((thing (cmacs-deixis-ask-buffer-thing
                  (current-buffer) (cmacs-deixis-ask-tests--pos "body a"))))
      (should (string-match-p "Alpha child"
                              (cmacs-deixis-ask-tests--thing-text thing)))
      (should-not (string-match-p "Beta"
                                  (cmacs-deixis-ask-tests--thing-text thing))))))

(ert-deftest cmacs-deixis-ask-test-thing-region ()
  "A region referent is exactly its region; an active region wins at a position in it."
  (cmacs-deixis-ask-tests--in-buffer #'emacs-lisp-mode
      "(defun two ()\n  (+ 1\n     2))\n"
    (let* ((beg (cmacs-deixis-ask-tests--pos "(+ 1"))
           (end (+ beg 5))
           (transient-mark-mode t))
      (let ((thing (cmacs-deixis-ask-buffer-thing (current-buffer) 3 nil nil
                                                  beg end)))
        (should (eq (plist-get thing :what) 'region))
        (should (equal (cmacs-deixis-ask-tests--thing-text thing) "(+ 1\n")))
      (set-mark beg)
      (goto-char end)
      (activate-mark)
      (let ((thing (cmacs-deixis-ask-buffer-thing (current-buffer) (1+ beg))))
        (should (eq (plist-get thing :what) 'region))
        (should (equal (list (plist-get thing :beg) (plist-get thing :end))
                       (list beg end))))
      ;; Pointing outside the region means the other thing.
      (should (eq (plist-get (cmacs-deixis-ask-buffer-thing (current-buffer) 3)
                             :what)
                  'defun)))))

(ert-deftest cmacs-deixis-ask-test-thing-sizes ()
  "Nothing longer than the limit is sent; the cut keeps the pointed place."
  (cmacs-deixis-ask-tests--in-buffer #'emacs-lisp-mode
      (concat "(defun big ()\n"
              (mapconcat (lambda (i) (format "  (line-number %04d)" i))
                         (number-sequence 1 400) "\n")
              ")\n")
    (let* ((cmacs-deixis-ask-max-chars 600)
           (pos (cmacs-deixis-ask-tests--pos "(line-number 0200)"))
           (thing (cmacs-deixis-ask-buffer-thing (current-buffer) pos))
           (text (cmacs-deixis-ask-tests--thing-text thing)))
      (should (eq (plist-get thing :what) 'defun))
      (should (plist-get thing :clipped))
      (should (<= (length text) 600))
      (should (string-match-p "0200" text))
      (should-not (string-match-p "0001\\|0400" text))
      ;; Whole lines only.
      (should (string-prefix-p "  (line-number" text)))
    ;; "This file", with no window showing it: all of it, cut the same way.
    (let* ((cmacs-deixis-ask-max-chars 600)
           (thing (cmacs-deixis-ask-buffer-thing (current-buffer) 1 'whole)))
      (should (eq (plist-get thing :what) 'shown))
      (should (plist-get thing :clipped))
      (should (<= (- (plist-get thing :end) (plist-get thing :beg)) 600)))
    ;; Unlimited.
    (let* ((cmacs-deixis-ask-max-chars 0)
           (thing (cmacs-deixis-ask-buffer-thing (current-buffer) 1 'whole)))
      (should-not (plist-get thing :clipped))
      (should (= (plist-get thing :end) (point-max))))))

(ert-deftest cmacs-deixis-ask-test-thing-compilation-error ()
  "In a compilation buffer, the message there with its excerpt, and what it is about."
  (cmacs-deixis-ask-tests--in-buffer #'compilation-mode
      (concat "gcc -c foo.c\n"
              "foo.c:10:5: error: 'bar' undeclared\n"
              "   10 |     bar = 1;\n"
              "      |     ^~~\n"
              "foo.c:20:1: warning: unused variable 'x'\n")
    (let* ((thing (cmacs-deixis-ask-buffer-thing
                   (current-buffer) (cmacs-deixis-ask-tests--pos "undeclared")))
           (text (cmacs-deixis-ask-tests--thing-text thing)))
      (should (eq (plist-get thing :what) 'compilation-error))
      (should (string-match-p "error: 'bar' undeclared" text))
      ;; The excerpt belongs to it; the next message does not.
      (should (string-match-p "\\^~~" text))
      (should-not (string-match-p "unused variable" text))
      (should (string-match-p "foo\\.c, line 10" (plist-get thing :note))))))

(ert-deftest cmacs-deixis-ask-test-buffer-context ()
  "The buffer extractor says the mode and the file, and adds the diagnostics."
  (cmacs-deixis-ask-tests--in-buffer #'emacs-lisp-mode
      "(defun one ()\n  1)\n\n(defun two ()\n  (undefined-thing))\n"
    (setq buffer-file-name "/tmp/cmacs-deixis-ask-test.el")
    (setq-local flymake-mode t)
    (let ((asked nil) (redacted nil))
      (unwind-protect
          (cmacs-deixis-ask-tests--with-redact
              (list :text (lambda (text) (setq redacted t) text))
            (cl-letf (((symbol-function 'flymake-diagnostics)
                       (lambda (&rest range) (setq asked range) '(d1)))
                      ((symbol-function 'flymake-diagnostic-text)
                       (lambda (&rest _) "function undefined-thing is not known"))
                      ((symbol-function 'flymake-diagnostic-type)
                       (lambda (&rest _) :warning))
                      ((symbol-function 'flymake-diagnostic-beg)
                       (lambda (&rest _)
                         (cmacs-deixis-ask-tests--pos "(undefined-thing"))))
              (let ((r (cmacs-deixis-ask-tests--extract
                        (list :kind 'buffer-position :buffer (current-buffer)
                              :position (cmacs-deixis-ask-tests--pos
                                         "(undefined-thing")))))
                (should (eq (plist-get r :source) 'buffer))
                (should (equal (plist-get r :text)
                               "(defun two ()\n  (undefined-thing))"))
                (should (string-match-p "emacs-lisp-mode"
                                        (plist-get r :description)))
                (should (string-match-p "cmacs-deixis-ask-test\\.el"
                                        (plist-get r :description)))
                (should (string-match-p "the function at the pointed position"
                                        (plist-get r :description)))
                ;; Diagnostics are asked for over the function's span.
                (should (equal asked (list (cmacs-deixis-ask-tests--pos "(defun two")
                                           (point-max))))
                (should (string-match-p
                         "line 5: \\[warning\\] function undefined-thing"
                         (plist-get r :extra)))
                ;; The buffer was asked about; its own text is not rewritten.
                (should (memq t cmacs-deixis-ask-tests--as-model))
                (should-not redacted))))
        (setq buffer-file-name nil)
        (set-buffer-modified-p nil)))))


;;;; Privacy

(ert-deftest cmacs-deixis-ask-test-refuses-excluded-buffer ()
  "An excluded buffer is refused before any extractor reads it."
  (with-temp-buffer
    (insert "the secret")
    (let ((cmacs-deixis-ask--extractors (copy-alist cmacs-deixis-ask--extractors))
          (read nil)
          (here (list :kind 'buffer-position :buffer (current-buffer)
                      :position 1)))
      (cmacs-deixis-ask-register-extractor
       'buffer :order 50
       :applies (lambda (&rest _) t)
       :extract (lambda (_r _s done) (setq read t) (funcall done nil)))
      (cmacs-deixis-ask-tests--with-redact (list :buffer-p (lambda (_b) t))
        (should (equal (cmacs-deixis-ask-refusal here)
                       cmacs-deixis-ask-refusal-text))
        (should (equal (plist-get (cmacs-deixis-ask-tests--extract here) :refused)
                       cmacs-deixis-ask-refusal-text))
        (should-not read)
        ;; The check ran as a model's.
        (should (equal cmacs-deixis-ask-tests--as-model '(t t))))
      ;; A dead buffer is refused in its own words.
      (should (stringp (cmacs-deixis-ask-refusal
                        (list :kind 'buffer-position
                              :buffer (let ((b (generate-new-buffer " gone")))
                                        (kill-buffer b)
                                        b)
                              :position 1)))))))

(ert-deftest cmacs-deixis-ask-test-refuses-excluded-window ()
  "An excluded window, a denied one, a closed one and a failed rule set all refuse."
  (cmacs-deixis-ask-tests--with-redact (list :window (lambda (_a _t) nil))
    (should (equal (cmacs-deixis-ask-refusal cmacs-deixis-ask-tests--browser)
                   cmacs-deixis-ask-refusal-text)))
  ;; Allowed by the rules.
  (cmacs-deixis-ask-tests--with-redact nil
    (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil)))
      (should-not (cmacs-deixis-ask-refusal cmacs-deixis-ask-tests--browser))))
  ;; The edit-field deny list stops the OCR road as well ...
  (cmacs-deixis-ask-tests--with-redact nil
    (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p)
               (lambda (app _title) (equal app "librewolf"))))
      (should (equal (cmacs-deixis-ask-refusal cmacs-deixis-ask-tests--browser)
                     cmacs-deixis-ask-refusal-text))
      ;; ... unless told it does not.
      (let ((cmacs-deixis-ask-deny-applies-to-ocr nil))
        (should-not (cmacs-deixis-ask-refusal cmacs-deixis-ask-tests--browser)))))
  ;; The rules cannot be asked: closed, not open.
  (cmacs-deixis-ask-tests--with-redact
      (list :window (lambda (&rest _) (error "Rules are broken")))
    (should (equal (cmacs-deixis-ask-refusal cmacs-deixis-ask-tests--browser)
                   cmacs-deixis-ask-refusal-text)))
  ;; A window that closed since it was pointed at, and bare desktop.
  (should (stringp (cmacs-deixis-ask-refusal
                    '(:kind window :stale t :client-id 3))))
  (should (stringp (cmacs-deixis-ask-refusal '(:kind monitor :monitor 0))))
  (should (stringp (cmacs-deixis-ask-refusal nil))))

(ert-deftest cmacs-deixis-ask-test-deny-list-is-the-edit-fields ()
  "The deny check is `cmacs-gowl-edit-field-deny' itself."
  (skip-unless (locate-library "cmacs-gowl-edit-field"))
  (require 'cmacs-gowl-edit-field)
  (let ((cmacs-gowl-edit-field-deny '("keepass")))
    (should (cmacs-deixis-ask--denied-p "org.keepassxc.KeePassXC" "Vault"))
    (should-not (cmacs-deixis-ask--denied-p "librewolf" "News"))))

(ert-deftest cmacs-deixis-ask-test-refused-question-sends-nothing ()
  "One refused referent of two: nothing is read, nothing is asked, it is said."
  (with-temp-buffer
    (insert "fine text")
    (let ((cmacs-deixis-ask--extractors (copy-alist cmacs-deixis-ask--extractors))
          (read nil) (asked nil) (said nil)
          (here (list :kind 'buffer-position :buffer (current-buffer)
                      :position 1)))
      (cmacs-deixis-ask-register-extractor
       'buffer :order 50 :applies (lambda (&rest _) t)
       :extract (lambda (_r _s done) (setq read t) (funcall done nil)))
      (cmacs-deixis-ask-tests--with-redact (list :window (lambda (_a _t) nil))
        (cl-letf (((symbol-function 'cmacs-ai-textops-stream)
                   (lambda (&rest args) (setq asked args) nil))
                  ((symbol-function 'cmacs-deixis-ask--say)
                   (lambda (voice fmt &rest args)
                     (push (cons voice (apply #'format fmt args)) said)
                     nil)))
          (should-not (cmacs-deixis-ask-run
                       "compare this and that"
                       (list here cmacs-deixis-ask-tests--browser)
                       :voice t))
          (should-not read)
          (should-not asked)
          ;; Said once, by voice, in the fixed words.
          (should (equal said (list (cons t cmacs-deixis-ask-refusal-text))))
          (should-not cmacs-deixis-ask--voice))))))

(ert-deftest cmacs-deixis-ask-test-foreign-text-is-redacted ()
  "Text from outside Emacs's buffers goes through the free-text rules, as a model's."
  (let ((cmacs-deixis-ask--extractors nil))
    (cmacs-deixis-ask-register-extractor
     'app :applies (lambda (&rest _) t)
     :extract (lambda (_r _s done)
                (funcall done (list :source 'ocr :foreign t
                                    :description "text off the screen"
                                    :text "card 4111-1111 here"
                                    :extra "also 4111-1111"))))
    (cmacs-deixis-ask-tests--with-redact
        (list :text (lambda (text)
                      (replace-regexp-in-string "[0-9]+-[0-9]+" "[card]" text)))
      (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil)))
        (let ((r (cmacs-deixis-ask-tests--extract cmacs-deixis-ask-tests--browser)))
          (should (equal (plist-get r :text) "card [card] here"))
          (should (equal (plist-get r :extra) "also [card]"))
          (should-not (memq nil cmacs-deixis-ask-tests--as-model)))))
    ;; A rule that withholds everything leaves nothing to ask about.
    (cmacs-deixis-ask-tests--with-redact (list :text (lambda (_text) ""))
      (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil)))
        (should (plist-get (cmacs-deixis-ask-tests--extract
                            cmacs-deixis-ask-tests--browser)
                           :failed))))
    ;; The rules failing while the text is read is not "send it anyway".
    (cmacs-deixis-ask-tests--with-redact nil
      (cl-letf (((symbol-function 'cmacs-redact-text)
                 (lambda (&rest _) (error "Rules are broken"))))
        (should (equal (cmacs-deixis-ask--redact "anything") ""))))))

(ert-deftest cmacs-deixis-ask-test-window-identity-stays-home ()
  "A window's title and application are not in what is sent, unless asked for."
  (cmacs-deixis-ask-tests--with-redact
      (list :window (lambda (app _title) (cons app "[title]")))
    (should (equal (cmacs-deixis-ask--identity cmacs-deixis-ask-tests--browser) ""))
    (let ((cmacs-deixis-ask-send-window-identity t))
      ;; And then as the rules rewrite it.
      (should (equal (cmacs-deixis-ask--identity cmacs-deixis-ask-tests--browser)
                     " (librewolf, titled \"[title]\")")))))


;;;; Another program's window: the field, then the screen

(ert-deftest cmacs-deixis-ask-test-ocr-region ()
  "The OCR box is centred on the pointer and kept inside the window."
  (let ((cmacs-deixis-ask-ocr-box '(400 . 200))
        (geom '(100 50 1000 800)))
    ;; In the middle: centred.
    (should (equal (cmacs-deixis-ask-ocr-region '(:x 600.0 :y 450.0) nil geom)
                   '(400 350 400 200)))
    ;; Near the top-left corner: pushed in, same size.
    (should (equal (cmacs-deixis-ask-ocr-region '(:x 110.0 :y 60.0) nil geom)
                   '(100 50 400 200)))
    ;; Near the bottom-right corner.
    (should (equal (cmacs-deixis-ask-ocr-region '(:x 1090.0 :y 840.0) nil geom)
                   '(700 650 400 200)))
    ;; "This window", or no position: all of it.
    (should (equal (cmacs-deixis-ask-ocr-region '(:x 600.0 :y 450.0) 'whole geom)
                   '(100 50 1000 800)))
    (should (equal (cmacs-deixis-ask-ocr-region '(:kind window) nil geom)
                   '(100 50 1000 800)))
    ;; A window smaller than the box is read whole.
    (should (equal (cmacs-deixis-ask-ocr-region '(:x 150.0 :y 80.0) nil
                                                '(100 50 300 100))
                   '(100 50 300 100)))
    (should-not (cmacs-deixis-ask-ocr-region '(:x 1 :y 1) nil '(0 0 0 0)))))

(ert-deftest cmacs-deixis-ask-test-window-falls-to-ocr ()
  "A window without the keyboard is read off the screen, and the text redacted."
  (let ((cmacs-deixis-ask-ocr-box '(400 . 200))
        (captured nil) (inside nil))
    (cmacs-deixis-ask-tests--with-redact
        (list :text (lambda (text) (concat "<" text ">")))
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                ((symbol-function 'gowl-client-info)
                 (lambda (&rest _) '((id . 12) (geometry 100 50 1000 800))))
                ((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil))
                ;; Another window has the keyboard.
                ((symbol-function 'cmacs-gowl-edit-field-focused-target)
                 (lambda (&rest _) '(:id 99 :client other)))
                ((symbol-function 'cmacs-gowl-edit-field-read-async)
                 (lambda (&rest _) (error "The field must not be read")))
                ((symbol-function 'cmacs-gowl-tools--screen-text)
                 (lambda (done &rest args)
                   (setq captured args
                         inside cmacs-redact--as-model)
                   (funcall done "Build failed: exit 2"))))
        (let ((r (cmacs-deixis-ask-tests--extract cmacs-deixis-ask-tests--browser)))
          (should (eq (plist-get r :source) 'ocr))
          ;; The box around 500,400, no language override, no clipboard.
          (should (equal captured '(300 300 400 200 nil nil)))
          ;; Entered as a model would, so the tool's region guard acts.
          (should inside)
          (should (equal (plist-get r :text) "<Build failed: exit 2>"))
          (should (string-match-p "OCR" (plist-get r :description)))
          (should-not (string-match-p "librewolf\\|Secret"
                                      (plist-get r :description))))
        ;; The whole window when that was the question.
        (cmacs-deixis-ask-tests--extract cmacs-deixis-ask-tests--browser 'whole)
        (should (equal (seq-take captured 4) '(100 50 1000 800)))))))

(ert-deftest cmacs-deixis-ask-test-ocr-failures ()
  "A failed OCR run, an empty one and a guarded region are failures, not answers."
  (cmacs-deixis-ask-tests--with-redact nil
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-client-info)
               (lambda (&rest _) '((geometry 0 0 800 600))))
              ((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil))
              ((symbol-function 'cmacs-gowl-edit-field-focused-target)
               (lambda (&rest _) '(:refused "no"))))
      (cl-letf (((symbol-function 'cmacs-gowl-tools--screen-text)
                 (lambda (done &rest _)
                   (funcall done "Error: OCR failed (tesseract exited 1)"))))
        (should (equal (plist-get (cmacs-deixis-ask-tests--extract
                                   cmacs-deixis-ask-tests--browser)
                                  :failed)
                       "OCR failed (tesseract exited 1)")))
      (cl-letf (((symbol-function 'cmacs-gowl-tools--screen-text)
                 (lambda (done &rest _) (funcall done "  \n"))))
        ;; Where a picture would go, if the model interface took one.
        (should (string-match-p "picture"
                                (plist-get (cmacs-deixis-ask-tests--extract
                                            cmacs-deixis-ask-tests--browser)
                                           :failed))))
      (cl-letf (((symbol-function 'cmacs-gowl-tools--screen-text)
                 (lambda (&rest _)
                   (error "That part of the screen shows a window the \
redaction rules withhold"))))
        (should (string-match-p "withhold"
                                (plist-get (cmacs-deixis-ask-tests--extract
                                            cmacs-deixis-ask-tests--browser)
                                           :failed)))))))

(ert-deftest cmacs-deixis-ask-test-field-selection ()
  "The focused window's field gives its selection; without one, the screen is read."
  (let ((released nil) (ocr nil) (reply nil) (read-args nil))
    (cmacs-deixis-ask-tests--with-redact nil
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                ((symbol-function 'gowl-client-info)
                 (lambda (&rest _) '((geometry 0 0 800 600))))
                ((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil))
                ((symbol-function 'cmacs-gowl-edit-field-focused-target)
                 (lambda (&rest _) '(:id 12 :client browser :app-id "librewolf")))
                ((symbol-function 'cmacs-gowl-edit-field-read-async)
                 (lambda (handler &rest args)
                   (setq read-args args)
                   (apply handler reply)
                   'session))
                ((symbol-function 'cmacs-gowl-edit-field-release)
                 (lambda (&rest _) (setq released t)))
                ((symbol-function 'cmacs-gowl-tools--screen-text)
                 (lambda (done &rest _) (setq ocr t) (funcall done "screen words"))))
        ;; Characters 6..11 are selected.
        (setq reply '(read session "hello world, more" 11 6))
        (let ((r (cmacs-deixis-ask-tests--extract cmacs-deixis-ask-tests--browser)))
          (should (eq (plist-get r :source) 'field))
          (should (equal (plist-get r :text) "world"))
          (should (plist-get r :foreign))
          (should released)
          (should-not ocr)
          ;; The clipboard fallback is never asked for.
          (should (equal read-args '((:id 12 :client browser :app-id "librewolf")
                                     t))))
        ;; A caret and no selection: not the field's to answer.
        (setq reply '(read session "hello world, more" 4 4) released nil)
        (let ((r (cmacs-deixis-ask-tests--extract cmacs-deixis-ask-tests--browser)))
          (should (eq (plist-get r :source) 'ocr))
          (should released))
        ;; A password field, a denied window, no text input: the same.
        (setq reply '(failed session "that is a password field") ocr nil)
        (should (eq (plist-get (cmacs-deixis-ask-tests--extract
                                cmacs-deixis-ask-tests--browser)
                               :source)
                    'ocr))
        (should ocr)))))


;;;; A web view

(ert-deftest cmacs-deixis-ask-test-web-script-takes-only-numbers ()
  "Nothing but numbers is formatted into the page script."
  (let ((script (cmacs-deixis-ask--web-script 0.25 0.75)))
    (should (string-match-p "(0\\.2500,0\\.7500,[0-9]+,[0-9]+)\\'" script))
    (should (string-match-p "elementFromPoint" script))
    (should (string-match-p "getSelection" script))))

(ert-deftest cmacs-deixis-ask-test-web-view ()
  "A web view: the selection, else the text at the pointed place; URL and title."
  (with-temp-buffer
    (let ((here (list :kind 'buffer-position :buffer (current-buffer)
                      :position 1))
          (script nil)
          (json (json-serialize
                 '((title . "Docs") (sel . "") (near . "The nearest paragraph.")
                   (page . "Everything on the page.")))))
      (cmacs-deixis-ask-tests--with-redact
          (list :url (lambda (url) (concat url "#seen"))
                :text (lambda (text) (concat "~" text)))
        (cl-letf (((symbol-function 'cmacs-gsurf-attached-p) (lambda (&rest _) t))
                  ((symbol-function 'cmacs-gsurf-get-uri)
                   (lambda (&rest _) "https://example.org/a"))
                  ((symbol-function 'cmacs-gsurf-run-javascript-async)
                   (lambda (_buffer js callback &rest _)
                     (setq script js)
                     (funcall callback json))))
          (let ((r (cmacs-deixis-ask-tests--extract here)))
            (should (eq (plist-get r :source) 'web))
            ;; With no pixel in the referent, the middle of the view.
            (should (string-match-p "(0\\.5000,0\\.5000," script))
            (should (equal (plist-get r :text) "~The nearest paragraph."))
            (should (string-match-p "https://example\\.org/a#seen"
                                    (plist-get r :description)))
            (should (string-match-p "titled \"~Docs\"" (plist-get r :description))))
          ;; "This page".
          (should (equal (plist-get (cmacs-deixis-ask-tests--extract here 'whole)
                                    :text)
                         "~Everything on the page."))
          ;; A selection beats where the pointer is.
          (setq json (json-serialize '((title . "") (sel . "picked words")
                                       (near . "n") (page . "p"))))
          (should (equal (plist-get (cmacs-deixis-ask-tests--extract here) :text)
                         "~picked words"))
          ;; A page that does not answer in JSON.
          (setq json "")
          (should (plist-get (cmacs-deixis-ask-tests--extract here) :failed))))
      ;; An excluded URL: the script never runs.
      (setq script nil)
      (cmacs-deixis-ask-tests--with-redact (list :url (lambda (_url) nil))
        (cl-letf (((symbol-function 'cmacs-gsurf-attached-p) (lambda (&rest _) t))
                  ((symbol-function 'cmacs-gsurf-get-uri)
                   (lambda (&rest _) "https://bank.example/"))
                  ((symbol-function 'cmacs-gsurf-run-javascript-async)
                   (lambda (_buffer js &rest _) (setq script js))))
          (should (equal (plist-get (cmacs-deixis-ask-tests--extract here) :refused)
                         cmacs-deixis-ask-refusal-text))
          (should-not script))))))


;;;; What is, and is not, a question

(defmacro cmacs-deixis-ask-tests--with-pointing (&rest body)
  "Run BODY with a pointer that is on the browser, then on the terminal.
Successive demonstratives of one utterance get the two in turn, so
\"this and that\" are two things.  Defines `bind' to resolve an
utterance to its bindings."
  (declare (indent 0))
  `(let* ((cmacs-deixis--pointers nil)
          (cmacs-deixis-pointer-order '(stub))
          (cmacs-deixis-fallback-to-point nil)
          (cmacs-deixis-clock-function (lambda () 100000))
          (calls 0))
     (cmacs-deixis-register-pointer
      'stub (lambda (_ms)
              (prog1 (if (cl-evenp calls) cmacs-deixis-ask-tests--browser
                       cmacs-deixis-ask-tests--term)
                (cl-incf calls))))
     (cl-flet ((bind (text)
                 (setq calls 0)
                 (cmacs-deixis-resolve
                  text (cmacs-deixis-result-words (list (cons :text text)))
                  nil)))
       (ignore #'bind)
       ,@body)))

(ert-deftest cmacs-deixis-ask-test-question-table ()
  "The shipped questions, the catch-all, and what is left alone."
  (cmacs-deixis-ask-tests--with-pointing
    (let ((cmacs-deixis-ask--last nil)
          (cmacs-deixis-ask-catch-all t))
      (pcase-dolist (`(,text ,route ,want)
                     '(;; The shipped set, whatever the route.
                       ("what is that" chat what-is)
                       ("What's this?" commands what-is)
                       ("So, what is that thing?" chat what-is)
                       ("explain this" commands explain)
                       ("Could you explain that to me" chat explain)
                       ("Please summarise that." chat summarise)
                       ("summarize this page" chat summarise)
                       ("translate that into German" chat translate)
                       ("what does this error mean" chat meaning)
                       ("What does that say?" chat meaning)
                       ("why is this failing" chat why)
                       ("why doesn't that compile" chat why)
                       ("compare this and that" chat compare)
                       ("what is the difference between this and that" chat compare)
                       ("how does this differ from that" chat compare)
                       ;; The catch-all: a question word first, on a route
                       ;; that was going to a model anyway.
                       ("how does this work" chat catch-all)
                       ("who wrote that" (agent "scout") catch-all)
                       ("is this correct" chat catch-all)
                       ("what is wrong with this" chat catch-all)
                       ;; ... and not on the voice commands' route, nor a
                       ;; function's.
                       ("how does this work" commands nil)
                       ("how does this work" ignore nil)
                       ;; Requests to DO something are not questions.
                       ("can you close that" chat nil)
                       ("make this bigger" chat nil)
                       ("delete this and write hello" chat nil)
                       ("put that on the second screen" chat nil)
                       ;; The deictic commands' own utterances.
                       ("move that there" chat nil)
                       ("close that" chat nil)
                       ("swap this and that" chat nil)
                       ;; Ordinary speech with no demonstrative in it.
                       ("I think that we should go" chat nil)
                       ("what is the weather" chat nil)
                       ("it is raining" chat nil)
                       ;; A follow-up form with nothing to follow up.
                       ("and that one" chat nil)
                       ("what about this" chat catch-all)))
        (let ((got (plist-get (cmacs-deixis-ask-match text (bind text) route)
                              :name)))
          (ert-info ((format "%S on %S" text route))
            (should (eq got want)))))
      ;; With a question to follow up, the follow-up forms are taken.
      (let ((cmacs-deixis-ask--last (list :question "what is that" :time 0.0)))
        (pcase-dolist (text '("and that one" "And this?" "what about that one"
                              "how about this" "and that one too"))
          (let ((m (cmacs-deixis-ask-match text (bind text) 'chat)))
            (ert-info (text)
              (should (eq (plist-get m :name) 'and-that))
              (should (plist-get m :followup))))))
      ;; The catch-all can be turned off, and its words changed.
      (let ((cmacs-deixis-ask-catch-all nil))
        (should-not (cmacs-deixis-ask-match "how does this work"
                                            (bind "how does this work") 'chat))
        (should (cmacs-deixis-ask-match "what is that" (bind "what is that")
                                        'chat)))
      (let ((cmacs-deixis-ask-question-words '("wherefore")))
        (should-not (cmacs-deixis-ask-match "how does this work"
                                            (bind "how does this work") 'chat))
        (should (cmacs-deixis-ask-match "wherefore is that so"
                                        (bind "wherefore is that so") 'chat)))
      ;; No route named: the loop's current one.
      (let ((cmacs-voice-loop--last-target 'commands))
        (should-not (cmacs-deixis-ask-match "how does this work"
                                            (bind "how does this work"))))
      (let ((cmacs-voice-loop--last-target 'chat))
        (should (cmacs-deixis-ask-match "how does this work"
                                        (bind "how does this work")))))))

(ert-deftest cmacs-deixis-ask-test-unresolved-is-not-a-question ()
  "A demonstrative with nothing pointed at, or a closed window, is not taken."
  (let ((cmacs-deixis--pointers nil)
        (cmacs-deixis-fallback-to-point nil)
        (cmacs-deixis-clock-function (lambda () 1)))
    (let ((b (cmacs-deixis-resolve "what is that" '(("what" 0 1) ("is" 1 2)
                                                    ("that" 2 3))
                                   nil)))
      (should b)
      (should-not (cmacs-deixis-ask-match "what is that" b 'chat)))
    (cmacs-deixis-register-pointer
     'stub (lambda (_ms) '(:kind window :stale t :client-id 4 :label "gone")))
    (let ((b (cmacs-deixis-resolve "what is that" nil nil)))
      (should-not (cmacs-deixis-ask-match "what is that" b 'chat)))))

(ert-deftest cmacs-deixis-ask-test-referents-and-scopes ()
  "Two demonstratives are two referents; one thing said twice is one."
  (cmacs-deixis-ask-tests--with-pointing
    (let* ((text "compare this window and that")
           (m (cmacs-deixis-ask-match text (bind text) 'chat)))
      (should (equal (mapcar (lambda (r) (plist-get r :client-id))
                             (plist-get m :referents))
                     '(12 7)))
      ;; "this window" is the whole window; "that" is where it pointed.
      (should (equal (plist-get m :scopes) '(whole nil)))
      (should (stringp (plist-get m :instruction)))))
  (let* ((cmacs-deixis--pointers nil)
         (cmacs-deixis-fallback-to-point nil)
         (cmacs-deixis-clock-function (lambda () 1)))
    (cmacs-deixis-register-pointer
     'stub (lambda (_ms) cmacs-deixis-ask-tests--browser))
    (let* ((text "what is this and why is this broken")
           (b (cmacs-deixis-resolve text nil nil))
           (m (cmacs-deixis-ask-match text b 'chat)))
      (should (= (length b) 2))
      (should (= (length (plist-get m :referents)) 1)))))


;;;; The prompt

(ert-deftest cmacs-deixis-ask-test-compose-two-contexts ()
  "Two referents give two numbered contexts, and the words say which is which."
  (cmacs-deixis-ask-tests--with-pointing
    (let* ((text "compare this and that")
           (prompt (cmacs-deixis-ask-compose
                    text
                    (list (list :source 'buffer :description "text from a buffer"
                                :text "ALPHA" :extra "Diagnostics: none")
                          (list :source 'ocr :description "text read by OCR"
                                :text "BETA"))
                    (list :bindings (bind text)
                          :instruction "Compare the two."))))
      (should (string-match-p "compare this \\[this=①\\] and that \\[that=②\\]"
                              prompt))
      (should (string-match-p "① text from a buffer\n<<<\nALPHA\n>>>\nDiagnostics: none"
                              prompt))
      (should (string-match-p "② text read by OCR\n<<<\nBETA\n>>>" prompt))
      (should (string-match-p "Compare the two\\." prompt))
      ;; Neither window's title nor its application is in it.
      (should-not (string-match-p "librewolf\\|Secret plans\\|gst" prompt))))
  ;; Typed, with no bindings: the question as it is.
  (let ((prompt (cmacs-deixis-ask-compose
                 "What is this?" (list (list :description "d" :text "T")))))
    (should (string-match-p "said:\n\n  What is this\\?\n" prompt)))
  ;; A follow-up names what it continues.
  (should (string-match-p
           "Answer the earlier question (\"what is that\") for this instead"
           (cmacs-deixis-ask-compose "and that one"
                                     (list (list :description "d" :text "T"))
                                     (list :followup t
                                           :previous "what is that")))))

(ert-deftest cmacs-deixis-ask-test-compare-end-to-end ()
  "\"Compare this and that\": both things are read and both are in one prompt."
  (cmacs-deixis-ask-tests--with-pointing
    (let ((cmacs-deixis-ask--extractors nil)
          (cmacs-deixis-ask--last nil)
          (asked nil))
      (cmacs-deixis-ask-register-extractor
       'app :applies (lambda (&rest _) t)
       :extract (lambda (r scope done)
                  (funcall done
                           (list :source 'ocr :foreign t
                                 :description (format "window %s%s"
                                                      (plist-get r :client-id)
                                                      (if scope " whole" ""))
                                 :text (format "words of %s"
                                               (plist-get r :client))))))
      (cmacs-deixis-ask-tests--with-redact nil
        (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p) (lambda (&rest _) nil))
                  ((symbol-function 'cmacs-ai-textops-stream)
                   (lambda (&rest args) (setq asked args) (current-buffer))))
          (let ((text "what is the difference between this window and that"))
            (should (cmacs-deixis-ask-utterance text (bind text)))
            (cmacs-deixis-ask--voice-end nil)
            (should (equal (nth 0 asked) cmacs-deixis-ask-title))
            (let ((prompt (nth 3 asked)))
              (should (string-match-p "① window 12 whole\n<<<\nwords of browser"
                                      prompt))
              (should (string-match-p "② window 7\n<<<\nwords of term" prompt))
              (should (string-match-p "this \\[this=①\\] window" prompt))
              (should (string-match-p "how they differ" prompt)))))))))


;;;; Asking, speaking and following up

(defmacro cmacs-deixis-ask-tests--with-model (&rest body)
  "Run BODY with the model and the voice loop stubbed.
The result window (`cmacs-ai-output') and `cmacs-ai-textops-stream' are
real.  Bound for BODY: `streams', a list of (SESSION PROMPT CALLBACK)
newest first; `sessions', how many sessions were made; `spoken', the
text handed to the loop's speech, newest first; `states', the loop
states entered; `cancelled', the sessions cancelled."
  (declare (indent 0))
  `(let ((streams nil) (sessions 0) (spoken nil) (states nil) (cancelled nil)
         (cmacs-deixis-ask--extractors nil)
         (cmacs-deixis-ask--last nil)
         (cmacs-deixis-ask--voice nil)
         (cmacs-voice-loop-mode t)
         (cmacs-voice-loop-speak t)
         (cmacs-voice-loop--stream-open nil)
         (cmacs-voice-loop--tts-tail "")
         (cmacs-voice-loop-barge-in-cancels-stream t)
         (cmacs-voice-loop-state-change-functions nil))
     (ignore sessions spoken states cancelled)
     (cmacs-deixis-ask-register-extractor
      'app :applies (lambda (&rest _) t)
      :extract (lambda (r _scope done)
                 (funcall done
                          (list :source 'ocr :foreign t
                                :description "text off a window"
                                :text (format "words of %s"
                                              (plist-get r :client))))))
     (unwind-protect
         (cmacs-deixis-ask-tests--with-redact nil
           (cl-letf (((symbol-function 'cmacs-deixis-ask--denied-p)
                      (lambda (&rest _) nil))
                     ((symbol-function 'cmacs-ai--ensure) (lambda (&rest _) t))
                     ((symbol-function 'cmacs-ai-make-session)
                      (lambda (&rest _)
                        (cl-incf sessions)
                        (cons (* 10 sessions) (+ 1 (* 10 sessions)))))
                     ((symbol-function 'cmacs-ai-free-session) (lambda (&rest _) t))
                     ((symbol-function 'cmacs-ai-chat-stream)
                      (lambda (session prompt callback &rest _)
                        (push (list session prompt callback) streams)
                        t))
                     ((symbol-function 'cmacs-ai-chat-cancel)
                      (lambda (session &rest _) (push session cancelled) t))
                     ((symbol-function 'cmacs-ai-output-show) (lambda (&rest _) nil))
                     ((symbol-function 'cmacs-voice-loop--set-state)
                      (lambda (new &rest _) (push new states)))
                     ((symbol-function 'cmacs-voice-loop--feed-reply)
                      (lambda (chunk &rest _) (push chunk spoken)))
                     ((symbol-function 'cmacs-voice-loop-speak)
                      (lambda (text &rest _) (push text spoken))))
             ,@body))
       (advice-remove 'cmacs-ai-output-append #'cmacs-deixis-ask--tap-append)
       (advice-remove 'cmacs-ai-output-finish #'cmacs-deixis-ask--tap-finish)
       (advice-remove 'cmacs-ai-output--settle-followup
                      #'cmacs-deixis-ask--tap-finish)
       (when-let* ((buf (get-buffer (cmacs-deixis-ask--buffer-name))))
         (with-current-buffer buf (setq cmacs-ai-output--session nil))
         (kill-buffer buf)))))

(ert-deftest cmacs-deixis-ask-test-voice-answer-is-shown-and-spoken ()
  "A spoken question streams into the result window and into the loop's speech."
  (skip-unless (locate-library "cmacs-ai-textops"))
  (cmacs-deixis-ask-tests--with-pointing
    (cmacs-deixis-ask-tests--with-model
      (should (cmacs-deixis-ask-utterance "what is that" (bind "what is that")))
      ;; The loop is waiting for a reply: talking now would be a barge-in.
      (should (equal states '(thinking)))
      (should cmacs-voice-loop--stream-open)
      (should (= (length streams) 1))
      (let ((prompt (nth 1 (car streams)))
            (callback (nth 2 (car streams)))
            (buf (get-buffer (cmacs-deixis-ask--buffer-name))))
        (should (string-match-p "what is that \\[that=①\\]" prompt))
        (should (string-match-p "words of browser" prompt))
        (funcall callback '(:start))
        (funcall callback '(:delta "It is a browser. "))
        (funcall callback '(:delta "Showing docs"))
        ;; Shown ...
        (with-current-buffer buf
          (should (string-match-p "It is a browser\\. Showing docs"
                                  (buffer-string))))
        ;; ... and spoken, through the loop's own sentence queue.
        (should (equal (reverse spoken) '("It is a browser. " "Showing docs")))
        (setq cmacs-voice-loop--tts-tail "Showing docs")
        (funcall callback '(:end :text "It is a browser. Showing docs" :stop end))
        ;; The tail is flushed and the loop's reply is closed.
        (should (equal (car spoken) "Showing docs"))
        (should-not cmacs-voice-loop--stream-open)
        (should-not cmacs-deixis-ask--voice)
        ;; The window kept its session for a follow-up.
        (with-current-buffer buf
          (should cmacs-ai-output--session)
          (should cmacs-ai-output--compose-marker))))))

(ert-deftest cmacs-deixis-ask-test-voice-followup-reuses-session ()
  "\"And that one?\" goes to the SAME session, with the new thing's text."
  (skip-unless (locate-library "cmacs-ai-textops"))
  (cmacs-deixis-ask-tests--with-pointing
    (cmacs-deixis-ask-tests--with-model
      (should (cmacs-deixis-ask-utterance "what is that" (bind "what is that")))
      (funcall (nth 2 (car streams)) '(:delta "A browser."))
      (funcall (nth 2 (car streams)) '(:end :text "A browser." :stop end))
      (should (= sessions 1))
      (let ((first-session (nth 0 (car streams)))
            (buf (get-buffer (cmacs-deixis-ask--buffer-name))))
        ;; The user had started typing a follow-up of their own.
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "my own draft"))
        ;; The pointer is on the terminal now.
        (cl-letf (((symbol-function 'cmacs-deixis--pointer-referent)
                   (lambda (&rest _) cmacs-deixis-ask-tests--term)))
          (let ((b (cmacs-deixis-resolve "and that one" nil nil)))
            (should (cmacs-deixis-ask-utterance "and that one" b))))
        (should (= (length streams) 2))
        ;; No new session: the conversation the answer is in.
        (should (= sessions 1))
        (should (eql (nth 0 (car streams)) first-session))
        (let ((prompt (nth 1 (car streams))))
          (should (string-match-p "words of term" prompt))
          (should (string-match-p "now pointed at something else" prompt))
          (should (string-match-p "earlier question (\"what is that\")" prompt))
          (should-not (string-match-p "my own draft" prompt)))
        (should cmacs-voice-loop--stream-open)
        (funcall (nth 2 (car streams)) '(:delta "A terminal."))
        (funcall (nth 2 (car streams)) '(:end :text "A terminal." :stop end))
        (should (member "A terminal." spoken))
        (should-not cmacs-voice-loop--stream-open)
        (with-current-buffer buf
          (should (string-match-p "A browser\\.[^z-a]*A terminal\\." (buffer-string)))
          ;; The draft is back where it was being typed.
          (should (equal (string-trim
                          (buffer-substring-no-properties
                           cmacs-ai-output--compose-marker (point-max)))
                         "my own draft")))
        ;; The question a later "and this?" continues is still the first.
        (should (equal (plist-get cmacs-deixis-ask--last :question)
                       "what is that"))))))

(ert-deftest cmacs-deixis-ask-test-stale-followup-asks-afresh ()
  "A follow-up after the window is gone asks the old question about the new thing."
  (skip-unless (locate-library "cmacs-ai-textops"))
  (cmacs-deixis-ask-tests--with-pointing
    (cmacs-deixis-ask-tests--with-model
      (should (cmacs-deixis-ask-utterance "what is that" (bind "what is that")))
      (funcall (nth 2 (car streams)) '(:end :text "A browser." :stop end))
      ;; Long ago.
      (setq cmacs-deixis-ask--last
            (plist-put cmacs-deixis-ask--last :time 0.0))
      (should (cmacs-deixis-ask-utterance "and that one" (bind "and that one")))
      (should (= sessions 2))
      (should (string-match-p "earlier question (\"what is that\")"
                              (nth 1 (car streams)))))))

(ert-deftest cmacs-deixis-ask-test-barge-in-stops-the-answer ()
  "Talking over a spoken answer cancels its stream and stops its speech."
  (skip-unless (locate-library "cmacs-ai-textops"))
  (cmacs-deixis-ask-tests--with-pointing
    (cmacs-deixis-ask-tests--with-model
      (should (cmacs-deixis-ask-utterance "explain this" (bind "explain this")))
      (should (memq #'cmacs-deixis-ask--on-loop-state
                    cmacs-voice-loop-state-change-functions))
      (let ((session (nth 0 (car streams)))
            (callback (nth 2 (car streams))))
        (funcall callback '(:delta "First sentence. "))
        ;; Any other change of state is not a barge-in.
        (cmacs-deixis-ask--on-loop-state 'speaking 'thinking)
        (should-not cancelled)
        ;; The loop does this itself on a barge-in, then says `hearing'.
        (setq cmacs-voice-loop--stream-open nil)
        (cmacs-deixis-ask--on-loop-state 'hearing 'speaking)
        (should (equal cancelled (list session)))
        (should-not cmacs-deixis-ask--voice)
        ;; What still arrives is shown but not spoken.
        (let ((before spoken))
          (funcall callback '(:delta "Second sentence."))
          (should (eq spoken before)))))))

(ert-deftest cmacs-deixis-ask-test-typed-question-is-not-spoken ()
  "The keyboard door answers in the window only, and leaves the loop alone."
  (skip-unless (locate-library "cmacs-ai-textops"))
  (cmacs-deixis-ask-tests--with-model
    (cmacs-deixis-ask-referent cmacs-deixis-ask-tests--browser "What is this?")
    (should (= (length streams) 1))
    (should-not states)
    (should-not cmacs-voice-loop--stream-open)
    (funcall (nth 2 (car streams)) '(:delta "A browser. "))
    (funcall (nth 2 (car streams)) '(:end :text "A browser. " :stop end))
    (should-not spoken)))


;;;; The doors

(ert-deftest cmacs-deixis-ask-test-filter-asks-commands-first ()
  "Through `cmacs-deixis-filter': a command keeps its utterance, a question is taken."
  (cmacs-deixis-ask-tests--with-pointing
    (let ((cmacs-deixis-unclaimed-functions '(cmacs-deixis-ask-utterance))
          (cmacs-deixis--segments nil)
          (cmacs-deixis-last-bindings nil)
          (cmacs-deixis-ask--last nil)
          (cmacs-voice-loop--last-target 'chat)
          (ran nil) (command nil))
      (cl-letf (((symbol-function 'cmacs-deixis-ask-run)
                 (lambda (question referents &rest props)
                   (push (list question (length referents)
                               (plist-get props :voice))
                         ran)
                   t))
                ((symbol-function 'cmacs-deixis-run-command)
                 (lambda (text &rest _)
                   (and (string-prefix-p "close" text) (setq command text)))))
        ;; A question: taken, nothing goes on to the route.
        (should-not (cmacs-deixis-filter "what is that" 1 nil))
        (should (equal ran '(("what is that" 1 t))))
        ;; A command: the hook is not even asked.
        (setq ran nil)
        (should-not (cmacs-deixis-filter "close that" 2 nil))
        (should (equal command "close that"))
        (should-not ran)
        ;; Neither: on to the route, annotated, as before.
        (let ((out (cmacs-deixis-filter "make this bigger" 3 nil)))
          (should (string-match-p "\\[this=①\\]" out))
          (should-not ran))
        ;; No demonstrative: untouched.
        (should (equal (cmacs-deixis-filter "what is the weather" 4 nil)
                       "what is the weather"))
        ;; Switched off: questions go on to the route too.
        (let ((cmacs-deixis-ask-voice nil))
          (should (stringp (cmacs-deixis-filter "what is that" 5 nil)))
          (should-not ran))))))

(ert-deftest cmacs-deixis-ask-test-at-pointer ()
  "The door with no voice: the pointer now, a typed or given question."
  (with-temp-buffer
    (insert "some text here")
    (let* ((here (list :kind 'buffer-position :buffer (current-buffer)
                       :position 3))
           (ran nil) (said nil))
      (cmacs-deixis-ask-tests--with-redact nil
        (cl-letf (((symbol-function 'cmacs-deixis-referent-now) (lambda () here))
                  ((symbol-function 'cmacs-deixis-ask-run)
                   (lambda (question referents &rest props)
                     (setq ran (list question referents props))))
                  ((symbol-function 'cmacs-deixis-ask--say)
                   (lambda (_voice fmt &rest args)
                     (setq said (apply #'format fmt args))
                     nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "  Explain this.  ")))
          (cmacs-deixis-ask-at-pointer "what is this file")
          (should (equal (nth 0 ran) "what is this file"))
          (should (equal (nth 1 ran) (list here)))
          ;; "This file" is all of it; not spoken.
          (should (equal (plist-get (nth 2 ran) :scopes) '(whole)))
          (should-not (plist-get (nth 2 ran) :voice))
          ;; No question given: read, trimmed.
          (cmacs-deixis-ask-at-pointer)
          (should (equal (nth 0 ran) "Explain this."))
          (should (equal (plist-get (nth 2 ran) :scopes) '(nil)))
          ;; An empty answer asks nothing.
          (setq ran nil)
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) " ")))
            (cmacs-deixis-ask-at-pointer))
          (should-not ran)))
      ;; A refused thing is refused before anything is typed.
      (cmacs-deixis-ask-tests--with-redact (list :buffer-p (lambda (_b) t))
        (cl-letf (((symbol-function 'cmacs-deixis-referent-now) (lambda () here))
                  ((symbol-function 'cmacs-deixis-ask-run)
                   (lambda (&rest args) (setq ran args)))
                  ((symbol-function 'cmacs-deixis-ask--say)
                   (lambda (_voice fmt &rest args)
                     (setq said (apply #'format fmt args))
                     nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) (error "Must not be asked"))))
          (cmacs-deixis-ask-at-pointer)
          (should-not ran)
          (should (equal said cmacs-deixis-ask-refusal-text))))
      ;; Nothing pointed at.
      (cl-letf (((symbol-function 'cmacs-deixis-referent-now) (lambda () nil))
                ((symbol-function 'cmacs-deixis-ask--say)
                 (lambda (_voice fmt &rest args)
                   (setq said (apply #'format fmt args))
                   nil)))
        (cmacs-deixis-ask-at-pointer)
        (should (string-match-p "Nothing is being pointed at" said))))))

(ert-deftest cmacs-deixis-ask-test-menu-card-over-another-window ()
  "Over another program's window the question comes from the gowl menu card."
  (let ((got 'unset) (card nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'cmacs-gowl-ai-field--choose)
               (lambda (prompt lines callback &rest _)
                 (setq card (cons prompt lines))
                 (funcall callback 1)))
              ((symbol-function 'cmacs-gowl-ai-field--read-instruction)
               (lambda (&rest _) "typed question")))
      (skip-unless (locate-library "cmacs-gowl-ai-field"))
      (cmacs-deixis-ask--read-question cmacs-deixis-ask-tests--browser
                                       (lambda (q) (setq got q)))
      (should (equal got (nth 1 cmacs-deixis-ask-menu)))
      ;; The rows are the menu plus one for something else.
      (should (= (length (cdr card)) (1+ (length cmacs-deixis-ask-menu))))
      ;; The last row reads a typed question.
      (cl-letf (((symbol-function 'cmacs-gowl-ai-field--choose)
                 (lambda (_prompt lines callback &rest _)
                   (funcall callback (1- (length lines))))))
        (cmacs-deixis-ask--read-question cmacs-deixis-ask-tests--browser
                                         (lambda (q) (setq got q)))
        (should (equal got "typed question")))
      ;; A cancelled card asks nothing.
      (cl-letf (((symbol-function 'cmacs-gowl-ai-field--choose)
                 (lambda (_prompt _lines callback &rest _) (funcall callback nil))))
        (cmacs-deixis-ask--read-question cmacs-deixis-ask-tests--browser
                                         (lambda (q) (setq got q)))
        (should-not got))
      ;; A place in Emacs, but another program has the keyboard: a
      ;; minibuffer read would wait for keys that go elsewhere.
      (with-temp-buffer
        (let ((here (list :kind 'buffer-position :buffer (current-buffer)
                          :position 1)))
          (cl-letf (((symbol-function 'gowl-focused-client) (lambda (&rest _) 'c))
                    ((symbol-function 'gowl-client-info) (lambda (&rest _) nil))
                    ((symbol-function 'gowl-client-pid) (lambda (&rest _) 1))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) (error "Must not read here"))))
            (cmacs-deixis-ask--read-question here (lambda (q) (setq got q)))
            (should (equal got (nth 1 cmacs-deixis-ask-menu))))
          ;; Emacs has the keyboard: the minibuffer.
          (cl-letf (((symbol-function 'gowl-focused-client) (lambda (&rest _) 'c))
                    ((symbol-function 'gowl-client-info) (lambda (&rest _) nil))
                    ((symbol-function 'gowl-client-pid)
                     (lambda (&rest _) (emacs-pid)))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "typed here")))
            (cmacs-deixis-ask--read-question here (lambda (q) (setq got q)))
            (should (equal got "typed here"))))))))

(ert-deftest cmacs-deixis-ask-test-ai-menu-entry ()
  "The AI menu's extension point gets an entry that asks about the click's target."
  (skip-unless (locate-library "cmacs-ai-actions"))
  (require 'cmacs-ai-actions)
  (require 'cmacs-ai-target)
  (cmacs-deixis-ask-register-menu)
  (let ((action (gethash 'deixis-ask cmacs-ai--actions)))
    (should action)
    (should (eq (plist-get action :group) 'ask))
    (with-temp-buffer
      (insert "abcdef")
      (let ((asked nil))
        (cl-letf (((symbol-function 'cmacs-deixis-ask-referent)
                   (lambda (referent &rest _) (setq asked referent))))
          ;; A region target is the region; anything else its position.
          (funcall (plist-get action :run)
                   (cmacs-ai-target-create :kind 'region :buffer (current-buffer)
                                           :bounds '(2 . 5)))
          (should (eq (plist-get asked :kind) 'region))
          (should (equal (list (plist-get asked :beg) (plist-get asked :end))
                         '(2 5)))
          (funcall (plist-get action :run)
                   (cmacs-ai-target-create :kind 'symbol :buffer (current-buffer)
                                           :bounds '(3 . 4)))
          (should (eq (plist-get asked :kind) 'buffer-position))
          (should (eql (plist-get asked :position) 3))
          (should (eq (plist-get asked :buffer) (current-buffer))))))))

(defvar cmacs-ai--actions)

(ert-deftest cmacs-deixis-ask-test-referent-now ()
  "`cmacs-deixis-referent-now': the region, unless the pointer is elsewhere."
  (with-temp-buffer
    (insert "one two three")
    (let ((cmacs-deixis-fallback-to-point t)
          (elsewhere '(:kind window :client c :client-id 3 :confidence 1.0
                       :window nil)))
      (save-window-excursion
        (set-window-buffer (selected-window) (current-buffer))
        ;; Nothing pointed at, no region: point.
        (cl-letf (((symbol-function 'cmacs-deixis--pointer-now) (lambda () nil)))
          (should (eq (plist-get (cmacs-deixis-referent-now) :kind) 'point))
          (let ((cmacs-deixis-fallback-to-point nil))
            (should-not (cmacs-deixis-referent-now))))
        ;; A pointer and no region: the pointer.
        (cl-letf (((symbol-function 'cmacs-deixis--pointer-now)
                   (lambda () elsewhere)))
          (should (eq (cmacs-deixis-referent-now) elsewhere))
          ;; A region, but the pointer is on another window: still the pointer.
          (let ((transient-mark-mode t))
            (set-mark 1)
            (goto-char 4)
            (activate-mark)
            (should (eq (cmacs-deixis-referent-now) elsewhere))
            ;; The pointer in the region's own window: the region.
            (cl-letf (((symbol-function 'cmacs-deixis--pointer-now)
                       (lambda ()
                         (list :kind 'buffer-position :confidence 1.0
                               :window (selected-window)
                               :buffer (current-buffer) :position 9))))
              (should (eq (plist-get (cmacs-deixis-referent-now) :kind)
                          'region)))))))))

(ert-deftest cmacs-deixis-ask-test-frame-referent-carries-its-pixel ()
  "A frame referent keeps the pixel it was resolved from, for a web view."
  (should (equal (cmacs-deixis-ask--window-fraction '(:kind buffer-position))
                 '(0.5 . 0.5)))
  (cl-letf (((symbol-function 'window-body-pixel-edges)
             (lambda (&rest _) '(100 20 500 420))))
    (should (equal (cmacs-deixis-ask--window-fraction
                    (list :window (selected-window) :frame-x 200 :frame-y 320))
                   '(0.25 . 0.75)))
    ;; Off the body (the mode line): clamped onto it.
    (should (equal (cmacs-deixis-ask--window-fraction
                    (list :window (selected-window) :frame-x 50 :frame-y 900))
                   '(0.0 . 1.0)))))

(provide 'cmacs-deixis-ask-tests)

;;; cmacs-deixis-ask-tests.el ends here
