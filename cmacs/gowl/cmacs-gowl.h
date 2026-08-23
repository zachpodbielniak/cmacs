/* cmacs-gowl.h — Gowl Wayland compositor integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds gowl (GObject Wayland compositor) into CMacs so that Emacs
 * itself becomes the Wayland window manager.
 */

#ifndef CMACS_GOWL_H
#define CMACS_GOWL_H

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <gowl.h>

/* Start the compositor dispatch thread. */
extern void cmacs_gowl_start_thread (void);

/* The running --gowl compositor, or NULL when gowl is not active.  Other
 * cmacs subsystems (e.g. cmacs-screensaver) use this to push raw frames into
 * the wallpaper / lock-screen sinks. */
extern GowlCompositor *cmacs_gowl_get_compositor (void);

/* Lock/unlock the compositor dispatch mutex.  Scene-graph mutations from a
 * thread other than the gowl dispatch thread (e.g. the screensaver frame
 * pump on the Emacs main thread) MUST be wrapped in these to avoid racing
 * the compositor's render/dispatch.  The lock is recursive. */
extern void cmacs_gowl_lock (void);
extern void cmacs_gowl_unlock (void);

/* Inhibit parent compositor keyboard shortcuts (nested mode). */
extern void cmacs_gowl_inhibit_parent_shortcuts (GowlCompositor *comp);

/* Xwidget integration callbacks — called from xwidget.c for gowl type. */
struct xwidget;
#include <gtk/gtk.h>
extern void cmacs_gowl_xwidget_setup (struct xwidget *xw,
                                       GtkWidget *view_widget,
                                       struct frame *frame);
extern void cmacs_gowl_xwidget_teardown (struct xwidget *xw);
extern gboolean cmacs_gowl_xwidget_draw_cb (GtkWidget *widget,
                                             cairo_t *cr,
                                             gpointer data);
extern gboolean cmacs_gowl_xwidget_event_cb (GtkWidget *widget,
                                              GdkEvent *event,
                                              gpointer data);

/* Focus helpers — called from the event forwarder in xwidget.c. */
extern void cmacs_gowl_xwidget_keyboard_enter (struct xwidget *xw);
extern void cmacs_gowl_xwidget_keyboard_leave (void);

/* Return the GtkWidget from an xwidget's gowl embed view, or NULL. */
extern GtkWidget *cmacs_gowl_xwidget_get_widget (struct xwidget *xw);

/* The two names a compiled C config expects to resolve against the
   embedding process: standalone gowl defines them in its main.c, cmacs
   defines them in cmacs-gowl.c.  Declared here rather than only defined
   there, so the definitions have a prototype.

   cmacs_gowl_compositor is deliberately NOT repeated here -- it is
   declared in cmacs-eval-dispatch.h, and a second declaration is a
   redundant redeclaration in every file that sees both. */
extern GowlCompositor *gowl_compositor;
extern GowlConfig     *gowl_config;

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_H */
