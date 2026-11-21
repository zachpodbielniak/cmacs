;;; cmacs-context-tests.el --- ERT tests for named contexts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Contexts are Elisp over the checkpoint snapshot and the restore
;; executor, so all of it runs here without a compositor:
;;
;;   * saved state in a private directory: the round trip, the modes,
;;     and that neither a save nor the files touch the journal;
;;   * a declaration overlaid by a saved state, category by category;
;;   * a switch with the compositor played by stubs that record every
;;     call -- it starts and moves, and never closes;
;;   * leaving: auto-save, a second switch cancelling the first, hooks
;;     that signal;
;;   * the journal event, only while recording and through the filters;
;;   * the tools, with redaction stubbed.
;;
;; No test talks to a running gowl, starts a program, opens a page or
;; reads the real state directory.  Stubs of C DEFUNs take &rest.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-journal)
(require 'cmacs-journal-checkpoint)
(require 'cmacs-journal-restore)
(require 'cmacs-context)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)

(defvar cmacs-context-tests--clients nil
  "The stub compositor's windows: plists of :id :app :title :tags (a
bitmask) :pid.")

(defvar cmacs-context-tests--calls nil
  "Calls made to the stub compositor, newest first: (FUNCTION . ARGS).")

(defvar cmacs-context-tests--gowl t
  "Whether the stub compositor says it is running.")

(defun cmacs-context-tests--record (name &optional value)
  "A stub that records a call to NAME and returns VALUE (default t)."
  (lambda (&rest args)
    (push (cons name args) cmacs-context-tests--calls)
    (or value t)))

(defun cmacs-context-tests--client (id)
  "The stub client whose :id is ID."
  (or (cl-find id cmacs-context-tests--clients
               :key (lambda (c) (plist-get c :id)))
      (error "Not a GowlClient")))

(defun cmacs-context-tests--calls-to (name)
  "The argument lists of the recorded calls to NAME, oldest first."
  (nreverse (mapcar #'cdr (cl-remove-if-not (lambda (c) (eq (car c) name))
                                            cmacs-context-tests--calls))))

(defmacro cmacs-context-tests--with (&rest body)
  "Run BODY with private context state, a private journal and a stub gowl.
`root' is the temporary directory.  The journal is off; a test that
wants it recording sets `cmacs-journal-mode'.  Nothing asks: the two
confirmation options are off unless a test turns one on."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory
                 (make-temp-file "cmacs-context-test" t)))
          (cmacs-context-directory (expand-file-name "state/contexts" root))
          (cmacs-context-files nil)
          (cmacs-context--files-loaded nil)
          (cmacs-context--declared nil)
          (cmacs-context--current nil)
          (cmacs-context--settled nil)
          (cmacs-context--switch nil)
          (cmacs-context--approved nil)
          (cmacs-context--original-directory 'unset)
          (cmacs-context-auto-save-on-leave t)
          (cmacs-context-park-others nil)
          (cmacs-context-confirm-first-switch nil)
          (cmacs-context-confirm-launches nil)
          (cmacs-context-save-include '(buffers urls apps layout))
          (cmacs-context-set-default-directory nil)
          (cmacs-context-use-perspectives nil)
          (cmacs-context-mode-line-format nil)
          (cmacs-context-bar-widget nil)
          (cmacs-context-after-switch-functions nil)
          (cmacs-context-tests--clients nil)
          (cmacs-context-tests--calls nil)
          (cmacs-context-tests--gowl t)
          ;; The journal: off, private, with an empty usable rule set.
          (cmacs-journal-directory (expand-file-name "state/journal" root))
          (cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters nil)
          (cmacs-journal-idle-threshold nil)
          (cmacs-journal--open nil)
          (cmacs-journal--queue nil)
          (cmacs-journal--paused nil)
          (cmacs-journal--locked nil)
          (cmacs-journal--in-tool-call nil)
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-journal-mode nil)
          (cmacs-journal-checkpoint--commands (make-hash-table :test #'eql))
          (cmacs-journal-checkpoint-command-lines t)
          (cmacs-journal-restore--pending nil)
          (cmacs-journal-restore--poll-timer nil)
          (cmacs-journal-restore-app-commands nil)
          (inhibit-interaction nil)
          (inhibit-message t)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (unwind-protect
         (save-window-excursion
           (cl-letf*
               (((symbol-function 'gowl-running-p)
                 (lambda (&rest _) cmacs-context-tests--gowl))
                ((symbol-function 'gowl-list-clients)
                 (lambda (&rest _)
                   (mapcar (lambda (c) (plist-get c :id))
                           cmacs-context-tests--clients)))
                ((symbol-function 'gowl-client-info)
                 (lambda (client &rest _)
                   (let ((c (cmacs-context-tests--client client)))
                     (list (cons 'id (plist-get c :id))
                           (cons 'title (or (plist-get c :title) ""))
                           (cons 'app-id (or (plist-get c :app) ""))
                           (cons 'tags (or (plist-get c :tags) 1))
                           (cons 'geometry '(0 0 800 600))))))
                ((symbol-function 'gowl-client-pid)
                 (lambda (client &rest _)
                   (plist-get (cmacs-context-tests--client client) :pid)))
                ((symbol-function 'gowl-focused-client) (lambda (&rest _) nil))
                ((symbol-function 'gowl-find-client) (lambda (&rest _) nil))
                ((symbol-function 'gowl-list-monitors)
                 (lambda (&rest _) '("DP-1")))
                ((symbol-function 'gowl-monitor-info)
                 (lambda (&rest _)
                   '((name . "DP-1") (geometry 0 0 1920 1080) (tags . 1)
                     (layout-symbol . "[]="))))
                ((symbol-function 'gowl-find-monitor)
                 (lambda (name &rest _) (and (equal name "DP-1") name)))
                ((symbol-function 'gowl-list-layouts)
                 (lambda (&rest _) '("tile" "monocle" "float")))
                ((symbol-function 'gowl-get-layout) (lambda (&rest _) "[]="))
                ((symbol-function 'gowl-spawn)
                 (cmacs-context-tests--record 'gowl-spawn 4242))
                ((symbol-function 'gowl-pretag-pid)
                 (cmacs-context-tests--record 'gowl-pretag-pid))
                ((symbol-function 'gowl-set-tags)
                 (cmacs-context-tests--record 'gowl-set-tags))
                ((symbol-function 'gowl-view-tags)
                 (cmacs-context-tests--record 'gowl-view-tags))
                ((symbol-function 'gowl-set-layout)
                 (cmacs-context-tests--record 'gowl-set-layout))
                ((symbol-function 'gowl-focus-client)
                 (cmacs-context-tests--record 'gowl-focus-client))
                ((symbol-function 'gowl-close-client)
                 (cmacs-context-tests--record 'gowl-close-client))
                ((symbol-function 'gowl-run-command) (lambda (&rest _) nil))
                ;; /proc is the machine's, not the test's.
                ((symbol-function 'cmacs-journal-checkpoint--read-cmdline)
                 (lambda (pid &rest _)
                   (plist-get (cl-find pid cmacs-context-tests--clients
                                       :key (lambda (c) (plist-get c :pid)))
                              :argv)))
                ((symbol-function 'cmacs-journal-restore--gsurf-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'browse-url)
                 (cmacs-context-tests--record 'browse-url)))
             (cmacs-journal-filters-reload)
             ,@body))
       (when (timerp cmacs-journal-restore--poll-timer)
         (cancel-timer cmacs-journal-restore--poll-timer))
       (when (get-buffer "*cmacs-journal-restore*")
         (kill-buffer "*cmacs-journal-restore*"))
       (dolist (buffer (buffer-list))
         (let ((file (buffer-local-value 'buffer-file-name buffer)))
           (when (and file (string-prefix-p root (expand-file-name file)))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (delete-directory root t))))

(defun cmacs-context-tests--file (root name)
  "Make the file NAME under ROOT and return its path."
  (let ((file (expand-file-name name root)))
    (with-temp-file file (insert name "\n"))
    file))

(defun cmacs-context-tests--settle ()
  "Let the timers of a switch run; return non-nil once it has settled."
  (let ((tries 300))
    (while (and (> tries 0) (not cmacs-context--settled))
      (accept-process-output nil 0.01)
      (cl-decf tries))
    cmacs-context--settled))

(defun cmacs-context-tests--saved-apps (name)
  "The app ids in the saved state of the context NAME."
  (mapcar (lambda (c) (plist-get c :app))
          (plist-get (plist-get (cmacs-context--read name) :snapshot)
                     :clients)))

;;;; Saved state

(ert-deftest cmacs-context-test-save-round-trip ()
  "A save is read back as it was written, privately, without the journal."
  (cmacs-context-tests--with
    (let ((file (cmacs-context-tests--file root "notes.org")))
      (find-file file)
      (setq cmacs-context-tests--clients
            (list (list :id 1 :app "foot" :title "shell" :tags 2 :pid 100
                        :argv '("foot" "--title" "a b"))
                  (list :id 2 :app "librewolf" :title "docs" :tags 4 :pid 101)))
      (should (equal "work" (cmacs-context-save "work")))
      (should (equal "work" (cmacs-context-current)))
      ;; The journal was off, stayed off, and got nothing.
      (should-not cmacs-journal-mode)
      (should-not cmacs-journal--queue)
      (should-not (file-exists-p cmacs-journal-directory))
      ;; 0700 and 0600.
      (should (= #o700 (file-modes cmacs-context-directory)))
      (should (= #o600 (file-modes (cmacs-context--file "work"))))
      (let* ((state (cmacs-context--read "work"))
             (snapshot (plist-get state :snapshot))
             (foot (cl-find "foot" (plist-get snapshot :clients)
                            :key (lambda (c) (plist-get c :app))
                            :test #'equal)))
        (should (equal "work" (plist-get state :name)))
        (should (numberp (plist-get state :saved)))
        (should (equal '("buffers" "urls" "apps" "layout")
                       (plist-get state :include)))
        (should (equal '("foot" "librewolf")
                       (cmacs-context-tests--saved-apps "work")))
        (should (equal '(2) (plist-get foot :tags)))
        ;; The command line survives quoting and JSON.
        (should (equal '("foot" "--title" "a b")
                       (split-string-shell-command
                        (plist-get foot :command))))
        (should (cl-find (abbreviate-file-name file)
                         (plist-get snapshot :buffers)
                         :key (lambda (b) (plist-get b :file))
                         :test #'equal))
        (should (plist-get (car (plist-get snapshot :frames)) :tree))
        (should (equal '(1) (plist-get (car (plist-get snapshot :monitors))
                                       :tags)))
        ;; Writing what was read gives the same thing again.
        (cmacs-context--write "work" state)
        (should (equal (cmacs-context--plist-without
                        (cmacs-context--read "work") '(:name))
                       (cmacs-context--plist-without state '(:name)))))
      (should (member "work" (cmacs-context-names))))))

(ert-deftest cmacs-context-test-save-include ()
  "A save limited to some categories holds only those."
  (cmacs-context-tests--with
    (find-file (cmacs-context-tests--file root "a.txt"))
    (setq cmacs-context-tests--clients
          (list (list :id 1 :app "foot" :tags 1 :pid 100)))
    (cmacs-context-save "half" '(buffers))
    (let ((snapshot (plist-get (cmacs-context--read "half") :snapshot)))
      (should (plist-get snapshot :buffers))
      (should-not (plist-get snapshot :clients))
      (should-not (plist-get snapshot :monitors)))))

(ert-deftest cmacs-context-test-save-fails-closed ()
  "With an unusable rule set nothing is saved."
  (cmacs-context-tests--with
    (setq cmacs-journal-filter--loaded nil
          cmacs-journal-filter--error "broken rules")
    (should-error (cmacs-context-save "work") :type 'user-error)
    (should-not (file-exists-p (cmacs-context--file "work")))
    (should-not (cmacs-context-current))))

(ert-deftest cmacs-context-test-filters-apply-to-a-save ()
  "What the journal's filters exclude is not in a saved context."
  (cmacs-context-tests--with
    (setq cmacs-journal-filters
          '((:match ((:app . "\\`keepassxc\\'")) :exclude t)))
    (cmacs-journal-filters-reload)
    (setq cmacs-context-tests--clients
          (list (list :id 1 :app "foot" :tags 1 :pid 100)
                (list :id 2 :app "keepassxc" :tags 1 :pid 101)))
    (cmacs-context-save "work")
    (should (equal '("foot") (cmacs-context-tests--saved-apps "work")))))

(ert-deftest cmacs-context-test-names ()
  "Names are validated, and rename and delete act on the saved state."
  (cmacs-context-tests--with
    (dolist (bad '("" "." ".hidden" "a/b" " lead" "trail " "x\ny"))
      (should-error (cmacs-context--check-name bad) :type 'user-error))
    (should (equal "client: acme (q4)"
                   (cmacs-context--check-name "client: acme (q4)")))
    (cmacs-context-save "client: acme (q4)")
    (should (equal '("client: acme (q4)") (cmacs-context-names)))
    (cmacs-context-rename "client: acme (q4)" "acme")
    (should (equal '("acme") (cmacs-context-names)))
    (should (equal "acme" (cmacs-context-current)))
    (should (equal "acme" (plist-get (cmacs-context--read "acme") :name)))
    (cmacs-context-define "declared" :files nil)
    (should-error (cmacs-context-rename "declared" "other") :type 'user-error)
    (cmacs-context-delete "acme")
    (should (equal '("declared") (cmacs-context-names)))
    (should-not (cmacs-context-current))))

;;;; Declarations

(ert-deftest cmacs-context-test-declaration-overlay ()
  "A saved category replaces the declared one; the rest stays declared."
  (cmacs-context-tests--with
    (let ((a (cmacs-context-tests--file root "a.txt"))
          (b (cmacs-context-tests--file root "b.txt")))
      (cmacs-context-define "dev"
                            :directory root
                            :files '("a.txt")
                            :apps '("foot --title dev"
                                    (:command "librewolf" :tag 3 :floating t))
                            :tags '(2)
                            :env '(("EDITOR" . "emacsclient"))
                            :project "cmacs")
      (should-error (cmacs-context-define "bad" :nope 1))
      ;; Declared only.
      (let* ((effective (cmacs-context--effective "dev"))
             (snapshot (plist-get effective :snapshot)))
        (should (eq 'declared (plist-get (cmacs-context-info "dev") :kind)))
        (should (equal (list (abbreviate-file-name a))
                       (mapcar (lambda (e) (plist-get e :file))
                               (plist-get snapshot :buffers))))
        (should (equal '("foot" "librewolf")
                       (mapcar (lambda (c) (plist-get c :app))
                               (plist-get snapshot :clients))))
        ;; No tag of its own: the context's.  A tag of its own: that.
        (should (equal '((2) (3))
                       (mapcar (lambda (c) (plist-get c :tags))
                               (plist-get snapshot :clients))))
        (should (equal '(2) (plist-get (car (plist-get snapshot :monitors))
                                       :tags))))
      ;; A saved state holding only the buffers category.
      (cmacs-context--write
       "dev" (list :saved 5.0 :directory "/elsewhere" :project "other"
                   :include '(buffers)
                   :snapshot (list :buffers
                                   (list (list :file (abbreviate-file-name b))))))
      (let* ((effective (cmacs-context--effective "dev"))
             (snapshot (plist-get effective :snapshot)))
        (should (eq 'both (plist-get (cmacs-context-info "dev") :kind)))
        ;; Buffers: the saved ones, not merged with the declared ones.
        (should (equal (list (abbreviate-file-name b))
                       (mapcar (lambda (e) (plist-get e :file))
                               (plist-get snapshot :buffers))))
        ;; Applications and layout: still the declaration's.
        (should (equal '("foot" "librewolf")
                       (mapcar (lambda (c) (plist-get c :app))
                               (plist-get snapshot :clients))))
        (should (plist-get snapshot :monitors))
        ;; What is not arrangement comes from the declaration.
        (should (equal root (plist-get effective :directory)))
        (should (equal "cmacs" (plist-get effective :project)))
        (should (equal '(("EDITOR" . "emacsclient"))
                       (plist-get effective :env))))
      ;; Deleting the saved state goes back to the declaration.
      (cmacs-context-delete "dev")
      (should (eq 'declared (plist-get (cmacs-context-info "dev") :kind)))
      (should (equal (list (abbreviate-file-name a))
                     (mapcar (lambda (e) (plist-get e :file))
                             (plist-get (plist-get (cmacs-context--effective
                                                    "dev")
                                                   :snapshot)
                                        :buffers)))))))

(ert-deftest cmacs-context-test-env-is-never-saved ()
  "Declared environment variables do not reach the state file."
  (cmacs-context-tests--with
    (cmacs-context-define "dev" :env '(("API_REGION" . "eu-west-zzz")))
    (cmacs-context-save "dev")
    (with-temp-buffer
      (insert-file-contents (cmacs-context--file "dev"))
      (should-not (search-forward "eu-west-zzz" nil t))
      (goto-char (point-min))
      (should-not (search-forward "API_REGION" nil t)))))

(ert-deftest cmacs-context-test-yaml-file ()
  "Contexts declared in YAML are the same declarations."
  (skip-unless (fboundp 'cmacs-yaml-parse-file))
  (cmacs-context-tests--with
    (let ((file (expand-file-name "contexts.yaml" root)))
      (with-temp-file file
        (insert "contexts:\n"
                "  research:\n"
                "    directory: /tmp\n"
                "    tags: [4]\n"
                "    urls:\n"
                "      - https://example.org/paper\n"
                "    apps:\n"
                "      - command: foot\n"
                "        tag: 4\n"
                "    env:\n"
                "      TOPIC: lasers\n"))
      (setq cmacs-context-files (list file))
      (should (equal '("research") (cmacs-context-names)))
      (let ((effective (cmacs-context--effective "research")))
        (should (equal "/tmp" (plist-get effective :directory)))
        (should (equal '(("TOPIC" . "lasers")) (plist-get effective :env)))
        (should (equal '((4))
                       (mapcar (lambda (c) (plist-get c :tags))
                               (plist-get (plist-get effective :snapshot)
                                          :clients)))))
      ;; A function cannot be named from YAML, and an unknown key is an
      ;; error, not something silently ignored.
      (with-temp-file file
        (insert "contexts:\n  bad:\n    setup: some-function\n"))
      (should-error (cmacs-context-load-file file)))))

;;;; Switching

(ert-deftest cmacs-context-test-switch-adds-and-arranges ()
  "A switch starts what is missing, moves what is running, closes nothing."
  (cmacs-context-tests--with
    (let ((file (cmacs-context-tests--file root "plan.org"))
          (bystander (generate-new-buffer "bystander")))
      (unwind-protect
          (progn
            (cmacs-context-define
             "dev"
             :directory root
             :files '("plan.org")
             :apps '((:command "foot" :tag 2)
                     (:command "librewolf --new-window" :tag 3))
             :tags '(2)
             :layout "monocle"
             :env '(("PROJECT" . "cm acs") ("bad name" . "x")))
            (setq cmacs-context-tests--clients
                  ;; foot runs, on the wrong tag; librewolf does not run;
                  ;; mpv belongs to nothing.
                  (list (list :id 1 :app "foot" :tags 1 :pid 100)
                        (list :id 9 :app "mpv" :tags 2 :pid 109)))
            (cmacs-context-switch "dev")
            ;; Nothing has happened yet: the steps are timers.
            (should-not (get-file-buffer file))
            (should (equal "dev" (cmacs-context-current)))
            (should-not cmacs-context--settled)
            (should (cmacs-context-tests--settle))
            ;; The file is open and shown.
            (should (get-file-buffer file))
            (should (eq (window-buffer) (get-file-buffer file)))
            ;; The running window moved to tag 2.
            (should (equal '((1 2))
                           (cmacs-context-tests--calls-to 'gowl-set-tags)))
            ;; The missing one was started, in the context's directory,
            ;; with its environment; a name that is not a variable name
            ;; is not passed on.
            (let ((spawned (cmacs-context-tests--calls-to 'gowl-spawn)))
              (should (= 1 (length spawned)))
              (should (equal (list "env" "-C" (directory-file-name root)
                                   "PROJECT=cm acs"
                                   "librewolf" "--new-window")
                             (mapcar #'directory-file-name
                                     (split-string-shell-command
                                      (caar spawned))))))
            (should (equal '((4242 4 nil))
                           (cmacs-context-tests--calls-to 'gowl-pretag-pid)))
            ;; The context's tags are viewed and its layout set.
            (should (equal '((2 "DP-1"))
                           (cmacs-context-tests--calls-to 'gowl-view-tags)))
            (should (equal '(("monocle" "DP-1"))
                           (cmacs-context-tests--calls-to 'gowl-set-layout)))
            ;; Nothing was closed and nothing else was touched.
            (should-not (cmacs-context-tests--calls-to 'gowl-close-client))
            (should (buffer-live-p bystander))
            (should-not (cl-find 9 (cmacs-context-tests--calls-to
                                    'gowl-set-tags)
                                 :key #'car))
            ;; The switch was recorded as a use.
            (should (numberp (plist-get (cmacs-context--read "dev") :used))))
        (kill-buffer bystander)))))

(ert-deftest cmacs-context-test-park-others ()
  "With a parking tag, other windows on the context's tags move there."
  (cmacs-context-tests--with
    (cmacs-context-define "dev" :apps '((:command "foot" :tag 2)) :tags '(2))
    (setq cmacs-context-park-others 9
          cmacs-context-tests--clients
          (list (list :id 1 :app "foot" :tags 2 :pid 100)
                (list :id 8 :app "mpv" :tags 2 :pid 108)
                (list :id 9 :app "gimp" :tags 16 :pid 109)))
    (cmacs-context-switch "dev")
    (should (cmacs-context-tests--settle))
    ;; mpv was on tag 2 and is not the context's: tag 9.  gimp is on a
    ;; tag the context does not use: left alone.  foot is the context's.
    (should (equal '((8 256))
                   (cmacs-context-tests--calls-to 'gowl-set-tags)))
    (should-not (cmacs-context-tests--calls-to 'gowl-close-client))))

(ert-deftest cmacs-context-test-confirmation ()
  "The plan is shown, and nothing done, when a switch needs confirming."
  (cmacs-context-tests--with
    (cmacs-context-define "dev" :apps '("foot" "librewolf") :tags '(1))
    ;; A first switch.
    (setq cmacs-context-confirm-first-switch t)
    (pcase-let ((`(,plan . ,asked) (cmacs-context--begin "dev")))
      (should asked)
      (should-not (cmacs-context-current))
      (should-not (cmacs-context-tests--calls-to 'gowl-spawn))
      (should (get-buffer "*cmacs-journal-restore*"))
      (with-current-buffer "*cmacs-journal-restore*"
        (should (string-match-p "Switch to context dev" (buffer-string)))
        (should (string-match-p "Nothing is closed" (buffer-string))))
      ;; Confirming in the plan buffer is the plan's :execute.
      (funcall (plist-get plan :execute) plan)
      (should (cmacs-context-tests--settle))
      (should (= 2 (length (cmacs-context-tests--calls-to 'gowl-spawn)))))
    ;; Used once now: no longer a first switch, so it is immediate...
    (setq cmacs-context-tests--calls nil)
    (should-not (cdr (cmacs-context--begin "dev")))
    (should (cmacs-context-tests--settle))
    ;; ...unless it would start more applications than the limit.
    (setq cmacs-context-confirm-launches 1
          cmacs-context-tests--calls nil)
    (should (cdr (cmacs-context--begin "dev")))
    (should-not (cmacs-context-tests--calls-to 'gowl-spawn))
    (setq cmacs-context-confirm-launches 2)
    (should-not (cdr (cmacs-context--begin "dev")))))

(ert-deftest cmacs-context-test-auto-save-on-leave ()
  "The context left is saved into itself, when the option says so."
  (cmacs-context-tests--with
    (setq cmacs-context-tests--clients
          (list (list :id 1 :app "foot" :tags 1 :pid 100)))
    (cmacs-context-save "a")
    (cmacs-context-save "b")
    (cmacs-context-save "a")
    (should (equal '("foot") (cmacs-context-tests--saved-apps "a")))
    ;; Something new is opened while in `a'.
    (push (list :id 2 :app "gimp" :tags 4 :pid 102)
          cmacs-context-tests--clients)
    (cmacs-context-switch "b")
    (should (cmacs-context-tests--settle))
    (should (equal '("gimp" "foot") (cmacs-context-tests--saved-apps "a")))
    ;; `b' did not have gimp and still does not: it was not left.
    (should (equal '("foot") (cmacs-context-tests--saved-apps "b")))
    ;; With the option off, leaving writes nothing.
    (setq cmacs-context-auto-save-on-leave nil)
    (push (list :id 3 :app "mpv" :tags 8 :pid 103)
          cmacs-context-tests--clients)
    (cmacs-context-switch "a")
    (should (cmacs-context-tests--settle))
    (should (equal '("foot") (cmacs-context-tests--saved-apps "b")))
    ;; A declaration's :auto-save overrides the option.
    (cmacs-context-define "a" :auto-save t)
    (cmacs-context-switch "b")
    (should (cmacs-context-tests--settle))
    (should (member "mpv" (cmacs-context-tests--saved-apps "a")))))

(ert-deftest cmacs-context-test-second-switch-cancels-the-first ()
  "A switch started while one is in flight stops it, cleanly."
  (cmacs-context-tests--with
    (let ((fb (cmacs-context-tests--file root "b.txt"))
          (fc (cmacs-context-tests--file root "c.txt"))
          (ran nil))
      (cmacs-context-define "b" :files (list fb) :apps '("foot")
                            :setup (lambda () (push 'b-setup ran))
                            :teardown (lambda () (push 'b-teardown ran)))
      (cmacs-context-define "c" :files (list fc)
                            :setup (lambda () (push 'c-setup ran)))
      (cmacs-context-save "a")
      (cmacs-context-switch "b")
      (let ((first (plist-get cmacs-context--switch :plan)))
        ;; Before a single step of `b' has run.
        (cmacs-context-switch "c")
        (should (plist-get first :cancelled))
        (should (cmacs-context-tests--settle))
        (should (equal "c" (cmacs-context-current)))
        ;; Let anything left of the first one fire, too.
        (dotimes (_ 5) (accept-process-output nil 0.01))
        ;; `b' did nothing: no file, no program, no setup -- and, never
        ;; having been arrived at, no teardown and no save on leaving.
        (should-not (get-file-buffer fb))
        (should-not (cmacs-context-tests--calls-to 'gowl-spawn))
        (should (equal '(c-setup) ran))
        (should-not (plist-member (cmacs-context--read "b") :snapshot))
        (should-not (plist-get first :done))
        (should (get-file-buffer fc))
        ;; `a' was left settled, so it was saved.
        (should (numberp (plist-get (cmacs-context--read "a") :saved)))))))

(ert-deftest cmacs-context-test-cancel-forgets-pending-windows ()
  "Cancelling stops waiting for the windows of started applications."
  (cmacs-context-tests--with
    (cmacs-context-define "dev" :apps '("foot"))
    (cmacs-context-switch "dev")
    (should (cmacs-context-tests--settle))
    (should (= 1 (length cmacs-journal-restore--pending)))
    (should (cmacs-context-cancel))
    (should-not cmacs-journal-restore--pending)
    (should-not (cmacs-context-cancel))))

(ert-deftest cmacs-context-test-hooks-fail-safely ()
  "A :setup or :teardown that signals does not stop a switch."
  (cmacs-context-tests--with
    (let ((file (cmacs-context-tests--file root "x.txt"))
          (after nil))
      (cmacs-context-define "bad"
                            :setup (lambda () (error "setup broke"))
                            :teardown (lambda () (error "teardown broke")))
      (cmacs-context-define "good" :files (list file))
      (setq cmacs-context-after-switch-functions
            (list (lambda (&rest _) (error "hook broke"))
                  (lambda (name previous) (push (cons name previous) after))))
      (cmacs-context-switch "bad")
      (should (cmacs-context-tests--settle))
      (should (equal "bad" (cmacs-context-current)))
      (cmacs-context-switch "good")
      (should (cmacs-context-tests--settle))
      (should (equal "good" (cmacs-context-current)))
      (should (get-file-buffer file))
      (should (equal '(("good" . "bad") ("bad")) after)))))

(ert-deftest cmacs-context-test-without-a-compositor ()
  "In a plain Emacs a context is its buffers and windows; gowl is not called."
  (cmacs-context-tests--with
    (setq cmacs-context-tests--gowl nil)
    (let ((one (cmacs-context-tests--file root "one.txt"))
          (two (cmacs-context-tests--file root "two.txt")))
      (find-file one)
      (delete-other-windows)
      (cmacs-context-save "solo")
      (let ((snapshot (plist-get (cmacs-context--read "solo") :snapshot)))
        (should-not (plist-get snapshot :clients))
        (should-not (plist-get snapshot :monitors))
        (should (plist-get snapshot :frames)))
      ;; A declared context with applications: they are reported as not
      ;; placeable, and the Emacs half is still done.
      (cmacs-context-define "decl" :files (list two) :apps '("foot")
                            :tags '(2) :layout "tile")
      (cmacs-context-switch "decl")
      (should (cmacs-context-tests--settle))
      (should (eq (window-buffer) (get-file-buffer two)))
      (cmacs-context-switch "solo")
      (should (cmacs-context-tests--settle))
      (should (eq (window-buffer) (get-file-buffer one)))
      (cmacs-context-setup)
      (should-not cmacs-context-tests--calls))))

(ert-deftest cmacs-context-test-directory ()
  "A context's directory becomes the default one, and is put back."
  (cmacs-context-tests--with
    (let ((original (default-value 'default-directory)))
      (unwind-protect
          (progn
            (setq cmacs-context-set-default-directory t)
            (cmacs-context-define "here" :directory root)
            (cmacs-context-define "nowhere")
            (cmacs-context-switch "here")
            (should (cmacs-context-tests--settle))
            (should (equal root (default-value 'default-directory)))
            (should (equal root (cmacs-context-directory-now)))
            (cmacs-context-switch "nowhere")
            (should (cmacs-context-tests--settle))
            (should (equal original (default-value 'default-directory)))
            (should-not (cmacs-context-directory-now)))
        (setq-default default-directory original)))))

(ert-deftest cmacs-context-test-integrations ()
  "A registered integration is told of arriving and leaving, and may fail."
  (cmacs-context-tests--with
    (let ((cmacs-context-integrations nil) (seen nil))
      (cmacs-context-register-integration
       'recorder
       :enter (lambda (name) (push (list 'enter name) seen))
       :leave (lambda (name) (push (list 'leave name) seen)))
      (cmacs-context-register-integration
       'broken :enter (lambda (_) (error "no")))
      (cmacs-context-register-integration
       'absent :when (lambda () nil)
       :enter (lambda (name) (push (list 'absent name) seen)))
      (cmacs-context-define "a")
      (cmacs-context-define "b")
      (cmacs-context-switch "a")
      (should (cmacs-context-tests--settle))
      (cmacs-context-switch "b")
      (should (cmacs-context-tests--settle))
      (should (equal '((enter "a") (leave "a") (enter "b"))
                     (reverse seen))))))

;;;; The journal

(ert-deftest cmacs-context-test-journal-event ()
  "A switch is one journal event, only while recording, and filtered."
  (cmacs-context-tests--with
    (cmacs-context-define "work" :project "cmacs")
    (cmacs-context-define "home" :label "personal")
    ;; Journal off: nothing.
    (cmacs-context-switch "work")
    (should (cmacs-context-tests--settle))
    (should-not cmacs-journal--queue)
    ;; Recording: one event per switch, and none for the save on leaving.
    (setq cmacs-journal-mode t)
    (should (cmacs-journal-recording-p))
    (cmacs-context-switch "home")
    (should (cmacs-context-tests--settle))
    (should (= 1 (length cmacs-journal--queue)))
    (let ((event (car cmacs-journal--queue)))
      (should (eq 'context (plist-get event :kind)))
      (should (equal "personal" (plist-get event :title)))
      (should (plist-get event :time)))
    (cmacs-context-save "home")
    (should (= 1 (length cmacs-journal--queue)))
    (cmacs-context-switch "work")
    (should (cmacs-context-tests--settle))
    (should (equal "work" (plist-get (car cmacs-journal--queue) :title)))
    (should (equal "cmacs" (plist-get (car cmacs-journal--queue) :project)))
    ;; A rule on the title rewrites it; a rule on the kind drops it.
    (setq cmacs-journal--queue nil
          cmacs-journal-filters
          '((:match ((:kind . "\\`context\\'") (:title . "\\`personal\\'"))
             :exclude t)))
    (cmacs-journal-filters-reload)
    (cmacs-context-switch "home")
    (should (cmacs-context-tests--settle))
    (should-not cmacs-journal--queue)
    (cmacs-context-switch "work")
    (should (cmacs-context-tests--settle))
    (should (= 1 (length cmacs-journal--queue)))))

;;;; Agents and tools

(defun cmacs-context-tests--root ()
  "The source tree's root."
  (file-name-as-directory
   (expand-file-name
    (locate-dominating-file
     (or load-file-name buffer-file-name default-directory)
     "lisp/cmacs/cmacs-context-tools.el"))))

(defmacro cmacs-context-tests--with-tools (&rest body)
  "Run BODY with a private registry holding only the context tools."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t))
               ;; The person's rules, played by a table: one name is
               ;; rewritten, one is withheld, the rest pass.
               ((symbol-function 'cmacs-redact-text)
                (lambda (string &rest _)
                  (pcase string
                    ("acme-merger" "client-1")
                    ("diagnosis" "[withheld by your privacy rules]")
                    (_ string)))))
       (let ((load-prefer-newer t))
         (load (expand-file-name "lisp/cmacs/cmacs-context-tools"
                                 (cmacs-context-tests--root))
               nil t))
       ,@body)))

(ert-deftest cmacs-context-test-agents-need-the-tool ()
  "An agent or a remote caller cannot switch or save directly."
  (cmacs-context-tests--with
    (cmacs-context-define "work" :apps '("foot"))
    (let ((inhibit-interaction t))
      (should-error (cmacs-context-switch "work"))
      (should-error (cmacs-context-save "work")))
    (let ((cmacs-journal--in-tool-call t))
      (should-error (cmacs-context-switch "work")))
    (should-not (cmacs-context-current))
    (should-not (cmacs-context-tests--calls-to 'gowl-spawn))))

(ert-deftest cmacs-context-test-tools ()
  "The tools list, report and switch, showing only redacted names."
  (cmacs-context-tests--with
    (cmacs-context-tests--with-tools
      (cmacs-context-define "work" :apps '("foot") :project "acme-merger")
      (cmacs-context-define "acme-merger")
      (cmacs-context-define "diagnosis")
      ;; A call with no arguments at all, as MCP may send it.
      (let ((listing (cmacs-brigade-call-tool "context_list" nil)))
        (should (string-match-p "^work\t1 apps\t0 files\tclient-1\t" listing))
        (should (string-match-p "^client-1\t" listing))
        (should-not (string-match-p "acme" listing))
        (should-not (string-match-p "diagnosis\\|withheld" listing)))
      (should (equal "none" (cmacs-brigade-call-tool "context_current" "{}")))
      ;; By the name it was shown.
      (let ((reply (cmacs-brigade-call-tool "context_switch"
                                            "{\"name\":\"client-1\"}")))
        (should (string-match-p "\\`Switching to client-1\\." reply))
        (should-not (string-match-p "acme" reply)))
      (should (cmacs-context-tests--settle))
      (should (equal "acme-merger" (cmacs-context-current)))
      (should (equal "client-1"
                     (cmacs-brigade-call-tool "context_current" "{}")))
      ;; One that starts a program says so, and starts it.
      (let ((reply (cmacs-brigade-call-tool "context_switch"
                                            "{\"name\":\"work\"}")))
        (should (string-match-p "starting 1 application" reply)))
      (should (cmacs-context-tests--settle))
      (should (= 1 (length (cmacs-context-tests--calls-to 'gowl-spawn))))
      ;; A withheld name, its real name, and a name that is nobody's
      ;; all get the same answer.
      (dolist (name '("diagnosis" "[withheld by your privacy rules]" "nope"))
        (should (string-match-p
                 "\\`Error: No context called"
                 (cmacs-brigade-call-tool
                  "context_switch" (json-serialize `((name . ,name)))))))
      (should (equal "work" (cmacs-context-current))))))

(ert-deftest cmacs-context-test-switch-tool-asks ()
  "context_switch is destructive and confirmed; a refusal switches nothing."
  (cmacs-context-tests--with
    (cmacs-context-tests--with-tools
      (let ((tool (cmacs-brigade--tool-by-wire "context_switch")))
        (should (cmacs-brigade-tool-destructive tool))
        (should (eq 'ask (cmacs-brigade-tool-confirm tool))))
      (should-not (cmacs-brigade-tool-confirm
                   (cmacs-brigade--tool-by-wire "context_list")))
      (cmacs-context-define "work" :apps '("foot"))
      (let ((cmacs-brigade-auto-approve nil)
            (cmacs-brigade-confirm-function (lambda (&rest _) nil)))
        (should (string-match-p
                 "\\`Error: .*declined"
                 (cmacs-brigade-call-tool "context_switch"
                                          "{\"name\":\"work\"}"))))
      (should-not (cmacs-context-current))
      (should-not (cmacs-context-tests--calls-to 'gowl-spawn)))))

;;;; Voice

(ert-deftest cmacs-context-test-voice ()
  "Spoken names are matched whatever their case; saving makes or updates."
  (cmacs-context-tests--with
    (cmacs-context-define "Deep Work")
    (should (equal "Deep Work" (cmacs-context--spoken "deep  work")))
    (should-not (cmacs-context--spoken "shallow work"))
    (cmacs-context-voice-switch "deep work")
    (should (cmacs-context-tests--settle))
    (should (equal "Deep Work" (cmacs-context-current)))
    (cmacs-context-voice-save "research")
    (should (equal "research" (cmacs-context-current)))
    (should (member "research" (cmacs-context-names)))
    (when (require 'cmacs-voice-commands nil t)
      (let ((cmacs-voice-commands nil))
        (cmacs-context-register-voice)
        ;; The bare phrase exists only for names that are contexts.
        (let ((bare (cl-find-if
                     (lambda (entry)
                       (plist-get (nth 3 entry) :cmacs-context-names))
                     cmacs-voice-commands)))
          (should bare)
          (should (string-match-p (concat "\\`" (car bare) "\\'")
                                  "switch to deep work"))
          (should (string-match-p (concat "\\`" (car bare) "\\'")
                                  "go back to research"))
          (should-not (string-match-p (concat "\\`" (car bare) "\\'")
                                      "switch to firefox")))
        ;; Rebuilt, not accumulated.
        (cmacs-context-define "third")
        (should (= 1 (cl-count-if
                      (lambda (entry)
                        (plist-get (nth 3 entry) :cmacs-context-names))
                      cmacs-voice-commands)))))))

;;;; The list

(ert-deftest cmacs-context-test-list ()
  "The list shows every context and which one is current."
  (cmacs-context-tests--with
    (cmacs-context-define "declared" :project "p")
    (cmacs-context-save "saved")
    (let ((entries (cmacs-context--list-entries)))
      (should (equal '("declared" "saved") (mapcar #'car entries)))
      (should (equal "*" (aref (cadr (assoc "saved" entries)) 0)))
      (should (equal "declared" (aref (cadr (assoc "declared" entries)) 2)))
      (should (equal "p" (aref (cadr (assoc "declared" entries)) 6))))
    ;; The previous context is the switcher's first candidate.
    (cmacs-context--touch "declared")
    (should (equal '("declared" "saved") (cmacs-context--names-by-use)))))

(provide 'cmacs-context-tests)

;;; cmacs-context-tests.el ends here
