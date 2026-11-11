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
  "The bundled Gsurf-0.5 typelib resolves via GObject Introspection."
  (skip-unless (and (fboundp 'cmacs-gsurf-supported-p)
                    (fboundp 'gi-require)))
  (should (gi-require "Gsurf" "0.5")))

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

;;;; gsurf 0.5 control surface (cmacs-gsurf-control.{c,el}) ----------

(ert-deftest cmacs-gsurf-control-defuns-present ()
  "The toolkit-neutral control DEFUNs are defined."
  (skip-unless (fboundp 'cmacs-gsurf-supported-p))
  (dolist (fn '(cmacs-gsurf-keyval cmacs-gsurf-modifier-mask
                cmacs-gsurf-send-key cmacs-gsurf-click cmacs-gsurf-type
                cmacs-gsurf-locate-script cmacs-gsurf-click-element
                cmacs-gsurf-add-cookie cmacs-gsurf-set-cookie-policy
                cmacs-gsurf-set-proxy cmacs-gsurf-containers
                cmacs-gsurf-containers-enabled-p cmacs-gsurf-container-define
                cmacs-gsurf-container-new-temporary
                cmacs-gsurf-container-set-network
                cmacs-gsurf-attach-in-container cmacs-gsurf-container-id
                cmacs-gsurf-view-id cmacs-gsurf-opener-id
                cmacs-gsurf-buffer-for-view-id cmacs-gsurf-actions
                cmacs-gsurf-dispatch-action cmacs-gsurf-input-modes
                cmacs-gsurf-input-mode cmacs-gsurf-set-input-mode
                cmacs-gsurf-editing-p cmacs-gsurf-typing-p
                cmacs-gsurf-blur-editable cmacs-gsurf-keybinds))
    (should (fboundp fn))))

(ert-deftest cmacs-gsurf-control-keyval ()
  "Key names resolve the way gsurf_view_keyval_from_name does."
  (skip-unless (fboundp 'cmacs-gsurf-keyval))
  (should (eql (cmacs-gsurf-keyval "Enter") #xff0d))
  (should (eql (cmacs-gsurf-keyval "Return") #xff0d))
  (should (eql (cmacs-gsurf-keyval "tab") #xff09))
  (should (eql (cmacs-gsurf-keyval 'Escape) #xff1b))
  (should (eql (cmacs-gsurf-keyval "a") ?a))
  (should-not (cmacs-gsurf-keyval "NoSuchKeyName"))
  (should-not (cmacs-gsurf-keyval nil)))

(ert-deftest cmacs-gsurf-control-modifier-mask ()
  "Modifier lists fold into GsurfKeyMod flags; unknown ones signal."
  (skip-unless (fboundp 'cmacs-gsurf-modifier-mask))
  (should (eql (cmacs-gsurf-modifier-mask nil) 0))
  (should (eql (cmacs-gsurf-modifier-mask '(shift)) 1))
  (should (eql (cmacs-gsurf-modifier-mask '(control shift)) 3))
  (should (eql (cmacs-gsurf-modifier-mask '("ctrl" meta)) 6))
  (should (eql (cmacs-gsurf-modifier-mask 'super) 8))
  (should-error (cmacs-gsurf-modifier-mask '(hyper)) :type 'cmacs-gsurf-error))

(ert-deftest cmacs-gsurf-control-arg-validation ()
  "Control DEFUNs reject a non-buffer and a buffer with no view."
  (skip-unless (fboundp 'cmacs-gsurf-send-key))
  (should-error (cmacs-gsurf-send-key 42 "Enter") :type 'wrong-type-argument)
  (with-temp-buffer
    (let ((b (current-buffer)))
      (should-error (cmacs-gsurf-send-key b "Enter") :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-click b 10 10) :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-type b "x") :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-click-element b "a") :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-add-cookie b '(:name "n" :value "v"
                                               :domain "example.com"))
                    :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-view-id b) :type 'cmacs-gsurf-error)
      (should-error (cmacs-gsurf-dispatch-action b "reload")
                    :type 'cmacs-gsurf-error)))
  (should-not (cmacs-gsurf-buffer-for-view-id 987654321))
  (should-not (cmacs-gsurf-buffer-for-view-id "not-an-id")))

(ert-deftest cmacs-gsurf-control-locate-and-parse ()
  "The locate script is gsurf's, and its [x, y] result parses."
  (skip-unless (fboundp 'cmacs-gsurf-locate-script))
  (let ((js (cmacs-gsurf-locate-script "#q")))
    (should (stringp js))
    (should (string-match-p "querySelector" js))
    (should (string-match-p "getBoundingClientRect" js)))
  (should (equal (cmacs-gsurf--parse-point "[12,30]") '(12.0 . 30.0)))
  (should (equal (cmacs-gsurf--parse-point " [ 1.5 , -2 ] ") '(1.5 . -2.0)))
  (should-not (cmacs-gsurf--parse-point "null"))
  (should-not (cmacs-gsurf--parse-point "[1]"))
  (should-not (cmacs-gsurf--parse-point "[1,2,3]"))
  (should-not (cmacs-gsurf--parse-point "")))

(ert-deftest cmacs-gsurf-control-actions-shape ()
  "`cmacs-gsurf-actions' is an alist of (NAME . DESCRIPTION) strings."
  (skip-unless (fboundp 'cmacs-gsurf-actions))
  (let ((acts (cmacs-gsurf-actions)))
    (should (> (length acts) 40))
    (dolist (a acts)
      (should (stringp (car a)))
      (should (stringp (cdr a))))
    (should-not (assoc "none" acts))
    (dolist (n '("reload" "back" "dark-mode-toggle" "dark-mode-toggle-site"
                 "form-autofill" "container-new-temp"))
      (should (assoc n acts)))))

(ert-deftest cmacs-gsurf-control-core-action-map ()
  "Every core action cmacs maps is a real gsurf action and a command."
  (skip-unless (and (fboundp 'cmacs-gsurf-actions)
                    (boundp 'cmacs-gsurf--core-action-commands)))
  (let ((acts (cmacs-gsurf-actions)))
    (dolist (entry cmacs-gsurf--core-action-commands)
      (should (assoc (car entry) acts))
      (should (commandp (cdr entry))))))

(ert-deftest cmacs-gsurf-control-input-modes ()
  "Input modes are the five GsurfModePolicy labels, lower-cased."
  (skip-unless (fboundp 'cmacs-gsurf-input-modes))
  (should (equal (cmacs-gsurf-input-modes)
                 '(normal insert follow find passthrough)))
  (should (memq (cmacs-gsurf-input-mode) (cmacs-gsurf-input-modes))))

(ert-deftest cmacs-gsurf-control-containers-display-free ()
  "The container registry answers in batch; a bad id is refused."
  (skip-unless (fboundp 'cmacs-gsurf-containers))
  (should (listp (cmacs-gsurf-containers)))
  (should (memq (cmacs-gsurf-containers-enabled-p) '(nil t)))
  (should-error (cmacs-gsurf-container-define "bad id!")
                :type 'cmacs-gsurf-error)
  (should-error (cmacs-gsurf-container-define "temporary")
                :type 'cmacs-gsurf-error))

(ert-deftest cmacs-gsurf-control-keybinds-shape ()
  "Keybinding help rows are plists with the documented keys."
  (skip-unless (fboundp 'cmacs-gsurf-keybinds))
  (let ((rows (cmacs-gsurf-keybinds)))
    (should (listp rows))
    (dolist (r rows)
      (should (plist-member r :key))
      (should (plist-member r :source))
      (should (plist-member r :description)))))

(ert-deftest cmacs-gsurf-control-elisp-surface ()
  "Commands, hooks and key bindings of cmacs-gsurf-control.el exist."
  (skip-unless (featurep 'cmacs-gsurf-control))
  (dolist (cmd '(cmacs-gsurf-press-key cmacs-gsurf-type-text
                 cmacs-gsurf-click-at cmacs-gsurf-click-selector
                 cmacs-gsurf-focus-first-input cmacs-gsurf-cookie-add
                 cmacs-gsurf-proxy cmacs-gsurf-open-in-container
                 cmacs-gsurf-open-in-temporary-container
                 cmacs-gsurf-reopen-in-container cmacs-gsurf-tree
                 cmacs-gsurf-run-action cmacs-gsurf-dark-mode-toggle
                 cmacs-gsurf-dark-mode-toggle-site cmacs-gsurf-form-autofill
                 cmacs-gsurf-keybinds-help))
    (should (commandp cmd)))
  (should (boundp 'cmacs-gsurf-input-mode-changed-functions))
  (should (boundp 'cmacs-gsurf-editing-changed-functions))
  (should (eq (lookup-key cmacs-gsurf-mode-map "?") #'cmacs-gsurf-keybinds-help))
  (should (eq (lookup-key cmacs-gsurf-mode-map "T") #'cmacs-gsurf-tree))
  (should (eq (lookup-key cmacs-gsurf-mode-map (kbd "C-c C-x"))
              #'cmacs-gsurf-run-action))
  (should (eq (lookup-key cmacs-gsurf-mode-map (kbd "C-M-d"))
              #'cmacs-gsurf-dark-mode-toggle))
  ;; The C bridges call these by name.
  (should (fboundp 'cmacs-gsurf--open-child))
  (should (>= (cdr (func-arity 'cmacs-gsurf--open-popup)) 2)))

(ert-deftest cmacs-gsurf-control-tree-order ()
  "Buffers are ordered depth-first under their openers."
  (skip-unless (fboundp 'cmacs-gsurf--tree-order))
  (should (equal (cmacs-gsurf--tree-order
                  '((a 1 nil) (b 2 1) (c 3 2) (d 4 1) (e 5 99)))
                 '((a . 0) (b . 1) (c . 2) (d . 1) (e . 0))))
  ;; A cycle (impossible in gsurf) is still listed, once each.
  (should (equal (length (cmacs-gsurf--tree-order '((x 1 2) (y 2 1)))) 2))
  (should-not (cmacs-gsurf--tree-order nil)))

(ert-deftest cmacs-gsurf-control-event-to-key ()
  "Emacs events translate to gsurf key names and modifiers."
  (skip-unless (fboundp 'cmacs-gsurf--event-to-key))
  (should (equal (cmacs-gsurf--event-to-key ?a) '("a")))
  (should (equal (cmacs-gsurf--event-to-key ?A) '("A")))
  (should (equal (cmacs-gsurf--event-to-key ?\C-a) '("a" control)))
  (should (equal (cmacs-gsurf--event-to-key 'M-return) '("Return" meta)))
  (should (equal (cmacs-gsurf--event-to-key 'f5) '("F5")))
  (should (equal (cmacs-gsurf--event-to-key ?\s) '("space")))
  (should (equal (cmacs-gsurf--event-to-key 'prior) '("Page_Up"))))

(ert-deftest cmacs-gsurf-control-modifier-strings ()
  "MCP/D-Bus modifier strings parse into modifier symbols."
  (skip-unless (fboundp 'cmacs-gsurf--modifiers-from-string))
  (should-not (cmacs-gsurf--modifiers-from-string nil))
  (should-not (cmacs-gsurf--modifiers-from-string ""))
  (should (equal (cmacs-gsurf--modifiers-from-string "ctrl+shift")
                 '(control shift)))
  (should (equal (cmacs-gsurf--modifiers-from-string "C-M-s")
                 '(control meta super)))
  (should (equal (cmacs-gsurf--modifiers-from-string "S") '(shift))))

(ert-deftest cmacs-gsurf-control-mode-line-text ()
  "The input-mode indicator shows only while the page has the keys."
  (skip-unless (fboundp 'cmacs-gsurf--input-mode-text))
  (should (equal (cmacs-gsurf--input-mode-text 'normal nil nil) ""))
  (should (equal (cmacs-gsurf--input-mode-text 'insert t nil) ""))
  (should (equal (cmacs-gsurf--input-mode-text 'normal nil t) "-- NORMAL --  "))
  (should (equal (cmacs-gsurf--input-mode-text 'normal t t) "-- INSERT --  "))
  (should (equal (cmacs-gsurf--input-mode-text 'follow t t) "-- FOLLOW --  "))
  ;; In a buffer with no view the mode-line snippet is empty.
  (with-temp-buffer
    (should (equal (cmacs-gsurf--mode-line-input-mode) ""))))

(ert-deftest cmacs-gsurf-control-module-knobs-yaml ()
  "Module knobs merge into `cmacs-gsurf-modules' and render as YAML."
  (skip-unless (fboundp 'cmacs-gsurf--effective-modules))
  ;; All knobs at default: modules pass through untouched.
  (let ((cmacs-gsurf-modules '(("modal" :enabled t))))
    (should (equal (cmacs-gsurf--effective-modules) '(("modal" :enabled t)))))
  (let ((cmacs-gsurf-modules '(("modal" :enabled t)
                               ("dark_mode" :enabled nil :brightness 90)))
        (cmacs-gsurf-dark-mode t)
        (cmacs-gsurf-dark-mode-style 'native)
        (cmacs-gsurf-dark-mode-sites '((:match "github" :mode native)))
        (cmacs-gsurf-adblock t)
        (cmacs-gsurf-adblock-filter-lists
         '("~/a.txt" (:path "~/b.txt" :trusted t)))
        (cmacs-gsurf-hardening 'off)
        (cmacs-gsurf-languages '("en-US" "de")))
    (let ((mods (cmacs-gsurf--effective-modules)))
      ;; knob overrides the explicit entry's :enabled, keeps its options
      (should (equal (plist-get (cdr (assoc "dark_mode" mods)) :enabled) t))
      (should (equal (plist-get (cdr (assoc "dark_mode" mods)) :brightness) 90))
      (should (eq (plist-get (cdr (assoc "hardening" mods)) :enabled) nil))
      ;; the defcustom value itself is not mutated
      (should (equal (cdr (assoc "dark_mode" cmacs-gsurf-modules))
                     '(:enabled nil :brightness 90))))
    (let ((y (cmacs-gsurf--config-to-yaml)))
      (should (string-match-p "^browser:\n  languages: \\[\"en-US\", \"de\"\\]$" y))
      (should (string-match-p "^    mode: \"native\"$" y))
      (should (string-match-p "^    sites: \\[{match: \"github\", mode: \"native\"}\\]$" y))
      (should (string-match-p
               "^    filter_lists: \\[\"~/a.txt\", {path: \"~/b.txt\", trusted: true}\\]$"
               y))
      (should (string-match-p "^  hardening:\n    enabled: false$" y)))))

(ert-deftest cmacs-gsurf-control-yaml-values ()
  "YAML rendering of lists, vectors and plists."
  (skip-unless (fboundp 'cmacs-gsurf--yaml-scalar))
  (should (equal (cmacs-gsurf--yaml-scalar []) "[]"))
  (should (equal (cmacs-gsurf--yaml-scalar '("a" 1 t)) "[\"a\", 1, true]"))
  (should (equal (cmacs-gsurf--yaml-scalar '(:k "v" :n 2)) "{k: \"v\", n: 2}"))
  (should (equal (cmacs-gsurf--yaml-scalar 'filter) "\"filter\"")))

(ert-deftest cmacs-gsurf-control-mcp-helpers ()
  "MCP/D-Bus helpers exist and the list helpers return JSON arrays."
  (skip-unless (featurep 'cmacs-gsurf-control))
  (dolist (fn '(cmacs-gsurf-mcp-click cmacs-gsurf-mcp-type-text
                cmacs-gsurf-mcp-press-key cmacs-gsurf-mcp-click-element
                cmacs-gsurf-mcp-set-cookie cmacs-gsurf-mcp-toggle-module
                cmacs-gsurf-mcp-run-action cmacs-gsurf-mcp-list-actions
                cmacs-gsurf-mcp-list-containers))
    (should (fboundp fn)))
  (when (fboundp 'cmacs-gsurf-actions)
    (let ((arr (json-parse-string (cmacs-gsurf-mcp-list-actions)
                                  :object-type 'alist)))
      (should (vectorp arr))
      (should (> (length arr) 40))
      (let ((reload (seq-find (lambda (o) (equal (alist-get 'name o) "reload"))
                              arr))
            (dark (seq-find (lambda (o) (equal (alist-get 'name o)
                                               "dark-mode-toggle"))
                            arr)))
        (should (equal (alist-get 'handler reload) "cmacs"))
        (should (equal (alist-get 'handler dark) "module")))))
  (when (fboundp 'cmacs-gsurf-containers)
    (should (vectorp (json-parse-string (cmacs-gsurf-mcp-list-containers)))))
  ;; No gsurf buffer: the buffer-targeting helpers refuse cleanly.
  (when (fboundp 'cmacs-gsurf-type)
    (let ((cmacs-gsurf--buffers nil))
      (should-error (cmacs-gsurf-mcp-type-text "x") :type 'user-error))))

(provide 'cmacs-gsurf-tests)
;;; cmacs-gsurf-tests.el ends here
