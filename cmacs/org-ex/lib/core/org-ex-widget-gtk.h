/* org-ex-widget-gtk.h — GTK widget wrapper for org-ex
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_GTK_H
#define ORG_EX_WIDGET_GTK_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET_GTK (org_ex_widget_gtk_get_type ())

G_DECLARE_FINAL_TYPE (OrgExWidgetGtk, org_ex_widget_gtk,
                      ORG_EX, WIDGET_GTK, OrgExWidget)

/**
 * org_ex_widget_gtk_new:
 * @gtk_widget: (transfer none): a GtkWidget to wrap
 *
 * Create a new #OrgExWidgetGtk wrapping @gtk_widget.  The widget
 * takes a reference on @gtk_widget.
 *
 * Returns: (transfer full): a new #OrgExWidgetGtk
 */
OrgExWidgetGtk *org_ex_widget_gtk_new (gpointer gtk_widget);

/**
 * org_ex_widget_gtk_get_gtk_widget:
 * @self: a #OrgExWidgetGtk
 *
 * Returns: (transfer none): the underlying GtkWidget pointer
 */
gpointer org_ex_widget_gtk_get_gtk_widget (OrgExWidgetGtk *self);

G_END_DECLS

#endif /* ORG_EX_WIDGET_GTK_H */
