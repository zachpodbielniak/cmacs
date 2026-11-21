;;; cmacs-rig-undo-tests.el --- Undo for agent actions, end to end  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The action log against a real session: a private `cmacs --gowl'
;; (cmacs-rig.el), its real MCP socket, a real Wayland window.  An MCP
;; client edits a buffer with `edit_buffer' and moves a window with
;; `gowl_set_client_geometry'; `action_log' lists both as that client's;
;; `action_undo' takes the window back and `cmacs-brigade-undo', run as
;; the person at the keyboard, takes the edit back.  A second case edits
;; the agent's text as the user and checks the undo refuses.
;;
;; Like every rig file this skips without CMACS_RIG=1:
;;
;;   CMACS_RIG=1 src/emacs --batch -Q -L lisp/cmacs -L test/cmacs \
;;     --eval '(setq load-prefer-newer t)' -l ert \
;;     -l test/cmacs/cmacs-rig-undo-tests.el -f ert-run-tests-batch-and-exit
;;
;; The child loads lisp/cmacs with `load-prefer-newer', so the undo code
;; is exercised from source even before the tree is rebuilt.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs)
;; By path: test/cmacs is not on `load-path' under `make check'.
(require 'cmacs-rig
         (expand-file-name
          "cmacs-rig"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

(defvar cmacs-rig-undo-tests--rig nil
  "The rig this file's tests share.")

(defun cmacs-rig-undo-tests--rig ()
  "The shared rig, started on first use; skip when there can be none."
  (unless (getenv "CMACS_RIG")
    (ert-skip "rig tests run only with CMACS_RIG=1 (`just test-rig')"))
  (when-let* ((why (cmacs-rig-available-p)))
    (ert-skip (format "no rig here: %s" why)))
  (unless (and cmacs-rig-undo-tests--rig
               (cmacs-rig-alive-p cmacs-rig-undo-tests--rig))
    (setq cmacs-rig-undo-tests--rig
          (condition-case err (cmacs-rig-start)
            (cmacs-rig-error
             (ert-skip (format "the rig would not start: %s" (cadr err)))))))
  (let ((rig cmacs-rig-undo-tests--rig))
    (unless (cmacs-rig-eval rig '(fboundp 'cmacs-brigade-undo--begin))
      (ert-skip "the child has no action log (cmacs-brigade-undo not loaded)"))
    ;; Each test starts from an empty log.
    (cmacs-rig-eval rig '(progn (cmacs-brigade-undo-clear) t))
    rig))

(add-hook 'kill-emacs-hook
          (lambda ()
            (when cmacs-rig-undo-tests--rig
              (ignore-errors (cmacs-rig-stop cmacs-rig-undo-tests--rig)))))

(defun cmacs-rig-undo-tests--buffer-text (rig name)
  "The text of buffer NAME in RIG."
  (cmacs-rig-eval rig `(with-current-buffer ,name
                         (buffer-substring-no-properties
                          (point-min) (point-max)))))

(defun cmacs-rig-undo-tests--geometry (rig id)
  "The geometry gowl reports for window ID in RIG."
  (alist-get 'geometry (cmacs-rig-client rig id)))

(ert-deftest cmacs-rig-undo-test-mcp-edit-and-geometry ()
  "An MCP client's edit and window move are logged as its own and undone."
  (let* ((rig (cmacs-rig-undo-tests--rig))
         (name "rig-undo-buffer"))
    (unwind-protect
        (progn
          (cmacs-rig-eval rig `(with-current-buffer (get-buffer-create ,name)
                                 (erase-buffer)
                                 (buffer-enable-undo)
                                 (insert "alpha beta gamma")
                                 (undo-boundary)
                                 t))
          ;; The agent's edit, over the wire.
          (cmacs-rig-tool-text rig "edit_buffer"
                               (list :buffer name :old_string "beta"
                                     :new_string "BETA"))
          (should (equal (cmacs-rig-undo-tests--buffer-text rig name)
                         "alpha BETA gamma"))
          ;; The agent's window move, over the wire, of a floating window
          ;; with a known place.
          (let* ((field (and (cmacs-rig-field-client)
                             (cmacs-rig-spawn-field rig
                                                    :title "rig-undo-window")))
                 (id (plist-get field :id))
                 (before nil))
            (when id
              (cmacs-rig-eval
               rig `(let ((c (cl-find-if
                              (lambda (c)
                                (eql ,id (alist-get 'id (gowl-client-info c))))
                              (gowl-list-clients))))
                      (gowl-set-client-floating c t)
                      (gowl-client-set-geometry c 40 40 300 200)
                      t))
              (setq before (cmacs-rig-wait-for
                            rig `(let ((g (alist-get
                                           'geometry
                                           (gowl-client-info
                                            (cl-find-if
                                             (lambda (c)
                                               (eql ,id (alist-get
                                                         'id (gowl-client-info c))))
                                             (gowl-list-clients))))))
                                   (and (equal g '(40 40 300 200)) g))))
              (cmacs-rig-tool-text rig "gowl_set_client_geometry"
                                   (list :pattern "rig-undo-window" :by "title"
                                         :x 120 :y 90 :width 400 :height 260))
              (should (equal (cmacs-rig-undo-tests--geometry rig id)
                             '(120 90 400 260))))
            ;; Both are this client's, in its own log.
            (let ((log (cmacs-rig-tool-text rig "action_log")))
              (should (string-match-p "edit_buffer \\[done\\]" log))
              (when id
                (should (string-match-p "gowl_set_client_geometry \\[done\\]"
                                        log))))
            ;; action_undo: the newest of the client's own, the window.
            (when id
              (should (string-match-p
                       "Undid #2 gowl_set_client_geometry"
                       (cmacs-rig-tool-text rig "action_undo")))
              (should (equal (cmacs-rig-undo-tests--geometry rig id) before)))
            ;; The command, as the user: the edit.
            (cmacs-rig-do rig '(cmacs-brigade-undo))
            (should (equal (cmacs-rig-undo-tests--buffer-text rig name)
                           "alpha beta gamma"))
            ;; And the edit was ONE change group in the buffer's own undo
            ;; list: C-/ there re-applies it in one step.
            (should (equal
                     (cmacs-rig-eval
                      rig `(with-current-buffer ,name
                             (primitive-undo
                              1 (copy-sequence
                                 (cmacs-brigade-undo--skip-boundaries
                                  buffer-undo-list)))
                             (buffer-string)))
                     "alpha BETA gamma"))))
      (ignore-errors
        (cmacs-rig-eval rig `(let ((b (get-buffer ,name)))
                               (when b
                                 (with-current-buffer b
                                   (set-buffer-modified-p nil))
                                 (kill-buffer b))
                               t))))))

(ert-deftest cmacs-rig-undo-test-stale-refused-over-mcp ()
  "After the user edits the agent's text, `action_undo' refuses and says why."
  (let* ((rig (cmacs-rig-undo-tests--rig))
         (name "rig-undo-stale"))
    (unwind-protect
        (progn
          (cmacs-rig-eval rig `(with-current-buffer (get-buffer-create ,name)
                                 (erase-buffer)
                                 (buffer-enable-undo)
                                 (insert "keep this")
                                 t))
          (cmacs-rig-tool-text rig "edit_buffer"
                               (list :buffer name :old_string "keep"
                                     :new_string "agent"))
          ;; The user, at the keyboard, changes what the agent wrote.
          (cmacs-rig-do rig `(with-current-buffer ,name
                               (goto-char (point-min))
                               (search-forward "agent")
                               (replace-match "user" t t)))
          (let ((err (should-error
                      (cmacs-rig-tool-text rig "action_undo")
                      :type 'cmacs-rig-tool-error)))
            (should (string-match-p "was changed since"
                                    (format "%s" (cdr err)))))
          (should (equal (cmacs-rig-undo-tests--buffer-text rig name)
                         "user this")))
      (ignore-errors
        (cmacs-rig-eval rig `(let ((b (get-buffer ,name)))
                               (when b
                                 (with-current-buffer b
                                   (set-buffer-modified-p nil))
                                 (kill-buffer b))
                               t))))))

(provide 'cmacs-rig-undo-tests)

;;; cmacs-rig-undo-tests.el ends here
