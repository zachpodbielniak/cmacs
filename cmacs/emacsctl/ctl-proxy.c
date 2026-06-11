/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-proxy.c --- see ctl-proxy.h. */

#include "ctl-proxy.h"
#include "ctl-frame.h"
#include "ctl-transport.h"
#include "ctl-transport-dbus.h"

#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#include <string.h>

struct _CtlProxyServer
{
  GObject parent_instance;

  CtlDbusTransport *dbus;
  GInputStream *in;           /* stdin */
  GOutputStream *out;         /* stdout */
  GMainLoop *loop;
  GSource *stdin_source;
  GHashTable *subscriptions;  /* client sub id -> transport sub id */
  gint exit_code;
};

G_DEFINE_FINAL_TYPE (CtlProxyServer, ctl_proxy_server, G_TYPE_OBJECT)

/* ── Signal forwarding ─────────────────────────────────────────────── */

typedef struct
{
  CtlProxyServer *server;     /* unowned */
  guint client_sub_id;
} ProxyForward;

static void
proxy_forward_signal (CtlTransport *transport, const gchar *iface,
                      const gchar *signal_name, GVariant *args,
                      gpointer user_data)
{
  ProxyForward *fwd = user_data;
  JsonObject *frame = ctl_frame_new ("signal");

  (void) transport;

  json_object_set_int_member (frame, "sub", fwd->client_sub_id);
  json_object_set_string_member (frame, "iface", iface);
  json_object_set_string_member (frame, "signal", signal_name);
  if (args != NULL)
    ctl_frame_set_variant (frame, "args", args);
  ctl_frame_write (fwd->server->out, frame, NULL);
  json_object_unref (frame);
}

/* ── Request handling ──────────────────────────────────────────────── */

static void
proxy_reply_error (CtlProxyServer *self, gint64 id, const GError *error)
{
  JsonObject *frame = ctl_frame_new ("error");
  gchar *name;

  json_object_set_int_member (frame, "id", id);
  name = g_dbus_error_get_remote_error ((GError *) error);
  json_object_set_string_member (frame, "name",
                                 name != NULL ? name
                                              : "org.cmacs.ctl.Error");
  g_free (name);
  json_object_set_string_member (frame, "message",
                                 error->message != NULL
                                 ? error->message : "unknown error");
  ctl_frame_write (self->out, frame, NULL);
  json_object_unref (frame);
}

static void
proxy_handle_call (CtlProxyServer *self, JsonObject *frame)
{
  gint64 id = json_object_get_int_member_with_default (frame, "id", 0);
  const gchar *iface =
    json_object_get_string_member_with_default (frame, "iface", "");
  const gchar *method =
    json_object_get_string_member_with_default (frame, "method", "");
  gint timeout_ms = (gint) json_object_get_int_member_with_default (
    frame, "timeout_ms", -1);
  GVariant *params;
  GVariant *reply;
  GError *error = NULL;

  /* Proxy-native verbs live on the pseudo-iface "ctl.proxy". */
  if (g_strcmp0 (iface, "ctl.proxy") == 0)
    {
      if (g_strcmp0 (method, "ListInstances") == 0)
        {
          gchar **pids = ctl_transport_list_instances (
            CTL_TRANSPORT (self->dbus), &error);
          if (pids == NULL)
            {
              proxy_reply_error (self, id, error);
              g_error_free (error);
              return;
            }
          reply = g_variant_ref_sink (
            g_variant_new ("(^as)", pids));
          g_strfreev (pids);
        }
      else
        {
          g_set_error (&error, CTL_ERROR, CTL_ERROR_FAILED,
                       "unknown proxy method '%s'", method);
          proxy_reply_error (self, id, error);
          g_error_free (error);
          return;
        }
    }
  else
    {
      params = ctl_frame_get_variant (frame, "params", &error);
      if (error != NULL)
        {
          proxy_reply_error (self, id, error);
          g_error_free (error);
          return;
        }
      reply = ctl_transport_call (CTL_TRANSPORT (self->dbus), iface,
                                  method, params, timeout_ms, &error);
      if (reply == NULL)
        {
          proxy_reply_error (self, id, error);
          g_error_free (error);
          return;
        }
    }

  {
    JsonObject *out = ctl_frame_new ("reply");
    json_object_set_int_member (out, "id", id);
    ctl_frame_set_variant (out, "result", reply);
    g_variant_unref (reply);
    ctl_frame_write (self->out, out, NULL);
    json_object_unref (out);
  }
}

static void
proxy_handle_subscribe (CtlProxyServer *self, JsonObject *frame)
{
  guint client_id = (guint) json_object_get_int_member_with_default (
    frame, "id", 0);
  const gchar *iface =
    json_object_get_string_member_with_default (frame, "iface", "");
  const gchar *signal_name =
    json_object_get_string_member_with_default (frame, "signal", "");
  ProxyForward *fwd = g_new0 (ProxyForward, 1);
  guint transport_id;

  fwd->server = self;
  fwd->client_sub_id = client_id;
  transport_id = ctl_transport_subscribe (CTL_TRANSPORT (self->dbus),
                                          iface, signal_name,
                                          proxy_forward_signal,
                                          fwd, g_free);
  g_hash_table_insert (self->subscriptions,
                       GUINT_TO_POINTER (client_id),
                       GUINT_TO_POINTER (transport_id));
}

static void
proxy_handle_unsubscribe (CtlProxyServer *self, JsonObject *frame)
{
  guint client_id = (guint) json_object_get_int_member_with_default (
    frame, "sub", 0);
  gpointer transport_id;

  if (g_hash_table_lookup_extended (self->subscriptions,
                                    GUINT_TO_POINTER (client_id), NULL,
                                    &transport_id))
    {
      ctl_transport_unsubscribe (CTL_TRANSPORT (self->dbus),
                                 GPOINTER_TO_UINT (transport_id));
      g_hash_table_remove (self->subscriptions,
                           GUINT_TO_POINTER (client_id));
    }
}

static gboolean
proxy_stdin_readable (GObject *pollable, gpointer user_data)
{
  CtlProxyServer *self = user_data;
  gboolean eof = FALSE;
  GError *error = NULL;
  JsonObject *frame;
  const gchar *type;

  (void) pollable;

  frame = ctl_frame_read (self->in, &eof, &error);
  if (frame == NULL)
    {
      if (!eof)
        g_clear_error (&error);
      g_main_loop_quit (self->loop);
      return G_SOURCE_REMOVE;
    }

  type = json_object_get_string_member_with_default (frame, "type", "");
  if (g_strcmp0 (type, "call") == 0)
    proxy_handle_call (self, frame);
  else if (g_strcmp0 (type, "subscribe") == 0)
    proxy_handle_subscribe (self, frame);
  else if (g_strcmp0 (type, "unsubscribe") == 0)
    proxy_handle_unsubscribe (self, frame);
  /* hello and unknown types: ignore. */
  json_object_unref (frame);
  return G_SOURCE_CONTINUE;
}

/* ── Lifecycle ─────────────────────────────────────────────────────── */

static void
ctl_proxy_server_finalize (GObject *object)
{
  CtlProxyServer *self = CTL_PROXY_SERVER (object);
  if (self->stdin_source != NULL)
    {
      g_source_destroy (self->stdin_source);
      g_source_unref (self->stdin_source);
    }
  if (self->loop != NULL)
    g_main_loop_unref (self->loop);
  g_hash_table_unref (self->subscriptions);
  g_clear_object (&self->dbus);
  g_clear_object (&self->in);
  g_clear_object (&self->out);
  G_OBJECT_CLASS (ctl_proxy_server_parent_class)->finalize (object);
}

static void
ctl_proxy_server_class_init (CtlProxyServerClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ctl_proxy_server_finalize;
}

static void
ctl_proxy_server_init (CtlProxyServer *self)
{
  self->subscriptions = g_hash_table_new (g_direct_hash, g_direct_equal);
}

CtlProxyServer *
ctl_proxy_server_new (const gchar *instance, GError **error)
{
  CtlProxyServer *self;
  CtlDbusTransport *dbus = ctl_dbus_transport_new (instance, error);

  if (dbus == NULL)
    return NULL;

  self = g_object_new (CTL_TYPE_PROXY_SERVER, NULL);
  self->dbus = dbus;
  self->in = g_unix_input_stream_new (0, FALSE);
  self->out = g_unix_output_stream_new (1, FALSE);
  self->loop = g_main_loop_new (NULL, FALSE);
  return self;
}

gint
ctl_proxy_server_run (CtlProxyServer *self)
{
  JsonObject *hello;
  gboolean eof = FALSE;
  GError *error = NULL;

  /* Handshake: read the client hello, answer with ours. */
  hello = ctl_frame_read (self->in, &eof, &error);
  if (hello == NULL)
    {
      g_clear_error (&error);
      return CTL_EXIT_ERROR;
    }
  json_object_unref (hello);

  hello = ctl_frame_new_hello ();
  if (!ctl_frame_write (self->out, hello, &error))
    {
      json_object_unref (hello);
      g_clear_error (&error);
      return CTL_EXIT_ERROR;
    }
  json_object_unref (hello);

  self->stdin_source = g_pollable_input_stream_create_source (
    G_POLLABLE_INPUT_STREAM (self->in), NULL);
  g_source_set_callback (self->stdin_source,
                         G_SOURCE_FUNC (proxy_stdin_readable), self,
                         NULL);
  g_source_attach (self->stdin_source, NULL);

  g_main_loop_run (self->loop);
  return self->exit_code;
}
