/* SpaceMouse / 6DOF input for CMacs -- wire format and axis shaping.

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

Pure functions only: no Emacs, no GLib loop, no device.  */

#include <config.h>

#ifdef HAVE_CMACS_SPACEMOUSE

#include <math.h>
#include <string.h>
#include <stdint.h>

#include "cmacs-spacemouse.h"

/* v0 report types.  */
#define SPNAV_V0_MOTION  0
#define SPNAV_V0_PRESS   1
#define SPNAV_V0_RELEASE 2

static int32_t
get_i32 (const unsigned char *buf, int i)
{
  int32_t v;
  memcpy (&v, buf + 4 * i, sizeof v);   /* native endian: a local socket */
  return v;
}

static void
put_i32 (unsigned char *buf, int i, int32_t v)
{
  memcpy (buf + 4 * i, &v, sizeof v);
}

bool
cmacs_spnav_decode_v0 (const unsigned char *buf, CmacsSpnavEvent *ev)
{
  int i;

  memset (ev, 0, sizeof *ev);
  switch (get_i32 (buf, 0))
    {
    case SPNAV_V0_MOTION:
      ev->kind = CMACS_SPNAV_MOTION;
      for (i = 0; i < 6; i++)
        ev->axis[i] = get_i32 (buf, 1 + i);
      ev->period_ms = (unsigned int) get_i32 (buf, 7);
      return true;
    case SPNAV_V0_PRESS:
    case SPNAV_V0_RELEASE:
      ev->kind = CMACS_SPNAV_BUTTON;
      ev->button = get_i32 (buf, 1);
      ev->press = get_i32 (buf, 0) == SPNAV_V0_PRESS;
      return ev->button >= 0;
    default:
      ev->kind = CMACS_SPNAV_NONE;
      return false;
    }
}

void
cmacs_spnav_encode_v0 (const CmacsSpnavEvent *ev, unsigned char *buf)
{
  int i;

  memset (buf, 0, CMACS_SPNAV_PACKET_SIZE);
  if (ev->kind == CMACS_SPNAV_MOTION)
    {
      put_i32 (buf, 0, SPNAV_V0_MOTION);
      for (i = 0; i < 6; i++)
        put_i32 (buf, 1 + i, ev->axis[i]);
      put_i32 (buf, 7, (int32_t) ev->period_ms);
    }
  else
    {
      put_i32 (buf, 0, ev->press ? SPNAV_V0_PRESS : SPNAV_V0_RELEASE);
      put_i32 (buf, 1, ev->button);
    }
}

void
cmacs_spnav_shape_defaults (CmacsSpnavShape *shape)
{
  shape->sensitivity = 1.0f;
  shape->translation_scale = 1.0f;
  shape->rotation_scale = 1.0f;
  /* SpaceMouse caps report about +-350 at full deflection (some older
     models +-512), and drift a few units around rest.  */
  shape->deadzone = 0.06f;
  shape->full_scale = 350.0f;
  shape->invert = 0;
  shape->dominant = false;
}

void
cmacs_spnav_shape (const CmacsSpnavShape *shape, const int *raw, float *out)
{
  float v[6], full = shape->full_scale > 1.0f ? shape->full_scale : 1.0f;
  float dz = shape->deadzone < 0.0f ? 0.0f
             : shape->deadzone > 0.95f ? 0.95f : shape->deadzone;
  int i, big = -1;

  /* Normalise, clamp to full deflection, and cut the deadzone out --
     rescaling the rest so the response starts at zero rather than with a
     jump at the deadzone's edge.  */
  for (i = 0; i < 6; i++)
    {
      float a = (float) raw[i] / full;
      float m;

      if (a > 1.0f)
        a = 1.0f;
      else if (a < -1.0f)
        a = -1.0f;
      m = fabsf (a);
      v[i] = m <= dz ? 0.0f : (a > 0.0f ? 1.0f : -1.0f) * (m - dz) / (1.0f - dz);
      if ((shape->invert & (1u << i)) && v[i] != 0.0f)
        v[i] = -v[i];          /* never -0.0: rest must read as 0 */
      if (v[i] != 0.0f && (big < 0 || fabsf (v[i]) > fabsf (v[big])))
        big = i;
    }

  /* Dominant-axis mode: only the strongest axis moves anything, which
     makes a pure pan or a pure twist easy to hold.  */
  if (shape->dominant)
    for (i = 0; i < 6; i++)
      if (i != big)
        v[i] = 0.0f;

  /* Device to intent.  spacenavd reports +Z toward the user, so pushing
     the cap away is -Z: forward is its negation.  Rotations keep the
     right-hand rule about the same axes (+Y up), so a counter-clockwise
     twist seen from above is a positive yaw.  */
  out[0] = v[CMACS_SPNAV_TX];
  out[1] = v[CMACS_SPNAV_TY];
  out[2] = v[CMACS_SPNAV_TZ] != 0.0f ? -v[CMACS_SPNAV_TZ] : 0.0f;
  out[3] = v[CMACS_SPNAV_RX];
  out[4] = v[CMACS_SPNAV_RY];
  out[5] = v[CMACS_SPNAV_RZ];
  for (i = 0; i < 3; i++)
    out[i] *= shape->sensitivity * shape->translation_scale;
  for (i = 3; i < 6; i++)
    out[i] *= shape->sensitivity * shape->rotation_scale;
}

#endif /* HAVE_CMACS_SPACEMOUSE */
