/* org-ex-binding.c — Reactive property binding implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-binding.h"
#include "../org-ex-types.h"

/**
 * SECTION:org-ex-binding
 * @title: OrgExBinding
 * @short_description: Bidirectional property binding between widgets and org properties
 *
 * #OrgExBinding connects an org document property to a widget.  When
 * the widget's value changes, the property is updated; when the
 * property changes (via editing the org file), the widget is updated.
 *
 * A guard flag prevents infinite update loops.
 */

struct _OrgExBinding
{
  GObject                parent_instance;
  OrgExDocument         *document;      /* weak ref */
  OrgExWidget           *widget;        /* weak ref */
  gchar                 *property_name;
  OrgExBindingDirection  direction;
  gulong                 widget_handler_id;
  gulong                 doc_handler_id;
  gboolean               inhibit;
};

enum
{
  BIND_PROP_0,
  BIND_PROP_PROPERTY_NAME,
  BIND_PROP_DIRECTION,
  BIND_N_PROPERTIES
};

static GParamSpec *bind_properties[BIND_N_PROPERTIES] = { NULL, };

enum
{
  BIND_SIGNAL_VALUE_CHANGED,
  BIND_N_SIGNALS
};

static guint bind_signals[BIND_N_SIGNALS] = { 0, };

G_DEFINE_FINAL_TYPE (OrgExBinding, org_ex_binding, G_TYPE_OBJECT)

/* ---- Weak ref callbacks ---- */

static void
binding_widget_weak_notify (gpointer  data,
                            GObject  *where_the_object_was)
{
  OrgExBinding *self = ORG_EX_BINDING (data);
  (void) where_the_object_was;
  self->widget = NULL;
  self->widget_handler_id = 0;
}

static void
binding_document_weak_notify (gpointer  data,
                              GObject  *where_the_object_was)
{
  OrgExBinding *self = ORG_EX_BINDING (data);
  (void) where_the_object_was;
  self->document = NULL;
  self->doc_handler_id = 0;
}

/* ---- Signal handlers ---- */

static void
on_widget_value_changed (OrgExWidget  *widget,
                         const gchar  *value,
                         OrgExBinding *self)
{
  (void) widget;

  if (self->inhibit)
    return;
  if (self->direction == ORG_EX_BINDING_TO_WIDGET)
    return;

  self->inhibit = TRUE;
  org_ex_document_notify_property_changed (self->document,
                                            self->property_name,
                                            value);
  g_signal_emit (self, bind_signals[BIND_SIGNAL_VALUE_CHANGED], 0, value);
  self->inhibit = FALSE;
}

static void
on_doc_property_changed (OrgExDocument *document,
                         const gchar   *name,
                         const gchar   *value,
                         OrgExBinding  *self)
{
  (void) document;

  if (self->inhibit)
    return;
  if (self->direction == ORG_EX_BINDING_FROM_WIDGET)
    return;
  if (g_strcmp0 (name, self->property_name) != 0)
    return;

  self->inhibit = TRUE;
  /* Emit value-changed on the widget so it can update itself */
  g_signal_emit_by_name (self->widget, "value-changed", value);
  self->inhibit = FALSE;
}

/* ---- GObject lifecycle ---- */

static void
org_ex_binding_get_property (GObject    *object,
                             guint       prop_id,
                             GValue     *value,
                             GParamSpec *pspec)
{
  OrgExBinding *self = ORG_EX_BINDING (object);

  switch (prop_id)
    {
    case BIND_PROP_PROPERTY_NAME:
      g_value_set_string (value, self->property_name);
      break;
    case BIND_PROP_DIRECTION:
      g_value_set_enum (value, self->direction);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_binding_dispose (GObject *object)
{
  OrgExBinding *self = ORG_EX_BINDING (object);

  org_ex_binding_unbind (self);

  G_OBJECT_CLASS (org_ex_binding_parent_class)->dispose (object);
}

static void
org_ex_binding_finalize (GObject *object)
{
  OrgExBinding *self = ORG_EX_BINDING (object);

  g_free (self->property_name);

  G_OBJECT_CLASS (org_ex_binding_parent_class)->finalize (object);
}

static void
org_ex_binding_class_init (OrgExBindingClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_binding_get_property;
  object_class->dispose = org_ex_binding_dispose;
  object_class->finalize = org_ex_binding_finalize;

  bind_properties[BIND_PROP_PROPERTY_NAME] =
    g_param_spec_string ("property-name", "Property Name",
                         "Org property name",
                         NULL,
                         G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);

  bind_properties[BIND_PROP_DIRECTION] =
    g_param_spec_enum ("direction", "Direction",
                       "Binding direction",
                       ORG_EX_TYPE_BINDING_DIRECTION,
                       ORG_EX_BINDING_BIDIRECTIONAL,
                       G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, BIND_N_PROPERTIES,
                                     bind_properties);

  /**
   * OrgExBinding::value-changed:
   * @binding: the #OrgExBinding
   * @value: the new value as string
   *
   * Emitted when the bound value changes from either direction.
   */
  bind_signals[BIND_SIGNAL_VALUE_CHANGED] =
    g_signal_new ("value-changed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 1,
                  G_TYPE_STRING);
}

static void
org_ex_binding_init (OrgExBinding *self)
{
  self->document = NULL;
  self->widget = NULL;
  self->property_name = NULL;
  self->direction = ORG_EX_BINDING_BIDIRECTIONAL;
  self->widget_handler_id = 0;
  self->doc_handler_id = 0;
  self->inhibit = FALSE;
}

/* ---- Public API ---- */

OrgExBinding *
org_ex_binding_new (OrgExDocument        *document,
                     const gchar          *property_name,
                     OrgExWidget          *widget,
                     OrgExBindingDirection direction)
{
  OrgExBinding *self;

  g_return_val_if_fail (ORG_EX_IS_DOCUMENT (document), NULL);
  g_return_val_if_fail (property_name != NULL, NULL);
  g_return_val_if_fail (ORG_EX_IS_WIDGET (widget), NULL);

  self = g_object_new (ORG_EX_TYPE_BINDING, NULL);
  self->document = document;
  self->widget = widget;
  self->property_name = g_strdup (property_name);
  self->direction = direction;

  /* Register weak refs so pointers are nulled on finalization. */
  g_object_weak_ref (G_OBJECT (widget),
                     binding_widget_weak_notify, self);
  g_object_weak_ref (G_OBJECT (document),
                     binding_document_weak_notify, self);

  /* Connect signals based on direction */
  if (direction != ORG_EX_BINDING_TO_WIDGET)
    self->widget_handler_id =
      g_signal_connect (widget, "value-changed",
                        G_CALLBACK (on_widget_value_changed), self);

  if (direction != ORG_EX_BINDING_FROM_WIDGET)
    self->doc_handler_id =
      g_signal_connect (document, "property-changed",
                        G_CALLBACK (on_doc_property_changed), self);

  return self;
}

const gchar *
org_ex_binding_get_property_name (OrgExBinding *self)
{
  g_return_val_if_fail (ORG_EX_IS_BINDING (self), NULL);
  return self->property_name;
}

OrgExWidget *
org_ex_binding_get_widget (OrgExBinding *self)
{
  g_return_val_if_fail (ORG_EX_IS_BINDING (self), NULL);
  return self->widget;
}

OrgExBindingDirection
org_ex_binding_get_direction (OrgExBinding *self)
{
  g_return_val_if_fail (ORG_EX_IS_BINDING (self),
                        ORG_EX_BINDING_BIDIRECTIONAL);
  return self->direction;
}

void
org_ex_binding_unbind (OrgExBinding *self)
{
  g_return_if_fail (ORG_EX_IS_BINDING (self));

  if (self->widget != NULL)
    {
      if (self->widget_handler_id != 0)
        {
          g_signal_handler_disconnect (self->widget,
                                       self->widget_handler_id);
          self->widget_handler_id = 0;
        }
      g_object_weak_unref (G_OBJECT (self->widget),
                           binding_widget_weak_notify, self);
      self->widget = NULL;
    }

  if (self->document != NULL)
    {
      if (self->doc_handler_id != 0)
        {
          g_signal_handler_disconnect (self->document,
                                       self->doc_handler_id);
          self->doc_handler_id = 0;
        }
      g_object_weak_unref (G_OBJECT (self->document),
                           binding_document_weak_notify, self);
      self->document = NULL;
    }
}
