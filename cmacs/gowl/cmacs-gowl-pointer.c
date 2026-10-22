/* cmacs-gowl-pointer.c --- injected pointer input for the gowl desktop
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-gowl-pointer.h.  */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <math.h>
#include <string.h>

#include "lisp.h"
#include "cmacs-gowl.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-gowl-pointer.h"

/* ------------------------------------------------------------- C half -- */

/* Whether injected input may go to the desktop now.  Caller holds the
   lock.  */
static enum cmacs_gowl_pointer_status
pointer_check (void)
{
  if (cmacs_gowl_compositor == NULL)
    return CMACS_GOWL_POINTER_NOT_RUNNING;
  if (gowl_compositor_is_locked (cmacs_gowl_compositor))
    return CMACS_GOWL_POINTER_LOCKED;
  return CMACS_GOWL_POINTER_OK;
}

enum cmacs_gowl_pointer_status
cmacs_gowl_pointer_warp (double x, double y)
{
  enum cmacs_gowl_pointer_status st;

  cmacs_gowl_lock ();
  st = pointer_check ();
  /* gowl's layout-absolute *motion*, not a warp: it obeys a lock or a
     confinement exactly as a physical device does (and reports relative
     motion to a locked client from the previous asked-for position).  */
  if (st == CMACS_GOWL_POINTER_OK)
    gowl_compositor_inject_pointer_warp (cmacs_gowl_compositor, x, y);
  cmacs_gowl_unlock ();
  return st;
}

enum cmacs_gowl_pointer_status
cmacs_gowl_pointer_move (double dx, double dy)
{
  enum cmacs_gowl_pointer_status st;

  cmacs_gowl_lock ();
  st = pointer_check ();
  if (st == CMACS_GOWL_POINTER_OK)
    gowl_compositor_inject_pointer_motion (cmacs_gowl_compositor, dx, dy);
  cmacs_gowl_unlock ();
  return st;
}

enum cmacs_gowl_pointer_status
cmacs_gowl_pointer_button (unsigned int button, bool pressed)
{
  enum cmacs_gowl_pointer_status st;

  cmacs_gowl_lock ();
  st = pointer_check ();
  /* Through the compositor's button handling: its hit test (the bar is
     clickable) and its focus rules, the ones a real click gets -- so a
     click never moves focus by any path the compositor would refuse.
     A release is delivered even when locked: a button held as the lock
     came up must not stay down.  */
  if (st == CMACS_GOWL_POINTER_OK
      || (st == CMACS_GOWL_POINTER_LOCKED && !pressed))
    gowl_compositor_inject_button (cmacs_gowl_compositor, button, pressed);
  cmacs_gowl_unlock ();
  return st;
}

enum cmacs_gowl_pointer_status
cmacs_gowl_pointer_scroll (bool horizontal, double notches)
{
  enum cmacs_gowl_pointer_status st;
  int v120;

  cmacs_gowl_lock ();
  st = pointer_check ();
  /* A discrete value120 alongside the continuous amount: with it gowl
     reports a WHEEL source, without it CONTINUOUS.  A wheel with no
     discrete amount scrolls by nothing in Firefox.  */
  v120 = (int) lround (notches * 120.0);
  if (st == CMACS_GOWL_POINTER_OK && notches != 0.0)
    gowl_compositor_inject_axis (cmacs_gowl_compositor, horizontal,
                                 notches * CMACS_GOWL_SCROLL_PER_NOTCH, v120);
  cmacs_gowl_unlock ();
  return st;
}

bool
cmacs_gowl_pointer_position (double *x, double *y)
{
  bool ok = false;

  cmacs_gowl_lock ();
  if (cmacs_gowl_compositor != NULL)
    ok = gowl_compositor_get_cursor_position (cmacs_gowl_compositor, x, y);
  cmacs_gowl_unlock ();
  return ok;
}

bool
cmacs_gowl_output_geometry (const char *name, int *x, int *y, int *w,
                            int *h)
{
  GList *l;
  double cx = 0.0, cy = 0.0;
  bool have_cursor, found = false;

  cmacs_gowl_lock ();
  if (cmacs_gowl_compositor == NULL)
    {
      cmacs_gowl_unlock ();
      return false;
    }
  have_cursor = gowl_compositor_get_cursor_position (cmacs_gowl_compositor,
                                                     &cx, &cy);
  for (l = gowl_compositor_get_monitors (cmacs_gowl_compositor);
       l != NULL && !found; l = l->next)
    {
      GowlMonitor *m = l->data;
      gint mx = 0, my = 0, mw = 0, mh = 0;

      gowl_monitor_get_geometry (m, &mx, &my, &mw, &mh);
      if (name != NULL)
        found = g_strcmp0 (gowl_monitor_get_name (m), name) == 0;
      else
        found = !have_cursor
                || (cx >= mx && cx < mx + mw && cy >= my && cy < my + mh);
      if (found)
        {
          *x = mx;
          *y = my;
          *w = mw;
          *h = mh;
        }
    }
  /* Under the pointer and nothing matched (it sits in a gap): the
     first output.  */
  if (!found && name == NULL)
    {
      l = gowl_compositor_get_monitors (cmacs_gowl_compositor);
      if (l != NULL)
        {
          gint mx = 0, my = 0, mw = 0, mh = 0;
          gowl_monitor_get_geometry (l->data, &mx, &my, &mw, &mh);
          *x = mx;
          *y = my;
          *w = mw;
          *h = mh;
          found = true;
        }
    }
  cmacs_gowl_unlock ();
  return found;
}

/* ----------------------------------------------------------- Lisp half -- */

/* Hold the gowl lock for the rest of this call; the release is on the
   specpdl, so an `error' below cannot leave the dispatch thread
   wedged (see cmacs-gowl.c's own, which this mirrors).  */
static specpdl_ref
cmacs_gowl_lock_scoped (void)
{
  specpdl_ref count = SPECPDL_INDEX ();

  cmacs_gowl_lock ();
  record_unwind_protect_void (cmacs_gowl_unlock);
  return count;
}

/* Signal for a refused call.  Caller holds the scoped lock; the specpdl
   releases it as the error unwinds.  */
static void
pointer_signal (enum cmacs_gowl_pointer_status st)
{
  if (st == CMACS_GOWL_POINTER_NOT_RUNNING)
    error ("Gowl compositor not running");
  if (st == CMACS_GOWL_POINTER_LOCKED)
    error ("The session is locked: injected input goes nowhere");
}

static unsigned int
pointer_button_code (Lisp_Object button)
{
  if (FIXNATP (button))
    return (unsigned int) XFIXNAT (button);
  if (EQ (button, intern_c_string ("left")))
    return CMACS_GOWL_BTN_LEFT;
  if (EQ (button, intern_c_string ("right")))
    return CMACS_GOWL_BTN_RIGHT;
  if (EQ (button, intern_c_string ("middle")))
    return CMACS_GOWL_BTN_MIDDLE;
  if (EQ (button, intern_c_string ("back")))
    return CMACS_GOWL_BTN_BACK;
  if (EQ (button, intern_c_string ("forward")))
    return CMACS_GOWL_BTN_FORWARD;
  xsignal2 (Qwrong_type_argument, intern_c_string ("gowl-pointer-button-p"),
            button);
}

DEFUN ("gowl-pointer-position", Fgowl_pointer_position,
       Sgowl_pointer_position, 0, 0, 0,
       doc: /* Return the pointer's position, (X . Y) in layout pixels.
Return nil when the compositor is not running.  */)
  (void)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  double x = 0.0, y = 0.0;

  if (cmacs_gowl_compositor == NULL
      || !gowl_compositor_get_cursor_position (cmacs_gowl_compositor, &x, &y))
    return unbind_to (lock_count, Qnil);
  return unbind_to (lock_count, Fcons (make_float (x), make_float (y)));
}

DEFUN ("gowl-pointer-warp", Fgowl_pointer_warp, Sgowl_pointer_warp, 2, 2, 0,
       doc: /* Move the pointer to X, Y in output-layout pixels.
This is injected motion, as a software KVM sends it: a point off the
layout is clamped onto it, a locked pointer stays where it is (the
locked client is told the motion), a confined one slides along its
region.  Signal while the session is locked.  Return the new position,
as `gowl-pointer-position'.  */)
  (Lisp_Object x, Lisp_Object y)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  enum cmacs_gowl_pointer_status st;

  CHECK_NUMBER (x);
  CHECK_NUMBER (y);
  st = cmacs_gowl_pointer_warp (XFLOATINT (x), XFLOATINT (y));
  pointer_signal (st);
  return unbind_to (lock_count, Fgowl_pointer_position ());
}

DEFUN ("gowl-pointer-move", Fgowl_pointer_move, Sgowl_pointer_move, 2, 2, 0,
       doc: /* Move the pointer by DX, DY layout pixels (relative motion).
Constraints apply as for `gowl-pointer-warp'.  Return the new position.  */)
  (Lisp_Object dx, Lisp_Object dy)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  enum cmacs_gowl_pointer_status st;

  CHECK_NUMBER (dx);
  CHECK_NUMBER (dy);
  st = cmacs_gowl_pointer_move (XFLOATINT (dx), XFLOATINT (dy));
  pointer_signal (st);
  return unbind_to (lock_count, Fgowl_pointer_position ());
}

DEFUN ("gowl-pointer-button", Fgowl_pointer_button, Sgowl_pointer_button,
       1, 2, 0,
       doc: /* Press, release or click BUTTON at the pointer.
BUTTON is `left', `right', `middle', `back', `forward' or an evdev code.
STATE is `press', `release', or nil for a click (press then release).
The click goes through the compositor's own hit test and focus rules,
as a real one does.  A press signals while the session is locked; a
release never does, so nothing is left held.  Return BUTTON.  */)
  (Lisp_Object button, Lisp_Object state)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  unsigned int code = pointer_button_code (button);
  enum cmacs_gowl_pointer_status st;

  if (EQ (state, intern_c_string ("release")))
    {
      st = cmacs_gowl_pointer_button (code, false);
      if (st == CMACS_GOWL_POINTER_NOT_RUNNING)
        pointer_signal (st);
    }
  else if (EQ (state, intern_c_string ("press")))
    pointer_signal (cmacs_gowl_pointer_button (code, true));
  else if (NILP (state))
    {
      pointer_signal (cmacs_gowl_pointer_button (code, true));
      cmacs_gowl_pointer_button (code, false);
    }
  else
    xsignal2 (Qwrong_type_argument, intern_c_string ("gowl-button-state-p"),
              state);
  return unbind_to (lock_count, button);
}

DEFUN ("gowl-pointer-scroll", Fgowl_pointer_scroll, Sgowl_pointer_scroll,
       1, 2, 0,
       doc: /* Scroll at the pointer by DY wheel notches (positive: down).
DX, if given, scrolls horizontally (positive: right).  Notches may be
fractional; each carries its discrete value120 (120 per notch), so the
scroll is reported as a wheel.  Signal while the session is locked.  */)
  (Lisp_Object dy, Lisp_Object dx)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();

  CHECK_NUMBER (dy);
  if (!NILP (dx))
    CHECK_NUMBER (dx);
  pointer_signal (cmacs_gowl_pointer_scroll (false, XFLOATINT (dy)));
  if (!NILP (dx))
    pointer_signal (cmacs_gowl_pointer_scroll (true, XFLOATINT (dx)));
  return unbind_to (lock_count, Qnil);
}

DEFUN ("gowl-output-geometry", Fgowl_output_geometry,
       Sgowl_output_geometry, 0, 1, 0,
       doc: /* Return output NAME's layout geometry as (X Y WIDTH HEIGHT).
NAME nil: the output under the pointer (else the first).  Return nil
when there is no such output or no compositor.  */)
  (Lisp_Object name)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  int x = 0, y = 0, w = 0, h = 0;

  if (!NILP (name))
    CHECK_STRING (name);
  if (cmacs_gowl_compositor == NULL
      || !cmacs_gowl_output_geometry (NILP (name) ? NULL : SSDATA (name),
                                      &x, &y, &w, &h))
    return unbind_to (lock_count, Qnil);
  return unbind_to (lock_count, list4 (make_fixnum (x), make_fixnum (y),
                                       make_fixnum (w), make_fixnum (h)));
}

void
syms_of_cmacs_gowl_pointer (void)
{
  defsubr (&Sgowl_pointer_position);
  defsubr (&Sgowl_pointer_warp);
  defsubr (&Sgowl_pointer_move);
  defsubr (&Sgowl_pointer_button);
  defsubr (&Sgowl_pointer_scroll);
  defsubr (&Sgowl_output_geometry);
}

#endif /* HAVE_CMACS_GOWL */
