/* cmacs-lsp-document.h --- LSP document store

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_DOCUMENT_H
#define CMACS_LSP_DOCUMENT_H

#include <glib.h>

/* One open text document, synced whole (TextDocumentSyncKind.Full).  */
typedef struct CmacsLspDocument
{
  gchar *uri;
  gchar *text;
  gint64 version;
} CmacsLspDocument;

extern CmacsLspDocument *cmacs_lsp_document_new (const gchar *uri,
                                                 const gchar *text,
                                                 gint64 version);
extern void cmacs_lsp_document_update (CmacsLspDocument *doc,
                                       const gchar *text, gint64 version);
extern void cmacs_lsp_document_free (CmacsLspDocument *doc);

/* Line access.  Lines are 0-based; the returned copy has no trailing
   newline.  NULL when LINE is out of range.  */
extern gchar *cmacs_lsp_document_line (CmacsLspDocument *doc, guint line);
extern guint cmacs_lsp_document_nlines (CmacsLspDocument *doc);

/* LSP positions count UTF-16 code units within a line; C code indexes
   bytes.  Convert between the two on one UTF-8 line (no newline).
   Offsets past the end clamp to the line end.  */
extern guint cmacs_lsp_utf16_to_byte (const gchar *line, guint utf16_col);
extern guint cmacs_lsp_byte_to_utf16 (const gchar *line, guint byte_col);

/* URI -> CmacsLspDocument store.  */
extern GHashTable *cmacs_lsp_document_store_new (void);
extern CmacsLspDocument *cmacs_lsp_document_store_open (GHashTable *store,
                                                        const gchar *uri,
                                                        const gchar *text,
                                                        gint64 version);
extern CmacsLspDocument *cmacs_lsp_document_store_get (GHashTable *store,
                                                       const gchar *uri);
extern void cmacs_lsp_document_store_close (GHashTable *store,
                                            const gchar *uri);

#endif /* CMACS_LSP_DOCUMENT_H */
