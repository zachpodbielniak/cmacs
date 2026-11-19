;;; cmacs-speech-brigade.el --- speech tools for brigade agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Publishes speech as brigade tools, so every agent kind -- in-process,
;; CLI agents over the MCP relay, external MCP clients -- can transcribe a
;; recording, ask who spoke in it, and speak.  They run asynchronously
;; (brigade's :async), through whichever engine M-x cmacs-speech chose,
;; and the two file tools are also on the right-click menu of an audio
;; file in dired.

;;; Code:

(require 'cmacs-speech)
(require 'cmacs-brigade-registry)

(cmacs-brigade-deftool speech-transcribe
  "Transcribe an audio or video file (any format ffmpeg reads) and return the text."
  ((path string "The audio or video file"))
  :group 'speech :async t :timeout 900
  :menu '(file) :menu-label "Transcribe (speech)"
  (cmacs-speech-transcribe-file
   path (lambda (r) (funcall done (or (alist-get :text r)
                                      (format "error: %s" (alist-get :error r)))))
   :feature 'brigade :component 'stt))

(cmacs-brigade-deftool speech-who-spoke
  "Who spoke when in an audio or video file: a speaker-labelled transcript."
  ((path string "The audio or video file"))
  :group 'speech :async t :timeout 1200
  :menu '(file) :menu-label "Who spoke? (speech)"
  (cmacs-speech-file-pcm
   path
   (lambda (got)
     (if (eq (car got) :error)
         (funcall done (format "error: %s" (cdr got)))
       (cmacs-speech-diarize
        (car got)
        (lambda (d)
          (if (assq :error d)
              (funcall done (format "error: %s" (alist-get :error d)))
            (cmacs-speech-transcribe
             (car got)
             (lambda (tr)
               (funcall done
                        (if (assq :error tr)
                            (format "error: %s" (alist-get :error tr))
                          (format "%d speakers\n\n%s" (alist-get :num-speakers d)
                                  (cmacs-speech-label-speakers (alist-get :segments d)
                                                               (alist-get :segments tr))))))
             :component 'stt :feature 'brigade :rate (cdr got))))
        :feature 'brigade :rate (cdr got))))))

(cmacs-brigade-deftool speech-say
  "Say TEXT aloud on the user's speakers with the configured voice."
  ((text string "What to say"))
  :group 'speech
  (cmacs-speech-speak text :feature 'brigade)
  "ok")

(provide 'cmacs-speech-brigade)
;;; cmacs-speech-brigade.el ends here
