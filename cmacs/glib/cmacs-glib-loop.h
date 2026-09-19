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
#include <stdbool.h>

/* Call before pselect(): query GMainContext for fds and adjust timeout.
 * Adds GLib's file descriptors to READABLE and WRITEABLE, and reduces
 * *TIMEOUT if GLib needs an earlier wake-up.
 * Returns the highest fd added by GLib, or -1 if none were added.
 */
extern int cmacs_glib_prepare (fd_set *readable, fd_set *writeable,
                               struct timespec *timeout);

/* True when the last cmacs_glib_prepare added an fd to WRITEABLE, so
 * the caller must hand that set to pselect even on a round it has no
 * connecting process of its own to watch. */
extern bool cmacs_glib_wants_write (void);

/* Call after pselect(): dispatch any ready GLib sources.
 * NFDS is the return value from pselect; if < 0, releases the context
 * without dispatching.  WRITEABLE is the set pselect filled, or NULL
 * when none was passed (then G_IO_OUT readiness is simply unknown). */
extern void cmacs_glib_dispatch (fd_set *readable, fd_set *writeable,
                                 int nfds);

/* Return the CMacs-owned GMainContext. */
extern GMainContext *cmacs_glib_get_context (void);

/* True on the thread that runs the Lisp VM.
 *
 * THE LISP VM IS SINGLE-THREADED AND ITS STATE IS PROCESS-GLOBAL.
 * `specpdl' -- the unwind stack every `unbind_to' walks -- belongs to
 * `current_thread', and a pthread that Emacs did not create does not
 * have one: it mutates the MAIN thread's.  Two threads pushing and
 * popping the same specpdl is not a race that produces a wrong answer,
 * it is a race that produces a garbage function pointer, and the next
 * `do_one_unbind' calls it.  That is a SIGSEGV at an address like 0 or
 * 0x31, on whichever thread gets there first, with a backtrace that
 * names neither the writer nor anything to do with the cause.
 *
 * So: anything reached from a thread cmacs did not start must ask this
 * before touching Lisp -- including ALLOCATING a Lisp object, which is
 * as unsafe as calling one.  Before init_cmacs_glib() this is true,
 * which is correct: nothing else is running that early.  */
extern bool cmacs_glib_on_main_thread (void);

/* Run FUNC on the Lisp thread, soon, and return at once.
 *
 * Attached to the CMacs context rather than the default one, because
 * the CMacs context is pumped from Emacs's own pselect() and is
 * therefore alive in every kind of session; the default context is only
 * iterated when a toolkit happens to be doing it.
 *
 * DATA is handed to FUNC and then to NOTIFY.  FUNC must return
 * G_SOURCE_REMOVE.  */
extern void cmacs_glib_invoke_on_main (GSourceFunc    func,
                                       gpointer       data,
                                       GDestroyNotify notify);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_GLIB_LOOP_H */
