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
#include "cmacs-libregnum.h"

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

/* Hands as the classifier sees them, frame after frame.  */
struct ht_tracker
{
  LrgVRHandState hands[2];       /* 0 left, 1 right */
  struct cmacs_hg_state g;
};

static struct
{
  struct ht_tracker tr;
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
};

/* ---------------------------------------------------------- tracking -- */

/* Advance TR by one frame of N camera hands at NOW; write the gestures
   to OUT.  ASPECT is the frame's height / width.  */
static int
ht_track (struct ht_tracker *tr, const CmacsHtLandmarks *lm, int n,
          float aspect, gint64 now, struct cmacs_hg_action *out, int max)
{
  struct cmacs_hg_sample smp[2];
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
    }
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
  return cmacs_hg_step (&tr->g, smp, now, out, max);
}

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
  n = ht_track (&hd.tr, r->hands, r->n,
                r->img_w > 0 ? (float) r->img_h / (float) r->img_w : 0.75f,
                g_get_monotonic_time (), act, HT_ACTIONS);
  for (i = 0; i < n; i++)
    ht_apply (&act[i]);
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
  if (!cmacs_ht_worker_start (&cfg, ht_on_result, &err))
    {
      Lisp_Object msg = build_string (err != NULL ? err : "hand tracking failed");
      g_free (err);
      xsignal1 (Qerror, msg);
    }
  return Qt;
}

DEFUN ("cmacs-handtrack-close", Fcmacs_handtrack_close,
       Scmacs_handtrack_close, 0, 0, 0,
       doc: /* Stop tracking hands.  The camera stays as it was.  */)
  (void)
{
  cmacs_ht_worker_stop ();
  lrg_vr_hand_state_reset (&hd.tr.hands[0]);
  lrg_vr_hand_state_reset (&hd.tr.hands[1]);
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
               intern_c_string (":target"), hd.target);
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
The thresholds apply from the next `cmacs-handtrack-open'.  Return VALUE.  */)
  (Lisp_Object key, Lisp_Object value)
{
  CHECK_SYMBOL (key);
  if (EQ (key, intern_c_string ("swap-hands")))
    {
      hd.swap_hands = !NILP (value);
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
      k = ht_track (&tr, lm, n, 0.75f, XFIXNUM (XCAR (fr)) * 1000, act,
                    HT_ACTIONS);
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
  defsubr (&Scmacs_handtrack__anchors);
  defsubr (&Scmacs_handtrack__decode);
  defsubr (&Scmacs_handtrack__letterbox);
  defsubr (&Scmacs_handtrack__roi_from_palm);
}

#endif /* HAVE_CMACS_HANDTRACK */
