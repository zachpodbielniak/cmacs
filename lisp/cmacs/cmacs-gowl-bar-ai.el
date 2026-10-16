;;; cmacs-gowl-bar-ai.el --- cmacs-ai for gowl bar widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of the gowl bar's AI contract (gowl's
;; modules/bar/bar-ai.c, docs/bar.org "Asking a language model").
;;
;; A bar widget with `ai-backend: cmacs' runs
;;
;;   emacsctl eval '(cmacs-gowl-bar-ai-run WIDGET ID SYSTEM PROMPT PROVIDER MODEL)'
;;
;; from one of the bar's worker threads.  That call has to return AT
;; ONCE: under `cmacs --gowl' Emacs's thread is the compositor's, and a
;; model call made synchronously here would freeze the desktop for as
;; long as the model takes.  So it starts an asynchronous cmacs-ai
;; stream and returns t; the answer travels back the other way, as
;; widget settings pushed with `gowl-bar-configure':
;;
;;   WIDGET.ai-id     the ID the widget asked with (it ignores others)
;;   WIDGET.ai-state  waiting | streaming | done | error
;;   WIDGET.ai-text   the answer so far
;;   WIDGET.ai-error  why, when the state is error
;;
;; Pushes are throttled (`cmacs-gowl-bar-ai-push-interval'): each one
;; re-lays the bar out, and a fast model emits far more deltas than
;; anyone can read.
;;
;; Every provider configured in cmacs-ai -- including named
;; `cmacs-ai-openai-compatible-endpoints' -- is available to the bar
;; this way, with nothing configured twice.
;;
;; `cmacs-gowl-bar-push' is the generic "set these settings on this
;; widget" helper the other bar integrations (meeting notes, the
;; assistant, webmail) share.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-bar-configure "cmacs-gowl.c" (alist))
(declare-function cmacs-ai--ensure "cmacs-ai" ())
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))
(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())

(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)
(defvar cmacs-ai-openai-compatible-endpoints)

(defgroup cmacs-gowl-bar nil
  "cmacs integrations for gowl bar widgets."
  :group 'cmacs
  :prefix "cmacs-gowl-bar-")

(defcustom cmacs-gowl-bar-ai-provider nil
  "cmacs-ai provider for bar widgets that do not name one.

A symbol, or nil for `cmacs-ai-textops-provider' -- the provider the
right-click AI actions use, which defaults to a CLI provider so a fresh
session with no API key in the environment still works."
  :type '(choice (const :tag "Same as the AI menu" nil) symbol))

(defcustom cmacs-gowl-bar-ai-model nil
  "Model for bar widgets that do not name one; nil for the provider's."
  :type '(choice (const :tag "Provider default" nil) string))

(defcustom cmacs-gowl-bar-ai-push-interval 0.25
  "Least time, in seconds, between two pushes of a streaming answer.
The final push is never delayed."
  :type 'number)

(defcustom cmacs-gowl-bar-ai-max-chars 200000
  "Longest answer pushed to a widget; the rest is cut with a note."
  :type 'integer)

(defvar cmacs-gowl-bar-push-function #'cmacs-gowl-bar--configure
  "Function that applies an alist of bar settings.
Tests rebind it; everything else leaves it alone.")

(defun cmacs-gowl-bar--configure (alist)
  "Hand ALIST to the running bar, when there is one."
  (when (fboundp 'gowl-bar-configure)
    (gowl-bar-configure alist)))

;;;###autoload
(defun cmacs-gowl-bar-push (widget alist)
  "Set the settings in ALIST on the bar widget named WIDGET.

ALIST maps setting names (strings) to values (strings).  Each is sent
as both `WIDGET.KEY' and `bottom-WIDGET.KEY', so the widget is reached
whichever bar it sits in; a key that reaches no widget is dropped by
the bar silently.  Never signals: a bar that is not running is not an
error for the code pushing to it."
  (let (out)
    (dolist (cell alist)
      (let ((key (car cell))
            (val (or (cdr cell) "")))
        (push (cons (format "%s.%s" widget key) val) out)
        (push (cons (format "bottom-%s.%s" widget key) val) out)))
    (condition-case err
        (funcall cmacs-gowl-bar-push-function (nreverse out))
      (error
       (message "cmacs-gowl-bar: could not push to %s: %s"
                widget (error-message-string err))))
    nil))

;;;; The AI contract --------------------------------------------------

(defun cmacs-gowl-bar-ai--provider (name)
  "The provider symbol for NAME, a string from the bar, or the default."
  (cond
   ((and (stringp name) (not (string-empty-p name))) (intern name))
   (cmacs-gowl-bar-ai-provider)
   ((boundp 'cmacs-ai-textops-provider) cmacs-ai-textops-provider)
   (t nil)))

(defun cmacs-gowl-bar-ai--model (provider-name model-name)
  "The model for a request naming PROVIDER-NAME and MODEL-NAME.

Both are strings from the bar, possibly empty.  A model default belongs
to its provider -- `sonnet' means nothing to ollama -- so the AI menu's
model is only borrowed along with the AI menu's provider, never for a
provider the widget or `cmacs-gowl-bar-ai-provider' named."
  (cond
   ((and (stringp model-name) (not (string-empty-p model-name))) model-name)
   ((and (stringp provider-name) (not (string-empty-p provider-name))) nil)
   (cmacs-gowl-bar-ai-model)
   (cmacs-gowl-bar-ai-provider nil)
   ((boundp 'cmacs-ai-textops-model) cmacs-ai-textops-model)
   (t nil)))

(defun cmacs-gowl-bar-ai--clip (text)
  "TEXT, cut to `cmacs-gowl-bar-ai-max-chars'."
  (if (> (length text) cmacs-gowl-bar-ai-max-chars)
      (concat (substring text 0 cmacs-gowl-bar-ai-max-chars)
              "\n[... cut: the answer was too long for the bar]")
    text))

;;;###autoload
(defun cmacs-gowl-bar-ai-run (widget id system prompt &optional provider model)
  "Answer PROMPT for the bar widget WIDGET, asynchronously.

ID is the widget's request id, echoed back so it can ignore answers to
requests it has moved past.  SYSTEM is a system prompt or nil.
PROVIDER and MODEL are strings or nil for the defaults
\(`cmacs-gowl-bar-ai-provider', `cmacs-gowl-bar-ai-model').

Returns t at once; the answer arrives as WIDGET.ai-* settings (see the
Commentary).  Never prompts and never blocks -- this runs from emacsctl,
on the compositor's thread under --gowl."
  (unless (and (stringp widget) (stringp id) (stringp prompt))
    (error "cmacs-gowl-bar-ai-run: WIDGET, ID and PROMPT must be strings"))
  (let* ((prov (cmacs-gowl-bar-ai--provider provider))
         (mdl (cmacs-gowl-bar-ai--model provider model))
         (acc nil)
         (pair nil)
         (last-push 0.0)
         (timer nil)
         (finished nil))
    (cl-labels
        ((push-state (state &optional text err)
           (cmacs-gowl-bar-push
            widget
            (append (list (cons "ai-id" id)
                          (cons "ai-state" state))
                    (when text (list (cons "ai-text"
                                           (cmacs-gowl-bar-ai--clip text))))
                    (when err (list (cons "ai-error" err))))))
         (text-so-far ()
           (apply #'concat (reverse acc)))
         (flush ()
           (setq timer nil)
           (unless finished
             (setq last-push (float-time))
             (push-state "streaming" (text-so-far))))
         (finish (state &optional final err)
           (unless finished
             (setq finished t)
             (when timer (cancel-timer timer) (setq timer nil))
             (push-state state final err)
             (when pair
               (let ((p pair))
                 ;; Not from inside the stream's own callback.
                 (run-at-time 0 nil
                              (lambda ()
                                (ignore-errors
                                  (cmacs-ai-free-session p)))))))))
      (push-state "waiting" "")
      (condition-case err
          (progn
            (require 'cmacs-ai)
            (require 'cmacs-ai-textops nil t)
            (cmacs-ai--ensure)
            (setq pair (cmacs-ai-make-session prov mdl
                                              (and (stringp system)
                                                   (not (string-empty-p system))
                                                   system)))
            (cmacs-ai-chat-stream
             (cdr pair) prompt
             (lambda (payload)
               (pcase (car-safe payload)
                 (:delta
                  (when (cadr payload)
                    (push (cadr payload) acc)
                    ;; Throttle: push now if it has been long enough,
                    ;; else make sure one push is pending.
                    (cond
                     ((>= (- (float-time) last-push)
                          cmacs-gowl-bar-ai-push-interval)
                      (flush))
                     ((null timer)
                      (setq timer (run-at-time
                                   cmacs-gowl-bar-ai-push-interval nil
                                   #'flush))))))
                 (:end
                  (let ((final (plist-get (cdr payload) :text))
                        (streamed (text-so-far)))
                    (finish "done"
                            (string-trim-right
                             (if (string-empty-p streamed)
                                 (or final "")
                               streamed)))))
                 (:error
                  (finish "error" nil (or (cadr payload) "stream error")))))))
        (error
         (finish "error" nil (error-message-string err)))))
    t))

;;;###autoload
(defun cmacs-gowl-bar-ai-provider-names ()
  "Every provider name cmacs-ai can be asked for, as strings.
Named `cmacs-ai-openai-compatible-endpoints' are included, since they
are providers in every sense."
  (let ((names (when (fboundp 'cmacs-ai-providers)
                 (ignore-errors
                   (mapcar (lambda (p) (if (symbolp p) (symbol-name p)
                                         (format "%s" p)))
                           (cmacs-ai-providers)))))
        (endpoints nil))
    (when (boundp 'cmacs-ai-openai-compatible-endpoints)
      (dolist (ep cmacs-ai-openai-compatible-endpoints)
        (let ((n (car-safe ep)))
          (when n (push (if (symbolp n) (symbol-name n) (format "%s" n))
                        endpoints)))))
    ;; Built-in providers first, in cmacs-ai's order, then the named
    ;; endpoints in the order they were configured.
    (delete-dups (append names (nreverse endpoints)))))

;;;###autoload
(defun cmacs-gowl-bar-ai-push-providers (widget)
  "Tell the bar widget WIDGET which providers cmacs-ai offers.
Pushes `ai-providers' (comma-separated) and `ai-default-provider'."
  (cmacs-gowl-bar-push
   widget
   (list (cons "ai-providers"
               (mapconcat #'identity (cmacs-gowl-bar-ai-provider-names) ","))
         (cons "ai-default-provider"
               (let ((p (cmacs-gowl-bar-ai--provider nil)))
                 (if p (format "%s" p) ""))))))

(provide 'cmacs-gowl-bar-ai)

;;; cmacs-gowl-bar-ai.el ends here
