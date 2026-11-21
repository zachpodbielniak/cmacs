/* cmacs-gowl-bar-slots.h --- bar items Lisp creates and fills
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The primitives under `cmacs-gowl-bar-slot-set'
 * (lisp/cmacs/cmacs-gowl-bar-slots.el): create, fill, list and remove
 * gowl's bar slots -- bar items whose content is pushed from outside
 * (deps/gowl/docs/bar.org, "Slots").
 *
 * Each is one command to the bar module, sent the way every other bar
 * DEFUN sends one, under the gowl lock.  Nothing is kept here: the
 * slots live in the bar module, and the click handlers in Lisp, where
 * a click arrives on Emacs's thread as the compositor's `module-event'
 * (`cmacs-gowl-module-event-functions').  So there is no per-compositor
 * state in this file and nothing for
 * cmacs_gowl_forget_compositor_state to drop.  */

#ifndef CMACS_GOWL_BAR_SLOTS_H
#define CMACS_GOWL_BAR_SLOTS_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

extern void syms_of_cmacs_gowl_bar_slots (void);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_BAR_SLOTS_H */
