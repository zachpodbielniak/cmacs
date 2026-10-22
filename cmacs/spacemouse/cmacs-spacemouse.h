/* SpaceMouse / 6DOF input for CMacs -- internal interface.

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

SPDX-License-Identifier: AGPL-3.0-or-later  */

#ifndef CMACS_SPACEMOUSE_H
#define CMACS_SPACEMOUSE_H

#include <stdbool.h>

/* ------------------------------------------------------------------
   The split, and why.

   `cmacs-spacemouse-proto.c' is pure arithmetic: decoding spacenavd's
   wire format and shaping six raw axes (deadzone, scale, inversion,
   dominant axis) into a camera intent.  `cmacs-spacemouse-conn.c' owns
   the connection: a socket to spacenavd (or libspnav, where configure
   found it), watched by a GSource on the CMacs GMainContext, so reports
   are read inside Emacs's own pselect -- on the main thread, with no
   thread of our own.  Neither sees `lisp.h'.

   `cmacs-spacemouse-defuns.c' sees `lisp.h': it turns a report into a
   camera move on the target scene (in C, at the device's rate -- Lisp
   never sees motion) or a button into a `<spacemouse-N>' event.

   Everything crossing between them is a plain struct below, so no
   `Lisp_Object' ever lives in GLib memory.
   ------------------------------------------------------------------ */

/* One report from the daemon.  */
enum cmacs_spnav_kind
{
  CMACS_SPNAV_NONE,
  CMACS_SPNAV_MOTION,
  CMACS_SPNAV_BUTTON
};

typedef struct
{
  enum cmacs_spnav_kind kind;
  int axis[6];                   /* MOTION: x y z rx ry rz, raw units */
  unsigned int period_ms;        /* MOTION: ms since the previous one */
  int button;                    /* BUTTON: number, from 0 */
  bool press;                    /* BUTTON: pressed (else released) */
} CmacsSpnavEvent;

/* spacenavd's original ("v0") protocol, which every daemon version still
   speaks to a client that does not ask for more: one packet per report,
   eight native-endian ints.  [0] is 0 motion, 1 press, 2 release; motion
   carries x y z rx ry rz in [1..6] and the period in [7]; a button its
   number in [1].  */
#define CMACS_SPNAV_PACKET_SIZE (8 * 4)

/* Decode one v0 packet.  Returns false (and kind NONE) for an unknown
   report type.  */
extern bool cmacs_spnav_decode_v0 (const unsigned char *buf,
                                   CmacsSpnavEvent *ev);

/* Encode one (for tests and the fake daemon used by them).  */
extern void cmacs_spnav_encode_v0 (const CmacsSpnavEvent *ev,
                                   unsigned char *buf);

/* --------------------------------------------------------- shaping ---- */

/* Axis indices, device order: translation x y z, rotation x y z.  */
enum { CMACS_SPNAV_TX, CMACS_SPNAV_TY, CMACS_SPNAV_TZ,
       CMACS_SPNAV_RX, CMACS_SPNAV_RY, CMACS_SPNAV_RZ };

typedef struct
{
  float sensitivity;             /* overall multiplier */
  float translation_scale;       /* extra multiplier, translation axes */
  float rotation_scale;          /* extra multiplier, rotation axes */
  float deadzone;                /* fraction of full scale ignored */
  float full_scale;              /* raw value that is full deflection */
  unsigned int invert;           /* bit N inverts axis N */
  bool dominant;                 /* only the largest axis passes */
} CmacsSpnavShape;

extern void cmacs_spnav_shape_defaults (CmacsSpnavShape *shape);

/* Shape RAW (device order) into an intent: OUT[0..2] translation (right,
   up, forward -- pushing the cap away is forward), OUT[3..5] rotation
   (pitch, yaw, roll -- a counter-clockwise twist seen from above is a
   positive yaw, a left turn).  Each lies in -S..S where S is the
   applicable scale times the sensitivity; 0 inside the deadzone.  */
extern void cmacs_spnav_shape (const CmacsSpnavShape *shape,
                               const int *raw, float *out);

/* ------------------------------------------------------ connection ---- */

typedef void (*CmacsSpnavHandler) (const CmacsSpnavEvent *ev);

/* Start reading reports, delivering each to HANDLER on the main thread.
   SOCKET_PATH is spacenavd's socket, or NULL for the default (libspnav's
   choice where built with it; else $SPNAV_SOCKET, /run/spnav.sock,
   /var/run/spnav.sock).  With RETRY, a missing daemon is not an error:
   the connection is retried every few seconds, and after a daemon
   restart.  Returns true if connected now.  */
extern bool cmacs_spnav_conn_start (const char *socket_path, bool retry,
                                    CmacsSpnavHandler handler);
extern void cmacs_spnav_conn_stop (void);
extern bool cmacs_spnav_conn_enabled (void);
extern bool cmacs_spnav_conn_connected (void);
/* "libspnav" or "socket" while connected, else NULL.  */
extern const char *cmacs_spnav_conn_backend (void);
/* The socket path in use or being retried (NULL under libspnav).  */
extern const char *cmacs_spnav_conn_socket (void);
/* Connection attempts so far (for status and tests).  */
extern unsigned long cmacs_spnav_conn_attempts (void);

/* Implemented in the DEFUN half.  */
extern void syms_of_cmacs_spacemouse_defuns (void);

#endif /* CMACS_SPACEMOUSE_H */
