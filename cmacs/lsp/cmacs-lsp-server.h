/* cmacs-lsp-server.h --- generic LSP server core

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_SERVER_H
#define CMACS_LSP_SERVER_H

#include <glib.h>
#include <json-glib/json-glib.h>

#include "cmacs-lsp-document.h"

typedef struct CmacsLspServer CmacsLspServer;

/* A language backend.  The core run loop owns the transport, lifecycle
   (initialize/shutdown/exit), and the full-sync document store; language
   smarts live behind these slots.  Position-taking slots receive the raw
   LSP position (0-based LINE, UTF-16 COL -- convert with
   cmacs_lsp_utf16_to_byte) and must send exactly one response for ID.
   A NULL slot means the method is not advertised and is answered with a
   null result.

   Capabilities: the core advertises textDocumentSync plus the boolean /
   plain providers derived from non-NULL slots (completion, hover,
   definition, documentSymbol).  Providers that carry backend-specific
   payloads (signatureHelpProvider trigger characters, the semanticTokens
   legend, ...) are emitted by init_capabilities, which is called with the
   builder positioned inside the "capabilities" object.  */
typedef struct CmacsLspServerOps
{
  const char *server_name;      /* serverInfo.name */
  const char *server_version;   /* serverInfo.version */

  void (*init_capabilities) (JsonBuilder *builder);
  void (*completion) (CmacsLspServer *server, CmacsLspDocument *doc,
                      guint line, guint col, gint64 id);
  void (*hover) (CmacsLspServer *server, CmacsLspDocument *doc,
                 guint line, guint col, gint64 id);
  void (*signature_help) (CmacsLspServer *server, CmacsLspDocument *doc,
                          guint line, guint col, gint64 id);
  void (*definition) (CmacsLspServer *server, CmacsLspDocument *doc,
                      guint line, guint col, gint64 id);
  void (*document_symbol) (CmacsLspServer *server, CmacsLspDocument *doc,
                           gint64 id);
  void (*semantic_tokens) (CmacsLspServer *server, CmacsLspDocument *doc,
                           gint64 id);
  /* Analyze DOC and publish textDocument/publishDiagnostics.  Called
     after didOpen and after every didChange.  */
  void (*diagnose) (CmacsLspServer *server, CmacsLspDocument *doc);
} CmacsLspServerOps;

extern CmacsLspServer *cmacs_lsp_server_new (const CmacsLspServerOps *ops);
extern void cmacs_lsp_server_free (CmacsLspServer *server);

/* Blocking read/dispatch loop over stdio.  Returns the process exit
   status: 0 when `exit' followed a `shutdown' request, 1 otherwise.  */
extern int cmacs_lsp_server_run (CmacsLspServer *server);

#endif /* CMACS_LSP_SERVER_H */
