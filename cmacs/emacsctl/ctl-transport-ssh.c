/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-transport-ssh.c --- see ctl-transport-ssh.h.
 *
 * Demultiplexing: calls are synchronous; while waiting for a reply,
 * interleaved signal frames are dispatched immediately.  When a main
 * loop runs (watcher, REPL idle), a pollable source on the ssh
 * stdout pipe drains incoming signal frames. */

#include "ctl-transport-ssh.h"
#include "ctl-frame.h"

#include <string.h>

struct _CtlSshTransport
{
  GObject parent_instance;

  GSubprocess *proc;
  GOutputStream *to_proxy;
  GInputStream *from_proxy;
  GSource *read_source;       /* pollable source for async signals */

  gint64 next_id;
  GHashTable *subscriptions;  /* GUINT -> SshSubscription */
  guint next_sub_id;
  gboolean closed;
};

typedef struct
{
  CtlTransportSignalFunc cb;
  gpointer user_data;
  GDestroyNotify destroy;
} SshSubscription;

static void ctl_ssh_transport_transport_init (CtlTransportInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlSshTransport, ctl_ssh_transport,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_TRANSPORT,
                           ctl_ssh_transport_transport_init))

static void
ssh_subscription_free (gpointer data)
{
  SshSubscription *sub = data;
  if (sub->destroy != NULL)
    sub->destroy (sub->user_data);
  g_free (sub);
}

static void
ssh_mark_closed (CtlSshTransport *self)
{
  if (!self->closed)
    {
      self->closed = TRUE;
      ctl_transport_emit_closed (CTL_TRANSPORT (self));
    }
}

/* Dispatch one signal frame to its subscription. */
static void
ssh_dispatch_signal (CtlSshTransport *self, JsonObject *frame)
{
  guint sub_id = (guint) json_object_get_int_member_with_default (
    frame, "sub", 0);
  SshSubscription *sub =
    g_hash_table_lookup (self->subscriptions, GUINT_TO_POINTER (sub_id));
  GVariant *args;

  if (sub == NULL)
    return;
  args = ctl_frame_get_variant (frame, "args", NULL);
  sub->cb (CTL_TRANSPORT (self),
           json_object_get_string_member_with_default (frame, "iface",
                                                       ""),
           json_object_get_string_member_with_default (frame, "signal",
                                                       ""),
           args, sub->user_data);
  if (args != NULL)
    g_variant_unref (args);
}

/* Read frames until a reply/error for CALL_ID arrives (signals are
 * dispatched inline).  Returns the reply frame. */
static JsonObject *
ssh_read_until_reply (CtlSshTransport *self, gint64 call_id,
                      GError **error)
{
  for (;;)
    {
      gboolean eof = FALSE;
      JsonObject *frame = ctl_frame_read (self->from_proxy, &eof, error);
      const gchar *type;

      if (frame == NULL)
        {
          if (eof)
            {
              ssh_mark_closed (self);
              g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                           "ssh proxy closed the connection");
            }
          return NULL;
        }

      type = json_object_get_string_member_with_default (frame, "type",
                                                         "");
      if (g_strcmp0 (type, "signal") == 0)
        {
          ssh_dispatch_signal (self, frame);
          json_object_unref (frame);
          continue;
        }
      if ((g_strcmp0 (type, "reply") == 0
           || g_strcmp0 (type, "error") == 0)
          && json_object_get_int_member_with_default (frame, "id", -1)
             == call_id)
        return frame;
      /* Stale or unknown frame: drop. */
      json_object_unref (frame);
    }
}

/* ── Async signal pump (used when a main loop runs) ────────────────── */

static gboolean
ssh_readable_cb (GObject *pollable, gpointer user_data)
{
  CtlSshTransport *self = user_data;
  gboolean eof = FALSE;
  GError *error = NULL;
  JsonObject *frame;

  (void) pollable;

  frame = ctl_frame_read (self->from_proxy, &eof, &error);
  if (frame == NULL)
    {
      g_clear_error (&error);
      ssh_mark_closed (self);
      return G_SOURCE_REMOVE;
    }
  if (g_strcmp0 (json_object_get_string_member_with_default (
                   frame, "type", ""), "signal") == 0)
    ssh_dispatch_signal (self, frame);
  json_object_unref (frame);
  return G_SOURCE_CONTINUE;
}

static void
ssh_ensure_read_source (CtlSshTransport *self)
{
  if (self->read_source != NULL || self->closed)
    return;
  if (!G_IS_POLLABLE_INPUT_STREAM (self->from_proxy))
    return;
  self->read_source = g_pollable_input_stream_create_source (
    G_POLLABLE_INPUT_STREAM (self->from_proxy), NULL);
  g_source_set_callback (self->read_source,
                         G_SOURCE_FUNC (ssh_readable_cb), self, NULL);
  g_source_attach (self->read_source, NULL);
}

/* ── CtlTransport implementation ───────────────────────────────────── */

static GVariant *
ssh_call (CtlTransport *transport, const gchar *iface,
          const gchar *method, GVariant *params, gint timeout_ms,
          GError **error)
{
  CtlSshTransport *self = CTL_SSH_TRANSPORT (transport);
  JsonObject *frame, *reply;
  gint64 id;
  GVariant *result = NULL;

  if (self->closed)
    {
      if (params != NULL)
        g_variant_unref (g_variant_ref_sink (params));
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "ssh transport is closed");
      return NULL;
    }

  id = self->next_id++;
  frame = ctl_frame_new ("call");
  json_object_set_int_member (frame, "id", id);
  json_object_set_string_member (frame, "iface", iface);
  json_object_set_string_member (frame, "method", method);
  if (timeout_ms > 0)
    json_object_set_int_member (frame, "timeout_ms", timeout_ms);
  if (params != NULL)
    {
      g_variant_ref_sink (params);
      ctl_frame_set_variant (frame, "params", params);
      g_variant_unref (params);
    }

  if (!ctl_frame_write (self->to_proxy, frame, error))
    {
      json_object_unref (frame);
      ssh_mark_closed (self);
      return NULL;
    }
  json_object_unref (frame);

  reply = ssh_read_until_reply (self, id, error);
  if (reply == NULL)
    return NULL;

  if (g_strcmp0 (json_object_get_string_member_with_default (
                   reply, "type", ""), "error") == 0)
    {
      const gchar *name = json_object_get_string_member_with_default (
        reply, "name", "org.cmacs.Error");
      const gchar *message =
        json_object_get_string_member_with_default (reply, "message",
                                                     "remote error");
      /* Re-materialize D-Bus error names so exit-code mapping (e.g.
       * UnknownInterface -> 3) keeps working across the tunnel. */
      if (strstr (name, "UnknownInterface") != NULL
          || strstr (name, "UnknownMethod") != NULL)
        g_set_error (error, CTL_ERROR, CTL_ERROR_UNSUPPORTED,
                     "%s: %s", name, message);
      else
        g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                     "%s: %s", name, message);
      json_object_unref (reply);
      return NULL;
    }

  result = ctl_frame_get_variant (reply, "result", error);
  json_object_unref (reply);
  return result;
}

static guint
ssh_subscribe (CtlTransport *transport, const gchar *iface,
               const gchar *signal_name, CtlTransportSignalFunc cb,
               gpointer user_data, GDestroyNotify destroy)
{
  CtlSshTransport *self = CTL_SSH_TRANSPORT (transport);
  SshSubscription *sub = g_new0 (SshSubscription, 1);
  JsonObject *frame;
  guint sub_id = ++self->next_sub_id;

  sub->cb = cb;
  sub->user_data = user_data;
  sub->destroy = destroy;
  g_hash_table_insert (self->subscriptions, GUINT_TO_POINTER (sub_id),
                       sub);

  frame = ctl_frame_new ("subscribe");
  json_object_set_int_member (frame, "id", sub_id);
  json_object_set_string_member (frame, "iface", iface);
  json_object_set_string_member (frame, "signal", signal_name);
  ctl_frame_write (self->to_proxy, frame, NULL);
  json_object_unref (frame);

  ssh_ensure_read_source (self);
  return sub_id;
}

static void
ssh_unsubscribe (CtlTransport *transport, guint id)
{
  CtlSshTransport *self = CTL_SSH_TRANSPORT (transport);
  JsonObject *frame;

  if (!g_hash_table_remove (self->subscriptions, GUINT_TO_POINTER (id)))
    return;
  frame = ctl_frame_new ("unsubscribe");
  json_object_set_int_member (frame, "sub", id);
  ctl_frame_write (self->to_proxy, frame, NULL);
  json_object_unref (frame);
}

static gchar **
ssh_list_instances (CtlTransport *transport, GError **error)
{
  /* The proxy answers this itself (special "instances" frame would be
   * another verb; instead reuse a D-Bus-shaped call the proxy
   * understands natively). */
  GVariant *reply = ssh_call (transport, "ctl.proxy", "ListInstances",
                              NULL, -1, error);
  gchar **pids;

  if (reply == NULL)
    return NULL;
  g_variant_get (reply, "(^as)", &pids);
  g_variant_unref (reply);
  return pids;
}

static void
ssh_close (CtlTransport *transport)
{
  CtlSshTransport *self = CTL_SSH_TRANSPORT (transport);

  if (self->read_source != NULL)
    {
      g_source_destroy (self->read_source);
      g_source_unref (self->read_source);
      self->read_source = NULL;
    }
  if (self->to_proxy != NULL)
    {
      g_output_stream_close (self->to_proxy, NULL, NULL);
      self->to_proxy = NULL;    /* borrowed from proc */
    }
  self->from_proxy = NULL;      /* borrowed from proc */
  if (self->proc != NULL)
    {
      g_subprocess_wait (self->proc, NULL, NULL);
      g_clear_object (&self->proc);
    }
  self->closed = TRUE;
}

static void
ctl_ssh_transport_transport_init (CtlTransportInterface *iface)
{
  iface->call = ssh_call;
  iface->subscribe = ssh_subscribe;
  iface->unsubscribe = ssh_unsubscribe;
  iface->list_instances = ssh_list_instances;
  iface->close = ssh_close;
}

/* ── GObject boilerplate ───────────────────────────────────────────── */

static void
ctl_ssh_transport_finalize (GObject *object)
{
  CtlSshTransport *self = CTL_SSH_TRANSPORT (object);
  ssh_close (CTL_TRANSPORT (self));
  g_hash_table_unref (self->subscriptions);
  G_OBJECT_CLASS (ctl_ssh_transport_parent_class)->finalize (object);
}

static void
ctl_ssh_transport_class_init (CtlSshTransportClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_ssh_transport_finalize;
}

static void
ctl_ssh_transport_init (CtlSshTransport *self)
{
  self->next_id = 1;
  self->subscriptions = g_hash_table_new_full (
    g_direct_hash, g_direct_equal, NULL, ssh_subscription_free);
}

CtlSshTransport *
ctl_ssh_transport_new (const gchar *host, const gchar *instance,
                       GError **error)
{
  CtlSshTransport *self;
  GSubprocess *proc;
  GPtrArray *argv = g_ptr_array_new ();
  JsonObject *hello;
  gboolean eof = FALSE;
  const gchar *remote_cmd = g_getenv ("EMACSCTL_REMOTE_COMMAND");

  if (remote_cmd == NULL || *remote_cmd == '\0')
    remote_cmd = "emacsctl";

  g_ptr_array_add (argv, (gpointer) "ssh");
  g_ptr_array_add (argv, (gpointer) "-o");
  g_ptr_array_add (argv, (gpointer) "BatchMode=yes");
  g_ptr_array_add (argv, (gpointer) "--");
  g_ptr_array_add (argv, (gpointer) host);
  g_ptr_array_add (argv, (gpointer) remote_cmd);
  g_ptr_array_add (argv, (gpointer) "proxy");
  if (instance != NULL && *instance != '\0')
    {
      g_ptr_array_add (argv, (gpointer) "--instance");
      g_ptr_array_add (argv, (gpointer) instance);
    }
  g_ptr_array_add (argv, NULL);

  proc = g_subprocess_newv ((const gchar * const *) argv->pdata,
                            G_SUBPROCESS_FLAGS_STDIN_PIPE
                            | G_SUBPROCESS_FLAGS_STDOUT_PIPE,
                            error);
  g_ptr_array_free (argv, TRUE);
  if (proc == NULL)
    return NULL;

  self = g_object_new (CTL_TYPE_SSH_TRANSPORT, NULL);
  self->proc = proc;
  self->to_proxy = g_subprocess_get_stdin_pipe (proc);
  self->from_proxy = g_subprocess_get_stdout_pipe (proc);

  /* Handshake. */
  hello = ctl_frame_new_hello ();
  if (!ctl_frame_write (self->to_proxy, hello, error))
    {
      json_object_unref (hello);
      g_object_unref (self);
      return NULL;
    }
  json_object_unref (hello);

  hello = ctl_frame_read (self->from_proxy, &eof, error);
  if (hello == NULL)
    {
      if (eof)
        g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                     "ssh connection to %s failed before handshake "
                     "(is emacsctl installed remotely?)", host);
      g_object_unref (self);
      return NULL;
    }
  if (json_object_get_int_member_with_default (hello, "proto", 0)
      != CTL_FRAME_PROTO)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "proxy protocol mismatch (remote emacsctl too old?)");
      json_object_unref (hello);
      g_object_unref (self);
      return NULL;
    }
  json_object_unref (hello);
  return self;
}
