/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-result.h --- CtlResult, the uniform data model every command
 * produces and every formatter consumes.
 *
 * A boxed, reference-counted value of one of three kinds:
 *
 *   SCALAR    raw text (e.g. an Eval result, shell output)
 *   LIST      rows (JsonArray of objects) + an ordered column list
 *   DOCUMENT  an arbitrary JSON tree
 *
 * The canonical backing store is json-glib nodes, so JSON output is
 * free and YAML/table derive from the same data. */

#ifndef CTL_RESULT_H
#define CTL_RESULT_H

#include <glib-object.h>
#include <json-glib/json-glib.h>

G_BEGIN_DECLS

typedef enum
{
  CTL_RESULT_SCALAR,
  CTL_RESULT_LIST,
  CTL_RESULT_DOCUMENT
} CtlResultKind;

typedef struct _CtlResult CtlResult;

#define CTL_TYPE_RESULT (ctl_result_get_type ())
GType ctl_result_get_type (void) G_GNUC_CONST;

CtlResult *ctl_result_new_scalar   (const gchar *text);
/* Takes ownership of ROOT. */
CtlResult *ctl_result_new_document (JsonNode *root);
/* Takes ownership of ROWS (array of objects). */
CtlResult *ctl_result_new_list     (JsonArray *rows);

CtlResult *ctl_result_ref   (CtlResult *self);
void       ctl_result_unref (CtlResult *self);

CtlResultKind ctl_result_get_kind   (CtlResult *self);
const gchar  *ctl_result_get_scalar (CtlResult *self);
JsonArray    *ctl_result_get_rows   (CtlResult *self);
JsonNode     *ctl_result_get_root   (CtlResult *self);

/* Columns (LIST kind): TITLE is the table header, KEY the member name
 * looked up in each row object.  Order of calls = column order. */
void   ctl_result_add_column     (CtlResult *self,
                                  const gchar *title, const gchar *key);
guint  ctl_result_get_n_columns  (CtlResult *self);
const gchar *ctl_result_get_column_title (CtlResult *self, guint idx);
const gchar *ctl_result_get_column_key   (CtlResult *self, guint idx);

/* Canonical JSON representation of any kind (scalar -> JSON string,
 * list -> array, document -> root).  Caller owns the returned node. */
JsonNode *ctl_result_to_json_node (CtlResult *self);

G_END_DECLS

#endif /* CTL_RESULT_H */
