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
 *
 * The IPC is fully non-blocking: the GIOChannel callback accumulates
 * bytes incrementally, complete messages are queued, and dispatch
 * happens via idle callbacks to avoid blocking the GLib event loop.
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
#include <fcntl.h>

/* ── Request queue entry ──────────────────────────────────────────── */

typedef struct
{
  gint64      id;
  gchar      *method;
  JsonObject *params;    /* owned ref */
} IpcRequest;

static void
ipc_request_free (IpcRequest *req)
{
  if (req == NULL)
    return;
  g_free (req->method);
  if (req->params != NULL)
    json_object_unref (req->params);
  g_free (req);
}

struct _CmacsBaconIpc
{
  int          fd;
  GSource     *source;
  GIOChannel  *channel;
  GByteArray  *read_buf;      /* incoming data accumulator */
  GQueue      *pending;       /* queue of IpcRequest* */
  GSource     *idle_source;   /* dispatch idle, NULL when not scheduled */
  GMainContext *ctx;           /* the GMainContext we attach to */
};

/* ── Wire protocol helpers ─────────────────────────────────────────── */

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

/* A string member of PARAMS, or NULL when PARAMS is absent, the member
   is missing, or it is not a string.  json_object_get_string_member
   g-warns and returns NULL on a missing member, and the handlers used to
   pass that NULL straight into build_string -- a frame from the child
   with a typo in it crashed the editor. */
static gint64
ipc_param_int (JsonObject *params, const gchar *key)
{
  if (params == NULL)
    return 0;
  return json_object_get_int_member_with_default (params, key, 0);
}

static gdouble
ipc_param_double (JsonObject *params, const gchar *key)
{
  if (params == NULL)
    return 0.0;
  return json_object_get_double_member_with_default (params, key, 0.0);
}

static gboolean
ipc_param_bool (JsonObject *params, const gchar *key)
{
  if (params == NULL)
    return FALSE;
  return json_object_get_boolean_member_with_default (params, key, FALSE);
}

static const gchar *
ipc_param_string (JsonObject *params, const gchar *key)
{
  if (params == NULL)
    return NULL;
  return json_object_get_string_member_with_default (params, key, NULL);
}

/* Reply with an error naming the missing parameter.  Every handler that
   needs a string goes through IPC_REQUIRE_STRING so the check cannot be
   forgotten on the next method added. */
#define IPC_REQUIRE_STRING(var, key)                                    \
  do {                                                                  \
    var = ipc_param_string (params, key);                               \
    if (var == NULL)                                                    \
      {                                                                 \
        g_autofree gchar *m_ =                                          \
          g_strdup_printf ("missing string parameter: %s", key);        \
        ipc_send_error (ipc->fd, id, m_);                               \
        return;                                                         \
      }                                                                 \
  } while (0)

/* ── Request dispatch (runs from idle callback) ───────────────────── */

static void
ipc_handle_request (CmacsBaconIpc *ipc, IpcRequest *req)
{
  const gchar *method = req->method;
  gint64 id = req->id;
  JsonObject *params = req->params;

  if (g_strcmp0 (method, "Eval") == 0)
    {
      const gchar *expr;
      IPC_REQUIRE_STRING (expr, "expression");
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
      const gchar *path;
      IPC_REQUIRE_STRING (path, "path");
      cmacs_dispatch_find_file (path);
      ipc_send_void_result (ipc->fd, id);
    }
  else if (g_strcmp0 (method, "Message") == 0)
    {
      const gchar *text;
      IPC_REQUIRE_STRING (text, "text");
      cmacs_dispatch_message (text);
      ipc_send_void_result (ipc->fd, id);
    }
  else if (g_strcmp0 (method, "GiRequire") == 0)
    {
      const gchar *ns;
      IPC_REQUIRE_STRING (ns, "namespace");
      const gchar *ver;
      IPC_REQUIRE_STRING (ver, "version");
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
      const gchar *ns;
      IPC_REQUIRE_STRING (ns, "namespace");
      const gchar *func;
      IPC_REQUIRE_STRING (func, "function");
      JsonArray *args_json =
        (params != NULL && json_object_has_member (params, "args")
         && JSON_NODE_HOLDS_ARRAY (json_object_get_member (params, "args")))
        ? json_object_get_array_member (params, "args") : NULL;
      guint n_args = args_json ? json_array_get_length (args_json) : 0;
      const gchar **args;
      GError *err = NULL;
      gchar *result;
      guint i;

      args = g_new (const gchar *, n_args);
      for (i = 0; i < n_args; i++)
        {
          JsonNode *el = json_array_get_element (args_json, i);
          /* A non-string element reads as nil rather than dereferencing
             a NULL further down. */
          args[i] = (el != NULL && JSON_NODE_HOLDS_VALUE (el)
                     && json_node_get_value_type (el) == G_TYPE_STRING)
            ? json_node_get_string (el) : "nil";
        }

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
      const gchar *ns;
      IPC_REQUIRE_STRING (ns, "namespace");
      gchar **funcs = cmacs_dispatch_gi_list_functions (ns);
      gchar *joined = g_strjoinv ("\n", funcs);
      ipc_send_result (ipc->fd, id, joined);
      g_free (joined);
      g_strfreev (funcs);
    }
#ifdef HAVE_CMACS_GOWL

  /* ── Gowl compositor methods (bypass elisp for performance) ──────── */

  else if (g_strcmp0 (method, "GowlListClients") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_clients (&err);
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
  else if (g_strcmp0 (method, "GowlFocusedClient") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_focused_client (&err);
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
  else if (g_strcmp0 (method, "GowlSpawn") == 0)
    {
      const gchar *command;
      IPC_REQUIRE_STRING (command, "command");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_spawn (command, &err);
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
  else if (g_strcmp0 (method, "GowlListMonitors") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_monitors (&err);
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
  else if (g_strcmp0 (method, "GowlAddKeybind") == 0)
    {
      const gchar *key;
      IPC_REQUIRE_STRING (key, "key");
      gint action = (gint)ipc_param_int (params, "action");
      const gchar *arg = ipc_param_string (params, "arg") ? ipc_param_string (params, "arg") : NULL;
      const gchar *desc = ipc_param_string (params, "desc");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_add_keybind (key, action, arg,
                                                         desc, &err);
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
  else if (g_strcmp0 (method, "GowlListKeybinds") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_list_keybinds (&err);
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
  else if (g_strcmp0 (method, "GowlAddRule") == 0)
    {
      const gchar *app_id = ipc_param_string (params, "app_id") ? ipc_param_string (params, "app_id") : NULL;
      const gchar *title = ipc_param_string (params, "title") ? ipc_param_string (params, "title") : NULL;
      guint32 tags = (guint32)ipc_param_int (params, "tags");
      gboolean floating = ipc_param_bool (params, "floating");
      gint monitor = (gint)ipc_param_int (params, "monitor");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_add_rule (app_id, title, tags,
                                                      floating, monitor, &err);
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
  else if (g_strcmp0 (method, "GowlSetMfact") == 0)
    {
      gdouble mfact = ipc_param_double (params, "mfact");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_mfact (mfact, &err);
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
  else if (g_strcmp0 (method, "GowlSetNmaster") == 0)
    {
      gint n = (gint)ipc_param_int (params, "n");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_nmaster (n, &err);
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
  else if (g_strcmp0 (method, "GowlViewTags") == 0)
    {
      guint32 tagmask = (guint32)ipc_param_int (params, "tagmask");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_view_tags (tagmask, &err);
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
  else if (g_strcmp0 (method, "GowlLock") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_lock (&err);
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
  else if (g_strcmp0 (method, "GowlUnlock") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_unlock (&err);
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
  else if (g_strcmp0 (method, "GowlReloadConfig") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_reload_config (&err);
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
  else if (g_strcmp0 (method, "GowlConfigGet") == 0)
    {
      const gchar *property;
      IPC_REQUIRE_STRING (property, "property");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_config_get (property, &err);
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
  else if (g_strcmp0 (method, "GowlFindClient") == 0)
    {
      const gchar *pattern;
      IPC_REQUIRE_STRING (pattern, "pattern");
      const gchar *by = ipc_param_string (params, "by") ? ipc_param_string (params, "by") : "app-id";
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_find_client (pattern, by, &err);
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
  else if (g_strcmp0 (method, "GowlMonitorInfo") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_monitor_info (name, &err);
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
  else if (g_strcmp0 (method, "GowlMonitorModes") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_monitor_modes (name, &err);
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
  else if (g_strcmp0 (method, "GowlSetMonitorMode") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      gint w = (gint)ipc_param_int (params, "width");
      gint h = (gint)ipc_param_int (params, "height");
      gint refresh = (gint)ipc_param_int (params, "refresh_mhz");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_monitor_mode (name, w, h,
                                                              refresh, &err);
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
  else if (g_strcmp0 (method, "GowlMonitorPosition") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_monitor_position (name, &err);
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
  else if (g_strcmp0 (method, "GowlSetMonitorPosition") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      gint x = (gint)ipc_param_int (params, "x");
      gint y = (gint)ipc_param_int (params, "y");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_monitor_pos (name, x, y, &err);
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
  else if (g_strcmp0 (method, "GowlSetMonitorEnabled") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      gboolean en = ipc_param_bool (params, "enabled");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_monitor_enabled (name, en,
                                                                 &err);
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
  else if (g_strcmp0 (method, "GowlSetMonitorScale") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      gdouble scale = ipc_param_double (params, "scale");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_monitor_scale (name, scale,
                                                               &err);
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
  else if (g_strcmp0 (method, "GowlSetMonitorTransform") == 0)
    {
      const gchar *name;
      IPC_REQUIRE_STRING (name, "name");
      gint xform = (gint)ipc_param_int (params, "transform");
      GError *err = NULL;
      gchar *result = cmacs_dispatch_gowl_set_monitor_transform (name,
                                                                    xform,
                                                                    &err);
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

#endif /* HAVE_CMACS_GOWL */

  else
    {
      ipc_send_error (ipc->fd, id, "unknown method");
    }
}

/* ── Idle dispatch callback ───────────────────────────────────────── */

static gboolean
ipc_idle_dispatch (gpointer user_data)
{
  CmacsBaconIpc *ipc = user_data;
  IpcRequest *req;

  req = g_queue_pop_head (ipc->pending);
  if (req == NULL)
    {
      /* Queue drained — remove idle source. */
      ipc->idle_source = NULL;
      return G_SOURCE_REMOVE;
    }

  ipc_handle_request (ipc, req);
  ipc_request_free (req);

  /* Keep running if more requests are pending. */
  if (!g_queue_is_empty (ipc->pending))
    return G_SOURCE_CONTINUE;

  ipc->idle_source = NULL;
  return G_SOURCE_REMOVE;
}

/* Schedule the idle dispatch if not already scheduled. */
static void
ipc_schedule_dispatch (CmacsBaconIpc *ipc)
{
  if (ipc->idle_source != NULL)
    return;  /* already scheduled */

  ipc->idle_source = g_idle_source_new ();
  g_source_set_callback (ipc->idle_source, ipc_idle_dispatch, ipc, NULL);
  g_source_attach (ipc->idle_source, ipc->ctx);
  g_source_unref (ipc->idle_source);  /* context holds ref */
}

/* ── Message extraction from read buffer ──────────────────────────── */

/* Try to extract one complete message from read_buf.
   Returns TRUE and fills *req_out if a complete message was found.
   Returns FALSE if more data is needed. */
static gboolean
ipc_try_extract_message (CmacsBaconIpc *ipc, IpcRequest **req_out)
{
  guint32 net_len, msg_len;
  JsonParser *parser;
  JsonNode *root;
  JsonObject *obj;
  IpcRequest *req;

  /* Need at least 4 bytes for the length prefix. */
  if (ipc->read_buf->len < 4)
    return FALSE;

  memcpy (&net_len, ipc->read_buf->data, 4);
  msg_len = GUINT32_FROM_BE (net_len);

  if (msg_len == 0 || msg_len > 16 * 1024 * 1024)
    {
      /* Protocol error — discard everything. */
      g_byte_array_set_size (ipc->read_buf, 0);
      return FALSE;
    }

  /* Need 4 + msg_len bytes total. */
  if (ipc->read_buf->len < 4 + msg_len)
    return FALSE;

  /* Parse JSON payload. */
  parser = json_parser_new ();
  if (!json_parser_load_from_data (parser,
                                    (const gchar *)(ipc->read_buf->data + 4),
                                    (gssize)msg_len, NULL))
    {
      g_object_unref (parser);
      /* Consume the bad message. */
      g_byte_array_remove_range (ipc->read_buf, 0, 4 + msg_len);
      return FALSE;
    }

  root = json_parser_get_root (parser);
  if (root == NULL || !JSON_NODE_HOLDS_OBJECT (root))
    {
      g_object_unref (parser);
      g_byte_array_remove_range (ipc->read_buf, 0, 4 + msg_len);
      return FALSE;
    }

  obj = json_node_get_object (root);

  /* Build the request. */
  req = g_new0 (IpcRequest, 1);
  req->id = json_object_get_int_member_with_default (obj, "id", 0);
  req->method = g_strdup (
    json_object_get_string_member_with_default (obj, "method", ""));

  if (json_object_has_member (obj, "params")
      && JSON_NODE_HOLDS_OBJECT (json_object_get_member (obj, "params")))
    {
      req->params = json_object_ref (
        json_object_get_object_member (obj, "params"));
    }

  g_object_unref (parser);

  /* Consume the message from the buffer. */
  g_byte_array_remove_range (ipc->read_buf, 0, 4 + msg_len);

  *req_out = req;
  return TRUE;
}

/* ── GSource callback (non-blocking read) ─────────────────────────── */

static gboolean
ipc_source_callback (GIOChannel *source, GIOCondition condition,
                     gpointer user_data)
{
  CmacsBaconIpc *ipc = user_data;
  guint8 chunk[4096];
  IpcRequest *req;

  (void)source;

  if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    {
      /* Child disconnected or error — clean up. */
      return FALSE;
    }

  /* Read all available data (non-blocking). */
  for (;;)
    {
      gssize n = read (ipc->fd, chunk, sizeof (chunk));
      if (n > 0)
        {
          g_byte_array_append (ipc->read_buf, chunk, (guint)n);
        }
      else if (n == 0)
        {
          /* EOF — child closed its end. */
          return FALSE;
        }
      else
        {
          if (errno == EAGAIN)
            break;  /* no more data available */
          if (errno == EINTR)
            continue;
          return FALSE;  /* real error */
        }
    }

  /* Extract all complete messages and queue them. */
  while (ipc_try_extract_message (ipc, &req))
    {
      g_queue_push_tail (ipc->pending, req);
    }

  /* Schedule idle dispatch if we queued anything. */
  if (!g_queue_is_empty (ipc->pending))
    ipc_schedule_dispatch (ipc);

  return TRUE;
}

/* ── Public API ────────────────────────────────────────────────────── */

CmacsBaconIpc *
cmacs_bacon_ipc_new (int fd, GMainContext *ctx)
{
  CmacsBaconIpc *ipc;
  int flags;

  ipc = g_new0 (CmacsBaconIpc, 1);
  ipc->fd = fd;
  ipc->ctx = ctx;
  ipc->read_buf = g_byte_array_new ();
  ipc->pending = g_queue_new ();
  ipc->idle_source = NULL;

  /* Set fd to non-blocking so the GSource callback never blocks. */
  flags = fcntl (fd, F_GETFL);
  if (flags >= 0)
    fcntl (fd, F_SETFL, flags | O_NONBLOCK);

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

  if (ipc->idle_source != NULL)
    {
      g_source_destroy (ipc->idle_source);
      ipc->idle_source = NULL;
    }
  if (ipc->source != NULL)
    {
      g_source_destroy (ipc->source);
      g_source_unref (ipc->source);
    }
  if (ipc->channel != NULL)
    g_io_channel_unref (ipc->channel);
  if (ipc->read_buf != NULL)
    g_byte_array_free (ipc->read_buf, TRUE);
  if (ipc->pending != NULL)
    {
      g_queue_free_full (ipc->pending, (GDestroyNotify)ipc_request_free);
    }
  if (ipc->fd >= 0)
    close (ipc->fd);
  g_free (ipc);
}

#endif /* HAVE_CMACS_BACON */
