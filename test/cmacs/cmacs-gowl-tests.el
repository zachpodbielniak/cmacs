;;; cmacs-gowl-tests.el --- Tests for gowl compositor integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs gowl Wayland compositor integration.
;; Tests cover compositor lifecycle (start/stop/running-p), client
;; management (list, info, focus, close, move, resize, tags),
;; monitor listing, tag switching, layout setting, and spawning.
;;
;; NOTE: Many tests cannot fully exercise the compositor without a
;; running Wayland session.  Tests that require an active compositor
;; use `gowl-running-p' as a skip guard.  Error-path tests can run
;; without a compositor.

;;; Code:

(require 'ert)
(require 'cmacs)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Running predicate tests

(ert-deftest cmacs-gowl-test-running-p-returns-boolean ()
  "Test that `gowl-running-p' returns t or nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (let ((result (gowl-running-p)))
    (should (memq result '(t nil)))))

;;; Start/stop lifecycle tests

(ert-deftest cmacs-gowl-test-start-already-running ()
  "Test that `gowl-start' errors when compositor is already running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-start)
                :type 'error))

(ert-deftest cmacs-gowl-test-stop-returns-nil ()
  "Test that `gowl-stop' returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; Only test the return value semantics; don't actually stop a
  ;; live compositor during testing.
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-stop)))

(ert-deftest cmacs-gowl-test-stop-when-not-running ()
  "Test that `gowl-stop' is a no-op when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-stop)))

;;; Client list tests

(ert-deftest cmacs-gowl-test-list-clients-returns-list ()
  "Test that `gowl-list-clients' returns a list."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (should (listp clients))))

(ert-deftest cmacs-gowl-test-list-clients-not-running ()
  "Test that `gowl-list-clients' returns nil when not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-list-clients)))

(ert-deftest cmacs-gowl-test-list-clients-all-gobjects ()
  "Test that all items in client list are GObjects."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (dolist (c clients)
      (should (gobject-p c)))))

;;; Client info tests

(ert-deftest cmacs-gowl-test-client-info-non-gobject ()
  "Test that `gowl-client-info' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-client-info 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-client-info-nil ()
  "Test that `gowl-client-info' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-client-info nil)
                :type 'error))

(ert-deftest cmacs-gowl-test-client-info-returns-alist ()
  "Test that `gowl-client-info' returns expected alist keys."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (let ((info (gowl-client-info (car clients))))
      (should (listp info))
      (should (assoc "title" info))
      (should (assoc "app-id" info))
      (should (assoc "tags" info))
      (should (assoc "floating" info))
      (should (assoc "geometry" info)))))

;;; Focus tests

(ert-deftest cmacs-gowl-test-focus-client-non-gobject ()
  "Test that `gowl-focus-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-focus-client 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-focus-client-nil ()
  "Test that `gowl-focus-client' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-focus-client nil)
                :type 'error))

;;; Move client tests

(ert-deftest cmacs-gowl-test-move-client-non-gobject ()
  "Test that `gowl-move-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-move-client 42 0 0)
                :type 'error))

(ert-deftest cmacs-gowl-test-move-client-non-integer-coords ()
  "Test that `gowl-move-client' rejects non-integer coordinates."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-move-client (car clients) "bad" 0)
                  :type 'wrong-type-argument)))

;;; Resize client tests

(ert-deftest cmacs-gowl-test-resize-client-non-gobject ()
  "Test that `gowl-resize-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-resize-client 42 100 100)
                :type 'error))

(ert-deftest cmacs-gowl-test-resize-client-non-integer-dims ()
  "Test that `gowl-resize-client' rejects non-integer dimensions."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-resize-client (car clients) "bad" 100)
                  :type 'wrong-type-argument)))

;;; Close client tests

(ert-deftest cmacs-gowl-test-close-client-non-gobject ()
  "Test that `gowl-close-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-close-client 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-close-client-nil ()
  "Test that `gowl-close-client' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-close-client nil)
                :type 'error))

;;; Set tags tests

(ert-deftest cmacs-gowl-test-set-tags-non-gobject ()
  "Test that `gowl-set-tags' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-tags 42 1)
                :type 'error))

(ert-deftest cmacs-gowl-test-set-tags-requires-fixnat ()
  "Test that `gowl-set-tags' requires a non-negative integer bitmask."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-set-tags (car clients) "bad")
                  :type 'wrong-type-argument)))

;;; Monitor tests

(ert-deftest cmacs-gowl-test-list-monitors-returns-list ()
  "Test that `gowl-list-monitors' returns a list."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((monitors (gowl-list-monitors)))
    (should (listp monitors))))

(ert-deftest cmacs-gowl-test-list-monitors-not-running ()
  "Test that `gowl-list-monitors' returns nil when not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-list-monitors)))

(ert-deftest cmacs-gowl-test-list-monitors-all-gobjects ()
  "Test that all items in monitor list are GObjects."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((monitors (gowl-list-monitors)))
    (dolist (m monitors)
      (should (gobject-p m)))))

;;; View tags tests

(ert-deftest cmacs-gowl-test-view-tags-requires-fixnat ()
  "Test that `gowl-view-tags' requires a non-negative integer tagmask."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-view-tags "bad")
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-view-tags-not-running ()
  "Test that `gowl-view-tags' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-view-tags 1)
                :type 'error))

;;; Layout tests

(ert-deftest cmacs-gowl-test-set-layout-requires-string ()
  "Test that `gowl-set-layout' requires a string layout name."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-layout 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-set-layout-not-running ()
  "Test that `gowl-set-layout' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-set-layout "tile")
                :type 'error))

;;; Spawn tests

(ert-deftest cmacs-gowl-test-spawn-requires-string ()
  "Test that `gowl-spawn' requires a string command."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-spawn 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-spawn-not-running ()
  "Test that `gowl-spawn' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-spawn "echo hello")
                :type 'error))

;; Edge cases
(ert-deftest cmacs-gowl-start-stop-cycle ()
  "Start/stop cycle should leave clean state."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (not (gowl-running-p)))
  ;; Gowl may not start without a display, so just test stop is safe
  (gowl-stop)
  (should-not (gowl-running-p)))

(ert-deftest cmacs-gowl-spawn-empty-string ()
  "Spawning empty command should error or handle gracefully."
  (skip-unless (fboundp 'gowl-spawn))
  (skip-unless (gowl-running-p))
  (should-error (gowl-spawn "")))

(ert-deftest cmacs-gowl-view-tags-zero ()
  "Tag mask of zero should be valid (show no tags)."
  (skip-unless (fboundp 'gowl-view-tags))
  (skip-unless (gowl-running-p))
  (gowl-view-tags 0))

(ert-deftest cmacs-gowl-move-client-negative-coords ()
  "Moving to negative coordinates should not crash."
  (skip-unless (fboundp 'gowl-move-client))
  ;; Without a real client, this should error on the type check
  (should-error (gowl-move-client nil -100 -200)))

(ert-deftest cmacs-gowl-resize-client-zero ()
  "Resizing to zero dimensions should not crash."
  (skip-unless (fboundp 'gowl-resize-client))
  (should-error (gowl-resize-client nil 0 0)))

(ert-deftest cmacs-gowl-set-layout-invalid ()
  "Setting an invalid layout string should not crash."
  (skip-unless (fboundp 'gowl-set-layout))
  (skip-unless (gowl-running-p))
  ;; Even an invalid name should not crash -- the function may just ignore it
  (gowl-set-layout "nonexistent_layout"))

(ert-deftest cmacs-gowl-client-info-nil ()
  "Getting info for nil should error."
  (skip-unless (fboundp 'gowl-client-info))
  (should-error (gowl-client-info nil)))

;;; Module management tests

(ert-deftest cmacs-gowl-test-enable-module-not-running ()
  "Enabling a module without a running compositor should error."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-enable-module "alpha") :type 'error))

(ert-deftest cmacs-gowl-test-enable-module-bad-name ()
  "Enabling a nonexistent module should signal gowl-error."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-enable-module "nonexistent-module-xyz")
                :type 'gowl-error))

(ert-deftest cmacs-gowl-test-enable-module-type-check ()
  "gowl-enable-module should reject non-string arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-enable-module 42) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-disable-module-not-loaded ()
  "Disabling a module that isn't loaded should return nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-disable-module "nonexistent-module-xyz")))

(ert-deftest cmacs-gowl-test-disable-module-type-check ()
  "gowl-disable-module should reject non-string arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-disable-module 42) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-configure-module-type-check ()
  "gowl-configure-module should reject non-string name."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-module 42 '()) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-configure-module-alist-check ()
  "gowl-configure-module should reject non-list alist."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-module "test" 42) :type 'wrong-type-argument))

;;; Alpha convenience DEFUN tests

(ert-deftest cmacs-gowl-test-set-client-alpha-type-check ()
  "gowl-set-client-alpha should reject nil client."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-client-alpha nil 0.5) :type 'error))

(ert-deftest cmacs-gowl-test-alpha-info-no-module ()
  "gowl-alpha-info returns nil when alpha module is not loaded."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should (null (gowl-alpha-info))))

(ert-deftest cmacs-gowl-test-set-focused-alpha-type-check ()
  "gowl-set-focused-alpha should reject non-number."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-focused-alpha "bad") :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-set-unfocused-alpha-type-check ()
  "gowl-set-unfocused-alpha should reject non-number."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-unfocused-alpha "bad") :type 'wrong-type-argument))

;;; Gaps convenience DEFUN tests

(ert-deftest cmacs-gowl-test-gaps-info-no-module ()
  "gowl-gaps-info returns nil when vanitygaps module is not loaded."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should (null (gowl-gaps-info))))

(ert-deftest cmacs-gowl-test-set-gaps-type-check ()
  "gowl-set-gaps should reject non-list argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-gaps 42) :type 'wrong-type-argument))

;;; Screenlock convenience DEFUN tests

(ert-deftest cmacs-gowl-test-configure-screenlock-type-check ()
  "gowl-configure-screenlock should reject non-list argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-screenlock 42) :type 'wrong-type-argument))

;;; Scratchpad convenience DEFUN tests

(ert-deftest cmacs-gowl-test-scratchpad-toggle-type-check ()
  "gowl-scratchpad-toggle should reject non-string argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-scratchpad-toggle 42) :type 'wrong-type-argument))

;;; Window rule DEFUN tests

(ert-deftest cmacs-gowl-test-add-rule-full-round-trip ()
  "`gowl-add-rule-full' then `gowl-list-rules' returns the rule."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((marker (format "test-rule-%d" (random 100000))))
    (unwind-protect
        (progn
          (gowl-add-rule-full marker nil 0 t -1 0 0 nil)
          (let* ((rules (gowl-list-rules))
                 (found (seq-find
                          (lambda (r)
                            (equal (cdr (assq 'app-id r)) marker))
                          rules)))
            (should found)
            (should (equal (cdr (assq 'floating found)) t))
            (should (equal (cdr (assq 'regex found)) nil))))
      (gowl-remove-rule marker nil))))

(ert-deftest cmacs-gowl-test-add-rule-regex-flag ()
  "Regex rules round-trip with the :regex field set."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (unwind-protect
      (progn
        (gowl-add-rule-full nil "^Zoom.*" 0 t -1 0 0 t)
        (let* ((rules (gowl-list-rules))
               (found (seq-find
                        (lambda (r)
                          (equal (cdr (assq 'title r)) "^Zoom.*"))
                        rules)))
          (should found)
          (should (equal (cdr (assq 'regex found)) t))))
    (gowl-remove-rule nil "^Zoom.*")))

(ert-deftest cmacs-gowl-test-remove-rule-returns-nil-for-missing ()
  "Removing a non-existent rule returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-remove-rule "nonexistent-app-id-xyz-123" nil)))

(ert-deftest cmacs-gowl-test-clear-rules-empties-list ()
  "`gowl-clear-rules' removes every rule."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  ;; Snapshot for restoration.
  (let ((snapshot (gowl-list-rules)))
    (unwind-protect
        (progn
          (gowl-clear-rules)
          (should (null (gowl-list-rules))))
      ;; Restore.
      (dolist (r snapshot)
        (gowl-add-rule-full
          (cdr (assq 'app-id r))
          (cdr (assq 'title r))
          (cdr (assq 'tags r))
          (cdr (assq 'floating r))
          (cdr (assq 'monitor r))
          (cdr (assq 'width r))
          (cdr (assq 'height r))
          (cdr (assq 'regex r)))))))

;;; Dropdown DEFUN tests

(ert-deftest cmacs-gowl-test-add-dropdown-round-trip ()
  "`gowl-add-dropdown' then `gowl-list-dropdowns' returns the entry."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((marker (format "test-dd-%d" (random 100000))))
    (unwind-protect
        (progn
          (gowl-add-dropdown marker "true" nil 1.0 0.4 0 0 'top)
          (let* ((dds (gowl-list-dropdowns))
                 (found (seq-find
                          (lambda (d)
                            (equal (cdr (assq 'name d)) marker))
                          dds)))
            (should found)
            (should (equal (cdr (assq 'spawn-cmd found)) "true"))
            (should (equal (cdr (assq 'anchor found)) 'top))))
      (gowl-remove-dropdown marker))))

(ert-deftest cmacs-gowl-test-add-dropdown-type-check ()
  "`gowl-add-dropdown' requires NAME and SPAWN-CMD strings."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; The DEFUN runs GOWL_CHECK_RUNNING before CHECK_STRING, so the
  ;; type check is only reachable with a live compositor.
  (skip-unless (gowl-running-p))
  (should-error (gowl-add-dropdown 42 "foo" nil 1.0 0.4 0 0 'top)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-remove-dropdown-returns-nil-for-missing ()
  "Removing a non-existent dropdown returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-remove-dropdown "nonexistent-dropdown-xyz-123")))

(ert-deftest cmacs-gowl-test-dropdown-toggle-type-check ()
  "`gowl-dropdown-toggle' requires a string argument."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; GOWL_CHECK_RUNNING precedes the type check; needs a compositor.
  (skip-unless (gowl-running-p))
  (should-error (gowl-dropdown-toggle 42) :type 'wrong-type-argument))

;;; Customization integration tests

(ert-deftest cmacs-gowl-test-float-rules-defaults-valid ()
  "Every shipped default float rule has a non-nil pattern."
  (require 'cmacs-gowl)
  (dolist (r cmacs-gowl-float-rules)
    (should (or (plist-get r :app-id) (plist-get r :title)))))

(ert-deftest cmacs-gowl-test-dropdowns-defaults-valid ()
  "Every shipped default dropdown has a :name and either a spawn-cmd
or nil (which falls back to `cmacs-gowl-default-dropdown-terminal')."
  (require 'cmacs-gowl)
  (dolist (d cmacs-gowl-dropdowns)
    (should (plist-get d :name))))

;;; Tag keybindings and launch-into-tag tests

(ert-deftest cmacs-gowl-test-default-keybinds-tag-bitmasks ()
  "The keybind installer passes tag-action args as raw bitmasks.
The compositor interprets a tag-action arg as `atoi(arg) & TAGMASK',
so tag N must be (ash 1 (1- N)) and \"view all\" must be (1<<9)-1,
not the plain tag number / \"0\" that gowl's default-config.c uses."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (let ((captured nil)
        (cmacs-gowl--keybinds-installed nil))
    (cl-letf (((symbol-function 'gowl-add-keybind)
               (lambda (key action &optional arg)
                 (push (list key action arg) captured))))
      (cmacs-gowl--install-default-keybinds))
    ;; tag 1 -> bit 0 = "1", tag 3 -> bit 2 = "4", tag 9 -> bit 8 = "256".
    (should (member '("Super+1" tag-view "1") captured))
    (should (member '("Super+3" tag-view "4") captured))
    (should (member '("Super+9" tag-view "256") captured))
    ;; Shift moves the focused client to that tag.
    (should (member '("Super+Shift+3" tag-set "4") captured))
    ;; Ctrl toggles the tag's visibility; Shift+Ctrl toggles on client.
    (should (member '("Super+Ctrl+3" tag-toggle-view "4") captured))
    (should (member '("Super+Shift+Ctrl+3" tag-toggle "4") captured))
    ;; "All tags" is the full mask (1<<9)-1 = 511, never "0" (a no-op).
    (should (member '("Super+0" tag-view "511") captured))
    (should (member '("Super+Shift+0" tag-set "511") captured))
    (should-not (member '("Super+0" tag-view "0") captured))
    ;; Launcher + terminal binds are present.
    (should (cl-find-if (lambda (e) (and (equal (car e) "Super+p")
                                         (eq (nth 1 e) 'spawn)))
                        captured))
    (should (cl-find-if (lambda (e) (and (equal (car e) "Super+Return")
                                         (eq (nth 1 e) 'spawn)))
                        captured))))

(ert-deftest cmacs-gowl-test-bemenu-binary-strips-run ()
  "`cmacs-gowl--bemenu-binary' derives the dmenu-mode binary name."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (let ((cmacs-gowl-dmenu-command "bemenu-run"))
    (should (equal (cmacs-gowl--bemenu-binary) "bemenu")))
  (let ((cmacs-gowl-dmenu-command "bemenu"))
    (should (equal (cmacs-gowl--bemenu-binary) "bemenu")))
  (let ((cmacs-gowl-dmenu-command "rofi -show drun"))
    (should (equal (cmacs-gowl--bemenu-binary) "rofi"))))

(ert-deftest cmacs-gowl-test-launch-commands-defined ()
  "Tag-launch commands and the pretag primitive are available."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (commandp 'cmacs-gowl-spawn-in-tag))
  (should (commandp 'cmacs-gowl-launch-in-tag))
  (should (commandp 'cmacs-gowl-bemenu-in-tag))
  (should (commandp 'cmacs-gowl-toggle-tag))
  (should (commandp 'cmacs-gowl-assign-monitor-tags))
  (should (fboundp 'gowl-pretag-pid))
  ;; gowl-pretag-pid takes (PID TAGMASK &optional MONITOR).
  (should (equal (func-arity 'gowl-pretag-pid) '(2 . 3))))

(ert-deftest cmacs-gowl-test-assign-monitor-tags ()
  "`cmacs-gowl-assign-monitor-tags' views tag i+1 on monitor i."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (let ((calls nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda () t))
              ((symbol-function 'gowl-list-monitors)
               (lambda () '(:m0 :m1 :m2)))
              ((symbol-function 'gowl-monitor-enabled-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-view-tags)
               (lambda (mask mon &rest _) (push (cons mon mask) calls)))
              ((symbol-function 'cmacs-gowl--bar-redraw) #'ignore))
      (cmacs-gowl-assign-monitor-tags))
    ;; monitor 0 → tag 1 (bit 0 = 1), 1 → tag 2 (2), 2 → tag 3 (4).
    (should (equal (assoc :m0 calls) '(:m0 . 1)))
    (should (equal (assoc :m1 calls) '(:m1 . 2)))
    (should (equal (assoc :m2 calls) '(:m2 . 4)))))

(ert-deftest cmacs-gowl-test-monitor-index-showing-tag ()
  "`cmacs-gowl--monitor-index-showing-tag' finds the monitor viewing a tag."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  ;; Three monitors viewing tags 1, 2, 4 (bits 0, 1, 2).
  (cl-letf (((symbol-function 'gowl-list-monitors)
             (lambda () '(:m0 :m1 :m2)))
            ((symbol-function 'gowl-monitor-info)
             (lambda (m)
               (list (cons 'tags (pcase m (:m0 1) (:m1 2) (:m2 4)))))))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 1) 0))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 2) 1))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 4) 2))
    ;; A tag shown on no monitor (fewer monitors than tags) → nil.
    (should (null (cmacs-gowl--monitor-index-showing-tag 8)))))

(ert-deftest cmacs-gowl-test-picker-commands-defined ()
  "The M-x tag/window pickers are interactive commands."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (commandp 'cmacs-gowl-switch-tag))
  (should (commandp 'cmacs-gowl-switch-to-app))
  (should (commandp 'cmacs-gowl-view-tag))
  (should (fboundp 'cmacs-gowl--refresh-view)))

(ert-deftest cmacs-gowl-test-tag-mask-label ()
  "`cmacs-gowl--tag-mask-label' renders tag bitmasks compactly."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (equal (cmacs-gowl--tag-mask-label 1) "1"))
  (should (equal (cmacs-gowl--tag-mask-label 4) "3"))
  (should (equal (cmacs-gowl--tag-mask-label 6) "2,3"))
  (should (equal (cmacs-gowl--tag-mask-label 256) "9"))
  (should (equal (cmacs-gowl--tag-mask-label 0) "—")))

(ert-deftest cmacs-gowl-test-client-label ()
  "`cmacs-gowl--client-label' formats title, app-id and tag."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (string-match-p
           "Firefox.*\\[firefox\\].*tag 2"
           (cmacs-gowl--client-label
            '((title . "Firefox") (app-id . "firefox") (tags . 2)))))
  ;; Untitled + no app-id still yields a usable label.
  (should (string-match-p
           "(untitled).*tag 1"
           (cmacs-gowl--client-label
            '((title . "") (app-id . "") (tags . 1))))))

(ert-deftest cmacs-gowl-test-spawn-in-tag-requires-running ()
  "`cmacs-gowl-spawn-in-tag' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (skip-unless (not (gowl-running-p)))
  (should-error (cmacs-gowl-spawn-in-tag "true" 2)))

(ert-deftest cmacs-gowl-test-pretag-pid-requires-running ()
  "`gowl-pretag-pid' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-pretag-pid 12345 2)))

(ert-deftest cmacs-gowl-test-pretag-pid-type-checks ()
  "`gowl-pretag-pid' type-checks its PID and TAGMASK arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-pretag-pid "notapid" 2) :type 'wrong-type-argument)
  (should-error (gowl-pretag-pid 123 "notamask") :type 'wrong-type-argument))

;;; Layer-surface keyboard grab
;;
;; Regression coverage for the "wofi maps, is drawn on top, and is
;; completely deaf" defect reported by Ben Doty on 2026-08-08.  A
;; keyboard-interactive layer surface is granted the keyboard by the
;; compositor's `arrangelayers', and every cmacs path that moves seat
;; keyboard focus must then leave it alone until it unmaps.
;;
;; cmacs moves seat focus by calling `wlr_seat_keyboard_notify_enter'
;; directly rather than going through `gowl_compositor_focus_client'
;; -- embedded clients are deliberately invisible to the compositor's
;; focus stack -- so the compositor's own guards do NOT cover these
;; paths.  `cmacs_gowl_layer_owns_keyboard' is the only thing that
;; does, and the source-shape test below is what keeps it that way: a
;; new seat-focus path that forgets the check reintroduces the bug,
;; and no runtime test can catch that without a live compositor, a
;; live layer-shell client, and a Wayland session.
;;
;; The decision logic itself (which layer surfaces take the keyboard,
;; which focus changes are refused) is unit-tested on the gowl side in
;; `deps/gowl/tests/test-focus-rules.c'.

(defconst cmacs-gowl-tests--this-file
  (or load-file-name buffer-file-name)
  "Absolute path of this test file, captured at load time.
`load-file-name' is nil while ERT bodies run, so the source-shape
tests below cannot resolve the tree from inside a test.")

(defun cmacs-gowl-tests--source-file (relative)
  "Return the absolute path of RELATIVE inside the cmacs source tree.
Resolves against this test file's own location, so it works from a
worktree or an out-of-tree test run.  Returns nil when the file is
not present (installed trees ship no C sources)."
  (let* ((here (or cmacs-gowl-tests--this-file
                   (locate-library "cmacs-gowl-tests")))
         (root (and here
                    (expand-file-name "../.." (file-name-directory here))))
         (file (and root (expand-file-name relative root))))
    (and file (file-readable-p file) file)))

(defun cmacs-gowl-tests--strip-c-comments ()
  "Replace every /* ... */ comment in the current buffer with a space.
The C sources document these call sites at length, quoting the very
identifiers the tests search for, so the prose has to go before any
call-site matching can mean anything."
  (goto-char (point-min))
  (while (re-search-forward "/\\*" nil t)
    (let ((start (match-beginning 0)))
      (if (re-search-forward "\\*/" nil t)
          (delete-region start (point))
        ;; Unterminated comment: drop the rest of the buffer.
        (delete-region start (point-max))))))

(defun cmacs-gowl-tests--defun-bodies (source symbol)
  "Return the code of each top-level C function in SOURCE calling SYMBOL.
Comments are stripped first.  A body runs from the enclosing top-level
function's opening brace (a `{' in column 0) through to the SYMBOL
call.  Good enough to answer \"was the guard checked before this
call?\" without parsing C."
  (let ((bodies nil))
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (goto-char (point-min))
      (while (re-search-forward
              (concat "\\_<" (regexp-quote symbol) "\\_>[[:space:]]*(")
              nil t)
        (let ((call-end (point))
              (start (save-excursion
                       (if (re-search-backward "^{" nil t)
                           (point)
                         (point-min)))))
          (push (buffer-substring-no-properties start call-end)
                bodies))))
    (nreverse bodies)))

(ert-deftest cmacs-gowl-test-seat-focus-paths-check-layer-grab ()
  "Every cmacs seat-keyboard-focus path consults the layer grab first.

This is the regression guard for the deaf-launcher bug: a path that
calls `wlr_seat_keyboard_notify_enter' without first checking
`cmacs_gowl_layer_owns_keyboard' can take the keyboard away from a
mapped launcher, leaving it visible, on top, and unable to receive a
single keystroke."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (let ((bodies (cmacs-gowl-tests--defun-bodies
                   source "wlr_seat_keyboard_notify_enter")))
      ;; Sanity: the call sites still exist and were actually found.
      ;; A zero here would make the assertion below vacuously true.
      (should (>= (length bodies) 4))
      (dolist (body bodies)
        (should (string-match-p "cmacs_gowl_layer_owns_keyboard" body))))))

(ert-deftest cmacs-gowl-test-layer-grab-helper-uses-compositor-api ()
  "`cmacs_gowl_layer_owns_keyboard' delegates to the compositor.

The grab must be derived from live compositor state rather than
cached in cmacs: a surface that unmaps or stops asking for the
keyboard releases it immediately, so a stale cmacs-side copy could
wedge keyboard focus with no way out."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (should (string-match-p
               "gowl_compositor_has_exclusive_keyboard_layer"
               (buffer-string))))))

(ert-deftest cmacs-gowl-test-grant-focus-requires-running ()
  "`gowl-grant-focus-to-emacs' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-grant-focus-to-emacs)))

(ert-deftest cmacs-gowl-test-return-focus-without-redirect ()
  "`gowl-return-focus-to-embed' is a no-op with no active redirect."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-not (gowl-return-focus-to-embed)))

(ert-deftest cmacs-gowl-test-focus-redirect-predicates ()
  "The focus-redirect predicates return booleans and default to nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should (memq (gowl-focus-redirect-active-p) '(t nil)))
  (should (memq (gowl-focus-redirect-sticky-p) '(t nil)))
  ;; With no redirect pushed, neither is active.
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-focus-redirect-active-p))
  (should-not (gowl-focus-redirect-sticky-p)))

(ert-deftest cmacs-gowl-test-focus-post-command-is-safe ()
  "The `post-command-hook' focus restore never errors.

It runs after literally every command in the session; a signal here
would make the editor unusable, so it must tolerate no compositor, no
redirect, and a redirect blocked by a layer grab alike."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl-focus)
  (should-not (cmacs-gowl-focus--post-command)))

(ert-deftest cmacs-gowl-test-prefix-keys-exclude-plain-escape ()
  "Plain ESC is not a prefix key; it is the hardcoded sticky redirect.
Listing it here would push a non-sticky redirect that
`post-command-hook' pops one command later, defeating the escape
hatch out of an embed."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl-focus)
  (should-not (member "Escape" cmacs-gowl-prefix-keys))
  (should (member "Control+Escape" cmacs-gowl-prefix-keys)))

;;; emacsclient --gowl / cmacs-gowl-attach

(ert-deftest cmacs-gowl-test-attach-is-an-interactive-command ()
  "`cmacs-gowl-attach' is defined and callable as a command.
`emacsclient --gowl' reaches it through server.el's `-gowl' branch, and
`M-x' through the autoload in `cmacs.el'."
  (require 'cmacs-gowl)
  (should (fboundp 'cmacs-gowl-attach))
  (should (commandp 'cmacs-gowl-attach)))

(ert-deftest cmacs-gowl-test-attach-refuses-without-a-display ()
  "`cmacs-gowl-attach' errors instead of letting wlroots fail deep inside.
A headless daemon has no parent session to nest in and no graphical
frame whose display gowl could borrow, so there is nothing to host an
output; the error is what `emacsclient --gowl' reports to the user."
  ;; `fboundp' rather than `cmacs-feature-p': that helper lives in
  ;; cmacs-glib-tests and is not loaded when this file runs alone.
  (skip-unless (fboundp 'gowl-start))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (skip-unless (not (gowl-running-p)))
  (skip-unless (not (cl-some #'display-graphic-p (frame-list))))
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "WAYLAND_DISPLAY" nil)
    (should-error (cmacs-gowl-attach))))

(ert-deftest cmacs-gowl-test-server-honours-the-gowl-request ()
  "`lisp/server.el' still carries the `-gowl' client command.
Without both hunks -- the request arm and the frame-dispatch branch --
`emacsclient --gowl' either dies with \"Unknown command: -gowl\" or
silently opens a frame on the launcher's terminal instead of bringing
up the compositor.  Both are re-applied by hand after an upstream
merge, so guard them."
  (let ((source (cmacs-gowl-tests--source-file "lisp/server.el")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (let ((text (buffer-string)))
        (should (string-match-p "(\"-gowl\"" text))
        (should (string-match-p "cmacs-gowl-attach" text))))))

(ert-deftest cmacs-gowl-test-emacsclient-has-the-gowl-option ()
  "`lib-src/emacsclient.c' still carries the `--gowl' option.
Guards the other half of the same upstream touch-point: the long
option, the request it sends, and the `emacs --gowl' fallback used when
no server answers."
  (let ((source (cmacs-gowl-tests--source-file "lib-src/emacsclient.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (let ((text (buffer-string)))
        (should (string-match-p "\"gowl\"[[:space:]]*," text))
        (should (string-match-p "\"-gowl \"" text))
        (should (string-match-p "emacs --gowl" text))))))

(ert-deftest cmacs-gowl-test-desktop-launchers-exist ()
  "The gowl application launchers ship and point at the right commands."
  (let ((session (cmacs-gowl-tests--source-file "etc/emacs-gowl.desktop"))
        (client (cmacs-gowl-tests--source-file "etc/emacsclient-gowl.desktop")))
    (skip-unless (and session client))
    (with-temp-buffer
      (insert-file-contents session)
      (should (string-match-p "^Exec=emacs --gowl" (buffer-string)))
      ;; A compositor session must not become the handler for text files.
      (should-not (string-match-p "^MimeType=" (buffer-string))))
    (with-temp-buffer
      (insert-file-contents client)
      (should (string-match-p "^Exec=emacsclient --gowl" (buffer-string)))
      (should-not (string-match-p "^MimeType=" (buffer-string))))))

(provide 'cmacs-gowl-tests)
;;; cmacs-gowl-tests.el ends here
