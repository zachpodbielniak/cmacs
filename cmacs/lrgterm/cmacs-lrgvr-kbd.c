/* cmacs-lrgvr-kbd.c --- physical keyboards for Emacs in a VR headset.

Copyright (C) 2026 Zach Podbielniak

This file is part of cmacs, a fork of GNU Emacs.

SPDX-License-Identifier: AGPL-3.0-or-later

In VR the frame's desktop window is hidden: a compositor that hosts the
headset (gamescope under SteamVR) otherwise shows it to the user as a
separate flat "desktop game" in front of the scene.  A hidden window gets
no key events, so in VR the keyboard is read straight from the kernel:
every /dev/input/event* that looks like a keyboard -- a Bluetooth or USB
one, or the headset's own virtual keyboard -- is opened, its key codes run
through xkbcommon with the system layout (XKB_DEFAULT_LAYOUT and friends),
and the result stored as the same Emacs events lrgterm makes from GLFW.

The devices are grabbed (EVIOCGRAB) only while the VR session has input
focus, so typing goes to Emacs and not also to whatever the compositor
focuses; when the dashboard takes focus the grab is released and the
keyboard works there.  Devices are rescanned every two seconds, so a
keyboard connected after startup is picked up.  The fds are keyboard wait
descriptors: a key press wakes pselect at once.

Needs read access to /dev/input/event* (the `input' group).  Without it
nothing breaks -- there is just no physical keyboard in VR.  */

#include <config.h>

#ifdef HAVE_CMACS_LRGVR

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/input-event-codes.h>
#include <glib.h>
#include <xkbcommon/xkbcommon.h>

#include "lisp.h"
#include "frame.h"
#include "keyboard.h"
#include "termhooks.h"
#include "cmacs-lrgterm.h"

/* <linux/input.h> cannot be included: its `struct input_event' collides
   with Emacs's (termhooks.h).  The kernel's event record and the two
   ioctls used are therefore spelled out here; the layout is the 64-bit
   one (two longs of timestamp, then type, code, value).  */
struct kernel_input_event
{
  unsigned long sec;
  unsigned long usec;
  unsigned short type;
  unsigned short code;
  int value;
};
#define KBD_EVIOCGBIT(ev, len) _IOC (_IOC_READ, 'E', 0x20 + (ev), (len))
#define KBD_EVIOCGRAB          _IOW ('E', 0x90, int)

#define KBD_MAX         16
#define KBD_RESCAN_US   (2 * G_USEC_PER_SEC)
#define BITS_PER_LONG_  (sizeof (unsigned long) * 8)
#define NLONGS(n)       (((n) + BITS_PER_LONG_ - 1) / BITS_PER_LONG_)
#define TEST_BIT(b, a)  (((a)[(b) / BITS_PER_LONG_] >> ((b) % BITS_PER_LONG_)) & 1UL)

struct kbd_dev
{
  int fd;
  dev_t rdev;
  bool grabbed;
};

static struct
{
  bool running;
  struct kbd_dev dev[KBD_MAX];
  int n;
  gint64 last_scan;
  bool want_grab;
  struct xkb_context *ctx;
  struct xkb_keymap *keymap;
  struct xkb_state *state;
} kbd;

/* A keyboard has letters, space and return; power buttons, volume rockers
   and controller "keys" do not.  */
static bool
is_keyboard (int fd)
{
  unsigned long bits[NLONGS (KEY_CNT)];

  memset (bits, 0, sizeof bits);
  if (ioctl (fd, KBD_EVIOCGBIT (EV_KEY, sizeof bits), bits) < 0)
    return false;
  return TEST_BIT (KEY_A, bits) && TEST_BIT (KEY_Z, bits)
         && TEST_BIT (KEY_SPACE, bits) && TEST_BIT (KEY_ENTER, bits);
}

static bool
known (dev_t rdev)
{
  int i;

  for (i = 0; i < kbd.n; i++)
    if (kbd.dev[i].rdev == rdev)
      return true;
  return false;
}

static void
set_grab (struct kbd_dev *d, bool on)
{
  if (d->grabbed == on)
    return;
  if (ioctl (d->fd, KBD_EVIOCGRAB, on ? 1 : 0) == 0)
    d->grabbed = on;
}

static void
drop (int i)
{
  delete_keyboard_wait_descriptor (kbd.dev[i].fd);
  set_grab (&kbd.dev[i], false);
  close (kbd.dev[i].fd);
  kbd.dev[i] = kbd.dev[--kbd.n];
}

static void
scan (void)
{
  g_autoptr (GDir) dir = g_dir_open ("/dev/input", 0, NULL);
  const gchar *name;

  kbd.last_scan = g_get_monotonic_time ();
  if (dir == NULL)
    return;
  while (kbd.n < KBD_MAX && (name = g_dir_read_name (dir)) != NULL)
    {
      g_autofree gchar *path = NULL;
      struct stat st;
      int fd;

      if (!g_str_has_prefix (name, "event"))
        continue;
      path = g_build_filename ("/dev/input", name, NULL);
      if (stat (path, &st) != 0 || known (st.st_rdev))
        continue;
      fd = open (path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
      if (fd < 0)
        continue;
      if (!is_keyboard (fd))
        {
          close (fd);
          continue;
        }
      kbd.dev[kbd.n].fd = fd;
      kbd.dev[kbd.n].rdev = st.st_rdev;
      kbd.dev[kbd.n].grabbed = false;
      set_grab (&kbd.dev[kbd.n], kbd.want_grab);
      add_keyboard_wait_descriptor (fd);
      kbd.n++;
    }
}

void
cmacs_lrgvr_kbd_start (void)
{
  struct xkb_rule_names names;

  if (kbd.running)
    return;
  kbd.ctx = xkb_context_new (XKB_CONTEXT_NO_FLAGS);
  if (kbd.ctx == NULL)
    return;
  /* NULL fields take XKB_DEFAULT_RULES/MODEL/LAYOUT/VARIANT/OPTIONS from
     the environment, then the system default (us).  */
  memset (&names, 0, sizeof names);
  kbd.keymap = xkb_keymap_new_from_names (kbd.ctx, &names,
                                          XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (kbd.keymap == NULL)
    {
      xkb_context_unref (kbd.ctx);
      kbd.ctx = NULL;
      return;
    }
  kbd.state = xkb_state_new (kbd.keymap);
  kbd.running = true;
  kbd.n = 0;
  scan ();
}

void
cmacs_lrgvr_kbd_stop (void)
{
  if (!kbd.running)
    return;
  while (kbd.n > 0)
    drop (kbd.n - 1);
  xkb_state_unref (kbd.state);
  xkb_keymap_unref (kbd.keymap);
  xkb_context_unref (kbd.ctx);
  kbd.state = NULL;
  kbd.keymap = NULL;
  kbd.ctx = NULL;
  kbd.running = false;
}

int
cmacs_lrgvr_kbd_count (void)
{
  return kbd.running ? kbd.n : 0;
}

/* Grab the keyboards while VR has focus, release them otherwise.  */
void
cmacs_lrgvr_kbd_set_grab (bool on)
{
  int i;

  kbd.want_grab = on;
  for (i = 0; i < kbd.n; i++)
    set_grab (&kbd.dev[i], on);
}

static bool
mod_active (const char *name)
{
  return xkb_state_mod_name_is_active (kbd.state, name,
                                       XKB_STATE_MODS_EFFECTIVE) > 0;
}

/* Keysyms Emacs gets as function keys (NON_ASCII_KEYSTROKE_EVENT) rather
   than characters: everything in the 0xff00 block -- Return, Tab,
   BackSpace, Escape, arrows, Home/End, F-keys, keypad -- and the
   XF86 media keys.  */
static bool
function_keysym (xkb_keysym_t sym)
{
  return (sym >= 0xff00 && sym <= 0xffff) || (sym >= 0x1008ff00 && sym <= 0x1008ffff);
}

static bool
modifier_keysym (xkb_keysym_t sym)
{
  return (sym >= XKB_KEY_Shift_L && sym <= XKB_KEY_Hyper_R)
         || sym == XKB_KEY_ISO_Level3_Shift || sym == XKB_KEY_Mode_switch
         || sym == XKB_KEY_Num_Lock || sym == XKB_KEY_Caps_Lock;
}

static int
emit_key (struct frame *f, struct input_event *hold_quit, xkb_keycode_t code)
{
  xkb_keysym_t sym = xkb_state_key_get_one_sym (kbd.state, code);
  bool ctrl = mod_active (XKB_MOD_NAME_CTRL);
  bool alt = mod_active (XKB_MOD_NAME_ALT);
  bool super = mod_active (XKB_MOD_NAME_LOGO);
  bool shift = mod_active (XKB_MOD_NAME_SHIFT);
  int mods = (ctrl ? ctrl_modifier : 0) | (alt ? meta_modifier : 0)
             | (super ? super_modifier : 0);
  struct input_event ie;
  uint32_t cp;

  if (sym == XKB_KEY_NoSymbol || modifier_keysym (sym))
    return 0;

  EVENT_INIT (ie);
  ie.timestamp = cmacs_lrgterm_now_ms ();

  if (function_keysym (sym))
    {
      ie.kind = NON_ASCII_KEYSTROKE_EVENT;
      ie.code = sym;
      ie.modifiers = mods | (shift ? shift_modifier : 0);
      return cmacs_lrgterm_store_event (f, hold_quit, &ie);
    }

  /* With Ctrl/Meta/Super, xkb's text for the key is a control code (or
     nothing); Emacs wants the plain character plus modifier bits, the way
     lrgterm builds them from GLFW: C-A is C-a.  */
  cp = (mods != 0) ? xkb_keysym_to_utf32 (sym)
                   : xkb_state_key_get_utf32 (kbd.state, code);
  if (cp == 0)
    return 0;
  if ((mods & ctrl_modifier) && cp >= 'A' && cp <= 'Z')
    cp += 'a' - 'A';
  ie.kind = cp < 128 ? ASCII_KEYSTROKE_EVENT : MULTIBYTE_CHAR_KEYSTROKE_EVENT;
  ie.code = cp;
  ie.modifiers = mods;
  return cmacs_lrgterm_store_event (f, hold_quit, &ie);
}

/* Drain every keyboard; store a key event per press and auto-repeat.
   Called on each read_socket wakeup while VR is active.  */
int
cmacs_lrgvr_kbd_read (struct frame *f, struct input_event *hold_quit)
{
  int count = 0, i;

  if (!kbd.running)
    return 0;
  if (g_get_monotonic_time () - kbd.last_scan > KBD_RESCAN_US)
    scan ();

  for (i = kbd.n - 1; i >= 0; i--)
    {
      ssize_t n;

      for (;;)
        {
          struct kernel_input_event ev[64];
          ssize_t k;

          n = read (kbd.dev[i].fd, ev, sizeof ev);
          if (n < 0 && errno == EINTR)
            continue;
          if (n <= 0)
            break;
          for (k = 0; k < n / (ssize_t) sizeof ev[0]; k++)
            {
              xkb_keycode_t code;

              if (ev[k].type != EV_KEY)
                continue;
              code = ev[k].code + 8;   /* evdev -> xkb keycode */
              if (ev[k].value == 1 || ev[k].value == 2)
                count += emit_key (f, hold_quit, code);
              /* Presses and releases move the modifier state; repeats do
                 not.  Update after emitting, so the key sees the state it
                 was pressed in.  */
              if (ev[k].value == 1)
                xkb_state_update_key (kbd.state, code, XKB_KEY_DOWN);
              else if (ev[k].value == 0)
                xkb_state_update_key (kbd.state, code, XKB_KEY_UP);
            }
        }
      /* A device that went away (Bluetooth keyboard switched off). */
      if (n < 0 && errno == ENODEV)
        drop (i);
    }
  return count;
}

#endif /* HAVE_CMACS_LRGVR */
