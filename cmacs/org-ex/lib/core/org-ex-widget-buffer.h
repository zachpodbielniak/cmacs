/* org-ex-widget-buffer.h — Embedded buffer widget for org-ex
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_BUFFER_H
#define ORG_EX_WIDGET_BUFFER_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET_BUFFER (org_ex_widget_buffer_get_type ())

G_DECLARE_FINAL_TYPE (OrgExWidgetBuffer, org_ex_widget_buffer,
                      ORG_EX, WIDGET_BUFFER, OrgExWidget)

/**
 * org_ex_widget_buffer_new:
 * @file: path to the file to embed
 * @editable: whether the embedded buffer allows editing
 *
 * Create a buffer embed widget that displays @file.
 *
 * Returns: (transfer full): a new #OrgExWidgetBuffer
 */
OrgExWidgetBuffer *org_ex_widget_buffer_new (const gchar *file,
                                              gboolean     editable);

const gchar *org_ex_widget_buffer_get_file     (OrgExWidgetBuffer *self);
const gchar *org_ex_widget_buffer_get_mode     (OrgExWidgetBuffer *self);
void         org_ex_widget_buffer_set_mode     (OrgExWidgetBuffer *self,
                                                 const gchar       *mode);
gboolean     org_ex_widget_buffer_get_editable (OrgExWidgetBuffer *self);
void         org_ex_widget_buffer_set_editable (OrgExWidgetBuffer *self,
                                                 gboolean           editable);

G_END_DECLS

#endif /* ORG_EX_WIDGET_BUFFER_H */
