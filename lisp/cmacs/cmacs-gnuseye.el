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

(declare-function cmacs-libregnum-resize "cmacs-libregnum-defuns.c"
                  (buffer width height))

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

(defcustom cmacs-gnuseye-focus-range 5.0
  "Camera range (world units) used when clicking a marker to recentre on it.
Smaller zooms in closer."
  :type 'number
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

;;;; Entity index, filter, and selection state -------------------------------

(defvar cmacs-gnuseye--layer-entities (make-hash-table :test 'eq)
  "Layer-name symbol -> list of the layer's current (rich) entity plists.
The source of truth the dashboard list, search, and filter operate on, and
what the globe is (re)rendered from.")

(defvar cmacs-gnuseye--id-index (make-hash-table :test 'equal)
  "Entity :id string -> entity plist (tagged with :layer) for quick lookup.")

(defvar cmacs-gnuseye-active-kinds nil
  "When nil, show every marker kind; otherwise a list of kind symbols to
show.  Applies to BOTH the globe and the entity list, so you can declutter
to e.g. only planes, or planes and boats.")

(defvar cmacs-gnuseye--search ""
  "Case-insensitive substring narrowing the entity list (label/id/kind).")

(defvar cmacs-gnuseye--selected-id nil
  "The :id of the currently selected entity (labelled + highlighted).")

(defconst cmacs-gnuseye--known-kinds
  '(satellite aircraft ship quake fire launch storm camera city)
  "Selectable marker kinds for filtering.")

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
         (lab   (plist-get e :label))
         (id    (format "%s" (or (plist-get e :id) "")))
         (sel   (and cmacs-gnuseye--selected-id
                     (equal id cmacs-gnuseye--selected-id))))
    (list :id        id
          :lat       (float (or (plist-get e :lat) 0.0))
          :lon       (float (or (plist-get e :lon) 0.0))
          :alt       (float (or (plist-get e :alt) 0.0))
          :heading   (float (or (plist-get e :heading) -1.0))
          ;; The selected entity is enlarged, brightened, and always labelled.
          :scale     (if sel (* scale 1.6) scale)
          :kind      code
          :kind-name kind
          :color     (cmacs-gnuseye--color->rgba (if sel "#ffffff" color))
          :label     (and lab (format "%s" lab))
          ;; Default "hover" (mouse over to identify); "always" when selected.
          :label-mode (if sel 3 (or (plist-get e :label-mode) 2))
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

(defun cmacs-gnuseye--kind-visible-p (kind)
  "Non-nil if KIND passes the active-kinds filter."
  (or (null cmacs-gnuseye-active-kinds)
      (memq kind cmacs-gnuseye-active-kinds)))

(defun cmacs-gnuseye--entity-visible-p (e)
  "Non-nil if entity E passes the active-kinds filter."
  (cmacs-gnuseye--kind-visible-p (or (plist-get e :kind) 'generic)))

(defun cmacs-gnuseye--reindex ()
  "Rebuild the id -> entity index from `cmacs-gnuseye--layer-entities'."
  (clrhash cmacs-gnuseye--id-index)
  (maphash
   (lambda (lname ents)
     (dolist (e ents)
       (let ((id (format "%s" (or (plist-get e :id) ""))))
         (unless (string-empty-p id)
           (puthash id (append (list :layer lname) e)
                    cmacs-gnuseye--id-index)))))
   cmacs-gnuseye--layer-entities))

(defun cmacs-gnuseye--render-layer (buf lname)
  "Push LNAME's kind-filtered entities from the index to BUF's globe."
  (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf))
    (let ((ents (seq-filter #'cmacs-gnuseye--entity-visible-p
                            (gethash lname cmacs-gnuseye--layer-entities))))
      (cmacs-gnuseye-set-entities
       buf lname (cmacs-gnuseye--entities->vector ents)))))

(defun cmacs-gnuseye--render-all (&optional buf)
  "Re-render every layer's markers (e.g. after a filter change)."
  (let ((buf (or buf cmacs-gnuseye-buffer)))
    (when (and buf (buffer-live-p buf))
      (maphash (lambda (lname _) (cmacs-gnuseye--render-layer buf lname))
               cmacs-gnuseye--layer-entities))))

(defun cmacs-gnuseye--refresh-layer (layer)
  "Run LAYER's fetch, store its entities in the index, and render them."
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
             (condition-case e2
                 (progn
                   (puthash (cmacs-gnuseye-layer-name layer) (or entities nil)
                            cmacs-gnuseye--layer-entities)
                   (cmacs-gnuseye--reindex)
                   (cmacs-gnuseye--render-layer buf
                                                (cmacs-gnuseye-layer-name layer))
                   (cmacs-gnuseye--list-refresh-soon))
               (error
                (setf (cmacs-gnuseye-layer-last-error layer)
                      (error-message-string e2))))))
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
  (remhash (cmacs-gnuseye-layer-name layer) cmacs-gnuseye--layer-entities)
  (cmacs-gnuseye--reindex)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer))
    (ignore-errors
      (cmacs-gnuseye-clear-layer cmacs-gnuseye-buffer
                                 (cmacs-gnuseye-layer-name layer))))
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye--load-layers ()
  "Load the built-in layer feature files."
  (dolist (f cmacs-gnuseye-layer-files)
    (require f nil t)))

;;;; Selection + inspector pane ----------------------------------------------

(defconst cmacs-gnuseye--inspector-name "*GNU's Eye Inspector*")
(defconst cmacs-gnuseye--list-name "*GNU's Eye Entities*")

(defun cmacs-gnuseye--select-entity (id &optional no-fly)
  "Select entity ID: show it in the inspector, highlight it on the globe,
and (unless NO-FLY) recentre the camera on it."
  (setq cmacs-gnuseye--selected-id (and id (format "%s" id)))
  (let ((e (and cmacs-gnuseye--selected-id
                (gethash cmacs-gnuseye--selected-id cmacs-gnuseye--id-index))))
    (when e
      (unless no-fly
        (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
                   (plist-get e :lat))
          (ignore-errors
            (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer
                                  (float (plist-get e :lat))
                                  (float (plist-get e :lon))
                                  cmacs-gnuseye-focus-range t))))
      (cmacs-gnuseye--show-inspector e)
      ;; Re-render so the selected marker is enlarged/brightened/labelled.
      (cmacs-gnuseye--render-all))
    e))

(defun cmacs-gnuseye--on-pick (buffer node-id)
  "Handle a marker click: select the entity (inspector + highlight + list).
Called from `cmacs-libregnum--node-clicked' on the cmacs context."
  (when (and (integerp node-id) (>= node-id 0))
    (let ((e (ignore-errors (cmacs-gnuseye-entity-at buffer node-id))))
      (when e
        (cmacs-gnuseye--select-entity (plist-get e :id))
        (cmacs-gnuseye--list-goto (plist-get e :id))))))

(defvar cmacs-gnuseye-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'cmacs-gnuseye-inspector-fly)
    (define-key map (kbd "RET") #'cmacs-gnuseye-inspector-fly)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-gnuseye-inspector-mode'.")

(define-derived-mode cmacs-gnuseye-inspector-mode special-mode "GnuseyeInspect"
  "GNU's Eye entity inspector pane.")

(defun cmacs-gnuseye-inspector-fly ()
  "Recentre the globe on the inspected entity."
  (interactive)
  (when cmacs-gnuseye--selected-id
    (cmacs-gnuseye--select-entity cmacs-gnuseye--selected-id)))

(defun cmacs-gnuseye--insp-row (k v)
  (when (and v (not (and (stringp v) (string-empty-p v))))
    (insert (format "  %-10s %s\n" k v))))

(defun cmacs-gnuseye--inspector-render (e)
  "Render entity E (a rich layer plist) into the current inspector buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null e)
        (insert "No entity selected.\n\n"
                "Click a marker on the globe, or select a row\n"
                "in the entity list with RET.\n")
      (let ((label (or (plist-get e :label)
                       (format "%s" (or (plist-get e :id) "entity")))))
        (insert (propertize (format "%s\n" label) 'face '(bold)))
        (insert (make-string (max 10 (string-width label)) ?─) "\n\n")
        (cmacs-gnuseye--insp-row "kind" (plist-get e :kind))
        (cmacs-gnuseye--insp-row "layer" (plist-get e :layer))
        (cmacs-gnuseye--insp-row "id" (plist-get e :id))
        (when (plist-get e :lat)
          (cmacs-gnuseye--insp-row "lat" (format "%.4f" (plist-get e :lat))))
        (when (plist-get e :lon)
          (cmacs-gnuseye--insp-row "lon" (format "%.4f" (plist-get e :lon))))
        (let ((a (plist-get e :alt)))
          (when (and (numberp a) (> a 0))
            (cmacs-gnuseye--insp-row "altitude" (format "%.1f km" (/ a 1000.0)))))
        (when (plist-get e :speed)
          (cmacs-gnuseye--insp-row "speed" (plist-get e :speed)))
        (when (and (numberp (plist-get e :heading))
                   (>= (plist-get e :heading) 0))
          (cmacs-gnuseye--insp-row "heading"
                                   (format "%s°" (plist-get e :heading))))
        (let ((data (plist-get e :data)))
          (when data
            (insert "\n" (propertize "data\n" 'face '(bold)))
            (cond
             ((and (consp data) (consp (car data)))
              (dolist (kv data)
                (cmacs-gnuseye--insp-row (format "%s" (car kv)) (cdr kv))))
             (t (insert (format "  %S\n" data))))))
        (insert "\n[f] fly-to   [q] close\n")))
    (goto-char (point-min))))

(defun cmacs-gnuseye--show-inspector (&optional e)
  "Show the inspector pane for entity E (or the current selection)."
  (let ((b (get-buffer-create cmacs-gnuseye--inspector-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-inspector-mode)
        (cmacs-gnuseye-inspector-mode))
      (cmacs-gnuseye--inspector-render
       (or e (and cmacs-gnuseye--selected-id
                  (gethash cmacs-gnuseye--selected-id
                           cmacs-gnuseye--id-index)))))
    (display-buffer-in-side-window
     b '((side . right) (slot . 0) (window-width . 0.26)))
    b))

;;;; Entity list pane (search + filter) --------------------------------------

(defun cmacs-gnuseye--search-match-p (e)
  (or (string-empty-p cmacs-gnuseye--search)
      (let ((q (downcase cmacs-gnuseye--search)))
        (or (string-search q (downcase (or (plist-get e :label) "")))
            (string-search q (downcase (format "%s" (or (plist-get e :id) ""))))
            (string-search q (symbol-name (or (plist-get e :kind) 'generic)))))))

(defun cmacs-gnuseye--list-entries ()
  "Tabulated-list rows for the entity list, honouring kind filter + search."
  (let (rows)
    (maphash
     (lambda (id e)
       (when (and (cmacs-gnuseye--entity-visible-p e)
                  (cmacs-gnuseye--search-match-p e))
         (let ((a (plist-get e :alt)))
           (push (list id
                       (vector
                        (symbol-name (or (plist-get e :kind) 'generic))
                        (or (plist-get e :label) id)
                        (format "%.2f" (or (plist-get e :lat) 0.0))
                        (format "%.2f" (or (plist-get e :lon) 0.0))
                        (if (and (numberp a) (> a 0))
                            (format "%.0f" (/ a 1000.0)) "-")
                        (format "%s" (or (plist-get e :layer) ""))))
                 rows))))
     cmacs-gnuseye--id-index)
    rows))

(defun cmacs-gnuseye--list-refresh-soon ()
  "Repaint the entity list buffer if it exists, keeping point."
  (let ((b (get-buffer cmacs-gnuseye--list-name)))
    (when (and b (buffer-live-p b))
      (with-current-buffer b
        (setq tabulated-list-entries (cmacs-gnuseye--list-entries))
        (tabulated-list-print t)
        (cmacs-gnuseye--list-update-header)))))

(defun cmacs-gnuseye--list-update-header ()
  (setq header-line-format
        (format " entities: %d   filter: %s   search: %s"
                (length tabulated-list-entries)
                (if cmacs-gnuseye-active-kinds
                    (mapconcat #'symbol-name cmacs-gnuseye-active-kinds ",")
                  "all")
                (if (string-empty-p cmacs-gnuseye--search) "-"
                  cmacs-gnuseye--search))))

(defun cmacs-gnuseye--list-goto (id)
  "Move point to the row for ID in the list buffer, if shown."
  (let ((b (get-buffer cmacs-gnuseye--list-name)))
    (when (and b (buffer-live-p b) (get-buffer-window b))
      (with-current-buffer b
        (goto-char (point-min))
        (let ((target (format "%s" id)))
          (while (and (not (eobp))
                      (not (equal (tabulated-list-get-id) target)))
            (forward-line 1)))))))

(defvar cmacs-gnuseye-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-gnuseye-list-select)
    (define-key map (kbd "s")   #'cmacs-gnuseye-search)
    (define-key map (kbd "f")   #'cmacs-gnuseye-filter-kinds)
    (define-key map (kbd "c")   #'cmacs-gnuseye-filter-clear)
    (define-key map (kbd "g")   #'cmacs-gnuseye-list-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map [mouse-1]   #'cmacs-gnuseye-list-select)
    map)
  "Keymap for `cmacs-gnuseye-list-mode'.")

(define-derived-mode cmacs-gnuseye-list-mode tabulated-list-mode "GnuseyeEntities"
  "Searchable, filterable list of the globe's live entities."
  (setq tabulated-list-format
        [("Kind" 10 t) ("Label" 18 t) ("Lat" 8 t) ("Lon" 9 t)
         ("Alt" 6 t) ("Layer" 10 t)])
  (setq tabulated-list-sort-key '("Kind" . nil))
  (tabulated-list-init-header))

(defun cmacs-gnuseye-list-select (&optional event)
  "Select the entity on the current list row (inspector + globe)."
  (interactive (list last-nonmenu-event))
  (when event (ignore-errors (mouse-set-point event)))
  (let ((id (tabulated-list-get-id)))
    (when id (cmacs-gnuseye--select-entity id))))

(defun cmacs-gnuseye-list-refresh ()
  "Repaint the entity list."
  (interactive)
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye-search (query)
  "Narrow the entity list to rows matching QUERY (empty clears)."
  (interactive
   (list (read-string "Search entities (label/id/kind, empty clears): "
                      cmacs-gnuseye--search)))
  (setq cmacs-gnuseye--search (or query ""))
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye-filter-kinds (kinds)
  "Show only KINDS on the globe and in the list (empty selection = all).
Pick one or more of e.g. aircraft, ship, satellite, quake."
  (interactive
   (list (completing-read-multiple
          "Show kinds (comma-separated, empty = all): "
          (mapcar #'symbol-name cmacs-gnuseye--known-kinds))))
  (setq cmacs-gnuseye-active-kinds
        (delq nil (mapcar (lambda (s) (and (stringp s) (not (string-empty-p s))
                                           (intern s)))
                          kinds)))
  (cmacs-gnuseye--render-all)
  (cmacs-gnuseye--list-refresh-soon)
  (message "GNU's Eye showing: %s"
           (if cmacs-gnuseye-active-kinds
               (mapconcat #'symbol-name cmacs-gnuseye-active-kinds ", ")
             "all kinds")))

(defun cmacs-gnuseye-filter-clear ()
  "Clear the kind filter and the search."
  (interactive)
  (setq cmacs-gnuseye-active-kinds nil
        cmacs-gnuseye--search "")
  (cmacs-gnuseye--render-all)
  (cmacs-gnuseye--list-refresh-soon)
  (message "GNU's Eye filters cleared"))

(defun cmacs-gnuseye--show-list ()
  "Show the entity list pane."
  (let ((b (get-buffer-create cmacs-gnuseye--list-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-list-mode)
        (cmacs-gnuseye-list-mode))
      (setq tabulated-list-entries (cmacs-gnuseye--list-entries))
      (tabulated-list-print)
      (cmacs-gnuseye--list-update-header))
    (display-buffer-in-side-window
     b '((side . left) (slot . 0) (window-width . 0.24)))
    b))

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
    (select-window
     (display-buffer-in-side-window
      buf '((side . left) (slot . 1) (window-width . 0.24))))))

;;;; Mode + entry point ------------------------------------------------------

(defun cmacs-gnuseye-legend ()
  "Show a legend of marker kinds, shapes, and colours."
  (interactive)
  (let ((buf (get-buffer-create "*GNU's Eye Legend*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "GNU's Eye — marker legend\n" 'face 'bold))
        (insert "─────────────────────────\n\n")
        (dolist (row '(("satellite" "winged body + solar panels, high, orbit trail")
                       ("aircraft"  "plane (nose = heading), floats at altitude + drop-line")
                       ("ship"      "hull + superstructure (bow = heading), on the water")
                       ("quake"     "sphere sized by magnitude, on the surface")
                       ("fire"      "flame, on the surface")
                       ("launch"    "upright rocket at the pad")
                       ("camera"    "camera body")
                       ("city"      "pin")))
          (let* ((kind (intern (car row)))
                 (style (alist-get kind cmacs-gnuseye-kind-styles))
                 (color (or (plist-get style :color) "#ffd24a")))
            (insert (propertize "  ███  " 'face (list :foreground color)))
            (insert (format "%-10s %s\n" (car row) (cadr row)))))
        (insert "\nInteract: drag = orbit, scroll = zoom, right-drag = pan,\n")
        (insert "hover = identify, click = recentre + details.\n"))
      (goto-char (point-min))
      (special-mode))
    (display-buffer
     buf '((display-buffer-in-side-window) (side . right) (window-width . 0.34)))))

(defvar cmacs-gnuseye-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'cmacs-gnuseye-entities)
    (define-key map (kbd "i") #'cmacs-gnuseye-inspector)
    (define-key map (kbd "l") #'cmacs-gnuseye-layers)
    (define-key map (kbd "s") #'cmacs-gnuseye-search)
    (define-key map (kbd "F") #'cmacs-gnuseye-filter-kinds)
    (define-key map (kbd "c") #'cmacs-gnuseye-filter-clear)
    (define-key map (kbd "g") #'cmacs-gnuseye-refresh-all)
    (define-key map (kbd "f") #'cmacs-gnuseye-fly-to-place)
    (define-key map (kbd "?") #'cmacs-gnuseye-legend)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-gnuseye-mode'.")

(defun cmacs-gnuseye--on-kill ()
  "Tear down the globe view and stop tracking the window when the buffer dies."
  (remove-hook 'window-size-change-functions #'cmacs-gnuseye--on-size-change)
  (ignore-errors (cmacs-gnuseye-detach (current-buffer)))
  (when (eq (current-buffer) cmacs-gnuseye-buffer)
    (setq cmacs-gnuseye-buffer nil)))

(define-derived-mode cmacs-gnuseye-mode special-mode "GNU's-Eye"
  "Major mode for the GNU's Eye live globe.
The buffer's text area is covered by the libregnum globe blit; mouse
drag orbits, scroll zooms, right-drag pans, hover identifies a marker,
and clicking one selects it (inspector + recentre)."
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'cmacs-gnuseye--on-kill nil t)
  (setq-local mode-line-format
              '(" GNU's Eye  drag=orbit scroll=zoom hover=id click=select \
 [e]ntities [i]nspect [l]ayers [s]earch [F]ilter [g]refresh [?]legend [q]uit")))

(defun cmacs-gnuseye-entities ()
  "Show (and select) the entity list pane."
  (interactive)
  (select-window (get-buffer-window (cmacs-gnuseye--show-list))))

(defun cmacs-gnuseye-inspector ()
  "Show the inspector pane for the current selection."
  (interactive)
  (cmacs-gnuseye--show-inspector))

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

;;;; The map: coastlines, borders, labels, admin-1, all aligned ------------

;; Real geography drawn in the globe's own lat/lon convention, so (unlike a
;; raster texture) it always lines up with the markers.  Data is Natural
;; Earth (public domain), downloaded once and cached under the gnuseye
;; cache directory.

(defconst cmacs-gnuseye--ne-base
  "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/")

(defcustom cmacs-gnuseye-coastlines t
  "Draw continent coastlines on the globe." :type 'boolean
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-borders t
  "Draw country borders on the globe." :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-labels t
  "Draw country name labels (shown once zoomed in)." :type 'boolean
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1 t
  "Draw admin-1 boundaries (states/provinces) for `cmacs-gnuseye-admin1-countries'."
  :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1-countries '("USA" "CAN")
  "ISO-A3 country codes whose states/provinces are drawn (admin-1)."
  :type '(repeat string) :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flags t
  "Draw country flags on the globe (shown once zoomed in).
Flag images (flagcdn.com) are downloaded once and cached; the first time
they trickle in over a short while, then load instantly."
  :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flag-size 0.3
  "Country flag billboard size in world units." :type 'number
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flag-url-format "https://flagcdn.com/w80/%s.png"
  "Flag image URL; %s is the lowercase ISO-A2 country code."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-coastline-color "#c8a96f"
  "Coastline colour." :type 'string :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-border-color "#6f93ba"
  "Country border colour." :type 'string :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1-color "#48627f"
  "Admin-1 (state/province) border colour." :type 'string
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-label-color "#e8eff6"
  "Country label colour." :type 'string :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--geojson (file callback)
  "Fetch+cache Natural Earth FILE under the gnuseye cache; call (CALLBACK DATA)."
  (let ((path (expand-file-name (concat "cmacs/gnuseye/" file)
                                (or (getenv "XDG_CACHE_HOME") "~/.cache"))))
    (cl-flet ((parse (s) (ignore-errors
                           (json-parse-string s :object-type 'alist
                                              :array-type 'list))))
      (if (file-readable-p path)
          (funcall callback
                   (parse (with-temp-buffer (insert-file-contents path)
                                            (buffer-string))))
        (cmacs-gnuseye-fetch-text
         (concat cmacs-gnuseye--ne-base file)
         (lambda (body)
           (when (and body (> (length body) 100))
             (ignore-errors
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert body)))
             (funcall callback (parse body)))))))))

(defun cmacs-gnuseye--decimate (coords step)
  "Keep every STEP-th point of COORDS, always including the last."
  (if (<= step 1) coords
    (let ((out nil) (i 0) (n (length coords)))
      (dolist (p coords)
        (when (or (zerop (mod i step)) (= i (1- n))) (push p out))
        (setq i (1+ i)))
      (nreverse out))))

(defun cmacs-gnuseye--draw-line (buffer coords rgba &optional step)
  "Draw one COORDS polyline (list of (LON LAT)) on BUFFER's globe."
  (let* ((pts (cmacs-gnuseye--decimate coords (or step 1)))
         (n (length pts)))
    (when (>= n 2)
      (let ((lats (make-vector n 0.0)) (lons (make-vector n 0.0)) (i 0))
        (dolist (p pts)
          (aset lons i (float (or (nth 0 p) 0.0)))
          (aset lats i (float (or (nth 1 p) 0.0)))
          (setq i (1+ i)))
        (ignore-errors (cmacs-gnuseye-add-coastline buffer lats lons rgba))))))

(defun cmacs-gnuseye--draw-lines (buffer data rgba &optional step)
  "Draw all LineString/MultiLineString features of DATA."
  (dolist (f (alist-get 'features data))
    (let* ((geom (alist-get 'geometry f))
           (gt (alist-get 'type geom))
           (coords (alist-get 'coordinates geom)))
      (cond
       ((equal gt "LineString")
        (cmacs-gnuseye--draw-line buffer coords rgba step))
       ((equal gt "MultiLineString")
        (dolist (l coords) (cmacs-gnuseye--draw-line buffer l rgba step)))))))

(defun cmacs-gnuseye--draw-polygons (buffer data rgba filter &optional step)
  "Draw the rings of Polygon/MultiPolygon features passing FILTER."
  (dolist (f (alist-get 'features data))
    (when (or (null filter) (funcall filter f))
      (let* ((geom (alist-get 'geometry f))
             (gt (alist-get 'type geom))
             (coords (alist-get 'coordinates geom)))
        (cond
         ((equal gt "Polygon")
          (dolist (ring coords)
            (cmacs-gnuseye--draw-line buffer ring rgba step)))
         ((equal gt "MultiPolygon")
          (dolist (poly coords)
            (dolist (ring poly)
              (cmacs-gnuseye--draw-line buffer ring rgba step)))))))))

(defun cmacs-gnuseye--draw-country-labels (buffer data)
  "Add a label at each country's anchor point (NAME + LABEL_X/LABEL_Y)."
  (let ((rgba (cmacs-gnuseye--color->rgba cmacs-gnuseye-label-color)))
    (dolist (f (alist-get 'features data))
      (let* ((props (alist-get 'properties f))
             (name (or (alist-get 'NAME props) (alist-get 'name props)))
             (lx (alist-get 'LABEL_X props))
             (ly (alist-get 'LABEL_Y props)))
        (when (and (stringp name) (numberp lx) (numberp ly))
          (ignore-errors
            (cmacs-gnuseye-add-label buffer (float ly) (float lx) name rgba)))))))

(defun cmacs-gnuseye--flag-path (cc)
  (expand-file-name (format "cmacs/gnuseye/flags/%s.png" (downcase cc))
                    (or (getenv "XDG_CACHE_HOME") "~/.cache")))

(defun cmacs-gnuseye--fetch-flag (cc path callback)
  "Download the flag for ISO-A2 code CC to PATH (binary); call (CALLBACK OK)."
  (url-retrieve
   (format cmacs-gnuseye-flag-url-format (downcase cc))
   (lambda (status)
     (let ((ok nil))
       (unless (plist-get status :error)
         (goto-char (point-min))
         (when (re-search-forward "\r?\n\r?\n" nil t)
           (let ((data (buffer-substring-no-properties (point) (point-max))))
             (ignore-errors
               (make-directory (file-name-directory path) t)
               (let ((coding-system-for-write 'binary))
                 (with-temp-file path
                   (set-buffer-multibyte nil)
                   (insert data)))
               (setq ok (file-readable-p path))))))
       (when callback (funcall callback ok))))
   nil t t))

(defun cmacs-gnuseye--flag-fetch-queue (buffer queue size)
  "Fetch missing flags in QUEUE one at a time, adding each as it arrives."
  (when (and queue (buffer-live-p buffer))
    (let ((item (car queue)))
      (cmacs-gnuseye--fetch-flag
       (nth 0 item) (nth 3 item)
       (lambda (ok)
         (when (and ok (buffer-live-p buffer)
                    (cmacs-gnuseye-attached-p buffer))
           (ignore-errors
             (cmacs-gnuseye-add-flag buffer (nth 1 item) (nth 2 item)
                                     (nth 3 item) size))
           (cmacs-gnuseye-redraw buffer))
         (cmacs-gnuseye--flag-fetch-queue buffer (cdr queue) size))))))

(defun cmacs-gnuseye--load-flags (buffer data)
  "Place a flag at each country's anchor (cached flags now, missing async)."
  (let ((size cmacs-gnuseye-flag-size) (queue nil))
    (dolist (f (alist-get 'features data))
      (let* ((props (alist-get 'properties f))
             (cc (seq-find (lambda (c) (and (stringp c) (= (length c) 2)
                                            (not (string= c "-99"))))
                           (list (alist-get 'ISO_A2_EH props)
                                 (alist-get 'ISO_A2 props)
                                 (alist-get 'iso_a2 props))))
             (lx (alist-get 'LABEL_X props))
             (ly (alist-get 'LABEL_Y props)))
        (when (and (stringp cc) (numberp lx) (numberp ly))
          (let ((path (cmacs-gnuseye--flag-path cc)))
            (if (file-readable-p path)
                (ignore-errors
                  (cmacs-gnuseye-add-flag buffer (float ly) (float lx)
                                          path size))
              (push (list cc (float ly) (float lx) path) queue))))))
    (cmacs-gnuseye-redraw buffer)
    (cmacs-gnuseye--flag-fetch-queue buffer (nreverse queue) size)))

;;;###autoload
(defun cmacs-gnuseye-load-map (&optional buffer)
  "Draw the world map (coastlines, borders, labels, admin-1) on BUFFER's globe.
Each layer's data is downloaded + cached once.  Honours the
`cmacs-gnuseye-coastlines'/`-borders'/`-labels'/`-admin1' toggles."
  (interactive)
  (let ((buffer (or buffer cmacs-gnuseye-buffer)))
    (when (and buffer (buffer-live-p buffer)
               (cmacs-gnuseye-attached-p buffer)
               (fboundp 'cmacs-gnuseye-add-coastline))
      (cmacs-gnuseye-clear-coastlines buffer)
      (cmacs-gnuseye-clear-labels buffer)
      (when (fboundp 'cmacs-gnuseye-clear-flags)
        (cmacs-gnuseye-clear-flags buffer))
      (when cmacs-gnuseye-coastlines
        (cmacs-gnuseye--geojson
         "ne_110m_coastline.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-lines
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-coastline-color))
             (cmacs-gnuseye-redraw buffer)))))
      (when cmacs-gnuseye-borders
        (cmacs-gnuseye--geojson
         "ne_110m_admin_0_boundary_lines_land.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-lines
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-border-color))
             (cmacs-gnuseye-redraw buffer)))))
      (when cmacs-gnuseye-admin1
        (cmacs-gnuseye--geojson
         "ne_50m_admin_1_states_provinces.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-polygons
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-admin1-color)
              (lambda (f)
                (member (alist-get 'adm0_a3 (alist-get 'properties f))
                        cmacs-gnuseye-admin1-countries))
              2)
             (cmacs-gnuseye-redraw buffer)))))
      (when (or cmacs-gnuseye-labels cmacs-gnuseye-flags)
        (cmacs-gnuseye--geojson
         "ne_110m_admin_0_countries.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (when cmacs-gnuseye-labels
               (cmacs-gnuseye--draw-country-labels buffer d))
             (when (and cmacs-gnuseye-flags
                        (fboundp 'cmacs-gnuseye-add-flag))
               (cmacs-gnuseye--load-flags buffer d))
             (cmacs-gnuseye-redraw buffer))))))))

(defalias 'cmacs-gnuseye-load-coastlines 'cmacs-gnuseye-load-map)

;;;; Keep the globe round: track the window's aspect ratio ------------------

(defvar cmacs-gnuseye--resize-timer nil)

(defun cmacs-gnuseye--fit-window-now ()
  "Resize the globe's render target (FBO) to its window's pixel size.
The overlay blits the FBO 1:1 across the window's pixel rectangle, so the
FBO must share the window's exact dimensions or the sphere is stretched
into an oval.  No-ops when the size is unchanged (the C side guards)."
  (setq cmacs-gnuseye--resize-timer nil)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-gnuseye-attached-p)
             (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-libregnum-resize))
    (let ((win (get-buffer-window cmacs-gnuseye-buffer t)))
      (when (window-live-p win)
        (let ((w (window-pixel-width win))
              (h (window-pixel-height win)))
          (when (and (> w 1) (> h 1))
            (ignore-errors
              (cmacs-libregnum-resize cmacs-gnuseye-buffer w h))))))))

(defun cmacs-gnuseye--on-size-change (&optional _frame)
  "Coalesce window size changes, then refit the globe (see `…-fit-window-now')."
  (unless cmacs-gnuseye--resize-timer
    (setq cmacs-gnuseye--resize-timer
          (run-with-idle-timer 0.06 nil #'cmacs-gnuseye--fit-window-now))))

;;;###autoload
(defun cmacs-gnuseye (&optional no-dashboard)
  "Open the GNU's Eye live planetary globe dashboard.
The globe viewport sits in the centre with an entity list on the left
and an inspector on the right.  With a prefix arg (NO-DASHBOARD), open
just the globe viewport."
  (interactive "P")
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
    ;; Lay out the dashboard: globe centre, entity list left, inspector right.
    (switch-to-buffer buf)
    (delete-other-windows)
    (unless no-dashboard
      (cmacs-gnuseye--show-list)
      (cmacs-gnuseye--show-inspector)
      (select-window (get-buffer-window buf)))
    ;; Keep the sphere round at any window aspect: match the FBO to the
    ;; window now, and on every later size change.
    (add-hook 'window-size-change-functions #'cmacs-gnuseye--on-size-change)
    (cmacs-gnuseye--fit-window-now)
    (cmacs-gnuseye--on-size-change)
    ;; Real geography (coastlines, borders, labels, admin-1) aligned with
    ;; the markers.
    (cmacs-gnuseye-load-map buf)
    buf))

;;;; Evil (Doom) + vanilla navigation -----------------------------------------

;; Make every pane usable with both vanilla Emacs and Evil/Doom:
;;  - Globe viewport: Emacs state, so its single-key commands reach the
;;    keymap instead of Evil operators (mouse drives the camera anyway).
;;  - Entity list + layers: Motion state, so Evil hjkl navigation works
;;    while they stay read-only; RET / s / f / g activate via the keymap.
;;  - Inspector: Normal state so Evil motion + Esc behave normally.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-gnuseye-mode 'emacs)
    (evil-set-initial-state 'cmacs-gnuseye-list-mode 'motion)
    (evil-set-initial-state 'cmacs-gnuseye-inspector-mode 'normal)
    (evil-set-initial-state 'cmacs-gnuseye-layers-mode 'motion))
  ;; Bind the list/layers actions in Motion state too (Motion otherwise
  ;; swallows single keys like s/f/g), keeping hjkl navigation.
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-gnuseye-list-mode-map
      (kbd "RET") #'cmacs-gnuseye-list-select
      "s" #'cmacs-gnuseye-search
      "f" #'cmacs-gnuseye-filter-kinds
      "c" #'cmacs-gnuseye-filter-clear
      "g" #'cmacs-gnuseye-list-refresh
      "q" #'quit-window)
    (evil-define-key* 'motion cmacs-gnuseye-layers-mode-map
      (kbd "RET") #'cmacs-gnuseye-layers-toggle
      "t" #'cmacs-gnuseye-layers-toggle
      "g" #'cmacs-gnuseye-layers-refresh
      "q" #'quit-window)))

(provide 'cmacs-gnuseye)
;;; cmacs-gnuseye.el ends here
