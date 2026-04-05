/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-service.h — D-Bus service for CMacs
 *
 * Exposes CMacs operations (eval, find-file, GI calls) over D-Bus
 * so external processes (like the bacon shell) can interact with CMacs
 * via GObject Introspection.
 */

#ifndef CMACS_DBUS_SERVICE_H
#define CMACS_DBUS_SERVICE_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

extern void syms_of_cmacs_dbus_service (void);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_DBUS_SERVICE_H */
