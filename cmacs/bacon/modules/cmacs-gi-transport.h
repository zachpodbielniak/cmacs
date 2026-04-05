/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-transport.h — transport abstraction for cmacsgi
 *
 * Wraps either a Unix socketpair fd (when $CMACS_IPC_FD is set) or a
 * GDBusProxy (when $CMACS_DBUS_NAME is set).  All cmacsgi commands go
 * through this layer so they work identically on both transports.
 */

#ifndef CMACS_GI_TRANSPORT_H
#define CMACS_GI_TRANSPORT_H

#include <gio/gio.h>
#include <glib.h>

typedef struct _CmacsGiTransport CmacsGiTransport;

/* Auto-detect transport: $CMACS_IPC_FD → fd, else $CMACS_DBUS_NAME → D-Bus.
   Returns NULL on failure (sets *error). */
CmacsGiTransport *cmacs_gi_transport_new (GError **error);

/* Free the transport and close/unref its resources. */
void cmacs_gi_transport_free (CmacsGiTransport *t);

/* Call method METHOD with GVariant PARAMS (may be NULL for no-arg
   methods).  Returns the result GVariant on success (caller unrefs),
   or NULL on error (sets *error). */
GVariant *cmacs_gi_transport_call (CmacsGiTransport *t,
                                   const gchar *method,
                                   GVariant *params,
                                   GError **error);

#endif /* CMACS_GI_TRANSPORT_H */
