;;; cmacs-gowl-dashboard.el --- WM config dashboard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Interactive Org-based dashboard for gowl compositor configuration.
;; Slider widgets bound to compositor properties (mfact, nmaster,
;; border-width, repeat-rate, etc.) update the running compositor
;; in real time.
;;
;; Usage:
;;   M-x cmacs-gowl-dashboard
;;
;; The dashboard uses org-ex widgets with `:gowl-property' extensions
;; for bidirectional binding.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-gowl-dashboard nil
  "WM configuration dashboard."
  :group 'cmacs
  :prefix "cmacs-gowl-dashboard-")

(defvar cmacs-gowl-dashboard--property-setters
  '(("mfact"        . cmacs-gowl-dashboard--set-mfact)
    ("nmaster"       . cmacs-gowl-dashboard--set-nmaster)
    ("border-width"  . cmacs-gowl-dashboard--set-border-width)
    ("repeat-rate"   . cmacs-gowl-dashboard--set-repeat-rate)
    ("repeat-delay"  . cmacs-gowl-dashboard--set-repeat-delay))
  "Alist mapping gowl property names to setter functions.")

(defun cmacs-gowl-dashboard--set-mfact (value)
  "Set mfact to VALUE (float 0.05-0.95)."
  (gowl-set-mfact (/ value 100.0)))

(defun cmacs-gowl-dashboard--set-nmaster (value)
  "Set nmaster to VALUE (integer)."
  (gowl-set-nmaster (round value)))

(defun cmacs-gowl-dashboard--set-border-width (value)
  "Set border width to VALUE pixels via config object."
  (gobject-set (gowl-config-object) "border-width" (round value)))

(defun cmacs-gowl-dashboard--set-repeat-rate (value)
  "Set keyboard repeat rate to VALUE keys/sec."
  (gowl-set-keyboard-repeat-rate (round value)))

(defun cmacs-gowl-dashboard--set-repeat-delay (value)
  "Set keyboard repeat delay to VALUE ms."
  (gowl-set-keyboard-repeat-delay (round value)))

(defun cmacs-gowl-dashboard--apply-property (prop-name value)
  "Apply VALUE to the gowl property PROP-NAME."
  (let ((setter (cdr (assoc prop-name
                             cmacs-gowl-dashboard--property-setters))))
    (when setter
      (funcall setter value))))

(defun cmacs-gowl-dashboard-config-file ()
  "Return the path this dashboard saves the gowl config to.
`$XDG_CONFIG_HOME/gowl/config.yaml', or `~/.config/gowl/config.yaml'
when that variable is unset.

The gowl/ component is not optional: an earlier version passed
XDG_CONFIG_HOME straight to `expand-file-name' as the directory, so
with the variable set --- which is the usual case --- the config
landed at ~/.config/config.yaml, where gowl does not look for it."
  (expand-file-name
   "gowl/config.yaml"
   (or (getenv "XDG_CONFIG_HOME") (expand-file-name "~/.config"))))

(defun cmacs-gowl-dashboard-save-yaml ()
  "Save the current compositor config as YAML."
  (interactive)
  (let ((yaml (gowl-config-generate-yaml)))
    (when yaml
      (let ((file (cmacs-gowl-dashboard-config-file)))
        (make-directory (file-name-directory file) t)
        (with-temp-file file
          (insert yaml))
        (message "Saved gowl config to %s" file)))))

;;;###autoload
(defun cmacs-gowl-dashboard ()
  "Open the gowl WM configuration dashboard.
Creates an Org buffer with interactive sliders for compositor
properties that update the running compositor in real time."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor not running"))
  (let ((buf (get-buffer-create "*gowl dashboard*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "#+TITLE: Gowl Dashboard\n")
        (insert "#+ORGEX: t\n\n")
        (insert "* Layout\n\n")
        (insert "** Master Factor\n\n")
        (insert "#+BEGIN_WIDGET slider\n")
        (insert ":min 5\n:max 95\n:value 55\n:step 5\n")
        (insert ":gowl-property mfact\n")
        (insert ":width 400\n:height 40\n")
        (insert "#+END_WIDGET\n\n")
        (insert "** Master Count\n\n")
        (insert "#+BEGIN_WIDGET slider\n")
        (insert ":min 1\n:max 5\n:value 1\n:step 1\n")
        (insert ":gowl-property nmaster\n")
        (insert ":width 400\n:height 40\n")
        (insert "#+END_WIDGET\n\n")
        (insert "* Appearance\n\n")
        (insert "** Border Width\n\n")
        (insert "#+BEGIN_WIDGET slider\n")
        (insert ":min 0\n:max 10\n:value 2\n:step 1\n")
        (insert ":gowl-property border-width\n")
        (insert ":width 400\n:height 40\n")
        (insert "#+END_WIDGET\n\n")
        (insert "* Input\n\n")
        (insert "** Repeat Rate (keys/sec)\n\n")
        (insert "#+BEGIN_WIDGET slider\n")
        (insert ":min 10\n:max 50\n:value 25\n:step 1\n")
        (insert ":gowl-property repeat-rate\n")
        (insert ":width 400\n:height 40\n")
        (insert "#+END_WIDGET\n\n")
        (insert "** Repeat Delay (ms)\n\n")
        (insert "#+BEGIN_WIDGET slider\n")
        (insert ":min 100\n:max 1000\n:value 600\n:step 50\n")
        (insert ":gowl-property repeat-delay\n")
        (insert ":width 400\n:height 40\n")
        (insert "#+END_WIDGET\n\n")
        (insert "* Actions\n\n")
        (insert "  - [[elisp:(cmacs-gowl-dashboard-save-yaml)][Save Config as YAML]]\n")
        (insert "  - [[elisp:(gowl-reload-config)][Reload Config]]\n"))
      (org-mode)
      (goto-char (point-min)))
    (switch-to-buffer buf)))

(provide 'cmacs-gowl-dashboard)
;;; cmacs-gowl-dashboard.el ends here
