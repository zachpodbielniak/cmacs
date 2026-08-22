;;; cmacs-ai-menu.el --- The universal AI right-click menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One right-click menu, everywhere, on every display backend.
;;
;; The pieces come from elsewhere: cmacs-ai-target.el works out what is
;; under the pointer, cmacs-ai-actions.el says what can be done with it,
;; and cmacs-menu.el knows how to draw a menu under pgtk (a real GTK
;; menu), under `emacs --lrg' (the in-engine libregnum menu) and on a
;; tty.  This file is the wiring: it puts one entry on
;; `context-menu-functions', binds a mouse button, and bootstraps itself.
;;
;; Two things about that wiring are worth knowing.
;;
;; `context-menu-mode' alone is not enough under --lrg.  Emacs routes
;; mouse-3 through `x-popup-menu', and the lrg backend's RIF
;; `menu_show_hook' deliberately returns "nothing selected" (a NULL hook
;; would crash menu.c, so it has to exist and do nothing).  A stock
;; `context-menu-mode' therefore does nothing at all in an --lrg frame.
;; So mouse-3 is bound to our own command, which builds exactly the same
;; `context-menu-map' and hands it to `cmacs-menu-popup-keymap' -- native
;; GTK where there is a toolkit, in-engine where there is not.
;;
;; And Doom leaves mouse-3 on `mouse-save-then-kill' with
;; `context-menu-mode' off, which silently swallows the whole feature.
;; cmacs-piper has carried a Doom-aware bootstrap for this for a while;
;; the detection now lives once in `cmacs-menu-claim-mouse-3', and both
;; call it.

;;; Code:

(require 'mouse)
(require 'menu-bar)
(require 'cmacs-menu)
(require 'cmacs-ai-target)
(require 'cmacs-ai-targets)
(require 'cmacs-ai-actions)
;; Registers the Mail group's actions.  Required here rather than left to
;; the user, since a group nobody loaded is a group that never appears.
(require 'cmacs-ai-mail)
(require 'cmacs-ai-git)
(require 'cmacs-ai-errors)
(require 'cmacs-ai-term)
(require 'cmacs-ai-notes)

(defgroup cmacs-ai-menu nil
  "The universal AI context menu."
  :group 'cmacs
  :prefix "cmacs-ai-menu-")

;;;###autoload
(defcustom cmacs-ai-menu-auto-enable t
  "When non-nil, install the AI context menu at startup.
Set to nil before init to opt out entirely; toggle later with
\\[cmacs-ai-menu-mode]."
  :type 'boolean)

(defcustom cmacs-ai-menu-label "AI"
  "Label of the single top-level entry the AI menu lives under.

Everything cmacs adds to the context menu hangs off this one item, so the
menu you already had grows by exactly one line however many actions are
registered."
  :type 'string)

(defcustom cmacs-ai-menu-inline-limit 5
  "Item count at or below which the group submenus are skipped.

A submenu holding two entries is a click you did not need.  When the
whole menu comes to this many items or fewer they are put directly under
the top-level \"AI\" entry, rather than inside \"Ask AI\" and friends."
  :type 'integer
  :safe #'integerp)

;;;; Building the menu -------------------------------------------------

(defun cmacs-ai-menu--item (action target)
  "A `menu-item' form running ACTION over TARGET."
  ;; ACTION and TARGET are re-bound per item by the caller: `dolist' keeps
  ;; ONE binding for its variable across iterations, so a closure made
  ;; inside the loop without this would capture the last action only.
  (let ((action action) (target target))
    `(menu-item ,(cmacs-ai-action-label action target)
                ,(lambda () (interactive) (cmacs-ai-action-run action target))
                :help ,(or (plist-get action :help) ""))))

(defun cmacs-ai-menu--group-keymap (group actions target)
  "A submenu keymap for GROUP holding ACTIONS over TARGET."
  (let ((sub (make-sparse-keymap (cmacs-ai-action-group-label group))))
    (dolist (action actions)
      ;; `define-key-after' so the registry's :order survives into the
      ;; rendered menu; plain `define-key' prepends and would reverse it.
      (define-key-after sub (vector (plist-get action :name))
        (cmacs-ai-menu--item action target)))
    sub))

(defun cmacs-ai-menu-populate (menu click)
  "Add the cmacs AI entries to context MENU for CLICK.

The function registered on `context-menu-functions'.  Returns MENU
unchanged when nothing here can act on what was clicked, which is the
normal outcome in a buffer with no AI build behind it.

Everything goes under ONE top-level entry, `cmacs-ai-menu-label'.  The
context menu is shared property -- org alone contributes a dozen items --
and a feature that takes three of the top-level slots for itself is a
feature that has overstayed.  One line in, the groups below it:

    AI > Ask AI  > Summarize... / Rephrase... / Reply... / ...
         Chat    > ...
         Brigade > ...
         Tools   > ..."
  (let* ((target (ignore-errors (cmacs-ai-target-at click)))
         (groups (and target (cmacs-ai-actions-for target)))
         (total (apply #'+ (mapcar (lambda (g) (length (cdr g))) groups))))
    (when groups
      (let ((root (make-sparse-keymap cmacs-ai-menu-label)))
        (if (<= total cmacs-ai-menu-inline-limit)
            ;; Few enough that the group submenus are pure friction: put
            ;; the actions straight under the AI entry.
            (dolist (group groups)
              (dolist (action (cdr group))
                (define-key-after root (vector (plist-get action :name))
                  (cmacs-ai-menu--item action target))))
          (dolist (group groups)
            (define-key-after root
              (vector (intern (format "cmacs-ai-group-%s" (car group))))
              (list 'menu-item
                    (cmacs-ai-action-group-label (car group))
                    (cmacs-ai-menu--group-keymap (car group) (cdr group)
                                                 target)))))
        (define-key-after menu [cmacs-ai-separator] menu-bar-separator)
        (define-key-after menu [cmacs-ai]
          (list 'menu-item cmacs-ai-menu-label root))))
    menu))

;;;; Opening it --------------------------------------------------------

;;;###autoload
(defalias 'cmacs-ai-menu-mouse #'cmacs-menu-open-context-menu
  "Open the context menu for EVENT.

Bound to mouse-3 by `cmacs-ai-menu-mode'.  Deliberately the generic
opener rather than an AI-specific one: the AI entries arrive through
`context-menu-functions' like everybody else's, so right-click keeps
showing the whole menu -- spell-check suggestions, `describe-symbol',
whatever your modes contribute -- with the AI groups appended.  Unlike
the stock binding it also works under `emacs --lrg'.")

;;;###autoload
(defun cmacs-ai-menu ()
  "Open the context menu for whatever is at point, from the keyboard.

The route for tty sessions, Evil users, and anyone who would rather not
reach for the mouse.  Falls back to completion when the display cannot
draw a popup at all."
  (interactive)
  (cmacs-menu-open-context-menu (list 'mouse-3 (posn-at-point))))

;;;###autoload
(defun cmacs-ai-menu-pick (&optional group)
  "Choose an AI action for the thing at point by completion.

Always completion, never a popup -- useful when you know the name of the
action and want it in three keystrokes.  With GROUP (a symbol from
`cmacs-ai-action-groups'), offer only that group's actions.

This is the binding that stays correct as the registry grows: unlike a
fixed key per action it also reaches whatever you registered yourself,
and whatever your `cmacs-brigade-deftool' forms published with :menu."
  (interactive)
  (let* ((target (or (cmacs-ai-target-at)
                     (user-error "cmacs-ai: nothing here to act on")))
         (groups (cmacs-ai-actions-for target))
         (groups (if group
                     (seq-filter (lambda (g) (eq (car g) group)) groups)
                   groups))
         (choices nil))
    (dolist (g groups)
      (dolist (action (cdr g))
        (push (cons (if group
                        (cmacs-ai-action-label action target)
                      (format "%s: %s"
                              (cmacs-ai-action-group-label (car g))
                              (cmacs-ai-action-label action target)))
                    action)
              choices)))
    (setq choices (nreverse choices))
    (unless choices
      (user-error "cmacs-ai: nothing%s applies to %s"
                  (if group (format " in %s" (cmacs-ai-action-group-label group))
                    "")
                  (cmacs-ai-target-describe target)))
    (let* ((pick (completing-read
                  (format "%s%s: "
                          (if group
                              (concat (cmacs-ai-action-group-label group) " on ")
                            "")
                          (cmacs-ai-target-describe target))
                  (mapcar #'car choices) nil t))
           (action (cdr (assoc pick choices))))
      (when action (cmacs-ai-action-run action target)))))

;; One command per group, so each can have its own key.  Defined rather
;; than closed over, so they are ordinary named commands that `M-x' and
;; `where-is' can find.
(dolist (group '(mail git errors terminal notes ask chat brigade tools))
  (defalias (intern (format "cmacs-ai-menu-pick-%s" group))
    (lambda () (interactive) (cmacs-ai-menu-pick group))
    (format "Choose an AI action from the %s group for the thing at point."
            (cmacs-ai-action-group-label group))))

;;;###autoload (autoload 'cmacs-ai-menu-pick-mail "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-git "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-errors "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-terminal "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-notes "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-ask "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-chat "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-brigade "cmacs-ai-menu" nil t)
;;;###autoload (autoload 'cmacs-ai-menu-pick-tools "cmacs-ai-menu" nil t)

;;;; In-scene menus ----------------------------------------------------
;;
;; The libregnum surfaces -- roamgraph, gnuseye, the scene editor -- do
;; not go through `context-menu-functions' at all.  Their right-click is
;; a ray-pick in the C input layer, and they build their own alist menu
;; for the node that was hit.  Rather than duplicate the AI menu into
;; each of them, they splice in one entry that opens it for whatever
;; their own resolver reports.

;;;###autoload
(defun cmacs-ai-act-on-target (&optional target)
  "Choose and run an AI action for TARGET (default: the thing at point).

The entry point for surfaces that build their own menus: one item calling
this gets the whole AI menu, kept in step automatically as actions are
registered and unregistered."
  (interactive)
  (let* ((target (or target (cmacs-ai-target-at)))
         (groups (and target (cmacs-ai-actions-for target))))
    (unless groups
      (user-error "cmacs-ai: nothing applies here"))
    (let* ((panes
            (mapcar
             (lambda (group)
               (cons (cmacs-ai-action-group-label (car group))
                     (mapcar (lambda (action)
                               (cons (cmacs-ai-action-label action target)
                                     action))
                             (cdr group))))
             groups))
           (choice (cmacs-menu-popup
                    t (cons (cmacs-ai-target-describe target) panes))))
      (when choice (cmacs-ai-action-run choice target)))))

;;;###autoload
(defun cmacs-ai-menu-scene-items ()
  "An alist menu section opening the AI menu, for in-scene context menus.

Returns nil when there is nothing to offer, so a scene can splice the
result in unconditionally:

    (append items (and (fboundp \\='cmacs-ai-menu-scene-items)
                       (cmacs-ai-menu-scene-items)))"
  (when (and (cmacs-ai-actions--ai-p)
             (let ((target (ignore-errors (cmacs-ai-target-at))))
               (and target (cmacs-ai-actions-for target))))
    ;; A leading nil is a separator in the alist menus these scenes use.
    (list nil (cons "Ask AI..." #'cmacs-ai-act-on-target))))

;;;; Keymap ------------------------------------------------------------

;;;###autoload
(defvar cmacs-ai-menu-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'cmacs-ai-menu-pick)
    (define-key map (kbd "m") #'cmacs-ai-menu)
    (define-key map (kbd "s") #'cmacs-ai-summarize)
    (define-key map (kbd "r") #'cmacs-ai-rephrase)
    (define-key map (kbd "p") #'cmacs-ai-reply)
    (define-key map (kbd "e") #'cmacs-ai-explain)
    (define-key map (kbd "?") #'cmacs-ai-ask)
    ;; The in-place family: RET sends the thing at point and the answer
    ;; lands underneath it, in the file.  `?' above answers off to the
    ;; side; RET answers *here*, which is why it gets the key you press
    ;; without thinking.
    (define-key map (kbd "RET") #'cmacs-ai-send)
    (define-key map (kbd "g") #'cmacs-ai-send-regenerate)
    (define-key map (kbd "x") #'cmacs-ai-send-delete-response)
    (define-key map (kbd "k") #'cmacs-ai-send-cancel)
    map)
  "Keyboard equivalents of the AI menu.

Not bound anywhere by default -- cmacs does not take a global prefix out
from under your config.  Bind it where you like:

    (global-set-key (kbd \"C-c a\") cmacs-ai-menu-command-map)")

(defvar cmacs-ai-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-3] #'cmacs-menu-open-context-menu)
    map)
  "Keymap installed by `cmacs-ai-menu-mode'.")

;;;; Mode and bootstrap ------------------------------------------------

;;;###autoload
(define-minor-mode cmacs-ai-menu-mode
  "Put cmacs AI actions on the right-click menu, everywhere.

Enables `context-menu-mode' as a side effect -- without it nothing on
`context-menu-functions' is ever consulted."
  :global t
  :init-value nil
  :keymap cmacs-ai-menu-mode-map
  (if cmacs-ai-menu-mode
      (progn
        (add-hook 'context-menu-functions #'cmacs-ai-menu-populate 90)
        (unless (bound-and-true-p context-menu-mode)
          (context-menu-mode 1)))
    (remove-hook 'context-menu-functions #'cmacs-ai-menu-populate)))

;;;###autoload
(defun cmacs-ai-menu-bootstrap ()
  "Install the AI context menu.  Idempotent; run from `after-init-hook'.

Honours `cmacs-ai-menu-auto-enable' (opt out of the whole thing) and
`cmacs-menu-override-mouse-3' (opt out of the mouse-3 rebind only)."
  (interactive)
  (cond
   ;; Batch: no display, no menus, and generating autoloads should not
   ;; start rebinding keys.
   ((and noninteractive (not (called-interactively-p 'any))) nil)
   ((not cmacs-ai-menu-auto-enable)
    (when (called-interactively-p 'any)
      (user-error "cmacs-ai-menu-auto-enable is nil; opting out")))
   (t
    (cmacs-ai-menu-mode 1)
    (cmacs-menu-claim-mouse-3 #'cmacs-menu-open-context-menu))))

;;;###autoload
(add-hook 'after-init-hook #'cmacs-ai-menu-bootstrap)

;; Loaded after init has already run (someone required us mid-session):
;; the hook above will never fire, so bootstrap directly.
(when (and after-init-time (not noninteractive))
  (cmacs-ai-menu-bootstrap))

(provide 'cmacs-ai-menu)

;;; cmacs-ai-menu.el ends here
