/* cmacs-dbexplorer-defuns.c --- Lisp interface to the database explorer

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

/* The Lisp surface.  Two kinds of failure live here and they are
   reported differently on purpose.

   A programming error -- a handle that was never issued, a parameter of
   a type the bridge has no meaning for -- signals `cmacs-dbexplorer-
   error', because it is a bug in the caller and a backtrace is what
   fixes it.

   A database failure -- a syntax error, a refused write, a connection
   that dropped -- arrives inside the reply as (:error . MESSAGE).  Those
   are produced in GLib completion callbacks, where a Lisp signal aborts
   the process instead of unwinding, so they cannot be signals however
   much they read like errors.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "lisp.h"
#include "coding.h"             /* ENCODE_UTF_8 / ENCODE_FILE */
#include "cmacs-dbexplorer.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>

/* Registry: handle == index; a NULL slot is free/closed. */
static GPtrArray *dbx_registry;

int
cmacs_dbx_register_conn (CmacsDbxConn *conn)
{
  guint i;

  if (dbx_registry == NULL)
    dbx_registry = g_ptr_array_new ();

  for (i = 0; i < dbx_registry->len; i++)
    if (g_ptr_array_index (dbx_registry, i) == NULL)
      {
        dbx_registry->pdata[i] = conn;
        cmacs_dbx_conn_set_tag (conn, (int) i);
        return (int) i;
      }

  g_ptr_array_add (dbx_registry, conn);
  cmacs_dbx_conn_set_tag (conn, (int) (dbx_registry->len - 1));
  return (int) (dbx_registry->len - 1);
}

static CmacsDbxConn *
dbx_lookup (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsDbxConn *conn;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (dbx_registry == NULL || h < 0 || h >= (EMACS_INT) dbx_registry->len)
    xsignal2 (Qcmacs_dbexplorer_error,
              build_string ("unknown or closed cmacs-dbexplorer handle"),
              handle);
  conn = g_ptr_array_index (dbx_registry, h);
  if (conn == NULL)
    xsignal2 (Qcmacs_dbexplorer_error,
              build_string ("unknown or closed cmacs-dbexplorer handle"),
              handle);
  return conn;
}

/* ------------------------------------------------------------------ */
/* Lisp to C                                                           */
/* ------------------------------------------------------------------ */

/* A C string owned by GLib, out of a Lisp string encoded as UTF-8.  The
   copy matters: SSDATA points into a Lisp string that the next
   allocation may move out from under a value the model layer keeps. */
static gchar *
dbx_dup_string (Lisp_Object string)
{
  Lisp_Object encoded;

  CHECK_STRING (string);
  encoded = ENCODE_UTF_8 (string);
  return g_strdup (SSDATA (encoded));
}

static gchar *
dbx_dup_string_or_null (Lisp_Object string)
{
  if (NILP (string))
    return NULL;
  return dbx_dup_string (string);
}

/* One bound value.  A Lisp string becomes text, an integer an integer, a
   float a float, and both nil and :null become SQL NULL.  Anything else
   is a caller bug rather than a value the database could have meant, so
   it signals.  */
static void
dbx_param_from_lisp (Lisp_Object value, CmacsDbxParam *param)
{
  memset (param, 0, sizeof *param);

  if (NILP (value) || EQ (value, intern (":null")))
    {
      param->type = CMACS_DBX_PARAM_NULL;
      return;
    }
  if (EQ (value, Qt))
    {
      param->type = CMACS_DBX_PARAM_INTEGER;
      param->integer = 1;
      return;
    }
  if (STRINGP (value))
    {
      param->type = CMACS_DBX_PARAM_STRING;
      param->text = dbx_dup_string (value);
      return;
    }
  if (FIXNUMP (value) || BIGNUMP (value))
    {
      param->type = CMACS_DBX_PARAM_INTEGER;
      param->integer = (long long) check_integer_range (value, INTMAX_MIN,
                                                        INTMAX_MAX);
      return;
    }
  if (FLOATP (value))
    {
      param->type = CMACS_DBX_PARAM_FLOAT;
      param->real = XFLOAT_DATA (value);
      return;
    }

  xsignal2 (Qcmacs_dbexplorer_error,
            build_string ("cannot bind that as a SQL parameter"), value);
}

/* A Lisp sequence of values into a freshly allocated parameter array. */
static CmacsDbxParam *
dbx_params_from_lisp (Lisp_Object params, int *n_params)
{
  ptrdiff_t n;
  ptrdiff_t i;
  CmacsDbxParam *out;

  *n_params = 0;
  if (NILP (params))
    return NULL;

  CHECK_LIST (params);
  n = list_length (params);
  if (n == 0)
    return NULL;

  out = g_new0 (CmacsDbxParam, n);
  for (i = 0; i < n; i++, params = XCDR (params))
    dbx_param_from_lisp (XCAR (params), &out[i]);

  *n_params = (int) n;
  return out;
}

/* An alist of (COLUMN . VALUE) into bindings.  COLUMN is quoted as an
   identifier downstream and VALUE is bound, never interpolated -- which
   is what makes a column called a";DROP TABLE x;-- a column name rather
   than three statements. */
static CmacsDbxBinding *
dbx_bindings_from_lisp (Lisp_Object alist, int *n_bindings)
{
  ptrdiff_t n;
  ptrdiff_t i;
  CmacsDbxBinding *out;

  *n_bindings = 0;
  if (NILP (alist))
    return NULL;

  CHECK_LIST (alist);
  n = list_length (alist);
  if (n == 0)
    return NULL;

  out = g_new0 (CmacsDbxBinding, n);
  for (i = 0; i < n; i++, alist = XCDR (alist))
    {
      Lisp_Object pair = XCAR (alist);

      if (!CONSP (pair))
        xsignal2 (Qcmacs_dbexplorer_error,
                  build_string ("an edit binding must be (COLUMN . VALUE)"),
                  pair);
      out[i].name = dbx_dup_string (XCAR (pair));
      dbx_param_from_lisp (XCDR (pair), &out[i].value);
    }

  *n_bindings = (int) n;
  return out;
}

static int
dbx_op_kind (Lisp_Object op)
{
  if (EQ (op, intern ("update")))
    return CMACS_DBX_OP_UPDATE;
  if (EQ (op, intern ("insert")))
    return CMACS_DBX_OP_INSERT;
  if (EQ (op, intern ("delete")))
    return CMACS_DBX_OP_DELETE;

  xsignal2 (Qcmacs_dbexplorer_error,
            build_string ("unknown edit operation"), op);
}

static CmacsDbxEditOp *
dbx_ops_from_lisp (Lisp_Object ops, int *n_ops)
{
  ptrdiff_t n;
  ptrdiff_t i;
  CmacsDbxEditOp *out;

  *n_ops = 0;
  CHECK_LIST (ops);
  n = list_length (ops);
  if (n == 0)
    return NULL;

  out = g_new0 (CmacsDbxEditOp, n);
  for (i = 0; i < n; i++, ops = XCDR (ops))
    {
      Lisp_Object plist = XCAR (ops);
      Lisp_Object expect;

      out[i].kind = dbx_op_kind (Fplist_get (plist, intern (":op"), Qnil));
      out[i].schema =
        dbx_dup_string_or_null (Fplist_get (plist, intern (":schema"), Qnil));
      out[i].table =
        dbx_dup_string_or_null (Fplist_get (plist, intern (":table"), Qnil));

      /* An insert names its columns with :values and an update with
         :set, which is the vocabulary `cmacs-dbexplorer-edits-to-ops'
         produces; both land in the same array here. */
      if (out[i].kind == CMACS_DBX_OP_INSERT)
        out[i].set =
          dbx_bindings_from_lisp (Fplist_get (plist, intern (":values"), Qnil),
                                  &out[i].n_set);
      else
        out[i].set =
          dbx_bindings_from_lisp (Fplist_get (plist, intern (":set"), Qnil),
                                  &out[i].n_set);

      out[i].where =
        dbx_bindings_from_lisp (Fplist_get (plist, intern (":where"), Qnil),
                                &out[i].n_where);

      expect = Fplist_get (plist, intern (":expect"), Qnil);
      out[i].expect = FIXNUMP (expect) ? (int) XFIXNUM (expect) : -1;
    }

  *n_ops = (int) n;
  return out;
}

static long long
dbx_option_integer (Lisp_Object options, const char *key, long long fallback)
{
  Lisp_Object value;

  if (NILP (options))
    return fallback;
  value = Fplist_get (options, intern (key), Qnil);
  if (FIXNUMP (value))
    return (long long) XFIXNUM (value);
  return fallback;
}

/* ------------------------------------------------------------------ */
/* C to Lisp                                                           */
/* ------------------------------------------------------------------ */

static Lisp_Object
dbx_utf8 (const char *s)
{
  return s ? code_convert_string_norecord (build_unibyte_string (s),
                                           Qutf_8, false)
           : Qnil;
}

static Lisp_Object
dbx_connection_alist (EMACS_INT handle, CmacsDbxConn *conn)
{
  /* The URL is the redacted one the connection kept; the password was
     never stored.  Resolving credentials late is pointless if the
     resolved URL then shows up in a connection listing. */
  return CALLN (Flist,
                Fcons (intern (":handle"), make_fixnum (handle)),
                Fcons (intern (":url"), dbx_utf8 (cmacs_dbx_conn_url (conn))),
                Fcons (intern (":dialect"),
                       dbx_utf8 (cmacs_dbx_conn_dialect (conn))),
                Fcons (intern (":state"),
                       intern (cmacs_dbx_conn_state (conn))),
                Fcons (intern (":read-only"),
                       cmacs_dbx_conn_read_only (conn) ? Qt : Qnil),
                Fcons (intern (":in-transaction"),
                       cmacs_dbx_conn_tx_depth (conn) > 0 ? Qt : Qnil));
}

/* ------------------------------------------------------------------ */
/* Availability                                                        */
/* ------------------------------------------------------------------ */

/* Every failure in this subsystem is signalled as one condition, so Lisp
   can catch the whole surface with a single handler.  The symbol itself
   needs no declaration here: DEFSYM below is what make-docfile scans,
   and globals.h defines the name.  */

DEFUN ("cmacs-dbexplorer-supported-p", Fcmacs_dbexplorer_supported_p,
       Scmacs_dbexplorer_supported_p, 0, 0, 0,
       doc: /* Return non-nil if this build has the database explorer.

This is the runtime companion to `IS-CMACS-DBEXPLORER': the variable says
the subsystem was compiled in, and this says its primitives are actually
reachable.  */)
  (void)
{
  return Qt;
}

/* ------------------------------------------------------------------ */
/* Connections                                                         */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-dbexplorer--connect-async", Fcmacs_dbexplorer__connect_async,
       Scmacs_dbexplorer__connect_async, 3, 3, 0,
       doc: /* Open URL and call CALLBACK with the reply.

READ-ONLY non-nil makes the connection refuse every statement the SQL
classifier does not recognise as a read, whichever primitive it arrives
through.

CALLBACK receives one alist: ((:handle . N) (:dialect . NAME)) on
success, ((:error . MESSAGE)) on failure.  A failed connection is not an
error condition here because the failure is discovered in a GLib
callback, where signalling would abort Emacs rather than unwind.

URL carries the password, if there is one, and it is not kept: the
connection stores a redacted copy for `cmacs-dbexplorer--connection-list'
and nothing else.  */)
  (Lisp_Object url, Lisp_Object read_only, Lisp_Object callback)
{
  g_autofree gchar *c_url = NULL;
  uint64_t token;

  CHECK_STRING (url);
  c_url = dbx_dup_string (url);

  token = cmacs_dispatch_callback_register (callback);
  cmacs_dbx_connect_async (c_url, NILP (read_only) ? 0 : 1,
                           cmacs_dbx_on_connect, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--disconnect", Fcmacs_dbexplorer__disconnect,
       Scmacs_dbexplorer__disconnect, 1, 1, 0,
       doc: /* Close HANDLE and release the connection it refers to.

Any query still running on it is cancelled first, because a stream holds
its connection busy until it is drained and closing under one would wait
rather than return.

The handle is not reusable afterwards, and a later one may be the same
integer -- which is why nothing above this layer keys on a handle.  */)
  (Lisp_Object handle)
{
  EMACS_INT h;
  CmacsDbxConn *conn;

  CHECK_FIXNUM (handle);
  h = XFIXNUM (handle);
  if (dbx_registry == NULL || h < 0 || h >= (EMACS_INT) dbx_registry->len)
    return Qnil;

  conn = g_ptr_array_index (dbx_registry, h);
  if (conn == NULL)
    return Qnil;

  /* Cleared before the close, not after: closing reports the state
     change, that report reaches Lisp, and Lisp may well ask for the
     connection list while it is being told. */
  dbx_registry->pdata[h] = NULL;
  cmacs_dbx_conn_close (conn);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--connection-list", Fcmacs_dbexplorer__connection_list,
       Scmacs_dbexplorer__connection_list, 0, 0, 0,
       doc: /* Return every connection the C layer holds, as a list of alists.

Each alist carries :handle, :url, :dialect, :state, :read-only and
:in-transaction.  The URL has any password replaced by `***'.

This is what the model reconciles against: a struct claiming to be open
whose handle is not in this list belongs to a connection the server, or a
C-side failure, already dropped.  */)
  (void)
{
  Lisp_Object out = Qnil;
  guint i;

  if (dbx_registry == NULL)
    return Qnil;

  for (i = dbx_registry->len; i > 0; i--)
    {
      CmacsDbxConn *conn = g_ptr_array_index (dbx_registry, i - 1);

      if (conn != NULL)
        out = Fcons (dbx_connection_alist ((EMACS_INT) (i - 1), conn), out);
    }
  return out;
}

DEFUN ("cmacs-dbexplorer--connection-info", Fcmacs_dbexplorer__connection_info,
       Scmacs_dbexplorer__connection_info, 1, 1, 0,
       doc: /* Return what is known about HANDLE, as one alist.
The same shape `cmacs-dbexplorer--connection-list' returns per entry.  */)
  (Lisp_Object handle)
{
  CmacsDbxConn *conn = dbx_lookup (handle);

  return dbx_connection_alist (XFIXNUM (handle), conn);
}

DEFUN ("cmacs-dbexplorer--set-read-only", Fcmacs_dbexplorer__set_read_only,
       Scmacs_dbexplorer__set_read_only, 2, 2, 0,
       doc: /* Make HANDLE refuse writes when FLAG is non-nil.

The guard is the SQL classifier, applied to every statement on both the
query and the execute path.  It allows SELECT, VALUES, EXPLAIN, SHOW, a
WITH whose body is a SELECT, and the pragmas that only report; anything
else, including anything it cannot classify confidently, is a write.  */)
  (Lisp_Object handle, Lisp_Object flag)
{
  cmacs_dbx_conn_set_read_only (dbx_lookup (handle), NILP (flag) ? 0 : 1);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--quote-identifier",
       Fcmacs_dbexplorer__quote_identifier,
       Scmacs_dbexplorer__quote_identifier, 2, 2, 0,
       doc: /* Return NAME quoted as an identifier in HANDLE's dialect.

The dialect doubles whatever quote character it uses, so a name that
contains one comes back as a quoted name rather than as an escape out of
the statement -- which is what makes this safe for a name that came from
the database, or from someone who called a table a";DROP TABLE x;--.  */)
  (Lisp_Object handle, Lisp_Object name)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_name = NULL;
  g_autofree gchar *quoted = NULL;

  CHECK_STRING (name);
  c_name = dbx_dup_string (name);
  quoted = cmacs_dbx_quote_identifier (conn, c_name);
  return dbx_utf8 (quoted);
}

/* ------------------------------------------------------------------ */
/* Introspection                                                       */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-dbexplorer--schemas-async", Fcmacs_dbexplorer__schemas_async,
       Scmacs_dbexplorer__schemas_async, 2, 2, 0,
       doc: /* Read HANDLE's schema names and call CALLBACK with the reply.

The reply is ((:schemas . VECTOR-OF-STRINGS)), or ((:error . MESSAGE)).
A dialect with no schemas at all -- SQLite -- answers with whatever its
inspector considers the default, which may be an empty vector.  */)
  (Lisp_Object handle, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  uint64_t token = cmacs_dispatch_callback_register (callback);

  cmacs_dbx_schemas_async (conn, cmacs_dbx_on_schemas, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--tables-async", Fcmacs_dbexplorer__tables_async,
       Scmacs_dbexplorer__tables_async, 3, 3, 0,
       doc: /* Read the relations in SCHEMA on HANDLE, then call CALLBACK.

SCHEMA of nil means the default one.  The reply is ((:relations . VEC)),
where each element is a plist (:name STRING :kind SYMBOL) and the kind is
`table' or `view'; or ((:error . MESSAGE)).  */)
  (Lisp_Object handle, Lisp_Object schema, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_schema = dbx_dup_string_or_null (schema);
  uint64_t token = cmacs_dispatch_callback_register (callback);

  cmacs_dbx_tables_async (conn, c_schema, cmacs_dbx_on_tables, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--table-info-async",
       Fcmacs_dbexplorer__table_info_async,
       Scmacs_dbexplorer__table_info_async, 4, 4, 0,
       doc: /* Read everything about TABLE in SCHEMA on HANDLE.

CALLBACK receives one alist carrying all four of

  (:columns . VECTOR)       plists (:name :type :type-name :nullable
                            :default :primary-key :ordinal)
  (:primary-key . VECTOR)   the key columns, in key order
  (:indexes . VECTOR)       plists (:name :unique :columns)
  (:foreign-keys . VECTOR)  plists (:name :columns :references
                            :ref-schema :ref-columns)

or ((:error . MESSAGE)).

All four in one reply because all four are wanted together -- the tree
draws them, the row editor needs the key to name a row with, and SQL
completion reads the columns on every keystroke -- and asking three times
is three chances to be told something different by a schema that changed
in between.

An empty :primary-key means the table has no key, which is what makes its
rows uneditable: without one there is no way to say which row you
meant.  */)
  (Lisp_Object handle, Lisp_Object schema, Lisp_Object table,
   Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_schema = dbx_dup_string_or_null (schema);
  g_autofree gchar *c_table = NULL;
  uint64_t token;

  CHECK_STRING (table);
  c_table = dbx_dup_string (table);

  token = cmacs_dispatch_callback_register (callback);
  cmacs_dbx_table_info_async (conn, c_schema, c_table,
                              cmacs_dbx_on_table_info, token);
  return Qnil;
}

/* ------------------------------------------------------------------ */
/* Statements                                                          */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-dbexplorer--query-async", Fcmacs_dbexplorer__query_async,
       Scmacs_dbexplorer__query_async, 4, 4, 0,
       doc: /* Run SQL on HANDLE and return the integer stream id at once.

PARAMS is a list of values bound to the statement's placeholders: a
string, an integer, a float, or nil or `:null' for SQL NULL.  OPTIONS is
a plist; `:max-rows' caps how many rows are read, and the terminating
event says whether the cap was reached.

Rows do not come back from here.  They arrive on the session's stream
callback -- see `cmacs-dbexplorer--set-stream-callback' -- as (:meta
COLUMNS), then (:rows VECTOR) a batch at a time, then exactly one of
(:end ...) or (:error MESSAGE).

A statement refused before it runs, on a read-only connection or a closed
handle, still returns an id and reports itself as that stream's :error
event.  Deferring it is what makes it visible: the caller registers its
handler for the id after this returns, so a refusal reported here and now
would be published before anyone was listening.  */)
  (Lisp_Object handle, Lisp_Object sql, Lisp_Object params,
   Lisp_Object options)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_sql = NULL;
  CmacsDbxParam *c_params;
  int n_params = 0;
  long long id;

  CHECK_STRING (sql);
  c_sql = dbx_dup_string (sql);
  c_params = dbx_params_from_lisp (params, &n_params);

  id = cmacs_dbx_query_async (conn, c_sql, c_params, n_params,
                              dbx_option_integer (options, ":max-rows", 0));
  cmacs_dbx_params_free (c_params, n_params);

  cmacs_dbx_events_track_stream (id);
  return make_int (id);
}

DEFUN ("cmacs-dbexplorer--export-async", Fcmacs_dbexplorer__export_async,
       Scmacs_dbexplorer__export_async, 5, 5, 0,
       doc: /* Write SQL's rows from HANDLE to PATH in FORMAT.

FORMAT is "csv" or "json".  OPTIONS is a plist and takes `:max-rows'.
Returns the integer stream id at once; the export reports (:progress N)
with the rows read so far as it goes, and finishes with (:end ...) or
(:error MESSAGE) on the session's stream callback.

No (:meta) or (:rows) event is sent for an export: the rows are going to
a file, and publishing them to a view as well would be a second copy of a
result nobody asked to see.  */)
  (Lisp_Object handle, Lisp_Object sql, Lisp_Object format, Lisp_Object path,
   Lisp_Object options)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_sql = NULL;
  g_autofree gchar *c_format = NULL;
  g_autofree gchar *c_path = NULL;
  Lisp_Object encoded_path;
  long long id;

  CHECK_STRING (sql);
  CHECK_STRING (format);
  CHECK_STRING (path);

  c_sql = dbx_dup_string (sql);
  c_format = dbx_dup_string (format);
  encoded_path = ENCODE_FILE (Fexpand_file_name (path, Qnil));
  c_path = g_strdup (SSDATA (encoded_path));

  id = cmacs_dbx_export_async (conn, c_sql, c_format, c_path,
                               dbx_option_integer (options, ":max-rows", 0));
  cmacs_dbx_events_track_stream (id);
  return make_int (id);
}

DEFUN ("cmacs-dbexplorer--cancel", Fcmacs_dbexplorer__cancel,
       Scmacs_dbexplorer__cancel, 1, 1, 0,
       doc: /* Stop the stream called STREAM-ID and forget it.

Silent about an id that has already finished: a cancel racing the last
batch is the normal case, not a mistake.  Cancelling is best-effort and
backend-dependent -- SQLite and PostgreSQL really do stop early, MySQL
finishes the statement and discards it -- but the connection is usable
immediately either way.  */)
  (Lisp_Object stream_id)
{
  CHECK_INTEGER (stream_id);
  cmacs_dbx_cancel ((long long) check_integer_range (stream_id, INTMAX_MIN,
                                                     INTMAX_MAX));
  cmacs_dbx_events_forget_stream
    ((long long) check_integer_range (stream_id, INTMAX_MIN, INTMAX_MAX));
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--execute-async", Fcmacs_dbexplorer__execute_async,
       Scmacs_dbexplorer__execute_async, 4, 4, 0,
       doc: /* Run SQL on HANDLE for its effect and call CALLBACK.

PARAMS binds the statement's placeholders, as in
`cmacs-dbexplorer--query-async'.  The reply is
((:rows-affected . N) (:last-insert-rowid . N)) or ((:error . MESSAGE)).

The same read-only classifier guards this path as guards the query path.
A connection that refused SELECTs but ran DELETEs because the caller
reached for the other primitive would be worse than no guard at all,
since it would look like one.  */)
  (Lisp_Object handle, Lisp_Object sql, Lisp_Object params,
   Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_sql = NULL;
  CmacsDbxParam *c_params;
  int n_params = 0;
  uint64_t token;

  CHECK_STRING (sql);
  c_sql = dbx_dup_string (sql);
  c_params = dbx_params_from_lisp (params, &n_params);

  token = cmacs_dispatch_callback_register (callback);
  cmacs_dbx_execute_async (conn, c_sql, c_params, n_params,
                           cmacs_dbx_on_execute, token);
  cmacs_dbx_params_free (c_params, n_params);
  return Qnil;
}

/* ------------------------------------------------------------------ */
/* Transactions                                                        */
/* ------------------------------------------------------------------ */

DEFUN ("cmacs-dbexplorer--begin-async", Fcmacs_dbexplorer__begin_async,
       Scmacs_dbexplorer__begin_async, 2, 2, 0,
       doc: /* Open a transaction on HANDLE and call CALLBACK.
The reply is ((:ok . t)) or ((:error . MESSAGE)).  */)
  (Lisp_Object handle, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  uint64_t token = cmacs_dispatch_callback_register (callback);

  cmacs_dbx_begin_async (conn, cmacs_dbx_on_done, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--commit-async", Fcmacs_dbexplorer__commit_async,
       Scmacs_dbexplorer__commit_async, 2, 2, 0,
       doc: /* Commit HANDLE's transaction and call CALLBACK.
The reply is ((:ok . t)) or ((:error . MESSAGE)).  */)
  (Lisp_Object handle, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  uint64_t token = cmacs_dispatch_callback_register (callback);

  cmacs_dbx_commit_async (conn, cmacs_dbx_on_done, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--rollback-async", Fcmacs_dbexplorer__rollback_async,
       Scmacs_dbexplorer__rollback_async, 3, 3, 0,
       doc: /* Roll HANDLE back and call CALLBACK.

SAVEPOINT of nil rolls the whole transaction back and ends it; a named
one undoes only what happened since that savepoint and leaves the
transaction open.  The reply is ((:ok . t)) or ((:error . MESSAGE)).  */)
  (Lisp_Object handle, Lisp_Object savepoint, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_savepoint = dbx_dup_string_or_null (savepoint);
  uint64_t token = cmacs_dispatch_callback_register (callback);

  cmacs_dbx_rollback_async (conn, c_savepoint, cmacs_dbx_on_done, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--savepoint-async", Fcmacs_dbexplorer__savepoint_async,
       Scmacs_dbexplorer__savepoint_async, 3, 3, 0,
       doc: /* Create savepoint NAME on HANDLE and call CALLBACK.

NAME is quoted as an identifier, so it may be anything the dialect can
name.  A savepoint outside a transaction starts one.  The reply is
((:ok . t)) or ((:error . MESSAGE)).  */)
  (Lisp_Object handle, Lisp_Object name, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  g_autofree gchar *c_name = NULL;
  uint64_t token;

  CHECK_STRING (name);
  c_name = dbx_dup_string (name);

  token = cmacs_dispatch_callback_register (callback);
  cmacs_dbx_savepoint_async (conn, c_name, cmacs_dbx_on_done, token);
  return Qnil;
}

DEFUN ("cmacs-dbexplorer--apply-edits-async",
       Fcmacs_dbexplorer__apply_edits_async,
       Scmacs_dbexplorer__apply_edits_async, 3, 3, 0,
       doc: /* Apply OPS to HANDLE as one transaction and call CALLBACK.

OPS is a list of plists, as `cmacs-dbexplorer-edits-to-ops' produces:

  (:op update :schema S :table T :set ALIST :where ALIST :expect 1)
  (:op insert :schema S :table T :values ALIST)
  (:op delete :schema S :table T :where ALIST :expect 1)

Each ALIST is (COLUMN . VALUE).  Column, table and schema names are
quoted by the dialect; values are bound as parameters, never
interpolated, not even numbers.

The whole batch is one transaction -- a SAVEPOINT rather than a nested
BEGIN when a transaction is already open, since SQL has no nested BEGIN
and a second one either errors or silently commits the first.

`:expect' is the guard the path exists for.  After each statement the
number of rows it touched is compared with what was expected, and a
mismatch rolls the entire batch back: a WHERE clause matching no rows, or
two, means the row identity the view used is not the one the database
has, and committing on that assumption is how the wrong row gets edited.
An update or a delete with no :where is refused outright, because that is
every row in the table.

The reply is ((:applied . N)) on success, or
((:error . MESSAGE) (:failed-index . I)) naming which op failed and what
it actually touched.  */)
  (Lisp_Object handle, Lisp_Object ops, Lisp_Object callback)
{
  CmacsDbxConn *conn = dbx_lookup (handle);
  CmacsDbxEditOp *c_ops;
  int n_ops = 0;
  uint64_t token;

  c_ops = dbx_ops_from_lisp (ops, &n_ops);
  token = cmacs_dispatch_callback_register (callback);
  /* Ownership of the ops passes to the model, which holds them for the
     length of the batch and frees them when it reports. */
  cmacs_dbx_apply_edits_async (conn, c_ops, n_ops, cmacs_dbx_on_apply, token);
  return Qnil;
}

void
syms_of_cmacs_dbexplorer_defuns (void)
{
  DEFSYM (Qcmacs_dbexplorer_error, "cmacs-dbexplorer-error");
  Fput (Qcmacs_dbexplorer_error, Qerror_conditions,
	list2 (Qcmacs_dbexplorer_error, Qerror));
  Fput (Qcmacs_dbexplorer_error, Qerror_message,
	build_string ("CMacs database explorer error"));

  defsubr (&Scmacs_dbexplorer_supported_p);
  defsubr (&Scmacs_dbexplorer__connect_async);
  defsubr (&Scmacs_dbexplorer__disconnect);
  defsubr (&Scmacs_dbexplorer__connection_list);
  defsubr (&Scmacs_dbexplorer__connection_info);
  defsubr (&Scmacs_dbexplorer__set_read_only);
  defsubr (&Scmacs_dbexplorer__quote_identifier);
  defsubr (&Scmacs_dbexplorer__schemas_async);
  defsubr (&Scmacs_dbexplorer__tables_async);
  defsubr (&Scmacs_dbexplorer__table_info_async);
  defsubr (&Scmacs_dbexplorer__query_async);
  defsubr (&Scmacs_dbexplorer__export_async);
  defsubr (&Scmacs_dbexplorer__cancel);
  defsubr (&Scmacs_dbexplorer__execute_async);
  defsubr (&Scmacs_dbexplorer__begin_async);
  defsubr (&Scmacs_dbexplorer__commit_async);
  defsubr (&Scmacs_dbexplorer__rollback_async);
  defsubr (&Scmacs_dbexplorer__savepoint_async);
  defsubr (&Scmacs_dbexplorer__apply_edits_async);
}

#endif /* HAVE_CMACS_DBEXPLORER */
