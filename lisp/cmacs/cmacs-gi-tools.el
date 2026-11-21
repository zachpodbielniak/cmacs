;;; cmacs-gi-tools.el --- The GI inspection tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The three read-only tools of cmacs/mcp/cmacs-mcp-tools-gi.c, written
;; once (doc_org/cmacs/cmacs-capability.org has the recipe).  `gi_call'
;; is not here: calling an arbitrary introspected function is calling
;; arbitrary C, which puts it in the privileged set.
;;
;; `gi_list_functions' calls the `gi-list-functions' primitive, as the C
;; did through `cmacs_dispatch_gi_list_functions', and returns its names
;; one per line, unprinted, as the C did.
;;
;; `gi_list_namespaces' and `gi_describe' call `gi-loaded-namespaces'
;; and `gi-describe'.  Those are the functions the C handlers named, and
;; at the time of writing no file in the tree defines either, so both
;; tools have been answering "void-function" on every call.  They are
;; registered anyway, so the names keep resolving and start working the
;; day the functions exist, and until then they say plainly what is
;; missing instead of leaking a Lisp error.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function gi-list-functions "cmacs-gi.c" (namespace))

(defun cmacs-gi-tools--namespace (namespace)
  "Return NAMESPACE, or signal when it is not a GI namespace name.
A namespace is an identifier (Gtk, Gio, GLib); checking it keeps
arbitrary text out of the typelib lookup."
  (unless (and (stringp namespace)
               (string-match-p "\\`[A-Za-z][A-Za-z0-9_]*\\'" namespace))
    (error "Missing or malformed argument: namespace"))
  namespace)

(defun cmacs-gi-tools--call (function &rest args)
  "Apply FUNCTION, a symbol, to ARGS, or signal that this build lacks it."
  (unless (fboundp function)
    (error "`%s' is not defined in this build" function))
  (apply function args))

(cmacs-brigade-deftool gi-list-namespaces
  "List loaded GObject Introspection namespaces."
    ()
  :group 'gi
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat #'identity
              (cmacs-gi-tools--call 'gi-loaded-namespaces)
              "\n")))

(cmacs-brigade-deftool gi-describe
  "Describe a type or function in a GI namespace."
    ((namespace string "GI namespace")
     (symbol string "Type or function name"))
  :group 'gi
  (require 'cmacs-core-tools)
  (unless (and (stringp symbol) (not (string-empty-p symbol)))
    (error "Missing required arguments: namespace, symbol"))
  (cmacs-core-tools-print
   (cmacs-gi-tools--call 'gi-describe
                         (cmacs-gi-tools--namespace namespace)
                         symbol)))

(cmacs-brigade-deftool gi-list-functions
  "List all functions in a GI namespace."
    ((namespace string "GI namespace"))
  :group 'gi
  :example "emacsctl tool gi list-functions --namespace GLib"
  (let ((names (seq-filter #'stringp
                           (cmacs-gi-tools--call
                            'gi-list-functions
                            (cmacs-gi-tools--namespace namespace)))))
    (if names
        (mapconcat #'identity names "\n")
      "(no functions)")))

(provide 'cmacs-gi-tools)

;;; cmacs-gi-tools.el ends here
