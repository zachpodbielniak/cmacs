;;; cmacs-org-ex-bridge.el --- JS ↔ Emacs bridge for web widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Provides a JavaScript-to-Emacs message bridge for org-ex web
;; widgets created via the GObject Introspection path.
;;
;; When a web widget has `:bridge t', JavaScript in the page can
;; call:
;;   window.webkit.messageHandlers.cmacs.postMessage(data)
;;
;; The message is received via WebKitUserContentManager's
;; "script-message-received::cmacs" signal and dispatched to
;; registered Elisp handlers.
;;
;; Usage in an Org file:
;;   #+BEGIN_WIDGET web
;;   :url file:///path/to/page.html
;;   :bridge t
;;   :width 600
;;   :height 400
;;   #+END_WIDGET
;;
;; Register handlers:
;;   (cmacs-org-ex-bridge-register "my-action"
;;     (lambda (data) (message "Got: %s" data)))

;;; Code:

(require 'cl-lib)

(defvar cmacs-org-ex-bridge--handlers (make-hash-table :test 'equal)
  "Hash table mapping action strings to handler functions.
Handlers receive one argument: the message data string.")

(defvar cmacs-org-ex-bridge--connections nil
  "List of active bridge signal connections for cleanup.")

(defun cmacs-org-ex-bridge-register (action handler)
  "Register HANDLER for messages with ACTION.
HANDLER is called with one argument, the message data string.
When JavaScript calls:
  window.webkit.messageHandlers.cmacs.postMessage(
    JSON.stringify({action: \"my-action\", data: \"payload\"}))
the handler registered for \"my-action\" receives \"payload\"."
  (puthash action handler cmacs-org-ex-bridge--handlers))

(defun cmacs-org-ex-bridge-unregister (action)
  "Remove the handler for ACTION."
  (remhash action cmacs-org-ex-bridge--handlers))

(defun cmacs-org-ex-bridge--dispatch (message-str)
  "Dispatch a bridge MESSAGE-STR to the appropriate handler.
MESSAGE-STR is expected to be JSON with \"action\" and \"data\" fields."
  (condition-case err
      (let* ((json (json-parse-string message-str
                                      :object-type 'alist))
             (action (cdr (assq 'action json)))
             (data (cdr (assq 'data json)))
             (handler (gethash action cmacs-org-ex-bridge--handlers)))
        (if handler
            (funcall handler data)
          (message "org-ex bridge: no handler for action \"%s\"" action)))
    (error
     (message "org-ex bridge: failed to parse message: %s"
              (error-message-string err)))))

(defun cmacs-org-ex-bridge-setup (webview)
  "Set up the JS bridge on WEBVIEW (a WebKitWebView GObject).
Registers the \"cmacs\" script message handler and connects the
signal for incoming messages.

JavaScript in the web page can send messages via:
  window.webkit.messageHandlers.cmacs.postMessage(
    JSON.stringify({action: \"my-action\", data: \"payload\"}))"
  (when (and webview (fboundp 'gi-method) (fboundp 'gobject-connect))
    ;; Ensure the JavaScriptCore typelib is loaded so gi-method can
    ;; resolve JSCValue (its C prefix "JSC" differs from the GI
    ;; namespace "JavaScriptCore").
    (gi-require "JavaScriptCore" "4.1")
    (let ((ucm (gi-method webview "get_user_content_manager")))
      (when ucm
        ;; Register the handler name.  WebKit2 4.1 added a world_name
        ;; parameter (nullable) — pass nil for the default world.
        (gi-method ucm "register_script_message_handler" "cmacs" nil)
        ;; Connect the signal — the callback receives the UCM and
        ;; a JSCValue (WebKit2 4.x) as arguments.
        (let ((handle
               (gobject-connect ucm "script-message-received::cmacs"
                                (lambda (js-result &rest _args)
                                  (condition-case nil
                                      (let* ((js-value (gi-method js-result
                                                                  "get_js_value"))
                                             (msg (gi-method js-value
                                                             "to_string")))
                                        (when msg
                                          (cmacs-org-ex-bridge--dispatch
                                           msg)))
                                    (error nil))))))
          (push handle cmacs-org-ex-bridge--connections))))))

(defun cmacs-org-ex-bridge-teardown ()
  "Disconnect all bridge signal connections."
  (dolist (handle cmacs-org-ex-bridge--connections)
    (ignore-errors (gobject-disconnect handle)))
  (setq cmacs-org-ex-bridge--connections nil))

(defun cmacs-org-ex-bridge--widget-hook (webview props)
  "Hook called after web widget creation.
Sets up the bridge if PROPS contains `:bridge t'."
  (when (string-equal-ignore-case
         (or (cdr (assoc "bridge" props)) "") "t")
    (cmacs-org-ex-bridge-setup webview)))

(provide 'cmacs-org-ex-bridge)
;;; cmacs-org-ex-bridge.el ends here
