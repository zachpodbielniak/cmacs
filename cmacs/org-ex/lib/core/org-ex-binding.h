/* org-ex-binding.h — Reactive property binding
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_BINDING_H
#define ORG_EX_BINDING_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"
#include "org-ex-document.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_BINDING (org_ex_binding_get_type ())

G_DECLARE_FINAL_TYPE (OrgExBinding, org_ex_binding,
                      ORG_EX, BINDING, GObject)

/**
 * org_ex_binding_new:
 * @document: the #OrgExDocument
 * @property_name: org property name to bind
 * @widget: the widget to bind
 * @direction: binding direction
 *
 * Create a reactive binding between an org property and a widget.
 *
 * Returns: (transfer full): a new #OrgExBinding
 */
OrgExBinding *org_ex_binding_new (OrgExDocument        *document,
                                   const gchar          *property_name,
                                   OrgExWidget          *widget,
                                   OrgExBindingDirection direction);

const gchar          *org_ex_binding_get_property_name (OrgExBinding *self);
OrgExWidget          *org_ex_binding_get_widget        (OrgExBinding *self);
OrgExBindingDirection org_ex_binding_get_direction     (OrgExBinding *self);

/**
 * org_ex_binding_unbind:
 * @self: a #OrgExBinding
 *
 * Disconnect the binding.  After this call the binding is inert.
 */
void org_ex_binding_unbind (OrgExBinding *self);

G_END_DECLS

#endif /* ORG_EX_BINDING_H */
