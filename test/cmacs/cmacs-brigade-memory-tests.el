;;; cmacs-brigade-memory-tests.el --- Tests for the memory index  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The chunker and the index are tested without touching a model: both
;; take and return plain data, so an embedding service is only needed for
;; the end-to-end path, which is not something a test suite should
;; depend on.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-memory nil 'noerror)

(defun cmacs-brigade-memory-tests--available-p ()
  (and (featurep 'cmacs-brigade-memory)
       (fboundp 'cmacs-brigade-chunk-string)))

(defmacro cmacs-brigade-memory-tests--with-index (dim &rest body)
  "Run BODY with DIR bound to a fresh empty index directory of DIM dims."
  (declare (indent 1))
  `(let ((dir (make-temp-file "cmacs-brigade-ix" t))
         (dims ,dim))
     (ignore dims)
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))


;;;; Chunker

(ert-deftest cmacs-brigade-chunk-empty-and-trivial ()
  "Degenerate documents produce no chunks rather than empty ones."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (should (null (cmacs-brigade-chunk-string "" "x.org")))
  (should (null (cmacs-brigade-chunk-string "\n\n\n   \n" "x.org")))
  ;; A file with no headlines at all is still indexable -- plenty of
  ;; notes are a single wall of prose.
  (should (= 1 (length (cmacs-brigade-chunk-string "just prose\n" "x.org")))))

(ert-deftest cmacs-brigade-chunk-breadcrumbs-follow-content ()
  "A chunk is labelled with where its content started, not where the
scan ended.

These differ whenever sibling sections are packed together, which is the
normal case for an outline of short entries -- and a chunk labelled with
the wrong section is worse than one labelled with none, because the
label is embedded."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let* ((pad (make-string 300 ?x))
         (doc (concat "* Alpha\n" pad "\n\n** Beta\n" pad "\n\n* Gamma\n" pad "\n"))
         (chunks (cmacs-brigade-chunk-string doc "n/t.org" 120 20))
         (heads (mapcar (lambda (c) (plist-get c :heading)) chunks)))
    (should (> (length chunks) 3))
    (should (cl-some (lambda (h) (equal h "n/t.org > Alpha")) heads))
    ;; nesting is preserved ...
    (should (cl-some (lambda (h) (equal h "n/t.org > Alpha > Beta")) heads))
    ;; ... and popped again at the next level-1 headline, rather than
    ;; accumulating "Alpha > Beta > Gamma"
    (should (cl-some (lambda (h) (equal h "n/t.org > Gamma")) heads))
    (should-not (cl-some (lambda (h) (string-search "Beta > Gamma" h)) heads))))

(ert-deftest cmacs-brigade-chunk-skips-drawers ()
  "LOGBOOK and PROPERTIES drawers never reach the index.

Clock lines and IDs are not prose; embedding them dilutes the section
they sit in and they match nothing anyone would ask in words."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let* ((doc "* H\n:PROPERTIES:\n:ID: deadbeef\n:END:\n:LOGBOOK:\nCLOCK: [2026-01-01]\n:END:\nreal prose\n")
         (chunks (cmacs-brigade-chunk-string doc "x.org"))
         (all (mapconcat (lambda (c) (plist-get c :text)) chunks "\n")))
    (should (string-search "real prose" all))
    (should-not (string-search "deadbeef" all))
    (should-not (string-search "CLOCK:" all))))

(ert-deftest cmacs-brigade-chunk-drops-long-src-blocks ()
  "Long source blocks are dropped; short ones stay with their prose.

Code embedded into a prose space makes every query about \"the parser\"
return the parser's own source."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let* ((long (mapconcat (lambda (i) (format "line %d" i))
                          (number-sequence 1 40) "\n"))
         (doc (concat "* H\nprose\n#+begin_src c\n" long "\n#+end_src\nmore\n"))
         (text (mapconcat (lambda (c) (plist-get c :text))
                          (cmacs-brigade-chunk-string doc "x.org") "\n")))
    (should (string-search "prose" text))
    (should-not (string-search "line 30" text)))
  (let* ((doc "* H\nprose\n#+begin_src c\nint x;\n#+end_src\nmore\n")
         (text (mapconcat (lambda (c) (plist-get c :text))
                          (cmacs-brigade-chunk-string doc "x.org") "\n")))
    (should (string-search "int x;" text))))

(ert-deftest cmacs-brigade-chunk-splits-oversized-on-utf8-boundary ()
  "A hard split never lands mid-character.

An invalid UTF-8 sequence would be embedded as replacement characters,
which silently poisons the vector for that chunk."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let* ((doc (concat "* H\n" (apply #'concat (make-list 200 "日本語テキスト "))))
         (chunks (cmacs-brigade-chunk-string doc "x.org" 100 20)))
    (should (> (length chunks) 1))
    (dolist (c chunks)
      ;; If a chunk were cut mid-character the decoder would have
      ;; produced U+FFFD.
      (should-not (string-search "�" (plist-get c :text))))))

(ert-deftest cmacs-brigade-chunk-offsets-are-monotonic ()
  "Chunk offsets advance through the document."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let* ((pad (make-string 400 ?y))
         (doc (concat "* A\n" pad "\n* B\n" pad "\n"))
         (chunks (cmacs-brigade-chunk-string doc "x.org" 150 20))
         (last -1))
    (dolist (c chunks)
      (should (>= (plist-get c :start) last))
      (setq last (plist-get c :start)))))


;;;; Index

(ert-deftest cmacs-brigade-index-round-trip ()
  "Vectors written come back with the right cosine ranking."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 8
    (let ((w (cmacs-brigade-index-writer-new dir 8)))
      (cmacs-brigade-index-writer-add w [1.0 0 0 0 0 0 0 0])
      (cmacs-brigade-index-writer-add w [0 1.0 0 0 0 0 0 0])
      (cmacs-brigade-index-writer-add w [0.7 0.7 0 0 0 0 0 0])
      (should (= 3 (cmacs-brigade-index-writer-commit w))))
    (let* ((h (cmacs-brigade-index-open dir))
           (info (cmacs-brigade-index-info h))
           (hits (cmacs-brigade-index-search h [1.0 0 0 0 0 0 0 0] 3)))
      (should (= 3 (plist-get info :count)))
      (should (= 8 (plist-get info :dim)))
      (should (= 0 (car (nth 0 hits))))
      (should (= 2 (car (nth 1 hits))))
      (should (= 1 (car (nth 2 hits))))
      ;; identical unit vectors score 1, orthogonal ones 0
      (should (< (abs (- 1.0 (cdr (nth 0 hits)))) 0.01))
      (should (< (abs (cdr (nth 2 hits))) 0.01))
      (cmacs-brigade-index-close h))))

(ert-deftest cmacs-brigade-index-normalises-on-write ()
  "Magnitude is discarded, so only direction affects ranking.

Search is a plain dot product precisely because rows are unit vectors;
if that stopped being true, a long document would outrank a relevant
one purely for being long."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w [1.0 0 0 0])
      (cmacs-brigade-index-writer-add w [50.0 0 0 0])   ; same direction
      (cmacs-brigade-index-writer-commit w))
    (let* ((h (cmacs-brigade-index-open dir))
           (hits (cmacs-brigade-index-search h [2.0 0 0 0] 2)))
      (should (< (abs (- (cdr (nth 0 hits)) (cdr (nth 1 hits)))) 0.01))
      (cmacs-brigade-index-close h))))

(ert-deftest cmacs-brigade-index-rejects-corrupt ()
  "A damaged or foreign index is refused, not reinterpreted.

Reading an unrecognised header as vectors is not an error the user would
notice -- it is confident wrong answers."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (should-error (cmacs-brigade-index-open dir))          ; absent
    (with-temp-file (expand-file-name "vectors.f16" dir) (insert "garbage"))
    (should-error (cmacs-brigade-index-open dir))          ; truncated
    ;; A valid header claiming more vectors than the file holds must be
    ;; refused too: otherwise the scan walks off the mapping.
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w [1.0 0 0 0])
      (cmacs-brigade-index-writer-commit w))
    (let* ((f (expand-file-name "vectors.f16" dir))
           (size (file-attribute-size (file-attributes f))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally f)
        (write-region (point-min) (+ (point-min) (- size 4)) f nil 'silent)))
    (should-error (cmacs-brigade-index-open dir))))

(ert-deftest cmacs-brigade-index-rejects-wrong-dims ()
  "A query of the wrong dimensionality is an error, not a silent 0."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w [1.0 0 0 0])
      (cmacs-brigade-index-writer-commit w))
    (let ((h (cmacs-brigade-index-open dir)))
      (should-error (cmacs-brigade-index-search h [1.0 0 0] 1))
      (cmacs-brigade-index-close h))))

(ert-deftest cmacs-brigade-index-empty-is-valid ()
  "An index with no vectors opens and returns nothing.

This is the state during the first moments of a build, and it must read
as \"nothing indexed yet\" rather than as a broken index."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (should (= 0 (cmacs-brigade-index-writer-commit w))))
    (let ((h (cmacs-brigade-index-open dir)))
      (should (= 0 (plist-get (cmacs-brigade-index-info h) :count)))
      (should (null (cmacs-brigade-index-search h [1.0 0 0 0] 5)))
      (cmacs-brigade-index-close h))))

(ert-deftest cmacs-brigade-index-abort-preserves-previous ()
  "An abandoned build leaves the live index untouched."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w [1.0 0 0 0])
      (cmacs-brigade-index-writer-commit w))
    (let ((w2 (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w2 [0 1.0 0 0])
      (cmacs-brigade-index-writer-abort w2))
    (let ((h (cmacs-brigade-index-open dir)))
      (should (= 1 (plist-get (cmacs-brigade-index-info h) :count)))
      (cmacs-brigade-index-close h))))

(ert-deftest cmacs-brigade-index-single-writer ()
  "Two concurrent builders cannot interleave into one index."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (should-error (cmacs-brigade-index-writer-new dir 4))
      (cmacs-brigade-index-writer-abort w)
      ;; released, so a later build succeeds
      (let ((w2 (cmacs-brigade-index-writer-new dir 4)))
        (cmacs-brigade-index-writer-abort w2)))))

(ert-deftest cmacs-brigade-index-accepts-list-or-vector ()
  "Queries and rows may be given as a list or a vector."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (cmacs-brigade-memory-tests--with-index 4
    (let ((w (cmacs-brigade-index-writer-new dir 4)))
      (cmacs-brigade-index-writer-add w '(1.0 0 0 0))
      (cmacs-brigade-index-writer-commit w))
    (let ((h (cmacs-brigade-index-open dir)))
      (should (cmacs-brigade-index-search h '(1.0 0 0 0) 1))
      (should (cmacs-brigade-index-search h [1.0 0 0 0] 1))
      (cmacs-brigade-index-close h))))


;;;; Policy

(ert-deftest cmacs-brigade-memory-off-by-default ()
  "The index does not build itself.

A first build of a large corpus runs for hours; inflicting that on
someone who merely installed a new cmacs would be indefensible."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (should-not (default-value 'cmacs-brigade-memory-enabled)))

(ert-deftest cmacs-brigade-memory-path-containment ()
  "memory_get cannot escape the configured roots.

The check is on the *resolved* path because that is what the filesystem
acts on -- testing the argument as written would be defeated by any
\"..\" at all."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let ((cmacs-brigade-memory-roots (list (list :path "/tmp/nr" :kind 'org))))
    (should-not (cmacs-brigade-memory--resolve-path "../../etc/passwd"))
    (should-not (cmacs-brigade-memory--resolve-path "/etc/passwd"))
    (should-not (cmacs-brigade-memory--resolve-path "/tmp/nrother/x.org"))
    (should (cmacs-brigade-memory--resolve-path "a/b.org"))
    (should (cmacs-brigade-memory--resolve-path "/tmp/nr/a/b.org"))))

(ert-deftest cmacs-brigade-memory-manifest-detects-drift ()
  "A manifest built with different settings counts as stale.

Vectors from another model or another chunk size are not merely out of
date, they are incomparable -- so this has to force a rebuild rather
than warn."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let ((m (list :model cmacs-brigade-embed-model
                 :dim cmacs-brigade-embed-dim
                 :chunk-target cmacs-brigade-chunk-target-bytes)))
    (should (cmacs-brigade-memory--manifest-matches-p m))
    (should-not (cmacs-brigade-memory--manifest-matches-p
                 (plist-put (copy-sequence m) :model "something-else")))
    (should-not (cmacs-brigade-memory--manifest-matches-p
                 (plist-put (copy-sequence m) :dim 1)))
    (should-not (cmacs-brigade-memory--manifest-matches-p
                 (plist-put (copy-sequence m) :chunk-target 99)))
    (should-not (cmacs-brigade-memory--manifest-matches-p nil))))

(ert-deftest cmacs-brigade-memory-source-registered ()
  "The shipped org source goes through the public registration API."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (let ((src (cmacs-brigade-registry-get 'memory-source 'org)))
    (should src)
    (should (functionp (plist-get src :enumerate)))
    (should (functionp (plist-get src :read-chunk)))))

(ert-deftest cmacs-brigade-memory-tools-registered ()
  "The memory tools reach the agent surfaces like any other tool."
  (skip-unless (cmacs-brigade-memory-tests--available-p))
  (dolist (name '(memory-search memory-get memory-stats))
    (should (cmacs-brigade-registry-get 'tool name)))
  ;; and they are in a group an agent can be granted wholesale
  (should (eq 'memory (cmacs-brigade-tool-group
                       (cmacs-brigade-registry-get 'tool 'memory-search)))))

(provide 'cmacs-brigade-memory-tests)

;;; cmacs-brigade-memory-tests.el ends here
