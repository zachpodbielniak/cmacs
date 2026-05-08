/*
 * cmacs-mcp-tools.h — MCP tool registration declarations
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_MCP_TOOLS_H
#define CMACS_MCP_TOOLS_H

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include <mcp.h>
#include <json-glib/json-glib.h>

/* Master registration: calls all category functions below. */
void cmacs_mcp_register_all_tools (McpServer *server);

/* Per-category tool registration. */
void cmacs_mcp_tools_eval_register    (McpServer *server);
void cmacs_mcp_tools_buffer_register  (McpServer *server);
void cmacs_mcp_tools_window_register  (McpServer *server);
void cmacs_mcp_tools_input_register   (McpServer *server);
void cmacs_mcp_tools_process_register (McpServer *server);
void cmacs_mcp_tools_debug_register   (McpServer *server);

#ifdef HAVE_CMACS_GI
void cmacs_mcp_tools_gi_register      (McpServer *server);
#endif

#ifdef HAVE_CMACS_GOWL
void cmacs_mcp_tools_gowl_register    (McpServer *server);
#endif

#ifdef HAVE_CMACS_CINTROSPECT
void cmacs_mcp_tools_cintrospect_register (McpServer *server);
#endif

/* Resource and prompt registration. */
void cmacs_mcp_register_resources (McpServer *server);
void cmacs_mcp_register_prompts   (McpServer *server);

/* Helper: parse a JSON schema string into a JsonNode (cached). */
JsonNode *cmacs_mcp_schema_from_string (const gchar *json_str);

#endif /* HAVE_CMACS_MCP */
#endif /* CMACS_MCP_TOOLS_H */
