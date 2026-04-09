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

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_H */
