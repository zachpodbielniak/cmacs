/*
 * cmacs-mcp.h — CMacs MCP server subsystem
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Embeds an MCP server in Emacs via McpUnixSocketServer on the CMacs
 * GMainContext.  AI agents connect through the cmacs-mcp shim binary
 * and get full access to the Emacs runtime: eval, buffers, windows,
 * input, processes, debugging, GI, gowl, and more.
 */

#ifndef CMACS_MCP_H
#define CMACS_MCP_H

#include <config.h>

#ifdef HAVE_CMACS_MCP

#include <mcp.h>

/* Get the McpUnixSocketServer instance, or NULL if not started. */
extern McpUnixSocketServer *cmacs_mcp_get_server (void);

/* Get the socket path (e.g. /run/user/1000/cmacs-mcp-12345.sock). */
extern const gchar *cmacs_mcp_get_socket_path (void);

/* Get the process-lifetime "internal" McpServer.
 *
 * Tools / resources / prompts register here at `init_cmacs_mcp' time
 * the same way they register per-session for external clients.  In-
 * process consumers (the cmacs-ai MCP bridge in particular) enumerate
 * tools off this server and invoke them via `mcp_server_invoke_tool'.
 *
 * Lifetime spans the cmacs process; the server has no transport bound
 * and never participates in the JSON-RPC wire path. */
extern McpServer *cmacs_mcp_get_internal_server (void);

/* Subsystem lifecycle (called from emacs.c). */

#endif /* HAVE_CMACS_MCP */
#endif /* CMACS_MCP_H */
