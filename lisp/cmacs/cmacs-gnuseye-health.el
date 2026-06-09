;;; cmacs-gnuseye-health.el --- GNU's Eye health/environment layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Health & environment layers, in the `health' category:
;;   radiation   Safecast crowdsourced radiation measurements (keyless).
;;   airquality  OpenAQ latest measurements (OpenAQ v3 needs an API key).

;;; Code:

(require 'cmacs-gnuseye)

;;;; Radiation (Safecast) -----------------------------------------------------

(defcustom cmacs-gnuseye-radiation-url
  "https://api.safecast.org/measurements.json?order=created_at+desc"
  "Safecast measurements endpoint (no key)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radiation-max 400
  "Maximum radiation measurements to plot."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-radiation--parse (data)
  "Parse a Safecast measurements array DATA into radiation entities."
  (let ((out nil) (n 0))
    (catch 'done
      (dolist (r data)
        (let ((lat (alist-get 'latitude r))
              (lon (alist-get 'longitude r))
              (val (alist-get 'value r))
              (unit (alist-get 'unit r)))
          (when (and (numberp lat) (numberp lon))
            (push (list :id (format "rad:%s" (or (alist-get 'id r) n))
                        :kind 'radiation
                        :label (and (numberp val) (format "%.2f %s" val
                                                          (or unit "")))
                        :lat (float lat) :lon (float lon)
                        :scale (if (numberp val)
                                   (max 0.6 (min 2.0 (+ 0.6 (/ val 0.5)))) 0.8)
                        :data `((value . ,val) (unit . ,unit)
                                (captured . ,(alist-get 'captured_at r))))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-radiation-max) (throw 'done nil))))))
    (nreverse out)))

(defun cmacs-gnuseye-radiation--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-radiation-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-radiation--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer radiation
  :title "Radiation (Safecast)"
  :group 'health
  :kind 'radiation
  :interval 1800
  :default-on nil
  :fetch #'cmacs-gnuseye-radiation--fetch)

;;;; Air quality (OpenAQ) -----------------------------------------------------

(defcustom cmacs-gnuseye-airquality-url
  "https://api.openaq.org/v3/latest?limit=300"
  "OpenAQ latest-measurements endpoint (OpenAQ v3 needs OPENAQ_API_KEY)."
  :type 'string
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-airquality--parse (data)
  "Parse an OpenAQ v3 latest response DATA into air-quality entities."
  (let (out)
    (dolist (r (alist-get 'results data))
      (let* ((coords (alist-get 'coordinates r))
             (lat (and coords (alist-get 'latitude coords)))
             (lon (and coords (alist-get 'longitude coords)))
             (loc (or (alist-get 'location r) (alist-get 'locationName r))))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "aq:%s" (or (alist-get 'locationsId r) loc))
                      :kind 'airq
                      :label (and loc (format "%s" loc))
                      :lat (float lat) :lon (float lon)
                      :data r)
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-airquality--fetch (cb)
  (let ((key (cmacs-gnuseye-secret "OPENAQ_API_KEY")))
    (if (not key)
        (funcall cb nil)
      (cmacs-gnuseye-fetch-json
       cmacs-gnuseye-airquality-url
       (lambda (data) (funcall cb (and data (cmacs-gnuseye-airquality--parse data))))
       `(("X-API-Key" . ,key)) 'list))))

(cmacs-gnuseye-define-layer airquality
  :title "Air quality (OpenAQ)"
  :group 'health
  :kind 'airq
  :interval 1800
  :default-on nil
  :needs-key "OPENAQ_API_KEY"
  :fetch #'cmacs-gnuseye-airquality--fetch)

;;;; Disasters / humanitarian (ReliefWeb) -------------------------------------

(defcustom cmacs-gnuseye-disasters-url
  (concat "https://api.reliefweb.int/v1/disasters?appname=cmacs-gnuseye"
          "&profile=list&limit=100"
          "&filter[field]=status&filter[value]=ongoing")
  "ReliefWeb ongoing-disasters endpoint (keyless)."
  :type 'string :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-disasters--parse (data)
  (let (out)
    (dolist (d (alist-get 'data data))
      (let* ((f (alist-get 'fields d))
             (countries (alist-get 'country f))
             (c (car (if (and (listp countries) (not (alist-get 'name countries)))
                         countries (list countries))))
             (loc (and c (alist-get 'location c)))
             (lat (and loc (alist-get 'lat loc)))
             (lon (and loc (alist-get 'lon loc)))
             (name (alist-get 'name f)))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "rwdis:%s" (alist-get 'id d))
                      :kind 'event :label (and name (format "%s" name))
                      :lat lat :lon lon :scale 1.2
                      :data `((country . ,(and c (alist-get 'name c)))
                              (status . ,(alist-get 'status f))))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-disasters--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-disasters-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-disasters--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer disasters
  :title "Disasters (ReliefWeb)"
  :group 'health
  :kind 'event
  :interval 3600
  :default-on nil
  :fetch #'cmacs-gnuseye-disasters--fetch)

(provide 'cmacs-gnuseye-health)
;;; cmacs-gnuseye-health.el ends here
