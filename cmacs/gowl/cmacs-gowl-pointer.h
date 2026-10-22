/* cmacs-gowl-pointer.h --- injected pointer input for the gowl desktop
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Moving, clicking and scrolling the compositor's pointer from cmacs:
 * the `gowl-pointer-*' DEFUNs, and the same calls from C for callers
 * that drive the pointer at frame rate (camera hands,
 * cmacs-handtrack-defuns.c) without going through Lisp per frame.
 *
 * Everything goes through gowl's injected-input path
 * (gowl_compositor_inject_*), which takes the same route as a physical
 * device: pointer constraints hold (a locked pointer stays put and the
 * client gets relative motion; a confined one slides along its region),
 * clicks go through the compositor's own hit test and focus rules, and
 * each call closes its own wl_pointer frame.  Scroll carries a discrete
 * value120, so a wheel source is honest.
 *
 * The C functions take the gowl lock themselves (it is recursive) and
 * never signal; the DEFUNs additionally hold it through the call with
 * cmacs_gowl_lock_scoped ().  Main thread only.  */

#ifndef CMACS_GOWL_POINTER_H
#define CMACS_GOWL_POINTER_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <stdbool.h>

/* evdev button codes (linux/input-event-codes.h).  */
#define CMACS_GOWL_BTN_LEFT    0x110
#define CMACS_GOWL_BTN_RIGHT   0x111
#define CMACS_GOWL_BTN_MIDDLE  0x112
#define CMACS_GOWL_BTN_BACK    0x113
#define CMACS_GOWL_BTN_FORWARD 0x114

/* Surface units one wheel notch scrolls, as libinput reports a click.  */
#define CMACS_GOWL_SCROLL_PER_NOTCH 15.0

enum cmacs_gowl_pointer_status
{
  CMACS_GOWL_POINTER_OK,
  CMACS_GOWL_POINTER_NOT_RUNNING,
  /* The session is locked: only the lock screen gets input, and only
     from real devices.  A release is still delivered, so a button held
     when the lock came up is not left down.  */
  CMACS_GOWL_POINTER_LOCKED
};

extern enum cmacs_gowl_pointer_status cmacs_gowl_pointer_warp (double x,
                                                               double y);
extern enum cmacs_gowl_pointer_status cmacs_gowl_pointer_move (double dx,
                                                               double dy);
extern enum cmacs_gowl_pointer_status
  cmacs_gowl_pointer_button (unsigned int button, bool pressed);
extern enum cmacs_gowl_pointer_status
  cmacs_gowl_pointer_scroll (bool horizontal, double notches);
extern bool cmacs_gowl_pointer_position (double *x, double *y);
/* NAME's layout geometry; NULL: the output under the pointer, else the
   first.  */
extern bool cmacs_gowl_output_geometry (const char *name, int *x, int *y,
                                        int *w, int *h);

extern void syms_of_cmacs_gowl_pointer (void);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_POINTER_H */
