/* cmacs-ai-mcp-bridge.h --- expose cmacs MCP tools as ai-glib callbacks
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Inverse of cmacs/mcp/cmacs-mcp-tools-ai.c: that file lets external
 * MCP clients (e.g. an outer Claude Code) drive cmacs-ai; THIS file
 * lets the in-process cmacs-ai drive cmacs's MCP tool surface.
 *
 * For each McpTool on a given McpServer (typically
 * `cmacs_mcp_get_internal_server'), an AiTool is built from the
 * McpTool's input_schema and registered on an AiToolExecutor as a
 * custom AiToolCallback.  When the model invokes one of these tools
 * the callback routes back through `mcp_server_invoke_tool', which
 * runs the SAME handler an external client would hit.
 */

#ifndef CMACS_AI_MCP_BRIDGE_H
#define CMACS_AI_MCP_BRIDGE_H

#include <config.h>

#if defined(HAVE_CMACS_AI) && defined(HAVE_CMACS_MCP)

#include <ai-glib.h>
#include <mcp.h>

/* Register MCP tools from SERVER as custom AiTools on EXEC.
 *
 * Filtering:
 *   - A tool is kept iff some regex in ALLOWLIST matches its name
 *     (NULL allowlist = match all).
 *   - A tool is rejected if any regex in DENYLIST matches.  The
 *     denylist always implicitly includes "^ai_" to block
 *     AI-driving-AI recursion regardless of caller intent.
 *   - If READONLY_ONLY is TRUE, only tools whose McpTool has
 *     `mcp_tool_get_read_only_hint(tool) == TRUE' pass.
 *
 * Returns the number of tools successfully registered.  Tools whose
 * input_schema can't be represented in AiTool's flat-properties
 * model (rare for the default cmacs allowlist; logged via g_message)
 * are skipped and don't count. */
guint cmacs_ai_mcp_bridge_register_tools (AiToolExecutor  *exec,
                                          McpServer       *server,
                                          GPtrArray       *allowlist,
                                          GPtrArray       *denylist,
                                          gboolean         readonly_only);

#endif /* HAVE_CMACS_AI && HAVE_CMACS_MCP */
#endif /* CMACS_AI_MCP_BRIDGE_H */
