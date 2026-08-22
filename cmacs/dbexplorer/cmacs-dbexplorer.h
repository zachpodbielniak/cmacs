/* cmacs-dbexplorer.h --- database explorer subsystem

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

/* Three translation-unit classes, the office/roamgraph split:

   - cmacs-dbexplorer-conn.c, -query.c and -schema.c are the model half.
     They include <orm.h> and glib and NEITHER lisp.h NOR any Emacs
     header.  That is what keeps the connection handling, the read-only
     SQL classifier and the schema readers testable with no Lisp VM.

   - cmacs-dbexplorer-defuns.c is the Lisp half.  It includes lisp.h and
     reaches the model only through this plain-C bridge header, so it
     never sees an OrmConnection or an OrmValue.

   - cmacs-dbexplorer-init.c aggregates the per-TU syms_of_ hooks.

   Handles are integers rather than pointers, and never Lisp_Object,
   because a Lisp_Object living in GLib-allocated memory has no GC root.

   Everything below is plain C over glib: no Lisp_Object, no orm-glib
   type.  The two halves therefore share one header without either being
   able to reach into the other's vocabulary, and a change to orm-glib's
   API cannot ripple past the model TUs.  Where a bridge function has to
   hand back an orm-glib object -- the connection's OrmConnection, its
   OrmInspector -- it is typed void * here and cast on the model side,
   which is the price of keeping this header includable from a TU that
   has already included lisp.h.  */

#ifndef CMACS_DBEXPLORER_H
#define CMACS_DBEXPLORER_H

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include <glib.h>

/* ------------------------------------------------------------------ */
/* Values crossing the bridge                                          */
/* ------------------------------------------------------------------ */

/* An open database connection.  Opaque: only the model half knows that
   it wraps an OrmEngine, an OrmConnection and a lazily-built
   OrmInspector.  */
typedef struct _CmacsDbxConn CmacsDbxConn;

/* What a bound parameter is.  Values are ALWAYS bound, never
   interpolated -- so the Lisp half needs a way to say "this is an
   integer" rather than handing over SQL text, and this is it.  */
enum
{
  CMACS_DBX_PARAM_NULL,
  CMACS_DBX_PARAM_STRING,
  CMACS_DBX_PARAM_INTEGER,
  CMACS_DBX_PARAM_FLOAT
};

typedef struct
{
  int        type;                     /* one of the CMACS_DBX_PARAM_* */
  char      *text;                     /* owned; CMACS_DBX_PARAM_STRING */
  long long  integer;
  double     real;
} CmacsDbxParam;

void cmacs_dbx_params_free (CmacsDbxParam *params, int n_params);

/* One column of a result set.  VALUE_TYPE is an OrmValueType widened to
   int; cmacs_dbx_value_type_name turns it back into a name, so the enum
   itself never crosses into the Lisp half.  */
typedef struct
{
  char *name;
  char *type_name;
  int   value_type;
  int   nullable;
} CmacsDbxColumn;

const char *cmacs_dbx_value_type_name (int value_type);

/* A batch of rows.

   CELLS is indexed [row][column].  A NULL cell is either a SQL NULL or a
   blob, told apart by BLOB_SIZES, which is a flat array of N_ROWS *
   N_COLUMNS entries: >= 0 means the cell held a blob of that many bytes,
   -1 means it did not.  Blobs never travel as text -- a result grid that
   pastes a JPEG into a cell is worse than one that says how big it
   is -- so every blob arrives as a size and the Lisp half renders it as
   (:blob . SIZE).  */
typedef struct
{
  int              n_columns;
  CmacsDbxColumn  *columns;
  int              n_rows;
  char          ***cells;
  long long       *blob_sizes;
  int              truncated;
  double           elapsed_ms;
} CmacsDbxPage;

void cmacs_dbx_page_free (CmacsDbxPage *page);

/* ------------------------------------------------------------------ */
/* What the schema reader reports                                      */
/* ------------------------------------------------------------------ */

typedef struct
{
  char *name;
  int   is_view;
} CmacsDbxRelation;

typedef struct
{
  char *name;
  char *type_name;
  int   value_type;
  int   nullable;
  char *default_value;
  int   primary_key;
  int   ordinal;
} CmacsDbxColumnInfo;

typedef struct
{
  char  *name;
  int    unique;
  char **columns;                      /* NULL-terminated */
} CmacsDbxIndexInfo;

typedef struct
{
  char  *name;
  char **columns;                      /* NULL-terminated */
  char  *ref_table;
  char  *ref_schema;
  char **ref_columns;                  /* NULL-terminated */
} CmacsDbxForeignKeyInfo;

/* Everything about one relation, in one record, because the tree, the
   row editor and SQL completion all want it and three round trips to
   answer one question is three chances to be told something different
   each time.  */
typedef struct
{
  CmacsDbxColumnInfo     *columns;
  int                     n_columns;
  char                  **primary_key;         /* NULL-terminated */
  CmacsDbxIndexInfo      *indexes;
  int                     n_indexes;
  CmacsDbxForeignKeyInfo *foreign_keys;
  int                     n_foreign_keys;
} CmacsDbxTableInfo;

/* ------------------------------------------------------------------ */
/* What apply-edits applies                                            */
/* ------------------------------------------------------------------ */

enum
{
  CMACS_DBX_OP_UPDATE,
  CMACS_DBX_OP_INSERT,
  CMACS_DBX_OP_DELETE
};

typedef struct
{
  char          *name;
  CmacsDbxParam  value;
} CmacsDbxBinding;

/* One staged change.  EXPECT is how many rows the statement must touch,
   or -1 for "do not check" -- which is only ever an insert, since an
   update or a delete whose WHERE matched the wrong number of rows is the
   failure this whole path exists to catch.  */
typedef struct
{
  int              kind;
  char            *schema;
  char            *table;
  CmacsDbxBinding *set;
  int              n_set;
  CmacsDbxBinding *where;
  int              n_where;
  int              expect;
} CmacsDbxEditOp;

void cmacs_dbx_edit_ops_free (CmacsDbxEditOp *ops, int n_ops);

/* ------------------------------------------------------------------ */
/* Completion callbacks                                                */
/* ------------------------------------------------------------------ */

/* One-shots carry an opaque TOKEN rather than a pointer.  The Lisp half
   stores the actual closure in cmacs-eval-dispatch's staticpro'd cookie
   registry and passes only the cookie through C, because a Lisp_Object
   in GLib-allocated memory has no GC root and the closure would be
   collected mid-flight.

   ERROR is NULL on success and the message otherwise.  A failure is
   always reported this way and never as a Lisp signal: these fire from
   GLib callbacks, and a signal raised there aborts the process rather
   than being caught.  */
typedef void (*CmacsDbxConnectCb)   (guint64 token, CmacsDbxConn *conn,
                                     const char *dialect, const char *error);
typedef void (*CmacsDbxDoneCb)      (guint64 token, const char *error);
typedef void (*CmacsDbxExecuteCb)   (guint64 token, long long rows_affected,
                                     long long last_rowid, const char *error);
typedef void (*CmacsDbxApplyCb)     (guint64 token, int applied,
                                     int failed_index, const char *error);
typedef void (*CmacsDbxSchemasCb)   (guint64 token, char **schemas,
                                     const char *error);
typedef void (*CmacsDbxTablesCb)    (guint64 token,
                                     const CmacsDbxRelation *relations,
                                     int n_relations, const char *error);
typedef void (*CmacsDbxTableInfoCb) (guint64 token,
                                     const CmacsDbxTableInfo *info,
                                     const char *error);

/* A query and an export call back many times, so they route through a
   sink installed once instead of a per-call closure.  The terminating
   event is exactly one of end or error, and it is what tells the Lisp
   half to forget the stream.  */
typedef struct
{
  void (*meta)     (long long stream_id, int n_columns,
                    const CmacsDbxColumn *columns);
  void (*rows)     (long long stream_id, const CmacsDbxPage *page);
  void (*progress) (long long stream_id, long long rows_so_far);
  void (*end)      (long long stream_id, long long row_count,
                    int truncated, double elapsed_ms);
  void (*error)    (long long stream_id, const char *message);
} CmacsDbxStreamSink;

void cmacs_dbx_set_stream_sink (const CmacsDbxStreamSink *sink);

/* Connection state, as the connection's own signal reports it: one of
   "connecting", "open", "busy" or "closed".  TAG is whatever
   cmacs_dbx_conn_set_tag stored, which is the Lisp handle.  */
void cmacs_dbx_set_state_sink (void (*fn) (int tag, const char *state));

/* ------------------------------------------------------------------ */
/* Connections (cmacs-dbexplorer-conn.c)                               */
/* ------------------------------------------------------------------ */

void cmacs_dbx_connect_async (const char *url, int read_only,
                              CmacsDbxConnectCb cb, guint64 token);

void         cmacs_dbx_conn_close        (CmacsDbxConn *conn);
const char  *cmacs_dbx_conn_dialect      (CmacsDbxConn *conn);
const char  *cmacs_dbx_conn_url          (CmacsDbxConn *conn);
const char  *cmacs_dbx_conn_state        (CmacsDbxConn *conn);
int          cmacs_dbx_conn_read_only    (CmacsDbxConn *conn);
void         cmacs_dbx_conn_set_read_only (CmacsDbxConn *conn, int flag);
int          cmacs_dbx_conn_tx_depth     (CmacsDbxConn *conn);
void         cmacs_dbx_conn_set_tx_depth (CmacsDbxConn *conn, int depth);
int          cmacs_dbx_conn_tag          (CmacsDbxConn *conn);
void         cmacs_dbx_conn_set_tag      (CmacsDbxConn *conn, int tag);

/* Quote NAME as an identifier in this connection's dialect.  The dialect
   doubles any embedded quote character, so this is safe for a name that
   came from the database itself -- or from someone who named a table
   a";DROP TABLE x;--.  Caller g_frees.  */
char *cmacs_dbx_quote_identifier (CmacsDbxConn *conn, const char *name);

/* Return URL with any password replaced, so a connection listing can be
   shown without leaking one.  Caller g_frees.  */
char *cmacs_dbx_redact_url (const char *url);

/* Non-zero when SQL cannot modify the database.  The classifier the
   read-only guard rests on; see the comment on its definition for what
   it does and does not promise.  */
int cmacs_dbx_sql_is_read_only (const char *sql);

/* Model-internal.  The three model TUs share one connection object, so
   its innards are reachable through accessors rather than a fourth
   header; the return types are void * because this header has to stay
   free of orm-glib for the Lisp half's sake.  */
void *cmacs_dbx_conn_orm       (CmacsDbxConn *conn);   /* OrmConnection * */
void *cmacs_dbx_conn_inspector (CmacsDbxConn *conn,    /* OrmInspector *  */
                                char **error);
void *cmacs_dbx_conn_cancellable (CmacsDbxConn *conn); /* GCancellable *  */

/* The sinks, for the model TUs that emit through them. */
const CmacsDbxStreamSink *cmacs_dbx_stream_sink (void);
void cmacs_dbx_emit_state (CmacsDbxConn *conn, const char *state);

/* ------------------------------------------------------------------ */
/* Statements (cmacs-dbexplorer-query.c)                               */
/* ------------------------------------------------------------------ */

/* Start a streaming query.  Always returns a stream id, even when the
   statement is refused before it runs -- a write on a read-only
   connection, a closed handle -- because the caller registers its
   handler for that id only after this returns.  A refusal therefore
   arrives as that stream's error event on the next main-loop turn,
   which is somewhere the caller is listening; returning the failure
   here would deliver it to nobody.  */
long long cmacs_dbx_query_async (CmacsDbxConn *conn, const char *sql,
                                 const CmacsDbxParam *params, int n_params,
                                 long long max_rows);

/* Start an export of SQL's rows to PATH in FORMAT ("csv" or "json").
   HEADER non-zero writes the CSV column-name line (JSON ignores it).
   Returns a stream id on the same terms as the query above.  */
long long cmacs_dbx_export_async (CmacsDbxConn *conn, const char *sql,
                                  const char *format, const char *path,
                                  long long max_rows, int header);

/* Stop a stream and forget it.  Silent on an id that is already gone:
   a cancel racing the last batch is normal, not an error. */
void cmacs_dbx_cancel (long long stream_id);

/* Stop every stream running on CONN.  Called before closing it, because
   a stream holds its connection busy until it is drained.  */
void cmacs_dbx_cancel_streams_for (CmacsDbxConn *conn);

void cmacs_dbx_execute_async (CmacsDbxConn *conn, const char *sql,
                              const CmacsDbxParam *params, int n_params,
                              CmacsDbxExecuteCb cb, guint64 token);

void cmacs_dbx_begin_async     (CmacsDbxConn *conn,
                                CmacsDbxDoneCb cb, guint64 token);
void cmacs_dbx_commit_async    (CmacsDbxConn *conn,
                                CmacsDbxDoneCb cb, guint64 token);
void cmacs_dbx_rollback_async  (CmacsDbxConn *conn, const char *savepoint,
                                CmacsDbxDoneCb cb, guint64 token);
void cmacs_dbx_savepoint_async (CmacsDbxConn *conn, const char *name,
                                CmacsDbxDoneCb cb, guint64 token);

void cmacs_dbx_apply_edits_async (CmacsDbxConn *conn,
                                  CmacsDbxEditOp *ops, int n_ops,
                                  CmacsDbxApplyCb cb, guint64 token);

/* ------------------------------------------------------------------ */
/* Introspection (cmacs-dbexplorer-schema.c)                           */
/* ------------------------------------------------------------------ */

void cmacs_dbx_schemas_async (CmacsDbxConn *conn,
                              CmacsDbxSchemasCb cb, guint64 token);
void cmacs_dbx_tables_async  (CmacsDbxConn *conn, const char *schema,
                              CmacsDbxTablesCb cb, guint64 token);
void cmacs_dbx_table_info_async (CmacsDbxConn *conn, const char *schema,
                                 const char *table,
                                 CmacsDbxTableInfoCb cb, guint64 token);

/* ------------------------------------------------------------------ */
/* Lisp-side entry points                                              */
/* ------------------------------------------------------------------ */

/* Each translation unit that registers DEFUNs exposes its own hook;
   cmacs-dbexplorer-init.c calls them.  syms_of_cmacs_dbexplorer and
   init_cmacs_dbexplorer themselves are declared in src/lisp.h.  */
extern void syms_of_cmacs_dbexplorer_defuns (void);
extern void syms_of_cmacs_dbexplorer_events (void);

/* Install the stream and state sinks.  Idempotent. */
extern void cmacs_dbx_events_install (void);

/* Note that a stream is live, so its events have somewhere to land, and
   forget it again when it is abandoned early.  A payload for an id that
   is not tracked is dropped rather than delivered.  */
extern void cmacs_dbx_events_track_stream (long long stream_id);
extern void cmacs_dbx_events_forget_stream (long long stream_id);

/* Defined in cmacs-dbexplorer-defuns.c, called from -events.c: the
   registry that turns a connection into the integer handle Lisp holds
   lives with the DEFUNs, but a connection is born in a completion
   callback, which lives with the events.  */
extern int cmacs_dbx_register_conn (CmacsDbxConn *conn);

/* The completion callbacks -events.c supplies, named here so the DEFUNs
   can hand them to the model without either TU including the other.  */
extern void cmacs_dbx_on_connect (guint64 token, CmacsDbxConn *conn,
                                  const char *dialect, const char *error);
extern void cmacs_dbx_on_done (guint64 token, const char *error);
extern void cmacs_dbx_on_execute (guint64 token, long long rows_affected,
                                  long long last_rowid, const char *error);
extern void cmacs_dbx_on_apply (guint64 token, int applied,
                                int failed_index, const char *error);
extern void cmacs_dbx_on_schemas (guint64 token, char **schemas,
                                  const char *error);
extern void cmacs_dbx_on_tables (guint64 token,
                                 const CmacsDbxRelation *relations,
                                 int n_relations, const char *error);
extern void cmacs_dbx_on_table_info (guint64 token,
                                     const CmacsDbxTableInfo *info,
                                     const char *error);

#endif /* HAVE_CMACS_DBEXPLORER */

#endif /* CMACS_DBEXPLORER_H */
