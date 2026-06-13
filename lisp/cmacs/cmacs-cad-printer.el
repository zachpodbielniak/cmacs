;;; cmacs-cad-printer.el --- Upload G-code to 3D printers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Upload a sliced G-code file to a networked printer over four backends
;; -- OctoPrint, Moonraker/Klipper, PrusaLink, and a local "copy to a
;; directory" sink -- via one transport: `curl' run with make-process.
;;
;; Safety + secrets:
;;   * API keys come from auth-source ONLY (never a defcustom slot, never
;;     an argv that `ps' could read): curl is invoked as `curl -K -' and
;;     the config (url, auth header, form fields) is fed on STDIN.
;;   * Printing is gated: `cmacs-cad-printer-upload' only uploads;
;;     `cmacs-cad-printer-start' is the ONLY path that starts a print and
;;     requires either an interactive `yes-or-no-p' or a programmatic
;;     `:confirm t'.  (A voice or MCP caller cannot start a print without
;;     an explicit human confirmation.)

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'url-util)

(defgroup cmacs-cad-printer nil
  "Send G-code to networked 3D printers."
  :group 'cmacs-cad
  :prefix "cmacs-cad-printer-")

(defcustom cmacs-cad-printers nil
  "List of printer definitions.  Each is a plist:

  (:name NAME :type TYPE :url BASE-URL [:storage S] [:api-version V])

TYPE is one of `octoprint', `moonraker', `prusalink' or `gcode'.  For
the network types the API key is looked up via auth-source by the URL
host (machine HOST, secret KEY) -- never stored here.  For `gcode',
:url is a local directory the file is copied into."
  :type '(repeat plist))

(defun cmacs-cad-printer--find (name)
  "Return the printer plist named NAME, or signal."
  (or (cl-find name cmacs-cad-printers
               :key (lambda (p) (plist-get p :name)) :test #'equal)
      (user-error "No printer named %s" name)))

(defun cmacs-cad-printer--host (printer)
  "Return the host of PRINTER's :url."
  (url-host (url-generic-parse-url (plist-get printer :url))))

(defun cmacs-cad-printer--api-key (printer)
  "Look up PRINTER's API key via auth-source (by URL host), or nil."
  (let* ((host (cmacs-cad-printer--host printer))
         (found (and host
                     (car (auth-source-search :host host :max 1
                                              :require '(:secret))))))
    (when found
      (let ((secret (plist-get found :secret)))
        (if (functionp secret) (funcall secret) secret)))))

;;; curl transport

(defun cmacs-cad-printer--curl-config (url method headers forms)
  "Build a curl config string (for `curl -K -') from URL, METHOD,
HEADERS (alist NAME . VALUE) and FORMS (alist FIELD . VALUE, where a
VALUE starting with @ is a file)."
  (with-temp-buffer
    (insert (format "url = \"%s\"\n" url))
    (when method
      (insert (format "request = \"%s\"\n" method)))
    (dolist (h headers)
      (insert (format "header = \"%s: %s\"\n" (car h) (cdr h))))
    (dolist (f forms)
      (insert (format "form = \"%s=%s\"\n" (car f) (cdr f))))
    (buffer-string)))

(defun cmacs-cad-printer--run (config &optional extra-args callback)
  "Run `curl -K -' feeding CONFIG on stdin.  EXTRA-ARGS are appended.
CALLBACK is called with (OK STATUS-LINE) on completion.  Returns the buffer."
  (let* ((buf (get-buffer-create "*cmacs-cad printer*"))
         (proc (make-process
                :name "cmacs-cad-curl"
                :buffer buf
                :command (append (list "curl" "--silent" "--show-error"
                                       "--fail-with-body"
                                       "--config" "-")
                                 extra-args)
                :noquery t
                :connection-type 'pipe
                :sentinel
                (lambda (p _e)
                  (when (memq (process-status p) '(exit signal))
                    (let ((ok (= 0 (process-exit-status p))))
                      (when callback
                        (funcall callback ok
                                 (with-current-buffer buf
                                   (buffer-string))))
                      (message "Printer transfer %s"
                               (if ok "ok" "FAILED"))))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer)))
    (process-send-string proc config)
    (process-send-eof proc)
    buf))

;;; Per-backend upload (cl-defgeneric on TYPE)

(cl-defgeneric cmacs-cad-printer--backend-upload (type printer gcode start)
  "Upload GCODE to PRINTER of TYPE; START non-nil also begins the print.")

(cl-defmethod cmacs-cad-printer--backend-upload
  ((_type (eql octoprint)) printer gcode start)
  (let* ((key (cmacs-cad-printer--api-key printer))
         (url (concat (string-trim-right (plist-get printer :url) "/")
                      "/api/files/local"))
         (config (cmacs-cad-printer--curl-config
                  url "POST"
                  (when key (list (cons "X-Api-Key" key)))
                  (append (list (cons "file" (concat "@" gcode)))
                          (when start '(("print" . "true")))))))
    (cmacs-cad-printer--run config)))

(cl-defmethod cmacs-cad-printer--backend-upload
  ((_type (eql moonraker)) printer gcode start)
  (let* ((key (cmacs-cad-printer--api-key printer))
         (url (concat (string-trim-right (plist-get printer :url) "/")
                      "/server/files/upload"))
         (config (cmacs-cad-printer--curl-config
                  url "POST"
                  (when key (list (cons "X-Api-Key" key)))
                  (append (list (cons "file" (concat "@" gcode)))
                          (when start '(("print" . "true")))))))
    (cmacs-cad-printer--run config)))

(cl-defmethod cmacs-cad-printer--backend-upload
  ((_type (eql prusalink)) printer gcode start)
  (let* ((key (cmacs-cad-printer--api-key printer))
         (storage (or (plist-get printer :storage) "usb"))
         (name (file-name-nondirectory gcode))
         (url (format "%s/api/v1/files/%s/%s"
                      (string-trim-right (plist-get printer :url) "/")
                      storage name))
         (config (cmacs-cad-printer--curl-config
                  url "PUT"
                  (append (when key (list (cons "X-Api-Key" key)))
                          (list (cons "Print-After-Upload"
                                      (if start "?1" "?0"))
                                (cons "Content-Type"
                                      "application/octet-stream")))
                  nil)))
    ;; PrusaLink takes the file as the raw PUT body.
    (cmacs-cad-printer--run config
                            (list "--data-binary" (concat "@" gcode)))))

(cl-defmethod cmacs-cad-printer--backend-upload
  ((_type (eql gcode)) printer gcode start)
  (let* ((dir (file-name-as-directory
               (expand-file-name (plist-get printer :url))))
         (dest (expand-file-name (file-name-nondirectory gcode) dir)))
    (make-directory dir t)
    (copy-file gcode dest t)
    (when start
      (message "gcode sink: copied to %s (no remote print to start)" dest))
    dest))

;;; Public API

(defun cmacs-cad-printer-upload (name gcode)
  "Upload GCODE to the printer named NAME (no print started)."
  (interactive
   (list (completing-read "Printer: "
                          (mapcar (lambda (p) (plist-get p :name))
                                  cmacs-cad-printers)
                          nil t)
         (read-file-name "G-code: " nil nil t)))
  (let ((printer (cmacs-cad-printer--find name)))
    (cmacs-cad-printer--backend-upload
     (plist-get printer :type) printer (expand-file-name gcode) nil)))

(cl-defun cmacs-cad-printer-start (name gcode &key confirm)
  "Upload GCODE to printer NAME AND start the print.
This is the only path that starts a print.  It refuses unless either it
is called interactively and the user answers `yes-or-no-p', or CONFIRM is
non-nil (a programmatic caller's explicit acknowledgement)."
  (interactive
   (list (completing-read "Printer: "
                          (mapcar (lambda (p) (plist-get p :name))
                                  cmacs-cad-printers)
                          nil t)
         (read-file-name "G-code: " nil nil t)
         :confirm
         (yes-or-no-p "Start the print on the selected printer? ")))
  (unless confirm
    (user-error "Refusing to start a print without confirmation"))
  (let ((printer (cmacs-cad-printer--find name)))
    (cmacs-cad-printer--backend-upload
     (plist-get printer :type) printer (expand-file-name gcode) t)))

(provide 'cmacs-cad-printer)
;;; cmacs-cad-printer.el ends here
