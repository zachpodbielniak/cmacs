/* cmacs-lsp-document.c --- LSP document store

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#include <config.h>

#ifdef HAVE_CMACS_LSP

#include "cmacs-lsp-document.h"

#include <string.h>

CmacsLspDocument *
cmacs_lsp_document_new (const gchar *uri, const gchar *text, gint64 version)
{
  CmacsLspDocument *doc;

  doc = g_new0 (CmacsLspDocument, 1);
  doc->uri = g_strdup (uri);
  doc->text = g_strdup (text ? text : "");
  doc->version = version;
  return doc;
}

void
cmacs_lsp_document_update (CmacsLspDocument *doc, const gchar *text,
                           gint64 version)
{
  g_return_if_fail (doc != NULL);

  g_free (doc->text);
  doc->text = g_strdup (text ? text : "");
  doc->version = version;
}

void
cmacs_lsp_document_free (CmacsLspDocument *doc)
{
  if (doc == NULL)
    return;
  g_free (doc->uri);
  g_free (doc->text);
  g_free (doc);
}

/* Point *START / *END at the bounds of 0-based LINE within TEXT (END
   excludes the newline).  Return FALSE when LINE is out of range.  */

static gboolean
line_bounds (const gchar *text, guint line, const gchar **start,
             const gchar **end)
{
  const gchar *p = text;
  guint n = 0;

  while (n < line)
    {
      p = strchr (p, '\n');
      if (p == NULL)
        return FALSE;
      p++;
      n++;
    }

  *start = p;
  *end = strchr (p, '\n');
  if (*end == NULL)
    *end = p + strlen (p);
  return TRUE;
}

gchar *
cmacs_lsp_document_line (CmacsLspDocument *doc, guint line)
{
  const gchar *start;
  const gchar *end;

  g_return_val_if_fail (doc != NULL, NULL);

  if (!line_bounds (doc->text, line, &start, &end))
    return NULL;
  return g_strndup (start, end - start);
}

guint
cmacs_lsp_document_nlines (CmacsLspDocument *doc)
{
  const gchar *p;
  guint n = 1;

  g_return_val_if_fail (doc != NULL, 0);

  for (p = doc->text; (p = strchr (p, '\n')) != NULL; p++)
    n++;
  return n;
}

/* How many UTF-16 code units CH occupies (2 outside the BMP).  */

static guint
utf16_units (gunichar ch)
{
  return ch >= 0x10000 ? 2 : 1;
}

guint
cmacs_lsp_utf16_to_byte (const gchar *line, guint utf16_col)
{
  const gchar *p = line;
  guint units = 0;

  while (*p != '\0' && units < utf16_col)
    {
      units += utf16_units (g_utf8_get_char (p));
      p = g_utf8_next_char (p);
    }
  return p - line;
}

guint
cmacs_lsp_byte_to_utf16 (const gchar *line, guint byte_col)
{
  const gchar *p = line;
  guint units = 0;

  while (*p != '\0' && (guint) (p - line) < byte_col)
    {
      units += utf16_units (g_utf8_get_char (p));
      p = g_utf8_next_char (p);
    }
  return units;
}

GHashTable *
cmacs_lsp_document_store_new (void)
{
  return g_hash_table_new_full (g_str_hash, g_str_equal, NULL,
                                (GDestroyNotify) cmacs_lsp_document_free);
}

CmacsLspDocument *
cmacs_lsp_document_store_open (GHashTable *store, const gchar *uri,
                               const gchar *text, gint64 version)
{
  CmacsLspDocument *doc;

  doc = cmacs_lsp_document_new (uri, text, version);
  g_hash_table_replace (store, doc->uri, doc);
  return doc;
}

CmacsLspDocument *
cmacs_lsp_document_store_get (GHashTable *store, const gchar *uri)
{
  return g_hash_table_lookup (store, uri);
}

void
cmacs_lsp_document_store_close (GHashTable *store, const gchar *uri)
{
  g_hash_table_remove (store, uri);
}

#endif /* HAVE_CMACS_LSP */
