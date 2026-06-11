/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport.c --- CtlTransport interface boilerplate. */

#include "ctl-transport.h"

G_DEFINE_INTERFACE (CtlTransport, ctl_transport, G_TYPE_OBJECT)

static guint signal_closed = 0;

static void
ctl_transport_default_init (CtlTransportInterface *iface)
{
  (void) iface;

  /* CtlTransport::closed --- the channel dropped (peer exited, ssh
   * pipe broke, bus connection lost).  Watchers and REPLs listen. */
  if (signal_closed == 0)
    signal_closed = g_signal_new ("closed",
                                  CTL_TYPE_TRANSPORT,
                                  G_SIGNAL_RUN_LAST,
                                  0, NULL, NULL, NULL,
                                  G_TYPE_NONE, 0);
}

GVariant *
ctl_transport_call (CtlTransport *self, const gchar *iface,
                    const gchar *method, GVariant *params,
                    gint timeout_ms, GError **error)
{
  g_return_val_if_fail (CTL_IS_TRANSPORT (self), NULL);
  return CTL_TRANSPORT_GET_IFACE (self)->call (self, iface, method,
                                               params, timeout_ms, error);
}

guint
ctl_transport_subscribe (CtlTransport *self, const gchar *iface,
                         const gchar *signal_name,
                         CtlTransportSignalFunc cb, gpointer user_data,
                         GDestroyNotify destroy)
{
  g_return_val_if_fail (CTL_IS_TRANSPORT (self), 0);
  return CTL_TRANSPORT_GET_IFACE (self)->subscribe (self, iface,
                                                    signal_name, cb,
                                                    user_data, destroy);
}

void
ctl_transport_unsubscribe (CtlTransport *self, guint id)
{
  g_return_if_fail (CTL_IS_TRANSPORT (self));
  CTL_TRANSPORT_GET_IFACE (self)->unsubscribe (self, id);
}

gchar **
ctl_transport_list_instances (CtlTransport *self, GError **error)
{
  g_return_val_if_fail (CTL_IS_TRANSPORT (self), NULL);
  return CTL_TRANSPORT_GET_IFACE (self)->list_instances (self, error);
}

void
ctl_transport_close (CtlTransport *self)
{
  g_return_if_fail (CTL_IS_TRANSPORT (self));
  CTL_TRANSPORT_GET_IFACE (self)->close (self);
}

void
ctl_transport_emit_closed (CtlTransport *self)
{
  g_signal_emit (self, signal_closed, 0);
}
