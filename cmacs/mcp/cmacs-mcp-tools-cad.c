/*
 * cmacs-mcp-tools-cad.c — the one CAD MCP tool that is still C
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * cad_snapshot renders a part and returns it as an inline PNG.  A
 * registry tool (`cmacs-brigade-deftool') returns text, so this one
 * stays a hand-written handler.
 *
 * The other seventeen cad_* tools that used to be registered here are
 * registry tools now (lisp/cmacs/cmacs-cad-tools.el), published by
 * cmacs-mcp-tools-brigade.c in every build with an MCP server; their C
 * handlers were deleted.  What they promised a client is frozen in
 * test/cmacs/data/mcp-wire-schema.json.
 */

#include <config.h>

#if defined(HAVE_CMACS_MCP) && defined(HAVE_CMACS_CAD)

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

/* Render STR as an Elisp string literal, or `nil' when STR is NULL. */
static gchar *
cad_lisp_str (const gchar *str)
{
  GString *s;
  const gchar *p;
  if (str == NULL)
    return g_strdup ("nil");
  s = g_string_new ("\"");
  for (p = str; *p; p++)
    {
      if (*p == '"' || *p == '\\')
        g_string_append_c (s, '\\');
      g_string_append_c (s, *p);
    }
  g_string_append_c (s, '"');
  return g_string_free (s, FALSE);
}

/* Wrap BODY so the cmacs-cad-mcp helper library is loaded first.  Takes
 * ownership of BODY. */
static gchar *
cad_wrap (gchar *body)
{
  gchar *out =
    g_strdup_printf ("(progn (require 'cmacs-cad-mcp) %s)", body);
  g_free (body);
  return out;
}

/* The "path" argument, as an Elisp string literal (caller frees). */
static gchar *
cad_path_arg (JsonObject *a)
{
  return cad_lisp_str (json_object_has_member (a, "path")
    ? json_object_get_string_member_with_default (a, "path", NULL) : NULL);
}

static McpToolResult *
handle_snapshot (McpServer *s, const gchar *n, JsonObject *a, gpointer u)
{
  g_autofree gchar *p = cad_path_arg (a);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *elisp =
    cad_wrap (g_strdup_printf ("(cmacs-cad-mcp-snapshot %s)", p));
  g_autofree gchar *out = cmacs_dispatch_eval (elisp, &error);
  McpToolResult *result;
  (void) s; (void) n; (void) u;

  if (out == NULL)
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, error ? error->message : "error");
      return result;
    }
  /* The helper returns the PNG path, or a string starting "error:". */
  if (g_str_has_prefix (out, "error:"))
    {
      result = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (result, out);
      return result;
    }
  result = mcp_tool_result_new (FALSE);
  if (!cmacs_mcp_result_add_png_file (result, out))
    mcp_tool_result_add_text (result, out);
  return result;
}

#define PATH_SCHEMA \
  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}," \
  "\"required\":[\"path\"]}"

void
cmacs_mcp_tools_cad_register (McpServer *server)
{
  McpTool *tool;

  /* cad_snapshot.  Name, description, schema and hint are what the tool
     has always published; see the frozen wire schema before changing
     any of them.  */
  tool = mcp_tool_new ("cad_snapshot",
    "Render the part in a workbench viewport and return an inline PNG.");
  mcp_tool_set_input_schema (tool,
    cmacs_mcp_schema_from_string (PATH_SCHEMA));
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_snapshot, NULL, NULL);
  g_object_unref (tool);
}

#endif /* HAVE_CMACS_MCP && HAVE_CMACS_CAD */
