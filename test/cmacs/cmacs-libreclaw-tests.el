;;; cmacs-libreclaw-tests.el --- ERT tests for cmacs-libreclaw  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the cmacs-libreclaw subsystem.  Most tests are gated on
;; `(fboundp 'cmacs-libreclaw--start-internal)' so the suite is a
;; no-op when cmacs is built --without-cmacs-libreclaw.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-libreclaw-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-libreclaw nil t)
(require 'cmacs-ai-view nil t)

(defvar cmacs-libreclaw-tests--fixture-dir
  (expand-file-name "fixtures"
                    (file-name-directory
                     (or load-file-name buffer-file-name
                         default-directory))))

(defun cmacs-libreclaw-tests--fixture (name)
  "Return absolute path to fixture NAME."
  (expand-file-name name cmacs-libreclaw-tests--fixture-dir))

;;;; Version & availability ----------------------------------------

(ert-deftest cmacs-libreclaw-feature-available ()
  "If built with libreclaw support, the start DEFUN is defined."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (should (fboundp 'cmacs-libreclaw--start-internal))
  (should (fboundp 'cmacs-libreclaw-stop))
  (should (fboundp 'cmacs-libreclaw-running-p))
  (should (fboundp 'cmacs-libreclaw-version)))

(ert-deftest cmacs-libreclaw-version-format ()
  "Version string has the form N.N.N and major is 0, minor is >= 18."
  (skip-unless (fboundp 'cmacs-libreclaw-version))
  (let ((v (cmacs-libreclaw-version)))
    (should (stringp v))
    (should (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\'" v))
    (let ((parts (mapcar #'string-to-number (split-string v "\\."))))
      (should (= 0  (nth 0 parts)))
      (should (>= (nth 1 parts) 18)))))

;;;; Config file accessors (no start required) ---------------------

(ert-deftest cmacs-libreclaw-set-get-config ()
  "set-config-file round-trips through get-config-file."
  (skip-unless (fboundp 'cmacs-libreclaw-set-config-file))
  (cmacs-libreclaw-set-config-file "/tmp/cmacs-libreclaw-test.yaml")
  (should (equal (cmacs-libreclaw-get-config-file)
                 "/tmp/cmacs-libreclaw-test.yaml")))

;;;; Running without a config file should signal -------------------

(ert-deftest cmacs-libreclaw-start-requires-config ()
  "With `cmacs-libreclaw-auto-generate-config' disabled and no
existing default config, `cmacs-libreclaw-start' should error out
rather than silently start against nothing.  (When auto-generate
is enabled — the default — it prompts the user; the interactive
path is covered by the `ensure-config-*' tests.)"
  (skip-unless (fboundp 'cmacs-libreclaw-start))
  (let ((cmacs-libreclaw-config-file nil)
        (cmacs-libreclaw-auto-generate-config nil)
        ;; Point the default workspace at an empty tempdir so
        ;; `ensure-config' can't adopt a pre-existing file.
        (cmacs-libreclaw-default-workspace
         (make-temp-file "cmacs-libreclaw-empty-" t)))
    (unwind-protect
        (should-error (cmacs-libreclaw-start))
      (delete-directory cmacs-libreclaw-default-workspace t))))

;;;; Podomation dependency ----------------------------------------

(ert-deftest cmacs-libreclaw-requires-podomation ()
  "start-internal errors if cmacs-podomation isn't running."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (skip-unless (fboundp 'cmacs-podomation-running-p))
  (when (cmacs-podomation-running-p)
    (cmacs-podomation-stop))
  (cmacs-libreclaw-set-config-file
   (cmacs-libreclaw-tests--fixture "libreclaw-local-only.yaml"))
  (should-error (cmacs-libreclaw--start-internal)
                :type 'cmacs-libreclaw-error))

;;;; Room buffer pure-Elisp flow ----------------------------------
;;
;; These tests exercise the Elisp signal-dispatch path without a
;; running LcApp — we call the handler functions directly with
;; synthetic plists, which is the same shape the C-layer produces.

(ert-deftest cmacs-libreclaw-room-buffer-creation ()
  "on-room-added creates a buffer in cmacs-libreclaw-room-mode."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "test-chan" "!room:test" "Test Room")
    (let ((buf (cdr (assoc '("test-chan" . "!room:test")
                           cmacs-libreclaw-rooms-alist))))
      (should (buffer-live-p buf))
      (with-current-buffer buf
        (should (derived-mode-p 'cmacs-libreclaw-room-mode))
        (should (derived-mode-p 'org-mode))
        (should (equal cmacs-libreclaw-room-channel "test-chan"))
        (should (equal cmacs-libreclaw-room-id "!room:test"))
        (should (markerp cmacs-libreclaw-room--compose-marker))
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^\\* Compose" nil t))))
      (kill-buffer buf))))

(ert-deftest cmacs-libreclaw-on-message-inserts-heading ()
  "Incoming message inserts an org heading above the compose sentinel."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "c" "r" "Room")
    (cmacs-libreclaw--on-message
     "c" "r"
     '(:channel-id "c" :sender-id "@bob:srv" :sender-name "Bob"
       :room-id "r" :thread-id nil :body "hello world" :timestamp 0))
    (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
      (with-current-buffer buf
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^\\*\\* .*  Bob$" nil t)))
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "^hello world$" nil t))))
      (kill-buffer buf))))

(ert-deftest cmacs-libreclaw-history-is-read-only ()
  "Edits above the compose marker should signal text-read-only."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "c" "r" "Room")
    (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
      (with-current-buffer buf
        (goto-char (point-min))
        (should-error (insert "x") :type 'text-read-only))
      (kill-buffer buf))))

(ert-deftest cmacs-libreclaw-compose-region-writable ()
  "Edits below the compose marker should work."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "c" "r" "Room")
    (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
      (with-current-buffer buf
        (goto-char (point-max))
        ;; Multi-line edit should be possible.
        (insert "line 1\nline 2\nline 3")
        (should (save-excursion
                  (goto-char cmacs-libreclaw-room--compose-marker)
                  (looking-at "line 1\nline 2\nline 3"))))
      (kill-buffer buf))))

(ert-deftest cmacs-libreclaw-buffer-killed-cleanup ()
  "Killing a room buffer removes it from the alist."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "c" "r" "Room")
    (kill-buffer (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist)))
    (should (null (assoc '("c" . "r") cmacs-libreclaw-rooms-alist)))))

(ert-deftest cmacs-libreclaw-multi-room-isolation ()
  "Messages to one room do not appear in another room's buffer."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let ((cmacs-libreclaw-rooms-alist nil))
    (cmacs-libreclaw--on-room-added "c" "a" "Alpha")
    (cmacs-libreclaw--on-room-added "c" "b" "Bravo")
    (cmacs-libreclaw--on-message
     "c" "a"
     '(:channel-id "c" :sender-id "u1" :sender-name "U1"
       :room-id "a" :body "alpha-msg" :timestamp 0))
    (let ((buf-a (cdr (assoc '("c" . "a") cmacs-libreclaw-rooms-alist)))
          (buf-b (cdr (assoc '("c" . "b") cmacs-libreclaw-rooms-alist))))
      (with-current-buffer buf-a
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward "alpha-msg" nil t))))
      (with-current-buffer buf-b
        (should-not (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "alpha-msg" nil t))))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

;;;; Hatch wizard (no filesystem side effects) ---------------------

(ert-deftest cmacs-libreclaw-hatch-new-free ()
  "Hatch context can be created and freed."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch-new))
  (let ((h (cmacs-libreclaw-hatch-new "/tmp/cmacs-libreclaw-test-ws")))
    (should (integerp h))
    (should (eq (cmacs-libreclaw-hatch-free h) t))))

(ert-deftest cmacs-libreclaw-hatch-set-name-validates ()
  "Invalid workspace names are rejected."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch-new))
  (let ((h (cmacs-libreclaw-hatch-new "/tmp/cmacs-libreclaw-test-ws")))
    (unwind-protect
        (progn
          (should (cmacs-libreclaw-hatch-set-name h "valid-name"))
          (should-error (cmacs-libreclaw-hatch-set-name h "1-bad-name")
                        :type 'cmacs-libreclaw-error))
      (cmacs-libreclaw-hatch-free h))))

;;;; Default config generation -------------------------------------

(ert-deftest cmacs-libreclaw-generate-default-config ()
  "Default config generation writes a valid YAML to disk."
  (skip-unless (fboundp 'cmacs-libreclaw-generate-default-config))
  (let* ((ws (make-temp-file "cmacs-libreclaw-default-" t))
         (cmacs-libreclaw-config-file nil)
         path)
    (unwind-protect
        (progn
          (setq path (cmacs-libreclaw-generate-default-config
                      ws 'claude t))
          (should (stringp path))
          (should (file-readable-p path))
          (should (equal cmacs-libreclaw-config-file path))
          ;; Validate: libreclaw-side YAML parser round-trips cleanly.
          (should (cmacs-libreclaw-config-validate path))
          ;; Spot-check the generated content against the real
          ;; libreclaw YAML schema.  Default generator now emits
          ;; the cmacs (in-process) channel, not local.
          (let ((contents (with-temp-buffer
                            (insert-file-contents path)
                            (buffer-string))))
            (should (string-match-p "^agent:"     contents))
            (should (string-match-p "^ai:"        contents))
            (should (string-match-p "^  model:"   contents))
            (should (string-match-p "^channels:"  contents))
            (should (string-match-p "^  cmacs:"   contents))
            (should (string-match-p "^    enabled: true" contents))
            (should (string-match-p "^session:"   contents))))
      (when (file-directory-p ws)
        (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-ensure-config-adopts-existing ()
  "ensure-config adopts a pre-existing default config without prompting."
  (skip-unless (fboundp 'cmacs-libreclaw-generate-default-config))
  (let* ((ws (make-temp-file "cmacs-libreclaw-adopt-" t))
         (cmacs-libreclaw-default-workspace ws)
         (cmacs-libreclaw-config-file nil)
         (cmacs-libreclaw-auto-generate-config nil))
    (unwind-protect
        (let ((path (cmacs-libreclaw-generate-default-config
                     ws 'claude t)))
          ;; Wipe the customize value so ensure-config has to rediscover.
          (setq cmacs-libreclaw-config-file nil)
          (cmacs-libreclaw-ensure-config)
          (should (equal cmacs-libreclaw-config-file path)))
      (when (file-directory-p ws)
        (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-generate-default-starts-cleanly ()
  "End-to-end: a freshly-generated default config must actually
start libreclaw without hitting the `lc_session_manager_new:
model != NULL' assertion.  Regression guard for the schema bug
where the old generator emitted top-level `providers:' instead
of `ai.model'."
  (skip-unless (fboundp 'cmacs-libreclaw-generate-default-config))
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  ;; Podomation must not already be running from a previous test
  ;; in this session — we need start-internal to bring it up.
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (when (cmacs-libreclaw-running-p)
    (cmacs-libreclaw-stop))
  (let* ((ws (make-temp-file "cmacs-libreclaw-start-" t))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (let ((path (cmacs-libreclaw-generate-default-config
                     ws 'claude t)))
          (should (stringp path))
          (cmacs-podomation-start)
          ;; This is the call that used to trigger
          ;; LibreClaw-CRITICAL: lc_session_manager_new: 'model != NULL'.
          (cmacs-libreclaw--start-internal)
          (should (cmacs-libreclaw-running-p))
          (should (cmacs-libreclaw-podomation-shared-p))
          ;; Generated config has exactly one cmacs channel.
          (let ((channels (cmacs-libreclaw-list-channels)))
            (should (= (length channels) 1))
            (should (equal (caar channels) "cmacs"))
            (should (eq (cdar channels) 'cmacs)))
          (cmacs-libreclaw-stop)
          (should-not (cmacs-libreclaw-running-p)))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (when (file-directory-p ws) (delete-directory ws t)))))

;; NOTE: the pre-existing starts-cleanly test asserted that the
;; lone channel was named "local".  Default-config now emits the
;; cmacs (in-process) channel instead, so the assertion below tracks
;; that.  The channel-kind-symbol function in cmacs-libreclaw.c was
;; updated in the same change to classify LcCmacsChannel as `cmacs'
;; rather than `unknown'.

(ert-deftest cmacs-libreclaw-load-config-stages-when-stopped ()
  "With libreclaw not running, `cmacs-libreclaw-load-config'
expands the path, sets `cmacs-libreclaw-config-file', and returns
the expanded path without attempting a restart."
  (skip-unless (fboundp 'cmacs-libreclaw-load-config))
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (let* ((ws (make-temp-file "cmacs-libreclaw-load-stage-" t))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (let ((path (cmacs-libreclaw-generate-default-config
                     ws 'claude t)))
          ;; Clear the config var so load-config has to set it.
          (setq cmacs-libreclaw-config-file nil)
          (let ((ret (cmacs-libreclaw-load-config path)))
            (should (equal ret path))
            (should (equal cmacs-libreclaw-config-file path))
            (should-not (cmacs-libreclaw-running-p))))
      (when (file-directory-p ws) (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-load-config-rejects-missing-file ()
  "`cmacs-libreclaw-load-config' must refuse a path that does not
exist."
  (skip-unless (fboundp 'cmacs-libreclaw-load-config))
  (should-error
   (cmacs-libreclaw-load-config
    "/tmp/this-file-does-not-exist-for-sure-xxxxxx.yaml")))

(ert-deftest cmacs-libreclaw-load-config-restarts-when-running ()
  "With libreclaw running and RESTART non-nil,
`cmacs-libreclaw-load-config' should cleanly stop the current
subsystem, switch the config var, and start against the new
file."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (let* ((ws-a (make-temp-file "cmacs-libreclaw-load-a-" t))
         (ws-b (make-temp-file "cmacs-libreclaw-load-b-" t))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (let ((path-a (cmacs-libreclaw-generate-default-config
                       ws-a 'claude t))
              (path-b (cmacs-libreclaw-generate-default-config
                       ws-b 'claude t)))
          ;; Start against A.
          (cmacs-libreclaw-load-config path-a)
          (cmacs-libreclaw-start)
          (should (cmacs-libreclaw-running-p))
          (should (equal (cmacs-libreclaw-get-config-file) path-a))
          ;; Switch to B with RESTART=t.
          (cmacs-libreclaw-load-config path-b t)
          (should (cmacs-libreclaw-running-p))
          (should (equal cmacs-libreclaw-config-file path-b))
          (should (equal (cmacs-libreclaw-get-config-file) path-b))
          (cmacs-libreclaw-stop))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (when (file-directory-p ws-a) (delete-directory ws-a t))
      (when (file-directory-p ws-b) (delete-directory ws-b t)))))

(ert-deftest cmacs-libreclaw-default-fallback-name ()
  "Workspace directory basenames that don't match the name regex
fall back to \"default\" rather than signalling an error."
  (skip-unless (fboundp 'cmacs-libreclaw-generate-default-config))
  (let* ((parent (make-temp-file "cmacs-libreclaw-fb-" t))
         ;; "1-bad" starts with a digit — invalid as a workspace name.
         (ws (expand-file-name "1-bad" parent))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (let ((path (cmacs-libreclaw-generate-default-config
                     ws 'claude t)))
          (should (file-readable-p path))
          (let ((contents (with-temp-buffer
                            (insert-file-contents path)
                            (buffer-string))))
            (should (string-match-p "name: \"default\"" contents))))
      (when (file-directory-p parent)
        (delete-directory parent t)))))

;;;; Hatch REPL wizard ---------------------------------------------
;;
;; These tests drive the REPL state machine by inserting text into
;; the compose region and calling `cmacs-libreclaw-hatch-submit'.
;; We never exercise the `read-passwd' code paths (matrix token,
;; email password), so all tests use the `local' channel.

(defun cmacs-libreclaw-tests--hatch-type (text)
  "Insert TEXT into the current hatch compose region."
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert text)))

(ert-deftest cmacs-libreclaw-hatch-repl-flow ()
  "Full REPL conversation: name → skip identity → claude → local
channel → done → no podomation → no audit → finalize."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch))
  (require 'cmacs-libreclaw-hatch)
  (let* ((ws (make-temp-file "cmacs-libreclaw-repl-" t))
         (buf nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-hatch ws)
          (setq buf (current-buffer))
          (should (derived-mode-p 'cmacs-libreclaw-hatch-mode))
          (should (derived-mode-p 'org-mode))
          (should (markerp cmacs-libreclaw-hatch--compose-marker))
          (should (eq cmacs-libreclaw-hatch--step 'name))
          ;; Step 1: workspace name
          (cmacs-libreclaw-tests--hatch-type "my-bot")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'identity))
          ;; Step 2: skip identity
          (cmacs-libreclaw-tests--hatch-type "skip")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'ai))
          ;; Step 3: AI provider
          (cmacs-libreclaw-tests--hatch-type "claude")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'channel))
          ;; Step 4: add a local channel then done
          (cmacs-libreclaw-tests--hatch-type "local")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'chan-local-prompt))
          (cmacs-libreclaw-tests--hatch-type "default")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'channel))
          (should (= cmacs-libreclaw-hatch--channels-added 1))
          (cmacs-libreclaw-tests--hatch-type "done")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'podomation))
          ;; Step 5: skip podomation
          (cmacs-libreclaw-tests--hatch-type "no")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'audit))
          ;; Step 6: skip audit — lands on review
          (cmacs-libreclaw-tests--hatch-type "no")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'review))
          ;; Buffer should now contain the YAML preview inline.
          (should (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "^#\\+begin_src yaml" nil t)))
          ;; Step 7: decline to write
          (cmacs-libreclaw-tests--hatch-type "no")
          (cmacs-libreclaw-hatch-submit)
          (should (null cmacs-libreclaw-hatch--step))
          ;; Conversation history: every user answer should appear.
          (let ((contents (buffer-substring-no-properties
                           (point-min) (point-max))))
            (should (string-match-p "^my-bot$" contents))
            (should (string-match-p "^skip$"   contents))
            (should (string-match-p "^claude$" contents))
            (should (string-match-p "^local$"  contents))
            (should (string-match-p "^done$"   contents))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-directory-p ws) (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-hatch-repl-retries-bad-name ()
  "An invalid name answer re-asks the same step rather than advancing."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch))
  (require 'cmacs-libreclaw-hatch)
  (let* ((ws (make-temp-file "cmacs-libreclaw-repl-retry-" t))
         (buf nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-hatch ws)
          (setq buf (current-buffer))
          ;; "1-bad" starts with a digit — rejected by
          ;; lc_hatch_set_workspace_name.  Wizard should stay on
          ;; the name step and re-ask.
          (cmacs-libreclaw-tests--hatch-type "1-bad")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'name))
          (should (save-excursion
                    (goto-char (point-min))
                    (re-search-forward "Try again" nil t)))
          ;; Now a valid name should advance.
          (cmacs-libreclaw-tests--hatch-type "good-name")
          (cmacs-libreclaw-hatch-submit)
          (should (eq cmacs-libreclaw-hatch--step 'identity)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-directory-p ws) (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-hatch-repl-history-protected ()
  "Edits above the compose marker in the hatch buffer should error."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch))
  (require 'cmacs-libreclaw-hatch)
  (let* ((ws (make-temp-file "cmacs-libreclaw-repl-ro-" t))
         (buf nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-hatch ws)
          (setq buf (current-buffer))
          (goto-char (point-min))
          (should-error (insert "x") :type 'text-read-only))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-directory-p ws) (delete-directory ws t)))))

;;;; Cmacs channel --------------------------------------------------
;;
;; The cmacs channel is libreclaw's in-process LcChannel.  Rather
;; than spin up a full LcApp for every test — which requires
;; podomation running + a real YAML config — these tests exercise
;; the Elisp layer directly: project detection, buffer routing,
;; response dispatch, multi-project isolation, and on-disk
;; persistence.  The end-to-end test (running libreclaw with a
;; cmacs-channel config and verifying DEFUN binding) lives in
;; cmacs-libreclaw-cmacs-channel-end-to-end below.

(defun cmacs-libreclaw-tests--cmacs-channel-reset ()
  "Clear all cmacs channel room state between tests."
  (require 'cmacs-libreclaw-cmacs-channel)
  (dolist (entry cmacs-libreclaw-cmacs-channel-rooms)
    (when (buffer-live-p (cdr entry))
      (kill-buffer (cdr entry))))
  (setq cmacs-libreclaw-cmacs-channel-rooms nil)
  (setq cmacs-libreclaw-rooms-alist nil))

(ert-deftest cmacs-libreclaw-cmacs-channel-project-detection ()
  "Room id is the absolute project root of the containing directory."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (let* ((parent (make-temp-file "cmacs-libreclaw-proj-" t))
         (sub    (expand-file-name "deep/nested" parent)))
    (unwind-protect
        (progn
          (make-directory sub t)
          ;; Plant a git marker so locate-dominating-file stops at parent.
          (make-directory (expand-file-name ".git" parent))
          (let ((room-id (cmacs-libreclaw-cmacs-channel--room-id sub)))
            (should (equal (file-name-as-directory room-id)
                           (file-name-as-directory parent)))))
      (when (file-directory-p parent) (delete-directory parent t)))))

(ert-deftest cmacs-libreclaw-cmacs-channel-history-file-is-stable ()
  "Two calls with the same room-id return the same persistence path."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (let ((cmacs-libreclaw-cmacs-channel-history-dir
         (make-temp-file "cmacs-libreclaw-hist-" t)))
    (unwind-protect
        (let ((a (cmacs-libreclaw-cmacs-channel--history-file "/x/y"))
              (b (cmacs-libreclaw-cmacs-channel--history-file "/x/y"))
              (c (cmacs-libreclaw-cmacs-channel--history-file "/x/z")))
          (should (equal a b))
          (should-not (equal a c)))
      (delete-directory cmacs-libreclaw-cmacs-channel-history-dir t))))

(ert-deftest cmacs-libreclaw-cmacs-channel-multi-buffer-isolation ()
  "Two project directories get distinct buffers and messages don't cross over."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((hist-dir (make-temp-file "cmacs-libreclaw-iso-hist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir))
    (unwind-protect
        (progn
          (let* ((buf-a (cmacs-libreclaw-cmacs-channel--ensure-buffer
                         "/projects/alpha"))
                 (buf-b (cmacs-libreclaw-cmacs-channel--ensure-buffer
                         "/projects/bravo")))
            (should (buffer-live-p buf-a))
            (should (buffer-live-p buf-b))
            (should-not (eq buf-a buf-b))
            ;; Response into alpha should only affect alpha's buffer.
            (cmacs-libreclaw--on-cmacs-response
             "cmacs" "/projects/alpha"
             "alpha-bot-response" nil nil)
            (with-current-buffer buf-a
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "alpha-bot-response" nil t))))
            (with-current-buffer buf-b
              (should-not (save-excursion
                            (goto-char (point-min))
                            (re-search-forward "alpha-bot-response" nil t))))
            ;; Response into bravo should only affect bravo.
            (cmacs-libreclaw--on-cmacs-response
             "cmacs" "/projects/bravo"
             "bravo-bot-response" nil nil)
            (with-current-buffer buf-b
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "bravo-bot-response" nil t))))
            (with-current-buffer buf-a
              (should-not (save-excursion
                            (goto-char (point-min))
                            (re-search-forward "bravo-bot-response" nil t))))))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p hist-dir)
        (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-cmacs-channel-persistence-round-trip ()
  "History written on kill is restored on reopen."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((hist-dir (make-temp-file "cmacs-libreclaw-persist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir)
         (cmacs-libreclaw-cmacs-channel-autosave-history t)
         (room "/persist/target"))
    (unwind-protect
        (progn
          ;; First buffer: receive a response, kill it.
          (let ((buf1 (cmacs-libreclaw-cmacs-channel--ensure-buffer room)))
            (cmacs-libreclaw--on-cmacs-response
             "cmacs" room "persisted-line" nil nil)
            (with-current-buffer buf1
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "persisted-line" nil t))))
            (kill-buffer buf1))
          ;; History file should have been written.
          (let ((file (cmacs-libreclaw-cmacs-channel--history-file room)))
            (should (file-readable-p file))
            (should (with-temp-buffer
                      (insert-file-contents file)
                      (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "persisted-line" nil t)))))
          ;; Second open should restore the history.
          (let ((buf2 (cmacs-libreclaw-cmacs-channel--ensure-buffer room)))
            (with-current-buffer buf2
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "persisted-line" nil t))))
            (kill-buffer buf2)))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p hist-dir)
        (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-cmacs-channel-room-mode-inherits ()
  "The channel room mode is derived from cmacs-libreclaw-room-mode."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((hist-dir (make-temp-file "cmacs-libreclaw-inherit-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir))
    (unwind-protect
        (let ((buf (cmacs-libreclaw-cmacs-channel--ensure-buffer
                    "/projects/mode-test")))
          (with-current-buffer buf
            (should (derived-mode-p 'cmacs-libreclaw-cmacs-channel-room-mode))
            (should (derived-mode-p 'cmacs-libreclaw-room-mode))
            (should (derived-mode-p 'org-mode))
            (should (equal cmacs-libreclaw-room-channel "cmacs"))
            (should (equal cmacs-libreclaw-cmacs-channel-room-id
                           "/projects/mode-test"))))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p hist-dir)
        (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-start-stop-restart-cycle ()
  "Regression guard: start -> stop -> start must work in the same
Emacs session.  Podomation's PodModuleManager has no unregister
API, so the bridge module persists across stops — the second
start has to look it up by name rather than re-register, or
`cmacs_libreclaw' collides in the manager's hash table."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (let* ((ws (make-temp-file "cmacs-libreclaw-cycle-" t))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-generate-default-config ws 'claude t)
          (cmacs-podomation-start)
          ;; Cycle 1
          (cmacs-libreclaw--start-internal)
          (should (cmacs-libreclaw-running-p))
          (should (member "cmacs_libreclaw"
                          (cmacs-podomation-list-modules)))
          (cmacs-libreclaw-stop)
          (should-not (cmacs-libreclaw-running-p))
          ;; Cycle 2 — this is the regression.  Must NOT signal
          ;; "Failed to register cmacs_libreclaw pod module".
          (cmacs-libreclaw--start-internal)
          (should (cmacs-libreclaw-running-p))
          ;; The module should still be the single registration
          ;; we already had — not duplicated.
          (should (= 1 (cl-count "cmacs_libreclaw"
                                 (cmacs-podomation-list-modules)
                                 :test #'string=)))
          (cmacs-libreclaw-stop)
          ;; Cycle 3 for good measure.
          (cmacs-libreclaw--start-internal)
          (should (cmacs-libreclaw-running-p))
          (cmacs-libreclaw-stop))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (when (file-directory-p ws) (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-default-config-writes-emacs-preamble ()
  "`cmacs-libreclaw-generate-default-config' must drop the
CMACS_EMACS_CHANNEL.md preamble next to config.yaml and list it
in agent.identity_files.  The preamble's job is to tell the AI
to use org formatting and start headings at `***'; if it's
missing, responses will break the buffer's structural layout."
  (skip-unless (fboundp 'cmacs-libreclaw-generate-default-config))
  (let* ((ws (make-temp-file "cmacs-libreclaw-preamble-" t))
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (let ((path (cmacs-libreclaw-generate-default-config
                     ws 'claude t)))
          (should (stringp path))
          ;; Preamble file exists in the workspace.
          (let ((preamble (expand-file-name "CMACS_EMACS_CHANNEL.md" ws)))
            (should (file-readable-p preamble))
            (let ((contents (with-temp-buffer
                              (insert-file-contents preamble)
                              (buffer-string))))
              (should (string-match-p "Emacs" contents))
              (should (string-match-p "org-mode" contents))
              (should (string-match-p "level 3" contents))
              (should (string-match-p "\\*\\*\\*" contents))))
          ;; YAML references the preamble in agent.identity_files.
          (let ((yaml (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string))))
            (should (string-match-p "^  identity_files:" yaml))
            (should (string-match-p "- CMACS_EMACS_CHANNEL.md" yaml))))
      (when (file-directory-p ws) (delete-directory ws t)))))

(ert-deftest cmacs-libreclaw-hatch-preamble-coexists-with-identity ()
  "The preamble and an explicit identity file both land in the
generated YAML's agent.identity_files list."
  (skip-unless (fboundp 'cmacs-libreclaw-hatch-include-emacs-preamble))
  (let* ((ws (make-temp-file "cmacs-libreclaw-coexist-" t))
         (soul (expand-file-name "my-soul.md"
                                  (make-temp-file "soul-" t))))
    (unwind-protect
        (let (h path)
          (with-temp-file soul (insert "# My soul\n"))
          (setq h (cmacs-libreclaw-hatch-new ws))
          (cmacs-libreclaw-hatch-set-name h "coexist")
          (cmacs-libreclaw-hatch-set-ai   h 'claude)
          (cmacs-libreclaw-hatch-add-cmacs h)
          (cmacs-libreclaw-hatch-set-identity h soul)
          (cmacs-libreclaw-hatch-include-emacs-preamble h)
          (setq path (cmacs-libreclaw-hatch-finalize h t))
          (cmacs-libreclaw-hatch-free h)
          ;; Both files written.
          (should (file-readable-p
                   (expand-file-name "SOUL.md" ws)))
          (should (file-readable-p
                   (expand-file-name "CMACS_EMACS_CHANNEL.md" ws)))
          ;; Both referenced in the generated YAML.
          (let ((yaml (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string))))
            (should (string-match-p "- CMACS_EMACS_CHANNEL.md" yaml))
            (should (string-match-p "- SOUL.md" yaml))))
      (when (file-directory-p ws) (delete-directory ws t))
      (when (and (file-exists-p soul)
                 (file-directory-p (file-name-directory soul)))
        (delete-directory (file-name-directory soul) t)))))

(ert-deftest cmacs-libreclaw-insert-heading-lands-in-messages ()
  "Inserted headings must live under `* Messages', not `* Compose'.
Regression guard for the bug where `--insert-heading' wrote at
the end of the Compose sentinel line, making the new `** ...'
entry a level-2 child of Compose.  The test walks the buffer as
an org tree via `org-element-parse-buffer' and asserts the
heading is nested under the Messages section."
  (skip-unless (featurep 'cmacs-libreclaw))
  (require 'cmacs-libreclaw-cmacs-channel)
  (require 'org-element)
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((hist-dir (make-temp-file "cmacs-libreclaw-place-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir))
    (unwind-protect
        (let ((buf (cmacs-libreclaw-cmacs-channel--ensure-buffer
                    "/projects/placement")))
          (cmacs-libreclaw--insert-heading
           buf "bob" "body-text-one" "2026-04-15 10:00:00")
          (cmacs-libreclaw--insert-heading
           buf "eve" "body-text-two" "2026-04-15 10:05:00")
          (with-current-buffer buf
            ;; Text check: both bodies appear and are above
            ;; the Compose sentinel.
            (save-excursion
              (goto-char (point-min))
              (should (re-search-forward "^body-text-one$" nil t))
              (should (re-search-forward "^body-text-two$" nil t))
              (should (re-search-forward "^\\* Compose" nil t)))
            ;; Positional check: Messages < headings < Compose.
            (let ((messages-pos
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward
                                    "^\\* Messages$" nil t)))
                  (heading-one-pos
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward
                                    "^\\*\\* 2026-04-15 10:00:00  bob$"
                                    nil t)))
                  (heading-two-pos
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward
                                    "^\\*\\* 2026-04-15 10:05:00  eve$"
                                    nil t)))
                  (compose-pos
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward
                                    "^\\* Compose" nil t))))
              (should (and messages-pos heading-one-pos
                           heading-two-pos compose-pos))
              (should (< messages-pos heading-one-pos))
              (should (< heading-one-pos heading-two-pos))
              (should (< heading-two-pos compose-pos)))
            ;; Org-element check: the heading's *parent* section
            ;; must be "Messages", not "Compose".
            (save-excursion
              (goto-char (point-min))
              (re-search-forward "^\\*\\* .+  bob$")
              (let* ((el (org-element-at-point))
                     (parent (org-element-lineage el '(headline) t)))
                ;; Walk up to the level-1 ancestor.
                (while (and parent
                            (> (org-element-property :level parent) 1))
                  (setq parent (org-element-property :parent parent)))
                (should parent)
                (should (equal
                         (org-element-property :raw-value parent)
                         "Messages")))))
          (kill-buffer buf))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p hist-dir)
        (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-agent-name-from-config ()
  "`cmacs-libreclaw-agent-name' reads `agent.name' from the running
LcApp's config and cmacs-libreclaw-cmacs-channel--bot-sender uses
it as the response heading sender."
  (skip-unless (fboundp 'cmacs-libreclaw-agent-name))
  (require 'cmacs-libreclaw-cmacs-channel)
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((ws (make-temp-file "cmacs-libreclaw-agent-" t))
         (hist-dir (make-temp-file "cmacs-libreclaw-agent-hist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir)
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-generate-default-config ws 'claude t)
          (cmacs-podomation-start)
          (cmacs-libreclaw--start-internal)
          ;; agent.name is derived from the workspace basename.
          (let ((name (cmacs-libreclaw-agent-name)))
            (should (stringp name))
            (should (string-match-p "^cmacs-libreclaw-agent-" name))
            (should (equal (cmacs-libreclaw-cmacs-channel--bot-sender)
                           name))
            ;; Inject a response and verify the heading uses the
            ;; agent name, not "libreclaw".
            (let ((buf (cmacs-libreclaw-cmacs-channel--ensure-buffer
                        "/projects/agent-name-test")))
              (cmacs-libreclaw--on-cmacs-response
               "cmacs" "/projects/agent-name-test"
               "response body" nil nil)
              (with-current-buffer buf
                (should (save-excursion
                          (goto-char (point-min))
                          (re-search-forward
                           (format "^\\*\\* .+  %s$"
                                   (regexp-quote name))
                           nil t)))
                (should-not (save-excursion
                              (goto-char (point-min))
                              (re-search-forward
                               "^\\*\\* .+  libreclaw$" nil t))))
              (kill-buffer buf)))
          (cmacs-libreclaw-stop))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p ws) (delete-directory ws t))
      (when (file-directory-p hist-dir) (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-agent-name-fallback ()
  "When libreclaw is not running, `cmacs-libreclaw-agent-name'
returns nil and the bot-sender helper falls back to
`cmacs-libreclaw-cmacs-channel-bot-name-fallback'."
  (skip-unless (fboundp 'cmacs-libreclaw-agent-name))
  (require 'cmacs-libreclaw-cmacs-channel)
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (should (null (cmacs-libreclaw-agent-name)))
  (let ((cmacs-libreclaw-cmacs-channel-bot-name-fallback "FALLBACK"))
    (should (equal (cmacs-libreclaw-cmacs-channel--bot-sender)
                   "FALLBACK"))))

(ert-deftest cmacs-libreclaw-cmacs-channel-bang-help-round-trip ()
  "Sending `!help' through the cmacs channel must hit libreclaw's
built-in command handler, get a response back through the channel
callback, and leave the buffer with the user's message FIRST and
the agent response SECOND — both under `* Messages'."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (require 'cmacs-libreclaw-cmacs-channel)
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((ws (make-temp-file "cmacs-libreclaw-help-" t))
         (hist-dir (make-temp-file "cmacs-libreclaw-help-hist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir)
         (cmacs-libreclaw-cmacs-channel-sender "testuser")
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-generate-default-config ws 'claude t)
          (cmacs-libreclaw-start)
          (let ((buf (cmacs-libreclaw-cmacs-channel--ensure-buffer
                      "/projects/help-test")))
            (with-current-buffer buf
              (goto-char (point-max))
              (let ((inhibit-read-only t)) (insert "!help"))
              (cmacs-libreclaw-cmacs-channel-send-compose)
              (let ((user-pos
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward
                        "^\\*\\* [0-9-]+ [0-9:]+  testuser$" nil t)))
                    (body-pos
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^!help$" nil t)))
                    (help-pos
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward
                        "^Available commands:" nil t)))
                    (compose-pos
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^\\* Compose" nil t))))
                ;; Every expected piece is present.
                (should user-pos)
                (should body-pos)
                (should help-pos)
                (should compose-pos)
                ;; And in the right order: user heading < !help
                ;; body < response body < Compose sentinel.
                (should (< user-pos body-pos))
                (should (< body-pos help-pos))
                (should (< help-pos compose-pos))
                ;; The user's body appears exactly once.
                (let ((n 0))
                  (save-excursion
                    (goto-char (point-min))
                    (while (re-search-forward "^!help$" nil t)
                      (cl-incf n)))
                  (should (= n 1)))))
            (kill-buffer buf))
          (cmacs-libreclaw-stop))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p ws) (delete-directory ws t))
      (when (file-directory-p hist-dir) (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-cmacs-channel-send-no-duplicate ()
  "Regression guard: `cmacs-libreclaw-cmacs-channel-send-compose'
must insert the user's message exactly once.  The message-received
signal dispatched by the C bridge already calls
`cmacs-libreclaw--insert-heading'; adding a local echo in the
Elisp send path duplicates the heading.  The test drives the send
path end-to-end with a running LcApp and asserts the body appears
exactly once in the resulting buffer."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (require 'cmacs-libreclaw-cmacs-channel)
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (let* ((ws (make-temp-file "cmacs-libreclaw-dup-" t))
         (hist-dir (make-temp-file "cmacs-libreclaw-dup-hist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir)
         (cmacs-libreclaw-cmacs-channel-sender "testuser")
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-generate-default-config ws 'claude t)
          (cmacs-podomation-start)
          (cmacs-libreclaw--start-internal)
          (let* ((room "/projects/send-dup")
                 (buf (cmacs-libreclaw-cmacs-channel--ensure-buffer room)))
            (with-current-buffer buf
              ;; Type a body into the compose region.
              (goto-char (point-max))
              (let ((inhibit-read-only t))
                (insert "hello from the dup test"))
              ;; Send.
              (cmacs-libreclaw-cmacs-channel-send-compose)
              ;; The body should appear EXACTLY once as a heading
              ;; body in the history section.  Count occurrences.
              (let ((count 0))
                (save-excursion
                  (goto-char (point-min))
                  (while (re-search-forward
                          "^hello from the dup test$" nil t)
                    (cl-incf count)))
                (should (= count 1)))
              ;; And the compose region should be empty now.
              (should (= (marker-position
                          cmacs-libreclaw-room--compose-marker)
                         (point-max))))
            (kill-buffer buf))
          (cmacs-libreclaw-stop))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p ws) (delete-directory ws t))
      (when (file-directory-p hist-dir) (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-cmacs-channel-end-to-end ()
  "Full stack: generate default config, start libreclaw, verify the
cmacs channel is bound, inject a fake response, verify it lands in
a project buffer, stop cleanly."
  (skip-unless (fboundp 'cmacs-libreclaw--start-internal))
  (skip-unless (fboundp 'cmacs-libreclaw-cmacs-channel-available-p))
  (require 'cmacs-libreclaw-cmacs-channel)
  (cmacs-libreclaw-tests--cmacs-channel-reset)
  (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
  (when (and (fboundp 'cmacs-podomation-running-p)
             (cmacs-podomation-running-p))
    (cmacs-podomation-stop))
  (let* ((ws (make-temp-file "cmacs-libreclaw-e2e-" t))
         (hist-dir (make-temp-file "cmacs-libreclaw-e2e-hist-" t))
         (cmacs-libreclaw-cmacs-channel-history-dir hist-dir)
         (cmacs-libreclaw-config-file nil))
    (unwind-protect
        (progn
          (cmacs-libreclaw-generate-default-config ws 'claude t)
          (cmacs-podomation-start)
          (cmacs-libreclaw--start-internal)
          (should (cmacs-libreclaw-running-p))
          (should (cmacs-libreclaw-cmacs-channel-available-p))
          ;; Verify the C-side channel shows up in the list tagged
          ;; with the `cmacs' kind symbol.
          (let ((channels (cmacs-libreclaw-list-channels)))
            (should (assoc "cmacs" channels))
            (should (eq (cdr (assoc "cmacs" channels)) 'cmacs)))
          ;; Exercise the Elisp open path.
          (let* ((room "/e2e/project")
                 (buf (cmacs-libreclaw-cmacs-channel--ensure-buffer room)))
            (should (buffer-live-p buf))
            (should (cmacs-libreclaw-cmacs-channel-has-room-p room))
            ;; Simulate an incoming response from the cmacs channel.
            (cmacs-libreclaw--on-cmacs-response
             "cmacs" room "e2e-response-body" nil nil)
            (with-current-buffer buf
              (should (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "e2e-response-body" nil t)))))
          (cmacs-libreclaw-stop)
          (should-not (cmacs-libreclaw-running-p)))
      (when (cmacs-libreclaw-running-p) (cmacs-libreclaw-stop))
      (when (and (fboundp 'cmacs-podomation-running-p)
                 (cmacs-podomation-running-p))
        (cmacs-podomation-stop))
      (cmacs-libreclaw-tests--cmacs-channel-reset)
      (when (file-directory-p ws) (delete-directory ws t))
      (when (file-directory-p hist-dir) (delete-directory hist-dir t)))))

(ert-deftest cmacs-libreclaw-remote-stale-client-reconnect ()
  "Regression: calling `cmacs-libreclaw-remote--connect-internal'
a second time must not signal \"remote bridge already connected\"
when the first attempt never reached the CONNECTED state (e.g.
the WebSocket handshake failed or the server was unreachable).

Before the fix, `cmacs_bridge_client != NULL' was used as the
guard, so a stale client left by a failed connect would block
every subsequent connect attempt."
  (skip-unless (fboundp 'cmacs-libreclaw-remote--connect-internal))
  (unwind-protect
      (progn
        ;; Ensure clean state going in (idempotent — returns nil when
        ;; no client is set).
        (cmacs-libreclaw-remote-disconnect)
        ;; First attempt: deliberately bad URL — async connect will
        ;; fail but the C DEFUN returns t immediately after creating
        ;; the client.
        (cmacs-libreclaw-remote--connect-internal
         "ws://127.0.0.1:19999/api/v1/bridge"   ; nothing listening
         "dummy-token" nil nil nil)
        ;; Client object is now non-NULL but not yet CONNECTED.
        (should-not (cmacs-libreclaw-remote-connected-p))
        ;; Second attempt must NOT signal
        ;; "remote bridge already connected".  It should either
        ;; succeed (if somehow connected) or fail for a different
        ;; reason (transport error, auth, etc.) — the critical
        ;; invariant is that it does not signal the stale-client
        ;; error.
        (should-not
         (condition-case err
             (progn
               (cmacs-libreclaw-remote--connect-internal
                "ws://127.0.0.1:19999/api/v1/bridge"
                "dummy-token" nil nil nil)
               nil)
           (cmacs-libreclaw-error
            (string= (cadr err) "remote bridge already connected")))))
    ;; Always tear down — neither attempt reached CONNECTED, so a
    ;; guarded "if connected" cleanup would leak the stale client
    ;; into the next test.  `disconnect' is a no-op when no client
    ;; is set.
    (cmacs-libreclaw-remote-disconnect)))

;;;; Conversation archiving ------------------------------------------

(ert-deftest cmacs-libreclaw-archive-writes-on-message ()
  "With a save dir set, an inbound message writes a .org archive file."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let* ((cmacs-libreclaw-rooms-alist nil)
         (dir (make-temp-file "cmacs-lc-archive" t)))
    (unwind-protect
        (let ((cmacs-libreclaw-save-conversations-dir dir))
          (cmacs-libreclaw--on-room-added "c" "r" "Room")
          (cmacs-libreclaw--on-message
           "c" "r"
           '(:channel-id "c" :sender-id "@bob:srv" :sender-name "Bob"
             :room-id "r" :body "hello world" :timestamp 0))
          (let ((files (directory-files dir nil "\\.org\\'")))
            (should (= 1 (length files)))
            ;; Default format: yymmdd-hhmmss-<agent-name>.org.  No
            ;; running LcApp, so the agent name falls back to the
            ;; room name "Room".
            (should (string-match-p
                     "\\`[0-9]\\{6\\}-[0-9]\\{6\\}-Room\\.org\\'"
                     (car files)))
            (with-temp-buffer
              (insert-file-contents (expand-file-name (car files) dir))
              (should (search-forward "hello world" nil t))
              ;; The editable compose region is excluded.
              (goto-char (point-min))
              (should-not (search-forward "* Compose" nil t)))))
      (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory dir t))))

(ert-deftest cmacs-libreclaw-archive-disabled-by-default ()
  "With no save dir set, no archive file is written."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let* ((cmacs-libreclaw-rooms-alist nil)
         (cmacs-libreclaw-save-conversations-dir nil)
         (dir (make-temp-file "cmacs-lc-noarchive" t)))
    (unwind-protect
        (progn
          (cmacs-libreclaw--on-room-added "c" "r" "Room")
          (cmacs-libreclaw--on-message
           "c" "r"
           '(:channel-id "c" :sender-id "s" :body "hi" :timestamp 0))
          (should (null (directory-files dir nil "\\.org\\'"))))
      (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory dir t))))

(ert-deftest cmacs-libreclaw-archive-name-format-token ()
  "The <agent-name> token is replaced and time directives expand."
  (skip-unless (featurep 'cmacs-libreclaw))
  (let* ((cmacs-libreclaw-rooms-alist nil)
         (dir (make-temp-file "cmacs-lc-archfmt" t)))
    (unwind-protect
        (let ((cmacs-libreclaw-save-conversations-dir dir)
              (cmacs-libreclaw-save-conversations-name-format
               "chat-%Y-<agent-name>.org"))
          (cmacs-libreclaw--on-room-added "c" "r" "Desk")
          (cmacs-libreclaw--on-message
           "c" "r"
           '(:channel-id "c" :sender-id "s" :body "x" :timestamp 0))
          (let ((files (directory-files dir nil "\\.org\\'")))
            (should (= 1 (length files)))
            (should (string-match-p
                     (concat "\\`chat-"
                             (format-time-string "%Y")
                             "-Desk\\.org\\'")
                     (car files)))))
      (let ((buf (cdr (assoc '("c" . "r") cmacs-libreclaw-rooms-alist))))
        (when (buffer-live-p buf) (kill-buffer buf)))
      (delete-directory dir t))))


;;;; Screen context on outgoing messages ---------------------------
;;
;; What rides the message and what appears in the room are deliberately
;; different, and they are separate statements in both send paths.
;; These tests are what keeps them from quietly converging.

(defmacro cmacs-libreclaw-tests--in-room (channel &rest body)
  "Run BODY in a throwaway room buffer on CHANNEL."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*lc-test-room*")))
     (unwind-protect
         (with-current-buffer buf
           (cmacs-libreclaw-room-mode)
           (setq-local cmacs-libreclaw-room-channel ,channel)
           (setq-local cmacs-libreclaw-room-id "room")
           (setq-local cmacs-libreclaw-room--view nil)
           (setq-local cmacs-libreclaw-room--hinted nil)
           ,@body)
       (kill-buffer buf))))

(ert-deftest cmacs-libreclaw-outgoing-body-carries-the-screen ()
  "The agent is told what is on screen; the room is not."
  (skip-unless (and (fboundp 'cmacs-libreclaw-room-mode)
                    (fboundp 'cmacs-ai-view-turn-block)))
  (cmacs-libreclaw-tests--in-room "cmacs"
    (let ((sent (cmacs-libreclaw--outgoing-body "what is this?")))
      (should (string-match-p "what is this?" sent))
      (should (string-match-p "on the user's screen" sent))
      ;; The user's own words survive intact and come last: what they
      ;; asked has to be the final thing before the model answers.
      (should (string-suffix-p "what is this?" sent)))))

(ert-deftest cmacs-libreclaw-standing-hint-rides-only-the-first-message ()
  "It is standing instruction, not per-turn preamble."
  (skip-unless (and (fboundp 'cmacs-libreclaw-room-mode)
                    (fboundp 'cmacs-ai-view-hint)))
  (cmacs-libreclaw-tests--in-room "cmacs"
    (should (string-match-p "not this conversation"
                            (cmacs-libreclaw--outgoing-body "one")))
    (should-not (string-match-p "not this conversation"
                                (cmacs-libreclaw--outgoing-body "two")))))

(ert-deftest cmacs-libreclaw-context-can-be-turned-off ()
  (skip-unless (fboundp 'cmacs-libreclaw-room-mode))
  (let ((cmacs-libreclaw-context-function nil))
    (cmacs-libreclaw-tests--in-room "cmacs"
      (should (equal "bare" (cmacs-libreclaw--outgoing-body "bare"))))))

(ert-deftest cmacs-libreclaw-context-failure-never-blocks-a-message ()
  "Context is a convenience.  Failing to build it must not eat a message
the user has already pressed C-c C-c on."
  (skip-unless (fboundp 'cmacs-libreclaw-room-mode))
  (let ((cmacs-libreclaw-context-function
         (lambda () (error "deliberate"))))
    (cmacs-libreclaw-tests--in-room "cmacs"
      (should (equal "still sent" (cmacs-libreclaw--outgoing-body
                                   "still sent"))))))

(ert-deftest cmacs-libreclaw-other-channels-get-no-screen-context ()
  "A matrix room or a mailing list is other people, and what is on your
screen is none of their business.  The branch in
`cmacs-libreclaw-send-compose' is what enforces this."
  (skip-unless (fboundp 'cmacs-libreclaw-send-compose))
  (let (sent echoed)
    ;; `&rest': the byte compiler expands a call to a (3 . 5) subr out
    ;; to its full arity, so a compiled run hands this five arguments
    ;; where an interpreted one hands it three.  A fixed-arity stub
    ;; passes standalone and fails under `make check-cmacs'.
    (cl-letf (((symbol-function 'cmacs-libreclaw-send-message)
               (lambda (_c _r body &rest _) (setq sent body)))
              ((symbol-function 'cmacs-libreclaw--insert-heading)
               (lambda (_buf _sender body &rest _) (setq echoed body))))
      (cmacs-libreclaw-tests--in-room "matrix"
        (setq-local cmacs-libreclaw-room--compose-marker (point-max-marker))
        (goto-char (point-max))
        (insert "hello everyone")
        (cmacs-libreclaw-send-compose)))
    (should (equal "hello everyone" sent))
    (should (equal "hello everyone" echoed))))

(ert-deftest cmacs-libreclaw-bridge-sends-context-but-echoes-the-typing ()
  "Remote mode: the prelude goes over the bridge, the room shows what
you typed.  Two separate statements in one function, and the reason a
transcript of an agent conversation is still readable a week later."
  (skip-unless (and (fboundp 'cmacs-libreclaw-send-compose)
                    (fboundp 'cmacs-ai-view-turn-block)))
  (let (sent echoed)
    (cl-letf (((symbol-function 'cmacs-libreclaw-remote-connected-p)
               (lambda () t))
              ((symbol-function 'cmacs-libreclaw-remote-send-message)
               (lambda (_r body &rest _) (setq sent body)))
              ((symbol-function 'cmacs-libreclaw--insert-heading)
               (lambda (_buf _sender body &rest _) (setq echoed body))))
      (cmacs-libreclaw-tests--in-room "bridge"
        (setq-local cmacs-libreclaw-room--compose-marker (point-max-marker))
        (goto-char (point-max))
        (insert "review this")
        (cmacs-libreclaw-send-compose)))
    (should (string-match-p "on the user's screen" sent))
    (should (string-suffix-p "review this" sent))
    (should (equal "review this" echoed))))


;;;; History protection ---------------------------------------------

(ert-deftest cmacs-libreclaw-history-stays-protected-after-a-failed-edit ()
  "A room transcript survives being typed into, more than once.

Emacs CLEARS `before-change-functions' when a function on it signals, so
`cmacs-libreclaw--protect-history' on its own protects the buffer
exactly once: the first stray keypress above `* Compose' disarms it and
every edit after lands in the transcript.  `cmacs-libreclaw--seal-history'
adds a `read-only' text property, enforced in C and unclearable, and
re-arms the guard.

The repetition and the mid-message position are both load-bearing --
a single attempt at the edge passes against the broken version."
  (skip-unless (fboundp 'cmacs-libreclaw--init-room-buffer))
  (let ((buf (generate-new-buffer "*lc-protect*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libreclaw--init-room-buffer buf "c" "r" "Room")
          (cmacs-libreclaw--insert-heading buf "bob" "A-DELIVERED-MESSAGE"
                                           "2026-01-01 00:00:00")
          (dolist (_ '(1 2 3))
            (goto-char (point-min))
            (should-error (insert "x") :type 'text-read-only))
          ;; ... and inside the message, not only above it.
          (goto-char (point-min))
          (should (search-forward "A-DELIVERED-MESSAGE" nil t))
          (goto-char (- (point) 4))
          (should-error (insert "x") :type 'text-read-only)
          ;; The compose region is still the user's.
          (goto-char (point-max))
          (insert "my reply")
          (should (string-suffix-p "my reply" (buffer-string)))
          (should (memq 'cmacs-libreclaw--protect-history
                        before-change-functions)))
      (kill-buffer buf))))


(ert-deftest cmacs-libreclaw-commands-are-sent-exactly-as-typed ()
  "A bot command gets no screen-context prelude in front of it.

libreclaw dispatches on the FIRST CHARACTER of the body
\(`cmd_body[0] == \='!\='\=' in lc-app.c\), so anything prepended stops
`!help\=' being a command and delivers it to the model as prose.  The
symptom is a command that silently does nothing, which is why this is
asserted on the wire rather than through the round-trip test alone."
  (skip-unless (and (fboundp 'cmacs-libreclaw-room-mode)
                    (fboundp 'cmacs-ai-view-turn-block)))
  (cmacs-libreclaw-tests--in-room "cmacs"
    (dolist (command '("!help" "!close_session" "  !help with spaces"))
      (should (equal command (cmacs-libreclaw--outgoing-body command))))
    ;; ... and an ordinary message still gets it.
    (let ((sent (cmacs-libreclaw--outgoing-body "what is this?")))
      (should (string-match-p "on the user's screen" sent)))))

(ert-deftest cmacs-libreclaw-a-command-does-not-consume-the-hint ()
  "Opening a room with `!help\=' must not spend the standing hint on a
message that never carried it."
  (skip-unless (and (fboundp 'cmacs-libreclaw-room-mode)
                    (fboundp 'cmacs-ai-view-hint)))
  (cmacs-libreclaw-tests--in-room "cmacs"
    (cmacs-libreclaw--outgoing-body "!help")
    (should-not cmacs-libreclaw-room--hinted)
    (should (string-match-p "not this conversation"
                            (cmacs-libreclaw--outgoing-body "now a question")))))

(provide 'cmacs-libreclaw-tests)

;;; cmacs-libreclaw-tests.el ends here
