;;; cmacs-evil-tests.el --- Tests for the Evil/Doom keymap shim -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-evil'.  The binding-collection half is pure and runs
;; everywhere.  The precedence half needs the real Evil (and, to reproduce
;; the original bug, evil-snipe), which is an external package: those tests
;; skip when it is not on `load-path'.  To run them against a Doom install:
;;
;;   src/emacs -Q --batch \
;;     -L lisp/cmacs -L test/cmacs \
;;     $(printf -- '-L %s ' ~/.config/emacs/.local/straight/build-*/evil{,-snipe}) \
;;     -l ert -l cmacs-evil-tests -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cmacs-evil nil t)

;; Evil and evil-snipe are external packages: the tests that use them skip
;; when they are missing, but the byte-compiler still sees the calls.
(declare-function evil-local-mode "evil-core" (&optional arg))
(declare-function evil-change-state "evil-core" (state &optional message))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function evil-get-auxiliary-keymap "evil-core"
                  (map state &optional create ignore-parent))
(declare-function evil-insert "evil-commands" (count &optional vcount skip-empty-lines))
(declare-function evil-visual-char "evil-commands" ())
(declare-function evil-snipe-local-mode "evil-snipe" (&optional arg))
(declare-function evil-snipe-override-local-mode "evil-snipe" (&optional arg))
(defvar evil-snipe-disabled-modes)

(defmacro cmacs-evil-tests--skip-unless-loaded ()
  "Skip the test unless `cmacs-evil' loaded."
  '(skip-unless (featurep 'cmacs-evil)))

(defmacro cmacs-evil-tests--skip-unless-evil ()
  "Skip the test unless the external Evil package is available."
  '(progn
     (skip-unless (featurep 'cmacs-evil))
     (skip-unless (require 'evil nil t))))

(defun cmacs-evil-tests--map ()
  "Return a fresh mode map shaped like a cmacs queue-buffer map.
`s', `S', `f' and `T' are exactly the keys evil-snipe steals."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "s") #'ignore)
    (define-key map (kbd "S") #'undefined)
    (define-key map (kbd "f") #'ignore)
    (define-key map (kbd "T") #'undefined)
    (define-key map (kbd "g") #'ignore)
    map))

;;; ---------------------------------------------------------------------
;;; Binding collection (pure)
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-evil-test-own-bindings-excludes-parent ()
  "Only the map's own bindings are collected, never the parent's."
  (cmacs-evil-tests--skip-unless-loaded)
  (let* ((map (cmacs-evil-tests--map))
         (events (mapcar #'car (cmacs-evil--own-bindings map))))
    (should (equal (sort (copy-sequence events) #'<) '(?S ?T ?f ?g ?s)))
    ;; `SPC' and `DEL' come from `special-mode-map'; promoting them would
    ;; shadow the Doom leader.
    (should-not (memq ?\s events))
    (should-not (memq 'backspace events))))

(ert-deftest cmacs-evil-test-own-bindings-definitions ()
  "Collected definitions are the live ones from the map itself."
  (cmacs-evil-tests--skip-unless-loaded)
  (let ((map (cmacs-evil-tests--map)))
    (should (eq (cdr (assq ?s (cmacs-evil--own-bindings map))) #'ignore))
    (should (eq (cdr (assq ?S (cmacs-evil--own-bindings map))) #'undefined))))

(ert-deftest cmacs-evil-test-own-bindings-skips-evil-scaffolding ()
  "Evil's in-keymap bookkeeping is never copied back into itself."
  (cmacs-evil-tests--skip-unless-loaded)
  (let ((map (cmacs-evil-tests--map)))
    ;; Fake what `evil-make-overriding-map' / auxiliary keymaps store in the
    ;; map, so the test holds even without Evil installed.
    (define-key map [override-state] 'all)
    (define-key map [intercept-state] 'normal)
    (define-key map [normal-state] (make-sparse-keymap))
    (let ((events (mapcar #'car (cmacs-evil--own-bindings map))))
      (should (equal (sort (copy-sequence events) #'<) '(?S ?T ?f ?g ?s)))
      (should-not (memq 'override-state events))
      (should-not (memq 'intercept-state events))
      (should-not (memq 'normal-state events)))))

(ert-deftest cmacs-evil-test-setup-without-evil-is-noop ()
  "Setting up a map with Evil absent neither errors nor mangles the map."
  (cmacs-evil-tests--skip-unless-loaded)
  (let ((map (cmacs-evil-tests--map)))
    (should (progn (cmacs-evil-setup-mode-map map 'fundamental-mode) t))
    (should (eq (lookup-key map (kbd "s")) #'ignore))))

;;; ---------------------------------------------------------------------
;;; Precedence under Evil (needs the external package)
;;; ---------------------------------------------------------------------

(defmacro cmacs-evil-tests--with-mode-buffer (map state &rest body)
  "Run BODY in a buffer whose local map is MAP and Evil STATE is active."
  (declare (indent 2))
  `(let ((buffer (generate-new-buffer " *cmacs-evil-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (use-local-map ,map)
           (evil-local-mode 1)
           (evil-change-state ,state)
           (evil-normalize-keymaps)
           ,@body)
       (kill-buffer buffer))))

(ert-deftest cmacs-evil-test-bindings-win-in-normal-and-motion ()
  "Every own binding resolves to the mode's command in normal and motion."
  (cmacs-evil-tests--skip-unless-evil)
  (let ((map (cmacs-evil-tests--map)))
    (cmacs-evil-setup-mode-map map 'fundamental-mode)
    (dolist (state '(normal motion))
      (cmacs-evil-tests--with-mode-buffer map state
        (dolist (binding (cmacs-evil--own-bindings map))
          (should (eq (key-binding (vector (car binding)) t)
                      (cdr binding))))))))

(ert-deftest cmacs-evil-test-beats-evil-snipe ()
  "The map beats evil-snipe, whose minor-mode maps own s/S/f/T.
This is the regression: with only `evil-make-overriding-map' these keys
resolved to `evil-snipe-s' and friends, so they did nothing useful in a
cmacs queue buffer under Doom."
  (cmacs-evil-tests--skip-unless-evil)
  (skip-unless (require 'evil-snipe nil t))
  (let ((map (cmacs-evil-tests--map)))
    (cmacs-evil-setup-mode-map map 'fundamental-mode)
    (dolist (state '(normal motion))
      (cmacs-evil-tests--with-mode-buffer map state
        ;; Force snipe on regardless of `evil-snipe-disabled-modes': this
        ;; asserts the intercept map wins even when snipe is active.
        (evil-snipe-local-mode 1)
        (evil-snipe-override-local-mode 1)
        (evil-normalize-keymaps)
        (dolist (key '("s" "S" "f" "T"))
          (should (eq (key-binding (kbd key) t)
                      (lookup-key map (kbd key)))))))))

(ert-deftest cmacs-evil-test-unbound-keys-fall-through ()
  "Keys the mode does not bind are left to Evil (Doom leader, ESC, ...)."
  (cmacs-evil-tests--skip-unless-evil)
  (let ((map (cmacs-evil-tests--map)))
    (cmacs-evil-setup-mode-map map 'fundamental-mode)
    (cmacs-evil-tests--with-mode-buffer map 'normal
      ;; `i' and `v' are not in the map, so Evil still owns them.
      (should (eq (key-binding (kbd "i") t) #'evil-insert))
      (should (eq (key-binding (kbd "v") t) #'evil-visual-char))
      ;; SPC and DEL are bound in the *parent* (`special-mode-map').  They
      ;; must stay out of the intercept map, or they would outrank Evil --
      ;; and under Doom that means the SPC leader dies in these buffers.
      (let ((aux (evil-get-auxiliary-keymap map 'normal)))
        (should (keymapp aux))
        (should-not (lookup-key aux (kbd "SPC")))
        (should-not (lookup-key aux (kbd "DEL")))
        (should (lookup-key aux (kbd "s")))))))

(ert-deftest cmacs-evil-test-user-rebinding-still-wins ()
  "A config that rebinds a key after setup overrides the mode's binding."
  (cmacs-evil-tests--skip-unless-evil)
  (let ((map (cmacs-evil-tests--map)))
    (cmacs-evil-setup-mode-map map 'fundamental-mode)
    (evil-define-key* 'normal map (kbd "s") #'forward-char)
    (cmacs-evil-tests--with-mode-buffer map 'normal
      (should (eq (key-binding (kbd "s") t) #'forward-char)))))

;;; ---------------------------------------------------------------------
;;; Sweep: every cmacs mode map that opted in must win, snipe forced on
;;; ---------------------------------------------------------------------

(defconst cmacs-evil-tests--covered
  ;; (FEATURE MAP-SYMBOL . AUX-ONLY-P).  AUX-ONLY maps keep their bindings
  ;; in the per-state auxiliary keymaps installed with `evil-define-key*',
  ;; so the expected set is read from there instead of the base map.
  '((cmacs-transcribe      cmacs-transcribe-mode-map)
    (cmacs-transcode       cmacs-transcode-mode-map)
    (cmacs-calculator-menu cmacs-calculator-menu-mode-map)
    (cmacs-calculator-chart cmacs-calculator-chart-mode-map)
    (cmacs-audio           cmacs-audio-mode-map)
    (cmacs-video           cmacs-video-mode-map)
    (cmacs-cad-model       cmacs-cad-model-mode-map)
    (cmacs-cad-sketch      cmacs-cad-sketch-mode-map)
    (cmacs-cad-editor      cmacs-cad-feature-tree-mode-map)
    (cmacs-gnuseye-meteo   cmacs-gnuseye-forecast-mode-map)
    (cmacs-imgedit         cmacs-imgedit-mode-map)
    (cmacs-vidstudio       cmacs-vidstudio-mode-map)
    (cmacs-gsurf-inspector cmacs-gsurf-dom-mode-map)
    (cmacs-gsurf-inspector cmacs-gsurf-console-mode-map)
    (cmacs-gsurf-bookmarks cmacs-gsurf-bookmarks-mode-map)
    (cmacs-gsurf-downloads cmacs-gsurf-downloads-mode-map)
    (cmacs-gsurf           cmacs-gsurf-mode-map . aux)
    (cmacs-gsurf-lite      cmacs-gsurf-lite-mode-map . aux)
    (cmacs-gnuseye         cmacs-gnuseye-list-mode-map . aux)
    (cmacs-gnuseye         cmacs-gnuseye-layers-mode-map . aux)
    (cmacs-gnuseye         cmacs-gnuseye-inspector-mode-map . aux))
  "Mode maps that call into `cmacs-evil' and must therefore win under Evil.")

(defun cmacs-evil-tests--expected (map aux-only state)
  "Return the (EVENT . DEF) alist that must win for MAP in STATE."
  (if (not aux-only)
      (cmacs-evil--own-bindings map)
    (let ((aux (evil-get-auxiliary-keymap map state))
          (result nil))
      (when (keymapp aux)
        (map-keymap
         (lambda (event definition)
           (unless (or (consp event)
                       (keymapp definition)
                       (and (symbolp event)
                            (string-suffix-p "-state" (symbol-name event))))
             (push (cons event definition) result)))
         aux))
      result)))

(ert-deftest cmacs-evil-test-covered-maps-win ()
  "Every opted-in cmacs mode map beats Evil in normal and motion state.
evil-snipe is forced on in the test buffer regardless of
`evil-snipe-disabled-modes', so this exercises the intercept promotion
itself.  Maps whose subsystem is not compiled into this build are
skipped, not failed."
  (cmacs-evil-tests--skip-unless-evil)
  (let ((snipe (require 'evil-snipe nil t))
        (checked 0))
    (dolist (entry cmacs-evil-tests--covered)
      (let ((feature (nth 0 entry))
            (sym (nth 1 entry))
            (aux-only (eq (cddr entry) 'aux)))
        (when (and (require feature nil t) (boundp sym))
          (let ((map (symbol-value sym)))
            (dolist (state '(normal motion))
              (cmacs-evil-tests--with-mode-buffer map state
                (when snipe
                  (evil-snipe-local-mode 1)
                  (evil-snipe-override-local-mode 1)
                  (evil-normalize-keymaps))
                (dolist (binding (cmacs-evil-tests--expected map aux-only state))
                  (setq checked (1+ checked))
                  ;; A prefix key resolves to a keymap composed from every
                  ;; active prefix map, so compare the full sequences.
                  (if (keymapp (cdr binding))
                      (map-keymap
                       (lambda (event definition)
                         (should (eq (key-binding (vector (car binding) event) t)
                                     definition)))
                       (cdr binding))
                    (should (eq (key-binding (vector (car binding)) t)
                                (cdr binding)))))))))))
    ;; A build with no cmacs Elisp on `load-path' would silently pass.
    (should (> checked 0))))

(ert-deftest cmacs-evil-test-snipe-disabled-for-mode ()
  "The mode is registered in `evil-snipe-disabled-modes'."
  (cmacs-evil-tests--skip-unless-evil)
  (skip-unless (require 'evil-snipe nil t))
  (let ((evil-snipe-disabled-modes (copy-sequence evil-snipe-disabled-modes)))
    (cmacs-evil-setup-mode-map (cmacs-evil-tests--map) 'cmacs-evil-test-mode)
    (should (memq 'cmacs-evil-test-mode evil-snipe-disabled-modes))))

(provide 'cmacs-evil-tests)
;;; cmacs-evil-tests.el ends here
