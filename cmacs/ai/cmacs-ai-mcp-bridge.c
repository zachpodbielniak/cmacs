/* cmacs-ai-mcp-bridge.c --- MCP-tools-as-ai-glib-tools bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-ai-mcp-bridge.h for the high-level model. */

#include <config.h>

#if defined(HAVE_CMACS_AI) && defined(HAVE_CMACS_MCP)

#include "cmacs-ai-mcp-bridge.h"

#include <ai-glib.h>
#include <mcp.h>
#include <json-glib/json-glib.h>
#include <glib.h>
#include <string.h>

/* ── Filtering ─────────────────────────────────────────────────────── */

/* Hard-coded recursion guard: never expose any tool named ai_*.
 * Otherwise an in-process cmacs-ai chat could call ai_open_chat
 * / ai_prompt and infinite-loop itself. */
#define CMACS_AI_BRIDGE_RECURSION_GUARD "^ai_"

static gboolean
matches_any (GPtrArray *patterns, const gchar *s)
{
  if (patterns == NULL) return FALSE;
  for (guint i = 0; i < patterns->len; i++)
    {
      const gchar *pat = g_ptr_array_index (patterns, i);
      if (pat == NULL) continue;
      g_autoptr (GError) err = NULL;
      g_autoptr (GRegex) re = g_regex_new (pat, 0, 0, &err);
      if (re == NULL)
        {
          g_warning ("cmacs-ai-mcp-bridge: bad regex '%s': %s",
                     pat, err ? err->message : "(unknown)");
          continue;
        }
      if (g_regex_match (re, s, 0, NULL))
        return TRUE;
    }
  return FALSE;
}

/* ── Schema translation: McpTool input_schema -> AiTool parameters ── */

/* Walk the JSON schema's top-level "properties" object and call
 * ai_tool_add_parameter for each.  Returns FALSE if the schema is
 * unrepresentable (e.g. a property whose type is "object" with
 * nested "properties" -- ai-glib only supports flat schemas at v0.2).
 *
 * The default cmacs MCP allowlist is entirely flat-schema tools, so
 * this path is exercised cleanly for the v1 use case.  Tier-1 tools
 * with nested objects (some podomation_*) get logged + skipped. */
static gboolean
build_ai_tool_params (AiTool *tool, JsonNode *schema, const gchar *tool_name)
{
  if (schema == NULL) return TRUE;
  if (!JSON_NODE_HOLDS_OBJECT (schema))
    {
      g_message ("cmacs-ai-mcp-bridge: tool '%s' has non-object schema; "
                 "skipping", tool_name);
      return FALSE;
    }
  JsonObject *obj = json_node_get_object (schema);
  if (!json_object_has_member (obj, "properties"))
    return TRUE;            /* no params -- nothing to add */

  JsonNode *props_node = json_object_get_member (obj, "properties");
  if (!JSON_NODE_HOLDS_OBJECT (props_node))
    {
      g_message ("cmacs-ai-mcp-bridge: tool '%s' properties is not an "
                 "object; skipping", tool_name);
      return FALSE;
    }
  JsonObject *props = json_node_get_object (props_node);

  /* Required list. */
  GHashTable *req_set = g_hash_table_new (g_str_hash, g_str_equal);
  if (json_object_has_member (obj, "required"))
    {
      JsonNode *r = json_object_get_member (obj, "required");
      if (JSON_NODE_HOLDS_ARRAY (r))
        {
          JsonArray *ra = json_node_get_array (r);
          guint n = json_array_get_length (ra);
          for (guint i = 0; i < n; i++)
            {
              const gchar *name = json_array_get_string_element (ra, i);
              if (name) g_hash_table_add (req_set, (gpointer) name);
            }
        }
    }

  GList *names = json_object_get_members (props);
  for (GList *l = names; l; l = l->next)
    {
      const gchar *pname = l->data;
      JsonNode *pn = json_object_get_member (props, pname);
      if (!JSON_NODE_HOLDS_OBJECT (pn))
        continue;
      JsonObject *po = json_node_get_object (pn);
      const gchar *ptype = json_object_has_member (po, "type")
        ? json_object_get_string_member (po, "type") : "string";
      const gchar *pdesc = json_object_has_member (po, "description")
        ? json_object_get_string_member (po, "description") : "";

      /* Reject nested-object properties: ai-glib has no way to
       * express the inner schema, and the model would have to guess
       * the structure.  Skip the whole tool rather than mislead it. */
      if (g_strcmp0 (ptype, "object") == 0
          && json_object_has_member (po, "properties"))
        {
          g_message ("cmacs-ai-mcp-bridge: tool '%s' has nested-object "
                     "parameter '%s'; skipping (ai-glib lacks nested "
                     "schema support)", tool_name, pname);
          g_list_free (names);
          g_hash_table_destroy (req_set);
          return FALSE;
        }

      gboolean is_req = g_hash_table_contains (req_set, pname);
      ai_tool_add_parameter (tool, pname, ptype, pdesc, is_req);
    }
  g_list_free (names);
  g_hash_table_destroy (req_set);
  return TRUE;
}

/* ── Result extraction: McpToolResult -> concatenated text ─────────── */

static gchar *
extract_text_from_result (McpToolResult *r)
{
  if (r == NULL) return g_strdup ("");
  JsonArray *content = mcp_tool_result_get_content (r);
  if (content == NULL) return g_strdup ("");

  GString *out = g_string_new (NULL);
  guint n = json_array_get_length (content);
  for (guint i = 0; i < n; i++)
    {
      JsonNode *item = json_array_get_element (content, i);
      if (!JSON_NODE_HOLDS_OBJECT (item)) continue;
      JsonObject *io = json_node_get_object (item);
      const gchar *type = json_object_has_member (io, "type")
        ? json_object_get_string_member (io, "type") : NULL;
      if (g_strcmp0 (type, "text") != 0) continue;
      const gchar *t = json_object_has_member (io, "text")
        ? json_object_get_string_member (io, "text") : NULL;
      if (t)
        {
          if (out->len > 0) g_string_append_c (out, '\n');
          g_string_append (out, t);
        }
    }
  return g_string_free (out, FALSE);
}

/* ── Per-callback context ──────────────────────────────────────────── */

typedef struct
{
  McpServer *server;       /* (owned ref) */
  gchar     *tool_name;    /* (owned) */
} CmacsAiMcpCtx;

static void
cmacs_ai_mcp_ctx_free (gpointer p)
{
  CmacsAiMcpCtx *c = p;
  if (!c) return;
  g_clear_object (&c->server);
  g_free (c->tool_name);
  g_free (c);
}

/* ── The AiToolCallback ────────────────────────────────────────────── */

static gchar *
cmacs_ai_mcp_bridge_callback (AiToolUse    *tool_use,
                              GCancellable *cancellable,
                              GError      **error,
                              gpointer      user_data)
{
  (void) cancellable;
  CmacsAiMcpCtx *ctx = user_data;
  if (ctx == NULL || ctx->server == NULL)
    {
      g_set_error_literal (error, AI_ERROR, AI_ERROR_INVALID_REQUEST,
                           "cmacs-ai-mcp-bridge: callback context lost");
      return NULL;
    }

  JsonObject *args = NULL;
  JsonNode *in = ai_tool_use_get_input (tool_use);
  if (in != NULL && JSON_NODE_HOLDS_OBJECT (in))
    args = json_node_get_object (in);

  GError *err = NULL;
  g_autoptr (McpToolResult) r =
    mcp_server_invoke_tool (ctx->server, ctx->tool_name, args, &err);

  if (r == NULL)
    {
      g_propagate_error (error, err);
      return NULL;
    }

  g_autofree gchar *body = extract_text_from_result (r);
  if (body == NULL) body = g_strdup ("");

  /* ai-glib's soft-error convention: prefix the body with "Error: "
   * so the model sees the failure mode in plain text rather than the
   * loop aborting. */
  if (mcp_tool_result_get_is_error (r))
    return g_strdup_printf ("Error: %s", body);
  return g_steal_pointer (&body);
}

/* ── Public entry point ────────────────────────────────────────────── */

guint
cmacs_ai_mcp_bridge_register_tools (AiToolExecutor *exec,
                                    McpServer      *server,
                                    GPtrArray      *allowlist,
                                    GPtrArray      *denylist,
                                    gboolean        readonly_only)
{
  g_return_val_if_fail (AI_IS_TOOL_EXECUTOR (exec), 0);
  g_return_val_if_fail (MCP_IS_SERVER (server), 0);

  /* Build effective denylist: caller's plus the hard recursion guard. */
  GPtrArray *deny = g_ptr_array_new ();
  if (denylist)
    for (guint i = 0; i < denylist->len; i++)
      g_ptr_array_add (deny, g_ptr_array_index (denylist, i));
  g_ptr_array_add (deny, (gpointer) CMACS_AI_BRIDGE_RECURSION_GUARD);

  guint registered = 0;
  GList *tools = mcp_server_list_tools (server);
  for (GList *l = tools; l; l = l->next)
    {
      McpTool *mt = MCP_TOOL (l->data);
      const gchar *name = mcp_tool_get_name (mt);
      if (name == NULL) continue;

      /* Filter. */
      if (allowlist != NULL && !matches_any (allowlist, name))
        continue;
      if (matches_any (deny, name))
        continue;
      if (readonly_only && !mcp_tool_get_read_only_hint (mt))
        continue;

      /* Build AiTool from McpTool. */
      const gchar *desc = mcp_tool_get_description (mt);
      g_autoptr (AiTool) at = ai_tool_new (name, desc ? desc : "");
      JsonNode *schema = mcp_tool_get_input_schema (mt);
      if (!build_ai_tool_params (at, schema, name))
        continue;   /* unrepresentable; logged inside */

      /* Register with the executor.  Per-callback ctx owns a ref on
       * the server so the bridge survives even if the caller drops
       * its server reference later. */
      CmacsAiMcpCtx *ctx = g_new0 (CmacsAiMcpCtx, 1);
      ctx->server    = g_object_ref (server);
      ctx->tool_name = g_strdup (name);
      ai_tool_executor_register_callback (exec,
                                          (AiTool *) g_steal_pointer (&at),
                                          cmacs_ai_mcp_bridge_callback,
                                          ctx,
                                          cmacs_ai_mcp_ctx_free);
      registered++;
    }
  g_list_free_full (tools, g_object_unref);
  g_ptr_array_unref (deny);

  return registered;
}

#endif /* HAVE_CMACS_AI && HAVE_CMACS_MCP */
