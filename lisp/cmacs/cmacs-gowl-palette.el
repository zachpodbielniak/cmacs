;;; cmacs-gowl-palette.el --- One palette for editor and compositor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; Author: Zach Podbielniak
;; Keywords: frames, faces, wayland

;;; Commentary:

;; gowl carries a palette --- one set of named colours that its
;; borders, its bar and its lock screen all resolve against.  This
;; connects that palette to the editor's.
;;
;; The useful direction is Emacs to gowl.  The theme in the editor is
;; the palette a user actually curates; the compositor's borders are
;; the thing that never got updated to match it, because updating them
;; meant editing a YAML file and reloading.  So the default here is
;; that the compositor follows the editor: enable a theme and the
;; borders, the bar and the lock screen change with it.
;;
;; What is derived is deliberately small.  A theme has hundreds of
;; faces and gowl needs fifteen colours; guessing which face means
;; "surface" across every theme in existence is not a solvable
;; problem.  `cmacs-gowl-palette-face-map' names one face attribute per
;; entry, defaults to faces every theme defines, and anything it cannot
;; find is left to the flavour underneath --- so a partial derivation
;; degrades to a partial retint rather than to a black desktop.
;;
;; The other direction exists too: `cmacs-gowl-set-palette' takes a
;; flavour name for when you want the compositor's own colours.

;;; Code:

(require 'cmacs)
(require 'color)
(require 'cl-lib)

(declare-function gowl-get-palette "cmacs-gowl" ())
(declare-function gowl-set-palette "cmacs-gowl" (palette &optional entries))
(declare-function gowl-list-palettes "cmacs-gowl" ())
(declare-function gowl-running-p "cmacs-gowl" ())
(declare-function gowl-set-border-colors "cmacs-gowl"
                  (focus &optional unfocus urgent))
(declare-function gowl-get-border-color-specs "cmacs-gowl" ())

(defgroup cmacs-gowl-palette nil
  "Share one colour palette between cmacs and the gowl compositor."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-palette-")

(defcustom cmacs-gowl-palette-face-map
  '(("base"    default        :background)
    ("mantle"  mode-line      :background)
    ("crust"   fringe         :background)
    ("surface" region         :background)
    ("overlay" shadow         :foreground)
    ("text"    default        :foreground)
    ("subtext" shadow         :foreground)
    ("accent"  link           :foreground)
    ("red"     error          :foreground)
    ("green"   success        :foreground)
    ("yellow"  warning        :foreground)
    ("blue"    link           :foreground)
    ("mauve"   font-lock-keyword-face  :foreground)
    ("teal"    font-lock-string-face   :foreground)
    ("peach"   font-lock-function-name-face :foreground))
  "How to read each gowl palette entry out of the current theme.

Each element is (NAME FACE ATTRIBUTE): the colour for the gowl palette
entry NAME is ATTRIBUTE of FACE.

The faces chosen are ones every theme defines, because the alternative
--- guessing which of a theme's hundreds of faces means \"surface\" ---
is not solvable in general.  An entry whose face resolves to nothing
is simply not sent, and gowl keeps that entry from the flavour
underneath, so a theme that defines less than this expects gives a
partial retint rather than a broken one.

`accent' reads the `link' face rather than the mode line, and that is
worth knowing because it decides the colour of every focused window
border.  A mode line is the more obvious choice and the wrong one: in
modus-vivendi, in many dark themes, its background is a neutral grey,
so every border came out grey.  A theme's link colour is the one it
actually chose to say \"this is the accent\"."
  :type '(repeat (list (string :tag "Palette entry")
                       (face   :tag "Face")
                       (choice :tag "Attribute"
                               (const :foreground)
                               (const :background))))
  :group 'cmacs-gowl-palette)

(defcustom cmacs-gowl-palette-adopt-borders t
  "When non-nil, point gowl's borders at palette entries before pushing.

Without this the feature silently does nothing for anyone with an
existing config.  gowl resolves a border colour written as a literal
--- \"#005577\", which is what every config shipped before palettes
existed --- to itself, so pushing a palette changes the palette and
leaves the borders exactly as they were.  No error, no warning, and a
desktop that looks like the theme did not apply.

So the first push retargets the three border colours at the entries
`accent', `surface' and `red'.  This changes the running compositor's
configuration, not the file on disk, and only for someone who has
asked for the editor to drive the colours by calling
`cmacs-gowl-palette-apply' or enabling
`cmacs-gowl-palette-follow-theme-mode'.

Set to nil to keep whatever the config file says, and edit the config
by hand if you want the borders to follow."
  :type 'boolean
  :group 'cmacs-gowl-palette)

(defcustom cmacs-gowl-palette-border-entries
  '("accent" "surface" "red")
  "Palette entries the focused, unfocused and urgent borders adopt.
Only consulted when `cmacs-gowl-palette-adopt-borders' is non-nil."
  :type '(list (string :tag "Focused")
               (string :tag "Unfocused")
               (string :tag "Urgent"))
  :group 'cmacs-gowl-palette)

(defcustom cmacs-gowl-palette-follow-theme t
  "When non-nil, push the editor's colours to gowl on a theme change.

Only has an effect while `cmacs-gowl-palette-follow-theme-mode' is on,
which `cmacs-gowl-mode' enables under a gowl session."
  :type 'boolean
  :group 'cmacs-gowl-palette)

;;; Reading colours out of the theme

(defun cmacs-gowl-palette--frame ()
  "Return a frame whose colours are worth reading, or nil.

Face colours on a terminal frame are the terminal's sixteen, which
would repaint a 24-bit compositor in approximations of them.  A
graphical frame is preferred; with none, nil means the selected frame,
whose colours are at least self-consistent."
  (catch 'found
    (dolist (frame (frame-list))
      (when (display-graphic-p frame)
        (throw 'found frame)))
    nil))

(defun cmacs-gowl-palette--hex (color)
  "Return COLOR as \"#rrggbb\", or nil if it is not a colour.

Face attributes come back as anything from `unspecified' to a colour
name to hex with one, two, three or four digits per component, and
gowl parses exactly two.

Hex is parsed here rather than handed to `color-values', which resolves
against a display: with no graphical frame --- a daemon before its
first frame, a batch run --- it snaps every colour to the terminal's
sixteen, so \"#1e1e2e\" comes back as pure blue.  A hex string means
the same thing on every display and needs no frame to say so.  Names
still have to go through `color-values', because nothing else knows
what \"rebeccapurple\" is."
  (when (and (stringp color)
             (not (string-empty-p color)))
    (if (string-match "\\`#\\([0-9a-fA-F]+\\)\\'" color)
        (let* ((digits (match-string 1 color))
               (width (/ (length digits) 3)))
          ;; Only the four widths Emacs actually emits; anything else is
          ;; not something we can narrow without guessing.
          (when (and (memq width '(1 2 3 4))
                     (= (length digits) (* width 3)))
            (apply #'format "#%02x%02x%02x"
                   (mapcar
                    (lambda (i)
                      (let ((v (string-to-number
                                (substring digits (* i width)
                                           (* (1+ i) width))
                                16)))
                        ;; Scale down to 8 bits rather than truncating:
                        ;; "#fff" is white, and taking the first digit
                        ;; of each channel would make it 0x0f0f0f.
                        (if (= width 1)
                            (+ (* v 16) v)
                          (ash v (* -4 (- width 2))))))
                    '(0 1 2)))))
      (let ((values (color-values color (cmacs-gowl-palette--frame))))
        (when values
          ;; color-values is 16-bit per channel; gowl wants 8.
          (apply #'format "#%02x%02x%02x"
                 (mapcar (lambda (v) (ash v -8)) values)))))))

(defun cmacs-gowl-palette-from-theme ()
  "Return the current theme's colours as a gowl palette alist.

Entries whose face gives no colour are omitted rather than guessed at,
so what comes back may be shorter than `cmacs-gowl-palette-face-map'."
  (let ((frame (cmacs-gowl-palette--frame))
        (out '()))
    (dolist (entry cmacs-gowl-palette-face-map)
      (pcase-let ((`(,name ,face ,attribute) entry))
        (when (facep face)
          ;; INHERIT is t so a face defined only by inheritance --- which
          ;; is how most themes define most faces --- still answers.
          (let ((hex (cmacs-gowl-palette--hex
                      (face-attribute face attribute frame t))))
            (when hex
              (push (cons name hex) out))))))
    (nreverse out)))

(defun cmacs-gowl-palette--adopt-borders ()
  "Point the border colours at palette entries, if they are literals.

Idempotent, and it leaves a border alone that already names an entry:
someone who configured `border-color-focus: mauve' meant it, and
overwriting that with `accent' would be this feature deciding it knows
better than the config it is supposed to be honouring."
  (when (fboundp 'gowl-get-border-color-specs)
    (let ((specs (ignore-errors (gowl-get-border-color-specs)))
          (want cmacs-gowl-palette-border-entries))
      (when specs
        (apply
         #'gowl-set-border-colors
         (cl-mapcar
          (lambda (spec entry)
            ;; A spec starting with "#" is a literal and follows no
            ;; palette; anything else already names an entry.
            (when (or (null spec)
                      (string-prefix-p "#" spec))
              entry))
          specs want))))))

;;; Commands

;;;###autoload
(defun cmacs-gowl-palette-apply ()
  "Push the editor's colours to the compositor.

Borders, the bar and the lock screen all resolve against the palette,
so they change together.  The entries sit above gowl's config file and
survive `gowl-reload-config'."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "No gowl compositor is running"))
  (let ((palette (cmacs-gowl-palette-from-theme)))
    (unless palette
      (user-error "No colours could be read from the current theme"))
    (when cmacs-gowl-palette-adopt-borders
      (cmacs-gowl-palette--adopt-borders))
    (gowl-set-palette palette)
    (when (called-interactively-p 'interactive)
      (message "Pushed %d colour%s to gowl"
               (length palette)
               (if (= (length palette) 1) "" "s")))
    palette))

;;;###autoload
(defun cmacs-gowl-set-palette (flavour)
  "Switch the compositor to the built-in palette FLAVOUR.

This is the other direction from `cmacs-gowl-palette-apply': gowl's own
colours rather than the editor's.  Overrides pushed earlier stay on
top, so a flavour switch after an editor push changes only what the
editor did not set --- disable
`cmacs-gowl-palette-follow-theme-mode' first for a clean switch."
  (interactive
   (list (completing-read "Palette flavour: "
                          (if (fboundp 'gowl-list-palettes)
                              (gowl-list-palettes)
                            '("mocha" "macchiato" "frappe" "latte" "dwm"))
                          nil t)))
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "No gowl compositor is running"))
  (gowl-set-palette flavour)
  (message "gowl palette: %s" flavour))

;;;###autoload
(defun cmacs-gowl-palette-show ()
  "Display the compositor's current palette."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "No gowl compositor is running"))
  (let ((palette (gowl-get-palette)))
    (with-current-buffer (get-buffer-create "*gowl palette*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local truncate-lines t)
        (insert (propertize "gowl palette\n\n" 'face 'bold))
        (dolist (entry palette)
          (let ((name (car entry))
                (hex (cdr entry)))
            (insert (format "%-10s %-10s " name (or hex "")))
            ;; A swatch, because a column of hex is unreadable and the
            ;; whole point of this buffer is seeing the colours.
            (when hex
              (insert (propertize "        "
                                  'face `(:background ,(substring hex 0 7)))))
            (insert "\n"))))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;; Following the theme

(defun cmacs-gowl-palette--on-reload (&rest _)
  "Re-assert the editor's colours after a config reload.

A reload re-reads the config file, and the file owns the border specs
--- so a config saying `border-color-focus: \"#005577\"' puts the
literal straight back and the borders stop following the theme.  The
palette overrides themselves survive a reload; it is the specs
pointing at them that do not.

Rightly so: the file should win on the things the file declares.  This
just says the editor's intent again afterwards, for someone who
switched the mode on."
  (when (and cmacs-gowl-palette-follow-theme
             (fboundp 'gowl-running-p)
             (gowl-running-p))
    (ignore-errors (cmacs-gowl-palette-apply))))

(defun cmacs-gowl-palette--on-theme-change (&rest _)
  "Re-push the palette after a theme change.

Deferred to an idle moment: `enable-theme' runs this while it is still
applying faces, and reading them mid-flight gives the outgoing theme's
colours for anything not yet updated."
  (when (and cmacs-gowl-palette-follow-theme
             (fboundp 'gowl-running-p)
             (gowl-running-p))
    (run-with-idle-timer
     0 nil
     (lambda ()
       ;; Errors here would land in a timer, where nobody sees them and
       ;; the next theme change tries again anyway.
       (ignore-errors (cmacs-gowl-palette-apply))))))

;;;###autoload
(define-minor-mode cmacs-gowl-palette-follow-theme-mode
  "Keep the compositor's colours in step with the editor's theme.

With this on, enabling or disabling a theme repaints gowl's borders,
bar and lock screen to match."
  :global t
  :group 'cmacs-gowl-palette
  (if cmacs-gowl-palette-follow-theme-mode
      (progn
        (add-hook 'enable-theme-functions
                  #'cmacs-gowl-palette--on-theme-change)
        (add-hook 'disable-theme-functions
                  #'cmacs-gowl-palette--on-theme-change)
        (advice-add 'gowl-reload-config :after
                    #'cmacs-gowl-palette--on-reload)
        ;; Push once on enable: the theme is almost always already
        ;; loaded by the time a session gets here, and waiting for the
        ;; next theme change would leave the borders wrong until then.
        (cmacs-gowl-palette--on-theme-change))
    (remove-hook 'enable-theme-functions
                 #'cmacs-gowl-palette--on-theme-change)
    (remove-hook 'disable-theme-functions
                 #'cmacs-gowl-palette--on-theme-change)
    (advice-remove 'gowl-reload-config
                   #'cmacs-gowl-palette--on-reload)))

(provide 'cmacs-gowl-palette)

;;; cmacs-gowl-palette.el ends here
