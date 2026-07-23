/* cmacs-lsp-io.h --- LSP JSON-RPC stdio transport

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_IO_H
#define CMACS_LSP_IO_H

#include <glib.h>
#include <json-glib/json-glib.h>

/* JSON-RPC standard error codes.  */
#define CMACS_LSP_JSONRPC_PARSE_ERROR      (-32700)
#define CMACS_LSP_JSONRPC_INVALID_REQUEST  (-32600)
#define CMACS_LSP_JSONRPC_METHOD_NOT_FOUND (-32601)
#define CMACS_LSP_JSONRPC_INVALID_PARAMS   (-32602)
#define CMACS_LSP_JSONRPC_INTERNAL_ERROR   (-32603)

/* LSP-specific error codes.  */
#define CMACS_LSP_ERROR_SERVER_NOT_INITIALIZED (-32002)

extern gchar *cmacs_lsp_read_message (GError **error);
extern void cmacs_lsp_write_message (const gchar *json_str);
extern void cmacs_lsp_send_response (gint64 id, JsonNode *result);
extern void cmacs_lsp_send_response_builder (gint64 id, JsonBuilder *builder);
extern void cmacs_lsp_send_error (gint64 id, gint code, const gchar *message);
extern void cmacs_lsp_send_notification (const gchar *method,
                                         JsonNode *params);

#endif /* CMACS_LSP_IO_H */
