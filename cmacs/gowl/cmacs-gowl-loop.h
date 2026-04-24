/* cmacs-gowl-loop.h — GSource wrapper for the gowl wl_event_loop
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Derivable GObject that owns a GSource attached to the CMacs
 * GMainContext (see cmacs-glib-loop.c) and pumps the gowl
 * wl_event_loop on ready events.  Replaces the pthread-based
 * cmacs_gowl_dispatch_thread: the compositor and Emacs now share a
 * single thread, and the 52 sites of cmacs_gowl_mutex are gone.
 *
 * Exposed as a GObject so Elisp / cmacs-gi can observe tick counts,
 * connect before-dispatch/after-dispatch signals for profiling, and
 * subclass the source for priority-aware variants.
 */

#ifndef CMACS_GOWL_LOOP_H
#define CMACS_GOWL_LOOP_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <glib-object.h>

struct wl_display;
struct wl_event_loop;

G_BEGIN_DECLS

#define CMACS_TYPE_GOWL_LOOP_SOURCE (cmacs_gowl_loop_source_get_type())

G_DECLARE_DERIVABLE_TYPE(CmacsGowlLoopSource, cmacs_gowl_loop_source,
                          CMACS, GOWL_LOOP_SOURCE, GObject)

/**
 * CmacsGowlLoopSourceClass:
 * @parent_class: the parent class
 *
 * Derivable class.  Subclasses can override the two vfunc hooks to
 * customise per-tick behaviour without touching the GSource
 * plumbing.  The default implementation just emits signals and
 * bumps the tick counter.
 */
struct _CmacsGowlLoopSourceClass {
	GObjectClass parent_class;

	void (*before_dispatch) (CmacsGowlLoopSource *self);
	void (*after_dispatch)  (CmacsGowlLoopSource *self,
	                         guint                n_events);
};

/**
 * cmacs_gowl_loop_source_new:
 * @loop: the wl_event_loop to pump
 * @display: the wl_display whose clients are flushed after dispatch
 *
 * Allocates a new source wrapper.  Does not attach to a
 * #GMainContext yet — call #cmacs_gowl_loop_source_attach for that.
 *
 * Returns: (transfer full): a new #CmacsGowlLoopSource
 */
CmacsGowlLoopSource *
cmacs_gowl_loop_source_new(struct wl_event_loop *loop,
                            struct wl_display    *display);

/**
 * cmacs_gowl_loop_source_attach:
 * @self: a #CmacsGowlLoopSource
 * @context: (nullable): the #GMainContext to attach to; %NULL means
 *   the CMacs-owned context from cmacs_glib_get_context()
 *
 * Attaches the underlying GSource so it starts being polled.  Safe
 * to call once per source; repeated calls are ignored.
 *
 * Returns: %TRUE on success, %FALSE if the source is already
 *          attached or @self is invalid.
 */
gboolean
cmacs_gowl_loop_source_attach(CmacsGowlLoopSource *self,
                               GMainContext        *context);

/**
 * cmacs_gowl_loop_source_detach:
 * @self: a #CmacsGowlLoopSource
 *
 * Removes the source from its #GMainContext (but retains the wrapper
 * object).  No-op if the source is not attached.
 */
void
cmacs_gowl_loop_source_detach(CmacsGowlLoopSource *self);

/**
 * cmacs_gowl_loop_source_is_attached:
 * @self: a #CmacsGowlLoopSource
 *
 * Returns: %TRUE if the source is currently attached to a context.
 */
gboolean
cmacs_gowl_loop_source_is_attached(CmacsGowlLoopSource *self);

/**
 * cmacs_gowl_loop_source_get_tick_count:
 * @self: a #CmacsGowlLoopSource
 *
 * Returns: number of dispatch ticks since creation (monotonic).
 */
guint64
cmacs_gowl_loop_source_get_tick_count(CmacsGowlLoopSource *self);

G_END_DECLS

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_LOOP_H */
