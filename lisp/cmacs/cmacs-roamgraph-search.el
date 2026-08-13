;;; cmacs-roamgraph-search.el --- finding notes in the graph -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two commands, because finding things in a graph is two different
;; tasks:
;;
;;   `/'    incremental search that highlights every match in place and
;;          dims the rest.  "Show me where X is in my notes."  Losing
;;          this is losing the point of a visualiser -- a completion
;;          list cannot tell you that all six matches are in one
;;          cluster.
;;
;;   `g /'  a completing-read palette that jumps to one node.  "Take me
;;          to that note."  Goes through `completing-read', so it
;;          inherits vertico/orderless/marginalia rather than
;;          hand-rolling a matcher.
;;
;; Search only highlights; it never re-lays-out the graph.  Filtering is
;; a separate, explicit command, because rebuilding on every keystroke
;; would reshuffle every position while you are still typing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-search-style 'literal
  "How `cmacs-roamgraph-search' matches what you type.

`literal'    plain substring
`regexp'     Emacs regexp
`orderless'  space-separated substrings, all of which must appear"
  :type '(choice (const literal) (const regexp) (const orderless))
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-search-debounce-threshold 5000
  "Above this many nodes, matching waits for a short idle pause.
Below it, matching is fast enough to run on every keystroke."
  :type 'integer
  :group 'cmacs-roamgraph)

(defvar-local cmacs-roamgraph--haystacks nil
  "Vector of lowercased searchable text, parallel to the node vector.")
(defvar-local cmacs-roamgraph--haystack-ids nil
  "Vector of ids parallel to `cmacs-roamgraph--haystacks'.")
(defvar-local cmacs-roamgraph--search-last nil)
(defvar-local cmacs-roamgraph--search-saved nil
  "Selection to restore if the search is aborted.")

(defun cmacs-roamgraph--build-haystacks ()
  "Precompute the searchable text for every node.
Done once per rebuild so a keystroke is a scan of already-lowercased
strings rather than a re-render of every node's metadata."
  (let* ((nodes (plist-get cmacs-roamgraph--graph :nodes))
         (n (length nodes))
         (hay (make-vector n ""))
         (ids (make-vector n nil)))
    (dotimes (i n)
      (let* ((node (aref nodes i))
             (file (plist-get node :file)))
        (aset ids i (plist-get node :id))
        (aset hay i
              (downcase
               (mapconcat
                #'identity
                (delq nil
                      (append (list (plist-get node :title))
                              (plist-get node :aliases)
                              (plist-get node :tags)
                              (list (and file (file-name-nondirectory file)))))
                " ")))))
    (setq cmacs-roamgraph--haystacks hay
          cmacs-roamgraph--haystack-ids ids)))

(defun cmacs-roamgraph--match-p (needle hay)
  "Return non-nil if NEEDLE matches HAY under the configured style."
  (pcase cmacs-roamgraph-search-style
    ('regexp (ignore-errors (string-match-p needle hay)))
    ('orderless (cl-every (lambda (w) (string-search w hay))
                          (split-string needle " " t)))
    (_ (string-search needle hay))))

(defun cmacs-roamgraph--matches-for (needle)
  "Return the vector of ids matching NEEDLE, ordered for cycling."
  (if (or (null needle) (string-empty-p needle))
      nil
    (unless cmacs-roamgraph--haystacks (cmacs-roamgraph--build-haystacks))
    (let ((needle (downcase needle))
          (hits '()))
      (dotimes (i (length cmacs-roamgraph--haystacks))
        (when (cmacs-roamgraph--match-p needle (aref cmacs-roamgraph--haystacks i))
          (push (aref cmacs-roamgraph--haystack-ids i) hits)))
      ;; Walk matches alphabetically rather than in scene-build order:
      ;; far more useful, and stable across a rebuild.
      (vconcat (cmacs-roamgraph--sort-ids (nreverse hits))))))

(defun cmacs-roamgraph--apply-highlight ()
  "Push the current match set to the renderer."
  (let ((buf (current-buffer)))
    (if (or (null cmacs-roamgraph--matches)
            (zerop (length cmacs-roamgraph--matches)))
        (when (fboundp 'cmacs-libregnum-set-match-set)
          (cmacs-libregnum-set-match-set buf nil nil))
      (let ((idx (delq nil
                       (mapcar #'cmacs-roamgraph--scene-index
                               (append cmacs-roamgraph--matches nil)))))
        (when (fboundp 'cmacs-libregnum-set-match-set)
          ;; Dim the non-matches: by far the strongest cue, and the
          ;; thing org-roam-ui's search gets wrong.
          (cmacs-libregnum-set-match-set buf (vconcat idx) t))))
    (when (fboundp 'cmacs-roamgraph-apply-flags)
      (cmacs-roamgraph-apply-flags buf))))

(defun cmacs-roamgraph--search-tick ()
  "Re-match on what is currently typed in the minibuffer."
  (let ((s (minibuffer-contents-no-properties)))
    (unless (equal s cmacs-roamgraph--search-last)
      (setq cmacs-roamgraph--search-last s)
      (let ((buf (window-buffer (minibuffer-selected-window))))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (derived-mode-p 'cmacs-roamgraph-mode)
              (setq cmacs-roamgraph--matches (cmacs-roamgraph--matches-for s)
                    cmacs-roamgraph--match-index 0)
              (cmacs-roamgraph--apply-highlight)
              (when (and cmacs-roamgraph--matches
                         (> (length cmacs-roamgraph--matches) 0))
                (cmacs-roamgraph--select (aref cmacs-roamgraph--matches 0)
                                         t 'search)))))))))

(defvar cmacs-roamgraph-search-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m minibuffer-local-map)
    (define-key m (kbd "C-n") #'cmacs-roamgraph-search-next)
    (define-key m (kbd "C-p") #'cmacs-roamgraph-search-prev)
    (define-key m (kbd "M-n") #'cmacs-roamgraph-search-next)
    (define-key m (kbd "M-p") #'cmacs-roamgraph-search-prev)
    m)
  "Minibuffer keymap during `cmacs-roamgraph-search'.")

(defun cmacs-roamgraph-search ()
  "Search the graph incrementally, highlighting every match.

Matches take an accent colour and are labelled unconditionally; the
rest of the graph dims.  \\<cmacs-roamgraph-search-map>\\[cmacs-roamgraph-search-next] and \\[cmacs-roamgraph-search-prev] walk the hits while you
are still typing.  RET keeps the highlight (so `n' and `N' stay live in
the viewport); C-g clears it and restores the previous selection."
  (interactive)
  (let ((buf (current-buffer)))
    (unless (derived-mode-p 'cmacs-roamgraph-mode)
      (user-error "Not in a roamgraph buffer"))
    (setq cmacs-roamgraph--search-saved cmacs-roamgraph--selected
          cmacs-roamgraph--search-last nil)
    (cmacs-roamgraph--build-haystacks)
    (let ((ok nil))
      (unwind-protect
          (progn
            (minibuffer-with-setup-hook
                (lambda ()
                  (add-hook 'post-command-hook
                            #'cmacs-roamgraph--search-tick nil t))
              (read-from-minibuffer "Find note: " nil
                                    cmacs-roamgraph-search-map))
            (setq ok t))
        (unless ok
          ;; Aborted: put everything back the way it was.
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (cmacs-roamgraph-search-clear)
              (when cmacs-roamgraph--search-saved
                (cmacs-roamgraph--select cmacs-roamgraph--search-saved
                                         nil 'restore)))))))))

(defun cmacs-roamgraph-search-clear ()
  "Drop the search highlight."
  (interactive)
  (setq cmacs-roamgraph--matches nil
        cmacs-roamgraph--match-index 0
        cmacs-roamgraph--search-last nil)
  (cmacs-roamgraph--apply-highlight)
  (message "Search cleared"))

(defun cmacs-roamgraph--cycle-match (delta)
  "Move DELTA places through the match set, wrapping."
  (let ((buf (if (minibufferp)
                 (window-buffer (minibuffer-selected-window))
               (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (or (null cmacs-roamgraph--matches)
                (zerop (length cmacs-roamgraph--matches)))
            (message "No matches")
          (setq cmacs-roamgraph--match-index
                (mod (+ cmacs-roamgraph--match-index delta)
                     (length cmacs-roamgraph--matches)))
          ;; A search jump SHOULD fly: you asked to be taken there.
          (cmacs-roamgraph--select
           (aref cmacs-roamgraph--matches cmacs-roamgraph--match-index)
           t 'search))))))

(defun cmacs-roamgraph-search-next ()
  "Go to the next search match."
  (interactive)
  (cmacs-roamgraph--cycle-match 1))

(defun cmacs-roamgraph-search-prev ()
  "Go to the previous search match."
  (interactive)
  (cmacs-roamgraph--cycle-match -1))

;;;###autoload
(defun cmacs-roamgraph-jump ()
  "Jump to a note chosen by name.
Uses `completing-read', so your completion UI applies."
  (interactive)
  (unless (derived-mode-p 'cmacs-roamgraph-mode)
    (user-error "Not in a roamgraph buffer"))
  (let* ((nodes (plist-get cmacs-roamgraph--graph :nodes))
         (table (make-hash-table :test #'equal))
         (cands '()))
    (mapc (lambda (n)
            (let* ((tags (plist-get n :tags))
                   (label (format "%s%s%s"
                                  (plist-get n :title)
                                  (if tags (format "  [%s]"
                                                   (string-join tags ", "))
                                    "")
                                  (if (plist-get n :group)
                                      (format "  (%s)" (plist-get n :group))
                                    ""))))
              ;; Titles repeat (every daily is a date); keep both.
              (while (gethash label table)
                (setq label (concat label " ")))
              (puthash label (plist-get n :id) table)
              (push label cands)))
          nodes)
    (let ((pick (completing-read "Note: " (nreverse cands) nil t)))
      (cmacs-roamgraph--select (gethash pick table) t 'jump))))

(provide 'cmacs-roamgraph-search)

;;; cmacs-roamgraph-search.el ends here
