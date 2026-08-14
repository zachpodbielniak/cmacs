;;; cmacs-ai-menu-tests.el --- Tests for the AI context menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers the four layers of the universal AI menu:
;;
;;   cmacs-menu.el        backend routing (GTK / --lrg / tty) + flattening
;;   cmacs-ai-target.el   resolving what is under the click
;;   cmacs-ai-actions.el  which actions apply, in which group, in order
;;   cmacs-ai-menu.el     the rendered context-menu keymap
;;
;; Everything here is pure Elisp: no display, no model call, no build
;; flags.  The two backends are exercised by mocking `x-popup-menu' and
;; `lrg-popup-menu' -- which is the point, since the whole reason the
;; routing layer exists is that only one of them is ever present.
;;
;; Note the deliberate absence of `cmacs-feature-p' guards: these tests
;; must run in a per-file batch run where that function is not defined
;; (see the ERT skip trap in the cmacs notes).  Tests that genuinely need
;; the AI C subsystem check `cmacs-ai-supported-p' with `fboundp' first.

;;; Code:

(require 'ert)
(require 'dired)                        ; the dired-marks test drives it
(require 'cmacs-menu)
(require 'cmacs-ai-target)
(require 'cmacs-ai-targets)
(require 'cmacs-ai-actions)
(require 'cmacs-ai-menu)
(require 'cmacs-ai-output)

;;;; Helpers -----------------------------------------------------------

(defmacro cmacs-ai-menu-tests--with-actions (actions &rest body)
  "Run BODY with exactly ACTIONS registered, restoring the registry after.
ACTIONS is a list of `cmacs-ai-register-action' argument lists."
  (declare (indent 1))
  `(let ((saved cmacs-ai--actions))
     (unwind-protect
         (progn
           (setq cmacs-ai--actions (make-hash-table :test 'eq))
           (dolist (a ,actions) (apply #'cmacs-ai-register-action a))
           ,@body)
       (setq cmacs-ai--actions saved))))

(defmacro cmacs-ai-menu-tests--with-resolvers (resolvers &rest body)
  "Run BODY with exactly RESOLVERS registered, restoring after."
  (declare (indent 1))
  `(let ((saved cmacs-ai-target--resolvers))
     (unwind-protect
         (progn
           (setq cmacs-ai-target--resolvers (make-hash-table :test 'eq))
           (dolist (r ,resolvers) (apply #'cmacs-ai-register-target-resolver r))
           ,@body)
       (setq cmacs-ai-target--resolvers saved))))

(defun cmacs-ai-menu-tests--always (label)
  "An action list that always applies, labelled LABEL."
  (list :name (intern (format "test-%s" label))
        :label label
        :run #'ignore))

;;;; cmacs-menu: flattening --------------------------------------------

(ert-deftest cmacs-ai-menu-tests-alist-to-tree ()
  "An alist menu flattens to an lrg item tree plus a value vector."
  (let* ((menu '("Title" ("Pane" ("A" . a) ("B" . b))))
         (flat (cmacs-menu-alist-to-tree menu)))
    (should (equal (car flat) '(("A" . 0) ("B" . 1))))
    (should (equal (cdr flat) [a b]))))

(ert-deftest cmacs-ai-menu-tests-alist-panes-separated ()
  "Successive panes are joined by exactly one separator row."
  (let* ((menu '("T" ("P1" ("A" . a)) ("P2" ("B" . b))))
         (tree (car (cmacs-menu-alist-to-tree menu))))
    (should (equal tree '(("A" . 0) nil ("B" . 1))))))

(ert-deftest cmacs-ai-menu-tests-collapse-separators ()
  "Runs of separators collapse, and leading/trailing ones are dropped."
  (should (equal (cmacs-menu-collapse-separators
                  '(nil nil ("A" . 0) nil nil ("B" . 1) nil))
                 '(("A" . 0) nil ("B" . 1))))
  ;; Recurses into submenus rather than only cleaning the top level.
  (should (equal (cmacs-menu-collapse-separators
                  '(("Sub" nil ("A" . 0) nil nil ("B" . 1) nil)))
                 '(("Sub" ("A" . 0) nil ("B" . 1))))))

(ert-deftest cmacs-ai-menu-tests-keymap-to-tree-nests ()
  "Nested keymaps become real submenu nodes with a flat value vector."
  (let ((map (make-sparse-keymap "Root"))
        (sub (make-sparse-keymap "Sub")))
    (define-key-after sub [one] '(menu-item "One" ignore))
    (define-key-after map [top] '(menu-item "Top" ignore))
    (define-key-after map [subm] (list 'menu-item "Sub" sub))
    (let* ((flat (cmacs-menu-keymap-to-tree map))
           (tree (car flat)))
      (should (equal tree '(("Top" . 0) ("Sub" ("One" . 1)))))
      (should (= (length (cdr flat)) 2)))))

(ert-deftest cmacs-ai-menu-tests-keymap-honours-enable-and-visible ()
  "An :enable nil item is disabled; a :visible nil item is dropped."
  (let ((map (make-sparse-keymap "Root")))
    (define-key-after map [on] '(menu-item "On" ignore :enable t))
    (define-key-after map [off] '(menu-item "Off" ignore :enable nil))
    (define-key-after map [gone] '(menu-item "Gone" ignore :visible nil))
    (let ((tree (car (cmacs-menu-keymap-to-tree map))))
      ;; A disabled leaf is (LABEL) -- a cons whose cdr is nil.
      (should (equal tree '(("On" . 0) ("Off"))))
      (should-not (assoc "Gone" tree)))))

(ert-deftest cmacs-ai-menu-tests-empty-submenu-dropped ()
  "A submenu whose items all filtered away does not appear at all."
  (let ((map (make-sparse-keymap "Root"))
        (sub (make-sparse-keymap "Sub")))
    (define-key-after sub [x] '(menu-item "X" ignore :visible nil))
    (define-key-after map [subm] (list 'menu-item "Sub" sub))
    (should (null (car (cmacs-menu-keymap-to-tree map))))))

;;;; cmacs-menu: backend routing ---------------------------------------

(ert-deftest cmacs-ai-menu-tests-popup-routes-to-lrg ()
  "On an --lrg frame the alist popup goes through `lrg-popup-menu'."
  (let ((menu '("T" ("P" ("A" . a) ("B" . b)))))
    (cl-letf (((symbol-function 'cmacs-menu-lrg-frame-p) (lambda (&rest _) t))
              ((symbol-function 'lrg-popup-menu) (lambda (&rest _) 1)))
      (should (eq (cmacs-menu-popup t menu) 'b)))
    ;; A dismissed menu is nil, not an error.
    (cl-letf (((symbol-function 'cmacs-menu-lrg-frame-p) (lambda (&rest _) t))
              ((symbol-function 'lrg-popup-menu) (lambda (&rest _) nil)))
      (should (null (cmacs-menu-popup t menu))))))

(ert-deftest cmacs-ai-menu-tests-popup-routes-to-native ()
  "Off an --lrg frame the alist popup goes through `x-popup-menu'."
  (cl-letf (((symbol-function 'cmacs-menu-lrg-frame-p) (lambda (&rest _) nil))
            ((symbol-function 'cmacs-menu-native-p) (lambda (&rest _) t))
            ((symbol-function 'x-popup-menu) (lambda (&rest _) 'native)))
    (should (eq (cmacs-menu-popup t '("T" ("P" ("A" . a)))) 'native))))

(ert-deftest cmacs-ai-menu-tests-popup-keymap-routes ()
  "The keymap popup returns a BINDING on both backends, not an event path."
  (let ((map (make-sparse-keymap "Root")))
    (define-key-after map [a] '(menu-item "A" ignore))
    ;; --lrg: index -> binding, straight out of the value vector.
    (cl-letf (((symbol-function 'cmacs-menu-lrg-frame-p) (lambda (&rest _) t))
              ((symbol-function 'lrg-popup-menu) (lambda (&rest _) 0)))
      (should (eq (cmacs-menu-popup-keymap map t) #'ignore)))
    ;; Native: event path -> `lookup-key' -> binding.
    (cl-letf (((symbol-function 'cmacs-menu-lrg-frame-p) (lambda (&rest _) nil))
              ((symbol-function 'cmacs-menu-native-p) (lambda (&rest _) t))
              ((symbol-function 'x-popup-menu) (lambda (&rest _) '(a))))
      (should (eq (cmacs-menu-popup-keymap map t) #'ignore)))))

(ert-deftest cmacs-ai-menu-tests-lrg-frame-detection ()
  "`cmacs-menu-lrg-frame-p' keys off the frame type, nothing else."
  (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg)))
    (should (cmacs-menu-lrg-frame-p)))
  (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'pgtk)))
    (should-not (cmacs-menu-lrg-frame-p))
    ;; And an lrg frame is never treated as able to draw a native menu.
    (should-not (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg)))
                  (cmacs-menu-native-p)))))

;;;; Targets -----------------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-region-wins ()
  "An active region beats every other resolver."
  (with-temp-buffer
    (insert "hello world")
    (set-mark (point-min))
    (goto-char 6)
    (activate-mark)
    (let ((tg (cmacs-ai-target-at)))
      (should (eq (cmacs-ai-target-kind tg) 'region))
      (should (equal (cmacs-ai-target-text tg) "hello"))
      (should (equal (cmacs-ai-target-bounds tg) (cons 1 6))))))

(ert-deftest cmacs-ai-menu-tests-region-only-when-click-inside ()
  "A click outside the region means the user is pointing at something else."
  (with-temp-buffer
    (insert "aaaa bbbb")
    (set-mark (point-min))
    (goto-char 5)
    (activate-mark)
    ;; No click at all: the region is what was meant.
    (should (cmacs-ai-target--region-covers-click-p nil))
    ;; A click inside it: still the region.
    (cl-letf (((symbol-function 'event-start) (lambda (_) 'posn))
              ((symbol-function 'posn-point) (lambda (_) 3)))
      (should (cmacs-ai-target--region-covers-click-p '(mouse-3 posn))))
    ;; A click past its end: not the region.
    (cl-letf (((symbol-function 'event-start) (lambda (_) 'posn))
              ((symbol-function 'posn-point) (lambda (_) 8)))
      (should-not (cmacs-ai-target--region-covers-click-p '(mouse-3 posn))))))

(ert-deftest cmacs-ai-menu-tests-buffer-fallback ()
  "Somewhere with no symbol and no region still yields a target."
  (with-temp-buffer
    (insert "   ")
    (goto-char (point-max))
    (let ((tg (cmacs-ai-target-at)))
      (should tg)
      (should (memq (cmacs-ai-target-kind tg) '(buffer file))))))

(ert-deftest cmacs-ai-menu-tests-hunk-target ()
  "A diff hunk is bounded by its own @@ header and the next one."
  (with-temp-buffer
    (insert "diff --git a/x b/x\n"
            "@@ -1,2 +1,2 @@\n context\n-old\n+new\n"
            "@@ -9,1 +9,1 @@\n other\n")
    (diff-mode)
    (goto-char (point-min))
    (search-forward "-old")
    (let ((tg (cmacs-ai-target-at)))
      (should (eq (cmacs-ai-target-kind tg) 'hunk))
      (should (string-match-p "-old" (cmacs-ai-target-text tg)))
      ;; Crucially, it stops before the SECOND hunk.
      (should-not (string-match-p "other" (cmacs-ai-target-text tg))))))

(ert-deftest cmacs-ai-menu-tests-dired-marked-files ()
  "Dired reports marked files as one `files' target, else the file at point."
  (let ((dir (make-temp-file "cmacs-ai-menu-test" t)))
    (unwind-protect
        (progn
          (dolist (n '("a.txt" "b.txt" "c.txt"))
            (with-temp-file (expand-file-name n dir) (insert n)))
          (let ((buf (dired dir)))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  (dired-goto-file (expand-file-name "a.txt" dir))
                  ;; One file at point, nothing marked.
                  (let ((tg (cmacs-ai-target-at)))
                    (should (eq (cmacs-ai-target-kind tg) 'file))
                    (should (equal (file-name-nondirectory
                                    (cmacs-ai-target-file tg))
                                   "a.txt")))
                  ;; Two marked: one target covering both.
                  (dired-mark 1)
                  (dired-goto-file (expand-file-name "b.txt" dir))
                  (dired-mark 1)
                  (let ((tg (cmacs-ai-target-at)))
                    (should (eq (cmacs-ai-target-kind tg) 'files))
                    (should (= (length (cmacs-ai-target-files tg)) 2))))
              (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest cmacs-ai-menu-tests-dirvish-is-dired ()
  "The dired resolver claims dirvish too -- it is a dired derivative."
  (let ((r (gethash 'dired cmacs-ai-target--resolvers)))
    (should (memq 'dirvish-mode (plist-get r :modes)))
    (should (memq 'dired-mode (plist-get r :modes)))))

(ert-deftest cmacs-ai-menu-tests-terminal-modes-cover-vterm ()
  "vterm is a first-class terminal for the resolver, alongside the built-ins."
  (let ((r (gethash 'terminal cmacs-ai-target--resolvers)))
    (dolist (m '(vterm-mode eshell-mode term-mode comint-mode))
      (should (memq m (plist-get r :modes))))))

(ert-deftest cmacs-ai-menu-tests-terminal-line-fallback ()
  "Without prompt navigation the terminal target is the last N lines."
  (with-temp-buffer
    (dotimes (i 300) (insert (format "line %d\n" i)))
    (goto-char (point-max))
    (let* ((cmacs-ai-target-terminal-lines 5)
           (beg (cmacs-ai-targets--terminal-start))
           (text (buffer-substring-no-properties beg (point))))
      (should (string-match-p "line 299" text))
      (should-not (string-match-p "line 200" text)))))

(ert-deftest cmacs-ai-menu-tests-resolver-order-respected ()
  "Resolvers run in :order and the first non-nil answer wins."
  (cmacs-ai-menu-tests--with-resolvers
      (list (list :name 'late :order 90
                  :resolve (lambda (_c) (cmacs-ai-target-create :kind 'late)))
            (list :name 'early :order 10
                  :resolve (lambda (_c) (cmacs-ai-target-create :kind 'early))))
    (with-temp-buffer
      (should (eq (cmacs-ai-target-kind (cmacs-ai-target-at)) 'early)))))

(ert-deftest cmacs-ai-menu-tests-broken-resolver-is-survivable ()
  "A resolver that signals is skipped, not fatal to the menu."
  (cmacs-ai-menu-tests--with-resolvers
      (list (list :name 'broken :order 10
                  :resolve (lambda (_c) (error "boom")))
            (list :name 'good :order 20
                  :resolve (lambda (_c) (cmacs-ai-target-create :kind 'good))))
    (with-temp-buffer
      (should (eq (cmacs-ai-target-kind (cmacs-ai-target-at)) 'good)))))

(ert-deftest cmacs-ai-menu-tests-truncation-is-middle-out ()
  "Oversized payloads keep the head and tail and elide the middle."
  (let* ((cmacs-ai-target-max-chars 200)
         (text (concat "HEAD" (make-string 4000 ?x) "TAIL"))
         (out (cmacs-ai-target-truncate text)))
    (should (< (length out) (length text)))
    (should (string-prefix-p "HEAD" out))
    (should (string-suffix-p "TAIL" out))
    (should (string-match-p "characters elided" out))))

(ert-deftest cmacs-ai-menu-tests-content-reads-file-lazily ()
  "A file target with no text reads its file only when content is asked for."
  (let ((f (make-temp-file "cmacs-ai-menu-test")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "on disk"))
          (let ((tg (cmacs-ai-target-create :kind 'file :file f :text nil)))
            (should (null (cmacs-ai-target-text tg)))
            (should (equal (cmacs-ai-target-content tg) "on disk"))))
      (delete-file f))))

;;;; Actions -----------------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-actions-filtered-and-grouped ()
  "Only applicable actions appear, grouped, with empty groups omitted."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'yes :label "Yes" :group 'ask :run #'ignore)
            (list :name 'no :label "No" :group 'ask :run #'ignore
                  :applies (lambda (_t) nil))
            (list :name 'chat :label "Chat" :group 'chat :run #'ignore))
    (let* ((tg (cmacs-ai-target-create :kind 'region :text "x"))
           (groups (cmacs-ai-actions-for tg)))
      (should (equal (mapcar #'car groups) '(ask chat)))
      (should (= (length (alist-get 'ask groups)) 1))
      (should (equal (cmacs-ai-action-label (car (alist-get 'ask groups)) tg)
                     "Yes")))))

(ert-deftest cmacs-ai-menu-tests-actions-ordered ()
  "Within a group, :order decides, ascending."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'b :label "B" :order 20 :run #'ignore)
            (list :name 'a :label "A" :order 10 :run #'ignore)
            (list :name 'c :label "C" :order 30 :run #'ignore))
    (let* ((tg (cmacs-ai-target-create :kind 'region :text "x"))
           (ask (alist-get 'ask (cmacs-ai-actions-for tg))))
      (should (equal (mapcar (lambda (a) (cmacs-ai-action-label a tg)) ask)
                     '("A" "B" "C"))))))

(ert-deftest cmacs-ai-menu-tests-broken-applies-is-survivable ()
  "An :applies that signals hides its own action and nothing else."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'broken :label "Broken" :run #'ignore
                  :applies (lambda (_t) (error "boom")))
            (list :name 'fine :label "Fine" :run #'ignore))
    (let* ((tg (cmacs-ai-target-create :kind 'region :text "x"))
           (ask (alist-get 'ask (cmacs-ai-actions-for tg))))
      (should (equal (mapcar (lambda (a) (cmacs-ai-action-label a tg)) ask)
                     '("Fine"))))))

(ert-deftest cmacs-ai-menu-tests-action-requires-name-label-run ()
  "Registration rejects an incomplete action rather than failing later."
  (should-error (cmacs-ai-register-action :label "x" :run #'ignore))
  (should-error (cmacs-ai-register-action :name 'x :run #'ignore))
  (should-error (cmacs-ai-register-action :name 'x :label "x")))

(ert-deftest cmacs-ai-menu-tests-textops-actions-registered ()
  "Summarize, rephrase and reply are all on the Ask menu."
  (let ((names nil))
    (maphash (lambda (k _v) (push k names)) cmacs-ai--actions)
    (dolist (op '(cmacs-ai-summarize cmacs-ai-rephrase cmacs-ai-reply))
      (should (memq op names)))))

;;;; Brigade tools on the menu ------------------------------------------

(ert-deftest cmacs-ai-menu-tests-deftool-menu-opt-in ()
  "A tool registered with :menu shows up in the Tools group, kind-filtered."
  (skip-unless (fboundp 'cmacs-brigade-register-tool))
  (let ((name 'cmacs-ai-menu-test-tool))
    (unwind-protect
        (progn
          (cmacs-brigade-register-tool
           :name name
           :description "A test tool."
           :params '((text string "The thing"))
           :handler (lambda (text) (format "got %d chars" (length text)))
           :menu '(region) :menu-label "Test tool")
          ;; Applies to a region target...
          (let ((acts (cmacs-ai-actions--tool-actions
                       (cmacs-ai-target-create :kind 'region :text "x"))))
            (should (= (length acts) 1))
            (should (equal (plist-get (car acts) :label) "Test tool"))
            (should (eq (plist-get (car acts) :group) 'tools)))
          ;; ...and not to a kind it did not ask for.
          (should (null (cmacs-ai-actions--tool-actions
                         (cmacs-ai-target-create :kind 'image)))))
      (when (fboundp 'cmacs-brigade-unregister-tool)
        (cmacs-brigade-unregister-tool name)))))

(ert-deftest cmacs-ai-menu-tests-tool-without-menu-stays-off ()
  "A tool that did not opt in is not on the menu."
  (skip-unless (fboundp 'cmacs-brigade-register-tool))
  (let ((name 'cmacs-ai-menu-test-quiet-tool))
    (unwind-protect
        (progn
          (cmacs-brigade-register-tool
           :name name :description "Quiet." :params nil
           :handler (lambda () "x"))
          (should (null (seq-find
                         (lambda (a) (string-match-p "quiet"
                                                     (plist-get a :label)))
                         (cmacs-ai-actions--tool-actions
                          (cmacs-ai-target-create :kind 'region :text "x"))))))
      (when (fboundp 'cmacs-brigade-unregister-tool)
        (cmacs-brigade-unregister-tool name)))))

;;;; The rendered menu --------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-populate-single-top-level-entry ()
  "Everything hangs off ONE top-level entry, however many actions there are.

The context menu is shared property; a feature taking several of its
top-level slots has overstayed."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'a1 :label "A1" :group 'ask :run #'ignore)
            (list :name 'a2 :label "A2" :group 'ask :run #'ignore)
            (list :name 'c1 :label "C1" :group 'chat :run #'ignore)
            (list :name 'b1 :label "B1" :group 'brigade :run #'ignore))
    (with-temp-buffer
      (insert "text")
      (let* ((cmacs-ai-menu-inline-limit 1)
             (menu (cmacs-ai-menu-populate
                    (make-sparse-keymap "Context Menu") nil))
             (tree (car (cmacs-menu-keymap-to-tree menu))))
        ;; Exactly one node, and it is the AI entry.
        (should (= (length tree) 1))
        (should (equal (car (car tree)) cmacs-ai-menu-label))
        ;; The groups live inside it, not beside it.
        (let ((inner (cdr (car tree))))
          (should (assoc "Ask AI" inner))
          (should (assoc "Chat" inner))
          (should (assoc "Brigade" inner))
          (should (equal (cdr (assoc "Ask AI" inner))
                         '(("A1" . 0) ("A2" . 1)))))))))

(ert-deftest cmacs-ai-menu-tests-populate-inlines-small-menus ()
  "At or below the inline limit the GROUP submenus are skipped.
The top-level AI entry stays either way."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'a1 :label "A1" :group 'ask :run #'ignore)
            (list :name 'c1 :label "C1" :group 'chat :run #'ignore))
    (with-temp-buffer
      (insert "text")
      (let* ((cmacs-ai-menu-inline-limit 5)
             (menu (cmacs-ai-menu-populate
                    (make-sparse-keymap "Context Menu") nil))
             (tree (car (cmacs-menu-keymap-to-tree menu))))
        (should (= (length tree) 1))
        (let ((inner (cdr (car tree))))
          (should-not (assoc "Ask AI" inner))
          (should (assoc "A1" inner))
          (should (assoc "C1" inner)))))))

(ert-deftest cmacs-ai-menu-tests-populate-items-are-distinct ()
  "Each menu item runs its OWN action.

The bug this guards: `dolist' keeps one binding for its loop variable, so
closures built inside the loop without re-binding all capture the last
action and every entry does the same thing."
  (let ((ran nil))
    (cmacs-ai-menu-tests--with-actions
        (list (list :name 'one :label "One" :group 'ask
                    :run (lambda (_t) (push 'one ran)))
              (list :name 'two :label "Two" :group 'ask
                    :run (lambda (_t) (push 'two ran))))
      (with-temp-buffer
        (insert "text")
        (let* ((cmacs-ai-menu-inline-limit 99)
               (menu (cmacs-ai-menu-populate
                      (make-sparse-keymap "Context Menu") nil)))
          ;; Nested under the top-level AI entry now.
          (funcall (lookup-key menu [cmacs-ai one]))
          (funcall (lookup-key menu [cmacs-ai two]))
          (should (equal (sort ran #'string<) '(one two))))))))

(ert-deftest cmacs-ai-menu-tests-populate-noop-without-actions ()
  "With nothing applicable the menu is returned untouched."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'never :label "Never" :run #'ignore
                  :applies (lambda (_t) nil)))
    (with-temp-buffer
      (insert "text")
      (let* ((menu (make-sparse-keymap "Context Menu"))
             (out (cmacs-ai-menu-populate menu nil)))
        (should (eq out menu))
        ;; The cdr of a titled sparse keymap is its title, not a binding,
        ;; so ask the flattener instead: no items means no entries added,
        ;; and in particular no orphan separator.
        (should (null (car (cmacs-menu-keymap-to-tree out))))))))

(ert-deftest cmacs-ai-menu-tests-mode-installs-and-removes-hook ()
  "Toggling the mode adds and removes exactly one hook entry."
  (let ((context-menu-functions nil)
        (was cmacs-ai-menu-mode))
    (unwind-protect
        (progn
          (cmacs-ai-menu-mode 1)
          (should (memq #'cmacs-ai-menu-populate context-menu-functions))
          (cmacs-ai-menu-mode -1)
          (should-not (memq #'cmacs-ai-menu-populate context-menu-functions)))
      (cmacs-ai-menu-mode (if was 1 -1)))))

(ert-deftest cmacs-ai-menu-tests-claim-mouse-3-respects-existing ()
  "mouse-3 is claimed only when nothing menu-shaped already owns it."
  (let ((map (make-sparse-keymap)))
    (cl-letf (((symbol-function 'current-global-map) (lambda () map))
              ((symbol-function 'global-set-key)
               (lambda (k d) (define-key map k d))))
      ;; Unbound: claim it.
      (should (cmacs-menu-claim-mouse-3 #'ignore))
      (should (eq (lookup-key map [mouse-3]) #'ignore))
      ;; Already ours: leave it.
      (should-not (cmacs-menu-claim-mouse-3 #'ignore))
      ;; A keymap already produces a context menu: leave that alone too.
      (define-key map [mouse-3] (make-sparse-keymap))
      (should-not (cmacs-menu-claim-mouse-3 #'ignore))
      ;; Something else entirely (Doom's mouse-save-then-kill): claim it.
      (define-key map [mouse-3] #'mouse-save-then-kill)
      (should (cmacs-menu-claim-mouse-3 #'ignore)))))

(ert-deftest cmacs-ai-menu-tests-claim-mouse-3-opt-out ()
  "`cmacs-menu-override-mouse-3' nil means never touch the binding."
  (let ((map (make-sparse-keymap))
        (cmacs-menu-override-mouse-3 nil))
    (cl-letf (((symbol-function 'current-global-map) (lambda () map))
              ((symbol-function 'global-set-key)
               (lambda (k d) (define-key map k d))))
      (should-not (cmacs-menu-claim-mouse-3 #'ignore))
      (should (null (lookup-key map [mouse-3]))))))

;;;; Result window ------------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-output-split-follows-frame-width ()
  "A wide frame gets a side window; a narrow one gets it underneath."
  (let ((cmacs-ai-output-split-threshold 100))
    (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 200)))
      (should (eq (alist-get 'side (cdr (cmacs-ai-output--display-action)))
                  'right)))
    (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 80)))
      (should (eq (alist-get 'side (cdr (cmacs-ai-output--display-action)))
                  'bottom)))))

(ert-deftest cmacs-ai-menu-tests-output-buffer-and-copy ()
  "The result buffer is Org, read-only, and copies without its header."
  (let ((buf (cmacs-ai-output-buffer "test" "subtitle")))
    (unwind-protect
        (with-current-buffer buf
          (should (derived-mode-p 'org-mode))
          (should buffer-read-only)
          (cmacs-ai-output-append buf "the answer")
          (should (string-match-p "the answer" (buffer-string)))
          (let ((kill-ring nil))
            (cmacs-ai-output-copy)
            (should (equal (string-trim (current-kill 0)) "the answer"))
            ;; The #+title header is not part of what you copy.
            (should-not (string-match-p "#\\+title" (current-kill 0)))))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-menu-tests-output-quit-cancels ()
  "Closing the window cancels an in-flight request rather than orphaning it."
  (let ((buf (cmacs-ai-output-buffer "test"))
        (cancelled nil)
        (freed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-ai-chat-cancel)
                   (lambda (_s) (setq cancelled t)))
                  ((symbol-function 'cmacs-ai-free-session)
                   (lambda (_p) (setq freed t)))
                  ((symbol-function 'quit-window) #'ignore))
          (cmacs-ai-output-attach-session buf (cons 'client 'session))
          (with-current-buffer buf (cmacs-ai-output-quit))
          (should cancelled)
          (should freed))
      (kill-buffer buf))))

(ert-deftest cmacs-ai-menu-tests-output-keys ()
  "Both `q' and `C-c C-k' close the result window."
  (should (eq (lookup-key cmacs-ai-output-mode-map (kbd "q"))
              #'cmacs-ai-output-quit))
  (should (eq (lookup-key cmacs-ai-output-mode-map (kbd "C-c C-k"))
              #'cmacs-ai-output-quit)))

;;;; Commands for actions ------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-run-action-runs-it ()
  "`cmacs-ai-run-action' resolves a name and runs it on the target at point."
  (let ((ran nil))
    (cmacs-ai-menu-tests--with-actions
        (list (list :name 'thing :label "Thing"
                    :run (lambda (target)
                           (setq ran (cmacs-ai-target-kind target)))))
      (with-temp-buffer
        (insert "hello")
        (set-mark (point-min))
        (goto-char (point-max))
        (activate-mark)
        (cmacs-ai-run-action 'thing)
        (should (eq ran 'region))))))

(ert-deftest cmacs-ai-menu-tests-run-action-honours-applies ()
  "Running an action that does not apply fails loudly, not obscurely."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'nope :label "Nope" :run #'ignore
                  :applies (lambda (_t) nil)))
    (with-temp-buffer
      (insert "x")
      (should-error (cmacs-ai-run-action 'nope) :type 'user-error))))

(ert-deftest cmacs-ai-menu-tests-run-action-unknown-name ()
  "An unregistered name is a user-error, not a wrong-type crash."
  (with-temp-buffer
    (insert "x")
    (should-error (cmacs-ai-run-action 'no-such-action-here)
                  :type 'user-error)))

(ert-deftest cmacs-ai-menu-tests-generated-commands-exist ()
  "Every menu-only action also has a real bindable command.

These are generated by `cmacs-ai-define-action-command', whose call sites
carry explicit autoload cookies -- a `;;;###autoload' inside the macro
body would never be seen, because the scraper reads source text and does
not expand macros."
  (dolist (c '(cmacs-ai-chat-with-this
               cmacs-ai-send-to-open-chat
               cmacs-ai-send-to-libreclaw
               cmacs-ai-spawn-agent
               cmacs-ai-send-to-task
               cmacs-ai-pin-context
               cmacs-ai-make-brigade-task))
    (should (commandp c))))

(ert-deftest cmacs-ai-menu-tests-group-pickers-exist ()
  "Each group has its own picker command, for a key per group."
  (dolist (c '(cmacs-ai-menu-pick-ask
               cmacs-ai-menu-pick-chat
               cmacs-ai-menu-pick-brigade
               cmacs-ai-menu-pick-tools))
    (should (commandp c))))

(ert-deftest cmacs-ai-menu-tests-action-names-filter-by-group ()
  "`cmacs-ai-action-names' scopes to a group when asked."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'a1 :label "A1" :group 'ask :run #'ignore)
            (list :name 'c1 :label "C1" :group 'chat :run #'ignore))
    (should (equal (cmacs-ai-action-names) '(a1 c1)))
    (should (equal (cmacs-ai-action-names 'ask) '(a1)))
    (should (equal (cmacs-ai-action-names 'chat) '(c1)))))

(ert-deftest cmacs-ai-menu-tests-group-picker-scopes-choices ()
  "A group picker offers only that group, and says so when it is empty."
  (cmacs-ai-menu-tests--with-actions
      (list (list :name 'a1 :label "A1" :group 'ask :run #'ignore)
            (list :name 'c1 :label "C1" :group 'chat :run #'ignore))
    (with-temp-buffer
      (insert "text")
      (let ((offered nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _) (setq offered coll) (car coll))))
          (cmacs-ai-menu-pick 'ask)
          (should (equal offered '("A1")))
          (cmacs-ai-menu-pick 'chat)
          (should (equal offered '("C1")))))
      ;; A group with nothing in it refuses rather than showing a blank prompt.
      (should-error (cmacs-ai-menu-pick 'brigade) :type 'user-error))))

;;;; Text operations ----------------------------------------------------

(ert-deftest cmacs-ai-menu-tests-refinement-defaults-on-empty ()
  "RET on an empty refinement means the operation's default, not an error."
  (dolist (op '(summarize rephrase reply explain ask))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (let ((r (cmacs-ai-textops-read-refinement op)))
        (should (stringp r))
        (should-not (string-empty-p r))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  focus on X  ")))
      (should (equal (cmacs-ai-textops-read-refinement op) "focus on X")))))

(ert-deftest cmacs-ai-menu-tests-textops-specs-well-formed ()
  "Every operation has a prompt, a default and a live system-prompt symbol."
  (dolist (entry cmacs-ai-textops--specs)
    (let ((spec (cdr entry)))
      (should (stringp (plist-get spec :title)))
      (should (stringp (plist-get spec :read)))
      (should (stringp (plist-get spec :default)))
      ;; Indirected through the symbol so customising it takes effect.
      (should (boundp (plist-get spec :system)))
      (should (stringp (symbol-value (plist-get spec :system)))))))

(ert-deftest cmacs-ai-menu-tests-textops-refuses-empty-target ()
  "There is nothing to summarize about nothing."
  (skip-unless (and (fboundp 'cmacs-ai-supported-p) (cmacs-ai-supported-p)))
  (should-error
   (cmacs-ai-textops-run 'summarize
                         (cmacs-ai-target-create :kind 'region :text "   ")
                         "anything")
   :type 'user-error))

(provide 'cmacs-ai-menu-tests)

;;; cmacs-ai-menu-tests.el ends here
