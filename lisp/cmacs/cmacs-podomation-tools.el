;;; cmacs-podomation-tools.el --- The podomation engine as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Eight of the ten `podomation_*' MCP tools of
;; cmacs/mcp/cmacs-mcp-tools-shell.c, moved onto the capability table
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Wire names,
;; parameter names and the required/optional split are the C ones.
;; Those eight handlers are deleted; the schema to keep is what they
;; published, frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; NOT here, and deliberately: `podomation_eval_dsl' and
;; `podomation_repl_eval'.  Both run podomation DSL a caller supplies,
;; which can do anything a pod can do -- run a program, write a file --
;; and both are in the allowlist's privileged set
;; (cmacs/ai-brigade/cmacs-brigade-allowlist.c).  They stay in C with
;; `eval' and the other tools an agent has to be granted by name.
;;
;; `podomation_emit_event' and `podomation_set_context' take an OBJECT
;; of string values (`cmacs-brigade-tool-types').  The C walked the JSON
;; object and wrote an alist literal, skipping members whose value was
;; not a string; the body here receives an alist and keeps the pairs
;; whose value is a string.  The engine wants string keys, so the symbol
;; keys the registry delivers are turned back into strings.
;;
;; What differs from the C, on purpose:
;;
;;   - No argument is spliced into Lisp source.
;;
;;   - A failure is signalled instead of returned as text.
;;
;; What does NOT differ: the result text.  The C sent every form through
;; `cmacs_dispatch_eval', which prints its value with `prin1' -- so
;; "engine started" reached the client inside double quotes, and the
;; pod list as the printed form of a printed form.  A client may be
;; comparing against exactly that, so `cmacs-podomation-tools--printed'
;; reproduces it.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-podomation-emit-event "cmacs-podomation.c"
                  (event-name data))
(declare-function cmacs-podomation-list-pods "cmacs-podomation.c" ())
(declare-function cmacs-podomation-stats "cmacs-podomation.c" ())
(declare-function cmacs-podomation-list-modules "cmacs-podomation.c" ())
(declare-function cmacs-podomation-load-file "cmacs-podomation.c" (file))
(declare-function cmacs-podomation-set-context "cmacs-podomation.c" (context))
(declare-function cmacs-podomation-reload "cmacs-podomation.c" ())
(declare-function cmacs-podomation-start "cmacs-podomation.c" ())
(declare-function cmacs-podomation-stop "cmacs-podomation.c" ())
(declare-function cmacs-podomation-running-p "cmacs-podomation.c" ())
(declare-function cmacs-podomation-run-pod "cmacs-podomation.c"
                  (name &optional event data))

(defun cmacs-podomation-tools--printed (value)
  "Return VALUE as `cmacs_dispatch_eval' returned it: printed by `prin1'."
  (prin1-to-string value))

(defun cmacs-podomation-tools--string-pairs (object)
  "Return OBJECT, an `object' argument, as an alist of (STRING . STRING).
Members whose value is not a string are left out, as the C's
`podomation_data_alist' left them out.  nil for no members."
  (delq nil
        (mapcar (lambda (cell)
                  (and (stringp (cdr cell))
                       (cons (format "%s" (car cell)) (cdr cell))))
                object)))


;;;; Reading

(cmacs-brigade-deftool podomation-list-pods
  "List active podomation pods and their health status."
    ()
  :group 'podomation
  :example "emacsctl tool podomation list-pods"
  (cmacs-podomation-tools--printed
   (prin1-to-string (cmacs-podomation-list-pods))))

(cmacs-brigade-deftool podomation-stats
  "Return podomation engine statistics: events dispatched, \
handlers called/failed, pipe-chains executed, and start time."
    ()
  :group 'podomation
  :example "emacsctl tool podomation stats"
  (cmacs-podomation-tools--printed
   (prin1-to-string (cmacs-podomation-stats))))

(cmacs-brigade-deftool podomation-list-modules
  "List the loaded podomation modules (available event sources \
and actions)."
    ()
  :group 'podomation
  (cmacs-podomation-tools--printed
   (prin1-to-string (cmacs-podomation-list-modules))))


;;;; Driving the engine
;;
;; All destructive: an event, a context value and a loaded file each
;; decide what the pods do next, and what a pod does is up to its
;; author.

(cmacs-brigade-deftool podomation-emit-event
  "Emit an event into the podomation automation engine, optionally \
with a data object of string values."
    ((event string "Event name, e.g. on_buffer_save")
     (data object "Event payload (string values)" :optional t))
  :group 'podomation :destructive t
  (unless (stringp event)
    (error "Missing required argument: event"))
  (cmacs-podomation-emit-event event
                               (cmacs-podomation-tools--string-pairs data))
  (cmacs-podomation-tools--printed (format "emitted %s" event)))

(cmacs-brigade-deftool podomation-set-context
  "Set the engine context variables (an object of string values) \
exposed to the DSL as {context->key} bindings."
    ((context object "Context key/value pairs (string values)"))
  :group 'podomation :destructive t
  (cmacs-podomation-set-context
   (cmacs-podomation-tools--string-pairs context))
  (cmacs-podomation-tools--printed "context set"))

(cmacs-brigade-deftool podomation-load-file
  "Load and parse a .pod DSL file into the automation engine."
    ((file string "Path to a .pod DSL file"))
  :group 'podomation :destructive t
  (unless (stringp file)
    (error "Missing required argument: file"))
  (let ((path (expand-file-name file)))
    (cmacs-podomation-load-file path)
    (cmacs-podomation-tools--printed (format "loaded %s" path))))

(cmacs-brigade-deftool podomation-reload
  "Hot-reload the podomation engine configuration."
    ()
  :group 'podomation :destructive t
  (cmacs-podomation-reload)
  (cmacs-podomation-tools--printed "engine reloaded"))

(cmacs-brigade-deftool podomation-control
  "Control the podomation engine. action is one of \"start\", \
\"stop\", \"status\", or \"run\" -- run pod's rules now, as if \
its source had fired event (default: the pod's only bound event)."
    ((action string "Lifecycle action, or run a pod"
             :enum ("start" "stop" "status" "run"))
     (pod string "Pod name, for action run" :optional t)
     (event string "Event to fire, for action run (optional)" :optional t))
  :group 'podomation :destructive t
  (pcase action
    ("start" (cmacs-podomation-start)
     (cmacs-podomation-tools--printed "engine started"))
    ("stop" (cmacs-podomation-stop)
     (cmacs-podomation-tools--printed "engine stopped"))
    ("status" (cmacs-podomation-tools--printed
               (if (cmacs-podomation-running-p) "running" "stopped")))
    ("run"
     (unless (and (stringp pod) (not (string-empty-p pod)))
       (error "action run needs a pod"))
     (cmacs-podomation-tools--printed
      (format "ran %s %s" pod
              (cmacs-podomation-run-pod
               pod (and (stringp event) (> (length event) 0) event)))))
    (_ (error "action must be one of: start, stop, status, run"))))

(provide 'cmacs-podomation-tools)

;;; cmacs-podomation-tools.el ends here
