;;; cmacs-voice-commands-tests.el --- ERT for voice commands and wake routes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Voice control of the desktop and wake-phrase routing.  Every gowl,
;; podomation and macro primitive is stubbed (C DEFUN stubs take &rest),
;; so no test touches a compositor.  Brigade tools are registered for
;; real when the brigade is available, and removed afterwards.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-voice-commands)

(defmacro cmacs-voice-commands-tests--with-desktop (&rest body)
  "Run BODY against a fake gowl desktop.
`calls' collects (FUNCTION . ARGS) for every compositor, macro and
podomation call; two windows exist, a terminal (focused) and firefox."
  (declare (indent 0))
  `(let ((calls nil)
         (cmacs-voice--confirm nil)
         (cmacs-voice-confirm-destructive t)
         (cmacs-voice-commands-speak-feedback nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-view-tags)
                (lambda (&rest a) (push (cons 'view-tags a) calls) t))
               ((symbol-function 'gowl-set-tags)
                (lambda (&rest a) (push (cons 'set-tags a) calls) t))
               ((symbol-function 'gowl-set-layout)
                (lambda (&rest a) (push (cons 'set-layout a) calls) t))
               ((symbol-function 'gowl-list-layouts)
                (lambda (&rest _) '("tile" "monocle" "tabbed" "float" "scrolling")))
               ((symbol-function 'gowl-list-clients) (lambda (&rest _) '(c-term c-fox)))
               ((symbol-function 'gowl-focused-client) (lambda (&rest _) 'c-term))
               ((symbol-function 'gowl-client-info)
                (lambda (c &rest _)
                  (if (eq c 'c-fox)
                      '((id . 2) (title . "Mozilla Firefox") (app-id . "firefox"))
                    '((id . 1) (title . "zsh") (app-id . "gst")))))
               ((symbol-function 'gowl-focus-client)
                (lambda (&rest a) (push (cons 'focus a) calls) t))
               ((symbol-function 'gowl-focus-direction)
                (lambda (&rest a) (push (cons 'focus-dir a) calls) t))
               ((symbol-function 'gowl-close-client)
                (lambda (&rest a) (push (cons 'close a) calls) t))
               ((symbol-function 'cmacs-gowl-macro-list)
                (lambda (&rest _) '(((name . "standup")) ((name . "sort-windows"))
                                    ((name . "wipe-scratch")))))
               ((symbol-function 'cmacs-gowl-macro-run)
                (lambda (&rest a) (push (cons 'macro a) calls) "ok"))
               ((symbol-function 'cmacs-podomation-emit-event)
                (lambda (&rest a) (push (cons 'event a) calls) t)))
       ,@body)))

;;;; Normalising and naming

(ert-deftest cmacs-voice-commands-test-normalize ()
  "Punctuation goes, case folds, numbers after a keyword become digits."
  (should (equal (cmacs-voice-command-normalize "Workspace Three!") "workspace 3"))
  (should (equal (cmacs-voice-command-normalize "Open two files.") "open two files")))

(ert-deftest cmacs-voice-commands-test-best-name ()
  "Exact, then all-words-contained, then fuzzy above the threshold."
  (let ((names '("standup" "sort-windows" "wipe_scratch.c")))
    (should (equal (cmacs-voice-best-name "sort windows" names) "sort-windows"))
    (should (equal (cmacs-voice-best-name "stand up" names) "standup"))
    (should (equal (cmacs-voice-best-name "wipe scratch" names) "wipe_scratch.c"))
    (should (equal (cmacs-voice-best-name "standupp" names) "standup"))
    (should-not (cmacs-voice-best-name "deploy" names))
    (should-not (cmacs-voice-best-name "" names))))

;;;; The desktop

(ert-deftest cmacs-voice-commands-test-workspaces ()
  "Workspace N views a tag; move-to sets the focused window's tag."
  (cmacs-voice-commands-tests--with-desktop
    (cmacs-voice-command-run "Workspace three." :context 'desktop)
    (cmacs-voice-command-run "move this to workspace two" :context 'desktop)
    (should (equal (reverse calls) '((view-tags 4) (set-tags c-term 2))))))

(ert-deftest cmacs-voice-commands-test-focus ()
  "Focus a window by fuzzy name, or by direction."
  (cmacs-voice-commands-tests--with-desktop
    (cmacs-voice-command-run "Focus Firefox" :context 'desktop)
    (cmacs-voice-command-run "focus left" :context 'desktop)
    (should (equal (reverse calls) '((focus c-fox) (focus-dir left))))))

(ert-deftest cmacs-voice-commands-test-layouts ()
  "\"tile left\", bare layout names and fuzzy \"layout NAME\"."
  (cmacs-voice-commands-tests--with-desktop
    (cmacs-voice-command-run "Tile left." :context 'desktop)
    (cmacs-voice-command-run "monocle" :context 'desktop)
    (cmacs-voice-command-run "layout scrollin" :context 'desktop)
    (should (equal (reverse calls)
                   '((set-layout "tile") (set-layout "monocle")
                     (set-layout "scrolling"))))))

(ert-deftest cmacs-voice-commands-test-close-asks-first ()
  "Closing a window waits for a spoken or typed yes."
  (cmacs-voice-commands-tests--with-desktop
    (should (eq (cmacs-voice-command-run "close window" :context 'desktop) 'pending))
    (should-not (assq 'close calls))
    (should (string-match-p "zsh" (car cmacs-voice--confirm)))
    (should (eq (cmacs-voice-command-run "Yes." :context 'desktop) 'confirm))
    (should (equal (assq 'close calls) '(close c-term)))
    ;; "no" cancels; a named window is closed by name.
    (setq calls nil)
    (cmacs-voice-command-run "close firefox" :context 'desktop)
    (should (string-match-p "Firefox" (car cmacs-voice--confirm)))
    (cmacs-voice-command-run "no" :context 'desktop)
    (should-not calls)
    (should-not (cmacs-voice-confirm-pending-p))))

(ert-deftest cmacs-voice-commands-test-confirm-modes ()
  "Keyboard-only confirmation ignores speech; nil acts at once; asks lapse."
  (cmacs-voice-commands-tests--with-desktop
    (let ((cmacs-voice-confirm-destructive 'keyboard))
      (cmacs-voice-command-run "close window" :context 'desktop)
      (should-not (cmacs-voice-confirm-answer "yes"))
      (should (cmacs-voice-confirm-pending-p))
      (cmacs-voice--confirm-resolve t)
      (should (assq 'close calls)))
    (setq calls nil)
    (let ((cmacs-voice-confirm-destructive nil))
      (cmacs-voice-command-run "close window" :context 'desktop)
      (should (assq 'close calls)))
    (cmacs-voice-command-run "close window" :context 'desktop)
    (setf (nth 2 cmacs-voice--confirm) (- (float-time) 1))
    (should-not (cmacs-voice-confirm-pending-p))))

(ert-deftest cmacs-voice-commands-test-needs-a-compositor ()
  "Without a running gowl the desktop entries do not apply."
  (cmacs-voice-commands-tests--with-desktop
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should-not (cmacs-voice-command-run "workspace 3" :context 'desktop))
      (should-not calls))))

(ert-deftest cmacs-voice-commands-test-context ()
  "Desktop entries are skipped in VR, VR entries outside it."
  (cmacs-voice-commands-tests--with-desktop
    (let ((vr nil)
          (cmacs-voice-commands (copy-sequence cmacs-voice-commands)))
      (cmacs-voice-define-command "workspace \\([0-9]+\\)"
                                  (lambda (n) (push n vr)) "vr ws" nil :context 'vr)
      (cmacs-voice-command-run "workspace two" :context 'vr)
      (cmacs-voice-command-run "workspace two" :context 'desktop)
      (should (equal vr '("2")))
      (should (equal calls '((view-tags 2)))))))

;;;; Macros, events, tools

(ert-deftest cmacs-voice-commands-test-macros ()
  "\"run standup\" runs the macro; a listed destructive macro asks first."
  (cmacs-voice-commands-tests--with-desktop
    (cmacs-voice-command-run "Run stand up." :context 'desktop)
    (cmacs-voice-command-run "run macro sort windows" :context 'desktop)
    (should (equal (reverse calls) '((macro "standup") (macro "sort-windows"))))
    (setq calls nil)
    (let ((cmacs-voice-destructive-macros '("wipe-scratch")))
      (cmacs-voice-command-run "run wipe scratch" :context 'desktop)
      (should-not calls)
      (should (cmacs-voice-confirm-pending-p))
      (cmacs-voice-command-run "yes, do it")
      (should (equal calls '((macro "wipe-scratch")))))))

(ert-deftest cmacs-voice-commands-test-podomation ()
  "Events fire by name; rules are reached through `voice_rule'."
  (cmacs-voice-commands-tests--with-desktop
    (cmacs-voice-command-run "Fire event backup now" :context 'desktop)
    (cmacs-voice-command-run "run rule standup" :context 'desktop)
    (should (equal (reverse calls)
                   '((event "backup_now" (("source" . "voice")))
                     (event "voice_rule" (("name" . "standup") ("source" . "voice"))))))))

(ert-deftest cmacs-voice-commands-test-brigade-tools ()
  "Tools run by name with a spoken argument; destructive ones ask."
  (skip-unless (and (require 'cmacs-brigade-registry nil t)
                    (require 'cmacs-brigade-tools nil t)))
  (let ((ran nil))
    (unwind-protect
        (cmacs-voice-commands-tests--with-desktop
          (cmacs-brigade-register-tool
           :name 'voice-test-echo :description "Echo for the voice tests."
           :params '((query string "What to echo"))
           :handler (lambda (q) (push q ran) (concat "got " q)))
          (cmacs-brigade-register-tool
           :name 'voice-test-wipe :description "Pretend to wipe."
           :params nil :destructive t
           :handler (lambda () (push 'wiped ran) "wiped"))
          (cmacs-voice-command-run "Use tool voice test echo for hello world"
                                   :context 'desktop)
          (should (equal ran '("hello world")))
          (should (eq (cmacs-voice-command-run "use tool voice test wipe" :context 'desktop)
                      'pending))
          (should (equal ran '("hello world")))
          (cmacs-voice-command-run "yes")
          (should (equal ran '(wiped "hello world"))))
      (cmacs-brigade-unregister-tool 'voice-test-echo)
      (cmacs-brigade-unregister-tool 'voice-test-wipe))))

(ert-deftest cmacs-voice-commands-test-push-to-talk-command ()
  "C-c v v: record, transcribe, run the command -- no chat involved."
  (cmacs-voice-commands-tests--with-desktop
    (let ((mic nil)
          (cmacs-voice--owners nil) (cmacs-voice--capture nil)
          (cmacs-voice--timer nil) (cmacs-voice--ptt nil))
      (cl-letf (((symbol-function 'cmacs-voice-available-p) (lambda () t))
                ((symbol-function 'cmacs-audio--capture-open-1) (lambda (&rest _) 'h))
                ((symbol-function 'cmacs-audio-start) (lambda (&rest _) t))
                ((symbol-function 'cmacs-audio-close) (lambda (&rest _) t))
                ((symbol-function 'cmacs-audio-read-pcm)
                 (lambda (&rest _) (if mic (pop mic) "")))
                ((symbol-function 'cmacs-whisper-model-path) (lambda (&rest _) "m"))
                ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                 (lambda (_m _p cb &rest _) (funcall cb '((:text . " Workspace five."))))))
        (should (eq (lookup-key cmacs-voice-map "v") #'cmacs-voice-command))
        (cmacs-voice-command)
        (should (cmacs-voice-ptt-active-p 'command))
        (setq mic (list (make-string 16000 1)))
        (cmacs-voice--tick)
        (cmacs-voice-command)
        (should-not (cmacs-voice-mic-open-p))
        (should (equal calls '((view-tags 16))))))))

(provide 'cmacs-voice-commands-tests)

;;; cmacs-voice-commands-tests.el ends here
