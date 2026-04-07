/* org-ex-exportable.c — OrgExExportable interface implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-exportable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-exportable
 * @title: OrgExExportable
 * @short_description: Interface for exporting widgets to various formats
 *
 * #OrgExExportable allows widgets to produce output for org export
 * backends.  HTML export produces live interactive elements where
 * possible; text export produces descriptive fallbacks.
 */

G_DEFINE_INTERFACE (OrgExExportable, org_ex_exportable, G_TYPE_OBJECT)

static void
org_ex_exportable_default_init (OrgExExportableInterface *iface)
{
  (void) iface;
}

gchar *
org_ex_exportable_export_html (OrgExExportable *self,
                               GError         **error)
{
  OrgExExportableInterface *iface;

  g_return_val_if_fail (ORG_EX_IS_EXPORTABLE (self), NULL);

  iface = ORG_EX_EXPORTABLE_GET_IFACE (self);
  g_return_val_if_fail (iface->export_html != NULL, NULL);

  return iface->export_html (self, error);
}

gchar *
org_ex_exportable_export_text (OrgExExportable *self,
                               GError         **error)
{
  OrgExExportableInterface *iface;

  g_return_val_if_fail (ORG_EX_IS_EXPORTABLE (self), NULL);

  iface = ORG_EX_EXPORTABLE_GET_IFACE (self);
  g_return_val_if_fail (iface->export_text != NULL, NULL);

  return iface->export_text (self, error);
}
