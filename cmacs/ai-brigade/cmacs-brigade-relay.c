/* cmacs-brigade-relay.c --- `emacs --mcp-relay': a scoped MCP bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Why this exists at all: cmacs's MCP server listens on a Unix socket,
 * but `claude --mcp-config' only understands a stdio command or an HTTP
 * URL.  A CLI agent therefore cannot reach cmacs directly.  This relay
 * is the stdio command it does understand -- it speaks NDJSON on stdin
 * and stdout, forwards to the socket, and enforces the agent's
 * allowlist in between.
 *
 * It follows the `--bacon' / `--cmacs-lsp' never-return model: the hook
 * runs in main() before any Emacs initialisation, so no Lisp VM ever
 * starts in this process.  That is not an optimisation, it is the
 * security property.  The relay is the thing standing between an agent
 * and the editor's whole tool surface; if it could evaluate Lisp, an
 * agent that got a prompt injection through would be evaluating Lisp
 * inside the process that is supposed to be restraining it.  stdout is
 * protocol-only for the same reason -- a stray message would corrupt
 * the JSON-RPC stream.
 *
 * Filtering happens in two places:
 *
 *   tools/list  responses are pruned to what the allowlist admits, so
 *               the agent never learns a forbidden tool exists.  Hiding
 *               is better than refusing: a model that can see `eval'
 *               will keep trying it and burn turns.
 *   tools/call  requests for anything else are answered locally with a
 *               JSON-RPC error and never reach cmacs.
 *
 * The allowlist arrives as CMACS_BRIGADE_ALLOW in the environment,
 * written into the agent's 0600 .mcp.json `env' block.  It is not a
 * command-line argument because argv is world-readable through /proc,
 * and the token beside it must not be.
 */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "cmacs-brigade.h"

#include <glib.h>
#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>
#include <json-glib/json-glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guard rails on a stream that an agent controls the far end of.  A
 * 16 MiB line is already far past anything MCP legitimately produces;
 * without a cap a hostile or wedged peer can drive us to OOM. */
#define RELAY_MAX_LINE (16 * 1024 * 1024)

typedef struct
{
  const gchar     *allowlist;
  GDataInputStream *from_cmacs;
  GOutputStream    *to_cmacs;
  GOutputStream    *to_agent;
} RelayCtx;

/* Write LINE plus a newline, flushing so the peer sees it immediately.
 * Returns FALSE when the far end has gone. */
static gboolean
relay_write (GOutputStream *out, const gchar *line)
{
  gsize written;

  if (!g_output_stream_write_all (out, line, strlen (line), &written,
                                  NULL, NULL))
    return FALSE;
  if (!g_output_stream_write_all (out, "\n", 1, &written, NULL, NULL))
    return FALSE;
  return g_output_stream_flush (out, NULL, NULL);
}

/* Emit a JSON-RPC error for ID without troubling cmacs. */
static gboolean
relay_deny (GOutputStream *to_agent, JsonNode *id, const gchar *message)
{
  g_autoptr (JsonBuilder) b = json_builder_new ();
  g_autoptr (JsonNode) root = NULL;
  g_autofree gchar *text = NULL;

  json_builder_begin_object (b);
  json_builder_set_member_name (b, "jsonrpc");
  json_builder_add_string_value (b, "2.0");
  json_builder_set_member_name (b, "id");
  if (id != NULL)
    json_builder_add_value (b, json_node_copy (id));
  else
    json_builder_add_null_value (b);
  json_builder_set_member_name (b, "error");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "code");
  /* -32601 "method not found" rather than a permission code: as far as
   * this agent is concerned the tool does not exist, which is also what
   * tools/list told it. */
  json_builder_add_int_value (b, -32601);
  json_builder_set_member_name (b, "message");
  json_builder_add_string_value (b, message);
  json_builder_end_object (b);
  json_builder_end_object (b);

  root = json_builder_get_root (b);
  text = json_to_string (root, FALSE);
  return relay_write (to_agent, text);
}

/* Prune a tools/list result to the tools the allowlist admits.
 * Returns a newly allocated line, or NULL to forward unchanged. */
static gchar *
relay_filter_tools_list (JsonObject *root, const gchar *allowlist)
{
  JsonObject *result;
  JsonArray *tools, *kept;
  guint i, n;

  result = json_object_get_object_member (root, "result");
  if (result == NULL || !json_object_has_member (result, "tools"))
    return NULL;
  tools = json_object_get_array_member (result, "tools");
  if (tools == NULL) return NULL;

  kept = json_array_new ();
  n = json_array_get_length (tools);
  for (i = 0; i < n; i++)
    {
      JsonNode *el = json_array_get_element (tools, i);
      JsonObject *t = JSON_NODE_HOLDS_OBJECT (el)
        ? json_node_get_object (el) : NULL;
      const gchar *name = t ? json_object_get_string_member_with_default
        (t, "name", NULL) : NULL;

      if (name != NULL && cmacs_brigade_tool_allowed (allowlist, name))
        json_array_add_element (kept, json_node_copy (el));
    }

  json_object_set_array_member (result, "tools", kept);
  {
    g_autoptr (JsonNode) node = json_node_new (JSON_NODE_OBJECT);
    json_node_set_object (node, root);
    return json_to_string (node, FALSE);
  }
}

/* Handle one line from the agent.  Returns FALSE to stop the relay. */
static gboolean
relay_from_agent (RelayCtx *ctx, const gchar *line)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  JsonObject *root;
  const gchar *method;

  if (!json_parser_load_from_data (parser, line, -1, NULL)
      || !JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser)))
    /* Not our business to validate the peer's JSON -- forward it and
     * let cmacs answer with a parse error. */
    return relay_write (ctx->to_cmacs, line);

  root = json_node_get_object (json_parser_get_root (parser));
  method = json_object_get_string_member_with_default (root, "method", NULL);

  if (g_strcmp0 (method, "tools/call") == 0)
    {
      JsonObject *params = json_object_get_object_member (root, "params");
      const gchar *name = params
        ? json_object_get_string_member_with_default (params, "name", NULL)
        : NULL;

      if (name == NULL || !cmacs_brigade_tool_allowed (ctx->allowlist, name))
        {
          g_autofree gchar *msg =
            g_strdup_printf ("Unknown tool: %s", name ? name : "(unnamed)");
          return relay_deny (ctx->to_agent,
                             json_object_has_member (root, "id")
                             ? json_object_get_member (root, "id") : NULL,
                             msg);
        }
    }

  return relay_write (ctx->to_cmacs, line);
}

/* Handle one line from cmacs.  Returns FALSE to stop the relay. */
static gboolean
relay_from_cmacs (RelayCtx *ctx, const gchar *line)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  g_autofree gchar *filtered = NULL;
  JsonObject *root;

  if (!json_parser_load_from_data (parser, line, -1, NULL)
      || !JSON_NODE_HOLDS_OBJECT (json_parser_get_root (parser)))
    return relay_write (ctx->to_agent, line);

  root = json_node_get_object (json_parser_get_root (parser));
  filtered = relay_filter_tools_list (root, ctx->allowlist);
  return relay_write (ctx->to_agent, filtered ? filtered : line);
}

/* Pump cmacs -> agent on its own thread.
 *
 * Two threads rather than a GMainLoop with two async readers because
 * this process does exactly one thing and blocking reads make the flow
 * obvious; there is no editor here whose responsiveness could suffer. */
static gpointer
relay_downstream (gpointer data)
{
  RelayCtx *ctx = data;

  for (;;)
    {
      gsize len = 0;
      g_autofree gchar *line =
        g_data_input_stream_read_line (ctx->from_cmacs, &len, NULL, NULL);

      if (line == NULL) break;                 /* cmacs closed */
      if (len > RELAY_MAX_LINE) break;
      if (!relay_from_cmacs (ctx, line)) break;
    }
  /* Losing either side ends the session; the agent must not be left
   * waiting on a reply that can no longer arrive. */
  exit (0);
  return NULL;
}

int
cmacs_brigade_relay_main (int argc, char **argv)
{
  g_autoptr (GSocketClient) client = NULL;
  g_autoptr (GSocketConnection) conn = NULL;
  g_autoptr (GSocketAddress) addr = NULL;
  g_autoptr (GDataInputStream) from_agent = NULL;
  g_autoptr (GError) err = NULL;
  const gchar *sock, *allow;
  RelayCtx ctx = { 0 };
  GInputStream *stdin_stream;

  (void) argc;
  (void) argv;

  sock  = g_getenv ("CMACS_BRIGADE_SOCKET");
  allow = g_getenv ("CMACS_BRIGADE_ALLOW");

  if (sock == NULL || sock[0] == '\0')
    {
      g_printerr ("cmacs --mcp-relay: CMACS_BRIGADE_SOCKET is unset.\n"
                  "This mode is spawned by cmacs itself through a generated\n"
                  ".mcp.json; it is not meant to be run by hand.\n");
      return 2;
    }
  /* No allowlist means no tools.  Failing closed here matters more than
   * anywhere else in the brigade: this process is the only thing
   * between the agent and the editor. */
  if (allow == NULL) allow = "";

  addr = g_unix_socket_address_new (sock);
  client = g_socket_client_new ();
  conn = g_socket_client_connect (client, G_SOCKET_CONNECTABLE (addr),
                                  NULL, &err);
  if (conn == NULL)
    {
      g_printerr ("cmacs --mcp-relay: cannot reach %s: %s\n",
                  sock, err ? err->message : "unknown error");
      return 3;
    }

  ctx.allowlist  = allow;
  ctx.to_cmacs   = g_io_stream_get_output_stream (G_IO_STREAM (conn));
  ctx.from_cmacs = g_data_input_stream_new (
    g_io_stream_get_input_stream (G_IO_STREAM (conn)));
  ctx.to_agent   = g_unix_output_stream_new (STDOUT_FILENO, FALSE);

  g_data_input_stream_set_newline_type (ctx.from_cmacs,
                                        G_DATA_STREAM_NEWLINE_TYPE_LF);

  g_thread_new ("brigade-relay-down", relay_downstream, &ctx);

  stdin_stream = g_unix_input_stream_new (STDIN_FILENO, FALSE);
  from_agent = g_data_input_stream_new (stdin_stream);
  g_data_input_stream_set_newline_type (from_agent,
                                        G_DATA_STREAM_NEWLINE_TYPE_LF);

  for (;;)
    {
      gsize len = 0;
      g_autofree gchar *line =
        g_data_input_stream_read_line (from_agent, &len, NULL, NULL);

      if (line == NULL) break;                 /* agent closed */
      if (len > RELAY_MAX_LINE) break;
      if (!relay_from_agent (&ctx, line)) break;
    }

  g_object_unref (stdin_stream);
  return 0;
}

/* Never-return entry point, called from main() before Emacs starts.
 * Mirrors cmacs_lsp_main's contract: if the flag is present we take over
 * the process entirely and exit; we never come back. */
void
cmacs_brigade_relay_maybe_main (int argc, char **argv)
{
  int i;

  for (i = 1; i < argc; i++)
    {
      if (strcmp (argv[i], "--mcp-relay") == 0)
        exit (cmacs_brigade_relay_main (argc, argv));
      if (strcmp (argv[i], "--") == 0)
        break;
    }
}

#endif /* HAVE_CMACS_AI_BRIGADE */
