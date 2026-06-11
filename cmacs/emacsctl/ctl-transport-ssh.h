/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport-ssh.h --- CtlTransport over `ssh HOST emacsctl proxy'.
 *
 * Spawns ssh with the remote emacsctl in hidden proxy mode and speaks
 * the ctl-frame protocol over its stdio.  Full-duplex, so calls,
 * signal subscriptions (watch/logs -f) and REPLs all work over one
 * connection.  Authentication is plain ssh (BatchMode: no prompts). */

#ifndef CTL_TRANSPORT_SSH_H
#define CTL_TRANSPORT_SSH_H

#include "ctl-transport.h"

G_BEGIN_DECLS

#define CTL_TYPE_SSH_TRANSPORT (ctl_ssh_transport_get_type ())
G_DECLARE_FINAL_TYPE (CtlSshTransport, ctl_ssh_transport,
                      CTL, SSH_TRANSPORT, GObject)

/* HOST is an ssh destination ("user@machine" or a ~/.ssh/config
 * alias).  INSTANCE is the remote instance selector (may be NULL). */
CtlSshTransport *ctl_ssh_transport_new (const gchar *host,
                                        const gchar *instance,
                                        GError **error);

G_END_DECLS

#endif /* CTL_TRANSPORT_SSH_H */
