/* Hand gestures for CMacs -- the pinch / palm classifier.

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later

Shared by every source of tracked hands: OpenXR in a headset
(cmacs-lrgvr.c) and the desktop camera (cmacs-handtrack-defuns.c).
Pure C -- no lisp.h, no libregnum -- so both feed it the same samples
and get the same gestures, and tests run it without either.  */

#ifndef CMACS_HAND_GESTURE_H
#define CMACS_HAND_GESTURE_H

#include <stdbool.h>
#include <glib.h>

/*
   A pinch is one of five things, decided while it is held:

     tap      released quickly without moving: a click at the laser (on a
              panel), a key (on the keyboard), <vr-hand-*-pinch> (on
              nothing);
     drag     held still on a panel for CMACS_HG_HOLD_US: mouse-1 goes down
              where the pinch began and follows the laser until release --
              selecting text, dragging a scroll bar, orbiting a globe;
     scroll   moved on a panel before that: the content follows the hand,
              CMACS_HG_SCROLL_PX of laser travel per wheel step;
     pull     moved on empty space: the world follows the hand (a world
              grab, as the controller grip does);
     zoom     both hands pinching at once, neither busy on a panel: the
              world scale follows the distance between them.

   A palm turned up and held for CMACS_HG_PALM_US is a palm-up action;
   turning it back is palm-down.  In a headset these become
   <vr-hand-...> events, on the desktop camera <hand-...> events.

   cmacs_hg_step is the whole classifier and is pure -- samples in,
   actions out, no Emacs or libregnum state -- so it runs per headset
   frame, per camera frame, and from `cmacs-lrg-vr--simulate-hand-gestures'
   and `cmacs-handtrack--simulate' in tests alike.  The desktop has no
   laser, so every camera sample's target is CMACS_HG_NONE: there a
   pinch taps, pulls (orbits a scene) or, with both hands, zooms.  */

#define CMACS_HG_HOLD_US    450000  /* still this long on a panel: drag */
#define CMACS_HG_TAP_EMPTY_US 600000 /* longest tap on empty space */
#define CMACS_HG_MOVE_PX    14      /* laser travel: a pending pinch scrolls */
#define CMACS_HG_MOVE_M     0.03f   /* hand travel: a pending pinch pulls */
#define CMACS_HG_SCROLL_PX  36      /* laser pixels per wheel step */
#define CMACS_HG_PALM_COS   0.70f   /* palm within ~45 degrees of up */
#define CMACS_HG_PALM_US    300000  /* palm up this long: the event */
#define CMACS_HG_ZOOM_MIN_M 0.05f   /* hands closer than this cannot zoom */
#define CMACS_HG_ZOOM_DEAD  0.05f   /* scale change that counts as a zoom */
#define CMACS_HG_MAX_ACTIONS 24

enum cmacs_hg_target
{
  CMACS_HG_NONE, CMACS_HG_PANEL, CMACS_HG_KEYBOARD, CMACS_HG_WORKSPACE
};

/* One hand, one frame, as the classifier sees it.  */
struct cmacs_hg_sample
{
  bool tracked;                  /* hand tracking drives this hand */
  bool pinched;                  /* the latch, hysteresis applied */
  bool palm_up;
  enum cmacs_hg_target target;    /* under the laser */
  int fx, fy;                    /* frame pixel under the laser */
  float pos[3];                  /* pinch point, tracking metres */
};

enum cmacs_hg_mode
{
  CMACS_HG_PM_IDLE, CMACS_HG_PM_PENDING, CMACS_HG_PM_DRAG,
  CMACS_HG_PM_SCROLL, CMACS_HG_PM_PULL, CMACS_HG_PM_KEY, CMACS_HG_PM_ZOOM
};

struct cmacs_hg_hand
{
  enum cmacs_hg_mode mode;
  gint64 t0;                     /* pinch start */
  enum cmacs_hg_target target0;  /* what it started on */
  int fx0, fy0, lastfx, lastfy;
  float pos0[3], lastpos[3];
  float acc_x, acc_y;            /* scroll travel not yet a wheel step */
  bool palm_up, palm_sent;
  gint64 palm_since;
};

struct cmacs_hg_state
{
  struct cmacs_hg_hand h[2];
  bool zooming;
  float zoom_d0, zoom_ratio;
};

enum cmacs_hg_kind
{
  CMACS_HG_CLICK,
  CMACS_HG_DRAG_BEGIN,
  CMACS_HG_DRAG_END,
  CMACS_HG_SCROLL,
  CMACS_HG_PULL_BEGIN,
  CMACS_HG_PULL_MOVE,
  CMACS_HG_PULL_END,
  CMACS_HG_TAP,
  CMACS_HG_KEY_DOWN,
  CMACS_HG_KEY_UP,
  CMACS_HG_PALM_UP,
  CMACS_HG_PALM_DOWN,
  CMACS_HG_ZOOM_BEGIN,
  CMACS_HG_ZOOM,
  CMACS_HG_ZOOM_END
};

struct cmacs_hg_action
{
  enum cmacs_hg_kind kind;
  int hand;                      /* 0 left, 1 right, -1 both (zoom) */
  int x, y;                      /* pixels (click, drag); wheel steps */
  float v[3];                    /* metres (pull), ratio in v[0] (zoom) */
};

/* Advance the gesture state G by one frame of samples S (both hands) at
   NOW (microseconds).  Writes up to MAX actions to OUT; returns how many.  */
extern int cmacs_hg_step (struct cmacs_hg_state *g,
                          const struct cmacs_hg_sample *s, gint64 now,
                          struct cmacs_hg_action *out, int max);

#endif /* CMACS_HAND_GESTURE_H */
