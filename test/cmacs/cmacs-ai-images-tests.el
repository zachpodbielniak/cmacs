;;; cmacs-ai-images-tests.el --- Image input for cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-ai-vision.el and cmacs/ai/cmacs-ai-vision.c: images
;; on every path that builds a user message, the "can this model see
;; it?" decision, in-memory captures behind the redaction rules, the
;; chat's image links, the ai_prompt / ai_call `images' parameter, and
;; "explain that" sending a crop with its OCR text.
;;
;; Two halves.  The C tests need this round's primitives and skip on
;; `fboundp' when the binary predates them: they read a real PNG through
;; `cmacs-ai-image-parts', append it to a real session and read the
;; AiImageContent back out, encode a capture with `cmacs-ai-png-encode',
;; and ask the probe about two providers.  Everything else stubs the C
;; (stubs take &rest) and runs on any binary.  No test talks to a model,
;; a compositor or the clipboard.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-ai-vision)
(require 'cmacs-ai-call)
(require 'cmacs-deixis-ask)
(require 'cmacs-redact)
(require 'cmacs-gowl-tools nil t)

;; These files may be in the dump, where `require' does not reload them:
;; a binary built before this round has the old definitions, and the
;; tests below would run against those.  Load the sources when the new
;; definitions are missing.
(dolist (cell '((cmacs-deixis-ask--images-p . "cmacs-deixis-ask")
                (cmacs-ai-output-followup-images . "cmacs-ai-output")))
  (unless (or (fboundp (car cell)) (boundp (car cell)))
    (load (locate-library (concat (cdr cell) ".el")) nil t t)))

(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)
(defvar cmacs-ai-default-provider)
(defvar cmacs-ai-default-model)
(defvar cmacs-mcp-workspace-root)
(defvar cmacs-deixis-ask-images)

(declare-function cmacs-ai-provider-image-input "cmacs-ai-vision.c"
                  (&optional provider))
(declare-function cmacs-ai-png-encode "cmacs-ai-vision.c"
                  (width height data &optional max-side))
(declare-function cmacs-ai-session-message-parts "cmacs-ai-vision.c"
                  (session &optional index))
(declare-function cmacs-ai-image-parts "cmacs-ai-vision.c" (images))
(declare-function cmacs-ai-tools--check-images "cmacs-ai-tools"
                  (images provider model))
(declare-function cmacs-ai-tools--images "cmacs-ai-tools" (images))
(declare-function cmacs-ai-chat--compose-images "cmacs-ai-chat" ())

;; The smallest valid PNG: 1x1, one opaque pixel.
(defconst cmacs-ai-images-tests--png
  (unibyte-string
   #x89 #x50 #x4e #x47 #x0d #x0a #x1a #x0a #x00 #x00 #x00 #x0d #x49 #x48
   #x44 #x52 #x00 #x00 #x00 #x01 #x00 #x00 #x00 #x01 #x08 #x06 #x00 #x00
   #x00 #x1f #x15 #xc4 #x89 #x00 #x00 #x00 #x0d #x49 #x44 #x41 #x54 #x78
   #x9c #x63 #xf8 #xcf #xc0 #xf0 #x1f #x00 #x05 #x00 #x01 #xff #x89 #x99
   #x3d #x1d #x00 #x00 #x00 #x00 #x49 #x45 #x4e #x44 #xae #x42 #x60 #x82)
  "A 1x1 PNG.")

(defmacro cmacs-ai-images-tests--with-probe (answers &rest body)
  "Run BODY with image input available and the C probe answering ANSWERS.
ANSWERS is an alist (PROVIDER . IMAGES-VALUE); a provider not in it
answers `unknown'.  :configured is t for every provider."
  (declare (indent 1))
  `(let ((cmacs-ai-vision-providers nil)
         (cmacs-ai-vision-model-overrides nil)
         (cmacs-ai-default-provider 'claude))
     (cl-letf (((symbol-function 'cmacs-ai-vision-available-p)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-ai-provider-image-input)
                (lambda (&optional provider &rest _)
                  (list :images (let ((a (assq provider ,answers)))
                                  (if a (cdr a) 'unknown))
                        :configured t)))
               ((symbol-function 'cmacs-ai-image-parts)
                (lambda (images &rest _)
                  (mapcar (lambda (_) '(:mime "image/png" :bytes 70))
                          images)))
               ((symbol-function 'cmacs-ai-providers)
                (lambda (&rest _)
                  '(claude openai ollama claude-code opencode))))
       ,@body)))


;;;; Which providers take images

(ert-deftest cmacs-ai-images-test-supported-p ()
  "The probe decides HTTP clients, the table CLI ones, a regexp ollama's."
  (cmacs-ai-images-tests--with-probe '((claude . t) (openai . t)
                                       (grok . nil) (ollama . t)
                                       (claude-code . cli)
                                       (opencode . cli))
    ;; The request builder keeps the image: yes.  Drops it: no.
    (should (cmacs-ai-vision-supported-p 'claude))
    (should-not (cmacs-ai-vision-supported-p 'grok))
    ;; A CLI client: the table.
    (should (cmacs-ai-vision-supported-p 'claude-code))
    (should-not (cmacs-ai-vision-supported-p 'opencode))
    ;; nil is the default provider.
    (should (cmacs-ai-vision-supported-p nil))
    ;; ollama: only a model that looks like a vision model, and never
    ;; "whatever the server defaults to".
    (should (cmacs-ai-vision-supported-p 'ollama "llava:13b"))
    (should (cmacs-ai-vision-supported-p 'ollama "qwen2.5vl:7b"))
    (should-not (cmacs-ai-vision-supported-p 'ollama "llama3.2"))
    (should-not (cmacs-ai-vision-supported-p 'ollama nil))
    ;; Unknown to the probe and to both tables: refused.
    (should-not (cmacs-ai-vision-supported-p 'laya))
    ;; Overrides win, per model first.
    (let ((cmacs-ai-vision-model-overrides '((ollama "\\`llama3\\.2" . t))))
      (should (cmacs-ai-vision-supported-p 'ollama "llama3.2")))
    (let ((cmacs-ai-vision-providers '((grok . t))))
      (should (cmacs-ai-vision-supported-p 'grok)))
    (let ((cmacs-ai-vision-model-overrides '((nil "special" . nil))))
      (should-not (cmacs-ai-vision-supported-p 'claude "special-1")))))

(ert-deftest cmacs-ai-images-test-named-providers ()
  "A named ACP agent is `acp'; a named endpoint is `openai-compatible'."
  (cmacs-ai-images-tests--with-probe '((my-agent . cli))
    (let ((cmacs-ai-acp-agents '((my-agent :command "true")))
          (cmacs-ai-openai-compatible-endpoints '((vllm :base-url "x"))))
      (should (eq (cmacs-ai-vision--kind 'my-agent) 'acp))
      (should (eq (cmacs-ai-vision--kind 'vllm) 'openai-compatible))
      (should (cmacs-ai-vision-supported-p 'my-agent))
      ;; The probe could not tell for the endpoint: the fallback table.
      (should (cmacs-ai-vision-supported-p 'vllm)))))

(ert-deftest cmacs-ai-images-test-unavailable-build ()
  "A binary without image input refuses every image, plainly."
  (cl-letf (((symbol-function 'cmacs-ai-vision-available-p)
             (lambda (&rest _) nil)))
    (should-not (cmacs-ai-vision-supported-p 'claude))
    (should (string-match-p "built without image input"
                            (cmacs-ai-vision-refusal 'claude)))))

(ert-deftest cmacs-ai-images-test-refusal-names-and-suggests ()
  "A refusal names the provider and model and the providers that can."
  (cmacs-ai-images-tests--with-probe '((claude . t) (openai . t)
                                       (opencode . cli) (claude-code . cli))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program &rest _) (equal program "claude"))))
      (let ((why (cmacs-ai-vision-refusal 'opencode "big-model")))
        (should (string-match-p "\\`opencode/big-model cannot take images"
                                why))
        (should (string-match-p "claude, openai, claude-code" why))
        ;; opencode's program is not installed and it cannot see anyway.
        (should-not (string-match-p "can: .*opencode" why))
        (should (string-match-p "cmacs-ai-vision-providers" why)))
      (should-not (cmacs-ai-vision-refusal 'claude "x"))
      ;; ollama's escape hatch is per model.
      (should (string-match-p "cmacs-ai-vision-model-overrides"
                              (cmacs-ai-vision-refusal 'ollama "llama3.2"))))))

(ert-deftest cmacs-ai-images-test-check-signals ()
  "`cmacs-ai-vision-check' signals a refusal and passes nil through."
  (cmacs-ai-images-tests--with-probe '((opencode . cli) (claude . t))
    (should-not (cmacs-ai-vision-check 'opencode nil nil))
    (should-error (cmacs-ai-vision-check 'opencode nil '((:file "/x.png")))
                  :type 'cmacs-ai-vision-refused)
    (should (equal (cmacs-ai-vision-check 'claude nil '((:file "/x.png")))
                   '((:file "/x.png"))))))


;;;; cmacs-ai-call

(ert-deftest cmacs-ai-images-test-call-passes-images ()
  "`cmacs-ai-call' :images reaches the primitive; no images, the old call."
  (cmacs-ai-images-tests--with-probe '((claude . t) (opencode . cli))
    (let ((calls nil))
      (cl-letf (((symbol-function 'cmacs-ai--call)
                 (lambda (&rest args) (push args calls) "ok")))
        (should (equal (cmacs-ai-call "what is this?" :provider 'claude
                                      :images '((:file "/a.png")))
                       "ok"))
        (should (equal (car calls)
                       '("what is this?" claude nil nil nil nil
                         ((:file "/a.png")))))
        ;; Without images the call is exactly what it was: no seventh
        ;; argument.  Natively compiled code pads a primitive's missing
        ;; optional arguments with nil before the call reaches this stub,
        ;; so "absent" arrives as a trailing nil there and as nothing in
        ;; interpreted code: the two are the same call.
        (cmacs-ai-call "hi" :provider 'claude)
        (should (<= (length (car calls)) 7))
        (should-not (nth 6 (car calls)))
        ;; A provider that cannot see: refused, nothing called.
        (setq calls nil)
        (should-error (cmacs-ai-call "what is this?" :provider 'opencode
                                     :images '((:file "/a.png")))
                      :type 'cmacs-ai-vision-refused)
        (should-not calls)))))


;;;; Captures and the redaction rules

(ert-deftest cmacs-ai-images-test-capture-region-refused ()
  "A region showing an excluded window is refused before any capture."
  (skip-unless (featurep 'cmacs-gowl-tools))
  (let ((captured nil) (as-model nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'cmacs-gowl-tools--region-guard)
               (lambda (&rest _)
                 (setq as-model cmacs-redact--as-model)
                 (error "That part of the screen shows a window the \
redaction rules withhold")))
              ((symbol-function 'gowl-screenshot-region)
               (lambda (&rest _) (setq captured t) nil)))
      (should-error (cmacs-ai-capture-region 10 10 100 100)
                    :type 'cmacs-ai-capture-refused)
      (should-not captured)
      ;; The guard was asked as a model asks.
      (should as-model))))

(ert-deftest cmacs-ai-images-test-capture-region-emacs-frame ()
  "A region over this Emacs's frame is refused while it shows an excluded buffer."
  (skip-unless (featurep 'cmacs-gowl-tools))
  (let ((captured nil) (asked nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'cmacs-gowl-tools--region-guard) #'ignore)
              ((symbol-function 'gowl-list-clients) (lambda (&rest _) '(c1)))
              ((symbol-function 'cmacs-gowl-tools--client-raw)
               (lambda (&rest _)
                 (list :pid (emacs-pid) :geometry '(0 0 800 600))))
              ((symbol-function 'cmacs-redact-capture-refused-p)
               (lambda (what &rest _) (setq asked what) t))
              ((symbol-function 'gowl-screenshot-region)
               (lambda (&rest _) (setq captured t) nil)))
      (should-error (cmacs-ai-capture-region 10 10 100 100)
                    :type 'cmacs-ai-capture-refused)
      (should (eq asked 'frame))
      (should-not captured)
      ;; Elsewhere on the screen the frame is not in the picture.
      (setq asked nil)
      (cl-letf (((symbol-function 'cmacs-ai-png-encode)
                 (lambda (&rest _) cmacs-ai-images-tests--png))
                ((symbol-function 'gowl-screenshot-region)
                 (lambda (&rest _) (setq captured t) (list 1 1 "abcd"))))
        (let ((cmacs-ai-capture-save-directory nil)
              (image (cmacs-ai-capture-region 900 10 100 100)))
          (should captured)
          (should-not asked)
          (should (equal (plist-get image :mime) "image/png"))
          ;; In memory only.
          (should-not (plist-get image :saved)))))))

(ert-deftest cmacs-ai-images-test-capture-saves-only-when-asked ()
  "`cmacs-ai-capture-save-directory' is the only way a capture reaches disk."
  (let* ((dir (make-temp-file "cmacs-ai-cap" t))
         (cmacs-ai-capture-save-directory dir))
    (unwind-protect
        (let ((image (cmacs-ai-capture--finish cmacs-ai-images-tests--png
                                               "region")))
          (should (file-exists-p (plist-get image :saved)))
          (should (= (logand (file-modes (plist-get image :saved)) #o077) 0)))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-images-test-capture-frame-refused ()
  "A frame showing an excluded buffer is not captured."
  (let ((exported nil))
    (cl-letf (((symbol-function 'cmacs-redact-capture-refused-p)
               (lambda (&rest _) t))
              ((symbol-function 'x-export-frames)
               (lambda (&rest _) (setq exported t) "")))
      (should-error (cmacs-ai-capture-frame) :type 'cmacs-ai-capture-refused)
      (should-not exported))))


;;;; Links in a chat's compose area

(ert-deftest cmacs-ai-images-test-compose-links ()
  "Image links become image specs; other links stay text."
  (with-temp-buffer
    (let* ((default-directory "/tmp/")
           (id (cmacs-ai-vision-hold '(:data "PNG" :mime "image/png")))
           (text (format "look at [[file:shot.png]] and [[./b.JPG][this]] \
and [[%s][capture]] but not [[file:notes.org]] or [[https://x/y.png]]"
                         id)))
      (should (equal (cmacs-ai-vision-compose-images text)
                     '((:file "/tmp/shot.png")
                       (:file "/tmp/b.JPG")
                       (:data "PNG" :mime "image/png"))))
      ;; A held image that is gone is an error, not a silent drop.
      (setq cmacs-ai-vision--held nil)
      (should-error (cmacs-ai-vision-compose-images (format "[[%s]]" id))
                    :type 'user-error))))

(ert-deftest cmacs-ai-images-test-chat-refusal-keeps-compose ()
  "A chat whose model cannot see refuses, and the compose text stays."
  (require 'cmacs-ai-chat)
  (cmacs-ai-images-tests--with-probe '((opencode . cli))
    (with-temp-buffer
      (insert "* Compose\n")
      (setq-local cmacs-ai-chat--compose-marker (point-marker))
      (setq-local cmacs-ai-chat-provider 'opencode)
      (setq-local cmacs-ai-chat-session-pair nil)
      (insert "what is [[file:/tmp/x.png]]?")
      (should-error (cmacs-ai-chat--compose-images) :type 'user-error)
      (should (string-match-p "x\\.png\\]\\]\\?\\'" (buffer-string)))
      ;; No link, no question asked.
      (delete-region cmacs-ai-chat--compose-marker (point-max))
      (insert "plain text")
      (should-not (cmacs-ai-chat--compose-images)))))


;;;; The ai_prompt / ai_call `images' argument

(ert-deftest cmacs-ai-images-test-tool-images-paths ()
  "Paths are held to the workspace, as project_read_file is."
  (require 'cmacs-ai-tools)
  (require 'cmacs-project-tools)
  ;; Loaded now, so the stubs below are not replaced by its definitions
  ;; when the code under test requires it.
  (require 'cmacs-core-tools)
  (let* ((root (file-name-as-directory (make-temp-file "cmacs-ai-ws" t)))
         (cmacs-mcp-workspace-root root))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region cmacs-ai-images-tests--png nil
                          (expand-file-name "shot.png" root)))
          (cl-letf (((symbol-function 'cmacs-core-tools-file-hidden-p)
                     (lambda (&rest _) nil)))
            (should (equal (cmacs-ai-tools--images '(((path . "shot.png"))))
                           (list (list :file (expand-file-name "shot.png"
                                                               root)))))
            ;; Out of the workspace: refused.
            (should-error (cmacs-ai-tools--images '(((path . "/etc/hostname")))))
            (should-error (cmacs-ai-tools--images '(((path . "../x.png")))))
            ;; Neither, or both.
            (should-error (cmacs-ai-tools--images '(((mime . "image/png")))))
            (should-error (cmacs-ai-tools--images
                           '(((path . "shot.png") (data . "AAAA")))))
            ;; Base64 data, decoded to bytes.
            (should (equal (cmacs-ai-tools--images
                            `(((data . ,(base64-encode-string
                                         cmacs-ai-images-tests--png))
                               (mime . "image/png"))))
                           (list (list :data cmacs-ai-images-tests--png
                                       :mime "image/png")))))
          ;; An excluded file answers as an unreadable one.
          (cl-letf (((symbol-function 'cmacs-core-tools-file-hidden-p)
                     (lambda (&rest _) t)))
            (should-error (cmacs-ai-tools--images '(((path . "shot.png")))))))
      (delete-directory root t))))

(ert-deftest cmacs-ai-images-test-tool-prompt-sends-images ()
  "ai_prompt with images streams them; a provider that cannot see is refused."
  (require 'cmacs-ai-tools)
  (require 'cmacs-ai)
  (cmacs-ai-images-tests--with-probe '((claude . t) (opencode . cli))
    (let ((streamed nil) (done-with nil))
      (cl-letf (((symbol-function 'cmacs-ai-client-new) (lambda (&rest _) 11))
                ((symbol-function 'cmacs-ai-client-free) #'ignore)
                ((symbol-function 'cmacs-ai-session-new) (lambda (&rest _) 22))
                ((symbol-function 'cmacs-ai-session-free) #'ignore)
                ((symbol-function 'cmacs-ai-chat-stream)
                 (lambda (&rest args) (setq streamed args) t)))
        (cmacs-ai-tools--one-shot (lambda (a) (setq done-with a))
                                  "what is it" 'claude nil nil nil
                                  '((:data "PNG" :mime "image/png")))
        (should (equal (nth 4 streamed) '((:data "PNG" :mime "image/png"))))
        (should (null (nth 3 streamed)))
        ;; The refusal comes before a client exists.
        (setq streamed nil)
        (should-error (cmacs-ai-tools--check-images
                       '((:data "PNG")) 'opencode nil))
        (should-not streamed)
        (should-not done-with)))))


;;;; "Explain that" with a picture

(defmacro cmacs-ai-images-tests--with-window (ocr-text capture &rest body)
  "Run BODY pointing at another program's window.
OCR reads OCR-TEXT; the region capture returns CAPTURE (a function of
the region, or a symbol: `refuse' signals the redaction refusal).  The
model takes images.  `regions' and `ocr-runs' record the calls."
  (declare (indent 2))
  `(let ((regions nil) (ocr-runs 0) (as-model nil)
         (capture-spec ,capture)
         (cmacs-deixis-ask-images t)
         (cmacs-deixis-ask-ocr-box '(400 . 200)))
     (ignore regions ocr-runs as-model)
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-client-info)
                (lambda (&rest _) '((id . 12) (geometry 100 50 1000 800))))
               ((symbol-function 'gowl-bar-notify) #'ignore)
               ((symbol-function 'gowl-client-pid) (lambda (&rest _) 4242))
               ((symbol-function 'cmacs-deixis-ask--denied-p) #'ignore)
               ((symbol-function 'cmacs-gowl-edit-field-focused-target)
                (lambda (&rest _) nil))
               ((symbol-function 'cmacs-redact-window)
                (lambda (app title &rest _) (cons app title)))
               ((symbol-function 'cmacs-redact-buffer-p) #'ignore)
               ((symbol-function 'cmacs-redact-text)
                (lambda (text &rest _) text))
               ((symbol-function 'cmacs-ai-vision-supported-p)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-ai-capture-region)
                (lambda (&rest region)
                  (push region regions)
                  (setq as-model cmacs-redact--as-model)
                  (cond ((eq capture-spec 'refuse)
                         (signal 'cmacs-ai-capture-refused nil))
                        ((functionp capture-spec)
                         (funcall capture-spec region))
                        (t capture-spec))))
               ((symbol-function 'cmacs-gowl-tools--screen-text)
                (lambda (done &rest _)
                  (setq ocr-runs (1+ ocr-runs))
                  (funcall done ,ocr-text))))
       ,@body)))

(defconst cmacs-ai-images-tests--window
  '(:kind window :device gowl :client c1 :client-id 12
    :app-id "org.example.Viewer" :title "Secret Plans" :x 500.0 :y 400.0)
  "Another program's window, pointed at near its middle.")

(defun cmacs-ai-images-tests--extract (referent &optional scope)
  "Run the extraction of REFERENT synchronously; return its result."
  (let ((out 'pending))
    (cmacs-deixis-ask-extract referent scope (lambda (r) (setq out r)))
    out))

(ert-deftest cmacs-ai-images-test-deixis-sends-crop-and-ocr ()
  "The OCR box is captured as a picture and sent with the OCR text."
  (cmacs-ai-images-tests--with-window "Q3 revenue" '(:data "PNG" :mime "image/png")
    (let ((r (cmacs-ai-images-tests--extract cmacs-ai-images-tests--window)))
      ;; The same box OCR reads: 400x200 around 500,400, inside the window.
      (should (equal regions '((300 300 400 200))))
      (should as-model)
      (should (= ocr-runs 1))
      (should (equal (plist-get r :text) "Q3 revenue"))
      (should (equal (plist-get r :image) '(:data "PNG" :mime "image/png")))
      ;; The window's identity stays home.
      (should-not (string-match-p "Secret\\|Viewer" (plist-get r :description)))
      (let ((prompt (cmacs-deixis-ask-compose "what is that" (list r))))
        (should (string-match-p "attached image 1" prompt))
        (should (string-match-p "Q3 revenue" prompt))))))

(ert-deftest cmacs-ai-images-test-deixis-picture-without-text ()
  "No text read is no longer unanswerable when there is a picture."
  (cmacs-ai-images-tests--with-window "" '(:data "PNG" :mime "image/png")
    (let ((r (cmacs-ai-images-tests--extract cmacs-ai-images-tests--window)))
      (should-not (plist-get r :failed))
      (should (plist-get r :image))
      (should (string-match-p "see the attached image"
                              (cmacs-deixis-ask-compose "what is that"
                                                        (list r)))))))

(ert-deftest cmacs-ai-images-test-deixis-capture-refused ()
  "An excluded window in the box refuses the question; nothing is read."
  (cmacs-ai-images-tests--with-window "words" 'refuse
    (let ((r (cmacs-ai-images-tests--extract cmacs-ai-images-tests--window)))
      (should (plist-get r :refused))
      (should (= ocr-runs 0)))))

(ert-deftest cmacs-ai-images-test-deixis-no-vision-unchanged ()
  "A model that cannot see: OCR only, and no picture is taken."
  (cmacs-ai-images-tests--with-window "words" '(:data "PNG")
    (cl-letf (((symbol-function 'cmacs-ai-vision-supported-p) #'ignore))
      (let ((r (cmacs-ai-images-tests--extract cmacs-ai-images-tests--window)))
        (should-not regions)
        (should-not (plist-get r :image))
        (should (eq (plist-get r :source) 'ocr))
        (should (equal (plist-get r :text) "words"))))))

(ert-deftest cmacs-ai-images-test-deixis-compare-sends-two ()
  "\"Compare this and that\" sends two crops, in spoken order."
  (cmacs-ai-images-tests--with-window "text"
      (lambda (region) (list :data (format "PNG-%d" (car region))
                             :mime "image/png"))
    (let ((sent nil)
          (cmacs-ai-textops-provider 'claude)
          (cmacs-ai-textops-model nil)
          (other (plist-put (copy-sequence cmacs-ai-images-tests--window)
                            :x 900.0)))
      (cl-letf (((symbol-function 'cmacs-ai-textops-stream)
                 (lambda (&rest args) (setq sent args) (get-buffer-create
                                                        " *rig-images*"))))
        (cmacs-deixis-ask-run "compare this and that"
                              (list cmacs-ai-images-tests--window other))
        (should sent)
        (should (equal (nth 5 sent)
                       '((:data "PNG-300" :mime "image/png")
                         (:data "PNG-700" :mime "image/png"))))
        (should (string-match-p "attached image 1.*\n\\(.*\n\\)*.*attached image 2"
                                (nth 3 sent)))))))


;;;; The C half (this round's primitives)

(ert-deftest cmacs-ai-images-test-c-image-parts ()
  "A file's bytes become an image block; oversize and non-images are refused."
  (skip-unless (fboundp 'cmacs-ai-image-parts))
  (let ((file (make-temp-file "cmacs-ai-img" nil ".bin")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region cmacs-ai-images-tests--png nil file))
          ;; The type comes from the bytes, not the name.
          (should (equal (cmacs-ai-image-parts `((:file ,file)))
                         `((:mime "image/png"
                            :bytes ,(length cmacs-ai-images-tests--png)))))
          ;; One plist alone is a list of one; "image/jpg" and parameters
          ;; are normalised before they are compared.
          (should (cmacs-ai-image-parts
                   (list :data cmacs-ai-images-tests--png
                         :mime "image/png; q=1")))
          (should-error (cmacs-ai-image-parts
                         (list :data cmacs-ai-images-tests--png
                               :mime "image/jpg"))
                        :type 'cmacs-ai-error)
          (let ((cmacs-ai-image-max-bytes 10))
            (should-error (cmacs-ai-image-parts `((:file ,file)))
                          :type 'cmacs-ai-error))
          (should-error (cmacs-ai-image-parts '((:data "not a picture")))
                        :type 'cmacs-ai-error)
          (should-error (cmacs-ai-image-parts
                         (list (list :data (string-to-multibyte "\x89PNG"))))
                        :type 'cmacs-ai-error)
          (should-error (cmacs-ai-image-parts `((:file ,temporary-file-directory)))
                        :type 'cmacs-ai-error)
          (let ((cmacs-ai-image-max-count 1))
            (should-error (cmacs-ai-image-parts `((:file ,file) (:file ,file)))
                          :type 'cmacs-ai-error)))
      (delete-file file))))

(ert-deftest cmacs-ai-images-test-c-session-carries-image ()
  "The bytes reach an AiImageContent on the session's user message."
  (skip-unless (and (fboundp 'cmacs-ai-session-message-parts)
                    (fboundp 'cmacs-ai-client-new)))
  (let* ((client (cmacs-ai-client-new 'openai))
         (session (cmacs-ai-session-new client)))
    (unwind-protect
        (progn
          (cmacs-ai-session-append-message
           session 'user "what is this?"
           (list (list :data cmacs-ai-images-tests--png :mime "image/png")))
          (should (equal (cmacs-ai-session-message-parts session)
                         `((text "what is this?")
                           (image :mime "image/png"
                                  :bytes ,(length cmacs-ai-images-tests--png)))))
          ;; A refused image adds nothing to the history.
          (should-error (cmacs-ai-session-append-message
                         session 'user "again" '((:data "nope")))
                        :type 'cmacs-ai-error)
          (should (= (cmacs-ai-session-message-count session) 1))
          (should-error (cmacs-ai-session-append-message
                         session 'assistant "no" '((:data "x")))))
      (cmacs-ai-session-free session)
      (cmacs-ai-client-free client))))

(ert-deftest cmacs-ai-images-test-c-png-encode ()
  "A capture's ARGB32 rows encode to a PNG in memory, scaled when asked."
  (skip-unless (fboundp 'cmacs-ai-png-encode))
  (let* ((pixels (apply #'unibyte-string
                        (make-list (* 4 4 4) #xff)))
         (png (cmacs-ai-png-encode 4 4 pixels))
         (small (cmacs-ai-png-encode 4 4 pixels 2)))
    (should (string-prefix-p "\x89PNG" png))
    (should (equal (car (cmacs-ai-image-parts (list :data png)))
                   (list :mime "image/png" :bytes (length png))))
    (should (string-prefix-p "\x89PNG" small))
    (should-error (cmacs-ai-png-encode 4 4 "short"))))

(ert-deftest cmacs-ai-images-test-c-probe ()
  "The probe looks at what ai-glib's request builder really does."
  (skip-unless (fboundp 'cmacs-ai-provider-image-input))
  ;; OpenAI's builder writes image_url data URLs.
  (should (eq (plist-get (cmacs-ai-provider-image-input 'openai) :images) t))
  ;; Claude's writes Anthropic image blocks (ai-glib >= 0.13.0).
  (should (eq (plist-get (cmacs-ai-provider-image-input 'claude) :images) t))
  ;; A CLI client has no body to look at.
  (should (eq (plist-get (cmacs-ai-provider-image-input 'claude-code) :images)
              'cli)))

(provide 'cmacs-ai-images-tests)

;;; cmacs-ai-images-tests.el ends here
