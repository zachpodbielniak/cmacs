;;; cmacs-load-quiet-tests.el --- Loading a subsystem does nothing but define  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A registered tool `require's its subsystem inside its body, so the
;; first call of even a read-only tool loads files.  `gnuseye_list_layers'
;; did that and the test rig saw ten connections to solarsystemscope.com:
;; cmacs-gnuseye-celestial.el started an idle timer at top level that
;; fetched the body maps.  Loading had become an action.
;;
;; The rule held here: LOADING A FILE DEFINES THINGS AND DOES NOTHING
;; ELSE.  No process, no socket, no fetch, no D-Bus call, and no file
;; written outside the user's own cache/state/config/data directories --
;; neither at top level nor from a timer the load scheduled.
;;
;; How: a child Emacs with a throwaway HOME and no display or session
;; bus.  In it every function that can start a process or reach the
;; network is replaced by one that records the call and does nothing
;; (so the test itself never touches the network), each feature is
;; `require'd, and every timer the load added is run on the spot.  The
;; parent reads the record.
;;
;; Which features: the GNU's Eye core, layer and feature files, and
;; every `cmacs-*' feature a tool family file (lisp/cmacs/cmacs-*-tools.el)
;; requires -- read from the sources, so a new family is covered the day
;; it is written.
;;
;; What this cannot see: work a C library does when its DEFUNs are first
;; reached (GStreamer scanning its plugins, Mesa writing a shader cache).
;; The functions replaced are the Lisp-visible ones, including the C
;; fetchers and connectors cmacs itself defines.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'subr-x)

(defvar cmacs-gnuseye-buffer)
(defvar cmacs-gnuseye-open-hook)
(declare-function cmacs-gnuseye-when-open "cmacs-gnuseye" (function))

;;;; The child's half

(defconst cmacs-load-quiet-tests--recorded
  '(;; Emacs's own.
    make-network-process make-process make-serial-process
    make-pipe-process call-process call-process-region process-file
    url-retrieve url-retrieve-synchronously
    dbus-call-method dbus-call-method-asynchronously
    dbus-register-signal dbus-send-signal
    ;; cmacs's C primitives that fetch, connect or spawn.  Lisp cannot
    ;; see inside them, so they are recorded by name.
    cmacs-gnuseye-http-get-async cmacs-ai--libresearch-fetch
    cmacs-ai--call cmacs-ai-chat-stream cmacs-ai-prompt-sync
    gowl-spawn lrg-open-connection
    cmacs-clawtilla--connect-local cmacs-clawtilla--connect-profile
    cmacs-clawtilla--connect-tcp cmacs-dbexplorer--connect-async
    cmacs-libreclaw-channel-connect
    cmacs-libreclaw-remote--connect-internal)
  "Functions the child replaces with a recorder.
Those not defined in this build are left out.")

(defvar cmacs-load-quiet-tests--loading nil
  "In the child: what is being loaded, a string.")

(defvar cmacs-load-quiet-tests--events nil
  "In the child: recorded calls, newest first, each (WHAT FUNCTION ARG).")

(defvar cmacs-load-quiet-tests--writes nil
  "In the child: recorded writes, newest first, each (WHAT FUNCTION FILE).")

(defun cmacs-load-quiet-tests--native-compiler-p ()
  "In the child: non-nil when the native compiler is what is running.
True inside the functions that build a subr trampoline or compile a
unit, read off the backtrace."
  (let ((found nil))
    (mapbacktrace
     (lambda (_evald func _args _flags)
       (when (and (symbolp func)
                  (memq func '(comp-trampoline-compile
                               comp--trampoline-search
                               comp-subr-trampoline-install
                               comp--native-compile
                               native-compile
                               comp--final)))
         (setq found t))))
    found))

(defun cmacs-load-quiet-tests--child-install ()
  "In the child: put the recorders in place.

Natively compiled Lisp calls a primitive directly unless a trampoline is
installed for it, and compiling a trampoline runs a subprocess -- which
the recorders would swallow.  So every trampoline first, then every
recorder."
  (when (and (fboundp 'comp-subr-trampoline-install)
             (fboundp 'native-comp-available-p)
             (native-comp-available-p))
    (dolist (fn (append cmacs-load-quiet-tests--recorded
                        '(write-region make-directory)))
      (when (and (fboundp fn) (subr-primitive-p (symbol-function fn)))
        (comp-subr-trampoline-install fn))))
  (dolist (fn cmacs-load-quiet-tests--recorded)
    (when (fboundp fn)
      (let ((name fn))
        (advice-add
         fn :around
         (lambda (original &rest args)
           (if (cmacs-load-quiet-tests--native-compiler-p)
               ;; Emacs compiling a trampoline for a primitive that the
               ;; file being loaded advises.  That is the native
               ;; compiler's subprocess, not the file's: it happens once
               ;; per eln cache, which is why it shows in a child with a
               ;; throwaway HOME and never in a developer's session.
               (apply original args)
             (push (list cmacs-load-quiet-tests--loading name
                         (let ((first (car args)))
                           (if (stringp first)
                               (substring first 0 (min 120 (length first)))
                             (format "%S" (and first (type-of first))))))
                   cmacs-load-quiet-tests--events)
             nil))))))
  ;; Writes still happen (the child's HOME is a throwaway); where to is
  ;; what gets judged.
  (advice-add 'write-region :before
              (lambda (_start _end file &rest _)
                (when (stringp file)
                  (push (list cmacs-load-quiet-tests--loading 'write-region
                              (expand-file-name file))
                        cmacs-load-quiet-tests--writes))))
  (advice-add 'make-directory :before
              (lambda (dir &rest _)
                (push (list cmacs-load-quiet-tests--loading 'make-directory
                            (expand-file-name dir))
                      cmacs-load-quiet-tests--writes))))

(defun cmacs-load-quiet-tests--child-load (feature)
  "In the child: `require' FEATURE, then run the timers that added.
Returns `loaded', or a string saying why it did not load.  A timer is
run here and now, with the recorders in place, because \"two seconds
after it was loaded\" is still \"because it was loaded\"."
  (let* ((cmacs-load-quiet-tests--loading (symbol-name feature))
         (before (append timer-list timer-idle-list nil))
         (status (condition-case err
                     (progn (require feature) 'loaded)
                   (error (format "%S" err)))))
    (dolist (timer (append timer-list timer-idle-list nil))
      (unless (memq timer before)
        (let ((cmacs-load-quiet-tests--loading
               (format "%s, from a timer it started" feature)))
          (cancel-timer timer)
          (ignore-errors
            (apply (timer--function timer) (timer--args timer))))))
    status))

(defun cmacs-load-quiet-tests--child-main (features)
  "In the child: load FEATURES (symbols) and print the record.
Once `cmacs-gnuseye' is loaded its layer and feature files are queued
too: those lists are only known once the core is, and they are what
listing the layers loads."
  (cmacs-load-quiet-tests--child-install)
  (let ((status nil)
        (queue (copy-sequence features)))
    (while queue
      (let ((feature (pop queue)))
        (unless (assq feature status)
          (push (cons feature (cmacs-load-quiet-tests--child-load feature))
                status)
          (when (eq feature 'cmacs-gnuseye)
            (dolist (var '(cmacs-gnuseye-layer-files
                           cmacs-gnuseye-feature-files))
              (when (boundp var)
                (setq queue (append queue
                                    (copy-sequence (symbol-value var))))))))))
    (princ "\n@@cmacs-load-quiet@@")
    (prin1 (list :status (nreverse status)
                 :events (reverse cmacs-load-quiet-tests--events)
                 :writes (reverse cmacs-load-quiet-tests--writes)))
    (princ "@@end@@\n")))

;;;; The parent's half

(defun cmacs-load-quiet-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-capability.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-load-quiet-tests--tool-requires (root)
  "Return the `cmacs-*' features the tool family files under ROOT require.
Every `(require \\='cmacs-...)' form of every lisp/cmacs/cmacs-*-tools.el,
at top level or in a tool body, plus the family files themselves."
  (let ((features nil))
    (dolist (file (directory-files (expand-file-name "lisp/cmacs" root) t
                                   "\\`cmacs-.*-tools\\.el\\'"))
      (push (intern (file-name-base file)) features)
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "(require '\\(cmacs-[a-z0-9-]+\\)" nil t)
          (push (intern (match-string 1)) features))))
    (sort (delete-dups features)
          (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun cmacs-load-quiet-tests--run (features &optional extra-load)
  "Load FEATURES in a child Emacs; return its record, a plist.
EXTRA-LOAD is a directory to add to the child's `load-path'.  The child
has a throwaway HOME, the standard XDG directories under it, and no
display, compositor or session bus.  Returns nil when the child printed
no record; the plist carries :home, the child's HOME."
  (let* ((root (cmacs-load-quiet-tests--root))
         (emacs (expand-file-name invocation-name invocation-directory))
         (home (file-name-as-directory
                (make-temp-file "cmacs-load-quiet" t)))
         (runtime (expand-file-name "run" home))
         (process-environment
          (append
           (list (concat "HOME=" (directory-file-name home))
                 (concat "XDG_CACHE_HOME=" (expand-file-name ".cache" home))
                 (concat "XDG_CONFIG_HOME=" (expand-file-name ".config" home))
                 (concat "XDG_STATE_HOME="
                         (expand-file-name ".local/state" home))
                 (concat "XDG_DATA_HOME="
                         (expand-file-name ".local/share" home))
                 (concat "XDG_RUNTIME_DIR=" runtime)
                 (concat "TMPDIR=" (expand-file-name "tmp" home))
                 (concat "PATH=" (or (getenv "PATH") "/usr/bin:/bin"))
                 ;; Explicitly unset: an entry with no `=' keeps Emacs
                 ;; from handing down the value it was started with.
                 "DISPLAY" "WAYLAND_DISPLAY" "WAYLAND_SOCKET"
                 "DBUS_SESSION_BUS_ADDRESS" "EMACS_SOCKET_NAME")
           nil)))
    (make-directory runtime t)
    (set-file-modes runtime #o700)
    (make-directory (expand-file-name "tmp" home) t)
    (unwind-protect
        (with-temp-buffer
          (let ((default-directory root))
            (apply #'call-process emacs nil t nil
                   (append
                    (list "--batch" "-Q"
                          "-L" (expand-file-name "lisp/cmacs" root)
                          "-L" (expand-file-name "test/cmacs" root))
                    (and extra-load (list "-L" extra-load))
                    (list "--eval" "(setq load-prefer-newer t)"
                          "-l" (expand-file-name
                                "test/cmacs/cmacs-load-quiet-tests.el" root)
                          "--eval"
                          (format "(cmacs-load-quiet-tests--child-main '%S)"
                                  features)))))
          (goto-char (point-min))
          (if (re-search-forward "@@cmacs-load-quiet@@" nil t)
              (append (list :home home :output (buffer-string))
                      (read (current-buffer)))
            (list :home home :output (buffer-string))))
      (delete-directory home t))))

(defun cmacs-load-quiet-tests--outside (record)
  "Return the writes in RECORD that left the user's own directories.
Allowed: the XDG cache, config, state, data and runtime directories and
the temporary directory -- all of which are under the child's HOME."
  (let* ((home (plist-get record :home))
         (allowed (mapcar (lambda (dir)
                            (file-name-as-directory
                             (expand-file-name dir home)))
                          '(".cache" ".config" ".local/state"
                            ".local/share" "run" "tmp" ".emacs.d"))))
    (cl-remove-if
     (lambda (write)
       (let ((file (nth 2 write)))
         (cl-some (lambda (dir)
                    (string-prefix-p dir (file-name-as-directory file)))
                  allowed)))
     (plist-get record :writes))))

(defun cmacs-load-quiet-tests--explain (rows)
  "ROWS of (WHAT FUNCTION ARG) as lines for a failure message."
  (mapconcat (lambda (row)
               (format "  loading %s: %s %s"
                       (nth 0 row) (nth 1 row) (nth 2 row)))
             rows "\n"))

(defun cmacs-load-quiet-tests--assert-quiet (record)
  "Fail unless RECORD shows that nothing but defining happened."
  (unless (plist-member record :status)
    (ert-fail (format "the child printed no record:\n%s"
                      (plist-get record :output))))
  (when-let* ((events (plist-get record :events)))
    (ert-fail (format "loading started a process or reached the network:\n%s"
                      (cmacs-load-quiet-tests--explain events))))
  (when-let* ((outside (cmacs-load-quiet-tests--outside record)))
    (ert-fail (format "loading wrote outside the user's own directories:\n%s"
                      (cmacs-load-quiet-tests--explain outside)))))

(defun cmacs-load-quiet-tests--loaded (record)
  "The features of RECORD that actually loaded."
  (delq nil (mapcar (lambda (cell) (and (eq (cdr cell) 'loaded) (car cell)))
                    (plist-get record :status))))

;;;; Tests

(ert-deftest cmacs-load-quiet-test-the-probe-sees-what-it-should ()
  "A file that fetches at load, or from a timer it starts, is caught.
Without this the tests below would pass for a probe that records
nothing."
  (skip-unless (cmacs-load-quiet-tests--root))
  (let ((dir (file-name-as-directory (make-temp-file "cmacs-load-loud" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "cmacs-load-loud.el" dir)
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    "(require 'url)\n"
                    "(url-retrieve \"https://example.invalid/at-load\""
                    " #'ignore)\n"
                    "(run-with-idle-timer 2 nil (lambda ()"
                    " (make-process :name \"loud\" :command '(\"true\"))"
                    " (url-retrieve \"https://example.invalid/later\""
                    " #'ignore)))\n"
                    "(write-region \"x\" nil \"/cmacs-load-loud-probe\")\n"
                    "(provide 'cmacs-load-loud)\n"))
          (let* ((record (cmacs-load-quiet-tests--run '(cmacs-load-loud) dir))
                 (events (plist-get record :events)))
            (should (plist-member record :status))
            (should (cl-some (lambda (e)
                               (and (eq (nth 1 e) 'url-retrieve)
                                    (equal (nth 0 e) "cmacs-load-loud")
                                    (string-match-p "at-load" (nth 2 e))))
                             events))
            (should (cl-some (lambda (e)
                               (and (eq (nth 1 e) 'url-retrieve)
                                    (string-match-p "timer" (nth 0 e))
                                    (string-match-p "later" (nth 2 e))))
                             events))
            (should (cl-some (lambda (e) (eq (nth 1 e) 'make-process))
                             events))
            ;; The write to / failed, and was still recorded as outside.
            (should (cl-some (lambda (w)
                               (equal (nth 2 w) "/cmacs-load-loud-probe"))
                             (cmacs-load-quiet-tests--outside record)))))
      (delete-directory dir t))))

(ert-deftest cmacs-load-quiet-test-gnuseye ()
  "Loading GNU's Eye -- core, every layer, every feature -- fetches nothing.
What `gnuseye_list_layers' and D-Bus `GnusEye.ListLayers' do is exactly
this load; body maps and the country index wait for a globe."
  (skip-unless (cmacs-load-quiet-tests--root))
  (skip-unless (fboundp 'cmacs-gnuseye-attach))
  (let* ((record (cmacs-load-quiet-tests--run '(cmacs-gnuseye)))
         (loaded (cmacs-load-quiet-tests--loaded record)))
    (cmacs-load-quiet-tests--assert-quiet record)
    ;; The two files that used to fetch were really loaded.
    (should (memq 'cmacs-gnuseye loaded))
    (should (memq 'cmacs-gnuseye-celestial loaded))
    (should (memq 'cmacs-gnuseye-country loaded))
    (should (> (length loaded) 20))))

(ert-deftest cmacs-load-quiet-test-gnuseye-fetches-wait-for-a-globe ()
  "The body-map and country fetches hang on the open hook, not on load."
  (skip-unless (cmacs-load-quiet-tests--root))
  (skip-unless (fboundp 'cmacs-gnuseye-attach))
  (require 'cmacs-gnuseye)
  (require 'cmacs-gnuseye-celestial nil t)
  (require 'cmacs-gnuseye-country nil t)
  (skip-unless (and (featurep 'cmacs-gnuseye-celestial)
                    (featurep 'cmacs-gnuseye-country)))
  (should (memq 'cmacs-gnuseye-celestial--textures-soon
                (default-value 'cmacs-gnuseye-open-hook)))
  (should (memq 'cmacs-gnuseye-country--load
                (default-value 'cmacs-gnuseye-open-hook)))
  ;; With no globe, registering a function runs nothing.
  (let ((cmacs-gnuseye-open-hook nil)
        (cmacs-gnuseye-buffer nil)
        (ran nil))
    (cmacs-gnuseye-when-open (lambda () (setq ran t)))
    (should-not ran)
    (should (= (length cmacs-gnuseye-open-hook) 1)))
  ;; And the source keeps no fetch at top level.
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "lisp/cmacs/cmacs-gnuseye-celestial.el"
                       (cmacs-load-quiet-tests--root)))
    (should-not (re-search-forward "^(run-with-\\(?:idle-\\)?timer" nil t))
    (should-not (re-search-forward
                 "^(cmacs-gnuseye-celestial-ensure-textures" nil t))))

(ert-deftest cmacs-load-quiet-test-tool-families ()
  "Every subsystem a tool family requires loads without acting.
A tool body's `require' runs on the first call of that tool, read-only
tools included."
  (let ((root (cmacs-load-quiet-tests--root)))
    (skip-unless root)
    (let* ((features (cmacs-load-quiet-tests--tool-requires root))
           (record (cmacs-load-quiet-tests--run features))
           (loaded (cmacs-load-quiet-tests--loaded record)))
      (should (> (length features) 30))
      (cmacs-load-quiet-tests--assert-quiet record)
      ;; A build without some subsystem loads fewer; a child that loaded
      ;; almost nothing proved nothing.
      (should (> (length loaded) (/ (length features) 2))))))

(provide 'cmacs-load-quiet-tests)

;;; cmacs-load-quiet-tests.el ends here
