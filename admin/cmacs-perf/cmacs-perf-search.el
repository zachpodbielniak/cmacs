;;; cmacs-perf-search.el --- cmacs-perf: buffer search workloads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; Copyright (C) 2026 Eval Exec and the neomacs contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The search primitives in isolation: six warmed literal / regexp /
;; POSIX searches in each direction over a tiny multibyte buffer, and a
;; bounded regexp search that fails at the same short bound while an
;; edit far away keeps moving the gap in a buffer of up to 8 MiB.
;; Ported from neomacs-perf's search-shape.el and bounded-search.el
;; (GPL-3.0-or-later), with the invariants their Rust adapters
;; (src/harness/scenarios/search_shape.rs and bounded_search.rs)
;; enforced on the result moved into the CHECK functions.  The
;; workloads and their invariants are theirs, the registration form is
;; cmacs-perf's.
;;
;; first-hot-loop.el is deliberately not ported.  It times the FIRST
;; call of freshly byte-compiled closures, to catch neomacs's
;; interpreter heat-up and on-stack-replacement JIT.  GNU Emacs has no
;; tiers: a first call executes the same bytecode as the millionth, so
;; the row would only re-measure lexical-loop (cmacs-perf-vm.el) plus
;; some cold instruction cache.  It cannot measure native compilation
;; either -- closures `byte-compile'd at run time stay bytecode even
;; when this file is native-compiled.
;;
;; As in cmacs-perf-vm.el, the driver compiles this file before the run
;; and every CHECK refuses a loop that ran interpreted.

;;; Code:

(require 'cmacs-perf)

(defun cmacs-perf-search--utf8-checksum ()
  "Return the SHA-256 of the current buffer's text encoded as UTF-8.
The encoding is explicit so the expected value can be computed from a
string independently of the ambient coding system."
  (secure-hash 'sha256
               (encode-coding-string
                (buffer-substring-no-properties (point-min) (point-max))
                'utf-8-unix t)))

(defun cmacs-perf-search--buffer (name)
  "Return a fresh, undo-free, multibyte buffer called NAME."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (buffer-disable-undo)
      (erase-buffer)
      (set-buffer-multibyte t))
    buffer))

;;;; search-shape: one warmed search primitive per workload.

(defconst cmacs-perf-search--text "éab abc"
  "The search-shape buffer: one two-byte character, then ASCII.
Seven characters, eight bytes, so every position after the first is a
character/byte conversion away from its byte offset.")

(defconst cmacs-perf-search--shape-cases
  '(("search-posix-forward" posix-search-forward "\\(ab\\)" 1 8 4
     (2 4 2 4 t))
    ("search-posix-backward" posix-search-backward "\\(ab\\)" 8 1 5
     (5 7 5 7 t))
    ("search-regexp-backward" re-search-backward "\\(ab\\)" 8 1 5
     (5 7 5 7 t))
    ("search-regexp-forward" re-search-forward "\\(ab\\)" 1 8 4
     (2 4 2 4 t))
    ("search-literal-forward" search-forward "ab" 1 8 4 (2 4 t))
    ("search-literal-backward" search-backward "ab" 8 1 5 (5 7 t)))
  "Search-shape workloads: (NAME FUNCTION PATTERN START BOUND ANSWER DATA).
Each iteration moves to START and calls (FUNCTION PATTERN BOUND t).
ANSWER is both the return value and point afterwards; DATA is
`match-data' with integers, its trailing buffer replaced by t when it
is the searched buffer.")

(defun cmacs-perf-search--shape-loop (n function pattern start bound)
  "Search N times with FUNCTION for PATTERN from START up to BOUND.
Return the last search's value.  The loop overhead (one `goto-char'
and one funcall per iteration) is part of every search-shape number."
  (let ((answer nil))
    (dotimes (_ n)
      (goto-char start)
      (setq answer (funcall function pattern bound t)))
    answer))

(defun cmacs-perf-search--match-data ()
  "Return `match-data' as integers, with its buffer replaced by a boolean.
The boolean is non-nil when the match was in the current buffer."
  (mapcar (lambda (value)
            (if (bufferp value) (eq value (current-buffer)) value))
          (match-data t)))

(defun cmacs-perf-search--shape-failures (case answer)
  "Return the failures of search-shape CASE given the search's ANSWER.
Call in the search buffer, right after the search."
  (let ((failures nil)
        (expected (nth 5 case)))
    (setq failures (cmacs-perf-expect failures "search result"
                                      answer expected))
    (setq failures (cmacs-perf-expect failures "point" (point) expected))
    (setq failures (cmacs-perf-expect failures "match data"
                                      (cmacs-perf-search--match-data)
                                      (nth 6 case)))
    (cmacs-perf-expect failures "buffer contents" (buffer-string)
                       cmacs-perf-search--text)))

(defun cmacs-perf-search--shape-setup (case)
  "Return the SETUP function for search-shape CASE.
The warm-up is neomacs's: 2,000 single searches and 20 batches of 100,
each one validated, so a primitive that only goes wrong once warm is
caught before it is timed."
  (lambda (_iterations)
    (let ((buffer (cmacs-perf-search--buffer
                   (format " *cmacs-perf-%s*" (car case))))
          (arguments (list (nth 1 case) (nth 2 case) (nth 3 case)
                           (nth 4 case)))
          (validations 0))
      (with-current-buffer buffer
        (insert cmacs-perf-search--text)
        (let ((case-fold-search nil))
          (set-match-data '(7 9))
          (dolist (shape '((2000 . 1) (20 . 100)))
            (dotimes (_ (car shape))
              (let ((failures (cmacs-perf-search--shape-failures
                               case (apply #'cmacs-perf-search--shape-loop
                                           (cdr shape) arguments))))
                (when failures
                  (error "warm-up search went wrong: %s"
                         (mapconcat #'identity failures "; ")))
                (setq validations (1+ validations)))))))
      (list :buffer buffer :arguments arguments :validations validations))))

(defun cmacs-perf-search--shape-body (state iterations)
  "Run the search of STATE ITERATIONS times; return its last answer."
  (with-current-buffer (plist-get state :buffer)
    (let ((case-fold-search nil))
      `((answer . ,(apply #'cmacs-perf-search--shape-loop iterations
                          (plist-get state :arguments)))))))

(defun cmacs-perf-search--shape-check (case)
  "Return the CHECK function for search-shape CASE."
  (lambda (state metrics)
    (let ((failures nil))
      (unless (cmacs-perf-compiled-p 'cmacs-perf-search--shape-loop)
        (push "search loop is not compiled" failures))
      (setq failures (cmacs-perf-expect failures "warm-up validations"
                                        (plist-get state :validations)
                                        2020))
      (with-current-buffer (plist-get state :buffer)
        (setq failures (append (cmacs-perf-search--shape-failures
                                case (alist-get 'answer metrics))
                               failures))
        (setq failures (cmacs-perf-expect failures "buffer size"
                                          (buffer-size) 7))
        (setq failures (cmacs-perf-expect failures "buffer bytes"
                                          (string-bytes (buffer-string)) 8))
        (cmacs-perf-expect failures "multibyte"
                           enable-multibyte-characters t)))))

(dolist (case cmacs-perf-search--shape-cases)
  (cmacs-perf-define
   (car case)
   :doc (format "warmed `%s' over multibyte text, with loop overhead"
                (nth 1 case))
   :iterations 2000000
   :setup (cmacs-perf-search--shape-setup case)
   :body #'cmacs-perf-search--shape-body
   :check (cmacs-perf-search--shape-check case)))

;;;; bounded-search: a failing bounded search after a distant edit.

(defconst cmacs-perf-search--bounded-cases
  `(("bounded-search-edit-small" 1024 t t
     "bounded search after distant edits in a 1 KiB multibyte buffer")
    ("bounded-search-edit-large" ,(* 8 1024 1024) t t
     "bounded search after distant edits in an 8 MiB multibyte buffer")
    ("bounded-search-edit-only" ,(* 8 1024 1024) t nil
     "distant edit control in an 8 MiB multibyte buffer")
    ("bounded-search-no-edit" ,(* 8 1024 1024) nil t
     "bounded search without edits in an 8 MiB multibyte buffer"))
  "Bounded-search workloads: (NAME SIZE EDIT SEARCH DOC).
SIZE is the buffer length in characters.  EDIT inserts and deletes one
character in the middle every iteration; SEARCH runs the bounded
search.  The edit-only and no-edit rows split the edit-small/large
cost into its two halves.")

(defun cmacs-perf-search--bounded-text (size)
  "Return the bounded-search buffer text of SIZE characters.
Eight ASCII characters, one three-byte character exactly at the search
bound (position 9), then ASCII to SIZE."
  (concat "aaaaaaaa中" (make-string (- size 9) ?a)))

(defun cmacs-perf-search--bounded-loop (iterations edit-at edit search)
  "Run ITERATIONS bounded-search steps; return (COMPLETED FAILED).
With EDIT, insert and delete one character at EDIT-AT first, which
moves the gap far from the search.  With SEARCH, look for \"z\" from
position 1 bounded at 9, which must fail without moving point -- the
bound has to keep the search from ever scanning the rest of the
buffer, however large it is."
  (let ((completed 0) (failures 0) (case-fold-search nil))
    (dotimes (_ iterations)
      (when edit
        (goto-char edit-at)
        (insert "a")
        (delete-char -1))
      (goto-char 1)
      (when search
        (if (re-search-forward "z" 9 t)
            (error "unexpected bounded search match")
          (setq failures (1+ failures))))
      (unless (= (point) 1)
        (error "bounded failure moved point"))
      (setq completed (1+ completed)))
    (list completed failures)))

(defun cmacs-perf-search--bounded-setup (case)
  "Return the SETUP function for bounded-search CASE.
It builds the buffer, runs 100 untimed steps, records the content
checksum and leaves match data at (7 9): a failing search must not
touch it."
  (lambda (_iterations)
    (pcase-let* ((`(,name ,size ,edit ,search ,_doc) case)
                 (buffer (cmacs-perf-search--buffer
                          (format " *cmacs-perf-%s*" name)))
                 (edit-at (1+ (/ size 2))))
      (with-current-buffer buffer
        (insert (cmacs-perf-search--bounded-text size))
        (cmacs-perf-search--bounded-loop 100 edit-at edit search)
        (set-match-data '(7 9))
        (list :buffer buffer :edit-at edit-at :edit edit :search search
              :size size
              :initial-checksum (cmacs-perf-search--utf8-checksum))))))

(defun cmacs-perf-search--bounded-body (state iterations)
  "Run ITERATIONS bounded-search steps over the buffer of STATE."
  (with-current-buffer (plist-get state :buffer)
    (let ((result (cmacs-perf-search--bounded-loop
                   iterations (plist-get state :edit-at)
                   (plist-get state :edit) (plist-get state :search))))
      `((requested . ,iterations)
        (completed . ,(nth 0 result))
        (failed_searches . ,(nth 1 result))
        (point . ,(point))
        (match_data . ,(match-data t))))))

(defun cmacs-perf-search--bounded-check (state metrics)
  "Return the bounded-search invariants that failed, given STATE and METRICS.
Every step completed, every search failed, the buffer is byte for byte
what was built (checked against a checksum computed from the string,
not from the buffer), point is back at 1 and match data is untouched."
  (let* ((size (plist-get state :size))
         (expected (secure-hash 'sha256
                                (encode-coding-string
                                 (cmacs-perf-search--bounded-text size)
                                 'utf-8-unix t)))
         (failures nil))
    (unless (cmacs-perf-compiled-p 'cmacs-perf-search--bounded-loop)
      (push "bounded-search loop is not compiled" failures))
    (setq failures (cmacs-perf-expect failures "completed steps"
                                      (alist-get 'completed metrics)
                                      (alist-get 'requested metrics)))
    (setq failures (cmacs-perf-expect failures "failed searches"
                                      (alist-get 'failed_searches metrics)
                                      (if (plist-get state :search)
                                          (alist-get 'completed metrics)
                                        0)))
    (setq failures (cmacs-perf-expect failures "point"
                                      (alist-get 'point metrics) 1))
    (setq failures (cmacs-perf-expect failures "match data"
                                      (alist-get 'match_data metrics)
                                      '(7 9)))
    (setq failures (cmacs-perf-expect failures "initial content"
                                      (plist-get state :initial-checksum)
                                      expected))
    (with-current-buffer (plist-get state :buffer)
      (setq failures (cmacs-perf-expect failures "buffer size"
                                        (buffer-size) size))
      ;; The one three-byte character makes the text two bytes longer
      ;; than it is characters.
      (setq failures (cmacs-perf-expect failures "buffer bytes"
                                        (1- (position-bytes (point-max)))
                                        (+ size 2)))
      (setq failures (cmacs-perf-expect failures "multibyte"
                                        enable-multibyte-characters t))
      (cmacs-perf-expect failures "final content"
                         (cmacs-perf-search--utf8-checksum) expected))))

(defun cmacs-perf-search--bounded-define (case)
  "Register the bounded-search workload described by CASE."
  (cmacs-perf-define
   (nth 0 case)
   :doc (nth 4 case)
   :iterations 10000
   :setup (cmacs-perf-search--bounded-setup case)
   :body #'cmacs-perf-search--bounded-body
   :check #'cmacs-perf-search--bounded-check))

(mapc #'cmacs-perf-search--bounded-define cmacs-perf-search--bounded-cases)

(provide 'cmacs-perf-search)

;;; cmacs-perf-search.el ends here
