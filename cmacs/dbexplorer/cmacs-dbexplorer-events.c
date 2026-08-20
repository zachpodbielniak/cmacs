/* cmacs-dbexplorer-events.c --- delivering async results into Lisp

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

/* Two callback lifetimes, because queries have two shapes.

   A one-shot -- connect, execute, apply-edits -- registers its Lisp
   callback with cmacs-eval-dispatch's cookie registry, which is a
   staticpro'd hash table, and the invoke-and-pop drops the GC root
   atomically when the reply lands.

   A stream -- a query, an export -- calls back many times before it is
   done, so a single-shot cookie is the wrong shape.  Those live in the
   table below, keyed by an integer stream id, until the terminating
   (:end) or (:error) event removes them.

   Both deliver through cmacs_dispatch_safe_call*, never safe_calln
   directly: a GLib callback can arrive while Emacs believes it is
   waiting for input, and a Lisp error raised in that state aborts the
   process rather than being caught.

   No completion needs g_main_context_invoke to reach the main thread.
   Every asynchronous call this subsystem makes is issued with cmacs's
   own GMainContext pushed as thread-default, so the GTask that carries
   the answer completes on the context Emacs's pselect drives -- which is
   the same thread, and the one place where clearing waiting_for_input
   around a dispatch is already understood.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "lisp.h"
#include "coding.h"
#include "cmacs-dbexplorer.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>

/* ------------------------------------------------------------------ */
/* The callback table                                                  */
/* ------------------------------------------------------------------ */

/* One staticpro'd hash table holds everything with a lifetime longer
   than a single reply: the session's two singleton callbacks under
   symbol keys, and one entry per live stream under its integer id.  The
   stream entries carry no closure -- Lisp routes payloads by id itself,
   through the single stream callback -- but their presence is what says
   a stream is still running, so a batch that was already in flight when
   the stream was cancelled is dropped here instead of being handed to a
   view that has forgotten it.  */
static Lisp_Object Vcmacs_dbexplorer__callbacks;

static Lisp_Object Qcmacs_dbx_state_key;
static Lisp_Object Qcmacs_dbx_stream_key;

static void
dbx_table_init (void)
{
  if (NILP (Vcmacs_dbexplorer__callbacks))
    Vcmacs_dbexplorer__callbacks = CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
dbx_table_get (Lisp_Object key)
{
  dbx_table_init ();
  return Fgethash (key, Vcmacs_dbexplorer__callbacks, Qnil);
}

static void
dbx_table_put (Lisp_Object key, Lisp_Object value)
{
  dbx_table_init ();
  Fputhash (key, value, Vcmacs_dbexplorer__callbacks);
}

static void
dbx_table_drop (Lisp_Object key)
{
  if (!NILP (Vcmacs_dbexplorer__callbacks))
    Fremhash (key, Vcmacs_dbexplorer__callbacks);
}

/* ------------------------------------------------------------------ */
/* Building Lisp values                                                */
/* ------------------------------------------------------------------ */

/* Text out of a database is UTF-8; decoding it as such is what makes a
   name with an accent in it round-trip instead of arriving as bytes. */
static Lisp_Object
dbx_utf8 (const char *s)
{
  return s ? code_convert_string_norecord (build_unibyte_string (s),
                                           Qutf_8, false)
           : Qnil;
}

static Lisp_Object
dbx_bool (int flag)
{
  return flag ? Qt : Qnil;
}

/* Every failure crosses into Lisp as data, never as a signal: these are
   built inside GLib callbacks, and a signal raised there is a crash
   rather than something a condition-case can catch. */
static Lisp_Object
dbx_error_reply (const char *message)
{
  return list1 (Fcons (intern (":error"),
                       dbx_utf8 (message != NULL ? message
                                 : "the database operation failed")));
}

static Lisp_Object
dbx_strv_vector (char **strv)
{
  ptrdiff_t n = 0;
  ptrdiff_t i;
  Lisp_Object vec;

  while (strv != NULL && strv[n] != NULL)
    n++;

  vec = make_nil_vector (n);
  for (i = 0; i < n; i++)
    ASET (vec, i, dbx_utf8 (strv[i]));
  return vec;
}

/* ------------------------------------------------------------------ */
/* One-shot completions                                                */
/* ------------------------------------------------------------------ */

void
cmacs_dbx_on_connect (guint64 token, CmacsDbxConn *conn,
                      const char *dialect, const char *error)
{
  int handle;

  if (conn == NULL || error != NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }

  handle = cmacs_dbx_register_conn (conn);
  cmacs_dispatch_callback_invoke1
    (token, list2 (Fcons (intern (":handle"), make_fixnum (handle)),
                   Fcons (intern (":dialect"), dbx_utf8 (dialect))));
}

void
cmacs_dbx_on_done (guint64 token, const char *error)
{
  if (error != NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }
  cmacs_dispatch_callback_invoke1 (token, list1 (Fcons (intern (":ok"), Qt)));
}

void
cmacs_dbx_on_execute (guint64 token, long long rows_affected,
                      long long last_rowid, const char *error)
{
  if (error != NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }

  cmacs_dispatch_callback_invoke1
    (token, list2 (Fcons (intern (":rows-affected"), make_int (rows_affected)),
                   Fcons (intern (":last-insert-rowid"),
                          make_int (last_rowid))));
}

void
cmacs_dbx_on_apply (guint64 token, int applied, int failed_index,
                    const char *error)
{
  if (error != NULL)
    {
      /* Which op failed and what it actually touched, because "the batch
         was rolled back" without saying where is an invitation to run it
         again and watch it fail the same way. */
      cmacs_dispatch_callback_invoke1
        (token, list2 (Fcons (intern (":error"), dbx_utf8 (error)),
                       Fcons (intern (":failed-index"),
                              make_fixnum (failed_index))));
      return;
    }

  cmacs_dispatch_callback_invoke1
    (token, list1 (Fcons (intern (":applied"), make_fixnum (applied))));
}

void
cmacs_dbx_on_schemas (guint64 token, char **schemas, const char *error)
{
  if (error != NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }

  cmacs_dispatch_callback_invoke1
    (token, list1 (Fcons (intern (":schemas"), dbx_strv_vector (schemas))));
}

void
cmacs_dbx_on_tables (guint64 token, const CmacsDbxRelation *relations,
                     int n_relations, const char *error)
{
  Lisp_Object vec;
  int i;

  if (error != NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }

  vec = make_nil_vector (n_relations);
  for (i = 0; i < n_relations; i++)
    ASET (vec, i,
          list4 (intern (":name"), dbx_utf8 (relations[i].name),
                 intern (":kind"),
                 relations[i].is_view ? intern ("view") : intern ("table")));

  cmacs_dispatch_callback_invoke1
    (token, list1 (Fcons (intern (":relations"), vec)));
}

static Lisp_Object
dbx_column_plist (const CmacsDbxColumnInfo *column)
{
  return CALLN (Flist,
                intern (":name"), dbx_utf8 (column->name),
                intern (":type"),
                intern (cmacs_dbx_value_type_name (column->value_type)),
                intern (":type-name"), dbx_utf8 (column->type_name),
                intern (":nullable"), dbx_bool (column->nullable),
                intern (":default"), dbx_utf8 (column->default_value),
                intern (":primary-key"), dbx_bool (column->primary_key),
                intern (":ordinal"), make_fixnum (column->ordinal));
}

static Lisp_Object
dbx_index_plist (const CmacsDbxIndexInfo *index)
{
  return CALLN (Flist,
                intern (":name"), dbx_utf8 (index->name),
                intern (":unique"), dbx_bool (index->unique),
                intern (":columns"), dbx_strv_vector (index->columns));
}

static Lisp_Object
dbx_foreign_key_plist (const CmacsDbxForeignKeyInfo *key)
{
  return CALLN (Flist,
                intern (":name"), dbx_utf8 (key->name),
                intern (":columns"), dbx_strv_vector (key->columns),
                intern (":references"), dbx_utf8 (key->ref_table),
                intern (":ref-schema"), dbx_utf8 (key->ref_schema),
                intern (":ref-columns"), dbx_strv_vector (key->ref_columns));
}

void
cmacs_dbx_on_table_info (guint64 token, const CmacsDbxTableInfo *info,
                         const char *error)
{
  Lisp_Object columns, indexes, foreign_keys;
  int i;

  if (error != NULL || info == NULL)
    {
      cmacs_dispatch_callback_invoke1 (token, dbx_error_reply (error));
      return;
    }

  columns = make_nil_vector (info->n_columns);
  for (i = 0; i < info->n_columns; i++)
    ASET (columns, i, dbx_column_plist (&info->columns[i]));

  indexes = make_nil_vector (info->n_indexes);
  for (i = 0; i < info->n_indexes; i++)
    ASET (indexes, i, dbx_index_plist (&info->indexes[i]));

  foreign_keys = make_nil_vector (info->n_foreign_keys);
  for (i = 0; i < info->n_foreign_keys; i++)
    ASET (foreign_keys, i, dbx_foreign_key_plist (&info->foreign_keys[i]));

  /* One reply carrying all four, so the tree, the row editor and
     completion each cost one round trip rather than four. */
  cmacs_dispatch_callback_invoke1
    (token, list4 (Fcons (intern (":columns"), columns),
                   Fcons (intern (":primary-key"),
                          dbx_strv_vector (info->primary_key)),
                   Fcons (intern (":indexes"), indexes),
                   Fcons (intern (":foreign-keys"), foreign_keys)));
}

/* ------------------------------------------------------------------ */
/* Stream events                                                       */
/* ------------------------------------------------------------------ */

static void
dbx_deliver_stream (long long stream_id, Lisp_Object payload)
{
  Lisp_Object id = make_int (stream_id);
  Lisp_Object callback;

  /* A payload for a stream that is no longer in the table belongs to one
     that was cancelled while a batch was already in flight.  Dropping it
     is right: the view that asked has forgotten it, and there is nowhere
     for the rows to go. */
  if (NILP (dbx_table_get (id)))
    return;

  callback = dbx_table_get (Qcmacs_dbx_stream_key);
  if (!NILP (callback))
    cmacs_dispatch_safe_call2 (callback, id, payload);
}

static void
dbx_sink_meta (long long stream_id, int n_columns,
               const CmacsDbxColumn *columns)
{
  Lisp_Object vec = make_nil_vector (n_columns);
  int i;

  for (i = 0; i < n_columns; i++)
    ASET (vec, i,
          CALLN (Flist,
                 intern (":name"), dbx_utf8 (columns[i].name),
                 intern (":type"),
                 intern (cmacs_dbx_value_type_name (columns[i].value_type)),
                 intern (":type-name"), dbx_utf8 (columns[i].type_name),
                 intern (":nullable"), dbx_bool (columns[i].nullable)));

  dbx_deliver_stream (stream_id, list2 (intern (":meta"), vec));
}

static void
dbx_sink_rows (long long stream_id, const CmacsDbxPage *page)
{
  Lisp_Object rows;
  int r, c;

  rows = make_nil_vector (page->n_rows);
  for (r = 0; r < page->n_rows; r++)
    {
      Lisp_Object row = make_nil_vector (page->n_columns);

      for (c = 0; c < page->n_columns; c++)
        {
          long long blob_size =
            page->blob_sizes[(ptrdiff_t) r * page->n_columns + c];
          const char *cell = page->cells[r][c];

          /* Three shapes, and they have to stay distinguishable: a
             string, the keyword :null, and (:blob . SIZE).  A column can
             legitimately contain the text "NULL", and rendering a
             missing value the same way is how a typo gets mistaken for
             an absence. */
          if (cell != NULL)
            ASET (row, c, dbx_utf8 (cell));
          else if (blob_size >= 0)
            ASET (row, c, Fcons (intern (":blob"), make_int (blob_size)));
          else
            ASET (row, c, intern (":null"));
        }
      ASET (rows, r, row);
    }

  dbx_deliver_stream (stream_id, list2 (intern (":rows"), rows));
}

static void
dbx_sink_progress (long long stream_id, long long rows_so_far)
{
  dbx_deliver_stream (stream_id,
                      list2 (intern (":progress"), make_int (rows_so_far)));
}

static void
dbx_sink_end (long long stream_id, long long row_count, int truncated,
              double elapsed_ms)
{
  Lisp_Object payload =
    CALLN (Flist,
           intern (":end"),
           intern (":row-count"), make_int (row_count),
           intern (":truncated"), dbx_bool (truncated),
           intern (":elapsed-ms"), make_float (elapsed_ms));

  dbx_deliver_stream (stream_id, payload);
  dbx_table_drop (make_int (stream_id));
}

static void
dbx_sink_error (long long stream_id, const char *message)
{
  dbx_deliver_stream (stream_id,
                      list2 (intern (":error"), dbx_utf8 (message)));
  dbx_table_drop (make_int (stream_id));
}

static const CmacsDbxStreamSink dbx_sink =
{
  dbx_sink_meta,
  dbx_sink_rows,
  dbx_sink_progress,
  dbx_sink_end,
  dbx_sink_error
};

/* ------------------------------------------------------------------ */
/* Connection state                                                    */
/* ------------------------------------------------------------------ */

static void
dbx_sink_state (int tag, const char *state)
{
  Lisp_Object callback = dbx_table_get (Qcmacs_dbx_state_key);

  if (NILP (callback))
    return;

  /* One list rather than three arguments, so the shape matches a stream
     payload and a handler can be written the same way for both. */
  cmacs_dispatch_safe_call1 (callback,
                             list3 (intern (":state"), make_fixnum (tag),
                                    intern (state != NULL ? state : "closed")));
}

void
cmacs_dbx_events_install (void)
{
  cmacs_dbx_set_stream_sink (&dbx_sink);
  cmacs_dbx_set_state_sink (dbx_sink_state);
}

/* Called by the DEFUNs when a stream starts, so its events have
   somewhere to land, and by --cancel when one is abandoned early. */
void
cmacs_dbx_events_track_stream (long long stream_id)
{
  dbx_table_put (make_int (stream_id), Qt);
}

void
cmacs_dbx_events_forget_stream (long long stream_id)
{
  dbx_table_drop (make_int (stream_id));
}

/* ------------------------------------------------------------------ */
/* The two singleton callbacks                                         */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-dbexplorer--set-state-callback",
       Fcmacs_dbexplorer__set_state_callback,
       Scmacs_dbexplorer__set_state_callback, 1, 1, 0,
       doc: /* Call FN whenever a database connection changes state.

FN is called with one list, (:state HANDLE STATE), where HANDLE is the
integer a connection was opened as and STATE is one of `connecting',
`open', `busy' or `closed'.

There is one such function for the whole session, not one per caller: a
second installer would take the first one's events with it, and which of
the two won would depend on load order.  `cmacs-dbexplorer.el' installs
it and re-broadcasts on
`cmacs-dbexplorer-connection-state-functions', which is what any number
of views can listen to at once.  FN of nil stops the reports.  */)
  (Lisp_Object fn)
{
  if (NILP (fn))
    dbx_table_drop (Qcmacs_dbx_state_key);
  else
    dbx_table_put (Qcmacs_dbx_state_key, fn);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--set-stream-callback",
       Fcmacs_dbexplorer__set_stream_callback,
       Scmacs_dbexplorer__set_stream_callback, 1, 1, 0,
       doc: /* Call FN with every event of every running query.

FN is called with two arguments, the integer stream id and a payload:

  (:meta COLUMNS)   a vector of (:name S :type SYM :type-name S
                    :nullable BOOL) plists, sent once before any row
  (:rows ROWS)      a vector of row vectors, at most 256 rows a time
  (:progress N)     rows written so far, sent only by an export
  (:end :row-count N :truncated BOOL :elapsed-ms MS)
  (:error MESSAGE)

A cell of a row vector is a string, the keyword `:null', or a cons
\(:blob . SIZE) for a value too large to have been sent as text.

Exactly one of `:end' and `:error' arrives, and it is the last event for
that id.  As with the state callback there is one of these for the whole
session; `cmacs-dbexplorer.el' owns it and routes by id.  FN of nil
stops the reports.  */)
  (Lisp_Object fn)
{
  if (NILP (fn))
    dbx_table_drop (Qcmacs_dbx_stream_key);
  else
    dbx_table_put (Qcmacs_dbx_stream_key, fn);
  return Qnil;
}

void
syms_of_cmacs_dbexplorer_events (void)
{
  Vcmacs_dbexplorer__callbacks = Qnil;
  staticpro (&Vcmacs_dbexplorer__callbacks);

  Qcmacs_dbx_state_key = intern_c_string ("cmacs-dbexplorer--state-callback");
  staticpro (&Qcmacs_dbx_state_key);
  Qcmacs_dbx_stream_key = intern_c_string ("cmacs-dbexplorer--stream-callback");
  staticpro (&Qcmacs_dbx_stream_key);

  defsubr (&Scmacs_dbexplorer__set_state_callback);
  defsubr (&Scmacs_dbexplorer__set_stream_callback);
}

#endif /* HAVE_CMACS_DBEXPLORER */
