/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-proxy.h --- CtlProxyServer, the hidden `emacsctl proxy' mode.
 *
 * Bridges stdin/stdout (ctl-frame protocol) to the local session
 * D-Bus.  CtlSshTransport spawns this on the remote host, which is
 * how `--host user@machine' works: the remote needs exactly one
 * binary, emacsctl itself. */

#ifndef CTL_PROXY_H
#define CTL_PROXY_H

#include "ctl.h"

G_BEGIN_DECLS

#define CTL_TYPE_PROXY_SERVER (ctl_proxy_server_get_type ())
G_DECLARE_FINAL_TYPE (CtlProxyServer, ctl_proxy_server,
                      CTL, PROXY_SERVER, GObject)

CtlProxyServer *ctl_proxy_server_new (const gchar *instance,
                                      GError **error);

/* Serve until stdin EOF.  Returns an exit code. */
gint ctl_proxy_server_run (CtlProxyServer *self);

G_END_DECLS

#endif /* CTL_PROXY_H */
