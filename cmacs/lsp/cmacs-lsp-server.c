/* cmacs-lsp-server.c --- generic LSP server core

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* Blocking JSON-RPC read/dispatch loop with the same lifecycle semantics
   as bacon's language server (deps/bacon/lsp/bacon-lsp-server.c):
   lifecycle methods are always allowed; other requests error with -32002
   until `initialized' arrives; unknown methods with an id get -32601;
   `$/cancelRequest' is a no-op; `exit' ends the loop.  Language behavior
   is delegated to a CmacsLspServerOps vtable so every `--cmacs-lsp'
   backend shares this core.  */

#include <config.h>

#ifdef HAVE_CMACS_LSP

#include "cmacs-lsp-server.h"
#include "cmacs-lsp-io.h"

#include <string.h>

struct CmacsLspServer
{
  const CmacsLspServerOps *ops;
  GHashTable *documents;
  gboolean initialized;
  gboolean shutdown_requested;
};

CmacsLspServer *
cmacs_lsp_server_new (const CmacsLspServerOps *ops)
{
  CmacsLspServer *server;

  g_return_val_if_fail (ops != NULL, NULL);

  server = g_new0 (CmacsLspServer, 1);
  server->ops = ops;
  server->documents = cmacs_lsp_document_store_new ();
  server->initialized = FALSE;
  server->shutdown_requested = FALSE;
  return server;
}

void
cmacs_lsp_server_free (CmacsLspServer *server)
{
  if (server == NULL)
    return;
  g_hash_table_destroy (server->documents);
  g_free (server);
}

/* Convenience JSON accessors (absent members yield NULL / DEF).  */

static const gchar *
get_string (JsonObject *obj, const gchar *key)
{
  if (obj == NULL || !json_object_has_member (obj, key))
    return NULL;
  return json_object_get_string_member (obj, key);
}

static gint64
get_int (JsonObject *obj, const gchar *key, gint64 def)
{
  if (obj == NULL || !json_object_has_member (obj, key))
    return def;
  return json_object_get_int_member (obj, key);
}

static JsonObject *
get_object (JsonObject *obj, const gchar *key)
{
  if (obj == NULL || !json_object_has_member (obj, key))
    return NULL;
  return json_object_get_object_member (obj, key);
}

/* Extract textDocument.uri and position.{line,character} from PARAMS.
   *URI is borrowed from PARAMS.  */

static void
extract_position (JsonObject *params, const gchar **uri, guint *line,
                  guint *col)
{
  JsonObject *td;
  JsonObject *pos;

  td = get_object (params, "textDocument");
  *uri = get_string (td, "uri");

  pos = get_object (params, "position");
  *line = (guint) get_int (pos, "line", 0);
  *col = (guint) get_int (pos, "character", 0);
}

static void
handle_initialize (CmacsLspServer *server, gint64 id)
{
  const CmacsLspServerOps *ops = server->ops;
  JsonBuilder *b;

  server->initialized = TRUE;

  b = json_builder_new ();
  json_builder_begin_object (b);

  json_builder_set_member_name (b, "capabilities");
  json_builder_begin_object (b);

  /* TextDocumentSyncKind.Full.  */
  json_builder_set_member_name (b, "textDocumentSync");
  json_builder_add_int_value (b, 1);

  if (ops->completion != NULL)
    {
      json_builder_set_member_name (b, "completionProvider");
      json_builder_begin_object (b);
      json_builder_set_member_name (b, "resolveProvider");
      json_builder_add_boolean_value (b, FALSE);
      json_builder_end_object (b);
    }

  if (ops->hover != NULL)
    {
      json_builder_set_member_name (b, "hoverProvider");
      json_builder_add_boolean_value (b, TRUE);
    }

  if (ops->definition != NULL)
    {
      json_builder_set_member_name (b, "definitionProvider");
      json_builder_add_boolean_value (b, TRUE);
    }

  if (ops->document_symbol != NULL)
    {
      json_builder_set_member_name (b, "documentSymbolProvider");
      json_builder_add_boolean_value (b, TRUE);
    }

  /* signatureHelpProvider, semanticTokensProvider, and any other
     payload-carrying providers come from the backend.  */
  if (ops->init_capabilities != NULL)
    ops->init_capabilities (b);

  json_builder_end_object (b);  /* capabilities */

  json_builder_set_member_name (b, "serverInfo");
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "name");
  json_builder_add_string_value (b, ops->server_name
                                 ? ops->server_name : "cmacs-lsp");
  json_builder_set_member_name (b, "version");
  json_builder_add_string_value (b, ops->server_version
                                 ? ops->server_version : "0.1.0");
  json_builder_end_object (b);

  json_builder_end_object (b);

  cmacs_lsp_send_response_builder (id, b);
  g_object_unref (b);
}

static void
handle_did_open (CmacsLspServer *server, JsonObject *params)
{
  JsonObject *td;
  const gchar *uri;
  const gchar *text;
  gint64 version;
  CmacsLspDocument *doc;

  td = get_object (params, "textDocument");
  uri = get_string (td, "uri");
  text = get_string (td, "text");
  version = get_int (td, "version", 0);

  if (uri == NULL)
    {
      g_printerr ("cmacs-lsp: didOpen missing textDocument.uri\n");
      return;
    }

  doc = cmacs_lsp_document_store_open (server->documents, uri, text,
                                       version);
  if (server->ops->diagnose != NULL)
    server->ops->diagnose (server, doc);
}

static void
handle_did_change (CmacsLspServer *server, JsonObject *params)
{
  JsonObject *td;
  JsonArray *changes;
  const gchar *uri;
  gint64 version;
  CmacsLspDocument *doc;

  td = get_object (params, "textDocument");
  uri = get_string (td, "uri");
  version = get_int (td, "version", 0);

  if (uri == NULL)
    {
      g_printerr ("cmacs-lsp: didChange missing textDocument.uri\n");
      return;
    }

  changes = NULL;
  if (params != NULL && json_object_has_member (params, "contentChanges"))
    changes = json_object_get_array_member (params, "contentChanges");

  if (changes != NULL && json_array_get_length (changes) > 0)
    {
      /* Full sync: the last change carries the whole new text.  */
      JsonObject *change;
      const gchar *text;

      change = json_array_get_object_element
        (changes, json_array_get_length (changes) - 1);
      text = get_string (change, "text");

      doc = cmacs_lsp_document_store_get (server->documents, uri);
      if (doc != NULL)
        {
          cmacs_lsp_document_update (doc, text, version);
          if (server->ops->diagnose != NULL)
            server->ops->diagnose (server, doc);
        }
    }
}

static void
handle_did_close (CmacsLspServer *server, JsonObject *params)
{
  JsonObject *td;
  const gchar *uri;
  JsonBuilder *b;
  JsonNode *pnode;

  td = get_object (params, "textDocument");
  uri = get_string (td, "uri");

  if (uri == NULL)
    {
      g_printerr ("cmacs-lsp: didClose missing textDocument.uri\n");
      return;
    }

  /* Clear the document's diagnostics on close.  */
  b = json_builder_new ();
  json_builder_begin_object (b);
  json_builder_set_member_name (b, "uri");
  json_builder_add_string_value (b, uri);
  json_builder_set_member_name (b, "diagnostics");
  json_builder_begin_array (b);
  json_builder_end_array (b);
  json_builder_end_object (b);

  pnode = json_builder_get_root (b);
  cmacs_lsp_send_notification ("textDocument/publishDiagnostics", pnode);
  json_node_unref (pnode);
  g_object_unref (b);

  cmacs_lsp_document_store_close (server->documents, uri);
}

/* Dispatch a position-taking request to SLOT, answering null when the
   backend has no slot or the document is unknown.  */

static void
dispatch_positional (CmacsLspServer *server, JsonObject *params, gint64 id,
                     void (*slot) (CmacsLspServer *, CmacsLspDocument *,
                                   guint, guint, gint64))
{
  const gchar *uri;
  guint line;
  guint col;
  CmacsLspDocument *doc;

  uri = NULL;
  extract_position (params, &uri, &line, &col);

  doc = NULL;
  if (uri != NULL)
    doc = cmacs_lsp_document_store_get (server->documents, uri);

  if (slot == NULL || doc == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  slot (server, doc, line, col, id);
}

/* Dispatch a whole-document request to SLOT (same null-answer rules).  */

static void
dispatch_document (CmacsLspServer *server, JsonObject *params, gint64 id,
                   void (*slot) (CmacsLspServer *, CmacsLspDocument *,
                                 gint64))
{
  JsonObject *td;
  const gchar *uri;
  CmacsLspDocument *doc;

  td = get_object (params, "textDocument");
  uri = get_string (td, "uri");

  doc = NULL;
  if (uri != NULL)
    doc = cmacs_lsp_document_store_get (server->documents, uri);

  if (slot == NULL || doc == NULL)
    {
      cmacs_lsp_send_response (id, NULL);
      return;
    }

  slot (server, doc, id);
}

int
cmacs_lsp_server_run (CmacsLspServer *server)
{
  const CmacsLspServerOps *ops;
  gboolean running;

  g_return_val_if_fail (server != NULL, 1);

  ops = server->ops;
  running = TRUE;

  while (running)
    {
      gchar *body;
      GError *error;
      JsonParser *parser;
      JsonNode *root;
      JsonObject *msg;
      const gchar *method;
      gint64 id;
      JsonObject *params;

      error = NULL;
      body = cmacs_lsp_read_message (&error);
      if (body == NULL)
        {
          if (error != NULL)
            {
              g_printerr ("cmacs-lsp: %s\n", error->message);
              g_clear_error (&error);
              continue;
            }
          /* EOF: client went away.  */
          break;
        }

      parser = json_parser_new ();
      if (!json_parser_load_from_data (parser, body, -1, &error))
        {
          g_printerr ("cmacs-lsp: parse error: %s\n",
                      error ? error->message : "(unknown)");
          g_clear_error (&error);
          cmacs_lsp_send_error (-1, CMACS_LSP_JSONRPC_PARSE_ERROR,
                                "Parse error");
          g_object_unref (parser);
          g_free (body);
          continue;
        }

      root = json_parser_get_root (parser);
      msg = (root != NULL && JSON_NODE_HOLDS_OBJECT (root))
        ? json_node_get_object (root) : NULL;

      method = get_string (msg, "method");
      /* Requests carry an id; notifications do not (-1 here).  */
      id = get_int (msg, "id", -1);
      params = get_object (msg, "params");

      if (method == NULL)
        {
          if (id >= 0)
            cmacs_lsp_send_error (id, CMACS_LSP_JSONRPC_INVALID_REQUEST,
                                  "Invalid request");
        }
      else if (strcmp (method, "initialize") == 0)
        handle_initialize (server, id);
      else if (strcmp (method, "initialized") == 0)
        ;
      else if (strcmp (method, "shutdown") == 0)
        {
          server->shutdown_requested = TRUE;
          cmacs_lsp_send_response (id, NULL);
        }
      else if (strcmp (method, "exit") == 0)
        running = FALSE;
      else if (strcmp (method, "$/cancelRequest") == 0)
        ;
      else if (!server->initialized)
        {
          if (id >= 0)
            cmacs_lsp_send_error (id, CMACS_LSP_ERROR_SERVER_NOT_INITIALIZED,
                                  "Server not initialized");
        }
      else if (strcmp (method, "textDocument/didOpen") == 0)
        handle_did_open (server, params);
      else if (strcmp (method, "textDocument/didChange") == 0)
        handle_did_change (server, params);
      else if (strcmp (method, "textDocument/didClose") == 0)
        handle_did_close (server, params);
      else if (strcmp (method, "textDocument/completion") == 0)
        dispatch_positional (server, params, id, ops->completion);
      else if (strcmp (method, "textDocument/hover") == 0)
        dispatch_positional (server, params, id, ops->hover);
      else if (strcmp (method, "textDocument/signatureHelp") == 0)
        dispatch_positional (server, params, id, ops->signature_help);
      else if (strcmp (method, "textDocument/definition") == 0)
        dispatch_positional (server, params, id, ops->definition);
      else if (strcmp (method, "textDocument/documentSymbol") == 0)
        dispatch_document (server, params, id, ops->document_symbol);
      else if (strcmp (method, "textDocument/semanticTokens/full") == 0)
        dispatch_document (server, params, id, ops->semantic_tokens);
      else if (id >= 0)
        cmacs_lsp_send_error (id, CMACS_LSP_JSONRPC_METHOD_NOT_FOUND,
                              "Method not found");

      g_object_unref (parser);
      g_free (body);
    }

  return server->shutdown_requested ? 0 : 1;
}

#endif /* HAVE_CMACS_LSP */
