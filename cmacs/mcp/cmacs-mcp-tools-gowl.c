/*
 * cmacs-mcp-tools-gowl.c — the gowl compositor MCP tools that are still C
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Two tools, kept as hand-written handlers on purpose:
 *
 *   gowl_screenshot
 *       returns a PNG; a registry tool (`cmacs-brigade-deftool')
 *       returns text.
 *   gowl_hotkey_send
 *       types caller-supplied keys into whatever window has focus.  It
 *       is in the privileged set, and stays where a change to it is
 *       reviewed as a change to that set.
 *
 * The other forty-five gowl_* tools and the eight screensaver_* tools
 * that used to be registered here are registry tools now (lisp/cmacs/
 * cmacs-gowl-tools.el, cmacs-screensaver-tools.el), published by
 * cmacs-mcp-tools-brigade.c in every build with an MCP server; their C
 * handlers were deleted.  What they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_GOWL)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Helper: dispatch a gowl function returning gchar*, wrap in result. */
static McpToolResult *
gowl_result (gchar *str, GError *error)
{
  McpToolResult *result;
  if (str == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result,
        error ? error->message : "Unknown gowl error");
    }
  else
    {
      result = mcp_tool_result_new (FALSE);
      mcp_tool_result_add_text (result, str);
      g_free (str);
    }
  return result;
}

/* Helper: validate a "by" field, defaulting to app-id. */
static const gchar *
gowl_by_field (JsonObject *a)
{
  const gchar *by = json_object_get_string_member_with_default (a, "by", NULL);
  if (by != NULL && g_strcmp0 (by, "title") == 0)
    return "title";
  return "app-id";
}

static McpToolResult *
gowl_missing (const gchar *what)
{
  McpToolResult *r = mcp_tool_result_new (TRUE);
  g_autofree gchar *msg = g_strdup_printf ("Missing required argument: %s",
                                           what);
  mcp_tool_result_add_text (r, msg);
  return r;
}

/* ── gowl_screenshot ──────────────────────────────────────────────── */

static McpToolResult *
handle_gowl_screenshot (McpServer *s, const gchar *n,
                        JsonObject *a, gpointer u)
{
  g_autoptr (GError) error = NULL;
  g_autofree gchar *path = NULL, *expr = NULL, *str = NULL;
  const gchar *pattern, *mode;
  McpToolResult *result;
  (void) s; (void) n; (void) u;

  path = g_strdup_printf ("%s/cmacs-mcp-shot-%u.png",
                          g_get_tmp_dir (), g_random_int ());
  pattern = json_object_get_string_member_with_default (a, "client", NULL);
  mode = json_object_get_string_member_with_default (a, "mode", NULL);
  if (mode == NULL
      || (g_strcmp0 (mode, "desktop") != 0
          && g_strcmp0 (mode, "window") != 0
          && g_strcmp0 (mode, "all") != 0))
    mode = "desktop";

  if (pattern != NULL)
    {
      g_autofree gchar *ep = cmacs_dispatch_lisp_escape (pattern);
      /* CMACS redact: an image cannot be rewritten the way a title
         can, so the user's privacy rules are asked first and the
         capture refused whole (cmacs-redact-capture-guard signals).
         A single window is its own picture, so only that window is
         asked about; an excluded one is reported exactly like one that
         matched nothing, so the pattern cannot be used to probe.  */
      expr = g_strdup_printf (
        "(progn (require 'cmacs-redact)"
        " (let ((c (gowl-find-client \"%s\" '%s)))"
        "  (if (and c (not (cmacs-redact-capture-refused-p 'client c)))"
        "      (let ((shot (gowl-screenshot-client c)))"
        "          (when shot"
        "            (apply #'gowl-screenshot-save-png"
        "                   (append shot (list \"%s\"))) t))"
        "    (error \"no client matching pattern\"))))",
        ep, gowl_by_field (a), path);
    }
  else
    /* MODE is one of three literals checked above: `window' is the
       focused window alone, the other two everything on screen.  */
    expr = g_strdup_printf (
      "(progn (require 'cmacs-redact)"
      " (cmacs-redact-capture-guard '%s)"
      " (gowl-screenshot '%s \"%s\" t))", mode, mode, path);

  str = cmacs_dispatch_eval (expr, &error);
  if (str == NULL)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, error->message);
      return r;
    }

  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, path))
    {
      mcp_tool_result_unref (result);
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, "Screenshot capture produced no image");
    }
  return result;
}

/* ── gowl_hotkey_send ───────────────────────────────────────────────
 *
 * One `hotkey-' module command run through `cmacs-gowl-hotkey-command'
 * (cmacs-gowl-hotkey.el), which loads the opt-in module and never
 * signals: an error comes back as "ERROR ..." text, turned into an MCP
 * error here.  Free text (keys) must be one line, since the command
 * framing is a line. */

static McpToolResult *
gowl_hotkey_line (const gchar *line)
{
  g_autofree gchar *el = cmacs_dispatch_lisp_escape (line);
  g_autofree gchar *expr = g_strdup_printf (
    "(progn (require 'cmacs-gowl-hotkey) "
    "(cmacs-gowl-hotkey-command \"%s\"))", el);
  GError *error = NULL;
  gchar *str = cmacs_dispatch_eval_string (expr, &error);
  McpToolResult *r;

  if (str != NULL && g_str_has_prefix (str, "ERROR"))
    {
      r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, str + (str[5] == ' ' ? 6 : 5));
      g_free (str);
      return r;
    }
  r = gowl_result (str, error);
  g_clear_error (&error);
  return r;
}

/* Free text for the command line: present, and one line. */
static gboolean
gowl_hotkey_one_line (const gchar *t)
{
  return t != NULL && *t != '\0' && strpbrk (t, "\n\r") == NULL;
}

static McpToolResult *
handle_gowl_hotkey_send (McpServer *s, const gchar *n,
                         JsonObject *a, gpointer u)
{
  const gchar *keys, *text;
  g_autofree gchar *line = NULL;
  (void) s; (void) n; (void) u;

  keys = json_object_get_string_member_with_default (a, "keys", NULL);
  text = json_object_get_string_member_with_default (a, "text", NULL);
  if (keys != NULL)
    {
      if (!gowl_hotkey_one_line (keys))
        return gowl_missing ("keys (one line; {Enter} for a newline)");
      line = g_strdup_printf ("hotkey-send %s", keys);
    }
  else
    {
      if (!gowl_hotkey_one_line (text))
        return gowl_missing ("keys or text (one line)");
      line = g_strdup_printf ("hotkey-send-text %s", text);
    }
  return gowl_hotkey_line (line);
}

/* ── Registration ─────────────────────────────────────────────────── */

void
cmacs_mcp_tools_gowl_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  /* Names, descriptions, schemas and hints below are what the two tools
     have always published; see the frozen wire schema before changing
     any of them.  */

  /* gowl_screenshot */
  tool = mcp_tool_new ("gowl_screenshot",
    "Capture a screenshot and return it as a PNG image. With no "
    "arguments captures the whole desktop; mode selects "
    "desktop/window/all; client captures one matching client.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"mode\":{\"type\":\"string\","
    "\"enum\":[\"desktop\",\"window\",\"all\"],"
    "\"description\":\"Capture mode (default: desktop)\"},"
    "\"client\":{\"type\":\"string\","
    "\"description\":\"Capture the client matching this pattern\"},"
    "\"by\":{\"type\":\"string\",\"enum\":[\"app-id\",\"title\"],"
    "\"description\":\"Client match field (default: app-id)\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_gowl_screenshot, NULL, NULL);
  g_object_unref (tool);

  /* gowl_hotkey_send */
  tool = mcp_tool_new ("gowl_hotkey_send",
    "Type keys or text into the focused window through the hotkey "
    "module.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"keys\":{\"type\":\"string\",\"description\":\"AutoHotkey "
    "Send syntax: ^c, {Enter}, {Tab 3}, {Shift down}\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Literal "
    "text instead\"}}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_gowl_hotkey_send, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_GOWL */
