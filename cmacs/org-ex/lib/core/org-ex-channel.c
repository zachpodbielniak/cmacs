/* org-ex-channel.c — Pub/sub channel implementation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_COMPILATION
#define ORG_EX_COMPILATION
#endif
#include "org-ex-channel.h"

/**
 * SECTION:org-ex-channel
 * @title: OrgExChannel
 * @short_description: Named pub/sub channel for widget-to-widget messaging
 *
 * #OrgExChannel provides ephemeral messaging between widgets via
 * GObject signals.  Publishers call org_ex_channel_publish() and
 * subscribers connect to the ::message signal.
 */

struct _OrgExChannel
{
  GObject  parent_instance;
  gchar   *name;
};

enum
{
  CHAN_PROP_0,
  CHAN_PROP_NAME,
  CHAN_N_PROPERTIES
};

static GParamSpec *chan_properties[CHAN_N_PROPERTIES] = { NULL, };

enum
{
  CHAN_SIGNAL_MESSAGE,
  CHAN_N_SIGNALS
};

static guint chan_signals[CHAN_N_SIGNALS] = { 0, };

G_DEFINE_FINAL_TYPE (OrgExChannel, org_ex_channel, G_TYPE_OBJECT)

static void
org_ex_channel_get_property (GObject    *object,
                             guint       prop_id,
                             GValue     *value,
                             GParamSpec *pspec)
{
  OrgExChannel *self = ORG_EX_CHANNEL (object);

  switch (prop_id)
    {
    case CHAN_PROP_NAME:
      g_value_set_string (value, self->name);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
org_ex_channel_finalize (GObject *object)
{
  OrgExChannel *self = ORG_EX_CHANNEL (object);

  g_free (self->name);

  G_OBJECT_CLASS (org_ex_channel_parent_class)->finalize (object);
}

static void
org_ex_channel_class_init (OrgExChannelClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = org_ex_channel_get_property;
  object_class->finalize = org_ex_channel_finalize;

  chan_properties[CHAN_PROP_NAME] =
    g_param_spec_string ("name", "Name", "Channel name",
                         NULL,
                         G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, CHAN_N_PROPERTIES,
                                     chan_properties);

  /**
   * OrgExChannel::message:
   * @channel: the #OrgExChannel
   * @value: the published value as a string
   *
   * Emitted when a value is published on this channel.
   */
  chan_signals[CHAN_SIGNAL_MESSAGE] =
    g_signal_new ("message",
                  G_TYPE_FROM_CLASS (klass),
                  G_SIGNAL_RUN_LAST,
                  0, NULL, NULL, NULL,
                  G_TYPE_NONE, 1,
                  G_TYPE_STRING);
}

static void
org_ex_channel_init (OrgExChannel *self)
{
  self->name = NULL;
}

/* ---- Public API ---- */

OrgExChannel *
org_ex_channel_new (const gchar *name)
{
  OrgExChannel *self;

  g_return_val_if_fail (name != NULL, NULL);

  self = g_object_new (ORG_EX_TYPE_CHANNEL, NULL);
  self->name = g_strdup (name);

  return self;
}

const gchar *
org_ex_channel_get_name (OrgExChannel *self)
{
  g_return_val_if_fail (ORG_EX_IS_CHANNEL (self), NULL);
  return self->name;
}

void
org_ex_channel_publish (OrgExChannel *self,
                         const gchar  *value)
{
  g_return_if_fail (ORG_EX_IS_CHANNEL (self));

  g_signal_emit (self, chan_signals[CHAN_SIGNAL_MESSAGE], 0, value);
}
