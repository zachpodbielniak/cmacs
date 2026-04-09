/* org-ex-widget-web.c — WebKit widget implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget-web.h"
#include "../interfaces/org-ex-exportable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-widget-web
 * @title: OrgExWidgetWeb
 * @short_description: Embeds WebKit web content in org documents
 *
 * #OrgExWidgetWeb uses the Emacs xwidget system (make-xwidget 'webkit)
 * to embed live web content.  It can load a URL or render inline HTML.
 */

struct _OrgExWidgetWeb
{
  OrgExWidget parent_instance;
  gchar      *url;
  gchar      *html;
};

enum
{
  WEB_PROP_0,
  WEB_PROP_URL,
  WEB_PROP_HTML,
  WEB_N_PROPERTIES
};

static GParamSpec *web_properties[WEB_N_PROPERTIES] = { NULL, };

/* ---- OrgExExportable interface ---- */

static gchar *
org_ex_widget_web_export_html (OrgExExportable *exportable,
                               GError         **error)
{
  OrgExWidgetWeb *self = ORG_EX_WIDGET_WEB (exportable);
  gint width, height;

  (void) error;
  org_ex_widget_get_size (ORG_EX_WIDGET (self), &width, &height);

  if (self->url != NULL)
    return g_strdup_printf ("<iframe src=\"%s\" width=\"%d\" height=\"%d\""
                            " style=\"border:1px solid #ccc;\"></iframe>",
                            self->url, width, height);
  if (self->html != NULL)
    return g_strdup_printf ("<div class=\"org-ex-web\" "
                            "style=\"width:%dpx;height:%dpx;\">"
                            "%s</div>",
                            width, height, self->html);

  return g_strdup ("<div class=\"org-ex-web\">[Web Widget]</div>");
}

static gchar *
org_ex_widget_web_export_text (OrgExExportable *exportable,
                               GError         **error)
{
  OrgExWidgetWeb *self = ORG_EX_WIDGET_WEB (exportable);

  (void) error;

  if (self->url != NULL)
    return g_strdup_printf ("[Web: %s]", self->url);

  return g_strdup ("[Web Widget]");
}

static void
org_ex_widget_web_exportable_init (OrgExExportableInterface *iface)
{
  iface->export_html = org_ex_widget_web_export_html;
  iface->export_text = org_ex_widget_web_export_text;
}

G_DEFINE_FINAL_TYPE_WITH_CODE (
  OrgExWidgetWeb, org_ex_widget_web, ORG_EX_TYPE_WIDGET,
  G_IMPLEMENT_INTERFACE (ORG_EX_TYPE_EXPORTABLE,
                         org_ex_widget_web_exportable_init))

/* ---- GObject property accessors ---- */

static void
org_ex_widget_web_get_property (GObject    *object,
                                guint       prop_id,
                                GValue     *value,
                                GParamSpec *pspec)
{
  OrgExWidgetWeb *self = ORG_EX_WIDGET_WEB (object);

  switch (prop_id)
    {
    case WEB_PROP_URL:
      g_value_set_string (value, self->url);
      break;
    case WEB_PROP_HTML:
      g_value_set_string (value, self->html);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_web_set_property (GObject      *object,
                                guint         prop_id,
                                const GValue *value,
                                GParamSpec   *pspec)
{
  OrgExWidgetWeb *self = ORG_EX_WIDGET_WEB (object);

  switch (prop_id)
    {
    case WEB_PROP_URL:
      g_free (self->url);
      self->url = g_value_dup_string (value);
      break;
    case WEB_PROP_HTML:
      g_free (self->html);
      self->html = g_value_dup_string (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_web_finalize (GObject *object)
{
  OrgExWidgetWeb *self = ORG_EX_WIDGET_WEB (object);

  g_free (self->url);
  g_free (self->html);

  G_OBJECT_CLASS (org_ex_widget_web_parent_class)->finalize (object);
}

static void
org_ex_widget_web_class_init (OrgExWidgetWebClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_widget_web_get_property;
  object_class->set_property = org_ex_widget_web_set_property;
  object_class->finalize = org_ex_widget_web_finalize;

  web_properties[WEB_PROP_URL] =
    g_param_spec_string ("url", "URL", "URL to load",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT
                         | G_PARAM_STATIC_STRINGS);

  web_properties[WEB_PROP_HTML] =
    g_param_spec_string ("html", "HTML", "Inline HTML content",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT
                         | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, WEB_N_PROPERTIES,
                                     web_properties);
}

static void
org_ex_widget_web_init (OrgExWidgetWeb *self)
{
  self->url = NULL;
  self->html = NULL;
}

/* ---- Public API ---- */

OrgExWidgetWeb *
org_ex_widget_web_new (const gchar *url,
                       gint         width,
                       gint         height)
{
  return g_object_new (ORG_EX_TYPE_WIDGET_WEB,
                       "widget-type", ORG_EX_WIDGET_TYPE_WEB,
                       "url", url,
                       "width", width,
                       "height", height,
                       NULL);
}

OrgExWidgetWeb *
org_ex_widget_web_new_from_html (const gchar *html,
                                  gint         width,
                                  gint         height)
{
  return g_object_new (ORG_EX_TYPE_WIDGET_WEB,
                       "widget-type", ORG_EX_WIDGET_TYPE_WEB,
                       "html", html,
                       "width", width,
                       "height", height,
                       NULL);
}

const gchar *
org_ex_widget_web_get_url (OrgExWidgetWeb *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_WEB (self), NULL);
  return self->url;
}

const gchar *
org_ex_widget_web_get_html (OrgExWidgetWeb *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_WEB (self), NULL);
  return self->html;
}
