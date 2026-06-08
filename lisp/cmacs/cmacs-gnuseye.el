;;; cmacs-gnuseye.el --- GNU's Eye: live planetary situational globe  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; GNU's Eye (gnuseye) is a Google-Earth / Palantir-style live 3D globe
;; rendered through the libregnum subsystem.  Real-time geospatial feeds
;; (satellites, aircraft, vessels, weather, geo-events) are drawn as
;; clickable markers on a textured Earth.
;;
;; The crux is EXTENSIBILITY: data sources are LAYERS defined in Elisp via
;; `cmacs-gnuseye-define-layer'.  Each layer supplies an async fetch
;; function that returns a list of entity plists; the C core
;; (`cmacs-gnuseye-set-entities') renders whatever entities a layer pushes
;; and stashes each entity as its marker's pick payload.  Adding a new feed
;; is one macro call -- no rebuild.
;;
;; Entity plist schema (what a layer's fetch returns):
;;   (:id S :lat F :lon F                       ; required
;;    :alt F :heading F :speed F :kind SYM       ; optional
;;    :label S :color "#rrggbb" :scale F :trail LIST
;;    :detail FN :data ANY :ts F)
;; Only :id :lat :lon are required.  :kind selects an icon/colour style.
;; :data is an opaque escape hatch surfaced in the detail view.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url)

(defgroup cmacs-gnuseye nil
  "GNU's Eye live planetary globe."
  :group 'cmacs
  :prefix "cmacs-gnuseye-")

(defcustom cmacs-gnuseye-base-texture nil
  "Path to an equirectangular Earth texture (e.g. NASA Blue Marble).
When nil or missing, a procedural ocean+graticule globe is used."
  :type '(choice (const :tag "Procedural" nil) (file :must-match t))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-default-layers '(satellites aircraft quakes)
  "Layer names enabled automatically when the globe opens."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-layer-files
  '(cmacs-gnuseye-astro cmacs-gnuseye-air
    cmacs-gnuseye-marine cmacs-gnuseye-weather)
  "Feature files providing the built-in layers, loaded when the globe opens."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-keys-file
  (expand-file-name "cmacs/gnuseye/keys.el"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "Optional alist file mapping API-key names to values.
Read on demand by `cmacs-gnuseye-secret'.  Keep it out of version control."
  :type 'file
  :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-buffer nil
  "The active GNU's Eye globe buffer that layer timers push entities to.")

;;;; Kind styles -------------------------------------------------------------

(defconst cmacs-gnuseye--kind-codes
  '((generic . 0) (satellite . 1) (aircraft . 2) (ship . 3)
    (quake . 4) (fire . 5) (launch . 6) (storm . 7) (camera . 8) (city . 9))
  "Marker kind symbol -> C CmacsGnuseyeMarkerKind code.")

(defcustom cmacs-gnuseye-kind-styles
  '((satellite :color "#9ad0ff" :scale 1.0)
    (aircraft  :color "#ffd24a" :scale 1.0)
    (ship      :color "#7cfc98" :scale 1.0)
    (quake     :color "#ff5a5a" :scale 1.4)
    (fire      :color "#ff8c1a" :scale 1.1)
    (launch    :color "#ff7be5" :scale 1.3)
    (storm     :color "#b0b0ff" :scale 1.2)
    (camera    :color "#7ad7ff" :scale 1.0)
    (city      :color "#dddddd" :scale 0.8)
    (generic   :color "#ffd24a" :scale 1.0))
  "Per-kind default marker style (:color hex, :scale multiplier)."
  :type '(alist :key-type symbol :value-type plist)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--color->rgba (color &optional alpha)
  "Convert COLOR (\"#rrggbb\" or \"#rrggbbaa\") to an integer 0xRRGGBBAA.
ALPHA (0-255) is applied when COLOR has no alpha (default 255)."
  (let ((a (or alpha 255)))
    (if (and (stringp color) (string-prefix-p "#" color))
        (let ((hex (substring color 1)))
          (cond
           ((= (length hex) 6) (logior (ash (string-to-number hex 16) 8) a))
           ((= (length hex) 8) (string-to-number hex 16))
           (t (logior (ash #xffd24a 8) a))))
      (logior (ash #xffd24a 8) a))))

;;;; Entity normalisation ----------------------------------------------------

(defun cmacs-gnuseye--normalize-trail (trail)
  "Normalise TRAIL (list/vector of (LAT LON [ALT])) to a vector of [LAT LON ALT]."
  (when (and trail (> (length trail) 1))
    (vconcat
     (mapcar (lambda (p)
               (vector (float (or (elt p 0) 0.0))
                       (float (or (elt p 1) 0.0))
                       (float (or (and (> (length p) 2) (elt p 2)) 0.0))))
             (append trail nil)))))

(defun cmacs-gnuseye--normalize-entity (e)
  "Normalise a layer entity plist E into the C-facing form.
Resolves :kind to its integer code and :color to packed RGBA, defaults
missing fields, and preserves the original keys (:detail :data ...) so the
stored payload drives the detail view."
  (let* ((kind  (or (plist-get e :kind) 'generic))
         (style (alist-get kind cmacs-gnuseye-kind-styles))
         (color (or (plist-get e :color) (plist-get style :color) "#ffd24a"))
         (scale (float (or (plist-get e :scale) (plist-get style :scale) 1.0)))
         (code  (or (alist-get kind cmacs-gnuseye--kind-codes) 0))
         (lab   (plist-get e :label)))
    (list :id        (format "%s" (or (plist-get e :id) ""))
          :lat       (float (or (plist-get e :lat) 0.0))
          :lon       (float (or (plist-get e :lon) 0.0))
          :alt       (float (or (plist-get e :alt) 0.0))
          :heading   (float (or (plist-get e :heading) -1.0))
          :scale     scale
          :kind      code
          :kind-name kind
          :color     (cmacs-gnuseye--color->rgba color)
          :label     (and lab (format "%s" lab))
          :label-mode (or (plist-get e :label-mode) 1) ; selected
          :trail     (cmacs-gnuseye--normalize-trail (plist-get e :trail))
          :detail    (plist-get e :detail)
          :data      (plist-get e :data)
          :speed     (plist-get e :speed)
          :ts        (plist-get e :ts))))

(defun cmacs-gnuseye--entities->vector (entities)
  "Normalise a list of layer ENTITIES into the vector C wants."
  (vconcat (delq nil (mapcar #'cmacs-gnuseye--normalize-entity entities))))

;;;; Fetch helpers -----------------------------------------------------------

(defun cmacs-gnuseye-fetch-text (url callback &optional headers)
  "GET URL asynchronously; call (CALLBACK BODY-STRING) or (CALLBACK nil).
HEADERS is an alist of (NAME . VALUE).  Prefers the native libsoup client
when built, else falls back to `url-retrieve' so a layer needs no C."
  (if (fboundp 'cmacs-gnuseye-http-get-async)
      (cmacs-gnuseye-http-get-async
       url (lambda (status body) (funcall callback (and status body))) headers)
    (let ((url-request-extra-headers headers))
      (url-retrieve
       url
       (lambda (status)
         (let ((body (unless (plist-get status :error)
                       (goto-char (point-min))
                       (when (re-search-forward "\n\n" nil t)
                         (decode-coding-string
                          (buffer-substring-no-properties (point) (point-max))
                          'utf-8)))))
           (funcall callback body)))
       nil t t))))

(defun cmacs-gnuseye-fetch-json (url callback &optional headers array-type)
  "GET URL and call (CALLBACK PARSED) with the parsed JSON, or (CALLBACK nil).
HEADERS is an alist of (NAME . VALUE).  ARRAY-TYPE is passed to
`json-parse-string' (default `list')."
  (cmacs-gnuseye-fetch-text
   url
   (lambda (body)
     (funcall callback
              (and body (stringp body)
                   (condition-case nil
                       (json-parse-string body :object-type 'alist
                                          :array-type (or array-type 'list)
                                          :null-object nil :false-object nil)
                     (error nil)))))
   headers))

;;;; Secrets -----------------------------------------------------------------

(defvar cmacs-gnuseye--keys nil)
(defvar cmacs-gnuseye--keys-loaded nil)

(defun cmacs-gnuseye-secret (name &optional default)
  "Resolve an API key NAME: env var, then `cmacs-gnuseye-keys-file', then DEFAULT."
  (unless cmacs-gnuseye--keys-loaded
    (setq cmacs-gnuseye--keys-loaded t)
    (when (file-readable-p cmacs-gnuseye-keys-file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents cmacs-gnuseye-keys-file)
          (setq cmacs-gnuseye--keys (read (current-buffer)))))))
  (or (getenv name) (cdr (assoc name cmacs-gnuseye--keys)) default))

;;;; Layer registry ----------------------------------------------------------

(cl-defstruct (cmacs-gnuseye-layer (:constructor cmacs-gnuseye--make-layer))
  name title group fetch interval default-on detail kind needs-key
  timer enabled last-fetch last-error in-flight)

(defvar cmacs-gnuseye--layers (make-hash-table :test 'eq)
  "Registry of defined layers: NAME symbol -> `cmacs-gnuseye-layer'.")

(defmacro cmacs-gnuseye-define-layer (name &rest props)
  "Define (or redefine) a GNU's Eye data layer NAME.
PROPS is a plist with:
  :title      human-readable string
  :group      grouping symbol (astronomical/air/marine/weather/...)
  :kind       default marker kind symbol for this layer
  :fetch      (lambda (CALLBACK) ...) that calls (CALLBACK ENTITIES) async
  :interval   refresh seconds (nil = fetch once)
  :default-on non-nil to allow auto-enable
  :detail     (lambda (ENTITY) ...) to render a clicked entity (optional)
  :needs-key  a key name string this layer requires (optional)"
  (declare (indent 1))
  `(progn
     (puthash ',name
              (cmacs-gnuseye--make-layer
               :name ',name
               :title ,(plist-get props :title)
               :group ,(plist-get props :group)
               :kind ,(plist-get props :kind)
               :fetch ,(plist-get props :fetch)
               :interval ,(plist-get props :interval)
               :default-on ,(plist-get props :default-on)
               :detail ,(plist-get props :detail)
               :needs-key ,(plist-get props :needs-key))
              cmacs-gnuseye--layers)
     ',name))

(defun cmacs-gnuseye--refresh-layer (layer)
  "Run LAYER's fetch and push its entities to the globe."
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf)
               (cmacs-gnuseye-attached-p buf)
               (not (cmacs-gnuseye-layer-in-flight layer)))
      (setf (cmacs-gnuseye-layer-in-flight layer) t)
      (condition-case err
          (funcall
           (cmacs-gnuseye-layer-fetch layer)
           (lambda (entities)
             (setf (cmacs-gnuseye-layer-in-flight layer) nil
                   (cmacs-gnuseye-layer-last-fetch layer) (float-time)
                   (cmacs-gnuseye-layer-last-error layer) nil)
             (when (and buf (buffer-live-p buf)
                        (cmacs-gnuseye-attached-p buf))
               (condition-case e2
                   (cmacs-gnuseye-set-entities
                    buf (cmacs-gnuseye-layer-name layer)
                    (cmacs-gnuseye--entities->vector (or entities nil)))
                 (error
                  (setf (cmacs-gnuseye-layer-last-error layer)
                        (error-message-string e2)))))))
        (error
         (setf (cmacs-gnuseye-layer-in-flight layer) nil
               (cmacs-gnuseye-layer-last-error layer)
               (error-message-string err)))))))

(defun cmacs-gnuseye--enable-layer (layer)
  "Enable LAYER: fetch now and (re)arm its refresh timer."
  (cmacs-gnuseye--disable-layer layer)
  (setf (cmacs-gnuseye-layer-enabled layer) t)
  (cmacs-gnuseye--refresh-layer layer)
  (let ((iv (cmacs-gnuseye-layer-interval layer)))
    (when (and iv (> iv 0))
      (setf (cmacs-gnuseye-layer-timer layer)
            (run-with-timer (+ iv (random 3)) iv
                            #'cmacs-gnuseye--refresh-layer layer)))))

(defun cmacs-gnuseye--disable-layer (layer)
  "Disable LAYER: cancel its timer and clear its markers."
  (when (timerp (cmacs-gnuseye-layer-timer layer))
    (cancel-timer (cmacs-gnuseye-layer-timer layer)))
  (setf (cmacs-gnuseye-layer-timer layer) nil
        (cmacs-gnuseye-layer-enabled layer) nil)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer))
    (ignore-errors
      (cmacs-gnuseye-clear-layer cmacs-gnuseye-buffer
                                 (cmacs-gnuseye-layer-name layer)))))

(defun cmacs-gnuseye--load-layers ()
  "Load the built-in layer feature files."
  (dolist (f cmacs-gnuseye-layer-files)
    (require f nil t)))

;;;; Pick + detail -----------------------------------------------------------

(defun cmacs-gnuseye--on-pick (buffer node-id)
  "Handle a marker click: look up the entity and show its detail view.
Called from `cmacs-libregnum--node-clicked' on the cmacs context."
  (when (and (integerp node-id) (>= node-id 0))
    (let ((e (ignore-errors (cmacs-gnuseye-entity-at buffer node-id))))
      (when e
        (let ((detail (plist-get e :detail)))
          (if (functionp detail)
              (funcall detail e)
            (cmacs-gnuseye--default-detail e)))))))

(defun cmacs-gnuseye--default-detail (e)
  "Render entity E into a side detail buffer."
  (let* ((label (or (plist-get e :label) (plist-get e :id) "entity"))
         (buf (get-buffer-create (format "*gnuseye: %s*" label))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" label) 'face 'bold))
        (insert (make-string (max 8 (length label)) ?─) "\n\n")
        (insert (format "kind     : %s\n" (or (plist-get e :kind-name) "?")))
        (insert (format "lat,lon  : %.4f, %.4f\n"
                        (plist-get e :lat) (plist-get e :lon)))
        (when (and (plist-get e :alt) (> (plist-get e :alt) 0))
          (insert (format "altitude : %.1f km\n"
                          (/ (plist-get e :alt) 1000.0))))
        (when (plist-get e :speed)
          (insert (format "speed    : %s\n" (plist-get e :speed))))
        (when (plist-get e :heading)
          (insert (format "heading  : %s\n" (plist-get e :heading))))
        (let ((data (plist-get e :data)))
          (when data
            (insert "\ndata:\n")
            (cond
             ((and (consp data) (consp (car data)))
              (dolist (kv data)
                (insert (format "  %s: %s\n" (car kv) (cdr kv)))))
             (t (insert (format "  %S\n" data)))))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer
     buf '((display-buffer-in-side-window) (side . right) (window-width . 0.32)))
    buf))

;;;; Layers UI ---------------------------------------------------------------

(defun cmacs-gnuseye--layers-entries ()
  "Tabulated-list entries for the layers buffer."
  (let (rows)
    (maphash
     (lambda (name layer)
       (push
        (list name
              (vector
               (if (cmacs-gnuseye-layer-enabled layer) "on" "off")
               (format "%s" (or (cmacs-gnuseye-layer-group layer) ""))
               (or (cmacs-gnuseye-layer-title layer) (symbol-name name))
               (let ((lf (cmacs-gnuseye-layer-last-fetch layer)))
                 (if lf (format "%ds ago" (truncate (- (float-time) lf))) "-"))
               (or (and (cmacs-gnuseye-layer-needs-key layer)
                        (not (cmacs-gnuseye-secret
                              (cmacs-gnuseye-layer-needs-key layer)))
                        (format "needs %s" (cmacs-gnuseye-layer-needs-key layer)))
                   (or (cmacs-gnuseye-layer-last-error layer) ""))))
        rows))
     cmacs-gnuseye--layers)
    (nreverse rows)))

(defvar cmacs-gnuseye-layers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-gnuseye-layers-toggle)
    (define-key map (kbd "t")   #'cmacs-gnuseye-layers-toggle)
    (define-key map (kbd "g")   #'cmacs-gnuseye-layers-refresh)
    map)
  "Keymap for `cmacs-gnuseye-layers-mode'.")

(define-derived-mode cmacs-gnuseye-layers-mode tabulated-list-mode "Gnuseye-Layers"
  "Major mode listing GNU's Eye data layers."
  (setq tabulated-list-format
        [("State" 5 t) ("Group" 12 t) ("Layer" 30 t)
         ("Fetched" 10 t) ("Note" 24 t)])
  (tabulated-list-init-header))

(defun cmacs-gnuseye-layers-refresh ()
  "Refresh the layers list."
  (interactive)
  (setq tabulated-list-entries (cmacs-gnuseye--layers-entries))
  (tabulated-list-print t))

(defun cmacs-gnuseye-layers-toggle ()
  "Toggle the layer at point on/off."
  (interactive)
  (let* ((name (tabulated-list-get-id))
         (layer (and name (gethash name cmacs-gnuseye--layers))))
    (when layer
      (if (cmacs-gnuseye-layer-enabled layer)
          (cmacs-gnuseye--disable-layer layer)
        (cmacs-gnuseye--enable-layer layer))
      (cmacs-gnuseye-layers-refresh))))

;;;###autoload
(defun cmacs-gnuseye-layers ()
  "Open the GNU's Eye layers control panel."
  (interactive)
  (cmacs-gnuseye--load-layers)
  (let ((buf (get-buffer-create "*GNU's Eye Layers*")))
    (with-current-buffer buf
      (cmacs-gnuseye-layers-mode)
      (cmacs-gnuseye-layers-refresh))
    (pop-to-buffer buf)))

;;;; Mode + entry point ------------------------------------------------------

(defvar cmacs-gnuseye-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'cmacs-gnuseye-layers)
    (define-key map (kbd "g") #'cmacs-gnuseye-refresh-all)
    (define-key map (kbd "f") #'cmacs-gnuseye-fly-to-place)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-gnuseye-mode'.")

(define-derived-mode cmacs-gnuseye-mode special-mode "GNU's-Eye"
  "Major mode for the GNU's Eye live globe.
The buffer's text area is covered by the libregnum globe blit; mouse
drag orbits, scroll zooms, right-drag pans, and clicking a marker opens
its detail view."
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (setq-local mode-line-format
              '(" GNU's Eye  [l]ayers  [g]refresh  [f]ly-to  [q]uit")))

(defun cmacs-gnuseye-refresh-all ()
  "Refresh every enabled layer now."
  (interactive)
  (maphash (lambda (_ layer)
             (when (cmacs-gnuseye-layer-enabled layer)
               (cmacs-gnuseye--refresh-layer layer)))
           cmacs-gnuseye--layers)
  (message "GNU's Eye: refreshing enabled layers"))

(defun cmacs-gnuseye-fly-to-place (lat lon)
  "Fly the globe camera to LAT, LON (degrees, read from the minibuffer)."
  (interactive "nLatitude: \nnLongitude: ")
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
    (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer (float lat) (float lon) 14.0 t)))

;;;###autoload
(defun cmacs-gnuseye ()
  "Open the GNU's Eye live planetary globe."
  (interactive)
  (unless (and (fboundp 'cmacs-gnuseye-supported-p) (cmacs-gnuseye-supported-p))
    (user-error "This cmacs was not built with --with-cmacs-gnuseye"))
  (let ((buf (get-buffer-create "*GNU's Eye*")))
    (setq cmacs-gnuseye-buffer buf)
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-gnuseye-mode)
        (cmacs-gnuseye-mode))
      (let ((inhibit-read-only t))
        (when (= (buffer-size) 0)
          (insert "GNU's Eye — initialising globe…\n")))
      (unless (cmacs-gnuseye-attached-p buf)
        (cmacs-gnuseye-attach
         buf 900 600
         (and cmacs-gnuseye-base-texture
              (file-exists-p cmacs-gnuseye-base-texture)
              (expand-file-name cmacs-gnuseye-base-texture))))
      (cmacs-gnuseye--load-layers)
      (maphash
       (lambda (name layer)
         (when (and (cmacs-gnuseye-layer-default-on layer)
                    (memq name cmacs-gnuseye-default-layers)
                    (or (null (cmacs-gnuseye-layer-needs-key layer))
                        (cmacs-gnuseye-secret
                         (cmacs-gnuseye-layer-needs-key layer))))
           (cmacs-gnuseye--enable-layer layer)))
       cmacs-gnuseye--layers))
    (pop-to-buffer buf)
    buf))

(provide 'cmacs-gnuseye)
;;; cmacs-gnuseye.el ends here
