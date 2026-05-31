;;; cmacs-gsurf-lite-tests.el --- Tests for cmacs-gsurf-lite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for gsurf-lite (offscreen render -> shr text buffer).
;; These avoid a live display: they check definitions, the extraction
;; JavaScript shape, the base-URL DOM wrapper, and the shr <a> tag
;; handler's id-carrying behaviour.  The full offscreen render path
;; needs a display + web process and is exercised by an ad-hoc / Xvfb
;; GUI smoke run, not here.

;;; Code:

(require 'ert)
(require 'dom)
(require 'cmacs-gsurf-lite)

(ert-deftest cmacs-gsurf-lite-feature-loaded ()
  "The cmacs-gsurf-lite feature should be loadable."
  (should (featurep 'cmacs-gsurf-lite)))

(ert-deftest cmacs-gsurf-lite-entry-points-defined ()
  "Entry points and navigation commands should be defined."
  (dolist (cmd '(cmacs-gsurf-lite cmacs-gsurf-lite-follow
                 cmacs-gsurf-lite-reload cmacs-gsurf-lite-back
                 cmacs-gsurf-lite-forward cmacs-gsurf-lite-open
                 cmacs-gsurf-lite-browse-external))
    (should (commandp cmd)))
  (should (fboundp 'cmacs-gsurf-lite-browse-url))
  (should (fboundp 'cmacs-gsurf-lite-mode)))

(ert-deftest cmacs-gsurf-lite-mcp-helpers-defined ()
  "MCP-facing helpers should be defined."
  (should (fboundp 'cmacs-gsurf-lite-mcp-open))
  (should (fboundp 'cmacs-gsurf-lite-mcp-extract-text)))

(ert-deftest cmacs-gsurf-lite-defcustoms-exist ()
  "gsurf-lite defcustoms should be defined."
  (should (boundp 'cmacs-gsurf-lite-extract-settle))
  (should (boundp 'cmacs-gsurf-lite-shr-width))
  ;; The SPA re-extract schedule (so late-rendered forms/content appear).
  (should (boundp 'cmacs-gsurf-lite-resettle-times))
  (should (consp cmacs-gsurf-lite-resettle-times)))

(ert-deftest cmacs-gsurf-lite-extract-js-shape ()
  "The extraction JS should tag interactive elements and return HTML."
  (let ((js cmacs-gsurf-lite--extract-js))
    (should (> (length js) 0))
    (should (string-match-p "data-cmlite-id" js))
    (should (string-match-p "outerHTML" js))
    (should (string-match-p "querySelectorAll" js))))

(ert-deftest cmacs-gsurf-lite-with-base-wraps-html ()
  "`cmacs-gsurf-lite--with-base' wraps an <html> dom in a <base> node."
  (let* ((html (dom-node 'html nil (dom-node 'body nil "hi")))
         (wrapped (cmacs-gsurf-lite--with-base html "https://example.com/")))
    (should (eq (dom-tag wrapped) 'base))
    (should (equal (dom-attr wrapped 'href) "https://example.com/"))
    ;; Non-html nodes pass through unchanged.
    (let ((p (dom-node 'p nil "x")))
      (should (eq (cmacs-gsurf-lite--with-base p "https://e.com/") p)))))

(ert-deftest cmacs-gsurf-lite-tag-a-carries-id ()
  "Rendering an <a data-cmlite-id> carries the id as a text property."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-a
       (dom-node 'a '((href . "https://e.com/x")
                      (data-cmlite-id . "cml7"))
                 "link")))
    (goto-char (point-min))
    (should (string-match-p
             "cml7"
             (or (get-text-property (point) 'cmacs-gsurf-lite-id) "")))))

(ert-deftest cmacs-gsurf-lite-link-opens-in-place ()
  "A rendered link routes RET/mouse to `cmacs-gsurf-lite-follow', NOT
shr's `shr-browse-url' (which would open it in eww / the external
browser).  Guards the bug where clicking a link opened an eww buffer."
  (require 'shr)
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-a
       (dom-node 'a '((href . "https://e.com/x")) "link")))
    (goto-char (point-min))
    (let ((km (get-text-property (point) 'keymap)))
      (should (eq km cmacs-gsurf-lite-link-keymap))
      (should (eq (lookup-key km (kbd "RET")) 'cmacs-gsurf-lite-follow))
      (should (eq (lookup-key km [mouse-2]) 'cmacs-gsurf-lite-follow))
      (should (eq (lookup-key km [mouse-1]) 'cmacs-gsurf-lite-follow))
      ;; The link still carries shr's URL for the follow command to read,
      ;; and still inherits shr-map for non-navigation keys.
      (should (equal (get-text-property (point) 'shr-url) "https://e.com/x"))
      (should (eq (keymap-parent km) shr-map)))))

(ert-deftest cmacs-gsurf-lite-offscreen-supported ()
  "gsurf-lite relies on headless attach: the offscreen predicate exists
and `cmacs-gsurf-attach' accepts the OFFSCREEN argument so the live
widget is never placed over the rendered text."
  (should (fboundp 'cmacs-gsurf-offscreen-p))
  (should (>= (cdr (func-arity 'cmacs-gsurf-attach)) 2)))

;;;; Forms / login

(ert-deftest cmacs-gsurf-lite-form-commands-defined ()
  "The form fill/submit/navigation surface should be defined."
  (dolist (cmd '(cmacs-gsurf-lite-submit
                 cmacs-gsurf-lite-next-field
                 cmacs-gsurf-lite-prev-field))
    (should (commandp cmd)))
  (dolist (fn '(cmacs-gsurf-lite--tag-input
                cmacs-gsurf-lite--tag-textarea
                cmacs-gsurf-lite--tag-select
                cmacs-gsurf-lite--tag-button
                cmacs-gsurf-lite--set-field
                cmacs-gsurf-lite--field-activate
                cmacs-gsurf-lite--field-label))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-lite-extract-js-syncs-values ()
  "The extraction JS reflects live form state into attributes and masks
passwords (their value is never written into the HTML)."
  (let ((js cmacs-gsurf-lite--extract-js))
    (should (string-match-p "data-cmlite-filled" js))     ; password marker
    (should (string-match-p "setAttribute('value'" js))   ; text value sync
    (should (string-match-p "removeAttribute('value')" js)) ; password masked
    (should (string-match-p "selected" js))))             ; <option> sync

(ert-deftest cmacs-gsurf-lite-tag-input-renders-field ()
  "An <input type=text data-cmlite-id> renders as an activatable field
carrying its plist (id/type/name) and the field keymap."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "text") (name . "user")
                          (data-cmlite-id . "cml3")))))
    (goto-char (point-min))
    (let ((f (get-text-property (point) 'cmacs-gsurf-lite-field)))
      (should f)
      (should (equal (plist-get f :id) "cml3"))
      (should (equal (plist-get f :type) "text"))
      (should (equal (plist-get f :name) "user"))
      (should (keymapp (get-text-property (point) 'keymap))))))

(ert-deftest cmacs-gsurf-lite-tag-input-password-masked ()
  "A password input never shows its value; it renders as a masked field."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "password") (name . "pass")
                          (value . "hunter2")
                          (data-cmlite-id . "cml4")))))
    (should-not (string-match-p "hunter2" (buffer-string)))
    (let ((f (get-text-property (point-min) 'cmacs-gsurf-lite-field)))
      (should (equal (plist-get f :type) "password")))))

(ert-deftest cmacs-gsurf-lite-tag-input-hidden-skipped ()
  "A hidden input renders nothing (no field, no text)."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "hidden") (name . "csrf")
                          (value . "tok") (data-cmlite-id . "cml5")))))
    (should (= (buffer-size) 0))))

(ert-deftest cmacs-gsurf-lite-field-label-priority ()
  "`cmacs-gsurf-lite--field-label' prefers aria-label, then name, etc."
  (should (equal "Email"
                 (cmacs-gsurf-lite--field-label
                  (dom-node 'input '((aria-label . "Email") (name . "e"))))))
  (should (equal "user"
                 (cmacs-gsurf-lite--field-label
                  (dom-node 'input '((name . "user") (placeholder . "p"))))))
  (should (equal "Search"
                 (cmacs-gsurf-lite--field-label
                  (dom-node 'input '((placeholder . "Search")))))))

(ert-deftest cmacs-gsurf-lite-form-keys-bound ()
  "TAB/S-TAB move between fields; C-c C-c submits."
  (should (eq (lookup-key cmacs-gsurf-lite-mode-map (kbd "TAB"))
              'cmacs-gsurf-lite-next-field))
  (should (eq (lookup-key cmacs-gsurf-lite-mode-map (kbd "<backtab>"))
              'cmacs-gsurf-lite-prev-field))
  (should (eq (lookup-key cmacs-gsurf-lite-mode-map (kbd "C-c C-c"))
              'cmacs-gsurf-lite-submit)))

(provide 'cmacs-gsurf-lite-tests)
;;; cmacs-gsurf-lite-tests.el ends here
