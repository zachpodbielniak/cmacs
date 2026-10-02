;;; cmacs-gowl-grab-tests.el --- Screen text, colours and their MCP tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-screen-text', `cmacs-gowl-pixel-color' and
;; `cmacs-gowl-command' with the gowl primitives stubbed; the agent-facing
;; macro helpers; the brigade gate's view of the new tools; and, in a
;; second cmacs on gowl's headless backend, the new MCP tools spoken to
;; over a scoped MCP socket exactly as an agent would -- plus the
;; clipboard regression that hung Emacs: a history entry put back on the
;; clipboard, then read from Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-grab)
(require 'cmacs-gowl-macro)

(defconst cmacs-gowl-grab-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time.")

;;;; Stubbed

(defmacro cmacs-gowl-grab-tests--with-gowl (replies &rest body)
  "BODY with gowl stubbed; REPLIES maps a command line to its reply.
Inside BODY, `sent' lists the command lines, `clipboard' what was set."
  (declare (indent 1))
  `(let ((sent nil) (clipboard nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (setq sent (append sent (list line)))
                  (funcall ,replies line)))
               ((symbol-function 'gowl-clipboard-set)
                (lambda (text &rest _) (setq clipboard text) t)))
       ,@body)))

(ert-deftest cmacs-gowl-grab-test-command ()
  "OK is stripped, ERROR and silence are errors."
  (cmacs-gowl-grab-tests--with-gowl
      (lambda (line)
        (pcase line
          ("good" "OK fine")
          ("bare" "OK")
          ("bad" "ERROR it broke")
          (_ nil)))
    (should (equal (cmacs-gowl-command "good") "fine"))
    (should (equal (cmacs-gowl-command "bare") ""))
    (should (equal (cadr (should-error (cmacs-gowl-command "bad")))
                   "it broke"))
    (should (string-match-p "No gowl module answers `nobody'"
                            (cadr (should-error
                                   (cmacs-gowl-command "nobody args")))))))

(ert-deftest cmacs-gowl-grab-test-pixel-color ()
  "The capture is B, G, R, A in memory; the answer is #rrggbb."
  (cmacs-gowl-grab-tests--with-gowl (lambda (_) nil)
    (cl-letf (((symbol-function 'gowl-screenshot-region)
               (lambda (&rest _)
                 (list 1 1 (unibyte-string #x99 #x66 #x33 #xff)))))
      (should (equal (cmacs-gowl-pixel-color 10 20) "#336699"))
      (should-not clipboard))
    (cl-letf (((symbol-function 'gowl-screenshot-region)
               (lambda (&rest _) nil)))
      (should-error (cmacs-gowl-pixel-color 10 20)))))

(ert-deftest cmacs-gowl-grab-test-screen-text ()
  "The screenshot module's OCR command runs on a private PNG that is
gone afterwards; the language is an argument; COPY puts the text on
the clipboard and nothing else does."
  (let* ((dir (make-temp-file "cmacs-grab-test-" t))
         (args-file (expand-file-name "args" dir))
         (fake (expand-file-name "fake-ocr" dir))
         (process-environment (cons (concat "XDG_RUNTIME_DIR=" dir)
                                    process-environment))
         (saved nil))
    (unwind-protect
        (progn
          (with-temp-file fake
            (insert "#!/bin/sh\n"
                    "printf '%s|%s|%s|%s' \"$1\" \"$2\" \"$3\" \"$4\" > '"
                    args-file "'\n"
                    "test -s \"$1\" || exit 3\n"
                    "printf '  Words on the screen \\n\\f'\n"))
          (set-file-modes fake #o755)
          (cmacs-gowl-grab-tests--with-gowl
              (lambda (line)
                (when (equal line "screenshot-ocr-config")
                  (format "OK {\"command\":\"%s\",\"language\":\"eng\"}"
                          fake)))
            (cl-letf (((symbol-function 'gowl-screenshot-region)
                       (lambda (&rest _) (list 2 2 (make-string 16 0))))
                      ((symbol-function 'gowl-screenshot-save-png)
                       (lambda (_w _h _d path)
                         (setq saved path)
                         (with-temp-file path (insert "PNG"))
                         t)))
              (should (equal (cmacs-gowl-screen-text 0 0 10 10)
                             "Words on the screen"))
              (should-not clipboard)
              (should saved)
              (should (string-prefix-p dir saved))
              (should-not (file-exists-p saved))
              (let ((a (split-string (with-temp-buffer
                                       (insert-file-contents args-file)
                                       (buffer-string))
                                     "|")))
                (should (equal (cdr a) '("stdout" "-l" "eng"))))
              (should (equal (cmacs-gowl-screen-text 0 0 10 10 "deu" t)
                             "Words on the screen"))
              (should (equal clipboard "Words on the screen"))
              (should (string-suffix-p "|deu"
                                       (with-temp-buffer
                                         (insert-file-contents args-file)
                                         (buffer-string))))
              (should-error (cmacs-gowl-screen-text 0 0 0 10)))))
      (delete-directory dir t))))

(ert-deftest cmacs-gowl-grab-test-screen-text-defaults ()
  "With no screenshot module answering, it is tesseract/eng."
  (cmacs-gowl-grab-tests--with-gowl (lambda (_) nil)
    (should (equal (cmacs-gowl-grab--ocr-config) '("tesseract" . "eng")))))

(ert-deftest cmacs-gowl-grab-test-agent-macro-lines ()
  "The agent forms: record asks for consent, voice can be dry."
  (cl-letf (((symbol-function 'cmacs-gowl-macro--command)
             (lambda (line) line)))
    (should (equal (cmacs-gowl-macro-record-command "start" "my mac" t)
                   "macro-record --require-consent start my\\ mac"))
    (should (equal (cmacs-gowl-macro-record-command "status" nil t)
                   "macro-record --require-consent status"))
    ;; a name only means something to start
    (should (equal (cmacs-gowl-macro-record-command "stop" "x")
                   "macro-record stop"))
    (should-error (cmacs-gowl-macro-record-command "explode"))
    (should (equal (cmacs-gowl-macro-voice-text "pip corner\n25" t)
                   "macro-voice-match --dry-run pip corner 25"))
    (should (equal (cmacs-gowl-macro-command "macro-list") "macro-list"))))

(ert-deftest cmacs-gowl-grab-test-brigade-privileges ()
  "The tools that watch input, run code or read the clipboard history
are privileged: named, they work; `*' does not sweep them in.  Reading
the screen is not -- screenshots never were."
  (skip-unless (fboundp 'cmacs-brigade-tool-privileged-p))
  (dolist (tool '("gowl_macro_record" "gowl_macro_run"
                  "gowl_macro_voice_match" "gowl_clipboard_list"
                  "gowl_clipboard_entry" "gowl_clipboard_copy"))
    (should (cmacs-brigade-tool-privileged-p tool)))
  (dolist (tool '("gowl_screen_text" "gowl_pick_color" "gowl_macro_list"
                  "gowl_macro_status" "gowl_macro_voice_status"))
    (should-not (cmacs-brigade-tool-privileged-p tool))))

;;;; The MCP tools, end to end

(defconst cmacs-gowl-grab-tests--tools
  "gowl_screen_text,gowl_pick_color,gowl_macro_record,gowl_macro_run,\
gowl_macro_list,gowl_macro_status,gowl_macro_voice_match,\
gowl_macro_voice_status,gowl_clipboard_list,gowl_clipboard_entry,\
gowl_clipboard_copy"
  "The tools the child's scoped socket serves (named, so privileged
ones are included).")

(defconst cmacs-gowl-grab-tests--headless-form
  `(progn
     (require 'cl-lib)
     (require 'json)
     (gowl-start)
     (require 'cmacs-gowl-grab)
     (require 'cmacs-gowl-macro)
     (defvar test-ran nil)
     (defun test-wait (pred &optional n)
       (let ((i 0))
         (while (and (not (funcall pred)) (< i (or n 100)))
           (sit-for 0.05)
           (setq i (1+ i)))
         (funcall pred)))
     ;; the screenshot and clipboard modules, as cmacs --gowl loads them
     (dolist (m '("screenshot" "clipboard"))
       (unless (gowl-run-command
                (if (equal m "clipboard") "clipboard-list"
                  "screenshot-ocr-config"))
         (gowl-enable-module m)))
     ;; a stand-in for tesseract
     (let ((fake (expand-file-name "fake-ocr" default-directory)))
       (with-temp-file fake
         (insert "#!/bin/sh\nprintf 'An agent read this\\n'\n"))
       (set-file-modes fake #o755)
       (gowl-configure-module "screenshot" (list (cons "ocr-command" fake))))
     (cmacs-gowl-macro-define
      "say-hi" (lambda (&rest args)
                 (setq test-ran (cons cmacs-gowl-macro-trigger args))))
     ;; The MCP socket an agent would get, serving these tools
     (let* ((path (cmacs-brigade-scope-open ,cmacs-gowl-grab-tests--tools))
            (out "")
            (id 1)
            (proc (make-network-process
                   :name "grab-mcp" :family 'local :service path
                   :noquery t :coding 'utf-8-unix
                   :filter (lambda (_p s) (setq out (concat out s))))))
       (cl-flet*
           ((send (method params)
              (setq id (1+ id))
              (process-send-string
               proc (concat (json-encode `((jsonrpc . "2.0") (id . ,id)
                                           (method . ,method)
                                           (params . ,params)))
                            "\n"))
              (let ((want (format "\"id\":%d," id))
                    (deadline (+ (float-time) 20)))
                (while (and (< (float-time) deadline)
                            (not (string-match-p want out)))
                  (accept-process-output proc 0.05)
                  (sit-for 0.02))
                (let* ((line (seq-find (lambda (l) (string-match-p want l))
                                       (split-string out "\n" t))))
                  (unless line (error "No reply to %s" method))
                  (json-parse-string line :object-type 'alist
                                     :false-object nil :null-object nil))))
            (call (tool args)
              (let* ((r (send "tools/call"
                              ;; no arguments is {}, never null
                              `((name . ,tool)
                                (arguments . ,(or args (make-hash-table))))))
                     (res (alist-get 'result r)))
                (cons (alist-get 'isError res)
                      (mapconcat (lambda (c) (or (alist-get 'text c) ""))
                                 (alist-get 'content res) "")))))
         (process-send-string
          proc
          (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                  "\"params\":{\"protocolVersion\":\"2024-11-05\","
                  "\"capabilities\":{},\"clientInfo\":{\"name\":\"ert\","
                  "\"version\":\"0\"}}}\n"
                  "{\"jsonrpc\":\"2.0\",\"method\":"
                  "\"notifications/initialized\"}\n"))
         (accept-process-output proc 1)
         ;; listed
         (let ((names (mapcar (lambda (tl) (alist-get 'name tl))
                              (alist-get 'tools
                                         (alist-get 'result
                                                    (send "tools/list" nil))))))
           (dolist (want (split-string ,cmacs-gowl-grab-tests--tools ","))
             (unless (member want names)
               (error "%s is not listed: %S" want names))))
         ;; the colour: the same pixel the function reads, as #rrggbb
         (let ((r (call "gowl_pick_color" '((x . 5) (y . 5)))))
           (unless (and (not (car r))
                        (string-match-p "\\`\"?#[0-9a-f]\\{6\\}\"?\\'" (cdr r))
                        (string-match-p (cmacs-gowl-pixel-color 5 5) (cdr r)))
             (error "gowl_pick_color: %S" r)))
         ;; the text, and the clipboard left alone
         (gowl-clipboard-set "the person's copy")
         (let ((r (call "gowl_screen_text"
                        '((x . 0) (y . 0) (width . 50) (height . 20)))))
           (unless (and (not (car r))
                        (string-match-p "An agent read this" (cdr r)))
             (error "gowl_screen_text: %S" r)))
         (unless (equal (gowl-clipboard-get) "the person's copy")
           (error "gowl_screen_text touched the clipboard"))
         ;; recording needs the consent from here
         (let ((r (call "gowl_macro_record" '((action . "start")))))
           (unless (and (car r) (string-match-p "input-recording" (cdr r)))
             (error "gowl_macro_record started without consent: %S" r)))
         ;; macros: run by name, and by sentence (dry and for real)
         (setq test-ran nil)
         (let ((r (call "gowl_macro_run"
                        '((name . "say-hi") (args . ["a b"])))))
           (unless (and (not (car r))
                        (test-wait (lambda () test-ran))
                        (equal test-ran '("api" "a b")))
             (error "gowl_macro_run: %S ran %S" r test-ran)))
         (let ((r (call "gowl_macro_voice_match"
                        '((text . "Say hi, forty.") (dry_run . t)))))
           (unless (and (string-match-p "\"macro\":\"say-hi\"" (cdr r))
                        (string-match-p "\"args\":\"40\"" (cdr r)))
             (error "dry voice match: %S" r)))
         (setq test-ran nil)
         (call "gowl_macro_voice_match" '((text . "say hi")))
         (unless (and (test-wait (lambda () test-ran))
                      (equal test-ran '("voice")))
           (error "voice match ran %S" test-ran))
         (let ((r (call "gowl_macro_list" nil)))
           (unless (string-match-p "say-hi" (cdr r))
             (error "gowl_macro_list does not list say-hi: %S" r)))
         (unless (string-match-p "\"listening\":false"
                                 (cdr (call "gowl_macro_voice_status" nil)))
           (error "gowl_macro_voice_status"))
         ;; the clipboard history, with what Emacs set in it
         (gowl-clipboard-set "copied from emacs")
         (unless (test-wait
                  (lambda ()
                    (string-match-p "copied from emacs"
                                    (cdr (call "gowl_clipboard_list" nil)))))
           (error "Emacs's own set is not in the history"))
         (let* ((list (cdr (call "gowl_clipboard_list" nil)))
                (line (seq-find (lambda (l)
                                  (string-match-p "copied from emacs" l))
                                (split-string list "\n" t)))
                (eid (string-to-number line)))
           (gowl-clipboard-set "something else")
           (let ((r (call "gowl_clipboard_copy" `((id . ,eid)))))
             (when (car r) (error "gowl_clipboard_copy: %S" r)))
           ;; THE REGRESSION: the entry is now a gowl-owned source, and
           ;; Emacs reads it synchronously on its own thread.  That used
           ;; to hang Emacs forever.
           (let* ((t0 (float-time))
                  (got (gowl-clipboard-get)))
             (unless (equal got "copied from emacs")
               (error "After a restore the clipboard read %S" got))
             (when (> (- (float-time) t0) 2.5)
               (error "Reading a restored entry took %.1fs"
                      (- (float-time) t0)))))
         (ignore-errors (delete-process proc))
         (cmacs-brigade-scope-close path)))
     (gowl-stop)
     (princ "cmacs-gowl-grab: ok\n"))
  "What `cmacs-gowl-grab-test-mcp-headless' runs in the second cmacs.")

(defun cmacs-gowl-grab-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Returns (STATUS . OUTPUT).  Private runtime, config, state and cache
directories; no parent display; pixman; fatal criticals.  The runtime
directory's name is short on purpose: the scoped MCP socket lives three
levels under it with a PID and a UUID in its name, and a socket path
longer than 107 bytes cannot be bound."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cgg-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_MACRO_DIR"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        (concat "XDG_CACHE_HOME="
                                (expand-file-name "cache" runtime))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "180" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(ert-deftest cmacs-gowl-grab-test-mcp-headless ()
  "The new MCP tools over a scoped MCP socket, in a real compositor.
Listed; the colour and the text read without touching the clipboard;
recording refused without consent; macros run by name and by sentence;
the clipboard history holds Emacs's own sets; and reading back an entry
put on the clipboard from the history does not hang Emacs."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (skip-unless (let ((d (getenv "XDG_RUNTIME_DIR")))
                 (and d (file-directory-p d))))
  (let* ((result (cmacs-gowl-grab-tests--run-headless
                  cmacs-gowl-grab-tests--headless-form))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-match-p "cmacs-gowl-grab: ok" output)))))

(provide 'cmacs-gowl-grab-tests)

;;; cmacs-gowl-grab-tests.el ends here
