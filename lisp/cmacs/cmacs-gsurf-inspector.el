;;; cmacs-gsurf-inspector.el --- Emacs-native DevTools for gsurf  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An Emacs-native inspector for a live gsurf page, built entirely on
;; injected JavaScript (no page focus needed) plus the JS->Emacs message
;; channel from the `js_bridge' module:
;;
;;   - *gsurf-dom*     a DOM tree you navigate with point; the node at point
;;                     can be highlighted in the live page, scrolled to, or
;;                     have its computed style shown.
;;   - *gsurf-css*     computed style of the selected node.
;;   - *gsurf-console* streamed console.log/warn/error output, plus a JS
;;                     eval line (press `e').
;;
;; Nodes are addressed by a `data-cmacs-node-id' attribute the DOM walk
;; stamps (the same proven scheme as gsurf-lite's `data-cmlite-id').

;;; Code:

(require 'cmacs-gsurf)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence
(require 'subr-x)
(require 'json)

(declare-function cmacs-gsurf-run-javascript-async "cmacs-gsurf-defuns.c"
                  (buffer script callback))
(declare-function cmacs-gsurf-add-user-script "cmacs-gsurf-defuns.c"
                  (buffer script &optional at-end))
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))

(defgroup cmacs-gsurf-inspector nil
  "Emacs-native inspector for the cmacs-gsurf browser."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-inspector-")

(defcustom cmacs-gsurf-inspector-depth 8
  "How many DOM levels the inspector walks for *gsurf-dom*."
  :type 'integer
  :group 'cmacs-gsurf-inspector)

;;;; Shared helpers ---------------------------------------------------

(defvar-local cmacs-gsurf-inspector--source nil
  "The gsurf buffer an inspector buffer is inspecting.")

(defun cmacs-gsurf-inspector--source ()
  "Return the gsurf buffer being inspected (error if gone)."
  (let ((b cmacs-gsurf-inspector--source))
    (unless (buffer-live-p b)
      (user-error "Inspected gsurf buffer is gone"))
    b))

(defun cmacs-gsurf-inspector--eval (src js callback)
  "Run JS in gsurf buffer SRC, calling CALLBACK with the result string."
  (cmacs-gsurf-run-javascript-async src js callback))

;;;; DOM tree ---------------------------------------------------------

(defun cmacs-gsurf-inspector--walk-js (depth)
  "JS that stamps data-cmacs-node-id and returns the DOM tree as JSON."
  (format "(function(){var n=0;function w(e,d){if(!e||e.nodeType!==1)return null;\
e.setAttribute('data-cmacs-node-id',String(n));var id=n++;\
var cl=(e.className&&e.className.toString)?e.className.toString():'';\
var o={id:id,tag:e.tagName.toLowerCase(),nid:e.id||'',cls:cl,kids:[],more:0};\
if(d>0){for(var i=0;i<e.children.length;i++){var c=w(e.children[i],d-1);\
if(c)o.kids.push(c);}}else{o.more=e.children.length;}return o;}\
return JSON.stringify(w(document.documentElement,%d));})()" depth))

(defun cmacs-gsurf-inspector--insert-node (node level)
  "Insert NODE (an alist) at indentation LEVEL into the DOM buffer."
  (let* ((id (alist-get 'id node))
         (tag (alist-get 'tag node))
         (nid (alist-get 'nid node))
         (cls (alist-get 'cls node))
         (kids (alist-get 'kids node))
         (more (alist-get 'more node))
         (label (concat
                 (make-string (* 2 level) ?\s)
                 (propertize (format "<%s>" tag) 'face 'font-lock-keyword-face)
                 (when (and nid (not (string-empty-p nid)))
                   (propertize (format " #%s" nid) 'face 'font-lock-variable-name-face))
                 (when (and cls (not (string-empty-p cls)))
                   (propertize (format " .%s" (string-replace " " "." cls))
                               'face 'font-lock-type-face))
                 (when (and more (> more 0))
                   (propertize (format "  (+%d)" more) 'face 'shadow)))))
    (insert (propertize label 'cmacs-gsurf-node-id id) "\n")
    (dolist (k kids)
      (cmacs-gsurf-inspector--insert-node k (1+ level)))))

(defun cmacs-gsurf-inspector--render-dom (buf json)
  "Render DOM JSON into the *gsurf-dom* BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (tree (ignore-errors
                    (json-parse-string json :object-type 'alist
                                       :array-type 'list))))
        (erase-buffer)
        (if (null tree)
            (insert "… loading DOM (try `g' to refresh)\n")
          (cmacs-gsurf-inspector--insert-node tree 0))
        (goto-char (point-min))))))

(defun cmacs-gsurf-inspector-refresh ()
  "Re-walk the inspected page and rebuild the DOM tree."
  (interactive)
  (let ((src (cmacs-gsurf-inspector--source))
        (buf (current-buffer)))
    (cmacs-gsurf-inspector--eval
     src (cmacs-gsurf-inspector--walk-js cmacs-gsurf-inspector-depth)
     (lambda (json) (cmacs-gsurf-inspector--render-dom buf json)))))

(defun cmacs-gsurf-inspector--node-at-point ()
  (or (get-text-property (point) 'cmacs-gsurf-node-id)
      (user-error "No DOM node on this line")))

(defun cmacs-gsurf-inspector-highlight ()
  "Outline the node at point in the live page and scroll it into view."
  (interactive)
  (let ((id (cmacs-gsurf-inspector--node-at-point))
        (src (cmacs-gsurf-inspector--source)))
    (cmacs-gsurf-inspector--eval
     src
     (format "(function(id){var p=document.querySelector('[data-cmacs-hl=\"1\"]');\
if(p){p.style.outline=p.__cmOld||'';p.removeAttribute('data-cmacs-hl');}\
var e=document.querySelector('[data-cmacs-node-id=\"'+id+'\"]');\
if(e){e.__cmOld=e.style.outline;e.style.outline='2px solid #ff69b4';\
e.setAttribute('data-cmacs-hl','1');e.scrollIntoView({block:'center'});}})(%d)"
             id)
     #'ignore)))

(defun cmacs-gsurf-inspector-show-css ()
  "Show the computed style of the node at point in *gsurf-css*."
  (interactive)
  (let ((id (cmacs-gsurf-inspector--node-at-point))
        (src (cmacs-gsurf-inspector--source)))
    (cmacs-gsurf-inspector--eval
     src
     (format "(function(id){var e=document.querySelector('[data-cmacs-node-id=\"'+id+'\"]');\
if(!e)return '{}';var c=getComputedStyle(e),o={};\
for(var i=0;i<c.length;i++){o[c[i]]=c.getPropertyValue(c[i]);}\
return JSON.stringify(o);})(%d)" id)
     (lambda (json)
       (let ((buf (get-buffer-create "*gsurf-css*"))
             (props (ignore-errors
                      (json-parse-string json :object-type 'alist
                                         :array-type 'list))))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (special-mode)
             (insert (propertize (format "computed style for node %d\n\n" id)
                                 'face 'bold))
             (dolist (p (sort (copy-sequence props)
                              (lambda (a b) (string< (format "%s" (car a))
                                                     (format "%s" (car b))))))
               (let ((v (cdr p)))
                 (when (and v (stringp v) (not (string-empty-p v)))
                   (insert (format "%-34s %s\n" (car p) v)))))
             (goto-char (point-min))))
         (display-buffer buf))))))

(defvar cmacs-gsurf-dom-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "g")   #'cmacs-gsurf-inspector-refresh)
    (define-key m (kbd "h")   #'cmacs-gsurf-inspector-highlight)
    (define-key m (kbd "RET") #'cmacs-gsurf-inspector-highlight)
    (define-key m (kbd "c")   #'cmacs-gsurf-inspector-show-css)
    m)
  "Keymap for `cmacs-gsurf-dom-mode'.")

(define-derived-mode cmacs-gsurf-dom-mode special-mode "gsurf-dom"
  "Major mode for the gsurf DOM inspector tree."
  (setq-local truncate-lines t))

;; Under Evil (Doom) `g' is a prefix, `h' a motion and `c' an operator, so
;; none of the inspector keys reached this map.  Install it as an Evil
;; intercept map (see cmacs-evil.el).
(cmacs-evil-setup-mode-map cmacs-gsurf-dom-mode-map 'cmacs-gsurf-dom-mode)

;;;###autoload
(defun cmacs-gsurf-inspect ()
  "Open the DOM inspector for the current gsurf buffer."
  (interactive)
  (unless (cmacs-gsurf-attached-p (current-buffer))
    (user-error "Not a gsurf buffer"))
  (let ((src (current-buffer))
        (buf (get-buffer-create "*gsurf-dom*")))
    (with-current-buffer buf
      (cmacs-gsurf-dom-mode)
      (setq cmacs-gsurf-inspector--source src)
      (cmacs-gsurf-inspector-refresh))
    (pop-to-buffer buf)))

;;;; Console ----------------------------------------------------------

(defconst cmacs-gsurf-inspector--console-capture-js
  "(function(){if(window.__cmacsConsole)return;window.__cmacsConsole=1;\
['log','info','warn','error','debug'].forEach(function(l){var o=console[l];\
console[l]=function(){try{var a=Array.prototype.slice.call(arguments).map(\
function(x){try{return (typeof x==='object')?JSON.stringify(x):String(x);}\
catch(e){return String(x);}});window.cmacs&&window.cmacs.send('console',\
{level:l,text:a.join(' ')});}catch(e){}return o.apply(console,arguments);};});})()"
  "JS that forwards console.* output through window.cmacs.send.")

(defun cmacs-gsurf-inspector--console-buffer (src)
  (let ((name (format "*gsurf-console: %s*" (buffer-name src))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (special-mode)
          (setq cmacs-gsurf-inspector--source src)
          (current-buffer)))))

(defun cmacs-gsurf-inspector--console-append (buf line face)
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (at-end (eobp)))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize line 'face face) "\n"))
        (when at-end (goto-char (point-max)))))))

(defun cmacs-gsurf-inspector--on-console (buffer channel payload)
  "Handler on `cmacs-gsurf-js-message-functions' for the console channel."
  (when (equal channel "console")
    (let ((cbuf (get-buffer (format "*gsurf-console: %s*" (buffer-name buffer)))))
      (when (buffer-live-p cbuf)
        (let* ((level (alist-get 'level payload))
               (text (alist-get 'text payload))
               (face (pcase level
                       ("error" 'error) ("warn" 'warning)
                       (_ 'default))))
          (cmacs-gsurf-inspector--console-append
           cbuf (format "%s: %s" (or level "log") (or text "")) face))))))

(add-hook 'cmacs-gsurf-js-message-functions
          #'cmacs-gsurf-inspector--on-console)

(defun cmacs-gsurf-console-eval (js)
  "Evaluate JS in the inspected page and append the result to the console."
  (interactive "sJS> ")
  (let ((src (cmacs-gsurf-inspector--source))
        (buf (current-buffer)))
    (cmacs-gsurf-inspector--console-append buf (concat "> " js) 'comint-highlight-input)
    (cmacs-gsurf-inspector--eval
     src js
     (lambda (res)
       (cmacs-gsurf-inspector--console-append buf (format "=> %s" res) 'shadow)))))

(defvar cmacs-gsurf-console-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "e") #'cmacs-gsurf-console-eval)
    (define-key m (kbd "g") #'ignore)
    m)
  "Keymap for the gsurf console buffer.")

;; The console buffer is a plain `special-mode' buffer with this map
;; installed by `use-local-map', so pass no mode symbol: `special-mode'
;; itself must not be added to `evil-snipe-disabled-modes'.  Evil still
;; finds the map (it is the local map), so the intercept promotion works.
(cmacs-evil-setup-mode-map cmacs-gsurf-console-mode-map)

;;;###autoload
(defun cmacs-gsurf-console ()
  "Open a console for the current gsurf buffer (streams console.* + eval)."
  (interactive)
  (unless (cmacs-gsurf-attached-p (current-buffer))
    (user-error "Not a gsurf buffer"))
  (let* ((src (current-buffer))
         (buf (cmacs-gsurf-inspector--console-buffer src)))
    ;; Install the capture script (persists across navigation).
    (cmacs-gsurf-add-user-script src cmacs-gsurf-inspector--console-capture-js nil)
    (cmacs-gsurf-run-javascript-async
     src cmacs-gsurf-inspector--console-capture-js #'ignore)
    (with-current-buffer buf
      (use-local-map cmacs-gsurf-console-mode-map))
    (pop-to-buffer buf)))

(provide 'cmacs-gsurf-inspector)
;;; cmacs-gsurf-inspector.el ends here
