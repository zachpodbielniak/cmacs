;;; cmacs-gowl-gabbrev-tests.el --- Tests for cmacs-gowl-gabbrev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl's text expander.  Most of it is pure -- how a
;; match plist becomes the YAML the module reads, how the deny filter
;; keeps Emacs's own frames out, how abbrev tables become matches -- and
;; is tested against stubs.  The rest needs the module answering: a
;; child cmacs starts a headless compositor (cmacs-gowl-tests.el's
;; runner), defines Lisp matches and types, and renders them, which
;; drives the whole path -- the module asks libgowl's registry, the C
;; callback in cmacs-gowl.c queues a form on the main thread, Lisp
;; answers through `gabbrev-resolve', and the answer is posted back to
;; the compositor.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-gabbrev)

;;;; Turning Lisp into the module's YAML

(ert-deftest cmacs-gowl-gabbrev-test-encode-plist ()
  "A match plist becomes JSON with espanso's key spelling."
  (let ((json (cmacs-gowl-gabbrev--encode
               '(:trigger ";x" :replace "y" :propagate-case t :word :false
                 :vars ((:name "d" :type "date" :params (:format "%Y")))))))
    (let ((back (json-parse-string json :object-type 'alist
                                   :false-object :false)))
      (should (equal (alist-get 'trigger back) ";x"))
      (should (eq (alist-get 'propagate_case back) t))
      (should (eq (alist-get 'word back) :false))
      (let ((var (aref (alist-get 'vars back) 0)))
        (should (equal (alist-get 'type var) "date"))
        (should (equal (alist-get 'format (alist-get 'params var)) "%Y"))))
    (should-not (string-search "\n" json))))

(ert-deftest cmacs-gowl-gabbrev-test-encode-alist-options ()
  "Option alists keep their values; nil keys are left out of plists."
  (let ((back (json-parse-string
               (cmacs-gowl-gabbrev--encode '((toggle_key . "ALT")
                                             (clipboard-threshold . 50)))
               :object-type 'alist)))
    (should (equal (alist-get 'toggle_key back) "ALT"))
    (should (equal (alist-get 'clipboard_threshold back) 50)))
  (should-not (string-search "label"
                             (cmacs-gowl-gabbrev--encode
                              '(:trigger "a" :replace "b" :label nil)))))

(ert-deftest cmacs-gowl-gabbrev-test-function-replacement ()
  "A function replacement becomes an `elisp' variable naming it."
  (let ((cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal))
        (fn (lambda (_ctx) "hi")))
    (let ((spec (cmacs-gowl-gabbrev--match-spec ";f" fn '(:word t))))
      (should (equal (plist-get spec :replace) "{{value}}"))
      (should (plist-get spec :word))
      (let ((var (car (plist-get spec :vars))))
        (should (equal (plist-get var :type) "elisp"))
        (should (eq (gethash (plist-get (plist-get var :params) :function)
                             cmacs-gowl-gabbrev--functions)
                    fn))))))

(ert-deftest cmacs-gowl-gabbrev-test-define-replaces ()
  "Defining a trigger again replaces it; undefining forgets it."
  (let ((cmacs-gowl-gabbrev--defined nil)
        (cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'cmacs-gowl-gabbrev--schedule-push) #'ignore))
      (cmacs-gowl-gabbrev-define ";a" "one")
      (cmacs-gowl-gabbrev-define ";b" "two")
      (cmacs-gowl-gabbrev-define ";a" "three")
      (should (= (length cmacs-gowl-gabbrev--defined) 2))
      (should (equal (plist-get (cl-find ";a" cmacs-gowl-gabbrev--defined
                                         :key (lambda (m) (plist-get m :trigger))
                                         :test #'equal)
                                :replace)
                     "three"))
      (cmacs-gowl-gabbrev-undefine ";a")
      (should (= (length cmacs-gowl-gabbrev--defined) 1)))))

;;;; Keeping Emacs's frames out

(ert-deftest cmacs-gowl-gabbrev-test-deny-filter ()
  "Emacs's pid joins whatever deny filter is in force, unless in-emacs."
  (let ((pid (format "pid = %d" (emacs-pid))))
    (let ((cmacs-gowl-gabbrev-in-emacs nil)
          (cmacs-gowl-gabbrev-deny-filter nil))
      (should (equal (cmacs-gowl-gabbrev--deny) (concat "+" pid))))
    (let ((cmacs-gowl-gabbrev-in-emacs nil)
          (cmacs-gowl-gabbrev-deny-filter "+app-id = x"))
      (should (equal (cmacs-gowl-gabbrev--deny)
                     (concat "+app-id = x or " pid))))
    (let ((cmacs-gowl-gabbrev-in-emacs nil)
          (cmacs-gowl-gabbrev-deny-filter "app-id = x"))
      (should (equal (cmacs-gowl-gabbrev--deny)
                     (concat "(app-id = x) or " pid))))
    (let ((cmacs-gowl-gabbrev-in-emacs nil)
          (cmacs-gowl-gabbrev-deny-filter "none"))
      (should (equal (cmacs-gowl-gabbrev--deny) pid)))
    (let ((cmacs-gowl-gabbrev-in-emacs t)
          (cmacs-gowl-gabbrev-deny-filter nil))
      (should-not (cmacs-gowl-gabbrev--deny)))))

;;;; abbrev-mode compatibility

;; Abbrev tables are found by name, through `symbol-value': special.
(defvar cmacs-gowl-gabbrev-test--table nil)
(defvar cmacs-gowl-gabbrev-test--ptable nil)

(ert-deftest cmacs-gowl-gabbrev-test-abbrev-export ()
  "Abbrevs become whole-word matches; case-fixed ones keep their case;
a hook becomes an Elisp variable that runs it; system abbrevs stay home."
  (let* ((cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal))
         (cmacs-gowl-gabbrev-abbrev-prefix "")
         (cmacs-gowl-gabbrev-abbrev-include-system nil)
         (table (make-abbrev-table))
         (cmacs-gowl-gabbrev-test--table table)
         (cmacs-gowl-gabbrev-abbrev-tables '(cmacs-gowl-gabbrev-test--table)))
    (define-abbrev table "teh" "the")
    (define-abbrev table "brb" "be right back" nil :case-fixed t)
    (define-abbrev table "sys" "system" nil :system t)
    (define-abbrev table "hk" "hook" (lambda () (insert "ed")))
    (let ((matches (cmacs-gowl-gabbrev--abbrev-matches)))
      (should (= (length matches) 3))
      (let ((teh (cl-find "teh" matches :key (lambda (m) (plist-get m :trigger))
                          :test #'equal))
            (brb (cl-find "brb" matches :key (lambda (m) (plist-get m :trigger))
                          :test #'equal))
            (hk (cl-find "hk" matches :key (lambda (m) (plist-get m :trigger))
                         :test #'equal)))
        (should (equal (plist-get teh :replace) "the"))
        (should (plist-get teh :word))
        (should (plist-get teh :propagate-case))
        (should-not (plist-get brb :propagate-case))
        (should (equal (plist-get hk :replace) "{{value}}"))
        (let* ((var (car (plist-get hk :vars)))
               (fn (gethash (plist-get (plist-get var :params) :function)
                            cmacs-gowl-gabbrev--functions)))
          (should (functionp fn))
          (should (equal (funcall fn nil) "hooked")))))))

(ert-deftest cmacs-gowl-gabbrev-test-abbrev-prefix ()
  "`cmacs-gowl-gabbrev-abbrev-prefix' goes before every abbrev."
  (let* ((cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal))
         (cmacs-gowl-gabbrev-abbrev-prefix ",")
         (table (make-abbrev-table))
         (cmacs-gowl-gabbrev-test--ptable table)
         (cmacs-gowl-gabbrev-abbrev-tables '(cmacs-gowl-gabbrev-test--ptable)))
    (define-abbrev table "ty" "thank you")
    (should (equal (plist-get (car (cmacs-gowl-gabbrev--abbrev-matches)) :trigger)
                   ",ty"))))

;;;; Answering the module

(ert-deftest cmacs-gowl-gabbrev-test-resolve-dispatch ()
  "`--resolve' finds the function by type or by name, and answers by id."
  (let ((cmacs-gowl-gabbrev--functions (make-hash-table :test #'equal))
        (cmacs-gowl-gabbrev--types (make-hash-table :test #'equal))
        (sent nil))
    (cmacs-gowl-gabbrev-define-function
     "greet" (lambda (ctx) (concat "hi " (cmacs-gowl-gabbrev-var ctx "who"))))
    (puthash "shout" (lambda (ctx) (upcase (cmacs-gowl-gabbrev-param ctx "text")))
             cmacs-gowl-gabbrev--types)
    (puthash "later" (lambda (_ctx) :async) cmacs-gowl-gabbrev--types)
    (cl-letf (((symbol-function 'cmacs-gowl-gabbrev--running-p) (lambda () t))
              ((symbol-function 'gowl-run-command)
               (lambda (line) (push line sent) "OK resolved")))
      (cmacs-gowl-gabbrev--resolve 7 "elisp" "v" "{\"function\":\"greet\"}"
                                   "{\"who\":\"Ada\"}" ";g" "app" "title")
      (should (equal (car sent) "gabbrev-resolve 7 \"hi Ada\""))
      (cmacs-gowl-gabbrev--resolve 8 "shout" "v" "{\"text\":\"loud\\nline\"}"
                                   "{}" "" "" "")
      (should (equal (car sent) "gabbrev-resolve 8 \"LOUD\\nLINE\""))
      ;; :async answers nothing now
      (setq sent nil)
      (cmacs-gowl-gabbrev--resolve 9 "later" "v" "{}" "{}" "" "" "")
      (should-not sent)
      ;; an unknown function is an error (the C side fails the request)
      (should-error (cmacs-gowl-gabbrev--resolve 10 "elisp" "v"
                                                 "{\"function\":\"nope\"}"
                                                 "{}" "" "" "")))))

(ert-deftest cmacs-gowl-gabbrev-test-choices ()
  "A choice's values: texts, and label/id objects."
  (should (equal (cmacs-gowl-gabbrev--choices '("a" "b"))
                 '(("a" . "a") ("b" . "b"))))
  (should (equal (cmacs-gowl-gabbrev--choices '(((label . "Yes") (id . "y"))))
                 '(("Yes" . "y"))))
  (should (equal (cmacs-gowl-gabbrev--choices "x\ny\n")
                 '(("x" . "x") ("y" . "y")))))

(ert-deftest cmacs-gowl-gabbrev-test-c-entry-points ()
  "The C entry points exist in a gowl build and register round trip."
  (skip-unless (fboundp 'gowl-gabbrev-register-type))
  (should (eq (gowl-gabbrev-register-type "cmacs-ert-type") t))
  (should (eq (gowl-gabbrev-unregister-type "cmacs-ert-type") t))
  (should-not (gowl-gabbrev-unregister-type "cmacs-ert-type"))
  (should-error (gowl-gabbrev-register-type "")))

;;;; The module, answering, in a second cmacs

(defconst cmacs-gowl-gabbrev-tests--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Where this file is: the gowl tests' runner is beside it.")

(declare-function cmacs-gowl-tests--run-headless "cmacs-gowl-tests")
(declare-function cmacs-gowl-tests--runtime-parent "cmacs-gowl-tests")

(defconst cmacs-gowl-gabbrev-tests--headless-form
  '(progn
     (setq cmacs-gowl-ipc nil)
     (require 'cmacs-gowl)
     (require 'cmacs-gowl-gabbrev)
     (if (not (gowl-start))
         (progn (princ "gabbrev-headless: no compositor\n") (kill-emacs 77))
       (cmacs-gowl--install-hook-bridges)
       (let ((got nil))
         (setq cmacs-gowl-gabbrev-espanso nil
               cmacs-gowl-gabbrev-ai-rewrite nil
               cmacs-gowl-gabbrev-search-key nil)
         (defvar gabbrev-headless-table (make-abbrev-table))
         (define-abbrev gabbrev-headless-table "zqx" "zebra quagga xerus")
         (setq cmacs-gowl-gabbrev-abbrev-tables '(gabbrev-headless-table))
         (cmacs-gowl-gabbrev-define
          ";lispy" (lambda (ctx) (format "lisp<%s>" (cmacs-gowl-gabbrev-var
                                                     ctx "pre"))))
         ;; a variable before the Lisp one, to see values cross over
         (setq cmacs-gowl-gabbrev--defined
               (list (append (car cmacs-gowl-gabbrev--defined)
                             (list :vars
                                   (cons '(:name "pre" :type "echo"
                                                 :params (:echo "P"))
                                         (plist-get (car cmacs-gowl-gabbrev--defined)
                                                    :vars))))))
         (cmacs-gowl-gabbrev-define-type
          "twice" (lambda (ctx) (let ((v (cmacs-gowl-gabbrev-param ctx "v")))
                                  (concat v v))))
         (cmacs-gowl-gabbrev-define ";tw" "{{x}}"
                                    :vars '((:name "x" :type "twice"
                                                   :params (:v "ab"))))
         (cmacs-gowl-gabbrev-define-type
          "slow" (lambda (ctx)
                   (run-at-time 0.2 nil #'cmacs-gowl-gabbrev-answer ctx "late")
                   :async))
         (cmacs-gowl-gabbrev-define ";sl" "{{x}}"
                                    :vars '((:name "x" :type "slow")))
         (cmacs-gowl-gabbrev-define ";er" (lambda (_) (error "Kaboom")))
         (cmacs-gowl-gabbrev-start)
         (cmacs-gowl-gabbrev--push-lisp)
         (add-hook 'cmacs-gowl-module-event-functions
                   (lambda (m text)
                     (when (and (equal m "gabbrev")
                                (string-prefix-p "render" text))
                       (push text got))))
         (dolist (pair '(("a" . ";lispy") ("b" . ";tw") ("c" . "zqx")
                         ("d" . ";today") ("e" . ";sl") ("f" . ";er")))
           (let ((r (gowl-run-command (format "gabbrev-render --id %s %s"
                                              (car pair) (cdr pair)))))
             (unless (string-prefix-p "OK" r)
               (princ (format "render %s: %s\n" (cdr pair) r)))))
         (dotimes (_ 60) (unless (>= (length got) 6) (sit-for 0.1)))
         (princ (format "events: %S\n" got))
         (princ (format "status: %s\n" (cmacs-gowl-gabbrev--summary)))
         (let ((ok (and (member "rendered a \"lisp<P>\"" got)
                        (member "rendered b \"abab\"" got)
                        (member "rendered c \"zebra quagga xerus\"" got)
                        (cl-some (lambda (e) (string-match-p
                                              "\\`rendered d \"[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\"\\'"
                                              e))
                                 got)
                        (member "rendered e \"late\"" got)
                        (cl-some (lambda (e) (string-match-p
                                              "\\`render-failed f .*Kaboom" e))
                                 got))))
           (ignore-errors (gowl-stop))
           (princ (if ok "gabbrev-headless: ok\n" "gabbrev-headless: FAIL\n"))
           (kill-emacs (if ok 0 3))))))
  "What `cmacs-gowl-gabbrev-test-lisp-types-headless' runs in a child.")

(ert-deftest cmacs-gowl-gabbrev-test-lisp-types-headless ()
  "Lisp-backed variables, through the real module and the C callback.
A Lisp replacement sees a value resolved before it, a Lisp-defined
type gets its params, an `:async' answer arrives later, an error in
Lisp fails just that expansion, the abbrev table is exported, and the
built-in ;today still renders a date."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (fboundp 'gowl-gabbrev-register-type))
  ;; The headless runner lives with the gowl tests (no `provide' there)
  (unless (fboundp 'cmacs-gowl-tests--run-headless)
    (load (expand-file-name "cmacs-gowl-tests" cmacs-gowl-gabbrev-tests--dir)
          t t))
  (skip-unless (fboundp 'cmacs-gowl-tests--run-headless))
  (skip-unless (cmacs-gowl-tests--runtime-parent))
  (let* ((result (cmacs-gowl-tests--run-headless
                  cmacs-gowl-gabbrev-tests--headless-form))
         (status (car result))
         (output (cdr result)))
    (when (eql status 77)
      (ert-skip "no headless compositor here"))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-search "gabbrev-headless: ok" output)))))

(provide 'cmacs-gowl-gabbrev-tests)

;;; cmacs-gowl-gabbrev-tests.el ends here
