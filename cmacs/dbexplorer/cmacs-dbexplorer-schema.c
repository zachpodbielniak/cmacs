/* cmacs-dbexplorer-schema.c --- database explorer model layer

Copyright (C) 2026 Zach Podbielniak

This file is part of CMacs.

CMacs is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

CMacs is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for
more details.

You should have received a copy of the GNU Affero General Public License
along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: AGPL-3.0-or-later  */

/* Model half: this file sees orm-glib and glib, and must never include
   lisp.h.  See cmacs/dbexplorer/cmacs-dbexplorer.h for why.

   One relation's details are four catalog reads -- columns, primary key,
   indexes, foreign keys -- and they are chained here into a single reply
   rather than exposed as four primitives.  The tree, the row editor and
   SQL completion all want the same four, and asking three times is three
   chances to be told something different each time by a schema that
   changed in between.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-dbexplorer.h"
#include "cmacs-glib-loop.h"

/* orm.h sets and clears the ORM_INSIDE guard itself, so it is the one
   orm-glib header a consumer includes. */
#include <orm.h>

#include <string.h>

static GMainContext *
dbx_push_context (void)
{
  GMainContext *context = cmacs_glib_get_context ();

  if (context != NULL)
    g_main_context_push_thread_default (context);
  return context;
}

static void
dbx_pop_context (GMainContext *context)
{
  if (context != NULL)
    g_main_context_pop_thread_default (context);
}

static const char *
dbx_error_message (GError *err, const char *fallback)
{
  return (err != NULL && err->message != NULL) ? err->message : fallback;
}

/* ------------------------------------------------------------------ */
/* Schemas                                                             */
/* ------------------------------------------------------------------ */

typedef struct
{
  CmacsDbxSchemasCb cb;
  guint64           token;
} CmacsDbxSchemasJob;

static void
dbx_on_schemas (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxSchemasJob *job = user_data;
  GError *err = NULL;
  g_auto(GStrv) schemas = NULL;

  schemas = orm_inspector_list_schemas_finish (ORM_INSPECTOR (source),
                                               result, &err);
  if (schemas == NULL)
    job->cb (job->token, NULL,
             dbx_error_message (err, "the schema list could not be read"));
  else
    job->cb (job->token, schemas, NULL);

  g_clear_error (&err);
  g_free (job);
}

void
cmacs_dbx_schemas_async (CmacsDbxConn *conn, CmacsDbxSchemasCb cb,
                         guint64 token)
{
  CmacsDbxSchemasJob *job;
  OrmInspector *inspector;
  g_autofree gchar *error = NULL;
  GMainContext *context;

  if (cb == NULL)
    return;

  inspector = cmacs_dbx_conn_inspector (conn, &error);
  if (inspector == NULL)
    {
      cb (token, NULL, error != NULL ? error : "the connection is closed");
      return;
    }

  job = g_new0 (CmacsDbxSchemasJob, 1);
  job->cb = cb;
  job->token = token;

  context = dbx_push_context ();
  orm_inspector_list_schemas_async (inspector,
                                    cmacs_dbx_conn_cancellable (conn),
                                    dbx_on_schemas, job);
  dbx_pop_context (context);
}

/* ------------------------------------------------------------------ */
/* Relations                                                           */
/* ------------------------------------------------------------------ */

typedef struct
{
  CmacsDbxTablesCb cb;
  guint64          token;
} CmacsDbxTablesJob;

static void
dbx_on_relations (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxTablesJob *job = user_data;
  GError *err = NULL;
  g_autoptr(GPtrArray) relations = NULL;
  CmacsDbxRelation *out;
  guint i;

  relations = orm_inspector_list_relations_finish (ORM_INSPECTOR (source),
                                                   result, &err);
  if (relations == NULL)
    {
      job->cb (job->token, NULL, 0,
               dbx_error_message (err, "the table list could not be read"));
      g_clear_error (&err);
      g_free (job);
      return;
    }
  g_clear_error (&err);

  out = g_new0 (CmacsDbxRelation, relations->len > 0 ? relations->len : 1);
  for (i = 0; i < relations->len; i++)
    {
      OrmTableInfo *info = g_ptr_array_index (relations, i);

      out[i].name = g_strdup (orm_table_info_get_name (info));
      out[i].is_view =
        orm_table_info_get_kind (info) == ORM_RELATION_VIEW ? 1 : 0;
    }

  job->cb (job->token, out, (int) relations->len, NULL);

  for (i = 0; i < relations->len; i++)
    g_free (out[i].name);
  g_free (out);
  g_free (job);
}

void
cmacs_dbx_tables_async (CmacsDbxConn *conn, const char *schema,
                        CmacsDbxTablesCb cb, guint64 token)
{
  CmacsDbxTablesJob *job;
  OrmInspector *inspector;
  g_autofree gchar *error = NULL;
  GMainContext *context;

  if (cb == NULL)
    return;

  inspector = cmacs_dbx_conn_inspector (conn, &error);
  if (inspector == NULL)
    {
      cb (token, NULL, 0,
          error != NULL ? error : "the connection is closed");
      return;
    }

  job = g_new0 (CmacsDbxTablesJob, 1);
  job->cb = cb;
  job->token = token;

  context = dbx_push_context ();
  orm_inspector_list_relations_async (inspector,
                                      (schema != NULL && *schema != '\0')
                                      ? schema : NULL,
                                      cmacs_dbx_conn_cancellable (conn),
                                      dbx_on_relations, job);
  dbx_pop_context (context);
}

/* ------------------------------------------------------------------ */
/* One relation, in full                                               */
/* ------------------------------------------------------------------ */

/* The four reads run in sequence, each starting the next from its own
   completion, because they share the connection's single worker anyway:
   issuing them together would only queue them behind each other with
   more state to unwind if one failed. */
enum
{
  DBX_INFO_COLUMNS,
  DBX_INFO_PRIMARY_KEY,
  DBX_INFO_INDEXES,
  DBX_INFO_FOREIGN_KEYS,
  DBX_INFO_DONE
};

typedef struct
{
  CmacsDbxConn        *conn;
  OrmInspector        *inspector;
  gchar               *schema;
  gchar               *table;
  int                  step;
  CmacsDbxTableInfo    info;
  CmacsDbxTableInfoCb  cb;
  guint64              token;
} CmacsDbxTableInfoJob;

static void dbx_table_info_step (CmacsDbxTableInfoJob *job);

static void
dbx_table_info_clear (CmacsDbxTableInfo *info)
{
  int i;

  for (i = 0; i < info->n_columns; i++)
    {
      g_free (info->columns[i].name);
      g_free (info->columns[i].type_name);
      g_free (info->columns[i].default_value);
    }
  g_free (info->columns);

  g_strfreev (info->primary_key);

  for (i = 0; i < info->n_indexes; i++)
    {
      g_free (info->indexes[i].name);
      g_strfreev (info->indexes[i].columns);
    }
  g_free (info->indexes);

  for (i = 0; i < info->n_foreign_keys; i++)
    {
      g_free (info->foreign_keys[i].name);
      g_free (info->foreign_keys[i].ref_table);
      g_free (info->foreign_keys[i].ref_schema);
      g_strfreev (info->foreign_keys[i].columns);
      g_strfreev (info->foreign_keys[i].ref_columns);
    }
  g_free (info->foreign_keys);

  memset (info, 0, sizeof *info);
}

static void
dbx_table_info_job_free (CmacsDbxTableInfoJob *job)
{
  dbx_table_info_clear (&job->info);
  g_clear_object (&job->inspector);
  g_free (job->schema);
  g_free (job->table);
  g_free (job);
}

static void
dbx_table_info_fail (CmacsDbxTableInfoJob *job, const char *message)
{
  job->cb (job->token, NULL, message);
  dbx_table_info_job_free (job);
}

/* An empty list rather than NULL, so a caller never has to distinguish
   "no columns" from "nothing was set". */
static gchar **
dbx_strv_copy (const gchar *const *strv)
{
  if (strv == NULL)
    return g_new0 (gchar *, 1);
  return g_strdupv ((gchar **) (gpointer) strv);
}

static void
dbx_on_columns (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxTableInfoJob *job = user_data;
  GError *err = NULL;
  g_autoptr(GPtrArray) columns = NULL;
  guint i;

  columns = orm_inspector_get_columns_finish (ORM_INSPECTOR (source),
                                              result, &err);
  if (columns == NULL)
    {
      g_autofree gchar *message =
        g_strdup (dbx_error_message (err, "the columns could not be read"));

      g_clear_error (&err);
      dbx_table_info_fail (job, message);
      return;
    }
  g_clear_error (&err);

  job->info.n_columns = (int) columns->len;
  job->info.columns =
    g_new0 (CmacsDbxColumnInfo, columns->len > 0 ? columns->len : 1);
  for (i = 0; i < columns->len; i++)
    {
      OrmColumnInfo *info = g_ptr_array_index (columns, i);

      job->info.columns[i].name = g_strdup (orm_column_info_get_name (info));
      job->info.columns[i].type_name =
        g_strdup (orm_column_info_get_type_name (info));
      job->info.columns[i].value_type =
        (int) orm_column_info_get_value_type (info);
      job->info.columns[i].nullable =
        orm_column_info_get_nullable (info) ? 1 : 0;
      job->info.columns[i].default_value =
        g_strdup (orm_column_info_get_default_value (info));
      job->info.columns[i].primary_key =
        orm_column_info_get_primary_key (info) ? 1 : 0;
      job->info.columns[i].ordinal = orm_column_info_get_ordinal (info);
    }

  job->step = DBX_INFO_PRIMARY_KEY;
  dbx_table_info_step (job);
}

static void
dbx_on_primary_key (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxTableInfoJob *job = user_data;
  GError *err = NULL;
  gchar **key;

  key = orm_inspector_get_primary_key_finish (ORM_INSPECTOR (source),
                                              result, &err);
  if (key == NULL)
    {
      g_autofree gchar *message =
        g_strdup (dbx_error_message (err,
                                     "the primary key could not be read"));

      g_clear_error (&err);
      dbx_table_info_fail (job, message);
      return;
    }
  g_clear_error (&err);

  job->info.primary_key = key;
  job->step = DBX_INFO_INDEXES;
  dbx_table_info_step (job);
}

static void
dbx_on_indexes (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxTableInfoJob *job = user_data;
  GError *err = NULL;
  g_autoptr(GPtrArray) indexes = NULL;
  guint i;

  indexes = orm_inspector_get_indexes_finish (ORM_INSPECTOR (source),
                                              result, &err);
  if (indexes == NULL)
    {
      g_autofree gchar *message =
        g_strdup (dbx_error_message (err, "the indexes could not be read"));

      g_clear_error (&err);
      dbx_table_info_fail (job, message);
      return;
    }
  g_clear_error (&err);

  job->info.n_indexes = (int) indexes->len;
  job->info.indexes =
    g_new0 (CmacsDbxIndexInfo, indexes->len > 0 ? indexes->len : 1);
  for (i = 0; i < indexes->len; i++)
    {
      OrmIndexInfo *info = g_ptr_array_index (indexes, i);

      job->info.indexes[i].name = g_strdup (orm_index_info_get_name (info));
      job->info.indexes[i].unique =
        orm_index_info_get_unique (info) ? 1 : 0;
      job->info.indexes[i].columns =
        dbx_strv_copy (orm_index_info_get_columns (info));
    }

  job->step = DBX_INFO_FOREIGN_KEYS;
  dbx_table_info_step (job);
}

static void
dbx_on_foreign_keys (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxTableInfoJob *job = user_data;
  GError *err = NULL;
  g_autoptr(GPtrArray) keys = NULL;
  guint i;

  keys = orm_inspector_get_foreign_keys_finish (ORM_INSPECTOR (source),
                                                result, &err);
  if (keys == NULL)
    {
      g_autofree gchar *message =
        g_strdup (dbx_error_message (err,
                                     "the foreign keys could not be read"));

      g_clear_error (&err);
      dbx_table_info_fail (job, message);
      return;
    }
  g_clear_error (&err);

  job->info.n_foreign_keys = (int) keys->len;
  job->info.foreign_keys =
    g_new0 (CmacsDbxForeignKeyInfo, keys->len > 0 ? keys->len : 1);
  for (i = 0; i < keys->len; i++)
    {
      OrmForeignKeyInfo *info = g_ptr_array_index (keys, i);

      job->info.foreign_keys[i].name =
        g_strdup (orm_foreign_key_info_get_name (info));
      job->info.foreign_keys[i].columns =
        dbx_strv_copy (orm_foreign_key_info_get_columns (info));
      job->info.foreign_keys[i].ref_table =
        g_strdup (orm_foreign_key_info_get_ref_table (info));
      job->info.foreign_keys[i].ref_schema =
        g_strdup (orm_foreign_key_info_get_ref_schema (info));
      job->info.foreign_keys[i].ref_columns =
        dbx_strv_copy (orm_foreign_key_info_get_ref_columns (info));
    }

  job->step = DBX_INFO_DONE;
  dbx_table_info_step (job);
}

static void
dbx_table_info_step (CmacsDbxTableInfoJob *job)
{
  GMainContext *context;
  const gchar *schema = (job->schema != NULL && *job->schema != '\0')
    ? job->schema : NULL;
  GCancellable *cancellable = cmacs_dbx_conn_cancellable (job->conn);

  if (job->step == DBX_INFO_DONE)
    {
      job->cb (job->token, &job->info, NULL);
      dbx_table_info_job_free (job);
      return;
    }

  context = dbx_push_context ();
  switch (job->step)
    {
    case DBX_INFO_COLUMNS:
      orm_inspector_get_columns_async (job->inspector, job->table, schema,
                                       cancellable, dbx_on_columns, job);
      break;
    case DBX_INFO_PRIMARY_KEY:
      orm_inspector_get_primary_key_async (job->inspector, job->table, schema,
                                           cancellable, dbx_on_primary_key,
                                           job);
      break;
    case DBX_INFO_INDEXES:
      orm_inspector_get_indexes_async (job->inspector, job->table, schema,
                                       cancellable, dbx_on_indexes, job);
      break;
    case DBX_INFO_FOREIGN_KEYS:
    default:
      orm_inspector_get_foreign_keys_async (job->inspector, job->table, schema,
                                            cancellable, dbx_on_foreign_keys,
                                            job);
      break;
    }
  dbx_pop_context (context);
}

void
cmacs_dbx_table_info_async (CmacsDbxConn *conn, const char *schema,
                            const char *table, CmacsDbxTableInfoCb cb,
                            guint64 token)
{
  CmacsDbxTableInfoJob *job;
  OrmInspector *inspector;
  g_autofree gchar *error = NULL;

  if (cb == NULL)
    return;

  if (table == NULL || *table == '\0')
    {
      cb (token, NULL, "no table named");
      return;
    }

  inspector = cmacs_dbx_conn_inspector (conn, &error);
  if (inspector == NULL)
    {
      cb (token, NULL, error != NULL ? error : "the connection is closed");
      return;
    }

  job = g_new0 (CmacsDbxTableInfoJob, 1);
  job->conn = conn;
  /* Its own reference: this job outlives four separate calls, and the
     connection's reference goes away the moment it is closed -- which
     can happen between any two of them. */
  job->inspector = g_object_ref (inspector);
  job->schema = g_strdup (schema);
  job->table = g_strdup (table);
  job->step = DBX_INFO_COLUMNS;
  job->cb = cb;
  job->token = token;

  dbx_table_info_step (job);
}

#endif /* HAVE_CMACS_DBEXPLORER */
