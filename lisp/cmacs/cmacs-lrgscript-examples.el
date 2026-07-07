;;; cmacs-lrgscript-examples.el --- A complete libregnum game in Emacs Lisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A complete, playable Breakout authored entirely in Emacs Lisp, driven by
;; `cmacs-lrgscript-play' (the game-authoring layer of `--with-cmacs-lrgscript').
;; This is the worked example for "author a whole libregnum game from your
;; init.el": M-x `cmacs-lrgscript-breakout' opens a game buffer and plays.
;;
;; The design deliberately separates the *game logic* from *rendering*:
;;
;;   * `cmacs-lrgscript-breakout--step' is a PURE function -- given a state and
;;     a timestep it returns the next state (ball motion, wall/paddle/brick
;;     collision, scoring, win/lose).  It touches no engine API, so it is unit
;;     tested headlessly (see test/cmacs/cmacs-lrgscript-tests.el).
;;
;;   * the :draw hook renders the state through the graylib GI draw helpers.
;;     Rendering needs a live libregnum display; the logic does not.
;;
;; This is the recommended shape for an elisp game: keep the simulation pure
;; and testable, and let the hooks wire it to input and rendering.

;;; Code:

(require 'cl-lib)
(require 'cmacs-lrgscript)

(declare-function cmacs-gi-call "cmacs-gi" (namespace function &rest args))

(defgroup cmacs-lrgscript-breakout nil
  "A Breakout game authored in Emacs Lisp on libregnum."
  :group 'cmacs)

(defconst cmacs-lrgscript-breakout--w 640 "Play-field width.")
(defconst cmacs-lrgscript-breakout--h 480 "Play-field height.")
(defconst cmacs-lrgscript-breakout--paddle-w 90 "Paddle width.")
(defconst cmacs-lrgscript-breakout--paddle-h 14 "Paddle height.")
(defconst cmacs-lrgscript-breakout--ball-r 8 "Ball radius.")
(defconst cmacs-lrgscript-breakout--brick-rows 5 "Rows of bricks.")
(defconst cmacs-lrgscript-breakout--brick-cols 10 "Columns of bricks.")

;; A game state is a plist so it is trivial to inspect and test:
;;   :ball-x :ball-y :ball-vx :ball-vy  ball centre + velocity (px/sec)
;;   :paddle-x                           paddle left edge
;;   :paddle-target                      where the paddle wants to be (input)
;;   :bricks                             vector of t/nil, row-major, t = present
;;   :score :lives :status               status: playing | won | lost

(defun cmacs-lrgscript-breakout--new-state ()
  "Return a fresh Breakout state with a full brick wall and a served ball."
  (list :ball-x (/ cmacs-lrgscript-breakout--w 2.0)
        :ball-y (- cmacs-lrgscript-breakout--h 60.0)
        :ball-vx 140.0 :ball-vy -220.0
        :paddle-x (/ (- cmacs-lrgscript-breakout--w
                        cmacs-lrgscript-breakout--paddle-w) 2.0)
        :paddle-target (/ (- cmacs-lrgscript-breakout--w
                             cmacs-lrgscript-breakout--paddle-w) 2.0)
        :bricks (make-vector (* cmacs-lrgscript-breakout--brick-rows
                                cmacs-lrgscript-breakout--brick-cols) t)
        :score 0 :lives 3 :status 'playing))

(defun cmacs-lrgscript-breakout--brick-rect (i)
  "Return (X Y W H) for brick index I in the wall."
  (let* ((cols cmacs-lrgscript-breakout--brick-cols)
         (col (mod i cols))
         (row (/ i cols))
         (bw (/ cmacs-lrgscript-breakout--w cols))
         (bh 22)
         (pad 2))
    (list (+ (* col bw) pad) (+ 40 (* row bh) pad)
          (- bw (* 2 pad)) (- bh (* 2 pad)))))

(defun cmacs-lrgscript-breakout--hit-rect-p (bx by r rx ry rw rh)
  "Return non-nil if a circle at BX,BY radius R overlaps rect RX,RY,RW,RH."
  (let ((cx (max rx (min bx (+ rx rw))))
        (cy (max ry (min by (+ ry rh)))))
    (<= (+ (expt (- bx cx) 2) (expt (- by cy) 2)) (* r r))))

(defun cmacs-lrgscript-breakout--step (state dt)
  "Advance Breakout STATE by DT seconds and return the next state (pure).
Handles paddle easing toward its target, ball integration, wall/paddle/brick
collisions, scoring, and win/lose.  No engine API is touched."
  (if (not (eq (plist-get state :status) 'playing))
      state
    (let* ((s (copy-sequence state))
           (bricks (copy-sequence (plist-get s :bricks)))
           (bx (+ (plist-get s :ball-x) (* (plist-get s :ball-vx) dt)))
           (by (+ (plist-get s :ball-y) (* (plist-get s :ball-vy) dt)))
           (vx (plist-get s :ball-vx))
           (vy (plist-get s :ball-vy))
           (r cmacs-lrgscript-breakout--ball-r)
           (w cmacs-lrgscript-breakout--w)
           (h cmacs-lrgscript-breakout--h)
           (score (plist-get s :score))
           (lives (plist-get s :lives))
           (status 'playing)
           ;; paddle eases toward its input target
           (px (let ((cur (plist-get s :paddle-x))
                     (tgt (plist-get s :paddle-target)))
                 (max 0 (min (- w cmacs-lrgscript-breakout--paddle-w)
                             (+ cur (* (- tgt cur) (min 1.0 (* 12.0 dt)))))))))
      ;; side walls
      (when (and (< bx r) (< vx 0)) (setq vx (- vx)) (setq bx r))
      (when (and (> bx (- w r)) (> vx 0)) (setq vx (- vx)) (setq bx (- w r)))
      ;; ceiling
      (when (and (< by r) (< vy 0)) (setq vy (- vy)) (setq by r))
      ;; paddle
      (let ((py (- h 40)))
        (when (and (> vy 0)
                   (cmacs-lrgscript-breakout--hit-rect-p
                    bx by r px py cmacs-lrgscript-breakout--paddle-w
                    cmacs-lrgscript-breakout--paddle-h))
          (setq vy (- (abs vy)))
          ;; steer by where it hit the paddle
          (let ((off (/ (- bx (+ px (/ cmacs-lrgscript-breakout--paddle-w 2.0)))
                        (/ cmacs-lrgscript-breakout--paddle-w 2.0))))
            (setq vx (+ vx (* off 120.0))))))
      ;; bricks
      (dotimes (i (length bricks))
        (when (aref bricks i)
          (pcase-let ((`(,rx ,ry ,rw ,rh) (cmacs-lrgscript-breakout--brick-rect i)))
            (when (cmacs-lrgscript-breakout--hit-rect-p bx by r rx ry rw rh)
              (aset bricks i nil)
              (setq score (+ score 10))
              (setq vy (- vy))))))
      ;; floor -> lose a life / re-serve
      (when (> by (+ h r))
        (setq lives (1- lives))
        (if (<= lives 0)
            (setq status 'lost)
          (setq bx (/ w 2.0) by (- h 60.0) vx 140.0 vy -220.0)))
      ;; win?
      (when (and (eq status 'playing) (not (cl-find t bricks)))
        (setq status 'won))
      (plist-put s :ball-x bx) (plist-put s :ball-y by)
      (plist-put s :ball-vx vx) (plist-put s :ball-vy vy)
      (plist-put s :paddle-x px) (plist-put s :bricks bricks)
      (plist-put s :score score) (plist-put s :lives lives)
      (plist-put s :status status)
      s)))

;;; --- rendering + input hooks (need a live display) ---------------------

(defvar cmacs-lrgscript-breakout--state nil
  "The live game state for the running Breakout, or nil.")

(defun cmacs-lrgscript-breakout--draw ()
  "Render `cmacs-lrgscript-breakout--state' (called from the :draw hook)."
  (let ((s cmacs-lrgscript-breakout--state))
    (cmacs-lrgscript-clear '(16 16 24))
    ;; bricks
    (let ((bricks (plist-get s :bricks)))
      (dotimes (i (length bricks))
        (when (aref bricks i)
          (pcase-let ((`(,x ,y ,w ,h) (cmacs-lrgscript-breakout--brick-rect i)))
            (cmacs-lrgscript-draw-rect x y w h
                                       (list (+ 80 (* 30 (mod i 5))) 120 200))))))
    ;; paddle
    (cmacs-lrgscript-draw-rect (plist-get s :paddle-x) (- cmacs-lrgscript-breakout--h 40)
                               cmacs-lrgscript-breakout--paddle-w
                               cmacs-lrgscript-breakout--paddle-h '(230 230 240))
    ;; ball
    (cmacs-lrgscript-draw-circle (plist-get s :ball-x) (plist-get s :ball-y)
                                 cmacs-lrgscript-breakout--ball-r '(255 210 90))
    ;; hud
    (cmacs-lrgscript-draw-text (format "SCORE %d   LIVES %d" (plist-get s :score)
                                       (plist-get s :lives))
                               12 12 20 '(200 200 220))
    (pcase (plist-get s :status)
      ('won  (cmacs-lrgscript-draw-text "YOU WIN!"  260 220 30 '(120 255 140)))
      ('lost (cmacs-lrgscript-draw-text "GAME OVER" 250 220 30 '(255 120 120))))))

(defun cmacs-lrgscript-breakout--fixed-update (dt)
  "Advance the game state by DT (called from the :fixed-update hook)."
  (setq cmacs-lrgscript-breakout--state
        (cmacs-lrgscript-breakout--step cmacs-lrgscript-breakout--state dt)))

(defun cmacs-lrgscript-breakout--update (_dt)
  "Read input and steer the paddle (called from the :update hook).
Uses graylib key state via GI; falls back to no movement if unavailable."
  (let ((s cmacs-lrgscript-breakout--state)
        (step 26))
    (ignore-errors
      ;; raylib key codes: LEFT=263, RIGHT=262, A=65, D=68
      (when (or (cmacs-gi-call "Graylib" "is_key_down" 263)
                (cmacs-gi-call "Graylib" "is_key_down" 65))
        (plist-put s :paddle-target (- (plist-get s :paddle-target) step)))
      (when (or (cmacs-gi-call "Graylib" "is_key_down" 262)
                (cmacs-gi-call "Graylib" "is_key_down" 68))
        (plist-put s :paddle-target (+ (plist-get s :paddle-target) step))))))

;;;###autoload
(defun cmacs-lrgscript-breakout ()
  "Play Breakout -- a complete libregnum game authored in Emacs Lisp.
Opens a game buffer and runs the loop.  Move the paddle with the arrow keys
(or A/D).  Requires a graphical libregnum display."
  (interactive)
  (unless (cmacs-lrgscript-available-p*)
    (user-error "cmacs-lrgscript: elisp scripting backend not available"))
  (let ((buf (get-buffer-create "*Breakout*")))
    (with-current-buffer buf
      (setq cmacs-lrgscript-breakout--state (cmacs-lrgscript-breakout--new-state))
      (cmacs-lrgscript-play
       :buffer buf
       :title "Breakout (Emacs Lisp)"
       :width cmacs-lrgscript-breakout--w
       :height cmacs-lrgscript-breakout--h
       :startup (lambda ()
                  (setq cmacs-lrgscript-breakout--state
                        (cmacs-lrgscript-breakout--new-state)))
       :update #'cmacs-lrgscript-breakout--update
       :fixed-update #'cmacs-lrgscript-breakout--fixed-update
       :draw #'cmacs-lrgscript-breakout--draw))
    (switch-to-buffer buf)
    buf))

(provide 'cmacs-lrgscript-examples)
;;; cmacs-lrgscript-examples.el ends here
