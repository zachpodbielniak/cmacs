;;; cmacs-lrg-vr-tests.el --- Tests for --lrg=3dvr (VR) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The headset path itself needs an OpenXR runtime and a GL context, which a
;; batch run has neither of; these tests cover what does not: the feature
;; flag, the primitives' behaviour while inactive, option validation, the
;; Lisp controller bindings, and the Steam-shortcut writer end to end against
;; a scratch HOME.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst cmacs-lrg-vr-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, captured at load.")

(defun cmacs-lrg-vr-tests--built-p ()
  (fboundp 'cmacs-lrg-vr-supported-p))

(ert-deftest cmacs-lrg-vr-feature-flag-matches-the-build ()
  "IS-CMACS-LRGVR is always bound and agrees with the primitives."
  (should (boundp 'IS-CMACS-LRGVR))
  (should (boundp 'is-cmacs-lrgvr))
  (should (eq (and IS-CMACS-LRGVR t) (and (cmacs-lrg-vr-tests--built-p) t)))
  (when IS-CMACS-LRGVR
    (should (memq 'lrgvr (cmacs-compiled-features)))))

(ert-deftest cmacs-lrg-vr-built-with-openxr ()
  "A --with-cmacs-lrgvr build has libregnum's OpenXR backend compiled in.
configure passes OPENXR=1 to the libregnum sub-make; if that flag were lost
the build would still link and VR would fail only at runtime."
  (skip-unless (cmacs-lrg-vr-tests--built-p))
  (should (cmacs-lrg-vr-supported-p)))

(ert-deftest cmacs-lrg-vr-inactive-in-batch ()
  "With no headset session the primitives answer nil or signal clearly."
  (skip-unless (cmacs-lrg-vr-tests--built-p))
  (should-not (cmacs-lrg-vr-active-p))
  (should-not (cmacs-lrg-vr-status))
  (should-not (cmacs-lrg-vr-pointed-window))
  (should-error (cmacs-lrg-vr-recenter))
  (should-error (cmacs-lrg-vr-keyboard))
  (should-error (cmacs-lrg-vr-set-scale 0.5))
  ;; Stopping when nothing runs is a no-op, not an error.
  (should-not (cmacs-lrg-vr-stop)))

(ert-deftest cmacs-lrg-vr-start-refuses-a-non-lrg-frame ()
  "VR attaches to a 3D lrg frame only."
  (skip-unless (cmacs-lrg-vr-tests--built-p))
  (should-error (cmacs-lrg-vr-start (selected-frame))))

(ert-deftest cmacs-lrg-vr-set-option-validates ()
  "Options take numbers where numbers are meant, and unknown keys are errors."
  (skip-unless (cmacs-lrg-vr-tests--built-p))
  (should (= 30 (cmacs-lrg-vr-set-option 'snap-degrees 30)))
  (should (= 1.5 (cmacs-lrg-vr-set-option 'move-speed 1.5)))
  (should (eq t (cmacs-lrg-vr-set-option 'haptics t)))
  (should (eq 'left (cmacs-lrg-vr-set-option 'move-hand 'left)))
  (should-error (cmacs-lrg-vr-set-option 'snap-degrees "thirty")
                :type 'wrong-type-argument)
  (should-error (cmacs-lrg-vr-set-option 'no-such-option 1)))

(ert-deftest cmacs-lrg-vr-mode-translates-the-buttons ()
  "The controller's F25..F30 become <vr-...> events bound in the mode map."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (let ((function-key-map (make-sparse-keymap)))
    (cmacs-lrg-vr--install-translations)
    (should (equal (lookup-key function-key-map [f25]) [vr-a]))
    (should (equal (lookup-key function-key-map [f29]) [vr-menu]))
    (should (equal (lookup-key function-key-map [f30]) [vr-left-stick])))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-a>")
              #'cmacs-lrg-vr-toggle-keyboard))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-y>")
              #'execute-extended-command))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-y-hold>")
              #'cmacs-lrg-vr-voice-command-hold))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-menu>")
              #'cmacs-lrg-vr-quick-menu))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-menu-hold>")
              #'cmacs-lrg-vr-recenter-view)))

(ert-deftest cmacs-lrg-vr-commands-refuse-outside-vr ()
  "Interactive VR commands say why instead of failing obscurely."
  (skip-unless (and (cmacs-lrg-vr-tests--built-p)
                    (require 'cmacs-lrg-vr nil t)))
  (should-error (cmacs-lrg-vr-recenter-view) :type 'user-error)
  (should-error (cmacs-lrg-vr-toggle-keyboard) :type 'user-error)
  (should (stringp (cmacs-lrg-vr-describe))))

;;;; Layers, holds and releases

(ert-deftest cmacs-lrg-vr-set-option-layer-modifiers ()
  "The modifier hand's layers take shift/meta/control/alt, not hyper/super."
  (skip-unless (cmacs-lrg-vr-tests--built-p))
  (should (eq 'shift (cmacs-lrg-vr-set-option 'mod-trigger 'shift)))
  (should (eq 'meta (cmacs-lrg-vr-set-option 'mod-bumper 'meta)))
  (should (eq 'auto (cmacs-lrg-vr-set-option 'mod-second-source 'auto)))
  ;; Alt is the second bank.
  (should-error (cmacs-lrg-vr-set-option 'mod-trigger 'alt))
  (should (eq 'control (cmacs-lrg-vr-set-option 'mod-both 'control)))
  (should (eq t (cmacs-lrg-vr-set-option 'modifier-hand t)))
  (should (= 0.35 (cmacs-lrg-vr-set-option 'hold-seconds 0.35)))
  (should (eq t (cmacs-lrg-vr-set-option 'dpad-arrows t)))
  ;; Hyper and super mark holds and releases.
  (should-error (cmacs-lrg-vr-set-option 'mod-grip 'hyper))
  (should-error (cmacs-lrg-vr-set-option 'mod-grip 'super))
  (should-error (cmacs-lrg-vr-set-option 'hold-seconds 10)
                :type 'args-out-of-range)
  (cmacs-lrg-vr-set-option 'mod-grip 'meta)
  (should-not (cmacs-lrg-vr-layer))
  (should-error (cmacs-lrg-vr-set-indicator 'left "red"))
  (should (equal "#ff3030" (cmacs-lrg-vr-set-indicator 'left "#ff3030")))
  (should-not (cmacs-lrg-vr-set-indicator 'left nil)))

(ert-deftest cmacs-lrg-vr-translations-cover-every-layer ()
  "Each button, in each layer, tap / hold / release, gets its name."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (let ((function-key-map (make-sparse-keymap))
        (cmacs-lrg-vr-mode-map (copy-keymap cmacs-lrg-vr-mode-map)))
    (cmacs-lrg-vr--install-translations)
    (should (equal (lookup-key function-key-map [f25]) [vr-a]))
    (should (equal (lookup-key function-key-map [H-f25]) [vr-a-hold]))
    (should (equal (lookup-key function-key-map [s-f25]) [vr-a-release]))
    (should (equal (lookup-key function-key-map [S-H-f28]) [S-vr-y-hold]))
    ;; The second bank: alt.
    (should (equal (lookup-key function-key-map [A-f25]) [vr-bumper]))
    (should (equal (lookup-key function-key-map [A-f27]) [vr-view]))
    (should (equal (lookup-key function-key-map [M-A-H-f30]) [M-vr-dpad-left-hold]))
    (should (equal (lookup-key function-key-map [A-s-f31]) [vr-dpad-right-release]))
    (should (equal (lookup-key function-key-map [C-s-f29]) [C-vr-menu-release]))
    (should (equal (lookup-key function-key-map [M-f33]) [M-vr-flick-right]))
    (should (equal (lookup-key function-key-map [f31]) [vr-right-stick]))
    ;; Releases always land somewhere; holds fall back to the tap.
    (should (eq (lookup-key cmacs-lrg-vr-mode-map [M-vr-b-release])
                #'cmacs-lrg-vr-button-released))
    (should (eq (lookup-key cmacs-lrg-vr-mode-map [M-vr-x-hold])
                #'cmacs-lrg-vr-hold-as-tap))
    ;; Explicit holds are kept.
    (should (eq (lookup-key cmacs-lrg-vr-mode-map [vr-a-hold])
                #'cmacs-lrg-vr-voice-dictate-hold))
    (should (eq (lookup-key cmacs-lrg-vr-mode-map [M-vr-b-hold])
                #'cmacs-lrg-vr-kill-buffer))))

(ert-deftest cmacs-lrg-vr-hold-without-binding-does-the-tap ()
  "A slow press of a button whose hold is unbound still does the tap."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (let* ((ran nil)
         (map (make-sparse-keymap)))
    (define-key map [S-vr-b] (lambda () (interactive) (setq ran 'tap)))
    (let ((minor-mode-overriding-map-alist `((cmacs-lrg-vr-mode . ,map)))
          (cmacs-lrg-vr-mode t)
          (last-command-event 'S-vr-b-hold))
      (cmacs-lrg-vr-hold-as-tap))
    (should (eq ran 'tap))))

(ert-deftest cmacs-lrg-vr-release-runs-what-the-hold-asked ()
  "A hold registers a release action; the release runs it once."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (let ((cmacs-lrg-vr--release-actions nil)
        (count 0))
    (let ((last-command-event 'M-vr-y-hold))
      (should (cmacs-lrg-vr-on-release (lambda () (cl-incf count)))))
    (let ((last-command-event 'M-vr-y-release))
      (cmacs-lrg-vr-button-released)
      (cmacs-lrg-vr-button-released))
    (should (= count 1))
    ;; Outside a hold there is nothing to register.
    (let ((last-command-event ?a))
      (should-not (cmacs-lrg-vr-on-release #'ignore)))))

;;;; Voice

(ert-deftest cmacs-lrg-vr-voice-normalizes-speech ()
  "Punctuation goes, case folds, and numbers after a keyword become digits."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (should (equal (cmacs-lrg-vr-voice--normalize "Workspace two.")
                 "workspace 2"))
  (should (equal (cmacs-lrg-vr-voice--normalize "Go to line Twelve!")
                 "go to line 12"))
  (should (equal (cmacs-lrg-vr-voice--normalize "Open two files")
                 "open two files"))
  (should (equal (cmacs-lrg-vr-voice--clean " [BLANK_AUDIO] hello  (music) world ")
                 "hello world")))

(ert-deftest cmacs-lrg-vr-voice-commands-dispatch ()
  "Spoken phrases reach the right function with their arguments."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (let (calls)
    (cl-letf (((symbol-function 'cmacs-lrg-vr-workspace-new)
               (lambda (&optional name) (push (list 'new name) calls)))
              ((symbol-function 'cmacs-lrg-vr-workspace-goto)
               (lambda (w) (push (list 'goto w) calls)))
              ((symbol-function 'cmacs-lrg-vr-split-right)
               (lambda () (interactive) (push '(split) calls))))
      (cmacs-lrg-vr-voice-run "New workspace called notes.")
      (cmacs-lrg-vr-voice-run "new workspace")
      (cmacs-lrg-vr-voice-run "Go to workspace three")
      (cmacs-lrg-vr-voice-run "Split window right"))
    (should (equal (reverse calls)
                   '((new "notes") (new nil) (goto "3") (split))))))

(ert-deftest cmacs-lrg-vr-voice-command-names-and-fallback ()
  "Unregistered phrases are tried as command names, then M-x."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (let ((ran nil))
    (cl-letf (((symbol-function 'cmacs-lrg-vr-test-command)
               (lambda () (interactive) (setq ran t))))
      (cmacs-lrg-vr-voice-run "cmacs lrg vr test command"))
    (should ran))
  (let ((cmacs-lrg-vr-voice-unmatched 'message))
    (should-not (cmacs-lrg-vr-voice-run "zzqx unknown phrase"))))

(ert-deftest cmacs-lrg-vr-voice-user-commands-win ()
  "A user's voice command is tried before the shipped ones."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (let ((cmacs-lrg-vr-voice-commands (copy-sequence cmacs-lrg-vr-voice-commands))
        (got nil))
    (cmacs-lrg-vr-define-voice-command "save\\(?: file\\)?"
                                       (lambda () (setq got 'mine)))
    (cmacs-lrg-vr-voice-run "Save file.")
    (should (eq got 'mine))))

(ert-deftest cmacs-lrg-vr-voice-dictation-fits-the-text ()
  "Dictation spaces itself from what is there and starts sentences capitalised."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (with-temp-buffer
    (insert "Hello")
    (cmacs-lrg-vr-voice-insert "world" (cmacs-lrg-vr-voice--target))
    (should (equal (buffer-string) "Hello world"))
    (insert ". ")
    (cmacs-lrg-vr-voice-insert "next one" (cmacs-lrg-vr-voice--target))
    (should (equal (buffer-string) "Hello world. Next one"))
    (goto-char (point-min))
    (cmacs-lrg-vr-voice-insert "well" (cmacs-lrg-vr-voice--target))
    (should (string-prefix-p "Well Hello" (buffer-string))))
  (with-temp-buffer
    (insert "x")
    (setq buffer-read-only t)
    (let ((kill-ring nil))
      (cmacs-lrg-vr-voice-insert "copied" (cmacs-lrg-vr-voice--target))
      (should (equal (car kill-ring) "copied"))
      (should (equal (buffer-string) "x")))))

(ert-deftest cmacs-lrg-vr-voice-results-run-as-commands ()
  "A transcription is queued to run from the command loop, never in the callback."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (let ((cmacs-lrg-vr--deferred nil)
        (unread-command-events nil)
        (got nil))
    (funcall (cmacs-lrg-vr-voice--finish (lambda (text) (setq got text)))
             '((:text . " [BLANK_AUDIO] split right ")))
    (should-not got)
    (should (equal unread-command-events '(cmacs-lrg-vr-deferred)))
    (should (eq (lookup-key cmacs-lrg-vr-mode-map [cmacs-lrg-vr-deferred])
                #'cmacs-lrg-vr--run-deferred))
    (cmacs-lrg-vr--run-deferred)
    (should (equal got "split right"))
    ;; Silence and errors queue nothing.
    (setq unread-command-events nil)
    (funcall (cmacs-lrg-vr-voice--finish #'ignore) '((:text . "[BLANK_AUDIO]")))
    (funcall (cmacs-lrg-vr-voice--finish #'ignore) '((:error . "boom")))
    (should-not unread-command-events)))

(ert-deftest cmacs-lrg-vr-says-when-steamvr-takes-the-controllers ()
  "Losing input focus to SteamVR's dashboard is announced, and so is its return."
  (skip-unless (require 'cmacs-lrg-vr-ui nil t))
  (let ((states '("focused" "visible" "visible" "focused"))
        (cmacs-lrg-vr-ui--last-state nil)
        (cmacs-lrg-vr-ui--focus-timer nil)
        (msgs nil))
    (cl-letf (((symbol-function 'cmacs-lrg-vr-active-now-p) (lambda () t))
              ((symbol-function 'cmacs-lrg-vr-status)
               (lambda () (list :state (pop states))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
      (dotimes (_ 4) (cmacs-lrg-vr-ui--watch-focus)))
    (setq msgs (nreverse msgs))
    (should (= (length msgs) 2))
    (should (string-search "Steam button" (car msgs)))
    (should (string-search "back" (cadr msgs)))))

;;;; The quick menu and help

(ert-deftest cmacs-lrg-vr-quick-menu-tree-indexes-leaves ()
  "The menu tree's leaf indices point at the right functions."
  (skip-unless (require 'cmacs-lrg-vr-ui nil t))
  (let* ((values (list nil))
         (tree (cmacs-lrg-vr--menu-tree
                '(("A" . a-fn) nil ("Sub" ("B" . b-fn) ("C" . c-fn)))
                values)))
    (should (equal tree '(("A" . 0) nil ("Sub" ("B" . 1) ("C" . 2)))))
    (should (equal (car values) '(a-fn b-fn c-fn))))
  ;; The real menu builds, and every leaf is callable.
  (let ((values (list nil)))
    (cmacs-lrg-vr--menu-tree (cmacs-lrg-vr--menu-spec) values)
    (should (> (length (car values)) 20))
    (should (cl-every #'functionp (car values)))))

(ert-deftest cmacs-lrg-vr-controller-help-lists-the-layers ()
  "The help sheet names the buttons, the layers and their commands."
  (skip-unless (require 'cmacs-lrg-vr-ui nil t))
  (save-window-excursion
    (cmacs-lrg-vr-controller-help)
    (with-current-buffer "*VR Controls*"
      (let ((s (buffer-string)))
        (should (string-search "D-pad = arrow keys" s))
        (should (string-search "pushes / pulls" s))
        (should (string-search "voice-dictate-hold" s))
        (should (string-search "shift layer" s))
        (should (string-search "workspace-new" s))))
    (kill-buffer "*VR Controls*")
    ;; With the D-pad as named events, it is listed button by button.
    (let ((cmacs-lrg-vr-dpad-arrows nil))
      (cmacs-lrg-vr-controller-help)
      (with-current-buffer "*VR Controls*"
        (should (string-search "D-pad left" (buffer-string))))
      (kill-buffer "*VR Controls*"))))

(ert-deftest cmacs-lrg-vr-controller-help-toggles ()
  "The help button shows the sheet, and the same button hides it."
  (skip-unless (require 'cmacs-lrg-vr-ui nil t))
  (save-window-excursion
    (delete-other-windows)
    (cmacs-lrg-vr-controller-help)
    (should (get-buffer-window "*VR Controls*"))
    (should (string-search "Meta held + x"
                           (with-current-buffer "*VR Controls*"
                             (buffer-string))))
    (cmacs-lrg-vr-controller-help)
    (should-not (get-buffer-window "*VR Controls*"))
    (should (one-window-p t))
    (cmacs-lrg-vr-controller-help)
    (should (get-buffer-window "*VR Controls*"))
    (kill-buffer "*VR Controls*")))

(ert-deftest cmacs-lrg-vr-close-window ()
  "Closing removes the cursor's window, but never the frame's last one."
  (skip-unless (require 'cmacs-lrg-vr-ui nil t))
  (save-window-excursion
    (delete-other-windows)
    (let ((home (selected-window)))
      (select-window (split-window-right))
      (cmacs-lrg-vr-close-window)
      (should (one-window-p t))
      (should (eq (selected-window) home))
      (cmacs-lrg-vr-close-window)
      (should (window-live-p home))))
  (should (eq (lookup-key cmacs-lrg-vr-mode-map [M-vr-b])
              'cmacs-lrg-vr-close-window))
  (should (eq (lookup-key cmacs-lrg-vr-mode-map [M-vr-b-hold])
              'cmacs-lrg-vr-kill-buffer)))

(ert-deftest cmacs-lrg-vr-every-bound-command-exists ()
  "Nothing in the VR keymap names a function that is not defined."
  (skip-unless (and (require 'cmacs-lrg-vr-ui nil t)
                    (require 'cmacs-lrg-vr-voice nil t)))
  (let (missing)
    (map-keymap
     (lambda (_ev def)
       (cond ((keymapp def)
              (map-keymap (lambda (_e d)
                            (when (and (symbolp d) d (not (fboundp d)))
                              (push d missing)))
                          def))
             ((and (symbolp def) def (not (fboundp def)))
              (push def missing))))
     cmacs-lrg-vr-mode-map)
    (should-not missing)))

;;;; The Steam shortcut (just steam-vr-shortcut)

(defun cmacs-lrg-vr-tests--python ()
  (executable-find "python3"))

(defun cmacs-lrg-vr-tests--run-shortcut (home &rest args)
  "Run the shortcut writer with HOME as the home directory; return (STATUS . OUT)."
  (let ((process-environment (cons (concat "HOME=" home) process-environment)))
    (with-temp-buffer
      (let ((status (apply #'call-process (cmacs-lrg-vr-tests--python) nil t nil
                           (expand-file-name "admin/cmacs-steam-shortcut.py"
                                             cmacs-lrg-vr-tests--root)
                           args)))
        (cons status (buffer-string))))))

(defun cmacs-lrg-vr-tests--fake-home ()
  "A scratch HOME with one Steam user and an exported emacs."
  (let* ((home (make-temp-file "cmacs-vr-home" t))
         (cfg (expand-file-name ".local/share/Steam/userdata/12345/config" home))
         (bin (expand-file-name "bin/export" home)))
    (make-directory cfg t)
    (make-directory bin t)
    (with-temp-file (expand-file-name "emacs" bin)
      (insert "#!/bin/sh\nexit 0\n"))
    (set-file-modes (expand-file-name "emacs" bin) #o755)
    home))

(ert-deftest cmacs-lrg-vr-steam-shortcut-creates-a-vr-entry ()
  "The writer adds an OpenVR entry that starts in HOME, plus its launcher."
  (skip-unless (cmacs-lrg-vr-tests--python))
  (let ((home (cmacs-lrg-vr-tests--fake-home)))
    (unwind-protect
        (let* ((res (cmacs-lrg-vr-tests--run-shortcut home))
               (vdf (expand-file-name
                     ".local/share/Steam/userdata/12345/config/shortcuts.vdf" home))
               (launcher (expand-file-name "bin/export/emacs-vr" home)))
          (should (= 0 (car res)))
          (should (file-exists-p vdf))
          (should (file-executable-p launcher))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally vdf)
            (let ((s (buffer-string)))
              (should (string-search "Emacs VR" s))
              (should (string-search (format "\"%s\"" launcher) s))
              (should (string-search (format "\"%s\"" home) s))
              ;; OpenVR = 1: type 0x02, key, little-endian int32 1.
              (should (string-search "\2OpenVR\0\1\0\0\0" s))))
          (with-temp-buffer
            (insert-file-contents launcher)
            (should (search-forward "cd \"${HOME}\"" nil t))
            (should (search-forward "--lrg=3dvr" nil t))))
      (delete-directory home t))))

(ert-deftest cmacs-lrg-vr-steam-shortcut-keeps-other-shortcuts ()
  "Rerunning updates in place, and existing entries survive byte for byte."
  (skip-unless (cmacs-lrg-vr-tests--python))
  (let* ((home (cmacs-lrg-vr-tests--fake-home))
         (vdf (expand-file-name
               ".local/share/Steam/userdata/12345/config/shortcuts.vdf" home))
         ;; A shortcut the user made: {"shortcuts" {"0" {"appname" "Other"}}}
         (other (concat "\0shortcuts\0" "\0000\0" "\1appname\0Other\0"
                        "\10" "\10" "\10")))
    (unwind-protect
        (progn
          (with-temp-file vdf
            (set-buffer-multibyte nil)
            (insert other))
          (should (= 0 (car (cmacs-lrg-vr-tests--run-shortcut home))))
          (should (= 0 (car (cmacs-lrg-vr-tests--run-shortcut home))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally vdf)
            (let ((s (buffer-string)))
              (should (string-search "\1appname\0Other\0" s))
              ;; Two runs, one entry.
              (should (= 1 (how-many "Emacs VR" (point-min) (point-max))))))
          (should (file-exists-p (concat vdf ".cmacs-bak")))
          (should (= 0 (car (cmacs-lrg-vr-tests--run-shortcut home "--remove"))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally vdf)
            (should-not (string-search "Emacs VR" (buffer-string)))
            (should (string-search "Other" (buffer-string)))))
      (delete-directory home t))))

(ert-deftest cmacs-lrg-vr-steam-shortcut-needs-the-export ()
  "Without the distrobox export there is nothing to launch: say so."
  (skip-unless (cmacs-lrg-vr-tests--python))
  (let ((home (cmacs-lrg-vr-tests--fake-home)))
    (unwind-protect
        (progn
          (delete-file (expand-file-name "bin/export/emacs" home))
          (let ((res (cmacs-lrg-vr-tests--run-shortcut home)))
            (should-not (= 0 (car res)))
            (should (string-search "just distrobox" (cdr res)))))
      (delete-directory home t))))

(provide 'cmacs-lrg-vr-tests)

;;; cmacs-lrg-vr-tests.el ends here
