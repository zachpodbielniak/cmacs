;;; cmacs-calculator-menu.el --- Calculator landing page -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; \\[cmacs-calculator] -- the front door.  A `*cmacs-calculator*' buffer
;; listing every calculator this build has, grouped by category, with RET on
;; one opening a sheet already filled in with a runnable call.
;;
;; Generated, never written down
;; -----------------------------
;; The listing is built from `cmacs-calculator-registry' at render time: the
;; categories come from `cmacs-calculator-categories', the entries from
;; `cmacs-calculator-list', the titles and templates from each entry's own
;; metadata.  Nothing here enumerates a calculator by hand, so a family added
;; tomorrow appears with no edit to this file, and a menu entry for something
;; that no longer exists is not expressible.
;;
;; Registration happens when a family file loads, which is why
;; `cmacs-calculator-families' is loaded before rendering.  A family that is
;; not built simply does not register and does not appear -- the page shows
;; what this build actually has, rather than what the manual says it might.
;;
;; Capabilities are reported honestly
;; ----------------------------------
;; The header states the ACTIVE chart tier, resolved through the chart
;; module's own `auto' logic rather than echoing the customization: on a TTY
;; or in batch `auto' means unicode, and saying "SVG" there would be a lie the
;; user only discovers when a plot comes out as block characters.

;;; Code:

(require 'cmacs-calculator)
(require 'cmacs-calculator-chart)
(require 'cmacs-calculator-sheet)
(require 'cmacs-calculator-inline)       ; `cmacs-calculator-error-message'
(require 'cmacs-calculator-repl)
(require 'subr-x)

(eval-when-compile (require 'cl-lib))


;;; Customization

(defgroup cmacs-calculator-menu nil
  "The calculator landing page."
  :group 'cmacs-calculator
  :prefix "cmacs-calculator-menu-")

(defconst cmacs-calculator-menu-buffer-name "*cmacs-calculator*"
  "Name of the landing-page buffer.")

(defface cmacs-calculator-menu-heading-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a category heading."
  :group 'cmacs-calculator-menu)

(defface cmacs-calculator-menu-name-face
  '((t :inherit font-lock-function-name-face))
  "Face for a calculator's name."
  :group 'cmacs-calculator-menu)

(defface cmacs-calculator-menu-title-face
  '((t :inherit default))
  "Face for a calculator's title."
  :group 'cmacs-calculator-menu)


;;; Family loading
;;
;; `cmacs-calculator-families' and `cmacs-calculator-load-families' live in
;; the engine (cmacs-calculator.el), not here.  They were originally local to
;; the landing page, but the D-Bus and MCP surfaces need them too -- without
;; them a bare instance answers `calc_list' with nothing and `calc_eval
;; "bscall(...)"' with "unknown function" -- and one definition shared by
;; every surface is what keeps those answers consistent.


;;; Non-registry surfaces
;;
;; The registry holds calculators -- named functions with arguments.  The
;; surfaces below are ways of calculating rather than things to calculate, so
;; they have no registry entry and are listed separately.

(defun cmacs-calculator-menu--new-sheet (name content &optional symbolic)
  "Open a sheet buffer called NAME prefilled with CONTENT.
With SYMBOLIC non-nil the sheet permits free variables, which is what CAS
work needs.  The sheet is evaluated once so it opens with its answers
already in place."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-calculator-sheet-mode)
        (cmacs-calculator-sheet-mode))
      (when symbolic (setq cmacs-calculator-sheet-symbolic t))
      (when (zerop (buffer-size))
        (insert content)
        (goto-char (point-min))
        (ignore-errors (cmacs-calculator-sheet-eval-buffer))))
    (pop-to-buffer buffer)
    buffer))

(defun cmacs-calculator-scratch-sheet ()
  "Open the desktop scratch sheet: a sheet for whatever is at hand.

The sheet opens empty below its header.  It is a scratch pad, so the
header carries the syntax you need and then gets out of the way -- a
worked example sitting in the buffer is something to delete before you
can start, and it draws the eye past the one line that explains how
variables work."
  (interactive)
  (cmacs-calculator-menu--new-sheet
   "*cmacs-calculator-scratch*"
   (concat "# Scratch sheet -- one expression per line.\n"
           "#\n"
           "#   C-c C-c  evaluate the buffer      C-c C-e  evaluate this line\n"
           "#   C-c C-k  strip every result       C-c C-p  plot the line at point\n"
           "#\n"
           "# `NAME := EXPR' (note the colon) defines a variable that any\n"
           "# later line can use:\n"
           "#\n"
           "#   myvar := pi * 3\n"
           "#   sqrt(myvar)\n"
           "#\n"
           "# A plain `=' is equality, not assignment: `solve(x^2 = 4, x)'.\n"
           "# Lines starting with # are comments.\n"
           "\n")))

(defun cmacs-calculator-cas-sheet ()
  "Open a CAS sheet: symbolic algebra, with free variables allowed."
  (interactive)
  (cmacs-calculator-menu--new-sheet
   "*cmacs-calculator-cas*"
   (concat "# CAS sheet -- symbolic evaluation, so free variables are fine.\n"
           "# Constants are not folded here: wrap in evalv() to force them.\n"
           "\n"
           "deriv(x^3 + sin(x), x)\n"
           "integ(x^2, x)\n"
           "solve(x^2 - 4 = 0, x)\n"
           "evalv(sin(pi/2))\n")
   'symbolic))

(defun cmacs-calculator-convert (expr units)
  "Convert EXPR to UNITS and report the result.

With UNITS empty, EXPR is expressed in base SI units instead, so
\"2 G * 1.989e30 kg / c^2\" comes out in metres.  The result is echoed
and copied to the kill ring."
  (interactive
   (list (read-string "Convert expression: ")
         (read-string "To units (empty for base SI units): ")))
  (condition-case err
      (let ((result (if (string-empty-p (string-trim units))
                        (cmacs-calculator-to-base-units expr)
                      (cmacs-calculator-convert-units expr units))))
        (kill-new result)
        (message "%s = %s (copied)" expr result)
        result)
    (cmacs-calculator-error
     (message "Calculator: %s" (cmacs-calculator-error-message err))
     nil)))

(defconst cmacs-calculator-menu--surfaces
  '((:label "Scratch sheet"
     :doc "A .calc sheet for whatever is at hand"
     :action cmacs-calculator-scratch-sheet)
    (:label "CAS sheet"
     :doc "Symbolic algebra: derivatives, integrals, solving"
     :action cmacs-calculator-cas-sheet)
    (:label "Unit conversion"
     :doc "Convert between units, or reduce to base SI units"
     :action cmacs-calculator-convert)
    (:label "REPL buffer"
     :doc "Line-by-line evaluation, as `emacs --calc' gives you"
     :action cmacs-calculator-repl-buffer))
  "Ways of calculating that are not registry entries.
See the Commentary for why these are listed apart.")


;;; Capability reporting

(defun cmacs-calculator-menu--chart-tier ()
  "Return a description of the chart tier that is actually active."
  (let ((configured cmacs-calculator-chart-backend))
    (cond
     ((eq configured 'libregnum)
      (if (cmacs-calculator-chart--libregnum-available-p)
          "libregnum (GPU, own buffer)"
        "libregnum -- UNAVAILABLE (needs --with-cmacs-libregnum and a display)"))
     (t
      (let ((active (condition-case nil
                        (cmacs-calculator-chart--backend)
                      (error nil))))
        (pcase active
          ('svg "SVG (inline)")
          ('unicode
           (if (eq configured 'auto)
               "unicode text (no graphical display; SVG when one is present)"
             "unicode text"))
          ('nil (format "%s -- UNAVAILABLE in this session" configured))
          (other (format "%s" other))))))))

(defun cmacs-calculator-menu--capabilities ()
  "Return the capability lines for the header."
  (let ((registered (length (cmacs-calculator-list))))
    (list (format "Engine:  %s"
                  (if (cmacs-calculator-supported-p)
                      "GNU Calc, arbitrary precision"
                    "UNAVAILABLE -- GNU Calc did not load"))
          (format "Charts:  %s" (cmacs-calculator-menu--chart-tier))
          (format "Loaded:  %d calculator%s in %d categor%s"
                  registered (if (= registered 1) "" "s")
                  (length (cmacs-calculator-categories))
                  (if (= (length (cmacs-calculator-categories)) 1) "y" "ies")))))


;;; Templates

(defun cmacs-calculator-menu--template (entry)
  "Return a runnable sheet line for registry ENTRY.

Its first `:examples' entry when it has one -- an example is a call known
to work, with real numbers in it.  Otherwise a call built from the
`:args' names, which is a shape to fill in rather than something to
evaluate, but at least names every argument in order."
  (let ((examples (plist-get entry :examples)))
    (if examples
        (car (car examples))
      (format "%s(%s)"
              (plist-get entry :name)
              (mapconcat (lambda (arg) (format "%s" (car arg)))
                         (plist-get entry :args) ", ")))))

(defun cmacs-calculator-menu--sheet-for (entry)
  "Open a sheet prefilled for registry ENTRY."
  (let* ((name (plist-get entry :name))
         (args (plist-get entry :args))
         (template (cmacs-calculator-menu--template entry)))
    (cmacs-calculator-menu--new-sheet
     (format "*calc: %s*" name)
     (concat
      (format "# %s -- %s\n" name (or (plist-get entry :title) ""))
      (when-let* ((doc (plist-get entry :doc)))
        (concat (mapconcat (lambda (line) (concat "# " line))
                           (split-string doc "\n") "\n")
                "\n"))
      (when args
        (concat "#\n"
                (mapconcat
                 (lambda (arg)
                   (format "#   %-12s %s" (car arg) (or (cadr arg) "")))
                 args "\n")
                "\n"))
      (when-let* ((returns (plist-get entry :returns)))
        (format "#\n# Returns: %s\n" returns))
      "\n"
      template "\n"))))


;;; Rendering

(defvar-local cmacs-calculator-menu--filter nil
  "Current filter string, or nil for the full listing.")

(defun cmacs-calculator-menu--matches-p (entry filter)
  "Return non-nil if registry ENTRY matches FILTER.
Matched against the name, the title and the doc, so \"mortgage\" finds
the mortgage calculator even though its name is `mortgagepmt'."
  (or (null filter)
      (string-empty-p filter)
      (let ((needle (downcase filter)))
        (seq-some
         (lambda (field)
           (and field (string-match-p (regexp-quote needle) (downcase field))))
         (list (symbol-name (plist-get entry :name))
               (plist-get entry :title)
               (plist-get entry :doc))))))

(defun cmacs-calculator-menu--surface-matches-p (surface filter)
  "Return non-nil if SURFACE matches FILTER."
  (or (null filter)
      (string-empty-p filter)
      (let ((needle (downcase filter)))
        (seq-some
         (lambda (field)
           (and field (string-match-p (regexp-quote needle) (downcase field))))
         (list (plist-get surface :label) (plist-get surface :doc))))))

(defun cmacs-calculator-menu--insert-entry (label doc action)
  "Insert one selectable line: LABEL, DOC, invoking ACTION on RET."
  (insert (propertize (concat "  " (propertize (format "%-22s" label)
                                               'face 'cmacs-calculator-menu-name-face)
                              (propertize (or doc "")
                                          'face 'cmacs-calculator-menu-title-face)
                              "\n")
                      'cmacs-calculator-menu-action action)))

(defun cmacs-calculator-menu--render ()
  "Draw the landing page into the current buffer."
  (let ((inhibit-read-only t)
        (filter cmacs-calculator-menu--filter)
        (shown 0))
    (erase-buffer)
    (insert (propertize "CMacs Calculator\n" 'face 'cmacs-calculator-menu-heading-face))
    (insert "\n")
    (dolist (line (cmacs-calculator-menu--capabilities))
      (insert "  " line "\n"))
    (when (and filter (not (string-empty-p filter)))
      (insert (propertize (format "\n  Filter: %s   (`/' to change, `g' to clear)\n"
                                  filter)
                          'face 'font-lock-warning-face)))
    (insert "\n")

    ;; Surfaces first: they are how you get started, and the registry is a
    ;; reference you reach for once you know what you want.
    (let ((surfaces (seq-filter
                     (lambda (s) (cmacs-calculator-menu--surface-matches-p s filter))
                     cmacs-calculator-menu--surfaces)))
      (when surfaces
        (insert (propertize "Surfaces\n" 'face 'cmacs-calculator-menu-heading-face))
        (dolist (surface surfaces)
          (setq shown (1+ shown))
          (cmacs-calculator-menu--insert-entry
           (plist-get surface :label)
           (plist-get surface :doc)
           (plist-get surface :action)))
        (insert "\n")))

    ;; Everything else comes straight out of the registry.
    (dolist (category (cmacs-calculator-categories))
      (let ((entries (seq-filter
                      (lambda (e) (cmacs-calculator-menu--matches-p e filter))
                      (cmacs-calculator-list category))))
        (when entries
          (insert (propertize (format "%s\n" (capitalize (symbol-name category)))
                              'face 'cmacs-calculator-menu-heading-face))
          (dolist (entry entries)
            (setq shown (1+ shown))
            (cmacs-calculator-menu--insert-entry
             (symbol-name (plist-get entry :name))
             (plist-get entry :title)
             ;; Close over the entry itself, so the action cannot drift from
             ;; the line it was drawn for.
             (let ((entry entry))
               (lambda () (cmacs-calculator-menu--sheet-for entry)))))
          (insert "\n"))))

    (when (zerop shown)
      (insert (propertize
               (if (and filter (not (string-empty-p filter)))
                   (format "  Nothing matches `%s'.\n" filter)
                 "  No calculators are registered in this build.\n")
               'face 'font-lock-warning-face)))
    (insert "\n")
    (insert (propertize
             "  RET open   /  filter   n/p next/prev   g refresh   q quit\n"
             'face 'font-lock-comment-face))
    (goto-char (point-min))
    (cmacs-calculator-menu-next)))


;;; Navigation and commands

(defun cmacs-calculator-menu--action-at-point ()
  "Return the action of the entry at point, or nil."
  (get-text-property (point) 'cmacs-calculator-menu-action))

(defun cmacs-calculator-menu-open ()
  "Open the calculator or surface on this line."
  (interactive)
  (let ((action (cmacs-calculator-menu--action-at-point)))
    (unless action
      (user-error "No calculator on this line"))
    (call-interactively action)))

(defun cmacs-calculator-menu-next ()
  "Move to the next selectable line."
  (interactive)
  (let ((start (point))
        (found nil))
    (save-excursion
      (forward-line 1)
      (while (and (not (eobp)) (not found))
        (if (get-text-property (line-beginning-position)
                               'cmacs-calculator-menu-action)
            (setq found (line-beginning-position))
          (forward-line 1))))
    (goto-char (or found start))))

(defun cmacs-calculator-menu-previous ()
  "Move to the previous selectable line."
  (interactive)
  (let ((start (point))
        (found nil))
    (save-excursion
      (while (and (not (bobp)) (not found))
        (forward-line -1)
        (when (get-text-property (line-beginning-position)
                                 'cmacs-calculator-menu-action)
          (setq found (line-beginning-position)))))
    (goto-char (or found start))))

(defun cmacs-calculator-menu-filter (filter)
  "Show only calculators matching FILTER; empty FILTER shows everything."
  (interactive (list (read-string "Filter: " cmacs-calculator-menu--filter)))
  (setq cmacs-calculator-menu--filter (and (not (string-empty-p filter)) filter))
  (cmacs-calculator-menu--render))

(defun cmacs-calculator-menu-refresh ()
  "Redraw the page, clearing any filter."
  (interactive)
  (setq cmacs-calculator-menu--filter nil)
  (cmacs-calculator-menu--render))


;;; Mode

(defvar cmacs-calculator-menu-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-calculator-menu-mode'.")

;; Bound on every load, so re-evaluating this file during development does not
;; leave a half-populated map behind.
(let ((map cmacs-calculator-menu-mode-map))
  (define-key map (kbd "RET") #'cmacs-calculator-menu-open)
  (define-key map (kbd "n") #'cmacs-calculator-menu-next)
  (define-key map (kbd "p") #'cmacs-calculator-menu-previous)
  (define-key map (kbd "j") #'cmacs-calculator-menu-next)
  (define-key map (kbd "k") #'cmacs-calculator-menu-previous)
  (define-key map (kbd "/") #'cmacs-calculator-menu-filter)
  (define-key map (kbd "s") #'cmacs-calculator-menu-filter)
  (define-key map (kbd "g") #'cmacs-calculator-menu-refresh)
  (define-key map (kbd "q") #'quit-window))

(define-derived-mode cmacs-calculator-menu-mode special-mode "Calc-Menu"
  "Major mode for the calculator landing page.

\\{cmacs-calculator-menu-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-calculator ()
  "Open the CMacs calculator landing page.

Lists every calculator this build has, grouped by category, with RET
opening a sheet prefilled with a runnable call.  The listing is generated
from the registry, so it describes the build you are running rather than
a hand-kept list."
  (interactive)
  (cmacs-calculator-load-families)
  (let ((buffer (get-buffer-create cmacs-calculator-menu-buffer-name)))
    (with-current-buffer buffer
      (cmacs-calculator-menu-mode)
      (cmacs-calculator-menu--render))
    (pop-to-buffer buffer)
    buffer))

;; Under Evil (Doom) the state maps shadow single-key bindings; give this
;; mode's map precedence in every state.
(with-eval-after-load 'evil
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map cmacs-calculator-menu-mode-map)))

(provide 'cmacs-calculator-menu)
;;; cmacs-calculator-menu.el ends here
