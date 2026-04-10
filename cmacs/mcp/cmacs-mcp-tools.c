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

#ifdef HAVE_CMACS_GI
  cmacs_mcp_tools_gi_register (server);
#endif

#ifdef HAVE_CMACS_GOWL
  cmacs_mcp_tools_gowl_register (server);
#endif
}

#endif /* HAVE_CMACS_MCP */
