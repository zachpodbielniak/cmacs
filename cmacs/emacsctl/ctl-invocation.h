/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-invocation.h --- CtlInvocation, the per-run context handed to
 * every command.
 *
 * Boxed and reference-counted.  Carries the resolved options
 * (instance/host/output/timeout), the command's positional argv, and
 * a lazily-connected transport, so local-only commands (config,
 * completion, version) never touch the bus. */

#ifndef CTL_INVOCATION_H
#define CTL_INVOCATION_H

#include "ctl.h"
#include "ctl-transport.h"
#include "ctl-formatter.h"
#include "ctl-result.h"

G_BEGIN_DECLS

typedef struct _CtlInvocation CtlInvocation;
typedef struct _CtlConfig CtlConfig;   /* ctl-config.h */

#define CTL_TYPE_INVOCATION (ctl_invocation_get_type ())
GType ctl_invocation_get_type (void) G_GNUC_CONST;

CtlInvocation *ctl_invocation_new   (void);
CtlInvocation *ctl_invocation_ref   (CtlInvocation *self);
void           ctl_invocation_unref (CtlInvocation *self);

/* Setters used by CtlApplication while resolving options. */
void ctl_invocation_set_args     (CtlInvocation *self,
                                  gchar **argv, gint argc);
void ctl_invocation_set_instance (CtlInvocation *self, const gchar *sel);
void ctl_invocation_set_host     (CtlInvocation *self, const gchar *host);
void ctl_invocation_set_output   (CtlInvocation *self, const gchar *fmt);
void ctl_invocation_set_watch    (CtlInvocation *self, gboolean watch);
void ctl_invocation_set_timeout  (CtlInvocation *self, gint seconds);
void ctl_invocation_set_config   (CtlInvocation *self, CtlConfig *config);

gchar      **ctl_invocation_get_args     (CtlInvocation *self,
                                          gint *argc);
const gchar *ctl_invocation_get_arg      (CtlInvocation *self, gint idx);
const gchar *ctl_invocation_get_instance (CtlInvocation *self);
const gchar *ctl_invocation_get_host     (CtlInvocation *self);
const gchar *ctl_invocation_get_output   (CtlInvocation *self);
gboolean     ctl_invocation_get_watch    (CtlInvocation *self);
gint         ctl_invocation_get_timeout  (CtlInvocation *self);
CtlConfig   *ctl_invocation_get_config   (CtlInvocation *self);

/* Lazy transport: connects on first use (D-Bus locally, ssh proxy
 * when a host is set).  Timeout for RPC calls in ms derives from the
 * timeout setting. */
CtlTransport *ctl_invocation_get_transport (CtlInvocation *self,
                                            GError **error);
gint          ctl_invocation_get_timeout_ms (CtlInvocation *self);

/* Render RESULT through the formatter selected by -o. */
gboolean ctl_invocation_emit (CtlInvocation *self, CtlResult *result,
                              GError **error);

G_END_DECLS

#endif /* CTL_INVOCATION_H */
