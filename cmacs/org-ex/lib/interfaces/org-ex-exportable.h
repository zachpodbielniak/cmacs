/* org-ex-exportable.h — Interface for exporting widgets
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_EXPORTABLE_H
#define ORG_EX_EXPORTABLE_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>

G_BEGIN_DECLS

#define ORG_EX_TYPE_EXPORTABLE (org_ex_exportable_get_type ())

G_DECLARE_INTERFACE (OrgExExportable, org_ex_exportable,
                     ORG_EX, EXPORTABLE, GObject)

/**
 * OrgExExportableInterface:
 * @parent_iface: the parent interface
 * @export_html: export widget as an HTML fragment
 * @export_text: export widget as a plain text description
 *
 * The virtual function table for #OrgExExportable.
 */
struct _OrgExExportableInterface
{
  GTypeInterface parent_iface;

  /* virtual methods */
  gchar * (*export_html) (OrgExExportable *self,
                          GError         **error);
  gchar * (*export_text) (OrgExExportable *self,
                          GError         **error);
};

/**
 * org_ex_exportable_export_html:
 * @self: a #OrgExExportable
 * @error: return location for a #GError, or %NULL
 *
 * Export the widget as an HTML fragment suitable for embedding in
 * an exported org document.
 *
 * Returns: (transfer full) (nullable): HTML string, or %NULL on error
 */
gchar *org_ex_exportable_export_html (OrgExExportable *self,
                                      GError         **error);

/**
 * org_ex_exportable_export_text:
 * @self: a #OrgExExportable
 * @error: return location for a #GError, or %NULL
 *
 * Export the widget as a plain text description for formats that
 * do not support interactive content.
 *
 * Returns: (transfer full) (nullable): text string, or %NULL on error
 */
gchar *org_ex_exportable_export_text (OrgExExportable *self,
                                      GError         **error);

G_END_DECLS

#endif /* ORG_EX_EXPORTABLE_H */
