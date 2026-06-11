/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-formatter-table.c --- the human-readable default formatter.
 *
 * SCALAR    printed verbatim (newline-terminated)
 * LIST      kubectl-style aligned columns with an upper-case header
 * DOCUMENT  "key: value" lines for a top-level object; nested values
 *           rendered as compact JSON */

#include "ctl-formatter.h"

#include <string.h>

#define CTL_TYPE_TABLE_FORMATTER (ctl_table_formatter_get_type ())
G_DECLARE_FINAL_TYPE (CtlTableFormatter, ctl_table_formatter,
                      CTL, TABLE_FORMATTER, GObject)

struct _CtlTableFormatter
{
  GObject parent_instance;
};

static void ctl_table_formatter_formatter_init (CtlFormatterInterface *iface);

G_DEFINE_TYPE_WITH_CODE (CtlTableFormatter, ctl_table_formatter,
                         G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (CTL_TYPE_FORMATTER,
                           ctl_table_formatter_formatter_init))

/* Render a json member value as a one-line cell string. */
static gchar *
cell_for_node (JsonNode *node)
{
  if (node == NULL || json_node_is_null (node))
    return g_strdup ("");
  if (JSON_NODE_HOLDS_VALUE (node))
    {
      GType vt = json_node_get_value_type (node);
      if (vt == G_TYPE_STRING)
        return g_strdup (json_node_get_string (node));
      if (vt == G_TYPE_BOOLEAN)
        return g_strdup (json_node_get_boolean (node) ? "true" : "false");
      if (vt == G_TYPE_INT64)
        return g_strdup_printf ("%" G_GINT64_FORMAT,
                                json_node_get_int (node));
      return g_strdup_printf ("%g", json_node_get_double (node));
    }
  {
    JsonGenerator *gen = json_generator_new ();
    gchar *s;
    json_generator_set_root (gen, node);
    s = json_generator_to_data (gen, NULL);
    g_object_unref (gen);
    return s;
  }
}

static gboolean
emit_list (CtlResult *result, FILE *out)
{
  JsonArray *rows = ctl_result_get_rows (result);
  guint n_cols = ctl_result_get_n_columns (result);
  guint n_rows = rows != NULL ? json_array_get_length (rows) : 0;
  guint r, c;
  gsize *widths;
  gchar ***cells;

  if (n_cols == 0)
    {
      /* No column spec: print each element as a line. */
      for (r = 0; r < n_rows; r++)
        {
          gchar *s = cell_for_node (json_array_get_element (rows, r));
          fprintf (out, "%s\n", s);
          g_free (s);
        }
      return TRUE;
    }

  widths = g_new0 (gsize, n_cols);
  cells = g_new0 (gchar **, n_rows);

  for (c = 0; c < n_cols; c++)
    widths[c] = strlen (ctl_result_get_column_title (result, c));

  for (r = 0; r < n_rows; r++)
    {
      JsonNode *row = json_array_get_element (rows, r);
      JsonObject *obj =
        JSON_NODE_HOLDS_OBJECT (row) ? json_node_get_object (row) : NULL;
      cells[r] = g_new0 (gchar *, n_cols);
      for (c = 0; c < n_cols; c++)
        {
          const gchar *key = ctl_result_get_column_key (result, c);
          JsonNode *member =
            (obj != NULL && json_object_has_member (obj, key))
            ? json_object_get_member (obj, key) : NULL;
          cells[r][c] = cell_for_node (member);
          if (strlen (cells[r][c]) > widths[c])
            widths[c] = strlen (cells[r][c]);
        }
    }

  for (c = 0; c < n_cols; c++)
    {
      gchar *title = g_ascii_strup (
        ctl_result_get_column_title (result, c), -1);
      fprintf (out, "%-*s%s", (int) widths[c], title,
               c + 1 < n_cols ? "   " : "\n");
      g_free (title);
    }
  for (r = 0; r < n_rows; r++)
    {
      for (c = 0; c < n_cols; c++)
        fprintf (out, "%-*s%s", (int) widths[c], cells[r][c],
                 c + 1 < n_cols ? "   " : "\n");
      for (c = 0; c < n_cols; c++)
        g_free (cells[r][c]);
      g_free (cells[r]);
    }
  g_free (cells);
  g_free (widths);
  return TRUE;
}

static gboolean
emit_document (CtlResult *result, FILE *out)
{
  JsonNode *root = ctl_result_get_root (result);

  if (JSON_NODE_HOLDS_OBJECT (root))
    {
      JsonObject *obj = json_node_get_object (root);
      JsonObjectIter iter;
      const gchar *name;
      JsonNode *member;
      json_object_iter_init_ordered (&iter, obj);
      while (json_object_iter_next_ordered (&iter, &name, &member))
        {
          gchar *s = cell_for_node (member);
          fprintf (out, "%s: %s\n", name, s);
          g_free (s);
        }
      return TRUE;
    }
  {
    gchar *s = cell_for_node (root);
    fprintf (out, "%s\n", s);
    g_free (s);
  }
  return TRUE;
}

static gboolean
table_emit (CtlFormatter *self, CtlResult *result, FILE *out,
            GError **error)
{
  (void) self; (void) error;

  switch (ctl_result_get_kind (result))
    {
    case CTL_RESULT_SCALAR:
      {
        const gchar *s = ctl_result_get_scalar (result);
        fputs (s, out);
        if (s[0] == '\0' || s[strlen (s) - 1] != '\n')
          fputc ('\n', out);
        return TRUE;
      }
    case CTL_RESULT_LIST:
      return emit_list (result, out);
    case CTL_RESULT_DOCUMENT:
    default:
      return emit_document (result, out);
    }
}

static void
ctl_table_formatter_formatter_init (CtlFormatterInterface *iface)
{
  iface->emit = table_emit;
}

static void
ctl_table_formatter_class_init (CtlTableFormatterClass *klass)
{
  (void) klass;
}

static void
ctl_table_formatter_init (CtlTableFormatter *self)
{
  (void) self;
}
