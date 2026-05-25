/*
 * cmacs-mcp-tools-ai.c — MCP tools for the cmacs-ai subsystem
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Exposes ai-glib as MCP tools so external agents (e.g. an outer
 * Claude Code instance) can drive the cmacs-local AI:
 *   - ai_prompt:        one-shot prompt to the default provider
 *   - ai_list_providers: enumerate provider symbols
 *   - ai_open_chat:     open a chat buffer with an initial prompt
 *
 * All handlers route through the Elisp dispatch path so the
 * implementation stays compact and re-uses the same code the
 * interactive M-x commands hit.
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP
#ifdef HAVE_CMACS_AI

#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <mcp.h>
#include <glib.h>

/* JSON-escape a string the way json-glib's serializer would.
 * The eval path interpolates these into a quoted Lisp string;
 * escape backslash and double-quote at minimum. */
static gchar *
escape_for_lisp (const gchar *s)
{
  if (s == NULL) return g_strdup ("");
  GString *out = g_string_sized_new (strlen (s) + 8);
  for (const gchar *p = s; *p; p++)
    {
      if (*p == '\\' || *p == '"')
        g_string_append_c (out, '\\');
      g_string_append_c (out, *p);
    }
  return g_string_free (out, FALSE);
}

static McpToolResult *
handle_ai_prompt (McpServer *server, const gchar *name,
                  JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *prompt = json_object_has_member (arguments, "prompt")
    ? json_object_get_string_member (arguments, "prompt") : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member (arguments, "provider") : NULL;
  const gchar *system   = json_object_has_member (arguments, "system")
    ? json_object_get_string_member (arguments, "system") : NULL;

  if (prompt == NULL || *prompt == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_prompt: missing 'prompt'");
      return r;
    }

  g_autofree gchar *prompt_esc = escape_for_lisp (prompt);
  g_autofree gchar *provider_arg = provider && *provider
    ? g_strdup_printf ("(quote %s)", provider)
    : g_strdup ("nil");
  g_autofree gchar *system_esc = escape_for_lisp (system ? system : "");
  g_autofree gchar *system_arg = system && *system
    ? g_strdup_printf ("\"%s\"", system_esc)
    : g_strdup ("nil");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case e (cmacs-ai-prompt-sync \"%s\" %s %s)"
    " (error (format \"error: %%S\" e)))",
    prompt_esc, provider_arg, system_arg);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_prompt failed"));
  return r;
}

static McpToolResult *
handle_ai_list_providers (McpServer *server, const gchar *name,
                          JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) arguments; (void) user_data;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = cmacs_dispatch_eval (
    "(format \"%S\" (cmacs-ai-providers))", &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_list_providers failed"));
  return r;
}

static McpToolResult *
handle_ai_open_chat (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *prompt = json_object_has_member (arguments, "prompt")
    ? json_object_get_string_member (arguments, "prompt") : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member (arguments, "provider") : NULL;

  g_autofree gchar *provider_arg = provider && *provider
    ? g_strdup_printf ("(quote %s)", provider)
    : g_strdup ("nil");
  g_autofree gchar *prompt_esc = escape_for_lisp (prompt ? prompt : "");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-ai-chat) "
    " (let ((buf (cmacs-ai-chat-open %s))) "
    "   (when (and \"%s\" (not (string-empty-p \"%s\"))) "
    "     (with-current-buffer buf "
    "       (goto-char (point-max)) "
    "       (insert \"%s\") "
    "       (cmacs-ai-chat-send-compose))) "
    "   (buffer-name buf)))",
    provider_arg, prompt_esc, prompt_esc, prompt_esc);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_open_chat failed"));
  return r;
}

void
cmacs_mcp_tools_ai_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("ai_prompt",
    "Send PROMPT to an AI provider via cmacs-ai (synchronous).  "
    "Optional 'provider' (claude / openai / gemini / grok / ollama / "
    "claude-code / opencode / claude-tmux) overrides the default; "
    "optional 'system' is a system prompt.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"User prompt\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"},"
    "\"system\":{\"type\":\"string\",\"description\":\"System prompt\"}"
    "},\"required\":[\"prompt\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_ai_prompt, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_list_providers",
    "Return the list of supported cmacs-ai provider symbols.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_list_providers, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_open_chat",
    "Open a cmacs-ai chat buffer.  If PROMPT is given, the prompt "
    "is sent as the first user turn and streamed.  Returns the "
    "buffer name.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"Optional initial prompt\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_ai_open_chat, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_AI */
#endif /* HAVE_CMACS_MCP */
