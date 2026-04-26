/* org-ex-enums.c — GType registrations for org-ex enumerations
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-types.h"

G_DEFINE_QUARK (org-ex-error-quark, org_ex_error)

GType
org_ex_widget_type_get_type (void)
{
  static volatile gsize g_type_id = 0;

  if (g_once_init_enter (&g_type_id))
    {
      static const GEnumValue values[] = {
        { ORG_EX_WIDGET_TYPE_GTK, "ORG_EX_WIDGET_TYPE_GTK", "gtk" },
        { ORG_EX_WIDGET_TYPE_WEB, "ORG_EX_WIDGET_TYPE_WEB", "web" },
        { ORG_EX_WIDGET_TYPE_BUFFER, "ORG_EX_WIDGET_TYPE_BUFFER", "buffer" },
        { ORG_EX_WIDGET_TYPE_CODE, "ORG_EX_WIDGET_TYPE_CODE", "code" },
        { ORG_EX_WIDGET_TYPE_INK,  "ORG_EX_WIDGET_TYPE_INK",  "ink" },
        { 0, NULL, NULL }
      };
      GType type_id = g_enum_register_static ("OrgExWidgetType", values);
      g_once_init_leave (&g_type_id, type_id);
    }

  return (GType) g_type_id;
}

GType
org_ex_binding_direction_get_type (void)
{
  static volatile gsize g_type_id = 0;

  if (g_once_init_enter (&g_type_id))
    {
      static const GEnumValue values[] = {
        { ORG_EX_BINDING_BIDIRECTIONAL,
          "ORG_EX_BINDING_BIDIRECTIONAL", "bidirectional" },
        { ORG_EX_BINDING_TO_WIDGET,
          "ORG_EX_BINDING_TO_WIDGET", "to-widget" },
        { ORG_EX_BINDING_FROM_WIDGET,
          "ORG_EX_BINDING_FROM_WIDGET", "from-widget" },
        { 0, NULL, NULL }
      };
      GType type_id = g_enum_register_static ("OrgExBindingDirection",
                                              values);
      g_once_init_leave (&g_type_id, type_id);
    }

  return (GType) g_type_id;
}
