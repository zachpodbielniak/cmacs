/* org-ex-widget-buffer.c — Embedded buffer widget implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget-buffer.h"
#include "../interfaces/org-ex-exportable.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-widget-buffer
 * @title: OrgExWidgetBuffer
 * @short_description: Embeds an Emacs buffer as an iframe-like widget
 *
 * #OrgExWidgetBuffer displays another file or buffer inline within
 * an org document, scrollable and optionally editable.
 */

struct _OrgExWidgetBuffer
{
  OrgExWidget parent_instance;
  gchar      *file;
  gchar      *buffer_name;
  gchar      *mode;
  gboolean    editable;
};

enum
{
  BUF_PROP_0,
  BUF_PROP_FILE,
  BUF_PROP_BUFFER_NAME,
  BUF_PROP_MODE,
  BUF_PROP_EDITABLE,
  BUF_N_PROPERTIES
};

static GParamSpec *buf_properties[BUF_N_PROPERTIES] = { NULL, };

/* ---- OrgExExportable interface ---- */

static gchar *
org_ex_widget_buffer_export_html (OrgExExportable *exportable,
                                  GError         **error)
{
  OrgExWidgetBuffer *self = ORG_EX_WIDGET_BUFFER (exportable);

  (void) error;

  if (self->file != NULL)
    return g_strdup_printf ("<pre class=\"org-ex-buffer\">"
                            "/* Embedded: %s */</pre>",
                            self->file);

  return g_strdup ("<pre class=\"org-ex-buffer\">"
                   "[Embedded Buffer]</pre>");
}

static gchar *
org_ex_widget_buffer_export_text (OrgExExportable *exportable,
                                  GError         **error)
{
  OrgExWidgetBuffer *self = ORG_EX_WIDGET_BUFFER (exportable);

  (void) error;

  if (self->file != NULL)
    return g_strdup_printf ("[Buffer: %s]", self->file);

  return g_strdup ("[Embedded Buffer]");
}

static void
org_ex_widget_buffer_exportable_init (OrgExExportableInterface *iface)
{
  iface->export_html = org_ex_widget_buffer_export_html;
  iface->export_text = org_ex_widget_buffer_export_text;
}

G_DEFINE_FINAL_TYPE_WITH_CODE (
  OrgExWidgetBuffer, org_ex_widget_buffer, ORG_EX_TYPE_WIDGET,
  G_IMPLEMENT_INTERFACE (ORG_EX_TYPE_EXPORTABLE,
                         org_ex_widget_buffer_exportable_init))

/* ---- GObject property accessors ---- */

static void
org_ex_widget_buffer_get_property (GObject    *object,
                                   guint       prop_id,
                                   GValue     *value,
                                   GParamSpec *pspec)
{
  OrgExWidgetBuffer *self = ORG_EX_WIDGET_BUFFER (object);

  switch (prop_id)
    {
    case BUF_PROP_FILE:
      g_value_set_string (value, self->file);
      break;
    case BUF_PROP_BUFFER_NAME:
      g_value_set_string (value, self->buffer_name);
      break;
    case BUF_PROP_MODE:
      g_value_set_string (value, self->mode);
      break;
    case BUF_PROP_EDITABLE:
      g_value_set_boolean (value, self->editable);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_buffer_set_property (GObject      *object,
                                   guint         prop_id,
                                   const GValue *value,
                                   GParamSpec   *pspec)
{
  OrgExWidgetBuffer *self = ORG_EX_WIDGET_BUFFER (object);

  switch (prop_id)
    {
    case BUF_PROP_FILE:
      g_free (self->file);
      self->file = g_value_dup_string (value);
      break;
    case BUF_PROP_BUFFER_NAME:
      g_free (self->buffer_name);
      self->buffer_name = g_value_dup_string (value);
      break;
    case BUF_PROP_MODE:
      g_free (self->mode);
      self->mode = g_value_dup_string (value);
      break;
    case BUF_PROP_EDITABLE:
      self->editable = g_value_get_boolean (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_buffer_finalize (GObject *object)
{
  OrgExWidgetBuffer *self = ORG_EX_WIDGET_BUFFER (object);

  g_free (self->file);
  g_free (self->buffer_name);
  g_free (self->mode);

  G_OBJECT_CLASS (org_ex_widget_buffer_parent_class)->finalize (object);
}

static void
org_ex_widget_buffer_class_init (OrgExWidgetBufferClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_widget_buffer_get_property;
  object_class->set_property = org_ex_widget_buffer_set_property;
  object_class->finalize = org_ex_widget_buffer_finalize;

  buf_properties[BUF_PROP_FILE] =
    g_param_spec_string ("file", "File", "File path to embed",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT
                         | G_PARAM_STATIC_STRINGS);

  buf_properties[BUF_PROP_BUFFER_NAME] =
    g_param_spec_string ("buffer-name", "Buffer Name",
                         "Name of an existing buffer to embed",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  buf_properties[BUF_PROP_MODE] =
    g_param_spec_string ("mode", "Mode",
                         "Major mode to use (auto-detected if NULL)",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  buf_properties[BUF_PROP_EDITABLE] =
    g_param_spec_boolean ("editable", "Editable",
                          "Whether the embedded buffer is editable",
                          FALSE,
                          G_PARAM_READWRITE | G_PARAM_CONSTRUCT
                          | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, BUF_N_PROPERTIES,
                                     buf_properties);
}

static void
org_ex_widget_buffer_init (OrgExWidgetBuffer *self)
{
  self->file = NULL;
  self->buffer_name = NULL;
  self->mode = NULL;
  self->editable = FALSE;
}

/* ---- Public API ---- */

OrgExWidgetBuffer *
org_ex_widget_buffer_new (const gchar *file,
                           gboolean     editable)
{
  return g_object_new (ORG_EX_TYPE_WIDGET_BUFFER,
                       "widget-type", ORG_EX_WIDGET_TYPE_BUFFER,
                       "file", file,
                       "editable", editable,
                       NULL);
}

const gchar *
org_ex_widget_buffer_get_file (OrgExWidgetBuffer *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_BUFFER (self), NULL);
  return self->file;
}

const gchar *
org_ex_widget_buffer_get_mode (OrgExWidgetBuffer *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_BUFFER (self), NULL);
  return self->mode;
}

void
org_ex_widget_buffer_set_mode (OrgExWidgetBuffer *self,
                                const gchar       *mode)
{
  g_return_if_fail (ORG_EX_IS_WIDGET_BUFFER (self));
  g_free (self->mode);
  self->mode = g_strdup (mode);
  g_object_notify (G_OBJECT (self), "mode");
}

gboolean
org_ex_widget_buffer_get_editable (OrgExWidgetBuffer *self)
{
  g_return_val_if_fail (ORG_EX_IS_WIDGET_BUFFER (self), FALSE);
  return self->editable;
}

void
org_ex_widget_buffer_set_editable (OrgExWidgetBuffer *self,
                                    gboolean           editable)
{
  g_return_if_fail (ORG_EX_IS_WIDGET_BUFFER (self));
  if (self->editable != editable)
    {
      self->editable = editable;
      g_object_notify (G_OBJECT (self), "editable");
    }
}
