/*
 * cmacs-mcp-tools-brigade.c — MCP publication for registry tools
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
 *
 * ── What needs the brigade, and what does not ───────────────────────
 *
 * The publisher is part of the MCP server: it is compiled in every
 * build that has one, and needs only the registry mirror
 * (cmacs/core/cmacs-tool-registry.c) and the Lisp files
 * cmacs-brigade-registry.el, cmacs-brigade-tools.el and
 * cmacs-capability.el, none of which need the AI subsystems.  That is
 * what makes a migrated tool family the ONLY implementation of its
 * tools: a build with MCP and no brigade publishes the same Lisp tools
 * a full build does, and the hand-written C handlers those tools
 * replaced have been deleted.
 *
 * ── When the Lisp side does not load ────────────────────────────────
 *
 * Nothing stands in for a registry tool any more, so a table that did
 * not load -- or a tool family inside it that did not -- is a set of
 * tools missing from every client, and must not be silent.  Each
 * session is told: the reason is appended to the server's instructions
 * (which a client reads at `initialize'), it is logged once, and a tool
 * called `capability_doctor' is always listed.  That tool is normally
 * the registry's own (cmacs-capability.el); when the registry itself is
 * what failed, a C stand-in below answers with the load error.
 *
 * The scoped sockets further down are a brigade feature -- they exist
 * to hold a CLI agent to its allowlist, and the allowlist gate is the
 * brigade's -- and stay under HAVE_CMACS_AI_BRIGADE.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"
#include "cmacs-tool-registry.h"
#ifdef HAVE_CMACS_AI_BRIGADE
#include "cmacs-brigade.h"
#endif

#include <mcp.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

/* The key a scope's task id is stored under on each of its sessions'
 * McpServer.  See scope_session_created.  Only a scoped socket ever
 * sets it, so in a build without the brigade no session has one and
 * every call belongs to no task.  */
#define CMACS_BRIGADE_SCOPE_TASK_KEY "cmacs-brigade-scope-task"

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
  g_autofree gchar *esc_task = NULL;
  g_autofree gchar *expr = NULL;
  const gchar *task;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;
  McpToolResult *result;

  (void) user_data;

  /* Re-serialise the arguments rather than walking them: the Elisp side
   * already has a JSON parser and a coercion table, and duplicating
   * either here would give MCP callers subtly different type handling
   * from in-process agents. */
  /* A client may leave "arguments" out altogether -- the MCP schema
   * makes it optional, and a tool with no parameters is usually called
   * that way -- and ARGUMENTS is then NULL.  A node holding a NULL
   * object does not serialise as {}; json-glib walks it and crashes, so
   * `tools/call list_buffers' with no arguments took the editor down.  */
  if (arguments != NULL)
    {
      node = json_node_new (JSON_NODE_OBJECT);
      json_node_set_object (node, arguments);
      args_json = json_to_string (node, FALSE);
    }
  else
    args_json = g_strdup ("{}");

  /* Every string here is untrusted input from an external agent;
   * cmacs_dispatch_lisp_escape is the boundary that keeps it data
   * rather than code.  */
  esc_name = cmacs_dispatch_lisp_escape (name);
  esc_args = cmacs_dispatch_lisp_escape (args_json);

  /* Who is calling.  The agent argument is "mcp": an external client is
   * not one of the brigade's own agents, and labelling it as such in
   * the audit trail matters when working out who called what.
   *
   * The task is another matter, and comes from exactly one place: the
   * record of the scoped socket this session was accepted on, copied
   * onto the session's McpServer when it was created.  Nothing the
   * client sends is consulted -- not an argument, not a header, not its
   * environment -- because a task id is what decides whose desktop a
   * `desktop_*' call acts on, and an agent that could state its task
   * could state another agent's.  A session on the plain cmacs socket,
   * or on a scope opened for no task, has no such record and belongs to
   * no task, which the tools that need one refuse in a sentence.  */
  task = g_object_get_data (G_OBJECT (server), CMACS_BRIGADE_SCOPE_TASK_KEY);
  if (task != NULL && *task != '\0')
    {
      esc_task = cmacs_dispatch_lisp_escape (task);
      expr = g_strdup_printf ("(cmacs-brigade-call-tool \"%s\" \"%s\" "
                              "\"mcp\" nil \"%s\")",
                              esc_name, esc_args, esc_task);
    }
  else
    expr = g_strdup_printf ("(cmacs-brigade-call-tool \"%s\" \"%s\" "
                            "\"mcp\")",
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

      /* An array or object parameter comes with its JSON Schema already
         written (`cmacs-brigade--params-json'): items, properties,
         required, nested as deep as the tool declared.  It is copied in
         whole rather than rebuilt here, so what an MCP client is shown
         is the one description the Lisp validator checks against.  */
      if (json_object_has_member (p, "schema")
          && JSON_NODE_HOLDS_OBJECT (json_object_get_member (p, "schema")))
        {
          json_builder_add_value (
            builder, json_node_copy (json_object_get_member (p, "schema")));
          continue;
        }

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

/* ── Publishing the registry onto one McpServer ───────────────────────
 *
 * A server is published to more than once.  A session's McpServer gets
 * the registry when it is created; the process-lifetime internal server
 * (cmacs_mcp_get_internal_server, which the cmacs-ai tool bridge reads)
 * is created during startup, before any Lisp file can be loaded, and is
 * brought up to date each time it is asked for.  So publishing has to
 * be repeatable: what an earlier pass put on the server is replaced or
 * removed, and what it did not put there is left alone.  */

/* Per-server record of the names this file published from the registry.
 * Everything else on the server is a hand-written C tool.  */
#define CMACS_REGISTRY_PUBLISHED_KEY "cmacs-registry-published"
/* The server's instructions before any notice was appended.  */
#define CMACS_REGISTRY_BASE_INSTRUCTIONS_KEY "cmacs-registry-base-instructions"
/* The registry generation the server was last published at, plus one
 * (so that zero means never).  */
#define CMACS_REGISTRY_GENERATION_KEY "cmacs-registry-generation"

typedef struct
{
  McpServer  *server;
  GHashTable *builtin;     /* names of the C tools on SERVER */
  GHashTable *seen;        /* names this pass published */
} PublishPass;

static void
publish_one (const CmacsBrigadeTool *tool, gpointer user_data)
{
  PublishPass *pass = user_data;
  g_autoptr (McpTool) mt = NULL;
  g_autoptr (JsonNode) schema = NULL;

  /* The surface filter, and the first gate: a tool whose :surfaces
   * leave out `mcp' is not offered here at all, so there is nothing for
   * the allowlist to admit later.  (The capability table applies the
   * same order on D-Bus: surface, then scope, then arguments.) */
  if (tool->no_mcp)
    return;

  /* A name that belongs to one of the tools that are still hand-written
   * C: the privileged ones -- `eval', `send_keys', `gi_call', ... --
   * the C introspection family, and the ones that return an image.  A
   * registry tool never takes such a name, whoever registered it and
   * from whichever file: mcp_server_add_tool replaces on collision, and
   * silently taking over `eval' for every MCP client is a privilege
   * escalation dressed as a naming accident.
   *
   * There used to be an exception for the shipped tool families, whose
   * tools replaced C twins of the same name.  The twins are deleted, so
   * a family tool no longer collides with anything and the exception
   * went with them.  */
  if (g_hash_table_contains (pass->builtin, tool->name))
    {
      g_warning ("cmacs-mcp: registry tool `%s' has the name of a built-in "
                 "MCP tool and was not published; rename it", tool->name);
      return;
    }

  mt = mcp_tool_new (tool->name, tool->description);
  schema = schema_for_tool (tool);

  mcp_tool_set_input_schema (mt, schema);
  /* The classification the policy filter uses is the same one the model
   * sees, so a tool cannot look harmless to a client while being
   * treated as destructive by the filter (or vice versa).  mcp-glib
   * writes a hint only when it differs from the protocol's default, so
   * a destructive tool (readOnlyHint false, destructiveHint true: both
   * defaults) goes out with no `annotations' at all, and a client reads
   * that absence as "may modify".  */
  mcp_tool_set_read_only_hint (mt, !tool->destructive);
  mcp_tool_set_destructive_hint (mt, tool->destructive);

  /* Replaces what an earlier pass published under this name.  */
  mcp_server_add_tool (pass->server, mt, handle_brigade_tool, NULL, NULL);
  g_hash_table_add (pass->seen, g_strdup (tool->name));
}

/* The names publishing has put on SERVER so far; created on first use
 * and owned by SERVER.  */
static GHashTable *
published_names (McpServer *server)
{
  GHashTable *names = g_object_get_data (G_OBJECT (server),
                                         CMACS_REGISTRY_PUBLISHED_KEY);

  if (names == NULL)
    {
      names = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
      g_object_set_data_full (G_OBJECT (server), CMACS_REGISTRY_PUBLISHED_KEY,
                              names, (GDestroyNotify) g_hash_table_unref);
    }
  return names;
}

/* Put the registry's current contents on SERVER: add what is new,
 * replace what changed, remove what was unregistered since the last
 * pass, and never touch a C tool.  */
static void
publish_registry (McpServer *server)
{
  PublishPass pass;
  GHashTable *published = published_names (server);
  GHashTableIter iter;
  gpointer key;
  GList *tools, *l;

  pass.server = server;
  pass.builtin = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  pass.seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  /* What is on the server and was not put there by an earlier pass is
   * a C tool.  Collected once: asking the server per tool is a list of
   * every tool, per tool.  */
  tools = mcp_server_list_tools (server);
  for (l = tools; l != NULL; l = l->next)
    {
      const gchar *name = mcp_tool_get_name (MCP_TOOL (l->data));

      if (name != NULL && !g_hash_table_contains (published, name))
        g_hash_table_add (pass.builtin, g_strdup (name));
    }
  g_list_free_full (tools, g_object_unref);

  cmacs_brigade_registry_init ();
  cmacs_brigade_registry_foreach (publish_one, &pass);

  /* Published before, not in the registry now: unregistered, or moved
   * off the `mcp' surface.  */
  g_hash_table_iter_init (&iter, published);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    if (!g_hash_table_contains (pass.seen, key))
      mcp_server_remove_tool (server, key);

  g_hash_table_remove_all (published);
  g_hash_table_iter_init (&iter, pass.seen);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    g_hash_table_add (published, g_strdup (key));

  g_hash_table_unref (pass.builtin);
  g_hash_table_unref (pass.seen);
}

/* ── A table that did not load ──────────────────────────────────────── */

/* Why the Lisp side of the tool table did not load, or NULL when it
 * did.  Main thread only, like everything else in this file.  */
static gchar *registry_load_error;

/* The notice last written to the log, so that a hundred sessions with
 * the same broken family file log it once.  */
static gchar *registry_logged_notice;

/* The stand-in `capability_doctor': registered only when the registry
 * did not provide the real one, which means the registry is what is
 * broken.  It says so, with the error, instead of leaving a client to
 * work out why two hundred tools are missing.  */
static McpToolResult *
handle_capability_doctor_fallback (McpServer *server, const gchar *name,
                                   JsonObject *arguments, gpointer user_data)
{
  McpToolResult *result = mcp_tool_result_new (FALSE);
  g_autofree gchar *text = NULL;

  (void) server;
  (void) name;
  (void) arguments;
  (void) user_data;

  text = g_strdup_printf (
    "The cmacs tool table did not load, so the only MCP tools on this "
    "server are the hand-written ones (eval, send_keys, the screenshot "
    "tools, ...).  Every other tool is MISSING, not disabled.\n"
    "Reason: %s\n"
    "The table is lisp/cmacs/cmacs-brigade-registry.el, "
    "cmacs-brigade-tools.el and cmacs-capability.el; fix the error, then "
    "evaluate (require 'cmacs-capability) and reconnect.",
    registry_load_error != NULL
    ? registry_load_error
    : "unknown (the registry loaded but defined no `capability_doctor')");
  mcp_tool_result_add_text (result, text);
  return result;
}

/* What every client of this session should be told, or NULL when the
 * table is whole.  Newly allocated.  */
static gchar *
registry_notice (void)
{
  g_autoptr (GError) err = NULL;
  gchar *text;

  if (registry_load_error != NULL)
    return g_strdup_printf (
      "NOTICE: cmacs could not load its tool table (%s), so most tools "
      "are MISSING from this server (they are not disabled on purpose); "
      "only the built-in ones are listed.  Call the capability_doctor "
      "tool for details.\n", registry_load_error);

  /* The families that failed, in the registry's own words.  A constant
   * form: nothing a client sent is in it.  */
  text = cmacs_dispatch_eval_string (
    "(if (fboundp 'cmacs-capability-status-notice)"
    " (cmacs-capability-status-notice) \"\")", &err);
  if (text != NULL && *text == '\0')
    g_clear_pointer (&text, g_free);
  return text;
}

void
cmacs_mcp_tools_brigade_register (McpServer *server)
{
  GError *err = NULL;
  gchar *res;
  const gchar *base;
  g_autofree gchar *notice = NULL;

  /* Load the Elisp side first.  The C mirror this publishes from is
   * filled by `cmacs-brigade-register-tool', and nothing else requires
   * the registry, so without this the mirror is empty at server start.
   *
   * The brigade first, and separately: it only exists in a build that
   * has it (`cmacs-brigade-available-p' guards its eager-load block),
   * and its failing must not keep the table from loading.  */
  res = cmacs_dispatch_eval_string ("(require 'cmacs-brigade nil t)", &err);
  if (res == NULL)
    {
      g_warning ("cmacs-mcp: cmacs-brigade failed to load: %s",
                 err ? err->message : "unknown error");
      g_clear_error (&err);
    }
  g_free (res);

  /* Then the table: the registry, the dispatcher, and cmacs-capability
   * with every tool family -- all of it brigade-free.  WITHOUT the
   * `noerror' argument, and with each file named: a missing file is as
   * much a failure as one that signals, and since the C handlers these
   * tools replaced are gone, a failure here takes most of the tool list
   * with it.  It is not fatal -- a server with only the built-in tools
   * still starts -- but it is remembered, and every session is told.
   * Tried again on every pass, so fixing the file and reconnecting is
   * enough.  (A single family that fails is caught in Lisp, by
   * `cmacs-capability--load-family', and reported through
   * `cmacs-capability-status-notice' below.)  */
  res = cmacs_dispatch_eval_string ("(progn (require 'cmacs-brigade-registry)"
                                    " (require 'cmacs-brigade-tools)"
                                    " (require 'cmacs-capability) \"ok\")",
                                    &err);
  g_clear_pointer (&registry_load_error, g_free);
  if (res == NULL)
    {
      registry_load_error = g_strdup (err ? err->message : "unknown error");
      g_clear_error (&err);
    }
  g_free (res);

  publish_registry (server);
  g_object_set_data (G_OBJECT (server), CMACS_REGISTRY_GENERATION_KEY,
                     GUINT_TO_POINTER (cmacs_brigade_registry_generation ()
                                       + 1));

  /* `capability_doctor' is always listed.  Normally publish_registry has
   * just published the registry's.  The stand-in is recorded as
   * published, not as a C tool, so that the real one replaces it on a
   * later pass, once the table loads.  */
  {
    GList *tools = mcp_server_list_tools (server), *l;
    gboolean have = FALSE;

    for (l = tools; l != NULL && !have; l = l->next)
      have = g_strcmp0 (mcp_tool_get_name (MCP_TOOL (l->data)),
                        "capability_doctor") == 0;
    g_list_free_full (tools, g_object_unref);

    if (!have)
      {
        g_autoptr (McpTool) doctor
          = mcp_tool_new ("capability_doctor",
                          "Report why tools are missing from this cmacs MCP "
                          "server: its tool table failed to load.");

        mcp_tool_set_read_only_hint (doctor, TRUE);
        mcp_tool_set_destructive_hint (doctor, FALSE);
        mcp_server_add_tool (server, doctor,
                             handle_capability_doctor_fallback, NULL, NULL);
        g_hash_table_add (published_names (server),
                          g_strdup ("capability_doctor"));
      }
  }

  /* The notice goes after the server's own instructions.  Those are
   * remembered the first time, so that a later pass replaces the notice
   * instead of appending a second one.  (For a session this runs before
   * `initialize' is answered: the unix-socket server has already copied
   * its instructions onto the session's McpServer.)  */
  base = g_object_get_data (G_OBJECT (server),
                            CMACS_REGISTRY_BASE_INSTRUCTIONS_KEY);
  if (base == NULL)
    {
      const gchar *current = mcp_server_get_instructions (server);

      g_object_set_data_full (G_OBJECT (server),
                              CMACS_REGISTRY_BASE_INSTRUCTIONS_KEY,
                              g_strdup (current != NULL ? current : ""),
                              g_free);
      base = g_object_get_data (G_OBJECT (server),
                                CMACS_REGISTRY_BASE_INSTRUCTIONS_KEY);
    }

  notice = registry_notice ();
  if (notice != NULL)
    {
      g_autofree gchar *instructions
        = g_strconcat (base, *base != '\0' ? "\n" : "", notice, NULL);

      mcp_server_set_instructions (server, instructions);

      if (g_strcmp0 (notice, registry_logged_notice) != 0)
        {
          g_warning ("cmacs-mcp: %s", notice);
          g_free (registry_logged_notice);
          registry_logged_notice = g_strdup (notice);
        }
    }
  else
    {
      if (*base != '\0' || mcp_server_get_instructions (server) != NULL)
        mcp_server_set_instructions (server, base);
      g_clear_pointer (&registry_logged_notice, g_free);
    }
}

void
cmacs_mcp_tools_brigade_sync (McpServer *server)
{
  guint stamp = GPOINTER_TO_UINT (
    g_object_get_data (G_OBJECT (server), CMACS_REGISTRY_GENERATION_KEY));

  /* Nothing registered or removed since this server was last published,
   * and the table loaded then: nothing to do.  A load that failed is
   * tried again every time; it may have been fixed.  */
  if (stamp != 0 && registry_load_error == NULL
      && stamp == cmacs_brigade_registry_generation () + 1)
    return;

  cmacs_mcp_tools_brigade_register (server);
}

#ifdef HAVE_CMACS_AI_BRIGADE

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
  gchar               *task;        /* brigade task it was opened for, or NULL */
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
  g_free (sc->task);
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

  /* The session inherits the scope's task, as a copy it owns: the tool
   * handler is handed the McpServer and nothing else, and a session can
   * outlive the scope record by the length of a call in flight.  This
   * is the only writer of the key.  */
  if (sc->task != NULL)
    g_object_set_data_full (G_OBJECT (server), CMACS_BRIGADE_SCOPE_TASK_KEY,
                            g_strdup (sc->task), g_free);

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
  /* The longest name scope-open puts in it: "mcp-<pid>-<uuid>.sock". */
  g_autofree gchar *probe
    = g_strdup_printf ("%s/mcp-%ld-%s.sock", dir, (long) G_MAXINT32,
                       "00000000-0000-0000-0000-000000000000");

  if (!cmacs_mcp_fits_sun_path (probe))
    {
      gchar *tmp = cmacs_mcp_private_tmp_dir (error);

      g_free (dir);
      if (tmp == NULL)
        return NULL;
      dir = g_build_filename (tmp, "brigade", NULL);
      g_free (tmp);
    }

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
       Scmacs_brigade_scope_open, 1, 2, 0,
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
an error if the socket cannot be created.

Optional TASK is the id of the brigade task the socket is opened for.
Every brigade tool call arriving on the socket is then made on that
task's behalf -- `cmacs-brigade-call-tool' receives it as its TASK --
which is how a tool that acts on "the calling task's" resources (its
desktop, say) knows whose they are.  The id is held here, with the
socket, and is never read from the client.  With TASK nil or empty the
socket's calls belong to no task, as on the plain cmacs socket.  */)
  (Lisp_Object allowlist, Lisp_Object task)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *dir = NULL;
  g_autofree gchar *uuid = NULL;
  g_autofree gchar *name = NULL;
  CmacsBrigadeScope *sc;
  GMainContext *ctx;

  CHECK_STRING (allowlist);
  if (!NILP (task))
    CHECK_STRING (task);

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
  if (!NILP (task) && SBYTES (task) > 0)
    sc->task = g_strdup (SSDATA (task));
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

#endif /* HAVE_CMACS_AI_BRIGADE */

DEFUN ("cmacs-mcp-registry-load-error", Fcmacs_mcp_registry_load_error,
       Scmacs_mcp_registry_load_error, 0, 0, 0,
       doc: /* Return why the MCP server could not load the tool table, or nil.
The table is the Lisp side of the tool registry: cmacs-brigade-registry,
cmacs-brigade-tools and cmacs-capability with its tool families.  The
server loads it when a session is set up; a string here is the error
that load signalled, and means the sessions set up since then list only
the hand-written C tools.  nil means the last load succeeded, or that
no session has been set up yet.

A single tool family that fails to load is not reported here but in
`cmacs-capability-family-failures'; `cmacs-capability-doctor' shows
both.  */)
  (void)
{
  return registry_load_error != NULL ? build_string (registry_load_error)
                                     : Qnil;
}

void
syms_of_cmacs_mcp_tools_brigade (void)
{
  defsubr (&Scmacs_mcp_registry_load_error);
  /* The mirror's DEFUNs.  The brigade registers them too when it is
     built; whichever syms_of_ runs second finds them done.  */
  syms_of_cmacs_tool_registry ();
#ifdef HAVE_CMACS_AI_BRIGADE
  defsubr (&Scmacs_brigade_scope_open);
  defsubr (&Scmacs_brigade_scope_close);
  defsubr (&Scmacs_brigade_scope_list);
#endif
}

#endif /* HAVE_CMACS_MCP */
