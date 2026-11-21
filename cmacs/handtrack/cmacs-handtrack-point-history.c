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

See cmacs-handtrack-point-history.h.  Like cmacs-handtrack-model.c this
file reads an LrgVRHandState's fields and calls nothing in libregnum,
so it links into a test without it.  */

#include <config.h>

#ifdef HAVE_CMACS_HANDTRACK

#include <math.h>
#include <string.h>

#include "cmacs-handtrack-point-history.h"

/* ------------------------------------------------------------ the pose -- */

static float
point_dist (const LrgVRHandState *st, int a, int b)
{
  const float *p = &st->positions[a * 3], *q = &st->positions[b * 3];
  float dx = p[0] - q[0], dy = p[1] - q[1], dz = p[2] - q[2];

  return sqrtf (dx * dx + dy * dy + dz * dz);
}

/* How much further from the wrist TIP is than KNUCKLE.  A straight
   finger adds its whole length to the knuckle's distance; one folded
   into the palm brings its tip back to about where the knuckle is, or
   nearer.  Measured from the wrist rather than as a bend angle because
   it needs no joint the landmark model is unsure of (the middle of a
   curled finger is hidden behind the hand as often as not).  */
static float
point_reach (const LrgVRHandState *st, int knuckle, int tip)
{
  return point_dist (st, tip, LRG_VR_HAND_JOINT_WRIST)
         - point_dist (st, knuckle, LRG_VR_HAND_JOINT_WRIST);
}

void
cmacs_ht_point_pose (const LrgVRHandState *st,
                     const struct cmacs_ht_point_params *p,
                     struct cmacs_ht_point_pose *out)
{
  float extend = p != NULL ? p->extend_m : CMACS_HT_POINT_EXTEND_M;
  float curl = p != NULL ? p->curl_m : CMACS_HT_POINT_CURL_M;
  float mid, ring, little, margin;

  memset (out, 0, sizeof *out);
  if (st == NULL || !st->active)
    return;

  out->index_reach = point_reach (st, LRG_VR_HAND_JOINT_INDEX_PROXIMAL,
                                  LRG_VR_HAND_JOINT_INDEX_TIP);
  mid = point_reach (st, LRG_VR_HAND_JOINT_MIDDLE_PROXIMAL,
                     LRG_VR_HAND_JOINT_MIDDLE_TIP);
  ring = point_reach (st, LRG_VR_HAND_JOINT_RING_PROXIMAL,
                      LRG_VR_HAND_JOINT_RING_TIP);
  little = point_reach (st, LRG_VR_HAND_JOINT_LITTLE_PROXIMAL,
                        LRG_VR_HAND_JOINT_LITTLE_TIP);
  out->other_reach = fmaxf (mid, fmaxf (ring, little));
  out->pinch_m = point_dist (st, LRG_VR_HAND_JOINT_THUMB_TIP,
                             LRG_VR_HAND_JOINT_INDEX_TIP);

  /* The thumb is left out on purpose: tucked in or stuck out, people
     point both ways.  But a thumb ON the index tip is a pinch, which
     already means something else.  */
  if (out->pinch_m < CMACS_HT_POINT_PINCH_M)
    return;

  /* The weaker of the two conditions decides: how far past straight
     the index is, how far short of straight the straightest of the
     others is.  Exactly on a threshold is 0.5; CMACS_HT_POINT_SOFT_M
     past it is certain.  */
  margin = fminf (out->index_reach - extend, curl - out->other_reach);
  out->confidence = CLAMP (0.5f + 0.5f * margin / CMACS_HT_POINT_SOFT_M,
                           0.0f, 1.0f);
  out->pointing = out->confidence >= 0.5f;
}

/* ------------------------------------------------------------ the ring -- */

#define POINT_MASK (CMACS_HT_POINT_RING - 1)

static struct cmacs_ht_point_sample point_ring[CMACS_HT_POINT_RING];
static unsigned int point_head;      /* next slot to write */
static unsigned int point_count;     /* valid entries */
static bool point_enabled;

/* Entry I, 0 being the oldest.  */
static const struct cmacs_ht_point_sample *
point_entry (unsigned int i)
{
  return &point_ring[(point_head - point_count + i) & POINT_MASK];
}

void
cmacs_ht_point_clear (void)
{
  memset (point_ring, 0, sizeof point_ring);
  point_head = 0;
  point_count = 0;
}

void
cmacs_ht_point_set_enabled (bool on)
{
  /* Either way what is there goes: turning it off because nobody may
     keep it, turning it on because it would be from another session.  */
  if (on != point_enabled)
    cmacs_ht_point_clear ();
  point_enabled = on;
}

bool
cmacs_ht_point_enabled (void)
{
  return point_enabled;
}

unsigned int
cmacs_ht_point_count (void)
{
  return point_count;
}

bool
cmacs_ht_point_push (const struct cmacs_ht_point_sample *s)
{
  if (!point_enabled)
    return false;
  point_ring[point_head] = *s;
  point_head = (point_head + 1) & POINT_MASK;
  if (point_count < CMACS_HT_POINT_RING)
    point_count++;
  return true;
}

bool
cmacs_ht_point_at (gint64 ms, struct cmacs_ht_point_sample *out)
{
  unsigned int i;

  if (!point_enabled)
    return false;
  for (i = point_count; i > 0; i--)
    {
      const struct cmacs_ht_point_sample *s = point_entry (i - 1);

      if (s->ms <= ms)
        {
          /* A sample is one frame of pointing, not a state that lasts:
             a stale one says nothing about MS.  */
          if (ms - s->ms > CMACS_HT_POINT_GAP_MS)
            return false;
          *out = *s;
          return true;
        }
    }
  return false;
}

/* A rest being built.  N counts its samples inside the window, which
   are the only ones its means are over.  */
struct point_run
{
  bool open;
  gint64 since, last;            /* first and latest sample of all */
  gint64 in_first, in_last;      /* ... inside the window */
  int n;
  double ax, ay;                 /* where it began */
  double sx, sy, su, sv, sc;
  guint client;
  gint monitor;
  bool layout;
};

/* Offer run R of HAND to BEST: taken when it has samples in the window,
   lasted at least MIN_MS there and beats what BEST holds.  */
static void
point_offer (const struct point_run *r, int hand, gint64 min_ms,
             struct cmacs_ht_point_rest *best, bool *have)
{
  gint64 d;

  if (!r->open || r->n == 0)
    return;
  d = r->in_last - r->in_first;
  if (d < min_ms)
    return;
  if (*have && (d < best->duration
                || (d == best->duration && r->in_first >= best->begin)))
    return;
  best->begin = r->in_first;
  best->since = r->since;
  best->duration = d;
  best->x = r->sx / r->n;
  best->y = r->sy / r->n;
  best->u = (float) (r->su / r->n);
  best->v = (float) (r->sv / r->n);
  best->confidence = (float) (r->sc / r->n);
  best->client = r->client;
  best->monitor = r->monitor;
  best->hand = hand;
  best->layout = r->layout;
  *have = true;
}

bool
cmacs_ht_point_rest (gint64 from, gint64 to, double radius, gint64 min_ms,
                     struct cmacs_ht_point_rest *out)
{
  bool have = false;
  int hand;

  if (!point_enabled || point_count == 0)
    return false;
  if (to < from)
    {
      gint64 swap = from;
      from = to;
      to = swap;
    }
  if (radius <= 0.0)
    radius = CMACS_HT_POINT_RADIUS;
  if (min_ms < 0)
    min_ms = 0;

  /* Each hand has rests of its own; the two interleave in the ring.
     A run is followed from before the window opens, so that SINCE says
     when the hand really came to rest there -- which is what tells a
     hand that has just been raised from one left lying in the pose.  */
  for (hand = 0; hand < 2; hand++)
    {
      struct point_run run = { 0 };
      unsigned int i;

      for (i = 0; i < point_count; i++)
        {
          const struct cmacs_ht_point_sample *s = point_entry (i);

          if (s->hand != hand)
            continue;
          if (s->ms > to)
            break;
          if (!(run.open && s->ms - run.last <= CMACS_HT_POINT_GAP_MS
                && s->client == run.client && s->layout == run.layout
                && hypot (s->x - run.ax, s->y - run.ay) <= radius))
            {
              point_offer (&run, hand, min_ms, out, &have);
              memset (&run, 0, sizeof run);
              run.open = true;
              run.since = s->ms;
              run.ax = s->x;
              run.ay = s->y;
              run.client = s->client;
              run.monitor = s->monitor;
              run.layout = s->layout;
            }
          run.last = s->ms;
          if (s->ms >= from)
            {
              if (run.n == 0)
                run.in_first = s->ms;
              run.in_last = s->ms;
              run.n++;
              run.sx += s->x;
              run.sy += s->y;
              run.su += (double) s->u;
              run.sv += (double) s->v;
              run.sc += (double) s->confidence;
            }
        }
      point_offer (&run, hand, min_ms, out, &have);
    }
  return have;
}

#endif /* HAVE_CMACS_HANDTRACK */
