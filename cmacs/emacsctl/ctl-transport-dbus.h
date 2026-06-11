/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport-dbus.h --- CtlTransport over the local session bus. */

#ifndef CTL_TRANSPORT_DBUS_H
#define CTL_TRANSPORT_DBUS_H

#include "ctl-transport.h"

G_BEGIN_DECLS

#define CTL_TYPE_DBUS_TRANSPORT (ctl_dbus_transport_get_type ())
G_DECLARE_FINAL_TYPE (CtlDbusTransport, ctl_dbus_transport,
                      CTL, DBUS_TRANSPORT, GObject)

/* SELECTOR resolves the target instance:
 *   "primary"      the well-known name org.cmacs.Editor
 *   "<pid>"        org.cmacs.Editor.Pid<pid>
 *   NULL / "auto"  $CMACS_DBUS_NAME if set; else the well-known name
 *                  if owned; else the single Pid* instance if there
 *                  is exactly one; else error (CTL_ERROR_NO_INSTANCE,
 *                  listing the candidates). */
CtlDbusTransport *ctl_dbus_transport_new (const gchar *selector,
                                          GError **error);

/* The resolved bus name this transport targets. */
const gchar *ctl_dbus_transport_get_bus_name (CtlDbusTransport *self);

G_END_DECLS

#endif /* CTL_TRANSPORT_DBUS_H */
