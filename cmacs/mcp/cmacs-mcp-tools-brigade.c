/*
 * cmacs-mcp-tools-brigade.c — MCP publication for brigade tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Publishes every capability registered through `cmacs-brigade-deftool'
 * onto an McpServer, which is the third of the three surfaces a single
 * registration reaches (the other two being in-process agents, handled
 * in cmacs-brigade-tools.el, and CLI agents, which come through the
 * relay and end up here too).
 *
 * Registration is dynamic by necessity.  cmacs_mcp_register_all_tools()
 * runs once per session, but a user's init file — or a package loaded
 * an hour later — can register a tool at any point.  So this walks the
 * live registry at session-creation time, and a hook re-announces the
 * tool list to already-connected clients when it grows.
 *
 * Handlers route through the Elisp dispatcher, so an MCP client and an
 * in-process agent execute the identical handler with the identical
 * confirmation and hook behaviour.  Two paths into one implementation
 * is the whole point; two implementations would drift.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP
#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"
#include "cmacs-brigade.h"

#include <mcp.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

/* Escape for interpolation into a quoted Lisp string.  Every argument
 * here is untrusted input from an external agent, so this is the
 * boundary that keeps it data rather than code. */
static gchar *
escape_for_lisp (const gchar *s)
{
  GString *out;
  const gchar *p;

  if (s == NULL) return g_strdup ("");
  out = g_string_sized_new (strlen (s) + 8);
  for (p = s; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  return g_string_free (out, FALSE);
}

/* One handler for every brigade tool.  The tool name arrives as MCP's
 * `name' argument, so a single handler can serve the whole registry
 * instead of generating a closure per tool. */
static McpToolResult *
handle_brigade_tool (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  g_autoptr (JsonNode) node = NULL;
  g_autofree gchar *args_json = NULL;
  g_autofree gchar *esc_name = NULL;
  g_autofree gchar *esc_args = NULL;
  g_autofree gchar *expr = NULL;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;
  McpToolResult *result;

  (void) server;
  (void) user_data;

  /* Re-serialise the arguments rather than walking them: the Elisp side
   * already has a JSON parser and a coercion table, and duplicating
   * either here would give MCP callers subtly different type handling
   * from in-process agents. */
  node = json_node_new (JSON_NODE_OBJECT);
  json_node_set_object (node, arguments);
  args_json = json_to_string (node, FALSE);

  esc_name = escape_for_lisp (name);
  esc_args = escape_for_lisp (args_json);
  /* The agent argument is "mcp": an external client is not one of the
   * brigade's own agents, and labelling it as such in the audit trail
   * matters when working out who called what. */
  expr = g_strdup_printf ("(cmacs-brigade-call-tool \"%s\" \"%s\" \"mcp\")",
                          esc_name, esc_args);

  res = cmacs_dispatch_eval_string (expr, &err);
  if (res == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, err ? err->message
                                : "brigade tool dispatch failed");
      return result;
    }

  /* `cmacs-brigade-call-tool' returns "Error: ..." rather than
   * signalling, following ai-glib's soft-error convention, so surface
   * that as an MCP error while still handing back the text. */
  result = mcp_tool_result_new (g_str_has_prefix (res, "Error: "));
  mcp_tool_result_add_text (result, res);
  return result;
}

/* Build the JSON Schema for one tool from its stored parameter array. */
static JsonNode *
schema_for_tool (const CmacsBrigadeTool *tool)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  JsonArray *params = NULL;
  guint i, n;

  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "type");
  json_builder_add_string_value (builder, "object");

  json_builder_set_member_name (builder, "properties");
  json_builder_begin_object (builder);

  if (tool->params_json != NULL
      && json_parser_load_from_data (parser, tool->params_json, -1, NULL)
      && JSON_NODE_HOLDS_ARRAY (json_parser_get_root (parser)))
    params = json_node_get_array (json_parser_get_root (parser));

  n = params ? json_array_get_length (params) : 0;
  for (i = 0; i < n; i++)
    {
      JsonObject *p = json_array_get_object_element (params, i);
      const gchar *pname, *ptype, *pdesc;

      if (p == NULL) continue;
      pname = json_object_get_string_member_with_default (p, "name", NULL);
      if (pname == NULL) continue;
      ptype = json_object_get_string_member_with_default (p, "type", "string");
      pdesc = json_object_get_string_member_with_default (p, "description", "");

      json_builder_set_member_name (builder, pname);
      json_builder_begin_object (builder);
      json_builder_set_member_name (builder, "type");
      json_builder_add_string_value (builder, ptype);
      json_builder_set_member_name (builder, "description");
      json_builder_add_string_value (builder, pdesc);
      json_builder_end_object (builder);
    }
  json_builder_end_object (builder);   /* properties */

  json_builder_set_member_name (builder, "required");
  json_builder_begin_array (builder);
  for (i = 0; i < n; i++)
    {
      JsonObject *p = json_array_get_object_element (params, i);
      const gchar *pname;

      if (p == NULL) continue;
      if (!json_object_get_boolean_member_with_default (p, "required", FALSE))
        continue;
      pname = json_object_get_string_member_with_default (p, "name", NULL);
      if (pname != NULL) json_builder_add_string_value (builder, pname);
    }
  json_builder_end_array (builder);
  json_builder_end_object (builder);

  return json_builder_get_root (builder);
}

/* True when SERVER already exposes a tool called NAME.
 *
 * mcp_server_add_tool replaces on collision, so without this check a
 * user registering a tool called "eval" would silently take over the
 * real eval for every MCP client -- a privilege escalation dressed up
 * as a naming accident. */
static gboolean
server_has_tool (McpServer *server, const gchar *name)
{
  GList *tools = mcp_server_list_tools (server);
  GList *l;
  gboolean found = FALSE;

  for (l = tools; l != NULL; l = l->next)
    {
      const gchar *existing = mcp_tool_get_name (MCP_TOOL (l->data));
      if (existing != NULL && strcmp (existing, name) == 0)
        {
          found = TRUE;
          break;
        }
    }
  g_list_free (tools);
  return found;
}

static void
publish_one (const CmacsBrigadeTool *tool, gpointer user_data)
{
  McpServer *server = user_data;
  g_autoptr (McpTool) mt = NULL;
  g_autoptr (JsonNode) schema = NULL;

  if (server_has_tool (server, tool->name))
    {
      g_warning ("cmacs-brigade: tool `%s' shadows a built-in MCP tool "
                 "and was not published; rename it", tool->name);
      return;
    }

  mt = mcp_tool_new (tool->name, tool->description);
  schema = schema_for_tool (tool);

  mcp_tool_set_input_schema (mt, schema);
  /* The classification the policy filter uses is the same one the model
   * sees, so a tool cannot look harmless to a client while being
   * treated as destructive by the filter (or vice versa). */
  mcp_tool_set_read_only_hint (mt, !tool->destructive);
  mcp_tool_set_destructive_hint (mt, tool->destructive);

  mcp_server_add_tool (server, mt, handle_brigade_tool, NULL, NULL);
}

void
cmacs_mcp_tools_brigade_register (McpServer *server)
{
  GError *err = NULL;
  gchar *res;

  /* Load the Elisp side first.  The C mirror this publishes from is
   * filled by `cmacs-brigade-register-tool', and nothing else requires
   * `cmacs-brigade' -- its eager-load block lives inside the file -- so
   * without this the mirror is empty at server start and every MCP
   * client sees a brigade with no tools, the subagent controls
   * included.  Failure is not fatal: an MCP server with the built-in
   * tools and none of the brigade's is still worth having. */
  res = cmacs_dispatch_eval_string ("(require 'cmacs-brigade nil t)", &err);
  if (res == NULL)
    {
      g_warning ("cmacs-brigade: could not load the Lisp side for MCP: %s",
                 err ? err->message : "unknown error");
      g_clear_error (&err);
    }
  else
    g_free (res);

  cmacs_brigade_registry_init ();
  cmacs_brigade_registry_foreach (publish_one, server);
}

/* ── Scoped sockets ───────────────────────────────────────────────────
 *
 * A capability token that nothing verifies is a comment.  For a long
 * time the token minted in `cmacs-brigade-host-provision' was exactly
 * that: written into the agent's config beside CMACS_BRIGADE_SOCKET,
 * which named the plain cmacs-mcp-<pid>.sock, read back by nobody.  The
 * allowlist was enforced only by the relay, a process the agent's own
 * config file describes, so an agent with a shell could `nc -U` the
 * socket and have `eval'.
 *
 * A scope is a second McpUnixSocketServer, one per provision, whose
 * session-created handler registers the full tool set and then removes
 * everything the allowlist does not admit -- the same C gate the relay
 * applies, run in the process that owns the tools.  Resources and
 * prompts are registered only when the allowlist grants their pseudo
 * tool.  Connecting to the socket directly therefore yields the scoped
 * surface, not the whole editor; the relay stays as the stdio adapter
 * and as defence in depth.
 *
 * The socket lives in the 0700 brigade runtime directory.  Its path is
 * not itself a secret (socket paths are listable through /proc/net/unix
 * by anyone): the directory mode is what keeps other users out, and a
 * same-user process could always read the config file anyway.  What the
 * scope closes is the gap between "can reach the socket" and "gets
 * everything" -- the thing the token was supposed to close and did not. */

typedef struct
{
  gchar               *path;
  gchar               *allowlist;
  McpUnixSocketServer *server;
} CmacsBrigadeScope;

static GHashTable *cmacs_brigade__scopes = NULL;   /* path -> scope */

static void
scope_free (gpointer p)
{
  CmacsBrigadeScope *sc = p;

  if (sc == NULL)
    return;
  if (sc->server != NULL)
    {
      mcp_unix_socket_server_stop (sc->server);
      g_clear_object (&sc->server);
    }
  if (sc->path != NULL && g_unlink (sc->path) != 0 && errno != ENOENT)
    g_debug ("cmacs-brigade: could not remove %s: %s", sc->path,
             g_strerror (errno));
  g_free (sc->path);
  g_free (sc->allowlist);
  g_free (sc);
}

/* Register the scoped surface on a fresh session's McpServer. */
static void
scope_session_created (McpUnixSocketServer *unix_server,
                       McpServer *server, gpointer user_data)
{
  CmacsBrigadeScope *sc = user_data;
  CmacsBrigadePolicy policy;
  GList *tools, *l;
  GPtrArray *drop;
  guint i;

  (void) unix_server;

  cmacs_brigade_policy_from_lisp (&policy);

  /* Everything, then subtract: the built-in tools are registered by a
   * dozen per-subsystem functions and this is the one place that must
   * not drift from what a full session gets. */
  cmacs_mcp_register_all_tools (server);

  drop = g_ptr_array_new_with_free_func (g_free);
  tools = mcp_server_list_tools (server);
  for (l = tools; l != NULL; l = l->next)
    {
      const gchar *name = mcp_tool_get_name (MCP_TOOL (l->data));

      if (name != NULL
          && !cmacs_brigade_tool_allowed_with_policy (sc->allowlist, name,
                                                      &policy))
        g_ptr_array_add (drop, g_strdup (name));
    }
  g_list_free_full (tools, g_object_unref);

  for (i = 0; i < drop->len; i++)
    mcp_server_remove_tool (server, g_ptr_array_index (drop, i));
  g_ptr_array_unref (drop);

  if (cmacs_brigade_tool_allowed_with_policy (sc->allowlist,
                                              CMACS_BRIGADE_PSEUDO_RESOURCES,
                                              &policy))
    cmacs_mcp_register_resources (server);
  if (cmacs_brigade_tool_allowed_with_policy (sc->allowlist,
                                              CMACS_BRIGADE_PSEUDO_PROMPTS,
                                              &policy))
    cmacs_mcp_register_prompts (server);
}

static gchar *
scope_dir (GError **error)
{
  gchar *dir = g_build_filename (g_get_user_runtime_dir (), "cmacs",
                                 "brigade", NULL);

  if (g_mkdir_with_parents (dir, 0700) != 0)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "cannot create %s: %s", dir, g_strerror (errno));
      g_free (dir);
      return NULL;
    }
  /* mkdir_with_parents leaves an existing directory's mode alone; this
   * one holds live capabilities, so insist. */
  (void) g_chmod (dir, 0700);
  return dir;
}

DEFUN ("cmacs-brigade-scope-open", Fcmacs_brigade_scope_open,
       Scmacs_brigade_scope_open, 1, 1, 0,
       doc: /* Open a per-agent MCP socket that serves only ALLOWLIST.
Returns the socket path.  A client connecting to it sees the tools
ALLOWLIST admits (evaluated by the same C gate the relay uses, with
the current `cmacs-brigade-restrict-privileged-tools' and
`cmacs-brigade-block-recursive-tools'), resources only if ALLOWLIST
grants "resources", prompts only if it grants "prompts".  "*" covers
both.

This is what makes a provision a capability: an agent that reaches
the socket directly, bypassing `emacs --mcp-relay', still gets the
scoped surface.  Close it with `cmacs-brigade-scope-close'.  Signals
an error if the socket cannot be created.  */)
  (Lisp_Object allowlist)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *dir = NULL;
  g_autofree gchar *uuid = NULL;
  g_autofree gchar *name = NULL;
  CmacsBrigadeScope *sc;
  GMainContext *ctx;

  CHECK_STRING (allowlist);

  dir = scope_dir (&error);
  if (dir == NULL)
    xsignal1 (Qerror, build_string (error->message));

  if (cmacs_brigade__scopes == NULL)
    cmacs_brigade__scopes =
      g_hash_table_new_full (g_str_hash, g_str_equal, g_free, scope_free);

  /* Pid first so a sweep after a crash can tell whose it was. */
  uuid = g_uuid_string_random ();
  name = g_strdup_printf ("mcp-%ld-%s.sock", (long) getpid (), uuid);

  sc = g_new0 (CmacsBrigadeScope, 1);
  sc->path = g_build_filename (dir, name, NULL);
  sc->allowlist = g_strdup (SSDATA (allowlist));
  sc->server = mcp_unix_socket_server_new ("cmacs-brigade-scope",
                                            PACKAGE_VERSION, sc->path);
  mcp_unix_socket_server_set_instructions (sc->server,
    "cmacs MCP server, scoped to one agent's allowlist.  Only the tools "
    "listed by tools/list are available on this socket.\n");
  g_signal_connect (sc->server, "session-created",
                    G_CALLBACK (scope_session_created), sc);

  ctx = cmacs_glib_get_context ();
  g_main_context_push_thread_default (ctx);
  if (!mcp_unix_socket_server_start (sc->server, &error))
    {
      g_main_context_pop_thread_default (ctx);
      scope_free (sc);
      xsignal1 (Qerror, build_string (error->message));
    }
  g_main_context_pop_thread_default (ctx);
  (void) g_chmod (sc->path, 0600);

  g_hash_table_replace (cmacs_brigade__scopes, g_strdup (sc->path), sc);
  return build_string (sc->path);
}

DEFUN ("cmacs-brigade-scope-close", Fcmacs_brigade_scope_close,
       Scmacs_brigade_scope_close, 1, 1, 0,
       doc: /* Close the scoped MCP socket at PATH.
Disconnects its clients and removes the socket file.  Returns t if a
scope was open there, nil otherwise.  */)
  (Lisp_Object path)
{
  CHECK_STRING (path);
  if (cmacs_brigade__scopes == NULL)
    return Qnil;
  return g_hash_table_remove (cmacs_brigade__scopes, SSDATA (path))
    ? Qt : Qnil;
}

DEFUN ("cmacs-brigade-scope-list", Fcmacs_brigade_scope_list,
       Scmacs_brigade_scope_list, 0, 0, 0,
       doc: /* Return the open scoped sockets as a list of (PATH . ALLOWLIST).  */)
  (void)
{
  Lisp_Object out = Qnil;
  GHashTableIter it;
  gpointer k, v;

  if (cmacs_brigade__scopes == NULL)
    return Qnil;
  g_hash_table_iter_init (&it, cmacs_brigade__scopes);
  while (g_hash_table_iter_next (&it, &k, &v))
    {
      CmacsBrigadeScope *sc = v;
      out = Fcons (Fcons (build_string (sc->path),
                          build_string (sc->allowlist)),
                   out);
    }
  return out;
}

void
syms_of_cmacs_mcp_tools_brigade (void)
{
  defsubr (&Scmacs_brigade_scope_open);
  defsubr (&Scmacs_brigade_scope_close);
  defsubr (&Scmacs_brigade_scope_list);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
#endif /* HAVE_CMACS_MCP */
