;;; cmacs-gowl-edit-field-tests.el --- Tests for editing foreign text fields -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-edit-field' pops another application's text field into
;; an Emacs buffer and commits it back.  Most of what can go wrong in
;; it is arithmetic and policy, and that is what is tested here against
;; a fake compositor: bytes against characters (the compositor speaks
;; UTF-8 offsets, a buffer speaks characters), the edit computed from
;; the old text and its cursor -- checked by APPLYING it, byte for
;; byte, the way an application would -- the deny lists, what happens
;; to a partial read, the editor frame's parameters, and the commit
;; that refuses to overwrite a field that changed.
;;
;; Every stub of a C DEFUN takes `&rest': a stub with a fixed arity
;; breaks under `make check-cmacs' the day the DEFUN gains an argument.
;;
;; The last tests need the new primitives.  One runs them with no
;; compositor; the other starts a real one in a SECOND cmacs on
;; wlroots' headless backend with a private runtime directory -- never
;; the session this runs in.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)
(require 'cmacs-gowl-edit-field)

(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-client-has-text-input-p "cmacs-gowl-textfield")
(declare-function gowl-text-field-read "cmacs-gowl-textfield")
(declare-function gowl-text-field-replace "cmacs-gowl-textfield")
(declare-function gowl-text-field-send-key "cmacs-gowl-textfield")
(declare-function gowl-clipboard-set-transient "cmacs-gowl-textfield")

;; Special, so `let' binds them dynamically and `add-hook' lands in the
;; binding (cmacs-gowl.el, which defines them, is not loaded here).
(defvar cmacs-gowl-focus-changed-functions)
(defvar cmacs-gowl-client-removed-functions)

;;;; A fake compositor

(defvar cmacs-gowl-edit-field-tests--calls nil
  "What the code under test asked the fake compositor, newest first.")

(defvar cmacs-gowl-edit-field-tests--focused 'origin
  "The window the fake compositor says holds the keyboard.")

(defvar cmacs-gowl-edit-field-tests--clients
  '((origin . ((id . 7) (title . "Reply - Browser") (app-id . "librewolf")
               (floating . nil) (embedded . nil)
               (geometry . (100 100 800 600)))))
  "The fake compositor's windows, an alist of (CLIENT . INFO).")

(defvar cmacs-gowl-edit-field-tests--clipboard nil
  "The fake clipboard.")

(defvar cmacs-gowl-edit-field-tests--messages nil
  "What was said to the user, newest first.")

(defun cmacs-gowl-edit-field-tests--called (name)
  "Return the argument lists of the recorded calls to NAME, oldest first."
  (nreverse (cl-loop for (n . args) in cmacs-gowl-edit-field-tests--calls
                     when (eq n name) collect args)))

(defmacro cmacs-gowl-edit-field-tests--with-gowl (&rest body)
  "Run BODY against a fake compositor with one window, `origin', focused."
  (declare (indent 0) (debug t))
  `(let ((cmacs-gowl-edit-field-tests--calls nil)
         (cmacs-gowl-edit-field-tests--focused 'origin)
         (cmacs-gowl-edit-field-tests--clients
          (copy-tree cmacs-gowl-edit-field-tests--clients))
         (cmacs-gowl-edit-field-tests--clipboard "the user's clipboard")
         (cmacs-gowl-edit-field-tests--messages nil)
         (cmacs-gowl-edit-field--sessions nil)
         (cmacs-gowl-edit-field--waiters nil)
         (cmacs-gowl-focus-changed-functions nil)
         (cmacs-gowl-client-removed-functions nil)
         (delete-frame-functions nil)
         (kill-ring nil))
     (cl-letf* (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                ((symbol-function 'gowl-focused-client)
                 (lambda (&rest _) cmacs-gowl-edit-field-tests--focused))
                ((symbol-function 'gowl-focus-client)
                 (lambda (&rest args)
                   (push (cons 'focus args)
                         cmacs-gowl-edit-field-tests--calls)
                   t))
                ((symbol-function 'gowl-list-clients)
                 (lambda (&rest _)
                   (mapcar #'car cmacs-gowl-edit-field-tests--clients)))
                ((symbol-function 'gowl-client-info)
                 (lambda (&rest args)
                   (alist-get (car args)
                              cmacs-gowl-edit-field-tests--clients)))
                ((symbol-function 'gowl-client-pid) (lambda (&rest _) 4242))
                ((symbol-function 'gowl-text-field-read)
                 (lambda (&rest args)
                   (push (cons 'read args)
                         cmacs-gowl-edit-field-tests--calls)
                   'pending))
                ((symbol-function 'gowl-text-field-replace)
                 (lambda (&rest args)
                   (push (cons 'replace args)
                         cmacs-gowl-edit-field-tests--calls)
                   'pending))
                ((symbol-function 'gowl-text-field-send-key)
                 (lambda (&rest args)
                   (push (cons 'key args)
                         cmacs-gowl-edit-field-tests--calls)
                   t))
                ((symbol-function 'gowl-clipboard-get)
                 (lambda (&rest _) cmacs-gowl-edit-field-tests--clipboard))
                ((symbol-function 'gowl-clipboard-set-transient)
                 (lambda (&rest args)
                   (push (cons 'clipboard args)
                         cmacs-gowl-edit-field-tests--calls)
                   (setq cmacs-gowl-edit-field-tests--clipboard (car args))
                   nil))
                ;; No frames in a batch run: the editor is "shown" by
                ;; being recorded.
                ((symbol-function 'cmacs-gowl-edit-field--show)
                 (lambda (&rest args)
                   (push (cons 'show args)
                         cmacs-gowl-edit-field-tests--calls)))
                ;; Timers do not run by themselves in a test: what one
                ;; would have run is recorded, to be called by hand.
                ((symbol-function 'run-at-time)
                 (lambda (&rest args)
                   (push (cons 'timer (cddr args))
                         cmacs-gowl-edit-field-tests--calls)
                   nil))
                ((symbol-function 'message)
                 (lambda (&rest args)
                   (when (car args)
                     (push (apply #'format-message args)
                           cmacs-gowl-edit-field-tests--messages))
                   nil)))
       (unwind-protect
           (progn ,@body)
         (dolist (session cmacs-gowl-edit-field--sessions)
           (let ((buffer (cmacs-gowl-edit-field--session-buffer session)))
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq cmacs-gowl-edit-field--session nil))
               (kill-buffer buffer))))))))

(defun cmacs-gowl-edit-field-tests--answer (name result)
  "Call the callback of the last recorded call to NAME with RESULT."
  (let ((args (car (last (cmacs-gowl-edit-field-tests--called name)))))
    (funcall (car (last args)) result)))

(defun cmacs-gowl-edit-field-tests--start (result)
  "Run the command and answer its read with RESULT; return the session."
  (cmacs-gowl-edit-field)
  (let ((session (car cmacs-gowl-edit-field--sessions)))
    (cmacs-gowl-edit-field-tests--answer 'read result)
    session))

(defun cmacs-gowl-edit-field-tests--ok (text cursor &optional anchor partial)
  "Return a successful read of TEXT with CURSOR and ANCHOR, in bytes."
  (list :status 'ok :text text :cursor cursor :anchor (or anchor cursor)
        :complete (not partial) :hint 0 :purpose 0))

;;;; Bytes and characters

(ert-deftest cmacs-gowl-edit-field-test-utf8-length ()
  "Characters are counted as the bytes UTF-8 gives them."
  (should (= 0 (cmacs-gowl-edit-field--utf8-length "")))
  (should (= 5 (cmacs-gowl-edit-field--utf8-length "hello")))
  ;; e-acute 2, a CJK character 3, an emoji 4.
  (should (= 2 (cmacs-gowl-edit-field--utf8-length "é")))
  (should (= 3 (cmacs-gowl-edit-field--utf8-length "日")))
  (should (= 4 (cmacs-gowl-edit-field--utf8-length "\U0001f600")))
  (should (= 10 (cmacs-gowl-edit-field--utf8-length
                 "aé日\U0001f600")))
  ;; A part of a string, by character index.
  (should (= 5 (cmacs-gowl-edit-field--utf8-length
                "aé日\U0001f600" 1 3)))
  ;; And it agrees with the encoder on text it has never seen.
  (dolist (s '("naïve café" "日本語" "x\U0001f600y"
               "русский"))
    (should (= (string-bytes (encode-coding-string s 'utf-8 t))
               (cmacs-gowl-edit-field--utf8-length s)))))

(ert-deftest cmacs-gowl-edit-field-test-byte-to-char ()
  "A byte offset becomes the index of the character that starts there."
  (let ((text "aé日\U0001f600z"))   ; 1 + 2 + 3 + 4 + 1 bytes
    (should (= 0 (cmacs-gowl-edit-field--byte-to-char text 0)))
    (should (= 1 (cmacs-gowl-edit-field--byte-to-char text 1)))
    (should (= 2 (cmacs-gowl-edit-field--byte-to-char text 3)))
    (should (= 3 (cmacs-gowl-edit-field--byte-to-char text 6)))
    (should (= 4 (cmacs-gowl-edit-field--byte-to-char text 10)))
    (should (= 5 (cmacs-gowl-edit-field--byte-to-char text 11)))
    ;; Inside a character: the start of that character.
    (should (= 1 (cmacs-gowl-edit-field--byte-to-char text 2)))
    (should (= 2 (cmacs-gowl-edit-field--byte-to-char text 5)))
    (should (= 3 (cmacs-gowl-edit-field--byte-to-char text 9)))
    ;; Past the end: the end.
    (should (= 5 (cmacs-gowl-edit-field--byte-to-char text 9999)))
    (should (= 0 (cmacs-gowl-edit-field--byte-to-char "" 3)))))

(ert-deftest cmacs-gowl-edit-field-test-char-to-byte ()
  "A character index becomes its byte offset, and the two round-trip."
  (let ((text "aé日\U0001f600z"))
    (should (equal '(0 1 3 6 10 11)
                   (mapcar (lambda (i)
                             (cmacs-gowl-edit-field--char-to-byte text i))
                           '(0 1 2 3 4 5))))
    (should (= 11 (cmacs-gowl-edit-field--char-to-byte text 99)))
    (should (= 0 (cmacs-gowl-edit-field--char-to-byte text -1)))
    (dotimes (i (1+ (length text)))
      (should (= i (cmacs-gowl-edit-field--byte-to-char
                    text (cmacs-gowl-edit-field--char-to-byte text i)))))))

;;;; The edit

(defun cmacs-gowl-edit-field-tests--apply (old cursor edit)
  "Apply EDIT to OLD as an application would, with its cursor at byte CURSOR.
EDIT is (DELETE-BEFORE DELETE-AFTER INSERT): bytes are removed either
side of the cursor and INSERT put there.  Works on the encoded text, so
an edit that cut a character in half shows up as a decoding difference."
  (let* ((bytes (encode-coding-string old 'utf-8 t))
         (from (- cursor (nth 0 edit)))
         (to (+ cursor (nth 1 edit))))
    (should (<= 0 from))
    (should (<= to (length bytes)))
    (decode-coding-string
     (concat (substring bytes 0 from)
             (encode-coding-string (nth 2 edit) 'utf-8 t)
             (substring bytes to))
     'utf-8 t)))

(ert-deftest cmacs-gowl-edit-field-test-replace-unchanged ()
  "Text that did not change is no edit at all."
  (should-not (cmacs-gowl-edit-field--compute-replace "same" "same" 2))
  (should-not (cmacs-gowl-edit-field--compute-replace "" "" 0)))

(ert-deftest cmacs-gowl-edit-field-test-replace-arguments ()
  "The edit is measured from the cursor and leaves shared text alone."
  ;; One word changed in the middle, cursor inside it.
  (should (equal '(2 3 "green")
                 (cmacs-gowl-edit-field--compute-replace
                  "the black cat" "the green cat" 6)))
  ;; Cursor at the start: nothing can be kept before it, so everything
  ;; up to the shared tail goes, after the cursor.
  (should (equal '(0 9 "the green")
                 (cmacs-gowl-edit-field--compute-replace
                  "the black cat" "the green cat" 0)))
  ;; Cursor at the end: nothing can be kept after it.
  (should (equal '(9 0 "green cat")
                 (cmacs-gowl-edit-field--compute-replace
                  "the black cat" "the green cat" 13)))
  ;; Appending at the cursor deletes nothing.
  (should (equal '(0 0 " world")
                 (cmacs-gowl-edit-field--compute-replace
                  "hello" "hello world" 5)))
  ;; Emptying the field deletes all of it, both ways from the cursor.
  (should (equal '(2 3 "")
                 (cmacs-gowl-edit-field--compute-replace "hello" "" 2)))
  ;; Filling an empty one inserts.
  (should (equal '(0 0 "hi")
                 (cmacs-gowl-edit-field--compute-replace "" "hi" 0)))
  ;; Counts are bytes: e-acute is two, and the cursor sits after it.
  (should (equal '(2 0 "e")
                 (cmacs-gowl-edit-field--compute-replace
                  "café!" "cafe!" 5))))

(ert-deftest cmacs-gowl-edit-field-test-replace-applies ()
  "Applying the computed edit to the old text always gives the new text.
Every cursor position of every pair, multibyte text included: this is
the property the commit depends on."
  (let ((texts '("" "a" "hello world" "the black cat"
                 "café au lait" "日本語の文"
                 "x\U0001f600y\U0001f600z" "aaaa" "abab" "line one\nline two"
                 "naïve \U0001f600 日")))
    (dolist (old texts)
      (dolist (new texts)
        (dotimes (i (1+ (length old)))
          (let* ((cursor (cmacs-gowl-edit-field--char-to-byte old i))
                 (edit (cmacs-gowl-edit-field--compute-replace
                        old new cursor)))
            (if (string= old new)
                (should-not edit)
              (should (equal new (cmacs-gowl-edit-field-tests--apply
                                  old cursor edit))))))))))

(ert-deftest cmacs-gowl-edit-field-test-replace-mid-character-cursor ()
  "A cursor reported inside a character is read as the start of it."
  (let* ((old "a日b")
         (edit (cmacs-gowl-edit-field--compute-replace old "a月b" 2)))
    ;; Byte 2 is inside the 3-byte character at byte 1: the edit is
    ;; measured from byte 1.
    (should (equal "a月b"
                   (cmacs-gowl-edit-field-tests--apply old 1 edit)))))

;;;; Policy

(ert-deftest cmacs-gowl-edit-field-test-deny ()
  "Password managers and prompts are denied by app-id or by title."
  (should (cmacs-gowl-edit-field--denied-p "org.keepassxc.KeePassXC" "x"))
  (should (cmacs-gowl-edit-field--denied-p "KeePassXC" nil))
  (should (cmacs-gowl-edit-field--denied-p "com.bitwarden.desktop" ""))
  (should (cmacs-gowl-edit-field--denied-p "pinentry-gnome3" "Passphrase"))
  (should (cmacs-gowl-edit-field--denied-p "gowl-lock" nil))
  ;; By title alone, whatever the case.
  (should (cmacs-gowl-edit-field--denied-p "librewolf" "Enter PASSWORD"))
  (should-not (cmacs-gowl-edit-field--denied-p "librewolf" "Reply - Forum"))
  (should-not (cmacs-gowl-edit-field--denied-p nil nil))
  ;; The list is the user's.
  (let ((cmacs-gowl-edit-field-deny '("\\`secret\\.")))
    (should (cmacs-gowl-edit-field--denied-p "secret.app" nil))
    (should-not (cmacs-gowl-edit-field--denied-p "org.keepassxc.KeePassXC"
                                                 nil)))
  (let ((cmacs-gowl-edit-field-deny nil))
    (should-not (cmacs-gowl-edit-field--denied-p "keepassxc" "password"))))

(ert-deftest cmacs-gowl-edit-field-test-fallback-policy ()
  "The clipboard fallback is never used on a terminal or a denied window."
  (let ((cmacs-gowl-edit-field-fallback 'clipboard))
    (should (cmacs-gowl-edit-field--fallback-allowed-p "librewolf" "Reply"))
    (dolist (terminal '("gst" "foot" "footclient" "kitty" "Alacritty"
                        "org.gnome.Terminal" "org.kde.konsole"
                        "org.wezfurlong.wezterm" "com.mitchellh.ghostty"
                        "tui.htop"))
      (should-not (cmacs-gowl-edit-field--fallback-allowed-p terminal "sh")))
    ;; An anchored name does not catch a longer one.
    (should (cmacs-gowl-edit-field--fallback-allowed-p "gstreamer-app" "x"))
    ;; The main deny list applies to the fallback too.
    (should-not (cmacs-gowl-edit-field--fallback-allowed-p "keepassxc" "x")))
  (let ((cmacs-gowl-edit-field-fallback nil))
    (should-not (cmacs-gowl-edit-field--fallback-allowed-p "librewolf" "x"))))

(ert-deftest cmacs-gowl-edit-field-test-sensitive ()
  "A field its application marks as a secret is recognised."
  (should (cmacs-gowl-edit-field--sensitive-p '(:purpose 8 :hint 0)))
  (should (cmacs-gowl-edit-field--sensitive-p '(:purpose 9 :hint 0)))
  (should (cmacs-gowl-edit-field--sensitive-p '(:purpose 0 :hint #x40)))
  (should (cmacs-gowl-edit-field--sensitive-p '(:purpose 0 :hint #x82)))
  (should-not (cmacs-gowl-edit-field--sensitive-p '(:purpose 0 :hint 0)))
  ;; Spellcheck + multiline, an e-mail purpose: ordinary fields.
  (should-not (cmacs-gowl-edit-field--sensitive-p '(:purpose 6 :hint #x202)))
  (should-not (cmacs-gowl-edit-field--sensitive-p '(:status no-field))))

(ert-deftest cmacs-gowl-edit-field-test-mode-for ()
  "The mode follows the application, when that mode exists."
  (let ((cmacs-gowl-edit-field-major-mode #'text-mode)
        (cmacs-gowl-edit-field-mode-alist
         '(("discord\\|element" . cmacs-gowl-edit-field-tests--chat-mode)
           ("mail" . cmacs-gowl-edit-field-tests--no-such-mode))))
    (cl-letf (((symbol-function 'cmacs-gowl-edit-field-tests--chat-mode)
               #'ignore))
      (should (eq 'cmacs-gowl-edit-field-tests--chat-mode
                  (cmacs-gowl-edit-field--mode-for "com.discordapp.Discord")))
      (should (eq 'cmacs-gowl-edit-field-tests--chat-mode
                  (cmacs-gowl-edit-field--mode-for "im.riot.Element"))))
    ;; A mode that is not installed is passed over, not called.
    (should (eq #'text-mode (cmacs-gowl-edit-field--mode-for "geary-mail")))
    (should (eq #'text-mode
                (cmacs-gowl-edit-field--mode-for "com.discordapp.Discord")))
    (should (eq #'text-mode (cmacs-gowl-edit-field--mode-for "librewolf")))
    (should (eq #'text-mode (cmacs-gowl-edit-field--mode-for nil)))))

;;;; The frame

(ert-deftest cmacs-gowl-edit-field-test-frame-parameters ()
  "The editor frame is named for the float rule, bare, and sized by option."
  (let* ((cmacs-gowl-edit-field-frame-name "cmacs-edit-field")
         (cmacs-gowl-edit-field-frame-width 90)
         (cmacs-gowl-edit-field-frame-height 20)
         (cmacs-gowl-edit-field-frame-minibuffer t)
         (cmacs-gowl-edit-field-frame-parameters nil)
         (params (cmacs-gowl-edit-field--frame-parameters)))
    (should (equal "cmacs-edit-field" (alist-get 'name params)))
    (should (= 90 (alist-get 'width params)))
    (should (= 20 (alist-get 'height params)))
    (should (eq t (alist-get 'minibuffer params)))
    (should (= 0 (alist-get 'tab-bar-lines params)))
    (should (= 0 (alist-get 'tool-bar-lines params)))
    (should (= 0 (alist-get 'menu-bar-lines params)))
    (should (alist-get 'cmacs-edit-field params))
    ;; No parameter twice: `make-frame' takes the first, and a second
    ;; would hide which one won.
    (should (= (length params)
               (length (cl-remove-duplicates (mapcar #'car params)))))))

(ert-deftest cmacs-gowl-edit-field-test-frame-parameters-user ()
  "The user's parameters win, except the name the float rule matches."
  (let* ((cmacs-gowl-edit-field-frame-name "cmacs-edit-field")
         (cmacs-gowl-edit-field-frame-minibuffer nil)
         (cmacs-gowl-edit-field-frame-parameters
          '((name . "mine") (width . 60) (alpha-background . 90)))
         (params (cmacs-gowl-edit-field--frame-parameters)))
    (should (equal "cmacs-edit-field" (alist-get 'name params)))
    (should (= 1 (cl-count 'name params :key #'car)))
    (should (= 60 (alist-get 'width params)))
    (should (= 1 (cl-count 'width params :key #'car)))
    (should (= 90 (alist-get 'alpha-background params)))
    ;; nil is a value here ("borrow the main frame's"), not "unset".
    (should (assq 'minibuffer params))
    (should-not (alist-get 'minibuffer params))
    ;; The option itself is not eaten by building the list.
    (should (equal "mine"
                   (alist-get 'name cmacs-gowl-edit-field-frame-parameters)))))

(ert-deftest cmacs-gowl-edit-field-test-float-rule ()
  "The rule floats exactly the frame's title, centred, and nothing more."
  (let* ((cmacs-gowl-edit-field-frame-name "cmacs-edit-field")
         (rule (cmacs-gowl-edit-field--float-rule)))
    (should (equal "cmacs-edit-field" (alist-get 'title rule)))
    (should (eq t (alist-get 'floating rule)))
    (should (eq t (alist-get 'center rule)))
    ;; Matched on the title alone: every Emacs frame has the same app-id.
    (should-not (assq 'app-id rule))
    ;; No tags and no `focus': a rule that views the tags it assigns
    ;; must not be handed "no tags" to view.
    (should-not (assq 'tags rule))
    (should-not (assq 'focus rule))))

(ert-deftest cmacs-gowl-edit-field-test-centre ()
  "The editor is centred over its window, and kept on the screen."
  (should (equal '(300 . 250)
                 (cmacs-gowl-edit-field--centre 400 300 '(100 100 800 600)
                                                nil)))
  ;; A small window in a corner: centred over it the editor would hang
  ;; off the screen, so it is pulled in.
  (should (equal '(0 . 30)
                 (cmacs-gowl-edit-field--centre 400 300 '(0 30 100 100)
                                                '(0 30 1920 1050))))
  (should (equal '(1520 . 780)
                 (cmacs-gowl-edit-field--centre 400 300 '(1800 1000 100 80)
                                                '(0 30 1920 1050))))
  ;; A second output, to the right.
  (should (equal '(2420 . 350)
                 (cmacs-gowl-edit-field--centre 400 300 '(2120 100 1000 800)
                                                '(1920 0 1920 1080)))))

(ert-deftest cmacs-gowl-edit-field-test-buffer-name ()
  "The buffer is named for the window, however long or absent its title."
  (should (equal "*edit-field: Reply*"
                 (cmacs-gowl-edit-field--buffer-name "Reply")))
  (should (equal "*edit-field: untitled*"
                 (cmacs-gowl-edit-field--buffer-name "")))
  (should (equal "*edit-field: untitled*"
                 (cmacs-gowl-edit-field--buffer-name nil)))
  (should (< (length (cmacs-gowl-edit-field--buffer-name
                      (make-string 300 ?x)))
             70)))

;;;; Reading

(ert-deftest cmacs-gowl-edit-field-test-needs-the-compositor ()
  "Outside gowl the command says what it needs and starts nothing."
  (cmacs-gowl-edit-field-tests--with-gowl
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (should-not (cmacs-gowl-edit-field))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'read))
      (should (string-match-p "needs the gowl compositor"
                              (car cmacs-gowl-edit-field-tests--messages))))))

(ert-deftest cmacs-gowl-edit-field-test-refuses-emacs-itself ()
  "With the keyboard in one of Emacs's own frames there is nothing to pop."
  (cmacs-gowl-edit-field-tests--with-gowl
    (cl-letf (((symbol-function 'gowl-client-pid)
               (lambda (&rest _) (emacs-pid))))
      (cmacs-gowl-edit-field)
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'read))
      (should (string-match-p "in Emacs already"
                              (car cmacs-gowl-edit-field-tests--messages))))))

(ert-deftest cmacs-gowl-edit-field-test-deny-stops-before-reading ()
  "A denied window is never asked for its text, by either path."
  (cmacs-gowl-edit-field-tests--with-gowl
    (setf (alist-get 'app-id (alist-get 'origin
                                        cmacs-gowl-edit-field-tests--clients))
          "org.keepassxc.KeePassXC")
    (cmacs-gowl-edit-field)
    (should-not cmacs-gowl-edit-field--sessions)
    (should-not (cmacs-gowl-edit-field-tests--called 'read))
    (should-not (cmacs-gowl-edit-field-tests--called 'key))
    (should-not (cmacs-gowl-edit-field-tests--called 'clipboard))))

(ert-deftest cmacs-gowl-edit-field-test-read-opens-at-the-cursor ()
  "The text opens with point at the field's cursor, converted from bytes."
  (cmacs-gowl-edit-field-tests--with-gowl
    ;; "caf<e-acute> " is 6 bytes, 5 characters.
    (let* ((text "café au lait")
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok text 6)))
           (buffer (cmacs-gowl-edit-field--session-buffer session)))
      (should (eq 'editing (cmacs-gowl-edit-field--session-state session)))
      (should (eq 'text-input
                  (cmacs-gowl-edit-field--session-method session)))
      (should (= 6 (cmacs-gowl-edit-field--session-cursor session)))
      (should (cmacs-gowl-edit-field-tests--called 'show))
      (with-current-buffer buffer
        (should (equal text (buffer-string)))
        (should (= (+ (point-min) 5) (point)))
        (should-not mark-active)
        (should-not (buffer-modified-p))
        (should cmacs-gowl-edit-field-mode)
        (should (string-match-p "\\`\\*edit-field: Reply - Browser\\*"
                                (buffer-name)))
        ;; The keys the header line promises.
        (should (eq #'cmacs-gowl-edit-field-finish
                    (key-binding (kbd "C-c C-c"))))
        (should (eq #'cmacs-gowl-edit-field-abort
                    (key-binding (kbd "C-c C-k"))))
        (should (eq #'cmacs-gowl-edit-field-finish
                    (key-binding (kbd "C-x #"))))))))

(ert-deftest cmacs-gowl-edit-field-test-read-restores-the-selection ()
  "A selection in the field comes back as the region, either way round."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((text "日本語 text")   ; 3 characters of 3 bytes
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok text 9 3))))
      (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
        (should (= (+ (point-min) 3) (point)))
        (should (= (+ (point-min) 1) (mark t)))
        (should mark-active))))
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--start
                    (cmacs-gowl-edit-field-tests--ok "hello world" 0 5))))
      (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
        (should (= (point-min) (point)))
        (should (= (+ (point-min) 5) (mark t)))))))

(ert-deftest cmacs-gowl-edit-field-test-partial-window-is-announced ()
  "A window of the field is edited as one, and the header line says so."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((cmacs-gowl-edit-field-partial-action 'window)
           (text (make-string 3950 ?x))
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok text 2000 nil t))))
      (should-not (cmacs-gowl-edit-field--session-complete session))
      (should (eq 'text-input
                  (cmacs-gowl-edit-field--session-method session)))
      ;; Not the clipboard: nothing was sent to the window.
      (should-not (cmacs-gowl-edit-field-tests--called 'key))
      (let ((header (cmacs-gowl-edit-field--header session)))
        (should (string-match-p "3950 bytes around the cursor" header))
        (should (string-match-p "not the whole field" header)))))
  ;; A complete read does not carry the warning.
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--start
                    (cmacs-gowl-edit-field-tests--ok "short" 0))))
      (should-not (string-match-p
                   "around the cursor"
                   (cmacs-gowl-edit-field--header session))))))

(ert-deftest cmacs-gowl-edit-field-test-partial-window-can-use-the-fallback ()
  "With the option set, a window of the field goes to the clipboard path."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((cmacs-gowl-edit-field-partial-action 'fallback)
           (cmacs-gowl-edit-field-fallback 'clipboard)
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok
                      (make-string 3950 ?x) 10 nil t))))
      (should-not (cmacs-gowl-edit-field--session-buffer session))
      (should (equal '("a" "c")
                     (mapcar #'cadr
                             (cmacs-gowl-edit-field-tests--called 'key))))))
  ;; ...but not where the fallback is off: the window is edited.
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((cmacs-gowl-edit-field-partial-action 'fallback)
           (cmacs-gowl-edit-field-fallback nil)
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok
                      (make-string 3950 ?x) 10 nil t))))
      (should (buffer-live-p (cmacs-gowl-edit-field--session-buffer session)))
      (should-not (cmacs-gowl-edit-field-tests--called 'key)))))

(ert-deftest cmacs-gowl-edit-field-test-password-field-is-refused ()
  "A field marked as a password is not opened, and not copied either."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-fallback 'clipboard))
      (cmacs-gowl-edit-field-tests--start
       '(:status ok :text "hunter2" :cursor 7 :anchor 7 :complete t
         :hint 0 :purpose 8))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'show))
      (should-not (cmacs-gowl-edit-field-tests--called 'key))
      (should (string-match-p "password field"
                              (car cmacs-gowl-edit-field-tests--messages)))))
  ;; One that would not even say what is in it.
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-fallback 'clipboard))
      (cmacs-gowl-edit-field-tests--start
       '(:status no-surrounding :text nil :cursor 0 :anchor 0 :complete nil
         :hint #x80 :purpose 0))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'key)))))

(ert-deftest cmacs-gowl-edit-field-test-no-field-without-fallback ()
  "With no fallback, a window with no text field is reported and left."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-fallback nil))
      (cmacs-gowl-edit-field-tests--start
       '(:status no-field :text nil :cursor 0 :anchor 0 :complete nil
         :hint 0 :purpose 0))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'key))
      (should (string-match-p "no text field"
                              (car cmacs-gowl-edit-field-tests--messages)))
      ;; Nothing is listening to the compositor once the session is gone.
      (should-not cmacs-gowl-focus-changed-functions))))

(ert-deftest cmacs-gowl-edit-field-test-same-window-twice ()
  "Asking again for a window already being edited shows that editor."
  (cmacs-gowl-edit-field-tests--with-gowl
    (cmacs-gowl-edit-field-tests--start
     (cmacs-gowl-edit-field-tests--ok "one" 0))
    (cmacs-gowl-edit-field)
    (should (= 1 (length cmacs-gowl-edit-field--sessions)))
    (should (= 1 (length (cmacs-gowl-edit-field-tests--called 'read))))
    (should (= 2 (length (cmacs-gowl-edit-field-tests--called 'show))))))

;;;; The clipboard fallback

(ert-deftest cmacs-gowl-edit-field-test-clipboard-read ()
  "No text input: select all, copy, and put the user's clipboard back."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-fallback 'clipboard))
      (cl-letf (((symbol-function 'gowl-text-field-read)
                 (lambda (&rest _) nil)))
        (cmacs-gowl-edit-field))
      (let* ((session (car cmacs-gowl-edit-field--sessions))
             (marker cmacs-gowl-edit-field-tests--clipboard)
             (timer (car (cmacs-gowl-edit-field-tests--called 'timer))))
        ;; A marker went on the clipboard, then Ctrl+A and Ctrl+C.
        (should (string-prefix-p "cmacs-edit-field-" marker))
        (should (equal '((origin "a" (control)) (origin "c" (control)))
                       (cmacs-gowl-edit-field-tests--called 'key)))
        (should (eq #'cmacs-gowl-edit-field--clipboard-collect (car timer)))
        ;; The application copies; the collector finds it.
        (setq cmacs-gowl-edit-field-tests--clipboard "the field's text")
        (apply (car timer) (cdr timer))
        (should (eq 'clipboard
                    (cmacs-gowl-edit-field--session-method session)))
        (should (equal "the field's text"
                       (cmacs-gowl-edit-field--session-text session)))
        ;; The user's clipboard is back.
        (should (equal "the user's clipboard"
                       cmacs-gowl-edit-field-tests--clipboard))
        (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
          (should (equal "the field's text" (buffer-string)))
          (should (= (point-max) (point))))
        (should (string-match-p "clipboard (best effort)"
                                (cmacs-gowl-edit-field--header session)))))))

(ert-deftest cmacs-gowl-edit-field-test-clipboard-read-copied-nothing ()
  "A marker still on the clipboard means there was nothing to copy."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-fallback 'clipboard))
      (cl-letf (((symbol-function 'gowl-text-field-read)
                 (lambda (&rest _) nil)))
        (cmacs-gowl-edit-field))
      (let ((session (car cmacs-gowl-edit-field--sessions))
            (marker cmacs-gowl-edit-field-tests--clipboard))
        ;; Out of tries, the marker untouched.
        (cmacs-gowl-edit-field--clipboard-collect session marker 0)
        (should-not cmacs-gowl-edit-field--sessions)
        (should-not (cmacs-gowl-edit-field-tests--called 'show))
        (should (equal "the user's clipboard"
                       cmacs-gowl-edit-field-tests--clipboard))
        (should (string-match-p
                 "copied nothing"
                 (car cmacs-gowl-edit-field-tests--messages)))))))

(ert-deftest cmacs-gowl-edit-field-test-clipboard-never-in-a-terminal ()
  "A terminal is never sent Ctrl+C, which would interrupt its program."
  (cmacs-gowl-edit-field-tests--with-gowl
    (setf (alist-get 'app-id (alist-get 'origin
                                        cmacs-gowl-edit-field-tests--clients))
          "gst")
    (let ((cmacs-gowl-edit-field-fallback 'clipboard))
      (cl-letf (((symbol-function 'gowl-text-field-read)
                 (lambda (&rest _) nil)))
        (cmacs-gowl-edit-field))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'key))
      (should-not (cmacs-gowl-edit-field-tests--called 'clipboard)))))

(ert-deftest cmacs-gowl-edit-field-test-clipboard-commit ()
  "Committing pastes over the field and puts the clipboard back after."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field--session-create
                    :client 'origin :id 7 :app-id "librewolf" :title "Reply"
                    :method 'clipboard :text "old" :state 'committing)))
      (push session cmacs-gowl-edit-field--sessions)
      (cmacs-gowl-edit-field--commit-clipboard session "new text")
      (should (equal "new text" cmacs-gowl-edit-field-tests--clipboard))
      (should (equal '((origin "a" (control)) (origin "v" (control)))
                     (cmacs-gowl-edit-field-tests--called 'key)))
      ;; Still a session: the paste has not had time to happen.
      (should (memq session cmacs-gowl-edit-field--sessions))
      (let ((timer (car (cmacs-gowl-edit-field-tests--called 'timer))))
        (apply (car timer) (cdr timer)))
      (should (equal "the user's clipboard"
                     cmacs-gowl-edit-field-tests--clipboard))
      (should-not cmacs-gowl-edit-field--sessions))))

;;;; Committing through text-input

(defun cmacs-gowl-edit-field-tests--editing (text cursor)
  "Return a session editing TEXT read with its cursor at byte CURSOR."
  (cmacs-gowl-edit-field-tests--start
   (cmacs-gowl-edit-field-tests--ok text cursor)))

(ert-deftest cmacs-gowl-edit-field-test-commit-replaces-what-was-read ()
  "A field that still holds what was read gets the computed edit."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "the black cat" 6)))
      (cmacs-gowl-edit-field--commit-verified
       session "the green cat"
       (cmacs-gowl-edit-field-tests--ok "the black cat" 6) nil)
      (let ((call (car (cmacs-gowl-edit-field-tests--called 'replace))))
        (should (equal '(origin 2 3 "green") (butlast call)))
        ;; Delivered: the editor closes and the window gets the keyboard.
        (funcall (car (last call)) t)
        (should-not cmacs-gowl-edit-field--sessions)
        (should-not (buffer-live-p
                     (cmacs-gowl-edit-field--session-buffer session)))
        (should (cmacs-gowl-edit-field-tests--called 'focus))))))

(ert-deftest cmacs-gowl-edit-field-test-commit-follows-a-moved-cursor ()
  "The edit is measured from where the cursor is now, not where it was."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "the black cat" 6)))
      (cmacs-gowl-edit-field--commit-verified
       session "the green cat"
       (cmacs-gowl-edit-field-tests--ok "the black cat" 13) nil)
      (should (equal '(origin 9 0 "green cat")
                     (butlast (car (cmacs-gowl-edit-field-tests--called
                                    'replace))))))))

(ert-deftest cmacs-gowl-edit-field-test-commit-refuses-a-changed-field ()
  "A field that changed meanwhile is not overwritten until asked twice."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "draft one" 9))
          (fresh (cmacs-gowl-edit-field-tests--ok "somebody typed here" 4)))
      (cmacs-gowl-edit-field--commit-verified session "my edit" fresh nil)
      (should-not (cmacs-gowl-edit-field-tests--called 'replace))
      (should (memq session cmacs-gowl-edit-field--sessions))
      (should (eq 'editing (cmacs-gowl-edit-field--session-state session)))
      (should (cmacs-gowl-edit-field--session-conflict session))
      (should (string-match-p "changed in the application"
                              (cmacs-gowl-edit-field--header session)))
      ;; The second commit overwrites what is there NOW, measured
      ;; against the fresh read.
      (cmacs-gowl-edit-field--commit-verified session "my edit" fresh t)
      (let ((call (butlast (car (cmacs-gowl-edit-field-tests--called
                                 'replace)))))
        (should (equal "my edit"
                       (cmacs-gowl-edit-field-tests--apply
                        "somebody typed here" 4 (cdr call))))))))

(ert-deftest cmacs-gowl-edit-field-test-commit-partial-replaces-the-window ()
  "A partial read replaces only the bytes that were read."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((window (concat (make-string 2000 ?a) (make-string 1950 ?b)))
           (session (cmacs-gowl-edit-field-tests--start
                     (cmacs-gowl-edit-field-tests--ok window 2000 nil t)))
           (new (concat (make-string 2000 ?a) "X" (make-string 1950 ?b))))
      (cmacs-gowl-edit-field--commit-verified
       session new (cmacs-gowl-edit-field-tests--ok window 2000 nil t) nil)
      (let ((call (butlast (car (cmacs-gowl-edit-field-tests--called
                                 'replace)))))
        ;; One character inserted at the cursor; never more deleted
        ;; than the window holds.
        (should (equal '(origin 0 0 "X") call))))))

(ert-deftest cmacs-gowl-edit-field-test-commit-unchanged-sends-nothing ()
  "Committing text that was not edited closes the editor quietly."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "as it was" 3)))
      (cmacs-gowl-edit-field--commit-verified
       session "as it was"
       (cmacs-gowl-edit-field-tests--ok "as it was" 3) nil)
      (should-not (cmacs-gowl-edit-field-tests--called 'replace))
      (should-not cmacs-gowl-edit-field--sessions))))

(ert-deftest cmacs-gowl-edit-field-test-commit-undelivered-keeps-the-text ()
  "An edit the application did not take leaves the editor open."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "old" 3)))
      (cmacs-gowl-edit-field--commit-verified
       session "new" (cmacs-gowl-edit-field-tests--ok "old" 3) nil)
      (funcall (car (last (car (cmacs-gowl-edit-field-tests--called
                                'replace))))
               nil)
      (should (memq session cmacs-gowl-edit-field--sessions))
      (should (buffer-live-p (cmacs-gowl-edit-field--session-buffer session)))
      (should (eq 'editing (cmacs-gowl-edit-field--session-state session)))
      (should (cmacs-gowl-edit-field--session-note session))))
  ;; ...and so does a field that can no longer be read at all.
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "old" 3)))
      (cmacs-gowl-edit-field--commit-verified
       session "new" '(:status no-field) nil)
      (should-not (cmacs-gowl-edit-field-tests--called 'replace))
      (should (memq session cmacs-gowl-edit-field--sessions)))))

(ert-deftest cmacs-gowl-edit-field-test-finish-waits-for-focus ()
  "The commit goes only once the window holds the keyboard."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "old" 3)))
      ;; The editor has the keyboard; focus has not come back yet.
      (setq cmacs-gowl-edit-field-tests--focused nil)
      (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
        (erase-buffer)
        (insert "new")
        (cmacs-gowl-edit-field-finish))
      (should (eq 'committing
                  (cmacs-gowl-edit-field--session-state session)))
      (should (equal '((origin)) (cmacs-gowl-edit-field-tests--called 'focus)))
      (should (= 1 (length (cmacs-gowl-edit-field-tests--called 'read))))
      (should (= 1 (length cmacs-gowl-edit-field--waiters)))
      ;; Focus lands; the compositor's hook resolves the wait.
      (setq cmacs-gowl-edit-field-tests--focused 'origin)
      (cmacs-gowl-edit-field--check-waiters)
      (should-not cmacs-gowl-edit-field--waiters)
      ;; The verifying read went out, and its answer sends the edit.
      (should (= 2 (length (cmacs-gowl-edit-field-tests--called 'read))))
      (cmacs-gowl-edit-field-tests--answer
       'read (cmacs-gowl-edit-field-tests--ok "old" 3))
      (should (equal '(origin 3 0 "new")
                     (butlast (car (cmacs-gowl-edit-field-tests--called
                                    'replace))))))))

(ert-deftest cmacs-gowl-edit-field-test-finish-without-verify ()
  "With verification off the edit is measured against the first read."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((cmacs-gowl-edit-field-verify nil)
          (session (cmacs-gowl-edit-field-tests--editing "old" 0)))
      (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
        (goto-char (point-max))
        (insert "er")
        (cmacs-gowl-edit-field-finish))
      ;; No second read; and with the cursor at 0 all of "old" is after
      ;; it, so that is where the deletion is counted.
      (should (= 1 (length (cmacs-gowl-edit-field-tests--called 'read))))
      (should (equal '(origin 0 3 "older")
                     (butlast (car (cmacs-gowl-edit-field-tests--called
                                    'replace))))))))

(ert-deftest cmacs-gowl-edit-field-test-focus-never-lands ()
  "A window that does not take the keyboard fails the commit, once."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((landed 0) (missed 0))
      (setq cmacs-gowl-edit-field-tests--focused nil)
      (cmacs-gowl-edit-field--when-focused
       'origin 7 (lambda () (cl-incf landed)) (lambda () (cl-incf missed)))
      (let ((waiter (car cmacs-gowl-edit-field--waiters)))
        (should waiter)
        ;; The deadline.
        (cmacs-gowl-edit-field--resolve-waiter waiter nil)
        (should (= 1 missed))
        ;; Focus arriving late, or the deadline again, does nothing.
        (setq cmacs-gowl-edit-field-tests--focused 'origin)
        (cmacs-gowl-edit-field--check-waiters)
        (cmacs-gowl-edit-field--resolve-waiter waiter t)
        (cmacs-gowl-edit-field--resolve-waiter waiter nil)
        (should (= 0 landed))
        (should (= 1 missed))))))

(ert-deftest cmacs-gowl-edit-field-test-focus-already-there ()
  "A window that takes the keyboard at once is not waited for."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((landed 0))
      (cmacs-gowl-edit-field--when-focused
       'origin 7 (lambda () (cl-incf landed)) #'ignore)
      (should (= 1 landed))
      (should-not cmacs-gowl-edit-field--waiters))))

;;;; Ending

(ert-deftest cmacs-gowl-edit-field-test-abort ()
  "Aborting closes the editor, sends nothing, and gives focus back."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((session (cmacs-gowl-edit-field-tests--editing "keep me" 0))
           (buffer (cmacs-gowl-edit-field--session-buffer session)))
      (with-current-buffer buffer
        (cmacs-gowl-edit-field-abort))
      (should-not (buffer-live-p buffer))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not (cmacs-gowl-edit-field-tests--called 'replace))
      (should (equal '((origin)) (cmacs-gowl-edit-field-tests--called 'focus)))
      (should-not cmacs-gowl-focus-changed-functions))))

(ert-deftest cmacs-gowl-edit-field-test-abort-asks-about-edits ()
  "Edits are not thrown away without a question."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((session (cmacs-gowl-edit-field-tests--editing "keep me" 0))
           (buffer (cmacs-gowl-edit-field--session-buffer session)))
      (with-current-buffer buffer
        (insert "edited ")
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (cmacs-gowl-edit-field-abort))
        (should (buffer-live-p buffer))
        (should (memq session cmacs-gowl-edit-field--sessions))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (cmacs-gowl-edit-field-abort)))
      (should-not (buffer-live-p buffer)))))

(ert-deftest cmacs-gowl-edit-field-test-window-gone ()
  "When the window disappears the text is kept and offered to the kill ring."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let* ((session (cmacs-gowl-edit-field-tests--editing "precious" 8))
           (buffer (cmacs-gowl-edit-field--session-buffer session)))
      ;; The compositor says the window unmapped.
      (cmacs-gowl-edit-field--on-client-removed 'origin)
      (setq cmacs-gowl-edit-field-tests--clients nil)
      (should (cmacs-gowl-edit-field--session-gone session))
      (should (buffer-live-p buffer))
      (should (string-match-p "window is gone"
                              (cmacs-gowl-edit-field--header session)))
      (should (cl-some (lambda (m) (string-match-p "is gone" m))
                       cmacs-gowl-edit-field-tests--messages))
      ;; Committing cannot reach it: nothing is sent, the text is
      ;; offered to the kill ring.
      (with-current-buffer buffer
        (insert " words")
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (cmacs-gowl-edit-field-finish)))
      (should-not (cmacs-gowl-edit-field-tests--called 'replace))
      (should (equal "precious words" (car kill-ring)))
      (should-not cmacs-gowl-edit-field--sessions)
      ;; Focus is not handed to a window that does not exist.
      (should-not (cmacs-gowl-edit-field-tests--called 'focus)))))

(ert-deftest cmacs-gowl-edit-field-test-window-gone-noticed-at-commit ()
  "A window that vanished without the hook firing is caught at commit."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "text" 4)))
      (setq cmacs-gowl-edit-field-tests--clients nil)
      (with-current-buffer (cmacs-gowl-edit-field--session-buffer session)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (cmacs-gowl-edit-field-finish)))
      ;; Declined: the buffer and its text stay.
      (should (cmacs-gowl-edit-field--session-gone session))
      (should (buffer-live-p (cmacs-gowl-edit-field--session-buffer session)))
      (should-not (cmacs-gowl-edit-field-tests--called 'replace)))))

(ert-deftest cmacs-gowl-edit-field-test-killing-the-buffer-ends-the-session ()
  "Killing the editor buffer by hand leaves no session behind."
  (cmacs-gowl-edit-field-tests--with-gowl
    (let ((session (cmacs-gowl-edit-field-tests--editing "text" 0)))
      (kill-buffer (cmacs-gowl-edit-field--session-buffer session))
      (should-not cmacs-gowl-edit-field--sessions)
      (should-not cmacs-gowl-client-removed-functions))))

(ert-deftest cmacs-gowl-edit-field-test-commands-need-a-session ()
  "The buffer commands refuse a buffer that is not an editor."
  (with-temp-buffer
    (should-error (cmacs-gowl-edit-field-finish) :type 'user-error)
    (should-error (cmacs-gowl-edit-field-abort) :type 'user-error)
    (should-error (cmacs-gowl-edit-field-copy) :type 'user-error)))

;;;; Setup

(ert-deftest cmacs-gowl-edit-field-test-setup-binds-the-key ()
  "Setup binds the key once, to the command, and nothing without it."
  (let ((calls nil)
        (cmacs-gowl-edit-field-key "Super+Ctrl+e"))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-remove-keybind)
               (lambda (&rest args) (push (cons 'remove args) calls) t))
              ((symbol-function 'gowl-add-keybind)
               (lambda (&rest args) (push (cons 'add args) calls) t)))
      (should (cmacs-gowl-edit-field-setup))
      ;; Removed first: gowl runs the first bind that matches.
      (should (equal '(remove "Super+Ctrl+e") (cadr calls)))
      (should (equal '(add "Super+Ctrl+e" custom "(cmacs-gowl-edit-field)")
                     (butlast (car calls))))
      (setq calls nil)
      (let ((cmacs-gowl-edit-field-key nil))
        (should-not (cmacs-gowl-edit-field-setup)))
      (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
        (should-not (cmacs-gowl-edit-field-setup)))
      (should-not calls))))

(ert-deftest cmacs-gowl-edit-field-test-key-is-free ()
  "The default key is not one cmacs binds for something else."
  (let ((dir (file-name-directory (locate-library "cmacs-gowl-edit-field")))
        (key (default-value 'cmacs-gowl-edit-field-key)))
    (dolist (file (directory-files dir t "\\`cmacs-gowl.*\\.el\\'"))
      (unless (string-match-p "edit-field" file)
        (with-temp-buffer
          (insert-file-contents file)
          (should-not (search-forward (format "\"%s\"" key) nil t)))))))

;;;; The C source

(defconst cmacs-gowl-edit-field-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, for finding the source tree.")

(defun cmacs-gowl-edit-field-tests--c-source ()
  "Return the text of cmacs-gowl-textfield.c, or nil outside a source tree."
  (let ((file (expand-file-name
               "../../cmacs/gowl/cmacs-gowl-textfield.c"
               (file-name-directory
                cmacs-gowl-edit-field-tests--this-file))))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun cmacs-gowl-edit-field-tests--c-function (source name)
  "Return the body of the C function NAME in SOURCE, braces included."
  (when (string-match (concat "^" (regexp-quote name) " (") source)
    (let ((start (string-search "\n{" source (match-end 0))))
      (substring source start (string-search "\n}" source start)))))

(ert-deftest cmacs-gowl-edit-field-test-defuns-take-the-lock ()
  "Every DEFUN in cmacs-gowl-textfield.c holds the gowl lock, scoped.
The dispatch thread holds the same lock across every dispatch, and each
of these reaches the compositor from Emacs's thread.  Scoped, because
each of them can signal: a plain lock would be left held by the `error'
and wedge the desktop.  And every `return' goes through `unbind_to',
which is what releases it.  (The guards in cmacs-gowl-tests.el read
cmacs-gowl.c and cmacs-gowl-pointer.c only.)"
  (let ((source (cmacs-gowl-edit-field-tests--c-source))
        (case-fold-search nil)
        (checked 0))
    (skip-unless source)
    (let ((chunks (cdr (split-string source "^DEFUN (")))
          (end "^\\(?:void\\|static\\|/\\* MODIFIERS\\)"))
      (dolist (chunk chunks)
        (let* ((name (and (string-match "\\`\"\\([^\"]+\\)\"" chunk)
                          (match-string 1 chunk)))
               ;; From the end of the doc string (which may well say
               ;; "return") up to the next top-level definition.
               (code (string-search "*/)" chunk))
               ;; Comments say "return" too; only code is read.
               (body (replace-regexp-in-string
                      "/\\*\\(?:.\\|\n\\)*?\\*/" ""
                      (substring chunk code
                                 (string-match end chunk code))))
               (pos 0))
          (setq checked (1+ checked))
          (ert-info ((format "%s" name))
            (should (string-match-p "cmacs_gowl_lock_scoped ()" body))
            (should-not (string-match-p "cmacs_gowl_unlock ()" body))
            (while (string-match "\\_<return\\_>[^;]*;" body pos)
              (setq pos (match-end 0))
              (should (string-match-p "\\`return unbind_to (lock_count,"
                                      (match-string 0 body))))))))
    (should (= 5 checked))))

(ert-deftest cmacs-gowl-edit-field-test-gowl-callbacks-run-no-lisp ()
  "What gowl calls back on its dispatch thread touches nothing of Lisp.
Lisp on that thread winds the `specpdl' from two threads at once, which
is a crash.  The callbacks copy into C memory and queue for the main
thread; the callback table is only touched there."
  (let ((source (cmacs-gowl-edit-field-tests--c-source))
        (case-fold-search nil))
    (skip-unless source)
    (dolist (name '("textfield_on_read" "textfield_on_commit"))
      (let ((body (cmacs-gowl-edit-field-tests--c-function source name)))
        (ert-info (name)
          (should body)
          (should (string-match-p "cmacs_glib_invoke_on_main" body))
          (should-not (string-match-p
                       (rx (or "Lisp_Object" "intern" "Fgethash" "Fputhash"
                               "textfield_take" "textfield_register"
                               "safe_call" "build_string" "make_uint"))
                       body)))))
    ;; The user data handed to gowl is an integer, never a pointer to
    ;; something that holds a Lisp object.
    (should-not (string-match-p "Lisp_Object[^;]*;[^}]*} TextfieldAnswer"
                                source))
    (should (string-match-p "GUINT_TO_POINTER (id)" source))
    ;; And the table is a GC root.
    (should (string-match-p
             "staticpro (&Vcmacs_gowl_textfield_callbacks)" source))))

;;;; The primitives

(ert-deftest cmacs-gowl-edit-field-test-primitives-without-a-compositor ()
  "With no compositor the primitives say so and leave nothing behind."
  (skip-unless (fboundp 'gowl-text-field-read))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-client-has-text-input-p nil))
  (should-error (gowl-text-field-read nil #'ignore))
  (should-error (gowl-text-field-replace nil 0 0 "x"))
  (should-error (gowl-text-field-send-key nil "a" '(control)))
  (should-error (gowl-clipboard-set-transient "x")))

(defun cmacs-gowl-edit-field-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT).  The same isolation as cmacs-gowl-tests.el's
harness: a private runtime directory, no parent display, systemd off,
the pixman renderer, fatal GLib criticals."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file (expand-file-name "cmacs-gowl-ef-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "120" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defconst cmacs-gowl-edit-field-tests--headless-form
  '(progn
     (gowl-start)
     (unless (gowl-running-p)
       (princ "no compositor\n")
       (kill-emacs 77))
     (let ((fail (lambda (fmt &rest args)
                   (princ (apply #'format (concat fmt "\n") args))
                   (ignore-errors (gowl-stop))
                   (kill-emacs 3)))
           (called nil))
       ;; An empty desktop: no window holds the keyboard, and what is
       ;; not a window is refused -- with the lock released on the way
       ;; out, or the second call here would never return.
       (when (gowl-focused-client)
         (funcall fail "a focused client on an empty desktop"))
       (dotimes (_ 2)
         (unless (condition-case nil
                     (progn (gowl-text-field-read 'not-a-client #'ignore) nil)
                   (error t))
           (funcall fail "read accepted a non-client"))
         (unless (condition-case nil
                     (progn (gowl-text-field-replace 'not-a-client 0 0 "x")
                            nil)
                   (error t))
           (funcall fail "replace accepted a non-client"))
         (unless (condition-case nil
                     (progn (gowl-client-has-text-input-p 'not-a-client) nil)
                   (error t))
           (funcall fail "has-text-input-p accepted a non-client")))
       ;; A callback that is not a function is refused before anything
       ;; is registered for it.
       (unless (condition-case nil
                   (progn (gowl-text-field-read 'not-a-client 42) nil)
                 (error t))
         (funcall fail "read accepted a non-function"))
       ;; Nothing above reached a window, so nothing may call back.
       (let ((cb (lambda (&rest _) (setq called t))))
         (ignore-errors (gowl-text-field-read 'not-a-client cb))
         (ignore-errors (gowl-text-field-replace 'not-a-client 0 0 "x" cb)))
       (dotimes (_ 5) (accept-process-output nil 0.05))
       (when called
         (funcall fail "a refused request called back"))
       ;; Stopping with nothing waiting is clean.
       (gowl-stop)
       (when (gowl-running-p)
         (funcall fail "still running after gowl-stop"))
       (princ "ok\n")
       (kill-emacs 0)))
  "What the headless child runs.")

(ert-deftest cmacs-gowl-edit-field-test-primitives-headless ()
  "The primitives refuse what is not a window, under a real compositor."
  (skip-unless (fboundp 'gowl-text-field-read))
  (skip-unless (let ((dir (getenv "XDG_RUNTIME_DIR")))
                 (and dir (file-directory-p dir))))
  (let ((result (cmacs-gowl-edit-field-tests--run-headless
                 cmacs-gowl-edit-field-tests--headless-form)))
    (skip-unless (not (eql 77 (car result))))
    (ert-info ((cdr result) :prefix "child output: ")
      (should (eql 0 (car result))))))

(provide 'cmacs-gowl-edit-field-tests)

;;; cmacs-gowl-edit-field-tests.el ends here
