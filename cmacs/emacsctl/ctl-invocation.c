/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-invocation.c --- see ctl-invocation.h. */

#include "ctl-invocation.h"
#include "ctl-transport-dbus.h"
#include "ctl-transport-ssh.h"
#include "ctl-config.h"

struct _CtlInvocation
{
  gint refcount;

  gchar **argv;               /* owned, NULL-terminated */
  gint argc;

  gchar *instance;            /* selector or NULL (auto) */
  gchar *host;                /* user@host or NULL (local) */
  gchar *output;              /* table|json|yaml|raw */
  gboolean watch;
  gint timeout_secs;

  CtlConfig *config;          /* owned, may be NULL */
  CtlTransport *transport;    /* lazy, owned */
};

G_DEFINE_BOXED_TYPE (CtlInvocation, ctl_invocation,
                     ctl_invocation_ref, ctl_invocation_unref)

CtlInvocation *
ctl_invocation_new (void)
{
  CtlInvocation *self = g_slice_new0 (CtlInvocation);
  self->refcount = 1;
  self->output = g_strdup ("table");
  self->timeout_secs = 30;
  return self;
}

CtlInvocation *
ctl_invocation_ref (CtlInvocation *self)
{
  g_atomic_int_inc (&self->refcount);
  return self;
}

void
ctl_invocation_unref (CtlInvocation *self)
{
  if (self == NULL || !g_atomic_int_dec_and_test (&self->refcount))
    return;
  g_strfreev (self->argv);
  g_free (self->instance);
  g_free (self->host);
  g_free (self->output);
  if (self->transport != NULL)
    {
      ctl_transport_close (self->transport);
      g_object_unref (self->transport);
    }
  if (self->config != NULL)
    g_object_unref (self->config);
  g_slice_free (CtlInvocation, self);
}

void
ctl_invocation_set_args (CtlInvocation *self, gchar **argv, gint argc)
{
  gint k;
  g_strfreev (self->argv);
  self->argv = g_new0 (gchar *, argc + 1);
  for (k = 0; k < argc; k++)
    self->argv[k] = g_strdup (argv[k]);
  self->argc = argc;
}

void
ctl_invocation_set_instance (CtlInvocation *self, const gchar *sel)
{
  g_free (self->instance);
  self->instance = g_strdup (sel);
}

void
ctl_invocation_set_host (CtlInvocation *self, const gchar *host)
{
  g_free (self->host);
  self->host = g_strdup (host);
}

void
ctl_invocation_set_output (CtlInvocation *self, const gchar *fmt)
{
  g_free (self->output);
  self->output = g_strdup (fmt);
}

void
ctl_invocation_set_watch (CtlInvocation *self, gboolean watch)
{
  self->watch = watch;
}

void
ctl_invocation_set_timeout (CtlInvocation *self, gint seconds)
{
  self->timeout_secs = seconds;
}

void
ctl_invocation_set_config (CtlInvocation *self, CtlConfig *config)
{
  if (self->config != NULL)
    g_object_unref (self->config);
  self->config = config != NULL ? g_object_ref (config) : NULL;
}

gchar **
ctl_invocation_get_args (CtlInvocation *self, gint *argc)
{
  if (argc != NULL)
    *argc = self->argc;
  return self->argv;
}

const gchar *
ctl_invocation_get_arg (CtlInvocation *self, gint idx)
{
  if (idx < 0 || idx >= self->argc)
    return NULL;
  return self->argv[idx];
}

const gchar *
ctl_invocation_get_instance (CtlInvocation *self)
{
  return self->instance;
}

const gchar *
ctl_invocation_get_host (CtlInvocation *self)
{
  return self->host;
}

const gchar *
ctl_invocation_get_output (CtlInvocation *self)
{
  return self->output;
}

gboolean
ctl_invocation_get_watch (CtlInvocation *self)
{
  return self->watch;
}

gint
ctl_invocation_get_timeout (CtlInvocation *self)
{
  return self->timeout_secs;
}

CtlConfig *
ctl_invocation_get_config (CtlInvocation *self)
{
  return self->config;
}

gint
ctl_invocation_get_timeout_ms (CtlInvocation *self)
{
  if (self->timeout_secs <= 0)
    return -1;                  /* GDBus default */
  return self->timeout_secs * 1000;
}

CtlTransport *
ctl_invocation_get_transport (CtlInvocation *self, GError **error)
{
  if (self->transport != NULL)
    return self->transport;

  if (self->host != NULL && *self->host != '\0')
    self->transport =
      CTL_TRANSPORT (ctl_ssh_transport_new (self->host, self->instance,
                                            error));
  else
    self->transport =
      CTL_TRANSPORT (ctl_dbus_transport_new (self->instance, error));
  return self->transport;
}

gboolean
ctl_invocation_emit (CtlInvocation *self, CtlResult *result,
                     GError **error)
{
  CtlFormatter *formatter = ctl_formatter_for_name (self->output);
  gboolean ok;

  if (formatter == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "unknown output format '%s' "
                   "(expected table|json|yaml|raw)", self->output);
      return FALSE;
    }
  ok = ctl_formatter_emit (formatter, result, stdout, error);
  g_object_unref (formatter);
  return ok;
}
