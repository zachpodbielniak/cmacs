;;; cmacs-gnuseye-tools.el --- GNU's Eye as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The eleven `gnuseye_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-gnuseye.c, each
;; of which built a Lisp form with printf and evaluated it.  Here they
;; are `cmacs-brigade-deftool' forms (doc_org/cmacs/cmacs-capability.org
;; has the recipe), so one definition reaches in-process agents, MCP
;; clients, org.cmacs.Editor1.Tools and `emacsctl tool gnuseye ...'.
;; The wire names, parameter names and required/optional split are the C
;; ones.  The C file is deleted; the schema it published is frozen in
;; test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - No argument is spliced into Lisp source.  A layer or entity kind
;;     is looked up with `intern-soft', so a name that matches nothing
;;     no longer interns a symbol on the way to finding that out.
;;
;;   - A failure is a failure.  "unknown layer" and "no globe open" were
;;     ordinary results an MCP client could not tell from success; they
;;     are errors now, and each surface reports them in its own way.
;;
;;   - A string result is the string.  The C handlers printed every
;;     value with `prin1', so "opened" arrived wrapped in quotes and the
;;     JSON of `gnuseye_query_entities' arrived as a quoted, escaped
;;     Lisp string.  The JSON is now the JSON.
;;
;;   - `gnuseye_query_entities' returns an array of objects, which is
;;     what its description always said.  What the C handler produced
;;     was not that (see the comment in the tool).

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-gnuseye "cmacs-gnuseye" ())
(declare-function cmacs-gnuseye--load-layers "cmacs-gnuseye" ())
(declare-function cmacs-gnuseye-layer-enabled "cmacs-gnuseye" (layer))
(declare-function cmacs-gnuseye-layer-group "cmacs-gnuseye" (layer))
(declare-function cmacs-gnuseye-layer-title "cmacs-gnuseye" (layer))
(declare-function cmacs-gnuseye--enable-layer "cmacs-gnuseye" (layer))
(declare-function cmacs-gnuseye--disable-layer "cmacs-gnuseye" (layer))
(declare-function cmacs-gnuseye-fly-to "cmacs-gnuseye"
                  (buffer lat lon &optional range animate))
(declare-function cmacs-gnuseye-refresh-all "cmacs-gnuseye" ())
(declare-function cmacs-gnuseye-add-geofence "cmacs-gnuseye-geofence"
                  (name lat lon radius-km))
(declare-function cmacs-gnuseye-intel--compute-cii "cmacs-gnuseye-intel" ())
(declare-function cmacs-gnuseye-weather-showcase "cmacs-gnuseye-meteo" ())
(declare-function cmacs-gnuseye-forecast-at "cmacs-gnuseye-meteo" (lat lon))

(defvar cmacs-gnuseye--layers)
(defvar cmacs-gnuseye--id-index)
(defvar cmacs-gnuseye-buffer)
(defvar cmacs-gnuseye-cii--scores)

(defun cmacs-gnuseye-tools--symbol (text)
  "Return the existing symbol named TEXT, or nil.
Layers and entity kinds are keyed by symbols.  `intern-soft' answers
\"is there such a name\" without creating one from whatever a caller
sent."
  (and (stringp text) (not (string-empty-p text)) (intern-soft text)))

(defun cmacs-gnuseye-tools--number (value what)
  "Return VALUE if it is a number, else signal naming WHAT."
  (unless (numberp value)
    (error "%s must be a number" what))
  value)

;; The globe is loaded when a tool runs, not when this file is: this
;; file is loaded at startup so the tools are listed, and the globe's
;; data layers are not something to pull into every session.

(cmacs-brigade-deftool gnuseye-open
    "Open the GNU's Eye live planetary globe buffer."
    ()
  :group 'gnuseye
  :destructive t
  :undo '(irreversible "close the gnuseye buffer it opened")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.GnusEye.Open
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gnuseye open"
  (require 'cmacs-gnuseye)
  (cmacs-gnuseye)
  "opened")

(cmacs-brigade-deftool gnuseye-list-layers
    "List GNU's Eye data layers with their on/off state and group."
    ()
  :group 'gnuseye
  :example "emacsctl tool gnuseye list-layers"
  (require 'cmacs-gnuseye)
  (cmacs-gnuseye--load-layers)
  (let (rows)
    (maphash (lambda (k v)
               (push (list k :on (and (cmacs-gnuseye-layer-enabled v) t)
                           :group (cmacs-gnuseye-layer-group v)
                           :title (cmacs-gnuseye-layer-title v))
                     rows))
             cmacs-gnuseye--layers)
    (format "%S" (nreverse rows))))

(cmacs-brigade-deftool gnuseye-toggle-layer
    "Toggle a data layer on/off by NAME (e.g. satellites, aircraft, \
vessels, quakes, launches, fires)."
    ((name string "Layer name, as gnuseye_list_layers reports it"))
  :group 'gnuseye
  :destructive t
  :undo '(irreversible "toggle the layer again with the tool")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.GnusEye.ToggleLayer
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gnuseye toggle-layer --name quakes"
  (require 'cmacs-gnuseye)
  (cmacs-gnuseye--load-layers)
  (let* ((sym (cmacs-gnuseye-tools--symbol name))
         (layer (and sym (gethash sym cmacs-gnuseye--layers))))
    (unless layer
      (error "Unknown layer: %s" name))
    (if (cmacs-gnuseye-layer-enabled layer)
        (progn (cmacs-gnuseye--disable-layer layer)
               (format "%s off" name))
      (cmacs-gnuseye--enable-layer layer)
      (format "%s on" name))))

(cmacs-brigade-deftool gnuseye-fly-to
    "Fly the globe camera to LAT, LON (degrees); optional RANGE world \
units."
    ((lat number "Latitude, degrees")
     (lon number "Longitude, degrees")
     (range number "Camera range in world units (default 14)" :optional t))
  :group 'gnuseye
  :destructive t
  :undo '(irreversible "the globe keeps no previous camera")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.GnusEye.FlyTo
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gnuseye fly-to --lat 51.5 --lon -0.12"
  (require 'cmacs-gnuseye)
  (let ((lat (cmacs-gnuseye-tools--number lat "lat"))
        (lon (cmacs-gnuseye-tools--number lon "lon"))
        (range (cmacs-gnuseye-tools--number (or range 14.0) "range")))
    (unless (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
      (error "No globe open"))
    (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer lat lon range t)
    (format "flew to %g,%g" lat lon)))

(cmacs-brigade-deftool gnuseye-refresh
    "Refresh every enabled GNU's Eye layer now."
    ()
  :group 'gnuseye
  :example "emacsctl tool gnuseye refresh"
  (require 'cmacs-gnuseye)
  ;; Starts the layers' fetches and returns; nothing here waits on one.
  (cmacs-gnuseye-refresh-all)
  "refreshing")

(cmacs-brigade-deftool gnuseye-query-entities
    "Query indexed entities by KIND and/or a bounding box \
\(WEST/SOUTH/EAST/NORTH degrees); returns JSON (capped by LIMIT)."
    ((kind string "Entity kind to keep; omit for every kind" :optional t)
     (west number "Western bound, degrees (default -180)" :optional t)
     (south number "Southern bound, degrees (default -90)" :optional t)
     (east number "Eastern bound, degrees (default 180)" :optional t)
     (north number "Northern bound, degrees (default 90)" :optional t)
     (limit integer "Most rows to return (default 200)" :optional t))
  :group 'gnuseye
  :returns 'json
  :example "emacsctl tool gnuseye query-entities --kind aircraft --limit 20"
  (require 'cmacs-gnuseye)
  (require 'json)
  (let* ((filter (and kind (not (string-empty-p kind))))
         ;; A kind nothing is indexed under has no symbol, and then no
         ;; row can match it: `:none' is never an entity's kind.
         (want (and filter (or (cmacs-gnuseye-tools--symbol kind) :none)))
         (west (cmacs-gnuseye-tools--number (or west -180.0) "west"))
         (east (cmacs-gnuseye-tools--number (or east 180.0) "east"))
         (south (cmacs-gnuseye-tools--number (or south -90.0) "south"))
         (north (cmacs-gnuseye-tools--number (or north 90.0) "north"))
         (limit (if (integerp limit) limit 200))
         (rows nil)
         (n 0))
    (catch 'done
      (maphash
       (lambda (id e)
         (let ((elat (or (plist-get e :lat) 0))
               (elon (or (plist-get e :lon) 0)))
           (when (and (or (not filter) (eq (plist-get e :kind) want))
                      (>= elat south) (<= elat north)
                      (>= elon west) (<= elon east))
             (push (list :id id :kind (plist-get e :kind)
                         :label (plist-get e :label)
                         :lat (plist-get e :lat) :lon (plist-get e :lon))
                   rows)
             (when (>= (setq n (1+ n)) limit)
               (throw 'done nil)))))
       cmacs-gnuseye--id-index))
    ;; A vector of plists is an array of objects.  The C handler encoded
    ;; the bare list, which `json-encode' takes for an alist keyed by
    ;; `:id' -- one object with a repeated "id" member whose values were
    ;; the rest of each row, keys and all -- and "null" for no rows.
    (json-encode (vconcat (nreverse rows)))))

(cmacs-brigade-deftool gnuseye-brief
    "Summarise the entities currently indexed on the globe (counts by \
kind)."
    ()
  :group 'gnuseye
  :example "emacsctl tool gnuseye brief"
  (require 'cmacs-gnuseye)
  (let ((counts (make-hash-table :test 'eq))
        (total 0)
        (parts nil))
    (maphash (lambda (_id e)
               (setq total (1+ total))
               (let ((kind (or (plist-get e :kind) 'generic)))
                 (puthash kind (1+ (gethash kind counts 0)) counts)))
             cmacs-gnuseye--id-index)
    (maphash (lambda (k c) (push (format "%s:%d" k c) parts)) counts)
    (format "%d entities indexed; by kind: %s"
            total (string-join (sort parts #'string<) ", "))))

(cmacs-brigade-deftool gnuseye-add-geofence
    "Add a geofence: a circle of RADIUS_KM about LAT, LON named NAME.  \
Entities entering/leaving emit podomation events."
    ((name string "Name for the fence")
     (lat number "Centre latitude, degrees")
     (lon number "Centre longitude, degrees")
     (radius-km number "Radius in kilometres"))
  :group 'gnuseye
  :destructive t
  :undo '(irreversible "remove the geofence in the gnuseye buffer")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.GnusEye.AddGeofence
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gnuseye add-geofence --name home --lat 41.9 \
--lon -87.6 --radius-km 50"
  (require 'cmacs-gnuseye)
  (require 'cmacs-gnuseye-geofence)
  (let ((lat (cmacs-gnuseye-tools--number lat "lat"))
        (lon (cmacs-gnuseye-tools--number lon "lon"))
        (radius (cmacs-gnuseye-tools--number radius-km "radius_km")))
    (cmacs-gnuseye-add-geofence name lat lon radius)
    (format "geofence %s @ %g,%g r=%gkm" name lat lon radius)))

(cmacs-brigade-deftool gnuseye-cii
    "Compute the country-instability index from active signals; returns \
the ranked ISO-A3 -> score JSON."
    ()
  :group 'gnuseye
  :returns 'json
  :example "emacsctl tool gnuseye cii"
  (require 'cmacs-gnuseye)
  (require 'cmacs-gnuseye-intel)
  (require 'json)
  (require 'seq)
  (cmacs-gnuseye-intel--compute-cii)
  (let (scores)
    (maphash (lambda (iso v) (push (cons iso v) scores))
             cmacs-gnuseye-cii--scores)
    ;; An alist, so an object in rank order; no scores is an empty
    ;; object rather than the "null" an empty list encodes as.
    (if scores
        (json-encode
         (seq-take (sort scores (lambda (x y) (> (cdr x) (cdr y)))) 15))
      "{}")))

(cmacs-brigade-deftool gnuseye-weather-showcase
    "Light the full weather picture: tropical cyclones (tracks/cones), \
animated precipitation radar, cloud imagery, wind particles, METARs, \
and US alert zones; flies to the strongest active storm."
    ()
  :group 'gnuseye
  :destructive t
  :undo '(irreversible "the globe keeps no previous view")
  :example "emacsctl tool gnuseye weather-showcase"
  (require 'cmacs-gnuseye)
  (require 'cmacs-gnuseye-meteo)
  (cmacs-gnuseye-weather-showcase)
  "weather showcase running")

(cmacs-brigade-deftool gnuseye-forecast
    "Open the 7-day point-forecast panel (Open-Meteo) for LAT, LON."
    ((lat number "Latitude, degrees")
     (lon number "Longitude, degrees"))
  :group 'gnuseye
  :example "emacsctl tool gnuseye forecast --lat 41.9 --lon -87.6"
  (require 'cmacs-gnuseye)
  (require 'cmacs-gnuseye-meteo)
  (let ((lat (cmacs-gnuseye-tools--number lat "lat"))
        (lon (cmacs-gnuseye-tools--number lon "lon")))
    ;; The panel fills in when the forecast arrives; this only asks.
    (cmacs-gnuseye-forecast-at lat lon)
    (format "forecast panel opening for %g,%g" lat lon)))

(provide 'cmacs-gnuseye-tools)

;;; cmacs-gnuseye-tools.el ends here
