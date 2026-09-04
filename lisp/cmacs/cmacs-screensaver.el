;;; cmacs-screensaver.el --- libregnum screensavers: wallpaper/lock/buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; User-facing layer for the cmacs screensaver subsystem: a table of named
;; configurations (`cmacs-screensaver-configs'), a completing-read picker, and
;; the commands that drive the three sinks:
;;
;;   `cmacs-screensaver-play'           -- play a config in an Emacs buffer
;;   `cmacs-screensaver-set-wallpaper'  -- animated gowl wallpaper
;;   `cmacs-screensaver-stop-wallpaper' -- back to the static wallpaper
;;
;; and the `gowl-lock' integration: when `cmacs-screensaver-lock-config' is
;; set, locking shows that config as an animated background with the password
;; box composited on top.
;;
;; Each config names a module (a key of `cmacs-screensaver-modules-alist' or an
;; absolute `.so' path) and a list of raw CLI-style argument strings passed
;; verbatim to the module -- so any current or future module flag works with no
;; changes here, and you can keep several variants of the same module (e.g.
;; multiple blackhole looks) and choose between them with the picker.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-screensaver nil
  "libregnum-rendered screensavers: animated wallpaper, lock screen, buffer."
  :group 'cmacs
  :prefix "cmacs-screensaver-")

(defcustom cmacs-screensaver-modules-alist
  '((blackhole   . "blackhole")
    (singularity . "singularity")
    (helios      . "helios"))
  "Alist mapping a module symbol to its `.so' base name.
The base name is resolved against `cmacs-screensaver-module-path'."
  :type '(alist :key-type symbol :value-type string)
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-configs
  '((default          . (:module blackhole   :args nil))
    (blackhole-warm   . (:module blackhole   :args ("--profile" "warm")))
    (blackhole-cool   . (:module blackhole   :args ("--profile" "cool" "--orbit-radius" "60" "--infall" "2")))
    (blackhole-infall . (:module blackhole   :args ("--profile" "cool" "--infall" "8")))
    ;; The look behind the second-brain graph: pulled far back, so it is
    ;; mostly dark field with a small blue-white disc.
    (blackhole-cool-orbit
     . (:module blackhole
        :args ("--profile" "cool" "--orbit-radius" "60" "--infall" "2")))
    (helios-trinary   . (:module helios       :args ("--stars" "3" "--profile" "golden"))))
  "Named screensaver configurations.
Each entry is (NAME . PLIST) where PLIST understands:
  :module  a key of `cmacs-screensaver-modules-alist', or an absolute
           path to a `.so' module built with LRG_DEFINE_GAME_MODULE.
  :args    a list of strings passed verbatim to the module as its
           CLI argument vector (the same flags the standalone saver
           accepts), e.g. (\"--profile\" \"warm\").
Add as many variants as you like and pick between them with the
screensaver commands."
  :type '(alist :key-type symbol
                :value-type
                (plist :value-type
                       (choice symbol string (repeat string))))
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-default-config 'default
  "Default config name from `cmacs-screensaver-configs'."
  :type 'symbol
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-fps 30
  "Target frames per second for the animated wallpaper/lock frame pump."
  :type 'integer
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-pause-when-covered t
  "When non-nil, stop rendering a monitor whose wallpaper is fully
covered by a fullscreen window (saves GPU/battery; the monitor resumes
when re-exposed)."
  :type 'boolean
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-wallpaper-config nil
  "Config used by `cmacs-screensaver-set-wallpaper' when called with no
argument.  nil means `cmacs-screensaver-default-config'."
  :type '(choice (const :tag "Use default" nil) symbol)
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-lock-config nil
  "When non-nil, `gowl-lock' shows this config as an animated lock-screen
background (password box and typing indicator composited on top).  nil
keeps the ordinary static lock screen."
  :type '(choice (const :tag "Static lock" nil) symbol)
  :group 'cmacs-screensaver)

(defcustom cmacs-screensaver-start-timeout 3
  "Seconds `cmacs-screensaver-set-wallpaper' waits for the render child to
report whether the module loaded, so a bad module errors synchronously.
On timeout the wallpaper still starts asynchronously."
  :type 'integer
  :group 'cmacs-screensaver
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'cmacs-screensaver--set-start-timeout)
           (cmacs-screensaver--set-start-timeout (* 1000 (max 1 val))))))

;; ---------------------------------------------------------------------------
;; C primitives
;; ---------------------------------------------------------------------------

(declare-function cmacs-screensaver-supported-p
                  "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--installed-module-dir
                  "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--start-wallpaper
                  "cmacs-screensaver-defuns.c"
                  (so-path &optional argv fps pause-covered))
(declare-function cmacs-screensaver--attach-background
                  "cmacs-screensaver-defuns")
(declare-function cmacs-screensaver--detach-background
                  "cmacs-screensaver-defuns")
(declare-function cmacs-screensaver--background-resize
                  "cmacs-screensaver-defuns")
(declare-function cmacs-screensaver--stop-wallpaper
                  "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--start-lock-bg
                  "cmacs-screensaver-defuns.c" (so-path &optional argv fps))
(declare-function cmacs-screensaver--stop-lock-bg
                  "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--status "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--restart "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--pause "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--resume "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver--set-fps "cmacs-screensaver-defuns.c" (fps))
(declare-function cmacs-screensaver--set-start-timeout
                  "cmacs-screensaver-defuns.c" (ms))
(declare-function cmacs-libregnum-play "cmacs-libregnum" (module &optional argv))

(unless (fboundp 'cmacs-screensaver-supported-p)
  ;; Fallback so this file loads in a build WITHOUT the C subsystem.  When the
  ;; subsystem is compiled in, the C primitive is already bound and must NOT be
  ;; shadowed by a defun, so this is guarded.
  (defun cmacs-screensaver-supported-p () nil))

;; ---------------------------------------------------------------------------
;; Module + config resolution
;; ---------------------------------------------------------------------------

(defun cmacs-screensaver-module-path ()
  "Return the directories searched for screensaver `.so' modules.
The dev override $CMACS_SCREENSAVER_MODULE_DIR comes first (so `just run'
uses freshly-built local modules), then the install directory."
  (delq nil
        (list (getenv "CMACS_SCREENSAVER_MODULE_DIR")
              (and (fboundp 'cmacs-screensaver--installed-module-dir)
                   (cmacs-screensaver--installed-module-dir)))))

(defun cmacs-screensaver--resolve-module (module)
  "Resolve MODULE to an absolute `.so' path.
MODULE may be a symbol key of `cmacs-screensaver-modules-alist', a bare
base name, or an absolute path.  Signal a `user-error' if not found."
  (cond
   ((and (stringp module) (file-name-absolute-p module))
    (if (file-exists-p module)
        module
      (user-error "Screensaver module not found: %s" module)))
   (t
    (let* ((base (cond ((symbolp module)
                        (or (cdr (assq module cmacs-screensaver-modules-alist))
                            (symbol-name module)))
                       (t module)))
           (file (if (string-suffix-p ".so" base) base (concat base ".so")))
           (dirs (cmacs-screensaver-module-path)))
      (or (cl-some (lambda (dir)
                     (let ((p (expand-file-name file dir)))
                       (and (file-exists-p p) p)))
                   dirs)
          (user-error "Screensaver module `%s' not found in %S" file dirs))))))

(defun cmacs-screensaver--config (name)
  "Return the plist for config NAME or signal a `user-error'."
  (or (cdr (assq name cmacs-screensaver-configs))
      (user-error "Unknown screensaver config: %s" name)))

(defun cmacs-screensaver--resolve-config (name)
  "Return (SO-PATH . ARGV) for config NAME."
  (let ((plist (cmacs-screensaver--config name)))
    (cons (cmacs-screensaver--resolve-module (plist-get plist :module))
          (plist-get plist :args))))

(defun cmacs-screensaver-read-config (&optional prompt)
  "Read a screensaver config name with completion."
  (intern
   (completing-read
    (or prompt "Screensaver config: ")
    (mapcar (lambda (e) (symbol-name (car e))) cmacs-screensaver-configs)
    nil t nil nil
    (symbol-name cmacs-screensaver-default-config))))

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

;;;###autoload
(defun cmacs-screensaver-play (name)
  "Play screensaver config NAME in an Emacs buffer."
  (interactive (list (cmacs-screensaver-read-config "Play screensaver: ")))
  (pcase-let ((`(,so . ,argv) (cmacs-screensaver--resolve-config name)))
    (cmacs-libregnum-play so argv)))

;;;###autoload
(defun cmacs-screensaver-set-wallpaper (name)
  "Set the animated gowl wallpaper to screensaver config NAME."
  (interactive
   (list (cmacs-screensaver-read-config "Wallpaper screensaver: ")))
  (unless (cmacs-screensaver-supported-p)
    (user-error "Screensaver wallpaper needs --with-cmacs-screensaver and --gowl"))
  (pcase-let ((`(,so . ,argv) (cmacs-screensaver--resolve-config name)))
    (cmacs-screensaver--start-wallpaper
     so argv cmacs-screensaver-fps cmacs-screensaver-pause-when-covered))
  (message "Animated wallpaper: %s" name))

;;;###autoload
(defun cmacs-screensaver-stop-wallpaper ()
  "Stop the animated wallpaper, restoring the static wallpaper."
  (interactive)
  (when (fboundp 'cmacs-screensaver--stop-wallpaper)
    (cmacs-screensaver--stop-wallpaper))
  (message "Animated wallpaper stopped"))

;; ---------------------------------------------------------------------------
;; Out-of-process renderer control
;; ---------------------------------------------------------------------------

;;;###autoload
(defun cmacs-screensaver-status ()
  "Return (and, interactively, echo) the render child's status plist.
Keys: :running :pid :fps :paused :gave-up :targets :wallpaper :lock
:last-error."
  (interactive)
  (let ((st (and (fboundp 'cmacs-screensaver--status)
                 (cmacs-screensaver--status))))
    (when (called-interactively-p 'interactive)
      (if (null st)
          (message "Screensaver renderer: unsupported in this build")
        (message "Screensaver renderer: %s%s pid=%s fps=%s targets=%s%s"
                 (if (plist-get st :running) "running" "stopped")
                 (cond ((plist-get st :paused) " (paused)")
                       ((plist-get st :gave-up) " (gave up)")
                       (t ""))
                 (plist-get st :pid) (plist-get st :fps)
                 (plist-get st :targets)
                 (if (plist-get st :last-error)
                     (format " err=%s" (plist-get st :last-error)) ""))))
    st))

(defun cmacs-screensaver-last-error ()
  "Return the render child's last error string, or nil."
  (plist-get (cmacs-screensaver-status) :last-error))

;;;###autoload
(defun cmacs-screensaver-restart ()
  "Kill and respawn the render child, re-applying the active sessions."
  (interactive)
  (unless (cmacs-screensaver-supported-p)
    (user-error "Screensaver renderer not available in this build"))
  (cmacs-screensaver--restart)
  (message "Screensaver renderer restarted"))

;;;###autoload
(defun cmacs-screensaver-pause ()
  "Pause the animated wallpaper/lock rendering (the child stops drawing)."
  (interactive)
  (when (fboundp 'cmacs-screensaver--pause)
    (cmacs-screensaver--pause))
  (message "Screensaver rendering paused"))

;;;###autoload
(defun cmacs-screensaver-resume ()
  "Resume the animated wallpaper/lock rendering after a pause."
  (interactive)
  (when (fboundp 'cmacs-screensaver--resume)
    (cmacs-screensaver--resume))
  (message "Screensaver rendering resumed"))

;;;###autoload
(defun cmacs-screensaver-set-fps (fps)
  "Set the animated wallpaper/lock target frame rate to FPS (1..240)."
  (interactive (list (read-number "Screensaver FPS: " cmacs-screensaver-fps)))
  (unless (and (integerp fps) (> fps 0))
    (user-error "FPS must be a positive integer"))
  (setq cmacs-screensaver-fps (min 240 fps))
  (when (fboundp 'cmacs-screensaver--set-fps)
    (cmacs-screensaver--set-fps cmacs-screensaver-fps))
  (message "Screensaver FPS: %d" cmacs-screensaver-fps))

;; ---------------------------------------------------------------------------
;; gowl-lock integration
;; ---------------------------------------------------------------------------

(defun cmacs-screensaver--maybe-start-lock-bg (&rest _)
  "Start the animated lock background if `cmacs-screensaver-lock-config' is set.
Used as `:before' advice on `gowl-lock' so the lock frames exist before
the lock engages (the password surface then renders transparently over
them).  Failure is non-fatal: locking falls back to the static screen.
The frame pump auto-stops this session when the compositor unlocks."
  (when (and cmacs-screensaver-lock-config
             (fboundp 'cmacs-screensaver-supported-p)
             (cmacs-screensaver-supported-p))
    (condition-case err
        (pcase-let ((`(,so . ,argv)
                     (cmacs-screensaver--resolve-config
                      cmacs-screensaver-lock-config)))
          (cmacs-screensaver--start-lock-bg so argv cmacs-screensaver-fps))
      (error
       (message "cmacs-screensaver: lock background failed: %s"
                (error-message-string err))))))

(when (fboundp 'gowl-lock)
  (advice-add 'gowl-lock :before #'cmacs-screensaver--maybe-start-lock-bg))

;;;; Screensaver as a libregnum scene background ----------------------

;; The frames come from the same out-of-process renderer the animated
;; wallpaper uses -- none of the screensaver's GL runs on Emacs's thread
;; -- and the TEXTURE sink needs no gowl, so this works in a plain pgtk
;; Emacs.  libregnum itself knows nothing about screensavers: it takes a
;; generic frame-source function pointer, and the C half of this file is
;; the only place that sees both subsystems.

;;;###autoload
(defun cmacs-screensaver-attach-background (buffer name width height)
  "Render screensaver config NAME behind BUFFER's libregnum scene.
WIDTH and HEIGHT are the frame size, normally the viewport's."
  (pcase-let ((`(,so . ,argv) (cmacs-screensaver--resolve-config name)))
    (cmacs-screensaver--attach-background buffer so width height argv
                                          cmacs-screensaver-fps)))

;;;###autoload
(defun cmacs-screensaver-detach-background (buffer)
  "Stop the screensaver background in BUFFER."
  (cmacs-screensaver--detach-background buffer))

;;;###autoload
(defun cmacs-screensaver-background-resize (width height)
  "Re-render the screensaver background at WIDTH x HEIGHT."
  (cmacs-screensaver--background-resize width height))

(provide 'cmacs-screensaver)
;;; cmacs-screensaver.el ends here
