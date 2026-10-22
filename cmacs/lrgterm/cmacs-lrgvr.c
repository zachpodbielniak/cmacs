/* cmacs-lrgvr.c --- `emacs --lrg=3dvr': the lrg 3D scene in a VR headset.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

VR is a presentation mode of the 3D lrg frame, not a separate display
backend.  Redisplay keeps rasterising the frame and slicing it onto panels
exactly as in `--lrg=3d'; this file adds:

  - an LrgOpenXRService bound to the frame's GL context, presented through
    lrg_3d_surface_render_vr () once per headset frame;
  - frame pacing without blocking Emacs: the service waits for frames on a
    thread of its own and signals an eventfd, registered as a keyboard wait
    descriptor, so pselect wakes us exactly when the runtime wants a frame
    and lrg_read_socket calls cmacs_lrgvr_tick ();
  - motion controllers as input: a laser per hand that clicks, drags and
    scrolls in buffers (ordinary mouse events at the frame pixel it hits),
    grabs and places panels, moves and turns the viewer, and types on an
    in-world keyboard;
  - controller buttons as function keys F25..F31, which cmacs-lrg-vr.el
    translates to <vr-right-a> etc., so every binding lives in Lisp;
  - tracked hands (OpenXR XR_EXT_hand_tracking) in place of a controller
    that is put down: the hand's aim ray is the laser, a pinch is the
    trigger -- tap to click, hold still to drag, move to scroll, pull on
    empty space to move yourself -- both hands pinching stretch the world,
    and a palm turned up is a menu.  The pinch is classified here at frame
    rate (vr_gesture_step); Lisp only sees the discrete results as
    <vr-hand-...> events.  See "hand tracking" below.

Default controls (right hand points, left hand moves; see cmacs-lrg-vr.el):
  trigger        mouse-1 at the laser (press / drag / release)
  grip           grab the panel or keyboard under the laser and carry it;
                 on empty space, grab the world and pull yourself around
  right stick    scroll (Y) and horizontal scroll (X); while grabbing,
                 push/pull (Y) and resize (X) the held panel
  right stick ↓  mouse-3 at the laser
  left stick     move (Y), snap turn (X)
  A / B / X / Y / menu / left stick click
                 <vr-right-a> <vr-right-b> <vr-left-x> <vr-left-y>
                 <vr-menu> <vr-left-stick>                              */

#include <config.h>

#ifdef HAVE_CMACS_LRGVR

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <libregnum.h>
#include <rlgl.h>
#include <GL/gl.h>

#include "lisp.h"
#include "frame.h"
#include "window.h"
#include "keyboard.h"
#include "termhooks.h"
#include "dispextern.h"
#include "blockinput.h"
#include "coding.h"
#include "cmacs-lrgterm.h"

/* X keysyms for the keys the in-world keyboard and the buttons produce.  */
#define VR_XK_BackSpace 0xff08
#define VR_XK_Tab       0xff09
#define VR_XK_Return    0xff0d
#define VR_XK_Escape    0xff1b
#define VR_XK_Left      0xff51
#define VR_XK_Up        0xff52
#define VR_XK_Right     0xff53
#define VR_XK_Down      0xff54
#define VR_XK_Delete    0xffff
#define VR_XK_F25       0xffd6   /* <vr-right-a> */
#define VR_XK_F26       0xffd7   /* <vr-right-b> */
#define VR_XK_F27       0xffd8   /* <vr-left-x> */
#define VR_XK_F28       0xffd9   /* <vr-left-y> */
#define VR_XK_F29       0xffda   /* <vr-menu> */
#define VR_XK_F30       0xffdb   /* <vr-left-stick> (the move hand's) */
#define VR_XK_F31       0xffdc   /* <vr-right-stick> (the pointer hand's, off a panel) */
#define VR_XK_F32       0xffdd   /* <vr-flick-left> */
#define VR_XK_F33       0xffde   /* <vr-flick-right> */
#define VR_XK_F34       0xffdf   /* <vr-flick-up> */
#define VR_XK_F35       0xffe0   /* <vr-flick-down> */

/* Hand-tracking gestures reuse the flick keys in banks of their own (the
   flicks never take alt, hyper or super):
     alt   F32 / F33   <vr-hand-left-palm-up> / <vr-hand-right-palm-up>
     super F32 / F33   <vr-hand-left-palm-down> / <vr-hand-right-palm-down>
     hyper F32 / F33   <vr-hand-left-pinch> / <vr-hand-right-pinch>
                       (a pinch tapped on empty space)
     alt   F34 / F35   <vr-hand-zoom-in> / <vr-hand-zoom-out>
                       (the end of a two-hand stretch that changed the
                       world scale)
   cmacs-lrg-vr.el names them.  */
#define VR_HAND_PALM_UP_MOD   alt_modifier
#define VR_HAND_PALM_DOWN_MOD super_modifier
#define VR_HAND_PINCH_MOD     hyper_modifier
#define VR_HAND_ZOOM_MOD      alt_modifier

/* Buttons are named by their letter, not their hand: <vr-a> <vr-b> <vr-x>
   <vr-y> <vr-menu> -- F25..F29.  A Touch-style controller has A and B on
   the right and X and Y on the left, which arrive as the left hand's A and
   B bits; the Steam Frame has all four on the right.  Either way the
   letter on the button is its name.  Buttons past the F-keys are a second
   bank, F25..F31 with the alt bit: <vr-bumper> (the pointer hand's),
   <vr-left-bumper>, <vr-view> and the D-pad.  So alt cannot be a layer
   modifier.  */
#define VR_BANK2        alt_modifier

/* Buttons distinguish a tap from a hold.  A tap is sent on release, as the
   button's plain keysym; holding past the hold time sends the keysym with
   the hyper bit at once, and the release after that the keysym with the
   super bit.  cmacs-lrg-vr.el translates them to <vr-right-a>,
   <vr-right-a-hold> and <vr-right-a-release>.  Hyper and super are
   reserved for this on these keysyms; the layer modifiers below are
   shift, meta, control or alt.  */
#define VR_HOLD_MOD     hyper_modifier
#define VR_RELEASE_MOD  super_modifier

enum vr_button
{
  VB_A, VB_B, VB_X, VB_Y, VB_MENU, VB_STICK, VB_BUMPER, VB_VIEW,
  VB_DPAD_UP, VB_DPAD_DOWN, VB_DPAD_LEFT, VB_DPAD_RIGHT, VB_COUNT
};

#define VR_DEADZONE      0.25f
#define VR_SNAP_ARM      0.75f
#define VR_SNAP_REARM    0.30f
#define VR_LASER_M       4.0f    /* laser length when it hits nothing */
/* While Lisp is busy, render a headset frame at most this often -- fifteen
   a second, SteamVR reprojecting in between -- and leave the rest of the
   main thread to Lisp.  Each frame blocks in xrEndFrame until the GPU is
   done with it, so rendering every frame the runtime wants would make a
   long command, or a large init file, crawl.  Idle (in the command loop,
   waiting for input), every frame renders.  */
#define VR_BUSY_FRAME_US 66667

/* The frame watcher (vr_watch_thread) waits this long after a frame becomes
   due before deciding Emacs is busy, and at least this long between the
   SIGIOs it then raises.  */
#define VR_WATCH_GRACE_US  4000
#define VR_WATCH_PERIOD_US 20000

/* The head of raylib's Texture2D: its GL name comes first.  graylib hands the
   struct out opaquely; mirroring two fields avoids pulling raylib.h (whose
   type names collide with Emacs's) into this translation unit.  */
typedef struct { unsigned int id; int width; } vr_texture_head;

/* raylib's log threshold, declared here for the same reason (LOG_WARNING
   is 4).  At its INFO default raylib logs every panel texture upload, and
   a VR session is usually launched with its output going to a log file
   (~/.local/state/cmacs/emacs-vr.log), which would grow without bound.  */
extern void SetTraceLogLevel (int log_level);
#define VR_RAYLIB_LOG_WARNING 4

/* ----------------------------------------------------------- keyboard ---- */

enum vr_key_kind { VK_NONE, VK_CHAR, VK_SYM, VK_SHIFT, VK_CTRL, VK_META,
                   VK_SUPER, VK_HIDE };

struct vr_key
{
  const char *label;
  enum vr_key_kind kind;
  int code;            /* VK_CHAR: unshifted char; VK_SYM: keysym */
  int shifted;         /* VK_CHAR: shifted char */
  float width;         /* in key units */
};

#define K(c, s)  { NULL, VK_CHAR, c, s, 1.0f }
static const struct vr_key vr_row0[] = {
  K('`', '~'), K('1', '!'), K('2', '@'), K('3', '#'), K('4', '$'), K('5', '%'),
  K('6', '^'), K('7', '&'), K('8', '*'), K('9', '('), K('0', ')'), K('-', '_'),
  K('=', '+'), { "Bksp", VK_SYM, VR_XK_BackSpace, 0, 1.6f } };
static const struct vr_key vr_row1[] = {
  { "Tab", VK_SYM, VR_XK_Tab, 0, 1.4f },
  K('q', 'Q'), K('w', 'W'), K('e', 'E'), K('r', 'R'), K('t', 'T'), K('y', 'Y'),
  K('u', 'U'), K('i', 'I'), K('o', 'O'), K('p', 'P'), K('[', '{'), K(']', '}'),
  K('\\', '|'), { "Del", VK_SYM, VR_XK_Delete, 0, 1.2f } };
static const struct vr_key vr_row2[] = {
  { "Ctrl", VK_CTRL, 0, 0, 1.7f },
  K('a', 'A'), K('s', 'S'), K('d', 'D'), K('f', 'F'), K('g', 'G'), K('h', 'H'),
  K('j', 'J'), K('k', 'K'), K('l', 'L'), K(';', ':'), K('\'', '"'),
  { "Ret", VK_SYM, VR_XK_Return, 0, 2.0f } };
static const struct vr_key vr_row3[] = {
  { "Shift", VK_SHIFT, 0, 0, 2.2f },
  K('z', 'Z'), K('x', 'X'), K('c', 'C'), K('v', 'V'), K('b', 'B'), K('n', 'N'),
  K('m', 'M'), K(',', '<'), K('.', '>'), K('/', '?'),
  { "Up", VK_SYM, VR_XK_Up, 0, 1.0f },
  { "Shift", VK_SHIFT, 0, 0, 1.5f } };
static const struct vr_key vr_row4[] = {
  { "Esc", VK_SYM, VR_XK_Escape, 0, 1.3f },
  { "Meta", VK_META, 0, 0, 1.4f },
  { "Super", VK_SUPER, 0, 0, 1.4f },
  { "Space", VK_CHAR, ' ', ' ', 6.0f },
  { "Hide", VK_HIDE, 0, 0, 1.4f },
  { "Left", VK_SYM, VR_XK_Left, 0, 1.0f },
  { "Down", VK_SYM, VR_XK_Down, 0, 1.0f },
  { "Right", VK_SYM, VR_XK_Right, 0, 1.0f } };
#undef K

static const struct { const struct vr_key *keys; int n; } vr_rows[] = {
  { vr_row0, G_N_ELEMENTS (vr_row0) },
  { vr_row1, G_N_ELEMENTS (vr_row1) },
  { vr_row2, G_N_ELEMENTS (vr_row2) },
  { vr_row3, G_N_ELEMENTS (vr_row3) },
  { vr_row4, G_N_ELEMENTS (vr_row4) },
};
#define VR_KB_ROWS   ((int) G_N_ELEMENTS (vr_rows))
#define VR_KB_UNITS  15.0f            /* widest row, in key units */
#define VR_KB_KEY_PX 96               /* texture pixels per key unit */
#define VR_KB_PAD_PX 12

/* ------------------------------------------------------------- state ---- */

/* What drives a hand's laser this frame.  */
enum vr_source { SRC_CONTROLLER, SRC_HAND };

struct vr_hand
{
  bool tracked;
  enum vr_source src;            /* the controller, or the tracked hand */
  bool src_changed;              /* src differs from last frame's */
  float origin[3], dir[3];       /* laser, scene units */
  bool hit_panel;                /* laser lands on a panel */
  float hit_dist;                /* scene units, to the panel or keyboard */
  int fx, fy;                    /* frame pixel under the laser */
  guint64 key;                   /* panel under the laser */
  int kb_row, kb_col;            /* keyboard key under the laser, or -1 */
  bool kb_trigger;               /* the trigger is down on the keyboard */
  int kb_hold;                   /* modifier key it holds, or VK_NONE */
  bool kb_hold_used;             /* a key was typed while it was held */

  guint buttons, prev;
  bool trigger_mouse;            /* trigger press went to Emacs as mouse-1 */
  bool trigger_view;             /* ... or to an embedded view (the globe) */
  int last_fx, last_fy;

  /* Grip: carrying a panel (grab_key), the keyboard, or the world. */
  enum { GRAB_NONE, GRAB_PANEL, GRAB_KEYBOARD, GRAB_WORLD } grab;
  guint64 grab_key;
  float grab_local[3];           /* unused since the laser carry */
  float grab_yaw_off;            /* object yaw - yaw facing the hand, degrees */
  float grab_w, grab_h;
  float grab_dist;               /* along the laser to the grabbed point */
  float grab_off_r, grab_off_u;  /* object centre from that point: right, up */
  float grab_track[3];           /* GRAB_WORLD: controller position, metres */

  float scroll_acc, hscroll_acc;
  bool snap_used;

  /* Tap / hold (enum vr_button).  */
  gint64 btn_down_us[VB_COUNT];  /* 0: not down */
  gint64 btn_next_us[VB_COUNT];  /* D-pad as arrows: next auto-repeat */
  bool btn_held[VB_COUNT];       /* the hold event was sent */
  bool btn_consumed[VB_COUNT];   /* handled at press (mouse-3): no tap */
  int btn_mods[VB_COUNT];        /* layer modifiers when it went down */

  bool flick_x_used, flick_y_used;

  /* Indicator above the controller (cmacs-lrg-vr-set-indicator).  */
  bool indicator;
  guint8 indicator_rgb[3];
};

/* ------------------------------------------------- hand tracking: gestures

   A pinch is one of five things, decided while it is held:

     tap      released quickly without moving: a click at the laser (on a
              panel), a key (on the keyboard), <vr-hand-*-pinch> (on
              nothing);
     drag     held still on a panel for VR_HAND_HOLD_US: mouse-1 goes down
              where the pinch began and follows the laser until release --
              selecting text, dragging a scroll bar, orbiting a globe;
     scroll   moved on a panel before that: the content follows the hand,
              VR_HAND_SCROLL_PX of laser travel per wheel step;
     pull     moved on empty space: the world follows the hand (a world
              grab, as the controller grip does);
     zoom     both hands pinching at once, neither busy on a panel: the
              world scale follows the distance between them.

   A palm turned up and held for VR_HAND_PALM_US is <vr-hand-*-palm-up>;
   turning it back is <vr-hand-*-palm-down>.

   vr_gesture_step is the whole classifier and is pure -- samples in,
   actions out, no Emacs or libregnum state -- so it runs per headset frame
   here and from `cmacs-lrg-vr--simulate-hand-gestures' in tests alike.  */

#define VR_HAND_HOLD_US    450000  /* still this long on a panel: drag */
#define VR_HAND_TAP_EMPTY_US 600000 /* longest tap on empty space */
#define VR_HAND_MOVE_PX    14      /* laser travel: a pending pinch scrolls */
#define VR_HAND_MOVE_M     0.03f   /* hand travel: a pending pinch pulls */
#define VR_HAND_SCROLL_PX  36      /* laser pixels per wheel step */
#define VR_HAND_PALM_COS   0.70f   /* palm within ~45 degrees of up */
#define VR_HAND_PALM_US    300000  /* palm up this long: the event */
#define VR_HAND_ZOOM_MIN_M 0.05f   /* hands closer than this cannot zoom */
#define VR_HAND_ZOOM_DEAD  0.05f   /* scale change that counts as a zoom */
#define VR_HAND_MAX_ACTIONS 24

enum vr_hand_target { HT_NONE, HT_PANEL, HT_KEYBOARD, HT_WORKSPACE };

/* One hand, one frame, as the classifier sees it.  */
struct vr_hand_sample
{
  bool tracked;                  /* hand tracking drives this hand */
  bool pinched;                  /* the latch, hysteresis applied */
  bool palm_up;
  enum vr_hand_target target;    /* under the laser */
  int fx, fy;                    /* frame pixel under the laser */
  float pos[3];                  /* pinch point, tracking metres */
};

enum vr_pinch_mode { PM_IDLE, PM_PENDING, PM_DRAG, PM_SCROLL, PM_PULL,
                     PM_KEY, PM_ZOOM };

struct vr_hand_gesture
{
  enum vr_pinch_mode mode;
  gint64 t0;                     /* pinch start */
  enum vr_hand_target target0;   /* what it started on */
  int fx0, fy0, lastfx, lastfy;
  float pos0[3], lastpos[3];
  float acc_x, acc_y;            /* scroll travel not yet a wheel step */
  bool palm_up, palm_sent;
  gint64 palm_since;
};

struct vr_gestures
{
  struct vr_hand_gesture h[2];
  bool zooming;
  float zoom_d0, zoom_ratio;
};

enum vr_hand_action_kind
{
  HA_CLICK, HA_DRAG_BEGIN, HA_DRAG_END, HA_SCROLL, HA_PULL_BEGIN,
  HA_PULL_MOVE, HA_PULL_END, HA_TAP, HA_KEY_DOWN, HA_KEY_UP, HA_PALM_UP,
  HA_PALM_DOWN, HA_ZOOM_BEGIN, HA_ZOOM, HA_ZOOM_END
};

struct vr_hand_action
{
  enum vr_hand_action_kind kind;
  int hand;                      /* 0 left, 1 right, -1 both (zoom) */
  int x, y;                      /* pixels (click/drag), wheel steps (scroll) */
  float v[3];                    /* metres (pull), ratio in v[0] (zoom) */
};

static float
v3_dist (const float *a, const float *b)
{
  float dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
  return sqrtf (dx * dx + dy * dy + dz * dz);
}

static int
vr_gesture_push (struct vr_hand_action *out, int n, int max,
                 enum vr_hand_action_kind kind, int hand, int x, int y,
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
vr_gesture_end (struct vr_hand_gesture *g, int h, gint64 now, bool released,
                struct vr_hand_action *out, int n, int max)
{
  switch (g->mode)
    {
    case PM_PENDING:
      if (!released)
        break;
      if (g->target0 == HT_PANEL || g->target0 == HT_WORKSPACE)
        n = vr_gesture_push (out, n, max, HA_CLICK, h, g->fx0, g->fy0, NULL);
      else if (g->target0 == HT_NONE && now - g->t0 <= VR_HAND_TAP_EMPTY_US)
        n = vr_gesture_push (out, n, max, HA_TAP, h, 0, 0, NULL);
      break;
    case PM_DRAG:
      n = vr_gesture_push (out, n, max, HA_DRAG_END, h, g->lastfx, g->lastfy,
                           NULL);
      break;
    case PM_PULL:
      n = vr_gesture_push (out, n, max, HA_PULL_END, h, 0, 0, NULL);
      break;
    case PM_KEY:
      n = vr_gesture_push (out, n, max, HA_KEY_UP, h, 0, 0, NULL);
      break;
    default:
      break;
    }
  g->mode = PM_IDLE;
  return n;
}

/* Advance the gesture state G by one frame of samples S (both hands) at
   NOW (microseconds).  Writes up to MAX actions to OUT; returns how many.  */
static int
vr_gesture_step (struct vr_gestures *g, const struct vr_hand_sample *s,
                 gint64 now, struct vr_hand_action *out, int max)
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
                && (g->h[h].mode == PM_PENDING || g->h[h].mode == PM_PULL);
      if (ready && v3_dist (s[0].pos, s[1].pos) >= VR_HAND_ZOOM_MIN_M)
        {
          for (h = 0; h < 2; h++)
            {
              if (g->h[h].mode == PM_PULL)
                n = vr_gesture_push (out, n, max, HA_PULL_END, h, 0, 0, NULL);
              g->h[h].mode = PM_ZOOM;
            }
          g->zooming = true;
          g->zoom_d0 = v3_dist (s[0].pos, s[1].pos);
          g->zoom_ratio = 1.0f;
          n = vr_gesture_push (out, n, max, HA_ZOOM_BEGIN, -1, 0, 0, NULL);
        }
    }
  else
    {
      if (s[0].tracked && s[0].pinched && s[1].tracked && s[1].pinched)
        {
          float r[3];
          g->zoom_ratio = v3_dist (s[0].pos, s[1].pos) / g->zoom_d0;
          r[0] = g->zoom_ratio; r[1] = r[2] = 0.0f;
          n = vr_gesture_push (out, n, max, HA_ZOOM, -1, 0, 0, r);
        }
      else
        {
          float r[3];
          r[0] = g->zoom_ratio; r[1] = r[2] = 0.0f;
          g->zooming = false;
          n = vr_gesture_push (out, n, max, HA_ZOOM_END, -1, 0, 0, r);
          /* A hand still pinched stays spent until it lets go.  */
        }
    }

  for (h = 0; h < 2; h++)
    {
      struct vr_hand_gesture *hg = &g->h[h];
      const struct vr_hand_sample *hs = &s[h];

      if (!hs->tracked)
        {
          n = vr_gesture_end (hg, h, now, false, out, n, max);
          if (hg->palm_up && hg->palm_sent)
            n = vr_gesture_push (out, n, max, HA_PALM_DOWN, h, 0, 0, NULL);
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
          else if (!hg->palm_sent && now - hg->palm_since >= VR_HAND_PALM_US)
            {
              hg->palm_sent = true;
              n = vr_gesture_push (out, n, max, HA_PALM_UP, h, 0, 0, NULL);
            }
        }
      else if (hg->palm_up && !hs->palm_up)
        {
          if (hg->palm_sent)
            n = vr_gesture_push (out, n, max, HA_PALM_DOWN, h, 0, 0, NULL);
          hg->palm_up = hg->palm_sent = false;
        }

      if (!hs->pinched)
        {
          if (hg->mode != PM_IDLE)
            n = vr_gesture_end (hg, h, now, true, out, n, max);
          continue;
        }

      switch (hg->mode)
        {
        case PM_IDLE:
          hg->t0 = now;
          hg->target0 = hs->target;
          hg->fx0 = hg->lastfx = hs->fx;
          hg->fy0 = hg->lastfy = hs->fy;
          memcpy (hg->pos0, hs->pos, sizeof hg->pos0);
          memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
          hg->acc_x = hg->acc_y = 0.0f;
          if (hs->target == HT_KEYBOARD)
            {
              hg->mode = PM_KEY;
              n = vr_gesture_push (out, n, max, HA_KEY_DOWN, h, 0, 0, NULL);
            }
          else
            hg->mode = PM_PENDING;
          break;

        case PM_PENDING:
          if (hg->target0 == HT_PANEL)
            {
              int moved = (hs->target == HT_PANEL)
                          ? abs (hs->fx - hg->fx0) + abs (hs->fy - hg->fy0) : 0;
              if (moved >= VR_HAND_MOVE_PX)
                {
                  hg->mode = PM_SCROLL;
                  hg->lastfx = hs->fx;
                  hg->lastfy = hs->fy;
                }
              else if (now - hg->t0 >= VR_HAND_HOLD_US)
                {
                  hg->mode = PM_DRAG;
                  n = vr_gesture_push (out, n, max, HA_DRAG_BEGIN, h, hg->fx0,
                                       hg->fy0, NULL);
                }
            }
          else if (hg->target0 == HT_NONE
                   && v3_dist (hs->pos, hg->pos0) >= VR_HAND_MOVE_M)
            {
              hg->mode = PM_PULL;
              memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
              n = vr_gesture_push (out, n, max, HA_PULL_BEGIN, h, 0, 0, NULL);
            }
          break;

        case PM_SCROLL:
          if (hs->target == HT_PANEL)
            {
              int sx, sy;
              hg->acc_x += (float) (hs->fx - hg->lastfx);
              hg->acc_y += (float) (hs->fy - hg->lastfy);
              hg->lastfx = hs->fx;
              hg->lastfy = hs->fy;
              sx = (int) (hg->acc_x / VR_HAND_SCROLL_PX);
              sy = (int) (hg->acc_y / VR_HAND_SCROLL_PX);
              hg->acc_x -= (float) (sx * VR_HAND_SCROLL_PX);
              hg->acc_y -= (float) (sy * VR_HAND_SCROLL_PX);
              if (sx != 0 || sy != 0)
                n = vr_gesture_push (out, n, max, HA_SCROLL, h, sx, sy, NULL);
            }
          break;

        case PM_DRAG:
          if (hs->target == HT_PANEL)
            {
              hg->lastfx = hs->fx;
              hg->lastfy = hs->fy;
            }
          break;

        case PM_PULL:
          {
            float d[3];
            int i;
            for (i = 0; i < 3; i++)
              d[i] = hs->pos[i] - hg->lastpos[i];
            memcpy (hg->lastpos, hs->pos, sizeof hg->lastpos);
            if (d[0] != 0.0f || d[1] != 0.0f || d[2] != 0.0f)
              n = vr_gesture_push (out, n, max, HA_PULL_MOVE, h, 0, 0, d);
          }
          break;

        default:   /* PM_KEY, PM_ZOOM: nothing until release */
          break;
        }
    }
  return n;
}

static struct
{
  bool active;
  bool window_hidden;            /* desktop window hidden; evdev keyboard */
  struct frame *f;
  Lrg3DSurface *s3;
  LrgOpenXRService *xr;
  int frame_fd;
  bool modal;                    /* a modal loop (popup menu) runs: no throttle */
  GThread *watch_thread;         /* vr_watch_thread */
  gint watch_quit;               /* atomic */
  bool quit_sent;
  gint64 last_frame_us;
  float dt;
  guint64 frame_no;
  bool pointers_fresh;           /* lasers recomputed for the current frame */
  char *shot_path;               /* cmacs-lrg-vr-screenshot: eye PNG to write */

  struct vr_hand hand[2];
  LrgVRHandState hs[2];          /* tracked hands, this frame */
  struct vr_gestures gestures;   /* pinch classifier (vr_gesture_step) */
  float zoom_scale0;             /* world scale when a stretch began */
  bool hands_enabled;            /* hands drive lasers (option `hands') */
  bool show_joints;              /* draw tracked hands (`hand-joints') */
  int pointer_hand;              /* hand whose laser is "the mouse" */
  bool mouse_valid;
  int mouse_x, mouse_y;

  /* In-world keyboard. */
  bool kb_visible;
  float kb_center[3];
  float kb_yaw;                  /* degrees */
  float kb_tilt;                 /* degrees from vertical, top away */
  float kb_w, kb_h;              /* scene units */
  GrlTexture *kb_texture;
  int kb_shift;                  /* 0 off, 1 one-shot, 2 locked */
  bool kb_ctrl, kb_meta, kb_super;
  bool kb_dirty;

  /* Options (cmacs-lrg-vr-set-option). */
  float snap_degrees;
  float move_speed;              /* metres/second at full stick */
  float scroll_rate;             /* wheel events/second at full stick */
  bool haptics;
  int move_hand;                 /* hand that moves and turns */

  /* The modifier hand: while `modifier_hand' is on, the move hand's
     trigger and grip are layer modifiers instead of click and grab --
     trigger, grip, or both held add mod_trigger, mod_grip or mod_both
     to everything the other hand sends.  */
  bool modifier_hand;
  int mod_trigger, mod_grip, mod_both;
  int mod_second;                /* 0 auto, 1 bumper, 2 grip: the second
                                    layer button (see vr_second_is_bumper) */
  bool second_is_bumper;         /* resolved: the bumper, not the grip */
  gint64 second_checked_us;
  int layer;                     /* modifiers in effect this frame */
  gint64 hold_us;                /* tap / hold threshold */
  bool dpad_arrows;              /* the D-pad sends arrow keys, repeating */
} vr = {
  .frame_fd = -1, .pointer_hand = LRG_VR_HAND_RIGHT,
  .snap_degrees = 30.0f, .move_speed = 1.5f, .scroll_rate = 10.0f,
  .haptics = true, .move_hand = LRG_VR_HAND_LEFT, .kb_tilt = 50.0f,
  .modifier_hand = true, .hold_us = 350000, .dpad_arrows = true,
  .mod_trigger = shift_modifier, .mod_grip = meta_modifier,
  .mod_both = ctrl_modifier, .hands_enabled = true, .show_joints = true,
};

static LrgVRService *
vr_service (void)
{
  return vr.xr != NULL ? LRG_VR_SERVICE (vr.xr) : NULL;
}

static void
vr_pulse (int hand, float seconds, float amplitude)
{
  if (vr.haptics && vr.xr != NULL)
    lrg_vr_service_trigger_haptic (vr_service (), (LrgVRHand) hand, seconds,
                                   amplitude);
}

/* True while H is the modifier hand: its trigger and grip are layer
   modifiers, not click and grab.  */
static bool
vr_is_modifier_hand (int h)
{
  /* A tracked hand has no trigger or grip to hold a layer with.  */
  return vr.modifier_hand && h == vr.move_hand
         && vr.hand[h].src != SRC_HAND;
}

/* The pose driving hand H's laser: its controller's aim, or the tracked
   hand's aim ray.  */
static void
vr_source_pose (int h, float *pose)
{
  if (vr.hand[h].src == SRC_HAND
      && lrg_vr_hand_state_get_aim (&vr.hs[h], pose))
    return;
  lrg_vr_service_get_controller_pose (vr_service (), (LrgVRHand) h, pose);
}

/* --------------------------------------------------------- vector math -- */

static float
v_dot (const float *a, const float *b)
{
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

static float
heading_deg (float dx, float dz)
{
  return atan2f (-dx, -dz) * (float) (180.0 / G_PI);
}

/* Ry(deg) applied to (x, z), the same convention as lrg-3d-surface.c. */
static void
rot_y_deg (float deg, float x, float z, float *ox, float *oz)
{
  float t = deg * (float) (G_PI / 180.0), c = cosf (t), s = sinf (t);
  *ox = x * c + z * s;
  *oz = -x * s + z * c;
}

/* ------------------------------------------------- keyboard: geometry -- */

/* Board axes: right, and "up the board" (tilted away from the viewer). */
static void
kb_axes (float *right, float *up, float *normal)
{
  float rx, rz, fx, fz, t = vr.kb_tilt * (float) (G_PI / 180.0);

  rot_y_deg (vr.kb_yaw, 1.0f, 0.0f, &rx, &rz);
  rot_y_deg (vr.kb_yaw, 0.0f, -1.0f, &fx, &fz);   /* away from the viewer */
  right[0] = rx; right[1] = 0.0f; right[2] = rz;
  up[0] = sinf (t) * fx; up[1] = cosf (t); up[2] = sinf (t) * fz;
  /* normal = right x up, facing the viewer */
  normal[0] = right[1] * up[2] - right[2] * up[1];
  normal[1] = right[2] * up[0] - right[0] * up[2];
  normal[2] = right[0] * up[1] - right[1] * up[0];
}

/* Key (row, col) at board coordinates U, V in 0..1 (V down from the top). */
static bool
kb_key_at (float u, float v, int *row, int *col)
{
  int r, c;
  float x, units;

  if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
    return false;
  r = (int) (v * VR_KB_ROWS);
  if (r >= VR_KB_ROWS)
    r = VR_KB_ROWS - 1;
  x = u * VR_KB_UNITS;
  units = 0.0f;
  for (c = 0; c < vr_rows[r].n; c++)
    {
      units += vr_rows[r].keys[c].width;
      if (x < units)
        {
          *row = r;
          *col = c;
          return true;
        }
    }
  return false;
}

/* Ray vs the keyboard plane.  Returns the distance, or -1 on a miss. */
static float
kb_hit (const float *o, const float *d, int *row, int *col)
{
  float right[3], up[3], n[3], rel[3], p[3], denom, t, u, v;
  int i;

  if (!vr.kb_visible)
    return -1.0f;
  kb_axes (right, up, n);
  denom = v_dot (d, n);
  if (fabsf (denom) < 1e-5f)
    return -1.0f;
  for (i = 0; i < 3; i++)
    rel[i] = vr.kb_center[i] - o[i];
  t = v_dot (rel, n) / denom;
  if (t <= 0.0f)
    return -1.0f;
  for (i = 0; i < 3; i++)
    p[i] = o[i] + d[i] * t - vr.kb_center[i];
  u = v_dot (p, right) / vr.kb_w + 0.5f;
  v = 0.5f - v_dot (p, up) / vr.kb_h;
  if (!kb_key_at (u, v, row, col))
    return -1.0f;
  return t;
}

/* Board coordinates of key (row, col): u0..u1, v0..v1. */
static void
kb_key_rect (int row, int col, float *u0, float *u1, float *v0, float *v1)
{
  float units = 0.0f;
  int c;

  for (c = 0; c < col; c++)
    units += vr_rows[row].keys[c].width;
  *u0 = units / VR_KB_UNITS;
  *u1 = (units + vr_rows[row].keys[col].width) / VR_KB_UNITS;
  *v0 = (float) row / VR_KB_ROWS;
  *v1 = (float) (row + 1) / VR_KB_ROWS;
}

/* ------------------------------------------------- keyboard: texture ---- */

static const char *
kb_label (const struct vr_key *k, char *buf)
{
  if (k->label != NULL)
    return k->label;
  buf[0] = (char) (vr.kb_shift ? k->shifted : k->code);
  buf[1] = '\0';
  return buf;
}

static bool
kb_lit (const struct vr_key *k)
{
  return (k->kind == VK_SHIFT && vr.kb_shift)
         || (k->kind == VK_CTRL && vr.kb_ctrl)
         || (k->kind == VK_META && vr.kb_meta)
         || (k->kind == VK_SUPER && vr.kb_super);
}

/* (Re)paint the keyboard texture: the key grid, labels, and lit modifiers.
   Repainted only when the shift/modifier state changes. */
static void
kb_paint (void)
{
  int w = (int) (VR_KB_UNITS * VR_KB_KEY_PX) + 2 * VR_KB_PAD_PX;
  int h = VR_KB_ROWS * VR_KB_KEY_PX + 2 * VR_KB_PAD_PX;
  g_autoptr (GrlColor) bg = grl_color_new (24, 26, 32, 235);
  g_autoptr (GrlColor) key = grl_color_new (52, 56, 66, 255);
  g_autoptr (GrlColor) lit = grl_color_new (70, 120, 200, 255);
  g_autoptr (GrlColor) fg = grl_color_new (230, 232, 238, 255);
  g_autoptr (GrlImage) img = grl_image_new_color (w, h, bg);
  int r, c;

  for (r = 0; r < VR_KB_ROWS; r++)
    {
      float x = (float) VR_KB_PAD_PX;
      for (c = 0; c < vr_rows[r].n; c++)
        {
          const struct vr_key *k = &vr_rows[r].keys[c];
          float kw = k->width * VR_KB_KEY_PX;
          float y = (float) (VR_KB_PAD_PX + r * VR_KB_KEY_PX);
          g_autoptr (GrlRectangle) rect =
            grl_rectangle_new (x + 4, y + 4, kw - 8, VR_KB_KEY_PX - 8);
          char buf[2];
          const char *label = kb_label (k, buf);
          int size = strlen (label) > 1 ? 30 : 44;

          grl_image_draw_rectangle (img, rect, kb_lit (k) ? lit : key);
          grl_image_draw_text (img, label, (int) (x + 16), (int) (y + 24),
                               size, fg);
          x += kw;
        }
    }

  if (vr.kb_texture == NULL)
    {
      vr.kb_texture = grl_texture_new_from_image (img);
      if (vr.kb_texture != NULL)
        {
          grl_texture_gen_mipmaps (vr.kb_texture);
          grl_texture_set_filter (vr.kb_texture,
                                  GRL_TEXTURE_FILTER_TRILINEAR);
        }
    }
  else
    {
      grl_texture_update (vr.kb_texture, img);
      grl_texture_gen_mipmaps (vr.kb_texture);
    }
  vr.kb_dirty = false;
}

/* Place the keyboard in front of and below the viewer's head, facing them. */
static void
kb_place (void)
{
  float head[16], pos[3], dir[3], mpu, fx, fz, len;

  if (vr.s3 == NULL)
    return;
  mpu = lrg_3d_surface_get_vr_scale (vr.s3);
  lrg_vr_service_get_hmd_pose (vr_service (), head);
  lrg_3d_surface_vr_tracking_to_scene (vr.s3, head, pos, dir);
  fx = dir[0];
  fz = dir[2];
  len = sqrtf (fx * fx + fz * fz);
  if (len < 1e-4f)
    {
      fx = 0.0f; fz = -1.0f; len = 1.0f;
    }
  fx /= len;
  fz /= len;
  vr.kb_yaw = heading_deg (fx, fz);
  vr.kb_w = 0.60f / mpu;
  vr.kb_h = vr.kb_w * (float) (VR_KB_ROWS * VR_KB_KEY_PX + 2 * VR_KB_PAD_PX)
            / (VR_KB_UNITS * VR_KB_KEY_PX + 2 * VR_KB_PAD_PX);
  vr.kb_center[0] = pos[0] + fx * 0.42f / mpu;
  vr.kb_center[1] = pos[1] - 0.38f / mpu;
  vr.kb_center[2] = pos[2] + fz * 0.42f / mpu;
}

static void
kb_set_visible (bool on)
{
  if (on && !vr.kb_visible)
    {
      kb_place ();
      vr.kb_dirty = true;
    }
  vr.kb_visible = on;
}

/* ---------------------------------------------------------- events ------ */

static int
vr_store (struct input_event *hold_quit, struct input_event *ie)
{
  return cmacs_lrgterm_store_event (vr.f, hold_quit, ie);
}

static int
vr_emit_keysym (struct input_event *hold_quit, int keysym, int mods)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = NON_ASCII_KEYSTROKE_EVENT;
  ie.code = keysym;
  ie.modifiers = mods;
  ie.timestamp = cmacs_lrgterm_now_ms ();
  return vr_store (hold_quit, &ie);
}

static int
vr_emit_char (struct input_event *hold_quit, int ch, int mods)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = ch < 128 ? ASCII_KEYSTROKE_EVENT : MULTIBYTE_CHAR_KEYSTROKE_EVENT;
  ie.code = ch;
  ie.modifiers = mods;
  ie.timestamp = cmacs_lrgterm_now_ms ();
  return vr_store (hold_quit, &ie);
}

static int
vr_emit_mouse (struct input_event *hold_quit, int button, bool down,
               int x, int y, int mods)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = MOUSE_CLICK_EVENT;
  ie.code = button;
  ie.modifiers = mods | (down ? down_modifier : up_modifier);
  XSETINT (ie.x, x);
  XSETINT (ie.y, y);
  ie.timestamp = cmacs_lrgterm_now_ms ();
  return vr_store (hold_quit, &ie);
}

static int
vr_emit_wheel (struct input_event *hold_quit, bool horizontal, bool up,
               int x, int y)
{
  struct input_event ie;
  EVENT_INIT (ie);
  ie.kind = horizontal ? HORIZ_WHEEL_EVENT : WHEEL_EVENT;
  ie.modifiers = (up ? up_modifier : down_modifier) | vr.layer;
  XSETINT (ie.x, x);
  XSETINT (ie.y, y);
  XSETFRAME (ie.frame_or_window, vr.f);
  ie.arg = Qnil;
  ie.timestamp = cmacs_lrgterm_now_ms ();
  return vr_store (hold_quit, &ie);
}

/* Whether a hand holds modifier key KIND down with its trigger.  */
static bool
kb_held (enum vr_key_kind kind)
{
  return kind != VK_NONE && (vr.hand[0].kb_hold == (int) kind
                            || vr.hand[1].kb_hold == (int) kind);
}

/* A key was typed: every modifier held down now has been used, so letting
   go of it releases it (a chord) instead of leaving it latched.  */
static void
kb_note_used (void)
{
  vr.hand[0].kb_hold_used |= vr.hand[0].kb_hold != VK_NONE;
  vr.hand[1].kb_hold_used |= vr.hand[1].kb_hold != VK_NONE;
}

/* Keyboard modifiers for the next non-modifier key.  A tapped (latched)
   modifier is consumed by it; one held down with a trigger stays down
   until that trigger lets go, so Meta held + x is M-x and Ctrl held +
   x, s is C-x C-s.  */
static int
kb_take_mods (void)
{
  int m = (vr.kb_ctrl ? ctrl_modifier : 0) | (vr.kb_meta ? meta_modifier : 0)
          | (vr.kb_super ? super_modifier : 0);
  kb_note_used ();
  if (vr.kb_ctrl && !kb_held (VK_CTRL))
    vr.kb_ctrl = false, vr.kb_dirty = true;
  if (vr.kb_meta && !kb_held (VK_META))
    vr.kb_meta = false, vr.kb_dirty = true;
  if (vr.kb_super && !kb_held (VK_SUPER))
    vr.kb_super = false, vr.kb_dirty = true;
  return m;
}

/* After a key: a one-shot shift is spent, unless a trigger holds it.  */
static void
kb_spend_shift (void)
{
  if (vr.kb_shift == 1 && !kb_held (VK_SHIFT))
    {
      vr.kb_shift = 0;
      vr.kb_dirty = true;
    }
}

/* Hand H's trigger let go of the keyboard.  A modifier it held is
   released if a key was typed meanwhile, and stays latched if not -- a
   tap, as before.  */
static void
kb_trigger_up (struct vr_hand *hand)
{
  if (hand->kb_hold != VK_NONE && hand->kb_hold_used)
    {
      switch ((enum vr_key_kind) hand->kb_hold)
        {
        case VK_SHIFT: vr.kb_shift = 0; break;
        case VK_CTRL:  vr.kb_ctrl = false; break;
        case VK_META:  vr.kb_meta = false; break;
        case VK_SUPER: vr.kb_super = false; break;
        default: break;
        }
      vr.kb_dirty = true;
    }
  hand->kb_trigger = false;
  hand->kb_hold = VK_NONE;
  hand->kb_hold_used = false;
}

static int
kb_press (struct input_event *hold_quit, struct vr_hand *hand, int row,
          int col)
{
  const struct vr_key *k = &vr_rows[row].keys[col];
  int count = 0, mods;
  bool on = false;

  switch (k->kind)
    {
    case VK_SHIFT:
      vr.kb_shift = (vr.kb_shift + 1) % 3;   /* off -> once -> locked -> off */
      on = vr.kb_shift != 0;
      break;
    case VK_CTRL:  on = vr.kb_ctrl = !vr.kb_ctrl;   break;
    case VK_META:  on = vr.kb_meta = !vr.kb_meta;   break;
    case VK_SUPER: on = vr.kb_super = !vr.kb_super; break;
    default: break;
    }

  switch (k->kind)
    {
    case VK_SHIFT: case VK_CTRL: case VK_META: case VK_SUPER:
      vr.kb_dirty = true;
      /* Held down while the trigger is: see kb_trigger_up.  */
      hand->kb_hold = on ? (int) k->kind : VK_NONE;
      hand->kb_hold_used = false;
      break;
    case VK_HIDE:  kb_set_visible (false); break;
    case VK_NONE:  break;
    case VK_SYM:
      mods = kb_take_mods () | (vr.kb_shift ? shift_modifier : 0) | vr.layer;
      count += vr_emit_keysym (hold_quit, k->code, mods);
      kb_spend_shift ();
      break;
    case VK_CHAR:
      {
        int ch;
        mods = kb_take_mods () | vr.layer;
        /* A held shift layer is the keyboard's shift too.  */
        ch = (vr.kb_shift || (mods & shift_modifier)) ? k->shifted : k->code;
        mods &= ~shift_modifier;
        /* As lrgterm does for a physical keyboard: C-A is C-a. */
        if ((mods & ctrl_modifier) && ch >= 'A' && ch <= 'Z')
          ch += 'a' - 'A';
        count += vr_emit_char (hold_quit, ch, mods);
        kb_spend_shift ();
      }
      break;
    }
  return count;
}

/* -------------------------------------------------------- pointers ------ */

/* Recompute each hand's laser and what it lands on.  Runs once per headset
   frame, after the runtime has located the controllers: from the first
   eye's overlay (so the lasers drawn this frame use this frame's poses), or
   from the tick when no eye was drawn. */
static void
vr_update_pointers (void)
{
  LrgVRService *svc = vr_service ();
  int h;

  vr.pointers_fresh = true;

  for (h = 0; h < 2; h++)
    {
      struct vr_hand *hand = &vr.hand[h];
      float pose[16], fx = 0.0f, fy = 0.0f, dist = 0.0f, kd;
      guint64 key = 0;
      int row = -1, col = -1;
      enum vr_source was = hand->src;

      /* A controller in the hand wins; a hand alone -- the controller put
         down, or never picked up -- takes over its laser.  */
      lrg_vr_service_get_hand_state (svc, (LrgVRHand) h, &vr.hs[h]);
      hand->tracked = lrg_vr_service_is_controller_tracked (svc, (LrgVRHand) h);
      hand->src = SRC_CONTROLLER;
      if (!hand->tracked && vr.hands_enabled
          && lrg_vr_hand_state_get_aim (&vr.hs[h], pose))
        {
          hand->tracked = true;
          hand->src = SRC_HAND;
        }
      hand->src_changed |= hand->src != was;
      hand->hit_panel = false;
      hand->kb_row = hand->kb_col = -1;
      hand->hit_dist = VR_LASER_M / lrg_3d_surface_get_vr_scale (vr.s3);
      if (!hand->tracked)
        continue;

      vr_source_pose (h, pose);
      lrg_3d_surface_vr_tracking_to_scene (vr.s3, pose, hand->origin, hand->dir);

      if (lrg_3d_surface_pick_ray (vr.s3, hand->origin[0], hand->origin[1],
                                   hand->origin[2], hand->dir[0], hand->dir[1],
                                   hand->dir[2], &fx, &fy, &key, &dist))
        {
          hand->hit_panel = true;
          hand->hit_dist = dist;
          hand->fx = (int) fx;
          hand->fy = (int) fy;
          hand->key = key;
        }
      /* The keyboard floats in front of the panels: nearer wins. */
      kd = kb_hit (hand->origin, hand->dir, &row, &col);
      if (kd > 0.0f && (!hand->hit_panel || kd < hand->hit_dist))
        {
          hand->hit_panel = false;
          hand->hit_dist = kd;
          hand->kb_row = row;
          hand->kb_col = col;
        }
    }
}

/* ---------------------------------------------------------- drawing ----- */

static void
draw_quad (const float *c0, const float *c1, const float *c2, const float *c3,
           unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
  rlBegin (RL_QUADS);
  rlColor4ub (r, g, b, a);
  rlVertex3f (c0[0], c0[1], c0[2]);
  rlVertex3f (c3[0], c3[1], c3[2]);
  rlVertex3f (c2[0], c2[1], c2[2]);
  rlVertex3f (c1[0], c1[1], c1[2]);
  rlEnd ();
}

/* Corner of the keyboard at board coordinates (u, v), lifted by LIFT along
   the normal (so highlights sit just above the keys). */
static void
kb_point (float u, float v, float lift, float *out)
{
  float right[3], up[3], n[3];
  int i;

  kb_axes (right, up, n);
  for (i = 0; i < 3; i++)
    out[i] = vr.kb_center[i] + right[i] * (u - 0.5f) * vr.kb_w
             + up[i] * (0.5f - v) * vr.kb_h + n[i] * lift;
}

static void
draw_keyboard (void)
{
  float c0[3], c1[3], c2[3], c3[3], lift;
  vr_texture_head *tex;
  int h;

  if (vr.kb_dirty || vr.kb_texture == NULL)
    kb_paint ();
  if (vr.kb_texture == NULL)
    return;
  tex = grl_texture_get_handle (vr.kb_texture);
  if (tex == NULL)
    return;

  kb_point (0.0f, 0.0f, 0.0f, c0);
  kb_point (1.0f, 0.0f, 0.0f, c1);
  kb_point (1.0f, 1.0f, 0.0f, c2);
  kb_point (0.0f, 1.0f, 0.0f, c3);

  rlSetTexture (tex->id);
  rlBegin (RL_QUADS);
  rlColor4ub (255, 255, 255, 255);
  rlTexCoord2f (0.0f, 0.0f); rlVertex3f (c0[0], c0[1], c0[2]);
  rlTexCoord2f (0.0f, 1.0f); rlVertex3f (c3[0], c3[1], c3[2]);
  rlTexCoord2f (1.0f, 1.0f); rlVertex3f (c2[0], c2[1], c2[2]);
  rlTexCoord2f (1.0f, 0.0f); rlVertex3f (c1[0], c1[1], c1[2]);
  rlEnd ();
  rlSetTexture (0);

  /* Hover highlight for each hand's key. */
  lift = 0.002f / lrg_3d_surface_get_vr_scale (vr.s3);
  for (h = 0; h < 2; h++)
    {
      struct vr_hand *hand = &vr.hand[h];
      float u0, u1, v0, v1;

      if (hand->kb_row < 0)
        continue;
      kb_key_rect (hand->kb_row, hand->kb_col, &u0, &u1, &v0, &v1);
      kb_point (u0, v0, lift, c0);
      kb_point (u1, v0, lift, c1);
      kb_point (u1, v1, lift, c2);
      kb_point (u0, v1, lift, c3);
      draw_quad (c0, c1, c2, c3, 120, 180, 255,
                 (hand->buttons & LRG_VR_CONTROLLER_BUTTON_TRIGGER) ? 150 : 80);
    }
}

/* Write the eye being drawn -- everything so far, lasers included -- as a
   PNG (cmacs-lrg-vr-screenshot), then forget the request.  */
static void
vr_write_eye (char *path)
{
  int vp[4] = { 0, 0, 0, 0 };
  unsigned char *px;

  rlDrawRenderBatchActive ();
  glGetIntegerv (GL_VIEWPORT, vp);
  px = rlReadScreenPixels (vp[2], vp[3]);   /* RGBA, rows top-down */
  if (px != NULL)
    {
      GrlImage *img = grl_image_new_from_pixels
        (vp[2], vp[3], GRL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, px);
      if (img != NULL)
        {
          grl_image_export (img, path);
          g_object_unref (img);
        }
      free (px);
    }
  xfree (path);
  vr.shot_path = NULL;
}

/* Hand H's tracked skeleton: a sphere per joint, a line per bone.  */
static void
draw_hand (int h, float mpu)
{
  const LrgVRHandState *st = &vr.hs[h];
  float scene[LRG_VR_HAND_JOINT_COUNT][3];
  bool ok[LRG_VR_HAND_JOINT_COUNT];
  bool pinched = lrg_vr_hand_state_is_pinched (st);
  g_autoptr (GrlColor) joint = pinched ? grl_color_new (255, 200, 80, 230)
                                       : grl_color_new (200, 225, 255, 210);
  g_autoptr (GrlColor) bone = grl_color_new (140, 170, 210, 180);
  int j;

  for (j = 0; j < LRG_VR_HAND_JOINT_COUNT; j++)
    {
      float m[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
      float dir[3];

      ok[j] = lrg_vr_hand_state_get_joint_position (st, (LrgVRHandJoint) j,
                                                    &m[12], &m[13], &m[14]);
      if (ok[j])
        lrg_3d_surface_vr_tracking_to_scene (vr.s3, m, scene[j], dir);
    }
  for (j = 0; j < LRG_VR_HAND_JOINT_COUNT; j++)
    {
      int p = lrg_vr_hand_joint_parent ((LrgVRHandJoint) j);
      float r;
      g_autoptr (GrlVector3) at = NULL;

      if (!ok[j])
        continue;
      at = grl_vector3_new (scene[j][0], scene[j][1], scene[j][2]);
      if (p >= 0 && ok[p])
        {
          g_autoptr (GrlVector3) from
            = grl_vector3_new (scene[p][0], scene[p][1], scene[p][2]);
          grl_draw_line_3d (from, at, bone);
        }
      r = lrg_vr_hand_state_get_joint_radius (st, (LrgVRHandJoint) j);
      grl_draw_sphere (at, MAX (r * 0.6f, 0.004f) / mpu, joint);
    }
}

static void
vr_overlay (Lrg3DSurface *s3, guint view, gpointer data)
{
  float mpu = lrg_3d_surface_get_vr_scale (s3);
  int h;

  (void) data;
  if (view == 0)
    vr_update_pointers ();

  if (vr.kb_visible)
    draw_keyboard ();

  for (h = 0; h < 2; h++)
    {
      struct vr_hand *hand = &vr.hand[h];
      g_autoptr (GrlVector3) a = NULL;
      g_autoptr (GrlVector3) b = NULL;
      g_autoptr (GrlColor) beam = NULL;
      g_autoptr (GrlColor) body = NULL;
      bool aiming = hand->hit_panel || hand->kb_row >= 0;
      bool pressed = (hand->buttons & LRG_VR_CONTROLLER_BUTTON_TRIGGER) != 0;
      float len;

      if (!hand->tracked)
        continue;
      if (hand->src == SRC_HAND && vr.show_joints)
        draw_hand (h, mpu);
      len = hand->hit_dist;
      a = grl_vector3_new (hand->origin[0], hand->origin[1], hand->origin[2]);
      b = grl_vector3_new (hand->origin[0] + hand->dir[0] * len,
                           hand->origin[1] + hand->dir[1] * len,
                           hand->origin[2] + hand->dir[2] * len);
      beam = aiming ? (pressed ? grl_color_new (255, 200, 80, 255)
                               : grl_color_new (110, 190, 255, 255))
                    : grl_color_new (150, 150, 160, 120);
      body = grl_color_new (60, 64, 76, 255);

      grl_draw_line_3d (a, b, beam);
      /* A controller gets a body; a hand is drawn as itself.  */
      if (hand->src == SRC_CONTROLLER)
        grl_draw_cube (a, 0.03f / mpu, 0.03f / mpu, 0.03f / mpu, body);
      if (aiming)
        grl_draw_sphere (b, (pressed ? 0.010f : 0.007f) / mpu, beam);

      /* The modifier hand shows its layer: blue trigger, green grip,
         orange both.  */
      if (vr_is_modifier_hand (h) && vr.layer != 0)
        {
          g_autoptr (GrlVector3) at
            = grl_vector3_new (hand->origin[0], hand->origin[1] + 0.035f / mpu,
                               hand->origin[2]);
          g_autoptr (GrlColor) c
            = vr.layer == vr.mod_both ? grl_color_new (255, 150, 60, 255)
              : vr.layer == vr.mod_grip ? grl_color_new (90, 220, 120, 255)
              : grl_color_new (80, 160, 255, 255);
          grl_draw_sphere (at, 0.008f / mpu, c);
        }
      /* Status from Lisp (cmacs-lrg-vr-set-indicator): recording, ...  */
      if (hand->indicator)
        {
          g_autoptr (GrlVector3) at
            = grl_vector3_new (hand->origin[0], hand->origin[1] + 0.055f / mpu,
                               hand->origin[2]);
          g_autoptr (GrlColor) c
            = grl_color_new (hand->indicator_rgb[0], hand->indicator_rgb[1],
                             hand->indicator_rgb[2], 255);
          grl_draw_sphere (at, 0.012f / mpu, c);
        }
    }

  if (view == 0 && vr.shot_path != NULL)
    vr_write_eye (vr.shot_path);
}

/* ----------------------------------------------------------- input ------ */

static bool
pressed_now (const struct vr_hand *hand, guint bit)
{
  return (hand->buttons & bit) && !(hand->prev & bit);
}

static bool
released_now (const struct vr_hand *hand, guint bit)
{
  return !(hand->buttons & bit) && (hand->prev & bit);
}

/* The yaw, in degrees, of a panel at (CX, CZ) that faces the point
   (PX, PZ): a panel faces +Z at yaw 0.  */
static float
yaw_facing (float cx, float cz, float px, float pz)
{
  return atan2f (px - cx, pz - cz) * (float) (180.0 / G_PI);
}

/* The grip carries what is under the laser -- the in-world keyboard or a
   panel -- or, on empty space, the world.  Carrying is a laser carry: the
   grabbed point stays on the laser, at its grab distance, so pointing
   anywhere -- up and down too -- moves the object, which keeps facing the
   hand.  While carrying, the gripping hand's stick pushes and pulls (Y)
   and turns the object (X); with its trigger held, Y resizes instead.  */
static void
grab_begin (struct vr_hand *hand, int which)
{
  float cx, cy, cz, yaw, w, h, hx, hy, hz, rx, rz, t;

  if (hand->kb_row >= 0)
    {
      hand->grab = GRAB_KEYBOARD;
      cx = vr.kb_center[0]; cy = vr.kb_center[1]; cz = vr.kb_center[2];
      yaw = vr.kb_yaw;
      w = vr.kb_w; h = vr.kb_h;
    }
  else if (hand->hit_panel
           && lrg_3d_surface_get_panel_geometry (vr.s3, hand->key, &cx, &cy,
                                                 &cz, &yaw, &w, &h))
    {
      hand->grab = GRAB_PANEL;
      hand->grab_key = hand->key;
    }
  else
    {
      float pose[16];
      hand->grab = GRAB_WORLD;
      vr_source_pose (which, pose);
      hand->grab_track[0] = pose[12];
      hand->grab_track[1] = pose[13];
      hand->grab_track[2] = pose[14];
      vr_pulse (which, 0.02f, 0.3f);
      return;
    }

  /* The grabbed point, and the object's centre relative to it along the
     object's own right and up axes.  */
  hand->grab_dist = hand->hit_dist;
  hx = hand->origin[0] + hand->dir[0] * hand->grab_dist;
  hy = hand->origin[1] + hand->dir[1] * hand->grab_dist;
  hz = hand->origin[2] + hand->dir[2] * hand->grab_dist;
  t = yaw * (float) (G_PI / 180.0);
  rx = cosf (t);
  rz = -sinf (t);
  hand->grab_off_r = (cx - hx) * rx + (cz - hz) * rz;
  hand->grab_off_u = cy - hy;
  /* Measured from the grabbed point, as grab_update does: the point is on
     the object's plane, so the object does not move as the grip closes.  */
  hand->grab_yaw_off = yaw - yaw_facing (hx, hz, hand->origin[0], hand->origin[2]);
  hand->grab_w = w;
  hand->grab_h = h;
  vr_pulse (which, 0.03f, 0.5f);
}

/* The hand moved (DX, DY, DZ) metres in tracking space while holding the
   world: move the viewer the other way, so the world follows the hand --
   pulling the hand toward you pulls the world toward you.  */
static void
vr_pull_world (float dx, float dy, float dz)
{
  float head[16], hyaw, fwd, right;

  lrg_vr_service_get_hmd_pose (vr_service (), head);
  hyaw = heading_deg (-head[8], -head[10]) * (float) (G_PI / 180.0);
  fwd = dx * -sinf (hyaw) + dz * -cosf (hyaw);
  right = dx * cosf (hyaw) + dz * -sinf (hyaw);
  lrg_3d_surface_vr_move (vr.s3, -fwd, -right, -dy);
}

static void
grab_update (struct vr_hand *hand, int which)
{
  float sx, sy, mpu, hx, hy, hz, yaw, t, nx, ny, nz;
  bool resize;

  if (hand->grab == GRAB_WORLD)
    {
      float pose[16];

      vr_source_pose (which, pose);
      vr_pull_world (pose[12] - hand->grab_track[0],
                     pose[13] - hand->grab_track[1],
                     pose[14] - hand->grab_track[2]);
      hand->grab_track[0] = pose[12];
      hand->grab_track[1] = pose[13];
      hand->grab_track[2] = pose[14];
      return;
    }

  mpu = lrg_3d_surface_get_vr_scale (vr.s3);
  sy = lrg_vr_service_get_controller_axis (vr_service (), (LrgVRHand) which,
                                           LRG_VR_AXIS_THUMBSTICK_Y);
  sx = lrg_vr_service_get_controller_axis (vr_service (), (LrgVRHand) which,
                                           LRG_VR_AXIS_THUMBSTICK_X);
  resize = (hand->buttons & LRG_VR_CONTROLLER_BUTTON_TRIGGER) != 0;

  if (fabsf (sy) > VR_DEADZONE)
    {
      if (resize)
        {
          float grow = 1.0f + sy * vr.dt * 0.8f;
          if ((hand->grab_h * grow * mpu > 0.1f || grow > 1.0f)
              && (hand->grab_h * grow * mpu < 8.0f || grow < 1.0f))
            {
              hand->grab_w *= grow;
              hand->grab_h *= grow;
              hand->grab_off_r *= grow;
              hand->grab_off_u *= grow;
            }
        }
      else
        {
          /* Push / pull, faster the farther it is; never into your hand
             (0.25 m) or past 30 m.  */
          float d = hand->grab_dist * (1.0f + sy * vr.dt * 1.5f);
          hand->grab_dist = CLAMP (d, 0.25f / mpu, 30.0f / mpu);
        }
    }
  if (fabsf (sx) > VR_DEADZONE && !resize)
    hand->grab_yaw_off -= sx * vr.dt * 90.0f;    /* 90 degrees a second */

  hx = hand->origin[0] + hand->dir[0] * hand->grab_dist;
  hy = hand->origin[1] + hand->dir[1] * hand->grab_dist;
  hz = hand->origin[2] + hand->dir[2] * hand->grab_dist;
  yaw = yaw_facing (hx, hz, hand->origin[0], hand->origin[2]) + hand->grab_yaw_off;
  t = yaw * (float) (G_PI / 180.0);
  nx = hx + cosf (t) * hand->grab_off_r;
  ny = hy + hand->grab_off_u;
  nz = hz - sinf (t) * hand->grab_off_r;

  if (hand->grab == GRAB_KEYBOARD)
    {
      vr.kb_center[0] = nx; vr.kb_center[1] = ny; vr.kb_center[2] = nz;
      vr.kb_yaw = yaw;
      vr.kb_w = hand->grab_w;
      vr.kb_h = hand->grab_h;
    }
  else
    lrg_3d_surface_set_panel_transform (vr.s3, hand->grab_key, nx, ny, nz, yaw,
                                        hand->grab_w, hand->grab_h);
}

/* The layer modifiers the modifier hand holds right now.  */
static int
vr_read_layer (void)
{
  guint b;
  bool trig, grip;
  const struct vr_hand *mh = &vr.hand[vr.move_hand];

  if (!vr_is_modifier_hand (vr.move_hand))
    return 0;
  b = lrg_vr_service_get_controller_buttons (vr_service (),
                                             (LrgVRHand) vr.move_hand);
  /* A trigger pressing a key on the in-world keyboard is typing, not the
     layer: one held down there (kb_trigger), or one going down on a key
     this frame -- this runs before vr_hand_input sees it, and MH->buttons
     is still last frame's.  A trigger already held as the layer stays
     the layer when the laser wanders onto the keyboard.  */
  trig = (b & LRG_VR_CONTROLLER_BUTTON_TRIGGER) != 0
         && !mh->kb_trigger
         && !(mh->kb_row >= 0
              && !(mh->buttons & LRG_VR_CONTROLLER_BUTTON_TRIGGER));
  grip = (b & (vr.second_is_bumper ? LRG_VR_CONTROLLER_BUTTON_BUMPER
                                   : LRG_VR_CONTROLLER_BUTTON_GRIP)) != 0;
  return trig && grip ? vr.mod_both : trig ? vr.mod_trigger
         : grip ? vr.mod_grip : 0;
}

/* The keysym and bank bit button B of hand H is sent as.  */
static int
vr_button_keysym (int h, enum vr_button b, int *bank)
{
  bool right = h == LRG_VR_HAND_RIGHT;

  *bank = 0;
  switch (b)
    {
    case VB_A: return right ? VR_XK_F25 : VR_XK_F27;   /* Touch: left A = X */
    case VB_B: return right ? VR_XK_F26 : VR_XK_F28;   /* Touch: left B = Y */
    case VB_X: return VR_XK_F27;
    case VB_Y: return VR_XK_F28;
    case VB_MENU: return VR_XK_F29;
    case VB_STICK: return h == vr.move_hand ? VR_XK_F30 : VR_XK_F31;
    default: break;
    }
  *bank = VR_BANK2;
  switch (b)
    {
    case VB_BUMPER: return h == vr.move_hand ? VR_XK_F26 : VR_XK_F25;
    case VB_VIEW: return VR_XK_F27;
    case VB_DPAD_UP: return VR_XK_F28;
    case VB_DPAD_DOWN: return VR_XK_F29;
    case VB_DPAD_LEFT: return VR_XK_F30;
    default: return VR_XK_F31;                         /* VB_DPAD_RIGHT */
    }
}

/* One button's tap / hold / release.  BIT is its controller bit.  */
static int
vr_button (struct input_event *hold_quit, int h, enum vr_button b, guint bit)
{
  struct vr_hand *hand = &vr.hand[h];
  gint64 now = g_get_monotonic_time ();
  int bank, count = 0, sym = vr_button_keysym (h, b, &bank);

  if (pressed_now (hand, bit))
    {
      hand->btn_down_us[b] = now;
      hand->btn_held[b] = false;
      hand->btn_consumed[b] = false;
      hand->btn_mods[b] = vr.layer;
      /* The pointer hand's stick click on a panel is mouse-3 at the laser
         (context menus), at once: a click has no hold.  */
      if (b == VB_STICK && h != vr.move_hand && hand->hit_panel
          && !cmacs_lrgterm_workspace_key_p (hand->key))
        {
          count += vr_emit_mouse (hold_quit, 2, true, hand->fx, hand->fy,
                                  vr.layer);
          count += vr_emit_mouse (hold_quit, 2, false, hand->fx, hand->fy,
                                  vr.layer);
          hand->btn_consumed[b] = true;
        }
    }
  else if ((hand->buttons & bit) && hand->btn_down_us[b] != 0
           && !hand->btn_held[b] && !hand->btn_consumed[b]
           && now - hand->btn_down_us[b] >= vr.hold_us)
    {
      hand->btn_held[b] = true;
      vr_pulse (h, 0.02f, 0.45f);
      count += vr_emit_keysym (hold_quit, sym,
                               hand->btn_mods[b] | bank | VR_HOLD_MOD);
    }
  if (released_now (hand, bit) && hand->btn_down_us[b] != 0)
    {
      if (!hand->btn_consumed[b])
        count += vr_emit_keysym (hold_quit, sym,
                                 hand->btn_mods[b] | bank
                                 | (hand->btn_held[b] ? VR_RELEASE_MOD : 0));
      hand->btn_down_us[b] = 0;
    }
  return count;
}

/* The D-pad as arrow keys (`dpad-arrows'): the key at once, with the
   layer's modifiers -- S-<left> extends the region -- then repeating while
   held, like a keyboard's.  Arrows work everywhere: buffers, the
   minibuffer, completion lists, popup menus.  */
#define VR_ARROW_DELAY_US  400000
#define VR_ARROW_REPEAT_US 70000

static int
vr_arrow (struct input_event *hold_quit, int h, enum vr_button b, guint bit)
{
  static const int sym[] = { 0xff52, 0xff54, 0xff51, 0xff53 };   /* XK_Up ... */
  struct vr_hand *hand = &vr.hand[h];
  gint64 now = g_get_monotonic_time ();
  int key = sym[b - VB_DPAD_UP];

  if (pressed_now (hand, bit))
    {
      hand->btn_down_us[b] = now;
      hand->btn_next_us[b] = now + VR_ARROW_DELAY_US;
      vr_pulse (h, 0.008f, 0.25f);
      return vr_emit_keysym (hold_quit, key, vr.layer);
    }
  if (released_now (hand, bit))
    {
      hand->btn_down_us[b] = 0;
      return 0;
    }
  if ((hand->buttons & bit) && hand->btn_down_us[b] != 0
      && now >= hand->btn_next_us[b])
    {
      hand->btn_next_us[b] = now + VR_ARROW_REPEAT_US;
      return vr_emit_keysym (hold_quit, key, vr.layer);
    }
  return 0;
}

/* An edge-triggered stick flick, like the snap turn: one event when the
   stick crosses the arm threshold, re-armed near the centre.  */
static int
vr_flick (struct input_event *hold_quit, float v, bool *used, int sym_neg,
          int sym_pos)
{
  if (!*used && fabsf (v) > VR_SNAP_ARM)
    {
      *used = true;
      return vr_emit_keysym (hold_quit, v > 0.0f ? sym_pos : sym_neg, vr.layer);
    }
  if (*used && fabsf (v) < VR_SNAP_REARM)
    *used = false;
  return 0;
}

static int
vr_scroll (struct input_event *hold_quit, struct vr_hand *hand, float sx,
           float sy, bool vertical, bool horizontal)
{
  int count = 0;

  if (vertical && fabsf (sy) > VR_DEADZONE)
    {
      hand->scroll_acc += sy * vr.scroll_rate * vr.dt;
      while (fabsf (hand->scroll_acc) >= 1.0f)
        {
          bool up = hand->scroll_acc > 0.0f;
          /* An embedded view (gnuseye's globe) zooms on the wheel.  */
          if (!cmacs_lrgterm_offer_scroll (vr.f, 0.0, up ? -1.0 : 1.0,
                                           hand->fx, hand->fy))
            count += vr_emit_wheel (hold_quit, false, up, hand->fx, hand->fy);
          hand->scroll_acc += up ? -1.0f : 1.0f;
        }
    }
  else
    hand->scroll_acc = 0.0f;
  if (horizontal && fabsf (sx) > VR_DEADZONE)
    {
      hand->hscroll_acc += sx * vr.scroll_rate * vr.dt;
      while (fabsf (hand->hscroll_acc) >= 1.0f)
        {
          bool r = hand->hscroll_acc > 0.0f;
          if (!cmacs_lrgterm_offer_scroll (vr.f, r ? 1.0 : -1.0, 0.0,
                                           hand->fx, hand->fy))
            count += vr_emit_wheel (hold_quit, true, !r, hand->fx, hand->fy);
          hand->hscroll_acc += r ? -1.0f : 1.0f;
        }
    }
  else
    hand->hscroll_acc = 0.0f;
  return count;
}

/* Pointer motion for hand H (drag while its trigger or pinch is held,
   hover otherwise) -- over the live frame only, not another workspace's
   picture -- and the hand-off of the mouse between hands.  */
static void
vr_pointer_motion (int h)
{
  struct vr_hand *hand = &vr.hand[h];

  if (hand->hit_panel && h == vr.pointer_hand
      && !cmacs_lrgterm_workspace_key_p (hand->key)
      && (hand->fx != vr.mouse_x || hand->fy != vr.mouse_y || !vr.mouse_valid))
    {
      vr.mouse_valid = true;
      vr.mouse_x = hand->fx;
      vr.mouse_y = hand->fy;
      if (hand->trigger_mouse || hand->trigger_view)
        {
          hand->last_fx = hand->fx;
          hand->last_fy = hand->fy;
        }
      vr.f->mouse_moved = true;
      /* An embedded view follows the laser (orbit while dragging, hover
         ids); text gets the mouse-face highlight.  */
      if (!cmacs_lrgterm_offer_motion (vr.f, hand->fx, hand->fy))
        {
          block_input ();
          note_mouse_highlight (vr.f, hand->fx, hand->fy);
          unblock_input ();
        }
    }
  /* A hand that points at a panel while the other is idle takes the mouse --
     never the modifier hand, which does not click.  */
  if (!vr_is_modifier_hand (h) && hand->hit_panel && h != vr.pointer_hand
      && !vr.hand[vr.pointer_hand].trigger_mouse
      && !vr.hand[vr.pointer_hand].trigger_view
      && !vr.hand[vr.pointer_hand].hit_panel)
    vr.pointer_hand = h;
}

static int
vr_hand_input (struct input_event *hold_quit, int h)
{
  struct vr_hand *hand = &vr.hand[h];
  LrgVRService *svc = vr_service ();
  bool mover = h == vr.move_hand;
  bool modhand = vr_is_modifier_hand (h);
  float sx, sy;
  int count = 0;

  /* A tracked hand's pinch was handled by vr_handtrack_tick; it only
     moves the pointer.  */
  if (hand->src == SRC_HAND)
    {
      vr_pointer_motion (h);
      return 0;
    }

  hand->prev = hand->buttons;
  hand->buttons = lrg_vr_service_get_controller_buttons (svc, (LrgVRHand) h);
  sx = lrg_vr_service_get_controller_axis (svc, (LrgVRHand) h,
                                           LRG_VR_AXIS_THUMBSTICK_X);
  sy = lrg_vr_service_get_controller_axis (svc, (LrgVRHand) h,
                                           LRG_VR_AXIS_THUMBSTICK_Y);

  /* Trigger on the keyboard: type, with either hand -- the modifier
     hand's trigger is a key press there, not its layer (vr_read_layer), so
     one hand can hold Meta while the other presses x.  */
  if (hand->grab == GRAB_NONE && hand->kb_row >= 0
      && pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER))
    {
      hand->kb_trigger = true;
      count += kb_press (hold_quit, hand, hand->kb_row, hand->kb_col);
      vr_pulse (h, 0.015f, 0.4f);
    }
  else if (hand->kb_trigger
           && !(hand->buttons & LRG_VR_CONTROLLER_BUTTON_TRIGGER))
    kb_trigger_up (hand);
  /* Trigger elsewhere: click in a buffer -- unless this is the modifier
     hand, whose trigger is a layer.  While carrying, the trigger turns the
     stick into resize (grab_update): it does not click.  */
  else if (!modhand && hand->grab == GRAB_NONE
           && pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER))
    {
      /* Another workspace's panel on the ring: switch to it, as a
         Ctrl+double-click on it does on the desktop.  It is a picture of
         that workspace, not the live frame, so it gets no mouse events.  */
      if (hand->hit_panel
          && cmacs_lrgterm_select_workspace_panel (hand->key))
        vr_pulse (h, 0.03f, 0.6f);
      else if (hand->hit_panel)
        {
          vr.pointer_hand = h;
          hand->last_fx = hand->fx;
          hand->last_fy = hand->fy;
          vr.mouse_valid = true;
          vr.mouse_x = hand->fx;
          vr.mouse_y = hand->fy;
          lrg_3d_surface_set_focus_window (vr.s3, hand->key);
          /* An embedded view takes the press first, as on the desktop:
             a drag orbits gnuseye's globe, a click picks on it.  */
          if (cmacs_lrgterm_offer_button (vr.f, 1, true, hand->fx, hand->fy))
            hand->trigger_view = true;
          else
            {
              hand->trigger_mouse = true;
              count += vr_emit_mouse (hold_quit, 0, true, hand->fx, hand->fy,
                                      kb_take_mods () | vr.layer);
            }
          vr_pulse (h, 0.012f, 0.35f);
        }
    }
  if (released_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER) && hand->trigger_mouse)
    {
      hand->trigger_mouse = false;
      count += vr_emit_mouse (hold_quit, 0, false, hand->last_fx, hand->last_fy,
                              vr.layer);
    }
  if (released_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER) && hand->trigger_view)
    {
      hand->trigger_view = false;
      cmacs_lrgterm_offer_button (vr.f, 1, false, hand->last_fx, hand->last_fy);
    }

  vr_pointer_motion (h);

  /* Grip: carry the panel / keyboard under the laser, or the world --
     also on the modifier hand when its second layer button is the bumper. */
  if (!modhand || vr.second_is_bumper)
    {
      if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_GRIP))
        grab_begin (hand, h);
      if (hand->grab != GRAB_NONE
          && (hand->buttons & LRG_VR_CONTROLLER_BUTTON_GRIP))
        grab_update (hand, h);
      if (released_now (hand, LRG_VR_CONTROLLER_BUTTON_GRIP))
        {
          if (hand->grab == GRAB_PANEL)
            lrg_3d_surface_release_panel (vr.s3);
          hand->grab = GRAB_NONE;
        }
    }

  /* Sticks.  The moving hand walks and turns; the other scrolls on a
     panel, and flicks -- <vr-flick-left> etc. -- off one, or on one while a
     layer is held (vertical still scrolls then, with the layer: C-wheel
     zooms text).  */
  if (hand->grab == GRAB_NONE)
    {
      if (mover)
        {
          if (fabsf (sy) > VR_DEADZONE)
            lrg_3d_surface_vr_move (vr.s3, sy * vr.move_speed * vr.dt, 0.0f, 0.0f);
          if (!hand->snap_used && fabsf (sx) > VR_SNAP_ARM)
            {
              lrg_3d_surface_vr_turn (vr.s3, sx > 0.0f ? -vr.snap_degrees
                                                       : vr.snap_degrees);
              hand->snap_used = true;
            }
          else if (hand->snap_used && fabsf (sx) < VR_SNAP_REARM)
            hand->snap_used = false;
        }
      else if (hand->hit_panel && vr.layer == 0
               && !cmacs_lrgterm_workspace_key_p (hand->key))
        count += vr_scroll (hold_quit, hand, sx, sy, true, true);
      else if (hand->hit_panel && !cmacs_lrgterm_workspace_key_p (hand->key))
        {
          count += vr_scroll (hold_quit, hand, sx, sy, true, false);
          count += vr_flick (hold_quit, sx, &hand->flick_x_used,
                             VR_XK_F32, VR_XK_F33);
        }
      else
        {
          count += vr_flick (hold_quit, sx, &hand->flick_x_used,
                             VR_XK_F32, VR_XK_F33);
          count += vr_flick (hold_quit, sy, &hand->flick_y_used,
                             VR_XK_F35, VR_XK_F34);
        }
    }

  /* Buttons: tap, hold, release (vr_button).  */
  count += vr_button (hold_quit, h, VB_A, LRG_VR_CONTROLLER_BUTTON_A);
  count += vr_button (hold_quit, h, VB_B, LRG_VR_CONTROLLER_BUTTON_B);
  count += vr_button (hold_quit, h, VB_X, LRG_VR_CONTROLLER_BUTTON_X);
  count += vr_button (hold_quit, h, VB_Y, LRG_VR_CONTROLLER_BUTTON_Y);
  count += vr_button (hold_quit, h, VB_MENU, LRG_VR_CONTROLLER_BUTTON_MENU);
  count += vr_button (hold_quit, h, VB_STICK, LRG_VR_CONTROLLER_BUTTON_THUMBSTICK);
  count += vr_button (hold_quit, h, VB_VIEW, LRG_VR_CONTROLLER_BUTTON_VIEW);
  {
    static const guint dpad[] = {
      LRG_VR_CONTROLLER_BUTTON_DPAD_UP, LRG_VR_CONTROLLER_BUTTON_DPAD_DOWN,
      LRG_VR_CONTROLLER_BUTTON_DPAD_LEFT, LRG_VR_CONTROLLER_BUTTON_DPAD_RIGHT
    };
    int i;
    for (i = 0; i < 4; i++)
      count += vr.dpad_arrows
               ? vr_arrow (hold_quit, h, (enum vr_button) (VB_DPAD_UP + i), dpad[i])
               : vr_button (hold_quit, h, (enum vr_button) (VB_DPAD_UP + i), dpad[i]);
  }
  /* The modifier hand's bumper is a layer button there, not a button.  */
  if (!(modhand && vr.second_is_bumper))
    count += vr_button (hold_quit, h, VB_BUMPER, LRG_VR_CONTROLLER_BUTTON_BUMPER);
  return count;
}

/* ------------------------------------------------- hand tracking: input -- */

/* Let go of whatever hand H's previous source held -- a mouse button, an
   embedded view's press, a keyboard key, a carry -- when the controller
   is put down mid-press or picked up mid-pinch.  */
static int
vr_hand_release_all (struct input_event *hold_quit, int h)
{
  struct vr_hand *hand = &vr.hand[h];
  int count = 0;

  if (hand->trigger_mouse)
    count += vr_emit_mouse (hold_quit, 0, false, hand->last_fx, hand->last_fy,
                            vr.layer);
  if (hand->trigger_view)
    cmacs_lrgterm_offer_button (vr.f, 1, false, hand->last_fx, hand->last_fy);
  hand->trigger_mouse = hand->trigger_view = false;
  if (hand->kb_trigger)
    kb_trigger_up (hand);
  if (hand->grab == GRAB_PANEL)
    lrg_3d_surface_release_panel (vr.s3);
  hand->grab = GRAB_NONE;
  hand->buttons = hand->prev = 0;
  memset (&vr.gestures.h[h], 0, sizeof vr.gestures.h[h]);
  if (vr.gestures.zooming)
    vr.gestures.zooming = false;
  return count;
}

/* Hand H's pinch went down at the laser: the same press the trigger
   makes (see vr_hand_input), minus haptics -- a hand has none.  DRAG:
   hold mouse-1 down; otherwise click.  */
static int
vr_hand_press (struct input_event *hold_quit, int h, int x, int y, bool drag)
{
  struct vr_hand *hand = &vr.hand[h];
  int count = 0;

  if (!hand->hit_panel)
    return 0;
  if (cmacs_lrgterm_select_workspace_panel (hand->key))
    return 0;
  vr.pointer_hand = h;
  hand->last_fx = x;
  hand->last_fy = y;
  vr.mouse_valid = true;
  vr.mouse_x = x;
  vr.mouse_y = y;
  lrg_3d_surface_set_focus_window (vr.s3, hand->key);
  if (cmacs_lrgterm_offer_button (vr.f, 1, true, x, y))
    {
      if (drag)
        hand->trigger_view = true;
      else
        cmacs_lrgterm_offer_button (vr.f, 1, false, x, y);
      return 0;
    }
  count += vr_emit_mouse (hold_quit, 0, true, x, y, kb_take_mods () | vr.layer);
  if (drag)
    hand->trigger_mouse = true;
  else
    count += vr_emit_mouse (hold_quit, 0, false, x, y, vr.layer);
  return count;
}

/* Apply one classified gesture (vr_gesture_step).  */
static int
vr_hand_apply (struct input_event *hold_quit, const struct vr_hand_action *a)
{
  struct vr_hand *hand = a->hand >= 0 ? &vr.hand[a->hand] : NULL;
  bool left = a->hand == LRG_VR_HAND_LEFT;
  int count = 0, i;

  switch (a->kind)
    {
    case HA_CLICK:
      count += vr_hand_press (hold_quit, a->hand, a->x, a->y, false);
      break;
    case HA_DRAG_BEGIN:
      count += vr_hand_press (hold_quit, a->hand, a->x, a->y, true);
      break;
    case HA_DRAG_END:
      if (hand->trigger_mouse)
        count += vr_emit_mouse (hold_quit, 0, false, hand->last_fx,
                                hand->last_fy, vr.layer);
      if (hand->trigger_view)
        cmacs_lrgterm_offer_button (vr.f, 1, false, hand->last_fx,
                                    hand->last_fy);
      hand->trigger_mouse = hand->trigger_view = false;
      break;
    case HA_SCROLL:
      /* The content follows the hand: moving it down (laser y grows)
         shows what is above -- the wheel turned up.  */
      for (i = 0; i < abs (a->y); i++)
        if (!cmacs_lrgterm_offer_scroll (vr.f, 0.0, a->y > 0 ? -1.0 : 1.0,
                                         hand->fx, hand->fy))
          count += vr_emit_wheel (hold_quit, false, a->y > 0, hand->fx,
                                  hand->fy);
      for (i = 0; i < abs (a->x); i++)
        if (!cmacs_lrgterm_offer_scroll (vr.f, a->x > 0 ? -1.0 : 1.0, 0.0,
                                         hand->fx, hand->fy))
          count += vr_emit_wheel (hold_quit, true, a->x > 0, hand->fx,
                                  hand->fy);
      break;
    case HA_PULL_MOVE:
      vr_pull_world (a->v[0], a->v[1], a->v[2]);
      break;
    case HA_TAP:
      count += vr_emit_keysym (hold_quit, left ? VR_XK_F32 : VR_XK_F33,
                               vr.layer | VR_HAND_PINCH_MOD);
      break;
    case HA_KEY_DOWN:
      if (hand->kb_row >= 0)
        {
          hand->kb_trigger = true;
          count += kb_press (hold_quit, hand, hand->kb_row, hand->kb_col);
        }
      break;
    case HA_KEY_UP:
      if (hand->kb_trigger)
        kb_trigger_up (hand);
      break;
    case HA_PALM_UP:
      count += vr_emit_keysym (hold_quit, left ? VR_XK_F32 : VR_XK_F33,
                               vr.layer | VR_HAND_PALM_UP_MOD);
      break;
    case HA_PALM_DOWN:
      count += vr_emit_keysym (hold_quit, left ? VR_XK_F32 : VR_XK_F33,
                               vr.layer | VR_HAND_PALM_DOWN_MOD);
      break;
    case HA_ZOOM_BEGIN:
      vr.zoom_scale0 = lrg_3d_surface_get_vr_scale (vr.s3);
      break;
    case HA_ZOOM:
      /* Hands apart: everything bigger, as a pinch-zoom on a phone.  */
      lrg_3d_surface_set_vr_scale (vr.s3, vr.zoom_scale0 * a->v[0]);
      break;
    case HA_ZOOM_END:
      if (a->v[0] > 1.0f + VR_HAND_ZOOM_DEAD)
        count += vr_emit_keysym (hold_quit, VR_XK_F34,
                                 vr.layer | VR_HAND_ZOOM_MOD);
      else if (a->v[0] < 1.0f - VR_HAND_ZOOM_DEAD)
        count += vr_emit_keysym (hold_quit, VR_XK_F35,
                                 vr.layer | VR_HAND_ZOOM_MOD);
      break;
    default:   /* HA_PULL_BEGIN, HA_PULL_END: nothing to do */
      break;
    }
  return count;
}

/* This frame's sample of hand H for the classifier.  */
static void
vr_hand_sample_of (int h, struct vr_hand_sample *out)
{
  const struct vr_hand *hand = &vr.hand[h];
  const LrgVRHandState *st = &vr.hs[h];

  memset (out, 0, sizeof *out);
  out->tracked = hand->tracked && hand->src == SRC_HAND;
  if (!out->tracked)
    return;
  out->pinched = lrg_vr_hand_state_is_pinched (st);
  out->palm_up = lrg_vr_hand_state_is_palm_up (st, VR_HAND_PALM_COS);
  out->target = hand->kb_row >= 0 ? HT_KEYBOARD
                : !hand->hit_panel ? HT_NONE
                : cmacs_lrgterm_workspace_key_p (hand->key) ? HT_WORKSPACE
                : HT_PANEL;
  out->fx = hand->fx;
  out->fy = hand->fy;
  if (!lrg_vr_hand_state_get_pinch_point (st, out->pos))
    lrg_vr_hand_state_get_joint_position (st, LRG_VR_HAND_JOINT_PALM,
                                          &out->pos[0], &out->pos[1],
                                          &out->pos[2]);
}

/* Hand tracking, once a headset frame: classify both hands' pinches and
   palms together (a stretch needs both) and apply the result.  */
static int
vr_handtrack_tick (struct input_event *hold_quit)
{
  struct vr_hand_sample smp[2];
  struct vr_hand_action act[VR_HAND_MAX_ACTIONS];
  int n, i, h, count = 0;

  for (h = 0; h < 2; h++)
    {
      /* A source swap mid-press must not leave anything held.  */
      if (vr.hand[h].src_changed)
        {
          count += vr_hand_release_all (hold_quit, h);
          vr.hand[h].src_changed = false;
        }
      vr_hand_sample_of (h, &smp[h]);
      /* The laser and keyboard highlight show a pinch as a trigger.  */
      if (vr.hand[h].src == SRC_HAND)
        {
          vr.hand[h].prev = vr.hand[h].buttons;
          vr.hand[h].buttons = smp[h].pinched ? LRG_VR_CONTROLLER_BUTTON_TRIGGER
                                              : 0;
        }
    }
  n = vr_gesture_step (&vr.gestures, smp, g_get_monotonic_time (), act,
                       VR_HAND_MAX_ACTIONS);
  for (i = 0; i < n; i++)
    count += vr_hand_apply (hold_quit, &act[i]);
  return count;
}

/* ------------------------------------------------------------ public ---- */

bool
cmacs_lrgvr_active_p (void)
{
  return vr.active;
}

/* A modal loop (lrg-popup-menu) drives the headset itself: it calls
   cmacs_lrgvr_tick every pass, and every frame renders -- the laser is
   how the menu is used, so it must not drop to the busy rate.  */
void
cmacs_lrgvr_set_modal (bool on)
{
  vr.modal = on;
}

/* True while the headset session has input focus -- the frame is
   "focused" for Emacs (solid cursor) then, whatever the hidden window
   reports.  */
bool
cmacs_lrgvr_focused_p (void)
{
  return vr.active && vr.xr != NULL && lrg_openxr_service_is_focused (vr.xr);
}

bool
cmacs_lrgvr_mouse_position (struct frame *f, int *x, int *y)
{
  if (!vr.active || f != vr.f || !vr.mouse_valid)
    return false;
  *x = vr.mouse_x;
  *y = vr.mouse_y;
  return true;
}

/* Eye images are rendered at this multiple of the runtime's recommended
   size.  SteamVR on a standalone headset recommends below the display's
   own resolution -- on the Steam Frame 1728 pixels a side against a
   2160-pixel panel (its "0.64" render scale is of area) -- and text loses
   the most to that: its strokes are finer than the eye image's pixels, so
   they blur and swim as the head moves.  1.25 is the panel's native size
   there; more supersamples, at the square of the scale in GPU fill.  The
   swapchains are made when VR starts, before any init file runs, so the
   override is the environment: CMACS_LRG_VR_RESOLUTION=1 renders at the
   runtime's size again, 1.5 supersamples.  */
#define VR_DEFAULT_RESOLUTION 1.25

static float
vr_resolution_scale (void)
{
  const gchar *env = g_getenv ("CMACS_LRG_VR_RESOLUTION");
  gdouble v;

  if (env == NULL || *env == '\0')
    return VR_DEFAULT_RESOLUTION;
  v = g_ascii_strtod (env, NULL);
  return v >= 0.25 && v <= 4.0 ? (float) v : (float) VR_DEFAULT_RESOLUTION;
}

/* Headset frames are drawn from read_socket, and Emacs calls read_socket
   only while it reads keyboard input: idle in the command loop, or in
   sit-for.  A command waiting on a process (accept-process-output, as
   Doom's project file listing does) never watches keyboard descriptors, so
   the frame eventfd wakes nothing, and busy Lisp polls for input only
   every `polling-period' (2 s).  For the length of any slow command the
   headset got no frames; SteamVR timed the app out and showed its own
   white environment until it came back.

   This thread watches the frame eventfd without draining it.  A frame that
   is still unclaimed VR_WATCH_GRACE_US after it became due means Emacs is
   busy, so it raises SIGIO: the handler sets pending_signals and cuts the
   select timeout short, and Emacs's next safe point (maybe_quit -- in every
   Lisp loop and every pass of wait_reading_process_output) runs
   read_socket, which renders the frame.  It is the mechanism Emacs's own
   input polling uses; a SIGIO landing on another thread is forwarded to
   the main one (deliver_process_signal).  Idle, the frame is claimed at
   once and nothing is raised.  */
static gpointer
vr_watch_thread (gpointer data)
{
  struct pollfd p;

  p.fd = GPOINTER_TO_INT (data);
  p.events = POLLIN;
  while (!g_atomic_int_get (&vr.watch_quit))
    {
      p.revents = 0;
      if (poll (&p, 1, 100) <= 0)
        continue;
      g_usleep (VR_WATCH_GRACE_US);
      p.revents = 0;
      if (poll (&p, 1, 0) > 0 && !g_atomic_int_get (&vr.watch_quit))
        kill (getpid (), SIGIO);
      g_usleep (VR_WATCH_PERIOD_US);
    }
  return NULL;
}

/* Start presenting F's 3D surface in the headset.  The GL context must be
   current (it is, on the main thread, once the frame's window exists).  On
   failure *ERR gets a malloc'd message and the frame stays in plain 3D.  */
bool
cmacs_lrgvr_attach (struct frame *f, char **err)
{
  LrgFrameSurface *surf = FRAME_LRG_SURFACE (f);
  g_autoptr (GError) error = NULL;
  LrgOpenXRService *xr;

  if (err != NULL)
    *err = NULL;
  if (vr.active)
    return true;
  if (surf == NULL || !LRG_IS_3D_SURFACE (surf))
    {
      if (err != NULL)
        *err = xstrdup ("VR needs a 3D lrg frame (emacs --lrg=3dvr)");
      return false;
    }
  if (!lrg_openxr_service_is_supported ())
    {
      if (err != NULL)
        *err = xstrdup ("libregnum was built without OpenXR");
      return false;
    }

  xr = lrg_openxr_service_new ("cmacs");
  lrg_openxr_service_set_resolution_scale (xr, vr_resolution_scale ());
  if (!lrg_vr_service_initialize (LRG_VR_SERVICE (xr), &error))
    {
      if (err != NULL)
        *err = xstrdup (error != NULL ? error->message : "OpenXR failed");
      g_object_unref (xr);
      return false;
    }

  /* CMACS_LRG_VR_GL_LOG keeps raylib's log of every texture and FBO it
     creates and frees, with GL names: the record needed to tell which
     object a frame was drawn into.  */
  if (g_getenv ("CMACS_LRG_VR_GL_LOG") == NULL)
    SetTraceLogLevel (VR_RAYLIB_LOG_WARNING);
  vr.xr = xr;
  vr.f = f;
  vr.s3 = LRG_3D_SURFACE (surf);
  vr.active = true;
  vr.quit_sent = false;
  vr.last_frame_us = g_get_monotonic_time ();
  memset (vr.hand, 0, sizeof vr.hand);
  vr.hand[0].kb_row = vr.hand[1].kb_row = -1;
  memset (&vr.gestures, 0, sizeof vr.gestures);
  lrg_vr_hand_state_reset (&vr.hs[0]);
  lrg_vr_hand_state_reset (&vr.hs[1]);

  lrg_3d_surface_set_vr_service (vr.s3, LRG_VR_SERVICE (xr));
  lrg_3d_surface_set_vr_overlay_func (vr.s3, vr_overlay, NULL, NULL);

  /* The flat frame is drawn off screen from here on, at the frame's own
     size; resizes set it (lrg_set_window_size), the window no longer
     does.  */
  lrg_3d_surface_set_offscreen_size (vr.s3, FRAME_PIXEL_WIDTH (f),
                                     FRAME_PIXEL_HEIGHT (f));

  /* Frames are waited for off the main thread; pselect wakes on this fd. */
  vr.frame_fd = lrg_openxr_service_start_frame_thread (xr);
  if (vr.frame_fd >= 0)
    {
      add_keyboard_wait_descriptor (vr.frame_fd);
      g_atomic_int_set (&vr.watch_quit, 0);
      vr.watch_thread = g_thread_new ("cmacs-vr-watch", vr_watch_thread,
                                      GINT_TO_POINTER (vr.frame_fd));
    }

  /* Hide the desktop window.  The headset is the display, and a compositor
     that hosts it (gamescope under SteamVR) shows any mapped window as a
     flat "desktop game" in the dashboard, in front of the scene -- black,
     since VR does not present it -- and gives that, not us, input focus.
     The flat frame is rasterised offscreen in VR (Lrg3DSurface), so nothing
     needs the window; physical keyboards are read from evdev instead.
     CMACS_LRG_VR_SHOW_WINDOW=1 keeps it (and its keyboard focus).  */
  vr.window_hidden = false;
  if (g_getenv ("CMACS_LRG_VR_SHOW_WINDOW") == NULL)
    {
      GrlWindow *win = lrg_frame_surface_get_window (surf);
      if (win != NULL)
        {
          grl_window_set_state (win, GRL_FLAG_WINDOW_HIDDEN);
          vr.window_hidden = true;
          cmacs_lrgvr_kbd_start ();
        }
    }
  return true;
}

void
cmacs_lrgvr_detach (void)
{
  if (!vr.active)
    return;
  if (vr.watch_thread != NULL)
    {
      g_atomic_int_set (&vr.watch_quit, 1);
      g_thread_join (vr.watch_thread);
      vr.watch_thread = NULL;
    }
  if (vr.frame_fd >= 0)
    delete_keyboard_wait_descriptor (vr.frame_fd);
  vr.frame_fd = -1;
  if (vr.window_hidden)
    {
      GrlWindow *win = vr.s3 != NULL
        ? lrg_frame_surface_get_window (LRG_FRAME_SURFACE (vr.s3)) : NULL;
      cmacs_lrgvr_kbd_stop ();
      if (win != NULL)
        grl_window_clear_state (win, GRL_FLAG_WINDOW_HIDDEN);
      vr.window_hidden = false;
    }
  if (vr.s3 != NULL)
    {
      lrg_3d_surface_set_offscreen_size (vr.s3, 0, 0);
      lrg_3d_surface_set_vr_overlay_func (vr.s3, NULL, NULL, NULL);
      lrg_3d_surface_set_vr_service (vr.s3, NULL);
    }
  g_clear_object (&vr.kb_texture);
  xfree (vr.shot_path);
  vr.shot_path = NULL;
  if (vr.xr != NULL)
    lrg_vr_service_shutdown (LRG_VR_SERVICE (vr.xr));
  g_clear_object (&vr.xr);
  vr.s3 = NULL;
  vr.f = NULL;
  vr.active = false;
  vr.mouse_valid = false;
  vr.kb_visible = false;
}

/* One headset frame, if one is due: render both eyes from the cached panel
   textures, then turn this frame's controller state into Emacs events.
   Called from lrg_read_socket on every wakeup, never while redisplay draws. */
int
cmacs_lrgvr_tick (struct frame *f, struct input_event *hold_quit)
{
  gint64 now;
  int count = 0, h;

  if (!vr.active || f != vr.f || vr.s3 == NULL)
    return 0;

  /* Physical keyboards, on every wakeup -- a key press must not wait for
     the next headset frame.  Grabbed only while VR has focus, so the
     dashboard gets the keyboard when it is up.  */
  if (vr.window_hidden)
    {
      cmacs_lrgvr_kbd_set_grab (cmacs_lrgvr_focused_p ());
      count += cmacs_lrgvr_kbd_read (f, hold_quit);
    }

  if (lrg_vr_service_should_quit (vr_service ()))
    {
      /* Quit from the VR dashboard: close the frame like its close button. */
      if (!vr.quit_sent)
        {
          struct input_event ie;
          EVENT_INIT (ie);
          ie.kind = DELETE_WINDOW_EVENT;
          vr.quit_sent = true;
          count += vr_store (hold_quit, &ie);
        }
      return count;
    }

  /* Busy = a command is running (not idle in the command loop).
     `waiting_for_input' cannot tell: process.c clears it as soon as pselect
     returns, before read_socket runs, so it reads false even when idle.  */
  if (!vr.modal && NILP (Fcurrent_idle_time ())
      && g_get_monotonic_time () - vr.last_frame_us < VR_BUSY_FRAME_US)
    return count;

  block_input ();
  if (!lrg_3d_surface_render_vr (vr.s3))
    {
      unblock_input ();
      return 0;
    }
  unblock_input ();

  now = g_get_monotonic_time ();
  vr.dt = (float) (now - vr.last_frame_us) / 1e6f;
  if (vr.dt <= 0.0f || vr.dt > 0.1f)
    vr.dt = 1.0f / 90.0f;
  vr.last_frame_us = now;
  vr.frame_no++;

  /* No views drawn (headset off / dashboard up): still track the lasers. */
  if (!vr.pointers_fresh)
    vr_update_pointers ();
  vr.pointers_fresh = false;

  /* The modifier hand's layer applies to everything the other hand sends
     this frame; a change is felt in the modifier hand.  The modifier hand
     never holds the mouse.  */
  /* The second layer button: the bumper where the modifier hand has one
     (the Steam Frame), else the grip.  Re-read now and then: the runtime
     binds the controller profile after the session starts.  */
  if (vr.mod_second != 0)
    vr.second_is_bumper = vr.mod_second == 1;
  else if (g_get_monotonic_time () - vr.second_checked_us > 2 * G_USEC_PER_SEC)
    {
      char *prof = lrg_openxr_service_get_interaction_profile
        (vr.xr, (LrgVRHand) vr.move_hand);
      vr.second_is_bumper = prof != NULL && strstr (prof, "frame_controller") != NULL;
      vr.second_checked_us = g_get_monotonic_time ();
      g_free (prof);
    }

  {
    int layer = vr_read_layer ();
    if (layer != vr.layer)
      vr_pulse (vr.move_hand, 0.01f, layer != 0 ? 0.3f : 0.15f);
    vr.layer = layer;
    if (vr_is_modifier_hand (vr.pointer_hand))
      vr.pointer_hand = 1 - vr.pointer_hand;
  }

  count += vr_handtrack_tick (hold_quit);
  for (h = 0; h < 2; h++)
    count += vr_hand_input (hold_quit, h);

  /* Keep the scene's eases (focus, carousel) moving between redisplays. */
  lrg_3d_surface_step (vr.s3, vr.dt);
  return count;
}

/* ------------------------------------------------------------ Lisp ------ */

static void
check_vr_active (void)
{
  if (!vr.active)
    error ("VR is not active (start Emacs with --lrg=3dvr, or call cmacs-lrg-vr-start)");
}

DEFUN ("cmacs-lrg-vr-supported-p", Fcmacs_lrg_vr_supported_p,
       Scmacs_lrg_vr_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build can present `--lrg' frames in VR.  */)
  (void)
{
  return lrg_openxr_service_is_supported () ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-vr-active-p", Fcmacs_lrg_vr_active_p, Scmacs_lrg_vr_active_p,
       0, 0, 0,
       doc: /* Return non-nil while an lrg frame is being shown in a VR headset.  */)
  (void)
{
  return vr.active ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-vr-start", Fcmacs_lrg_vr_start, Scmacs_lrg_vr_start, 0, 1, 0,
       doc: /* Start showing FRAME in a VR headset (OpenXR).
FRAME must be a 3D lrg frame (`emacs --lrg=3d' or `--lrg=3dvr'); it
defaults to the selected frame.  Signals an error when no OpenXR runtime
(SteamVR, Monado) is available.  Return t.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  char *err = NULL;

  if (!FRAME_LRG_P (f))
    error ("Not an lrg frame");
  if (!cmacs_lrgvr_attach (f, &err))
    {
      Lisp_Object msg = build_string (err != NULL ? err : "VR failed");
      xfree (err);
      xsignal1 (Qerror, msg);
    }
  return Qt;
}

DEFUN ("cmacs-lrg-vr-stop", Fcmacs_lrg_vr_stop, Scmacs_lrg_vr_stop, 0, 0, 0,
       doc: /* Stop VR presentation; the frame stays a desktop 3D frame.  */)
  (void)
{
  cmacs_lrgvr_detach ();
  return Qnil;
}

DEFUN ("cmacs-lrg-vr-recenter", Fcmacs_lrg_vr_recenter, Scmacs_lrg_vr_recenter,
       0, 0, "",
       doc: /* Put the scene straight ahead of where you are looking now.  */)
  (void)
{
  check_vr_active ();
  lrg_3d_surface_vr_recenter (vr.s3);
  return Qnil;
}

DEFUN ("cmacs-lrg-vr-scale", Fcmacs_lrg_vr_scale, Scmacs_lrg_vr_scale, 0, 0, 0,
       doc: /* Return the VR world scale: metres per scene unit.  */)
  (void)
{
  check_vr_active ();
  return make_float (lrg_3d_surface_get_vr_scale (vr.s3));
}

DEFUN ("cmacs-lrg-vr-set-scale", Fcmacs_lrg_vr_set_scale,
       Scmacs_lrg_vr_set_scale, 1, 1, 0,
       doc: /* Set the VR world scale to METRES per scene unit (0.02..5).
Larger makes the whole workspace bigger and farther away; 0.3 is the
default (a whole-frame panel 1.5 m tall, about 2 m away).  */)
  (Lisp_Object metres)
{
  check_vr_active ();
  CHECK_NUMBER (metres);
  lrg_3d_surface_set_vr_scale (vr.s3, (float) XFLOATINT (metres));
  if (vr.kb_visible)
    kb_place ();
  return make_float (lrg_3d_surface_get_vr_scale (vr.s3));
}

DEFUN ("cmacs-lrg-vr-turn", Fcmacs_lrg_vr_turn, Scmacs_lrg_vr_turn, 1, 1, 0,
       doc: /* Turn the viewer by DEGREES (positive turns left).  */)
  (Lisp_Object degrees)
{
  check_vr_active ();
  CHECK_NUMBER (degrees);
  lrg_3d_surface_vr_turn (vr.s3, (float) XFLOATINT (degrees));
  return Qnil;
}

DEFUN ("cmacs-lrg-vr-move", Fcmacs_lrg_vr_move, Scmacs_lrg_vr_move, 1, 3, 0,
       doc: /* Move the viewer FORWARD metres (and RIGHT, UP), relative to the gaze.  */)
  (Lisp_Object forward, Lisp_Object right, Lisp_Object up)
{
  check_vr_active ();
  CHECK_NUMBER (forward);
  if (!NILP (right))
    CHECK_NUMBER (right);
  if (!NILP (up))
    CHECK_NUMBER (up);
  lrg_3d_surface_vr_move (vr.s3, (float) XFLOATINT (forward),
                          NILP (right) ? 0.0f : (float) XFLOATINT (right),
                          NILP (up) ? 0.0f : (float) XFLOATINT (up));
  return Qnil;
}

DEFUN ("cmacs-lrg-vr-keyboard", Fcmacs_lrg_vr_keyboard, Scmacs_lrg_vr_keyboard,
       0, 1, 0,
       doc: /* Show the in-world keyboard if ARG is positive, hide it if not.
With ARG nil, toggle it.  It appears in front of you, below eye level;
grab it with the grip to move it.  Return non-nil if it is now shown.  */)
  (Lisp_Object arg)
{
  check_vr_active ();
  if (NILP (arg))
    kb_set_visible (!vr.kb_visible);
  else
    kb_set_visible (FIXNUMP (arg) ? XFIXNUM (arg) > 0 : !EQ (arg, Qnil));
  return vr.kb_visible ? Qt : Qnil;
}

DEFUN ("cmacs-lrg-vr-haptic", Fcmacs_lrg_vr_haptic, Scmacs_lrg_vr_haptic,
       1, 3, 0,
       doc: /* Pulse the controller in HAND (`left' or `right').
SECONDS defaults to 0.05 and AMPLITUDE (0..1) to 0.5.  */)
  (Lisp_Object hand, Lisp_Object seconds, Lisp_Object amplitude)
{
  int h;

  check_vr_active ();
  CHECK_SYMBOL (hand);
  if (!NILP (seconds))
    CHECK_NUMBER (seconds);
  if (!NILP (amplitude))
    CHECK_NUMBER (amplitude);
  h = EQ (hand, intern_c_string ("left")) ? LRG_VR_HAND_LEFT : LRG_VR_HAND_RIGHT;
  lrg_vr_service_trigger_haptic (vr_service (), (LrgVRHand) h,
                                 NILP (seconds) ? 0.05f
                                                : (float) XFLOATINT (seconds),
                                 NILP (amplitude) ? 0.5f
                                                  : (float) XFLOATINT (amplitude));
  return Qnil;
}

/* A layer modifier named by SYM: shift, meta or control.  Hyper and super
   mark a button's hold and release (VR_HOLD_MOD, VR_RELEASE_MOD), alt its
   second bank (VR_BANK2).  */
static int
vr_modifier_bit (Lisp_Object sym)
{
  CHECK_SYMBOL (sym);
  if (EQ (sym, intern_c_string ("shift")))
    return shift_modifier;
  if (EQ (sym, intern_c_string ("meta")))
    return meta_modifier;
  if (EQ (sym, intern_c_string ("control")))
    return ctrl_modifier;
  xsignal2 (Qwrong_type_argument, intern_c_string ("vr-layer-modifier-p"), sym);
}

DEFUN ("cmacs-lrg-vr-set-indicator", Fcmacs_lrg_vr_set_indicator,
       Scmacs_lrg_vr_set_indicator, 2, 2, 0,
       doc: /* Show a status light above the controller in HAND.
HAND is `left' or `right'.  COLOR is a string "#RRGGBB", or nil to turn
the light off.  Used for voice: red while listening, amber while
transcribing.  */)
  (Lisp_Object hand, Lisp_Object color)
{
  int h, i;
  guint8 rgb[3];

  CHECK_SYMBOL (hand);
  h = EQ (hand, intern_c_string ("left")) ? LRG_VR_HAND_LEFT : LRG_VR_HAND_RIGHT;
  if (NILP (color))
    {
      vr.hand[h].indicator = false;
      return Qnil;
    }
  CHECK_STRING (color);
  if (SBYTES (color) != 7 || SREF (color, 0) != '#')
    error ("Indicator colour must be \"#RRGGBB\"");
  for (i = 0; i < 3; i++)
    {
      int hi = g_ascii_xdigit_value (SREF (color, 1 + 2 * i));
      int lo = g_ascii_xdigit_value (SREF (color, 2 + 2 * i));
      if (hi < 0 || lo < 0)
        error ("Indicator colour must be \"#RRGGBB\"");
      rgb[i] = (guint8) (hi * 16 + lo);
    }
  memcpy (vr.hand[h].indicator_rgb, rgb, sizeof rgb);
  vr.hand[h].indicator = true;
  return color;
}

DEFUN ("cmacs-lrg-vr-layer", Fcmacs_lrg_vr_layer, Scmacs_lrg_vr_layer,
       0, 0, 0,
       doc: /* Return the controller layer held now, as a list of modifiers.
For example (shift) while the modifier hand's trigger is held, nil when
no layer is.  */)
  (void)
{
  Lisp_Object mods = Qnil;

  if (vr.layer & shift_modifier)
    mods = Fcons (intern_c_string ("shift"), mods);
  if (vr.layer & meta_modifier)
    mods = Fcons (intern_c_string ("meta"), mods);
  if (vr.layer & ctrl_modifier)
    mods = Fcons (intern_c_string ("control"), mods);
  return mods;
}

DEFUN ("cmacs-lrg-vr-set-option", Fcmacs_lrg_vr_set_option,
       Scmacs_lrg_vr_set_option, 2, 2, 0,
       doc: /* Set VR option KEY to VALUE.
KEY is one of:
  `snap-degrees'  snap-turn step in degrees (default 30)
  `move-speed'    stick locomotion speed, metres/second (default 1.5)
  `scroll-rate'   wheel events/second at full stick (default 10)
  `haptics'       non-nil to pulse controllers on clicks (default t)
  `move-hand'     `left' or `right': the hand that moves and turns; the
                  other hand's stick scrolls (default `left')
  `keyboard-tilt' degrees the keyboard leans away from you (default 50)
  `modifier-hand' non-nil: the move hand's trigger and grip are layer
                  modifiers for everything the other hand sends, instead
                  of click and grab (default t)
  `mod-trigger', `mod-bumper', `mod-both'
                  the modifier for the trigger, the second layer button
                  and both held: `shift', `meta' or `control' (defaults
                  shift, meta, control); `mod-grip' is an alias of
                  `mod-bumper'
  `mod-second-source'
                  the second layer button: `bumper', `grip', or `auto'
                  -- the bumper on controllers that have one (the Steam
                  Frame), else the grip
  `hold-seconds'  how long a button is held before it is a hold, not a
                  tap (default 0.35)
  `dpad-arrows'   non-nil: the D-pad sends arrow keys, repeating while
                  held; nil: <vr-dpad-up> etc. with tap and hold
                  (default t)
  `hands'         non-nil: a tracked hand (OpenXR hand tracking) drives
                  the laser of a controller that is not tracked -- pinch
                  to click, drag and scroll (default t)
  `hand-joints'   non-nil: draw tracked hands as joints and bones
                  (default t)
Return VALUE.  */)
  (Lisp_Object key, Lisp_Object value)
{
  CHECK_SYMBOL (key);
  if (!EQ (key, intern_c_string ("haptics"))
      && !EQ (key, intern_c_string ("move-hand"))
      && !EQ (key, intern_c_string ("modifier-hand"))
      && !EQ (key, intern_c_string ("mod-trigger"))
      && !EQ (key, intern_c_string ("mod-grip"))
      && !EQ (key, intern_c_string ("mod-bumper"))
      && !EQ (key, intern_c_string ("mod-second-source"))
      && !EQ (key, intern_c_string ("dpad-arrows"))
      && !EQ (key, intern_c_string ("hands"))
      && !EQ (key, intern_c_string ("hand-joints"))
      && !EQ (key, intern_c_string ("mod-both")))
    CHECK_NUMBER (value);
  if (EQ (key, intern_c_string ("snap-degrees")))
    vr.snap_degrees = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("move-speed")))
    vr.move_speed = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("scroll-rate")))
    vr.scroll_rate = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("haptics")))
    vr.haptics = !NILP (value);
  else if (EQ (key, intern_c_string ("move-hand")))
    vr.move_hand = EQ (value, intern_c_string ("right")) ? LRG_VR_HAND_RIGHT
                                                         : LRG_VR_HAND_LEFT;
  else if (EQ (key, intern_c_string ("keyboard-tilt")))
    vr.kb_tilt = (float) XFLOATINT (value);
  else if (EQ (key, intern_c_string ("modifier-hand")))
    vr.modifier_hand = !NILP (value);
  else if (EQ (key, intern_c_string ("mod-trigger")))
    vr.mod_trigger = vr_modifier_bit (value);
  else if (EQ (key, intern_c_string ("mod-grip"))
           || EQ (key, intern_c_string ("mod-bumper")))
    vr.mod_grip = vr_modifier_bit (value);
  else if (EQ (key, intern_c_string ("dpad-arrows")))
    vr.dpad_arrows = !NILP (value);
  else if (EQ (key, intern_c_string ("hands")))
    vr.hands_enabled = !NILP (value);
  else if (EQ (key, intern_c_string ("hand-joints")))
    vr.show_joints = !NILP (value);
  else if (EQ (key, intern_c_string ("mod-second-source")))
    {
      vr.mod_second = EQ (value, intern_c_string ("bumper")) ? 1
                      : EQ (value, intern_c_string ("grip")) ? 2 : 0;
      vr.second_checked_us = 0;
    }
  else if (EQ (key, intern_c_string ("mod-both")))
    vr.mod_both = vr_modifier_bit (value);
  else if (EQ (key, intern_c_string ("hold-seconds")))
    {
      double sec = XFLOATINT (value);
      if (sec < 0.1 || sec > 3.0)
        args_out_of_range (value, make_float (3.0));
      vr.hold_us = (gint64) (sec * 1e6);
    }
  else
    error ("Unknown VR option");
  return value;
}

DEFUN ("cmacs-lrg-vr-screenshot", Fcmacs_lrg_vr_screenshot,
       Scmacs_lrg_vr_screenshot, 1, 1, 0,
       doc: /* Save what the headset shows, as PNGs, with names built from PREFIX.
PREFIX-eye.png gets the left eye of the next headset frame, lasers and
keyboard included; PREFIX-frame.png gets the flat Emacs frame as last
captured onto the panels.  The eye image appears once that frame is
drawn -- a moment later, and not while the headset is asleep.  Return
the list of the two file names.  */)
  (Lisp_Object prefix)
{
  Lisp_Object eye, flat;

  check_vr_active ();
  CHECK_STRING (prefix);
  prefix = Fexpand_file_name (prefix, Qnil);
  eye = concat2 (prefix, build_string ("-eye.png"));
  flat = concat2 (prefix, build_string ("-frame.png"));
  xfree (vr.shot_path);
  vr.shot_path = xstrdup (SSDATA (ENCODE_FILE (eye)));
  if (!lrg_3d_surface_export_content (vr.s3, SSDATA (ENCODE_FILE (flat))))
    flat = Qnil;
  return list2 (eye, flat);
}

DEFUN ("cmacs-lrg-vr-pointed-window", Fcmacs_lrg_vr_pointed_window,
       Scmacs_lrg_vr_pointed_window, 0, 0, 0,
       doc: /* Return the window under the active controller's laser, or nil.  */)
  (void)
{
  if (!vr.active || !vr.mouse_valid || vr.f == NULL)
    return Qnil;
  return window_from_coordinates (vr.f, vr.mouse_x, vr.mouse_y, NULL, false,
                                  false, false);
}

DEFUN ("cmacs-lrg-vr-status", Fcmacs_lrg_vr_status, Scmacs_lrg_vr_status,
       0, 0, 0,
       doc: /* Return a plist describing the VR session, or nil when inactive.
Keys: :runtime :system :state :refresh-rate :scale :keyboard
:left-profile :right-profile :left-tracked :right-tracked, :hand-tracking
(the runtime tracks hands), :hand-aim (with its own aim and pinch),
:left-hand and :right-hand (that hand, not its controller, drives its
laser now), :frames
(headset frames rendered so far), :eye-size (WIDTH . HEIGHT of each
eye image, see CMACS_LRG_VR_RESOLUTION), :keyboards (physical keyboards
read from evdev) and :window-hidden.  */)
  (void)
{
  Lisp_Object plist = Qnil;
  char *lp, *rp;

  if (!vr.active)
    return Qnil;

  lp = lrg_openxr_service_get_interaction_profile (vr.xr, LRG_VR_HAND_LEFT);
  rp = lrg_openxr_service_get_interaction_profile (vr.xr, LRG_VR_HAND_RIGHT);
#define PUT(k, v) plist = Fcons (intern_c_string (k), Fcons ((v), plist))
  PUT (":frames", make_fixnum (vr.frame_no));
  {
    guint ew = 0, eh = 0;
    lrg_openxr_service_get_eye_size (vr.xr, &ew, &eh);
    PUT (":eye-size", Fcons (make_fixnum (ew), make_fixnum (eh)));
  }
  PUT (":keyboards", make_fixnum (cmacs_lrgvr_kbd_count ()));
  PUT (":right-hand", vr.hand[1].src == SRC_HAND ? Qt : Qnil);
  PUT (":left-hand", vr.hand[0].src == SRC_HAND ? Qt : Qnil);
  PUT (":hand-aim", lrg_openxr_service_has_hand_aim (vr.xr) ? Qt : Qnil);
  PUT (":hand-tracking",
       lrg_vr_service_is_hand_tracking_supported (vr_service ()) ? Qt : Qnil);
  PUT (":window-hidden", vr.window_hidden ? Qt : Qnil);
  PUT (":right-tracked", vr.hand[1].tracked ? Qt : Qnil);
  PUT (":left-tracked", vr.hand[0].tracked ? Qt : Qnil);
  PUT (":right-profile", rp != NULL ? build_string (rp) : Qnil);
  PUT (":left-profile", lp != NULL ? build_string (lp) : Qnil);
  PUT (":keyboard", vr.kb_visible ? Qt : Qnil);
  PUT (":scale", make_float (lrg_3d_surface_get_vr_scale (vr.s3)));
  PUT (":refresh-rate",
       make_float (lrg_openxr_service_get_display_refresh_rate (vr.xr)));
  PUT (":state", build_string (lrg_openxr_service_get_session_state_name (vr.xr)));
  {
    const char *sys = lrg_openxr_service_get_system_name (vr.xr);
    const char *rt = lrg_openxr_service_get_runtime_name (vr.xr);
    PUT (":system", sys != NULL ? build_string (sys) : Qnil);
    PUT (":runtime", rt != NULL ? build_string (rt) : Qnil);
  }
#undef PUT
  g_free (lp);
  g_free (rp);
  return plist;
}

/* One hand of a simulated frame: nil (untracked) or a plist (see
   `cmacs-lrg-vr--simulate-hand-gestures').  */
static void
vr_sim_hand (Lisp_Object spec, struct vr_hand_sample *out)
{
  Lisp_Object target, pos;
  int i;

  memset (out, 0, sizeof *out);
  if (NILP (spec))
    return;
  CHECK_LIST (spec);
  out->tracked = true;
  out->pinched = !NILP (plist_get (spec, intern_c_string (":pinch")));
  out->palm_up = !NILP (plist_get (spec, intern_c_string (":palm-up")));
  target = plist_get (spec, intern_c_string (":target"));
  out->target = EQ (target, intern_c_string ("panel")) ? HT_PANEL
                : EQ (target, intern_c_string ("keyboard")) ? HT_KEYBOARD
                : EQ (target, intern_c_string ("workspace")) ? HT_WORKSPACE
                : HT_NONE;
  {
    Lisp_Object x = plist_get (spec, intern_c_string (":x"));
    Lisp_Object y = plist_get (spec, intern_c_string (":y"));
    out->fx = FIXNUMP (x) ? (int) XFIXNUM (x) : 0;
    out->fy = FIXNUMP (y) ? (int) XFIXNUM (y) : 0;
  }
  pos = plist_get (spec, intern_c_string (":pos"));
  for (i = 0; i < 3 && CONSP (pos); i++, pos = XCDR (pos))
    {
      CHECK_NUMBER (XCAR (pos));
      out->pos[i] = (float) XFLOATINT (XCAR (pos));
    }
}

DEFUN ("cmacs-lrg-vr--simulate-hand-gestures",
       Fcmacs_lrg_vr__simulate_hand_gestures,
       Scmacs_lrg_vr__simulate_hand_gestures, 1, 1, 0,
       doc: /* Run the hand-gesture classifier over FRAMES; return its actions.
For tests: no headset is needed, and nothing is sent anywhere.  This is
the same classifier the headset frame runs (vr_gesture_step), started
fresh.

FRAMES is a list of (MILLISECONDS LEFT RIGHT).  LEFT and RIGHT are nil
for an untracked hand, or a plist:
  :pinch    non-nil while pinched (the latch, hysteresis applied)
  :palm-up  non-nil while the palm faces up
  :target   what the laser is on: `panel', `keyboard', `workspace' or nil
  :x :y     the frame pixel under the laser
  :pos      (X Y Z), the pinch point in metres

Each action is (KIND HAND . ARGS), HAND `left', `right' or `both':
  (click HAND X Y)  (drag-begin HAND X Y)  (drag-end HAND X Y)
  (scroll HAND DX DY)  -- wheel steps; DY > 0 is the hand moving down
  (pull-begin HAND)  (pull-move HAND DX DY DZ)  (pull-end HAND)
  (tap HAND)  (key-down HAND)  (key-up HAND)
  (palm-up HAND)  (palm-down HAND)
  (zoom-begin both)  (zoom both RATIO)  (zoom-end both RATIO)  */)
  (Lisp_Object frames)
{
  static const char *const kinds[] = {
    "click", "drag-begin", "drag-end", "scroll", "pull-begin", "pull-move",
    "pull-end", "tap", "key-down", "key-up", "palm-up", "palm-down",
    "zoom-begin", "zoom", "zoom-end"
  };
  struct vr_gestures g;
  Lisp_Object result = Qnil, tail;

  memset (&g, 0, sizeof g);
  CHECK_LIST (frames);
  for (tail = frames; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object fr = XCAR (tail);
      struct vr_hand_sample smp[2];
      struct vr_hand_action act[VR_HAND_MAX_ACTIONS];
      int n, i;

      CHECK_CONS (fr);
      CHECK_FIXNUM (XCAR (fr));
      vr_sim_hand (Fnth (make_fixnum (1), fr), &smp[0]);
      vr_sim_hand (Fnth (make_fixnum (2), fr), &smp[1]);
      n = vr_gesture_step (&g, smp, XFIXNUM (XCAR (fr)) * 1000, act,
                           VR_HAND_MAX_ACTIONS);
      for (i = 0; i < n; i++)
        {
          const struct vr_hand_action *a = &act[i];
          Lisp_Object hand = intern_c_string (a->hand < 0 ? "both"
                                              : a->hand == LRG_VR_HAND_LEFT
                                              ? "left" : "right");
          Lisp_Object args = Qnil;

          switch (a->kind)
            {
            case HA_CLICK: case HA_DRAG_BEGIN: case HA_DRAG_END: case HA_SCROLL:
              args = list2 (make_fixnum (a->x), make_fixnum (a->y));
              break;
            case HA_PULL_MOVE:
              args = list3 (make_float (a->v[0]), make_float (a->v[1]),
                            make_float (a->v[2]));
              break;
            case HA_ZOOM: case HA_ZOOM_END:
              args = list1 (make_float (a->v[0]));
              break;
            default:
              break;
            }
          result = Fcons (Fcons (intern_c_string (kinds[a->kind]),
                                 Fcons (hand, args)),
                          result);
        }
    }
  return Fnreverse (result);
}

/* The SpaceMouse in VR (cmacs-spacemouse.c): move the viewer.  T is
   (right, up, forward) and R (pitch, yaw, roll), each -1..1 already
   shaped; DT seconds since the last report.  Returns false when no VR
   session runs, so the caller tries its next target.  */
bool
cmacs_lrgvr_spacemouse_motion (const float *t, const float *r, float dt)
{
  if (!vr.active || vr.s3 == NULL)
    return false;
  lrg_3d_surface_vr_move (vr.s3, t[2] * vr.move_speed * dt,
                          t[0] * vr.move_speed * dt,
                          t[1] * vr.move_speed * dt);
  /* Yaw: positive turns left, as `cmacs-lrg-vr-turn'.  A smooth turn,
     90 degrees a second at full twist.  */
  if (r[1] != 0.0f)
    lrg_3d_surface_vr_turn (vr.s3, r[1] * 90.0f * dt);
  return true;
}

void
syms_of_cmacs_lrgvr (void)
{
  defsubr (&Scmacs_lrg_vr__simulate_hand_gestures);
  defsubr (&Scmacs_lrg_vr_supported_p);
  defsubr (&Scmacs_lrg_vr_set_indicator);
  defsubr (&Scmacs_lrg_vr_layer);
  defsubr (&Scmacs_lrg_vr_active_p);
  defsubr (&Scmacs_lrg_vr_start);
  defsubr (&Scmacs_lrg_vr_stop);
  defsubr (&Scmacs_lrg_vr_recenter);
  defsubr (&Scmacs_lrg_vr_scale);
  defsubr (&Scmacs_lrg_vr_set_scale);
  defsubr (&Scmacs_lrg_vr_turn);
  defsubr (&Scmacs_lrg_vr_move);
  defsubr (&Scmacs_lrg_vr_keyboard);
  defsubr (&Scmacs_lrg_vr_haptic);
  defsubr (&Scmacs_lrg_vr_set_option);
  defsubr (&Scmacs_lrg_vr_pointed_window);
  defsubr (&Scmacs_lrg_vr_screenshot);
  defsubr (&Scmacs_lrg_vr_status);
}

#endif /* HAVE_CMACS_LRGVR */
