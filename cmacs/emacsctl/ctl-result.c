/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-result.c --- see ctl-result.h. */

#include "ctl-result.h"

typedef struct
{
  gchar *title;
  gchar *key;
} CtlResultColumn;

struct _CtlResult
{
  gint refcount;
  CtlResultKind kind;
  gchar *scalar;
  JsonArray *rows;
  JsonNode *root;
  GArray *columns;            /* of CtlResultColumn */
};

G_DEFINE_BOXED_TYPE (CtlResult, ctl_result,
                     ctl_result_ref, ctl_result_unref)

static void
column_clear (gpointer data)
{
  CtlResultColumn *col = data;
  g_free (col->title);
  g_free (col->key);
}

static CtlResult *
result_alloc (CtlResultKind kind)
{
  CtlResult *self = g_slice_new0 (CtlResult);
  self->refcount = 1;
  self->kind = kind;
  self->columns = g_array_new (FALSE, TRUE, sizeof (CtlResultColumn));
  g_array_set_clear_func (self->columns, column_clear);
  return self;
}

CtlResult *
ctl_result_new_scalar (const gchar *text)
{
  CtlResult *self = result_alloc (CTL_RESULT_SCALAR);
  self->scalar = g_strdup (text != NULL ? text : "");
  return self;
}

CtlResult *
ctl_result_new_document (JsonNode *root)
{
  CtlResult *self = result_alloc (CTL_RESULT_DOCUMENT);
  self->root = root;
  return self;
}

CtlResult *
ctl_result_new_list (JsonArray *rows)
{
  CtlResult *self = result_alloc (CTL_RESULT_LIST);
  self->rows = rows;
  return self;
}

CtlResult *
ctl_result_ref (CtlResult *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  g_atomic_int_inc (&self->refcount);
  return self;
}

void
ctl_result_unref (CtlResult *self)
{
  if (self == NULL)
    return;
  if (!g_atomic_int_dec_and_test (&self->refcount))
    return;
  g_free (self->scalar);
  if (self->rows != NULL)
    json_array_unref (self->rows);
  if (self->root != NULL)
    json_node_unref (self->root);
  g_array_unref (self->columns);
  g_slice_free (CtlResult, self);
}

CtlResultKind
ctl_result_get_kind (CtlResult *self)
{
  return self->kind;
}

const gchar *
ctl_result_get_scalar (CtlResult *self)
{
  return self->scalar;
}

JsonArray *
ctl_result_get_rows (CtlResult *self)
{
  return self->rows;
}

JsonNode *
ctl_result_get_root (CtlResult *self)
{
  return self->root;
}

void
ctl_result_add_column (CtlResult *self, const gchar *title,
                       const gchar *key)
{
  CtlResultColumn col;
  col.title = g_strdup (title);
  col.key = g_strdup (key);
  g_array_append_val (self->columns, col);
}

guint
ctl_result_get_n_columns (CtlResult *self)
{
  return self->columns->len;
}

const gchar *
ctl_result_get_column_title (CtlResult *self, guint idx)
{
  return g_array_index (self->columns, CtlResultColumn, idx).title;
}

const gchar *
ctl_result_get_column_key (CtlResult *self, guint idx)
{
  return g_array_index (self->columns, CtlResultColumn, idx).key;
}

JsonNode *
ctl_result_to_json_node (CtlResult *self)
{
  JsonNode *node;

  switch (self->kind)
    {
    case CTL_RESULT_SCALAR:
      node = json_node_new (JSON_NODE_VALUE);
      json_node_set_string (node, self->scalar);
      return node;
    case CTL_RESULT_LIST:
      node = json_node_new (JSON_NODE_ARRAY);
      json_node_set_array (node, self->rows);
      return node;
    case CTL_RESULT_DOCUMENT:
    default:
      return json_node_copy (self->root);
    }
}
