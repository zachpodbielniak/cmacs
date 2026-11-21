;;; cmacs-deixis-tests.el --- Tests for cmacs-deixis  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Pure ERT: pointers are stubs that answer from a table keyed by time,
;; word times are synthetic, and every gowl DEFUN a command reaches is
;; stubbed (with &rest, as a C DEFUN's stub must be).  No audio, no
;; compositor, nothing on the screen.  The compositor's ring itself
;; (cmacs/gowl/cmacs-gowl-pointer-history.c) is only reachable with a
;; live compositor; its tests here are gated on the primitive and skip
;; without one.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-deixis)

;; The voice loop's variables, bound here without loading the loop.
(defvar cmacs-voice-loop-mode)
(defvar cmacs-voice-loop--last-target)

(declare-function gowl-running-p "cmacs-gowl.c")
(declare-function gowl-pointer-history-now "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-enable "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-at "cmacs-gowl-pointer-history.c")
(declare-function gowl-pointer-history-dwell "cmacs-gowl-pointer-history.c")

(defmacro cmacs-deixis-tests--with-pointer (table &rest body)
  "Run BODY with one stub pointer answering from TABLE.
TABLE is a list of (FROM-MS TO-MS REFERENT): the pointer \"rested\" on
REFERENT between those times.  A lookup answers with the entry
overlapping the word's window the most, as a real history's dwell
does.  Region and point fallbacks are off unless BODY turns them on."
  (declare (indent 1))
  `(let* ((table ,table)
          (cmacs-deixis--pointers nil)
          (cmacs-deixis-pointer-order '(stub))
          (cmacs-deixis-fallback-to-point nil)
          (cmacs-deixis-latency-ms 0)
          (cmacs-deixis-last-bindings nil))
     (cmacs-deixis-register-pointer
      'stub
      (lambda (ms)
        (let* ((w (or cmacs-deixis-lookup-window (cons ms ms)))
               (best nil) (best-d -1))
          (dolist (e table)
            (let ((d (- (min (cdr w) (nth 1 e)) (max (car w) (nth 0 e)))))
              (when (> d best-d) (setq best e best-d d))))
          (and best (>= best-d 0) (nth 2 best)))))
     ,@body))

(defconst cmacs-deixis-tests--browser
  '(:kind window :client browser :client-id 12 :app-id "librewolf"
    :title "wlroots docs" :monitor 0 :x 400.0 :y 300.0 :confidence 1.0
    :label "window: librewolf — 'wlroots docs' (client 12)"))

(defconst cmacs-deixis-tests--second-screen
  '(:kind monitor :monitor 1 :x 2900.0 :y 400.0 :confidence 1.0
    :label "monitor 1 (DP-2) at 2900,400"))


;;;; Words

(ert-deftest cmacs-deixis-test-merge-tokens ()
  "Subword pieces become words; punctuation stays on its word."
  (should (equal (cmacs-deixis-merge-tokens
                  '("▁mo" "ve" "▁that" "," "▁o" "ver" "▁there" ".")
                  '(100 180 400 520 700 760 1000 1200))
                 '(("move" 100 400) ("that," 400 700)
                   ("over" 700 1000) ("there." 1000 1500))))
  ;; A leading space is the other word marker (BPE vocabularies).
  (should (equal (mapcar #'car (cmacs-deixis-merge-tokens
                                '(" close" " th" "at") '(0 300 380)))
                 '("close" "that")))
  ;; The end of the audio bounds the last word.
  (should (equal (cmacs-deixis-merge-tokens '("▁hi") '(100) 250)
                 '(("hi" 100 250))))
  ;; A word never ends after the next begins, nor 300 ms after its last
  ;; piece began.
  (should (equal (cmacs-deixis-merge-tokens '("▁a" "▁b") '(0 2000))
                 '(("a" 0 300) ("b" 2000 2300))))
  ;; Scripts without spaces: one character, one word.
  (should (equal (mapcar #'car (cmacs-deixis-merge-tokens
                                '("这" "个") '(0 200)))
                 '("这" "个")))
  (should-not (cmacs-deixis-merge-tokens nil nil)))

(ert-deftest cmacs-deixis-test-interpolation ()
  "Words share a segment's span in proportion to their length."
  (let ((w (cmacs-deixis-interpolate-words "move that there" 1000 2600)))
    ;; Weights 5, 5, 6 of 16: 500, 500, 600 ms.
    (should (equal w '(("move" 1000 1500 :approx) ("that" 1500 2000 :approx)
                       ("there" 2000 2600 :approx)))))
  (should-not (cmacs-deixis-interpolate-words "" 0 1000)))

(ert-deftest cmacs-deixis-test-result-words ()
  "Real word times win; segments are interpolated and flagged."
  ;; sherpa: the recognizer's own words, untouched.
  (should (equal (cmacs-deixis-result-words
                  '((:text . "close that")
                    (:segments ((:start . 0) (:end . 900) (:text . "close that")))
                    (:words ("close" 0 400) ("that" 500 800))))
                 '(("close" 0 400) ("that" 500 800))))
  ;; whisper: segment times only.
  (let ((w (cmacs-deixis-result-words
            '((:text . "close that now")
              (:segments ((:start . 0) (:end . 800) (:text . "close that"))
                         ((:start . 1000) (:end . 1400) (:text . "now")))))))
    (should (equal (mapcar #'car w) '("close" "that" "now")))
    (should (cl-every (lambda (x) (memq :approx x)) w))
    (should (equal (cdr (nth 2 w)) '(1000 1400 :approx))))
  ;; Raw tokens with timestamps in seconds.
  (should (equal (cmacs-deixis-result-words
                  '((:text . "hi there")
                    (:tokens "▁hi" "▁the" "re")
                    (:timestamps . [0.0 0.5 0.6])
                    (:duration . 800)))
                 '(("hi" 0 300) ("there" 500 800))))
  ;; Nothing but text: a guess, flagged.
  (let ((cmacs-deixis-fallback-word-ms 100))
    (should (equal (cmacs-deixis-result-words '((:text . "a b")))
                   '(("a" 0 100 :approx) ("b" 100 200 :approx))))))

(ert-deftest cmacs-deixis-test-token-times-skip-wake-phrase ()
  "The text is matched from the end, so a cut wake phrase costs nothing."
  (let ((times (cmacs-deixis--token-times
                '("Close" "that.")
                '(("hey" 0 200) ("jarvis" 200 600) ("close" 800 1100)
                  ("that" 1200 1500)))))
    (should (equal (aref times 0) '(800 1100 nil)))
    (should (equal (aref times 1) '(1200 1500 nil))))
  ;; A token the recognizer spelt differently takes a time in between.
  (let ((times (cmacs-deixis--token-times
                '("put" "21" "there")
                '(("put" 0 200) ("twenty" 300 500) ("there" 900 1100)))))
    (should (equal (aref times 0) '(0 200 nil)))
    (should (equal (aref times 2) '(900 1100 nil)))
    (should (equal (aref times 1) '(200 550 t)))))


;;;; Detection

(ert-deftest cmacs-deixis-test-find ()
  "Demonstratives are found with their roles; conjunctions are not."
  (should (equal (mapcar (lambda (d) (list (plist-get d :index)
                                           (plist-get d :word)
                                           (plist-get d :role)))
                         (cmacs-deixis-find "Move THAT, over there."))
                 '((1 "that" object) (3 "there" place))))
  ;; "that" introducing a clause, "it" as a dummy subject.
  (should-not (cmacs-deixis-find "I think that we should stop"))
  (should-not (cmacs-deixis-find "it is raining"))
  (should (equal (mapcar (lambda (d) (plist-get d :role))
                         (cmacs-deixis-find "summarise it"))
                 '(pronoun)))
  ;; The vocabulary is the user's.
  (let ((cmacs-deixis-words '(("das" . object) ("dort" . place))))
    (should (equal (mapcar (lambda (d) (plist-get d :word))
                           (cmacs-deixis-find "schieb das nach dort"))
                   '("das" "dort")))
    (should-not (cmacs-deixis-find "move that there"))))


;;;; Resolving

(ert-deftest cmacs-deixis-test-two-referents-in-one-utterance ()
  "Each word gets what was pointed at while IT was spoken."
  (cmacs-deixis-tests--with-pointer
      `((10000 11300 ,cmacs-deixis-tests--browser)
        (11300 14000 ,cmacs-deixis-tests--second-screen))
    (let* ((words '(("move" 500 800) ("that" 900 1200) ("over" 1300 1500)
                    ("there" 1700 2000)))
           (b (cmacs-deixis-resolve "move that over there" words 10000)))
      (should (= (length b) 2))
      (should (equal (plist-get (plist-get (nth 0 b) :referent) :client-id) 12))
      (should (eq (plist-get (plist-get (nth 1 b) :referent) :kind) 'monitor))
      (should (equal (mapcar (lambda (x) (plist-get x :marker)) b) '(1 2)))
      ;; The word's time is the middle of the word, on the pointer's clock.
      (should (= (plist-get (nth 0 b) :time) 11050))
      (should (eq (plist-get (plist-get (nth 0 b) :referent) :device) 'stub)))))

(ert-deftest cmacs-deixis-test-latency-shift ()
  "`cmacs-deixis-latency-ms' moves the lookup."
  (cmacs-deixis-tests--with-pointer
      `((0 11000 ,cmacs-deixis-tests--browser)
        (11000 20000 ,cmacs-deixis-tests--second-screen))
    (let ((words '(("close" 500 800) ("that" 1300 1500)))
          (cmacs-deixis-window-before-ms 0)
          (cmacs-deixis-window-after-ms 0))
      ;; Unshifted the word falls at 11300-11500: the second screen.
      (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                              "close that" words 10000))
                                        :referent)
                             :kind)
                  'monitor))
      ;; Half a second earlier it was still the browser.
      (let ((cmacs-deixis-latency-ms -600))
        (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                                "close that" words 10000))
                                          :referent)
                               :kind)
                    'window))))))

(ert-deftest cmacs-deixis-test-window-and-dwell ()
  "The pointer's longest rest in the word's window wins, not one instant."
  (cmacs-deixis-tests--with-pointer
      ;; On the browser until 100 ms into the word, then away.
      `((0 11000 ,cmacs-deixis-tests--browser)
        (11000 11050 ,cmacs-deixis-tests--second-screen)
        (11050 20000 ,cmacs-deixis-tests--browser))
    (let* ((cmacs-deixis-window-before-ms 150)
           (cmacs-deixis-window-after-ms 300)
           (b (cmacs-deixis-resolve "close that"
                                    '(("close" 500 800) ("that" 1000 1040))
                                    10000)))
      ;; The instant (11020) is on the second screen; the window is not.
      (should (eq (plist-get (plist-get (car b) :referent) :kind) 'window)))))

(ert-deftest cmacs-deixis-test-region-beats-pointer ()
  "An active region is \"this\" unless the pointer is clearly elsewhere."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (set-window-buffer (selected-window) (current-buffer))
    (transient-mark-mode 1)
    (set-mark 1)
    (goto-char 8)
    (activate-mark)
    (let ((words '(("summarise" 0 600) ("this" 700 900)))
          (here (list :kind 'buffer-position :window (selected-window)
                      :buffer (current-buffer) :position 3 :confidence 1.0
                      :label "buffer: here")))
      ;; No pointer at all.
      (cmacs-deixis-tests--with-pointer nil
        (let ((r (plist-get (car (cmacs-deixis-resolve "summarise this" words 0))
                            :referent)))
          (should (eq (plist-get r :kind) 'region))
          (should (equal (list (plist-get r :beg) (plist-get r :end)) '(1 8)))
          ;; The label names the place and never the text.
          (should-not (string-match-p "two" (plist-get r :label)))))
      ;; The pointer in the region's own window: still the region.
      (cmacs-deixis-tests--with-pointer `((0 5000 ,here))
        (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                                "summarise this" words 0))
                                          :referent)
                               :kind)
                    'region)))
      ;; Clearly on another window: the pointer.
      (cmacs-deixis-tests--with-pointer `((0 5000 ,cmacs-deixis-tests--browser))
        (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                                "summarise this" words 0))
                                          :referent)
                               :kind)
                    'window))
        ;; ...unless it is not sure enough.
        (let ((cmacs-deixis-elsewhere-confidence 1.1))
          (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                                  "summarise this" words 0))
                                            :referent)
                                 :kind)
                      'region))))
      ;; A place is never the region.
      (cmacs-deixis-tests--with-pointer `((0 5000 ,cmacs-deixis-tests--browser))
        (should (eq (plist-get (plist-get (car (cmacs-deixis-resolve
                                                "go there"
                                                '(("go" 0 200) ("there" 300 600))
                                                0))
                                          :referent)
                               :kind)
                    'window))))
    (deactivate-mark)))

(ert-deftest cmacs-deixis-test-pronoun ()
  "\"It\" follows the object before it, and is dropped with nothing."
  (cmacs-deixis-tests--with-pointer
      `((0 1000 ,cmacs-deixis-tests--browser))
    ;; "it" at 5 s has no pointer of its own: the earlier "that".
    (let ((b (cmacs-deixis-resolve
              "take that and close it"
              '(("take" 0 200) ("that" 300 500) ("and" 600 700)
                ("close" 4800 5000) ("it" 5100 5200))
              0)))
      (should (= (length b) 2))
      (should (equal (mapcar (lambda (x) (plist-get x :marker)) b) '(1 1))))
    (should-not (cmacs-deixis-resolve "close it" '(("close" 4800 5000)
                                                   ("it" 5100 5200))
                                      0))))

(ert-deftest cmacs-deixis-test-fallback-to-point ()
  "With nothing pointed at, \"this\" is point, with low confidence."
  (cmacs-deixis-tests--with-pointer nil
    (let ((cmacs-deixis-fallback-to-point t))
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (let ((r (plist-get (car (cmacs-deixis-resolve
                                  "explain this" '(("explain" 0 300) ("this" 400 600))
                                  0))
                            :referent)))
          (should (eq (plist-get r :kind) 'point))
          (should (< (plist-get r :confidence) 0.5)))))))

(ert-deftest cmacs-deixis-test-broken-pointer-is-skipped ()
  "A pointer that signals costs its answer, not the utterance."
  (let ((cmacs-deixis--pointers nil)
        (cmacs-deixis-pointer-order '(bad good))
        (cmacs-deixis-fallback-to-point nil)
        (inhibit-message t))
    (cmacs-deixis-register-pointer 'bad (lambda (&rest _) (error "Boom")))
    (cmacs-deixis-register-pointer
     'good (lambda (&rest _) (copy-sequence cmacs-deixis-tests--browser)))
    (let ((r (cmacs-deixis--pointer-referent 100 0 200)))
      (should (eq (plist-get r :device) 'good)))))


;;;; Annotation

(ert-deftest cmacs-deixis-test-annotate ()
  "Markers follow the words; the legend names things by id."
  (cmacs-deixis-tests--with-pointer
      `((10000 11300 ,cmacs-deixis-tests--browser)
        (11300 14000 ,cmacs-deixis-tests--second-screen))
    (let* ((words '(("move" 500 800) ("that" 900 1200) ("over" 1300 1500)
                    ("there" 1700 2000)))
           (text "Move that over there.")
           (out (cmacs-deixis-annotate
                 text (cmacs-deixis-resolve text words 10000))))
      (should (equal out
                     (concat
                      "Move that [that=①] over there. [there=②]\n\n"
                      "[Pointing: what each marked word referred to when it was spoken]\n"
                      "① window: librewolf — 'wlroots docs' (client 12)\n"
                      "② monitor 1 (DP-2) at 2900,400")))))
  ;; Nothing pointed at: said so, not invented.
  (cmacs-deixis-tests--with-pointer nil
    (let* ((text "close that")
           (out (cmacs-deixis-annotate
                 text (cmacs-deixis-resolve text '(("close" 0 300) ("that" 400 600)) 0))))
      (should (string-match-p "\\[that=\\?\\]" out))
      (should (string-match-p "nothing was being pointed at" out))))
  ;; No demonstratives: the text, untouched.
  (should (equal (cmacs-deixis-annotate "hello" nil) "hello"))
  (should (equal (cmacs-deixis--marker-string 21) "(21)")))


;;;; Commands

(ert-deftest cmacs-deixis-test-canonical ()
  "Filler words go, demonstratives become placeholders."
  (cmacs-deixis-tests--with-pointer `((0 99999 ,cmacs-deixis-tests--browser))
    (cl-flet ((canon (text)
                (cmacs-deixis-canonical
                 text (cmacs-deixis-resolve text nil 0))))
      (should (equal (canon "Please move that window over there.")
                     "move <object> <place>"))
      (should (equal (canon "swap this and that") "swap <object> and <object>"))
      (should (equal (canon "Close that!") "close <object>"))
      (should (equal (canon "open that here") "open <object> <place>")))))

(defmacro cmacs-deixis-tests--with-gowl (&rest body)
  "Run BODY with the gowl DEFUNs commands use recording into `calls'."
  (declare (indent 0))
  `(let ((calls nil)
         (cmacs-deixis-confirm-destructive nil))
     (cl-letf (((symbol-function 'gowl-list-monitors)
                (lambda (&rest _) '(mon-0 mon-1)))
               ((symbol-function 'gowl-monitor-info)
                (lambda (&rest args)
                  (if (eq (car args) 'mon-1)
                      '((name . "DP-2") (geometry 2560 0 1920 1080))
                    '((name . "DP-1") (geometry 0 0 2560 1440)))))
               ((symbol-function 'gowl-move-client-to-monitor)
                (lambda (&rest args) (push (cons 'to-monitor args) calls) nil))
               ((symbol-function 'gowl-client-set-geometry)
                (lambda (&rest args) (push (cons 'geometry args) calls) nil))
               ((symbol-function 'gowl-set-tags)
                (lambda (&rest args) (push (cons 'tags args) calls) nil))
               ((symbol-function 'gowl-swap-clients)
                (lambda (&rest args) (push (cons 'swap args) calls) nil))
               ((symbol-function 'gowl-close-client)
                (lambda (&rest args) (push (cons 'close args) calls) nil))
               ((symbol-function 'gowl-focus-client)
                (lambda (&rest args) (push (cons 'focus args) calls) t))
               ;; The voice engine may or may not be loaded: run now.
               ((symbol-function 'cmacs-deixis--run-later)
                (lambda (fn) (funcall fn))))
       ,@body)))

(defun cmacs-deixis-tests--say (text words)
  "Resolve TEXT with WORDS from time 0 and try the commands."
  (cmacs-deixis-run-command text (cmacs-deixis-resolve text words 0)))

(ert-deftest cmacs-deixis-test-command-move-to-monitor ()
  "\"Move that there\" sends the window to the pointed screen."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer
        `((0 1000 ,cmacs-deixis-tests--browser)
          (1000 9000 ,cmacs-deixis-tests--second-screen))
      (should (eq (cmacs-deixis-tests--say
                   "move that over there"
                   '(("move" 0 200) ("that" 300 500) ("over" 1200 1300)
                     ("there" 1500 1800)))
                  'move))
      (should (equal calls '((to-monitor browser mon-1)))))
    ;; A floating window also takes the half that was pointed at.
    (setq calls nil)
    (cmacs-deixis-tests--with-pointer
        `((0 1000 (:floating t ,@cmacs-deixis-tests--browser))
          (1000 9000 ,cmacs-deixis-tests--second-screen))
      (cmacs-deixis-tests--say
       "put that there" '(("put" 0 200) ("that" 300 500) ("there" 1500 1800)))
      ;; x 2900 is in the left half of 2560..4480.
      (should (equal (reverse calls)
                     '((to-monitor browser mon-1)
                       (geometry browser 2560 0 960 1080)))))))

(ert-deftest cmacs-deixis-test-command-move-onto-window-swaps ()
  "Onto another window of the same screen is a swap."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer
        `((0 1000 ,cmacs-deixis-tests--browser)
          (1000 9000 (:kind window :client term :client-id 7 :monitor 0
                      :x 1800.0 :y 300.0 :confidence 1.0 :label "window: gst")))
      (cmacs-deixis-tests--say
       "move that there" '(("move" 0 200) ("that" 300 500) ("there" 1500 1800)))
      (should (equal calls '((swap browser term)))))))

(ert-deftest cmacs-deixis-test-command-close-confirms ()
  "\"Close that\" asks first, and names what it would close."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer `((0 9000 ,cmacs-deixis-tests--browser))
      (let ((asked nil) (cmacs-deixis-confirm-destructive t))
        (cl-letf (((symbol-function 'cmacs-deixis--confirm)
                   (lambda (prompt action) (setq asked (cons prompt action)))))
          (should (eq (cmacs-deixis-tests--say
                       "close that" '(("close" 0 200) ("that" 300 500)))
                      'close))
          ;; Nothing closed yet.
          (should-not calls)
          (should (string-match-p "client 12" (car asked)))
          (funcall (cdr asked))
          (should (equal calls '((close browser)))))))))

(ert-deftest cmacs-deixis-test-command-focus-and-swap ()
  "\"Go there\" focuses; \"swap this and that\" swaps two windows."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer
        `((0 1000 ,cmacs-deixis-tests--browser)
          (1000 9000 (:kind window :client term :client-id 7 :monitor 1
                      :confidence 1.0 :label "window: gst")))
      (should (eq (cmacs-deixis-tests--say
                   "go there" '(("go" 1200 1400) ("there" 1500 1800)))
                  'focus))
      (should (equal calls '((focus term))))
      (setq calls nil)
      (should (eq (cmacs-deixis-tests--say
                   "swap this and that"
                   '(("swap" 0 200) ("this" 300 500) ("and" 600 700)
                     ("that" 1500 1800)))
                  'swap))
      (should (equal calls '((swap browser term)))))))

(ert-deftest cmacs-deixis-test-command-emacs-buffer-move ()
  "A buffer pointed at moves into the pointed Emacs window."
  (save-window-excursion
    (delete-other-windows)
    (let* ((left (selected-window))
           (right (split-window-right))
           (a (generate-new-buffer " *deixis-a*"))
           (b (generate-new-buffer " *deixis-b*")))
      (unwind-protect
          (progn
            (set-window-buffer left a)
            (set-window-buffer right b)
            (cmacs-deixis-tests--with-gowl
              (cmacs-deixis-tests--with-pointer
                  `((0 1000 (:kind buffer-position :window ,left :buffer ,a
                             :position 1 :confidence 1.0 :label "buffer: a"))
                    (1000 9000 (:kind buffer-position :window ,right :buffer ,b
                                :position 1 :confidence 1.0 :label "buffer: b")))
                (cmacs-deixis-tests--say
                 "move that there"
                 '(("move" 0 200) ("that" 300 500) ("there" 1500 1800)))
                (should (eq (window-buffer right) a))
                (should-not calls))))
        (kill-buffer a)
        (kill-buffer b)))))

(ert-deftest cmacs-deixis-test-command-needs-every-referent ()
  "A command never runs on something that was not pointed at."
  (cmacs-deixis-tests--with-gowl
    ;; Nothing under the pointer when "there" was said.
    (cmacs-deixis-tests--with-pointer `((0 1000 ,cmacs-deixis-tests--browser))
      (should-not (cmacs-deixis-tests--say
                   "move that there"
                   '(("move" 0 200) ("that" 300 500) ("there" 4000 4300))))
      (should-not calls))
    ;; Not a command at all.
    (cmacs-deixis-tests--with-pointer `((0 9000 ,cmacs-deixis-tests--browser))
      (should-not (cmacs-deixis-tests--say
                   "what is that" '(("what" 0 200) ("is" 250 350) ("that" 400 600))))
      (should-not calls))))

(ert-deftest cmacs-deixis-test-stale-client ()
  "A window that closed between the word and the transcript is refused."
  ;; The compositor's lookup found the id but no live client.
  (let* ((cmacs-deixis-lookup-window nil)
         (r (cmacs-deixis--gowl-referent
             '(:time 100 :x 10.0 :y 20.0 :client nil :client-id 12 :monitor 0))))
    (should (eq (plist-get r :kind) 'window))
    (should (plist-get r :stale))
    (should-not (plist-get r :client))
    (should-not (cmacs-deixis--desktop-window-p r))
    (should (string-match-p "closed" (plist-get r :label)))
    (cmacs-deixis-tests--with-gowl
      (cmacs-deixis-tests--with-pointer `((0 9000 ,r))
        (let ((b (cmacs-deixis-resolve "close that"
                                       '(("close" 0 200) ("that" 300 500)) 0)))
          ;; No command acts on it...
          (should-not (cmacs-deixis-run-command "close that" b))
          (should-not calls)
          ;; ...and a model is told what happened.
          (should (string-match-p "has since closed (client 12)"
                                  (cmacs-deixis-annotate "close that" b)))))))
  ;; Nothing under the pointer at all: the screen it was on.
  (cl-letf (((symbol-function 'gowl-list-monitors) (lambda (&rest _) nil))
            ((symbol-function 'gowl-monitor-info) (lambda (&rest _) nil)))
    (let ((r (cmacs-deixis--gowl-referent
              '(:time 100 :x 10.0 :y 20.0 :client nil :client-id 0 :monitor 1))))
      (should (eq (plist-get r :kind) 'monitor))
      (should (equal (plist-get r :label) "monitor 1 at 10,20")))))

(ert-deftest cmacs-deixis-test-define-command ()
  "A user's command sees its referents in spoken order."
  (let ((cmacs-deixis-commands cmacs-deixis-commands)
        (got nil))
    (cmacs-deixis-define-command test-raise
        "\\`raise <object>\\'" (that)
      "Raise the pointed window."
      (setq got (plist-get that :client-id)))
    (cmacs-deixis-tests--with-gowl
      (cmacs-deixis-tests--with-pointer `((0 9000 ,cmacs-deixis-tests--browser))
        (should (eq (cmacs-deixis-tests--say
                     "raise that" '(("raise" 0 200) ("that" 300 500)))
                    'test-raise))
        (should (equal got 12))))
    (should (equal (plist-get (alist-get 'test-raise cmacs-deixis-commands) :doc)
                   "Raise the pointed window."))))


;;;; The voice loop

(ert-deftest cmacs-deixis-test-filter ()
  "The filter takes commands, annotates the rest, passes plain speech."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer
        `((10000 11000 ,cmacs-deixis-tests--browser)
          (11000 19000 ,cmacs-deixis-tests--second-screen))
      (let ((cmacs-deixis--segments '((7 . 10000)))
            (cmacs-deixis--calibration nil)
            (cmacs-deixis-resolved-functions nil)
            ;; This is the filter with nobody claiming what the commands
            ;; leave: deictic questions (cmacs-deixis-ask) have their
            ;; own suite.
            (cmacs-deixis-unclaimed-functions nil)
            (cmacs-voice-loop--last-target 'chat))
        ;; A command: taken, nothing to send.
        (should-not (cmacs-deixis-filter
                     "move that there" 7
                     '((:text . "jarvis move that there")
                       (:words ("jarvis" 0 300) ("move" 400 500) ("that" 600 800)
                               ("there" 1500 1800)))))
        (should (equal calls '((to-monitor browser mon-1))))
        ;; Not a command: annotated for the model.
        (let ((out (cmacs-deixis-filter
                    "what is that" 7
                    '((:text . "what is that")
                      (:words ("what" 0 200) ("is" 250 350) ("that" 600 800))))))
          (should (string-prefix-p "what is that [that=①]\n" out))
          (should (string-match-p "client 12" out)))
        ;; The voice-command route gets plain words.
        (let ((cmacs-voice-loop--last-target 'commands))
          (should (equal (cmacs-deixis-filter
                          "what is that" 7
                          '((:text . "what is that")
                            (:words ("what" 0 200) ("is" 250 350) ("that" 600 800))))
                         "what is that"))
          (should (= (length cmacs-deixis-last-bindings) 1)))
        ;; No demonstrative: untouched.
        (should (equal (cmacs-deixis-filter "hello world" 7 '((:text . "hello world")))
                       "hello world"))))))

(ert-deftest cmacs-deixis-test-segment-clock ()
  "A segment's start is the hook's time less the audio already in it."
  (let ((cmacs-deixis--segments nil)
        (cmacs-deixis-clock-function (lambda () 50000)))
    (cmacs-deixis--segment-started 3 384)
    (should (equal cmacs-deixis--segments '((3 . 49616))))
    (dotimes (i 20) (cmacs-deixis--segment-started (+ 4 i) 0))
    (should (= (length cmacs-deixis--segments) 8))))

(ert-deftest cmacs-deixis-test-lisp-ring ()
  "The Lisp-side rings store changes and answer with the longest rest."
  (let ((cmacs-deixis--mouse-ring nil))
    (cmacs-deixis--ring-push 'cmacs-deixis--mouse-ring '(100 f 10 10))
    (cmacs-deixis--ring-push 'cmacs-deixis--mouse-ring '(200 f 10 10))
    (cmacs-deixis--ring-push 'cmacs-deixis--mouse-ring '(300 f 50 50))
    (cmacs-deixis--ring-push 'cmacs-deixis--mouse-ring '(350 f 90 90))
    ;; The unchanged sample was not stored.
    (should (= (length cmacs-deixis--mouse-ring) 3))
    (should (equal (cmacs-deixis--ring-at cmacs-deixis--mouse-ring 320)
                   '(300 f 50 50)))
    (should-not (cmacs-deixis--ring-at cmacs-deixis--mouse-ring 50))
    ;; 250..400: 50 ms at (10,10), 50 at (50,50), 50 at (90,90) -- a
    ;; tie, the earliest wins; 150..400 is plainly the first.
    (should (equal (car (cmacs-deixis--ring-dwell cmacs-deixis--mouse-ring 150 400))
                   '(100 f 10 10)))
    (should (equal (cmacs-deixis--ring-dwell cmacs-deixis--mouse-ring 320 600)
                   '((350 f 90 90) . 250)))
    (should-not (cmacs-deixis--ring-dwell cmacs-deixis--mouse-ring 0 50))))

(ert-deftest cmacs-deixis-test-sampling-follows-mode-and-loop ()
  "Pointers are sampled only while the mode is on AND the loop listens."
  (let* ((events nil)
         (cmacs-deixis--pointers nil)
         (cmacs-deixis--sampling nil)
         (cmacs-deixis-mode nil)
         (cmacs-voice-loop-mode nil)
         (state 'idle))
    (cmacs-deixis-register-pointer 'stub #'ignore
                                   :start (lambda () (push 'start events))
                                   :stop (lambda () (push 'stop events)))
    (cl-letf (((symbol-function 'cmacs-voice-loop-state) (lambda (&rest _) state)))
      (setq cmacs-deixis-mode t)
      (cmacs-deixis--update-sampling)
      (should-not events)                 ; the loop is off
      (setq cmacs-voice-loop-mode t state 'listening)
      (cmacs-deixis--update-sampling 'listening 'idle)
      (should (equal events '(start)))
      (setq state 'hearing)
      (cmacs-deixis--update-sampling 'hearing 'listening)
      (should (equal events '(start)))    ; still on, not restarted
      (setq state 'paused)
      (cmacs-deixis--update-sampling 'paused 'hearing)
      (should (equal events '(stop start)))
      (setq state 'listening)
      (cmacs-deixis--update-sampling)
      (setq cmacs-deixis-mode nil)
      (cmacs-deixis--update-sampling)
      (should (equal events '(stop start stop start))))))


(defvar cmacs-voice-loop-utterance-filter-function)
(defvar cmacs-voice-loop-default-route)
(defvar cmacs-voice-loop-routes)
(defvar cmacs-voice-loop--last-sent-seg)
(defvar cmacs-voice-loop--state)
(defvar cmacs-voice-loop--heard-phrases)
(defvar cmacs-voice-loop-state-change-functions)
(declare-function cmacs-voice-loop--on-final "cmacs-voice-loop")

(ert-deftest cmacs-deixis-test-voice-loop-calls-the-filter ()
  "The loop hands a final utterance and its result to the filter.
The filter's text is what goes down the route; nil sends nothing."
  (skip-unless (require 'cmacs-voice-loop nil t))
  ;; A voice loop compiled before the filter existed proves nothing.
  (skip-unless (boundp 'cmacs-voice-loop-utterance-filter-function))
  (let* ((sent nil) (seen nil)
         (inhibit-message t)
         (cmacs-voice-loop-routes nil)
         (cmacs-voice-loop-default-route (lambda (text) (push text sent)))
         (cmacs-voice-loop--last-target nil)
         (cmacs-voice-loop--last-sent-seg 0)
         (cmacs-voice-loop--heard-phrases nil)
         (cmacs-voice-loop--state 'listening)
         (cmacs-voice-loop-state-change-functions nil)
         (result '((:text . "what is that")
                   (:words ("what" 0 200) ("is" 250 350) ("that" 600 800))))
         (cmacs-voice-loop-utterance-filter-function
          (lambda (text seg res)
            (push (list text seg (alist-get :words res)) seen)
            (concat text " [marked]"))))
    (cmacs-voice-loop--on-final result 1 nil)
    (should (equal seen '(("what is that" 1
                           (("what" 0 200) ("is" 250 350) ("that" 600 800))))))
    (should (equal sent '("what is that [marked]")))
    ;; Taken by the filter: nothing is sent.
    (setq cmacs-voice-loop-utterance-filter-function (lambda (&rest _) nil))
    (cmacs-voice-loop--on-final result 2 nil)
    (should (= (length sent) 1))
    ;; A filter that fails does not eat what was said.
    (setq cmacs-voice-loop-utterance-filter-function
          (lambda (&rest _) (error "Boom")))
    (cmacs-voice-loop--on-final result 3 nil)
    (should (equal (car sent) "what is that"))))


;;;; A bare hand pointing, and which pointer is believed

(defvar cmacs-handtrack-pointer-mode)

(defun cmacs-deixis-tests--hand-dwell (rests from to &optional min-ms)
  "What the hand history's dwell DEFUN would say of RESTS for FROM..TO.
RESTS is a list of (BEGIN END SAMPLE): the hand held the pointing pose
on one spot from BEGIN to END.  As in C, the rest that lasted longest
inside the window wins, one shorter than MIN-MS (default 120) is none,
:time is clipped to the window and :since is not."
  (let ((best nil) (best-d -1))
    (dolist (e rests)
      (let ((d (- (min to (nth 1 e)) (max from (nth 0 e)))))
        (when (and (>= d (or min-ms 120)) (> d best-d))
          (setq best e best-d d))))
    (and best
         (append (list :time (max from (nth 0 best)) :duration best-d
                       :since (nth 0 best))
                 (nth 2 best)))))

(defmacro cmacs-deixis-tests--with-hand (rests &rest body)
  "Run BODY with the hand's pointing history answering from RESTS.
The compositor is \"running\", with two windows -- client 12, a browser,
and client 7, a terminal -- so a hand sample resolves the way a mouse
sample does.  `hand-enabled' records what the history was last told.
Only the `hand' pointer is registered; BODY may add others."
  (declare (indent 1))
  `(let* ((rests ,rests)
          (hand-enabled 'untouched)
          (cmacs-deixis--pointers nil)
          (cmacs-deixis-pointer-order '(hand gowl))
          (cmacs-deixis-fallback-to-point nil)
          (cmacs-deixis-latency-ms 0)
          (cmacs-deixis-parked-ms 2000)
          (cmacs-deixis-hand-confidence 0.9)
          (cmacs-deixis-last-bindings nil)
          (cmacs-handtrack-pointer-mode nil))
     (ignore hand-enabled)
     (cl-letf (((symbol-function 'cmacs-handtrack-point-history-dwell)
                (lambda (&rest args)
                  (cmacs-deixis-tests--hand-dwell rests (nth 0 args) (nth 1 args)
                                                  (nth 3 args))))
               ((symbol-function 'cmacs-handtrack-point-history-at)
                (lambda (&rest args)
                  (cmacs-deixis-tests--hand-dwell rests (car args) (car args) 0)))
               ((symbol-function 'cmacs-handtrack-point-history-enable)
                (lambda (&rest args) (setq hand-enabled (car args))))
               ((symbol-function 'cmacs-deixis--gowl-live-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-list-clients)
                (lambda (&rest _) '(browser term)))
               ((symbol-function 'gowl-client-pid) (lambda (&rest _) 1))
               ((symbol-function 'gowl-client-info)
                (lambda (&rest args)
                  (if (eq (car args) 'browser)
                      '((id . 12) (title . "wlroots docs") (app-id . "librewolf")
                        (geometry 0 0 1280 1440))
                    '((id . 7) (title . "~") (app-id . "gst")
                      (geometry 1280 0 1280 1440))))))
       (cmacs-deixis-register-pointer 'hand #'cmacs-deixis--hand-pointer
                                      :start #'cmacs-deixis--hand-start
                                      :stop #'cmacs-deixis--hand-stop)
       ,@body)))

(defconst cmacs-deixis-tests--hand-on-browser
  '(:x 400.0 :y 300.0 :client-id 12 :monitor 0 :hand right :confidence 1.0
    :u 0.16 :v 0.21 :layout t)
  "A hand sample over client 12, as the C ring reports it.")

(defconst cmacs-deixis-tests--hand-on-second-screen
  '(:x 2900.0 :y 400.0 :client-id 0 :monitor 1 :hand right :confidence 1.0
    :u 0.18 :v 0.37 :layout t)
  "A hand sample over bare desktop on the second output.")

(ert-deftest cmacs-deixis-test-choose-referent ()
  "A parked pointer gives way to one that has just come to rest."
  (let ((cmacs-deixis-parked-ms 2000)
        (parked '(:label "parked" :since 0))
        (fresh '(:label "fresh" :since 9500))
        (edge '(:label "edge" :since 8000))
        (silent '(:label "says nothing")))
    (cl-flet ((pick (candidates)
                (plist-get (cmacs-deixis-choose-referent candidates 10000)
                           :label)))
      (should-not (cmacs-deixis-choose-referent nil 10000))
      (should (equal (pick (list parked)) "parked"))
      ;; Order decides between two that are both being used...
      (should (equal (pick (list fresh edge)) "fresh"))
      (should (equal (pick (list edge fresh)) "edge"))
      ;; ... but not in favour of one that was left lying, whichever
      ;; way round they are listed.
      (should (equal (pick (list parked fresh)) "fresh"))
      (should (equal (pick (list fresh parked)) "fresh"))
      ;; Exactly the limit is still pointing; a millisecond more is not.
      (let ((cmacs-deixis-parked-ms 1999))
        (should (equal (pick (list edge fresh)) "fresh")))
      ;; Everything parked: the order again.
      (should (equal (pick (list parked '(:label "older" :since -5))) "parked"))
      ;; A pointer that gives no :since is taken at its word.
      (should (equal (pick (list parked silent)) "says nothing"))
      (should (equal (pick (list silent fresh)) "says nothing"))
      ;; A word with no time: nothing can be called parked.
      (should (equal (plist-get (cmacs-deixis-choose-referent
                                 (list parked fresh) nil)
                                :label)
                     "parked")))))

(ert-deftest cmacs-deixis-test-hand-referent ()
  "A bare hand's rest resolves like the mouse's, approximately."
  (cmacs-deixis-tests--with-hand
      `((200 700 ,cmacs-deixis-tests--hand-on-browser))
    (cl-letf (((symbol-function 'gowl-list-monitors) (lambda (&rest _) nil))
              ((symbol-function 'gowl-monitor-info) (lambda (&rest _) nil)))
      (let* ((b (car (cmacs-deixis-resolve "close that"
                                           '(("close" 0 200) ("that" 300 500))
                                           0)))
             (r (plist-get b :referent)))
        (should (eq (plist-get r :device) 'hand))
        (should (eq (plist-get r :hand) 'right))
        (should (eq (plist-get r :kind) 'window))
        (should (eq (plist-get r :client) 'browser))
        (should (eql (plist-get r :client-id) 12))
        (should (plist-get r :approximate))
        (should (= (plist-get r :since) 200))
        (should (string-match-p "librewolf.*client 12" (plist-get r :label)))
        ;; The window is 150..800 and the hand was there for 500 of
        ;; those 650 ms: 0.9 * 1.0 * (0.5 + 0.5 * 500/650).
        (should (< (abs (- (plist-get r :confidence)
                           (* 0.9 (+ 0.5 (* 0.5 (/ 500.0 650))))))
                   1e-6))
        (should (<= (plist-get r :confidence) cmacs-deixis-hand-confidence))
        ;; The model is told it is approximate.
        (should (string-match-p
                 "client 12) \\[approximate\\]"
                 (cmacs-deixis-annotate "close that" (list b)))))
      ;; A weaker pose is a weaker referent.
      (setq rests `((200 700 (:confidence 0.6
                              ,@cmacs-deixis-tests--hand-on-browser))))
      (let ((r (plist-get (car (cmacs-deixis-resolve
                                "close that" '(("close" 0 200) ("that" 300 500))
                                0))
                          :referent)))
        (should (< (plist-get r :confidence) 0.5)))
      ;; A window that closed since: named, stale, and worth nothing.
      (setq rests `((200 700 (:client-id 99
                              ,@cmacs-deixis-tests--hand-on-browser))))
      (let ((r (plist-get (car (cmacs-deixis-resolve
                                "close that" '(("close" 0 200) ("that" 300 500))
                                0))
                          :referent)))
        (should (plist-get r :stale))
        (should (= (plist-get r :confidence) 0.0))
        (should-not (cmacs-deixis--desktop-window-p r)))
      ;; Bare desktop: the output.
      (setq rests `((200 700 ,cmacs-deixis-tests--hand-on-second-screen)))
      (let ((r (plist-get (car (cmacs-deixis-resolve
                                "focus there" '(("focus" 0 200) ("there" 300 500))
                                0))
                          :referent)))
        (should (eq (plist-get r :kind) 'monitor))
        (should (eql (plist-get r :monitor) 1))
        (should (eq (plist-get r :device) 'hand))))))

(ert-deftest cmacs-deixis-test-hand-needs-a-rest ()
  "A hand passing through the word's window refers to nothing."
  (cmacs-deixis-tests--with-hand
      ;; 60 ms of the pose inside the window.
      `((400 460 ,cmacs-deixis-tests--hand-on-browser))
    (let ((b (cmacs-deixis-resolve "close that"
                                   '(("close" 0 200) ("that" 300 500)) 0)))
      (should-not (plist-get (car b) :referent))
      (should-not (cmacs-deixis-run-command "close that" b))))
  ;; No history in this build at all: the provider answers nil.
  (let ((cmacs-handtrack-pointer-mode nil))
    (cl-letf (((symbol-function 'cmacs-deixis--hand-live-p) (lambda (&rest _) nil)))
      (should-not (cmacs-deixis--hand-pointer 1000)))))

(ert-deftest cmacs-deixis-test-hand-without-compositor ()
  "With no compositor the fractions across the output go to Emacs's frames."
  (cmacs-deixis-tests--with-hand
      `((200 700 (:layout nil ,@cmacs-deixis-tests--hand-on-browser)))
    (let ((seen nil))
      (cl-letf (((symbol-function 'cmacs-deixis--hand-frame-referent)
                 (lambda (&rest args)
                   (setq seen args)
                   (list :kind 'buffer-position :window 'win :buffer 'buf
                         :position 42 :approximate t :confidence (nth 1 args)
                         :label "buffer: notes.org, line 3 (position 42)"))))
        (let ((r (plist-get (car (cmacs-deixis-resolve
                                  "focus there"
                                  '(("focus" 0 200) ("there" 300 500)) 0))
                            :referent)))
          (should (eq (plist-get r :kind) 'buffer-position))
          (should (eq (plist-get r :device) 'hand))
          (should (= (plist-get (car seen) :u) 0.16))
          (should (< (abs (- (plist-get r :confidence) 0.9)) 1e-6))))))
  ;; The real resolver never signals, whatever the display is.
  (should-not (condition-case nil
                  (progn (cmacs-deixis--hand-frame-referent '(:u 0.5 :v 0.5) 1.0)
                         nil)
                (error t))))

(ert-deftest cmacs-deixis-test-hand-with-pointer-mode ()
  "In pointer mode the hand is the gowl pointer, as before."
  (cmacs-deixis-tests--with-hand nil
    (cl-letf (((symbol-function 'cmacs-deixis--gowl-pointer)
               (lambda (&rest _) cmacs-deixis-tests--browser)))
      (should-not (cmacs-deixis--hand-pointer 1000))
      (let ((cmacs-handtrack-pointer-mode t))
        (let ((r (cmacs-deixis--hand-pointer 1000)))
          (should (eq (plist-get r :device) 'hand))
          (should (eq (plist-get r :client) 'browser))
          ;; It is the real pointer: not a camera's guess.
          (should-not (plist-get r :approximate)))
        ;; The other hand, bare and pointing, comes first.
        (setq rests `((0 5000 (:client-id 7
                               ,@cmacs-deixis-tests--hand-on-browser))))
        (let* ((cmacs-deixis-lookup-window '(800 . 1400))
               (r (cmacs-deixis--hand-pointer 1000)))
          (should (eq (plist-get r :client) 'term))
          (should (plist-get r :approximate)))))))

(ert-deftest cmacs-deixis-test-hand-and-mouse-arbitration ()
  "A still mouse does not outvote a pointing hand, nor a lying hand a mouse."
  (let ((mouse-since 0))
    (cl-flet ((that ()
                (plist-get
                 (car (cmacs-deixis-resolve "close that"
                                            '(("close" 9000 9200)
                                              ("that" 9300 9500))
                                            0))
                 :referent)))
      (cmacs-deixis-tests--with-hand
          `((9200 9700 ,cmacs-deixis-tests--hand-on-browser))
        (cmacs-deixis-register-pointer
         'gowl (lambda (_ms)
                 (list :kind 'window :client 'term :client-id 7 :monitor 0
                       :confidence 1.0 :since mouse-since :label "window: gst")))
        ;; The mouse has not moved for nine seconds; the hand has just
        ;; been raised.  The hand, in either order.
        (dolist (order '((hand gowl) (gowl hand)))
          (let ((cmacs-deixis-pointer-order order))
            (should (eq (plist-get (that) :device) 'hand))
            (should (eq (plist-get (that) :client) 'browser))))
        ;; Both in use: the order decides.
        (setq mouse-since 9100)
        (let ((cmacs-deixis-pointer-order '(gowl hand)))
          (should (eq (plist-get (that) :device) 'gowl)))
        (let ((cmacs-deixis-pointer-order '(hand gowl)))
          (should (eq (plist-get (that) :device) 'hand)))
        ;; The hand has been lying in the pose since long before, and
        ;; the mouse was just moved: the mouse, though the hand is
        ;; listed first.
        (setq rests `((1000 9700 ,cmacs-deixis-tests--hand-on-browser)))
        (let ((cmacs-deixis-pointer-order '(hand gowl)))
          (should (eq (plist-get (that) :device) 'gowl))
          (should (eq (plist-get (that) :client) 'term)))
        ;; Both left lying: the order again.
        (setq mouse-since 0)
        (let ((cmacs-deixis-pointer-order '(hand gowl)))
          (should (eq (plist-get (that) :device) 'hand)))
        ;; No hand in the pose: the mouse answers, parked or not.
        (setq rests nil)
        (should (eq (plist-get (that) :device) 'gowl))))))

(ert-deftest cmacs-deixis-test-hand-move-that-there ()
  "\"Move that there\" with two rests of a bare hand, bound by word time."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-hand
        `((200 700 ,cmacs-deixis-tests--hand-on-browser)
          ;; On the way across the hand is out of the pose.
          (1300 2000 ,cmacs-deixis-tests--hand-on-second-screen))
      (let* ((text "move that over there")
             (words '(("move" 0 200) ("that" 300 500) ("over" 1200 1300)
                      ("there" 1500 1800)))
             (said nil)
             (bindings (cmacs-deixis-resolve text words 0)))
        (should (equal (mapcar (lambda (b)
                                 (plist-get (plist-get b :referent) :kind))
                               bindings)
                       '(window monitor)))
        (should (equal (mapcar (lambda (b) (plist-get b :marker)) bindings)
                       '(1 2)))
        (cl-letf (((symbol-function 'message)
                   (lambda (&rest args) (push (apply #'format args) said))))
          (should (eq (cmacs-deixis-run-command text bindings) 'move)))
        (should (equal calls '((to-monitor browser mon-1))))
        ;; What the hand was taken to mean is said before it is acted on.
        (should (cl-some (lambda (m)
                           (string-match-p
                            "by hand.*that = window: librewolf.*there = monitor 1"
                            m))
                         said))
        ;; Said in the other order, the times bind the other way round.
        (setq calls nil)
        (should-not
         (cmacs-deixis-run-command
          "move that over there"
          (cmacs-deixis-resolve
           "move that over there"
           '(("move" 1000 1200) ("that" 1500 1800) ("over" 2600 2700)
             ("there" 2800 3000))
           0)))
        ;; "that" was the bare desktop, "there" nothing: no command.
        (should-not calls)))))

(ert-deftest cmacs-deixis-test-hand-destructive-is-confirmed ()
  "\"Close that\" by hand asks first, and says a hand pointed."
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-hand
        `((200 700 ,cmacs-deixis-tests--hand-on-browser))
      (let ((asked nil) (said nil)
            (cmacs-deixis-confirm-destructive t))
        (cl-letf (((symbol-function 'cmacs-deixis--confirm)
                   (lambda (prompt action) (setq asked (cons prompt action))))
                  ((symbol-function 'message)
                   (lambda (&rest args) (push (apply #'format args) said))))
          (should (eq (cmacs-deixis-tests--say
                       "close that" '(("close" 0 200) ("that" 300 500)))
                      'close))
          (should-not calls)
          (should (string-match-p "client 12" (car asked)))
          (should (string-match-p "pointed at by hand" (car asked)))
          (should (cl-some (lambda (m) (string-match-p "that = window" m)) said))
          (funcall (cdr asked))
          (should (equal calls '((close browser))))
          ;; The announcement is an option; the confirmation is not its.
          (setq said nil asked nil)
          (let ((cmacs-deixis-announce-hand nil))
            (cmacs-deixis-tests--say
             "close that" '(("close" 0 200) ("that" 300 500))))
          (should-not said)
          (should (string-match-p "pointed at by hand" (car asked)))))))
  ;; The mouse's question is as it was.
  (cmacs-deixis-tests--with-gowl
    (cmacs-deixis-tests--with-pointer `((0 9000 ,cmacs-deixis-tests--browser))
      (let ((asked nil))
        (cl-letf (((symbol-function 'cmacs-deixis--confirm)
                   (lambda (prompt action) (setq asked (cons prompt action)))))
          (cmacs-deixis-tests--say
           "close that" '(("close" 0 200) ("that" 300 500)))
          (should (string-match-p "client 12" (car asked)))
          (should-not (string-match-p "by hand" (car asked))))))))

(ert-deftest cmacs-deixis-test-hand-history-follows-sampling ()
  "The hand's ring is on exactly while deixis samples, and emptied after."
  (should (plist-get (alist-get 'hand cmacs-deixis--pointers) :start))
  (should (plist-get (alist-get 'hand cmacs-deixis--pointers) :stop))
  (cmacs-deixis-tests--with-hand nil
    (let ((cmacs-deixis--sampling nil))
      (cmacs-deixis--set-sampling t)
      (should (eq hand-enabled t))
      (cmacs-deixis--set-sampling nil)
      ;; Turning the history off is what empties it.
      (should (eq hand-enabled nil)))))

(ert-deftest cmacs-deixis-test-hand-clock ()
  "Hand samples are read on the clock they were written with."
  ;; The compositor's clock, or a test's: the same clock, no offset.
  (let ((cmacs-deixis-clock-function (lambda () 5)))
    (should (= (cmacs-deixis--hand-clock-offset) 0)))
  ;; Hand tracking without a compositor: `cmacs-deixis-now-ms' is wall
  ;; time and the ring is monotonic, a constant apart.
  (let ((asked nil))
    (cl-letf (((symbol-function 'gowl-pointer-history-now) nil)
              ((symbol-function 'cmacs-handtrack-point-history-now)
               (lambda (&rest _) 700))
              ((symbol-function 'cmacs-deixis-now-ms) (lambda (&rest _) 1000700))
              ((symbol-function 'cmacs-handtrack-point-history-dwell)
               (lambda (&rest args)
                 (setq asked (list (nth 0 args) (nth 1 args)))
                 nil)))
      (fmakunbound 'gowl-pointer-history-now)
      (should (= (cmacs-deixis--hand-clock-offset) -1000000))
      (let ((cmacs-deixis-lookup-window '(1000500 . 1000900))
            (cmacs-handtrack-pointer-mode nil))
        (cmacs-deixis--hand-pointer 1000700)
        (should (equal asked '(500 900)))))))


;;;; The compositor's ring (needs a live compositor)

(ert-deftest cmacs-deixis-test-gowl-history-without-compositor ()
  "With no compositor the history DEFUNs answer nil and never signal."
  (skip-unless (fboundp 'gowl-pointer-history-at))
  (skip-unless (and (fboundp 'gowl-running-p) (not (gowl-running-p))))
  (should-not (gowl-pointer-history-enable t))
  (should-not (gowl-pointer-history-at (gowl-pointer-history-now)))
  (should-not (gowl-pointer-history-dwell 0 (gowl-pointer-history-now)))
  (should (integerp (gowl-pointer-history-now))))

(provide 'cmacs-deixis-tests)

;;; cmacs-deixis-tests.el ends here
