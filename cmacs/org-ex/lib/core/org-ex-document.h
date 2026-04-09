/* org-ex-document.h — Document-level widget manager
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_DOCUMENT_H
#define ORG_EX_DOCUMENT_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_DOCUMENT (org_ex_document_get_type ())

G_DECLARE_FINAL_TYPE (OrgExDocument, org_ex_document,
                      ORG_EX, DOCUMENT, GObject)

/**
 * org_ex_document_new:
 * @file_path: (nullable): path to the org file
 *
 * Create a new document manager for an org-ex enabled buffer.
 *
 * Returns: (transfer full): a new #OrgExDocument
 */
OrgExDocument *org_ex_document_new (const gchar *file_path);

/**
 * org_ex_document_register_widget:
 * @self: a #OrgExDocument
 * @id: unique widget ID
 * @widget: (transfer none): the widget to register
 *
 * Register a widget with this document.  Emits ::widget-added.
 */
void org_ex_document_register_widget (OrgExDocument *self,
                                      const gchar   *id,
                                      OrgExWidget   *widget);

/**
 * org_ex_document_get_widget:
 * @self: a #OrgExDocument
 * @id: widget ID
 *
 * Returns: (transfer none) (nullable): the widget, or %NULL
 */
OrgExWidget *org_ex_document_get_widget (OrgExDocument *self,
                                          const gchar   *id);

/**
 * org_ex_document_remove_widget:
 * @self: a #OrgExDocument
 * @id: widget ID to remove
 *
 * Remove and teardown a widget.  Emits ::widget-removed.
 */
void org_ex_document_remove_widget (OrgExDocument *self,
                                    const gchar   *id);

/**
 * org_ex_document_list_widget_ids:
 * @self: a #OrgExDocument
 *
 * Returns: (transfer full) (element-type utf8): list of widget IDs
 */
GList *org_ex_document_list_widget_ids (OrgExDocument *self);

guint org_ex_document_get_widget_count (OrgExDocument *self);

/**
 * org_ex_document_notify_property_changed:
 * @self: a #OrgExDocument
 * @name: property name
 * @value: new value as string
 *
 * Notify all bound widgets that an org property changed.
 */
void org_ex_document_notify_property_changed (OrgExDocument *self,
                                               const gchar   *name,
                                               const gchar   *value);

/**
 * org_ex_document_teardown_all:
 * @self: a #OrgExDocument
 *
 * Teardown and remove all widgets.
 */
void org_ex_document_teardown_all (OrgExDocument *self);

G_END_DECLS

#endif /* ORG_EX_DOCUMENT_H */
