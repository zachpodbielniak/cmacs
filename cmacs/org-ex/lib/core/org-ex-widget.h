/* org-ex-widget.h — Abstract base class for all org-ex widgets
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_H
#define ORG_EX_WIDGET_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "../org-ex-types.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET (org_ex_widget_get_type ())

G_DECLARE_DERIVABLE_TYPE (OrgExWidget, org_ex_widget,
                          ORG_EX, WIDGET, GObject)

/**
 * OrgExWidgetClass:
 * @parent_class: the parent class
 * @render: render the widget to a display target
 * @update: update widget state from properties
 * @teardown: release display resources
 * @save_state: serialize ephemeral state for persistence
 * @restore_state: restore ephemeral state from saved data
 * @padding: reserved for future virtual methods
 *
 * The class structure for #OrgExWidget.  Subclasses override the
 * virtual methods to implement widget-specific behavior.
 */
struct _OrgExWidgetClass
{
  GObjectClass parent_class;

  /* virtual methods */
  gpointer           (*render)        (OrgExWidget      *self,
                                       gpointer          display_context,
                                       GError          **error);
  void               (*update)        (OrgExWidget      *self);
  void               (*teardown)      (OrgExWidget      *self);
  OrgExWidgetState * (*save_state)    (OrgExWidget      *self);
  gboolean           (*restore_state) (OrgExWidget      *self,
                                       OrgExWidgetState *state,
                                       GError          **error);

  /*< private >*/
  gpointer padding[8];
};

/* ---- Construction ---- */

/**
 * org_ex_widget_get_id:
 * @self: a #OrgExWidget
 *
 * Returns: (transfer none): the widget's unique ID string
 */
const gchar *org_ex_widget_get_id (OrgExWidget *self);

/**
 * org_ex_widget_set_id:
 * @self: a #OrgExWidget
 * @id: the unique ID to assign
 *
 * Set the widget's unique ID.  Must be set before rendering.
 */
void org_ex_widget_set_id (OrgExWidget *self,
                           const gchar *id);

/**
 * org_ex_widget_get_widget_type:
 * @self: a #OrgExWidget
 *
 * Returns: the #OrgExWidgetType of this widget
 */
OrgExWidgetType org_ex_widget_get_widget_type (OrgExWidget *self);

/* ---- Dimensions ---- */

void org_ex_widget_get_size (OrgExWidget *self,
                             gint        *width,
                             gint        *height);

void org_ex_widget_set_size (OrgExWidget *self,
                             gint         width,
                             gint         height);

/* ---- Visibility ---- */

gboolean org_ex_widget_get_visible (OrgExWidget *self);
void     org_ex_widget_set_visible (OrgExWidget *self,
                                    gboolean     visible);

/* ---- Virtual method dispatchers ---- */

/**
 * org_ex_widget_render:
 * @self: a #OrgExWidget
 * @display_context: opaque display context
 * @error: return location for a #GError, or %NULL
 *
 * Render the widget.  Dispatches to the subclass implementation.
 *
 * Returns: (transfer none) (nullable): display handle, or %NULL
 */
gpointer org_ex_widget_render (OrgExWidget *self,
                               gpointer     display_context,
                               GError     **error);

void org_ex_widget_update (OrgExWidget *self);
void org_ex_widget_teardown (OrgExWidget *self);

/**
 * org_ex_widget_save_state:
 * @self: a #OrgExWidget
 *
 * Returns: (transfer full) (nullable): saved state, or %NULL
 */
OrgExWidgetState *org_ex_widget_save_state (OrgExWidget *self);

gboolean org_ex_widget_restore_state (OrgExWidget      *self,
                                      OrgExWidgetState *state,
                                      GError          **error);

G_END_DECLS

#endif /* ORG_EX_WIDGET_H */
