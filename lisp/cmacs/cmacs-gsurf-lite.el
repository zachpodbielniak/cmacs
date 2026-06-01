;;; cmacs-gsurf-lite.el --- eww-style text rendering via offscreen gsurf -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "gsurf-lite": render a page with gsurf/WebKit *offscreen* (its
;; JavaScript runs, and logins/sessions persist in WebKit's shared
;; cookie context), then dump the post-JS DOM into a real Emacs text
;; buffer rendered with `shr' -- like eww, but the HTML is WebKit's live
;; `document.documentElement.outerHTML' instead of a raw `url-retrieve'
;; fetch.  The result is a normal, fully navigable, copy/search/yank-able
;; Emacs buffer that works on JS-only / SPA sites and stays logged in.
;;
;; Architecture: a hidden `GsurfView' is attached to the lite buffer but
;; never placed into a frame (so it is offscreen).  On each load-finish
;; we inject an extraction script via `cmacs-gsurf-run-javascript-async'
;; (the result return channel) and render the returned HTML with shr.
;; Link clicks navigate the hidden view (NOT url.el), and the next
;; load-finish re-extracts and re-renders.  This is the same Emacs-side
;; "inject JS, read it back" model the live caret mode uses.
;;
;; Forms / logins WORK two ways, your pick:
;;   1. INLINE: just type into a text field (or password / textarea) like
;;      any editable buffer -- characters self-insert in place, DEL erases,
;;      passwords echo as bullets.  Edits are pushed to the LIVE DOM on a
;;      short idle debounce (and immediately before any submit/click).
;;   2. MINIBUFFER: RET on a field reads the value in the minibuffer
;;      (passwords without echo) and pushes it -- handy on small fields.
;; Either way the value goes into the LIVE DOM via the native value setter
;; + input/change events (React-safe).  RET on a submit button clicks the
;; real control.  Because the real DOM submits, cookies / CSRF tokens /
;; hidden fields / the session all ride along -- so a real login posts
;; exactly what a browser would.  TAB / S-TAB move between fields and
;; links; C-c C-c submits the form.

;;; Code:

(require 'cmacs-gsurf)
(require 'shr)
(require 'dom)
(require 'cl-lib)

(defgroup cmacs-gsurf-lite nil
  "eww-style text rendering powered by an offscreen gsurf view."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-lite-")

(defcustom cmacs-gsurf-lite-extract-settle 0.4
  "Seconds to wait after a JS/SPA click before re-extracting the DOM.
pushState single-page navigations fire no load event, so a click that
does not trigger a real load is followed by a timed re-extract."
  :type 'number
  :group 'cmacs-gsurf-lite)

(defcustom cmacs-gsurf-lite-shr-width nil
  "Override `shr' fill width for lite buffers (nil = use the window width)."
  :type '(choice (const :tag "Window width" nil) integer)
  :group 'cmacs-gsurf-lite)

(defcustom cmacs-gsurf-lite-action-watch-times '(0.3 0.8 1.6 3.0 4.5 6.5)
  "Delays (seconds) after a click/submit at which to re-extract the DOM.
A login button often kicks off work that lands later than one settle:
a `fetch'-then-update, a client-side (`pushState'/hash) route change, or
a redirect that completes after a server round-trip.  Such navigations
may fire no load event (so `cmacs-gsurf-lite--on-load-changed' never
runs) or fire it later than `cmacs-gsurf-lite-extract-settle', so after a
click we re-render at each of these delays to follow the page where it
goes.  Re-extracts are idempotent and skipped while you are typing
inline; raise the tail for very slow sign-in flows."
  :type '(repeat number)
  :group 'cmacs-gsurf-lite)

(defvar cmacs-gsurf-lite--buffers nil
  "List of live gsurf-lite buffers, most recent first (for MCP targeting).")

(defvar-local cmacs-gsurf-lite--base-url nil
  "Current absolute URL of the page rendered in this lite buffer.")

(declare-function cmacs-gsurf-run-javascript-async "cmacs-gsurf-defuns.c"
                  (buffer script callback))
(declare-function cmacs-gsurf-attach "cmacs-gsurf-defuns.c"
                  (buffer &optional offscreen))

;;;; Extraction JavaScript
;;
;; Stamp a stable `data-cmlite-id' on links/buttons/inputs so Emacs can
;; later click-by-selector (for SPA/onclick links and, in Phase 2, push
;; form values), then return the post-JS HTML as a string.

(defconst cmacs-gsurf-lite--extract-js
  "(function(){
  try{
    var n=0;
    document.querySelectorAll('a,button,[role=button],input[type=submit],input[type=button],[onclick]')
      .forEach(function(el){ if(!el.hasAttribute('data-cmlite-id')) el.setAttribute('data-cmlite-id','cml'+(n++)); });
    document.querySelectorAll('input,textarea,select').forEach(function(el){
      if(!el.hasAttribute('data-cmlite-id')) el.setAttribute('data-cmlite-id','cml'+(n++)); });
    /* Reflect LIVE form state into attributes so the extracted outerHTML
       shows what the user has entered (the value PROPERTY is not in
       outerHTML otherwise).  Passwords are masked -- their value is never
       written into the HTML; only a filled/empty marker. */
    document.querySelectorAll('input').forEach(function(el){ try{
      var t=(el.type||'').toLowerCase();
      if(t==='checkbox'||t==='radio'){ if(el.checked) el.setAttribute('checked',''); else el.removeAttribute('checked'); }
      else if(t==='password'){ el.removeAttribute('value'); el.setAttribute('data-cmlite-filled', (el.value&&el.value.length>0)?'1':'0'); }
      else if(t!=='hidden'){ el.setAttribute('value', el.value); }
    }catch(_e){} });
    document.querySelectorAll('textarea').forEach(function(el){ try{ el.textContent=el.value; }catch(_e){} });
    document.querySelectorAll('select').forEach(function(el){ try{
      Array.prototype.forEach.call(el.options,function(o){ if(o.selected) o.setAttribute('selected',''); else o.removeAttribute('selected'); });
    }catch(_e){} });
    return document.documentElement.outerHTML;
  }catch(e){ return '<html><body>gsurf-lite extract error: '+e+'</body></html>'; }
})();"
  "JavaScript that tags interactive elements, syncs live form state into
attributes (passwords masked), and returns the post-JS page HTML.")

;;;; shr rendering

(defvar cmacs-gsurf-lite-link-keymap
  (let ((m (make-sparse-keymap)))
    ;; Inherit shr's link keys (image probe, copy-url, etc.) but override
    ;; every URL-FOLLOWING key so links open in the hidden view in place
    ;; instead of shr's `shr-browse-url', which dispatches through
    ;; `browse-url' to the user's configured browser (e.g. eww).
    (set-keymap-parent m shr-map)
    (define-key m (kbd "RET")       #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-1]         #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-2]         #'cmacs-gsurf-lite-follow)
    (define-key m "v"               #'cmacs-gsurf-lite-follow)
    (define-key m (kbd "TAB")       #'cmacs-gsurf-lite-next-field)
    (define-key m (kbd "<backtab>") #'cmacs-gsurf-lite-prev-field)
    m)
  "Keymap placed on rendered links in a gsurf-lite buffer.
Overrides shr's URL-following keys so activating a link navigates the
hidden gsurf view in place rather than handing the URL to `browse-url'
(which would open it in eww or whatever external browser is set).")

(defun cmacs-gsurf-lite--tag-a (dom)
  "Render an <a> via shr, then route its keys to `cmacs-gsurf-lite-follow'.
Shr leaves its own `shr-map' keymap on the link text (RET / mouse-2 ->
`shr-browse-url' -> the external browser); we override that with
`cmacs-gsurf-lite-link-keymap' so links open in the hidden view, and
carry the `data-cmlite-id' for SPA/onclick links."
  (let ((start (point))
        (cmid (dom-attr dom 'data-cmlite-id)))
    (shr-tag-a dom)
    (when (> (point) start)
      (put-text-property start (point) 'keymap cmacs-gsurf-lite-link-keymap)
      (when cmid
        (put-text-property start (point) 'cmacs-gsurf-lite-id cmid)))))

;;;; Form fields (real fill + submit through the live DOM)
;;
;; Form controls render as editable items.  Activating one (RET / mouse)
;; reads a value (a password without echo) and pushes it into the LIVE
;; DOM via the native value setter + input/change events (React-safe),
;; then re-extracts.  Because the real DOM submits, cookies, CSRF tokens,
;; hidden fields and the session all ride along -- so logins actually
;; work, unlike a reconstructed url.el POST.

(defface cmacs-gsurf-lite-field-face
  '((t :inherit widget-field))
  "Face for editable form fields in gsurf-lite buffers."
  :group 'cmacs-gsurf-lite)

(defface cmacs-gsurf-lite-button-face
  '((t :inherit custom-button :weight bold))
  "Face for buttons/submit controls in gsurf-lite buffers."
  :group 'cmacs-gsurf-lite)

(defvar-local cmacs-gsurf-lite--focus-id nil
  "When set, `cmacs-gsurf-lite--render' moves point to this field id.")

(defvar-local cmacs-gsurf-lite--dirty nil
  "Hash of field id -> value typed inline but not yet flushed to the DOM.")

(defvar-local cmacs-gsurf-lite--flush-timer nil
  "Idle timer that pushes `cmacs-gsurf-lite--dirty' into the live DOM.")

(defvar-local cmacs-gsurf-lite--editing nil
  "Non-nil once the user has typed inline; suppresses SPA resettle re-renders.
A late re-extract would erase in-progress text, so once editing starts we
stop the timed re-renders until the next explicit navigation/reload.")

(defun cmacs-gsurf-lite--reset-edit-state ()
  "Drop any pending inline edits and re-enable resettle re-renders.
Called whenever an explicit navigation, reload, or click is initiated."
  (when (timerp cmacs-gsurf-lite--flush-timer)
    (cancel-timer cmacs-gsurf-lite--flush-timer))
  (setq cmacs-gsurf-lite--flush-timer nil
        cmacs-gsurf-lite--editing nil)
  (when cmacs-gsurf-lite--dirty
    (clrhash cmacs-gsurf-lite--dirty)))

(defvar cmacs-gsurf-lite-field-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")   #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-1]     #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-2]     #'cmacs-gsurf-lite-follow)
    m)
  "Keymap active on a non-editable gsurf-lite control (button/checkbox/select).")

(defvar cmacs-gsurf-lite-text-field-keymap
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m text-mode-map)
    ;; Inline editing: printable keys self-insert into the field, DEL erases.
    (define-key m [remap self-insert-command]    #'cmacs-gsurf-lite--self-insert)
    (define-key m [remap delete-backward-char]   #'cmacs-gsurf-lite--delete-backward)
    (define-key m [remap backward-delete-char]   #'cmacs-gsurf-lite--delete-backward)
    (define-key m [remap backward-delete-char-untabify]
                #'cmacs-gsurf-lite--delete-backward)
    (define-key m (kbd "DEL")     #'cmacs-gsurf-lite--delete-backward)
    (define-key m [remap delete-char]            #'cmacs-gsurf-lite--delete-forward)
    (define-key m [remap delete-forward-char]    #'cmacs-gsurf-lite--delete-forward)
    ;; RET still opens the minibuffer prompt path (see `cmacs-gsurf-lite-follow').
    (define-key m (kbd "RET")        #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-1]          #'cmacs-gsurf-lite--mouse-place)
    (define-key m [mouse-2]          #'cmacs-gsurf-lite-follow)
    (define-key m (kbd "TAB")        #'cmacs-gsurf-lite-next-field)
    (define-key m (kbd "<backtab>")  #'cmacs-gsurf-lite-prev-field)
    (define-key m (kbd "C-c C-c")    #'cmacs-gsurf-lite-submit)
    m)
  "Keymap on an inline-editable gsurf-lite text/password/textarea field.
Printable keys edit the field in place; RET opens the minibuffer prompt.")

(defconst cmacs-gsurf-lite--editable-types
  '("text" "password" "textarea" "email" "search" "tel" "url" "number"
    "date" "datetime-local" "month" "week" "time" "color")
  "Input types rendered as inline-editable text fields.")

(defun cmacs-gsurf-lite--editable-type-p (type)
  "Return non-nil if TYPE is an inline-editable text field type."
  (member type cmacs-gsurf-lite--editable-types))

(defun cmacs-gsurf-lite--field-label (dom)
  "Best human label for form-control DOM (name/aria/placeholder/id/type)."
  (let ((s (or (dom-attr dom 'aria-label)
               (dom-attr dom 'name)
               (dom-attr dom 'placeholder)
               (dom-attr dom 'id)
               (dom-attr dom 'type)
               "field")))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " (format "%s" s)))))

(defun cmacs-gsurf-lite--insert-field (text field face)
  "Insert TEXT as an activatable form field carrying FIELD plist, in FACE."
  (let ((start (point))
        (type (plist-get field :type)))
    (insert text)
    (add-text-properties
     start (point)
     (list 'cmacs-gsurf-lite-field field
           'keymap cmacs-gsurf-lite-field-keymap
           'face face 'mouse-face 'highlight
           'help-echo
           (format "%s (%s) — RET to %s"
                   (plist-get field :name) type
                   (if (member type '("submit" "button" "reset" "image"
                                      "checkbox" "radio"))
                       "activate" "edit"))))))

(defun cmacs-gsurf-lite--insert-text-field (label value width field type)
  "Insert an inline-editable text field: LABEL plus an editable VALUE box.
The editable region is WIDTH columns wide (padded with spaces), carries the
FIELD plist, and uses `cmacs-gsurf-lite-text-field-keymap' so printable keys
edit it in place.  For a password TYPE the characters display as bullets."
  (let ((password (string= type "password")))
    (insert (format "%s: " label))
    (let ((vstart (point)))
      (insert value)
      (when (and password (> (length value) 0))
        (put-text-property vstart (point) 'display
                           (make-string (length value) ?•)))
      (when (< (length value) width)
        (insert (make-string (- width (length value)) ?\s)))
      (add-text-properties
       vstart (point)
       (list 'cmacs-gsurf-lite-field field
             'keymap cmacs-gsurf-lite-text-field-keymap
             'face 'cmacs-gsurf-lite-field-face
             'mouse-face 'highlight
             'front-sticky t
             'help-echo
             (format "%s (%s) — type to edit inline, RET for minibuffer prompt"
                     label type)))
      ;; A plain trailing space ends the field run cleanly (boundary marker).
      (insert " "))))

;;;; Inline field editing
;;
;; Text/password/textarea fields are editable directly in the buffer, even
;; though it is `special-mode' read-only: the field's keymap remaps
;; `self-insert-command' (and the delete commands) to functions that edit
;; only inside the field region (with `inhibit-read-only' bound), keep the
;; box width stable by eating/adding trailing pad spaces, recompute the
;; field value, and push it into the live DOM on a short idle debounce.

(defun cmacs-gsurf-lite--field-bounds (pos)
  "Return (BEG . END) of the editable field run covering POS, or nil.
END is exclusive.  Handles POS sitting just past the end of a field."
  (let* ((here (get-text-property pos 'cmacs-gsurf-lite-field))
         (prev (and (> pos (point-min))
                    (get-text-property (1- pos) 'cmacs-gsurf-lite-field)))
         (at (cond (here pos)
                   (prev (1- pos))
                   (t nil)))
         (field (and at (get-text-property at 'cmacs-gsurf-lite-field))))
    (when (and field
               (cmacs-gsurf-lite--editable-type-p (plist-get field :type)))
      (let ((beg (if (and (> at (point-min))
                          (eq (get-text-property (1- at) 'cmacs-gsurf-lite-field)
                              field))
                     (previous-single-property-change
                      at 'cmacs-gsurf-lite-field nil (point-min))
                   at))
            (end (next-single-property-change
                  at 'cmacs-gsurf-lite-field nil (point-max))))
        (cons beg end)))))

(defun cmacs-gsurf-lite--field-value (beg end type)
  "Logical value of the editable field text in [BEG, END) of TYPE.
Trailing pad spaces are stripped.  Passwords return the real characters
(the bullets are only a `display' overlay, ignored by the substring)."
  (ignore type)
  (replace-regexp-in-string
   " +\\'" "" (buffer-substring-no-properties beg end)))

(defun cmacs-gsurf-lite--after-edit ()
  "Record the field at point as dirty and (re)arm the debounced DOM flush."
  (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
    (when bounds
      (let* ((beg (car bounds)) (end (cdr bounds))
             (field (get-text-property beg 'cmacs-gsurf-lite-field))
             (id (plist-get field :id))
             (val (cmacs-gsurf-lite--field-value beg end (plist-get field :type))))
        (setq cmacs-gsurf-lite--editing t
              cmacs-gsurf-lite--focus-id id)
        (when id
          (unless cmacs-gsurf-lite--dirty
            (setq cmacs-gsurf-lite--dirty (make-hash-table :test 'equal)))
          (puthash id val cmacs-gsurf-lite--dirty)
          (cmacs-gsurf-lite--schedule-flush))))))

(defun cmacs-gsurf-lite--schedule-flush ()
  "Arm an idle timer to push pending inline edits into the live DOM."
  (when (timerp cmacs-gsurf-lite--flush-timer)
    (cancel-timer cmacs-gsurf-lite--flush-timer))
  (setq cmacs-gsurf-lite--flush-timer
        (run-with-idle-timer 0.5 nil #'cmacs-gsurf-lite--flush-pending
                             (current-buffer))))

(defun cmacs-gsurf-lite--flush-pending (&optional buffer)
  "Push every dirty inline field in BUFFER into the live DOM (no re-render)."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (timerp cmacs-gsurf-lite--flush-timer)
          (cancel-timer cmacs-gsurf-lite--flush-timer)
          (setq cmacs-gsurf-lite--flush-timer nil))
        (when (and cmacs-gsurf-lite--dirty
                   (> (hash-table-count cmacs-gsurf-lite--dirty) 0))
          (maphash (lambda (id val)
                     (cmacs-gsurf-lite--set-field-quiet buf id val))
                   cmacs-gsurf-lite--dirty)
          (clrhash cmacs-gsurf-lite--dirty))))))

(defun cmacs-gsurf-lite--self-insert (&optional n)
  "Insert the typed character into the editable field at point, N times."
  (interactive "p")
  (let ((bounds (cmacs-gsurf-lite--field-bounds (point)))
        (ch last-command-event))
    (cond
     ((not bounds) (user-error "Not in an editable field"))
     ((not (characterp ch)) (ding))
     (t
      (let* ((beg (car bounds))
             (field (get-text-property beg 'cmacs-gsurf-lite-field))
             (password (string= (plist-get field :type) "password"))
             (props (text-properties-at beg))
             (inhibit-read-only t)
             (buffer-undo-list t))
        (dotimes (_ (max 1 (or n 1)))
          (let ((p (point)))
            (insert (char-to-string ch))
            (set-text-properties p (point) props)
            (when password
              (put-text-property p (point) 'display "•")))
          ;; Keep the box width stable: consume one trailing pad space.
          (let ((end (cdr (cmacs-gsurf-lite--field-bounds (point)))))
            (when (and end (> end (point)) (eq (char-before end) ?\s))
              (delete-region (1- end) end))))
        (cmacs-gsurf-lite--after-edit))))))

(defun cmacs-gsurf-lite--pad-field-end (props)
  "Append one pad space (carrying PROPS) at the end of the field at point.
Keeps the editable box a stable width as characters are deleted."
  (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
    (when bounds
      (save-excursion
        (goto-char (cdr bounds))
        (let ((p (point)))
          (insert " ")
          (set-text-properties p (point) props))))))

(defun cmacs-gsurf-lite--delete-backward (&optional n)
  "Delete N characters before point within the editable field at point."
  (interactive "p")
  (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
    (if (not bounds)
        (user-error "Not in an editable field")
      (let* ((beg (car bounds))
             (props (text-properties-at beg))
             (inhibit-read-only t)
             (buffer-undo-list t))
        (dotimes (_ (max 1 (or n 1)))
          (when (> (point) beg)
            (delete-region (1- (point)) (point))
            (cmacs-gsurf-lite--pad-field-end props)))
        (cmacs-gsurf-lite--after-edit)))))

(defun cmacs-gsurf-lite--delete-forward (&optional n)
  "Delete N characters after point within the editable field at point."
  (interactive "p")
  (let ((bounds (cmacs-gsurf-lite--field-bounds (point))))
    (if (not bounds)
        (user-error "Not in an editable field")
      (let* ((beg (car bounds))
             (props (text-properties-at beg))
             (inhibit-read-only t)
             (buffer-undo-list t))
        (dotimes (_ (max 1 (or n 1)))
          (let ((end (cdr (cmacs-gsurf-lite--field-bounds (point)))))
            (when (and end (< (point) end))
              (delete-region (point) (1+ (point)))
              (cmacs-gsurf-lite--pad-field-end props))))
        (cmacs-gsurf-lite--after-edit)))))

(defun cmacs-gsurf-lite--mouse-place (event)
  "Move point to the clicked position inside an editable field."
  (interactive "e")
  (mouse-set-point event))

(defun cmacs-gsurf-lite--tag-input (dom)
  "shr handler: render an <input> as an activatable field."
  (let* ((type (downcase (or (dom-attr dom 'type) "text")))
         (id   (dom-attr dom 'data-cmlite-id))
         (name (cmacs-gsurf-lite--field-label dom))
         (value (or (dom-attr dom 'value) ""))
         (field (list :id id :type type :name name)))
    (cond
     ((string= type "hidden") nil)
     ((member type '("submit" "button" "reset" "image"))
      (cmacs-gsurf-lite--insert-field
       (format "[ %s ]"
               (cond ((> (length value) 0) value)
                     ((> (length name) 0) name)
                     (t "Submit")))
       field 'cmacs-gsurf-lite-button-face))
     ((member type '("checkbox" "radio"))
      (cmacs-gsurf-lite--insert-field
       (format "[%s] %s" (if (dom-attr dom 'checked) "X" " ") name)
       field 'cmacs-gsurf-lite-field-face))
     ((string= type "password")
      ;; The real value is never extracted (masked); start the box empty so
      ;; inline typing builds the password fresh.
      (cmacs-gsurf-lite--insert-text-field name "" 24 field type))
     ((cmacs-gsurf-lite--editable-type-p type)
      (cmacs-gsurf-lite--insert-text-field
       name value
       (max 24 (string-to-number (or (dom-attr dom 'size) "40")))
       field type))
     (t
      (cmacs-gsurf-lite--insert-field
       (format "%s: [%s]" name (if (> (length value) 0) value "        "))
       field 'cmacs-gsurf-lite-field-face)))))

(defun cmacs-gsurf-lite--tag-textarea (dom)
  "shr handler: render a <textarea> as an inline-editable field."
  (let* ((id (dom-attr dom 'data-cmlite-id))
         (name (cmacs-gsurf-lite--field-label dom))
         (value (string-trim (or (dom-texts dom) "")))
         (field (list :id id :type "textarea" :name name)))
    (cmacs-gsurf-lite--insert-text-field name value 60 field "textarea")))

(defun cmacs-gsurf-lite--tag-select (dom)
  "shr handler: render a <select> as an activatable field with options."
  (let* ((id (dom-attr dom 'data-cmlite-id))
         (name (cmacs-gsurf-lite--field-label dom))
         (opts (mapcar (lambda (o)
                         (cons (string-trim (or (dom-texts o) ""))
                               (or (dom-attr o 'value)
                                   (string-trim (or (dom-texts o) "")))))
                       (dom-by-tag dom 'option)))
         (cur (cl-loop for o in (dom-by-tag dom 'option)
                       when (dom-attr o 'selected)
                       return (string-trim (or (dom-texts o) ""))))
         (field (list :id id :type "select" :name name :options opts)))
    (cmacs-gsurf-lite--insert-field
     (format "%s: [%s ▾]" name (or cur (and opts (caar opts)) ""))
     field 'cmacs-gsurf-lite-field-face)))

(defun cmacs-gsurf-lite--tag-button (dom)
  "shr handler: render a <button> as an activatable button."
  (let* ((id (dom-attr dom 'data-cmlite-id))
         (label (string-trim (or (dom-texts dom)
                                 (dom-attr dom 'value)
                                 (cmacs-gsurf-lite--field-label dom))))
         (field (list :id id :type "button" :name label)))
    (cmacs-gsurf-lite--insert-field
     (format "[ %s ]" (if (> (length label) 0) label "Button"))
     field 'cmacs-gsurf-lite-button-face)))

(defun cmacs-gsurf-lite--goto-field (id)
  "Move point to the start of the field whose id is ID.  Return non-nil."
  (let ((pos (point-min)) (found nil))
    (while (and (not found) (< pos (point-max)))
      (let ((f (get-text-property pos 'cmacs-gsurf-lite-field)))
        (if (and f (equal (plist-get f :id) id))
            (progn (goto-char pos) (setq found t))
          (setq pos (or (next-single-property-change
                         pos 'cmacs-gsurf-lite-field)
                        (point-max))))))
    found))

(defun cmacs-gsurf-lite--schedule-reextracts (buffer &optional delays)
  "Re-extract/re-render BUFFER at each delay in DELAYS (seconds).
DELAYS defaults to `cmacs-gsurf-lite-action-watch-times'.
This is how a JS click/submit that redirects client-side -- a `pushState'
SPA route change, a `window.location' bounce, or a fetch-then-update --
gets reflected even though such navigations may fire late or fire no
load event at all (so the `load-changed' hook never runs).  In-progress
inline editing suppresses the re-render so typed text is not clobbered."
  (dolist (d (or delays cmacs-gsurf-lite-action-watch-times))
    (run-at-time d nil
                 (lambda ()
                   (when (and (cmacs-gsurf-lite-buffer-p buffer)
                              (not (buffer-local-value
                                    'cmacs-gsurf-lite--editing buffer)))
                     (cmacs-gsurf-lite--extract-and-render buffer))))))

(defun cmacs-gsurf-lite--run-js-then-reextract (buffer js &optional focus-id)
  "Run JS in BUFFER's view, then re-extract/re-render across the resettle window.
If FOCUS-ID is non-nil, point is moved back to that field after render.
Several re-extracts are scheduled (not just one) so a click/submit that
triggers a delayed or client-side (SPA) redirect still re-renders."
  (when (and focus-id (buffer-live-p buffer))
    (with-current-buffer buffer (setq cmacs-gsurf-lite--focus-id focus-id)))
  (cmacs-gsurf-run-javascript-async
   buffer js
   (lambda (_r)
     (cmacs-gsurf-lite--schedule-reextracts buffer))))

(defun cmacs-gsurf-lite--set-field (id value)
  "Set the live DOM control ID to VALUE (React-safe), then re-extract."
  (let ((js (format "(function(){\
var e=document.querySelector('[data-cmlite-id=%s]');\
if(!e)return 'nofound';\
var pr=(e.tagName==='TEXTAREA')?window.HTMLTextAreaElement.prototype:\
((e.tagName==='SELECT')?window.HTMLSelectElement.prototype:window.HTMLInputElement.prototype);\
var d=Object.getOwnPropertyDescriptor(pr,'value');\
try{ if(d&&d.set){ d.set.call(e,%s); } else { e.value=%s; } }catch(_e){ try{e.value=%s;}catch(_f){} }\
e.dispatchEvent(new Event('input',{bubbles:true}));\
e.dispatchEvent(new Event('change',{bubbles:true}));\
e.dispatchEvent(new Event('blur',{bubbles:true}));\
return 'ok';})();"
                    (cmacs-gsurf--js-string id)
                    (cmacs-gsurf--js-string value)
                    (cmacs-gsurf--js-string value)
                    (cmacs-gsurf--js-string value))))
    (cmacs-gsurf-lite--run-js-then-reextract (current-buffer) js id)))

(defun cmacs-gsurf-lite--set-field-quiet (buffer id value)
  "Push VALUE into live DOM control ID in BUFFER, with NO re-extract/render.
Used while typing inline so the buffer text the user is editing is left
untouched; the DOM is updated underneath (input/change, but not blur)."
  (let ((js (format "(function(){\
var e=document.querySelector('[data-cmlite-id=%s]');\
if(!e)return 'nofound';\
var pr=(e.tagName==='TEXTAREA')?window.HTMLTextAreaElement.prototype:\
((e.tagName==='SELECT')?window.HTMLSelectElement.prototype:window.HTMLInputElement.prototype);\
var d=Object.getOwnPropertyDescriptor(pr,'value');\
try{ if(d&&d.set){ d.set.call(e,%s); } else { e.value=%s; } }catch(_e){ try{e.value=%s;}catch(_f){} }\
e.dispatchEvent(new Event('input',{bubbles:true}));\
e.dispatchEvent(new Event('change',{bubbles:true}));\
return 'ok';})();"
                    (cmacs-gsurf--js-string id)
                    (cmacs-gsurf--js-string value)
                    (cmacs-gsurf--js-string value)
                    (cmacs-gsurf--js-string value))))
    (when (buffer-live-p buffer)
      (cmacs-gsurf-run-javascript-async buffer js #'ignore))))

(defun cmacs-gsurf-lite--edit-select (field)
  "Prompt for one of FIELD's options and set it in the live DOM."
  (let* ((opts (plist-get field :options))
         (choice (completing-read
                  (format "%s: " (plist-get field :name))
                  (mapcar #'car opts) nil t))
         (val (or (cdr (assoc choice opts)) choice)))
    (cmacs-gsurf-lite--set-field (plist-get field :id) val)))

(defun cmacs-gsurf-lite--field-activate (field)
  "Activate FIELD: click buttons/toggles, prompt + set text/password/select."
  (let ((id (plist-get field :id))
        (type (plist-get field :type)))
    (unless id (user-error "This field cannot be activated"))
    (pcase type
      ((or "submit" "button" "reset" "image" "checkbox" "radio")
       ;; Land any inline-typed values in the DOM before the click submits.
       (cmacs-gsurf-lite--flush-pending (current-buffer))
       (cmacs-gsurf-lite--click-id (current-buffer) id))
      ("select" (cmacs-gsurf-lite--edit-select field))
      ("password"
       (cmacs-gsurf-lite--set-field
        id (read-passwd (format "%s: " (plist-get field :name)))))
      (_
       (cmacs-gsurf-lite--set-field
        id (read-string (format "%s: " (plist-get field :name))))))))

(defun cmacs-gsurf-lite-submit ()
  "Submit the form on the page (click its submit control / call submit()).
Convenience for when the submit button is hard to land on; usually you
just press RET on the login/submit button itself."
  (interactive)
  ;; Push any inline-typed values first so the form posts what is on screen.
  (cmacs-gsurf-lite--flush-pending (current-buffer))
  (cmacs-gsurf-lite--run-js-then-reextract
   (current-buffer)
   "(function(){\
var f=document.querySelector('form');\
var b=(f||document).querySelector('input[type=submit],button[type=submit],button');\
if(b){b.click();return 'clicked';}\
if(f){ if(f.requestSubmit) f.requestSubmit(); else f.submit(); return 'submitted';}\
return 'noform';})();"))

(defun cmacs-gsurf-lite--item-at (pos)
  "Return non-nil if POS is on a field or a link."
  (or (get-text-property pos 'cmacs-gsurf-lite-field)
      (get-text-property pos 'shr-url)))

(defun cmacs-gsurf-lite--goto-item (dir)
  "Move to the next (DIR 1) or previous (DIR -1) field or link."
  (let ((pos (point)) (lim (if (> dir 0) (point-max) (point-min))))
    ;; step off the current item
    (while (and (/= pos lim) (cmacs-gsurf-lite--item-at pos))
      (setq pos (+ pos dir)))
    ;; find the next item
    (while (and (/= pos lim) (not (cmacs-gsurf-lite--item-at pos)))
      (setq pos (+ pos dir)))
    (if (cmacs-gsurf-lite--item-at pos)
        (progn
          ;; for backward motion, land on the START of the item
          (when (< dir 0)
            (while (and (> pos (point-min))
                        (cmacs-gsurf-lite--item-at (1- pos)))
              (setq pos (1- pos))))
          (goto-char pos))
      (message "No more fields or links"))))

(defun cmacs-gsurf-lite-next-field ()
  "Move to the next form field or link."
  (interactive)
  (cmacs-gsurf-lite--goto-item 1))

(defun cmacs-gsurf-lite-prev-field ()
  "Move to the previous form field or link."
  (interactive)
  (cmacs-gsurf-lite--goto-item -1))

(defun cmacs-gsurf-lite--with-base (dom base-url)
  "Wrap DOM in a <base href=BASE-URL> node so shr resolves relatives.
Mirrors eww's `eww-document-base'."
  (if (and base-url (eq (dom-tag dom) 'html))
      (dom-node 'base (list (cons 'href base-url)) dom)
    dom))

(defun cmacs-gsurf-lite--render (html base-url)
  "Render HTML (a string) into the current buffer with shr, using BASE-URL."
  (let* ((inhibit-read-only t)
         (dom (with-temp-buffer
                (insert (or html ""))
                (libxml-parse-html-region (point-min) (point-max))))
         (shr-width cmacs-gsurf-lite-shr-width)
         (shr-external-rendering-functions
          (list (cons 'a        #'cmacs-gsurf-lite--tag-a)
                (cons 'input    #'cmacs-gsurf-lite--tag-input)
                (cons 'textarea #'cmacs-gsurf-lite--tag-textarea)
                (cons 'select   #'cmacs-gsurf-lite--tag-select)
                (cons 'button   #'cmacs-gsurf-lite--tag-button)))
         (point-before (point))
         (focus cmacs-gsurf-lite--focus-id))
    (erase-buffer)
    (when dom
      (shr-insert-document (cmacs-gsurf-lite--with-base dom base-url)))
    (setq cmacs-gsurf-lite--base-url base-url)
    ;; Restore point: to a just-edited field if any, else the prior spot.
    (cond
     ((and focus (cmacs-gsurf-lite--goto-field focus))
      (setq cmacs-gsurf-lite--focus-id nil))
     ((<= point-before (point-max)) (goto-char point-before))
     (t (goto-char (point-min))))
    (cmacs-gsurf-lite--update-header)))

(defun cmacs-gsurf-lite--update-header ()
  "Refresh the lite buffer's header line with the current URL."
  (setq header-line-format
        (concat " gsurf-lite: " (or cmacs-gsurf-lite--base-url "")))
  (force-mode-line-update))

;;;; Load / extract loop

(defun cmacs-gsurf-lite-buffer-p (buffer)
  "Return non-nil if BUFFER is a gsurf-lite buffer."
  (and (buffer-live-p buffer)
       (eq (buffer-local-value 'major-mode buffer) 'cmacs-gsurf-lite-mode)))

(defun cmacs-gsurf-lite--extract-and-render (buffer)
  "Pull the post-JS HTML out of BUFFER's hidden view and render it."
  (when (cmacs-gsurf-lite-buffer-p buffer)
    (cmacs-gsurf-run-javascript-async
     buffer cmacs-gsurf-lite--extract-js
     (lambda (html)
       (when (cmacs-gsurf-lite-buffer-p buffer)
         (with-current-buffer buffer
           (let ((u (ignore-errors (cmacs-gsurf-get-uri buffer))))
             (cmacs-gsurf-lite--render
              (or html "") (or u cmacs-gsurf-lite--base-url)))))))))

(defcustom cmacs-gsurf-lite-resettle-times '(0.6 1.6 3.0)
  "Extra delays (seconds) after load-finish to re-extract the DOM.
Many sites (Fidelity's sign-in, other React/SPA pages) render their
real content -- forms, results -- only after the load-finished event,
once JavaScript hydrates.  gsurf-lite renders immediately on finish and
then re-extracts at each of these delays so late-rendered content shows
up.  Each re-extract simply re-renders the buffer (idempotent)."
  :type '(repeat number)
  :group 'cmacs-gsurf-lite)

(defun cmacs-gsurf-lite--on-load-changed (buffer event)
  "Re-render BUFFER when its hidden view finishes a load (EVENT).
Renders immediately, then re-extracts at `cmacs-gsurf-lite-resettle-times'
to catch SPA content that hydrates after the load-finished event."
  (when (and (eq event 'finished) (cmacs-gsurf-lite-buffer-p buffer)
             ;; Don't clobber in-progress inline typing with a re-render.
             (not (buffer-local-value 'cmacs-gsurf-lite--editing buffer)))
    (cmacs-gsurf-lite--extract-and-render buffer)
    (cmacs-gsurf-lite--schedule-reextracts
     buffer cmacs-gsurf-lite-resettle-times)))

(add-hook 'cmacs-gsurf-load-changed-functions
          #'cmacs-gsurf-lite--on-load-changed)

;;;; Navigation / interaction (never url-retrieve)

(defun cmacs-gsurf-lite-follow ()
  "Activate the thing at point: a form field, or a link.
On a text field this opens a minibuffer prompt (passwords without echo) --
you can also just type into the field inline; either way the value is
pushed into the live DOM.  Buttons/checkboxes/selects are clicked/toggled.
Real links navigate the hidden view (the load-finish hook re-renders);
JS/onclick links with a `data-cmlite-id' are clicked by selector."
  (interactive)
  (let ((field (get-text-property (point) 'cmacs-gsurf-lite-field))
        (url (get-text-property (point) 'shr-url))
        (cmid (get-text-property (point) 'cmacs-gsurf-lite-id)))
    (cond
     (field (cmacs-gsurf-lite--field-activate field))
     ((and url (not (string-prefix-p "javascript:" url)))
      (cmacs-gsurf-lite--reset-edit-state)
      (let ((abs (shr-expand-url url cmacs-gsurf-lite--base-url)))
        (setq cmacs-gsurf-lite--base-url abs)
        (message "gsurf-lite: loading %s" abs)
        (cmacs-gsurf-load-uri (current-buffer) abs)))
     (cmid (cmacs-gsurf-lite--click-id (current-buffer) cmid))
     (t (message "No link or field at point")))))

(defun cmacs-gsurf-lite--click-id (buffer cmid)
  "Click the element tagged CMID in BUFFER's hidden view, then re-extract."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (cmacs-gsurf-lite--reset-edit-state)))
  (cmacs-gsurf-lite--run-js-then-reextract
   buffer
   (format "(function(){var e=document.querySelector('[data-cmlite-id=%s]');\
if(!e)return 'nofound';e.click();return 'clicked';})();"
           (cmacs-gsurf--js-string cmid))))

(defun cmacs-gsurf-lite-reload ()
  "Reload the current lite page."
  (interactive)
  (cmacs-gsurf-lite--reset-edit-state)
  (cmacs-gsurf-reload (current-buffer)))

(defun cmacs-gsurf-lite-back ()
  "Go back in the hidden view's history."
  (interactive)
  (cmacs-gsurf-lite--reset-edit-state)
  (cmacs-gsurf-back (current-buffer)))

(defun cmacs-gsurf-lite-forward ()
  "Go forward in the hidden view's history."
  (interactive)
  (cmacs-gsurf-lite--reset-edit-state)
  (cmacs-gsurf-forward (current-buffer)))

(defun cmacs-gsurf-lite-open (url)
  "Load URL (or a search) in the current lite buffer."
  (interactive "sOpen URL or search: ")
  (cmacs-gsurf-lite--reset-edit-state)
  (let ((abs (cmacs-gsurf--normalize-url url)))
    (setq cmacs-gsurf-lite--base-url abs)
    (cmacs-gsurf-load-uri (current-buffer) abs)))

(defun cmacs-gsurf-lite-browse-external ()
  "Open the current page (or link at point) in a full live gsurf buffer."
  (interactive)
  (cmacs-gsurf (or (get-text-property (point) 'shr-url)
                   cmacs-gsurf-lite--base-url
                   cmacs-gsurf-home-url)))

;;;; Mode

(defvar cmacs-gsurf-lite-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")      #'cmacs-gsurf-lite-follow)
    (define-key m (kbd "<mouse-2>") #'cmacs-gsurf-lite-follow)
    (define-key m "g"              #'cmacs-gsurf-lite-reload)
    (define-key m "r"              #'cmacs-gsurf-lite-reload)
    (define-key m "B"              #'cmacs-gsurf-lite-back)
    (define-key m "F"              #'cmacs-gsurf-lite-forward)
    (define-key m "H"              #'cmacs-gsurf-lite-back)
    (define-key m "L"              #'cmacs-gsurf-lite-forward)
    (define-key m "o"              #'cmacs-gsurf-lite-open)
    (define-key m (kbd "TAB")      #'cmacs-gsurf-lite-next-field)
    (define-key m (kbd "<backtab>") #'cmacs-gsurf-lite-prev-field)
    (define-key m (kbd "C-c C-c")  #'cmacs-gsurf-lite-submit)
    (define-key m "&"              #'cmacs-gsurf-lite-browse-external)
    (define-key m "q"              #'quit-window)
    m)
  "Keymap for `cmacs-gsurf-lite-mode'.")

(defun cmacs-gsurf-lite--on-kill ()
  "Detach the hidden view and unregister when a lite buffer is killed."
  (when (timerp cmacs-gsurf-lite--flush-timer)
    (cancel-timer cmacs-gsurf-lite--flush-timer))
  (setq cmacs-gsurf-lite--buffers
        (delq (current-buffer) cmacs-gsurf-lite--buffers))
  (when (ignore-errors (cmacs-gsurf-attached-p (current-buffer)))
    (ignore-errors (cmacs-gsurf-detach (current-buffer)))))

(define-derived-mode cmacs-gsurf-lite-mode special-mode "gsurf-lite"
  "Major mode for gsurf-lite text-rendered web buffers.
The page is rendered offscreen by gsurf/WebKit (so its JavaScript runs
and logins persist) and dumped here as real, navigable Emacs text via
`shr'.  Links navigate the hidden view in place.  Text/password/textarea
fields are editable inline -- just type into them -- or press RET for a
minibuffer prompt; either way the value is pushed into the live DOM, so
real logins work.  TAB/S-TAB move between fields and links; C-c C-c
submits.
\\{cmacs-gsurf-lite-mode-map}"
  (unless (cmacs-gsurf-supported-p)
    (user-error "cmacs-gsurf not built; reconfigure with --with-cmacs-gsurf"))
  (buffer-disable-undo)
  (setq-local cmacs-gsurf-lite--base-url nil)
  (add-hook 'kill-buffer-hook #'cmacs-gsurf-lite--on-kill nil t))

;;;###autoload
(defun cmacs-gsurf-lite (&optional url)
  "Open URL in a gsurf-lite text buffer (offscreen render -> shr text).
Interactively, prompt for a URL or search query."
  (interactive (list (read-string "gsurf-lite URL or search: "
                                   nil nil cmacs-gsurf-home-url)))
  (unless (cmacs-gsurf-supported-p)
    (user-error "cmacs-gsurf not built; reconfigure with --with-cmacs-gsurf"))
  (let* ((target (cmacs-gsurf--normalize-url (or url cmacs-gsurf-home-url)))
         (buf (generate-new-buffer "*gsurf-lite*")))
    (with-current-buffer buf
      (cmacs-gsurf-lite-mode)
      (when (fboundp 'cmacs-gsurf--apply-config)
        (ignore-errors (cmacs-gsurf--apply-config)))
      ;; Attach a HEADLESS view: hosted in a GtkOffscreenWindow so WebKit
      ;; realizes and runs JS, but never shown on a frame (so the live
      ;; page can't cover the shr text we render below).
      (cmacs-gsurf-attach buf t)
      (push buf cmacs-gsurf-lite--buffers)
      (setq cmacs-gsurf-lite--base-url target)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Loading " target " ..."))
      (cmacs-gsurf-lite--update-header)
      (cmacs-gsurf-load-uri buf target))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-gsurf-lite-browse-url (url &rest _args)
  "`browse-url' handler that opens URL in a gsurf-lite buffer."
  (cmacs-gsurf-lite url))

;;;; MCP helpers (exposed as gsurf_lite_open / gsurf_extract_text)

(defun cmacs-gsurf-lite--mcp-target (&optional name)
  "Resolve a lite buffer by NAME, or the most recent live one."
  (or (and name (get-buffer name))
      (cl-find-if #'buffer-live-p cmacs-gsurf-lite--buffers)
      (user-error "No gsurf-lite buffer")))

(defun cmacs-gsurf-lite-mcp-open (url)
  "MCP: open URL in a gsurf-lite buffer; return the buffer name."
  (buffer-name (cmacs-gsurf-lite url)))

(defun cmacs-gsurf-lite-mcp-extract-text (&optional name)
  "MCP: return the rendered plain text of lite buffer NAME (or newest)."
  (with-current-buffer (cmacs-gsurf-lite--mcp-target name)
    (buffer-substring-no-properties (point-min) (point-max))))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-gsurf-lite-mode 'normal))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) cmacs-gsurf-lite-mode-map
      (kbd "RET") #'cmacs-gsurf-lite-follow
      "g"  #'cmacs-gsurf-lite-reload
      "B"  #'cmacs-gsurf-lite-back
      "F"  #'cmacs-gsurf-lite-forward
      "o"  #'cmacs-gsurf-lite-open
      "&"  #'cmacs-gsurf-lite-browse-external
      (kbd "TAB") #'cmacs-gsurf-lite-next-field
      (kbd "<backtab>") #'cmacs-gsurf-lite-prev-field
      (kbd "C-c C-c") #'cmacs-gsurf-lite-submit
      "q"  #'quit-window)))

(provide 'cmacs-gsurf-lite)
;;; cmacs-gsurf-lite.el ends here
