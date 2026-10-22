/* SpaceMouse / 6DOF input for CMacs -- targets, events and Lisp API.

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

A motion report moves a camera here, in C, the moment it is read: the
cap's six axes are shaped (deadzone, sensitivity, inversion) and handed
to the target scene's own orbit / pan / zoom.  Lisp chooses the target
and the tuning, and sees only the buttons -- as <spacemouse-N> events --
because a 60 Hz stream of motion through the command loop would be both
slow and pointless.

Targets, `auto' trying them in this order:
  - the VR viewer, while `emacs --lrg=3dvr' presents a headset;
  - the libregnum scene in the selected window (roamgraph, the second
    brain, gnuseye's globe, the CAD viewer, ...);
  - the 3D lrg frame's camera (`emacs --lrg=3d').
or one buffer named with `cmacs-spacemouse-set-target', or `none'.

The handler runs from a GSource dispatch on the main thread, with
`waiting_for_input' already cleared by cmacs_glib_dispatch.  It still
must not signal: it reads C structs, never calls a Lisp F* that can
xsignal, and stores at most a keyboard event.  */

#include <config.h>

#ifdef HAVE_CMACS_SPACEMOUSE

#include <string.h>
#include <glib.h>

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "window.h"
#include "keyboard.h"
#include "termhooks.h"
#include "cmacs-spacemouse.h"
#ifdef HAVE_CMACS_LIBREGNUM
#include "cmacs-libregnum.h"
#endif
#ifdef HAVE_CMACS_LRGTERM
#include "cmacs-lrgterm.h"
#endif

/* Buttons arrive as keystrokes whose codes match no keysym, so Emacs
   names them `key-NNN' (see make_lispy_event); cmacs-spacemouse.el
   translates those to <spacemouse-N> and <spacemouse-N-release>.  The
   base is above the Unicode keysym range (0x0100_0000 + codepoint) and
   the XF86 range (0x1008_FFxx).  */
#define SPACEMOUSE_KEY_BASE    0x10ff0000u
#define SPACEMOUSE_KEY_RELEASE 0x100u
#define SPACEMOUSE_MAX_BUTTON  0xff

#define SPACEMOUSE_RECENT 32

static CmacsSpnavShape sm_shape;
static Lisp_Object sm_target;            /* `auto', `none' or a buffer */
static bool sm_releases;                 /* also send button releases */
static unsigned long sm_motion_count, sm_button_count;
static const char *sm_last_target;       /* static string, or NULL */
static gint64 sm_last_motion_us;

static CmacsSpnavEvent sm_recent[SPACEMOUSE_RECENT];
static int sm_recent_head, sm_recent_len;

static void
sm_record (const CmacsSpnavEvent *ev)
{
  sm_recent[sm_recent_head] = *ev;
  sm_recent_head = (sm_recent_head + 1) % SPACEMOUSE_RECENT;
  if (sm_recent_len < SPACEMOUSE_RECENT)
    sm_recent_len++;
}

/* ---------------------------------------------------------- targets ---- */

#ifdef HAVE_CMACS_LIBREGNUM
/* The buffer in the selected window, or nil.  Read from the C structs:
   nothing here may signal.  */
static Lisp_Object
sm_selected_buffer (void)
{
  if (!WINDOWP (selected_window))
    return Qnil;
  return BUFFERP (XWINDOW (selected_window)->contents)
         ? XWINDOW (selected_window)->contents : Qnil;
}
#endif

/* Move the target camera by intent T (right, up, forward) and R (pitch,
   yaw, roll) over DT seconds.  Returns the target's name, or NULL when
   nothing took it.  */
static const char *
sm_apply_motion (const float *t, const float *r, float dt)
{
  bool any = false;
  int i;

  for (i = 0; i < 3; i++)
    any = any || t[i] != 0.0f || r[i] != 0.0f;
  if (!any || EQ (sm_target, intern_c_string ("none")))
    return NULL;

  if (BUFFERP (sm_target))
    {
#ifdef HAVE_CMACS_LIBREGNUM
      if (BUFFER_LIVE_P (XBUFFER (sm_target))
          && cmacs_libregnum_spacemouse_motion (sm_target, t, r, dt))
        return "buffer";
#endif
      return NULL;
    }

#ifdef HAVE_CMACS_LRGVR
  if (cmacs_lrgvr_spacemouse_motion (t, r, dt))
    return "vr";
#endif
#ifdef HAVE_CMACS_LIBREGNUM
  {
    Lisp_Object buf = sm_selected_buffer ();
    if (!NILP (buf) && cmacs_libregnum_spacemouse_motion (buf, t, r, dt))
      return "libregnum";
  }
#endif
#ifdef HAVE_CMACS_LRGTERM
  {
    struct frame *f = SELECTED_FRAME ();
    if (FRAME_LIVE_P (f) && FRAME_LRG_P (f)
        && cmacs_lrgterm_spacemouse_motion (f, t, r, dt))
      return "lrgterm";
  }
#endif
  return NULL;
}

/* The keystroke code button N is sent as.  */
static unsigned int
sm_key_code (int button, bool release)
{
  return SPACEMOUSE_KEY_BASE + (release ? SPACEMOUSE_KEY_RELEASE : 0)
         + (unsigned int) button;
}

static void
sm_store_button (int button, bool press)
{
  struct input_event ie;
  struct frame *f = SELECTED_FRAME ();

  if (button < 0 || button > SPACEMOUSE_MAX_BUTTON || !FRAME_LIVE_P (f))
    return;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = sm_key_code (button, !press);
  ie.modifiers = 0;
  XSETFRAME (ie.frame_or_window, f);
  ie.timestamp = (Time) (g_get_monotonic_time () / 1000);
  kbd_buffer_store_event (&ie);
}

/* Seconds the report covers: the daemon's period, or the time since the
   last report, bounded so a first push after a long rest does not jump.  */
static float
sm_report_dt (unsigned int period_ms)
{
  gint64 now = g_get_monotonic_time ();
  float dt;

  if (period_ms > 0)
    dt = (float) period_ms / 1000.0f;
  else if (sm_last_motion_us > 0)
    dt = (float) (now - sm_last_motion_us) / 1e6f;
  else
    dt = 1.0f / 60.0f;
  sm_last_motion_us = now;
  if (dt <= 0.0f || dt > 0.1f)
    dt = 1.0f / 60.0f;
  return dt;
}

/* Every report from the connection lands here (main thread).  */
static void
sm_handle (const CmacsSpnavEvent *ev)
{
  sm_record (ev);
  if (ev->kind == CMACS_SPNAV_MOTION)
    {
      float out[6];

      sm_motion_count++;
      cmacs_spnav_shape (&sm_shape, ev->axis, out);
      sm_last_target = sm_apply_motion (out, out + 3,
                                        sm_report_dt (ev->period_ms));
    }
  else if (ev->kind == CMACS_SPNAV_BUTTON)
    {
      sm_button_count++;
      if (ev->press || sm_releases)
        sm_store_button (ev->button, ev->press);
    }
}

/* -------------------------------------------------------------- Lisp ---- */

DEFUN ("cmacs-spacemouse-start", Fcmacs_spacemouse_start,
       Scmacs_spacemouse_start, 0, 2, 0,
       doc: /* Start reading a SpaceMouse (or any 6DOF device) from spacenavd.
SOCKET is the daemon's socket, or nil for the default ($SPNAV_SOCKET,
else /run/spnav.sock or /var/run/spnav.sock; libspnav's own choice where
cmacs was built with libspnav).  A daemon that is not running is not an
error: unless NO-RETRY, the connection is retried every few seconds and
after the daemon restarts.  Return t if connected now, nil if not (yet).

Motion moves a camera in C (see `cmacs-spacemouse-set-target'); buttons
arrive as <spacemouse-1>, <spacemouse-2>, ... events once
`cmacs-spacemouse-mode' has installed their names.  */)
  (Lisp_Object socket, Lisp_Object no_retry)
{
  const char *path = NULL;

  if (!NILP (socket))
    {
      CHECK_STRING (socket);
      socket = ENCODE_FILE (Fexpand_file_name (socket, Qnil));
      path = SSDATA (socket);
    }
  return cmacs_spnav_conn_start (path, NILP (no_retry), sm_handle) ? Qt : Qnil;
}

DEFUN ("cmacs-spacemouse-stop", Fcmacs_spacemouse_stop,
       Scmacs_spacemouse_stop, 0, 0, 0,
       doc: /* Stop reading the SpaceMouse and stop retrying.  */)
  (void)
{
  cmacs_spnav_conn_stop ();
  return Qnil;
}

DEFUN ("cmacs-spacemouse-status", Fcmacs_spacemouse_status,
       Scmacs_spacemouse_status, 0, 0, 0,
       doc: /* Return a plist describing the SpaceMouse connection.
Keys: :enabled (started and not stopped), :connected, :backend
\(\"libspnav\" or \"socket\"), :socket, :attempts (connection attempts),
:motion-events, :button-events, :target, and :last-target -- what the
last motion report moved: `vr', `libregnum', `lrgterm', `buffer' or
nil.  */)
  (void)
{
  const char *b = cmacs_spnav_conn_backend ();
  const char *p = cmacs_spnav_conn_socket ();

  /* Keywords are interned, not DEFSYMed: several are DEFSYMed elsewhere
     (`:target' by office), and a second DEFSYM of a name splits it into
     two symbols.  */
  return list (intern_c_string (":enabled"),
               cmacs_spnav_conn_enabled () ? Qt : Qnil,
               intern_c_string (":connected"),
               cmacs_spnav_conn_connected () ? Qt : Qnil,
               intern_c_string (":backend"),
               b != NULL ? build_string (b) : Qnil,
               intern_c_string (":socket"),
               p != NULL ? build_string (p) : Qnil,
               intern_c_string (":attempts"),
               make_fixnum (cmacs_spnav_conn_attempts ()),
               intern_c_string (":motion-events"), make_fixnum (sm_motion_count),
               intern_c_string (":button-events"), make_fixnum (sm_button_count),
               intern_c_string (":target"), sm_target,
               intern_c_string (":last-target"),
               sm_last_target != NULL ? intern_c_string (sm_last_target) : Qnil);
}

DEFUN ("cmacs-spacemouse-set-target", Fcmacs_spacemouse_set_target,
       Scmacs_spacemouse_set_target, 1, 1, 0,
       doc: /* Choose what SpaceMouse motion moves.
TARGET is `auto' (the VR viewer, else the libregnum scene in the
selected window, else the 3D lrg frame's camera), `none', or a buffer
showing a libregnum scene (roamgraph, the second brain, gnuseye, ...),
which then moves whichever window is selected.  Return TARGET.  */)
  (Lisp_Object target)
{
  if (!EQ (target, intern_c_string ("auto"))
      && !EQ (target, intern_c_string ("none"))
      && !BUFFERP (target))
    wrong_type_argument (intern_c_string ("cmacs-spacemouse-target-p"), target);
  sm_target = target;
  return target;
}

/* Signal unless BUTTON is a button number, 0 .. SPACEMOUSE_MAX_BUTTON.  */
static void
sm_check_button (Lisp_Object button)
{
  CHECK_FIXNAT (button);
  if (XFIXNAT (button) > SPACEMOUSE_MAX_BUTTON)
    args_out_of_range (button, make_fixnum (SPACEMOUSE_MAX_BUTTON));
}

/* The axis bit named by SYM (tx ty tz rx ry rz).  */
static unsigned int
sm_axis_bit (Lisp_Object sym)
{
  static const char *const names[6] = { "tx", "ty", "tz", "rx", "ry", "rz" };
  int i;

  CHECK_SYMBOL (sym);
  for (i = 0; i < 6; i++)
    if (EQ (sym, intern_c_string (names[i])))
      return 1u << i;
  xsignal2 (Qwrong_type_argument, intern_c_string ("cmacs-spacemouse-axis-p"),
            sym);
}

DEFUN ("cmacs-spacemouse-set-option", Fcmacs_spacemouse_set_option,
       Scmacs_spacemouse_set_option, 2, 2, 0,
       doc: /* Set SpaceMouse option KEY to VALUE.
KEY is one of:
  `sensitivity'        overall multiplier (default 1.0)
  `translation-scale'  multiplier for pan and zoom (default 1.0)
  `rotation-scale'     multiplier for orbit and turn (default 1.0)
  `deadzone'           fraction of full deflection ignored around rest
                       (default 0.06)
  `full-scale'         raw reading that is full deflection (default 350)
  `invert'             list of axes to invert, from tx ty tz rx ry rz
  `dominant'           non-nil: only the strongest axis acts at a time
  `releases'           non-nil: also send <spacemouse-N-release>
Return VALUE.  */)
  (Lisp_Object key, Lisp_Object value)
{
  CHECK_SYMBOL (key);
  if (EQ (key, intern_c_string ("invert")))
    {
      unsigned int bits = 0;
      Lisp_Object tail;

      CHECK_LIST (value);
      for (tail = value; CONSP (tail); tail = XCDR (tail))
        bits |= sm_axis_bit (XCAR (tail));
      sm_shape.invert = bits;
      return value;
    }
  if (EQ (key, intern_c_string ("dominant")))
    {
      sm_shape.dominant = !NILP (value);
      return value;
    }
  if (EQ (key, intern_c_string ("releases")))
    {
      sm_releases = !NILP (value);
      return value;
    }

  CHECK_NUMBER (value);
  if (EQ (key, intern_c_string ("sensitivity")))
    sm_shape.sensitivity = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("translation-scale")))
    sm_shape.translation_scale = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("rotation-scale")))
    sm_shape.rotation_scale = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("deadzone")))
    {
      double d = XFLOATINT (value);
      if (d < 0.0 || d > 0.95)
        args_out_of_range (value, make_float (0.95));
      sm_shape.deadzone = (float) d;
    }
  else if (EQ (key, intern_c_string ("full-scale")))
    {
      if (XFLOATINT (value) < 1.0)
        args_out_of_range (value, make_fixnum (1));
      sm_shape.full_scale = (float) XFLOATINT (value);
    }
  else
    error ("Unknown SpaceMouse option");
  return value;
}

DEFUN ("cmacs-spacemouse-key-code", Fcmacs_spacemouse_key_code,
       Scmacs_spacemouse_key_code, 1, 2, 0,
       doc: /* Return the keystroke code SpaceMouse BUTTON arrives as.
BUTTON counts from 0, as spacenavd numbers them.  With RELEASE, the code
of its release.  Emacs names an event with this code `key-CODE';
`cmacs-spacemouse-mode' translates it to <spacemouse-N>, N = BUTTON + 1.  */)
  (Lisp_Object button, Lisp_Object release)
{
  sm_check_button (button);
  return make_fixnum (sm_key_code ((int) XFIXNUM (button), !NILP (release)));
}

DEFUN ("cmacs-spacemouse--shape", Fcmacs_spacemouse__shape,
       Scmacs_spacemouse__shape, 6, 6, 0,
       doc: /* Shape raw axes TX TY TZ RX RY RZ with the current options.
For tests.  Return a vector [RIGHT UP FORWARD PITCH YAW ROLL] of floats:
what a report with those raw values would move a camera by, per unit of
rate.  */)
  (Lisp_Object tx, Lisp_Object ty, Lisp_Object tz, Lisp_Object rx,
   Lisp_Object ry, Lisp_Object rz)
{
  Lisp_Object args[6] = { tx, ty, tz, rx, ry, rz };
  int raw[6], i;
  float out[6];

  for (i = 0; i < 6; i++)
    {
      CHECK_FIXNUM (args[i]);
      raw[i] = (int) XFIXNUM (args[i]);
    }
  cmacs_spnav_shape (&sm_shape, raw, out);
  return CALLN (Fvector, make_float (out[0]), make_float (out[1]),
                make_float (out[2]), make_float (out[3]), make_float (out[4]),
                make_float (out[5]));
}

DEFUN ("cmacs-spacemouse--inject", Fcmacs_spacemouse__inject,
       Scmacs_spacemouse__inject, 1, 1, 0,
       doc: /* Handle EVENT as if spacenavd had sent it.  For tests.
EVENT is (motion TX TY TZ RX RY RZ [PERIOD-MS]) or (button N PRESSED).
A motion moves the current target; a button stores its event.  Return
what the motion moved (as :last-target in `cmacs-spacemouse-status'),
or nil.  */)
  (Lisp_Object event)
{
  CmacsSpnavEvent ev;
  Lisp_Object kind, args;
  int i;

  CHECK_CONS (event);
  memset (&ev, 0, sizeof ev);
  kind = XCAR (event);
  args = XCDR (event);
  if (EQ (kind, intern_c_string ("motion")))
    {
      ev.kind = CMACS_SPNAV_MOTION;
      for (i = 0; i < 6; i++, args = XCDR (args))
        {
          CHECK_CONS (args);
          CHECK_FIXNUM (XCAR (args));
          ev.axis[i] = (int) XFIXNUM (XCAR (args));
        }
      if (CONSP (args))
        {
          CHECK_FIXNAT (XCAR (args));
          ev.period_ms = (unsigned int) XFIXNAT (XCAR (args));
        }
    }
  else if (EQ (kind, intern_c_string ("button")))
    {
      CHECK_CONS (args);
      sm_check_button (XCAR (args));
      ev.kind = CMACS_SPNAV_BUTTON;
      ev.button = (int) XFIXNUM (XCAR (args));
      ev.press = CONSP (XCDR (args)) && !NILP (XCAR (XCDR (args)));
    }
  else
    error ("SpaceMouse event must be (motion ...) or (button ...)");
  sm_last_target = NULL;
  sm_handle (&ev);
  return sm_last_target != NULL ? intern_c_string (sm_last_target) : Qnil;
}

DEFUN ("cmacs-spacemouse--recent-events", Fcmacs_spacemouse__recent_events,
       Scmacs_spacemouse__recent_events, 0, 1, 0,
       doc: /* Return the last reports received, oldest first.  For tests.
Each is (motion TX TY TZ RX RY RZ PERIOD) or (button N press|release).
With CLEAR non-nil, forget them afterwards.  */)
  (Lisp_Object clear)
{
  Lisp_Object out = Qnil;
  int k;

  for (k = 0; k < sm_recent_len; k++)
    {
      int at = (sm_recent_head - 1 - k + SPACEMOUSE_RECENT) % SPACEMOUSE_RECENT;
      const CmacsSpnavEvent *ev = &sm_recent[at];
      Lisp_Object item;

      if (ev->kind == CMACS_SPNAV_MOTION)
        item = list (intern_c_string ("motion"), make_fixnum (ev->axis[0]),
                     make_fixnum (ev->axis[1]), make_fixnum (ev->axis[2]),
                     make_fixnum (ev->axis[3]), make_fixnum (ev->axis[4]),
                     make_fixnum (ev->axis[5]), make_fixnum (ev->period_ms));
      else
        item = list3 (intern_c_string ("button"), make_fixnum (ev->button),
                      intern_c_string (ev->press ? "press" : "release"));
      out = Fcons (item, out);
    }
  if (!NILP (clear))
    sm_recent_len = sm_recent_head = 0;
  return out;
}

DEFUN ("cmacs-spacemouse--packet", Fcmacs_spacemouse__packet,
       Scmacs_spacemouse__packet, 1, 1, 0,
       doc: /* Return EVENT as spacenavd's wire packet, a unibyte string.
For tests, which play the daemon.  EVENT is as for
`cmacs-spacemouse--inject'.  */)
  (Lisp_Object event)
{
  CmacsSpnavEvent ev;
  unsigned char buf[CMACS_SPNAV_PACKET_SIZE];
  Lisp_Object kind, args;
  int i;

  CHECK_CONS (event);
  memset (&ev, 0, sizeof ev);
  kind = XCAR (event);
  args = XCDR (event);
  if (EQ (kind, intern_c_string ("motion")))
    {
      ev.kind = CMACS_SPNAV_MOTION;
      for (i = 0; i < 6; i++, args = XCDR (args))
        {
          CHECK_CONS (args);
          CHECK_FIXNUM (XCAR (args));
          ev.axis[i] = (int) XFIXNUM (XCAR (args));
        }
      if (CONSP (args))
        {
          CHECK_FIXNAT (XCAR (args));
          ev.period_ms = (unsigned int) XFIXNAT (XCAR (args));
        }
    }
  else
    {
      CHECK_CONS (args);
      CHECK_FIXNUM (XCAR (args));
      ev.kind = CMACS_SPNAV_BUTTON;
      ev.button = (int) XFIXNUM (XCAR (args));
      ev.press = CONSP (XCDR (args)) && !NILP (XCAR (XCDR (args)));
    }
  cmacs_spnav_encode_v0 (&ev, buf);
  return make_unibyte_string ((const char *) buf, sizeof buf);
}

void
syms_of_cmacs_spacemouse_defuns (void)
{
  cmacs_spnav_shape_defaults (&sm_shape);

  sm_target = intern_c_string ("auto");
  staticpro (&sm_target);

  defsubr (&Scmacs_spacemouse_start);
  defsubr (&Scmacs_spacemouse_stop);
  defsubr (&Scmacs_spacemouse_status);
  defsubr (&Scmacs_spacemouse_set_target);
  defsubr (&Scmacs_spacemouse_set_option);
  defsubr (&Scmacs_spacemouse_key_code);
  defsubr (&Scmacs_spacemouse__shape);
  defsubr (&Scmacs_spacemouse__inject);
  defsubr (&Scmacs_spacemouse__recent_events);
  defsubr (&Scmacs_spacemouse__packet);
}

#endif /* HAVE_CMACS_SPACEMOUSE */
