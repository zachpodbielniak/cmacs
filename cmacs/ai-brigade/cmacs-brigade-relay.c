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
 * Filtering covers the whole request surface, not only tool calls:
 *
 *   tools/list       responses are pruned to what the allowlist admits,
 *                    so the agent never learns a forbidden tool exists.
 *                    Hiding is better than refusing: a model that can
 *                    see `eval' will keep trying it and burn turns.
 *   tools/call       requests for anything else are answered locally
 *                    with a JSON-RPC error and never reach cmacs.
 *   resources/...    need the pseudo tool "resources" in the allowlist
 *                    ("*" covers it).  resources/read reaches every
 *                    buffer and, through file://, any file on disk, so
 *                    an allowlist of two read-only tools must not hand
 *                    it over for free.  The list methods are answered
 *                    locally with empty lists so the client sees
 *                    nothing rather than an error.
 *   prompts/...      likewise, behind the pseudo tool "prompts".
 *   anything that is not a JSON object -- an array (a JSON-RPC batch),
 *                    a scalar, or text that does not parse -- is
 *                    answered locally with an error.  Forwarding it
 *                    "for cmacs to reject" was the one path that
 *                    bypassed every check above.
 *
 * The policy the gate applies (whether "*" covers the privileged set,
 * whether ai_* / brigade_* are refused) comes from the environment too
 * (cmacs_brigade_policy_from_env): this process has no Lisp VM, and the
 * Lisp variables the editor consults read as nil here.
 *
 * The allowlist arrives as CMACS_BRIGADE_ALLOW in the environment,
 * written into the agent's 0600 .mcp.json `env' block.  It is not a
 * command-line argument because argv is world-readable through /proc,
 * and the token beside it must not be.
 *
 * What the relay is and is not: with a scoped socket
 * (`cmacs-brigade-scope-open'), CMACS_BRIGADE_SOCKET names a per-agent
 * listener that already applies the same allowlist server-side, and the
 * relay is defence in depth plus the stdio adapter.  Against a plain
 * cmacs-mcp-<pid>.sock the relay is the only gate, and an agent that
 * can open sockets itself can walk around it.
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

/* A line reader with a hard cap on the line it will assemble.
 * GDataInputStream's read_line grows without bound and only lets the
 * caller measure the line after it has been allocated, which is not a
 * guard against a peer that never sends a newline. */
typedef struct
{
  GInputStream *in;
  GByteArray   *buf;
  gsize         max;
  gboolean      eof;
} RelayReader;

typedef struct
{
  const gchar        *allowlist;
  CmacsBrigadePolicy  policy;
  RelayReader         from_cmacs;
  GOutputStream      *to_cmacs;
  GOutputStream      *to_agent;
} RelayCtx;

static void
relay_reader_init (RelayReader *r, GInputStream *in, gsize max)
{
  r->in  = g_object_ref (in);
  r->buf = g_byte_array_new ();
  r->max = max;
  r->eof = FALSE;
}

/* Next line without its newline, or NULL at EOF or when a line exceeds
 * the cap (the caller stops either way).  Caller g_frees. */
static gchar *
relay_reader_line (RelayReader *r)
{
  for (;;)
    {
      guint8 *nl = r->buf->len
        ? memchr (r->buf->data, '\n', r->buf->len) : NULL;

      if (nl != NULL)
        {
          gsize n = (gsize) (nl - r->buf->data);
          gchar *line = g_strndup ((const gchar *) r->buf->data, n);
          g_byte_array_remove_range (r->buf, 0, (guint) (n + 1));
          return line;
        }
      if (r->buf->len > r->max)
        return NULL;                          /* cap: refuse to grow */
      if (r->eof)
        {
          if (r->buf->len == 0)
            return NULL;
          {
            gchar *line = g_strndup ((const gchar *) r->buf->data,
                                     r->buf->len);
            g_byte_array_set_size (r->buf, 0);
            return line;
          }
        }
      {
        guint8 chunk[65536];
        gssize got = g_input_stream_read (r->in, chunk, sizeof chunk,
                                          NULL, NULL);
        if (got <= 0)
          r->eof = TRUE;
        else
          g_byte_array_append (r->buf, chunk, (guint) got);
      }
    }
}

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
relay_deny_code (GOutputStream *to_agent, JsonNode *id, gint code,
                 const gchar *message)
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
  json_builder_add_int_value (b, code);
  json_builder_set_member_name (b, "message");
  json_builder_add_string_value (b, message);
  json_builder_end_object (b);
  json_builder_end_object (b);

  root = json_builder_get_root (b);
  text = json_to_string (root, FALSE);
  return relay_write (to_agent, text);
}

/* -32601 "method not found" rather than a permission code: as far as
 * this agent is concerned the tool does not exist, which is also what
 * tools/list told it. */
static gboolean
relay_deny (GOutputStream *to_agent, JsonNode *id, const gchar *message)
{
  return relay_deny_code (to_agent, id, -32601, message);
}

/* Answer ID locally with {"<member>": []} -- how a list method reads
 * when the allowlist covers none of what it lists. */
static gboolean
relay_reply_empty_list (GOutputStream *to_agent, JsonNode *id,
                        const gchar *member)
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
  json_builder_set_member_name (b, "result");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, member);
  json_builder_begin_array (b);
  json_builder_end_array (b);
  json_builder_end_object (b);
  json_builder_end_object (b);

  root = json_builder_get_root (b);
  text = json_to_string (root, FALSE);
  return relay_write (to_agent, text);
}

/* Prune a tools/list result to the tools the allowlist admits.
 * Returns a newly allocated line, or NULL to forward unchanged. */
static gchar *
relay_filter_tools_list (JsonObject *root, const RelayCtx *ctx)
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

      if (name != NULL
          && cmacs_brigade_tool_allowed_with_policy (ctx->allowlist, name,
                                                     &ctx->policy))
        json_array_add_element (kept, json_node_copy (el));
    }

  json_object_set_array_member (result, "tools", kept);
  {
    g_autoptr (JsonNode) node = json_node_new (JSON_NODE_OBJECT);
    json_node_set_object (node, root);
    return json_to_string (node, FALSE);
  }
}

/* True when the allowlist grants pseudo tool NAME ("resources",
 * "prompts").  The policy is applied too, so a "*" that has been told
 * to withhold privileged tools still grants these -- they are not
 * privileged, they are simply not free. */
static gboolean
relay_pseudo_allowed (const RelayCtx *ctx, const gchar *name)
{
  return cmacs_brigade_tool_allowed_with_policy (ctx->allowlist, name,
                                                 &ctx->policy);
}

/* Handle one line from the agent.  Returns FALSE to stop the relay. */
static gboolean
relay_from_agent (RelayCtx *ctx, const gchar *line)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  JsonNode *root_node;
  JsonObject *root;
  JsonNode *id;
  const gchar *method;

  /* Blank lines are keep-alives some clients emit; nothing to filter. */
  if (line[0] == '\0')
    return TRUE;

  if (!json_parser_load_from_data (parser, line, -1, NULL))
    return relay_deny_code (ctx->to_agent, NULL, -32700, "Parse error");

  root_node = json_parser_get_root (parser);
  if (root_node == NULL || !JSON_NODE_HOLDS_OBJECT (root_node))
    /* A JSON-RPC batch (an array) would carry its own requests past
     * every check below, and a scalar is not a request at all.  Neither
     * is forwarded. */
    return relay_deny_code (ctx->to_agent, NULL, -32600,
                            "Invalid Request: the relay accepts one "
                            "JSON-RPC object per line");

  root = json_node_get_object (root_node);
  method = json_object_get_string_member_with_default (root, "method", NULL);
  id = json_object_has_member (root, "id")
    ? json_object_get_member (root, "id") : NULL;

  if (g_strcmp0 (method, "tools/call") == 0)
    {
      JsonObject *params = json_object_has_member (root, "params")
        && JSON_NODE_HOLDS_OBJECT (json_object_get_member (root, "params"))
        ? json_object_get_object_member (root, "params") : NULL;
      const gchar *name = params
        ? json_object_get_string_member_with_default (params, "name", NULL)
        : NULL;

      if (name == NULL
          || !cmacs_brigade_tool_allowed_with_policy (ctx->allowlist, name,
                                                      &ctx->policy))
        {
          g_autofree gchar *msg =
            g_strdup_printf ("Unknown tool: %s", name ? name : "(unnamed)");
          return relay_deny (ctx->to_agent, id, msg);
        }
    }
  else if (g_strcmp0 (method, "resources/read") == 0
           || g_strcmp0 (method, "resources/subscribe") == 0
           || g_strcmp0 (method, "resources/unsubscribe") == 0)
    {
      if (!relay_pseudo_allowed (ctx, CMACS_BRIGADE_PSEUDO_RESOURCES))
        return relay_deny (ctx->to_agent, id, "Unknown resource");
    }
  else if (g_strcmp0 (method, "resources/list") == 0)
    {
      if (!relay_pseudo_allowed (ctx, CMACS_BRIGADE_PSEUDO_RESOURCES))
        return relay_reply_empty_list (ctx->to_agent, id, "resources");
    }
  else if (g_strcmp0 (method, "resources/templates/list") == 0)
    {
      if (!relay_pseudo_allowed (ctx, CMACS_BRIGADE_PSEUDO_RESOURCES))
        return relay_reply_empty_list (ctx->to_agent, id,
                                       "resourceTemplates");
    }
  else if (g_strcmp0 (method, "prompts/get") == 0)
    {
      if (!relay_pseudo_allowed (ctx, CMACS_BRIGADE_PSEUDO_PROMPTS))
        return relay_deny (ctx->to_agent, id, "Unknown prompt");
    }
  else if (g_strcmp0 (method, "prompts/list") == 0)
    {
      if (!relay_pseudo_allowed (ctx, CMACS_BRIGADE_PSEUDO_PROMPTS))
        return relay_reply_empty_list (ctx->to_agent, id, "prompts");
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
  filtered = relay_filter_tools_list (root, ctx);
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
      g_autofree gchar *line = relay_reader_line (&ctx->from_cmacs);

      if (line == NULL) break;                 /* cmacs closed, or a line over the cap */
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
  g_autoptr (GError) err = NULL;
  const gchar *sock, *allow;
  /* Static, not on this frame: the downstream thread keeps using the
   * context after the agent closes stdin and this function returns.
   * With the context on the stack that return freed it under the
   * thread's feet, and the process died in g_byte_array_append on the
   * way out instead of exiting cleanly. */
  static RelayCtx ctx;
  static RelayReader from_agent;
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
  cmacs_brigade_policy_from_env (&ctx.policy);
  ctx.to_cmacs   = g_io_stream_get_output_stream (G_IO_STREAM (conn));
  relay_reader_init (&ctx.from_cmacs,
                     g_io_stream_get_input_stream (G_IO_STREAM (conn)),
                     RELAY_MAX_LINE);
  ctx.to_agent   = g_unix_output_stream_new (STDOUT_FILENO, FALSE);

  g_thread_new ("brigade-relay-down", relay_downstream, &ctx);

  stdin_stream = g_unix_input_stream_new (STDIN_FILENO, FALSE);
  relay_reader_init (&from_agent, stdin_stream, RELAY_MAX_LINE);

  for (;;)
    {
      g_autofree gchar *line = relay_reader_line (&from_agent);

      if (line == NULL) break;                 /* agent closed, or a line over the cap */
      if (!relay_from_agent (&ctx, line)) break;
    }

  /* The agent is gone.  Half-close the socket -- our write side only --
   * so cmacs sees EOF and can still deliver replies to anything it is
   * mid-way through; the downstream thread forwards those and exits the
   * process when cmacs closes its side.  Bounded: a cmacs that never
   * closes must not keep a relay alive for a dead agent. */
  {
    GSocket *gsock = g_socket_connection_get_socket (conn);
    int i;

    if (gsock != NULL)
      g_socket_shutdown (gsock, FALSE, TRUE, NULL);
    for (i = 0; i < 50; i++)
      g_usleep (100 * 1000);
  }
  g_object_unref (stdin_stream);
  exit (0);
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
