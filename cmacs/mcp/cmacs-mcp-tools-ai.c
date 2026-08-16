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
 *   - ai_list_models:   enumerate model names per provider
 *   - ai_open_chat:     open a chat buffer with an initial prompt
 *   - generate_image:   generate an image and insert it into a buffer
 *                       (unprefixed on purpose -- see its handler)
 *
 * D-Bus parity: org.cmacs.Editor1.Ai in
 * cmacs/dbus/cmacs-dbus-iface-ai.c (sync discipline: adding a tool
 * here requires a matching method there, and vice versa).
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
    ? json_object_get_string_member_with_default (arguments, "prompt", NULL) : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member_with_default (arguments, "provider", NULL) : NULL;
  const gchar *system   = json_object_has_member (arguments, "system")
    ? json_object_get_string_member_with_default (arguments, "system", NULL) : NULL;
  const gchar *model    = json_object_has_member (arguments, "model")
    ? json_object_get_string_member_with_default (arguments, "model", NULL) : NULL;

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
  g_autofree gchar *model_esc = escape_for_lisp (model ? model : "");
  g_autofree gchar *model_arg = model && *model
    ? g_strdup_printf ("\"%s\"", model_esc)
    : g_strdup ("nil");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case e (cmacs-ai-prompt-sync \"%s\" %s %s %s)"
    " (error (format \"error: %%S\" e)))",
    prompt_esc, provider_arg, system_arg, model_arg);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_prompt failed"));
  return r;
}

static McpToolResult *
handle_ai_call (McpServer *server, const gchar *name,
                JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *prompt = json_object_has_member (arguments, "prompt")
    ? json_object_get_string_member_with_default (arguments, "prompt", NULL) : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member_with_default (arguments, "provider", NULL) : NULL;
  const gchar *system   = json_object_has_member (arguments, "system")
    ? json_object_get_string_member_with_default (arguments, "system", NULL) : NULL;
  const gchar *model    = json_object_has_member (arguments, "model")
    ? json_object_get_string_member_with_default (arguments, "model", NULL) : NULL;
  gboolean tools = json_object_has_member (arguments, "tools")
    ? json_object_get_boolean_member (arguments, "tools") : FALSE;

  if (prompt == NULL || *prompt == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_call: missing 'prompt'");
      return r;
    }

  g_autofree gchar *prompt_esc = escape_for_lisp (prompt);
  g_autofree gchar *provider_arg = provider && *provider
    ? g_strdup_printf (":provider (quote %s)", provider)
    : g_strdup ("");
  g_autofree gchar *system_esc = escape_for_lisp (system ? system : "");
  g_autofree gchar *system_arg = system && *system
    ? g_strdup_printf (":system \"%s\"", system_esc)
    : g_strdup ("");
  g_autofree gchar *model_esc = escape_for_lisp (model ? model : "");
  g_autofree gchar *model_arg = model && *model
    ? g_strdup_printf (":model \"%s\"", model_esc)
    : g_strdup ("");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case e"
    " (progn (require 'cmacs-ai-call)"
    "  (cmacs-ai-call \"%s\" %s %s %s %s))"
    " (error (format \"error: %%S\" e)))",
    prompt_esc, provider_arg, system_arg, model_arg,
    tools ? ":builtin-tools t" : "");
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_call failed"));
  return r;
}

/*
 * generate_image
 *
 * Deliberately NOT named ai_generate_image: the MCP bridge hides every
 * "^ai_" tool from in-process chat buffers to stop the model calling
 * itself, and an in-process chat buffer is precisely where an agent
 * should be able to draw something.
 *
 * The schema is flat -- references arrive as a comma-separated string --
 * because the bridge's schema translator rejects nested objects.
 */
static McpToolResult *
handle_generate_image (McpServer *server, const gchar *name,
                       JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *prompt = json_object_has_member (arguments, "prompt")
    ? json_object_get_string_member_with_default (arguments, "prompt", NULL) : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member_with_default (arguments, "provider", NULL) : NULL;
  const gchar *model = json_object_has_member (arguments, "model")
    ? json_object_get_string_member_with_default (arguments, "model", NULL) : NULL;
  const gchar *aspect = json_object_has_member (arguments, "aspect")
    ? json_object_get_string_member_with_default (arguments, "aspect", NULL) : NULL;
  const gchar *size = json_object_has_member (arguments, "size")
    ? json_object_get_string_member_with_default (arguments, "size", NULL) : NULL;
  const gchar *quality = json_object_has_member (arguments, "quality")
    ? json_object_get_string_member_with_default (arguments, "quality", NULL) : NULL;
  const gchar *refs = json_object_has_member (arguments, "references")
    ? json_object_get_string_member_with_default (arguments, "references", NULL) : NULL;
  const gchar *buffer = json_object_has_member (arguments, "buffer")
    ? json_object_get_string_member_with_default (arguments, "buffer", NULL) : NULL;

  if (prompt == NULL || *prompt == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "generate_image: missing 'prompt'");
      return r;
    }

  g_autofree gchar *prompt_esc = escape_for_lisp (prompt);
  /* These two are positional arguments to cmacs-ai-image--client, so
   * they must evaluate to a value (or nil), not to a keyword pair. */
  g_autofree gchar *provider_form = provider && *provider
    ? g_strdup_printf ("(quote %s)", provider) : g_strdup ("nil");
  g_autofree gchar *model_esc = escape_for_lisp (model ? model : "");
  g_autofree gchar *model_form = model && *model
    ? g_strdup_printf ("\"%s\"", model_esc) : g_strdup ("nil");
  g_autofree gchar *aspect_esc = escape_for_lisp (aspect ? aspect : "");
  g_autofree gchar *aspect_arg = aspect && *aspect
    ? g_strdup_printf (":aspect \"%s\"", aspect_esc) : g_strdup ("");
  g_autofree gchar *size_esc = escape_for_lisp (size ? size : "");
  g_autofree gchar *size_arg = size && *size
    ? g_strdup_printf (":custom-size \"%s\"", size_esc) : g_strdup ("");
  g_autofree gchar *quality_esc = escape_for_lisp (quality ? quality : "");
  g_autofree gchar *quality_arg = quality && *quality
    ? g_strdup_printf (":quality \"%s\"", quality_esc) : g_strdup ("");
  g_autofree gchar *refs_esc = escape_for_lisp (refs ? refs : "");
  g_autofree gchar *refs_arg = refs && *refs
    ? g_strdup_printf (":references (cmacs-ai-image-chat--parse-refs \"%s\")",
                       refs_esc)
    : g_strdup ("");
  g_autofree gchar *buffer_esc = escape_for_lisp (buffer ? buffer : "");

  /* Runs synchronously: an MCP call is a request/response, and the
   * caller is waiting on the result. */
  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case e"
    " (progn (require 'cmacs-ai-image) (require 'cmacs-ai-image-chat)"
    "  (with-current-buffer %s%s%s"
    "   (let* ((h (cmacs-ai-image--client %s %s))"
    "          (p (unwind-protect"
    "                 (cmacs-ai-image-generate-sync"
    "                  h \"%s\" (list %s %s %s %s) cmacs-ai-image-timeout)"
    "               (ignore-errors (cmacs-ai-client-free h))))"
    "          (n (cmacs-ai-image--place (plist-get p :images)"
    "                                    \"%s\" (current-buffer) (point))))"
    "    (format \"Inserted %%d image(s) into %%s\" n (buffer-name)))))"
    " (error (format \"error: %%S\" e)))",
    buffer && *buffer ? "(or (get-buffer \"" : "(current-buffer)",
    buffer && *buffer ? buffer_esc : "",
    buffer && *buffer ? "\") (current-buffer))" : "",
    provider_form, model_form,
    prompt_esc,
    aspect_arg, size_arg, quality_arg, refs_arg,
    prompt_esc);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "generate_image failed"));
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
handle_ai_list_models (McpServer *server, const gchar *name,
                       JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member_with_default (arguments, "provider", NULL) : NULL;

  /* No provider = every supported provider; each one guarded so a
   * keyless/offline provider reports instead of failing the whole
   * call.  Result is a JSON object provider -> [models]. */
  g_autofree gchar *providers_form = provider && *provider
    ? g_strdup_printf ("(list (quote %s))", provider)
    : g_strdup ("(cmacs-ai-providers)");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(let ((tbl (make-hash-table :test (quote equal))))"
    " (dolist (pv %s)"
    "  (puthash (symbol-name pv)"
    "   (condition-case e"
    "    (apply (function vector) (cmacs-ai-list-models pv))"
    "    (error (vector (format \"(unavailable: %%s)\""
    "                    (error-message-string e)))))"
    "   tbl))"
    " (json-serialize tbl))",
    providers_form);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_list_models failed"));
  return r;
}

static McpToolResult *
handle_ai_open_chat (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *prompt = json_object_has_member (arguments, "prompt")
    ? json_object_get_string_member_with_default (arguments, "prompt", NULL) : NULL;
  const gchar *provider = json_object_has_member (arguments, "provider")
    ? json_object_get_string_member_with_default (arguments, "provider", NULL) : NULL;
  const gchar *model = json_object_has_member (arguments, "model")
    ? json_object_get_string_member_with_default (arguments, "model", NULL) : NULL;

  g_autofree gchar *provider_arg = provider && *provider
    ? g_strdup_printf ("(quote %s)", provider)
    : g_strdup ("nil");
  g_autofree gchar *model_esc = escape_for_lisp (model ? model : "");
  g_autofree gchar *model_arg = model && *model
    ? g_strdup_printf ("\"%s\"", model_esc)
    : g_strdup ("nil");
  g_autofree gchar *prompt_esc = escape_for_lisp (prompt ? prompt : "");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-ai-chat) "
    " (let ((buf (cmacs-ai-chat-open %s %s))) "
    "   (when (and \"%s\" (not (string-empty-p \"%s\"))) "
    "     (with-current-buffer buf "
    "       (goto-char (point-max)) "
    "       (insert \"%s\") "
    "       (cmacs-ai-chat-send-compose))) "
    "   (buffer-name buf)))",
    provider_arg, model_arg, prompt_esc, prompt_esc, prompt_esc);
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
    "claude-code / opencode / claude-tmux / grok-build) overrides the "
    "default; "
    "optional 'system' is a system prompt; optional 'model' overrides "
    "the provider's default model.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"User prompt\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"},"
    "\"system\":{\"type\":\"string\",\"description\":\"System prompt\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Model name\"}"
    "},\"required\":[\"prompt\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_ai_prompt, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_call",
    "Send PROMPT to an AI provider and return the final answer "
    "(synchronous).  Like ai_prompt, but with 'tools':true the model is "
    "given the built-in agent tools (bash/read/write/edit/glob/grep/ls/"
    "web_fetch) and runs a multi-turn tool loop.  WARNING: a tool loop "
    "blocks the cmacs main thread for its whole duration.  Optional "
    "'provider' / 'system' / 'model' behave as for ai_prompt.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"User prompt\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"},"
    "\"system\":{\"type\":\"string\",\"description\":\"System prompt\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Model name\"},"
    "\"tools\":{\"type\":\"boolean\","
    "\"description\":\"Give the model the built-in agent tools\"}"
    "},\"required\":[\"prompt\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_ai_call, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("generate_image",
    "Generate an image from a text prompt and insert it into a cmacs "
    "buffer.  In an Org buffer the image is attached to the current "
    "node and previewed inline; elsewhere it is saved under "
    "cmacs-ai-image-dir.  Optional 'references' is a comma-separated "
    "list of input images to condition on, each PATH or PATH::ROLE "
    "(e.g. \"logo.png::style,cat.jpg::subject\") -- roles tell the "
    "model what each reference is for.  Optional 'provider' (gemini / "
    "openai / grok), 'model', 'aspect' (e.g. 16:9), 'size' (e.g. "
    "1024x1024) and 'quality'.  Optional 'buffer' names the target "
    "buffer; the current one is used otherwise.  WARNING: this blocks "
    "the cmacs main thread for the tens of seconds generation takes.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"What to depict\"},"
    "\"references\":{\"type\":\"string\",\"description\":"
    "\"Comma-separated PATH or PATH::ROLE reference images\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"gemini/openai/grok\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Model id\"},"
    "\"aspect\":{\"type\":\"string\",\"description\":\"Aspect ratio\"},"
    "\"size\":{\"type\":\"string\",\"description\":\"Pixel size\"},"
    "\"quality\":{\"type\":\"string\",\"description\":\"Quality level\"},"
    "\"buffer\":{\"type\":\"string\",\"description\":\"Target buffer name\"}"
    "},\"required\":[\"prompt\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_generate_image, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_list_providers",
    "Return the list of supported cmacs-ai provider symbols.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_list_providers, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_list_models",
    "List the model names each cmacs-ai provider offers, as a JSON "
    "object mapping provider to an array of models.  Optional "
    "'provider' restricts the query to one provider; otherwise all "
    "providers are queried (unavailable ones report inline).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_list_models, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_open_chat",
    "Open a cmacs-ai chat buffer.  If PROMPT is given, the prompt "
    "is sent as the first user turn and streamed.  Optional 'model' "
    "overrides the provider's default model.  Returns the buffer "
    "name.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"prompt\":{\"type\":\"string\",\"description\":\"Optional initial prompt\"},"
    "\"provider\":{\"type\":\"string\",\"description\":\"Provider name\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Model name\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_ai_open_chat, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_AI */
#endif /* HAVE_CMACS_MCP */
