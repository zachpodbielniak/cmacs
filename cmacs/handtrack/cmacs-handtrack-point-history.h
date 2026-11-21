/* Camera hand tracking for CMacs -- where a bare hand pointed, a moment ago.

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

Two things, both pure -- no lisp.h, no gowl, no allocation:

  the pose   "is this hand pointing": index finger extended, the other
             three curled, not a pinch.  cmacs_ht_point_pose, from the
             26 joints of an LrgVRHandState, with thresholds in metres
             on the standard palm (CMACS_HT_PALM_M) as the pinch latch
             has, so they do not depend on the distance to the camera.

  the ring   CMACS_HT_POINT_RING samples of where a pointing hand's
             index fingertip was on the screen, read back by time: the
             twin of cmacs/gowl/cmacs-gowl-pointer-history.c for
             `cmacs-deixis', which asks "what was being pointed at when
             the word THAT was spoken" a second or two after the fact.

The clock is the mouse ring's: CLOCK_MONOTONIC milliseconds
(g_get_monotonic_time () / 1000).  A sample is stamped with the time its
camera frame arrived (CmacsHtResult.frame_us, taken on the camera's
streaming thread), not the time its inference result reached the main
thread, less a calibration offset for the camera's own delay.

Unlike the mouse ring a sample here is an event, not a state: one per
camera frame in which a hand was pointing, and nothing while none was.
A hand that stops pointing therefore leaves a gap, and a rest is a run
of samples with no gap longer than CMACS_HT_POINT_GAP_MS.

Main thread only (results arrive there, the DEFUNs read there), so no
lock.  Off unless asked for, in memory only, emptied when it is turned
off and when the tracker closes.  */

#ifndef CMACS_HANDTRACK_POINT_HISTORY_H
#define CMACS_HANDTRACK_POINT_HISTORY_H

#include <stdbool.h>
#include <glib.h>
#include <libregnum.h>

/* A power of two, so an index wraps with a mask.  About 17 seconds of
   one hand pointing without pause at 30 frames a second.  */
#define CMACS_HT_POINT_RING 512

/* Defaults, metres on the standard palm.  "Reach" is how much further
   from the wrist a fingertip is than its own knuckle: about +0.075 for
   a straight finger, about zero or below for one folded into the
   palm.  */
#define CMACS_HT_POINT_EXTEND_M 0.055f  /* index reach at least this */
#define CMACS_HT_POINT_CURL_M   0.035f  /* the other three at most this */
#define CMACS_HT_POINT_SOFT_M   0.020f  /* margin that is full confidence */
#define CMACS_HT_POINT_PINCH_M  0.030f  /* thumb on the index tip: a pinch */

/* Samples of one hand further apart than this are two rests.  */
#define CMACS_HT_POINT_GAP_MS 250
/* Samples this close together (layout pixels) are one rest, unless the
   caller says otherwise.  Twice the mouse's: a hand held in the air is
   not as still as a mouse on a desk.  */
#define CMACS_HT_POINT_RADIUS 96.0

struct cmacs_ht_point_params
{
  float extend_m;                /* CMACS_HT_POINT_EXTEND_M */
  float curl_m;                  /* CMACS_HT_POINT_CURL_M */
};

struct cmacs_ht_point_pose
{
  bool pointing;                 /* confidence >= 0.5 and not a pinch */
  float confidence;              /* 0..1 */
  float index_reach;             /* metres on the standard palm */
  float other_reach;             /* the largest of middle, ring, little */
  float pinch_m;                 /* thumb tip to index tip */
};

/* Classify ST.  Pure: joints in, a verdict out.  An inactive hand is
   not pointing.  P may be NULL for the defaults.  */
extern void cmacs_ht_point_pose (const LrgVRHandState *st,
                                 const struct cmacs_ht_point_params *p,
                                 struct cmacs_ht_point_pose *out);

struct cmacs_ht_point_sample
{
  gint64 ms;                     /* monotonic, when the frame was taken */
  double x, y;                   /* layout pixels (or of a nominal screen) */
  float u, v;                    /* 0..1 across the output */
  float confidence;              /* of the pointing pose */
  guint client;                  /* gowl client id under it, 0: none */
  gint monitor;                  /* index in the monitor list, -1: none */
  guint8 hand;                   /* 0 left, 1 right */
  bool layout;                   /* X, Y are real layout pixels */
};

/* A rest: a run of one hand's samples over the same window that stays
   within a radius of where the run began.  */
struct cmacs_ht_point_rest
{
  gint64 begin;                  /* its first sample inside the window */
  gint64 since;                  /* its first sample of all */
  gint64 duration;               /* inside the window */
  double x, y;                   /* means over the samples in the window */
  float u, v, confidence;
  guint client;
  gint monitor;
  int hand;
  bool layout;
};

extern void cmacs_ht_point_set_enabled (bool on);  /* off: also clears */
extern bool cmacs_ht_point_enabled (void);
extern void cmacs_ht_point_clear (void);
extern unsigned int cmacs_ht_point_count (void);
/* Append S.  Does nothing, and returns false, while disabled.  */
extern bool cmacs_ht_point_push (const struct cmacs_ht_point_sample *s);
/* The latest sample at or before MS and no older than
   CMACS_HT_POINT_GAP_MS.  */
extern bool cmacs_ht_point_at (gint64 ms, struct cmacs_ht_point_sample *out);
/* The longest rest between FROM and TO (of equals, the earliest) that
   lasted at least MIN_MS there.  RADIUS <= 0: CMACS_HT_POINT_RADIUS.  */
extern bool cmacs_ht_point_rest (gint64 from, gint64 to, double radius,
                                 gint64 min_ms,
                                 struct cmacs_ht_point_rest *out);

#endif /* CMACS_HANDTRACK_POINT_HISTORY_H */
