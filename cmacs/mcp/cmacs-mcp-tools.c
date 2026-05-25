/*
 * cmacs-mcp-tools.c — MCP tool master registration and schema helper
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include "cmacs-mcp-tools.h"

#include <json-glib/json-glib.h>
#include <glib/gstdio.h>

/* ── Schema helper ────────────────────────────────────────────────── */

JsonNode *
cmacs_mcp_schema_from_string (const gchar *json_str)
{
  g_autoptr (JsonParser) parser = json_parser_new ();
  g_autoptr (GError) error = NULL;

  if (!json_parser_load_from_data (parser, json_str, -1, &error))
    {
      g_warning ("cmacs-mcp: bad JSON schema: %s", error->message);
      return NULL;
    }

  return json_node_copy (json_parser_get_root (parser));
}

/* ── Image content helper ─────────────────────────────────────────── */

gboolean
cmacs_mcp_result_add_png_file (McpToolResult *result, const gchar *path)
{
  g_autofree gchar *data = NULL;
  g_autofree gchar *b64 = NULL;
  gsize len = 0;

  if (path == NULL
      || !g_file_get_contents (path, &data, &len, NULL)
      || len == 0)
    return FALSE;

  b64 = g_base64_encode ((const guchar *) data, len);
  mcp_tool_result_add_image (result, b64, "image/png");
  g_unlink (path);
  return TRUE;
}

/* ── Master registration ──────────────────────────────────────────── */

void
cmacs_mcp_register_all_tools (McpServer *server)
{
  cmacs_mcp_tools_eval_register (server);
  cmacs_mcp_tools_buffer_register (server);
  cmacs_mcp_tools_window_register (server);
  cmacs_mcp_tools_input_register (server);
  cmacs_mcp_tools_process_register (server);
  cmacs_mcp_tools_debug_register (server);
  cmacs_mcp_tools_edit_register (server);
  cmacs_mcp_tools_shell_register (server);
  cmacs_mcp_tools_project_register (server);

#ifdef HAVE_CMACS_GI
  cmacs_mcp_tools_gi_register (server);
#endif

#ifdef HAVE_CMACS_GOWL
  cmacs_mcp_tools_gowl_register (server);
#endif

#ifdef HAVE_CMACS_CINTROSPECT
  cmacs_mcp_tools_cintrospect_register (server);
#endif

#ifdef HAVE_CMACS_AUDIO
  cmacs_mcp_tools_audio_register (server);
#endif

#ifdef HAVE_CMACS_AI
  cmacs_mcp_tools_ai_register (server);
#endif
}

#endif /* HAVE_CMACS_MCP */
