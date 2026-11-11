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
 *   - ai_research:      libresearch cited answer to a question
 *   - ai_web_fetch:     libresearch page read (Wayback fallback)
 *   - ai_lql:           libresearch LQL query
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

/* Embeddings reach MCP as a similarity score, not as vectors.
 * A vector is 768 floats -- ~10 kB of JSON per text, which no caller
 * can act on directly, and semantic *search* is already served by the
 * memory_search tool over the brigade index.  What is actually useful
 * over the wire is the comparison itself. */
static McpToolResult *
handle_ai_embed_similarity (McpServer *server, const gchar *name,
                            JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *a = json_object_get_string_member_with_default (
    arguments, "a", NULL);
  const gchar *b = json_object_get_string_member_with_default (
    arguments, "b", NULL);
  const gchar *model = json_object_has_member (arguments, "model")
    ? json_object_get_string_member_with_default (arguments, "model", NULL)
    : NULL;

  if (!a || !*a || !b || !*b)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_embed_similarity: need both 'a' and 'b'");
      return r;
    }

  /* Every interpolated string goes through escape_for_lisp: these are
   * attacker-controlled tool arguments being spliced into a form that
   * is about to be evaluated. */
  g_autofree gchar *a_esc = escape_for_lisp (a);
  g_autofree gchar *b_esc = escape_for_lisp (b);
  g_autofree gchar *model_esc = escape_for_lisp (model ? model : "");
  g_autofree gchar *model_form = model && *model
    ? g_strdup_printf ("\"%s\"", model_esc) : g_strdup ("nil");

  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(let* ((vs (cmacs-ai-embed (list \"%s\" \"%s\") nil %s)))"
    " (format \"%%.6f\" (cmacs-ai-embed-cosine (nth 0 vs) (nth 1 vs))))",
    a_esc, b_esc, model_form);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : "ai_embed_similarity failed"));
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

/*
 * ai_research / ai_web_fetch / ai_lql -- libresearch (cmacs-ai-research.el).
 *
 * The request itself runs on a worker thread (cmacs-ai-libresearch.c);
 * the eval below waits for it by polling with accept-process-output,
 * which keeps process I/O alive and, unlike sit-for, does not read
 * events -- this dispatch binds inhibit-interaction, under which
 * read-event signals.  The Lisp thread is still occupied for the wait,
 * which for ai_research is minutes: the descriptions say so.
 *
 * Strings from the caller are spliced into the form through
 * cmacs_dispatch_lisp_escape, never g_strescape (whose octal escapes
 * the reader turns into raw bytes).  Integers are formatted by us.
 */

/* Run the research-library FORM (already escaped) and wrap its result.
 * cmacs-ai-research-sync-text answers "error: ..." for a failure, which
 * becomes an MCP error result. */
static McpToolResult *
cmacs_mcp_ai__research_eval (const gchar *form, const gchar *what)
{
  g_autoptr (GError) err = NULL;
  g_autofree gchar *expr = g_strdup_printf (
    "(condition-case e"
    " (progn (require 'cmacs-ai-research) %s)"
    " (error (format \"error: %%s\" (error-message-string e))))",
    form);
  g_autofree gchar *res = cmacs_dispatch_eval_string (expr, &err);
  gboolean failed = res == NULL || g_str_has_prefix (res, "error: ");
  McpToolResult *r = mcp_tool_result_new (failed);

  mcp_tool_result_add_text (r,
    res ? res : (err ? err->message : what));
  return r;
}

static McpToolResult *
handle_ai_research (McpServer *server, const gchar *name,
                    JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *question = json_object_get_string_member_with_default (
    arguments, "question", NULL);
  gboolean deep = json_object_has_member (arguments, "deep")
    ? json_object_get_boolean_member_with_default (arguments, "deep", FALSE)
    : FALSE;
  gint64 pages = json_object_has_member (arguments, "pages")
    ? json_object_get_int_member_with_default (arguments, "pages", 0) : 0;

  if (question == NULL || *question == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_research: missing 'question'");
      return r;
    }
  if (pages < 0 || pages > 20)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_research: 'pages' must be 1-20");
      return r;
    }

  g_autofree gchar *q_esc = cmacs_dispatch_lisp_escape (question);
  g_autofree gchar *pages_arg = pages > 0
    ? g_strdup_printf (" :pages %d", (int) pages) : g_strdup ("");
  g_autofree gchar *form = g_strdup_printf (
    "(cmacs-ai-research-sync-text 'research \"%s\"%s%s)",
    q_esc, deep ? " :deep t" : "", pages_arg);
  return cmacs_mcp_ai__research_eval (form, "ai_research failed");
}

static McpToolResult *
handle_ai_web_fetch (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *url = json_object_get_string_member_with_default (
    arguments, "url", NULL);
  const gchar *archive = json_object_get_string_member_with_default (
    arguments, "archive", NULL);
  gint64 max_chars = json_object_has_member (arguments, "max_chars")
    ? json_object_get_int_member_with_default (arguments, "max_chars", 0) : 0;

  if (url == NULL || *url == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_web_fetch: missing 'url'");
      return r;
    }
  /* Checked here rather than left to the primitive so the caller gets
   * the vocabulary back, not a Lisp error dump. */
  if (archive != NULL && *archive != '\0'
      && g_strcmp0 (archive, "never") != 0
      && g_strcmp0 (archive, "fallback") != 0
      && g_strcmp0 (archive, "only") != 0)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r,
        "ai_web_fetch: 'archive' must be never, fallback or only");
      return r;
    }
  if (max_chars != 0 && (max_chars < 100 || max_chars > 1000000))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r,
        "ai_web_fetch: 'max_chars' must be 100-1000000");
      return r;
    }

  g_autofree gchar *url_esc = cmacs_dispatch_lisp_escape (url);
  g_autofree gchar *archive_arg = archive != NULL && *archive != '\0'
    ? g_strdup_printf (" :archive \"%s\"", archive)   /* one of three literals */
    : g_strdup ("");
  g_autofree gchar *max_arg = max_chars > 0
    ? g_strdup_printf (" :max-chars %d", (int) max_chars) : g_strdup ("");
  g_autofree gchar *form = g_strdup_printf (
    "(cmacs-ai-research-sync-text 'fetch \"%s\"%s%s)",
    url_esc, archive_arg, max_arg);
  return cmacs_mcp_ai__research_eval (form, "ai_web_fetch failed");
}

static McpToolResult *
handle_ai_lql (McpServer *server, const gchar *name,
               JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *query = json_object_get_string_member_with_default (
    arguments, "query", NULL);
  gboolean explain = json_object_has_member (arguments, "explain")
    ? json_object_get_boolean_member_with_default (arguments, "explain", FALSE)
    : FALSE;

  if (query == NULL || *query == '\0')
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "ai_lql: missing 'query'");
      return r;
    }

  g_autofree gchar *q_esc = cmacs_dispatch_lisp_escape (query);
  g_autofree gchar *form = g_strdup_printf (
    "(cmacs-ai-research-sync-text 'lql \"%s\" :max-rows 100%s)",
    q_esc, explain ? " :explain t" : "");
  return cmacs_mcp_ai__research_eval (form, "ai_lql failed");
}

void
cmacs_mcp_tools_ai_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("ai_prompt",
    "Send PROMPT to an AI provider via cmacs-ai (synchronous).  "
    "Optional 'provider' (claude / openai / gemini / grok / ollama / "
    "claude-code / opencode / claude-tmux / grok-build / antigravity / "
    "cursor) overrides the default; "
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

  tool = mcp_tool_new ("ai_embed_similarity",
    "Cosine similarity of two texts' embeddings, in [-1, 1]: 1 is the "
    "same direction, 0 unrelated, -1 opposite.  Use it to judge whether "
    "two passages mean the same thing -- near-duplicate detection, or "
    "checking an answer against a source.  Needs a local embedding "
    "provider (ollama).  Optional 'model' overrides the default "
    "embedding model.  To SEARCH the notes corpus use memory_search "
    "instead; this compares two specific strings.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"a\":{\"type\":\"string\",\"description\":\"First text\"},"
    "\"b\":{\"type\":\"string\",\"description\":\"Second text\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Embedding model\"}"
    "},\"required\":[\"a\",\"b\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_embed_similarity, NULL, NULL);
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

  tool = mcp_tool_new ("ai_research",
    "Research a question on the web with libresearch and return a cited "
    "answer: the answer with numbered citations [n], then the sources "
    "(title, URL).  Needs a libresearch server (cmacs-ai-libresearch-url). "
    "'deep' lets the server run follow-up searches; 'pages' (1-20) is how "
    "many pages it reads.  WARNING: a run takes minutes, and the cmacs "
    "Lisp thread waits for it (the network runs on a worker thread).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"question\":{\"type\":\"string\",\"description\":\"The question\"},"
    "\"deep\":{\"type\":\"boolean\","
    "\"description\":\"Run follow-up searches\"},"
    "\"pages\":{\"type\":\"integer\",\"description\":\"Pages to read, 1-20\"}"
    "},\"required\":[\"question\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_research, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_web_fetch",
    "Read a web page's text through libresearch (the server applies its "
    "own SSRF guard).  'archive' is never (default), fallback (use the "
    "Wayback Machine when the live page fails) or only; 'max_chars' "
    "(100-1000000) caps the text.  Returns title, URL, the archived copy "
    "if one stood in, then the text.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"url\":{\"type\":\"string\",\"description\":\"Page URL\"},"
    "\"archive\":{\"type\":\"string\","
    "\"enum\":[\"never\",\"fallback\",\"only\"],"
    "\"description\":\"Wayback Machine policy\"},"
    "\"max_chars\":{\"type\":\"integer\",\"description\":\"Longest text\"}"
    "},\"required\":[\"url\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_web_fetch, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("ai_lql",
    "Run an LQL query on the libresearch server and return its rows "
    "(at most 100 shown).  LQL pipes search results: "
    "search \"glib\", category: CODE | filter extra.stars > 100 | fields "
    "title, url -- or the shorthand gtk docs | filter "
    "site(\"docs.gtk.org\").  'explain' returns the plan without "
    "running it.  An invalid query reports the server's position and "
    "caret excerpt.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"query\":{\"type\":\"string\",\"description\":\"LQL query\"},"
    "\"explain\":{\"type\":\"boolean\","
    "\"description\":\"Plan without running\"}"
    "},\"required\":[\"query\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_ai_lql, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_AI */
#endif /* HAVE_CMACS_MCP */
