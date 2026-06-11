/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-watcher.h --- CtlWatcher, the streaming engine behind
 * `logs -f', `watch stream' and `-w'.
 *
 * Subscribes to D-Bus signals through the transport (identical over
 * local D-Bus and the ssh proxy), runs a GMainLoop, and re-emits each
 * event as the GObject signal "event" carrying a CtlResult that the
 * caller renders through the active formatter. */

#ifndef CTL_WATCHER_H
#define CTL_WATCHER_H

#include "ctl-transport.h"
#include "ctl-result.h"

G_BEGIN_DECLS

#define CTL_TYPE_WATCHER (ctl_watcher_get_type ())
G_DECLARE_FINAL_TYPE (CtlWatcher, ctl_watcher, CTL, WATCHER, GObject)

CtlWatcher *ctl_watcher_new (CtlTransport *transport);

/* Watch IFACE.SIGNAL_NAME; each emission becomes an "event" whose
 * CtlResult is the scalar first-string-argument (or the printed
 * args).  Call any number of times before run. */
void ctl_watcher_add_signal (CtlWatcher *self, const gchar *iface,
                             const gchar *signal_name);

/* Re-run a polling callback every INTERVAL_MS, emitting "event" when
 * the produced result differs from the previous one (fallback when
 * no signal source exists). */
typedef CtlResult *(*CtlWatcherPollFunc) (CtlTransport *transport,
                                          gpointer user_data,
                                          GError **error);
void ctl_watcher_set_poll (CtlWatcher *self, guint interval_ms,
                           CtlWatcherPollFunc poll, gpointer user_data);

/* Blocks until the transport closes or SIGINT. */
void ctl_watcher_run (CtlWatcher *self);

G_END_DECLS

#endif /* CTL_WATCHER_H */
