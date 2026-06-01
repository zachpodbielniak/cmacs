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
(require 'cl-lib)
(require 'cmacs-gsurf-lite)

(defun cmacs-gsurf-lite-tests--first-field ()
  "Return the position of the first gsurf-lite field in the buffer, or nil."
  (text-property-not-all (point-min) (point-max)
                         'cmacs-gsurf-lite-field nil))

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
  "An <input type=text data-cmlite-id> renders as an inline-editable field
carrying its plist (id/type/name) and the text-field keymap."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "text") (name . "user")
                          (data-cmlite-id . "cml3")))))
    (let ((pos (cmacs-gsurf-lite-tests--first-field)))
      (should pos)
      (let ((f (get-text-property pos 'cmacs-gsurf-lite-field)))
        (should (equal (plist-get f :id) "cml3"))
        (should (equal (plist-get f :type) "text"))
        (should (equal (plist-get f :name) "user")))
      (should (eq (get-text-property pos 'keymap)
                  cmacs-gsurf-lite-text-field-keymap)))))

(ert-deftest cmacs-gsurf-lite-tag-input-password-masked ()
  "A password input never shows its value; it renders as a masked field."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "password") (name . "pass")
                          (value . "hunter2")
                          (data-cmlite-id . "cml4")))))
    (should-not (string-match-p "hunter2" (buffer-string)))
    (let* ((pos (cmacs-gsurf-lite-tests--first-field))
           (f (get-text-property pos 'cmacs-gsurf-lite-field)))
      (should (equal (plist-get f :type) "password")))))

;;;; Inline editing

(ert-deftest cmacs-gsurf-lite-inline-helpers-defined ()
  "The inline-editing surface should be defined."
  (dolist (fn '(cmacs-gsurf-lite--self-insert
                cmacs-gsurf-lite--delete-backward
                cmacs-gsurf-lite--delete-forward
                cmacs-gsurf-lite--field-bounds
                cmacs-gsurf-lite--field-value
                cmacs-gsurf-lite--set-field-quiet
                cmacs-gsurf-lite--flush-pending
                cmacs-gsurf-lite--reset-edit-state
                cmacs-gsurf-lite--insert-text-field))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-lite-text-field-keymap-edits ()
  "The inline text-field keymap remaps self-insert/delete and keeps RET."
  (let ((m cmacs-gsurf-lite-text-field-keymap))
    (should (eq (lookup-key m [remap self-insert-command])
                'cmacs-gsurf-lite--self-insert))
    (should (eq (lookup-key m (kbd "DEL")) 'cmacs-gsurf-lite--delete-backward))
    ;; RET still opens the minibuffer prompt path.
    (should (eq (lookup-key m (kbd "RET")) 'cmacs-gsurf-lite-follow))
    (should (eq (lookup-key m (kbd "TAB")) 'cmacs-gsurf-lite-next-field))))

(ert-deftest cmacs-gsurf-lite-self-insert-edits-value ()
  "Typing into a text field updates the buffer and the recomputed value,
without point escaping the editable box."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "text") (name . "user")
                          (data-cmlite-id . "cml3")))))
    (goto-char (cmacs-gsurf-lite-tests--first-field))
    ;; No web process under ERT: skip the debounced live-DOM push.
    (cl-letf (((symbol-function 'cmacs-gsurf-lite--schedule-flush) #'ignore))
      (dolist (ch '(?a ?b ?c))
        (let ((last-command-event ch))
          (cmacs-gsurf-lite--self-insert 1))))
    (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
      (should bounds)
      (should (equal (cmacs-gsurf-lite--field-value
                      (car bounds) (cdr bounds) "text")
                     "abc")))))

(ert-deftest cmacs-gsurf-lite-password-inline-masked ()
  "Inline-typed password chars display as bullets but the value is real."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "password") (name . "pass")
                          (data-cmlite-id . "cml4")))))
    (let ((pos (cmacs-gsurf-lite-tests--first-field)))
      (goto-char pos)
      (cl-letf (((symbol-function 'cmacs-gsurf-lite--schedule-flush) #'ignore))
        (dolist (ch '(?s ?e ?c))
          (let ((last-command-event ch))
            (cmacs-gsurf-lite--self-insert 1))))
      ;; Visible text is masked...
      (should (get-text-property pos 'display))
      ;; ...but the logical value recovers the plaintext.
      (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
        (should (equal (cmacs-gsurf-lite--field-value
                        (car bounds) (cdr bounds) "password")
                       "sec"))))))

(ert-deftest cmacs-gsurf-lite-delete-backward-shrinks-value ()
  "DEL inside a field removes the preceding character from the value."
  (with-temp-buffer
    (let ((shr-width 80))
      (cmacs-gsurf-lite--tag-input
       (dom-node 'input '((type . "text") (name . "user")
                          (data-cmlite-id . "cml3")))))
    (goto-char (cmacs-gsurf-lite-tests--first-field))
    (cl-letf (((symbol-function 'cmacs-gsurf-lite--schedule-flush) #'ignore))
      (dolist (ch '(?h ?i))
        (let ((last-command-event ch)) (cmacs-gsurf-lite--self-insert 1)))
      (cmacs-gsurf-lite--delete-backward 1))
    (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
      (should (equal (cmacs-gsurf-lite--field-value
                      (car bounds) (cdr bounds) "text")
                     "h")))))

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

(ert-deftest cmacs-gsurf-lite-action-watch-times-defcustom ()
  "The post-click watch schedule is defined and spans more than one tick."
  (should (boundp 'cmacs-gsurf-lite-action-watch-times))
  (should (consp cmacs-gsurf-lite-action-watch-times))
  (should (> (length cmacs-gsurf-lite-action-watch-times) 1)))

(ert-deftest cmacs-gsurf-lite-click-schedules-multiple-reextracts ()
  "A JS click/submit schedules a re-extract at every action-watch time, so a
delayed or client-side (SPA/pushState) redirect re-renders even when the
navigation fires no load event.  Guards the regression where a login that
redirected behind the scenes left the lite buffer showing the old page."
  (let ((scheduled '()))
    (cl-letf (((symbol-function 'cmacs-gsurf-run-javascript-async)
               (lambda (_buf _js cb) (funcall cb "ok")))
              ((symbol-function 'run-at-time)
               (lambda (delay _repeat _fn &rest _args)
                 (push delay scheduled) nil)))
      (with-temp-buffer
        (cmacs-gsurf-lite--run-js-then-reextract (current-buffer) "x();")))
    (setq scheduled (nreverse scheduled))
    ;; The click schedules exactly one re-extract per action-watch time
    ;; (ignoring any unrelated Emacs-internal timers also seen by the stub).
    (should (equal (last scheduled (length cmacs-gsurf-lite-action-watch-times))
                   cmacs-gsurf-lite-action-watch-times))))

(provide 'cmacs-gsurf-lite-tests)
;;; cmacs-gsurf-lite-tests.el ends here
