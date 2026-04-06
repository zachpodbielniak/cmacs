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
                                       GtkWidget *view_widget);
extern void cmacs_gowl_xwidget_teardown (struct xwidget *xw);
extern gboolean cmacs_gowl_xwidget_draw_cb (GtkWidget *widget,
                                             cairo_t *cr,
                                             gpointer data);
extern gboolean cmacs_gowl_xwidget_event_cb (GtkWidget *widget,
                                              GdkEvent *event,
                                              gpointer data);

#endif /* HAVE_CMACS_GOWL */
#endif /* CMACS_GOWL_H */
