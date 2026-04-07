/* org-ex-renderable.c — OrgExRenderable interface implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-renderable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-renderable
 * @title: OrgExRenderable
 * @short_description: Interface for rendering widgets to display
 *
 * #OrgExRenderable is a GInterface that widgets implement to provide
 * rendering capability.  The render method returns an opaque handle
 * that the Emacs display engine uses to place the widget in a buffer.
 */

G_DEFINE_INTERFACE (OrgExRenderable, org_ex_renderable, G_TYPE_OBJECT)

static void
org_ex_renderable_default_init (OrgExRenderableInterface *iface)
{
  (void) iface;
}

gpointer
org_ex_renderable_render (OrgExRenderable *self,
                          gpointer         display_context,
                          GError         **error)
{
  OrgExRenderableInterface *iface;

  g_return_val_if_fail (ORG_EX_IS_RENDERABLE (self), NULL);

  iface = ORG_EX_RENDERABLE_GET_IFACE (self);
  g_return_val_if_fail (iface->render != NULL, NULL);

  return iface->render (self, display_context, error);
}

void
org_ex_renderable_get_preferred_size (OrgExRenderable *self,
                                      gint            *width,
                                      gint            *height)
{
  OrgExRenderableInterface *iface;

  g_return_if_fail (ORG_EX_IS_RENDERABLE (self));

  iface = ORG_EX_RENDERABLE_GET_IFACE (self);
  if (iface->get_preferred_size != NULL)
    iface->get_preferred_size (self, width, height);
  else
    {
      if (width != NULL)
        *width = 400;
      if (height != NULL)
        *height = 200;
    }
}
