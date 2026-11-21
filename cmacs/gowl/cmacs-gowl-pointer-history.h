/* cmacs-gowl-pointer-history.h --- where the pointer was, a moment ago
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A short ring of pointer samples kept on the compositor side, so that
 * "what was the pointer over when the word THAT was spoken" has an
 * answer by the time the transcript arrives, a second or two later
 * (lisp/cmacs/cmacs-deixis.el).  Motion never reaches Lisp: the ring is
 * filled by a timer on gowl's own wl_event_loop and only read by the
 * `gowl-pointer-history-*' DEFUNs.  Off unless asked for, in memory
 * only, and emptied when it is turned off.  */

#ifndef CMACS_GOWL_POINTER_HISTORY_H
#define CMACS_GOWL_POINTER_HISTORY_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <stdbool.h>

/* Stop sampling and empty the ring.  For
   cmacs_gowl_forget_compositor_state: the timer is an event source on
   the compositor's event loop, so it has to come off while that loop is
   still alive, and the samples name clients of a compositor that is
   about to be gone.  Takes the gowl lock itself.  */
extern void cmacs_gowl_pointer_history_forget (void);

/* What a pointer at layout X, Y would be over, by the hit test the
   ring's own samples use: *CLIENT the gowl client id (0: none),
   *MONITOR the output's index in the monitor list (-1: off every
   output).  For pointing devices that keep a history of their own (a
   camera hand, cmacs-handtrack-point-history.c) and want it to name
   windows the way this one does.  Works whether or not the mouse ring
   is on.  Takes the gowl lock itself and never signals, so it may be
   called from a GLib dispatch on the main thread.  Returns false, with
   the outputs untouched, when no compositor runs or the session is
   locked.  */
extern bool cmacs_gowl_pointer_history_hit (double x, double y,
                                            unsigned int *client,
                                            int *monitor);

extern void syms_of_cmacs_gowl_pointer_history (void);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_POINTER_HISTORY_H */
