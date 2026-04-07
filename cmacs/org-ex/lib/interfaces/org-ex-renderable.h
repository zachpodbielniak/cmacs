/* org-ex-renderable.h — Interface for rendering widgets to display
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_RENDERABLE_H
#define ORG_EX_RENDERABLE_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>

G_BEGIN_DECLS

#define ORG_EX_TYPE_RENDERABLE (org_ex_renderable_get_type ())

G_DECLARE_INTERFACE (OrgExRenderable, org_ex_renderable,
                     ORG_EX, RENDERABLE, GObject)

/**
 * OrgExRenderableInterface:
 * @parent_iface: the parent interface
 * @render: render the widget, returning an opaque handle for the
 *   display system (e.g. an xwidget ID or overlay reference)
 * @get_preferred_size: query the widget's preferred width and height
 *
 * The virtual function table for #OrgExRenderable.
 */
struct _OrgExRenderableInterface
{
  GTypeInterface parent_iface;

  /* virtual methods */
  gpointer (*render)             (OrgExRenderable *self,
                                  gpointer         display_context,
                                  GError         **error);
  void     (*get_preferred_size) (OrgExRenderable *self,
                                  gint            *width,
                                  gint            *height);
};

/**
 * org_ex_renderable_render:
 * @self: a #OrgExRenderable
 * @display_context: opaque display context (frame pointer, etc.)
 * @error: return location for a #GError, or %NULL
 *
 * Render the widget to the display.
 *
 * Returns: (transfer none) (nullable): opaque display handle,
 *   or %NULL on error
 */
gpointer org_ex_renderable_render (OrgExRenderable *self,
                                   gpointer         display_context,
                                   GError         **error);

/**
 * org_ex_renderable_get_preferred_size:
 * @self: a #OrgExRenderable
 * @width: (out): return location for preferred width
 * @height: (out): return location for preferred height
 *
 * Query the widget's preferred dimensions.
 */
void org_ex_renderable_get_preferred_size (OrgExRenderable *self,
                                           gint            *width,
                                           gint            *height);

G_END_DECLS

#endif /* ORG_EX_RENDERABLE_H */
