/* cmacs-lsp-io.c --- LSP JSON-RPC stdio transport

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* Content-Length framed JSON-RPC over stdin/stdout, ported from bacon's
   language server (deps/bacon/lsp/bacon-lsp-io.c).  stdout belongs to the
   protocol exclusively -- nothing else in an `emacs --cmacs-lsp' process
   may write to it; diagnostics go to stderr (g_printerr).  */

#include <config.h>

#ifdef HAVE_CMACS_LSP

#include "cmacs-lsp-io.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Read one line (including the terminating '\n') from FP into BUF.
   Return FALSE on EOF or error before any bytes were read.  The '\r'
   before '\n' (if present) is preserved so callers can detect the blank
   CRLF separator.  */

static gboolean
read_line (FILE *fp, GString *buf)
{
  int c;

  while ((c = fgetc (fp)) != EOF)
    {
      g_string_append_c (buf, (gchar) c);
      if (c == '\n')
        return TRUE;
    }

  return buf->len > 0;
}

/* Read one framed message body from stdin.  Return a NUL-terminated
   malloc'd body, or NULL on EOF (error unset) or framing error (error
   set).  */

gchar *
cmacs_lsp_read_message (GError **error)
{
  GString *line;
  glong content_length;
  gchar *body;
  gsize n_read;

  content_length = -1;
  line = g_string_new (NULL);

  /* Read headers until the blank CRLF separator.  */
  for (;;)
    {
      g_string_truncate (line, 0);

      if (!read_line (stdin, line))
        {
          /* EOF with no data.  */
          g_string_free (line, TRUE);
          return NULL;
        }

      /* Strip trailing \r\n.  */
      if (line->len >= 2
          && line->str[line->len - 1] == '\n'
          && line->str[line->len - 2] == '\r')
        g_string_truncate (line, line->len - 2);
      else if (line->len >= 1 && line->str[line->len - 1] == '\n')
        g_string_truncate (line, line->len - 1);

      /* Blank line = end of headers.  */
      if (line->len == 0)
        break;

      /* Parse Content-Length (case-insensitive prefix match); ignore
         other headers such as Content-Type.  */
      if (g_ascii_strncasecmp (line->str, "Content-Length:", 15) == 0)
        {
          const gchar *val = g_strstrip (line->str + 15);
          content_length = strtol (val, NULL, 10);
        }
    }

  g_string_free (line, TRUE);

  if (content_length <= 0)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                   "LSP: missing or invalid Content-Length header");
      return NULL;
    }

  body = g_malloc (content_length + 1);
  n_read = fread (body, 1, (gsize) content_length, stdin);

  if (n_read < (gsize) content_length)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_PARTIAL_INPUT,
                   "LSP: expected %ld bytes, got %" G_GSIZE_FORMAT,
                   content_length, n_read);
      g_free (body);
      return NULL;
    }

  body[content_length] = '\0';
  return body;
}

void
cmacs_lsp_write_message (const gchar *json_str)
{
  gsize len;

  g_return_if_fail (json_str != NULL);

  len = strlen (json_str);
  fprintf (stdout, "Content-Length: %" G_GSIZE_FORMAT "\r\n\r\n", len);
  fwrite (json_str, 1, len, stdout);
  fflush (stdout);
}

/* Serialize ROOT (consuming nothing) and write it as one framed
   message.  */

static void
write_root (JsonNode *root)
{
  JsonGenerator *gen;
  gchar *json;

  gen = json_generator_new ();
  json_generator_set_root (gen, root);
  json = json_generator_to_data (gen, NULL);

  cmacs_lsp_write_message (json);

  g_free (json);
  g_object_unref (gen);
}

void
cmacs_lsp_send_response (gint64 id, JsonNode *result)
{
  JsonBuilder *builder;
  JsonNode *root;

  builder = json_builder_new ();
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "jsonrpc");
  json_builder_add_string_value (builder, "2.0");
  json_builder_set_member_name (builder, "id");
  json_builder_add_int_value (builder, id);
  json_builder_set_member_name (builder, "result");
  if (result != NULL)
    json_builder_add_value (builder, result);
  else
    json_builder_add_null_value (builder);
  json_builder_end_object (builder);

  root = json_builder_get_root (builder);
  write_root (root);
  json_node_unref (root);
  g_object_unref (builder);
}

/* Send BUILDER's root as the "result" of a response to ID.  BUILDER must
   hold a complete value; it is not consumed.  */

void
cmacs_lsp_send_response_builder (gint64 id, JsonBuilder *builder)
{
  JsonNode *result;

  result = json_builder_get_root (builder);
  cmacs_lsp_send_response (id, result);
  json_node_unref (result);
}

void
cmacs_lsp_send_error (gint64 id, gint code, const gchar *message)
{
  JsonBuilder *builder;
  JsonNode *root;

  builder = json_builder_new ();
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "jsonrpc");
  json_builder_add_string_value (builder, "2.0");
  json_builder_set_member_name (builder, "id");
  if (id >= 0)
    json_builder_add_int_value (builder, id);
  else
    json_builder_add_null_value (builder);
  json_builder_set_member_name (builder, "error");
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "code");
  json_builder_add_int_value (builder, code);
  json_builder_set_member_name (builder, "message");
  json_builder_add_string_value (builder, message ? message : "");
  json_builder_end_object (builder);
  json_builder_end_object (builder);

  root = json_builder_get_root (builder);
  write_root (root);
  json_node_unref (root);
  g_object_unref (builder);
}

void
cmacs_lsp_send_notification (const gchar *method, JsonNode *params)
{
  JsonBuilder *builder;
  JsonNode *root;

  g_return_if_fail (method != NULL);

  builder = json_builder_new ();
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "jsonrpc");
  json_builder_add_string_value (builder, "2.0");
  json_builder_set_member_name (builder, "method");
  json_builder_add_string_value (builder, method);
  json_builder_set_member_name (builder, "params");
  if (params != NULL)
    json_builder_add_value (builder, params);
  else
    json_builder_add_null_value (builder);
  json_builder_end_object (builder);

  root = json_builder_get_root (builder);
  write_root (root);
  json_node_unref (root);
  g_object_unref (builder);
}

#endif /* HAVE_CMACS_LSP */
