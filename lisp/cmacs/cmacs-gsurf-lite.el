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
;; Forms / logins WORK: form controls render as editable items; RET on
;; one prompts for a value (passwords without echo) and pushes it into
;; the LIVE DOM via the native value setter + input/change events
;; (React-safe), and RET on a submit button clicks the real control.
;; Because the real DOM submits, cookies / CSRF tokens / hidden fields /
;; the session all ride along -- so a real login posts exactly what a
;; browser would.  TAB / S-TAB move between fields and links; C-c C-c
;; submits the form.

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

(defvar cmacs-gsurf-lite-field-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")   #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-1]     #'cmacs-gsurf-lite-follow)
    (define-key m [mouse-2]     #'cmacs-gsurf-lite-follow)
    m)
  "Keymap active on a gsurf-lite form field (text property keymap).")

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
      (cmacs-gsurf-lite--insert-field
       (format "%s: [%s]" name
               (if (equal (dom-attr dom 'data-cmlite-filled) "1")
                   "••••••" "        "))
       field 'cmacs-gsurf-lite-field-face))
     (t
      (cmacs-gsurf-lite--insert-field
       (format "%s: [%s]" name (if (> (length value) 0) value "        "))
       field 'cmacs-gsurf-lite-field-face)))))

(defun cmacs-gsurf-lite--tag-textarea (dom)
  "shr handler: render a <textarea> as an activatable field."
  (let* ((id (dom-attr dom 'data-cmlite-id))
         (name (cmacs-gsurf-lite--field-label dom))
         (value (string-trim (or (dom-texts dom) "")))
         (field (list :id id :type "textarea" :name name)))
    (cmacs-gsurf-lite--insert-field
     (format "%s: [%s]" name
             (if (> (length value) 0)
                 (truncate-string-to-width value 40 nil nil "…")
               "        "))
     field 'cmacs-gsurf-lite-field-face)))

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

(defun cmacs-gsurf-lite--run-js-then-reextract (buffer js &optional focus-id)
  "Run JS in BUFFER's view, then re-extract/re-render after a settle.
If FOCUS-ID is non-nil, point is moved back to that field after render."
  (when focus-id
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (setq cmacs-gsurf-lite--focus-id focus-id))))
  (cmacs-gsurf-run-javascript-async
   buffer js
   (lambda (_r)
     (run-at-time cmacs-gsurf-lite-extract-settle nil
                  #'cmacs-gsurf-lite--extract-and-render buffer))))

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
  (when (and (eq event 'finished) (cmacs-gsurf-lite-buffer-p buffer))
    (cmacs-gsurf-lite--extract-and-render buffer)
    (dolist (delay cmacs-gsurf-lite-resettle-times)
      (run-at-time delay nil
                   (lambda ()
                     (when (cmacs-gsurf-lite-buffer-p buffer)
                       (cmacs-gsurf-lite--extract-and-render buffer)))))))

(add-hook 'cmacs-gsurf-load-changed-functions
          #'cmacs-gsurf-lite--on-load-changed)

;;;; Navigation / interaction (never url-retrieve)

(defun cmacs-gsurf-lite-follow ()
  "Activate the thing at point: a form field, or a link.
Form fields prompt + push into the live DOM (passwords without echo);
real links navigate the hidden view (the load-finish hook re-renders);
JS/onclick links with a `data-cmlite-id' are clicked by selector."
  (interactive)
  (let ((field (get-text-property (point) 'cmacs-gsurf-lite-field))
        (url (get-text-property (point) 'shr-url))
        (cmid (get-text-property (point) 'cmacs-gsurf-lite-id)))
    (cond
     (field (cmacs-gsurf-lite--field-activate field))
     ((and url (not (string-prefix-p "javascript:" url)))
      (let ((abs (shr-expand-url url cmacs-gsurf-lite--base-url)))
        (setq cmacs-gsurf-lite--base-url abs)
        (message "gsurf-lite: loading %s" abs)
        (cmacs-gsurf-load-uri (current-buffer) abs)))
     (cmid (cmacs-gsurf-lite--click-id (current-buffer) cmid))
     (t (message "No link or field at point")))))

(defun cmacs-gsurf-lite--click-id (buffer cmid)
  "Click the element tagged CMID in BUFFER's hidden view, then re-extract."
  (cmacs-gsurf-lite--run-js-then-reextract
   buffer
   (format "(function(){var e=document.querySelector('[data-cmlite-id=%s]');\
if(!e)return 'nofound';e.click();return 'clicked';})();"
           (cmacs-gsurf--js-string cmid))))

(defun cmacs-gsurf-lite-reload ()
  "Reload the current lite page."
  (interactive)
  (cmacs-gsurf-reload (current-buffer)))

(defun cmacs-gsurf-lite-back ()
  "Go back in the hidden view's history."
  (interactive)
  (cmacs-gsurf-back (current-buffer)))

(defun cmacs-gsurf-lite-forward ()
  "Go forward in the hidden view's history."
  (interactive)
  (cmacs-gsurf-forward (current-buffer)))

(defun cmacs-gsurf-lite-open (url)
  "Load URL (or a search) in the current lite buffer."
  (interactive "sOpen URL or search: ")
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
  (setq cmacs-gsurf-lite--buffers
        (delq (current-buffer) cmacs-gsurf-lite--buffers))
  (when (ignore-errors (cmacs-gsurf-attached-p (current-buffer)))
    (ignore-errors (cmacs-gsurf-detach (current-buffer)))))

(define-derived-mode cmacs-gsurf-lite-mode special-mode "gsurf-lite"
  "Major mode for gsurf-lite text-rendered web buffers.
The page is rendered offscreen by gsurf/WebKit (so its JavaScript runs
and logins persist) and dumped here as real, navigable Emacs text via
`shr'.  Links navigate the hidden view in place; form fields are
editable (RET to fill, passwords without echo) and submit through the
live DOM, so real logins work.  TAB/S-TAB move between fields and links.
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
