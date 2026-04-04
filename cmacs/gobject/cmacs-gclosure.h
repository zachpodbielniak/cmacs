/* cmacs-gclosure.h — GClosure ↔ elisp function bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Wraps elisp functions as GClosures so they can be passed to any
 * GLib API expecting a callback.  The closure invokes funcall on the
 * elisp function when fired.
 */

#ifndef CMACS_GCLOSURE_H
#define CMACS_GCLOSURE_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include <glib-object.h>
#include "lisp.h"

/* Create a GClosure that calls FUNC when invoked.
 * The closure invokes funcall(func, marshaled-args...) on the Emacs
 * main thread.  If fired from a GLib worker thread, the call is
 * proxied to the main GMainContext via g_main_context_invoke(). */
extern GClosure *cmacs_gclosure_new (Lisp_Object func);

/* Connect an elisp function as a signal handler.
 * Returns the GSignal handler ID. */
extern gulong cmacs_gclosure_connect (GObject *obj, const gchar *signal,
                                      Lisp_Object func);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_GCLOSURE_H */
