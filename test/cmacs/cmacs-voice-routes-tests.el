;;; cmacs-voice-routes-tests.el --- ERT for wake phrases as routes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-voice-loop-wake-phrase' as a list and `cmacs-voice-loop-routes':
;; the loop is driven with synthetic tones, whisper is stubbed to answer
;; a fixed transcript, and route delivery is captured.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-voice-loop)
;; Loaded up front: the commands route requires it, and loading it inside
;; a test would redefine the stubbed `cmacs-voice-command-run'.
(require 'cmacs-voice-commands)

;;;; Wake phrases as routes

(defmacro cmacs-voice-routes-tests--with-loop (reply &rest body)
  "BODY with the loop listening; whisper answers REPLY for every model.
`delivered' collects (TARGET . TEXT) for each routed utterance."
  (declare (indent 1))
  `(let ((delivered nil)
         (cmacs-voice-loop-mode t)
         (cmacs-voice-loop-partial-interval nil)
         (cmacs-voice-loop-partial-display nil)
         (cmacs-voice-loop-state-change-functions nil)
         (cmacs-voice-loop--state 'listening)
         (cmacs-voice--vad nil)
         (cmacs-voice--frame-fn #'cmacs-voice-loop--frame)
         (cmacs-voice-loop--last-sent-seg 0)
         (cmacs-voice-loop--last-target nil)
         (cmacs-voice-loop--heard-phrases nil)
         (cmacs-voice--tts-until 0.0)
         (cmacs-voice--tts-queue nil)
         (cmacs-voice--tts-synth nil)
         (reply ,reply))
     (cmacs-voice-loop--reset-state)
     (cl-letf (((symbol-function 'cmacs-voice-loop--deliver)
                (lambda (target text) (push (cons target text) delivered) nil))
               ((symbol-function 'cmacs-voice-loop--model-path)
                (lambda (which) (symbol-name which)))
               ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                (lambda (_m _pcm cb &rest _) (funcall cb (list (cons :text reply))))))
       (unwind-protect (progn ,@body) (cmacs-voice-loop--reset-state)))))

(defun cmacs-voice-routes-tests--speak ()
  "Feed one tone utterance and the silence that ends it."
  (dolist (p (list (cmacs-voice-routes-tests--tone 900)
                   (make-string (* 2 16 1000) 0)))
    (let ((i 0))
      (while (< i (length p))
        (cmacs-voice-loop--ingest (substring p i (min (length p) (+ i 3200))))
        (cmacs-voice-loop--housekeeping)
        (setq i (+ i 3200))))))

(defun cmacs-voice-routes-tests--tone (ms)
  "MS of a 440 Hz sine at 16 kHz, S16LE."
  (let* ((n (* 16 ms)) (s (make-string (* 2 n) 0)))
    (dotimes (i n)
      (let ((u (logand (round (* 0.3 32767 (sin (/ (* 2 float-pi 440 i) 16000.0))))
                       #xffff)))
        (aset s (* 2 i) (logand u 255))
        (aset s (1+ (* 2 i)) (ash u -8))))
    s))

(ert-deftest cmacs-voice-routes-test-each-phrase ()
  "Each wake phrase sends its utterance to its own target."
  (let ((cmacs-voice-loop-wake-phrase '("jarvis" "computer"))
        (cmacs-voice-loop-routes '(("computer" . commands)
                                   ("friday" . (agent researcher))))
        (cmacs-voice-loop-default-route 'chat))
    (cmacs-voice-routes-tests--with-loop " Computer, workspace three."
      (cmacs-voice-routes-tests--speak)
      (setq reply " Friday, survey the notes on VR.")
      (cmacs-voice-routes-tests--speak)
      (setq cmacs-voice-loop--armed-until 0.0)
      (setq reply " Jarvis, what changed in the build?")
      (cmacs-voice-routes-tests--speak)
      (should (equal (reverse delivered)
                     '((commands . "workspace three.")
                       ((agent researcher) . "survey the notes on VR.")
                       (chat . "what changed in the build?")))))))

(ert-deftest cmacs-voice-routes-test-follow-up ()
  "A bare phrase and the follow-up window keep that phrase's route."
  (let ((cmacs-voice-loop-wake-phrase "jarvis")
        (cmacs-voice-loop-routes '(("computer" . commands))))
    (cmacs-voice-routes-tests--with-loop " Computer."
      (cmacs-voice-routes-tests--speak)
      (should-not delivered)
      (should (cmacs-voice-loop--armed-p))
      (setq reply " Monocle.")
      (cmacs-voice-routes-tests--speak)
      ;; the stub started no reply: the follow-up window is open, and
      ;; still on the commands route
      (setq reply " Tile left.")
      (cmacs-voice-routes-tests--speak)
      (should (equal (reverse delivered)
                     '((commands . "Monocle.") (commands . "Tile left.")))))))

(ert-deftest cmacs-voice-routes-test-string-form ()
  "The plain string form still means: that phrase, to the chat."
  (let ((cmacs-voice-loop-wake-phrase "jarvis")
        (cmacs-voice-loop-routes nil))
    (should (equal (cmacs-voice-loop--phrases) '("jarvis")))
    (should (eq (cmacs-voice-loop-route-target "jarvis") 'chat))
    (cmacs-voice-routes-tests--with-loop " Jarvis, hello."
      (cmacs-voice-routes-tests--speak)
      (should (equal delivered '((chat . "hello.")))))))

(ert-deftest cmacs-voice-routes-test-deliver-targets ()
  "Route targets: commands run without the chat, agents get a task, functions are called."
  (let ((got nil))
    (cl-letf (((symbol-function 'cmacs-voice-command-run)
               (lambda (text &rest _) (push (cons 'cmd text) got) nil))
              ((symbol-function 'cmacs-brigade-voice--queue)
               (lambda (text agent) (push (list 'agent agent text) got)))
              (cmacs-voice-loop-send-function (lambda (text) (push (cons 'chat text) got))))
      (should-not (cmacs-voice-loop--deliver 'commands "workspace 2"))
      (cmacs-voice-loop--deliver '(agent researcher) "survey")
      (cmacs-voice-loop--deliver (lambda (text) (push (cons 'fn text) got)) "x")
      (should (cmacs-voice-loop--deliver 'chat "hi"))
      (should (equal (reverse got)
                     '((cmd . "workspace 2") (agent researcher "survey")
                       (fn . "x") (chat . "hi")))))))

(provide 'cmacs-voice-routes-tests)

;;; cmacs-voice-routes-tests.el ends here
