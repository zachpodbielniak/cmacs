/* org-ex-widget.c — OrgExWidget abstract base class
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-widget.h"
#include "../interfaces/org-ex-renderable.h"
#include "../interfaces/org-ex-exportable.h"

/**
 * SECTION:org-ex-widget
 * @title: OrgExWidget
 * @short_description: Abstract base class for org-ex widgets
 *
 * #OrgExWidget is the abstract base class for all widget types that
 * can be embedded in org documents.  Subclasses implement the virtual
 * methods for rendering, state management, and teardown.
 *
 * Each widget has a unique ID, dimensions, visibility state, and a
 * widget type enum.  The base class provides common property and
 * signal infrastructure.
 */

typedef struct
{
  gchar           *id;
  OrgExWidgetType  widget_type;
  gint             width;
  gint             height;
  gboolean         visible;
} OrgExWidgetPrivate;

enum
{
  PROP_0,
  PROP_ID,
  PROP_WIDGET_TYPE,
  PROP_WIDTH,
  PROP_HEIGHT,
  PROP_VISIBLE,
  N_PROPERTIES
};

static GParamSpec *properties[N_PROPERTIES] = { NULL, };

enum
{
  SIGNAL_CREATED,
  SIGNAL_DESTROYED,
  SIGNAL_RESIZED,
  SIGNAL_STATE_CHANGED,
  SIGNAL_VALUE_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS] = { 0, };

/* ---- OrgExRenderable interface ---- */

static gpointer
org_ex_widget_renderable_render (OrgExRenderable *renderable,
                                 gpointer         display_context,
                                 GError         **error)
{
  return org_ex_widget_render (ORG_EX_WIDGET (renderable),
                               display_context, error);
}

static void
org_ex_widget_renderable_get_preferred_size (OrgExRenderable *renderable,
                                             gint            *width,
                                             gint            *height)
{
  org_ex_widget_get_size (ORG_EX_WIDGET (renderable), width, height);
}

static void
org_ex_widget_renderable_init (OrgExRenderableInterface *iface)
{
  iface->render = org_ex_widget_renderable_render;
  iface->get_preferred_size = org_ex_widget_renderable_get_preferred_size;
}

G_DEFINE_ABSTRACT_TYPE_WITH_CODE (
  OrgExWidget, org_ex_widget, G_TYPE_OBJECT,
  G_ADD_PRIVATE (OrgExWidget)
  G_IMPLEMENT_INTERFACE (ORG_EX_TYPE_RENDERABLE,
                         org_ex_widget_renderable_init))

/* ---- Default vfunc implementations ---- */

static gpointer
org_ex_widget_real_render (OrgExWidget *self,
                           gpointer     display_context,
                           GError     **error)
{
  (void) self;
  (void) display_context;
  g_set_error_literal (error, ORG_EX_ERROR, ORG_EX_ERROR_RENDER,
                       "render not implemented for this widget type");
  return NULL;
}

static void
org_ex_widget_real_update (OrgExWidget *self)
{
  (void) self;
}

static void
org_ex_widget_real_teardown (OrgExWidget *self)
{
  (void) self;
}

static OrgExWidgetState *
org_ex_widget_real_save_state (OrgExWidget *self)
{
  (void) self;
  return NULL;
}

static gboolean
org_ex_widget_real_restore_state (OrgExWidget      *self,
                                  OrgExWidgetState *state,
                                  GError          **error)
{
  (void) self;
  (void) state;
  (void) error;
  return TRUE;
}

/* ---- GObject overrides ---- */

static void
org_ex_widget_get_property (GObject    *object,
                            guint       prop_id,
                            GValue     *value,
                            GParamSpec *pspec)
{
  OrgExWidgetPrivate *priv;

  priv = org_ex_widget_get_instance_private (ORG_EX_WIDGET (object));

  switch (prop_id)
    {
    case PROP_ID:
      g_value_set_string (value, priv->id);
      break;
    case PROP_WIDGET_TYPE:
      g_value_set_enum (value, priv->widget_type);
      break;
    case PROP_WIDTH:
      g_value_set_int (value, priv->width);
      break;
    case PROP_HEIGHT:
      g_value_set_int (value, priv->height);
      break;
    case PROP_VISIBLE:
      g_value_set_boolean (value, priv->visible);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_set_property (GObject      *object,
                            guint         prop_id,
                            const GValue *value,
                            GParamSpec   *pspec)
{
  OrgExWidgetPrivate *priv;

  priv = org_ex_widget_get_instance_private (ORG_EX_WIDGET (object));

  switch (prop_id)
    {
    case PROP_ID:
      g_free (priv->id);
      priv->id = g_value_dup_string (value);
      break;
    case PROP_WIDGET_TYPE:
      priv->widget_type = g_value_get_enum (value);
      break;
    case PROP_WIDTH:
      priv->width = g_value_get_int (value);
      break;
    case PROP_HEIGHT:
      priv->height = g_value_get_int (value);
      break;
    case PROP_VISIBLE:
      priv->visible = g_value_get_boolean (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_widget_finalize (GObject *object)
{
  OrgExWidgetPrivate *priv;

  priv = org_ex_widget_get_instance_private (ORG_EX_WIDGET (object));

  g_free (priv->id);

  G_OBJECT_CLASS (org_ex_widget_parent_class)->finalize (object);
}

static void
org_ex_widget_dispose (GObject *object)
{
  g_signal_emit (object, signals[SIGNAL_DESTROYED], 0);

  G_OBJECT_CLASS (org_ex_widget_parent_class)->dispose (object);
}

/* ---- Class init ---- */

static void
org_ex_widget_class_init (OrgExWidgetClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_widget_get_property;
  object_class->set_property = org_ex_widget_set_property;
  object_class->finalize = org_ex_widget_finalize;
  object_class->dispose = org_ex_widget_dispose;

  /* Default vfunc implementations */
  klass->render = org_ex_widget_real_render;
  klass->update = org_ex_widget_real_update;
  klass->teardown = org_ex_widget_real_teardown;
  klass->save_state = org_ex_widget_real_save_state;
  klass->restore_state = org_ex_widget_real_restore_state;

  /**
   * OrgExWidget:id:
   *
   * Unique identifier for this widget within the document.
   */
  properties[PROP_ID] =
    g_param_spec_string ("id", "ID",
                         "Unique widget identifier",
                         NULL,
                         G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  /**
   * OrgExWidget:widget-type:
   *
   * The #OrgExWidgetType of this widget.
   */
  properties[PROP_WIDGET_TYPE] =
    g_param_spec_enum ("widget-type", "Widget Type",
                       "The type of this widget",
                       ORG_EX_TYPE_WIDGET_TYPE,
                       ORG_EX_WIDGET_TYPE_GTK,
                       G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY
                       | G_PARAM_STATIC_STRINGS);

  /**
   * OrgExWidget:width:
   *
   * Widget width in pixels.
   */
  properties[PROP_WIDTH] =
    g_param_spec_int ("width", "Width",
                      "Widget width in pixels",
                      0, G_MAXINT, 400,
                      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  /**
   * OrgExWidget:height:
   *
   * Widget height in pixels.
   */
  properties[PROP_HEIGHT] =
    g_param_spec_int ("height", "Height",
                      "Widget height in pixels",
                      0, G_MAXINT, 200,
                      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  /**
   * OrgExWidget:visible:
   *
   * Whether the widget is currently displayed.
   */
  properties[PROP_VISIBLE] =
    g_param_spec_boolean ("visible", "Visible",
                          "Whether the widget is visible",
                          TRUE,
                          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, N_PROPERTIES, properties);

  /**
   * OrgExWidget::created:
   * @widget: the #OrgExWidget
   *
   * Emitted after the widget has been fully constructed and rendered.
   */
  signals[SIGNAL_CREATED] =
    g_signal_new ("created",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 0);

  /**
   * OrgExWidget::destroyed:
   * @widget: the #OrgExWidget
   *
   * Emitted when the widget is being destroyed.
   */
  signals[SIGNAL_DESTROYED] =
    g_signal_new ("destroyed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 0);

  /**
   * OrgExWidget::resized:
   * @widget: the #OrgExWidget
   * @width: new width
   * @height: new height
   *
   * Emitted when the widget dimensions change.
   */
  signals[SIGNAL_RESIZED] =
    g_signal_new ("resized",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 2,
                  G_TYPE_UINT, G_TYPE_UINT);

  /**
   * OrgExWidget::state-changed:
   * @widget: the #OrgExWidget
   *
   * Emitted when the widget's internal state changes.
   */
  signals[SIGNAL_STATE_CHANGED] =
    g_signal_new ("state-changed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 0);

  /**
   * OrgExWidget::value-changed:
   * @widget: the #OrgExWidget
   * @value: the new value as a string
   *
   * Emitted when the widget's bound value changes (e.g. slider moved).
   */
  signals[SIGNAL_VALUE_CHANGED] =
    g_signal_new ("value-changed",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 1,
                  G_TYPE_STRING);
}

static void
org_ex_widget_init (OrgExWidget *self)
{
  OrgExWidgetPrivate *priv;

  priv = org_ex_widget_get_instance_private (self);
  priv->id = NULL;
  priv->width = 400;
  priv->height = 200;
  priv->visible = TRUE;
}

/* ---- Public API ---- */

const gchar *
org_ex_widget_get_id (OrgExWidget *self)
{
  OrgExWidgetPrivate *priv;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), NULL);

  priv = org_ex_widget_get_instance_private (self);
  return priv->id;
}

void
org_ex_widget_set_id (OrgExWidget *self,
                      const gchar *id)
{
  OrgExWidgetPrivate *priv;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  priv = org_ex_widget_get_instance_private (self);
  g_free (priv->id);
  priv->id = g_strdup (id);
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_ID]);
}

OrgExWidgetType
org_ex_widget_get_widget_type (OrgExWidget *self)
{
  OrgExWidgetPrivate *priv;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), ORG_EX_WIDGET_TYPE_GTK);

  priv = org_ex_widget_get_instance_private (self);
  return priv->widget_type;
}

void
org_ex_widget_get_size (OrgExWidget *self,
                        gint        *width,
                        gint        *height)
{
  OrgExWidgetPrivate *priv;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  priv = org_ex_widget_get_instance_private (self);
  if (width != NULL)
    *width = priv->width;
  if (height != NULL)
    *height = priv->height;
}

void
org_ex_widget_set_size (OrgExWidget *self,
                        gint         width,
                        gint         height)
{
  OrgExWidgetPrivate *priv;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  priv = org_ex_widget_get_instance_private (self);
  if (priv->width != width || priv->height != height)
    {
      priv->width = width;
      priv->height = height;
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_WIDTH]);
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_HEIGHT]);
      g_signal_emit (self, signals[SIGNAL_RESIZED], 0,
                     (guint) width, (guint) height);
    }
}

gboolean
org_ex_widget_get_visible (OrgExWidget *self)
{
  OrgExWidgetPrivate *priv;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), FALSE);

  priv = org_ex_widget_get_instance_private (self);
  return priv->visible;
}

void
org_ex_widget_set_visible (OrgExWidget *self,
                           gboolean     visible)
{
  OrgExWidgetPrivate *priv;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  priv = org_ex_widget_get_instance_private (self);
  if (priv->visible != visible)
    {
      priv->visible = visible;
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_VISIBLE]);
    }
}

gpointer
org_ex_widget_render (OrgExWidget *self,
                      gpointer     display_context,
                      GError     **error)
{
  OrgExWidgetClass *klass;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), NULL);

  klass = ORG_EX_WIDGET_GET_CLASS (self);
  return klass->render (self, display_context, error);
}

void
org_ex_widget_update (OrgExWidget *self)
{
  OrgExWidgetClass *klass;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  klass = ORG_EX_WIDGET_GET_CLASS (self);
  klass->update (self);
}

void
org_ex_widget_teardown (OrgExWidget *self)
{
  OrgExWidgetClass *klass;

  g_return_if_fail (ORG_EX_IS_WIDGET (self));

  klass = ORG_EX_WIDGET_GET_CLASS (self);
  klass->teardown (self);
}

OrgExWidgetState *
org_ex_widget_save_state (OrgExWidget *self)
{
  OrgExWidgetClass *klass;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), NULL);

  klass = ORG_EX_WIDGET_GET_CLASS (self);
  return klass->save_state (self);
}

gboolean
org_ex_widget_restore_state (OrgExWidget      *self,
                             OrgExWidgetState *state,
                             GError          **error)
{
  OrgExWidgetClass *klass;

  g_return_val_if_fail (ORG_EX_IS_WIDGET (self), FALSE);
  g_return_val_if_fail (state != NULL, FALSE);

  klass = ORG_EX_WIDGET_GET_CLASS (self);
  return klass->restore_state (self, state, error);
}
