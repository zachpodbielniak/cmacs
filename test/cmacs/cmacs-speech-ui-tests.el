;;; cmacs-speech-ui-tests.el --- ERT for M-x cmacs-speech  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The settings buffer rendered headlessly against fake backends, the
;; Evil key rules every cmacs dashboard keeps, and the pure helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-speech-ui)

(defmacro cmacs-speech-ui-test--with-buffer (&rest body)
  "Render the settings buffer over fake backends and a private state, then BODY."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "speech-ui" t))
          (cmacs-speech-state-file (expand-file-name "speech.eld" dir))
          (cmacs-speech-models-directory (expand-file-name "store" dir))
          (cmacs-speech-config nil) (cmacs-speech-override nil)
          (cmacs-speech--session nil) (cmacs-speech--ui nil) (cmacs-speech--ui-loaded nil)
          (cmacs-speech-config-changed-hook nil)
          (cmacs-speech-model-progress-functions nil)
          (cmacs-speech--backends (make-hash-table :test 'eq))
          (cmacs-speech-backend-order nil)
          (cmacs-speech-auto-preference '((stt alpha)))
          (cmacs-speech-ui-folded nil))
     (cmacs-speech-define-backend
      'alpha :components '(stt tts) :describe (lambda () "Alpha engine 1.0")
      :models (lambda (_c) '("alpha-model"))
      :default-model (lambda (_c) "alpha-model"))
     (unwind-protect
         (with-temp-buffer
           (cmacs-speech-ui-mode)
           (cmacs-speech-ui--render)
           ,@body)
       (delete-directory dir t))))

(ert-deftest cmacs-speech-ui-test-renders-sections ()
  (cmacs-speech-ui-test--with-buffer
    (let ((text (buffer-string)))
      (should (string-match-p "cmacs speech" text))
      (should (string-match-p "Alpha engine 1.0" text))
      (dolist (h '("Components" "Features" "Models" "Speakers" "Loaded engines" "Bench"))
        (should (string-match-p (regexp-quote h) text)))
      ;; Every component has a row; stt resolved automatically.
      (should (string-match-p "^  stt +alpha +alpha-model +auto → alpha +ready" text))
      (should (string-match-p "^  diarize +— " text)))))

(ert-deftest cmacs-speech-ui-test-source-labels ()
  "Rows say which layer decided them; init.el rows are locked."
  (cmacs-speech-ui-test--with-buffer
    (cmacs-speech-set 'stt 'alpha :model "pinned")
    (cmacs-speech-ui-set 'tts 'alpha :model "ui-voice")
    (cmacs-speech-ui--render)
    (should (string-match-p "^  stt .*pinned.*🔒 init.el" (buffer-string)))
    (should (string-match-p "^  tts .*ui-voice.*chosen here" (buffer-string)))))

(ert-deftest cmacs-speech-ui-test-context-at-point ()
  (cmacs-speech-ui-test--with-buffer
    (goto-char (point-min))
    (re-search-forward "^  stt ")
    (should (equal (seq-take (cmacs-speech-ui--context) 2) '(component stt)))))

(ert-deftest cmacs-speech-ui-test-folding-survives-redraw ()
  "Folding hides a section's body and stays across a redraw."
  (cmacs-speech-ui-test--with-buffer
    (goto-char (point-min))
    (re-search-forward "^▾ Components")
    (cmacs-clawtilla-toggle-fold)
    (should (string-match-p "^▸ Components" (buffer-string)))
    (should-not (string-match-p "^  stt " (buffer-string)))
    (cmacs-speech-ui--render)
    (should (string-match-p "^▸ Components" (buffer-string)))))

(ert-deftest cmacs-speech-ui-test-notes-shown ()
  (cmacs-speech-ui-test--with-buffer
    (setq cmacs-speech-ui--notes '((stt . "heard “hi”")))
    (cmacs-speech-ui--render)
    (should (string-match-p "^  stt .*heard “hi”" (buffer-string)))))

(defconst cmacs-speech-ui-test--motion-keys
  '("j" "k" "h" "l" "w" "b" "e" "W" "B" "E" "0" "$" "^" "G" "H" "M" "L"
    "{" "}" "(" ")" "%" "/" "n" "N" "f" "F" "t" "T" ";" "g" "SPC" ",")
  "Evil motions and Doom leaders; see `cmacs-clawtilla-define-common-keys'.")

(ert-deftest cmacs-speech-ui-test-no-motion-keys ()
  "The settings buffer is an Evil intercept map: it must not take a motion."
  (let ((own (copy-keymap cmacs-speech-ui-mode-map)) offenders)
    (set-keymap-parent own nil)
    (dolist (k cmacs-speech-ui-test--motion-keys)
      (when (commandp (lookup-key own (kbd k)))
        (push k offenders)))
    (should-not offenders)))

(ert-deftest cmacs-speech-ui-test-registers-with-evil ()
  "Without the Evil setup the buffer is inert under Doom."
  (with-temp-buffer
    (insert-file-contents (locate-library "cmacs-speech-ui.el"))
    (should (search-forward "(cmacs-clawtilla-setup-evil cmacs-speech-ui-mode-map" nil t))))

(ert-deftest cmacs-speech-ui-test-wer ()
  (should (= (cmacs-speech-ui--wer "the quick brown fox" "the quick brown fox") 0.0))
  (should (= (cmacs-speech-ui--wer "the quick brown fox" "The quick, brown fox!") 0.0))
  (should (= (cmacs-speech-ui--wer "a b c d" "a x c d") 0.25))
  (should (= (cmacs-speech-ui--wer "a b c d" "a b c") 0.25))
  (should (= (cmacs-speech-ui--wer "a b" "a b c d") 1.0)))

(ert-deftest cmacs-speech-ui-test-export-forms ()
  "UI choices become init.el forms that evaluate back to the same choice."
  (cmacs-speech-ui-test--with-buffer
    (cmacs-speech-ui-set 'tts 'alpha :model "v" :speaker 3)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (cmacs-speech-ui-export))
    (with-current-buffer "*cmacs speech init.el*"
      (goto-char (point-min))
      (re-search-forward "^(cmacs-speech-set")
      (beginning-of-line)
      (let ((form (read (current-buffer))))
        (should (equal form '(cmacs-speech-set 'tts 'alpha :model "v" :speaker 3)))
        (let ((cmacs-speech-config nil))
          (eval form t)
          (should (equal (plist-get (cmacs-speech-resolve 'tts) :model) "v"))))
      (kill-buffer))))

(ert-deftest cmacs-speech-ui-test-helpers ()
  (should (equal (cmacs-speech-ui--size 1536) "2 kB"))
  (should (equal (cmacs-speech-ui--size (* 3 1048576)) "3 MB"))
  (should (equal (cmacs-speech-ui--stars 3) "★★★☆☆"))
  (should (= (length (cmacs-speech-ui--bar 0.5 10)) 10)))

(provide 'cmacs-speech-ui-tests)
;;; cmacs-speech-ui-tests.el ends here
