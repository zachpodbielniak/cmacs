;;; cmacs-speech-ui.el --- M-x cmacs-speech: the speech settings buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One buffer for everything speech: which engine and model each
;; component and feature uses (and why -- every row names the layer that
;; decided it), the model store with live downloads, auditions and
;; one-key tests that need no microphone, enrolled speakers, the engines
;; loaded right now, and a benchmark of every installed recognizer.
;;
;; Choices made here are saved to `cmacs-speech-state-file'.  Anything
;; init.el sets is shown locked (🔒) and is never overwritten; `o'
;; overrides it for this session only, and `i' turns the buffer's
;; choices into `cmacs-speech-set' forms to paste into init.el.
;;
;; Built on the clawtilla section kit (folding, stable redraws by section
;; identity, Evil intercept keys), so it behaves like the other cmacs
;; dashboards; see `cmacs-clawtilla-define-common-keys' for why no key
;; here is an Evil motion.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-speech)
(require 'cmacs-speech-models)
(require 'cmacs-clawtilla-ui)
(require 'transient)

(declare-function cmacs-sherpa-loaded "cmacs-sherpa-defuns.c")
(declare-function cmacs-speech-sherpa-speakers "cmacs-speech-sherpa" (&optional model))
(declare-function cmacs-speech-sherpa-forget-speaker "cmacs-speech-sherpa" (name))
(declare-function cmacs-speech-sherpa-unload-all "cmacs-speech-sherpa" ())
(declare-function cmacs-voice-ptt-start "cmacs-voice" (id &rest keys))
(declare-function cmacs-voice-ptt-stop "cmacs-voice" (id))

(defgroup cmacs-speech-ui nil
  "The speech settings buffer."
  :group 'cmacs-speech
  :prefix "cmacs-speech-ui-")

(defcustom cmacs-speech-ui-test-sentence
  "The quick brown fox jumps over the lazy dog, and the speech engine heard every word."
  "What `x' says and then listens to when trying a component."
  :type 'string
  :group 'cmacs-speech-ui)

(defcustom cmacs-speech-ui-folded '(features speakers engines bench)
  "Sections folded when the buffer first opens."
  :type '(repeat symbol)
  :group 'cmacs-speech-ui)

(defface cmacs-speech-ui-title '((t :inherit font-lock-keyword-face :weight bold :height 1.25))
  "Buffer title." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-heading '((t :inherit font-lock-function-name-face :weight bold))
  "Section headings." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-backend '((t :inherit font-lock-type-face))
  "Engine names." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-model '((t :inherit font-lock-string-face))
  "Model ids." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-dim '((t :inherit shadow))
  "Secondary text." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-ok '((t :inherit success))
  "Ready / installed." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-warn '((t :inherit warning))
  "Needs attention." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-bad '((t :inherit error))
  "Failed." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-lock '((t :inherit font-lock-constant-face))
  "init.el-owned choices." :group 'cmacs-speech-ui)
(defface cmacs-speech-ui-bar '((t :inherit font-lock-builtin-face))
  "Progress bars." :group 'cmacs-speech-ui)

(defconst cmacs-speech-ui-buffer "*cmacs speech*")

(defvar-local cmacs-speech-ui--filter nil "Model filter regexp, or nil.")
(defvar-local cmacs-speech-ui--installed-only nil "Show only installed models.")
(defvar-local cmacs-speech-ui--notes nil "Alist (KEY . STRING): test results shown in rows.")
(defvar cmacs-speech-ui--bench nil "Last benchmark: list of plists.")
(defvar cmacs-speech-ui--redraw-timer nil)

;;;; Formatting helpers

(defun cmacs-speech-ui--size (bytes)
  "BYTES as a short human size."
  (cond ((null bytes) "")
        ((>= bytes 1073741824) (format "%.1f GB" (/ bytes 1073741824.0)))
        ((>= bytes 1048576) (format "%.0f MB" (/ bytes 1048576.0)))
        ((>= bytes 1024) (format "%.0f kB" (/ bytes 1024.0)))
        (t (format "%d B" bytes))))

(defun cmacs-speech-ui--stars (n)
  "N out of 5 as stars."
  (let ((n (max 0 (min 5 (or n 0)))))
    (concat (make-string n ?★) (make-string (- 5 n) ?☆))))

(defun cmacs-speech-ui--bar (fraction width)
  "A WIDTH-cell progress bar for FRACTION."
  (let* ((cells (round (* (max 0.0 (min 1.0 fraction)) width))))
    (propertize (concat (make-string cells ?█) (make-string (- width cells) ?░))
                'face 'cmacs-speech-ui-bar)))

(defun cmacs-speech-ui--pad (s width)
  "S padded or truncated to WIDTH columns."
  (truncate-string-to-width (or s "") width nil ?\s "…"))

(defun cmacs-speech-ui--source (r)
  "A short propertised label for where resolution R came from."
  (let ((src (plist-get r :source)))
    (pcase src
      ('init (propertize "🔒 init.el" 'face 'cmacs-speech-ui-lock
                         'help-echo "Set in init.el; o overrides for this session"))
      ('session (propertize "session" 'face 'cmacs-speech-ui-warn
                            'help-echo "Overridden for this session; u drops it"))
      ('override (propertize "scoped" 'face 'cmacs-speech-ui-warn))
      ('ui (propertize "chosen here" 'face 'cmacs-speech-ui-ok))
      (_ (propertize (if (plist-get r :backend)
                         (format "auto → %s" (plist-get r :backend))
                       "auto")
                     'face 'cmacs-speech-ui-dim)))))

(defun cmacs-speech-ui--status (r)
  "Readiness of resolution R."
  (cond
   ((null (plist-get r :backend))
    (let* ((c (plist-get r :component))
           ;; Suggest the smallest decent model: a first download
           ;; should be quick.
           (pick (car (sort (cl-remove-if (lambda (m) (< (or (plist-get m :quality) 0) 3))
                                          (cmacs-speech-models :component c :installed 'none))
                            (lambda (a b) (< (or (plist-get a :size) 0)
                                             (or (plist-get b :size) 0)))))))
      (propertize (if pick
                      (format "⬇ get %s (%s)" (plist-get pick :id)
                              (cmacs-speech-ui--size (plist-get pick :size)))
                    "no engine")
                  'face 'cmacs-speech-ui-warn)))
   ((null (plist-get r :model))
    (propertize "no model" 'face 'cmacs-speech-ui-warn))
   (t (propertize "ready" 'face 'cmacs-speech-ui-ok))))

;;;; Sections

(defun cmacs-speech-ui--header ()
  "The title, engines and store summary."
  (let ((active (cmacs-speech-models-active-jobs)))
    (insert (propertize "cmacs speech" 'face 'cmacs-speech-ui-title)
            (propertize (format "    %s · store %s%s\n"
                                (abbreviate-file-name cmacs-speech-models-directory)
                                (cmacs-speech-ui--size (cmacs-speech-models-disk-usage))
                                (if active (format " · ⬇ %d downloading" (length active)) ""))
                        'face 'cmacs-speech-ui-dim))
    (dolist (b cmacs-speech-backend-order)
      (let ((d (plist-get (cmacs-speech-backend b) :describe)))
        (insert "  " (propertize (cmacs-speech-ui--pad (symbol-name b) 9)
                                 'face 'cmacs-speech-ui-backend)
                (or (and d (ignore-errors (funcall d))) "")
                "\n")))
    (insert (propertize (format "  choices saved to %s; 🔒 init.el entries always win\n\n"
                                (abbreviate-file-name cmacs-speech-state-file))
                        'face 'cmacs-speech-ui-dim))))

(defun cmacs-speech-ui--row (r label &optional key)
  "Insert one resolution row R labelled LABEL; KEY identifies its notes."
  (let ((note (alist-get key cmacs-speech-ui--notes nil nil #'equal)))
    (insert "  "
            (cmacs-speech-ui--pad label 18) " "
            (propertize (cmacs-speech-ui--pad (format "%s" (or (plist-get r :backend) "—")) 9)
                        'face 'cmacs-speech-ui-backend)
            (propertize (cmacs-speech-ui--pad (format "%s" (or (plist-get r :model) "—")) 44)
                        'face 'cmacs-speech-ui-model)
            " " (cmacs-speech-ui--pad (cmacs-speech-ui--source r) 15)
            " " (cmacs-speech-ui--status r)
            (if note (concat "  " (propertize note 'face 'cmacs-speech-ui-dim)) "")
            "\n")))

(defun cmacs-speech-ui--components ()
  "The Components section."
  (cmacs-clawtilla-insert-section
   :type 'section :value 'components :foldable t
   :heading (propertize "Components" 'face 'cmacs-speech-ui-heading)
   :body
   (lambda ()
     (dolist (c cmacs-speech-components)
       (cmacs-clawtilla-insert-section
        :type 'component :value (car c)
        :body (lambda ()
                (cmacs-speech-ui--row (cmacs-speech-resolve (car c))
                                      (symbol-name (car c)) (car c)))))
     (insert "\n"))))

(defun cmacs-speech-ui--features ()
  "The Features section: per-feature overrides, inherited rows dimmed."
  (cmacs-clawtilla-insert-section
   :type 'section :value 'features :foldable t
   :heading (concat (propertize "Features" 'face 'cmacs-speech-ui-heading)
                    (propertize "  (a feature uses its component's choice unless set here)"
                                'face 'cmacs-speech-ui-dim))
   :body
   (lambda ()
     (dolist (f cmacs-speech-features)
       (cmacs-clawtilla-insert-section
        :type 'feature :value (car f) :level 1 :foldable t
        :heading (propertize (nth 1 f) 'face 'bold)
        :body
        (lambda ()
          (dolist (c (nth 2 f))
            (let* ((r (cmacs-speech-resolve c (car f)))
                   (own (let ((hit (cmacs-speech--find c (car f))))
                          (and hit (plist-get (cddr (cdr hit)) :feature)))))
              (cmacs-clawtilla-insert-section
               :type 'feature-component :value (cons (car f) c)
               :body (lambda ()
                       (if own
                           (cmacs-speech-ui--row r (format "  %s" c) (cons (car f) c))
                         (insert (propertize
                                  (format "    %-18s inherits: %s / %s\n" c
                                          (or (plist-get r :backend) "—")
                                          (or (plist-get r :model) "—"))
                                  'face 'cmacs-speech-ui-dim)))))))))
       nil)
     (insert "\n"))))

(defun cmacs-speech-ui--model-row (m)
  "Insert model plist M."
  (let* ((job (plist-get m :job))
         (state (and job (cmacs-speech-models-job-state job)))
         (icon (cond ((plist-get m :installed) (propertize "✓" 'face 'cmacs-speech-ui-ok))
                     ((memq state '(queued downloading verifying extracting))
                      (propertize "⬇" 'face 'cmacs-speech-ui-bar))
                     ((eq state 'failed) (propertize "✗" 'face 'cmacs-speech-ui-bad))
                     (t (propertize "·" 'face 'cmacs-speech-ui-dim)))))
    (insert "    " icon " "
            (propertize (cmacs-speech-ui--pad (plist-get m :id) 52) 'face 'cmacs-speech-ui-model)
            " "
            (propertize (cmacs-speech-ui--pad (symbol-name (plist-get m :backend)) 8)
                        'face 'cmacs-speech-ui-backend)
            (cmacs-speech-ui--pad (string-join (plist-get m :languages) ",") 9)
            (cmacs-speech-ui--pad (cmacs-speech-ui--size (plist-get m :size)) 8)
            (if (plist-get m :local) (propertize "local       " 'face 'cmacs-speech-ui-dim)
              (concat (propertize (cmacs-speech-ui--stars (plist-get m :quality))
                                  'face 'cmacs-speech-ui-ok
                                  'help-echo "quality")
                      " "
                      (propertize (format "⚡%d " (or (plist-get m :speed) 0))
                                  'face 'cmacs-speech-ui-dim 'help-echo "speed")))
            (pcase state
              ((or 'downloading 'queued)
               (let* ((total (cmacs-speech-models-job-total job))
                      ;; The .part on disk is the truth; the job's count
                      ;; is only as fresh as its last progress tick.
                      (part (cmacs-speech-models-job-part job))
                      (bytes (max (cmacs-speech-models-job-bytes job)
                                  (or (and part (file-attribute-size
                                                 (file-attributes part)))
                                      0))))
                 (concat (cmacs-speech-ui--bar (if total (/ (float bytes) total) 0.0) 16)
                         (format " %3d%% %s/s"
                                 (if total (/ (* 100 bytes) total) 0)
                                 (cmacs-speech-ui--size
                                  (round (cmacs-speech-models-job-speed job)))))))
              ('verifying (propertize "verifying sha256…" 'face 'cmacs-speech-ui-bar))
              ('extracting (propertize "unpacking…" 'face 'cmacs-speech-ui-bar))
              ('failed (propertize (cmacs-speech-models-job-error job) 'face 'cmacs-speech-ui-bad))
              (_ (propertize (or (plist-get m :description) "") 'face 'cmacs-speech-ui-dim)))
            "\n")))

(defun cmacs-speech-ui--models ()
  "The Models section, one foldable group per component."
  (cmacs-clawtilla-insert-section
   :type 'section :value 'models :foldable t
   :heading (concat (propertize "Models" 'face 'cmacs-speech-ui-heading)
                    (propertize (format "  %s%s   d download · D delete · a audition · RET use"
                                        (if cmacs-speech-ui--installed-only "[installed] " "")
                                        (if cmacs-speech-ui--filter
                                            (format "[filter: %s] " cmacs-speech-ui--filter) ""))
                                'face 'cmacs-speech-ui-dim))
   :body
   (lambda ()
     (dolist (c cmacs-speech-components)
       (let ((models (cl-remove-if-not
                      (lambda (m)
                        (and (or (not cmacs-speech-ui--installed-only) (plist-get m :installed))
                             (or (null cmacs-speech-ui--filter)
                                 (string-match-p cmacs-speech-ui--filter
                                                 (concat (plist-get m :id) " "
                                                         (or (plist-get m :description) "") " "
                                                         (string-join (plist-get m :languages) " "))))))
                      (cmacs-speech-models :component (car c)))))
         (when models
           (cmacs-clawtilla-insert-section
            :type 'model-group :value (car c) :level 1 :foldable t
            :heading (concat (propertize (nth 1 c) 'face 'bold)
                             (propertize (format "  %d installed / %d"
                                                 (cl-count-if (lambda (m) (plist-get m :installed)) models)
                                                 (length models))
                                         'face 'cmacs-speech-ui-dim))
            :body (lambda ()
                    (dolist (m models)
                      (cmacs-clawtilla-insert-section
                       :type 'model :value (list (car c) (plist-get m :backend) (plist-get m :id))
                       :body (lambda () (cmacs-speech-ui--model-row m)))))))))
     (insert "\n"))))

(defun cmacs-speech-ui--speakers ()
  "The Speakers section."
  (let ((names (and (fboundp 'cmacs-speech-sherpa-speakers) (cmacs-speech-sherpa-speakers))))
    (cmacs-clawtilla-insert-section
     :type 'section :value 'speakers :foldable t
     :heading (concat (propertize "Speakers" 'face 'cmacs-speech-ui-heading)
                      (propertize (format "  %d enrolled   p enroll · P forget" (length names))
                                  'face 'cmacs-speech-ui-dim))
     :body (lambda ()
             (if names
                 (dolist (n names)
                   (cmacs-clawtilla-insert-section
                    :type 'speaker :value n
                    :body (lambda () (insert "    🎙 " n "\n"))))
               (insert (propertize "    nobody yet: p records 8 s of your voice\n"
                                   'face 'cmacs-speech-ui-dim)))
             (insert "\n")))))

(defun cmacs-speech-ui--engines ()
  "The Loaded engines section."
  (let ((rows (and (fboundp 'cmacs-sherpa-loaded) (cmacs-sherpa-loaded))))
    (cmacs-clawtilla-insert-section
     :type 'section :value 'engines :foldable t
     :heading (concat (propertize "Loaded engines" 'face 'cmacs-speech-ui-heading)
                      (propertize (format "  %d sherpa handles   U unload all" (length rows))
                                  'face 'cmacs-speech-ui-dim))
     :body (lambda ()
             (dolist (h rows)
               (insert (format "    #%-4s %-14s %-6s jobs %-4s %s\n"
                               (alist-get :id h) (alist-get :kind h)
                               (if (> (alist-get :pending h) 0) "busy" "idle")
                               (alist-get :jobs h)
                               (abbreviate-file-name (alist-get :model h)))))
             (insert "\n")))))

(defun cmacs-speech-ui--bench-section ()
  "The Bench section."
  (cmacs-clawtilla-insert-section
   :type 'section :value 'bench :foldable t
   :heading (concat (propertize "Bench" 'face 'cmacs-speech-ui-heading)
                    (propertize "  R runs every installed recognizer on the same clip"
                                'face 'cmacs-speech-ui-dim))
   :body (lambda ()
           (if (null cmacs-speech-ui--bench)
               (insert (propertize "    not run yet\n" 'face 'cmacs-speech-ui-dim))
             (insert (propertize (format "    %-8s %-46s %8s %7s %6s  %s\n"
                                         "engine" "model" "seconds" "RTF" "WER" "heard")
                                 'face 'bold))
             (dolist (b cmacs-speech-ui--bench)
               (insert (format "    %-8s %-46s %8s %7s %6s  %s\n"
                               (plist-get b :backend)
                               (cmacs-speech-ui--pad (plist-get b :model) 46)
                               (if (plist-get b :secs) (format "%.2f" (plist-get b :secs)) "…")
                               (if (plist-get b :rtf) (format "%.3f" (plist-get b :rtf)) "")
                               (if (plist-get b :wer) (format "%.0f%%" (* 100 (plist-get b :wer))) "")
                               (propertize (cmacs-speech-ui--pad (or (plist-get b :text)
                                                                     (plist-get b :error) "")
                                                                 60)
                                           'face 'cmacs-speech-ui-dim)))))
           (insert "\n"))))

(defun cmacs-speech-ui--render ()
  "Draw the whole buffer."
  (cmacs-clawtilla-ui-preserving
    (cmacs-speech-ui--header)
    (cmacs-speech-ui--components)
    (cmacs-speech-ui--features)
    (cmacs-speech-ui--models)
    (cmacs-speech-ui--speakers)
    (cmacs-speech-ui--engines)
    (cmacs-speech-ui--bench-section)
    (insert (propertize "? all commands · TAB fold · C-j/C-k sections · gr refresh · q quit\n"
                        'face 'cmacs-speech-ui-dim))))

(defun cmacs-speech-ui--schedule-redraw (&rest _)
  "Redraw soon, coalescing bursts, and only while the buffer is visible."
  (unless cmacs-speech-ui--redraw-timer
    (setq cmacs-speech-ui--redraw-timer
          (run-at-time 0.3 nil
                       (lambda ()
                         (setq cmacs-speech-ui--redraw-timer nil)
                         (when-let* ((buf (get-buffer cmacs-speech-ui-buffer)))
                           (when (get-buffer-window buf t)
                             (with-current-buffer buf (cmacs-speech-ui--render)))))))))

;;;; Row context

(defun cmacs-speech-ui--context ()
  "What point is on: (KIND COMPONENT FEATURE MODEL-PLIST-OR-NIL)."
  (let* ((sec (cmacs-clawtilla-section-at-point))
         (type (plist-get sec :type))
         (val (plist-get sec :value)))
    (pcase type
      ('component (list 'component val nil nil))
      ('feature-component (list 'component (cdr val) (car val) nil))
      ('model (list 'model (nth 0 val) nil
                    (cl-find-if (lambda (m) (and (eq (plist-get m :backend) (nth 1 val))
                                                 (equal (plist-get m :id) (nth 2 val))))
                                (cmacs-speech-models :component (nth 0 val)))))
      ('speaker (list 'speaker nil nil val))
      (_ (list type nil nil nil)))))

(defun cmacs-speech-ui--require-component ()
  "(COMPONENT . FEATURE) at point, or ask."
  (pcase-let ((`(,kind ,c ,f ,_m) (cmacs-speech-ui--context)))
    (if (memq kind '(component model))
        (cons c f)
      (cons (intern (completing-read "Component: "
                                     (mapcar (lambda (x) (symbol-name (car x)))
                                             cmacs-speech-components)
                                     nil t))
            nil))))

;;;; Choosing

(defun cmacs-speech-ui--set (component feature backend model &optional session)
  "Record BACKEND/MODEL for COMPONENT (FEATURE): UI file, or SESSION."
  (let ((plist (append (and model (list :model model)) (and feature (list :feature feature)))))
    (if session
        (apply #'cmacs-speech-session-set component backend plist)
      (when (cmacs-speech-init-owned-p component feature)
        (message "init.el sets %s%s; saved, but init.el wins (o overrides for this session)"
                 component (if feature (format " for %s" feature) "")))
      (apply #'cmacs-speech-ui-set component backend plist))))

(defun cmacs-speech-ui--read-backend (component)
  "Ask for a backend serving COMPONENT (or auto)."
  (let ((choices (cons "auto" (mapcar #'symbol-name (cmacs-speech-backends component)))))
    (intern (completing-read (format "Engine for %s: " component) choices nil t))))

(defun cmacs-speech-ui--read-model (component backend)
  "Ask for an installed BACKEND model serving COMPONENT, with annotations."
  (let* ((models (cmacs-speech-models :component component :backend backend :installed 'only))
         (ids (mapcar (lambda (m) (plist-get m :id)) models))
         (completion-extra-properties
          (list :annotation-function
                (lambda (id)
                  (when-let* ((m (cl-find id models :key (lambda (m) (plist-get m :id))
                                          :test #'equal)))
                    (format "  %s %s  %s"
                            (cmacs-speech-ui--stars (plist-get m :quality))
                            (cmacs-speech-ui--size (plist-get m :size))
                            (or (plist-get m :description) "")))))))
    (if ids
        (completing-read (format "%s model for %s: " backend component) ids nil t)
      (user-error "No %s model for %s is installed; d on one in Models downloads it"
                  backend component))))

(defun cmacs-speech-ui-choose-backend (&optional session)
  "Choose the engine (and model) for the row at point.
With SESSION (prefix arg), override for this session only."
  (interactive "P")
  (pcase-let* ((`(,c . ,f) (cmacs-speech-ui--require-component))
               (backend (cmacs-speech-ui--read-backend c))
               (model (and (not (eq backend 'auto))
                           (cmacs-speech-ui--read-model c backend))))
    (cmacs-speech-ui--set c f backend model session)))

(defun cmacs-speech-ui-choose-model (&optional session)
  "Choose the model for the row at point, keeping its engine."
  (interactive "P")
  (pcase-let* ((`(,c . ,f) (cmacs-speech-ui--require-component))
               (r (cmacs-speech-resolve c f))
               (backend (or (plist-get r :backend) (cmacs-speech-ui--read-backend c))))
    (cmacs-speech-ui--set c f backend (cmacs-speech-ui--read-model c backend) session)))

(defun cmacs-speech-ui-override ()
  "Override the row at point for this session only (init.el rows too)."
  (interactive)
  (cmacs-speech-ui-choose-backend t))

(defun cmacs-speech-ui-unset-at-point ()
  "Drop the session override, else the saved choice, of the row at point."
  (interactive)
  (pcase-let ((`(,c . ,f) (cmacs-speech-ui--require-component)))
    (if (cl-find (cons c f) cmacs-speech--session :key #'cmacs-speech--entry-key :test #'equal)
        (cmacs-speech-session-unset c f)
      (cmacs-speech-ui-unset c f))))

(defun cmacs-speech-ui-act ()
  "RET: choose for a component row; use or download a model row."
  (interactive)
  (pcase-let ((`(,kind ,c ,_f ,m) (cmacs-speech-ui--context)))
    (pcase kind
      ('component (cmacs-speech-ui-choose-backend))
      ('model
       (cond
        ((null m) (user-error "No model here"))
        ((plist-get m :installed)
         (cmacs-speech-ui--set c nil (plist-get m :backend) (plist-get m :id))
         (message "%s now uses %s" c (plist-get m :id)))
        (t (cmacs-speech-ui-download))))
      ('section (cmacs-clawtilla-toggle-fold))
      ('feature (cmacs-clawtilla-toggle-fold))
      ('model-group (cmacs-clawtilla-toggle-fold))
      (_ (user-error "Nothing to do here")))))

;;;; The store

(defun cmacs-speech-ui--model-at-point ()
  "Model plist at point, or signal."
  (or (nth 3 (cmacs-speech-ui--context))
      (user-error "Put point on a model in the Models section")))

(defun cmacs-speech-ui-download ()
  "Download the model at point."
  (interactive)
  (let ((m (cmacs-speech-ui--model-at-point)))
    (when (plist-get m :local) (user-error "%s is a local model" (plist-get m :id)))
    (cmacs-speech-models-download m)
    (message "Downloading %s (%s)…" (plist-get m :id) (cmacs-speech-ui--size (plist-get m :size)))))

(defun cmacs-speech-ui-delete ()
  "Move the installed model at point to the trash."
  (interactive)
  (let ((m (cmacs-speech-ui--model-at-point)))
    (unless (plist-get m :installed) (user-error "Not installed"))
    (when (yes-or-no-p (format "Move %s to the trash? " (plist-get m :id)))
      (message "Trashed %s" (cmacs-speech-models-delete (plist-get m :backend) (plist-get m :id))))))

(defun cmacs-speech-ui-cancel ()
  "Cancel the download at point."
  (interactive)
  (cmacs-speech-models-cancel (plist-get (cmacs-speech-ui--model-at-point) :id)))

(defun cmacs-speech-ui-filter (regexp)
  "Show only models matching REGEXP (id, description, language); empty clears."
  (interactive (list (read-string "Filter models (regexp, empty for all): "
                                  cmacs-speech-ui--filter)))
  (setq cmacs-speech-ui--filter (and (not (string-empty-p regexp)) regexp))
  (cmacs-speech-ui--render))

(defun cmacs-speech-ui-toggle-installed ()
  "Toggle showing only installed models."
  (interactive)
  (setq cmacs-speech-ui--installed-only (not cmacs-speech-ui--installed-only))
  (cmacs-speech-ui--render))

;;;; Trying things (no microphone needed)

(defun cmacs-speech-ui--note (key text)
  "Show TEXT beside the row KEY."
  (when-let* ((buf (get-buffer cmacs-speech-ui-buffer)))
    (with-current-buffer buf
      (setf (alist-get key cmacs-speech-ui--notes nil nil #'equal) text)
      (cmacs-speech-ui--render))))

(defun cmacs-speech-ui--synth-clip (callback)
  "Synthesise `cmacs-speech-ui-test-sentence'; CALLBACK gets (PCM16K . TEXT).
The clip is the round-trip test input: a recognizer that hears what the
TTS said needs no microphone."
  (cmacs-speech-synthesize
   cmacs-speech-ui-test-sentence
   (lambda (r)
     (if (assq :error r)
         (funcall callback (cons :error (alist-get :error r)))
       (let ((pcm (alist-get :pcm r)) (rate (alist-get :sample-rate r)))
         (funcall callback
                  (cons (if (= rate 16000) pcm
                          (if (fboundp 'cmacs-whisper-pcm-resample)
                              (cmacs-whisper-pcm-resample pcm rate 16000)
                            pcm))
                        cmacs-speech-ui-test-sentence)))))))

(defun cmacs-speech-ui-try ()
  "Try the row at point: speak, or say something and listen to it."
  (interactive)
  (pcase-let* ((`(,c . ,f) (cmacs-speech-ui--require-component))
               (key (if f (cons f c) c))
               (t0 (float-time)))
    (pcase c
      ('tts
       (cmacs-speech-ui--note key "speaking…")
       (cmacs-speech-speak cmacs-speech-ui-test-sentence :feature f)
       (cmacs-speech-ui--note key (format "spoke (%.2fs to first audio)" (- (float-time) t0))))
      ((or 'stt 'stt-live)
       (cmacs-speech-ui--note key "synthesising a test clip…")
       (cmacs-speech-ui--synth-clip
        (lambda (clip)
          (if (eq (car clip) :error)
              (cmacs-speech-ui--note key (format "needs a TTS voice: %s" (cdr clip)))
            (let ((t1 (float-time)))
              (cmacs-speech-transcribe
               (car clip)
               (lambda (r)
                 (cmacs-speech-ui--note
                  key (if (assq :error r) (format "✗ %s" (alist-get :error r))
                        (format "heard “%s” in %.2fs (RTF %.2f)"
                                (string-trim (alist-get :text r))
                                (- (float-time) t1)
                                (/ (- (float-time) t1)
                                   (/ (length (car clip)) 32000.0))))))
               :component c :feature f))))))
      ('stt-stream
       (cmacs-speech-ui--synth-clip
        (lambda (clip)
          (let* ((partials 0)
                 (s (cmacs-speech-stream-open
                     :feature f
                     :on-partial (lambda (p) (cl-incf partials)
                                   (message "partial: %s" p))
                     :on-final (lambda (fin)
                                 (cmacs-speech-ui--note
                                  key (format "%d partials, final “%s”" partials
                                              (alist-get :text fin)))))))
            (if (not s)
                (cmacs-speech-ui--note key "no streaming engine")
              (let ((pcm (car clip)) (i 0))
                (while (< i (length pcm))
                  (cmacs-speech-stream-feed s (substring pcm i (min (length pcm) (+ i 3200))))
                  (setq i (+ i 3200))))
              (cmacs-speech-stream-finish s)
              (run-at-time 10 nil #'cmacs-speech-stream-close s))))))
      ('wake
       (let ((cmacs-speech-ui-test-sentence "Jarvis, what time is it?"))
         (cmacs-speech-ui--synth-clip
          (lambda (clip)
            (let ((w (cmacs-speech-wake-open
                      '("jarvis")
                      (lambda (p) (cmacs-speech-ui--note
                                   key (format "fired on “%s” after %.2fs" p (- (float-time) t0))))
                      :feature f)))
              (if (not w)
                  (cmacs-speech-ui--note key "no keyword spotter")
                (cmacs-speech-ui--note key "listening to a synthetic “Jarvis…”")
                ;; The spotter loads asynchronously; give it a moment.
                (run-at-time 1.5 nil
                             (lambda ()
                               (cmacs-speech-wake-feed w (car clip))
                               (cmacs-speech-wake-feed w (make-string 32000 0 t))))
                (run-at-time 8 nil #'cmacs-speech-wake-close w)))))))
      (_ (cmacs-speech-ui--note key "x tries stt, stt-live, stt-stream, wake and tts")))))

(defun cmacs-speech-ui-audition ()
  "Hear the TTS model at point: itself when installed, else its sample."
  (interactive)
  (let ((m (cmacs-speech-ui--model-at-point)))
    (unless (memq 'tts (plist-get m :components)) (user-error "Not a voice"))
    (cond
     ((plist-get m :installed)
      (cmacs-speech-speak cmacs-speech-ui-test-sentence :voice (plist-get m :id)
                          :feature nil))
     ((plist-get m :sample)
      (message "Fetching a sample of %s…" (plist-get m :id))
      (let ((tmp (make-temp-file "voice-sample" nil ".mp3")))
        (make-process
         :name "speech-sample" :noquery t
         :command (list cmacs-speech-models-curl-program "-sfL" "-o" tmp (plist-get m :sample))
         :sentinel (lambda (p _)
                     (unless (process-live-p p)
                       (cmacs-speech-file-pcm
                        tmp (lambda (got)
                              (delete-file tmp)
                              (if (eq (car got) :error)
                                  (message "Sample: %s" (cdr got))
                                (cmacs-speech-play-pcm (car got) (cdr got))))))))))
     (t (user-error "No sample for %s; download it to hear it" (plist-get m :id))))))

;;;; Bench

(defun cmacs-speech-ui--wer (ref hyp)
  "Word error rate of HYP against REF (case and punctuation ignored)."
  (let* ((norm (lambda (s) (split-string (downcase (replace-regexp-in-string
                                                    "[^[:alnum:] ']" " " (or s "")))
                                         nil t)))
         (r (vconcat (funcall norm ref))) (h (vconcat (funcall norm hyp)))
         (prev (number-sequence 0 (length h))))
    (dotimes (i (length r))
      (let ((cur (list (1+ i))))
        (dotimes (j (length h))
          (push (min (1+ (car cur)) (1+ (nth (1+ j) prev))
                     (+ (nth j prev) (if (equal (aref r i) (aref h j)) 0 1)))
                cur))
        (setq prev (nreverse cur))))
    (if (zerop (length r)) 0.0 (/ (float (car (last prev))) (length r)))))

(defun cmacs-speech-ui-bench ()
  "Run every installed recognizer on one synthetic clip; rank them."
  (interactive)
  (cmacs-speech-ui--synth-clip
   (lambda (clip)
     (if (eq (car clip) :error)
         (user-error "The bench speaks its own test clip and needs a TTS voice")
       (let* ((secs (/ (length (car clip)) 32000.0))
              (runs (cl-loop for b in (cmacs-speech-backends 'stt)
                             append (mapcar (lambda (id) (list :backend b :model id))
                                            (cmacs-speech-backend-models b 'stt)))))
         (setq cmacs-speech-ui--bench runs)
         (cmacs-speech-ui--schedule-redraw)
         ;; One at a time, so the timings do not fight over the CPU.
         (cl-labels
             ((next (rest)
                (when rest
                  (let ((run (car rest)) (t0 (float-time)))
                    (cmacs-speech-transcribe
                     (car clip)
                     (lambda (r)
                       (let ((dt (- (float-time) t0)))
                         (if (assq :error r)
                             (plist-put run :error (alist-get :error r))
                           (plist-put run :secs dt)
                           (plist-put run :rtf (/ dt secs))
                           (plist-put run :text (string-trim (alist-get :text r)))
                           (plist-put run :wer (cmacs-speech-ui--wer (cdr clip) (alist-get :text r)))))
                       (setq cmacs-speech-ui--bench
                             (sort (copy-sequence cmacs-speech-ui--bench)
                                   (lambda (a b) (< (or (plist-get a :wer) 9) (or (plist-get b :wer) 9)))))
                       (cmacs-speech-ui--schedule-redraw)
                       (next (cdr rest)))
                     :component 'stt :backend (plist-get run :backend)
                     :model (plist-get run :model))))))
           (next runs)))))))

;;;; Speakers

(defun cmacs-speech-ui-enroll (name &optional file)
  "Enroll NAME: record 8 s from the mic, or (prefix arg) use FILE."
  (interactive
   (list (read-string "Speaker name: " user-login-name)
         (and current-prefix-arg (read-file-name "Audio file: "))))
  (let ((done (lambda (r)
                (message (if (assq :error r) "Enroll failed: %s" "Enrolled %s")
                         (or (alist-get :error r) name))
                (cmacs-speech-ui--schedule-redraw))))
    (if file
        (cmacs-speech-file-pcm file (lambda (got)
                                      (if (eq (car got) :error) (funcall done (list got))
                                        (cmacs-speech-enroll-speaker name (car got) done))))
      (require 'cmacs-voice)
      (cmacs-voice-ptt-start 'speech-enroll)
      (message "Recording %s for 8 seconds: talk naturally…" name)
      (run-at-time 8 nil
                   (lambda ()
                     (let ((pcm (cmacs-voice-ptt-stop 'speech-enroll)))
                       (cmacs-speech-enroll-speaker name pcm done)))))))

(defun cmacs-speech-ui-forget ()
  "Forget the speaker at point."
  (interactive)
  (let ((name (or (nth 3 (cmacs-speech-ui--context))
                  (completing-read "Forget speaker: " (cmacs-speech-sherpa-speakers) nil t))))
    (when (yes-or-no-p (format "Forget %s's voiceprint? " name))
      (cmacs-speech-sherpa-forget-speaker name)
      (cmacs-speech-ui--render))))

(defun cmacs-speech-ui-unload ()
  "Unload every sherpa model (frees memory; reloads on next use)."
  (interactive)
  (cmacs-speech-sherpa-unload-all)
  (cmacs-speech-ui--render))

;;;; Export

(defun cmacs-speech-ui-export ()
  "Show the buffer's choices as `cmacs-speech-set' forms for init.el."
  (interactive)
  (cmacs-speech--load-state)
  (with-current-buffer (get-buffer-create "*cmacs speech init.el*")
    (erase-buffer)
    (insert ";; Speech choices from M-x cmacs-speech, as init.el forms.\n"
            ";; Paste into init.el: they will then win over the settings buffer.\n\n")
    (dolist (e cmacs-speech--ui)
      (insert (format "%S\n" `(cmacs-speech-set ',(car e) ',(cadr e) ,@(mapcar (lambda (x) (if (and (symbolp x) (not (keywordp x))) `',x x)) (cddr e))))))
    (emacs-lisp-mode)
    (goto-char (point-min))
    (pop-to-buffer (current-buffer))))

;;;; Mode

(defvar cmacs-speech-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "RET") #'cmacs-speech-ui-act)
    (define-key map "s" #'cmacs-speech-ui-choose-backend)
    (define-key map "m" #'cmacs-speech-ui-choose-model)
    (define-key map "o" #'cmacs-speech-ui-override)
    (define-key map "u" #'cmacs-speech-ui-unset-at-point)
    (define-key map "d" #'cmacs-speech-ui-download)
    (define-key map "D" #'cmacs-speech-ui-delete)
    (define-key map "c" #'cmacs-speech-ui-cancel)
    (define-key map "x" #'cmacs-speech-ui-try)
    (define-key map "a" #'cmacs-speech-ui-audition)
    (define-key map "=" #'cmacs-speech-ui-filter)
    (define-key map "I" #'cmacs-speech-ui-toggle-installed)
    (define-key map "R" #'cmacs-speech-ui-bench)
    (define-key map "p" #'cmacs-speech-ui-enroll)
    (define-key map "P" #'cmacs-speech-ui-forget)
    (define-key map "U" #'cmacs-speech-ui-unload)
    (define-key map "i" #'cmacs-speech-ui-export)
    (define-key map "?" #'cmacs-speech-ui-dispatch)
    map)
  "Keys of the speech settings buffer.  None is an Evil motion.")

(define-derived-mode cmacs-speech-ui-mode special-mode "Speech"
  "The speech settings buffer.  \\<cmacs-speech-ui-mode-map>
\\[cmacs-speech-ui-act] chooses (component rows) or uses/downloads (model rows);
\\[cmacs-speech-ui-choose-backend] engine, \\[cmacs-speech-ui-choose-model] model,
\\[cmacs-speech-ui-override] session override, \\[cmacs-speech-ui-unset-at-point] unset;
\\[cmacs-speech-ui-download] download, \\[cmacs-speech-ui-delete] delete,
\\[cmacs-speech-ui-cancel] cancel, \\[cmacs-speech-ui-audition] audition;
\\[cmacs-speech-ui-try] try the row, \\[cmacs-speech-ui-bench] bench recognizers;
\\[cmacs-speech-ui-enroll] enroll a speaker; \\[cmacs-speech-ui-export] export to init.el;
\\[cmacs-speech-ui-dispatch] lists everything.

\\{cmacs-speech-ui-mode-map}"
  (setq-local cmacs-clawtilla-refresh-function #'cmacs-speech-ui--render)
  (setq-local truncate-lines t)
  (setq-local cmacs-clawtilla-ui--folded
              (mapcar (lambda (s) (cmacs-clawtilla-ui--identity 'section s))
                      cmacs-speech-ui-folded))
  (add-hook 'cmacs-speech-config-changed-hook #'cmacs-speech-ui--schedule-redraw)
  (add-hook 'cmacs-speech-model-progress-functions #'cmacs-speech-ui--schedule-redraw))

(cmacs-clawtilla-setup-evil cmacs-speech-ui-mode-map 'cmacs-speech-ui-mode)

;;;###autoload (autoload 'cmacs-speech-ui-dispatch "cmacs-speech-ui" nil t)
(transient-define-prefix cmacs-speech-ui-dispatch ()
  "Every command of the speech settings buffer."
  [["Choose"
    ("RET" "Choose / use / download" cmacs-speech-ui-act)
    ("s" "Engine" cmacs-speech-ui-choose-backend)
    ("m" "Model" cmacs-speech-ui-choose-model)
    ("o" "Override (session only)" cmacs-speech-ui-override)
    ("u" "Unset" cmacs-speech-ui-unset-at-point)
    ("i" "Export to init.el" cmacs-speech-ui-export)]
   ["Models"
    ("d" "Download" cmacs-speech-ui-download)
    ("D" "Delete (trash)" cmacs-speech-ui-delete)
    ("c" "Cancel download" cmacs-speech-ui-cancel)
    ("a" "Audition voice" cmacs-speech-ui-audition)
    ("=" "Filter" cmacs-speech-ui-filter)
    ("I" "Installed only" cmacs-speech-ui-toggle-installed)]
   ["Try"
    ("x" "Try this row" cmacs-speech-ui-try)
    ("R" "Bench recognizers" cmacs-speech-ui-bench)
    ("p" "Enroll speaker" cmacs-speech-ui-enroll)
    ("P" "Forget speaker" cmacs-speech-ui-forget)
    ("U" "Unload engines" cmacs-speech-ui-unload)]])

;;;###autoload
(defun cmacs-speech ()
  "Open the speech settings: engines, models, downloads, tests."
  (interactive)
  (let ((buf (get-buffer-create cmacs-speech-ui-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-speech-ui-mode)
        (cmacs-speech-ui-mode))
      (cmacs-speech-ui--render)
      (goto-char (point-min)))
    (pop-to-buffer-same-window buf)))

;;;###autoload
(with-eval-after-load 'cmacs-audio
  (when (boundp 'cmacs-voice-map)
    (define-key cmacs-voice-map "," #'cmacs-speech)))

(provide 'cmacs-speech-ui)
;;; cmacs-speech-ui.el ends here
