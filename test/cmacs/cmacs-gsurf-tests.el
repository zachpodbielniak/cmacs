;;; cmacs-gsurf-tests.el --- ERT tests for cmacs-gsurf  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Batch-safe smoke tests for the gsurf subsystem.  The live web view
;; needs a display + a WebKit process, so the interactive browser path
;; is not exercised here; these tests confirm the subsystem is built,
;; its DEFUNs and Elisp surface are present, and (when GI is available)
;; the Gsurf typelib resolves.

;;; Code:

(require 'ert)
(require 'cmacs-gsurf nil t)

(ert-deftest cmacs-gsurf-built-in ()
  "cmacs-gsurf is compiled into this cmacs."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (should (cmacs-gsurf-supported-p)))

(ert-deftest cmacs-gsurf-defuns-present ()
  "The core gsurf DEFUNs are defined."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (dolist (fn '(cmacs-gsurf-attach
                cmacs-gsurf-detach
                cmacs-gsurf-attached-p
                cmacs-gsurf-place
                cmacs-gsurf-hide
                cmacs-gsurf-load-uri
                cmacs-gsurf-reload
                cmacs-gsurf-back
                cmacs-gsurf-forward
                cmacs-gsurf-get-uri
                cmacs-gsurf-get-title
                cmacs-gsurf-set-zoom
                cmacs-gsurf-run-javascript
                cmacs-gsurf-modules-list))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-elisp-surface ()
  "The Elisp layer (mode + entry points + MCP helpers) is loaded."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (fboundp 'cmacs-gsurf))
  (should (fboundp 'cmacs-gsurf-mode))
  (should (fboundp 'cmacs-gsurf-browse-url))
  (should (fboundp 'cmacs-gsurf-mcp-open)))

(ert-deftest cmacs-gsurf-url-normalization ()
  "URL heuristics pass URLs through and search bare words."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (equal (cmacs-gsurf--normalize-url "https://gnu.org")
                 "https://gnu.org"))
  (should (equal (cmacs-gsurf--normalize-url "example.com")
                 "https://example.com"))
  (should (string-prefix-p "https://duckduckgo.com/"
                           (cmacs-gsurf--normalize-url "hello world"))))

(ert-deftest cmacs-gsurf-gi-typelib ()
  "The bundled Gsurf-0.1 typelib resolves via GObject Introspection."
  (skip-unless (and (fboundp 'cmacs-gsurf-supported-p)
                    (fboundp 'gi-require)))
  (should (gi-require "Gsurf" "0.1")))

(ert-deftest cmacs-gsurf-config-synthesis ()
  "`cmacs-gsurf-modules' is synthesised into a gsurf modules: YAML doc."
  (skip-unless (featurep 'cmacs-gsurf))
  ;; nil -> empty (so nothing is loaded by default-unset)
  (let ((cmacs-gsurf-modules nil))
    (should (equal (cmacs-gsurf--config-to-yaml) "")))
  ;; enabled flag + an option, with proper YAML scalars
  (let ((cmacs-gsurf-modules
         '(("modal" :enabled t :scroll_step 120 :hint_chars "asdfjkl")
           ("tabs"  :enabled nil))))
    (let ((y (cmacs-gsurf--config-to-yaml)))
      (should (string-prefix-p "modules:\n" y))
      (should (string-match-p "^  modal:$" y))
      (should (string-match-p "^    enabled: true$" y))
      (should (string-match-p "^    scroll_step: 120$" y))
      (should (string-match-p "^    hint_chars: \"asdfjkl\"$" y))
      (should (string-match-p "^  tabs:$" y))
      (should (string-match-p "^    enabled: false$" y)))))

(ert-deftest cmacs-gsurf-config-defuns-present ()
  "The Emacs-driven config DEFUNs + commands exist."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (dolist (fn '(cmacs-gsurf-load-config-data
                cmacs-gsurf-load-config-file
                cmacs-gsurf-load-config-c-file
                cmacs-gsurf-reconfigure-modules))
    (should (fboundp fn)))
  (should (commandp 'cmacs-gsurf-reload-config))
  ;; By default we do NOT read gsurf's own user config files.
  (should-not (and (boundp 'cmacs-gsurf-load-user-config)
                   cmacs-gsurf-load-user-config)))

(ert-deftest cmacs-gsurf-config-data-roundtrip ()
  "`cmacs-gsurf-load-config-data' parses valid YAML and rejects bad."
  (skip-unless (fboundp 'cmacs-gsurf-load-config-data))
  ;; config_ensure is display-free, so this works in batch.
  (should (eq t (cmacs-gsurf-load-config-data
                 "modules:\n  modal:\n    enabled: true\n")))
  (should-error (cmacs-gsurf-load-config-data ":\n  : : :bad")
                :type 'cmacs-gsurf-error))

;;;; Caret mode + result channel + offscreen --------------------------

(ert-deftest cmacs-gsurf-caret-primitives-present ()
  "Result-return, user-script and offscreen DEFUNs should be present."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (should (fboundp 'cmacs-gsurf-run-javascript-async))
  (should (fboundp 'cmacs-gsurf-add-user-script))
  (should (fboundp 'cmacs-gsurf-offscreen-p))
  ;; `cmacs-gsurf-attach' must accept the optional OFFSCREEN argument.
  (should (>= (cdr (func-arity 'cmacs-gsurf-attach)) 2)))

(ert-deftest cmacs-gsurf-caret-mode-defined ()
  "The caret minor mode + its defcustoms should exist."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (fboundp 'cmacs-gsurf-caret-mode))
  (should (boundp 'cmacs-gsurf-caret-mode-default))
  (should (boundp 'cmacs-gsurf-caret-color)))

(ert-deftest cmacs-gsurf-caret-motion-commands ()
  "All caret motion / action commands should be defined."
  (skip-unless (featurep 'cmacs-gsurf))
  (dolist (cmd '(cmacs-gsurf-caret-left cmacs-gsurf-caret-right
                 cmacs-gsurf-caret-up cmacs-gsurf-caret-down
                 cmacs-gsurf-caret-word-forward cmacs-gsurf-caret-word-backward
                 cmacs-gsurf-caret-word-end
                 cmacs-gsurf-caret-line-start cmacs-gsurf-caret-line-end
                 cmacs-gsurf-caret-top cmacs-gsurf-caret-bottom
                 cmacs-gsurf-caret-start-highlight cmacs-gsurf-caret-copy
                 cmacs-gsurf-caret-activate))
    (should (commandp cmd))))

(ert-deftest cmacs-gsurf-caret-search-commands ()
  "Caret search (/ n N) and vim line-scroll (C-e/C-y) commands exist."
  (skip-unless (featurep 'cmacs-gsurf))
  (dolist (cmd '(cmacs-gsurf-caret-search cmacs-gsurf-caret-search-next
                 cmacs-gsurf-caret-search-prev
                 cmacs-gsurf-scroll-line-down cmacs-gsurf-scroll-line-up))
    (should (commandp cmd))))

(ert-deftest cmacs-gsurf-caret-keymaps ()
  "Caret map shadows hjkl + binds / n N; base map binds C-e/C-y; SPC free."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (eq (lookup-key cmacs-gsurf-caret-mode-map (kbd "j"))
              'cmacs-gsurf-caret-down))
  (should (eq (lookup-key cmacs-gsurf-caret-mode-map (kbd "/"))
              'cmacs-gsurf-caret-search))
  (should (eq (lookup-key cmacs-gsurf-caret-mode-map (kbd "n"))
              'cmacs-gsurf-caret-search-next))
  (should (eq (lookup-key cmacs-gsurf-caret-mode-map (kbd "N"))
              'cmacs-gsurf-caret-search-prev))
  (should (eq (lookup-key cmacs-gsurf-mode-map (kbd "C-e"))
              'cmacs-gsurf-scroll-line-down))
  (should (eq (lookup-key cmacs-gsurf-mode-map (kbd "C-y"))
              'cmacs-gsurf-scroll-line-up))
  ;; SPC stays free for the leader; C-e/C-y are NOT in the caret map.
  (should-not (lookup-key cmacs-gsurf-caret-mode-map (kbd "SPC")))
  (should-not (lookup-key cmacs-gsurf-caret-mode-map (kbd "C-e"))))

(ert-deftest cmacs-gsurf-caret-engine-shape ()
  "The injected caret engine references the key DOM APIs incl. search."
  (skip-unless (featurep 'cmacs-gsurf))
  (let ((js cmacs-gsurf--caret-engine-js))
    (should (string-match-p "__cmacsCaret" js))
    (should (string-match-p "getSelection" js))
    (should (string-match-p "modify" js))
    (should (string-match-p "C.search" js))
    (should (string-match-p "window.find" js))))

(ert-deftest cmacs-gsurf-caret-color-wiring ()
  "The caret colour defcustom is hot pink, the engine reads it from
`window.__cmacsCaretColor', and draws a glow + white halo so it stands
out.  The boot JS carries the configured colour."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (equal cmacs-gsurf-caret-color "#ff69b4"))
  (let ((js cmacs-gsurf--caret-engine-js))
    ;; The wiring bug fix: the engine must SET C.caretColor from the
    ;; injected window.__cmacsCaretColor (it was previously undefined).
    (should (string-match-p "C.caretColor = window.__cmacsCaretColor" js))
    (should (string-match-p "width:3px" js))
    (should (string-match-p "box-shadow" js)))
  ;; The boot wrapper substitutes the configured colour.
  (let ((cmacs-gsurf-caret-color "#123456"))
    (should (string-match-p "#123456" (cmacs-gsurf--caret-boot-js)))))

(ert-deftest cmacs-gsurf-js-string-escaping ()
  "`cmacs-gsurf--js-string' produces a safe JS string literal."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (equal (cmacs-gsurf--js-string "ab") "\"ab\""))
  (should (equal (cmacs-gsurf--js-string "a\"b") "\"a\\\"b\""))
  (should (equal (cmacs-gsurf--js-string "a\\b") "\"a\\\\b\""))
  (should (equal (cmacs-gsurf--js-string "a\nb") "\"a\\nb\"")))

(provide 'cmacs-gsurf-tests)
;;; cmacs-gsurf-tests.el ends here
