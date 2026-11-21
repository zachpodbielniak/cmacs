/* Camera hand tracking for CMacs -- the main-thread half and Lisp API.

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

Each inference result arrives here on the main thread (through the CMacs
GLib loop, see cmacs-handtrack-worker.c) and goes the way a headset's
hands go: into libregnum's LrgVRHandState, through its pinch latch and
palm test, and into the shared gesture classifier
(cmacs-hand-gesture.c).  On the desktop there is no laser, so every
sample's target is CMACS_HG_NONE: a quick pinch is a tap, a pinch moved
pulls -- here, orbits the scene in the selected window, at frame rate, in
C -- and both hands pinching zoom it.  The discrete results become
<hand-...> events.

Runs from a GLib dispatch: it must not signal, so it reads C structs and
stores keyboard events, nothing more.  */

#include <config.h>

#ifdef HAVE_CMACS_HANDTRACK

#include <math.h>
#include <string.h>

#include "lisp.h"
#include "buffer.h"
#include "frame.h"
#include "window.h"
#include "keyboard.h"
#include "termhooks.h"
#include "coding.h"
#include "cmacs-hand-gesture.h"
#include "cmacs-handtrack.h"
#include "cmacs-handtrack-point-history.h"
#include "cmacs-libregnum.h"
#ifdef HAVE_CMACS_GOWL
#include "cmacs-gowl-pointer.h"
#include "cmacs-gowl-pointer-history.h"
#endif
#include "cmacs-glib-loop.h"

/* Gesture events are keystrokes whose codes match no keysym (Emacs names
   them key-NNN; cmacs-handtrack.el translates them), as the SpaceMouse's
   buttons are, in a range of their own.  */
#define HT_KEY_BASE 0x10fe0000u
enum ht_event
{
  HT_EV_LEFT_PINCH, HT_EV_RIGHT_PINCH, HT_EV_LEFT_PALM_UP, HT_EV_RIGHT_PALM_UP,
  HT_EV_LEFT_PALM_DOWN, HT_EV_RIGHT_PALM_DOWN, HT_EV_ZOOM_IN, HT_EV_ZOOM_OUT,
  HT_EV_COUNT
};
static const char *const ht_event_names[HT_EV_COUNT] = {
  "hand-left-pinch", "hand-right-pinch", "hand-left-palm-up",
  "hand-right-palm-up", "hand-left-palm-down", "hand-right-palm-down",
  "hand-zoom-in", "hand-zoom-out"
};

#define HT_ACTIONS 24

/* ---------------------------------------------------------------------
   The hand cursor: one hand drives the gowl desktop's pointer.

   Per frame, in C on the main thread, never through Lisp: the point
   between the thumb and index knuckles (it barely moves as the fingers
   close, so a pinch does not jog the pointer) is mapped from an active
   region of the camera image onto one output, smoothed with a One-Euro
   filter (steady when still, quick when moving), and sent through
   cmacs-gowl-pointer.c -- gowl's injected-input path, under the gowl
   lock -- when it has moved past a deadzone.

   Clicks come from the shared gesture classifier, with the target
   chosen per pinch: a thumb-index pinch is "nothing" (tap = left click,
   moved = drag with the left button held); a pinch with the middle
   finger as well is a "panel" (moved = scroll, the content following
   the hand, with the pointer held where the pinch began; tapped = right
   click).

   A lost hand never leaves a button down: the classifier ends a pinch
   whose hand left view, and a watchdog on the CMacs context releases
   anything held once no result has arrived for CMACS_HT_RELEASE_US
   (a camera that stopped, an inference thread that stalled).
   --------------------------------------------------------------------- */

#define CMACS_HT_RELEASE_US 400000     /* no hand this long: let go */
#define CMACS_HT_TWO_FINGER_M 0.035f   /* middle tip near the thumb tip */

/* Where pointer output goes: the desktop, or a recorder for tests.  */
struct ht_pointer_out
{
  void (*warp) (struct ht_pointer_out *, double, double);
  void (*button) (struct ht_pointer_out *, unsigned int, bool);
  void (*scroll) (struct ht_pointer_out *, bool, double);
  Lisp_Object *log;              /* recorder: the calls, newest first */
};

struct ht_euro
{
  bool init;
  double x, dx;
};

struct ht_cursor
{
  bool enabled;
  int hand;                      /* 0 left, 1 right */
  float region[4];               /* x0 y0 x1 y1 of the (mirrored) image */
  char output[64];               /* "" : the output under the pointer */
  float deadzone_px;
  float min_cutoff, beta;        /* One-Euro parameters */
  struct ht_euro ex, ey;
  bool have_last;
  double last_x, last_y;         /* last position sent */
  gint64 last_us;                /* last filter step */
  bool held;                     /* left button down (a drag) */
  bool two_finger;               /* the current pinch includes the middle */
  bool was_pinched;
  gint64 seen_us;                /* last result with the cursor hand */
};

/* Hands as the classifier sees them, frame after frame.  */
struct ht_tracker
{
  LrgVRHandState hands[2];       /* 0 left, 1 right */
  struct cmacs_hg_state g;
  /* The landmarks each side was mapped from in the frame ht_track last
     saw, or NULL.  They point into that call's argument: read them
     before it goes away (ht_point_step does, straight after) and never
     later.  */
  const CmacsHtLandmarks *lm[2];
};

static struct
{
  struct ht_tracker tr;
  struct ht_cursor cursor;
  guint watchdog;                /* GSource id on the CMacs context */
  Lisp_Object target;            /* auto, none or a buffer; staticpro'd */
  bool swap_hands;               /* handedness the other way round */
  float palm_threshold, presence_threshold;
  float orbit_gain;              /* mouse pixels per metre of pull */
  float zoom_gain;               /* wheel ticks per e-fold of stretch */
  float zoom_prev;
  unsigned long results, events;
  gint64 latency_us;
  int last_n;
} hd = {
  .palm_threshold = 0.5f, .presence_threshold = 0.5f,
  .orbit_gain = 2500.0f, .zoom_gain = 9.5f,
  .cursor = { .hand = 1, .region = { 0.2f, 0.2f, 0.8f, 0.8f },
              .deadzone_px = 1.5f, .min_cutoff = 1.2f, .beta = 0.02f },
};

/* ----------------------------------------------------------- the cursor -- */

static double
euro_alpha (double cutoff, double dt)
{
  double tau = 1.0 / (2.0 * G_PI * cutoff);
  return 1.0 / (1.0 + tau / dt);
}

/* One-Euro filter step: the cutoff rises with speed, so a still hand is
   smoothed hard and a moving one follows without lag.  */
static double
euro_step (struct ht_euro *e, double x, double dt, double min_cutoff,
           double beta)
{
  double dx, a;

  if (!e->init || dt <= 0.0)
    {
      e->init = true;
      e->x = x;
      e->dx = 0.0;
      return x;
    }
  dx = (x - e->x) / dt;
  a = euro_alpha (1.0, dt);
  e->dx = e->dx + a * (dx - e->dx);
  a = euro_alpha (min_cutoff + beta * fabs (e->dx), dt);
  e->x = e->x + a * (x - e->x);
  return e->x;
}

/* The camera's active region onto an output: image point IU, IV
   (image-normalised, mirrored) as *U, *V, 0..1 across REGION and
   clamped to it.  Returns how far outside the region the point was, as
   a fraction of the region's size (<= 0: inside).  The one place this
   arithmetic lives: the hand cursor and a bare pointing hand
   (ht_point_step) both go through it, so "the edge of the region is the
   edge of the screen" means the same to both.  */
static float
ht_region_uv (const float *region, float iu, float iv, float *u, float *v)
{
  float rw = region[2] - region[0], rh = region[3] - region[1];
  float ru = rw > 1e-3f ? (iu - region[0]) / rw : 0.5f;
  float rv = rh > 1e-3f ? (iv - region[1]) / rh : 0.5f;

  *u = CLAMP (ru, 0.0f, 1.0f);
  *v = CLAMP (rv, 0.0f, 1.0f);
  return fmaxf (fmaxf (-ru, ru - 1.0f), fmaxf (-rv, rv - 1.0f));
}

/* U, V (0..1 across the output) as layout pixels on output GEOM,
   through a One-Euro filter whose state is EX, EY and *LAST_US.  NOW is
   in microseconds.  */
static void
ht_output_smooth (struct ht_euro *ex, struct ht_euro *ey, gint64 *last_us,
                  float u, float v, const int *geom, gint64 now,
                  double min_cutoff, double beta, double *x, double *y)
{
  double dt = *last_us > 0 ? (double) (now - *last_us) / 1e6 : 0.0;

  if (dt > 0.5)
    dt = 0.0;                    /* back after a gap: start afresh */
  *x = euro_step (ex, geom[0] + (double) u * (geom[2] - 1), dt, min_cutoff,
                  beta);
  *y = euro_step (ey, geom[1] + (double) v * (geom[3] - 1), dt, min_cutoff,
                  beta);
  *last_us = now;
}

/* The cursor hand's pointer position on output GEOM, smoothed, from
   landmarks LM (image-normalised, mirrored).  */
static void
cursor_target (struct ht_cursor *c, const CmacsHtLandmarks *lm,
               const int *geom, gint64 now, double *x, double *y)
{
  float u, v;

  ht_region_uv (c->region, 0.5f * (lm->lm[2][0] + lm->lm[5][0]),
                0.5f * (lm->lm[2][1] + lm->lm[5][1]), &u, &v);
  ht_output_smooth (&c->ex, &c->ey, &c->last_us, u, v, geom, now,
                    c->min_cutoff, c->beta, x, y);
}

static void
cursor_release (struct ht_cursor *c, struct ht_pointer_out *out)
{
  if (c->held)
    out->button (out, 0x110, false);
  c->held = false;
}

/* The real output: gowl, under its lock (cmacs-gowl-pointer.c).  */
static void
desk_warp (struct ht_pointer_out *o, double x, double y)
{
  (void) o;
#ifdef HAVE_CMACS_GOWL
  cmacs_gowl_pointer_warp (x, y);
#else
  (void) x;
  (void) y;
#endif
}

static void
desk_button (struct ht_pointer_out *o, unsigned int b, bool pressed)
{
  (void) o;
#ifdef HAVE_CMACS_GOWL
  cmacs_gowl_pointer_button (b, pressed);
#else
  (void) b;
  (void) pressed;
#endif
}

static void
desk_scroll (struct ht_pointer_out *o, bool horizontal, double notches)
{
  (void) o;
#ifdef HAVE_CMACS_GOWL
  cmacs_gowl_pointer_scroll (horizontal, notches);
#else
  (void) horizontal;
  (void) notches;
#endif
}

static struct ht_pointer_out ht_desktop = {
  desk_warp, desk_button, desk_scroll, NULL
};

/* The test recorder: (warp X Y) (button CODE press|release)
   (scroll HORIZONTAL NOTCHES), newest first.  */
static void
rec_warp (struct ht_pointer_out *o, double x, double y)
{
  *o->log = Fcons (list3 (intern_c_string ("warp"), make_fixnum (lround (x)),
                          make_fixnum (lround (y))), *o->log);
}

static void
rec_button (struct ht_pointer_out *o, unsigned int b, bool pressed)
{
  *o->log = Fcons (list3 (intern_c_string ("button"), make_fixnum (b),
                          intern_c_string (pressed ? "press" : "release")),
                   *o->log);
}

static void
rec_scroll (struct ht_pointer_out *o, bool horizontal, double notches)
{
  *o->log = Fcons (list3 (intern_c_string ("scroll"), horizontal ? Qt : Qnil,
                          make_float (notches)), *o->log);
}


/* ---------------------------------------------------------- tracking -- */

/* Advance TR by one frame of N camera hands at NOW; write the gestures
   to OUT.  ASPECT is the frame's height / width.  */
static int
ht_track (struct ht_tracker *tr, const CmacsHtLandmarks *lm, int n,
          float aspect, gint64 now, struct ht_cursor *cur, const int *geom,
          struct ht_pointer_out *pout, struct cmacs_hg_action *out, int max)
{
  struct cmacs_hg_sample smp[2];
  const CmacsHtLandmarks *side_lm[2] = { NULL, NULL };
  bool seen[2] = { false, false };
  bool was[2];
  int i, side;

  was[0] = tr->hands[0].active && tr->hands[0].pinched;
  was[1] = tr->hands[1].active && tr->hands[1].pinched;

  for (i = 0; i < n && i < CMACS_HT_MAX_HANDS; i++)
    {
      side = (lm[i].handedness > 0.5f) != hd.swap_hands ? 1 : 0;
      /* The model called both hands the same: the second takes the
         other side.  */
      if (seen[side])
        side = 1 - side;
      if (seen[side])
        continue;
      cmacs_ht_to_hand_state (&lm[i], aspect, side == 1, &tr->hands[side]);
      seen[side] = true;
      side_lm[side] = &lm[i];
    }
  tr->lm[0] = side_lm[0];
  tr->lm[1] = side_lm[1];
  memset (smp, 0, sizeof smp);
  for (side = 0; side < 2; side++)
    {
      LrgVRHandState *st = &tr->hands[side];

      if (!seen[side])
        {
          lrg_vr_hand_state_reset (st);
          continue;
        }
      lrg_vr_hand_state_update_pinch (st, was[side]);
      smp[side].tracked = true;
      smp[side].pinched = lrg_vr_hand_state_is_pinched (st);
      smp[side].palm_up = lrg_vr_hand_state_is_palm_up (st, CMACS_HG_PALM_COS);
      smp[side].target = CMACS_HG_NONE;
      if (!lrg_vr_hand_state_get_pinch_point (st, smp[side].pos))
        lrg_vr_hand_state_get_joint_position (st, LRG_VR_HAND_JOINT_PALM,
                                              &smp[side].pos[0],
                                              &smp[side].pos[1],
                                              &smp[side].pos[2]);
    }

  /* The cursor hand: its pointer, and the kind of pinch it makes.  */
  if (cur != NULL && cur->enabled && geom != NULL)
    {
      side = cur->hand;
      if (seen[side])
        {
          double x, y;
          bool pinched = smp[side].pinched;

          cur->seen_us = now;
          if (pinched && !cur->was_pinched)
            {
              float mt[3], tt[3], d[3];
              const LrgVRHandState *st = &tr->hands[side];
              lrg_vr_hand_state_get_joint_position (st, LRG_VR_HAND_JOINT_MIDDLE_TIP,
                                                    &mt[0], &mt[1], &mt[2]);
              lrg_vr_hand_state_get_joint_position (st, LRG_VR_HAND_JOINT_THUMB_TIP,
                                                    &tt[0], &tt[1], &tt[2]);
              d[0] = mt[0] - tt[0];
              d[1] = mt[1] - tt[1];
              d[2] = mt[2] - tt[2];
              cur->two_finger = sqrtf (d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                                < CMACS_HT_TWO_FINGER_M;
            }
          cur->was_pinched = pinched;
          cursor_target (cur, side_lm[side], geom, now, &x, &y);
          smp[side].target = cur->two_finger && pinched ? CMACS_HG_PANEL
                             : CMACS_HG_NONE;
          /* The hand's own position feeds the scroll; the pointer stays
             where a two-finger pinch began.  */
          smp[side].fx = (int) lround (x);
          smp[side].fy = (int) lround (y);
          if (!(cur->two_finger && pinched)
              && (!cur->have_last
                  || hypot (x - cur->last_x, y - cur->last_y)
                     >= (double) cur->deadzone_px))
            {
              pout->warp (pout, x, y);
              cur->last_x = x;
              cur->last_y = y;
              cur->have_last = true;
            }
        }
      else
        cur->was_pinched = false;
    }
  return cmacs_hg_step (&tr->g, smp, now, out, max);
}

/* A cursor-hand action, if A is one: true when handled here.  */
static bool
cursor_apply (struct ht_cursor *c, struct ht_pointer_out *out,
              const struct cmacs_hg_action *a)
{
  if (c == NULL || !c->enabled || a->hand != c->hand)
    return false;
  switch (a->kind)
    {
    case CMACS_HG_TAP:             /* thumb-index tap: left click */
      out->button (out, 0x110, true);
      out->button (out, 0x110, false);
      return true;
    case CMACS_HG_PULL_BEGIN:      /* ... moved: a drag */
      if (!c->held)
        out->button (out, 0x110, true);
      c->held = true;
      return true;
    case CMACS_HG_PULL_END:
      cursor_release (c, out);
      return true;
    case CMACS_HG_PULL_MOVE:       /* the pointer already follows */
      return true;
    case CMACS_HG_CLICK:           /* two-finger tap: right click */
      out->button (out, 0x111, true);
      out->button (out, 0x111, false);
      return true;
    case CMACS_HG_SCROLL:          /* two-finger move: scroll */
      /* The content follows the hand: moving it down shows what is
         above, a scroll up.  */
      if (a->y != 0)
        out->scroll (out, false, -(double) a->y);
      if (a->x != 0)
        out->scroll (out, true, -(double) a->x);
      return true;
    case CMACS_HG_DRAG_BEGIN: case CMACS_HG_DRAG_END:
      return true;                 /* a two-finger hold does nothing */
    default:
      return false;
    }
}

/* Let go if the cursor hand has not been seen for CMACS_HT_RELEASE_US.  */
static void
cursor_watch (struct ht_cursor *c, struct ht_pointer_out *out, gint64 now)
{
  if (c->held && now - c->seen_us > CMACS_HT_RELEASE_US)
    cursor_release (c, out);
}

static void ht_point_result (const CmacsHtResult *r);
static void ht_point_forget (void);
static bool ht_point_set_option (Lisp_Object key, Lisp_Object value);

/* ------------------------------------------------------------ applying -- */

static void
ht_store_event (enum ht_event ev)
{
  struct input_event ie;
  struct frame *f = SELECTED_FRAME ();

  if (!FRAME_LIVE_P (f))
    return;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = HT_KEY_BASE + (unsigned int) ev;
  XSETFRAME (ie.frame_or_window, f);
  ie.timestamp = (Time) (g_get_monotonic_time () / 1000);
  kbd_buffer_store_event (&ie);
  hd.events++;
}

/* The buffer a pull or a stretch moves, or nil.  */
static Lisp_Object
ht_target_buffer (void)
{
  if (BUFFERP (hd.target))
    return BUFFER_LIVE_P (XBUFFER (hd.target)) ? hd.target : Qnil;
  if (!EQ (hd.target, intern_c_string ("auto")) || !WINDOWP (selected_window))
    return Qnil;
  return BUFFERP (XWINDOW (selected_window)->contents)
         ? XWINDOW (selected_window)->contents : Qnil;
}

static void
ht_apply (const struct cmacs_hg_action *a)
{
  bool left = a->hand == 0;
  Lisp_Object buf;

  switch (a->kind)
    {
    case CMACS_HG_TAP:
      ht_store_event (left ? HT_EV_LEFT_PINCH : HT_EV_RIGHT_PINCH);
      break;
    case CMACS_HG_PALM_UP:
      ht_store_event (left ? HT_EV_LEFT_PALM_UP : HT_EV_RIGHT_PALM_UP);
      break;
    case CMACS_HG_PALM_DOWN:
      ht_store_event (left ? HT_EV_LEFT_PALM_DOWN : HT_EV_RIGHT_PALM_DOWN);
      break;
    case CMACS_HG_ZOOM_BEGIN:
      hd.zoom_prev = 1.0f;
      break;
    case CMACS_HG_ZOOM:
      /* Hands apart: closer.  The scene zooms by the stretch since the
         last frame, so it tracks the hands rather than a rate.  */
      buf = ht_target_buffer ();
      if (!NILP (buf) && a->v[0] > 0.0f && hd.zoom_prev > 0.0f)
        cmacs_libregnum_camera_gesture (buf, 0.0, 0.0,
                                        (double) hd.zoom_gain
                                        * log ((double) a->v[0]
                                               / (double) hd.zoom_prev));
      hd.zoom_prev = a->v[0];
      break;
    case CMACS_HG_ZOOM_END:
      if (a->v[0] > 1.0f + CMACS_HG_ZOOM_DEAD)
        ht_store_event (HT_EV_ZOOM_IN);
      else if (a->v[0] < 1.0f - CMACS_HG_ZOOM_DEAD)
        ht_store_event (HT_EV_ZOOM_OUT);
      break;
    case CMACS_HG_PULL_MOVE:
      /* The scene follows the pinch, as it follows a mouse drag: right
         is right, up (+Y) is a drag up (negative screen y).  */
      buf = ht_target_buffer ();
      if (!NILP (buf))
        cmacs_libregnum_camera_gesture (buf, (double) (a->v[0] * hd.orbit_gain),
                                        (double) (-a->v[1] * hd.orbit_gain),
                                        0.0);
      break;
    default:
      break;
    }
}

/* Every inference result (main thread).  */
static void
ht_on_result (const CmacsHtResult *r)
{
  struct cmacs_hg_action act[HT_ACTIONS];
  int n, i;

  hd.results++;
  hd.latency_us = r->latency_us;
  hd.last_n = r->n;
  {
    int geom[4];
    bool have_geom = false;
    gint64 now = g_get_monotonic_time ();

#ifdef HAVE_CMACS_GOWL
    if (hd.cursor.enabled)
      have_geom = cmacs_gowl_output_geometry (hd.cursor.output[0] != '\0'
                                              ? hd.cursor.output : NULL,
                                              &geom[0], &geom[1], &geom[2],
                                              &geom[3]);
#endif
    cursor_watch (&hd.cursor, &ht_desktop, now);
    n = ht_track (&hd.tr, r->hands, r->n,
                  r->img_w > 0 ? (float) r->img_h / (float) r->img_w : 0.75f,
                  now, &hd.cursor, have_geom ? geom : NULL, &ht_desktop,
                  act, HT_ACTIONS);
  }
  /* Where a bare hand is pointing, for `cmacs-deixis'.  Stamped with
     the time the frame arrived, not with now.  */
  ht_point_result (r);
  for (i = 0; i < n; i++)
    if (!cursor_apply (&hd.cursor, &ht_desktop, &act[i]))
      ht_apply (&act[i]);
}

/* The watchdog (CMacs context, main thread): a lost camera or a stalled
   inference thread delivers no results, so nothing else would let go.  */
static gboolean
ht_watchdog (gpointer data)
{
  (void) data;
  cursor_watch (&hd.cursor, &ht_desktop, g_get_monotonic_time ());
  return G_SOURCE_CONTINUE;
}

static void
ht_watchdog_set (bool on)
{
  if (on && hd.watchdog == 0)
    {
      GSource *src = g_timeout_source_new (100);
      g_source_set_callback (src, ht_watchdog, NULL, NULL);
      hd.watchdog = g_source_attach (src, cmacs_glib_get_context ());
      g_source_unref (src);
    }
  else if (!on && hd.watchdog != 0)
    {
      GSource *src = g_main_context_find_source_by_id
        (cmacs_glib_get_context (), hd.watchdog);
      if (src != NULL)
        g_source_destroy (src);
      hd.watchdog = 0;
    }
}

/* ------------------------------------------------------------- helpers -- */

static float
ht_float (Lisp_Object v)
{
  CHECK_NUMBER (v);
  return (float) XFLOATINT (v);
}

/* A Lisp sequence of 63 numbers as landmarks.  */
static void
ht_landmarks_of (Lisp_Object v, CmacsHtLandmarks *lm)
{
  int i;

  memset (lm, 0, sizeof *lm);
  if (!VECTORP (v) || ASIZE (v) < 63)
    wrong_type_argument (intern_c_string ("cmacs-handtrack-landmarks-p"), v);
  for (i = 0; i < 63; i++)
    lm->lm[i / 3][i % 3] = ht_float (AREF (v, i));
  lm->presence = 1.0f;
  lm->handedness = 1.0f;
}

static Lisp_Object
ht_landmarks_vector (const CmacsHtLandmarks *lm)
{
  Lisp_Object v = make_nil_vector (63);
  int i;

  for (i = 0; i < 63; i++)
    ASET (v, i, make_float (lm->lm[i / 3][i % 3]));
  return v;
}

static Lisp_Object
ht_xyz (const float *p)
{
  return list3 (make_float (p[0]), make_float (p[1]), make_float (p[2]));
}

static Lisp_Object
ht_hand_plist (const LrgVRHandState *st)
{
  float n[3] = { 0, 0, 0 };
  float pin = lrg_vr_hand_state_get_pinch_distance (st);

  lrg_vr_hand_state_get_palm_normal (st, n);
  return list (intern_c_string (":pinch-distance"), make_float (pin),
               intern_c_string (":pinch-strength"),
               make_float (lrg_vr_hand_state_get_pinch_strength (st)),
               intern_c_string (":pinched"),
               lrg_vr_hand_state_is_pinched (st) ? Qt : Qnil,
               intern_c_string (":palm-up"),
               lrg_vr_hand_state_is_palm_up (st, CMACS_HG_PALM_COS) ? Qt : Qnil,
               intern_c_string (":palm-normal"), ht_xyz (n),
               intern_c_string (":wrist"),
               ht_xyz (&st->positions[LRG_VR_HAND_JOINT_WRIST * 3]),
               intern_c_string (":palm"),
               ht_xyz (&st->positions[LRG_VR_HAND_JOINT_PALM * 3]));
}

/* ----------------------------------------------------------------- Lisp -- */

DEFUN ("cmacs-handtrack-available-p", Fcmacs_handtrack_available_p,
       Scmacs_handtrack_available_p, 0, 0, 0,
       doc: /* Return non-nil if this build can run the hand-tracking networks.
That needs onnxruntime at build time; without it the rest of hand
tracking -- the mapping, the gestures -- is still here, for tests.  */)
  (void)
{
  return cmacs_ht_inference_available () ? Qt : Qnil;
}

DEFUN ("cmacs-handtrack-open", Fcmacs_handtrack_open, Scmacs_handtrack_open,
       2, 4, 0,
       doc: /* Track hands in the open camera with PALM-MODEL and LANDMARK-MODEL.
Both are ONNX files: MediaPipe's palm detector (192 x 192 input) and its
hand landmark model (224 x 224).  THREADS is onnxruntime's intra-op
thread count (default 2).  The networks see the mirrored (selfie)
image, as MediaPipe expects, unless MIRROR is the symbol `no'.
Inference runs on a thread of its own; results come back to the main
thread.  Prefer `cmacs-handtrack-mode'.  Return t, or signal.  */)
  (Lisp_Object palm_model, Lisp_Object landmark_model, Lisp_Object threads,
   Lisp_Object mirror)
{
  CmacsHtConfig cfg;
  char *err = NULL;
  Lisp_Object p, l;

  CHECK_STRING (palm_model);
  CHECK_STRING (landmark_model);
  if (!NILP (threads))
    CHECK_FIXNAT (threads);
  p = ENCODE_FILE (Fexpand_file_name (palm_model, Qnil));
  l = ENCODE_FILE (Fexpand_file_name (landmark_model, Qnil));
  memset (&cfg, 0, sizeof cfg);
  cfg.palm_model = SSDATA (p);
  cfg.landmark_model = SSDATA (l);
  cfg.threads = NILP (threads) ? 2 : (int) XFIXNAT (threads);
  cfg.mirror = !EQ (mirror, intern_c_string ("no"));
  cfg.palm_threshold = hd.palm_threshold;
  cfg.presence_threshold = hd.presence_threshold;
  memset (&hd.tr, 0, sizeof hd.tr);
  lrg_vr_hand_state_reset (&hd.tr.hands[0]);
  lrg_vr_hand_state_reset (&hd.tr.hands[1]);
  hd.cursor.have_last = false;
  hd.cursor.ex.init = hd.cursor.ey.init = false;
  ht_point_forget ();
  if (!cmacs_ht_worker_start (&cfg, ht_on_result, &err))
    {
      Lisp_Object msg = build_string (err != NULL ? err : "hand tracking failed");
      g_free (err);
      xsignal1 (Qerror, msg);
    }
  ht_watchdog_set (hd.cursor.enabled);
  return Qt;
}

DEFUN ("cmacs-handtrack-close", Fcmacs_handtrack_close,
       Scmacs_handtrack_close, 0, 0, 0,
       doc: /* Stop tracking hands.  The camera stays as it was.  */)
  (void)
{
  cmacs_ht_worker_stop ();
  cursor_release (&hd.cursor, &ht_desktop);
  ht_watchdog_set (false);
  lrg_vr_hand_state_reset (&hd.tr.hands[0]);
  lrg_vr_hand_state_reset (&hd.tr.hands[1]);
  hd.tr.lm[0] = hd.tr.lm[1] = NULL;
  /* Where the user pointed does not outlive the session that saw it.  */
  ht_point_forget ();
  return Qnil;
}

DEFUN ("cmacs-handtrack-status", Fcmacs_handtrack_status,
       Scmacs_handtrack_status, 0, 0, 0,
       doc: /* Return a plist describing hand tracking.
Keys: :inference (onnxruntime built in), :running, :frames (inferred),
:results (delivered to the main thread), :events (gesture events sent),
:hands (in the last result), :latency-ms (of the last inference) and
:target.  */)
  (void)
{
  return list (intern_c_string (":inference"),
               cmacs_ht_inference_available () ? Qt : Qnil,
               intern_c_string (":running"),
               cmacs_ht_worker_running () ? Qt : Qnil,
               intern_c_string (":frames"), make_uint (cmacs_ht_worker_frames ()),
               intern_c_string (":results"), make_uint (hd.results),
               intern_c_string (":events"), make_uint (hd.events),
               intern_c_string (":hands"), make_fixnum (hd.last_n),
               intern_c_string (":latency-ms"),
               make_float ((double) hd.latency_us / 1000.0),
               intern_c_string (":target"), hd.target,
               intern_c_string (":pointer"), hd.cursor.enabled ? Qt : Qnil,
               intern_c_string (":pointer-held"), hd.cursor.held ? Qt : Qnil);
}

DEFUN ("cmacs-handtrack-hands", Fcmacs_handtrack_hands,
       Scmacs_handtrack_hands, 0, 0, 0,
       doc: /* Return the tracked hands now: an alist (left . PLIST) (right . PLIST).
A hand not in view is absent.  PLIST keys: :pinch-distance (metres, on
the standard palm), :pinch-strength, :pinched, :palm-up, :palm-normal,
:wrist and :palm (positions in the viewer space, metres).  */)
  (void)
{
  Lisp_Object out = Qnil;

  if (hd.tr.hands[1].active)
    out = Fcons (Fcons (intern_c_string ("right"), ht_hand_plist (&hd.tr.hands[1])),
                 out);
  if (hd.tr.hands[0].active)
    out = Fcons (Fcons (intern_c_string ("left"), ht_hand_plist (&hd.tr.hands[0])),
                 out);
  return out;
}

DEFUN ("cmacs-handtrack-set-target", Fcmacs_handtrack_set_target,
       Scmacs_handtrack_set_target, 1, 1, 0,
       doc: /* Choose what a pinch-drag orbits and a two-hand stretch zooms.
TARGET is `auto' (the libregnum scene in the selected window: roamgraph,
the second brain, gnuseye, ...), `none', or a buffer.  Return TARGET.  */)
  (Lisp_Object target)
{
  if (!EQ (target, intern_c_string ("auto"))
      && !EQ (target, intern_c_string ("none")) && !BUFFERP (target))
    wrong_type_argument (intern_c_string ("cmacs-handtrack-target-p"), target);
  hd.target = target;
  return target;
}

DEFUN ("cmacs-handtrack-set-option", Fcmacs_handtrack_set_option,
       Scmacs_handtrack_set_option, 2, 2, 0,
       doc: /* Set hand-tracking option KEY to VALUE.
KEY is one of:
  `palm-threshold'      palm detector score to accept, 0..1 (0.5)
  `presence-threshold'  landmark model's hand score to keep, 0..1 (0.5)
  `swap-hands'          non-nil: take the model's left for right
  `orbit-gain'          scene-orbit mouse pixels per metre of pull (2500)
  `zoom-gain'           wheel ticks per e-fold of two-hand stretch (9.5)
  `pointer'             non-nil: a hand drives the gowl desktop pointer
  `pointer-hand'        `left' or `right' (right)
  `pointer-region'      (X0 Y0 X1 Y1) of the mirrored image, 0..1, mapped
                        onto the output ((0.2 0.2 0.8 0.8))
  `pointer-output'      output name, or nil for the one under the pointer
  `pointer-deadzone'    pixels the pointer must move before it is sent (1.5)
  `pointer-min-cutoff'  One-Euro minimum cutoff, Hz (1.2): lower is steadier
  `pointer-beta'        One-Euro speed coefficient (0.02): higher is snappier
and, for a bare hand pointing (`cmacs-handtrack-point-history-enable'):
  `point-hand'          `any', `left' or `right' (any)
  `point-extend'        how far past its knuckle the index tip must reach
                        from the wrist, metres on the standard palm (0.055)
  `point-curl'          ... and the most any of the other three may (0.035)
  `point-min-confidence' pose confidence a sample needs, 0..1 (0.5)
  `point-dwell'         milliseconds a hand must rest to be a referent (120)
  `point-radius'        layout pixels within which it is one rest (96)
  `point-latency'       milliseconds from the camera seeing a frame to the
                        frame reaching cmacs, taken off each sample's
                        time (40)
  `point-min-cutoff'    One-Euro minimum cutoff for the fingertip, Hz (1.2)
  `point-beta'          One-Euro speed coefficient for it (0.02)
The two detector thresholds apply from the next `cmacs-handtrack-open'.
Return VALUE.  */)
  (Lisp_Object key, Lisp_Object value)
{
  CHECK_SYMBOL (key);
  if (ht_point_set_option (key, value))
    return value;
  if (EQ (key, intern_c_string ("swap-hands")))
    {
      hd.swap_hands = !NILP (value);
      return value;
    }
  if (EQ (key, intern_c_string ("pointer")))
    {
      hd.cursor.enabled = !NILP (value);
      if (!hd.cursor.enabled)
        cursor_release (&hd.cursor, &ht_desktop);
      hd.cursor.have_last = false;
      hd.cursor.ex.init = hd.cursor.ey.init = false;
      ht_watchdog_set (hd.cursor.enabled && cmacs_ht_worker_running ());
      return value;
    }
  if (EQ (key, intern_c_string ("pointer-hand")))
    {
      cursor_release (&hd.cursor, &ht_desktop);
      hd.cursor.hand = EQ (value, intern_c_string ("left")) ? 0 : 1;
      return value;
    }
  if (EQ (key, intern_c_string ("pointer-output")))
    {
      if (NILP (value))
        hd.cursor.output[0] = '\0';
      else
        {
          CHECK_STRING (value);
          g_strlcpy (hd.cursor.output, SSDATA (value), sizeof hd.cursor.output);
        }
      return value;
    }
  if (EQ (key, intern_c_string ("pointer-region")))
    {
      float r[4];
      Lisp_Object t = value;
      int k;

      for (k = 0; k < 4; k++, t = Fcdr (t))
        r[k] = ht_float (Fcar (t));
      if (!(r[0] >= 0.0f && r[2] <= 1.0f && r[1] >= 0.0f && r[3] <= 1.0f
            && r[2] - r[0] > 0.05f && r[3] - r[1] > 0.05f))
        args_out_of_range (value, intern_c_string ("pointer-region"));
      memcpy (hd.cursor.region, r, sizeof r);
      return value;
    }
  CHECK_NUMBER (value);
  if (EQ (key, intern_c_string ("palm-threshold"))
      || EQ (key, intern_c_string ("presence-threshold")))
    {
      double d = XFLOATINT (value);
      if (d < 0.0 || d > 1.0)
        args_out_of_range (value, make_fixnum (1));
      if (EQ (key, intern_c_string ("palm-threshold")))
        hd.palm_threshold = (float) d;
      else
        hd.presence_threshold = (float) d;
    }
  else if (EQ (key, intern_c_string ("orbit-gain")))
    hd.orbit_gain = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("zoom-gain")))
    hd.zoom_gain = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("pointer-deadzone")))
    hd.cursor.deadzone_px = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("pointer-min-cutoff")))
    {
      if (XFLOATINT (value) <= 0.0)
        args_out_of_range (value, make_fixnum (0));
      hd.cursor.min_cutoff = (float) XFLOATINT (value);
    }
  else if (EQ (key, intern_c_string ("pointer-beta")))
    hd.cursor.beta = (float) XFLOATINT (value);
  else
    error ("Unknown hand-tracking option");
  return value;
}

DEFUN ("cmacs-handtrack-event-codes", Fcmacs_handtrack_event_codes,
       Scmacs_handtrack_event_codes, 0, 0, 0,
       doc: /* Return the gesture events as an alist (NAME . KEYSTROKE-CODE).
Emacs names a keystroke with such a code `key-CODE';
`cmacs-handtrack-mode' translates each to <NAME>.  */)
  (void)
{
  Lisp_Object out = Qnil;
  int i;

  for (i = HT_EV_COUNT - 1; i >= 0; i--)
    out = Fcons (Fcons (intern_c_string (ht_event_names[i]),
                        make_fixnum (HT_KEY_BASE + (unsigned int) i)),
                 out);
  return out;
}

/* ---------------------------------------------------------- for tests -- */

DEFUN ("cmacs-handtrack--synthetic-landmarks",
       Fcmacs_handtrack__synthetic_landmarks,
       Scmacs_handtrack__synthetic_landmarks, 3, 7, 0,
       doc: /* Return MediaPipe-style landmarks of a synthetic HAND.  For tests.
HAND is `left' or `right'; PINCH the thumb-to-index distance in metres;
PALM-UP non-nil turns the palm up.  X Y Z place the wrist (default 0.1,
-0.1, -0.5: right of centre and below eye level, at the plane); ASPECT
is the frame's height / width (default 0.75).  The hand is libregnum's
synthetic one, projected onto the camera image -- so mapping it back
must recover it.  Return a vector of 63 floats.  */)
  (Lisp_Object hand, Lisp_Object pinch, Lisp_Object palm_up, Lisp_Object x,
   Lisp_Object y, Lisp_Object z, Lisp_Object aspect)
{
  LrgVRHandState st;
  CmacsHtLandmarks lm;
  bool right = EQ (hand, intern_c_string ("right"));

  lrg_vr_hand_state_set_synthetic (&st, right ? LRG_VR_HAND_RIGHT
                                   : LRG_VR_HAND_LEFT,
                                   NILP (x) ? 0.1f : ht_float (x),
                                   NILP (y) ? -0.1f : ht_float (y),
                                   NILP (z) ? -CMACS_HT_PLANE_M : ht_float (z),
                                   ht_float (pinch), !NILP (palm_up));
  cmacs_ht_from_hand_state (&st, NILP (aspect) ? 0.75f : ht_float (aspect),
                            &lm);
  return ht_landmarks_vector (&lm);
}

DEFUN ("cmacs-handtrack--map", Fcmacs_handtrack__map, Scmacs_handtrack__map,
       2, 3, 0,
       doc: /* Map LANDMARKS (63 numbers) of a RIGHT (non-nil) or left hand.
For tests.  ASPECT defaults to 0.75.  Return the plist
`cmacs-handtrack-hands' gives for a hand, plus :valid (joints marked
valid) -- after one frame of the pinch latch from open.  */)
  (Lisp_Object landmarks, Lisp_Object right, Lisp_Object aspect)
{
  CmacsHtLandmarks lm;
  LrgVRHandState st;
  int i, valid = 0;

  ht_landmarks_of (landmarks, &lm);
  cmacs_ht_to_hand_state (&lm, NILP (aspect) ? 0.75f : ht_float (aspect),
                          !NILP (right), &st);
  lrg_vr_hand_state_update_pinch (&st, false);
  for (i = 0; i < LRG_VR_HAND_JOINT_COUNT; i++)
    valid += (st.valid >> i) & 1u;
  return Fcons (intern_c_string (":valid"),
                Fcons (make_fixnum (valid), ht_hand_plist (&st)));
}

DEFUN ("cmacs-handtrack--simulate", Fcmacs_handtrack__simulate,
       Scmacs_handtrack__simulate, 1, 1, 0,
       doc: /* Run camera FRAMES through mapping, latch and classifier.  For tests.
FRAMES is a list of (MILLISECONDS LEFT RIGHT); each hand is nil or 63
landmark numbers (a vector), as the landmark model gives them.  Starts
from nothing, sends nothing, moves no camera.  Return the gestures as
`cmacs-lrg-vr--simulate-hand-gestures' does: (KIND HAND . ARGS).  */)
  (Lisp_Object frames)
{
  static const char *const kinds[] = {
    "click", "drag-begin", "drag-end", "scroll", "pull-begin", "pull-move",
    "pull-end", "tap", "key-down", "key-up", "palm-up", "palm-down",
    "zoom-begin", "zoom", "zoom-end"
  };
  struct ht_tracker tr;
  Lisp_Object result = Qnil, tail;

  memset (&tr, 0, sizeof tr);
  lrg_vr_hand_state_reset (&tr.hands[0]);
  lrg_vr_hand_state_reset (&tr.hands[1]);
  CHECK_LIST (frames);
  for (tail = frames; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object fr = XCAR (tail), l, r;
      CmacsHtLandmarks lm[2];
      struct cmacs_hg_action act[HT_ACTIONS];
      int n = 0, k, i;

      CHECK_CONS (fr);
      CHECK_FIXNUM (XCAR (fr));
      l = Fnth (make_fixnum (1), fr);
      r = Fnth (make_fixnum (2), fr);
      if (!NILP (l))
        {
          ht_landmarks_of (l, &lm[n]);
          lm[n++].handedness = 0.0f;
        }
      if (!NILP (r))
        {
          ht_landmarks_of (r, &lm[n]);
          lm[n++].handedness = 1.0f;
        }
      k = ht_track (&tr, lm, n, 0.75f, XFIXNUM (XCAR (fr)) * 1000, NULL, NULL,
                    &ht_desktop, act, HT_ACTIONS);
      for (i = 0; i < k; i++)
        {
          const struct cmacs_hg_action *a = &act[i];
          Lisp_Object args = Qnil;

          if (a->kind == CMACS_HG_PULL_MOVE)
            args = list3 (make_float (a->v[0]), make_float (a->v[1]),
                          make_float (a->v[2]));
          else if (a->kind == CMACS_HG_ZOOM || a->kind == CMACS_HG_ZOOM_END)
            args = list1 (make_float (a->v[0]));
          result = Fcons (Fcons (intern_c_string (kinds[a->kind]),
                                 Fcons (intern_c_string (a->hand < 0 ? "both"
                                                         : a->hand == 0
                                                         ? "left" : "right"),
                                        args)),
                          result);
        }
    }
  return Fnreverse (result);
}

DEFUN ("cmacs-handtrack--simulate-pointer", Fcmacs_handtrack__simulate_pointer,
       Scmacs_handtrack__simulate_pointer, 2, 2, 0,
       doc: /* Run camera FRAMES through the hand cursor on output GEOMETRY.  For tests.
FRAMES is as for `cmacs-handtrack--simulate', with a frame of nil hands
\(MILLISECONDS) also meaning "no result yet" -- the watchdog runs on
every frame.  GEOMETRY is (X Y WIDTH HEIGHT).  The cursor hand and its
region are the current options; nothing reaches the desktop.  Return
the pointer calls in order: (warp X Y), (button CODE press|release),
\(scroll HORIZONTAL NOTCHES).  */)
  (Lisp_Object frames, Lisp_Object geometry)
{
  struct ht_tracker tr;
  struct ht_cursor cur = hd.cursor;
  Lisp_Object log = Qnil, tail;
  struct ht_pointer_out rec = { rec_warp, rec_button, rec_scroll, &log };
  int geom[4], k;

  for (k = 0, tail = geometry; k < 4; k++, tail = Fcdr (tail))
    {
      CHECK_FIXNUM (Fcar (tail));
      geom[k] = (int) XFIXNUM (Fcar (tail));
    }
  if (geom[2] <= 0 || geom[3] <= 0)
    args_out_of_range (geometry, Qnil);
  memset (&tr, 0, sizeof tr);
  lrg_vr_hand_state_reset (&tr.hands[0]);
  lrg_vr_hand_state_reset (&tr.hands[1]);
  cur.enabled = true;
  cur.held = cur.have_last = cur.two_finger = cur.was_pinched = false;
  cur.ex.init = cur.ey.init = false;
  cur.last_us = cur.seen_us = 0;
  CHECK_LIST (frames);
  for (tail = frames; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object fr = XCAR (tail), l, r;
      CmacsHtLandmarks lm[2];
      struct cmacs_hg_action act[HT_ACTIONS];
      gint64 now;
      int n = 0, i, got;

      CHECK_CONS (fr);
      CHECK_FIXNUM (XCAR (fr));
      now = XFIXNUM (XCAR (fr)) * 1000;
      l = Fnth (make_fixnum (1), fr);
      r = Fnth (make_fixnum (2), fr);
      if (!NILP (l))
        {
          ht_landmarks_of (l, &lm[n]);
          lm[n++].handedness = 0.0f;
        }
      if (!NILP (r))
        {
          ht_landmarks_of (r, &lm[n]);
          lm[n++].handedness = 1.0f;
        }
      cursor_watch (&cur, &rec, now);
      got = ht_track (&tr, lm, n, 0.75f, now, &cur, geom, &rec, act,
                      HT_ACTIONS);
      for (i = 0; i < got; i++)
        cursor_apply (&cur, &rec, &act[i]);
    }
  return Fnreverse (log);
}

DEFUN ("cmacs-handtrack--anchors", Fcmacs_handtrack__anchors,
       Scmacs_handtrack__anchors, 0, 0, 0,
       doc: /* Return the palm detector's anchors as a vector of (X . Y).  For tests.  */)
  (void)
{
  float *xy = g_new (float, CMACS_HT_ANCHORS * 2);
  int n = cmacs_ht_anchors (xy), i;
  Lisp_Object v = make_nil_vector (n);

  for (i = 0; i < n; i++)
    ASET (v, i, Fcons (make_float (xy[2 * i]), make_float (xy[2 * i + 1])));
  g_free (xy);
  return v;
}

/* Signal unless V is a vector of WANT numbers.  */
static void
ht_check_floats (Lisp_Object v, ptrdiff_t want)
{
  ptrdiff_t i;

  if (!VECTORP (v) || ASIZE (v) != want)
    wrong_type_argument (intern_c_string ("vectorp"), v);
  for (i = 0; i < want; i++)
    CHECK_NUMBER (AREF (v, i));
}

/* V (checked by ht_check_floats) as floats; xfree the result.  */
static float *
ht_floats (Lisp_Object v, ptrdiff_t want)
{
  float *out = xmalloc ((size_t) want * sizeof (float));
  ptrdiff_t i;

  for (i = 0; i < want; i++)
    out[i] = (float) XFLOATINT (AREF (v, i));
  return out;
}

DEFUN ("cmacs-handtrack--decode", Fcmacs_handtrack__decode,
       Scmacs_handtrack__decode, 4, 5, 0,
       doc: /* Decode raw palm-detector output for a WIDTH x HEIGHT frame.  For tests.
BOXES is a vector of 2016 * 18 numbers, SCORES of 2016 logits.
THRESHOLD defaults to 0.5.  Return a list of palms, each
\(CX CY W H SCORE (WRIST-X . WRIST-Y) (MIDDLE-X . MIDDLE-Y)),
image-normalised, after weighted non-maximum suppression.  */)
  (Lisp_Object boxes, Lisp_Object scores, Lisp_Object width,
   Lisp_Object height, Lisp_Object threshold)
{
  float anchors[CMACS_HT_ANCHORS * 2], *b, *s, scale, padx, pady, thr;
  CmacsHtPalm palms[CMACS_HT_MAX_PALMS];
  int w, h, n, i;
  Lisp_Object out = Qnil;

  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  w = (int) XFIXNAT (width);
  h = (int) XFIXNAT (height);
  if (w <= 0 || h <= 0)
    args_out_of_range (width, height);
  thr = NILP (threshold) ? 0.5f : ht_float (threshold);
  ht_check_floats (boxes, CMACS_HT_ANCHORS * 18);
  ht_check_floats (scores, CMACS_HT_ANCHORS);
  b = ht_floats (boxes, CMACS_HT_ANCHORS * 18);
  s = ht_floats (scores, CMACS_HT_ANCHORS);
  cmacs_ht_anchors (anchors);
  scale = (float) CMACS_HT_PALM_SIZE / (float) MAX (w, h);
  padx = ((float) CMACS_HT_PALM_SIZE - (float) w * scale) / 2.0f;
  pady = ((float) CMACS_HT_PALM_SIZE - (float) h * scale) / 2.0f;
  n = cmacs_ht_decode_palms (b, s, anchors, CMACS_HT_ANCHORS,
                             thr,
                             scale, padx, pady, w, h, palms,
                             CMACS_HT_MAX_PALMS);
  xfree (b);
  xfree (s);
  for (i = n - 1; i >= 0; i--)
    out = Fcons (list (make_float (palms[i].cx), make_float (palms[i].cy),
                       make_float (palms[i].w), make_float (palms[i].h),
                       make_float (palms[i].score),
                       Fcons (make_float (palms[i].kp[0][0]),
                              make_float (palms[i].kp[0][1])),
                       Fcons (make_float (palms[i].kp[2][0]),
                              make_float (palms[i].kp[2][1]))),
                 out);
  return out;
}

DEFUN ("cmacs-handtrack--letterbox", Fcmacs_handtrack__letterbox,
       Scmacs_handtrack__letterbox, 5, 5, 0,
       doc: /* Letterbox a uniform WIDTH x HEIGHT image of colour R G B.  For tests.
Return (SCALE PADX PADY MEAN-R COVERED): the mapping, the mean red over
the 192 x 192 tensor, and the fraction of it the image covers.  */)
  (Lisp_Object width, Lisp_Object height, Lisp_Object r, Lisp_Object g,
   Lisp_Object b)
{
  int w, h, S = CMACS_HT_PALM_SIZE, i;
  guint8 *img;
  float *t, scale, padx, pady;
  double sum = 0.0;
  long covered = 0;

  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  CHECK_FIXNAT (r);
  CHECK_FIXNAT (g);
  CHECK_FIXNAT (b);
  w = (int) XFIXNAT (width);
  h = (int) XFIXNAT (height);
  if (w <= 0 || h <= 0 || w > 4096 || h > 4096)
    args_out_of_range (width, height);
  img = g_malloc ((gsize) w * (gsize) h * 3);
  for (i = 0; i < w * h; i++)
    {
      img[3 * i] = (guint8) XFIXNAT (r);
      img[3 * i + 1] = (guint8) XFIXNAT (g);
      img[3 * i + 2] = (guint8) XFIXNAT (b);
    }
  t = g_new (float, (gsize) S * S * 3);
  cmacs_ht_letterbox (img, w, h, w * 3, false, S, false, t, &scale, &padx,
                      &pady);
  for (i = 0; i < S * S; i++)
    {
      sum += (double) t[3 * i];
      covered += t[3 * i + 1] > 0.0f || t[3 * i] > 0.0f || t[3 * i + 2] > 0.0f;
    }
  g_free (img);
  g_free (t);
  return list5 (make_float (scale), make_float (padx), make_float (pady),
                make_float (sum / (S * S)),
                make_float ((double) covered / (S * S)));
}

DEFUN ("cmacs-handtrack--roi-from-palm", Fcmacs_handtrack__roi_from_palm,
       Scmacs_handtrack__roi_from_palm, 3, 3, 0,
       doc: /* The hand region for PALM in a WIDTH x HEIGHT frame.  For tests.
PALM is (CX CY W H WRIST-X WRIST-Y MIDDLE-X MIDDLE-Y), image-normalised.
Return (CX CY SIZE ROTATION) in pixels and radians.  */)
  (Lisp_Object palm, Lisp_Object width, Lisp_Object height)
{
  CmacsHtPalm p;
  CmacsHtRoi roi;
  float v[8];
  int i;

  CHECK_FIXNAT (width);
  CHECK_FIXNAT (height);
  for (i = 0; i < 8; i++, palm = Fcdr (palm))
    v[i] = ht_float (Fcar (palm));
  memset (&p, 0, sizeof p);
  p.cx = v[0];
  p.cy = v[1];
  p.w = v[2];
  p.h = v[3];
  p.kp[0][0] = v[4];
  p.kp[0][1] = v[5];
  p.kp[2][0] = v[6];
  p.kp[2][1] = v[7];
  cmacs_ht_roi_from_palm (&p, (int) XFIXNAT (width), (int) XFIXNAT (height),
                          &roi);
  return list4 (make_float (roi.cx), make_float (roi.cy),
                make_float (roi.size), make_float (roi.rotation));
}

/* ---------------------------------------------------------------------
   A bare hand pointing.

   For `cmacs-deixis': "move THAT over THERE", said while pointing at
   the screen with an index finger and no pointer mode.  Each result in
   which a hand holds the pointing pose (cmacs-handtrack-point-history.c:
   index out, the other three curled, not a pinch) leaves one sample in
   a ring -- where its index fingertip was on the screen, and what was
   there -- stamped with the time the camera frame ARRIVED, not the time
   inference finished.  Deixis reads the ring by time once the
   transcript is in.

   The fingertip goes through the hand cursor's own mapping
   (ht_region_uv, ht_output_smooth): the camera's active region onto one
   output, One-Euro smoothed.  That makes it a cursor held in the air,
   not a ray: one camera sees where the fingertip is in its image and
   cannot tell where the finger is aimed.  The docs say so.

   The hand that drives the pointer in `cmacs-handtrack-pointer-mode' is
   left out: it already is the gowl pointer, and the compositor's ring
   has it.

   Runs from the GLib dispatch that delivers results, on the main
   thread: it must not signal and makes no Lisp object.  What is under
   the fingertip is asked of the compositor through
   cmacs_gowl_pointer_history_hit, which takes the gowl lock itself.
   Off until `cmacs-handtrack-point-history-enable'; emptied when that
   turns it off and when the tracker closes.
   --------------------------------------------------------------------- */

/* A fingertip this far outside the active region (a fraction of the
   region's size) is pointing past the edge of the screen: nothing.  */
#define HT_POINT_OVERSHOOT 0.10f

/* With no compositor to ask there are no layout pixels.  The fingertip
   is then filtered on a screen of this size, so the filter's
   parameters mean what they mean for the cursor, and only its
   fractions across the output (u, v) are any use to the reader.  */
static const int ht_point_nominal[4] = { 0, 0, 1920, 1080 };

struct ht_point_filter
{
  struct ht_euro ex, ey;
  gint64 last_us;
  bool was_pinched;
};

static struct
{
  struct cmacs_ht_point_params pose;
  int hand;                      /* -1 either, 0 left, 1 right */
  float min_confidence;
  float min_cutoff, beta;        /* One-Euro parameters */
  gint64 dwell_ms;               /* shortest rest that is a referent */
  gint64 latency_ms;             /* camera delay, off each sample's time */
  double radius;                 /* layout pixels that are one rest */
  struct ht_point_filter f[2];
  gint64 pinch_ms[2];            /* last pinch onset, sample time; 0: none */
  bool pointing[2];              /* in the last result */
  unsigned long samples;         /* stored since startup */
} pt = {
  .pose = { CMACS_HT_POINT_EXTEND_M, CMACS_HT_POINT_CURL_M },
  .hand = -1, .min_confidence = 0.5f, .min_cutoff = 1.2f, .beta = 0.02f,
  .dwell_ms = 120, .latency_ms = 40, .radius = CMACS_HT_POINT_RADIUS,
};

static gint64
ht_point_now (void)
{
  return g_get_monotonic_time () / 1000;
}

static void
ht_point_filter_reset (struct ht_point_filter *f)
{
  f->ex.init = f->ey.init = false;
  f->last_us = 0;
}

/* Empty the ring and forget everything derived from hands seen so far.
   The ring stays enabled or not as it was.  */
static void
ht_point_forget (void)
{
  int side;

  cmacs_ht_point_clear ();
  for (side = 0; side < 2; side++)
    {
      ht_point_filter_reset (&pt.f[side]);
      pt.f[side].was_pinched = false;
      pt.pinch_ms[side] = 0;
      pt.pointing[side] = false;
    }
}

/* The output a bare hand points at: the one `pointer-output' names,
   else the one the pointer is on -- the hand cursor's choice.  False,
   with the nominal screen in GEOM, when there is no compositor.  */
static bool
ht_point_desktop_geom (int *geom)
{
#ifdef HAVE_CMACS_GOWL
  if (cmacs_gowl_output_geometry (hd.cursor.output[0] != '\0'
                                  ? hd.cursor.output : NULL,
                                  &geom[0], &geom[1], &geom[2], &geom[3])
      && geom[2] > 0 && geom[3] > 0)
    return true;
#endif
  memcpy (geom, ht_point_nominal, sizeof ht_point_nominal);
  return false;
}

/* One frame of pointing.  TR is as ht_track just left it (its hands and
   the landmarks they came from).  MS is the samples' time, NOW_US the
   smoothing filter's clock.  GEOM is the output to map onto, or NULL
   for the desktop's.  DESKTOP is true for live results: the cursor hand
   is then skipped and what is under the fingertip is asked of the
   compositor; false (tests) stores bare positions.  Returns how many
   samples were stored.  Must not signal.  */
static int
ht_point_step (const struct ht_tracker *tr, gint64 ms, gint64 now_us,
               const int *geom, bool desktop)
{
  int dgeom[4], side, stored = 0;
  bool have_dgeom = false, layout = geom != NULL;

  for (side = 0; side < 2; side++)
    {
      const LrgVRHandState *st = &tr->hands[side];
      const CmacsHtLandmarks *lm = tr->lm[side];
      struct ht_point_filter *f = &pt.f[side];
      struct cmacs_ht_point_pose pose;
      struct cmacs_ht_point_sample s;
      const int *g = geom;
      float u = 0.5f, v = 0.5f;
      double x, y;
      bool pinched;

      pt.pointing[side] = false;
      if (!st->active || lm == NULL)
        {
          ht_point_filter_reset (f);
          f->was_pinched = false;
          continue;
        }

      /* When this hand last closed a pinch, for
         `cmacs-handtrack-point-calibrate': a moment the user can mark
         with a key, on the same clock as the samples.  A time and
         nothing else, so it is kept whether or not the ring is on.  */
      pinched = lrg_vr_hand_state_is_pinched (st);
      if (pinched && !f->was_pinched)
        pt.pinch_ms[side] = ms;
      f->was_pinched = pinched;

      if (!cmacs_ht_point_enabled ()
          || (pt.hand >= 0 && pt.hand != side)
          || (desktop && hd.cursor.enabled && hd.cursor.hand == side))
        continue;

      cmacs_ht_point_pose (st, &pt.pose, &pose);
      /* MediaPipe's landmark 8 is the index fingertip.  */
      if (!pose.pointing || pose.confidence < pt.min_confidence
          || ht_region_uv (hd.cursor.region, lm->lm[8][0], lm->lm[8][1],
                           &u, &v) > HT_POINT_OVERSHOOT)
        {
          /* The next time it points it starts where it then is, not
             gliding there from where it last was.  */
          ht_point_filter_reset (f);
          continue;
        }
      pt.pointing[side] = true;

      if (g == NULL)
        {
          /* Asked only now: most frames have no pointing hand, and the
             answer costs the gowl lock.  */
          if (!have_dgeom)
            {
              layout = ht_point_desktop_geom (dgeom);
              have_dgeom = true;
            }
          g = dgeom;
        }
      ht_output_smooth (&f->ex, &f->ey, &f->last_us, u, v, g, now_us,
                        (double) pt.min_cutoff, (double) pt.beta, &x, &y);

      memset (&s, 0, sizeof s);
      s.ms = ms;
      s.x = x;
      s.y = y;
      s.u = g[2] > 1 ? (float) ((x - g[0]) / (double) (g[2] - 1)) : 0.5f;
      s.v = g[3] > 1 ? (float) ((y - g[1]) / (double) (g[3] - 1)) : 0.5f;
      s.confidence = pose.confidence;
      s.hand = (guint8) side;
      s.layout = layout;
      s.monitor = -1;
#ifdef HAVE_CMACS_GOWL
      /* What a click there would land on, as the mouse ring notes it.
         False: the session is locked (or the compositor has gone), and
         what a hand does in front of a lock screen is nobody's
         business.  */
      if (desktop && layout
          && !cmacs_gowl_pointer_history_hit (x, y, &s.client, &s.monitor))
        continue;
#endif
      if (cmacs_ht_point_push (&s))
        {
          stored++;
          pt.samples++;
        }
    }
  return stored;
}

/* Every inference result, after ht_track (main thread, GLib dispatch).
   The sample's time is the frame's arrival on the camera's streaming
   thread -- the same clock as the mouse ring's -- less the camera's own
   delay; inference time is not in it at all.  */
static void
ht_point_result (const CmacsHtResult *r)
{
  ht_point_step (&hd.tr, r->frame_us / 1000 - pt.latency_ms, r->frame_us,
                 NULL, true);
}

/* The `point-*' options of `cmacs-handtrack-set-option'.  True when KEY
   was one of them.  Signals on a bad VALUE (called from the DEFUN).  */
static bool
ht_point_set_option (Lisp_Object key, Lisp_Object value)
{
  static const char *const names[] = {
    "point-extend", "point-curl", "point-min-confidence", "point-dwell",
    "point-radius", "point-latency", "point-min-cutoff", "point-beta"
  };
  size_t which;
  double d;

  if (EQ (key, intern_c_string ("point-hand")))
    {
      pt.hand = EQ (value, intern_c_string ("left")) ? 0
                : EQ (value, intern_c_string ("right")) ? 1 : -1;
      return true;
    }
  for (which = 0; which < G_N_ELEMENTS (names); which++)
    if (EQ (key, intern_c_string (names[which])))
      break;
  if (which == G_N_ELEMENTS (names))
    return false;

  CHECK_NUMBER (value);
  d = XFLOATINT (value);
  switch (which)
    {
    case 0: case 1:              /* metres on a 0.094 m palm */
      if (d < -0.1 || d > 0.2)
        args_out_of_range (value, key);
      if (which == 0)
        pt.pose.extend_m = (float) d;
      else
        pt.pose.curl_m = (float) d;
      break;
    case 2:
      if (d < 0.0 || d > 1.0)
        args_out_of_range (value, key);
      pt.min_confidence = (float) d;
      break;
    case 3:
      if (d < 0.0 || d > 10000.0)
        args_out_of_range (value, key);
      pt.dwell_ms = (gint64) d;
      break;
    case 4:
      if (d <= 0.0)
        args_out_of_range (value, key);
      pt.radius = d;
      break;
    case 5:
      if (d < -2000.0 || d > 2000.0)
        args_out_of_range (value, key);
      pt.latency_ms = (gint64) d;
      break;
    case 6:
      if (d <= 0.0)
        args_out_of_range (value, key);
      pt.min_cutoff = (float) d;
      break;
    default:
      if (d < 0.0)
        args_out_of_range (value, key);
      pt.beta = (float) d;
      break;
    }
  return true;
}

/* The plist a lookup returns; the keys of `gowl-pointer-history-at',
   less :client (see the DEFUNs), plus the hand's own.  DURATION < 0: a
   single sample, with no :duration and no :since.  */
static Lisp_Object
ht_point_plist (gint64 ms, double x, double y, float u, float v,
                float confidence, guint client, gint monitor, int hand,
                bool layout, gint64 duration, gint64 since)
{
  Lisp_Object tail = Qnil;

  if (duration >= 0)
    tail = list4 (intern_c_string (":duration"), make_int (duration),
                  intern_c_string (":since"), make_int (since));
  tail = Fcons (intern_c_string (":layout"), Fcons (layout ? Qt : Qnil, tail));
  tail = Fcons (intern_c_string (":v"),
                Fcons (make_float ((double) v), tail));
  tail = Fcons (intern_c_string (":u"),
                Fcons (make_float ((double) u), tail));
  tail = Fcons (intern_c_string (":confidence"),
                Fcons (make_float ((double) confidence), tail));
  tail = Fcons (intern_c_string (":hand"),
                Fcons (intern_c_string (hand == 0 ? "left" : "right"), tail));
  tail = Fcons (intern_c_string (":monitor"),
                Fcons (monitor >= 0 ? make_fixnum (monitor) : Qnil, tail));
  tail = Fcons (intern_c_string (":client-id"),
                Fcons (make_fixnum ((EMACS_INT) client), tail));
  tail = Fcons (intern_c_string (":y"), Fcons (make_float (y), tail));
  tail = Fcons (intern_c_string (":x"), Fcons (make_float (x), tail));
  return Fcons (intern_c_string (":time"), Fcons (make_int (ms), tail));
}

/* A time argument in milliseconds, integer or float.  */
static gint64
ht_point_ms_arg (Lisp_Object ms)
{
  CHECK_NUMBER (ms);
  return (gint64) XFLOATINT (ms);
}

DEFUN ("cmacs-handtrack-point-history-now",
       Fcmacs_handtrack_point_history_now,
       Scmacs_handtrack_point_history_now, 0, 0, 0,
       doc: /* Return the monotonic clock in milliseconds.
This is the clock the pointing history's samples are stamped with
\(CLOCK_MONOTONIC), the same one as `gowl-pointer-history-now'; it has
no relation to `float-time'.  */)
  (void)
{
  return make_int (ht_point_now ());
}

DEFUN ("cmacs-handtrack-point-history-enable",
       Fcmacs_handtrack_point_history_enable,
       Scmacs_handtrack_point_history_enable, 1, 1, 0,
       doc: /* Start (ENABLE non-nil) or stop noting where a hand points.
While on, and while hands are tracked (`cmacs-handtrack-mode'), every
camera frame in which a hand holds the pointing pose -- index finger
out, the other three curled -- leaves one sample in a fixed ring in
memory: when, which hand, how sure, where its fingertip was on the
screen and which window was there.  About seventeen seconds of
uninterrupted pointing.  Nothing is written anywhere else, nothing is
noted while the session is locked, and the ring is emptied when this
turns it off and whenever hand tracking stops.

The hand that drives the pointer in `cmacs-handtrack-pointer-mode' is
not noted here: it is the pointer, and `gowl-pointer-history-enable'
has it.

Return non-nil when the history is now on.  */)
  (Lisp_Object enable)
{
  cmacs_ht_point_set_enabled (!NILP (enable));
  if (NILP (enable))
    ht_point_forget ();
  return cmacs_ht_point_enabled () ? Qt : Qnil;
}

DEFUN ("cmacs-handtrack-point-history-clear",
       Fcmacs_handtrack_point_history_clear,
       Scmacs_handtrack_point_history_clear, 0, 0, 0,
       doc: /* Forget where hands have pointed.  The history stays on or off.  */)
  (void)
{
  ht_point_forget ();
  return Qnil;
}

DEFUN ("cmacs-handtrack-point-history-status",
       Fcmacs_handtrack_point_history_status,
       Scmacs_handtrack_point_history_status, 0, 0, 0,
       doc: /* Return a plist describing the pointing history.
Keys: :enabled, :samples (in the ring now), :capacity, :stored (since
startup), :pointing (the hands holding the pose in the last result: a
list of `left' and `right'), :pinch-left and :pinch-right (when each
hand last closed a pinch, on the clock of
`cmacs-handtrack-point-history-now', or nil), :latency-ms (the
`point-latency' option) and :now.  */)
  (void)
{
  Lisp_Object pointing = Qnil;

  if (pt.pointing[1])
    pointing = Fcons (intern_c_string ("right"), pointing);
  if (pt.pointing[0])
    pointing = Fcons (intern_c_string ("left"), pointing);
  return list (intern_c_string (":enabled"),
               cmacs_ht_point_enabled () ? Qt : Qnil,
               intern_c_string (":samples"),
               make_fixnum ((EMACS_INT) cmacs_ht_point_count ()),
               intern_c_string (":capacity"),
               make_fixnum (CMACS_HT_POINT_RING),
               intern_c_string (":stored"), make_uint (pt.samples),
               intern_c_string (":pointing"), pointing,
               intern_c_string (":pinch-left"),
               pt.pinch_ms[0] != 0 ? make_int (pt.pinch_ms[0]) : Qnil,
               intern_c_string (":pinch-right"),
               pt.pinch_ms[1] != 0 ? make_int (pt.pinch_ms[1]) : Qnil,
               intern_c_string (":latency-ms"), make_int (pt.latency_ms),
               intern_c_string (":now"), make_int (ht_point_now ()));
}

DEFUN ("cmacs-handtrack-point-history-at",
       Fcmacs_handtrack_point_history_at,
       Scmacs_handtrack_point_history_at, 1, 1, 0,
       doc: /* Return where a hand was pointing at time MS.
MS is on the clock of `cmacs-handtrack-point-history-now'.  The value is
a plist
  (:time T :x X :y Y :client-id ID :monitor N :hand HAND
   :confidence C :u U :v V :layout LAYOUT)
for the latest sample at or before MS, as `gowl-pointer-history-at'
gives for the mouse: T is the time the camera frame was taken, X and Y
layout pixels, ID the id of the window that was under the fingertip
\(0: none) and N the index of the output in `gowl-list-monitors'.  HAND
is `left' or `right', C the confidence of the pointing pose (0.5..1),
and U, V the position as fractions across the output.  LAYOUT is nil
when no compositor was there to give layout pixels; then only U and V
mean anything.  There is no :client: look ID up among the live clients.

A sample is one frame of pointing, not a state that lasts: return nil
when the history is off or no hand was pointing within a quarter of a
second before MS.  */)
  (Lisp_Object ms)
{
  struct cmacs_ht_point_sample s;

  if (!cmacs_ht_point_at (ht_point_ms_arg (ms), &s))
    return Qnil;
  return ht_point_plist (s.ms, s.x, s.y, s.u, s.v, s.confidence, s.client,
                         s.monitor, s.hand, s.layout, -1, 0);
}

DEFUN ("cmacs-handtrack-point-history-dwell",
       Fcmacs_handtrack_point_history_dwell,
       Scmacs_handtrack_point_history_dwell, 2, 4, 0,
       doc: /* Return where a hand rested longest between FROM-MS and TO-MS.
The pointing samples in that window are grouped into rests -- runs of
one hand over the same window that stay within RADIUS layout pixels
\(default: the `point-radius' option, 96) of where the run began, with no
gap longer than a quarter of a second -- and the rest that lasted
longest inside the window wins; of equals, the earliest.  A rest shorter
than MIN-MS milliseconds (default: the `point-dwell' option, 120) is not
one: a hand passing through on its way somewhere else points at
nothing.

The value is as for `cmacs-handtrack-point-history-at', with X, Y, U, V
and C the means over the rest's samples in the window, T its first
sample there, and added :duration (milliseconds inside the window) and
:since (when the rest really began, which may be well before FROM-MS:
a hand left lying in the pose has an old one).  Return nil when the
history is off or holds no such rest.  */)
  (Lisp_Object from_ms, Lisp_Object to_ms, Lisp_Object radius,
   Lisp_Object min_ms)
{
  struct cmacs_ht_point_rest r;
  double rad = pt.radius;
  gint64 min = pt.dwell_ms;

  if (!NILP (radius))
    {
      CHECK_NUMBER (radius);
      rad = XFLOATINT (radius);
    }
  if (!NILP (min_ms))
    min = ht_point_ms_arg (min_ms);
  if (!cmacs_ht_point_rest (ht_point_ms_arg (from_ms),
                            ht_point_ms_arg (to_ms), rad, min, &r))
    return Qnil;
  return ht_point_plist (r.begin, r.x, r.y, r.u, r.v, r.confidence, r.client,
                         r.monitor, r.hand, r.layout, r.duration, r.since);
}

DEFUN ("cmacs-handtrack--point-pose", Fcmacs_handtrack__point_pose,
       Scmacs_handtrack__point_pose, 1, 3, 0,
       doc: /* Classify LANDMARKS (63 numbers) as pointing or not.  For tests.
RIGHT non-nil: a right hand.  ASPECT defaults to 0.75.  The thresholds
and the active region are the current options.  Return a plist:
:pointing, :confidence, :index-reach and :other-reach (metres on the
standard palm), :pinch-distance, :u and :v (the index fingertip as
fractions across the output) and :outside (how far beyond the active
region it is, as a fraction of the region; zero or less inside).  */)
  (Lisp_Object landmarks, Lisp_Object right, Lisp_Object aspect)
{
  CmacsHtLandmarks lm;
  LrgVRHandState st;
  struct cmacs_ht_point_pose pose;
  float u, v, outside;

  ht_landmarks_of (landmarks, &lm);
  cmacs_ht_to_hand_state (&lm, NILP (aspect) ? 0.75f : ht_float (aspect),
                          !NILP (right), &st);
  cmacs_ht_point_pose (&st, &pt.pose, &pose);
  outside = ht_region_uv (hd.cursor.region, lm.lm[8][0], lm.lm[8][1], &u, &v);
  return list (intern_c_string (":pointing"), pose.pointing ? Qt : Qnil,
               intern_c_string (":confidence"),
               make_float ((double) pose.confidence),
               intern_c_string (":index-reach"),
               make_float ((double) pose.index_reach),
               intern_c_string (":other-reach"),
               make_float ((double) pose.other_reach),
               intern_c_string (":pinch-distance"),
               make_float ((double) pose.pinch_m),
               intern_c_string (":u"), make_float ((double) u),
               intern_c_string (":v"), make_float ((double) v),
               intern_c_string (":outside"), make_float ((double) outside));
}

DEFUN ("cmacs-handtrack--simulate-point", Fcmacs_handtrack__simulate_point,
       Scmacs_handtrack__simulate_point, 2, 2, 0,
       doc: /* Run camera FRAMES through the pointing history on output GEOMETRY.
For tests.  FRAMES is as for `cmacs-handtrack--simulate': a list of
\(MILLISECONDS LEFT RIGHT), each hand nil or 63 landmark numbers.
MILLISECONDS is the time each sample is stored with, as it stands (the
`point-latency' option is not taken off).  GEOMETRY is (X Y WIDTH
HEIGHT).  The frames go through the same mapping, pose test, smoothing
and ring as live results do, with the current options, and into the
real ring -- which must be on (`cmacs-handtrack-point-history-enable')
and is not emptied first.  No compositor is asked what is under the
fingertip: every sample has client 0 and no monitor.  Return the number
of samples stored.  */)
  (Lisp_Object frames, Lisp_Object geometry)
{
  struct ht_tracker tr;
  Lisp_Object tail;
  int geom[4], k, stored = 0;

  for (k = 0, tail = geometry; k < 4; k++, tail = Fcdr (tail))
    {
      CHECK_FIXNUM (Fcar (tail));
      geom[k] = (int) XFIXNUM (Fcar (tail));
    }
  if (geom[2] <= 0 || geom[3] <= 0)
    args_out_of_range (geometry, Qnil);
  memset (&tr, 0, sizeof tr);
  lrg_vr_hand_state_reset (&tr.hands[0]);
  lrg_vr_hand_state_reset (&tr.hands[1]);
  ht_point_filter_reset (&pt.f[0]);
  ht_point_filter_reset (&pt.f[1]);
  pt.f[0].was_pinched = pt.f[1].was_pinched = false;
  CHECK_LIST (frames);
  for (tail = frames; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object fr = XCAR (tail), l, r;
      CmacsHtLandmarks lm[2];
      struct cmacs_hg_action act[HT_ACTIONS];
      gint64 ms;
      int n = 0;

      CHECK_CONS (fr);
      CHECK_FIXNUM (XCAR (fr));
      ms = XFIXNUM (XCAR (fr));
      l = Fnth (make_fixnum (1), fr);
      r = Fnth (make_fixnum (2), fr);
      if (!NILP (l))
        {
          ht_landmarks_of (l, &lm[n]);
          lm[n++].handedness = 0.0f;
        }
      if (!NILP (r))
        {
          ht_landmarks_of (r, &lm[n]);
          lm[n++].handedness = 1.0f;
        }
      ht_track (&tr, lm, n, 0.75f, ms * 1000, NULL, NULL, &ht_desktop, act,
                HT_ACTIONS);
      stored += ht_point_step (&tr, ms, ms * 1000, geom, false);
    }
  /* A live result after this starts its filters afresh.  */
  ht_point_filter_reset (&pt.f[0]);
  ht_point_filter_reset (&pt.f[1]);
  pt.f[0].was_pinched = pt.f[1].was_pinched = false;
  return make_fixnum (stored);
}

void
syms_of_cmacs_handtrack_defuns (void)
{
  hd.target = intern_c_string ("auto");
  staticpro (&hd.target);
  lrg_vr_hand_state_reset (&hd.tr.hands[0]);
  lrg_vr_hand_state_reset (&hd.tr.hands[1]);

  defsubr (&Scmacs_handtrack_available_p);
  defsubr (&Scmacs_handtrack_open);
  defsubr (&Scmacs_handtrack_close);
  defsubr (&Scmacs_handtrack_status);
  defsubr (&Scmacs_handtrack_hands);
  defsubr (&Scmacs_handtrack_set_target);
  defsubr (&Scmacs_handtrack_set_option);
  defsubr (&Scmacs_handtrack_event_codes);
  defsubr (&Scmacs_handtrack__synthetic_landmarks);
  defsubr (&Scmacs_handtrack__map);
  defsubr (&Scmacs_handtrack__simulate);
  defsubr (&Scmacs_handtrack__simulate_pointer);
  defsubr (&Scmacs_handtrack__anchors);
  defsubr (&Scmacs_handtrack__decode);
  defsubr (&Scmacs_handtrack__letterbox);
  defsubr (&Scmacs_handtrack__roi_from_palm);
  defsubr (&Scmacs_handtrack_point_history_now);
  defsubr (&Scmacs_handtrack_point_history_enable);
  defsubr (&Scmacs_handtrack_point_history_clear);
  defsubr (&Scmacs_handtrack_point_history_status);
  defsubr (&Scmacs_handtrack_point_history_at);
  defsubr (&Scmacs_handtrack_point_history_dwell);
  defsubr (&Scmacs_handtrack__point_pose);
  defsubr (&Scmacs_handtrack__simulate_point);
}

#endif /* HAVE_CMACS_HANDTRACK */
