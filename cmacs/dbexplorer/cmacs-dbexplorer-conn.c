/* cmacs-dbexplorer-conn.c --- database explorer model layer

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
   lisp.h.  See cmacs/dbexplorer/cmacs-dbexplorer.h for why.  */

#include <config.h>

#ifdef HAVE_CMACS_DBEXPLORER

#include "cmacs-dbexplorer.h"
#include "cmacs-glib-loop.h"

/* orm.h sets and clears the ORM_INSIDE guard itself, so it is the one
   orm-glib header a consumer includes. */
#include <orm.h>

#include <string.h>

/* ------------------------------------------------------------------ */
/* The connection                                                      */
/* ------------------------------------------------------------------ */

struct _CmacsDbxConn
{
  OrmEngine     *engine;
  OrmConnection *connection;
  OrmInspector  *inspector;      /* built on the first introspection */
  GCancellable  *cancellable;    /* cancels everything in flight at close */
  gchar         *url;            /* already redacted; the secret is not kept */
  gchar         *dialect;
  gint           tag;            /* the integer handle Lisp holds */
  gboolean       read_only;
  gint           tx_depth;       /* explicit transactions this layer opened */
  gulong         state_handler;
};

static const CmacsDbxStreamSink *dbx_stream_sink;
static void (*dbx_state_sink) (int tag, const char *state);

void
cmacs_dbx_set_stream_sink (const CmacsDbxStreamSink *sink)
{
  dbx_stream_sink = sink;
}

const CmacsDbxStreamSink *
cmacs_dbx_stream_sink (void)
{
  return dbx_stream_sink;
}

void
cmacs_dbx_set_state_sink (void (*fn) (int tag, const char *state))
{
  dbx_state_sink = fn;
}

void
cmacs_dbx_emit_state (CmacsDbxConn *conn, const char *state)
{
  if (dbx_state_sink != NULL && conn != NULL && conn->tag >= 0)
    dbx_state_sink (conn->tag, state);
}

/* ------------------------------------------------------------------ */
/* Small conversions                                                   */
/* ------------------------------------------------------------------ */

const char *
cmacs_dbx_value_type_name (int value_type)
{
  switch ((OrmValueType) value_type)
    {
    case ORM_VALUE_INTEGER:  return "integer";
    case ORM_VALUE_FLOAT:    return "float";
    case ORM_VALUE_STRING:   return "string";
    case ORM_VALUE_BLOB:     return "blob";
    case ORM_VALUE_BOOLEAN:  return "boolean";
    case ORM_VALUE_DATETIME: return "datetime";
    case ORM_VALUE_NULL:
    default:                 return "unknown";
    }
}

static const char *
dbx_state_name (OrmConnectionState state)
{
  switch (state)
    {
    case ORM_CONNECTION_CONNECTING: return "connecting";
    case ORM_CONNECTION_IDLE:       return "open";
    case ORM_CONNECTION_BUSY:       return "busy";
    case ORM_CONNECTION_CLOSED:
    default:                        return "closed";
    }
}

void
cmacs_dbx_params_free (CmacsDbxParam *params, int n_params)
{
  int i;

  if (params == NULL)
    return;
  for (i = 0; i < n_params; i++)
    g_free (params[i].text);
  g_free (params);
}

void
cmacs_dbx_page_free (CmacsDbxPage *page)
{
  int row, col;

  if (page == NULL)
    return;

  if (page->cells != NULL)
    {
      for (row = 0; row < page->n_rows; row++)
        {
          if (page->cells[row] == NULL)
            continue;
          for (col = 0; col < page->n_columns; col++)
            g_free (page->cells[row][col]);
          g_free (page->cells[row]);
        }
      g_free (page->cells);
    }

  if (page->columns != NULL)
    {
      for (col = 0; col < page->n_columns; col++)
        {
          g_free (page->columns[col].name);
          g_free (page->columns[col].type_name);
        }
      g_free (page->columns);
    }

  g_free (page->blob_sizes);
  g_free (page);
}

static void
dbx_binding_array_free (CmacsDbxBinding *bindings, int n)
{
  int i;

  if (bindings == NULL)
    return;
  for (i = 0; i < n; i++)
    {
      g_free (bindings[i].name);
      g_free (bindings[i].value.text);
    }
  g_free (bindings);
}

void
cmacs_dbx_edit_ops_free (CmacsDbxEditOp *ops, int n_ops)
{
  int i;

  if (ops == NULL)
    return;
  for (i = 0; i < n_ops; i++)
    {
      g_free (ops[i].schema);
      g_free (ops[i].table);
      dbx_binding_array_free (ops[i].set, ops[i].n_set);
      dbx_binding_array_free (ops[i].where, ops[i].n_where);
    }
  g_free (ops);
}

/* ------------------------------------------------------------------ */
/* The read-only classifier                                            */
/* ------------------------------------------------------------------ */

/* Skip whitespace and comments from *P onwards.

   Repeatedly, because a comment can be followed by whitespace followed
   by another comment, and someone who wants a DELETE past a read-only
   guard will happily prefix it with a block comment, a line comment and
   a newline.  A single pass that stopped after the first comment would
   classify that statement on a first keyword it never reached.  */
static void
dbx_skip_blanks (const char **p)
{
  const char *s = *p;

  for (;;)
    {
      while (*s != '\0' && g_ascii_isspace (*s))
        s++;

      if (s[0] == '-' && s[1] == '-')
        {
          while (*s != '\0' && *s != '\n')
            s++;
          continue;
        }

      if (s[0] == '/' && s[1] == '*')
        {
          const char *close = strstr (s + 2, "*/");

          /* An unterminated block comment swallows the rest of the
             statement, so there is no first keyword to judge.  Leaving
             the cursor on the terminator makes the caller fail closed. */
          if (close == NULL)
            {
              *p = s + strlen (s);
              return;
            }
          s = close + 2;
          continue;
        }

      break;
    }

  *p = s;
}

/* Read the identifier at *P, advancing past it.  Returns NULL at
   anything that is not a bare word -- a quoted identifier, a paren, a
   string literal -- because the caller only ever wants a keyword and
   "not a keyword" has to be distinguishable from "some keyword".  */
static gchar *
dbx_take_word (const char **p)
{
  const char *s = *p;
  const char *start = s;

  while (*s != '\0' && (g_ascii_isalnum (*s) || *s == '_'))
    s++;
  if (s == start)
    return NULL;
  *p = s;
  return g_strndup (start, (gsize) (s - start));
}

static gboolean
dbx_word_is (const gchar *word, const gchar *keyword)
{
  return word != NULL && g_ascii_strcasecmp (word, keyword) == 0;
}

/* Whether a WITH statement's body is a read.

   A common table expression is a prefix, not a statement: `WITH x AS
   (...) SELECT' reads and `WITH x AS (...) DELETE FROM y' writes, and
   the two are the same for everything up to the last close paren.  So
   the CTE list is skipped by counting parentheses -- tracking string
   literals, because a paren inside 'it''s (fine)' is not a paren -- and
   the word after it is what decides.

   Anything this cannot follow confidently is a write.  Failing closed
   costs a refused SELECT; failing open costs a table.  */
static gboolean
dbx_with_is_read_only (const char *p)
{
  int depth = 0;
  gboolean seen_body = FALSE;

  for (;;)
    {
      g_autofree gchar *word = NULL;

      dbx_skip_blanks (&p);
      if (*p == '\0')
        return FALSE;

      if (depth == 0 && seen_body)
        {
          /* Between CTEs the only thing that may follow a definition is
             a comma and another one; anything else is the statement. */
          if (*p == ',')
            {
              p++;
              seen_body = FALSE;
              continue;
            }
          word = dbx_take_word (&p);
          if (dbx_word_is (word, "SELECT") || dbx_word_is (word, "VALUES"))
            return TRUE;
          return FALSE;
        }

      if (*p == '\'' || *p == '"' || *p == '`')
        {
          char quote = *p++;

          while (*p != '\0')
            {
              if (*p == quote)
                {
                  /* A doubled quote is an escaped one, not the end. */
                  if (p[1] == quote)
                    p += 2;
                  else
                    break;
                }
              else
                p++;
            }
          if (*p == '\0')
            return FALSE;
          p++;
          continue;
        }

      if (*p == '(')
        {
          depth++;
          p++;
          continue;
        }

      if (*p == ')')
        {
          depth--;
          p++;
          if (depth < 0)
            return FALSE;
          if (depth == 0)
            seen_body = TRUE;
          continue;
        }

      word = dbx_take_word (&p);
      if (word == NULL)
        p++;                    /* punctuation inside the CTE list */
    }
}

/* The pragmas that report rather than configure even though they take an
   argument.  SQLite spells "read this" and "set this" identically --
   `PRAGMA foreign_keys(1)' is a setter and `PRAGMA table_info(t)' is a
   query -- so an argument list on its own cannot be classified, and the
   introspection ones are named here rather than guessed at.  */
static const char *const dbx_read_only_pragmas[] =
{
  "collation_list", "compile_options", "database_list", "foreign_key_check",
  "foreign_key_list", "function_list", "index_info", "index_list",
  "index_xinfo", "integrity_check", "module_list", "pragma_list",
  "quick_check", "table_info", "table_list", "table_xinfo",
  NULL
};

/* Whether a PRAGMA statement only reads.

   A bare `PRAGMA journal_mode' reports and `PRAGMA journal_mode = WAL'
   sets, so an `=' is decisive.  An argument list is not: it is a setter
   as often as a getter, so a parenthesised pragma is a read only when it
   is one of the introspection pragmas above.  Everything else -- a
   trailing token this does not understand, a name it has not heard
   of -- is a write, because a refused query is a smaller mistake than a
   `PRAGMA writable_schema = ON' that got through.  */
static gboolean
dbx_pragma_is_read_only (const char *p)
{
  g_autofree gchar *name = NULL;
  int i;

  dbx_skip_blanks (&p);

  /* A schema-qualified pragma (`PRAGMA main.journal_mode') is still the
     same pragma; step over the qualifier and judge the rest. */
  for (;;)
    {
      g_free (name);
      name = dbx_take_word (&p);
      if (name == NULL)
        return FALSE;
      dbx_skip_blanks (&p);
      if (*p != '.')
        break;
      p++;
      dbx_skip_blanks (&p);
    }

  if (*p == '\0' || *p == ';')
    return TRUE;

  if (*p != '(')
    return FALSE;

  for (i = 0; dbx_read_only_pragmas[i] != NULL; i++)
    if (g_ascii_strcasecmp (name, dbx_read_only_pragmas[i]) == 0)
      return TRUE;

  return FALSE;
}

int
cmacs_dbx_sql_is_read_only (const char *sql)
{
  const char *p = sql;
  g_autofree gchar *word = NULL;

  if (sql == NULL)
    return 0;

  dbx_skip_blanks (&p);
  word = dbx_take_word (&p);
  if (word == NULL)
    return 0;

  /* The allowlist.  Everything not on it is a write, which is the only
     ordering that is safe as the SQL dialects grow new statements: a new
     keyword nobody here has heard of is refused rather than waved
     through.  A RETURNING trailer changes nothing, because only the
     first keyword is ever consulted -- DELETE ... RETURNING is a DELETE. */
  if (dbx_word_is (word, "SELECT")
      || dbx_word_is (word, "VALUES")
      || dbx_word_is (word, "EXPLAIN")
      || dbx_word_is (word, "SHOW"))
    return 1;

  if (dbx_word_is (word, "WITH"))
    return dbx_with_is_read_only (p) ? 1 : 0;

  if (dbx_word_is (word, "PRAGMA"))
    return dbx_pragma_is_read_only (p) ? 1 : 0;

  return 0;
}

/* ------------------------------------------------------------------ */
/* URLs                                                                */
/* ------------------------------------------------------------------ */

char *
cmacs_dbx_redact_url (const char *url)
{
  const char *scheme_end;
  const char *authority;
  const char *at;
  const char *colon;

  if (url == NULL)
    return NULL;

  scheme_end = strstr (url, "://");
  if (scheme_end == NULL)
    return g_strdup (url);

  authority = scheme_end + 3;

  /* The last `@' before the first `/' of the path ends the userinfo; a
     password is allowed to contain one, and taking the first would leave
     half of it on screen. */
  {
    const char *path = strchr (authority, '/');
    const char *scan = authority;

    at = NULL;
    for (; *scan != '\0' && (path == NULL || scan < path); scan++)
      if (*scan == '@')
        at = scan;
  }

  if (at == NULL)
    return g_strdup (url);

  colon = memchr (authority, ':', (gsize) (at - authority));
  if (colon == NULL)
    return g_strdup (url);

  return g_strdup_printf ("%.*s***%s",
                          (int) (colon - url) + 1, url, at);
}

/* ------------------------------------------------------------------ */
/* Opening                                                             */
/* ------------------------------------------------------------------ */

typedef struct
{
  CmacsDbxConn      *conn;
  CmacsDbxConnectCb  cb;
  guint64            token;
} CmacsDbxConnectJob;

static void
dbx_on_state_changed (OrmConnection *connection, guint old_state,
                      guint new_state, gpointer user_data)
{
  CmacsDbxConn *conn = user_data;

  (void) connection;
  (void) old_state;
  cmacs_dbx_emit_state (conn, dbx_state_name ((OrmConnectionState) new_state));
}

static void
dbx_conn_free (CmacsDbxConn *conn)
{
  if (conn == NULL)
    return;

  if (conn->connection != NULL && conn->state_handler != 0)
    g_signal_handler_disconnect (conn->connection, conn->state_handler);
  g_clear_object (&conn->inspector);
  g_clear_object (&conn->connection);
  g_clear_object (&conn->engine);
  g_clear_object (&conn->cancellable);
  g_free (conn->url);
  g_free (conn->dialect);
  g_free (conn);
}

static void
dbx_on_connected (GObject *source, GAsyncResult *result, gpointer user_data)
{
  CmacsDbxConnectJob *job = user_data;
  CmacsDbxConn *conn = job->conn;
  GError *err = NULL;
  OrmConnection *connection;

  connection = orm_engine_connect_finish (ORM_ENGINE (source), result, &err);
  if (connection == NULL)
    {
      job->cb (job->token, NULL, NULL,
               err && err->message ? err->message : "cannot open the database");
      g_clear_error (&err);
      dbx_conn_free (conn);
      g_free (job);
      return;
    }

  conn->connection = connection;
  conn->state_handler =
    g_signal_connect (connection, "state-changed",
                      G_CALLBACK (dbx_on_state_changed), conn);

  job->cb (job->token, conn, conn->dialect, NULL);
  g_free (job);
}

void
cmacs_dbx_connect_async (const char *url, int read_only,
                         CmacsDbxConnectCb cb, guint64 token)
{
  CmacsDbxConn *conn;
  CmacsDbxConnectJob *job;
  OrmEngine *engine;
  GError *err = NULL;
  GMainContext *context;

  if (cb == NULL)
    return;

  if (url == NULL || *url == '\0')
    {
      cb (token, NULL, NULL, "no database URL");
      return;
    }

  /* Building the engine parses the URL and resolves the driver, which is
     bounded work with no I/O in it; only the handshake is worth being
     asynchronous about, and that is what connect_async covers. */
  engine = orm_engine_new (url, &err);
  if (engine == NULL)
    {
      cb (token, NULL, NULL,
          err && err->message ? err->message : "cannot use that database URL");
      g_clear_error (&err);
      return;
    }

  conn = g_new0 (CmacsDbxConn, 1);
  conn->engine = engine;
  conn->cancellable = g_cancellable_new ();
  conn->url = cmacs_dbx_redact_url (url);
  conn->dialect = g_strdup (orm_dialect_get_name (orm_engine_get_dialect (engine)));
  conn->read_only = read_only ? TRUE : FALSE;
  conn->tag = -1;

  job = g_new0 (CmacsDbxConnectJob, 1);
  job->conn = conn;
  job->cb = cb;
  job->token = token;

  /* The connection adopts whatever context is thread-default when it is
     asked for, and every GTask it later creates completes on the same
     one.  cmacs's GMainContext is a private context driven from Emacs's
     pselect, NOT the global default -- so without this push the replies
     would attach to a context nothing iterates in a batch Emacs and the
     callbacks would simply never arrive.  The push is around one
     non-reentrant call, which is what keeps it clear of the reentrancy
     that made cmacs-glib-loop stop holding it across dispatch. */
  context = cmacs_glib_get_context ();
  if (context != NULL)
    g_main_context_push_thread_default (context);
  orm_engine_connect_async (engine, conn->cancellable, dbx_on_connected, job);
  if (context != NULL)
    g_main_context_pop_thread_default (context);
}

/* Closing releases the database, not the handle object.

   The object becomes a tombstone: its orm-glib half is dropped, its own
   fields stay.  That is deliberate, and it is the only thing that makes
   closing safe.  A close cancels what is in flight, but a cancelled
   asynchronous operation still completes -- later, from the main loop,
   with a pointer to this object in its closure -- and there is no moment
   at which every one of them is known to have done so.  Freeing here
   would hand those completions a dangling pointer; leaving the shell
   behind makes them find a closed connection instead, which every path
   already knows how to report.  The cost is a few dozen bytes per
   connection ever opened, against a class of crash that only shows up
   under load.  */
void
cmacs_dbx_conn_close (CmacsDbxConn *conn)
{
  if (conn == NULL || conn->connection == NULL)
    return;

  /* A stream holds its connection busy until it is drained, so closing
     one out from under a half-read result would block here rather than
     return.  Cancel first, then close. */
  cmacs_dbx_cancel_streams_for (conn);
  g_cancellable_cancel (conn->cancellable);

  if (conn->state_handler != 0)
    {
      g_signal_handler_disconnect (conn->connection, conn->state_handler);
      conn->state_handler = 0;
    }

  orm_connection_close (conn->connection);
  g_clear_object (&conn->inspector);
  g_clear_object (&conn->connection);
  g_clear_object (&conn->engine);
  conn->tx_depth = 0;

  /* Reported before the tag is dropped, so this last event still names
     the handle Lisp was holding; afterwards the object emits nothing,
     which is what stops a completion arriving late from announcing a
     state change on a handle that has since been reissued. */
  cmacs_dbx_emit_state (conn, "closed");
  conn->tag = -1;
}

/* ------------------------------------------------------------------ */
/* Accessors                                                           */
/* ------------------------------------------------------------------ */

const char *
cmacs_dbx_conn_dialect (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->dialect : NULL;
}

const char *
cmacs_dbx_conn_url (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->url : NULL;
}

const char *
cmacs_dbx_conn_state (CmacsDbxConn *conn)
{
  if (conn == NULL || conn->connection == NULL)
    return "closed";
  return dbx_state_name (orm_connection_get_state (conn->connection));
}

int
cmacs_dbx_conn_read_only (CmacsDbxConn *conn)
{
  return (conn != NULL && conn->read_only) ? 1 : 0;
}

void
cmacs_dbx_conn_set_read_only (CmacsDbxConn *conn, int flag)
{
  if (conn != NULL)
    conn->read_only = flag ? TRUE : FALSE;
}

int
cmacs_dbx_conn_tx_depth (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->tx_depth : 0;
}

void
cmacs_dbx_conn_set_tx_depth (CmacsDbxConn *conn, int depth)
{
  if (conn != NULL)
    conn->tx_depth = depth < 0 ? 0 : depth;
}

int
cmacs_dbx_conn_tag (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->tag : -1;
}

void
cmacs_dbx_conn_set_tag (CmacsDbxConn *conn, int tag)
{
  if (conn != NULL)
    conn->tag = tag;
}

void *
cmacs_dbx_conn_orm (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->connection : NULL;
}

void *
cmacs_dbx_conn_cancellable (CmacsDbxConn *conn)
{
  return conn != NULL ? conn->cancellable : NULL;
}

void *
cmacs_dbx_conn_inspector (CmacsDbxConn *conn, char **error)
{
  GError *err = NULL;

  if (error != NULL)
    *error = NULL;
  if (conn == NULL || conn->connection == NULL)
    {
      if (error != NULL)
        *error = g_strdup ("the connection is closed");
      return NULL;
    }

  /* Built once and kept: an inspector owns no state beyond its
     connection, and rebuilding it per expansion of a tree node would run
     the backend's capability probe every time. */
  if (conn->inspector == NULL)
    {
      conn->inspector = orm_inspector_new (conn->connection, &err);
      if (conn->inspector == NULL && error != NULL)
        *error = g_strdup (err && err->message
                           ? err->message
                           : "this backend cannot be introspected");
      g_clear_error (&err);
    }

  return conn->inspector;
}

char *
cmacs_dbx_quote_identifier (CmacsDbxConn *conn, const char *name)
{
  OrmDialect *dialect;

  if (name == NULL)
    name = "";

  /* The dialect doubles the quote character it uses, so a name carrying
     one comes back quoted rather than escaping into the statement.  That
     is the whole reason identifiers go through here and never through a
     printf. */
  if (conn != NULL && conn->engine != NULL)
    {
      dialect = orm_engine_get_dialect (conn->engine);
      if (dialect != NULL)
        return orm_dialect_quote_identifier (dialect, name);
    }

  /* No engine to ask -- fall back on SQL's own double quoting, with any
     embedded quote doubled, which is what every dialect here does for
     the standard form. */
  {
    g_auto(GStrv) parts = g_strsplit (name, "\"", -1);
    g_autofree gchar *inner = g_strjoinv ("\"\"", parts);

    return g_strdup_printf ("\"%s\"", inner);
  }
}

#endif /* HAVE_CMACS_DBEXPLORER */
