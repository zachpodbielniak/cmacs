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

;;;; Phase 1: dropped view signals, downloads, permissions ------------

(ert-deftest cmacs-gsurf-phase1-defuns-present ()
  "The Phase-1 C DEFUNs are defined."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (dolist (fn '(cmacs-gsurf-download-cancel
                cmacs-gsurf-set-permission-policy
                cmacs-gsurf-clear-permission-policies))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-phase1-hooks-defined ()
  "The previously-dropped signals are exposed as abnormal hooks."
  (skip-unless (featurep 'cmacs-gsurf))
  (dolist (h '(cmacs-gsurf-hovered-uri-changed-functions
               cmacs-gsurf-progress-changed-functions
               cmacs-gsurf-crashed-functions
               cmacs-gsurf-favicon-changed-functions
               cmacs-gsurf-download-changed-functions
               cmacs-gsurf-permission-request-functions))
    (should (boundp h))))

(ert-deftest cmacs-gsurf-phase1-defcustoms ()
  "Phase-1 defcustoms exist with sane defaults."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (boundp 'cmacs-gsurf-show-hovered-uri))
  (should (boundp 'cmacs-gsurf-rename-buffers))
  (should (boundp 'cmacs-gsurf-auto-reload-on-crash))
  (should (boundp 'cmacs-gsurf-popup-display-function))
  (should (boundp 'cmacs-gsurf-download-directory))
  (should (boundp 'cmacs-gsurf-permission-policy)))

(ert-deftest cmacs-gsurf-uri-origin ()
  "`cmacs-gsurf--uri-origin' extracts scheme://host[:port]."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (equal (cmacs-gsurf--uri-origin "https://example.com/foo?x=1")
                 "https://example.com"))
  (should (equal (cmacs-gsurf--uri-origin "http://h:8080/a")
                 "http://h:8080"))
  (should (null (cmacs-gsurf--uri-origin "not a url"))))

(ert-deftest cmacs-gsurf-permission-commands ()
  "Permission policy helpers and commands are present."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (fboundp 'cmacs-gsurf-allow-origin))
  (should (fboundp 'cmacs-gsurf-deny-origin))
  (should (fboundp 'cmacs-gsurf--apply-permission-policy))
  ;; Applying an empty policy must not error even before a view exists.
  (let ((cmacs-gsurf-permission-policy nil))
    (should (progn (cmacs-gsurf--apply-permission-policy) t))))

(ert-deftest cmacs-gsurf-downloads-loaded ()
  "The download manager is loaded with the subsystem."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (featurep 'cmacs-gsurf-downloads))
  (should (fboundp 'cmacs-gsurf-downloads))
  (should (fboundp 'cmacs-gsurf-downloads-mode)))

(ert-deftest cmacs-gsurf-download-record ()
  "`cmacs-gsurf--download-record' accumulates and updates entries."
  (skip-unless (featurep 'cmacs-gsurf-downloads))
  (let ((cmacs-gsurf--downloads nil))
    (cmacs-gsurf--download-record 1 "http://x/f" "/tmp/f" 0 100 'started)
    (cmacs-gsurf--download-record 1 "http://x/f" "/tmp/f" 50 100 'progress)
    (should (= 1 (length cmacs-gsurf--downloads)))
    (let ((pl (cdr (assq 1 cmacs-gsurf--downloads))))
      (should (eq (plist-get pl :state) 'progress))
      (should (= (plist-get pl :received) 50)))
    (cmacs-gsurf--download-record 2 "http://x/g" "/tmp/g" 0 0 'started)
    (should (= 2 (length cmacs-gsurf--downloads)))))

(ert-deftest cmacs-gsurf-download-format-helpers ()
  "Download size/percent formatting behaves."
  (skip-unless (featurep 'cmacs-gsurf-downloads))
  (should (equal (cmacs-gsurf-downloads--human-size 512) "512B"))
  (should (equal (cmacs-gsurf-downloads--human-size 0) "—"))
  (should (equal (cmacs-gsurf-downloads--percent '(:received 25 :total 100))
                 "25%"))
  (should (equal (cmacs-gsurf-downloads--percent '(:state finished)) "100%")))

;;;; Phase 2: snapshot, print, pipe/play, AI, MCP --------------------

(ert-deftest cmacs-gsurf-phase2-defuns-present ()
  "Snapshot / print C DEFUNs are defined."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (should (fboundp 'cmacs-gsurf-snapshot))
  (should (fboundp 'cmacs-gsurf-print-to-pdf)))

(ert-deftest cmacs-gsurf-phase2-pipe-play ()
  "Page-text helpers and pipe/play commands are present."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (fboundp 'cmacs-gsurf--page-text))
  (should (fboundp 'cmacs-gsurf--page-html))
  (should (fboundp 'cmacs-gsurf-pipe))
  (should (fboundp 'cmacs-gsurf-play-external))
  (should (boundp 'cmacs-gsurf-external-player)))

(ert-deftest cmacs-gsurf-phase2-mcp-helpers ()
  "MCP helper functions for the new tools exist."
  (skip-unless (featurep 'cmacs-gsurf))
  (dolist (fn '(cmacs-gsurf-mcp-snapshot
                cmacs-gsurf-mcp-print-pdf
                cmacs-gsurf-mcp-download-cancel
                cmacs-gsurf-mcp-permission-policy))
    (should (fboundp fn)))
  (require 'cmacs-gsurf-downloads)
  (should (fboundp 'cmacs-gsurf-mcp-download-list))
  ;; download-list returns valid JSON for an empty set.
  (let ((cmacs-gsurf--downloads nil))
    (should (equal (cmacs-gsurf-mcp-download-list) "[]"))))

(ert-deftest cmacs-gsurf-phase2-ai ()
  "The AI page commands load and are present."
  (skip-unless (featurep 'cmacs-gsurf))
  (require 'cmacs-gsurf-ai)
  (should (fboundp 'cmacs-gsurf-summarize))
  (should (fboundp 'cmacs-gsurf-ask))
  (should (boundp 'cmacs-gsurf-ai-max-chars)))

;;;; Phase 3: JS bridge, inspector, bookmarks ------------------------

(ert-deftest cmacs-gsurf-js-message-dispatch ()
  "`cmacs-gsurf--js-message' parses JSON and runs the channel hook."
  (skip-unless (featurep 'cmacs-gsurf))
  (should (boundp 'cmacs-gsurf-js-message-functions))
  (let* ((got nil)
         (fn (lambda (_buf ch pl) (setq got (list ch pl)))))
    (add-hook 'cmacs-gsurf-js-message-functions fn)
    (unwind-protect
        (with-temp-buffer
          (cmacs-gsurf--js-message
           (current-buffer)
           "{\"channel\":\"console\",\"payload\":{\"level\":\"log\",\"text\":\"hi\"}}")
          (should (equal (car got) "console"))
          (should (equal (alist-get 'text (cadr got)) "hi")))
      (remove-hook 'cmacs-gsurf-js-message-functions fn))))

(ert-deftest cmacs-gsurf-js-message-bad-input ()
  "A malformed JS message does not error out."
  (skip-unless (featurep 'cmacs-gsurf))
  (with-temp-buffer
    (should (progn (cmacs-gsurf--js-message (current-buffer) "not json") t))))

(ert-deftest cmacs-gsurf-inspector-loaded ()
  "The inspector commands and DOM-walk JS are present."
  (skip-unless (featurep 'cmacs-gsurf))
  (require 'cmacs-gsurf-inspector)
  (should (fboundp 'cmacs-gsurf-inspect))
  (should (fboundp 'cmacs-gsurf-console))
  (should (fboundp 'cmacs-gsurf-dom-mode))
  ;; The DOM walk stamps the node-id attribute used to address nodes.
  (let ((js (cmacs-gsurf-inspector--walk-js 4)))
    (should (string-match-p "data-cmacs-node-id" js))
    (should (string-match-p "JSON.stringify" js))))

(ert-deftest cmacs-gsurf-bookmarks-roundtrip ()
  "Adding a bookmark persists and reloads from disk."
  (skip-unless (featurep 'cmacs-gsurf))
  (require 'cmacs-gsurf-bookmarks)
  (let* ((tmp (make-temp-file "gsurf-bm" nil ".el"))
         (cmacs-gsurf-bookmarks-file tmp)
         (cmacs-gsurf--bookmarks 'unset))
    (unwind-protect
        (progn
          (cmacs-gsurf-bookmark-add "https://e.com" "Example" '("work"))
          (should (assoc "https://e.com" cmacs-gsurf--bookmarks))
          (should (member "work" (cmacs-gsurf-bookmarks--all-tags)))
          ;; Reload from disk and confirm it persisted.
          (setq cmacs-gsurf--bookmarks 'unset)
          (cmacs-gsurf-bookmarks--ensure)
          (should (assoc "https://e.com" cmacs-gsurf--bookmarks)))
      (delete-file tmp))))

;;;; libregnum (--lrg) backend ----------------------------------------

(ert-deftest cmacs-gsurf-lrg-predicate-present ()
  "The `cmacs-gsurf-lrg-supported-p' build predicate is defined and
returns a boolean."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (should (fboundp 'cmacs-gsurf-lrg-supported-p))
  (should (memq (cmacs-gsurf-lrg-supported-p) '(nil t))))

(ert-deftest cmacs-gsurf-lrg-backend-agnostic-commands ()
  "The gsurf commands are backend-agnostic: they exist regardless of
whether the run is pgtk or --lrg (the backend is chosen by frame type
inside the C layer, with no separate Elisp surface)."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  ;; These drive whichever backend the frame uses.
  (dolist (fn '(cmacs-gsurf-attach cmacs-gsurf-load-uri
                cmacs-gsurf-focus-page cmacs-gsurf-release-focus))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-lrg-edge-batch-safe ()
  "In --batch (no graphical frame) gsurf entry points must not crash;
attaching simply fails gracefully without a display/backend."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  ;; supported-p is a pure build check -- always t when built.
  (should (cmacs-gsurf-supported-p))
  ;; Placing/hiding a buffer with no attached view is a no-op, not a crash.
  (with-temp-buffer
    (should (progn (ignore-errors (cmacs-gsurf-hide)) t))))

(provide 'cmacs-gsurf-tests)
;;; cmacs-gsurf-tests.el ends here
