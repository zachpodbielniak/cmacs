;;; cmacs-gsurf-tools.el --- The gsurf browser as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The twenty-nine `gsurf_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-gsurf.c that
;; evaluated a printf-built call to a `cmacs-gsurf-mcp-*' helper.  Here
;; they are `cmacs-brigade-deftool' forms calling the same helpers
;; (doc_org/cmacs/cmacs-capability.org has the recipe), reaching
;; in-process agents, MCP clients, org.cmacs.Editor1.Tools and
;; `emacsctl tool gsurf ...' from one definition.  Wire names, parameter
;; names and the required/optional split are the C ones.  The C file is
;; deleted; the schema it published is frozen in
;; test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; Redaction
;; ---------
;;
;; A browser is the most revealing thing these tools can reach, so every
;; tool that names or acts on a view goes through the one rule set that
;; decides what a model-facing surface may show (lisp/cmacs/
;; cmacs-redact.el; the rules are the activity journal's):
;;
;;   - A view whose URL `cmacs-redact-url' excludes does not exist as
;;     far as these tools are concerned.  It is left out of
;;     `gsurf_list', it is never the "most recent" view a tool defaults
;;     to, and naming it is refused -- by the tools that read it and by
;;     the ones that act on it (click, type, key, JavaScript, cookie,
;;     zoom, history, snapshot, print), since acting on a page is a way
;;     of reading it.
;;
;;   - `gsurf_snapshot' and `gsurf_print_pdf' produce a picture of the
;;     page, which cannot be rewritten afterwards, so they also ask
;;     `cmacs-redact-capture-refused-p' -- the check the C handler
;;     made -- which looks at the title as well as the URL.
;;
;;   - The refusal is one fixed message, the same one a name that
;;     matches nothing gets (`cmacs-gsurf-tools--unavailable').  A
;;     caller cannot use it to learn that a hidden view exists, let
;;     alone which rule hid it.
;;
;;   - `gsurf_navigate' is the exception: sending a view somewhere else
;;     reveals nothing about where it was.
;;
;;   - URLs are reported as `cmacs-redact-url' rewrote them; titles and
;;     page text pass through `cmacs-redact-text'.
;;
;; This file only calls those functions.  Whether the current caller is
;; model-facing at all, and failing closed when the rules did not load,
;; are theirs to decide.
;;
;; What else differs from the C handlers, on purpose:
;;
;;   - A buffer name that is not a gsurf view is refused.  The C helper
;;     fell back to the most recent view, so a tool could act on a page
;;     other than the one it was asked about.
;;
;;   - `gsurf_snapshot' and `gsurf_print_pdf' answer when the file has
;;     been written (or could not be), from the primitive's own
;;     callback, instead of returning the path of a file that does not
;;     exist yet.
;;
;;   - The tools that run code in, type into or change the state of a
;;     logged-in browser session -- `gsurf_eval_js', `gsurf_type_text',
;;     `gsurf_press_key', `gsurf_set_cookie', `gsurf_permission_policy'
;;     -- and the two that write a file are :destructive and go through
;;     the shared confirmation policy (`cmacs-brigade-auto-approve').
;;     `gsurf_eval_js' also stays in the C allowlist's privileged set,
;;     which is keyed on the wire name and so is unchanged.
;;
;;   - No argument is spliced into Lisp source; a failure is a failure
;;     on every surface; a string result is the string, not its `prin1'
;;     form in quotes (so the JSON tools return JSON).

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-redact-url "cmacs-redact" (url))
(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function cmacs-redact-capture-refused-p "cmacs-redact"
                  (what &optional target))

(declare-function cmacs-gsurf--live-buffers "cmacs-gsurf" ())
(declare-function cmacs-gsurf-mcp-open "cmacs-gsurf" (url))
(declare-function cmacs-gsurf-mcp-navigate "cmacs-gsurf"
                  (url &optional buffer))
(declare-function cmacs-gsurf-mcp-back "cmacs-gsurf" (&optional buffer))
(declare-function cmacs-gsurf-mcp-forward "cmacs-gsurf" (&optional buffer))
(declare-function cmacs-gsurf-mcp-reload "cmacs-gsurf" (&optional buffer))
(declare-function cmacs-gsurf-mcp-stop "cmacs-gsurf" (&optional buffer))
(declare-function cmacs-gsurf-mcp-eval-js "cmacs-gsurf"
                  (script &optional buffer))
(declare-function cmacs-gsurf-mcp-set-zoom "cmacs-gsurf"
                  (level &optional buffer))
(declare-function cmacs-gsurf-mcp-permission-policy "cmacs-gsurf"
                  (origin type verdict))
(declare-function cmacs-gsurf-mcp-click "cmacs-gsurf-control"
                  (x y &optional button buffer))
(declare-function cmacs-gsurf-mcp-type-text "cmacs-gsurf-control"
                  (text &optional buffer))
(declare-function cmacs-gsurf-mcp-press-key "cmacs-gsurf-control"
                  (key &optional modifiers buffer))
(declare-function cmacs-gsurf-mcp-click-element "cmacs-gsurf-control"
                  (selector &optional buffer))
(declare-function cmacs-gsurf-mcp-set-cookie "cmacs-gsurf-control"
                  (name value domain &optional path secure http-only
                        expires buffer))
(declare-function cmacs-gsurf-mcp-toggle-module "cmacs-gsurf-control"
                  (name enabled))
(declare-function cmacs-gsurf-mcp-run-action "cmacs-gsurf-control"
                  (action &optional buffer))
(declare-function cmacs-gsurf-mcp-list-actions "cmacs-gsurf-control" ())
(declare-function cmacs-gsurf-mcp-list-containers "cmacs-gsurf-control" ())
(declare-function cmacs-gsurf-lite-mcp-open "cmacs-gsurf-lite" (url))
(declare-function cmacs-gsurf-lite-mcp-extract-text "cmacs-gsurf-lite"
                  (&optional name))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-progress "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-modules-list "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-snapshot "cmacs-gsurf-defuns.c"
                  (buffer file &optional callback full-page))
(declare-function cmacs-gsurf-print-to-pdf "cmacs-gsurf-defuns.c"
                  (buffer file &optional callback))
(declare-function cmacs-gsurf-download-cancel "cmacs-gsurf-defuns.c" (id))

(defvar cmacs-gsurf--downloads)
(defvar cmacs-gsurf-lite--buffers)
(defvar cmacs-gsurf-lite--base-url)

(defconst cmacs-gsurf-tools--unavailable "No gsurf buffer is available"
  "The one thing a tool says when it has no view to work on.
The same words whether no view is open, the name matches nothing, or the
view is one the redaction rules exclude -- so the answer cannot be used
to probe for a hidden view.")

(defconst cmacs-gsurf-tools--no-download "No such download"
  "What `gsurf_download_cancel' says for an id it will not act on.
Unknown and excluded downloads get the same words, for the same reason
as `cmacs-gsurf-tools--unavailable'.")


;;;; Redaction

(defun cmacs-gsurf-tools--shown-url (url)
  "Return URL as a model-facing surface may see it, or nil when excluded.
A view with no URL yet is asked about as the empty string, so that it
too is withheld when the rules fail closed."
  (require 'cmacs-redact)
  (cmacs-redact-url (or url "")))

(defun cmacs-gsurf-tools--shown-text (text)
  "Return TEXT with the free-text redaction rules applied."
  (require 'cmacs-redact)
  (cmacs-redact-text (or text "")))

(defun cmacs-gsurf-tools--view-url (buffer)
  "Return the URL gsurf view BUFFER is showing, or nil."
  (ignore-errors (cmacs-gsurf-get-uri buffer)))

(defun cmacs-gsurf-tools--visible-p (buffer)
  "Non-nil when gsurf view BUFFER may be shown to the current caller."
  (and (cmacs-gsurf-tools--shown-url (cmacs-gsurf-tools--view-url buffer))
       t))

(defun cmacs-gsurf-tools--named-p (name)
  "Non-nil when NAME is a buffer name a caller actually supplied."
  (and (stringp name) (not (string-empty-p name))))

(defun cmacs-gsurf-tools--target (name &optional allow-excluded)
  "Return the gsurf view a tool should work on, or signal.

NAME, when given, must be the name of a live gsurf view.  Without NAME
the most recently opened view the caller may see is used.  A view the
redaction rules exclude is refused unless ALLOW-EXCLUDED is non-nil,
which only `gsurf_navigate' passes.  Every refusal signals
`cmacs-gsurf-tools--unavailable' and nothing else."
  (require 'cmacs-gsurf)
  (let* ((live (cmacs-gsurf--live-buffers))
         (buf (cond
               ((cmacs-gsurf-tools--named-p name)
                (let ((b (get-buffer name)))
                  (and b (memq b live) b)))
               (allow-excluded (car live))
               (t (seq-find #'cmacs-gsurf-tools--visible-p live)))))
    (unless (and buf
                 (or allow-excluded (cmacs-gsurf-tools--visible-p buf)))
      (error "%s" cmacs-gsurf-tools--unavailable))
    buf))

;; A picture of a page cannot be rewritten the way its URL or title can,
;; so the capturing tools ask the stricter question the image-returning C
;; tools ask (`cmacs-redact-capture-refused-p': the view's URL and its
;; title), and answer a refusal in the same fixed words as everything
;; else here.

(defun cmacs-gsurf-tools--capture-target (name)
  "Return the gsurf view NAME may be captured from, or signal.
As `cmacs-gsurf-tools--target', and the view must also pass the capture
rule."
  (let ((buf (cmacs-gsurf-tools--target name)))
    (when (cmacs-redact-capture-refused-p 'gsurf (buffer-name buf))
      (error "%s" cmacs-gsurf-tools--unavailable))
    buf))

(defun cmacs-gsurf-tools--target-name (name)
  "Return the name of the view `cmacs-gsurf-tools--target' picks for NAME.
The `cmacs-gsurf-mcp-*' helpers take a buffer name; handing them the
resolved one keeps them from making a different choice."
  (buffer-name (cmacs-gsurf-tools--target name)))

(defun cmacs-gsurf-tools--lite-target (name)
  "Return the gsurf-lite buffer for NAME, or the newest visible one.
Refusals are as in `cmacs-gsurf-tools--target'."
  (require 'cmacs-gsurf-lite)
  (let* ((live (seq-filter #'buffer-live-p cmacs-gsurf-lite--buffers))
         (visible-p
          (lambda (b)
            (and (cmacs-gsurf-tools--shown-url
                  (buffer-local-value 'cmacs-gsurf-lite--base-url b))
                 t)))
         (buf (if (cmacs-gsurf-tools--named-p name)
                  (let ((b (get-buffer name)))
                    (and b (memq b live) b))
                (seq-find visible-p live))))
    (unless (and buf (funcall visible-p buf))
      (error "%s" cmacs-gsurf-tools--unavailable))
    buf))

(defun cmacs-gsurf-tools--string (value what)
  "Return VALUE if it is a non-empty string, else signal that WHAT is missing."
  (unless (cmacs-gsurf-tools--named-p value)
    (error "Missing required argument: %s" what))
  value)


;;;; Opening and navigating

(cmacs-brigade-deftool gsurf-open
    "Open a URL (or search query) in a new gsurf browser buffer; returns \
the buffer name."
    ((url string "URL or search query"))
  :group 'gsurf
  :destructive t
  :undo 'cmacs-brigade-undo-capture-gsurf-open
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Open
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf open --url https://www.gnu.org/"
  (require 'cmacs-gsurf)
  (cmacs-gsurf-mcp-open (cmacs-gsurf-tools--string url "url")))

(cmacs-brigade-deftool gsurf-navigate
    "Navigate a gsurf buffer to a URL (or search query)."
    ((url string "URL or search query")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo 'cmacs-brigade-undo-capture-gsurf-navigate
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Navigate
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf navigate --url https://www.gnu.org/"
  ;; The one acting tool allowed on an excluded view: it sends the view
  ;; elsewhere and reports only the URL the caller supplied.
  (let ((buf (cmacs-gsurf-tools--target buffer t)))
    (cmacs-gsurf-mcp-navigate (cmacs-gsurf-tools--string url "url")
                              (buffer-name buf))))

(cmacs-brigade-deftool gsurf-back
    "Navigate a gsurf buffer back."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "history moved; use gsurf_forward")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Back
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf back"
  (cmacs-gsurf-mcp-back (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-forward
    "Navigate a gsurf buffer forward."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "history moved; use gsurf_back")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Forward
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf forward"
  (cmacs-gsurf-mcp-forward (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-reload
    "Reload a gsurf buffer."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "a reload discards the page's state")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Reload
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf reload"
  (cmacs-gsurf-mcp-reload (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-stop
    "Stop loading in a gsurf buffer."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "a stopped load is not resumed; use gsurf_reload")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Stop
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf stop"
  (cmacs-gsurf-mcp-stop (cmacs-gsurf-tools--target-name buffer)))


;;;; Reading a view

(cmacs-brigade-deftool gsurf-get-uri
    "Return a gsurf buffer's current URI."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :example "emacsctl tool gsurf get-uri"
  (let ((buf (cmacs-gsurf-tools--target buffer)))
    ;; The target is visible, so this is a string: the URL as the rules
    ;; rewrote it, which is not necessarily the URL as loaded.
    (or (cmacs-gsurf-tools--shown-url (cmacs-gsurf-tools--view-url buf))
        (error "%s" cmacs-gsurf-tools--unavailable))))

(cmacs-brigade-deftool gsurf-get-title
    "Return a gsurf buffer's page title."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :example "emacsctl tool gsurf get-title"
  (let ((buf (cmacs-gsurf-tools--target buffer)))
    (cmacs-gsurf-tools--shown-text
     (ignore-errors (cmacs-gsurf-get-title buf)))))

(defun cmacs-gsurf-tools--describe (buffer url)
  "Return the plist `gsurf_list' reports for BUFFER, shown as URL."
  (list :buffer (buffer-name buffer)
        :uri url
        :title (cmacs-gsurf-tools--shown-text
                (ignore-errors (cmacs-gsurf-get-title buffer)))))

(cmacs-brigade-deftool gsurf-current
    "Return JSON for the current gsurf buffer \
\(buffer/uri/title/progress)."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf current"
  (require 'json)
  (let* ((buf (cmacs-gsurf-tools--target nil))
         (url (cmacs-gsurf-tools--shown-url
               (cmacs-gsurf-tools--view-url buf))))
    (unless url
      (error "%s" cmacs-gsurf-tools--unavailable))
    (json-encode
     (append (cmacs-gsurf-tools--describe buf url)
             (list :progress (cmacs-gsurf-get-progress buf))))))

(cmacs-brigade-deftool gsurf-list
    "Return a JSON array of all open gsurf buffers."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf list"
  (require 'cmacs-gsurf)
  (require 'json)
  (let (rows)
    ;; An excluded view is not listed at all: not as a blank row, not
    ;; as a count.
    (dolist (buf (cmacs-gsurf--live-buffers))
      (let ((url (cmacs-gsurf-tools--shown-url
                  (cmacs-gsurf-tools--view-url buf))))
        (when url
          (push (cmacs-gsurf-tools--describe buf url) rows))))
    ;; A vector, so no views is "[]" and not "null".
    (json-encode (vconcat (nreverse rows)))))

(cmacs-brigade-deftool gsurf-modules-list
    "Return JSON describing the loaded gsurf modules."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf modules-list"
  (or (cmacs-gsurf-modules-list)
      (error "The gsurf runtime is not up (open a gsurf buffer first)")))


;;;; Acting on a view

(cmacs-brigade-deftool gsurf-eval-js
    "Run JavaScript in a gsurf buffer's page (fire-and-forget)."
    ((script string "JavaScript source")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "a script's effects in a page cannot be taken back")
  :confirm 'ask
  (let ((name (cmacs-gsurf-tools--target-name buffer)))
    (cmacs-gsurf-mcp-eval-js (cmacs-gsurf-tools--string script "script")
                             name)))

(cmacs-brigade-deftool gsurf-set-zoom
    "Set the zoom level (1.0 = 100%) of a gsurf buffer."
    ((level number "zoom level")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo 'cmacs-brigade-undo-capture-gsurf-zoom
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.SetZoom
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf set-zoom --level 1.25"
  (unless (numberp level)
    (error "level must be a number"))
  (cmacs-gsurf-mcp-set-zoom level (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-lite-open
    "Open a URL as eww-style text: gsurf renders it offscreen (JavaScript \
runs, logins persist) and the post-JS page is dumped to a real Emacs \
text buffer.  Returns the buffer name; read it with gsurf_extract_text \
once loaded."
    ((url string "URL or search query"))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "close the buffer it opened")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.LiteOpen
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf lite-open --url https://www.gnu.org/"
  (require 'cmacs-gsurf-lite)
  ;; Returns as soon as the buffer exists; the page arrives in it later
  ;; and nothing here waits for the load.
  (cmacs-gsurf-lite-mcp-open (cmacs-gsurf-tools--string url "url")))

(cmacs-brigade-deftool gsurf-extract-text
    "Return the rendered plain text of a gsurf-lite buffer (newest, or \
the named one).  Reads a JS-rendered or logged-in page as clean text \
after gsurf_lite_open."
    ((buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :example "emacsctl tool gsurf extract-text"
  (let ((buf (cmacs-gsurf-tools--lite-target buffer)))
    (cmacs-gsurf-tools--shown-text
     (cmacs-gsurf-lite-mcp-extract-text (buffer-name buf)))))


;;;; Downloads

(cmacs-brigade-deftool gsurf-download-list
    "Return a JSON array of known gsurf downloads \
\(id/uri/dest/received/total/state)."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf download-list"
  (require 'cmacs-gsurf-downloads)
  (require 'json)
  (let (rows)
    (pcase-dolist (`(,id . ,pl) cmacs-gsurf--downloads)
      ;; A download is as revealing as the page it came from: one whose
      ;; source is excluded is left out, and the file name it was saved
      ;; under gets the free-text rules.
      (let ((uri (cmacs-gsurf-tools--shown-url (plist-get pl :uri))))
        (when uri
          (push (list (cons 'id id)
                      (cons 'uri uri)
                      (cons 'dest (cmacs-gsurf-tools--shown-text
                                   (plist-get pl :dest)))
                      (cons 'received (or (plist-get pl :received) 0))
                      (cons 'total (or (plist-get pl :total) 0))
                      (cons 'state (format "%s" (plist-get pl :state))))
                rows))))
    (json-encode (vconcat (nreverse rows)))))

(cmacs-brigade-deftool gsurf-download-cancel
    "Cancel an in-flight gsurf download by id."
    ((id integer "download id"))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "a cancelled download cannot be resumed")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.DownloadCancel
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf download-cancel --id 3"
  (require 'cmacs-gsurf)
  (require 'cmacs-gsurf-downloads)
  (let ((known (and (integerp id) (assq id cmacs-gsurf--downloads))))
    ;; Only a download the caller could have been shown can be
    ;; cancelled, and the two ways of not being one look the same.
    (unless (and known
                 (cmacs-gsurf-tools--shown-url (plist-get (cdr known) :uri)))
      (error "%s" cmacs-gsurf-tools--no-download))
    (cmacs-gsurf-download-cancel id)
    "ok"))


;;;; Snapshot and print

(cmacs-brigade-deftool gsurf-snapshot
    "Save a PNG snapshot of a gsurf buffer to FILE (async); returns the \
path.  Set full_page for the whole document."
    ((file string "output PNG path")
     (full-page boolean "capture full document" :optional t)
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "the image is written after the call returns")
  :confirm 'ask
  :async t
  (let ((buf (cmacs-gsurf-tools--capture-target buffer))
        (path (expand-file-name (cmacs-gsurf-tools--string file "file"))))
    ;; The primitive renders off the main thread and calls back with
    ;; the path, or nil when the capture failed.
    (cmacs-gsurf-snapshot
     buf path
     (lambda (out)
       (funcall done (if out path "Error: the snapshot could not be saved")))
     (and full-page t))))

(cmacs-brigade-deftool gsurf-print-pdf
    "Print a gsurf buffer to a PDF at FILE (async); returns the path."
    ((file string "output PDF path")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "the PDF is written after the call returns")
  :confirm 'ask
  :async t
  (let ((buf (cmacs-gsurf-tools--capture-target buffer))
        (path (expand-file-name (cmacs-gsurf-tools--string file "file"))))
    (cmacs-gsurf-print-to-pdf
     buf path
     (lambda (out)
       (funcall done (if out path "Error: the PDF could not be written"))))))


;;;; Permissions and input

(cmacs-brigade-deftool gsurf-permission-policy
    "Set a permission policy for an origin and type (verdict \"allow\" or \
\"deny\")."
    ((origin string "scheme://host:port")
     (type string "geolocation/notification/media/...")
     (verdict string "allow or deny"))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "the previous policy is not kept")
  :confirm 'ask
  (require 'cmacs-gsurf)
  ;; The helper interns the verdict; only the two it documents get
  ;; that far.
  (unless (member verdict '("allow" "deny"))
    (error "verdict must be allow|deny"))
  (cmacs-gsurf-mcp-permission-policy
   (cmacs-gsurf-tools--string origin "origin")
   (cmacs-gsurf-tools--string type "type")
   verdict))

;; gsurf 0.5 control surface.  Input is trusted (native GTK events) and
;; needs the page to have been on screen once; keyboard focus is
;; borrowed for the call and handed back to the editor.

(cmacs-brigade-deftool gsurf-click
    "Click at x,y (CSS pixels from the page's top-left, as \
getBoundingClientRect reports) in a gsurf page with a trusted click."
    ((x number "CSS px from the left")
     (y number "CSS px from the top")
     (button integer "1 left (default), 2 middle, 3 right" :optional t)
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "input delivered to a page cannot be taken back")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.Click
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf click --x 120 --y 48"
  (unless (and (numberp x) (numberp y))
    (error "x and y must be numbers"))
  (cmacs-gsurf-mcp-click
   x y
   ;; Anything that is not a button is the left one, as in C.
   (if (and (integerp button) (<= 1 button 3)) button 1)
   (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-type-text
    "Type text into whatever has focus in a gsurf page, one trusted key \
press per character (newline = Enter).  Focus a field first with \
gsurf_click_element."
    ((text string "UTF-8 text")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "input delivered to a page cannot be taken back")
  :confirm 'ask
  (unless (stringp text)
    (error "Missing required argument: text"))
  (cmacs-gsurf-mcp-type-text text (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-press-key
    "Press and release one key in a gsurf page (trusted).  key is a DOM \
or X name (Enter, Tab, Escape, ArrowDown, PageDown, a, ...)."
    ((key string "key name or one character")
     (modifiers string "e.g. ctrl+shift (ctrl, shift, alt/meta, super)"
                :optional t)
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "input delivered to a page cannot be taken back")
  :confirm 'ask
  (cmacs-gsurf-mcp-press-key
   (cmacs-gsurf-tools--string key "key")
   (and (cmacs-gsurf-tools--named-p modifiers) modifiers)
   (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-click-element
    "Click the first element matching a CSS selector in a gsurf page: it \
is scrolled into view, focused and clicked at its centre.  \
Asynchronous: returns at once; the outcome goes to the echo area."
    ((selector string "CSS selector")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "input delivered to a page cannot be taken back")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.ClickElement
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf click-element --selector 'input[name=q]'"
  (cmacs-gsurf-mcp-click-element
   (cmacs-gsurf-tools--string selector "selector")
   (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-set-cookie
    "Add a cookie to a gsurf view's session (its container's cookie jar \
for a view in a container)."
    ((name string "Cookie name")
     (value string "Cookie value")
     (domain string "example.com, or .example.com for subdomains too")
     (path string "default /" :optional t)
     (secure boolean "Send over HTTPS only" :optional t)
     (http-only boolean "Hide from page scripts" :optional t)
     (expires integer "Unix seconds; 0 = session cookie" :optional t)
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "the cookie it replaced is not kept")
  :confirm 'ask
  (unless (and (stringp name) (stringp value) (stringp domain))
    (error "Missing required argument: name, value or domain"))
  (cmacs-gsurf-mcp-set-cookie
   name value domain
   (and (cmacs-gsurf-tools--named-p path) path)
   (and secure t) (and http-only t)
   (if (integerp expires) expires 0)
   (cmacs-gsurf-tools--target-name buffer)))


;;;; Modules, actions, containers

(cmacs-brigade-deftool gsurf-toggle-module
    "Enable or disable a loaded gsurf module by name (adblock, dark_mode, \
hardening, containers, form_autofill, modal, ...)."
    ((name string "module name")
     (enabled boolean "true to enable, false to disable"))
  :group 'gsurf
  :destructive t
  :undo 'cmacs-brigade-undo-capture-gsurf-module
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.ToggleModule
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf toggle-module --name adblock --enabled true"
  (require 'cmacs-gsurf)
  (let ((text (cmacs-gsurf-mcp-toggle-module
               (cmacs-gsurf-tools--string name "name") (and enabled t))))
    ;; The helper reports an unknown module as ordinary text.
    (when (string-prefix-p "no such gsurf module" text)
      (error "%s" text))
    text))

(cmacs-brigade-deftool gsurf-run-action
    "Run a gsurf action by name on a gsurf buffer (see \
gsurf_list_actions): core ones map to editor commands, the rest go to \
the modules (dark-mode-toggle, dark-mode-toggle-site, form-autofill, \
...)."
    ((action string "action name")
     (buffer string "gsurf buffer name; defaults to the most recent"
             :optional t))
  :group 'gsurf
  :destructive t
  :undo '(irreversible "an action's effect in a page cannot be taken back")
  ;; Destructive, and on `dbus' and `cli' all the same:
  ;; org.cmacs.Editor1.Gsurf.RunAction
  ;; has always done this, and is now served from this tool.
  :surfaces '(agents mcp dbus cli menu)
  :example "emacsctl tool gsurf run-action --action dark-mode-toggle"
  ;; "not handled" is an answer about the action, not a failure, and
  ;; stays text.  The helper refuses the actions that would prompt.
  (cmacs-gsurf-mcp-run-action
   (cmacs-gsurf-tools--string action "action")
   (cmacs-gsurf-tools--target-name buffer)))

(cmacs-brigade-deftool gsurf-list-actions
    "Return a JSON array of every gsurf action: name, description and \
handler (cmacs or module)."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf list-actions"
  (require 'cmacs-gsurf)
  (cmacs-gsurf-mcp-list-actions))

(cmacs-brigade-deftool gsurf-list-containers
    "Return a JSON array of gsurf browsing containers (id, name, color, \
temporary, views, proxy)."
    ()
  :group 'gsurf
  :returns 'json
  :example "emacsctl tool gsurf list-containers"
  (require 'cmacs-gsurf)
  (cmacs-gsurf-mcp-list-containers))

(provide 'cmacs-gsurf-tools)

;;; cmacs-gsurf-tools.el ends here
