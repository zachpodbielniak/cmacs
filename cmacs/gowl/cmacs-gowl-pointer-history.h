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

/* Stop sampling and empty the ring.  For
   cmacs_gowl_forget_compositor_state: the timer is an event source on
   the compositor's event loop, so it has to come off while that loop is
   still alive, and the samples name clients of a compositor that is
   about to be gone.  Takes the gowl lock itself.  */
extern void cmacs_gowl_pointer_history_forget (void);

extern void syms_of_cmacs_gowl_pointer_history (void);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_POINTER_HISTORY_H */
