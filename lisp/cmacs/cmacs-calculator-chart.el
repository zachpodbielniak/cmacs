;;; cmacs-calculator-chart.el --- Calculator charting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Charting for `cmacs-calculator', in two tiers.
;;
;; Tier 1 -- SVG (`svg.el'), the default.  Renders inline next to the formula
;; that produced it, works in batch and over TTY (via a unicode fallback),
;; needs no GL and no libregnum, and is testable without a display.  This is
;; where amortization curves, option payoff diagrams and function plots land
;; unless something better is asked for.
;;
;; Tier 2 -- libregnum, opt-in.  libregnum ships a full 2D chart module
;; (line/bar/pie/area/scatter/radar/candlestick/gauge/heatmap/histogram, with
;; axes, legends, tooltips, animation and hit-testing) rendered on the GPU
;; into an Emacs buffer.  It needs `--with-cmacs-libregnum' and a display.
;; See `cmacs-calculator-chart-open' and `cmacs/calculator/'.
;;
;; The tier is chosen by `cmacs-calculator-chart-backend'; the default `auto'
;; degrades SVG -> unicode as capabilities disappear, so a chart request never
;; hard-fails just because a build lacks GL.
;;
;; Data model
;; ----------
;; A chart takes a list of SERIES, each a plist:
;;
;;   (:name "Principal" :points ((0 . 1000) (1 . 950) ...) :color "#3b6fb0")
;;
;; which mirrors libregnum's `LrgChartDataSeries' / `LrgChartDataPoint' so
;; both tiers consume the same input.

;;; Code:

(require 'cmacs-calculator)
(require 'svg nil t)
(require 'seq)

(eval-when-compile (require 'cl-lib))

(declare-function cmacs-calculator-chart-supported-p "cmacs-calculator-chart-defuns.c")
(declare-function cmacs-calculator-chart-attach "cmacs-calculator-chart-defuns.c"
                  (buffer width height))
(declare-function cmacs-calculator-chart-set-type "cmacs-calculator-chart-defuns.c"
                  (buffer type))
(declare-function cmacs-calculator-chart-set-title "cmacs-calculator-chart-defuns.c"
                  (buffer title))
(declare-function cmacs-calculator-chart-clear-series "cmacs-calculator-chart-defuns.c"
                  (buffer))
(declare-function cmacs-calculator-chart-add-series "cmacs-calculator-chart-defuns.c"
                  (buffer name color points))
(declare-function cmacs-calculator-chart-refresh "cmacs-calculator-chart-defuns.c"
                  (buffer))


;;; Customization

(defgroup cmacs-calculator-chart nil
  "Charting for the CMacs calculator."
  :group 'cmacs-calculator
  :prefix "cmacs-calculator-chart-")

(defcustom cmacs-calculator-chart-backend 'auto
  "Which renderer draws calculator charts.

`auto'      pick the best available: SVG when the frame is graphical and
            libsvg is present, otherwise a unicode approximation.
`svg'       always SVG; signals if unavailable.
`unicode'   always the text approximation, useful over a TTY or in batch.
`libregnum' GPU chart in its own buffer; requires --with-cmacs-libregnum
            and a display.  See `cmacs-calculator-chart-open'.

Note that `libregnum' is not a drop-in for the inline tiers: it opens a
buffer rather than returning an insertable string."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "SVG" svg)
                 (const :tag "Unicode text" unicode)
                 (const :tag "libregnum (GPU)" libregnum))
  :group 'cmacs-calculator-chart)

(defcustom cmacs-calculator-chart-width 480
  "Default chart width in pixels."
  :type 'integer
  :group 'cmacs-calculator-chart)

(defcustom cmacs-calculator-chart-height 300
  "Default chart height in pixels."
  :type 'integer
  :group 'cmacs-calculator-chart)

(defcustom cmacs-calculator-chart-palette
  '("#3b6fb0" "#b04f3b" "#3bb06a" "#b0a13b" "#7a3bb0"
    "#3bb0a8" "#b03b8e" "#6f7a8a")
  "Series colours, cycled in order."
  :type '(repeat string)
  :group 'cmacs-calculator-chart)

(defcustom cmacs-calculator-chart-samples 200
  "Number of points sampled when plotting a function expression."
  :type 'integer
  :group 'cmacs-calculator-chart)


;;; Backend selection

(defun cmacs-calculator-chart--svg-available-p ()
  "Return non-nil if SVG charts can be rendered in this session."
  (and (fboundp 'svg-create)
       (display-graphic-p)
       (image-type-available-p 'svg)))

(defun cmacs-calculator-chart--libregnum-available-p ()
  "Return non-nil if the libregnum GPU chart backend is usable."
  (and (fboundp 'cmacs-calculator-chart-supported-p)
       (cmacs-calculator-chart-supported-p)))

(defun cmacs-calculator-chart--backend ()
  "Return the backend symbol to use for an inline chart."
  (pcase cmacs-calculator-chart-backend
    ('auto (if (cmacs-calculator-chart--svg-available-p) 'svg 'unicode))
    ('svg (if (cmacs-calculator-chart--svg-available-p)
              'svg
            (signal 'cmacs-calculator-error
                    (list "SVG charts unavailable in this session"))))
    ('libregnum 'libregnum)
    (other other)))


;;; Series helpers

(defun cmacs-calculator-chart--series-points (series)
  "Return the numeric (X . Y) points of SERIES, dropping non-numeric ones."
  (seq-filter (lambda (p) (and (numberp (car-safe p)) (numberp (cdr-safe p))))
              (plist-get series :points)))

(defun cmacs-calculator-chart--color (series index)
  "Return the colour for SERIES, falling back to palette entry INDEX."
  (or (plist-get series :color)
      (nth (mod index (length cmacs-calculator-chart-palette))
           cmacs-calculator-chart-palette)))

(defun cmacs-calculator-chart--bounds (series-list)
  "Return (XMIN XMAX YMIN YMAX) spanning every series in SERIES-LIST.
Degenerate ranges are padded so a constant series still renders as a
line rather than collapsing to a division by zero."
  (let ((xs nil) (ys nil))
    (dolist (s series-list)
      (dolist (p (cmacs-calculator-chart--series-points s))
        (push (car p) xs)
        (push (cdr p) ys)))
    (unless xs
      (signal 'cmacs-calculator-error (list "chart has no plottable points")))
    (let ((xmin (apply #'min xs)) (xmax (apply #'max xs))
          (ymin (apply #'min ys)) (ymax (apply #'max ys)))
      (when (= xmin xmax) (setq xmin (- xmin 0.5) xmax (+ xmax 0.5)))
      (when (= ymin ymax) (setq ymin (- ymin 0.5) ymax (+ ymax 0.5)))
      (list xmin xmax ymin ymax))))

(defun cmacs-calculator-chart--nice-ticks (lo hi count)
  "Return about COUNT round tick values spanning LO to HI.
Picks a 1/2/5 x 10^n step so labels read as round numbers instead of
whatever the data bounds happen to be."
  (let* ((span (- hi lo))
         (raw (/ span (max 1 count)))
         (mag (expt 10 (floor (log raw 10))))
         (norm (/ raw mag))
         (step (* mag (cond ((< norm 1.5) 1) ((< norm 3) 2) ((< norm 7) 5) (t 10))))
         (start (* (ceiling (/ lo step)) step))
         (out nil))
    (cl-loop for v = start then (+ v step)
             while (<= v (+ hi (* step 1e-9)))
             do (push v out))
    (nreverse out)))

(defun cmacs-calculator-chart--fmt (v)
  "Format tick value V compactly."
  (cond ((and (integerp v) (< (abs v) 1000000)) (number-to-string v))
        ((zerop v) "0")
        ((or (>= (abs v) 100000) (< (abs v) 0.001)) (format "%.1e" v))
        ((= v (ftruncate v)) (format "%d" (truncate v)))
        (t (format "%.4g" v))))


;;; SVG rendering

(defconst cmacs-calculator-chart--margin '(48 16 34 16)
  "Plot margins as (LEFT TOP BOTTOM RIGHT) in pixels.
Left and bottom are wider to hold the axis tick labels.")

(defun cmacs-calculator-chart--svg (type series-list opts)
  "Render SERIES-LIST as a TYPE chart, returning a propertized string.
OPTS is a plist accepting :width, :height, :title, :xlabel and :ylabel."
  (let* ((w (or (plist-get opts :width) cmacs-calculator-chart-width))
         (h (or (plist-get opts :height) cmacs-calculator-chart-height))
         (title (plist-get opts :title))
         (ml (nth 0 cmacs-calculator-chart--margin))
         (mt (+ (nth 1 cmacs-calculator-chart--margin) (if title 16 0)))
         (mb (nth 2 cmacs-calculator-chart--margin))
         (mr (nth 3 cmacs-calculator-chart--margin))
         (pw (- w ml mr))
         (ph (- h mt mb))
         (fg (face-foreground 'default nil t))
         (dim "#8a8a8a")
         (svg (svg-create w h)))
    (when (< (min pw ph) 20)
      (signal 'cmacs-calculator-error (list "chart area too small" w h)))
    (pcase type
      ('pie (cmacs-calculator-chart--svg-pie svg series-list w h mt))
      (_ (cmacs-calculator-chart--svg-xy svg type series-list
                                         ml mt pw ph fg dim)))
    (when title
      (svg-text svg title :x (/ w 2) :y 14 :font-size 12
                :text-anchor "middle" :fill (or fg "black")))
    (propertize (format "[%s chart]" type)
                'display (svg-image svg :ascent 'center)
                'help-echo (or title (format "%s chart" type)))))

(defun cmacs-calculator-chart--svg-xy (svg type series-list ml mt pw ph fg dim)
  "Draw an axed TYPE chart of SERIES-LIST into SVG.
ML and MT are the left/top margins, PW and PH the plot size, FG and DIM
the foreground and muted colours."
  (pcase-let* ((`(,xmin ,xmax ,ymin ,ymax)
                (cmacs-calculator-chart--bounds series-list))
               ;; Bars and areas are read against zero, so the axis must
               ;; include it or the picture lies about magnitude.
               (ymin (if (memq type '(bar area)) (min 0 ymin) ymin))
               (ymax (if (memq type '(bar area)) (max 0 ymax) ymax))
               (xr (float (- xmax xmin)))
               (yr (float (- ymax ymin)))
               (sx (lambda (x) (+ ml (* pw (/ (- x xmin) xr)))))
               (sy (lambda (y) (+ mt (- ph (* ph (/ (- y ymin) yr)))))))
    ;; Grid + ticks.
    (dolist (ty (cmacs-calculator-chart--nice-ticks ymin ymax 5))
      (let ((py (funcall sy ty)))
        (svg-line svg ml py (+ ml pw) py :stroke-color dim
                  :stroke-width 0.4 :stroke-dasharray "2,3")
        (svg-text svg (cmacs-calculator-chart--fmt ty)
                  :x (- ml 4) :y (+ py 3) :font-size 9
                  :text-anchor "end" :fill dim)))
    (dolist (tx (cmacs-calculator-chart--nice-ticks xmin xmax 6))
      (let ((px (funcall sx tx)))
        (svg-text svg (cmacs-calculator-chart--fmt tx)
                  :x px :y (+ mt ph 12) :font-size 9
                  :text-anchor "middle" :fill dim)))
    ;; Axes.
    (svg-line svg ml mt ml (+ mt ph) :stroke-color (or fg "black") :stroke-width 0.8)
    (svg-line svg ml (+ mt ph) (+ ml pw) (+ mt ph)
              :stroke-color (or fg "black") :stroke-width 0.8)
    ;; Zero line, when zero is interior to the y range.
    (when (and (< ymin 0) (> ymax 0))
      (let ((py (funcall sy 0)))
        (svg-line svg ml py (+ ml pw) py :stroke-color (or fg "black")
                  :stroke-width 0.5)))
    ;; Series.
    (let ((index -1)
          (nseries (length series-list)))
      (dolist (s series-list)
        (setq index (1+ index))
        (let ((pts (cmacs-calculator-chart--series-points s))
              (color (cmacs-calculator-chart--color s index)))
          (pcase type
            ('line
             (when (cdr pts)
               (svg-polyline svg (mapcar (lambda (p)
                                           (cons (funcall sx (car p))
                                                 (funcall sy (cdr p))))
                                         pts)
                             :stroke-color color :stroke-width 1.5 :fill "none")))
            ('area
             (when (cdr pts)
               (svg-polygon svg (append
                                 (list (cons (funcall sx (car (car pts)))
                                             (funcall sy (max ymin 0))))
                                 (mapcar (lambda (p)
                                           (cons (funcall sx (car p))
                                                 (funcall sy (cdr p))))
                                         pts)
                                 (list (cons (funcall sx (car (car (last pts))))
                                             (funcall sy (max ymin 0)))))
                            :fill color :fill-opacity 0.35
                            :stroke-color color :stroke-width 1.2)))
            ('scatter
             (dolist (p pts)
               (svg-circle svg (funcall sx (car p)) (funcall sy (cdr p)) 2.2
                           :fill color)))
            ('bar
             ;; Slot each series side by side within its x step so bars do
             ;; not paint over each other.
             (let* ((n (max 1 (length pts)))
                    (slot (/ (float pw) n))
                    (bw (max 1.0 (/ (* slot 0.8) nseries)))
                    (zero (funcall sy (max ymin 0))))
               (dolist (p pts)
                 (let* ((cx (funcall sx (car p)))
                        (py (funcall sy (cdr p)))
                        (bx (+ (- cx (/ (* bw nseries) 2)) (* index bw))))
                   (svg-rectangle svg bx (min py zero) bw (abs (- zero py))
                                  :fill color)))))
            (_ (signal 'cmacs-calculator-error
                       (list "unknown chart type" type)))))))
    ;; Legend, only when it carries information.
    (when (and (cdr series-list)
               (seq-some (lambda (s) (plist-get s :name)) series-list))
      (let ((ly (+ mt 4)) (index -1))
        (dolist (s series-list)
          (setq index (1+ index))
          (when (plist-get s :name)
            (svg-rectangle svg (+ ml pw -70) ly 8 8
                           :fill (cmacs-calculator-chart--color s index))
            (svg-text svg (truncate-string-to-width (plist-get s :name) 12)
                      :x (+ ml pw -58) :y (+ ly 8) :font-size 9
                      :fill (or fg "black"))
            (setq ly (+ ly 12))))))))

(defun cmacs-calculator-chart--svg-pie (svg series-list w h mt)
  "Draw a pie of the first series in SERIES-LIST into SVG (W x H, top MT).
Each point's Y value is a slice; its X value is ignored."
  (let* ((pts (cmacs-calculator-chart--series-points (car series-list)))
         (labels (plist-get (car series-list) :labels))
         (total (apply #'+ (mapcar (lambda (p) (abs (cdr p))) pts)))
         (cx (/ w 2.0))
         (cy (+ mt (/ (- h mt) 2.0)))
         (r (* 0.38 (min w (- h mt))))
         (angle (- (/ float-pi 2)))
         (index -1))
    (when (zerop total)
      (signal 'cmacs-calculator-error (list "pie chart values sum to zero")))
    (dolist (p pts)
      (setq index (1+ index))
      (let* ((frac (/ (abs (cdr p)) (float total)))
             (sweep (* 2 float-pi frac))
             (a2 (+ angle sweep))
             (x1 (+ cx (* r (cos angle)))) (y1 (+ cy (* r (sin angle))))
             (x2 (+ cx (* r (cos a2))))    (y2 (+ cy (* r (sin a2))))
             (large (if (> sweep float-pi) 1 0))
             (color (nth (mod index (length cmacs-calculator-chart-palette))
                         cmacs-calculator-chart-palette)))
        ;; A full-circle slice cannot be expressed as one arc (start and end
        ;; coincide), so draw it as a plain circle instead.
        (if (>= frac 0.9999)
            (svg-circle svg cx cy r :fill color)
          (svg-node svg 'path
                    :d (format "M %.2f %.2f L %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f Z"
                               cx cy x1 y1 r r large x2 y2)
                    :fill color))
        (when (and labels (> frac 0.05))
          (let* ((mid (+ angle (/ sweep 2)))
                 (lx (+ cx (* r 0.65 (cos mid))))
                 (ly (+ cy (* r 0.65 (sin mid)))))
            (svg-text svg (format "%s" (or (nth index labels) ""))
                      :x lx :y ly :font-size 9 :text-anchor "middle"
                      :fill "white")))
        (setq angle a2)))))


;;; Unicode fallback

(defconst cmacs-calculator-chart--blocks "▁▂▃▄▅▆▇█"
  "Block characters used by the unicode fallback, ascending in height.")

(defun cmacs-calculator-chart--unicode (series-list opts)
  "Render SERIES-LIST as text, for a TTY or batch session.
A compact per-series sparkline, regardless of the chart type asked for --
the point is to degrade rather than to reproduce the shape.  OPTS is as
in `cmacs-calculator-chart--svg'; only :title is honoured."
  (let ((title (plist-get opts :title))
        (lines nil))
    (dolist (s series-list)
      (let* ((pts (cmacs-calculator-chart--series-points s))
             (ys (mapcar #'cdr pts)))
        (when ys
          (let* ((mn (apply #'min ys)) (mx (apply #'max ys))
                 (rng (max 1e-9 (- mx mn)))
                 (spark (mapconcat
                         (lambda (v)
                           (string (aref cmacs-calculator-chart--blocks
                                         (min 7 (floor (* 7 (/ (- v mn) rng)))))))
                         ys "")))
            (push (format "%s%s  [%s .. %s]"
                          (if (plist-get s :name)
                              (format "%-12s " (plist-get s :name)) "")
                          spark
                          (cmacs-calculator-chart--fmt mn)
                          (cmacs-calculator-chart--fmt mx))
                  lines)))))
    (unless lines
      (signal 'cmacs-calculator-error (list "chart has no plottable points")))
    (concat (if title (concat title "\n") "")
            (mapconcat #'identity (nreverse lines) "\n"))))


;;; Public entry points

(defun cmacs-calculator-chart (type series-list &rest opts)
  "Render SERIES-LIST as a chart of TYPE and return it as a string.

TYPE is one of `line', `bar', `area', `scatter' or `pie'.  SERIES-LIST
is a list of plists, each (:name STRING :points ((X . Y) ...) :color
STRING); `pie' additionally honours :labels.

OPTS is a plist of :width, :height, :title, :xlabel and :ylabel.

The returned string carries a display property holding the image, so it
can simply be inserted into any buffer.  On a TTY or in batch the result
is a unicode approximation instead, so callers need no capability check
of their own.  Rendering respects `cmacs-calculator-chart-backend'."
  (unless series-list
    (signal 'cmacs-calculator-error (list "no series to chart")))
  (pcase (cmacs-calculator-chart--backend)
    ('svg (cmacs-calculator-chart--svg type series-list opts))
    ('unicode (cmacs-calculator-chart--unicode series-list opts))
    ('libregnum
     (signal 'cmacs-calculator-error
             (list "libregnum charts open a buffer; use cmacs-calculator-chart-open")))
    (other (signal 'cmacs-calculator-error (list "unknown chart backend" other)))))

(defun cmacs-calculator-chart-sample (expr var from to &optional samples modes)
  "Sample EXPR over VAR from FROM to TO, returning a list of (X . Y).

EXPR is a Calc expression string such as \"sin(x)\"; VAR is the variable
name in it.  SAMPLES defaults to `cmacs-calculator-chart-samples'.
MODES is as in `cmacs-calculator-eval'.

Points where the expression has no real numeric value -- a pole, a
domain error, a complex result -- are omitted rather than aborting the
whole plot, so \"1/x\" and \"sqrt(x)\" plot over ranges that include
their bad points."
  (let* ((samples (or samples cmacs-calculator-chart-samples))
         (from (float from))
         (to (float to))
         (step (/ (- to from) (max 1 (1- samples))))
         (out nil))
    (when (<= samples 1)
      (signal 'cmacs-calculator-error (list "need at least two samples" samples)))
    (dotimes (i samples)
      (let* ((x (+ from (* i step)))
             ;; The expression names VAR, which strict numeric evaluation
             ;; would reject as an unbound variable -- but `subst' is about
             ;; to bind it, so allow variables and demand a number back.
             (y (ignore-errors
                  (cmacs-calculator-eval-symbolic-number
                   (format "evalv(subst(%s, %s, %s))" expr var
                           (cmacs-calculator--fmt-float x))
                   modes))))
        (when (and y (not (isnan y))
                   (not (= y 1.0e+INF)) (not (= y -1.0e+INF)))
          (push (cons x y) out))))
    (nreverse out)))

(defun cmacs-calculator--fmt-float (x)
  "Format float X for splicing into a Calc expression without precision loss."
  (format "%.17g" x))

(defun cmacs-calculator-plot (expr var from to &rest opts)
  "Plot Calc expression EXPR over VAR from FROM to TO; return a chart string.

  (cmacs-calculator-plot \"sin(x)\" \"x\" -3.14159 3.14159)

OPTS is passed to `cmacs-calculator-chart', plus :samples to control the
sample count.  The expression is evaluated through the calculator
engine, so it sees the same corrected precedence and radian angle mode
as everything else."
  (let* ((samples (plist-get opts :samples))
         (pts (cmacs-calculator-chart-sample expr var from to samples)))
    (unless pts
      (signal 'cmacs-calculator-error
              (list "expression has no real values over that range" expr)))
    (apply #'cmacs-calculator-chart 'line
           (list (list :name expr :points pts))
           (append (list :title (or (plist-get opts :title) expr)) opts))))


;;; libregnum tier

(defun cmacs-calculator-chart-open (type series-list &rest opts)
  "Open SERIES-LIST as a GPU-rendered TYPE chart in its own buffer.

Uses libregnum's chart module, which adds animation, hover tooltips and
hit-testing over the inline SVG tier, and supports types SVG does not
\(candlestick, heatmap, radar, gauge, histogram).  Requires a cmacs
built --with-cmacs-libregnum and a graphical display.

OPTS accepts :buffer, :width, :height and :title.  Returns the buffer.

Renders identically under pgtk and under `emacs --lrg': both go through
the shared libregnum view, which owns the backend difference."
  (unless (cmacs-calculator-chart--libregnum-available-p)
    (signal 'cmacs-calculator-error
            (list "libregnum charts unavailable: needs --with-cmacs-libregnum and a display")))
  (let* ((buffer (get-buffer-create
                  (or (plist-get opts :buffer) "*cmacs-calculator-chart*")))
         (w (or (plist-get opts :width) cmacs-calculator-chart-width))
         (h (or (plist-get opts :height) cmacs-calculator-chart-height)))
    (with-current-buffer buffer
      (cmacs-calculator-chart-mode)
      (cmacs-calculator-chart-attach buffer w h)
      (cmacs-calculator-chart-set-type buffer type)
      (when (plist-get opts :title)
        (cmacs-calculator-chart-set-title buffer (plist-get opts :title)))
      (cmacs-calculator-chart-clear-series buffer)
      (let ((index -1))
        (dolist (s series-list)
          (setq index (1+ index))
          (cmacs-calculator-chart-add-series
           buffer
           (or (plist-get s :name) (format "series %d" (1+ index)))
           (cmacs-calculator-chart--color s index)
           (cmacs-calculator-chart--series-points s))))
      (cmacs-calculator-chart-refresh buffer))
    (pop-to-buffer buffer)
    buffer))

(defvar cmacs-calculator-chart-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'cmacs-calculator-chart-redraw)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-calculator-chart-mode'.")

(defun cmacs-calculator-chart-redraw ()
  "Re-render the chart in the current buffer."
  (interactive)
  (when (fboundp 'cmacs-calculator-chart-refresh)
    (cmacs-calculator-chart-refresh (current-buffer))))

(define-derived-mode cmacs-calculator-chart-mode special-mode "Calc-Chart"
  "Major mode for a libregnum-rendered calculator chart.

\\{cmacs-calculator-chart-mode-map}"
  (buffer-disable-undo)
  (setq-local cursor-type nil))

(provide 'cmacs-calculator-chart)
;;; cmacs-calculator-chart.el ends here
