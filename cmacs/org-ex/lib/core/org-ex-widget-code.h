/* org-ex-widget-code.h — Code evaluation widget for org-ex
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_CODE_H
#define ORG_EX_WIDGET_CODE_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET_CODE (org_ex_widget_code_get_type ())

G_DECLARE_FINAL_TYPE (OrgExWidgetCode, org_ex_widget_code,
                      ORG_EX, WIDGET_CODE, OrgExWidget)

/**
 * org_ex_widget_code_new:
 * @language: code language ("elisp", "crispy", or "bacon")
 * @code: the source code to evaluate
 *
 * Create a code widget.  When rendered, the code is evaluated and
 * the resulting widget (if any) is displayed in its place.
 *
 * Returns: (transfer full): a new #OrgExWidgetCode
 */
OrgExWidgetCode *org_ex_widget_code_new (const gchar *language,
                                          const gchar *code);

const gchar *org_ex_widget_code_get_language (OrgExWidgetCode *self);
const gchar *org_ex_widget_code_get_code     (OrgExWidgetCode *self);

/**
 * org_ex_widget_code_set_result:
 * @self: a #OrgExWidgetCode
 * @result: (nullable) (transfer none): the result widget from evaluation
 *
 * Set the result widget produced by evaluating the code block.
 * This is typically called by the Elisp evaluation dispatch.
 */
void org_ex_widget_code_set_result (OrgExWidgetCode *self,
                                    OrgExWidget     *result);

/**
 * org_ex_widget_code_get_result:
 * @self: a #OrgExWidgetCode
 *
 * Returns: (transfer none) (nullable): the result widget, or %NULL
 */
OrgExWidget *org_ex_widget_code_get_result (OrgExWidgetCode *self);

G_END_DECLS

#endif /* ORG_EX_WIDGET_CODE_H */
