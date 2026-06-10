;;; cmacs-gnuseye-markets.el --- GNU's Eye non-geospatial dashboards  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Some worldmonitor feeds are tables, not map features (markets, macro).
;; Those render as Emacs side-buffer PANELS, registered via
;; `cmacs-gnuseye-define-panel', driven by the same fetch helpers and never
;; touching the globe.  Keyless panels ship enabled-capable:
;;   crypto       CoinGecko top coins (price + 24h %).
;;   fear-greed   alternative.me crypto Fear & Greed index.
;;   fx           Frankfurter / ECB reference FX rates.
;;   predictions  Polymarket open markets by volume.

;;; Code:

(require 'cmacs-gnuseye)

(defvar cmacs-gnuseye--panels (make-hash-table :test 'eq)
  "Panel name -> plist (:title :fetch :render).")

(defmacro cmacs-gnuseye-define-panel (name &rest props)
  "Define a non-geospatial dashboard panel NAME.
PROPS: :title, :fetch (lambda (CB) -> calls (CB DATA) async), :render
\(lambda (DATA) -> string)."
  (declare (indent 1))
  `(puthash ',name (list :title ,(plist-get props :title)
                         :fetch ,(plist-get props :fetch)
                         :render ,(plist-get props :render))
            cmacs-gnuseye--panels))

(defun cmacs-gnuseye--pct (v)
  "Format a signed percentage V with an arrow."
  (if (numberp v)
      (format "%s%.2f%%" (cond ((> v 0) "▲") ((< v 0) "▼") (t " ")) v)
    "—"))

(defun cmacs-gnuseye--panel-buffer (title text)
  (let ((b (get-buffer-create (format "*GNU's Eye: %s*" title))))
    (with-current-buffer b
      (let ((inhibit-read-only t))
        (unless (derived-mode-p 'special-mode) (special-mode))
        (erase-buffer)
        (insert (propertize (concat title "\n") 'face 'bold))
        (insert (make-string (max 8 (string-width title)) ?─) "\n")
        (insert text))
      (goto-char (point-min)))
    b))

;;;###autoload
(defun cmacs-gnuseye-panel (name)
  "Open dashboard panel NAME in a side window."
  (interactive
   (list (intern (completing-read
                  "Panel: "
                  (let (ks) (maphash (lambda (k _) (push k ks))
                                     cmacs-gnuseye--panels) ks)
                  nil t))))
  (let ((p (gethash name cmacs-gnuseye--panels)))
    (when p
      (let ((title (or (plist-get p :title) (symbol-name name))))
        (funcall (plist-get p :fetch)
                 (lambda (data)
                   (let ((text (condition-case e
                                   (funcall (plist-get p :render) data)
                                 (error (format "render error: %S" e)))))
                     (display-buffer
                      (cmacs-gnuseye--panel-buffer title (or text "no data"))
                      '((display-buffer-in-side-window) (side . right)
                        (window-width . 0.3))))))))))

;;;###autoload
(defun cmacs-gnuseye-dashboard ()
  "Open all keyless market panels."
  (interactive)
  (dolist (n '(crypto fear-greed fx predictions))
    (when (gethash n cmacs-gnuseye--panels) (cmacs-gnuseye-panel n))))

;;;; Crypto (CoinGecko) -------------------------------------------------------

(cmacs-gnuseye-define-panel crypto
  :title "Crypto (CoinGecko)"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json
            (concat "https://api.coingecko.com/api/v3/coins/markets"
                    "?vs_currency=usd&order=market_cap_desc&per_page=15&page=1")
            cb nil 'list))
  :render
  (lambda (data)
    (mapconcat
     (lambda (c)
       (format "%-6s %12s  %s"
               (upcase (format "%s" (alist-get 'symbol c)))
               (format "$%s" (alist-get 'current_price c))
               (cmacs-gnuseye--pct (alist-get 'price_change_percentage_24h c))))
     data "\n")))

;;;; Fear & Greed (alternative.me) --------------------------------------------

(cmacs-gnuseye-define-panel fear-greed
  :title "Fear & Greed"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json "https://api.alternative.me/fng/" cb))
  :render
  (lambda (data)
    (let ((d (car (alist-get 'data data))))
      (if d (format "Index: %s  (%s)\nupdated: %s"
                    (alist-get 'value d)
                    (alist-get 'value_classification d)
                    (alist-get 'timestamp d))
        "no data"))))

;;;; FX (Frankfurter / ECB) ---------------------------------------------------

(cmacs-gnuseye-define-panel fx
  :title "FX (USD base, ECB)"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json
            "https://api.frankfurter.app/latest?from=USD" cb))
  :render
  (lambda (data)
    (let ((rates (alist-get 'rates data)))
      (if rates
          (mapconcat (lambda (kv) (format "USD/%s  %s" (car kv) (cdr kv)))
                     (seq-filter (lambda (kv)
                                   (memq (car kv) '(EUR GBP JPY CNY CHF CAD AUD INR)))
                                 rates)
                     "\n")
        "no data"))))

;;;; Predictions (Polymarket) -------------------------------------------------

(cmacs-gnuseye-define-panel predictions
  :title "Predictions (Polymarket)"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json
            (concat "https://gamma-api.polymarket.com/markets"
                    "?closed=false&limit=15&order=volume&ascending=false")
            cb nil 'list))
  :render
  (lambda (data)
    (mapconcat
     (lambda (m)
       (let ((q (or (alist-get 'question m) (alist-get 'title m))))
         (format "• %s" (truncate-string-to-width (format "%s" q) 60))))
     data "\n")))

;;;; Crypto market-cap treemap (SVG) ------------------------------------------

(require 'cmacs-gnuseye-charts nil t)

(cmacs-gnuseye-define-panel crypto-treemap
  :title "Crypto market caps"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json
            (concat "https://api.coingecko.com/api/v3/coins/markets"
                    "?vs_currency=usd&order=market_cap_desc&per_page=20&page=1")
            cb nil 'list))
  :render
  (lambda (data)
    (if (fboundp 'cmacs-gnuseye-chart-treemap)
        (concat (cmacs-gnuseye-chart-treemap
                 (mapcar (lambda (c)
                           (cons (upcase (format "%s" (alist-get 'symbol c)))
                                 (or (alist-get 'market_cap c) 0)))
                         data)
                 320 200)
                "\n")
      "svg charts unavailable")))

;;;; Hacker News front page (keyless) -----------------------------------------

(cmacs-gnuseye-define-panel hackernews
  :title "Hacker News"
  :fetch (lambda (cb)
           (cmacs-gnuseye-fetch-json
            "https://hn.algolia.com/api/v1/search?tags=front_page" cb))
  :render
  (lambda (data)
    (mapconcat
     (lambda (h)
       (format "%4s  %s" (or (alist-get 'points h) "")
               (truncate-string-to-width
                (format "%s" (or (alist-get 'title h) "")) 56)))
     (seq-take (alist-get 'hits data) 20) "\n")))

;;;; FRED macro series (keyed stub) -------------------------------------------

(defcustom cmacs-gnuseye-fred-series "DGS10"
  "FRED series id for the macro panel (e.g. DGS10 = 10y Treasury)."
  :type 'string :group 'cmacs-gnuseye)

(cmacs-gnuseye-define-panel fred
  :title "FRED macro (needs FRED_API_KEY)"
  :fetch (lambda (cb)
           (let ((key (cmacs-gnuseye-secret "FRED_API_KEY")))
             (if (not key)
                 (funcall cb nil)
               (cmacs-gnuseye-fetch-json
                (format (concat "https://api.stlouisfed.org/fred/series/"
                                "observations?series_id=%s&api_key=%s"
                                "&file_type=json&sort_order=desc&limit=20")
                        cmacs-gnuseye-fred-series key)
                cb))))
  :render
  (lambda (data)
    (if (null data) "Set FRED_API_KEY to enable."
      (let ((obs (reverse (alist-get 'observations data))))
        (concat
         (when (fboundp 'cmacs-gnuseye-chart-sparkline)
           (concat (cmacs-gnuseye-chart-sparkline
                    (mapcar (lambda (o) (string-to-number
                                         (or (alist-get 'value o) "0")))
                            obs)
                    160 24) "\n"))
         (format "%s: latest %s"
                 cmacs-gnuseye-fred-series
                 (alist-get 'value (car (last obs)))))))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "D") #'cmacs-gnuseye-dashboard))

(provide 'cmacs-gnuseye-markets)
;;; cmacs-gnuseye-markets.el ends here
