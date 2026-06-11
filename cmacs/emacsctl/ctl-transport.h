/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport.h --- CtlTransport, the abstract RPC channel.
 *
 * A GInterface so the rest of emacsctl is transport-agnostic: the
 * same command code runs over the local session bus
 * (CtlDbusTransport) or an ssh-tunnelled stdio proxy
 * (CtlSshTransport).  Implementations emit the "closed" interface
 * signal when the channel drops, letting REPLs and watchers exit
 * cleanly. */

#ifndef CTL_TRANSPORT_H
#define CTL_TRANSPORT_H

#include "ctl.h"

G_BEGIN_DECLS

#define CTL_TYPE_TRANSPORT (ctl_transport_get_type ())
G_DECLARE_INTERFACE (CtlTransport, ctl_transport, CTL, TRANSPORT, GObject)

typedef void (*CtlTransportSignalFunc) (CtlTransport *transport,
                                        const gchar  *iface,
                                        const gchar  *signal_name,
                                        GVariant     *args,
                                        gpointer      user_data);

struct _CtlTransportInterface
{
  GTypeInterface parent_iface;

  /* Call IFACE.METHOD at /org/cmacs/Editor with PARAMS (a tuple
   * variant, or NULL for none).  Returns the reply tuple. */
  GVariant *(*call)        (CtlTransport *self,
                            const gchar  *iface,
                            const gchar  *method,
                            GVariant     *params,
                            gint          timeout_ms,
                            GError      **error);

  /* Subscribe to IFACE.SIGNAL_NAME; CB fires from the thread-default
   * main context.  Returns a subscription id for unsubscribe. */
  guint     (*subscribe)   (CtlTransport *self,
                            const gchar  *iface,
                            const gchar  *signal_name,
                            CtlTransportSignalFunc cb,
                            gpointer      user_data,
                            GDestroyNotify destroy);
  void      (*unsubscribe) (CtlTransport *self, guint id);

  /* NULL-terminated array of PID strings of reachable instances. */
  gchar   **(*list_instances) (CtlTransport *self, GError **error);

  void      (*close)       (CtlTransport *self);
};

GVariant *ctl_transport_call        (CtlTransport *self,
                                     const gchar *iface,
                                     const gchar *method,
                                     GVariant *params,
                                     gint timeout_ms,
                                     GError **error);
guint     ctl_transport_subscribe   (CtlTransport *self,
                                     const gchar *iface,
                                     const gchar *signal_name,
                                     CtlTransportSignalFunc cb,
                                     gpointer user_data,
                                     GDestroyNotify destroy);
void      ctl_transport_unsubscribe (CtlTransport *self, guint id);
gchar   **ctl_transport_list_instances (CtlTransport *self, GError **error);
void      ctl_transport_close       (CtlTransport *self);

/* For implementations: emit the "closed" interface signal. */
void      ctl_transport_emit_closed (CtlTransport *self);

G_END_DECLS

#endif /* CTL_TRANSPORT_H */
