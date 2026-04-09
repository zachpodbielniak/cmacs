/* org-ex-document.c — Document-level widget manager implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-document.h"

/**
 * SECTION:org-ex-document
 * @title: OrgExDocument
 * @short_description: Manages all widgets within a single org document
 *
 * #OrgExDocument tracks widget instances by ID, emits signals when
 * widgets are added or removed, and dispatches property change
 * notifications to bound widgets.
 */

struct _OrgExDocument
{
  GObject      parent_instance;
  gchar       *file_path;
  GHashTable  *widgets;   /* gchar* -> OrgExWidget* (owned refs) */
};

enum
{
  DOC_PROP_0,
  DOC_PROP_FILE_PATH,
  DOC_PROP_WIDGET_COUNT,
  DOC_N_PROPERTIES
};

static GParamSpec *doc_properties[DOC_N_PROPERTIES] = { NULL, };

enum
{
  DOC_SIGNAL_WIDGET_ADDED,
  DOC_SIGNAL_WIDGET_REMOVED,
  DOC_SIGNAL_PROPERTY_CHANGED,
  DOC_N_SIGNALS
};

static guint doc_signals[DOC_N_SIGNALS] = { 0, };

G_DEFINE_FINAL_TYPE (OrgExDocument, org_ex_document, G_TYPE_OBJECT)

/* ---- GObject lifecycle ---- */

static void
org_ex_document_get_property (GObject    *object,
                              guint       prop_id,
                              GValue     *value,
                              GParamSpec *pspec)
{
  OrgExDocument *self = ORG_EX_DOCUMENT (object);

  switch (prop_id)
    {
    case DOC_PROP_FILE_PATH:
      g_value_set_string (value, self->file_path);
      break;
    case DOC_PROP_WIDGET_COUNT:
      g_value_set_uint (value,
                        g_hash_table_size (self->widgets));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_document_set_property (GObject      *object,
                              guint         prop_id,
                              const GValue *value,
                              GParamSpec   *pspec)
{
  OrgExDocument *self = ORG_EX_DOCUMENT (object);

  switch (prop_id)
    {
    case DOC_PROP_FILE_PATH:
      g_free (self->file_path);
      self->file_path = g_value_dup_string (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
teardown_widget_cb (gpointer key,
                    gpointer value,
                    gpointer user_data)
{
  (void) key;
  (void) user_data;
  org_ex_widget_teardown (ORG_EX_WIDGET (value));
}

static void
org_ex_document_dispose (GObject *object)
{
  OrgExDocument *self = ORG_EX_DOCUMENT (object);

  if (self->widgets != NULL)
    {
      g_hash_table_foreach (self->widgets, teardown_widget_cb, NULL);
      g_hash_table_remove_all (self->widgets);
    }

  G_OBJECT_CLASS (org_ex_document_parent_class)->dispose (object);
}

static void
org_ex_document_finalize (GObject *object)
{
  OrgExDocument *self = ORG_EX_DOCUMENT (object);

  g_free (self->file_path);
  g_clear_pointer (&self->widgets, g_hash_table_unref);

  G_OBJECT_CLASS (org_ex_document_parent_class)->finalize (object);
}

static void
org_ex_document_class_init (OrgExDocumentClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_document_get_property;
  object_class->set_property = org_ex_document_set_property;
  object_class->dispose = org_ex_document_dispose;
  object_class->finalize = org_ex_document_finalize;

  doc_properties[DOC_PROP_FILE_PATH] =
    g_param_spec_string ("file-path", "File Path",
                         "Path to the org file",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
                         | G_PARAM_STATIC_STRINGS);

  doc_properties[DOC_PROP_WIDGET_COUNT] =
    g_param_spec_uint ("widget-count", "Widget Count",
                       "Number of registered widgets",
                       0, G_MAXUINT, 0,
                       G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, DOC_N_PROPERTIES,
                                     doc_properties);

  /**
   * OrgExDocument::widget-added:
   * @doc: the #OrgExDocument
   * @id: the widget ID
   * @widget: the #OrgExWidget
   */
  doc_signals[DOC_SIGNAL_WIDGET_ADDED] =
    g_signal_new ("widget-added",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 2,
                  G_TYPE_STRING, G_TYPE_OBJECT);

  /**
   * OrgExDocument::widget-removed:
   * @doc: the #OrgExDocument
   * @id: the widget ID
   */
  doc_signals[DOC_SIGNAL_WIDGET_REMOVED] =
    g_signal_new ("widget-removed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 1,
                  G_TYPE_STRING);

  /**
   * OrgExDocument::property-changed:
   * @doc: the #OrgExDocument
   * @name: property name
   * @value: new value as string
   */
  doc_signals[DOC_SIGNAL_PROPERTY_CHANGED] =
    g_signal_new ("property-changed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 2,
                  G_TYPE_STRING, G_TYPE_STRING);
}

static void
org_ex_document_init (OrgExDocument *self)
{
  self->file_path = NULL;
  self->widgets = g_hash_table_new_full (g_str_hash, g_str_equal,
                                         g_free, g_object_unref);
}

/* ---- Public API ---- */

OrgExDocument *
org_ex_document_new (const gchar *file_path)
{
  return g_object_new (ORG_EX_TYPE_DOCUMENT,
                       "file-path", file_path,
                       NULL);
}

void
org_ex_document_register_widget (OrgExDocument *self,
                                  const gchar   *id,
                                  OrgExWidget   *widget)
{
  g_return_if_fail (ORG_EX_IS_DOCUMENT (self));
  g_return_if_fail (id != NULL);
  g_return_if_fail (ORG_EX_IS_WIDGET (widget));

  org_ex_widget_set_id (widget, id);
  g_hash_table_insert (self->widgets,
                        g_strdup (id),
                        g_object_ref (widget));

  g_signal_emit (self, doc_signals[DOC_SIGNAL_WIDGET_ADDED], 0,
                 id, widget);
  g_object_notify_by_pspec (G_OBJECT (self),
                            doc_properties[DOC_PROP_WIDGET_COUNT]);
}

OrgExWidget *
org_ex_document_get_widget (OrgExDocument *self,
                             const gchar   *id)
{
  g_return_val_if_fail (ORG_EX_IS_DOCUMENT (self), NULL);
  g_return_val_if_fail (id != NULL, NULL);

  return g_hash_table_lookup (self->widgets, id);
}

void
org_ex_document_remove_widget (OrgExDocument *self,
                                const gchar   *id)
{
  OrgExWidget *widget;

  g_return_if_fail (ORG_EX_IS_DOCUMENT (self));
  g_return_if_fail (id != NULL);

  widget = g_hash_table_lookup (self->widgets, id);
  if (widget != NULL)
    {
      g_object_ref (widget);
      org_ex_widget_teardown (widget);
      g_hash_table_remove (self->widgets, id);
      g_signal_emit (self, doc_signals[DOC_SIGNAL_WIDGET_REMOVED], 0, id);
      g_object_notify_by_pspec (G_OBJECT (self),
                                doc_properties[DOC_PROP_WIDGET_COUNT]);
      g_object_unref (widget);
    }
}

GList *
org_ex_document_list_widget_ids (OrgExDocument *self)
{
  g_return_val_if_fail (ORG_EX_IS_DOCUMENT (self), NULL);

  return g_hash_table_get_keys (self->widgets);
}

guint
org_ex_document_get_widget_count (OrgExDocument *self)
{
  g_return_val_if_fail (ORG_EX_IS_DOCUMENT (self), 0);

  return g_hash_table_size (self->widgets);
}

void
org_ex_document_notify_property_changed (OrgExDocument *self,
                                          const gchar   *name,
                                          const gchar   *value)
{
  g_return_if_fail (ORG_EX_IS_DOCUMENT (self));
  g_return_if_fail (name != NULL);

  g_signal_emit (self, doc_signals[DOC_SIGNAL_PROPERTY_CHANGED], 0,
                 name, value);
}

void
org_ex_document_teardown_all (OrgExDocument *self)
{
  g_return_if_fail (ORG_EX_IS_DOCUMENT (self));

  g_hash_table_foreach (self->widgets, teardown_widget_cb, NULL);
  g_hash_table_remove_all (self->widgets);
  g_object_notify_by_pspec (G_OBJECT (self),
                            doc_properties[DOC_PROP_WIDGET_COUNT]);
}
