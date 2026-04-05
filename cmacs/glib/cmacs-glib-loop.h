/* cmacs-glib-loop.h — GLib event loop integration for Emacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Integrates GMainContext into the Emacs select()-based event loop.
 * GLib sources (D-Bus, GFileMonitor, GSocket, timers) fire naturally
 * within the Emacs event cycle — no threads, no races.
 */

#ifndef CMACS_GLIB_LOOP_H
#define CMACS_GLIB_LOOP_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include <glib.h>
#include <sys/select.h>

/* Call before pselect(): query GMainContext for fds and adjust timeout.
 * Adds GLib's file descriptors to READABLE and WRITEABLE, and reduces
 * *TIMEOUT if GLib needs an earlier wake-up.
 * Returns the highest fd added by GLib, or -1 if none were added.
 */
extern int cmacs_glib_prepare (fd_set *readable, fd_set *writeable,
                               struct timespec *timeout);

/* Call after pselect(): dispatch any ready GLib sources.
 * NFDS is the return value from pselect; if < 0, releases the context
 * without dispatching. */
extern void cmacs_glib_dispatch (fd_set *readable, int nfds);

/* Return the CMacs-owned GMainContext. */
extern GMainContext *cmacs_glib_get_context (void);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_GLIB_LOOP_H */
