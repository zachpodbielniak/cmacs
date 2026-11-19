;;; speech-menu.el --- headless scenario: the right-click Speech menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase-6/7 screenshots: the Speech menu on a text region, on an audio
;; file in dired (Transcribe submenu open), on an org audio link; then
;; two of its actions carried out -- a speaker-labelled "Who spoke?"
;; transcript of a three-voice recording, and SubRip subtitles.
;;
;; The recording is made here: two LibriSpeech readers (the test clips
;; the sherpa models ship) and the TTS voice, joined with pauses, so it
;; needs no network and no microphone.

;;; Code:

(require 'cmacs-speech-menu)
(require 'cmacs-speech-ui)
(require 'dired)
(set-face-attribute 'default nil :height 110)

(defvar speech-menu--dir (make-temp-file "speech-menu-demo" t))
(defvar speech-menu--wav (expand-file-name "standup-meeting.wav" speech-menu--dir))
(defvar speech-menu--mp3 (expand-file-name "standup-meeting.mp3" speech-menu--dir))
(defvar speech-menu--ready nil)
(defvar speech-menu-shot nil
  "Which menu ends the run: \"region\", \"dired\" or \"org\" (via --eval).")

(defun speech-menu--clip (name)
  "16 kHz PCM of the moonshine model's test clip NAME."
  (car (cmacs-speech-read-wav
        (expand-file-name (concat "sherpa-onnx-moonshine-tiny-en-int8/test_wavs/" name)
                          (car (cmacs-speech-model-dirs 'sherpa))))))

(defun speech-menu--make-recording ()
  "Build a three-voice WAV (and an MP3 copy) in the demo directory."
  (cmacs-speech-synthesize
   "Thanks both. I will write that up and send the summary to everyone this afternoon."
   (lambda (r)
     (let* ((tts (alist-get :pcm r))
            (rate (alist-get :sample-rate r))
            (tts16 (if (= rate 16000) tts (cmacs-whisper-pcm-resample tts rate 16000)))
            (gap (make-string 16000 0 t)))
       (cmacs-speech-write-wav speech-menu--wav
                               (concat (speech-menu--clip "0.wav") gap
                                       (speech-menu--clip "1.wav") gap tts16)
                               16000)
       (call-process cmacs-speech-ffmpeg-program nil nil nil "-y" "-loglevel" "error"
                     "-i" speech-menu--wav speech-menu--mp3)
       (setq speech-menu--ready t)))))

(defvar speech-menu--map nil "The menu of the current shot, built once.")

(defun speech-menu--ctx-keymap ()
  "The Speech menu for point in the current buffer, built once per shot."
  (or speech-menu--map
      (setq speech-menu--map (cmacs-speech-menu-keymap (cmacs-speech-menu-context)))))

(defun speech-menu--shot (name &optional keys)
  "A step body: shoot the Speech menu at point as NAME."
  (let ((r (cmacs-headless-shot-menu name (speech-menu--ctx-keymap) keys)))
    (unless r (setq speech-menu--map nil))
    r))

(cmacs-headless-steps
 (lambda () (speech-menu--make-recording) nil)
 (lambda () (if speech-menu--ready nil 'wait))
 ;; The prose and the org link the menus are shown on.
 (lambda ()
   (switch-to-buffer (get-buffer-create "notes.org"))
   (org-mode)
   (erase-buffer)
   (insert "* Standup\n\n"
           "The sherpa engine now runs beside whisper.cpp and piper.  Streaming\n"
           "dictation shows words as they are spoken, and the wake word is heard\n"
           "by a three megabyte keyword spotter instead of a full recognizer.\n\n"
           "Recording: [[file:" speech-menu--wav "][standup meeting]]\n")
   nil)
 ;; 4. Who spoke?
 (lambda () (cmacs-speech-menu-who-spoke speech-menu--wav) nil)
 (lambda ()
   (if (not (get-buffer "*who spoke*")) 'wait
     (delete-other-windows)
     (switch-to-buffer "*who spoke*")
     (goto-char (point-min))
     nil))
 (lambda () (cmacs-headless-shot "phase7-01-who-spoke") nil)
 ;; 5. Subtitles beside the file.
 (lambda () (cmacs-speech-menu-transcribe speech-menu--mp3 'srt) nil)
 (lambda ()
   (let ((srt (cmacs-speech-menu--sibling speech-menu--mp3 ".srt")))
     (if (not (file-exists-p srt)) 'wait
       (find-file srt)
       nil)))
 (lambda () (cmacs-headless-shot "phase7-02-subtitles") nil)
 ;; Last: one real menu (it cannot be closed headless; see the driver).
 (lambda ()
   (pcase speech-menu-shot
     ("region"
      (switch-to-buffer "notes.org")
      (goto-char (point-min)) (forward-line 2) (set-mark (point)) (forward-line 3)
      (activate-mark)
      (cmacs-headless-shot-menu-final "phase6-01-menu-region" (speech-menu--ctx-keymap)))
     ("dired"
      (dired speech-menu--dir)
      (goto-char (point-min)) (search-forward "standup-meeting.mp3")
      (cmacs-headless-shot-menu-final "phase6-02-menu-dired" (speech-menu--ctx-keymap)))
     ("transcribe"
      ;; The submenu a hover over "Transcribe" opens.
      (dired speech-menu--dir)
      (goto-char (point-min)) (search-forward "standup-meeting.mp3")
      (cmacs-headless-shot-menu-final
       "phase6-03-menu-transcribe"
       (plist-get (cmacs-media-menu-lookup (speech-menu--ctx-keymap) "Transcribe") :submenu)))
     ("org"
      (switch-to-buffer "notes.org")
      (deactivate-mark)
      (goto-char (point-min)) (search-forward "standup meeting")
      (cmacs-headless-shot-menu-final "phase6-04-menu-org-link" (speech-menu--ctx-keymap)))
     (_ nil))))

;;; speech-menu.el ends here
