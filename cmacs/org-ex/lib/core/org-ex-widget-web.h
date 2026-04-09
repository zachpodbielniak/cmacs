/* org-ex-widget-web.h — WebKit widget for org-ex
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_WIDGET_WEB_H
#define ORG_EX_WIDGET_WEB_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>
#include "org-ex-widget.h"

G_BEGIN_DECLS

#define ORG_EX_TYPE_WIDGET_WEB (org_ex_widget_web_get_type ())

G_DECLARE_FINAL_TYPE (OrgExWidgetWeb, org_ex_widget_web,
                      ORG_EX, WIDGET_WEB, OrgExWidget)

/**
 * org_ex_widget_web_new:
 * @url: (nullable): URL to load
 * @width: widget width in pixels
 * @height: widget height in pixels
 *
 * Create a web widget that loads @url.
 *
 * Returns: (transfer full): a new #OrgExWidgetWeb
 */
OrgExWidgetWeb *org_ex_widget_web_new (const gchar *url,
                                       gint         width,
                                       gint         height);

/**
 * org_ex_widget_web_new_from_html:
 * @html: HTML content to render
 * @width: widget width in pixels
 * @height: widget height in pixels
 *
 * Create a web widget that renders inline HTML.
 *
 * Returns: (transfer full): a new #OrgExWidgetWeb
 */
OrgExWidgetWeb *org_ex_widget_web_new_from_html (const gchar *html,
                                                  gint         width,
                                                  gint         height);

const gchar *org_ex_widget_web_get_url  (OrgExWidgetWeb *self);
const gchar *org_ex_widget_web_get_html (OrgExWidgetWeb *self);

G_END_DECLS

#endif /* ORG_EX_WIDGET_WEB_H */
