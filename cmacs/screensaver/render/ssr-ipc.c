/* ssr-ipc.c --- child-side control IPC.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include "ssr-ipc.h"

#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <gio/gunixfdmessage.h>
#include <string.h>

struct _SsrIpc
{
  GObject          parent_instance;
  GSocket         *socket;        /* owns the inherited fd */
  GSource         *source;        /* G_IO_IN watch on the socket */
  SsrIpcCallbacks  cb;
  gpointer         user;
  gboolean         quit_sent;     /* coalesce repeated quit callbacks */
};

G_DEFINE_FINAL_TYPE (SsrIpc, ssr_ipc, G_TYPE_OBJECT)

/* ---- low-level send ------------------------------------------------------ */

/* Send JSON as one datagram, optionally with MEMFD attached via SCM_RIGHTS.
 * Takes ownership of nothing; MEMFD is dup'd by the kernel/g_unix_fd_message. */
static gboolean
ipc_send (SsrIpc *self, const gchar *json, int memfd, GError **error)
{
  GOutputVector ov;
  GSocketControlMessage *cm = NULL;
  GSocketControlMessage **cmv = NULL;
  gint n_cm = 0;
  gssize w;

  if (self->socket == NULL)
    return FALSE;

  ov.buffer = json;
  ov.size = strlen (json);

  if (memfd >= 0)
    {
      GUnixFDMessage *fdm = G_UNIX_FD_MESSAGE (g_unix_fd_message_new ());
      if (!g_unix_fd_message_append_fd (fdm, memfd, error))
        {
          g_object_unref (fdm);
          return FALSE;
        }
      cm = G_SOCKET_CONTROL_MESSAGE (fdm);
      cmv = &cm;
      n_cm = 1;
    }

  w = g_socket_send_message (self->socket, NULL, &ov, 1, cmv, n_cm,
                             G_SOCKET_MSG_NONE, NULL, error);
  if (cm != NULL)
    g_object_unref (cm);
  return w >= 0;
}

static void
ipc_send_simple (SsrIpc *self, const gchar *type)
{
  gchar *json = scr_proto_build_simple (type);
  ipc_send (self, json, -1, NULL);
  g_free (json);
}

/* ---- public sends -------------------------------------------------------- */

gboolean
ssr_ipc_send_frame_buffer (SsrIpc *self, const ScrFrameBuffer *fb,
                           int memfd, GError **error)
{
  gchar *json = scr_proto_build_frame_buffer (fb);
  gboolean ok = ipc_send (self, json, memfd, error);
  g_free (json);
  return ok;
}

void
ssr_ipc_send_load_result (SsrIpc *self, const ScrLoadResult *lr)
{
  gchar *json = scr_proto_build_load_result (lr);
  ipc_send (self, json, -1, NULL);
  g_free (json);
}

void
ssr_ipc_send_heartbeat (SsrIpc *self, gint64 seq)
{
  gchar *json = scr_proto_build_heartbeat (seq);
  ipc_send (self, json, -1, NULL);
  g_free (json);
}

void
ssr_ipc_send_stopped (SsrIpc *self, const gchar *reason)
{
  GString *s = g_string_new (NULL);
  /* tiny inline build; keeps the reason out of the shared proto vocabulary */
  g_string_printf (s, "{\"t\":\"%s\",\"reason\":", SCR_MSG_STOPPED);
  {
    gchar *esc = g_strescape (reason ? reason : "", NULL);
    g_string_append_printf (s, "\"%s\"}", esc);
    g_free (esc);
  }
  ipc_send (self, s->str, -1, NULL);
  g_string_free (s, TRUE);
}

/* ---- receive / dispatch -------------------------------------------------- */

static void
ipc_emit_quit (SsrIpc *self)
{
  if (self->quit_sent)
    return;
  self->quit_sent = TRUE;
  if (self->cb.quit != NULL)
    self->cb.quit (self->user);
}

static void
ipc_dispatch (SsrIpc *self, const gchar *json, gssize len)
{
  gchar *type = scr_proto_message_type (json, len);

  if (type == NULL)
    return;                       /* malformed datagram: ignore, never crash */

  if (g_strcmp0 (type, SCR_MSG_HELLO) == 0)
    {
      int ver = 0;
      scr_proto_parse_hello (json, len, &ver);
      if (ver != SCR_PROTO_VERSION)
        {
          ssr_ipc_send_stopped (self, "protocol version mismatch");
          ipc_emit_quit (self);
        }
      else
        ipc_send_simple (self, SCR_MSG_HELLO_ACK);
    }
  else if (g_strcmp0 (type, SCR_MSG_SET_TARGET) == 0)
    {
      ScrSetTarget t;
      if (scr_proto_parse_set_target (json, len, &t))
        {
          if (self->cb.set_target != NULL)
            self->cb.set_target (&t, self->user);
          scr_set_target_clear (&t);
        }
    }
  else if (g_strcmp0 (type, SCR_MSG_REMOVE_TARGET) == 0)
    {
      int sink = 0;
      gchar *mon = NULL;
      if (scr_proto_parse_remove_target (json, len, &sink, &mon))
        {
          if (self->cb.remove_target != NULL)
            self->cb.remove_target (sink, mon, self->user);
          g_free (mon);
        }
    }
  else if (g_strcmp0 (type, SCR_MSG_SET_FPS) == 0)
    {
      int fps = 0;
      if (scr_proto_parse_set_fps (json, len, &fps) && self->cb.set_fps != NULL)
        self->cb.set_fps (fps, self->user);
    }
  else if (g_strcmp0 (type, SCR_MSG_PAUSE) == 0)
    {
      gboolean paused = FALSE;
      if (scr_proto_parse_pause (json, len, &paused) && self->cb.set_pause != NULL)
        self->cb.set_pause (paused, self->user);
    }
  else if (g_strcmp0 (type, SCR_MSG_PING) == 0)
    {
      ipc_send_simple (self, SCR_MSG_PONG);
    }
  else if (g_strcmp0 (type, SCR_MSG_QUIT) == 0)
    {
      ipc_emit_quit (self);
    }
  /* unknown types are ignored */

  g_free (type);
}

static gboolean
ipc_on_readable (GSocket *socket, GIOCondition condition, gpointer user_data)
{
  SsrIpc *self = user_data;
  guint8 buf[SCR_MSG_MAX_BYTES];
  GInputVector iv;
  GSocketControlMessage **cmsgs = NULL;
  gint n_cmsgs = 0;
  gint flags = 0;
  GError *err = NULL;
  gssize n;
  gint i;

  if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    {
      ipc_emit_quit (self);
      return G_SOURCE_REMOVE;
    }

  iv.buffer = buf;
  iv.size = sizeof buf;
  n = g_socket_receive_message (socket, NULL, &iv, 1,
                                &cmsgs, &n_cmsgs, &flags, NULL, &err);

  /* The parent never sends fds to the child; drop any we somehow received. */
  for (i = 0; i < n_cmsgs; i++)
    g_object_unref (cmsgs[i]);
  g_free (cmsgs);

  if (n == 0)
    {
      /* Orderly EOF: parent closed the socket. */
      ipc_emit_quit (self);
      return G_SOURCE_REMOVE;
    }
  if (n < 0)
    {
      gboolean would_block = g_error_matches (err, G_IO_ERROR,
                                              G_IO_ERROR_WOULD_BLOCK);
      g_clear_error (&err);
      if (would_block)
        return G_SOURCE_CONTINUE;
      ipc_emit_quit (self);
      return G_SOURCE_REMOVE;
    }

  ipc_dispatch (self, (const gchar *) buf, n);
  return G_SOURCE_CONTINUE;
}

/* ---- lifecycle ----------------------------------------------------------- */

static void
ssr_ipc_init (SsrIpc *self)
{
  self->socket = NULL;
  self->source = NULL;
  self->quit_sent = FALSE;
}

static void
ssr_ipc_finalize (GObject *object)
{
  SsrIpc *self = SSR_IPC (object);

  if (self->source != NULL)
    {
      g_source_destroy (self->source);
      g_source_unref (self->source);
      self->source = NULL;
    }
  if (self->socket != NULL)
    {
      g_socket_close (self->socket, NULL);
      g_clear_object (&self->socket);
    }
  G_OBJECT_CLASS (ssr_ipc_parent_class)->finalize (object);
}

static void
ssr_ipc_class_init (SsrIpcClass *klass)
{
  G_OBJECT_CLASS (klass)->finalize = ssr_ipc_finalize;
}

SsrIpc *
ssr_ipc_new (int fd, const SsrIpcCallbacks *cb, gpointer user)
{
  SsrIpc *self;
  GSocket *socket;
  GError *err = NULL;

  socket = g_socket_new_from_fd (fd, &err);
  if (socket == NULL)
    {
      g_warning ("cmacs-screensaver-render: g_socket_new_from_fd: %s",
                 err ? err->message : "unknown");
      g_clear_error (&err);
      return NULL;
    }
  g_socket_set_blocking (socket, FALSE);

  self = g_object_new (SSR_TYPE_IPC, NULL);
  self->socket = socket;
  self->cb = *cb;
  self->user = user;

  self->source = g_socket_create_source (socket,
                                         G_IO_IN | G_IO_HUP | G_IO_ERR, NULL);
  g_source_set_callback (self->source, G_SOURCE_FUNC (ipc_on_readable),
                         self, NULL);
  g_source_attach (self->source, NULL);   /* default (main loop) context */

  return self;
}
