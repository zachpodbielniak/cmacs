/* org-ex-widget-code.c — Code evaluation widget implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget-code.h"
#include "../interfaces/org-ex-exportable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-widget-code
 * @title: OrgExWidgetCode
 * @short_description: Evaluates code blocks and displays the result widget
 *
 * #OrgExWidgetCode evaluates a block of Elisp, Crispy C, or Bacon
 * shell code.  The evaluation is expected to produce an #OrgExWidget
 * (or a GtkWidget that gets auto-wrapped) which is then displayed
 * in the code block's position.
 */

struct _OrgExWidgetCode
{
  OrgExWidget  parent_instance;
  gchar       *language;
  gchar       *code;
  OrgExWidget *result;
};

enum
{
  CODE_PROP_0,
  CODE_PROP_LANGUAGE,
  CODE_PROP_CODE,
  CODE_N_PROPERTIES
};

static GParamSpec *code_properties[CODE_N_PROPERTIES] = { NULL, };

enum
{
  CODE_SIGNAL_EVALUATED,
  CODE_N_SIGNALS
};

static guint code_signals[CODE_N_SIGNALS] = { 0, };

/* ---- OrgExExportable interface ---- */

static gchar *
org_ex_widget_code_export_html (OrgExExportable *exportable,
                                GError         **error)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (exportable);

  /* If we have a result widget that is exportable, delegate */
  if (self->result != NULL
      && ORG_EX_IS_EXPORTABLE (self->result))
    return org_ex_exportable_export_html (
             ORG_EX_EXPORTABLE (self->result), error);

  return g_strdup_printf ("<pre class=\"org-ex-code\">"
                          "<code class=\"%s\">%s</code></pre>",
                          self->language ? self->language : "text",
                          self->code ? self->code : "");
}

static gchar *
org_ex_widget_code_export_text (OrgExExportable *exportable,
                                GError         **error)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (exportable);

  if (self->result != NULL
      && ORG_EX_IS_EXPORTABLE (self->result))
    return org_ex_exportable_export_text (
             ORG_EX_EXPORTABLE (self->result), error);

  return g_strdup_printf ("[Code: %s]",
                          self->language ? self->language : "unknown");
}

static void
org_ex_widget_code_exportable_init (OrgExExportableInterface *iface)
{
  iface->export_html = org_ex_widget_code_export_html;
  iface->export_text = org_ex_widget_code_export_text;
}

G_DEFINE_FINAL_TYPE_WITH_CODE (
  OrgExWidgetCode, org_ex_widget_code, ORG_EX_TYPE_WIDGET,
  G_IMPLEMENT_INTERFACE (ORG_EX_TYPE_EXPORTABLE,
                         org_ex_widget_code_exportable_init))

/* ---- GObject lifecycle ---- */

static void
org_ex_widget_code_get_property (GObject    *object,
                                 guint       prop_id,
                                 GValue     *value,
                                 GParamSpec *pspec)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (object);

  switch (prop_id)
    {
    case CODE_PROP_LANGUAGE:
      g_value_set_string (value, self->language);
      break;
    case CODE_PROP_CODE:
      g_value_set_string (value, self->code);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_code_set_property (GObject      *object,
                                 guint         prop_id,
                                 const GValue *value,
                                 GParamSpec   *pspec)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (object);

  switch (prop_id)
    {
    case CODE_PROP_LANGUAGE:
      g_free (self->language);
      self->language = g_value_dup_string (value);
      break;
    case CODE_PROP_CODE:
      g_free (self->code);
      self->code = g_value_dup_string (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_code_dispose (GObject *object)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (object);

  g_clear_object (&self->result);

  G_OBJECT_CLASS (org_ex_widget_code_parent_class)->dispose (object);
}

static void
org_ex_widget_code_finalize (GObject *object)
{
  OrgExWidgetCode *self = ORG_EX_WIDGET_CODE (object);

  g_free (self->language);
  g_free (self->code);

  G_OBJECT_CLASS (org_ex_widget_code_parent_class)->finalize (object);
}

static void
org_ex_widget_code_class_init (OrgExWidgetCodeClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_widget_code_get_property;
  object_class->set_property = org_ex_widget_code_set_property;
  object_class->dispose = org_ex_widget_code_dispose;
  object_class->finalize = org_ex_widget_code_finalize;

  code_properties[CODE_PROP_LANGUAGE] =
    g_param_spec_string ("language", "Language",
                         "Code language (elisp, crispy, bacon)",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
                         | G_PARAM_STATIC_STRINGS);

  code_properties[CODE_PROP_CODE] =
    g_param_spec_string ("code", "Code",
                         "Source code to evaluate",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
                         | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, CODE_N_PROPERTIES,
                                     code_properties);

  /**
   * OrgExWidgetCode::evaluated:
   * @widget: the #OrgExWidgetCode
   * @result: (nullable): the result #OrgExWidget
   *
   * Emitted after code evaluation completes.
   */
  code_signals[CODE_SIGNAL_EVALUATED] =
    g_signal_new ("evaluated",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 1,
                  ORG_EX_TYPE_WIDGET);
}

static void
org_ex_widget_code_init (OrgExWidgetCode *self)
{
  self->language = NULL;
  self->code = NULL;
  self->result = NULL;
}

/* ---- Public API ---- */

OrgExWidgetCode *
org_ex_widget_code_new (const gchar *language,
                         const gchar *code)
{
  return g_object_new (ORG_EX_TYPE_WIDGET_CODE,
                       "widget-type", ORG_EX_WIDGET_TYPE_CODE,
                       "language", language,
                       "code", code,
                       NULL);
}

const gchar *
org_ex_widget_code_get_language (OrgExWidgetCode *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_CODE (self), NULL);
  return self->language;
}

const gchar *
org_ex_widget_code_get_code (OrgExWidgetCode *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_CODE (self), NULL);
  return self->code;
}

void
org_ex_widget_code_set_result (OrgExWidgetCode *self,
                                OrgExWidget     *result)
{
  g_return_if_fail (ORG_EX_IS_WIDGET_CODE (self));

  if (self->result != result)
    {
      g_clear_object (&self->result);
      if (result != NULL)
        self->result = g_object_ref (result);
      g_signal_emit (self, code_signals[CODE_SIGNAL_EVALUATED], 0, result);
    }
}

OrgExWidget *
org_ex_widget_code_get_result (OrgExWidgetCode *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_CODE (self), NULL);
  return self->result;
}
