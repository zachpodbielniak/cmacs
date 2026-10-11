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
    translates to <vr-right-a> etc., so every binding lives in Lisp.

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
#define VR_XK_F30       0xffdb   /* <vr-left-stick> */

#define VR_DEADZONE      0.25f
#define VR_SNAP_ARM      0.75f
#define VR_SNAP_REARM    0.30f
#define VR_LASER_M       4.0f    /* laser length when it hits nothing */
/* While Lisp is busy, render a headset frame at most this often.  The
   headset still gets a fresh frame ten times a second -- SteamVR reprojects
   in between -- and the rest of the main thread goes to Lisp.  Rendering
   every frame the runtime wants would block in xrEndFrame for most of each
   display interval (it waits for the GPU), and read_socket runs constantly
   while Lisp works (input polling), so a long command -- or a large init
   file -- would crawl.  Idle (in the command loop, waiting for input),
   every frame renders.  */
#define VR_BUSY_FRAME_US 100000

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

enum vr_key_kind { VK_CHAR, VK_SYM, VK_SHIFT, VK_CTRL, VK_META, VK_SUPER,
                   VK_HIDE };

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

struct vr_hand
{
  bool tracked;
  float origin[3], dir[3];       /* laser, scene units */
  bool hit_panel;                /* laser lands on a panel */
  float hit_dist;                /* scene units, to the panel or keyboard */
  int fx, fy;                    /* frame pixel under the laser */
  guint64 key;                   /* panel under the laser */
  int kb_row, kb_col;            /* keyboard key under the laser, or -1 */

  guint buttons, prev;
  bool trigger_mouse;            /* trigger press went to Emacs as mouse-1 */
  int last_fx, last_fy;

  /* Grip: carrying a panel (grab_key), the keyboard, or the world. */
  enum { GRAB_NONE, GRAB_PANEL, GRAB_KEYBOARD, GRAB_WORLD } grab;
  guint64 grab_key;
  float grab_local[3];           /* object centre in the controller-yaw frame */
  float grab_yaw_off;            /* object yaw - controller yaw, degrees */
  float grab_w, grab_h;
  float grab_track[3];           /* GRAB_WORLD: controller position, metres */

  float scroll_acc, hscroll_acc;
  bool snap_used;
};

static struct
{
  bool active;
  bool window_hidden;            /* desktop window hidden; evdev keyboard */
  struct frame *f;
  Lrg3DSurface *s3;
  LrgOpenXRService *xr;
  int frame_fd;
  bool quit_sent;
  gint64 last_frame_us;
  float dt;
  guint64 frame_no;
  bool pointers_fresh;           /* lasers recomputed for the current frame */
  char *shot_path;               /* cmacs-lrg-vr-screenshot: eye PNG to write */

  struct vr_hand hand[2];
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
} vr = {
  .frame_fd = -1, .pointer_hand = LRG_VR_HAND_RIGHT,
  .snap_degrees = 30.0f, .move_speed = 1.5f, .scroll_rate = 10.0f,
  .haptics = true, .move_hand = LRG_VR_HAND_LEFT, .kb_tilt = 50.0f,
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
  ie.modifiers = up ? up_modifier : down_modifier;
  XSETINT (ie.x, x);
  XSETINT (ie.y, y);
  XSETFRAME (ie.frame_or_window, vr.f);
  ie.arg = Qnil;
  ie.timestamp = cmacs_lrgterm_now_ms ();
  return vr_store (hold_quit, &ie);
}

/* Sticky keyboard modifiers, consumed by the next non-modifier key. */
static int
kb_take_mods (void)
{
  int m = (vr.kb_ctrl ? ctrl_modifier : 0) | (vr.kb_meta ? meta_modifier : 0)
          | (vr.kb_super ? super_modifier : 0);
  if (vr.kb_ctrl || vr.kb_meta || vr.kb_super)
    vr.kb_dirty = true;
  vr.kb_ctrl = vr.kb_meta = vr.kb_super = false;
  return m;
}

static int
kb_press (struct input_event *hold_quit, int row, int col)
{
  const struct vr_key *k = &vr_rows[row].keys[col];
  int count = 0, mods;

  switch (k->kind)
    {
    case VK_SHIFT:
      vr.kb_shift = (vr.kb_shift + 1) % 3;   /* off -> once -> locked -> off */
      vr.kb_dirty = true;
      break;
    case VK_CTRL:  vr.kb_ctrl = !vr.kb_ctrl;   vr.kb_dirty = true; break;
    case VK_META:  vr.kb_meta = !vr.kb_meta;   vr.kb_dirty = true; break;
    case VK_SUPER: vr.kb_super = !vr.kb_super; vr.kb_dirty = true; break;
    case VK_HIDE:  kb_set_visible (false); break;
    case VK_SYM:
      mods = kb_take_mods () | (vr.kb_shift ? shift_modifier : 0);
      count += vr_emit_keysym (hold_quit, k->code, mods);
      if (vr.kb_shift == 1)
        {
          vr.kb_shift = 0;
          vr.kb_dirty = true;
        }
      break;
    case VK_CHAR:
      {
        int ch = vr.kb_shift ? k->shifted : k->code;
        mods = kb_take_mods ();
        /* As lrgterm does for a physical keyboard: C-A is C-a. */
        if ((mods & ctrl_modifier) && ch >= 'A' && ch <= 'Z')
          ch += 'a' - 'A';
        count += vr_emit_char (hold_quit, ch, mods);
        if (vr.kb_shift == 1)
          {
            vr.kb_shift = 0;
            vr.kb_dirty = true;
          }
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

      hand->tracked = lrg_vr_service_is_controller_tracked (svc, (LrgVRHand) h);
      hand->hit_panel = false;
      hand->kb_row = hand->kb_col = -1;
      hand->hit_dist = VR_LASER_M / lrg_3d_surface_get_vr_scale (vr.s3);
      if (!hand->tracked)
        continue;

      lrg_vr_service_get_controller_pose (svc, (LrgVRHand) h, pose);
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
      grl_draw_cube (a, 0.03f / mpu, 0.03f / mpu, 0.03f / mpu, body);
      if (aiming)
        grl_draw_sphere (b, (pressed ? 0.010f : 0.007f) / mpu, beam);
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

static void
grab_begin (struct vr_hand *hand, int which)
{
  float cx, cy, cz, yaw, w, h, cyaw, lx, lz;

  cyaw = heading_deg (hand->dir[0], hand->dir[2]);

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
      lrg_vr_service_get_controller_pose (vr_service (), (LrgVRHand) which, pose);
      hand->grab_track[0] = pose[12];
      hand->grab_track[1] = pose[13];
      hand->grab_track[2] = pose[14];
      vr_pulse (which, 0.02f, 0.3f);
      return;
    }

  /* The object rides on the controller: remember its centre in the frame
     that turns with the controller's heading (pitch/roll are ignored, so
     panels stay upright). */
  rot_y_deg (-cyaw, cx - hand->origin[0], cz - hand->origin[2], &lx, &lz);
  hand->grab_local[0] = lx;
  hand->grab_local[1] = cy - hand->origin[1];
  hand->grab_local[2] = lz;
  hand->grab_yaw_off = yaw - cyaw;
  hand->grab_w = w;
  hand->grab_h = h;
  vr_pulse (which, 0.03f, 0.5f);
}

static void
grab_update (struct vr_hand *hand, int which)
{
  float cyaw, wx, wz, nx, ny, nz, sy, sx, push, grow, mpu;

  if (hand->grab == GRAB_WORLD)
    {
      float pose[16], head[16], dx, dy, dz, hy, fwd, right;
      LrgVRService *svc = vr_service ();

      lrg_vr_service_get_controller_pose (svc, (LrgVRHand) which, pose);
      lrg_vr_service_get_hmd_pose (svc, head);
      dx = pose[12] - hand->grab_track[0];
      dy = pose[13] - hand->grab_track[1];
      dz = pose[14] - hand->grab_track[2];
      /* Pulling the hand toward you pulls the world toward you. */
      hy = heading_deg (-head[8], -head[10]) * (float) (G_PI / 180.0);
      fwd = dx * -sinf (hy) + dz * -cosf (hy);
      right = dx * cosf (hy) + dz * -sinf (hy);
      lrg_3d_surface_vr_move (vr.s3, -fwd, -right, -dy);
      hand->grab_track[0] = pose[12];
      hand->grab_track[1] = pose[13];
      hand->grab_track[2] = pose[14];
      return;
    }

  /* While carrying: stick Y pushes/pulls, stick X resizes. */
  mpu = lrg_3d_surface_get_vr_scale (vr.s3);
  sy = lrg_vr_service_get_controller_axis (vr_service (), (LrgVRHand) which,
                                           LRG_VR_AXIS_THUMBSTICK_Y);
  sx = lrg_vr_service_get_controller_axis (vr_service (), (LrgVRHand) which,
                                           LRG_VR_AXIS_THUMBSTICK_X);
  if (fabsf (sy) > VR_DEADZONE)
    {
      float len = sqrtf (hand->grab_local[0] * hand->grab_local[0]
                         + hand->grab_local[2] * hand->grab_local[2]);
      push = 1.0f + sy * vr.dt * 1.2f;
      if (len * push * mpu > 0.15f || push > 1.0f)
        {
          hand->grab_local[0] *= push;
          hand->grab_local[2] *= push;
        }
    }
  if (fabsf (sx) > VR_DEADZONE)
    {
      grow = 1.0f + sx * vr.dt * 0.8f;
      if ((hand->grab_w * grow * mpu > 0.1f || grow > 1.0f)
          && (hand->grab_w * grow * mpu < 12.0f || grow < 1.0f))
        {
          hand->grab_w *= grow;
          hand->grab_h *= grow;
        }
    }

  cyaw = heading_deg (hand->dir[0], hand->dir[2]);
  rot_y_deg (cyaw, hand->grab_local[0], hand->grab_local[2], &wx, &wz);
  nx = hand->origin[0] + wx;
  ny = hand->origin[1] + hand->grab_local[1];
  nz = hand->origin[2] + wz;

  if (hand->grab == GRAB_KEYBOARD)
    {
      vr.kb_center[0] = nx; vr.kb_center[1] = ny; vr.kb_center[2] = nz;
      vr.kb_yaw = cyaw + hand->grab_yaw_off;
      vr.kb_w = hand->grab_w;
      vr.kb_h = hand->grab_h;
    }
  else
    lrg_3d_surface_set_panel_transform (vr.s3, hand->grab_key, nx, ny, nz,
                                        cyaw + hand->grab_yaw_off,
                                        hand->grab_w, hand->grab_h);
}

static int
vr_hand_input (struct input_event *hold_quit, int h)
{
  struct vr_hand *hand = &vr.hand[h];
  LrgVRService *svc = vr_service ();
  bool right = h == LRG_VR_HAND_RIGHT;
  bool mover = h == vr.move_hand;
  float sx, sy;
  int count = 0;

  hand->prev = hand->buttons;
  hand->buttons = lrg_vr_service_get_controller_buttons (svc, (LrgVRHand) h);
  sx = lrg_vr_service_get_controller_axis (svc, (LrgVRHand) h,
                                           LRG_VR_AXIS_THUMBSTICK_X);
  sy = lrg_vr_service_get_controller_axis (svc, (LrgVRHand) h,
                                           LRG_VR_AXIS_THUMBSTICK_Y);

  /* Trigger: type on the keyboard, or click in a buffer. */
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER))
    {
      if (hand->kb_row >= 0)
        {
          count += kb_press (hold_quit, hand->kb_row, hand->kb_col);
          vr_pulse (h, 0.015f, 0.4f);
        }
      else if (hand->hit_panel)
        {
          vr.pointer_hand = h;
          hand->trigger_mouse = true;
          hand->last_fx = hand->fx;
          hand->last_fy = hand->fy;
          vr.mouse_valid = true;
          vr.mouse_x = hand->fx;
          vr.mouse_y = hand->fy;
          lrg_3d_surface_set_focus_window (vr.s3, hand->key);
          count += vr_emit_mouse (hold_quit, 0, true, hand->fx, hand->fy,
                                  kb_take_mods ());
          vr_pulse (h, 0.012f, 0.35f);
        }
    }
  if (released_now (hand, LRG_VR_CONTROLLER_BUTTON_TRIGGER) && hand->trigger_mouse)
    {
      hand->trigger_mouse = false;
      count += vr_emit_mouse (hold_quit, 0, false, hand->last_fx, hand->last_fy,
                              0);
    }

  /* Pointer motion (drag while the trigger is held, hover otherwise). */
  if (hand->hit_panel && h == vr.pointer_hand
      && (hand->fx != vr.mouse_x || hand->fy != vr.mouse_y || !vr.mouse_valid))
    {
      vr.mouse_valid = true;
      vr.mouse_x = hand->fx;
      vr.mouse_y = hand->fy;
      if (hand->trigger_mouse)
        {
          hand->last_fx = hand->fx;
          hand->last_fy = hand->fy;
        }
      vr.f->mouse_moved = true;
      block_input ();
      note_mouse_highlight (vr.f, hand->fx, hand->fy);
      unblock_input ();
    }
  /* A hand that points at a panel while the other is idle takes the mouse. */
  if (hand->hit_panel && h != vr.pointer_hand
      && !vr.hand[vr.pointer_hand].trigger_mouse
      && !vr.hand[vr.pointer_hand].hit_panel)
    vr.pointer_hand = h;

  /* Grip: carry the panel / keyboard under the laser, or the world. */
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_GRIP))
    grab_begin (hand, h);
  if (hand->grab != GRAB_NONE && (hand->buttons & LRG_VR_CONTROLLER_BUTTON_GRIP))
    grab_update (hand, h);
  if (released_now (hand, LRG_VR_CONTROLLER_BUTTON_GRIP))
    {
      if (hand->grab == GRAB_PANEL)
        lrg_3d_surface_release_panel (vr.s3);
      hand->grab = GRAB_NONE;
    }

  /* Sticks.  The moving hand walks and turns; the other scrolls. */
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
      else if (hand->hit_panel)
        {
          if (fabsf (sy) > VR_DEADZONE)
            {
              hand->scroll_acc += sy * vr.scroll_rate * vr.dt;
              while (fabsf (hand->scroll_acc) >= 1.0f)
                {
                  bool up = hand->scroll_acc > 0.0f;
                  count += vr_emit_wheel (hold_quit, false, up, hand->fx,
                                          hand->fy);
                  hand->scroll_acc += up ? -1.0f : 1.0f;
                }
            }
          else
            hand->scroll_acc = 0.0f;
          if (fabsf (sx) > VR_DEADZONE)
            {
              hand->hscroll_acc += sx * vr.scroll_rate * vr.dt;
              while (fabsf (hand->hscroll_acc) >= 1.0f)
                {
                  bool r = hand->hscroll_acc > 0.0f;
                  count += vr_emit_wheel (hold_quit, true, !r, hand->fx,
                                          hand->fy);
                  hand->hscroll_acc += r ? -1.0f : 1.0f;
                }
            }
          else
            hand->hscroll_acc = 0.0f;
        }
    }

  /* Buttons. */
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_A))
    count += vr_emit_keysym (hold_quit, right ? VR_XK_F25 : VR_XK_F27, 0);
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_B))
    count += vr_emit_keysym (hold_quit, right ? VR_XK_F26 : VR_XK_F28, 0);
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_MENU))
    count += vr_emit_keysym (hold_quit, VR_XK_F29, 0);
  if (pressed_now (hand, LRG_VR_CONTROLLER_BUTTON_THUMBSTICK))
    {
      if (!mover && hand->hit_panel)
        {
          /* mouse-3 at the laser: context menus. */
          count += vr_emit_mouse (hold_quit, 2, true, hand->fx, hand->fy, 0);
          count += vr_emit_mouse (hold_quit, 2, false, hand->fx, hand->fy, 0);
        }
      else
        count += vr_emit_keysym (hold_quit, VR_XK_F30, 0);
    }
  return count;
}

/* ------------------------------------------------------------ public ---- */

bool
cmacs_lrgvr_active_p (void)
{
  return vr.active;
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

  lrg_3d_surface_set_vr_service (vr.s3, LRG_VR_SERVICE (xr));
  lrg_3d_surface_set_vr_overlay_func (vr.s3, vr_overlay, NULL, NULL);

  /* Frames are waited for off the main thread; pselect wakes on this fd. */
  vr.frame_fd = lrg_openxr_service_start_frame_thread (xr);
  if (vr.frame_fd >= 0)
    add_keyboard_wait_descriptor (vr.frame_fd);

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
  if (NILP (Fcurrent_idle_time ())
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
Return VALUE.  */)
  (Lisp_Object key, Lisp_Object value)
{
  CHECK_SYMBOL (key);
  if (!EQ (key, intern_c_string ("haptics"))
      && !EQ (key, intern_c_string ("move-hand")))
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
:left-profile :right-profile :left-tracked :right-tracked, :frames
(headset frames rendered so far), :keyboards (physical keyboards read
from evdev) and :window-hidden.  */)
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
  PUT (":keyboards", make_fixnum (cmacs_lrgvr_kbd_count ()));
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

void
syms_of_cmacs_lrgvr (void)
{
  defsubr (&Scmacs_lrg_vr_supported_p);
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
