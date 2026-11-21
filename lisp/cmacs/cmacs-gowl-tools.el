;;; cmacs-gowl-tools.el --- The gowl compositor as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The `gowl_*' MCP tools of cmacs/mcp/cmacs-mcp-tools-gowl.c, moved onto
;; the capability table (doc_org/cmacs/cmacs-capability.org has the
;; recipe; cmacs-calculator-tools.el is the worked example).  The wire
;; names, parameter names and result shapes are the C ones, so nothing
;; that called `gowl_list_clients' has to change.  Those C handlers are
;; deleted; the schema these tools must keep is what they published,
;; frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; What a body calls is what the C handler called: a `gowl-*' DEFUN, or
;; the function in cmacs-gowl-macro.el / -broadcast.el / -hotkey.el /
;; -grab.el the C built a form around.  Where the C handler went straight
;; to gowl in C (`cmacs_dispatch_gowl_list_clients' and friends) the body
;; uses the DEFUNs that read the same state and prints the same JSON.
;; Every DEFUN takes the compositor lock itself; nothing here holds it.
;;
;; Four things differ from the C, all on purpose:
;;
;;   - No argument is spliced into Lisp source.  Words that go on a
;;     module command line are still checked to be one word, and free
;;     text to be one line, because the module's framing is a line.
;;
;;   - A failure is a failure: the error is signalled, not returned as
;;     text.  The messages are the C ones ("Gowl compositor not running",
;;     "no client matching pattern", "Missing required argument: ...").
;;
;;   - `gowl_screen_text' is asynchronous.  The C handler ran tesseract
;;     with `call-process', and a tool call is dispatched on the main
;;     thread, which under `emacs --gowl' is the compositor: the desktop
;;     stood still for as long as the OCR took.
;;
;;   - The redaction contract (cmacs-redact.el) is applied wherever a
;;     tool shows what is on the person's screen.  A window the rules
;;     exclude is absent from the client list, is "nil" to
;;     `gowl_focused_client' and `gowl_find_client', and cannot be
;;     focused, closed, moved or assigned -- with the message a window
;;     that does not exist gets, so the tools cannot be used to find out
;;     that it is there.  A pattern is matched against the title the
;;     caller is shown, never the one it is not.  Screen text and pixel
;;     colours are refused for a region showing such a window; OCR text
;;     and clipboard previews go through `cmacs-redact-text'.
;;
;; `gowl_macro_run', `gowl_broadcast_add_team', `gowl_broadcast_add_rule'
;; and `gowl_hotkey_add' take an array or an object, which the registry
;; can describe (`cmacs-brigade-tool-types').  Each hands its argument on
;; to a module's command line as JSON, as the C did, so the body turns
;; the alist it received back into text with
;; `cmacs-brigade-structured-json'.  The one thing that differs from the
;; C's text: an EMPTY array or object nested inside the argument is
;; written as null (see that function), which gowl's flow-YAML reader
;; takes for an empty value.
;;
;; Not here, and still served by the C: `gowl_screenshot' (an image),
;; and `gowl_hotkey_send', which is `send_keys' by another name and
;; stays with the privileged set.  `gowl_reload_config' is registered at
;; the end of this file only when the DEFUN it needs exists -- see the
;; comment there; without it nothing serves the name.  The
;; `screensaver_*' tools that were registered from the same C file are
;; cmacs-screensaver-tools.el.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-client-sticky-p "cmacs-gowl.c" (client))
(declare-function gowl-client-fullscreen-p "cmacs-gowl.c" (client))
(declare-function gowl-find-client "cmacs-gowl.c" (pattern &optional by))
(declare-function gowl-focus-client "cmacs-gowl.c" (client))
(declare-function gowl-close-client "cmacs-gowl.c" (client))
(declare-function gowl-client-set-geometry "cmacs-gowl.c" (client x y w h))
(declare-function gowl-spawn "cmacs-gowl.c" (command))
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-set-monitor-transform "cmacs-gowl.c"
                  (transform &optional monitor))
(declare-function gowl-list-keybinds "cmacs-gowl.c" ())
(declare-function gowl-set-layout "cmacs-gowl.c" (layout &optional monitor))
(declare-function gowl-workspace-list "cmacs-gowl.c" ())
(declare-function gowl-workspace-switch "cmacs-gowl.c" (id))
(declare-function gowl-start-recording "cmacs-gowl.c"
                  (&optional max-seconds max-events))
(declare-function gowl-drain-recording "cmacs-gowl.c" (token))
(declare-function gowl-stop-recording "cmacs-gowl.c" (&optional token))
(declare-function gowl-recording-status "cmacs-gowl.c" ())
(declare-function gowl-screenshot-region "cmacs-gowl.c"
                  (x y w h &optional monitor))
(declare-function gowl-screenshot-save-png "cmacs-gowl.c" (&rest args))
(declare-function gowl-clipboard-set "cmacs-gowl.c" (text))
(declare-function cmacs-gowl-command "cmacs-gowl-grab" (line))
(declare-function cmacs-gowl-pixel-color "cmacs-gowl-grab" (x y))
(declare-function cmacs-gowl-grab--ocr-config "cmacs-gowl-grab" ())
(declare-function cmacs-gowl-macro-command "cmacs-gowl-macro" (line))
(declare-function cmacs-gowl-macro-record-command "cmacs-gowl-macro"
                  (action &optional name for-agent))
(declare-function cmacs-gowl-macro-voice-text "cmacs-gowl-macro"
                  (text &optional dry-run))
(declare-function cmacs-gowl-broadcast-command "cmacs-gowl-broadcast" (line))
(declare-function cmacs-gowl-hotkey-command "cmacs-gowl-hotkey" (line))
(declare-function cmacs-redact-window "cmacs-redact" (app title &optional pid))
(declare-function cmacs-redact-text "cmacs-redact" (string))

(defvar cmacs-gowl-grab-ocr-timeout)


;;;; Shared helpers

(defun cmacs-gowl-tools--running ()
  "Signal, in the C handlers' words, unless a compositor runs here.
The C checked `cmacs_gowl_compositor' before anything else and answered
\"Gowl compositor not running\"; so does every tool below."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (error "Gowl compositor not running")))

(defun cmacs-gowl-tools--missing (what)
  "Signal the C handlers' \"Missing required argument: WHAT\"."
  (error "Missing required argument: %s" what))

(defun cmacs-gowl-tools--quoted (value)
  "Return VALUE as `cmacs_dispatch_eval' returned it: printed by `prin1'.
The handlers that built a form and evaluated it got their answer back
printed, so the string \"focused\" reached the client inside double
quotes.  A client may be comparing against exactly that."
  (prin1-to-string value))

(defun cmacs-gowl-tools--raw (value)
  "Return VALUE as `cmacs_dispatch_eval_string' returned it.
A string verbatim, anything else printed."
  (if (stringp value) value (prin1-to-string value)))

(defun cmacs-gowl-tools--json-string (text)
  "Return TEXT (nil is \"\") as a JSON string literal, quotes included."
  (let ((text (or text "")))
    (decode-coding-string
     (condition-case nil
         (json-serialize text)
       ;; A title that is not valid text (raw bytes from a client) cannot
       ;; be serialised; an answer with the bytes replaced is better than
       ;; no client list at all.
       (error (json-serialize
               (replace-regexp-in-string "[^[:ascii:]]" "?"
                                         (string-to-multibyte text)))))
     'utf-8 t)))

(defun cmacs-gowl-tools--word-p (text)
  "Non-nil when TEXT is one word: what may go on a module command line.
The C's `gowl_broadcast_word': present, no whitespace, no control
character."
  (and (stringp text)
       (not (string-empty-p text))
       (not (string-match-p "[[:space:][:cntrl:]]" text))))

(defun cmacs-gowl-tools--one-line-p (text)
  "Non-nil when TEXT is present and one line (`gowl_hotkey_one_line')."
  (and (stringp text)
       (not (string-empty-p text))
       (not (string-match-p "[\n\r]" text))))

(defun cmacs-gowl-tools--shell-quote (text)
  "Return TEXT quoted as GLib's `g_shell_quote' quotes it.
The macro module splits its command line with `g_shell_parse_argv', and
the C handlers quoted with the matching function; `shell-quote-argument'
escapes differently and is for a real shell."
  (concat "'" (replace-regexp-in-string "'" "'\\''" text t t) "'"))


;;;; Redaction
;;
;; The rules live in cmacs-redact.el and decide everything, including
;; whether the current caller is one they apply to.  These only call.
;; When that file cannot be loaded the `require' signals and the tool
;; fails, which is the direction to fail in.

(defun cmacs-gowl-tools--redact-window (app title pid)
  "Return (APP . TITLE) as the caller may see it, or nil when it may not."
  (require 'cmacs-redact)
  (cmacs-redact-window app title pid))

(defun cmacs-gowl-tools--redact-text (text)
  "Return TEXT with the free-text rules applied; \"\" stays \"\"."
  (if (or (null text) (string-empty-p text))
      ""
    (require 'cmacs-redact)
    (cmacs-redact-text text)))

(defun cmacs-gowl-tools--client-raw (client)
  "Return what gowl knows of CLIENT as a plist, nothing withheld.
For this file's own decisions only; what a caller is shown comes from
`cmacs-gowl-tools--client'."
  (let* ((info (gowl-client-info client))
         (geometry (alist-get 'geometry info)))
    (list :client client
          :id (alist-get 'id info)
          :app (or (alist-get 'app-id info) "")
          :title (or (alist-get 'title info) "")
          :tags (or (alist-get 'tags info) 0)
          :floating (and (alist-get 'floating info) t)
          ;; `gowl-client-info' has no fullscreen key today and no DEFUN
          ;; reads the flag; taken from either the day one exists, and
          ;; left out of the JSON until then rather than guessed.
          :fullscreen (cond ((assq 'fullscreen info)
                             (if (alist-get 'fullscreen info) t :false))
                            ((fboundp 'gowl-client-fullscreen-p)
                             (if (gowl-client-fullscreen-p client) t :false)))
          :pid (gowl-client-pid client)
          :geometry (or geometry '(0 0 0 0)))))

(defun cmacs-gowl-tools--client (client)
  "Return CLIENT as the caller may see it, or nil when the rules exclude it.
The plist is `cmacs-gowl-tools--client-raw' with :app and :title
rewritten; :raw-app and :raw-title keep what gowl said, so a caller can
tell whether the name it would match on is the one being shown."
  (let* ((raw (cmacs-gowl-tools--client-raw client))
         (app (plist-get raw :app))
         (title (plist-get raw :title))
         (shown (cmacs-gowl-tools--redact-window
                 app title (plist-get raw :pid))))
    (when shown
      (append (list :app (or (car shown) "")
                    :title (or (cdr shown) "")
                    :raw-app app :raw-title title)
              raw))))

(defun cmacs-gowl-tools--client-json (rec shape)
  "Return the JSON object for client REC in the C handler's SHAPE.
SHAPE is `list', `focused' or `find': the three dispatch functions wrote
three different sets of keys, and each is kept as it was."
  (let ((geometry (plist-get rec :geometry))
        (floating (if (plist-get rec :floating) "true" "false"))
        (fullscreen (plist-get rec :fullscreen)))
    (concat
     (format "{\"id\":%d,\"title\":%s,\"app-id\":%s,\"tags\":%d,"
             (plist-get rec :id)
             (cmacs-gowl-tools--json-string (plist-get rec :title))
             (cmacs-gowl-tools--json-string (plist-get rec :app))
             (plist-get rec :tags))
     (pcase shape
       ('list (concat (format "\"floating\":%s," floating)
                      (and fullscreen
                           (format "\"fullscreen\":%s,"
                                   (if (eq fullscreen t) "true" "false")))
                      (format "\"pid\":%d," (plist-get rec :pid))))
       ('focused (format "\"floating\":%s,\"pid\":%d,"
                         floating (plist-get rec :pid)))
       (_ ""))
     (format "\"geometry\":[%d,%d,%d,%d]}"
             (nth 0 geometry) (nth 1 geometry)
             (nth 2 geometry) (nth 3 geometry)))))

(defun cmacs-gowl-tools--glob-p (pattern text)
  "Non-nil when TEXT matches PATTERN as `g_pattern_match_simple' matches.
`*' is any run of characters, `?' is one, the rest is literal, and the
whole of TEXT must match -- gowl's own client search."
  (let ((case-fold-search nil))
    (string-match-p
     (concat "\\`"
             (mapconcat (lambda (ch)
                          (pcase ch
                            (?* "\\(?:.\\|\n\\)*")
                            (?? "\\(?:.\\|\n\\)")
                            (_ (regexp-quote (char-to-string ch)))))
                        pattern "")
             "\\'")
     text)))

(defun cmacs-gowl-tools--find (pattern by)
  "Return the first client the caller may see matching PATTERN, or nil.
BY is \"title\" to match titles; anything else matches app-ids, which is
how the C read it.

gowl's own search runs first, so with nothing withheld the answer is the
one the C handler gave.  When it finds nothing, or its match is a window
the rules exclude or one shown under another name, the search is done
again here over what the caller is shown.  Matching the hidden name
instead would make every tool taking a pattern an oracle: whether some
window's title contains a given word would be answered for exactly the
titles the rules exist to keep back."
  (unless (stringp pattern)
    (cmacs-gowl-tools--missing "pattern"))
  (cmacs-gowl-tools--running)
  (let* ((by-title (equal by "title"))
         (shown-key (if by-title :title :app))
         (raw-key (if by-title :raw-title :raw-app))
         (hit (gowl-find-client pattern (if by-title 'title 'app-id)))
         (rec (and hit (cmacs-gowl-tools--client hit))))
    (if (and rec (equal (plist-get rec shown-key) (plist-get rec raw-key)))
        rec
      ;; No hit, a hidden hit or a renamed one: in each case the answer
      ;; is the first window whose *shown* name matches, which may be
      ;; none.  With nothing withheld this finds what gowl found.
      (cl-loop for client in (gowl-list-clients)
               for r = (cmacs-gowl-tools--client client)
               when (and r (cmacs-gowl-tools--glob-p
                            pattern (plist-get r shown-key)))
               return r))))

(defun cmacs-gowl-tools--find-or-signal (pattern by)
  "Return the gowl client for PATTERN and BY, or signal as the C did.
An excluded window and no window are the same answer."
  (let ((rec (cmacs-gowl-tools--find pattern by)))
    (unless rec
      (error "no client matching pattern"))
    (plist-get rec :client)))

(defun cmacs-gowl-tools--region-guard (x y width height)
  "Signal when the screen region X Y WIDTH HEIGHT shows a withheld window.
That is: the focused window is one the rules exclude, or an excluded
window on a tag some monitor is viewing overlaps the region.  Text read
off the screen and colours read pixel by pixel are both ways to see a
window, so neither may see one the client list would not name."
  (let ((visible-tags 0)
        (focused (gowl-focused-client))
        (refuse (lambda ()
                  (error "That part of the screen shows a window the \
redaction rules withhold"))))
    (when (and focused (null (cmacs-gowl-tools--client focused)))
      (funcall refuse))
    (dolist (monitor (gowl-list-monitors))
      (setq visible-tags
            (logior visible-tags
                    (or (alist-get 'tags (gowl-monitor-info monitor)) 0))))
    (dolist (client (gowl-list-clients))
      (let* ((raw (cmacs-gowl-tools--client-raw client))
             (g (plist-get raw :geometry))
             (cx (nth 0 g)) (cy (nth 1 g)) (cw (nth 2 g)) (ch (nth 3 g)))
        (when (and (< cx (+ x width)) (< x (+ cx cw))
                   (< cy (+ y height)) (< y (+ cy ch))
                   (or (/= 0 (logand (plist-get raw :tags) visible-tags))
                       (and (fboundp 'gowl-client-sticky-p)
                            (gowl-client-sticky-p client)))
                   (null (cmacs-gowl-tools--redact-window
                          (plist-get raw :app) (plist-get raw :title)
                          (plist-get raw :pid))))
          (funcall refuse))))))


;;;; Clients

(cmacs-brigade-deftool gowl-list-clients
  "List all Wayland clients (JSON array with id, title, app-id, tags, geometry)."
    ()
  :group 'gowl
  :returns 'json
  :example "emacsctl tool gowl list-clients"
  (cmacs-gowl-tools--running)
  (concat "["
          (mapconcat (lambda (rec) (cmacs-gowl-tools--client-json rec 'list))
                     (delq nil (mapcar #'cmacs-gowl-tools--client
                                       (gowl-list-clients)))
                     ",")
          "]"))

(cmacs-brigade-deftool gowl-focused-client
  "Get info about the currently focused Wayland client."
    ()
  :group 'gowl
  (cmacs-gowl-tools--running)
  (let* ((client (gowl-focused-client))
         (rec (and client (cmacs-gowl-tools--client client))))
    ;; "nil" is what the C printed with nothing focused, and a focused
    ;; window the caller may not see is nothing focused.
    (if rec (cmacs-gowl-tools--client-json rec 'focused) "nil")))

(cmacs-brigade-deftool gowl-find-client
  "Find a Wayland client by app-id or title pattern."
    ((pattern string "Search pattern")
     (by string "Search field (default: app-id)"
         :optional t :enum ("app-id" "title")))
  :group 'gowl
  :example "emacsctl tool gowl find-client --pattern 'librewolf*'"
  (let ((rec (cmacs-gowl-tools--find pattern by)))
    (if rec (cmacs-gowl-tools--client-json rec 'find) "nil")))

(cmacs-brigade-deftool gowl-focus-client
  "Give keyboard focus to the Wayland client matching a pattern."
    ((pattern string "Match pattern")
     (by string "Match field (default: app-id)"
         :optional t :enum ("app-id" "title")))
  :group 'gowl :destructive t
  (gowl-focus-client (cmacs-gowl-tools--find-or-signal pattern by))
  (cmacs-gowl-tools--quoted "focused"))

(cmacs-brigade-deftool gowl-close-client
  "Close the Wayland client matching a pattern."
    ((pattern string "Match pattern")
     (by string "Match field (default: app-id)"
         :optional t :enum ("app-id" "title")))
  :group 'gowl :destructive t
  (gowl-close-client (cmacs-gowl-tools--find-or-signal pattern by))
  (cmacs-gowl-tools--quoted "closed"))

(cmacs-brigade-deftool gowl-set-client-geometry
  "Move and resize the Wayland client matching a pattern in one call."
    ((pattern string "Match pattern")
     (by string "Match field (default: app-id)"
         :optional t :enum ("app-id" "title"))
     (x integer "Left edge, layout coordinates")
     (y integer "Top edge, layout coordinates")
     (width integer "Width in pixels")
     (height integer "Height in pixels"))
  :group 'gowl :destructive t
  (unless (and (integerp x) (integerp y) (integerp width) (integerp height))
    (cmacs-gowl-tools--missing "pattern, x, y, width, height"))
  (gowl-client-set-geometry (cmacs-gowl-tools--find-or-signal pattern by)
                            x y width height)
  (cmacs-gowl-tools--quoted "geometry set"))

(cmacs-brigade-deftool gowl-spawn
  "Spawn a command in the Wayland compositor."
    ((command string "Shell command to spawn"))
  :group 'gowl :destructive t
  (unless (stringp command)
    (cmacs-gowl-tools--missing "command"))
  (cmacs-gowl-tools--running)
  ;; Not a wait: `gowl-spawn' forks and returns the child's pid.
  (number-to-string (gowl-spawn command)))


;;;; Monitors, keybinds, layout, workspaces

(defun cmacs-gowl-tools--monitor-json (info)
  "Return the JSON object for a monitor from INFO, its `gowl-monitor-info'.
Key for key and digit for digit what `cmacs_dispatch_gowl_list_monitors'
printed."
  (let ((geometry (or (alist-get 'geometry info) '(0 0 0 0)))
        (mode (alist-get 'current-mode info)))
    (format "{\"name\":%s,\"mfact\":%.2f,\"nmaster\":%d,\"tags\":%d,\
\"layout\":%s,\"enabled\":%s,\"scale\":%.2f,\"transform\":%d,\
\"current_mode\":%s,\"geometry\":[%d,%d,%d,%d]}"
            (cmacs-gowl-tools--json-string (alist-get 'name info))
            (or (alist-get 'mfact info) 0.0)
            (or (alist-get 'nmaster info) 0)
            (or (alist-get 'tags info) 0)
            (cmacs-gowl-tools--json-string (alist-get 'layout-symbol info))
            (if (alist-get 'enabled info) "true" "false")
            (or (alist-get 'scale info) 0.0)
            (or (alist-get 'transform info) 0)
            (if mode
                (format "{\"width\":%d,\"height\":%d,\"refresh_mhz\":%d}"
                        (nth 0 mode) (nth 1 mode) (nth 2 mode))
              "null")
            (nth 0 geometry) (nth 1 geometry)
            (nth 2 geometry) (nth 3 geometry))))

(cmacs-brigade-deftool gowl-list-monitors
  "List monitors (JSON array with name, geometry, mode, scale, layout)."
    ()
  :group 'gowl
  :returns 'json
  :example "emacsctl tool gowl list-monitors"
  (cmacs-gowl-tools--running)
  (concat "["
          (mapconcat (lambda (monitor)
                       (cmacs-gowl-tools--monitor-json
                        (gowl-monitor-info monitor)))
                     (gowl-list-monitors) ",")
          "]"))

(cmacs-brigade-deftool gowl-set-monitor-transform
  "Set the wl_output transform for a monitor (rotation/flip). \
transform is an integer 0-7: 0=normal, 1=90, 2=180, 3=270, \
4=flipped, 5=flipped-90, 6=flipped-180, 7=flipped-270. \
To persist across sessions, add `transform:` under the \
matching output name in the YAML `monitors:` block."
    ((name string "Output name (e.g. eDP-1)")
     (transform integer "Transform code 0-7"))
  :group 'gowl :destructive t
  (unless (stringp name)
    (cmacs-gowl-tools--missing "name"))
  (unless (integerp transform)
    (cmacs-gowl-tools--missing "transform"))
  (cmacs-gowl-tools--running)
  (let ((monitor (cl-find-if
                  (lambda (m)
                    (equal (alist-get 'name (gowl-monitor-info m)) name))
                  (gowl-list-monitors))))
    ;; The C's order: the monitor first, then the range.
    (unless monitor
      (error "No monitor named \"%s\"" name))
    (unless (<= 0 transform 7)
      (error "Invalid transform %d (must be 0-7)" transform))
    (unless (gowl-set-monitor-transform transform monitor)
      (error "Failed to set transform %d on \"%s\"" transform name))
    "t"))

(cmacs-brigade-deftool gowl-list-keybinds
  "List all compositor keybinds."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--running)
  (concat
   "["
   (mapconcat
    (lambda (bind)
      (let ((action (alist-get 'action bind))
            (desc (alist-get 'desc bind)))
        (format "{\"key\":%s,\"action\":%s,\"arg\":%s,\"desc\":%s}"
                (cmacs-gowl-tools--json-string (alist-get 'key bind))
                ;; The nick when gowl knows the action, else its number.
                (if (integerp action)
                    (number-to-string action)
                  (cmacs-gowl-tools--json-string (format "%s" action)))
                (cmacs-gowl-tools--json-string (alist-get 'arg bind))
                (if desc (cmacs-gowl-tools--json-string desc) "null"))))
    (gowl-list-keybinds) ",")
   "]"))

(cmacs-brigade-deftool gowl-set-layout
  "Set the tiling layout: \"tile\", \"monocle\", or \"float\"."
    ((layout string "Layout name" :enum ("tile" "monocle" "float")))
  :group 'gowl :destructive t
  (unless (stringp layout)
    (cmacs-gowl-tools--missing "layout"))
  (cmacs-gowl-tools--running)
  ;; The C answered "layout set" whatever the DEFUN returned, so a name
  ;; gowl does not know read as success.  nil is the DEFUN saying no.
  (unless (gowl-set-layout layout)
    (error "No layout named \"%s\"" layout))
  (cmacs-gowl-tools--quoted "layout set"))

(cmacs-brigade-deftool gowl-workspace-list
  "List workspaces as plists (:id :name :tag-mask)."
    ()
  :group 'gowl
  ;; No compositor is not an error here: the DEFUN answers nil, and so
  ;; did the C.  Printed twice because the C printed twice -- its form
  ;; was `prin1-to-string' and the dispatch printed that string again.
  (cmacs-gowl-tools--quoted
   (prin1-to-string (and (fboundp 'gowl-workspace-list)
                         (gowl-workspace-list)))))

(cmacs-brigade-deftool gowl-workspace-switch
  "Switch to the workspace with the given id."
    ((id integer "Workspace id"))
  :group 'gowl :destructive t
  (unless (integerp id)
    (cmacs-gowl-tools--missing "id"))
  (cmacs-gowl-tools--running)
  (cmacs-gowl-tools--quoted
   (if (gowl-workspace-switch id)
       "switched"
     "workspace unchanged or unknown id")))


;;;; Input recording
;;
;; The observing counterpart to send_keys, behind gowl's own
;; `input-recording' consent key, which is off by default and which the
;; DEFUNs check.  None of these waits: a drain takes what the ring holds
;; now and returns.

(defun cmacs-gowl-tools--limit (value)
  "Return VALUE when it is a positive integer, else nil (the default).
There is no spelling for \"unbounded\", because there is no unbounded."
  (and (integerp value) (> value 0) value))

(cmacs-brigade-deftool gowl-start-recording
  "Record real keyboard and pointer input so a human demonstration \
can be turned into a procedure. Returns a token for \
gowl_drain_recording and gowl_stop_recording. Bounded: the ring \
holds at most max_events (older events are dropped and counted) \
and the recording stops itself after max_seconds. Requires gowl's \
`input-recording' config key, which is separate from send_keys \
and off by default. While it runs the screen is framed in red and \
Super+Shift+Escape stops it. Capture is suppressed on the lock \
screen and for windows on the deny list, but gowl CANNOT see a \
password field inside an ordinary window -- review a trace before \
storing or sharing it."
    ((max-seconds integer "Stop automatically after this many seconds \
\(default 120, maximum 3600)" :optional t)
     (max-events integer "Ring size in events (default 4096, \
maximum 100000)" :optional t))
  :group 'gowl :destructive t
  :returns 'json
  (cmacs-gowl-tools--running)
  (gowl-start-recording (cmacs-gowl-tools--limit max-seconds)
                        (cmacs-gowl-tools--limit max-events)))

(cmacs-brigade-deftool gowl-drain-recording
  "Take everything recorded since the last drain and leave the \
recording running. The reply carries dropped (since the last \
drain) and dropped_total, so a demonstration that overflowed the \
ring is reported rather than passed off as complete, plus active \
and stop_reason."
    ((token string "Token from gowl_start_recording"))
  :group 'gowl :destructive t
  :returns 'json
  (unless (stringp token)
    (cmacs-gowl-tools--missing "token"))
  (cmacs-gowl-tools--running)
  (gowl-drain-recording token))

(cmacs-brigade-deftool gowl-stop-recording
  "Stop the recording and take the tail, in the same shape \
gowl_drain_recording returns. Stopping a recording that already \
stopped itself still returns its remaining events exactly once."
    ((token string "Token from gowl_start_recording"))
  :group 'gowl :destructive t
  :returns 'json
  ;; The DEFUN with no token stops whatever is running and keeps the
  ;; events; that is the person's way out, not an agent's, so a token is
  ;; required here as it was in C.
  (unless (and (stringp token) (not (string-empty-p token)))
    (cmacs-gowl-tools--missing "token"))
  (cmacs-gowl-tools--running)
  (gowl-stop-recording token))

(cmacs-brigade-deftool gowl-recording-status
  "Whether an input recording is running, its token, limits and \
counters, without consuming anything. Poll this to notice that a \
recording started, stopped, or was stopped from the keyboard."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--running)
  (gowl-recording-status))


;;;; Macros
;;
;; Each is one call into cmacs-gowl-macro.el, which loads the opt-in
;; module and signals with the module's own explanation.

(defun cmacs-gowl-tools--macro (line)
  "Run the macro module command LINE; return its reply as the C did."
  (require 'cmacs-gowl-macro)
  (cmacs-gowl-tools--raw (cmacs-gowl-macro-command line)))

(cmacs-brigade-deftool gowl-macro-run
  "Run a gowl macro: in-process C (crispy) or an Elisp macro that \
drives the compositor. Runs under gowl's fault guard and time \
budget; a crash or runaway loop is stopped and held back. \
Loads the opt-in macro module on first use."
    ((name string "A macro name (a file on the macro path, a registered \
or an Elisp macro), or a path to a .c file")
     (args array "Arguments handed to the macro, in order"
           :optional t :items string))
  ;; Destructive, and in the allowlist's privileged set by name: a macro
  ;; is arbitrary code in the compositor.
  :group 'gowl :destructive t
  (unless (and (stringp name) (not (string-empty-p name)))
    (cmacs-gowl-tools--missing "name"))
  ;; The module splits its line with g_shell_parse_argv; every word is
  ;; quoted the way the C quoted it, so a name or an argument with a
  ;; space, a quote or a `;' in it is one word and nothing more.
  (cmacs-gowl-tools--macro
   (mapconcat #'identity
              (append (list "macro-run --trigger=api --"
                            (cmacs-gowl-tools--shell-quote name))
                      (mapcar #'cmacs-gowl-tools--shell-quote args))
              " ")))

(cmacs-brigade-deftool gowl-macro-list
  "Every macro runnable by name, as JSON: name, kind (file, \
registered, custom = Elisp, ...), path, held-back."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--macro "macro-list"))

(cmacs-brigade-deftool gowl-macro-status
  "Running macros, held-back ones and why, the fault count, the \
time budget, triggers -- the macro module's status JSON."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--macro "macro-status"))

(cmacs-brigade-deftool gowl-macro-stop
  "Stop running macros."
    ((which string "A macro name, a run id or all (the default)"
            :optional t))
  :group 'gowl :destructive t
  (cmacs-gowl-tools--macro
   (if (and which (not (string-empty-p which)))
       (concat "macro-stop " (cmacs-gowl-tools--shell-quote which))
     "macro-stop")))

(cmacs-brigade-deftool gowl-macro-record
  "The macro recorder (Super+Alt+r). start records the person's \
keys, clicks, drags and scrolls; stop writes last-recording.c \
\(and NAME.c) and replies `recorded NAME STEPS PATH'; cancel \
discards; status reports. Starting from here needs gowl's \
`input-recording' consent, because it watches the person's \
input; the screen is framed while it runs and password prompts \
are not recorded."
    ((action string "start, stop, cancel or status"
             :enum ("start" "stop" "cancel" "status"))
     (name string "With start: also write NAME.c" :optional t))
  :group 'gowl :destructive t
  (require 'cmacs-gowl-macro)
  ;; FOR-AGENT is always t: the record key needs no consent because the
  ;; person pressed it; a program asking is a different thing.
  (cmacs-gowl-tools--raw
   (cmacs-gowl-macro-record-command (or action "status") name t)))

(cmacs-brigade-deftool gowl-macro-voice-match
  "Run the macro a sentence names, as Super+Alt+m does with what \
was said: a configured phrase, a macro's name said as words \
\(\"pip corner 25\" runs pip-corner 25), or every word of a name. \
dry_run reports what it would run (heard, normalised, macro, \
args) and runs nothing."
    ((text string "The sentence")
     (dry-run boolean "Report what would run, and run nothing"
              :optional t))
  :group 'gowl :destructive t
  (unless (and (stringp text) (not (string-empty-p text)))
    (cmacs-gowl-tools--missing "text"))
  (require 'cmacs-gowl-macro)
  (cmacs-gowl-tools--raw (cmacs-gowl-macro-voice-text text dry-run)))

(cmacs-brigade-deftool gowl-macro-voice-status
  "The voice listener's state: listening, command, time limit, last \
sentence heard, last error. There is no tool to start \
listening: the microphone is the person's to turn on."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--macro "macro-voice status"))


;;;; Module command lines (broadcast, hotkey)
;;
;; `cmacs-gowl-broadcast-command' and `cmacs-gowl-hotkey-command' load
;; their opt-in module and never signal: a failure is text beginning
;; "ERROR".  The C turned that into an MCP error with the prefix cut off;
;; here it is signalled with the same text.

(defun cmacs-gowl-tools--module-line (feature function line)
  "Load FEATURE, call FUNCTION with LINE, and return its reply.
A reply beginning \"ERROR\" is signalled without the prefix."
  (require feature)
  (let ((reply (funcall function line)))
    (cond ((not (stringp reply)) (prin1-to-string reply))
          ((string-prefix-p "ERROR" reply)
           (error "%s" (substring reply
                                  (if (and (> (length reply) 5)
                                           (eq (aref reply 5) ?\s))
                                      6
                                    5))))
          (t reply))))

(defun cmacs-gowl-tools--redact-json-windows (text)
  "Return TEXT, a module's JSON reply, with the windows in it redacted.
A window is an object with both `app_id' and `title' -- how the modules
write one.  One the rules exclude becomes null (an empty slot); one they
rewrite carries the rewritten names.  TEXT comes back untouched, byte
for byte, when nothing in it changes or it is not JSON at all."
  (if (not (string-match-p "\\`[ \t\n]*[[{]" text))
      text
    (let ((changed nil))
      (cl-labels
          ((walk (value)
             (cond
              ((vectorp value) (vconcat (mapcar #'walk value)))
              ((and (consp value) (assq 'app_id value) (assq 'title value))
               (let* ((app (alist-get 'app_id value))
                      (title (alist-get 'title value))
                      (shown (cmacs-gowl-tools--redact-window
                              (and (stringp app) app)
                              (and (stringp title) title)
                              nil)))
                 (cond ((null shown) (setq changed t) :null)
                       ((and (equal (car shown) app)
                             (equal (cdr shown) title))
                        value)
                       (t (setq changed t)
                          (mapcar (lambda (cell)
                                    (pcase (car cell)
                                      ('app_id
                                       (cons 'app_id (or (car shown) "")))
                                      ('title
                                       (cons 'title (or (cdr shown) "")))
                                      (_ cell)))
                                  value)))))
              ((consp value)
               (mapcar (lambda (cell) (cons (car cell) (walk (cdr cell))))
                       value))
              (t value))))
        (let ((parsed (condition-case nil
                          (list (json-parse-string text :object-type 'alist))
                        (error nil))))
          (if (null parsed)
              ;; It looked like JSON and did not parse, so nothing in it
              ;; could be judged window by window.
              (cmacs-gowl-tools--redact-text text)
            (let ((walked (walk (car parsed))))
              (if changed
                  (decode-coding-string (json-serialize walked) 'utf-8 t)
                text))))))))

(defun cmacs-gowl-tools--broadcast (line)
  "Run the broadcast module command LINE; return its reply, redacted."
  (cmacs-gowl-tools--redact-json-windows
   (cmacs-gowl-tools--module-line 'cmacs-gowl-broadcast
                                  #'cmacs-gowl-broadcast-command line)))

(defun cmacs-gowl-tools--hotkey (line)
  "Run the hotkey module command LINE; return its reply."
  (cmacs-gowl-tools--module-line 'cmacs-gowl-hotkey
                                 #'cmacs-gowl-hotkey-command line))


;;;; Input broadcasting (multiboxing)

(cmacs-brigade-deftool gowl-broadcast-status
  "Input broadcasting (multiboxing): whether it is on, strict mode, \
the toggle and panic keys, every team with the window in each \
slot, every rule with the reason it cannot run if any, and \
delivery counters (JSON). The module is opt-in."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--broadcast "broadcast-status"))

(cmacs-brigade-deftool gowl-broadcast-list
  "The broadcast teams and rules in force, each as YAML (JSON)."
    ()
  :group 'gowl
  :returns 'json
  (cmacs-gowl-tools--broadcast "broadcast-list"))

(cmacs-brigade-deftool gowl-broadcast-set
  "Switch input broadcasting on, off or toggle it (a toast shows the \
result), or panic: off, and every key held in any window \
released. Or set strict one-press-one-window mode instead."
    ((state string "on, off, toggle or panic"
            :optional t :enum ("on" "off" "toggle" "panic"))
     (strict string "on, off or toggle"
             :optional t :enum ("on" "off" "toggle")))
  :group 'gowl :destructive t
  (cond
   (strict
    (unless (member strict '("on" "off" "toggle"))
      (cmacs-gowl-tools--missing "strict (on, off or toggle)"))
    (cmacs-gowl-tools--broadcast (concat "broadcast-strict " strict)))
   (t
    (unless (member state '("on" "off" "toggle" "panic"))
      (cmacs-gowl-tools--missing "state (on, off, toggle or panic)"))
    (cmacs-gowl-tools--broadcast (concat "broadcast-" state)))))

(defun cmacs-gowl-tools--definition (object yaml what one-line-p)
  "Return the text of a module definition given as OBJECT or as YAML.
OBJECT is the alist an `object' parameter delivers and wins when given;
it is written back out as JSON, which is flow YAML.  Otherwise YAML has
to pass ONE-LINE-P, because the module's command is a line.  WHAT names
the missing argument, in the C handler's words."
  (cond
   (object (cmacs-brigade-structured-json object '(:type "object")))
   ((funcall one-line-p yaml) yaml)
   (t (cmacs-gowl-tools--missing what))))

(defun cmacs-gowl-tools--yaml-line-p (text)
  "Non-nil when TEXT is present and has no newline.
The broadcast handlers' own check, which unlike
`cmacs-gowl-tools--one-line-p' lets a carriage return through."
  (and (stringp text) (not (string-empty-p text))
       (not (string-search "\n" text))))

(cmacs-brigade-deftool gowl-broadcast-add-team
  "Add, or replace by name, a broadcast team for this session."
    ((team object "{name, slots: [{name, match, focus-key, delivery}], \
groups: {NAME: [slot]}}; match is a filter such as app-id = eqgame.exe"
           :optional t)
     (yaml string "The same as one line of flow YAML" :optional t))
  :group 'gowl :destructive t
  (cmacs-gowl-tools--broadcast
   (concat "broadcast-add-team "
           (cmacs-gowl-tools--definition
            team yaml "an object, or yaml (one line of flow YAML)"
            #'cmacs-gowl-tools--yaml-line-p))))

(cmacs-brigade-deftool gowl-broadcast-add-rule
  "Add, or replace by name, a broadcast rule for this session; the \
reply says when it cannot run."
    ((rule object "{name, team, when, keys: {include, exclude}, \
modifiers, targets, translate, mode, reset-ms, delivery, mouse, \
delay-ms, local}" :optional t)
     (yaml string "The same as one line of flow YAML" :optional t))
  :group 'gowl :destructive t
  (cmacs-gowl-tools--broadcast
   (concat "broadcast-add-rule "
           (cmacs-gowl-tools--definition
            rule yaml "an object, or yaml (one line of flow YAML)"
            #'cmacs-gowl-tools--yaml-line-p))))

(cmacs-brigade-deftool gowl-broadcast-remove
  "Remove a broadcast team or rule."
    ((kind string "team or rule" :enum ("team" "rule"))
     (name string "The team's or rule's name"))
  :group 'gowl :destructive t
  (unless (member kind '("team" "rule"))
    (cmacs-gowl-tools--missing "kind (team or rule)"))
  (unless (cmacs-gowl-tools--word-p name)
    (cmacs-gowl-tools--missing "name"))
  (cmacs-gowl-tools--broadcast (format "broadcast-remove-%s %s" kind name)))

(cmacs-brigade-deftool gowl-broadcast-assign
  "Put a window in a broadcast team's slot by hand."
    ((team string "The team")
     (slot string "The slot")
     (client-id integer "The window (default: the focused one); 0 hands \
the slot back to its match" :optional t))
  :group 'gowl :destructive t
  (unless (and (cmacs-gowl-tools--word-p team)
               (cmacs-gowl-tools--word-p slot))
    (cmacs-gowl-tools--missing "team and slot"))
  (let ((id (if (integerp client-id) client-id -1)))
    (cond
     ((= id 0)
      (cmacs-gowl-tools--broadcast
       (format "broadcast-unassign %s %s" team slot)))
     (t
      ;; A window named by id, or the focused one: either way one the
      ;; caller must have been able to list.  The messages are the
      ;; module's own for "no such window", so an id cannot be probed.
      (cmacs-gowl-tools--running)
      (if (> id 0)
          (let ((client (cl-find-if
                         (lambda (c)
                           (eql (alist-get 'id (gowl-client-info c)) id))
                         (gowl-list-clients))))
            (when (and client (null (cmacs-gowl-tools--client client)))
              (error "Broadcast: no window with id %d" id))
            (cmacs-gowl-tools--broadcast
             (format "broadcast-assign %s %s %d" team slot id)))
        (let ((focused (gowl-focused-client)))
          (when (and focused (null (cmacs-gowl-tools--client focused)))
            (error "Broadcast: no window has focus; give an id"))
          (cmacs-gowl-tools--broadcast
           (format "broadcast-assign %s %s" team slot))))))))

(cmacs-brigade-deftool gowl-broadcast-focus-slot
  "Focus the window in a broadcast team's slot, viewing its tag."
    ((team string "The team (default: the only one)" :optional t)
     (slot string "The slot"))
  :group 'gowl :destructive t
  (unless (cmacs-gowl-tools--word-p slot)
    (cmacs-gowl-tools--missing "slot"))
  (when (and team (not (cmacs-gowl-tools--word-p team)))
    (cmacs-gowl-tools--missing "team (one word)"))
  (cmacs-gowl-tools--broadcast
   (if team
       (format "broadcast-focus-slot %s %s" team slot)
     (format "broadcast-focus-slot %s" slot))))


;;;; Hotkeys (AutoHotkey for gowl)
;;
;; `gowl_hotkey_send' (keys typed into the focused window: the
;; privileged set) stays in C.

(cmacs-brigade-deftool gowl-hotkey-add
  "Add a hotkey (or a section of them) for this session; refused \
whole, with the reason, on any problem."
    ((hotkey object "A hotkey entry {id, key, do, context, when, mode, \
double, hold, ...} -- key in AutoHotkey notation (#!t, CapsLock & j, \
~LButton) or gowl's (Super+Alt+t); do is a list of actions such as \
{shell: CMD}, {send: KEYS}, {action: spawn, arg: PROGRAM} -- or a whole \
section {hotkeys: [...], remaps: {...}, modes: {...}}" :optional t)
     (yaml string "The same as one line of flow YAML" :optional t)
     (id string "Name it, so adding again replaces it and \
gowl_hotkey_remove takes it back" :optional t))
  :group 'gowl :destructive t
  (let ((text (cmacs-gowl-tools--definition
               hotkey yaml
               "a hotkey object, or yaml (one line of flow YAML)"
               #'cmacs-gowl-tools--one-line-p)))
    (when (and id (not (cmacs-gowl-tools--word-p id)))
      (cmacs-gowl-tools--missing "id (one word)"))
    (cmacs-gowl-tools--hotkey
     (if id
         (format "hotkey-add --id=%s %s" id text)
       (concat "hotkey-add " text)))))

(cmacs-brigade-deftool gowl-hotkey-status
  "Hotkeys (AutoHotkey for gowl): whether they are suspended, the \
key mode, counts of hotkeys, remaps, timers and hotstrings, the \
lock keys, the last hotkey fired and the last error (JSON). The \
module is opt-in; this loads it."
    ()
  :group 'gowl
  (cmacs-gowl-tools--hotkey "hotkey-status"))

(cmacs-brigade-deftool gowl-hotkey-list
  "Every hotkey and remap in force (JSON): id, key as written and \
canonical, context, mode, enabled, origin, description."
    ()
  :group 'gowl
  (cmacs-gowl-tools--hotkey "hotkey-list"))

(cmacs-brigade-deftool gowl-hotkey-history
  "The last 64 inputs the hotkey module saw (JSON): keycode, keysym, \
pressed, injected, swallowed and the hotkey each fired. The \
first thing to look at when a hotkey does not fire."
    ()
  :group 'gowl
  (cmacs-gowl-tools--hotkey "hotkey-history"))

(cmacs-brigade-deftool gowl-hotkey-remove
  "Remove a hotkey added at run time (one from the configuration is \
disabled instead)."
    ((id string "The hotkey's id"))
  :group 'gowl :destructive t
  (unless (cmacs-gowl-tools--word-p id)
    (cmacs-gowl-tools--missing "id"))
  (cmacs-gowl-tools--hotkey (concat "hotkey-remove " id)))

(cmacs-brigade-deftool gowl-hotkey-set
  "Switch one hotkey on or off (id + enabled), suspend every hotkey, \
or enter a key mode."
    ((id string "The hotkey, with enabled" :optional t)
     (enabled string "on, off or toggle"
              :optional t :enum ("on" "off" "toggle"))
     (suspended string "on, off or toggle"
                :optional t :enum ("on" "off" "toggle"))
     (mode string "A key mode; default leaves every mode" :optional t))
  :group 'gowl :destructive t
  ;; One of three things, looked for in the C's order.
  (cmacs-gowl-tools--hotkey
   (cond
    (enabled
     (unless (member enabled '("on" "off" "toggle"))
       (cmacs-gowl-tools--missing "enabled (on, off or toggle)"))
     (unless (cmacs-gowl-tools--word-p id)
       (cmacs-gowl-tools--missing "id, with enabled"))
     (format "hotkey-%s %s"
             (pcase enabled ("on" "enable") ("off" "disable") (_ "toggle"))
             id))
    (suspended
     (unless (member suspended '("on" "off" "toggle"))
       (cmacs-gowl-tools--missing "suspended (on, off or toggle)"))
     (concat "hotkey-suspend " suspended))
    (mode
     (unless (cmacs-gowl-tools--word-p mode)
       (cmacs-gowl-tools--missing "mode (one word)"))
     (concat "hotkey-mode " mode))
    (t (cmacs-gowl-tools--missing "enabled (with id), suspended or mode")))))

(cmacs-brigade-deftool gowl-hotkey-fire
  "Run a hotkey's actions as if it had been pressed."
    ((id string "The hotkey's id"))
  :group 'gowl :destructive t
  (unless (cmacs-gowl-tools--word-p id)
    (cmacs-gowl-tools--missing "id"))
  (cmacs-gowl-tools--hotkey (concat "hotkey-fire " id)))


;;;; The screen

(defun cmacs-gowl-tools--ocr-result (text copy)
  "Return the tool's answer for TEXT, what the OCR program printed.
Trimmed as `cmacs-gowl-screen-text' trims, then through the free-text
rules.  With COPY non-nil the answer also goes on the clipboard -- the
answer, not the raw text: the clipboard history is one tool call away."
  (let* ((text (string-trim (subst-char-in-string ?\f ?\n text)))
         (shown (cmacs-gowl-tools--redact-text text)))
    (when (and copy (not (string-empty-p shown)))
      (gowl-clipboard-set shown))
    shown))

(defun cmacs-gowl-tools--screen-text (done x y width height language copy)
  "Read the text in a screen region and hand it to DONE.
X, Y, WIDTH, HEIGHT, LANGUAGE and COPY are `cmacs-gowl-screen-text's.
The capture is done now; the OCR program runs as an asynchronous
process, and DONE is called from its sentinel -- with the text, or with
\"Error: ...\", the registry's spelling of a failure that happens after
the handler has returned.  Anything wrong before the process starts is
signalled."
  (cmacs-gowl-tools--running)
  (unless (and (natnump x) (natnump y)
               (integerp width) (integerp height)
               (> width 0) (> height 0))
    (error "X and Y must be at least 0, WIDTH and HEIGHT positive"))
  (cmacs-gowl-tools--region-guard x y width height)
  (require 'cmacs-gowl-grab)
  (let* ((cfg (cmacs-gowl-grab--ocr-config))
         (shot (or (gowl-screenshot-region x y width height)
                   (error "Nothing captured at %d,%d %dx%d"
                          x y width height)))
         (dir (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
         (png (make-temp-file (expand-file-name "cmacs-ocr-" dir)
                              nil ".png"))
         (argv (append (split-string-and-unquote (car cfg))
                       (list png "stdout" "-l"
                             (if (and language (not (string-empty-p language)))
                                 language
                               (cdr cfg)))))
         (command (if (executable-find "timeout")
                      (append (list "timeout"
                                    (number-to-string
                                     cmacs-gowl-grab-ocr-timeout))
                              argv)
                    argv))
         (out (generate-new-buffer " *cmacs-gowl-ocr*" t))
         (err (generate-new-buffer " *cmacs-gowl-ocr-stderr*" t))
         (cleanup (lambda ()
                    (ignore-errors (delete-file png))
                    (dolist (buffer (list out err))
                      (when (buffer-live-p buffer)
                        (let ((kill-buffer-query-functions nil))
                          (kill-buffer buffer))))))
         (started nil))
    (unwind-protect
        (let ((default-directory (file-name-as-directory dir)))
          (set-file-modes png #o600)
          (apply #'gowl-screenshot-save-png (append shot (list png)))
          (condition-case failure
              (make-process
               :name "cmacs-gowl-ocr"
               :buffer out :stderr err
               :command command
               :connection-type 'pipe
               :coding 'utf-8
               :noquery t
               :sentinel
               (lambda (process _event)
                 (when (memq (process-status process) '(exit signal))
                   (let ((ok (and (eq (process-status process) 'exit)
                                  (eql (process-exit-status process) 0)))
                         (status (process-exit-status process))
                         (text (if (buffer-live-p out)
                                   (with-current-buffer out (buffer-string))
                                 "")))
                     (funcall cleanup)
                     (funcall
                      done
                      (condition-case failure
                          (if ok
                              (cmacs-gowl-tools--ocr-result text copy)
                            (format "Error: OCR failed (%s exited %s)"
                                    (car argv) status))
                        (error (format "Error: %s"
                                       (error-message-string failure)))))))))
            (file-missing
             (error "%s -- is tesseract installed? (Fedora: \
tesseract, tesseract-langpack-eng)" (error-message-string failure))))
          (let ((stderr-process (get-buffer-process err)))
            (when stderr-process
              (set-process-query-on-exit-flag stderr-process nil)))
          (setq started t))
      (unless started
        (funcall cleanup)))))

(cmacs-brigade-deftool gowl-screen-text
  "Read the text in a region of the screen (OCR via tesseract, the \
screenshot module's ocr-command), in layout coordinates as \
gowl_list_monitors and gowl_list_clients report them. Returns \
the text, \"\" when there is none. The clipboard is left alone \
unless copy is true."
    ((x integer "Left edge, layout coordinates")
     (y integer "Top edge, layout coordinates")
     (width integer "Width of the region")
     (height integer "Height of the region")
     (language string "tesseract languages, e.g. eng+deu (default: \
the screenshot module's)" :optional t)
     (copy boolean "Also put the text on the clipboard (default false)"
           :optional t))
  :group 'gowl :destructive t
  :async t :timeout 90
  (unless (and (integerp x) (integerp y) (integerp width) (integerp height))
    (cmacs-gowl-tools--missing "x, y, width, height"))
  (cmacs-gowl-tools--screen-text done x y width height language copy))

(cmacs-brigade-deftool gowl-pick-color
  "The colour of the screen at layout x, y, as \"#rrggbb\". The \
clipboard is left alone."
    ((x integer "Layout x")
     (y integer "Layout y"))
  :group 'gowl
  (unless (and (integerp x) (integerp y))
    (cmacs-gowl-tools--missing "x, y"))
  (cmacs-gowl-tools--running)
  ;; One pixel of one capture: nothing here waits.  Guarded like the
  ;; text, because a window can be read back a pixel at a time.
  (cmacs-gowl-tools--region-guard x y 1 1)
  (require 'cmacs-gowl-grab)
  (cmacs-gowl-tools--raw (cmacs-gowl-pixel-color x y)))


;;;; The clipboard history

(defun cmacs-gowl-tools--clipboard (line)
  "Run the clipboard module command LINE through `cmacs-gowl-command'."
  (require 'cmacs-gowl-grab)
  (cmacs-gowl-tools--raw (cmacs-gowl-command line)))

(defun cmacs-gowl-tools--clipboard-line (line)
  "Return LINE of the history index with its preview redacted.
A line is ID<TAB>MIME<TAB>BYTES<TAB>PREVIEW; only the preview is text
the person copied."
  (let ((fields (split-string line "\t")))
    (if (< (length fields) 4)
        line
      (mapconcat #'identity
                 (append (cl-subseq fields 0 3)
                         (list (cmacs-gowl-tools--redact-text
                                (mapconcat #'identity (nthcdr 3 fields)
                                           "\t"))))
                 "\t"))))

(defun cmacs-gowl-tools--clipboard-id (id)
  "Return ID when it is a positive entry id, else signal as the C did."
  (unless (and (integerp id) (> id 0))
    (cmacs-gowl-tools--missing "id (a positive entry id)"))
  id)

(defconst cmacs-gowl-tools--clipboard-check-bytes (* 1024 1024)
  "How much of a stored clipboard entry is read to decide on its path.")

(defun cmacs-gowl-tools--clipboard-withheld-p (id path)
  "Non-nil when history entry ID, stored at PATH, must not be handed out.
`gowl_clipboard_entry' answers with a path, and whoever holds the path
reads the bytes exactly as copied, past every rule.  So the path is
given only for an entry the rules would have shown unchanged: its index
preview survives them, and so does its text (the first megabyte; an
image or other media entry has no text to judge and stands on its
preview)."
  (let* ((index (cmacs-gowl-tools--clipboard "clipboard-list"))
         (prefix (format "%d\t" id))
         (line (cl-find-if (lambda (l) (string-prefix-p prefix l))
                           (split-string index "\n" t)))
         (mime (and line (nth 1 (split-string line "\t")))))
    (or (and line
             (not (equal (cmacs-gowl-tools--clipboard-line line) line)))
        (and (not (and mime (string-match-p "\\`\\(?:image\\|audio\\|video\\)/"
                                            mime)))
             (file-readable-p path)
             (let ((text (with-temp-buffer
                           (insert-file-contents
                            path nil 0
                            cmacs-gowl-tools--clipboard-check-bytes)
                           (buffer-string))))
               (not (equal (cmacs-gowl-tools--redact-text text) text)))))))

(cmacs-brigade-deftool gowl-clipboard-list
  "The clipboard history, newest first: one line per entry, \
ID<TAB>MIME<TAB>BYTES<TAB>PREVIEW. This is everything the person \
copied -- passwords included -- so read it when the task needs \
it, not by habit. The Super+space menu keeps it private for the \
same reason."
    ()
  :group 'gowl
  (mapconcat #'cmacs-gowl-tools--clipboard-line
             (split-string (cmacs-gowl-tools--clipboard "clipboard-list")
                           "\n")
             "\n"))

(cmacs-brigade-deftool gowl-clipboard-entry
  "The path of one history entry's stored bytes (exactly what was \
copied, in its MIME type)."
    ((id integer "The entry's id, from gowl_clipboard_list"))
  :group 'gowl
  (let* ((id (cmacs-gowl-tools--clipboard-id id))
         (reply (cmacs-gowl-tools--clipboard
                 (format "clipboard-path %d" id))))
    (when (cmacs-gowl-tools--clipboard-withheld-p id (string-trim reply))
      (error "Clipboard entry %d is withheld by the redaction rules" id))
    reply))

(cmacs-brigade-deftool gowl-clipboard-copy
  "Put a history entry back on the clipboard: the next paste in any \
window produces it. Replaces what the person has copied."
    ((id integer "The entry's id, from gowl_clipboard_list"))
  :group 'gowl :destructive t
  (cmacs-gowl-tools--clipboard
   (format "clipboard-copy %d" (cmacs-gowl-tools--clipboard-id id))))

;;;; Reloading the configuration
;;
;; The C handler did two things in one critical section: it reloaded the
;; compositor's config from gowl's SEARCH PATH
;; (gowl_config_load_yaml_from_search_path: ./data/config.yaml, the XDG
;; config directory, then gowl's compiled-in sysconfdir and datadir, and
;; the rules.d beside whichever was found) and re-applied the per-output
;; overrides to the live monitors.  `gowl-reload-config' the DEFUN does
;; neither: it loads one named file, or resets to defaults, and its
;; docstring says it never searches.  The search path cannot be rebuilt
;; here either -- two of its four directories are constants compiled
;; into libgowl.
;;
;; So this tool exists only in a build that has the DEFUN that does what
;; the C did, `gowl-reload-config-from-search-path'.  The C handler is
;; deleted, so in a build without that DEFUN nothing is registered under
;; the name and nothing serves it.

(declare-function gowl-reload-config-from-search-path "cmacs-gowl.c" ())

(when (fboundp 'gowl-reload-config-from-search-path)
  (cmacs-brigade-deftool gowl-reload-config
    "Reload the gowl compositor configuration from YAML."
      ()
    :group 'gowl :destructive t
    (cmacs-gowl-tools--running)
    (gowl-reload-config-from-search-path)
    ;; `cmacs_dispatch_gowl_reload_config' answered the literal t.
    "t"))

(provide 'cmacs-gowl-tools)

;;; cmacs-gowl-tools.el ends here
