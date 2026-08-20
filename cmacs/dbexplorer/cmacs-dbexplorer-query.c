/* cmacs-dbexplorer-query.c --- database explorer model layer

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

   Nothing here starts a thread.  orm-glib already owns one worker per
   connection and runs everything queued on it in order, so a second
   layer of threading would buy no parallelism the backend can use and
   would cost the ordering that makes a transaction mean anything.  What
   this file does instead is chain _async calls, which is also why a
   batch of edits reads as a state machine rather than a loop.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-dbexplorer.h"
#include "cmacs-glib-loop.h"

/* orm.h sets and clears the ORM_INSIDE guard itself, so it is the one
   orm-glib header a consumer includes. */
#include <orm.h>

#include <string.h>

/* Rows per fetch.  Big enough that a wide browse is a handful of round
   trips, small enough that the first screenful appears before the last
   row has been read. */
#define DBX_BATCH_ROWS 256

/* The savepoint a batch of edits wraps itself in when the user already
   has a transaction open.  Named rather than generated because it is
   released on both paths and a name is easier to recognise in a log. */
#define DBX_APPLY_SAVEPOINT "cmacs_dbexplorer_apply"

/* ------------------------------------------------------------------ */
/* Running async work on cmacs's own GMainContext                      */
/* ------------------------------------------------------------------ */

/* Every GTask orm-glib creates completes on whichever context was
   thread-default when it was created.  cmacs's context is private and
   driven from Emacs's pselect; the global default is driven only under
   pgtk, and not at all in a batch Emacs.  So each _async call is issued
   with cmacs's context pushed, and the completion lands somewhere that
   is actually iterated.  */
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

/* ------------------------------------------------------------------ */
/* Parameters                                                          */
/* ------------------------------------------------------------------ */

static OrmValue *
dbx_param_to_value (const CmacsDbxParam *param)
{
  switch (param->type)
    {
    case CMACS_DBX_PARAM_STRING:
      return orm_value_new_string (param->text != NULL ? param->text : "");
    case CMACS_DBX_PARAM_INTEGER:
      return orm_value_new_integer ((gint64) param->integer);
    case CMACS_DBX_PARAM_FLOAT:
      return orm_value_new_float (param->real);
    case CMACS_DBX_PARAM_NULL:
    default:
      return orm_value_new_null ();
    }
}

static GList *
dbx_params_to_list (const CmacsDbxParam *params, int n_params)
{
  GList *list = NULL;
  int i;

  for (i = 0; i < n_params; i++)
    list = g_list_prepend (list, dbx_param_to_value (&params[i]));
  return g_list_reverse (list);
}

static void
dbx_params_list_free (GList *list)
{
  g_list_free_full (list, (GDestroyNotify) orm_value_free);
}

/* ------------------------------------------------------------------ */
/* Cells                                                               */
/* ------------------------------------------------------------------ */

/* Render one value for a grid cell.

   Blobs never come back as text: BLOB_SIZE is set instead and the cell
   is NULL, so the view can say how big the value is rather than pasting
   a JPEG into a column.  A SQL NULL is also a NULL cell, told apart by
   BLOB_SIZE staying negative.  */
static gchar *
dbx_value_to_cell (const OrmValue *value, long long *blob_size)
{
  *blob_size = -1;

  if (value == NULL || orm_value_is_null (value))
    return NULL;

  switch (orm_value_get_value_type (value))
    {
    case ORM_VALUE_BLOB:
      {
        GBytes *bytes = orm_value_get_blob (value);

        *blob_size = bytes != NULL ? (long long) g_bytes_get_size (bytes) : 0;
        return NULL;
      }

    case ORM_VALUE_STRING:
      return g_strdup (orm_value_get_string (value));

    default:
      /* orm_value_to_string is the library's own rendering, so an
         integer, a float and a timestamp read the same here as they do
         everywhere else in orm-glib. */
      return orm_value_to_string (value);
    }
}

/* ------------------------------------------------------------------ */
/* Streams                                                             */
/* ------------------------------------------------------------------ */

typedef struct
{
  long long        id;
  CmacsDbxConn    *conn;
  OrmRowStream    *stream;
  GCancellable    *cancellable;
  gint64           started_us;
  long long        max_rows;
  long long        row_count;
  gboolean         truncated;
  gboolean         cancelled;
  int              n_columns;
  CmacsDbxColumn  *columns;

  /* Export only.  An export drains the rows into memory and hands them
     to orm-glib's exporter once, rather than writing per batch: the
     exporter emits a format's prologue and epilogue around whatever it
     is given, so calling it per batch would produce a CSV header, or a
     closing JSON bracket, every 256 rows. */
  gboolean         exporting;
  gchar           *path;
  gchar           *format;
  GPtrArray       *rows;
} CmacsDbxStream;

static GHashTable *dbx_streams;         /* long long id -> CmacsDbxStream * */
static long long   dbx_next_stream_id = 1;

static void dbx_stream_fetch (CmacsDbxStream *s);
static void dbx_stream_finish (CmacsDbxStream *s);
static void dbx_stream_fail (CmacsDbxStream *s, const char *message);

static void
dbx_stream_columns_free (CmacsDbxStream *s)
{
  int i;

  if (s->columns == NULL)
    return;
  for (i = 0; i < s->n_columns; i++)
    {
      g_free (s->columns[i].name);
      g_free (s->columns[i].type_name);
    }
  g_free (s->columns);
  s->columns = NULL;
}

static void
dbx_stream_free (CmacsDbxStream *s)
{
  if (s == NULL)
    return;
  dbx_stream_columns_free (s);
  g_clear_object (&s->stream);
  g_clear_object (&s->cancellable);
  g_clear_pointer (&s->rows, g_ptr_array_unref);
  g_free (s->path);
  g_free (s->format);
  g_free (s);
}

static void
dbx_stream_forget (CmacsDbxStream *s)
{
  gint64 key = (gint64) s->id;

  if (dbx_streams != NULL)
    g_hash_table_remove (dbx_streams, &key);
}

static void
dbx_on_stream_closed (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxStream *s = user_data;
  GError *err = NULL;

  /* Nothing to report: the rows were already delivered, or the failure
     was, and a cursor that would not release is not the caller's
     problem.  Consuming the error keeps it out of the GLib log. */
  orm_row_stream_close_finish (ORM_ROW_STREAM (source), result, &err);
  g_clear_error (&err);
  dbx_stream_free (s);
}

/* End a stream: release the backend cursor and free the state once the
   release lands.  Exactly one asynchronous operation is outstanding on a
   stream at all times, which is what makes it safe to free it only in a
   completion callback -- a cancel can then mark it and walk away rather
   than racing the fetch it just interrupted. */
static void
dbx_stream_release (CmacsDbxStream *s)
{
  GMainContext *context;

  dbx_stream_forget (s);

  if (s->stream == NULL)
    {
      dbx_stream_free (s);
      return;
    }

  context = dbx_push_context ();
  orm_row_stream_close_async (s->stream, NULL, dbx_on_stream_closed, s);
  dbx_pop_context (context);
}

static void
dbx_stream_fail (CmacsDbxStream *s, const char *message)
{
  const CmacsDbxStreamSink *sink = cmacs_dbx_stream_sink ();

  if (!s->cancelled && sink != NULL && sink->error != NULL)
    sink->error (s->id, message != NULL ? message : "the query failed");
  dbx_stream_release (s);
}

/* ------------------------------------------------------------------ */
/* Export                                                              */
/* ------------------------------------------------------------------ */

static OrmExporter *
dbx_exporter_for (const char *format, char **error)
{
  if (format != NULL && g_ascii_strcasecmp (format, "csv") == 0)
    return ORM_EXPORTER (orm_csv_exporter_new ());
  if (format != NULL && g_ascii_strcasecmp (format, "json") == 0)
    return ORM_EXPORTER (orm_json_exporter_new ());

  if (error != NULL)
    *error = g_strdup_printf ("unknown export format \"%s\"; use csv or json",
                              format != NULL ? format : "");
  return NULL;
}

static gboolean
dbx_stream_write_export (CmacsDbxStream *s, char **error)
{
  g_autoptr(OrmExporter) exporter = NULL;
  g_autoptr(GFile) file = NULL;
  g_autoptr(GFileOutputStream) out = NULL;
  GError *err = NULL;

  exporter = dbx_exporter_for (s->format, error);
  if (exporter == NULL)
    return FALSE;

  file = g_file_new_for_path (s->path);
  out = g_file_replace (file, NULL, FALSE, G_FILE_CREATE_NONE, NULL, &err);
  if (out == NULL)
    {
      if (error != NULL)
        *error = g_strdup (err && err->message ? err->message
                           : "cannot write the export file");
      g_clear_error (&err);
      return FALSE;
    }

  if (!orm_exporter_export_rows (exporter, s->rows, G_OUTPUT_STREAM (out),
                                 NULL, &err))
    {
      if (error != NULL)
        *error = g_strdup (err && err->message ? err->message
                           : "the export failed");
      g_clear_error (&err);
      return FALSE;
    }

  if (!g_output_stream_close (G_OUTPUT_STREAM (out), NULL, &err))
    {
      if (error != NULL)
        *error = g_strdup (err && err->message ? err->message
                           : "the export file would not close");
      g_clear_error (&err);
      return FALSE;
    }

  return TRUE;
}

/* ------------------------------------------------------------------ */
/* Draining a stream                                                   */
/* ------------------------------------------------------------------ */

static void
dbx_stream_finish (CmacsDbxStream *s)
{
  const CmacsDbxStreamSink *sink = cmacs_dbx_stream_sink ();
  double elapsed_ms =
    (double) (g_get_monotonic_time () - s->started_us) / 1000.0;

  if (s->cancelled)
    {
      dbx_stream_release (s);
      return;
    }

  if (s->exporting)
    {
      g_autofree gchar *error = NULL;

      if (!dbx_stream_write_export (s, &error))
        {
          dbx_stream_fail (s, error);
          return;
        }
    }

  if (sink != NULL && sink->end != NULL)
    sink->end (s->id, s->row_count, s->truncated ? 1 : 0, elapsed_ms);
  dbx_stream_release (s);
}

/* Turn one fetched batch into the page the sink publishes. */
static CmacsDbxPage *
dbx_page_from_rows (CmacsDbxStream *s, GPtrArray *rows)
{
  CmacsDbxPage *page = g_new0 (CmacsDbxPage, 1);
  guint r;
  int c;

  page->n_columns = s->n_columns;
  page->n_rows = (int) rows->len;
  page->cells = g_new0 (char **, rows->len > 0 ? rows->len : 1);
  page->blob_sizes =
    g_new0 (long long, (gsize) page->n_rows * (gsize) (page->n_columns > 0
                                                       ? page->n_columns : 1)
            + 1);

  for (r = 0; r < rows->len; r++)
    {
      OrmRow *row = g_ptr_array_index (rows, r);

      page->cells[r] = g_new0 (char *, s->n_columns > 0 ? s->n_columns : 1);
      for (c = 0; c < s->n_columns; c++)
        {
          long long blob_size = -1;

          page->cells[r][c] = dbx_value_to_cell (orm_row_get_value (row, c),
                                                 &blob_size);
          page->blob_sizes[(gsize) r * (gsize) s->n_columns + (gsize) c] =
            blob_size;
        }
    }

  return page;
}

static void
dbx_on_fetched (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxStream *s = user_data;
  const CmacsDbxStreamSink *sink = cmacs_dbx_stream_sink ();
  GError *err = NULL;
  g_autoptr(GPtrArray) rows = NULL;
  guint asked;

  rows = orm_row_stream_fetch_finish (ORM_ROW_STREAM (source), result, &err);

  if (s->cancelled)
    {
      g_clear_error (&err);
      dbx_stream_release (s);
      return;
    }

  /* NULL is a failure and an empty array is the end of the rows; the
     library is explicit that conflating them is how a broken query
     renders as an empty table. */
  if (rows == NULL)
    {
      g_autofree gchar *message =
        g_strdup (err && err->message ? err->message : "the query failed");

      g_clear_error (&err);
      dbx_stream_fail (s, message);
      return;
    }
  g_clear_error (&err);

  asked = (guint) DBX_BATCH_ROWS;
  if (s->max_rows > 0)
    {
      long long remaining = s->max_rows - s->row_count;

      if (remaining < (long long) asked)
        asked = (guint) (remaining > 0 ? remaining : 0);
    }

  if (rows->len > 0)
    {
      s->row_count += (long long) rows->len;

      if (s->exporting)
        {
          guint i;

          for (i = 0; i < rows->len; i++)
            g_ptr_array_add (s->rows,
                             g_object_ref (g_ptr_array_index (rows, i)));
          if (sink != NULL && sink->progress != NULL)
            sink->progress (s->id, s->row_count);
        }
      else if (sink != NULL && sink->rows != NULL)
        {
          CmacsDbxPage *page = dbx_page_from_rows (s, rows);

          sink->rows (s->id, page);
          cmacs_dbx_page_free (page);
        }
    }

  /* Short of what was asked for means the rows are exhausted; the cap
     being reached means they may not be, and saying so is what lets a
     view offer the next page. */
  if (rows->len < asked)
    {
      dbx_stream_finish (s);
      return;
    }

  if (s->max_rows > 0 && s->row_count >= s->max_rows)
    {
      s->truncated = !orm_row_stream_is_at_end (s->stream);
      dbx_stream_finish (s);
      return;
    }

  dbx_stream_fetch (s);
}

static void
dbx_stream_fetch (CmacsDbxStream *s)
{
  GMainContext *context;
  guint want = (guint) DBX_BATCH_ROWS;

  if (s->max_rows > 0)
    {
      long long remaining = s->max_rows - s->row_count;

      if (remaining <= 0)
        {
          s->truncated = !orm_row_stream_is_at_end (s->stream);
          dbx_stream_finish (s);
          return;
        }
      if (remaining < (long long) want)
        want = (guint) remaining;
    }

  context = dbx_push_context ();
  orm_row_stream_fetch_async (s->stream, want, s->cancellable,
                              dbx_on_fetched, s);
  dbx_pop_context (context);
}

static void
dbx_on_stream_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxStream *s = user_data;
  const CmacsDbxStreamSink *sink = cmacs_dbx_stream_sink ();
  GError *err = NULL;
  OrmRowStream *stream;
  int i;

  stream = orm_connection_query_stream_finish (ORM_CONNECTION (source),
                                               result, &err);
  if (stream == NULL)
    {
      if (!s->cancelled && sink != NULL && sink->error != NULL)
        sink->error (s->id, err && err->message ? err->message
                     : "the query failed");
      g_clear_error (&err);
      dbx_stream_forget (s);
      dbx_stream_free (s);
      return;
    }
  g_clear_error (&err);

  s->stream = stream;

  if (s->cancelled)
    {
      dbx_stream_release (s);
      return;
    }

  /* Column metadata is captured when the stream is created, so it can be
     published before a single row has been read -- which is what lets a
     grid draw its header while the rows are still arriving. */
  s->n_columns = orm_row_stream_get_column_count (stream);
  s->columns = g_new0 (CmacsDbxColumn, s->n_columns > 0 ? s->n_columns : 1);
  for (i = 0; i < s->n_columns; i++)
    {
      s->columns[i].name =
        g_strdup (orm_row_stream_get_column_name (stream, i));
      s->columns[i].type_name =
        g_strdup (orm_row_stream_get_column_type_name (stream, i));
      s->columns[i].value_type =
        (int) orm_row_stream_get_column_type (stream, i);
      /* The backend does not report nullability on a result set, only on
         a table definition, so a result column is described as nullable
         and the schema reader is where a NOT NULL is learned. */
      s->columns[i].nullable = 1;
    }

  if (!s->exporting && sink != NULL && sink->meta != NULL)
    sink->meta (s->id, s->n_columns, s->columns);

  dbx_stream_fetch (s);
}

/* A start-time refusal still gets an id, and its message is delivered as
   that stream's error event on a later turn of the main loop.

   That is not ceremony.  The caller registers its handler for a stream
   after the call that creates it returns, because it needs the id to
   register under; a failure reported synchronously would therefore be
   published before anyone was listening and would vanish.  Deferring it
   makes a refused query look exactly like one the database rejected,
   which is the only shape callers have to handle.  */
typedef struct
{
  long long  id;
  gchar     *message;
} CmacsDbxDeferredError;

static gboolean
dbx_deferred_error (gpointer data)
{
  CmacsDbxDeferredError *deferred = data;
  const CmacsDbxStreamSink *sink = cmacs_dbx_stream_sink ();

  if (sink != NULL && sink->error != NULL)
    sink->error (deferred->id, deferred->message);
  return G_SOURCE_REMOVE;
}

static void
dbx_deferred_error_free (gpointer data)
{
  CmacsDbxDeferredError *deferred = data;

  g_free (deferred->message);
  g_free (deferred);
}

static long long
dbx_stream_refuse (const char *message)
{
  CmacsDbxDeferredError *deferred = g_new0 (CmacsDbxDeferredError, 1);
  GSource *source = g_idle_source_new ();

  deferred->id = dbx_next_stream_id++;
  deferred->message = g_strdup (message);

  g_source_set_callback (source, dbx_deferred_error, deferred,
                         dbx_deferred_error_free);
  g_source_attach (source, cmacs_glib_get_context ());
  g_source_unref (source);

  return deferred->id;
}

static CmacsDbxStream *
dbx_stream_start (CmacsDbxConn *conn, const char *sql,
                  const CmacsDbxParam *params, int n_params,
                  long long max_rows)
{
  CmacsDbxStream *s;
  OrmConnection *connection = cmacs_dbx_conn_orm (conn);
  GList *values;
  GMainContext *context;
  gint64 *key;

  s = g_new0 (CmacsDbxStream, 1);
  s->id = dbx_next_stream_id++;
  s->conn = conn;
  s->cancellable = g_cancellable_new ();
  s->started_us = g_get_monotonic_time ();
  s->max_rows = max_rows;

  if (dbx_streams == NULL)
    dbx_streams = g_hash_table_new_full (g_int64_hash, g_int64_equal,
                                         g_free, NULL);
  key = g_new (gint64, 1);
  *key = (gint64) s->id;
  g_hash_table_insert (dbx_streams, key, s);

  values = dbx_params_to_list (params, n_params);
  context = dbx_push_context ();
  orm_connection_query_stream_async (connection, sql, values, s->cancellable,
                                     dbx_on_stream_ready, s);
  dbx_pop_context (context);
  dbx_params_list_free (values);

  return s;
}

long long
cmacs_dbx_query_async (CmacsDbxConn *conn, const char *sql,
                       const CmacsDbxParam *params, int n_params,
                       long long max_rows)
{
  if (cmacs_dbx_conn_orm (conn) == NULL)
    return dbx_stream_refuse ("the connection is closed");

  if (cmacs_dbx_conn_read_only (conn) && !cmacs_dbx_sql_is_read_only (sql))
    return dbx_stream_refuse ("this connection is read-only,"
                              " and that statement writes");

  return dbx_stream_start (conn, sql, params, n_params, max_rows)->id;
}

long long
cmacs_dbx_export_async (CmacsDbxConn *conn, const char *sql,
                        const char *format, const char *path,
                        long long max_rows)
{
  CmacsDbxStream *s;
  g_autofree gchar *format_error = NULL;
  g_autoptr(OrmExporter) probe = NULL;

  if (path == NULL || *path == '\0')
    return dbx_stream_refuse ("no path to export to");

  /* Reject an unknown format before running the query rather than after
     draining it: the alternative is reading a million rows and then
     saying the format was a typo. */
  probe = dbx_exporter_for (format, &format_error);
  if (probe == NULL)
    return dbx_stream_refuse (format_error);

  if (cmacs_dbx_conn_orm (conn) == NULL)
    return dbx_stream_refuse ("the connection is closed");

  if (cmacs_dbx_conn_read_only (conn) && !cmacs_dbx_sql_is_read_only (sql))
    return dbx_stream_refuse ("this connection is read-only,"
                              " and that statement writes");

  s = dbx_stream_start (conn, sql, NULL, 0, max_rows);
  s->exporting = TRUE;
  s->path = g_strdup (path);
  s->format = g_strdup (format);
  s->rows = g_ptr_array_new_with_free_func (g_object_unref);
  return s->id;
}

void
cmacs_dbx_cancel (long long stream_id)
{
  CmacsDbxStream *s;
  gint64 key = (gint64) stream_id;

  if (dbx_streams == NULL)
    return;

  s = g_hash_table_lookup (dbx_streams, &key);
  if (s == NULL)
    return;

  /* Marked and dropped from the table, not freed: an operation is always
     outstanding on a live stream, and its completion callback is what
     frees the state.  Freeing here would hand that callback a dangling
     pointer. */
  s->cancelled = TRUE;
  g_hash_table_remove (dbx_streams, &key);
  g_cancellable_cancel (s->cancellable);
}

void
cmacs_dbx_cancel_streams_for (CmacsDbxConn *conn)
{
  GHashTableIter iter;
  gpointer value;
  GSList *doomed = NULL;
  GSList *l;

  if (dbx_streams == NULL)
    return;

  g_hash_table_iter_init (&iter, dbx_streams);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      CmacsDbxStream *s = value;

      if (s->conn == conn)
        doomed = g_slist_prepend (doomed, s);
    }

  for (l = doomed; l != NULL; l = l->next)
    cmacs_dbx_cancel (((CmacsDbxStream *) l->data)->id);
  g_slist_free (doomed);
}

/* ------------------------------------------------------------------ */
/* One-shot statements                                                 */
/* ------------------------------------------------------------------ */

typedef struct
{
  CmacsDbxConn      *conn;
  CmacsDbxExecuteCb  execute_cb;
  CmacsDbxDoneCb     done_cb;
  guint64            token;
  int                tx_depth_on_success;   /* -1 to leave it alone */
} CmacsDbxStatementJob;

static void
dbx_on_executed (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxStatementJob *job = user_data;
  OrmConnection *connection = ORM_CONNECTION (source);
  GError *err = NULL;

  if (!orm_connection_execute_finish (connection, result, &err))
    {
      const char *message = err && err->message ? err->message
        : "the statement failed";

      if (job->execute_cb != NULL)
        job->execute_cb (job->token, 0, 0, message);
      else if (job->done_cb != NULL)
        job->done_cb (job->token, message);
      g_clear_error (&err);
      g_free (job);
      return;
    }
  g_clear_error (&err);

  if (job->tx_depth_on_success >= 0)
    cmacs_dbx_conn_set_tx_depth (job->conn, job->tx_depth_on_success);

  if (job->execute_cb != NULL)
    job->execute_cb (job->token,
                     (long long) orm_connection_get_changes (connection),
                     (long long) orm_connection_get_last_insert_rowid (connection),
                     NULL);
  else if (job->done_cb != NULL)
    job->done_cb (job->token, NULL);

  g_free (job);
}

/* Issue SQL and report through whichever of the two callbacks the caller
   supplied.  TX_DEPTH_ON_SUCCESS is the transaction depth to record when
   the statement lands, or -1 to leave it as it was. */
static void
dbx_statement_async (CmacsDbxConn *conn, const char *sql,
                     const CmacsDbxParam *params, int n_params,
                     CmacsDbxExecuteCb execute_cb, CmacsDbxDoneCb done_cb,
                     guint64 token, int tx_depth_on_success)
{
  OrmConnection *connection = cmacs_dbx_conn_orm (conn);
  CmacsDbxStatementJob *job;
  GList *values;
  GMainContext *context;

  if (connection == NULL)
    {
      if (execute_cb != NULL)
        execute_cb (token, 0, 0, "the connection is closed");
      else if (done_cb != NULL)
        done_cb (token, "the connection is closed");
      return;
    }

  job = g_new0 (CmacsDbxStatementJob, 1);
  job->conn = conn;
  job->execute_cb = execute_cb;
  job->done_cb = done_cb;
  job->token = token;
  job->tx_depth_on_success = tx_depth_on_success;

  values = dbx_params_to_list (params, n_params);
  context = dbx_push_context ();
  orm_connection_execute_async (connection, sql, values,
                                cmacs_dbx_conn_cancellable (conn),
                                dbx_on_executed, job);
  dbx_pop_context (context);
  dbx_params_list_free (values);
}

void
cmacs_dbx_execute_async (CmacsDbxConn *conn, const char *sql,
                         const CmacsDbxParam *params, int n_params,
                         CmacsDbxExecuteCb cb, guint64 token)
{
  if (cb == NULL)
    return;

  /* The same classifier guards this path as guards the query path.  A
     read-only connection that refused SELECTs but ran DELETEs because
     the caller reached for the other primitive would be worse than no
     guard, since it would look like one. */
  if (cmacs_dbx_conn_read_only (conn) && !cmacs_dbx_sql_is_read_only (sql))
    {
      cb (token, 0, 0,
          "this connection is read-only, and that statement writes");
      return;
    }

  dbx_statement_async (conn, sql, params, n_params, cb, NULL, token, -1);
}

/* ------------------------------------------------------------------ */
/* Transactions                                                        */
/* ------------------------------------------------------------------ */

void
cmacs_dbx_begin_async (CmacsDbxConn *conn, CmacsDbxDoneCb cb, guint64 token)
{
  if (cb == NULL)
    return;
  if (cmacs_dbx_conn_read_only (conn))
    {
      cb (token, "this connection is read-only");
      return;
    }
  dbx_statement_async (conn, "BEGIN", NULL, 0, NULL, cb, token, 1);
}

void
cmacs_dbx_commit_async (CmacsDbxConn *conn, CmacsDbxDoneCb cb, guint64 token)
{
  if (cb == NULL)
    return;
  dbx_statement_async (conn, "COMMIT", NULL, 0, NULL, cb, token, 0);
}

void
cmacs_dbx_rollback_async (CmacsDbxConn *conn, const char *savepoint,
                          CmacsDbxDoneCb cb, guint64 token)
{
  if (cb == NULL)
    return;

  if (savepoint != NULL && *savepoint != '\0')
    {
      g_autofree gchar *quoted = cmacs_dbx_quote_identifier (conn, savepoint);
      g_autofree gchar *sql =
        g_strdup_printf ("ROLLBACK TO SAVEPOINT %s", quoted);

      /* Rolling back to a savepoint leaves the transaction open, so the
         depth is unchanged; only a whole-transaction rollback ends it. */
      dbx_statement_async (conn, sql, NULL, 0, NULL, cb, token, -1);
      return;
    }

  dbx_statement_async (conn, "ROLLBACK", NULL, 0, NULL, cb, token, 0);
}

void
cmacs_dbx_savepoint_async (CmacsDbxConn *conn, const char *name,
                           CmacsDbxDoneCb cb, guint64 token)
{
  g_autofree gchar *quoted = NULL;
  g_autofree gchar *sql = NULL;

  if (cb == NULL)
    return;
  if (name == NULL || *name == '\0')
    {
      cb (token, "a savepoint needs a name");
      return;
    }
  if (cmacs_dbx_conn_read_only (conn))
    {
      cb (token, "this connection is read-only");
      return;
    }

  quoted = cmacs_dbx_quote_identifier (conn, name);
  sql = g_strdup_printf ("SAVEPOINT %s", quoted);

  /* A SAVEPOINT outside a transaction starts one, so the depth becomes
     non-zero either way. */
  dbx_statement_async (conn, sql, NULL, 0, NULL, cb, token, 1);
}

/* ------------------------------------------------------------------ */
/* Applying staged edits                                               */
/* ------------------------------------------------------------------ */

/* The batch is one transaction, driven as a state machine because
   orm-glib's asynchronous API is one statement at a time and the whole
   point is that these statements happen in order or not at all.

   PHASE says what the outstanding statement is:

     OPEN       the BEGIN or the SAVEPOINT that wraps the batch
     STATEMENT  the op at INDEX
     CLOSE      the COMMIT or the RELEASE that ends a successful batch
     UNDO       the ROLLBACK that ends a failed one
     RELEASE    the RELEASE that follows a rollback to a savepoint, so
                the user's own transaction is left as it was found  */
enum
{
  DBX_APPLY_OPEN,
  DBX_APPLY_STATEMENT,
  DBX_APPLY_CLOSE,
  DBX_APPLY_UNDO,
  DBX_APPLY_RELEASE
};

typedef struct
{
  CmacsDbxConn    *conn;
  CmacsDbxEditOp  *ops;
  int              n_ops;
  int              index;
  int              applied;
  int              phase;
  gboolean         savepoint;    /* wrapped in a savepoint, not a BEGIN */
  int              outer_depth;  /* the depth to restore on the way out */
  gchar           *failure;
  int              failed_index;
  CmacsDbxApplyCb  cb;
  guint64          token;
} CmacsDbxApplyJob;

static void dbx_apply_step (CmacsDbxApplyJob *job);

static void
dbx_apply_job_free (CmacsDbxApplyJob *job)
{
  cmacs_dbx_edit_ops_free (job->ops, job->n_ops);
  g_free (job->failure);
  g_free (job);
}

static void
dbx_apply_report (CmacsDbxApplyJob *job)
{
  cmacs_dbx_conn_set_tx_depth (job->conn, job->outer_depth);

  if (job->failure != NULL)
    job->cb (job->token, 0, job->failed_index, job->failure);
  else
    job->cb (job->token, job->applied, -1, NULL);

  dbx_apply_job_free (job);
}

/* Record a failure and switch the machine to unwinding.  The message is
   kept rather than reported now, because reporting before the rollback
   has landed would tell the caller the batch was abandoned while its
   statements were still committed. */
static void
dbx_apply_fail (CmacsDbxApplyJob *job, int index, gchar *message)
{
  if (job->failure == NULL)
    {
      job->failure = message;
      job->failed_index = index;
    }
  else
    {
      g_free (message);
    }
  job->phase = DBX_APPLY_UNDO;
  dbx_apply_step (job);
}

/* Build the statement for one op, and the values it binds.

   Identifiers go through the dialect's quoting, which doubles whatever
   quote character it uses -- so a table called a";DROP TABLE x;-- comes
   back as a name and not as three statements.  Values are bound, never
   interpolated, not even numbers: a number that came from a grid cell is
   text until something proves otherwise, and "it looked numeric" is not
   a proof worth a table.  */
static gchar *
dbx_apply_build (CmacsDbxApplyJob *job, const CmacsDbxEditOp *op,
                 CmacsDbxParam **out_params, int *out_n_params,
                 gchar **error)
{
  GString *sql = g_string_new (NULL);
  GArray *params = g_array_new (FALSE, TRUE, sizeof (CmacsDbxParam));
  g_autofree gchar *table = NULL;
  int i;

  *error = NULL;

  if (op->table == NULL || *op->table == '\0')
    {
      *error = g_strdup ("the edit names no table");
      goto failed;
    }

  /* An update or a delete with no WHERE is every row in the table.  That
     is never what a staged row edit meant, so it is refused here rather
     than caught by the :expect check afterwards -- by then the rows are
     already gone and only the rollback saves them. */
  if (op->kind != CMACS_DBX_OP_INSERT && op->n_where < 1)
    {
      *error = g_strdup ("the edit has no WHERE clause,"
                         " so it would match every row");
      goto failed;
    }
  if (op->kind != CMACS_DBX_OP_DELETE && op->n_set < 1)
    {
      *error = g_strdup ("the edit sets no columns");
      goto failed;
    }

  {
    g_autofree gchar *quoted_table =
      cmacs_dbx_quote_identifier (job->conn, op->table);

    if (op->schema != NULL && *op->schema != '\0')
      {
        g_autofree gchar *quoted_schema =
          cmacs_dbx_quote_identifier (job->conn, op->schema);

        table = g_strdup_printf ("%s.%s", quoted_schema, quoted_table);
      }
    else
      {
        table = g_strdup (quoted_table);
      }
  }

  switch (op->kind)
    {
    case CMACS_DBX_OP_UPDATE:
      g_string_append_printf (sql, "UPDATE %s SET ", table);
      for (i = 0; i < op->n_set; i++)
        {
          g_autofree gchar *column =
            cmacs_dbx_quote_identifier (job->conn, op->set[i].name);

          if (i > 0)
            g_string_append (sql, ", ");
          g_string_append_printf (sql, "%s = ?", column);
          g_array_append_val (params, op->set[i].value);
        }
      break;

    case CMACS_DBX_OP_INSERT:
      g_string_append_printf (sql, "INSERT INTO %s (", table);
      for (i = 0; i < op->n_set; i++)
        {
          g_autofree gchar *column =
            cmacs_dbx_quote_identifier (job->conn, op->set[i].name);

          if (i > 0)
            g_string_append (sql, ", ");
          g_string_append (sql, column);
        }
      g_string_append (sql, ") VALUES (");
      for (i = 0; i < op->n_set; i++)
        {
          if (i > 0)
            g_string_append (sql, ", ");
          g_string_append (sql, "?");
          g_array_append_val (params, op->set[i].value);
        }
      g_string_append (sql, ")");
      break;

    case CMACS_DBX_OP_DELETE:
    default:
      g_string_append_printf (sql, "DELETE FROM %s", table);
      break;
    }

  if (op->kind != CMACS_DBX_OP_INSERT)
    {
      g_string_append (sql, " WHERE ");
      for (i = 0; i < op->n_where; i++)
        {
          g_autofree gchar *column =
            cmacs_dbx_quote_identifier (job->conn, op->where[i].name);

          if (i > 0)
            g_string_append (sql, " AND ");

          /* `= NULL' is never true, so a key column that is NULL has to
             be compared with IS NULL or the row is simply not found --
             which the :expect check would then report as a mismatch
             rather than as the bug it is. */
          if (op->where[i].value.type == CMACS_DBX_PARAM_NULL)
            {
              g_string_append_printf (sql, "%s IS NULL", column);
            }
          else
            {
              g_string_append_printf (sql, "%s = ?", column);
              g_array_append_val (params, op->where[i].value);
            }
        }
    }

  *out_n_params = (int) params->len;
  *out_params = (CmacsDbxParam *) g_array_free (params, FALSE);
  return g_string_free (sql, FALSE);

 failed:
  g_array_free (params, TRUE);
  g_string_free (sql, TRUE);
  *out_params = NULL;
  *out_n_params = 0;
  return NULL;
}

static void
dbx_on_apply_statement (GObject *source, GAsyncResult *result,
                        gpointer user_data)
{
  CmacsDbxApplyJob *job = user_data;
  OrmConnection *connection = ORM_CONNECTION (source);
  GError *err = NULL;
  const CmacsDbxEditOp *op;
  gint changes;

  if (!orm_connection_execute_finish (connection, result, &err))
    {
      gchar *message = g_strdup (err && err->message ? err->message
                                 : "the statement failed");

      g_clear_error (&err);

      switch (job->phase)
        {
        case DBX_APPLY_OPEN:
          /* Nothing was opened, so there is nothing to unwind. */
          job->failure = message;
          job->failed_index = -1;
          dbx_apply_report (job);
          return;

        case DBX_APPLY_STATEMENT:
          dbx_apply_fail (job, job->index, message);
          return;

        case DBX_APPLY_CLOSE:
          /* The commit itself failed, which the database has already
             undone; there is nothing left to roll back. */
          job->failure = message;
          job->failed_index = -1;
          dbx_apply_report (job);
          return;

        case DBX_APPLY_UNDO:
        case DBX_APPLY_RELEASE:
        default:
          /* A failed rollback leaves the original failure the more
             useful thing to report. */
          g_free (message);
          dbx_apply_report (job);
          return;
        }
    }
  g_clear_error (&err);

  switch (job->phase)
    {
    case DBX_APPLY_OPEN:
      job->phase = DBX_APPLY_STATEMENT;
      job->index = 0;
      dbx_apply_step (job);
      return;

    case DBX_APPLY_STATEMENT:
      op = &job->ops[job->index];
      changes = orm_connection_get_changes (connection);

      /* The guard the whole batch exists for.  A WHERE clause that
         matched no rows, or two, means the row identity the view used is
         not the row identity the database has -- someone else changed
         the table, or the primary key was not what it looked like -- and
         committing on that assumption is how the wrong row is edited. */
      if (op->expect >= 0 && changes != op->expect)
        {
          dbx_apply_fail (job, job->index,
                          g_strdup_printf ("statement %d expected to touch"
                                           " %d row%s but touched %d;"
                                           " the whole batch was rolled back",
                                           job->index, op->expect,
                                           op->expect == 1 ? "" : "s",
                                           changes));
          return;
        }

      job->applied++;
      job->index++;
      dbx_apply_step (job);
      return;

    case DBX_APPLY_CLOSE:
      dbx_apply_report (job);
      return;

    case DBX_APPLY_UNDO:
      /* A rollback to a savepoint leaves the savepoint itself in place,
         so it is released before the caller's transaction is handed
         back the way it was found. */
      if (job->savepoint)
        {
          job->phase = DBX_APPLY_RELEASE;
          dbx_apply_step (job);
          return;
        }
      dbx_apply_report (job);
      return;

    case DBX_APPLY_RELEASE:
    default:
      dbx_apply_report (job);
      return;
    }
}

static void
dbx_apply_issue (CmacsDbxApplyJob *job, const gchar *sql,
                 const CmacsDbxParam *params, int n_params)
{
  OrmConnection *connection = cmacs_dbx_conn_orm (job->conn);
  GList *values;
  GMainContext *context;

  if (connection == NULL)
    {
      g_free (job->failure);
      job->failure = g_strdup ("the connection closed mid-batch");
      job->failed_index = job->index;
      dbx_apply_report (job);
      return;
    }

  values = dbx_params_to_list (params, n_params);
  context = dbx_push_context ();
  orm_connection_execute_async (connection, sql, values, NULL,
                                dbx_on_apply_statement, job);
  dbx_pop_context (context);
  dbx_params_list_free (values);
}

static void
dbx_apply_step (CmacsDbxApplyJob *job)
{
  g_autofree gchar *sql = NULL;

  switch (job->phase)
    {
    case DBX_APPLY_OPEN:
      if (job->savepoint)
        sql = g_strdup ("SAVEPOINT " DBX_APPLY_SAVEPOINT);
      else
        sql = g_strdup ("BEGIN");
      dbx_apply_issue (job, sql, NULL, 0);
      return;

    case DBX_APPLY_STATEMENT:
      if (job->index >= job->n_ops)
        {
          job->phase = DBX_APPLY_CLOSE;
          dbx_apply_step (job);
          return;
        }
      {
        CmacsDbxParam *params = NULL;
        int n_params = 0;
        gchar *error = NULL;
        gchar *statement = dbx_apply_build (job, &job->ops[job->index],
                                            &params, &n_params, &error);

        if (statement == NULL)
          {
            g_free (params);
            dbx_apply_fail (job, job->index, error);
            return;
          }
        dbx_apply_issue (job, statement, params, n_params);
        /* The bindings belong to the ops, so only the array itself is
           freed here; freeing the params would free strings the op still
           owns and would need again on a retry. */
        g_free (params);
        g_free (statement);
      }
      return;

    case DBX_APPLY_CLOSE:
      if (job->savepoint)
        sql = g_strdup ("RELEASE SAVEPOINT " DBX_APPLY_SAVEPOINT);
      else
        sql = g_strdup ("COMMIT");
      dbx_apply_issue (job, sql, NULL, 0);
      return;

    case DBX_APPLY_UNDO:
      if (job->savepoint)
        sql = g_strdup ("ROLLBACK TO SAVEPOINT " DBX_APPLY_SAVEPOINT);
      else
        sql = g_strdup ("ROLLBACK");
      dbx_apply_issue (job, sql, NULL, 0);
      return;

    case DBX_APPLY_RELEASE:
    default:
      sql = g_strdup ("RELEASE SAVEPOINT " DBX_APPLY_SAVEPOINT);
      dbx_apply_issue (job, sql, NULL, 0);
      return;
    }
}

void
cmacs_dbx_apply_edits_async (CmacsDbxConn *conn, CmacsDbxEditOp *ops,
                             int n_ops, CmacsDbxApplyCb cb, guint64 token)
{
  CmacsDbxApplyJob *job;

  if (cb == NULL)
    {
      cmacs_dbx_edit_ops_free (ops, n_ops);
      return;
    }

  if (cmacs_dbx_conn_read_only (conn))
    {
      cmacs_dbx_edit_ops_free (ops, n_ops);
      cb (token, 0, -1, "this connection is read-only");
      return;
    }

  if (cmacs_dbx_conn_orm (conn) == NULL)
    {
      cmacs_dbx_edit_ops_free (ops, n_ops);
      cb (token, 0, -1, "the connection is closed");
      return;
    }

  if (n_ops < 1)
    {
      cmacs_dbx_edit_ops_free (ops, n_ops);
      cb (token, 0, -1, NULL);
      return;
    }

  job = g_new0 (CmacsDbxApplyJob, 1);
  job->conn = conn;
  job->ops = ops;
  job->n_ops = n_ops;
  job->failed_index = -1;
  job->cb = cb;
  job->token = token;
  job->phase = DBX_APPLY_OPEN;

  /* A batch inside a transaction the user opened has to nest, and SQL
     has no nested BEGIN: a second one either errors or silently commits
     the first, depending on the backend.  A savepoint is the nesting
     construct, and rolling back to it undoes the batch without touching
     what the user did before it. */
  job->outer_depth = cmacs_dbx_conn_tx_depth (conn);
  job->savepoint = job->outer_depth > 0;

  dbx_apply_step (job);
}

#endif /* HAVE_CMACS_DBEXPLORER */
