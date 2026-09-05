;;; cmacs-gowl-palette-tests.el --- Tests for the shared palette -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-gowl-palette'.
;;
;; The compositor half is tested in gowl's own suite (tests/test-palette.c).
;; What is tested here is the derivation: turning Emacs face attributes
;; into the two-digits-per-channel hex gowl parses, and refusing to send
;; anything that is not a colour.
;;
;; That refusal is the part worth testing.  A face attribute can be
;; `unspecified', a colour name, or hex with 1, 2, 3 or 4 digits per
;; component; gowl's parser accepts exactly two.  Sending it anything
;; else does not raise an error at either end --- the value fails to
;; parse and the border is painted black, which looks like a theme
;; choice rather than a bug.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-palette)

;;; Colour normalisation

(ert-deftest cmacs-gowl-palette-test-hex-passthrough ()
  "Six-digit hex survives unchanged."
  (should (equal (cmacs-gowl-palette--hex "#1e1e2e") "#1e1e2e")))

(ert-deftest cmacs-gowl-palette-test-hex-narrows-wide-components ()
  "Four-digits-per-component hex narrows to two.
Emacs hands out `#rrrrggggbbbb' freely and gowl parses two digits per
channel, so an unnarrowed value is read as a different colour."
  (should (equal (cmacs-gowl-palette--hex "#1e1e1e1e2e2e") "#1e1e2e")))

(ert-deftest cmacs-gowl-palette-test-hex-color-name ()
  "A colour name resolves to hex."
  (should (equal (cmacs-gowl-palette--hex "white") "#ffffff"))
  (should (equal (cmacs-gowl-palette--hex "black") "#000000")))

(ert-deftest cmacs-gowl-palette-test-hex-rejects-non-colors ()
  "Anything that is not a colour yields nil rather than a bad string.
`unspecified' is what an undefined face attribute returns, and it is a
symbol, not a string."
  (should-not (cmacs-gowl-palette--hex 'unspecified))
  (should-not (cmacs-gowl-palette--hex nil))
  (should-not (cmacs-gowl-palette--hex ""))
  (should-not (cmacs-gowl-palette--hex "not-a-color-at-all")))

;;; Derivation

(ert-deftest cmacs-gowl-palette-test-from-theme-shape ()
  "Every derived entry is a (NAME . \"#rrggbb\") pair."
  (let ((palette (cmacs-gowl-palette-from-theme)))
    ;; Not asserted to be non-empty: a batch Emacs has no frame and most
    ;; faces resolve to `unspecified' there.  Whatever it does derive
    ;; must still be well-formed, which is the invariant that matters --
    ;; a malformed entry is what paints a border black.
    (dolist (entry palette)
      (should (consp entry))
      (should (stringp (car entry)))
      (should (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" (cdr entry))))))

(ert-deftest cmacs-gowl-palette-test-from-theme-names-are-known ()
  "Derived names all come from the face map, and none repeat.
A duplicate would mean one entry silently overwriting another on the
compositor side, where the last one sent wins."
  (let* ((palette (cmacs-gowl-palette-from-theme))
         (names (mapcar #'car palette)))
    (dolist (name names)
      (should (assoc name cmacs-gowl-palette-face-map)))
    (should (equal names (delete-dups (copy-sequence names))))))

(defface cmacs-gowl-palette-tests--known
  '((t :background "#123456" :foreground "#654321"))
  "A face defined only for these tests.
Used instead of `default' because a batch Emacs has no frame, and
`default' resolves to `unspecified' there --- which would make these
tests assert something about the test runner rather than about the
code."
  :group 'cmacs-gowl-palette)

(ert-deftest cmacs-gowl-palette-test-from-theme-skips-missing-faces ()
  "A face that does not exist costs its entry, not the derivation.
This is what keeps a sparse theme from producing a black desktop."
  (let ((cmacs-gowl-palette-face-map
         '(("accent" no-such-face-at-all          :background)
           ("text"   cmacs-gowl-palette-tests--known :foreground))))
    (let ((palette (cmacs-gowl-palette-from-theme)))
      (should-not (assoc "accent" palette))
      (should (equal (cdr (assoc "text" palette)) "#654321")))))

(ert-deftest cmacs-gowl-palette-test-from-theme-follows-faces ()
  "The derived colour is the face's, not a fixed guess."
  (let ((cmacs-gowl-palette-face-map
         '(("accent" cmacs-gowl-palette-tests--known :background))))
    (should (equal (cdr (assoc "accent" (cmacs-gowl-palette-from-theme)))
                   "#123456"))))

;;; Border adoption

;; The hole this exists to close: gowl resolves a literal border colour
;; to itself, so a config written before palettes existed -- every
;; config -- would take a palette push and change nothing at all.

(ert-deftest cmacs-gowl-palette-test-adopt-retargets-literals ()
  "Literal border colours are pointed at palette entries."
  (let (sent)
    (cl-letf (((symbol-function 'gowl-get-border-color-specs)
               (lambda (&rest _) '("#005577" "#444444" "#ff0000")))
              ((symbol-function 'gowl-set-border-colors)
               (lambda (&rest args) (setq sent args) t)))
      (cmacs-gowl-palette--adopt-borders)
      (should (equal sent '("accent" "surface" "red"))))))

(ert-deftest cmacs-gowl-palette-test-adopt-keeps-deliberate-entries ()
  "A border already naming an entry is left alone.
Someone who wrote `border-color-focus: mauve' meant it, and
overwriting that would be this feature overruling the config it is
supposed to be honouring."
  (let (sent)
    (cl-letf (((symbol-function 'gowl-get-border-color-specs)
               (lambda (&rest _) '("mauve" "#444444" "red")))
              ((symbol-function 'gowl-set-border-colors)
               (lambda (&rest args) (setq sent args) t)))
      (cmacs-gowl-palette--adopt-borders)
      ;; nil means "leave this one", so only the literal is retargeted.
      (should (equal sent '(nil "surface" nil))))))

(ert-deftest cmacs-gowl-palette-test-adopt-is-idempotent ()
  "Adopting twice changes nothing the second time."
  (let (sent)
    (cl-letf (((symbol-function 'gowl-get-border-color-specs)
               (lambda (&rest _) '("accent" "surface" "red")))
              ((symbol-function 'gowl-set-border-colors)
               (lambda (&rest args) (setq sent args) t)))
      (cmacs-gowl-palette--adopt-borders)
      (should (equal sent '(nil nil nil))))))

(ert-deftest cmacs-gowl-palette-test-apply-can-skip-adoption ()
  "With adoption off, the config's border specs are left as written."
  (let ((cmacs-gowl-palette-adopt-borders nil)
        (adopted nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-palette) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-border-colors)
               (lambda (&rest _) (setq adopted t) t)))
      (cmacs-gowl-palette-apply)
      (should-not adopted))))

;;; Guards

(ert-deftest cmacs-gowl-palette-test-apply-without-gowl ()
  "Applying with no compositor is a user error, not a crash."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (should-error (cmacs-gowl-palette-apply) :type 'user-error)))

(ert-deftest cmacs-gowl-palette-test-apply-sends-derived-palette ()
  "The derived alist is what reaches the compositor."
  (let (sent)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-palette)
               (lambda (palette &rest _) (setq sent palette) t)))
      (cmacs-gowl-palette-apply)
      (should sent)
      (should (equal sent (cmacs-gowl-palette-from-theme))))))

(ert-deftest cmacs-gowl-palette-test-follow-respects-opt-out ()
  "With following off, a theme change sends nothing."
  (let ((cmacs-gowl-palette-follow-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-palette)
               (lambda (&rest _) (setq called t) t)))
      (cmacs-gowl-palette--on-theme-change 'some-theme)
      ;; The push is deferred to an idle timer; run them.
      (while (and (not called) (sit-for 0.05)
                  (accept-process-output nil 0.05)))
      (should-not called))))

(ert-deftest cmacs-gowl-palette-test-reload-reasserts ()
  "A config reload re-pushes the editor's colours.
Without this the borders stop following the theme the first time the
config is reloaded, because the file owns the border specs and puts
its literals straight back."
  (let (pushed)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-palette)
               (lambda (&rest _) (setq pushed t) t))
              ((symbol-function 'gowl-set-border-colors) (lambda (&rest _) t))
              ((symbol-function 'gowl-get-border-color-specs)
               (lambda (&rest _) '("#005577" "#444444" "#ff0000"))))
      (cmacs-gowl-palette--on-reload)
      (should pushed))))

(ert-deftest cmacs-gowl-palette-test-reload-respects-opt-out ()
  "With following off, a reload leaves the config file the winner."
  (let ((cmacs-gowl-palette-follow-theme nil)
        (pushed nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-set-palette)
               (lambda (&rest _) (setq pushed t) t)))
      (cmacs-gowl-palette--on-reload)
      (should-not pushed))))

(ert-deftest cmacs-gowl-palette-test-mode-manages-hooks ()
  "The mode adds and removes both theme hooks."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (let ((enable-theme-functions nil)
          (disable-theme-functions nil))
      (cmacs-gowl-palette-follow-theme-mode 1)
      (should (memq #'cmacs-gowl-palette--on-theme-change
                    enable-theme-functions))
      (should (memq #'cmacs-gowl-palette--on-theme-change
                    disable-theme-functions))
      (should (advice-member-p #'cmacs-gowl-palette--on-reload
                               'gowl-reload-config))
      (cmacs-gowl-palette-follow-theme-mode -1)
      (should-not (advice-member-p #'cmacs-gowl-palette--on-reload
                                   'gowl-reload-config))
      (should-not (memq #'cmacs-gowl-palette--on-theme-change
                        enable-theme-functions))
      (should-not (memq #'cmacs-gowl-palette--on-theme-change
                        disable-theme-functions)))))

(provide 'cmacs-gowl-palette-tests)

;;; cmacs-gowl-palette-tests.el ends here
