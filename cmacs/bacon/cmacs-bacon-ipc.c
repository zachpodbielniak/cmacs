/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-bacon-ipc.c — parent-side socketpair IPC for CMacs ↔ bacon
 *
 * Reads length-prefixed JSON requests from the forked bacon child,
 * dispatches them via cmacs-eval-dispatch (same code as D-Bus), and
 * writes length-prefixed JSON responses back on the same fd.
 *
 * The GSource is attached to the CMacs GMainContext, so dispatch
 * happens on the Emacs main thread — safe for calling Emacs primitives.
 */

#include <config.h>

#ifdef HAVE_CMACS_BACON

#include "lisp.h"
#include "cmacs-bacon-ipc.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <json-glib/json-glib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

struct _CmacsBaconIpc
{
  int         fd;
  GSource    *source;
  GIOChannel *channel;
  GByteArray *read_buf;      /* incoming data accumulator */
};

/* ── Wire protocol helpers ─────────────────────────────────────────── */

/* Read exactly N bytes from fd into buf.  Returns TRUE on success,
   FALSE on EOF or error. */
static gboolean
read_exact (int fd, guint8 *buf, gsize n)
{
  gsize off = 0;
  while (off < n)
    {
      gssize r = read (fd, buf + off, n - off);
      if (r <= 0)
        return FALSE;
      off += (gsize)r;
    }
  return TRUE;
}

/* Write exactly N bytes to fd.  Returns TRUE on success. */
static gboolean
write_exact (int fd, const guint8 *buf, gsize n)
{
  gsize off = 0;
  while (off < n)
    {
      gssize w = write (fd, buf + off, n - off);
      if (w < 0)
        {
          if (errno == EINTR)
            continue;
          return FALSE;
        }
      off += (gsize)w;
    }
  return TRUE;
}

/* Write a length-prefixed JSON response. */
static void
ipc_write_response (int fd, JsonNode *root)
{
  JsonGenerator *gen;
  gchar *json;
  gsize len;
  guint32 net_len;

  gen = json_generator_new ();
  json_generator_set_root (gen, root);
  json = json_generator_to_data (gen, &len);
  g_object_unref (gen);

  net_len = GUINT32_TO_BE ((guint32)len);
  write_exact (fd, (const guint8 *)&net_len, 4);
  write_exact (fd, (const guint8 *)json, len);
  g_free (json);
}

/* Build a JSON response object with "id" and either "result" or "error". */
static void
ipc_send_result (int fd, gint64 id, const gchar *result)
{
  JsonNode *root;
  JsonObject *obj;

  obj = json_object_new ();
  json_object_set_int_member (obj, "id", id);
  json_object_set_string_member (obj, "result", result);

  root = json_node_new (JSON_NODE_OBJECT);
  json_node_set_object (root, obj);
  ipc_write_response (fd, root);
  json_node_unref (root);
  json_object_unref (obj);
}

static void
ipc_send_error (int fd, gint64 id, const gchar *message)
{
  JsonNode *root;
  JsonObject *obj;

  obj = json_object_new ();
  json_object_set_int_member (obj, "id", id);
  json_object_set_string_member (obj, "error", message);

  root = json_node_new (JSON_NODE_OBJECT);
  json_node_set_object (root, obj);
  ipc_write_response (fd, root);
  json_node_unref (root);
  json_object_unref (obj);
}

static void
ipc_send_void_result (int fd, gint64 id)
{
  ipc_send_result (fd, id, "nil");
}

/* ── Request dispatch ──────────────────────────────────────────────── */

static void
ipc_handle_request (CmacsBaconIpc *ipc, JsonObject *req)
{
  const gchar *method;
  gint64 id;
  JsonObject *params;

  id = json_object_get_int_member (req, "id");
  method = json_object_get_string_member (req, "method");
  params = json_object_get_object_member (req, "params");

  if (g_strcmp0 (method, "Eval") == 0)
    {
      const gchar *expr = json_object_get_string_member (params, "expression");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_eval (expr, &err);
      if (result != NULL)
        {
          ipc_send_result (ipc->fd, id, result);
          g_free (result);
        }
      else
        {
          ipc_send_error (ipc->fd, id, err->message);
          g_error_free (err);
        }
    }
  else if (g_strcmp0 (method, "FindFile") == 0)
    {
      const gchar *path = json_object_get_string_member (params, "path");
      cmacs_dispatch_find_file (path);
      ipc_send_void_result (ipc->fd, id);
    }
  else if (g_strcmp0 (method, "Message") == 0)
    {
      const gchar *text = json_object_get_string_member (params, "text");
      cmacs_dispatch_message (text);
      ipc_send_void_result (ipc->fd, id);
    }
  else if (g_strcmp0 (method, "GiRequire") == 0)
    {
      const gchar *ns = json_object_get_string_member (params, "namespace");
      const gchar *ver = json_object_get_string_member (params, "version");
      GError *err = NULL;
      gboolean ok = cmacs_dispatch_gi_require (ns, ver, &err);
      if (err != NULL)
        {
          ipc_send_error (ipc->fd, id, err->message);
          g_error_free (err);
        }
      else
        ipc_send_result (ipc->fd, id, ok ? "t" : "nil");
    }
  else if (g_strcmp0 (method, "GiCall") == 0)
    {
      const gchar *ns = json_object_get_string_member (params, "namespace");
      const gchar *func = json_object_get_string_member (params, "function");
      JsonArray *args_json = json_object_get_array_member (params, "args");
      guint n_args = args_json ? json_array_get_length (args_json) : 0;
      const gchar **args;
      GError *err = NULL;
      gchar *result;
      guint i;

      args = g_new (const gchar *, n_args);
      for (i = 0; i < n_args; i++)
        args[i] = json_array_get_string_element (args_json, i);

      result = cmacs_dispatch_gi_call (ns, func, args, (gint)n_args, &err);
      g_free (args);

      if (result != NULL)
        {
          ipc_send_result (ipc->fd, id, result);
          g_free (result);
        }
      else
        {
          ipc_send_error (ipc->fd, id, err->message);
          g_error_free (err);
        }
    }
  else if (g_strcmp0 (method, "GiListFunctions") == 0)
    {
      const gchar *ns = json_object_get_string_member (params, "namespace");
      gchar **funcs = cmacs_dispatch_gi_list_functions (ns);
      gchar *joined = g_strjoinv ("\n", funcs);
      ipc_send_result (ipc->fd, id, joined);
      g_free (joined);
      g_strfreev (funcs);
    }
  else
    {
      ipc_send_error (ipc->fd, id, "unknown method");
    }
}

/* ── GSource callback ──────────────────────────────────────────────── */

static gboolean
ipc_source_callback (GIOChannel *source, GIOCondition condition,
                     gpointer user_data)
{
  CmacsBaconIpc *ipc = user_data;
  guint32 net_len;
  guint32 msg_len;
  guint8 *msg_buf;
  JsonParser *parser;
  JsonNode *root;
  JsonObject *obj;

  (void)source;

  if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    {
      /* Child disconnected or error — clean up. */
      return FALSE;
    }

  /* Read length prefix. */
  if (!read_exact (ipc->fd, (guint8 *)&net_len, 4))
    return FALSE;

  msg_len = GUINT32_FROM_BE (net_len);
  if (msg_len == 0 || msg_len > 16 * 1024 * 1024)
    return FALSE;

  /* Read payload. */
  msg_buf = g_malloc (msg_len + 1);
  if (!read_exact (ipc->fd, msg_buf, msg_len))
    {
      g_free (msg_buf);
      return FALSE;
    }
  msg_buf[msg_len] = '\0';

  /* Parse JSON. */
  parser = json_parser_new ();
  if (json_parser_load_from_data (parser, (const gchar *)msg_buf,
                                  (gssize)msg_len, NULL))
    {
      root = json_parser_get_root (parser);
      if (root != NULL && JSON_NODE_HOLDS_OBJECT (root))
        {
          obj = json_node_get_object (root);
          ipc_handle_request (ipc, obj);
        }
    }
  g_object_unref (parser);
  g_free (msg_buf);

  return TRUE;
}

/* ── Public API ────────────────────────────────────────────────────── */

CmacsBaconIpc *
cmacs_bacon_ipc_new (int fd, GMainContext *ctx)
{
  CmacsBaconIpc *ipc;

  ipc = g_new0 (CmacsBaconIpc, 1);
  ipc->fd = fd;
  ipc->read_buf = g_byte_array_new ();

  ipc->channel = g_io_channel_unix_new (fd);
  g_io_channel_set_encoding (ipc->channel, NULL, NULL);
  g_io_channel_set_buffered (ipc->channel, FALSE);

  ipc->source = g_io_create_watch (ipc->channel,
                                    G_IO_IN | G_IO_HUP | G_IO_ERR);
  g_source_set_callback (ipc->source,
                         G_SOURCE_FUNC (ipc_source_callback),
                         ipc, NULL);
  g_source_attach (ipc->source, ctx);

  return ipc;
}

void
cmacs_bacon_ipc_destroy (CmacsBaconIpc *ipc)
{
  if (ipc == NULL)
    return;

  if (ipc->source != NULL)
    {
      g_source_destroy (ipc->source);
      g_source_unref (ipc->source);
    }
  if (ipc->channel != NULL)
    g_io_channel_unref (ipc->channel);
  if (ipc->read_buf != NULL)
    g_byte_array_free (ipc->read_buf, TRUE);
  if (ipc->fd >= 0)
    close (ipc->fd);
  g_free (ipc);
}

#endif /* HAVE_CMACS_BACON */
