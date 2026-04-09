/* org-ex-channel.h — Pub/sub channel for widget communication
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ORG_EX_CHANNEL_H
#define ORG_EX_CHANNEL_H

#if !defined(ORG_EX_INSIDE) && !defined(ORG_EX_COMPILATION)
#error "Only <org-ex.h> can be included directly."
#endif

#include <glib-object.h>

G_BEGIN_DECLS

#define ORG_EX_TYPE_CHANNEL (org_ex_channel_get_type ())

G_DECLARE_FINAL_TYPE (OrgExChannel, org_ex_channel,
                      ORG_EX, CHANNEL, GObject)

/**
 * org_ex_channel_new:
 * @name: channel name
 *
 * Create a named pub/sub channel.  Widgets subscribe to a channel's
 * ::message signal to receive published values.
 *
 * Returns: (transfer full): a new #OrgExChannel
 */
OrgExChannel *org_ex_channel_new (const gchar *name);

const gchar *org_ex_channel_get_name (OrgExChannel *self);

/**
 * org_ex_channel_publish:
 * @self: a #OrgExChannel
 * @value: the value to publish
 *
 * Publish a value to all subscribers.  Emits ::message.
 */
void org_ex_channel_publish (OrgExChannel *self,
                              const gchar  *value);

G_END_DECLS

#endif /* ORG_EX_CHANNEL_H */
