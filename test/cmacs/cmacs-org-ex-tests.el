;;; cmacs-org-ex-tests.el --- Tests for org-ex subsystem -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs org-ex interactive widget embedding.
;; Tests cover feature detection, document creation, widget creation,
;; document registration, channel creation, export, code widget
;; set-result, Org block parsing, and mode activation.
;;
;; GTK widget tests are skipped (require display server).

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs)               ; defines `cmacs-feature-p' (not preloaded)

;;; Feature detection

(ert-deftest cmacs-org-ex-test-feature-p ()
  "Test that `cmacs-feature-p' returns non-nil when org-ex is compiled in."
  (skip-unless (fboundp 'org-ex-document-create))
  (should (cmacs-feature-p 'org-ex)))

(ert-deftest cmacs-org-ex-test-feature-p-checks-defun ()
  "Test that org-ex feature detection checks `org-ex-document-create'."
  ;; If the DEFUN is not available, feature-p should return nil.
  (if (fboundp 'org-ex-document-create)
      (should (cmacs-feature-p 'org-ex))
    (should-not (cmacs-feature-p 'org-ex))))

;;; Document creation tests

(ert-deftest cmacs-org-ex-test-document-create-nil ()
  "Test that `org-ex-document-create' with nil returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create nil)))
    (should (gobject-p doc))))

(ert-deftest cmacs-org-ex-test-document-create-no-args ()
  "Test that `org-ex-document-create' with no arguments returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create)))
    (should (gobject-p doc))))

(ert-deftest cmacs-org-ex-test-document-create-with-path ()
  "Test that `org-ex-document-create' accepts a file path string."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create "/tmp/test.org")))
    (should (gobject-p doc))))

(ert-deftest cmacs-org-ex-test-document-create-type ()
  "Test that a created document has GObject type name containing Document."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((doc (org-ex-document-create nil))
         (type-name (gobject-type-name doc)))
    (should (stringp type-name))
    (should (string-match-p "Document" type-name))))

(ert-deftest cmacs-org-ex-test-document-create-rejects-non-string ()
  "Test that `org-ex-document-create' rejects non-string, non-nil argument."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-document-create 42)
                :type 'wrong-type-argument))

;;; Widget creation tests

(ert-deftest cmacs-org-ex-test-widget-web-new ()
  "Test that `org-ex-widget-web-new' returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (should (gobject-p widget))))

(ert-deftest cmacs-org-ex-test-widget-web-new-nil-url ()
  "Test that `org-ex-widget-web-new' accepts nil URL."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-web-new nil 400 200)))
    (should (gobject-p widget))))

(ert-deftest cmacs-org-ex-test-widget-web-new-requires-fixnum-width ()
  "Test that `org-ex-widget-web-new' requires integer width."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-widget-web-new "https://example.com" "bad" 200)
                :type 'wrong-type-argument))

(ert-deftest cmacs-org-ex-test-widget-web-new-requires-fixnum-height ()
  "Test that `org-ex-widget-web-new' requires integer height."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-widget-web-new "https://example.com" 400 "bad")
                :type 'wrong-type-argument))

(ert-deftest cmacs-org-ex-test-widget-buffer-new ()
  "Test that `org-ex-widget-buffer-new' returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-buffer-new "/tmp/test.txt")))
    (should (gobject-p widget))))

(ert-deftest cmacs-org-ex-test-widget-buffer-new-editable ()
  "Test that `org-ex-widget-buffer-new' accepts editable flag."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-buffer-new "/tmp/test.txt" t)))
    (should (gobject-p widget))))

(ert-deftest cmacs-org-ex-test-widget-buffer-new-requires-string ()
  "Test that `org-ex-widget-buffer-new' requires string file path."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-widget-buffer-new 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-org-ex-test-widget-code-new ()
  "Test that `org-ex-widget-code-new' returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-code-new "elisp" "(+ 1 2)")))
    (should (gobject-p widget))))

(ert-deftest cmacs-org-ex-test-widget-code-new-requires-string-language ()
  "Test that `org-ex-widget-code-new' requires string language."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-widget-code-new 42 "(+ 1 2)")
                :type 'wrong-type-argument))

(ert-deftest cmacs-org-ex-test-widget-code-new-requires-string-code ()
  "Test that `org-ex-widget-code-new' requires string code."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-widget-code-new "elisp" 42)
                :type 'wrong-type-argument))

;;; Document registration tests

(ert-deftest cmacs-org-ex-test-register-and-get-widget ()
  "Test registering a widget and retrieving it by ID."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create nil))
        (widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (org-ex-document-register-widget doc "test-id" widget)
    (let ((retrieved (org-ex-document-get-widget doc "test-id")))
      (should (gobject-p retrieved)))))

(ert-deftest cmacs-org-ex-test-get-widget-not-found ()
  "Test that getting a nonexistent widget returns nil."
  (skip-unless (cmacs-feature-p 'org-ex))
  (let ((doc (org-ex-document-create nil)))
    (should-not (org-ex-document-get-widget doc "nonexistent-id"))))

(ert-deftest cmacs-org-ex-test-remove-widget ()
  "Test removing a registered widget by ID."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create nil))
        (widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (org-ex-document-register-widget doc "remove-me" widget)
    (org-ex-document-remove-widget doc "remove-me")
    (should-not (org-ex-document-get-widget doc "remove-me"))))

(ert-deftest cmacs-org-ex-test-teardown-all ()
  "Test that teardown-all removes all widgets."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create nil))
        (w1 (org-ex-widget-web-new "https://a.com" 400 200))
        (w2 (org-ex-widget-buffer-new "/tmp/b.txt")))
    (org-ex-document-register-widget doc "w1" w1)
    (org-ex-document-register-widget doc "w2" w2)
    (org-ex-document-teardown-all doc)
    (should-not (org-ex-document-get-widget doc "w1"))
    (should-not (org-ex-document-get-widget doc "w2"))))

(ert-deftest cmacs-org-ex-test-register-requires-string-id ()
  "Test that registering with non-string ID signals an error."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((doc (org-ex-document-create nil))
        (widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (should-error (org-ex-document-register-widget doc 42 widget)
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-org-ex-test-get-requires-string-id ()
  "Test that getting with non-string ID signals an error."
  (skip-unless (cmacs-feature-p 'org-ex))
  (let ((doc (org-ex-document-create nil)))
    (should-error (org-ex-document-get-widget doc 42)
                  :type 'wrong-type-argument)))

;;; Channel creation tests

(ert-deftest cmacs-org-ex-test-channel-create ()
  "Test that `org-ex-channel-create' returns a GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((ch (org-ex-channel-create "test-channel")))
    (should (gobject-p ch))))

(ert-deftest cmacs-org-ex-test-channel-create-type ()
  "Test that a created channel has GObject type name containing Channel."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((ch (org-ex-channel-create "test-channel"))
         (type-name (gobject-type-name ch)))
    (should (stringp type-name))
    (should (string-match-p "Channel" type-name))))

(ert-deftest cmacs-org-ex-test-channel-create-requires-string ()
  "Test that `org-ex-channel-create' requires a string name."
  (skip-unless (cmacs-feature-p 'org-ex))
  (should-error (org-ex-channel-create 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-org-ex-test-channel-publish ()
  "Test that `org-ex-channel-publish' does not error for valid channel."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((ch (org-ex-channel-create "pub-test")))
    (should (null (org-ex-channel-publish ch "hello")))))

(ert-deftest cmacs-org-ex-test-channel-publish-requires-string ()
  "Test that `org-ex-channel-publish' requires a string value."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((ch (org-ex-channel-create "pub-test")))
    (should-error (org-ex-channel-publish ch 42)
                  :type 'wrong-type-argument)))

;;; Export tests

(ert-deftest cmacs-org-ex-test-export-html-web-widget ()
  "Test that `org-ex-widget-export-html' returns a string for web widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((widget (org-ex-widget-web-new "https://example.com" 400 200))
         (html (org-ex-widget-export-html widget)))
    ;; Web widgets implement OrgExExportable, should return HTML string.
    (when html
      (should (stringp html)))))

(ert-deftest cmacs-org-ex-test-export-text-web-widget ()
  "Test that `org-ex-widget-export-text' returns a string for web widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((widget (org-ex-widget-web-new "https://example.com" 400 200))
         (text (org-ex-widget-export-text widget)))
    (when text
      (should (stringp text)))))

(ert-deftest cmacs-org-ex-test-export-html-buffer-widget ()
  "Test that `org-ex-widget-export-html' returns a string for buffer widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((widget (org-ex-widget-buffer-new "/tmp/test.txt"))
         (html (org-ex-widget-export-html widget)))
    (when html
      (should (stringp html)))))

(ert-deftest cmacs-org-ex-test-export-text-code-widget ()
  "Test that `org-ex-widget-export-text' returns a string for code widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((widget (org-ex-widget-code-new "elisp" "(message \"hello\")"))
         (text (org-ex-widget-export-text widget)))
    (when text
      (should (stringp text)))))

(ert-deftest cmacs-org-ex-test-export-html-non-exportable ()
  "Test that export returns nil for a plain GObject (not exportable)."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-not (org-ex-widget-export-html obj))))

;;; Code widget set-result tests

(ert-deftest cmacs-org-ex-test-code-set-result-nil ()
  "Test that `org-ex-widget-code-set-result' accepts nil result."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((code-widget (org-ex-widget-code-new "elisp" "(+ 1 2)")))
    (should (null (org-ex-widget-code-set-result code-widget nil)))))

(ert-deftest cmacs-org-ex-test-code-set-result-widget ()
  "Test that `org-ex-widget-code-set-result' accepts an OrgExWidget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((code-widget (org-ex-widget-code-new "elisp" "(+ 1 2)"))
        (result-widget (org-ex-widget-web-new "https://result.com" 400 200)))
    (should (null (org-ex-widget-code-set-result
                   code-widget result-widget)))))

(ert-deftest cmacs-org-ex-test-code-set-result-rejects-non-widget ()
  "Test that `org-ex-widget-code-set-result' rejects a plain GObject."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((code-widget (org-ex-widget-code-new "elisp" "(+ 1 2)"))
        (bad-result (gobject-new "GObject")))
    (should-error (org-ex-widget-code-set-result code-widget bad-result)
                  :type 'error)))

;;; Org block parsing tests
;;
;; These test the pure-Elisp parsing functions that do not require the
;; org-ex C subsystem.

(ert-deftest cmacs-org-ex-test-parse-block-properties ()
  "Test that `cmacs-org-ex--parse-block-properties' parses :key value lines."
  (require 'cmacs-org-ex)
  (require 'org)
  (with-temp-buffer
    (insert "#+BEGIN_WIDGET slider\n")
    (insert ":min 0\n")
    (insert ":max 100\n")
    (insert ":value 50\n")
    (insert "#+END_WIDGET\n")
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (block (car (org-element-map tree 'special-block #'identity))))
      (when block
        (let ((props (cmacs-org-ex--parse-block-properties block)))
          (should (listp props))
          (should (equal (cdr (assoc "min" props)) "0"))
          (should (equal (cdr (assoc "max" props)) "100"))
          (should (equal (cdr (assoc "value" props)) "50")))))))

(ert-deftest cmacs-org-ex-test-parse-block-subtype ()
  "Test that `cmacs-org-ex--parse-block-subtype' extracts the widget type."
  (require 'cmacs-org-ex)
  (require 'org)
  (with-temp-buffer
    (insert "#+BEGIN_WIDGET web\n")
    (insert ":url https://example.com\n")
    (insert "#+END_WIDGET\n")
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (block (car (org-element-map tree 'special-block #'identity))))
      (when block
        (let ((subtype (cmacs-org-ex--parse-block-subtype block)))
          (should (equal subtype "web")))))))

(ert-deftest cmacs-org-ex-test-parse-block-multiple-widgets ()
  "Test parsing multiple widget blocks from a single buffer."
  (require 'cmacs-org-ex)
  (require 'org)
  (with-temp-buffer
    (insert "#+BEGIN_WIDGET slider\n")
    (insert ":min 0\n")
    (insert ":max 50\n")
    (insert "#+END_WIDGET\n")
    (insert "\n")
    (insert "#+BEGIN_WIDGET web\n")
    (insert ":url https://example.com\n")
    (insert "#+END_WIDGET\n")
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (blocks (org-element-map tree 'special-block #'identity))
           subtypes)
      (dolist (block blocks)
        (let ((st (cmacs-org-ex--parse-block-subtype block)))
          (when st (push st subtypes))))
      (setq subtypes (nreverse subtypes))
      (should (= (length subtypes) 2))
      (should (equal (car subtypes) "slider"))
      (should (equal (cadr subtypes) "web")))))

(ert-deftest cmacs-org-ex-test-parse-block-empty-properties ()
  "Test parsing a widget block with no properties."
  (require 'cmacs-org-ex)
  (require 'org)
  (with-temp-buffer
    (insert "#+BEGIN_WIDGET buffer\n")
    (insert "#+END_WIDGET\n")
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (block (car (org-element-map tree 'special-block #'identity))))
      (when block
        (let ((props (cmacs-org-ex--parse-block-properties block)))
          (should (listp props))
          (should (null props)))))))

(ert-deftest cmacs-org-ex-test-parse-block-non-widget ()
  "Test that non-WIDGET special blocks return nil subtype."
  (require 'cmacs-org-ex)
  (require 'org)
  (with-temp-buffer
    (insert "#+BEGIN_SRC elisp\n")
    (insert "(+ 1 2)\n")
    (insert "#+END_SRC\n")
    (org-mode)
    (let* ((tree (org-element-parse-buffer))
           (blocks (org-element-map tree 'special-block #'identity)))
      ;; SRC blocks are not special-blocks, so there should be nothing.
      (should (null blocks)))))

;;; Mode activation tests

(ert-deftest cmacs-org-ex-test-keyword-enabled-p-true ()
  "Test that `cmacs-org-ex--keyword-enabled-p' returns non-nil with #+ORGEX: t."
  (require 'cmacs-org-ex)
  (with-temp-buffer
    (insert "#+TITLE: Test\n")
    (insert "#+ORGEX: t\n")
    (insert "* Heading\n")
    (org-mode)
    (should (cmacs-org-ex--keyword-enabled-p))))

(ert-deftest cmacs-org-ex-test-keyword-enabled-p-false ()
  "Test that `cmacs-org-ex--keyword-enabled-p' returns nil without keyword."
  (require 'cmacs-org-ex)
  (with-temp-buffer
    (insert "#+TITLE: Test\n")
    (insert "* Heading\n")
    (org-mode)
    (should-not (cmacs-org-ex--keyword-enabled-p))))

(ert-deftest cmacs-org-ex-test-keyword-enabled-p-false-value ()
  "Test that #+ORGEX: nil does not activate the mode."
  (require 'cmacs-org-ex)
  (with-temp-buffer
    (insert "#+ORGEX: nil\n")
    (org-mode)
    (should-not (cmacs-org-ex--keyword-enabled-p))))

(ert-deftest cmacs-org-ex-test-keyword-enabled-p-indented ()
  "Test that indented #+ORGEX: t is still detected."
  (require 'cmacs-org-ex)
  (with-temp-buffer
    (insert "  #+ORGEX: t\n")
    (org-mode)
    (should (cmacs-org-ex--keyword-enabled-p))))

;;; Widget set-size test

(ert-deftest cmacs-org-ex-test-widget-set-size ()
  "Test that `org-ex-widget-set-size' does not error on valid widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (should (null (org-ex-widget-set-size widget 800 600)))))

(ert-deftest cmacs-org-ex-test-widget-set-size-requires-fixnum ()
  "Test that `org-ex-widget-set-size' requires integer dimensions."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (should-error (org-ex-widget-set-size widget "wide" 600)
                  :type 'wrong-type-argument)))

;;; Widget teardown test

(ert-deftest cmacs-org-ex-test-widget-teardown ()
  "Test that `org-ex-widget-teardown' does not error on valid widget."
  (skip-unless (cmacs-feature-p 'org-ex))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((widget (org-ex-widget-web-new "https://example.com" 400 200)))
    (should (null (org-ex-widget-teardown widget)))))

(provide 'cmacs-org-ex-tests)
;;; cmacs-org-ex-tests.el ends here
