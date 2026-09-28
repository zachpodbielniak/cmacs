;;; cmacs-gowl-input-remap-tests.el --- Tests for per-device input remapping -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl's per-device input remapping: the rule a
;; plist turns into, the one-to-one refusals made before anything is
;; sent, function targets and their dispatch, and the opt-in startup
;; (nothing loads without a rule).  None of these need a compositor;
;; the headless round trip through the real module lives with the other
;; child-cmacs tests in cmacs-gowl-tests.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-input-remap)

(defun cmacs-gowl-input-remap-tests--parse (json)
  "JSON as alists."
  (json-parse-string json :object-type 'alist :false-object nil))

(ert-deftest cmacs-gowl-input-remap-test-wow-rule-json ()
  "The WoW pedal rule becomes the rule the module reads."
  (let* ((json (cmacs-gowl-input-remap-rule-json
                "wow-pedals"
                :match '(:id "1a86:e026" :type keyboard)
                :unmatched 'drop
                :log t
                :map '((KEY_A . (button middle))
                       (KEY_B . (action focus-client
                                        "title:World of Warcraft*")))))
         (rule (cmacs-gowl-input-remap-tests--parse json))
         (map (alist-get 'map rule)))
    (should (equal (alist-get 'name rule) "wow-pedals"))
    (should (equal (alist-get 'match rule)
                   '((id . "1a86:e026") (type . "keyboard"))))
    (should (equal (alist-get 'unmatched rule) "drop"))
    (should (eq (alist-get 'log rule) t))
    (should (equal (alist-get 'KEY_A map) '((button . "middle"))))
    (should (equal (alist-get 'KEY_B map)
                   '((action . "focus-client")
                     (arg . "title:World of Warcraft*"))))))

(ert-deftest cmacs-gowl-input-remap-test-target-forms ()
  "Every declarative target has one JSON form."
  (let* ((rule (cmacs-gowl-input-remap-tests--parse
                (cmacs-gowl-input-remap-rule-json
                 "forms" :match '(:vendor #x1a86 :product "e026")
                 :map '((KEY_A . pass)
                        (KEY_B . drop)
                        ("KEY_C" . (key "Super+9"))
                        (KEY_D . (key KEY_F13))
                        (BTN_SIDE . (button BTN_MIDDLE))
                        (WHEEL_UP . (action tag-view 256))
                        (KEY_E . (action zoom))
                        (KEY_F . (command "scratchpad-toggle"))))))
         (map (alist-get 'map rule)))
    ;; an integer id is written in hex, the only way the module reads it
    (should (equal (alist-get 'match rule)
                   '((vendor . "0x1a86") (product . "e026"))))
    (should (equal (alist-get 'KEY_A map) "pass"))
    (should (equal (alist-get 'KEY_B map) "drop"))
    (should (equal (alist-get 'KEY_C map) '((key . "Super+9"))))
    (should (equal (alist-get 'KEY_D map) '((key . "KEY_F13"))))
    (should (equal (alist-get 'BTN_SIDE map) '((button . "BTN_MIDDLE"))))
    (should (equal (alist-get 'WHEEL_UP map)
                   '((action . "tag-view") (arg . "256"))))
    (should (equal (alist-get 'KEY_E map) '((action . "zoom"))))
    (should (equal (alist-get 'KEY_F map)
                   '((command . "scratchpad-toggle"))))))

(ert-deftest cmacs-gowl-input-remap-test-empty-map ()
  "A rule with no mappings (it only claims) still has a map object."
  (let ((json (cmacs-gowl-input-remap-rule-json
               "mute" :match '(:name "Pedal*") :unmatched 'drop)))
    (should (string-match-p "\"map\":{}" json))))

(ert-deftest cmacs-gowl-input-remap-test-refuses-macros ()
  "Anything asking one input for more than one output is refused here."
  (let ((match '(:name "Pedal")))
    ;; a list of targets
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match
                   :map '((KEY_A . ((key "a") (key "b")))))
                  :type 'user-error)
    ;; two values for one target
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match :map '((KEY_A . (key "a" "b"))))
                  :type 'user-error)
    ;; a delay or a repeat inside a target
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match :map '((KEY_A . (key "a" :delay 50))))
                  :type 'user-error)
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match :map '((KEY_A . (action zoom :repeat))))
                  :type 'user-error)
    ;; a macro key on the rule
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match :macro '("a" "b"))
                  :type 'user-error)
    ;; one input mapped twice
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match
                   :map '((KEY_A . drop) ("KEY_A" . pass)))
                  :type 'user-error)
    ;; a key target that is a list
    (should-error (cmacs-gowl-input-remap-rule-json
                   "r" :match match :map '((KEY_A . (key ("a" "b")))))
                  :type 'user-error)))

(ert-deftest cmacs-gowl-input-remap-test-refuses-bad-match ()
  "A rule has to name its device; `:type' alone names every keyboard."
  (should-error (cmacs-gowl-input-remap-rule-json
                 "r" :match '(:type keyboard))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "r" :match '(:colour "red"))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "r" :match '(:name "x") :unmatched 'maybe)
                :type 'user-error))

(ert-deftest cmacs-gowl-input-remap-test-function-target ()
  "A function target is a `custom' action calling back into Elisp."
  (let* ((cmacs-gowl-input-remap--functions (make-hash-table :test #'equal))
         (calls nil)
         (rule (cmacs-gowl-input-remap-tests--parse
                (cmacs-gowl-input-remap-rule-json
                 "fn" :match '(:name "Pedal")
                 :map `((KEY_A . ,(lambda (rule input)
                                    (push (list rule input) calls)))
                        (KEY_B . ,(lambda () (push 'no-args calls)))))))
         (target (alist-get 'KEY_A (alist-get 'map rule))))
    (should (equal (alist-get 'action target) "custom"))
    ;; the form is only string literals, and reads back as the call
    (should (equal (read (alist-get 'arg target))
                   '(cmacs-gowl-input-remap--call "fn" "KEY_A")))
    (eval (read (alist-get 'arg target)) t)
    (cmacs-gowl-input-remap--call "fn" "KEY_B")
    (should (equal calls '(no-args ("fn" "KEY_A"))))
    ;; a function that errors is reported, not propagated
    (puthash "fn/KEY_C" (lambda () (error "Boom"))
             cmacs-gowl-input-remap--functions)
    (should-not (condition-case nil
                    (progn (cmacs-gowl-input-remap--call "fn" "KEY_C") nil)
                  (error t)))))

(ert-deftest cmacs-gowl-input-remap-test-define-without-compositor ()
  "A rule defined before gowl runs is validated, kept, and not sent."
  (let ((cmacs-gowl-input-remap--defined nil)
        (sent nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil))
              ((symbol-function 'gowl-run-command)
               (lambda (&rest args) (push args sent) nil)))
      (should (equal (cmacs-gowl-input-remap-define
                      "p" :match '(:name "Pedal") :map '((KEY_A . drop)))
                     "p"))
      ;; redefining replaces
      (cmacs-gowl-input-remap-define
       "p" :match '(:name "Pedal") :map '((KEY_A . pass)))
      (should (= (length cmacs-gowl-input-remap--defined) 1))
      (should-not sent)
      ;; and a bad rule is refused even with nothing to send it to
      (should-error (cmacs-gowl-input-remap-define
                     "bad" :match '(:name "x")
                     :map '((KEY_A . ((key "a") (key "b")))))
                    :type 'user-error))))

(ert-deftest cmacs-gowl-input-remap-test-opt-in-startup ()
  "No rule, no module: startup loads nothing.  A rule loads it."
  (let ((cmacs-gowl-input-remap--defined nil)
        (cmacs-gowl-input-remap-rules nil)
        (enabled nil)
        (commands nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-enable-module)
               (lambda (&rest args) (push args enabled) t))
              ((symbol-function 'gowl-configure-module)
               (lambda (&rest _) t))
              ((symbol-function 'gowl-run-command)
               (lambda (line &rest _)
                 (push line commands)
                 (cond ((equal line "inputremap-status")
                        (and enabled "OK enabled=1"))
                       ((string-prefix-p "inputremap-add " line)
                        "OK added x")
                       (t "OK")))))
      (cmacs-gowl-input-remap--on-start)
      (should-not enabled)
      (should-not commands)

      (setq cmacs-gowl-input-remap-rules
            '(("wow-pedals" :match (:id "1a86:e026")
               :map ((KEY_A . (button middle))))))
      (cmacs-gowl-input-remap--on-start)
      (should (equal enabled '(("inputremap"))))
      (should (cl-some (lambda (l) (string-prefix-p "inputremap-add " l))
                       commands)))))

(ert-deftest cmacs-gowl-input-remap-test-command-errors ()
  "The module's ERROR replies and its absence become user errors."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
            ((symbol-function 'gowl-run-command)
             (lambda (line &rest _)
               (if (string-suffix-p "missing" line) nil
                 "ERROR no rule named x"))))
    (should-error (cmacs-gowl-input-remap--command "inputremap-remove x")
                  :type 'user-error)
    (should-error (cmacs-gowl-input-remap--command "inputremap-missing")
                  :type 'user-error)))

(ert-deftest cmacs-gowl-input-remap-test-match-snippet ()
  "A device becomes a `:match' plist by id, or by name without one."
  (should (equal (cmacs-gowl-input-remap--match-snippet
                  '((type . "keyboard") (vendor-product . "1a86:e026")
                    (name . "PCsensor FootSwitch")))
                 "(:id \"1a86:e026\" :type keyboard)"))
  (should (equal (cmacs-gowl-input-remap--match-snippet
                  '((type . "pointer") (vendor-product . "0000:0000")
                    (name . "virtual")))
                 "(:name \"virtual\" :type pointer)")))

(provide 'cmacs-gowl-input-remap-tests)

;;; cmacs-gowl-input-remap-tests.el ends here
