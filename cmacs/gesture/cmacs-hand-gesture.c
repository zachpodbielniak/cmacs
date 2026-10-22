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

See cmacs-hand-gesture.h.  Moved out of cmacs-lrgvr.c unchanged when the
desktop camera became a second source of hands.  */

#include <config.h>

#ifdef HAVE_CMACS_HAND_GESTURE

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "cmacs-hand-gesture.h"

static float
hg_dist (const float *a, const float *b)
{
  float dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
  return sqrtf (dx * dx + dy * dy + dz * dz);
}

static int
hg_push (struct cmacs_hg_action *out, int n, int max,
                 enum cmacs_hg_kind kind, int hand, int x, int y,
                 const float *v)
{
  if (n >= max)
    return n;
  out[n].kind = kind;
  out[n].hand = hand;
  out[n].x = x;
  out[n].y = y;
  out[n].v[0] = v != NULL ? v[0] : 0.0f;
  out[n].v[1] = v != NULL ? v[1] : 0.0f;
  out[n].v[2] = v != NULL ? v[2] : 0.0f;
  return n + 1;
}

/* End hand H's pinch, whatever it was doing.  RELEASED: the fingers
   opened (a pending pinch is then a tap); otherwise the hand was lost.  */
static int
hg_end (struct cmacs_hg_hand *g, int h, gint64 now, bool released,
                struct cmacs_hg_action *out, int n, int max)
{
  switch (g->mode)
    {
    case CMACS_HG_PM_PENDING:
      if (!released)
        break;
      if (g->target0 == CMACS_HG_PANEL || g->target0 == CMACS_HG_WORKSPACE)
        n = hg_push (out, n, max, CMACS_HG_CLICK, h, g->fx0, g->fy0, NULL);
      else if (g->target0 == CMACS_HG_NONE
               && now - g->t0 <= CMACS_HG_TAP_EMPTY_US)
        n = hg_push (out, n, max, CMACS_HG_TAP, h, 0, 0, NULL);
      break;
    case CMACS_HG_PM_DRAG:
      n = hg_push (out, n, max, CMACS_HG_DRAG_END, h, g->lastfx, g->lastfy,
                           NULL);
      break;
    case CMACS_HG_PM_PULL:
      n = hg_push (out, n, max, CMACS_HG_PULL_END, h, 0, 0, NULL);
      break;
    case CMACS_HG_PM_KEY:
      n = hg_push (out, n, max, CMACS_HG_KEY_UP, h, 0, 0, NULL);
      break;
    default:
      break;
    }
  g->mode = CMACS_HG_PM_IDLE;
  return n;
}

/* Advance the gesture state G by one frame of samples S (both hands) at
   NOW (microseconds).  Writes up to MAX actions to OUT; returns how many.  */
int
cmacs_hg_step (struct cmacs_hg_state *g, const struct cmacs_hg_sample *s,
                 gint64 now, struct cmacs_hg_action *out, int max)
{
  int n = 0, h;

  /* Two hands: a stretch.  Starts when both hold a pinch that is still
     undecided or pulling the world -- not one busy on a panel or the
     keyboard -- and lasts while both stay pinched.  */
  if (!g->zooming)
    {
      bool ready = true;
      for (h = 0; h < 2; h++)
        ready = ready && s[h].tracked && s[h].pinched
                && (g->h[h].mode == CMACS_HG_PM_PENDING
                    || g->h[h].mode == CMACS_HG_PM_PULL);
      if (ready && hg_dist (s[0].pos, s[1].pos) >= CMACS_HG_ZOOM_MIN_M)
        {
          for (h = 0; h < 2; h++)
            {
              if (g->h[h].mode == CMACS_HG_PM_PULL)
                n = hg_push (out, n, max, CMACS_HG_PULL_END, h, 0, 0, NULL);
              g->h[h].mode = CMACS_HG_PM_ZOOM;
            }
          g->zooming = true;
          g->zoom_d0 = hg_dist (s[0].pos, s[1].pos);
          g->zoom_ratio = 1.0f;
          n = hg_push (out, n, max, CMACS_HG_ZOOM_BEGIN, -1, 0, 0, NULL);
        }
    }
  else
    {
      if (s[0].tracked && s[0].pinched && s[1].tracked && s[1].pinched)
        {
          float r[3];
          g->zoom_ratio = hg_dist (s[0].pos, s[1].pos) / g->zoom_d0;
          r[0] = g->zoom_ratio; r[1] = r[2] = 0.0f;
          n = hg_push (out, n, max, CMACS_HG_ZOOM, -1, 0, 0, r);
        }
      else
        {
          float r[3];
          r[0] = g->zoom_ratio; r[1] = r[2] = 0.0f;
          g->zooming = false;
          n = hg_push (out, n, max, CMACS_HG_ZOOM_END, -1, 0, 0, r);
          /* A hand still pinched stays spent until it lets go.  */
        }
    }

  for (h = 0; h < 2; h++)
    {
      struct cmacs_hg_hand *hg = &g->h[h];
      const struct cmacs_hg_sample *hs = &s[h];

      if (!hs->tracked)
        {
          n = hg_end (hg, h, now, false, out, n, max);
          if (hg->palm_up && hg->palm_sent)
            n = hg_push (out, n, max, CMACS_HG_PALM_DOWN, h, 0, 0, NULL);
          hg->palm_up = hg->palm_sent = false;
          continue;
        }

      /* The palm: up and held (not while pinching), then back down.  */
      if (hs->palm_up && !hs->pinched)
        {
          if (!hg->palm_up)
            {
              hg->palm_up = true;
              hg->palm_sent = false;
              hg->palm_since = now;
            }
          else if (!hg->palm_sent && now - hg->palm_since >= CMACS_HG_PALM_US)
            {
              hg->palm_sent = true;
              n = hg_push (out, n, max, CMACS_HG_PALM_UP, h, 0, 0, NULL);
            }
        }
      else if (hg->palm_up && !hs->palm_up)
        {
          if (hg->palm_sent)
            n = hg_push (out, n, max, CMACS_HG_PALM_DOWN, h, 0, 0, NULL);
          hg->palm_up = hg->palm_sent = false;
        }

      if (!hs->pinched)
        {
          if (hg->mode != CMACS_HG_PM_IDLE)
            n = hg_end (hg, h, now, true, out, n, max);
          continue;
        }

      switch (hg->mode)
        {
        case CMACS_HG_PM_IDLE:
          hg->t0 = now;
          hg->target0 = hs->target;
          hg->fx0 = hg->lastfx = hs->fx;
          hg->fy0 = hg->lastfy = hs->fy;
          memcpy (hg->pos0, hs->pos, sizeof hg->pos0);
          memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
          hg->acc_x = hg->acc_y = 0.0f;
          if (hs->target == CMACS_HG_KEYBOARD)
            {
              hg->mode = CMACS_HG_PM_KEY;
              n = hg_push (out, n, max, CMACS_HG_KEY_DOWN, h, 0, 0, NULL);
            }
          else
            hg->mode = CMACS_HG_PM_PENDING;
          break;

        case CMACS_HG_PM_PENDING:
          if (hg->target0 == CMACS_HG_PANEL)
            {
              int moved = (hs->target == CMACS_HG_PANEL)
                          ? abs (hs->fx - hg->fx0) + abs (hs->fy - hg->fy0)
                          : 0;
              if (moved >= CMACS_HG_MOVE_PX)
                {
                  hg->mode = CMACS_HG_PM_SCROLL;
                  hg->lastfx = hs->fx;
                  hg->lastfy = hs->fy;
                }
              else if (now - hg->t0 >= CMACS_HG_HOLD_US)
                {
                  hg->mode = CMACS_HG_PM_DRAG;
                  n = hg_push (out, n, max, CMACS_HG_DRAG_BEGIN, h, hg->fx0,
                                       hg->fy0, NULL);
                }
            }
          else if (hg->target0 == CMACS_HG_NONE
                   && hg_dist (hs->pos, hg->pos0) >= CMACS_HG_MOVE_M)
            {
              hg->mode = CMACS_HG_PM_PULL;
              memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
              n = hg_push (out, n, max, CMACS_HG_PULL_BEGIN, h, 0, 0, NULL);
            }
          break;

        case CMACS_HG_PM_SCROLL:
          if (hs->target == CMACS_HG_PANEL)
            {
              int sx, sy;
              hg->acc_x += (float) (hs->fx - hg->lastfx);
              hg->acc_y += (float) (hs->fy - hg->lastfy);
              hg->lastfx = hs->fx;
              hg->lastfy = hs->fy;
              sx = (int) (hg->acc_x / CMACS_HG_SCROLL_PX);
              sy = (int) (hg->acc_y / CMACS_HG_SCROLL_PX);
              hg->acc_x -= (float) (sx * CMACS_HG_SCROLL_PX);
              hg->acc_y -= (float) (sy * CMACS_HG_SCROLL_PX);
              if (sx != 0 || sy != 0)
                n = hg_push (out, n, max, CMACS_HG_SCROLL, h, sx, sy, NULL);
            }
          break;

        case CMACS_HG_PM_DRAG:
          if (hs->target == CMACS_HG_PANEL)
            {
              hg->lastfx = hs->fx;
              hg->lastfy = hs->fy;
            }
          break;

        case CMACS_HG_PM_PULL:
          {
            float d[3];
            int i;
            for (i = 0; i < 3; i++)
              d[i] = hs->pos[i] - hg->lastpos[i];
            memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
            if (d[0] != 0.0f || d[1] != 0.0f || d[2] != 0.0f)
              n = hg_push (out, n, max, CMACS_HG_PULL_MOVE, h, 0, 0, d);
          }
          break;

        default:   /* KEY, ZOOM: nothing until release */
          break;
        }
    }
  return n;
}

#endif /* HAVE_CMACS_HAND_GESTURE */
