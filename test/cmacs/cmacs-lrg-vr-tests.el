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
    (should (equal (lookup-key function-key-map [f25]) [vr-right-a]))
    (should (equal (lookup-key function-key-map [f29]) [vr-menu]))
    (should (equal (lookup-key function-key-map [f30]) [vr-left-stick])))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-right-a>")
              #'cmacs-lrg-vr-toggle-keyboard))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-left-y>")
              #'execute-extended-command))
  (should (eq (keymap-lookup cmacs-lrg-vr-mode-map "<vr-menu>")
              #'cmacs-lrg-vr-recenter-view)))

(ert-deftest cmacs-lrg-vr-commands-refuse-outside-vr ()
  "Interactive VR commands say why instead of failing obscurely."
  (skip-unless (and (cmacs-lrg-vr-tests--built-p)
                    (require 'cmacs-lrg-vr nil t)))
  (should-error (cmacs-lrg-vr-recenter-view) :type 'user-error)
  (should-error (cmacs-lrg-vr-toggle-keyboard) :type 'user-error)
  (should (stringp (cmacs-lrg-vr-describe))))

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
