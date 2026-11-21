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

/* Master registration: the hand-written C tools, then the registry. */
void cmacs_mcp_register_all_tools (McpServer *server);

/* Only the hand-written C tools.  For a server set up before Lisp files
 * can be loaded, which then gets the registry from
 * cmacs_mcp_tools_brigade_sync. */
void cmacs_mcp_register_c_tools (McpServer *server);

/* The tools that are still hand-written C; see the comment in
 * cmacs_mcp_register_all_tools.  */
void cmacs_mcp_tools_eval_register    (McpServer *server);
void cmacs_mcp_tools_input_register   (McpServer *server);
void cmacs_mcp_tools_process_register (McpServer *server);
void cmacs_mcp_tools_shell_register   (McpServer *server);

#ifdef HAVE_CMACS_GI
void cmacs_mcp_tools_gi_register      (McpServer *server);
#endif

#ifdef HAVE_CMACS_GOWL
void cmacs_mcp_tools_gowl_register    (McpServer *server);
#endif

#ifdef HAVE_CMACS_CINTROSPECT
void cmacs_mcp_tools_cintrospect_register (McpServer *server);
#endif

#ifdef HAVE_CMACS_CAD
void cmacs_mcp_tools_cad_register (McpServer *server);
#endif

#ifdef HAVE_CMACS_LRGTERM
void cmacs_mcp_tools_lrgterm_register (McpServer *server);
#endif

/* Publishes every capability registered through `cmacs-brigade-deftool'.
 * Walks the live registry rather than a static table, because a tool can
 * be registered at any point after startup.  In every build with an MCP
 * server: the registry does not need the brigade.  Also makes sure a
 * `capability_doctor' tool is listed, and appends a notice to SERVER's
 * instructions when the registry or one of its tool families failed to
 * load. */
void cmacs_mcp_tools_brigade_register (McpServer *server);
/* Bring SERVER up to date with the registry: the same as the function
 * above, skipped when nothing was registered or removed since SERVER
 * was last published.  For a server that outlives one session. */
void cmacs_mcp_tools_brigade_sync (McpServer *server);
/* DEFUNs of the registry mirror and, in a brigade build, of the
 * per-agent scoped sockets (`cmacs-brigade-scope-open' and friends).
 * Called from syms_of_cmacs_mcp. */
void syms_of_cmacs_mcp_tools_brigade (void);

/* Resource and prompt registration. */

void cmacs_mcp_register_resources (McpServer *server);
void cmacs_mcp_register_prompts   (McpServer *server);

/* Helper: parse a JSON schema string into a JsonNode (cached). */
JsonNode *cmacs_mcp_schema_from_string (const gchar *json_str);

/* Helper: read the PNG file at PATH, base64-encode it, attach it to
   RESULT as image content, and unlink PATH.  Returns TRUE on success;
   on failure RESULT is left untouched and PATH is not removed. */
gboolean cmacs_mcp_result_add_png_file (McpToolResult *result,
                                        const gchar   *path);

/* Create a private scratch file for a tool to write into and return its
   path (caller g_frees, and unlinks when done -- cmacs_mcp_result_add_png_file
   does the unlink itself).  TEMPLATE is a basename containing "XXXXXX",
   e.g. "cmacs-mcp-frame-XXXXXX.png".  The file is created 0600 with
   O_EXCL under the user's runtime directory, never in the shared tmp
   directory under a guessable name, so another local user cannot plant
   a symlink where a screenshot is about to be written.  NULL on
   failure. */
gchar *cmacs_mcp_temp_path (const gchar *template);

/* True when PATH fits a sockaddr_un.  bind() does not fail on a longer
 * one; it binds a truncated path. */
gboolean cmacs_mcp_fits_sun_path (const gchar *path);

/* $TMPDIR/cmacs-<uid>, created 0700 and refused unless it is a private
 * directory of ours: where sockets go when the runtime directory's path
 * is too long for them.  Free with g_free. */
gchar *cmacs_mcp_private_tmp_dir (GError **error);

#endif /* HAVE_CMACS_MCP */
#endif /* CMACS_MCP_TOOLS_H */
