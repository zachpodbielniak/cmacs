;;; cmacs-speech-models-tests.el --- ERT for the speech model store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The downloader runs real curl/sha256sum/tar processes against
;; file:// URLs made here, into a private store, so it is exercised end
;; to end without the network.  The shipped catalog is checked for
;; shape and against its YAML seed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-speech-models)
(require 'cmacs-speech-sherpa)

(defmacro cmacs-speech-models-test--store (&rest body)
  "Run BODY with an empty private store; `src' is a scratch directory."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "speech-store" t))
          (src (expand-file-name "src" root))
          (cmacs-speech-models-directory (expand-file-name "store" root))
          (cmacs-speech-models-extra-directories nil)
          (cmacs-speech-system-models-directory (expand-file-name "system" root))
          (cmacs-speech-sherpa-models-directories nil)
          (cmacs-speech-models--jobs nil)
          (cmacs-speech-models-gowl-toast nil)
          (cmacs-speech-model-progress-functions nil)
          (cmacs-speech-model-installed-functions nil)
          (cmacs-speech-config-changed-hook nil)
          (inhibit-message t))
     (make-directory src t)
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(defun cmacs-speech-models-test--sha (file)
  "SHA-256 of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun cmacs-speech-models-test--file (dir name content)
  "Write CONTENT to DIR/NAME; return the path."
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (let ((coding-system-for-write 'binary))
      (with-temp-file f (set-buffer-multibyte nil) (insert content)))
    f))

(ert-deftest cmacs-speech-models-test-catalog-shape ()
  "Every shipped entry has what the store and the UI need."
  (let ((all (cmacs-speech-models-catalog)))
    (should (> (length all) 30))
    (dolist (m all)
      (should (stringp (plist-get m :id)))
      (should (memq (plist-get m :backend) '(whisper sherpa piper)))
      (should (plist-get m :components))
      (dolist (c (plist-get m :components))
        (should (assq c cmacs-speech-components)))
      (should (string-prefix-p "https://" (plist-get m :url)))
      (should (natnump (plist-get m :size)))
      (should (stringp (plist-get m :description))))
    ;; Every component has something to offer.
    (dolist (c '(stt stt-live stt-stream wake vad tts diarize speaker-id
                     punctuate audio-tag denoise separate lang-id))
      (should (cmacs-speech-models-catalog :component c)))))

(ert-deftest cmacs-speech-models-test-catalog-matches-seed ()
  "The .eld lists the same ids as the YAML seed (drift guard).
An id missing from the .eld was dropped by the generator because its
source vanished; that must be noticed, not shipped silently."
  (let* ((yaml (expand-file-name "cmacs/speech-models.yaml" data-directory))
         (ids (with-temp-buffer
                (insert-file-contents yaml)
                (let (out)
                  (while (re-search-forward "^  - id: \\(.+\\)$" nil t)
                    (push (match-string 1) out))
                  (nreverse out)))))
    (should (equal ids (mapcar (lambda (m) (plist-get m :id))
                               (cmacs-speech-models-catalog))))))

(ert-deftest cmacs-speech-models-test-download-file-with-sha ()
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "ggml-test.bin" (make-string 40000 ?a)))
           (entry (list :id "ggml-test.bin" :backend 'whisper :url (concat "file://" f)
                        :size 40000 :sha256 (cmacs-speech-models-test--sha f)))
           (events nil))
      (add-hook 'cmacs-speech-model-progress-functions
                (lambda (_id j) (push (cmacs-speech-models-job-state j) events)))
      (let ((path (cmacs-speech-models-download entry :wait t)))
        (should (equal path (expand-file-name "whisper/ggml-test.bin"
                                              cmacs-speech-models-directory)))
        (should (= (file-attribute-size (file-attributes path)) 40000))
        (should-not (file-exists-p (concat path ".part")))
        (should (memq 'verifying events))
        (should (eq (car events) 'done))))))

(ert-deftest cmacs-speech-models-test-sha-mismatch-removes-part ()
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "x.bin" "hello"))
           (entry (list :id "x.bin" :backend 'whisper :url (concat "file://" f)
                        :size 5 :sha256 (make-string 64 ?0))))
      (should-error (cmacs-speech-models-download entry :wait t))
      (let ((job (cmacs-speech-models-job "x.bin")))
        (should (eq (cmacs-speech-models-job-state job) 'failed))
        (should (string-match-p "checksum" (cmacs-speech-models-job-error job)))
        (should-not (file-exists-p (cmacs-speech-models-job-part job)))
        (should-not (file-exists-p (cmacs-speech-models-job-dest job)))))))

(ert-deftest cmacs-speech-models-test-size-mismatch ()
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "y.bin" "short"))
           (entry (list :id "y.bin" :backend 'whisper :url (concat "file://" f) :size 99)))
      (should-error (cmacs-speech-models-download entry :wait t))
      (should (string-match-p "expected 99"
                              (cmacs-speech-models-job-error (cmacs-speech-models-job "y.bin")))))))

(ert-deftest cmacs-speech-models-test-archive-extracts-to-model-dir ()
  "A tar.bz2 with one top directory becomes <store>/sherpa/<id>/."
  (cmacs-speech-models-test--store
    (let* ((top (expand-file-name "pkg/some-other-name" src)))
      (cmacs-speech-models-test--file top "tokens.txt" "a 0\n")
      (cmacs-speech-models-test--file top "model.onnx" "onnx")
      (let ((tar (expand-file-name "m.tar.bz2" src)))
        (should (zerop (call-process "tar" nil nil nil "-cjf" tar "-C"
                                     (expand-file-name "pkg" src) "some-other-name")))
        (let* ((entry (list :id "sherpa-onnx-test-model" :backend 'sherpa
                            :url (concat "file://" tar) :archive "tar.bz2"
                            :sha256 (cmacs-speech-models-test--sha tar)))
               (path (cmacs-speech-models-download entry :wait t)))
          (should (file-exists-p (expand-file-name "tokens.txt" path)))
          (should (string-suffix-p "sherpa/sherpa-onnx-test-model" path))
          (should-not (file-exists-p (concat path ".staging")))
          (should-not (file-exists-p (concat path ".part"))))))))

(ert-deftest cmacs-speech-models-test-single-onnx-gets-a-directory ()
  "A bare sherpa .onnx lands in a directory named by its id."
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "silero_vad.onnx" "vad"))
           (path (cmacs-speech-models-download
                  (list :id "silero_vad" :backend 'sherpa :url (concat "file://" f))
                  :wait t)))
      (should (file-exists-p (expand-file-name "silero_vad.onnx" path)))
      (should (eq (car (cmacs-speech-sherpa-model-spec path)) 'vad))
      (should (equal (mapcar #'car (cmacs-speech-sherpa-models 'vad)) '("silero_vad"))))))

(ert-deftest cmacs-speech-models-test-piper-extra-files ()
  "A piper voice brings its .onnx.json."
  (cmacs-speech-models-test--store
    (let* ((v (cmacs-speech-models-test--file src "en_XX-test-low.onnx" "voice"))
           (j (cmacs-speech-models-test--file src "en_XX-test-low.onnx.json" "{}"))
           (path (cmacs-speech-models-download
                  (list :id "en_XX-test-low.onnx" :backend 'piper :url (concat "file://" v)
                        :extra-files (list (list :name "en_XX-test-low.onnx.json"
                                                 :url (concat "file://" j))))
                  :wait t)))
      (should (file-exists-p path))
      (should (file-exists-p (concat path ".json"))))))

(ert-deftest cmacs-speech-models-test-already-installed ()
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "z.onnx" "z"))
           (entry (list :id "silero_vad" :backend 'sherpa :url (concat "file://" f))))
      (cmacs-speech-models-download entry :wait t)
      (should-error (cmacs-speech-models-download entry) :type 'user-error))))

(ert-deftest cmacs-speech-models-test-cancel-keeps-part ()
  "Cancelling stops the process and keeps the .part for a resume."
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "big.bin" (make-string 100 ?b)))
           (entry (list :id "big.bin" :backend 'whisper :url (concat "file://" f)))
           ;; A curl that writes a little and then waits, so there is a
           ;; download in flight to cancel.
           (cmacs-speech-models-curl-program
            (cmacs-speech-models-test--file
             src "fake-curl"
             "#!/bin/sh\nwhile [ \"$1\" != -o ]; do shift; done\nprintf partial > \"$2\"\nexec sleep 30\n")))
      (set-file-modes cmacs-speech-models-curl-program #o755)
      (let ((job (cmacs-speech-models-download entry)))
        (while (not (file-exists-p (concat (cmacs-speech-models-job-dest job) ".part")))
          (accept-process-output nil 0.05))
        (cmacs-speech-models-cancel "big.bin")
        (should (eq (cmacs-speech-models-job-state job) 'cancelled))
        (should (file-exists-p (cmacs-speech-models-job-part job)))
        (should-not (file-exists-p (cmacs-speech-models-job-dest job)))))))

(ert-deftest cmacs-speech-models-test-delete-to-trash-only-in-store ()
  (cmacs-speech-models-test--store
    (let* ((f (cmacs-speech-models-test--file src "q.onnx" "q"))
           (delete-by-moving-to-trash t)
           (trash-directory (expand-file-name "trash" root)))
      (cmacs-speech-models-download
       (list :id "silero_vad" :backend 'sherpa :url (concat "file://" f)) :wait t)
      (cmacs-speech-models-delete 'sherpa "silero_vad")
      (should-not (cmacs-speech-models-installed-path 'sherpa "silero_vad"))
      (should (file-exists-p trash-directory)))))

(ert-deftest cmacs-speech-models-test-extra-directories-searched ()
  "A model dropped into an extra tree shows up as installed and local."
  (cmacs-speech-models-test--store
    (let ((extra (expand-file-name "extra" root)))
      (cmacs-speech-models-test--file (expand-file-name "sherpa/my-silero_vad" extra)
                                      "silero_vad.onnx" "x")
      (let ((cmacs-speech-models-extra-directories (list extra))
            (cmacs-speech-sherpa--spec-cache (make-hash-table :test 'equal)))
        (let ((m (cl-find "my-silero_vad" (cmacs-speech-models :component 'vad)
                          :key (lambda (m) (plist-get m :id)) :test #'equal)))
          (should m)
          (should (plist-get m :local))
          (should (plist-get m :installed)))))))

(ert-deftest cmacs-speech-models-test-part-files-are-not-models ()
  "An in-flight download's .part / .staging never lists as a model."
  (cmacs-speech-models-test--store
    (let ((dir (car (cmacs-speech-model-dirs 'sherpa)))
          (cmacs-speech-sherpa--spec-cache (make-hash-table :test 'equal)))
      (cmacs-speech-models-test--file dir "sherpa-onnx-online-punct-en.part" "partial")
      (make-directory (expand-file-name "silero_vad.staging" dir) t)
      (cmacs-speech-models-test--file (expand-file-name "silero_vad.staging" dir)
                                      "silero_vad.onnx" "x")
      (should-not (cmacs-speech-sherpa-models)))))

(provide 'cmacs-speech-models-tests)
;;; cmacs-speech-models-tests.el ends here
