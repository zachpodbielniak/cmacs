/* cmacs-lql-env.c --- the LQL environment cmacs queries run in

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

SPDX-License-Identifier: AGPL-3.0-or-later

   The model half of the LQL subsystem.  It sees <lql.h> and the lql
   tools headers, never lisp.h (cmacs-lql.h explains the split), and it
   owns exactly one LqlEnvironment for the whole process:

   - the language's built-ins (lql_environment_new);
   - every source the `lql' program offers, registered through
     liblql-tools exactly as the program does: read/files of every
     format, git_*, exec and the command definitions (built-in and
     ~/.config/lql/commands), the journal, coredumps, Kubernetes, sql_*;
   - the user's ~/.config/lql aliases;
   - one LqlMemorySource per Elisp-defined source, whose table is
     replaced by a fresh snapshot before each run that names it.

   Locking.  ENV_LOCK guards the environment.  A query run holds it from
   installing its snapshots until its table is built, so a snapshot can
   never be swapped under a running fetch.  Everything the editor calls
   synchronously only TRIES the lock (CMACS_LQL_BUSY otherwise), because
   the editor thread must never wait on a git log.  Source definitions go
   on PENDING (its own small lock) and are applied by the next holder of
   ENV_LOCK, so `cmacs-lql-define-source' never waits either.  */

#include <config.h>

#ifdef HAVE_CMACS_LQL

#include "cmacs-lql.h"

#include <string.h>
#include <lql.h>
#include <lql-tool-environment.h>
#include <lql-tool-formats.h>
#include <sql/lql-tool-sql.h>

/* ── State ──────────────────────────────────────────────────────── */

static GMutex env_lock;
static LqlEnvironment *env;
static LqlFormatRegistry *env_registry;
static LqlFormatContext *env_context;

/* name -> LqlMemorySource, the Elisp-defined sources.  ENV_LOCK.  */
static GHashTable *env_memory_sources;

/* name -> column spec JSON, the declared schema of each Elisp source,
   kept so every snapshot table gets the declared columns in order even
   when it has no rows.  ENV_LOCK.  */
static GHashTable *env_source_columns;

/* Definitions waiting for ENV_LOCK.  PENDING_LOCK.  */
typedef struct
{
  gchar *name;
  gchar *columns_json;
  gchar *description;
} CmacsLqlPendingSource;

static GMutex pending_lock;
static GPtrArray *pending_sources;

static void
pending_source_free (gpointer data)
{
  CmacsLqlPendingSource *p = data;

  g_free (p->name);
  g_free (p->columns_json);
  g_free (p->description);
  g_free (p);
}

/* ── Small JSON writers ─────────────────────────────────────────── */

/* Append S to OUT as a JSON string literal.  */
static void
json_append_string (GString *out, const gchar *s)
{
  const guchar *p;

  g_string_append_c (out, '"');
  for (p = (const guchar *) (s != NULL ? s : ""); *p != '\0'; p++)
    {
      switch (*p)
        {
        case '"':  g_string_append (out, "\\\""); break;
        case '\\': g_string_append (out, "\\\\"); break;
        case '\n': g_string_append (out, "\\n"); break;
        case '\r': g_string_append (out, "\\r"); break;
        case '\t': g_string_append (out, "\\t"); break;
        default:
          if (*p < 0x20)
            g_string_append_printf (out, "\\u%04x", (guint) *p);
          else
            g_string_append_c (out, (gchar) *p);
        }
    }
  g_string_append_c (out, '"');
}

/* ── Building the environment ───────────────────────────────────── */

/* Register everything the `lql' program registers, in its order:
   sources, then sql, then the user's aliases last so an alias can never
   take the name of a source or command.  Caller holds ENV_LOCK.  */
static gboolean
env_build (GError **error)
{
  g_autoptr (LqlEnvironment) e = lql_environment_new ();
  g_autoptr (LqlFormatRegistry) registry = lql_tool_format_registry_new ();
  g_autoptr (LqlFormatContext) context = lql_format_context_new ();

  lql_format_context_set_infer (context, TRUE);
  if (!lql_tool_register_sources (e, registry, context, error))
    return FALSE;
  if (!lql_tool_register_sql (e, NULL, error))
    return FALSE;
  if (!lql_tool_load_user_aliases (e, error))
    return FALSE;

  env = g_steal_pointer (&e);
  env_registry = g_steal_pointer (&registry);
  env_context = g_steal_pointer (&context);
  env_memory_sources = g_hash_table_new_full (g_str_hash, g_str_equal,
                                              g_free, g_object_unref);
  env_source_columns = g_hash_table_new_full (g_str_hash, g_str_equal,
                                              g_free, g_free);
  return TRUE;
}

/**
 * cmacs_lql_env_ensure:
 * @error: return location for a #GError
 *
 * Build the process-wide environment on first use.  Blocks on the
 * environment lock only the first time, before any query can hold it.
 *
 * Returns: %TRUE when the environment exists.
 */
gboolean
cmacs_lql_env_ensure (GError **error)
{
  gboolean ok = TRUE;

  g_mutex_lock (&env_lock);
  if (env == NULL)
    ok = env_build (error);
  g_mutex_unlock (&env_lock);
  return ok;
}

/* Parse a column spec, a JSON array of {"name":..,"type":..} objects,
   into an empty table with those columns.  Unknown or missing types are
   Any.  Returns NULL on a malformed spec.  */
static LqlTable *
table_from_columns (const gchar *columns_json, GError **error)
{
  g_autoptr (LqlValue) spec = lql_json_parse (columns_json, -1, error);
  g_autoptr (LqlTable) table = NULL;
  GPtrArray *items;
  guint i;

  if (spec == NULL)
    return NULL;
  if (lql_value_get_value_type (spec) != LQL_VALUE_TYPE_ARRAY)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                   "a source's columns must be a JSON array");
      return NULL;
    }
  table = lql_table_new ();
  items = lql_value_get_array (spec);
  for (i = 0; items != NULL && i < items->len; i++)
    {
      LqlValue *item = g_ptr_array_index (items, i);
      LqlRecord *rec;
      LqlValue *name, *type;
      LqlValueType vt = LQL_VALUE_TYPE_ANY;

      if (lql_value_get_value_type (item) != LQL_VALUE_TYPE_RECORD)
        continue;
      rec = lql_value_get_record (item);
      name = lql_record_get (rec, "name");
      type = lql_record_get (rec, "type");
      if (name == NULL
          || lql_value_get_value_type (name) != LQL_VALUE_TYPE_STRING)
        continue;
      if (type != NULL
          && lql_value_get_value_type (type) == LQL_VALUE_TYPE_STRING
          && !lql_value_type_from_string (lql_value_get_string (type), &vt))
        vt = LQL_VALUE_TYPE_ANY;
      lql_table_add_column (table, lql_value_get_string (name), vt);
    }
  return g_steal_pointer (&table);
}

/* Apply queued source definitions.  Caller holds ENV_LOCK.  A definition
   whose name is already an Elisp source replaces its schema; one that
   collides with a built-in source is dropped with a warning (a user's
   `buffers' must not shadow liblql's `read').  */
static void
env_apply_pending (void)
{
  g_autoptr (GPtrArray) todo = NULL;
  guint i;

  g_mutex_lock (&pending_lock);
  todo = g_steal_pointer (&pending_sources);
  g_mutex_unlock (&pending_lock);
  if (todo == NULL)
    return;

  for (i = 0; i < todo->len; i++)
    {
      CmacsLqlPendingSource *p = g_ptr_array_index (todo, i);
      g_autoptr (GError) err = NULL;
      g_autoptr (LqlTable) table = table_from_columns (p->columns_json, &err);
      LqlMemorySource *existing;

      if (table == NULL)
        {
          g_warning ("cmacs-lql: source %s: %s", p->name,
                     err != NULL ? err->message : "bad column spec");
          continue;
        }
      existing = g_hash_table_lookup (env_memory_sources, p->name);
      if (existing != NULL)
        lql_memory_source_set_table (existing, table);
      else
        {
          g_autoptr (LqlMemorySource) src = NULL;

          if (lql_environment_lookup_source (env, p->name) != NULL
              || lql_environment_lookup_source_command (env, p->name) != NULL)
            {
              g_warning ("cmacs-lql: source %s already exists in LQL; "
                         "not shadowing it", p->name);
              continue;
            }
          src = lql_memory_source_new (p->name, table);
          if (!lql_environment_register_source (env, LQL_SOURCE (src), &err))
            {
              g_warning ("cmacs-lql: source %s: %s", p->name, err->message);
              continue;
            }
          g_hash_table_insert (env_memory_sources, g_strdup (p->name),
                               g_steal_pointer (&src));
        }
      g_hash_table_insert (env_source_columns, g_strdup (p->name),
                           g_strdup (p->columns_json));
    }
}

/**
 * cmacs_lql_env_define_source:
 * @name: the source's name in queries
 * @columns_json: its columns, a JSON array of {"name","type"} objects
 * @description: (nullable): a one-line description
 *
 * Define (or redefine) an Elisp-backed source.  Never blocks: the
 * definition is applied by the next holder of the environment lock.
 */
void
cmacs_lql_env_define_source (const gchar *name, const gchar *columns_json,
                             const gchar *description)
{
  CmacsLqlPendingSource *p = g_new0 (CmacsLqlPendingSource, 1);

  p->name = g_strdup (name);
  p->columns_json = g_strdup (columns_json);
  p->description = g_strdup (description);
  g_mutex_lock (&pending_lock);
  if (pending_sources == NULL)
    pending_sources = g_ptr_array_new_with_free_func (pending_source_free);
  g_ptr_array_add (pending_sources, p);
  g_mutex_unlock (&pending_lock);

  /* Apply now if nobody is running a query.  */
  if (env != NULL && g_mutex_trylock (&env_lock))
    {
      env_apply_pending ();
      g_mutex_unlock (&env_lock);
    }
}

/* ── Snapshots ──────────────────────────────────────────────────── */

void
cmacs_lql_snapshot_free (gpointer data)
{
  CmacsLqlSnapshot *s = data;

  if (s == NULL)
    return;
  g_free (s->name);
  g_free (s->rows_json);
  g_free (s);
}

/* Coerce V to the declared column TYPE where Lisp cannot say it
   directly: a number for a Timestamp is seconds since the epoch (what
   `float-time' returns), a number for a Duration is seconds.  Anything
   else is kept as it is.  Returns a new reference.  */
static LqlValue *
coerce_value (LqlValue *v, LqlValueType type)
{
  LqlValueType have = lql_value_get_value_type (v);

  if ((type == LQL_VALUE_TYPE_TIMESTAMP || type == LQL_VALUE_TYPE_DURATION)
      && (have == LQL_VALUE_TYPE_INT || have == LQL_VALUE_TYPE_DOUBLE))
    {
      gdouble seconds = 0;
      gint64 usec;

      lql_value_get_number (v, &seconds);
      usec = (gint64) (seconds * (gdouble) G_USEC_PER_SEC);

      return type == LQL_VALUE_TYPE_TIMESTAMP
        ? lql_value_new_timestamp (usec)
        : lql_value_new_duration (usec);
    }
  return lql_value_ref (v);
}

/* Build NAME's snapshot table from ROWS_JSON (an array of objects),
   with the declared columns first in their declared order.  Caller
   holds ENV_LOCK.  */
static LqlTable *
snapshot_table (const gchar *name, const gchar *rows_json, GError **error)
{
  const gchar *columns = g_hash_table_lookup (env_source_columns, name);
  g_autoptr (LqlTable) table = NULL;
  g_autoptr (LqlValue) rows = NULL;
  GPtrArray *items;
  guint i, c;

  table = table_from_columns (columns != NULL ? columns : "[]", error);
  if (table == NULL)
    return NULL;
  rows = lql_json_parse (rows_json, -1, error);
  if (rows == NULL)
    return NULL;
  if (lql_value_get_value_type (rows) != LQL_VALUE_TYPE_ARRAY)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                   "source %s: rows must be a JSON array", name);
      return NULL;
    }
  items = lql_value_get_array (rows);
  for (i = 0; items != NULL && i < items->len; i++)
    {
      LqlValue *item = g_ptr_array_index (items, i);
      LqlRecord *in;
      g_autoptr (LqlRecord) out = NULL;

      if (lql_value_get_value_type (item) != LQL_VALUE_TYPE_RECORD)
        continue;
      in = lql_value_get_record (item);
      out = lql_record_new ();
      /* Declared columns first, coerced, NULL when absent.  */
      for (c = 0; c < lql_table_get_n_columns (table); c++)
        {
          LqlColumn *col = lql_table_get_column (table, c);
          LqlValue *v = lql_record_get (in, lql_column_get_name (col));

          lql_record_take (out, lql_column_get_name (col),
                           v != NULL
                           ? coerce_value (v, lql_column_get_column_type (col))
                           : lql_value_new_null ());
        }
      /* Then any extra fields the snapshot carries, as they are.  */
      for (c = 0; c < lql_record_get_n_fields (in); c++)
        {
          const gchar *field = lql_record_get_field_name (in, c);

          if (!lql_record_has (out, field))
            lql_record_set (out, field, lql_record_get_field_value (in, c));
        }
      lql_table_take_row (table, g_steal_pointer (&out));
    }
  return g_steal_pointer (&table);
}

/* ── Results ────────────────────────────────────────────────────── */

void
cmacs_lql_result_clear (CmacsLqlResult *result)
{
  g_clear_pointer (&result->json, g_free);
  g_clear_pointer (&result->text, g_free);
  result->n_rows = 0;
  result->elapsed_us = 0;
}

/* TABLE as {"columns":[{"name","type"}],"rows":[[...]],"total":N},
   at most MAX_ROWS rows (0: all).  Cells are liblql's own JSON for the
   value, so arrays and records survive structurally.  */
static gchar *
table_to_json (LqlTable *table, guint max_rows)
{
  GString *out = g_string_new ("{\"columns\":[");
  guint n_cols = lql_table_get_n_columns (table);
  guint n_rows = lql_table_get_n_rows (table);
  guint limit = (max_rows > 0 && max_rows < n_rows) ? max_rows : n_rows;
  guint r, c;

  for (c = 0; c < n_cols; c++)
    {
      LqlColumn *col = lql_table_get_column (table, c);

      if (c > 0)
        g_string_append_c (out, ',');
      g_string_append (out, "{\"name\":");
      json_append_string (out, lql_column_get_name (col));
      g_string_append (out, ",\"type\":");
      json_append_string (out, lql_value_type_to_string
                                 (lql_column_get_column_type (col)));
      g_string_append_c (out, '}');
    }
  g_string_append (out, "],\"rows\":[");
  for (r = 0; r < limit; r++)
    {
      LqlRecord *row = lql_table_get_row (table, r);

      if (r > 0)
        g_string_append_c (out, ',');
      g_string_append_c (out, '[');
      for (c = 0; c < n_cols; c++)
        {
          LqlValue *v = lql_record_get (row, lql_column_get_name
                                               (lql_table_get_column (table, c)));

          if (c > 0)
            g_string_append_c (out, ',');
          if (v == NULL)
            g_string_append (out, "null");
          else
            {
              g_autofree gchar *cell = lql_value_to_json (v);

              g_string_append (out, cell);
            }
        }
      g_string_append_c (out, ']');
    }
  g_string_append_printf (out, "],\"total\":%u}", n_rows);
  return g_string_free (out, FALSE);
}

/**
 * cmacs_lql_env_run:
 * @text: the query
 * @snapshots: (element-type CmacsLqlSnapshot) (nullable): Elisp source
 *   tables to install first
 * @max_rows: rows to put in the JSON (0: all)
 * @text_width: when non-zero, also render the table as text this wide
 * @timeout_ms: the run's time limit (0: liblql's default)
 * @cancellable: (nullable): cancels the run
 * @out: (out caller-allocates): the result
 * @error: return location for a #GError
 *
 * Run one query.  Blocks the calling thread for the whole run, holding
 * the environment lock -- call it from the worker, never the editor.
 *
 * Returns: %TRUE on success.
 */
gboolean
cmacs_lql_env_run (const gchar *text, GPtrArray *snapshots, guint max_rows,
                   guint text_width, gint64 timeout_ms,
                   GCancellable *cancellable, CmacsLqlResult *out,
                   GError **error)
{
  g_autoptr (LqlTable) table = NULL;
  gint64 started;
  gint64 old_timeout = 0;
  guint i;

  memset (out, 0, sizeof *out);
  if (!cmacs_lql_env_ensure (error))
    return FALSE;

  g_mutex_lock (&env_lock);
  env_apply_pending ();

  /* Install the snapshots this query names.  */
  for (i = 0; snapshots != NULL && i < snapshots->len; i++)
    {
      CmacsLqlSnapshot *s = g_ptr_array_index (snapshots, i);
      LqlMemorySource *src = g_hash_table_lookup (env_memory_sources, s->name);
      g_autoptr (LqlTable) snap = NULL;

      if (src == NULL)
        continue;
      snap = snapshot_table (s->name, s->rows_json, error);
      if (snap == NULL)
        {
          g_mutex_unlock (&env_lock);
          return FALSE;
        }
      lql_memory_source_set_table (src, snap);
    }

  if (timeout_ms > 0)
    {
      old_timeout = lql_environment_get_limit (env, LQL_LIMIT_TIMEOUT_MS);
      lql_environment_set_limit (env, LQL_LIMIT_TIMEOUT_MS, timeout_ms);
    }
  /* `now()' is the moment the query starts, not when the env was built. */
  lql_environment_set_now (env, g_get_real_time ());
  started = g_get_monotonic_time ();
  table = lql_environment_run_sync (env, text, NULL, cancellable, error);
  out->elapsed_us = g_get_monotonic_time () - started;
  if (timeout_ms > 0)
    lql_environment_set_limit (env, LQL_LIMIT_TIMEOUT_MS, old_timeout);

  if (table != NULL)
    {
      out->n_rows = lql_table_get_n_rows (table);
      out->json = table_to_json (table, max_rows);
      if (text_width > 0)
        {
          /* The text shows what the JSON shows: at most MAX_ROWS rows. */
          if (max_rows > 0 && out->n_rows > max_rows)
            {
              g_autoptr (LqlTable) head = lql_table_new ();
              guint c, r;

              for (c = 0; c < lql_table_get_n_columns (table); c++)
                {
                  LqlColumn *col = lql_table_get_column (table, c);

                  lql_table_add_column (head, lql_column_get_name (col),
                                        lql_column_get_column_type (col));
                }
              for (r = 0; r < max_rows; r++)
                lql_table_add_row (head, lql_table_get_row (table, r));
              out->text = lql_table_to_text_wrapped (head, text_width);
            }
          else
            out->text = lql_table_to_text_wrapped (table, text_width);
        }
    }
  g_mutex_unlock (&env_lock);
  return table != NULL;
}

/* ── Editor-side helpers (try-lock) ─────────────────────────────── */

/* Take ENV_LOCK without waiting, building the environment first if it
   has never been built.  FALSE means a query holds it.  */
static gboolean
env_try_enter (void)
{
  if (env == NULL && !cmacs_lql_env_ensure (NULL))
    return FALSE;
  if (env == NULL || !g_mutex_trylock (&env_lock))
    return FALSE;
  env_apply_pending ();
  return TRUE;
}

/**
 * cmacs_lql_env_describe:
 * @out_json: (out) (transfer full): the lql-environment/1 JSON
 * @error: return location for a #GError
 *
 * Describe the whole environment -- built-ins, the tool sources, the
 * Elisp sources -- in the format `lql-language-server --environment'
 * reads.
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_describe (gchar **out_json, GError **error)
{
  *out_json = NULL;
  if (env == NULL && !cmacs_lql_env_ensure (error))
    return CMACS_LQL_ERROR;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  *out_json = lql_environment_describe (env);
  g_mutex_unlock (&env_lock);
  return CMACS_LQL_OK;
}

/**
 * cmacs_lql_env_complete:
 * @text: the query text
 * @offset: byte offset of point in @text
 * @out_json: (out) (transfer full): a JSON array of
 *   {"label","kind","detail","doc","insert","offset","length"}
 *
 * Completion candidates at @offset, from liblql's own assist code (the
 * same the language server uses).
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_complete (const gchar *text, guint offset, gchar **out_json)
{
  g_autoptr (GPtrArray) items = NULL;
  GString *out;
  guint i;

  *out_json = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  items = lql_assist_complete (env, text, offset);
  g_mutex_unlock (&env_lock);

  out = g_string_new ("[");
  for (i = 0; items != NULL && i < items->len; i++)
    {
      LqlCompletion *c = g_ptr_array_index (items, i);

      if (i > 0)
        g_string_append_c (out, ',');
      g_string_append (out, "{\"label\":");
      json_append_string (out, c->label);
      g_string_append (out, ",\"kind\":");
      json_append_string (out, lql_completion_kind_to_string (c->kind));
      g_string_append (out, ",\"detail\":");
      json_append_string (out, c->detail);
      g_string_append (out, ",\"doc\":");
      json_append_string (out, c->documentation);
      g_string_append (out, ",\"insert\":");
      json_append_string (out, c->insert_text != NULL ? c->insert_text
                                                      : c->label);
      g_string_append_printf (out, ",\"offset\":%u,\"length\":%u}",
                              c->offset, c->length);
    }
  g_string_append_c (out, ']');
  *out_json = g_string_free (out, FALSE);
  return CMACS_LQL_OK;
}

/**
 * cmacs_lql_env_hover:
 * @text: the query text
 * @offset: byte offset in @text
 * @out_json: (out) (transfer full) (nullable): {"text","offset","length"}
 *   or %NULL when there is nothing to say
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_hover (const gchar *text, guint offset, gchar **out_json)
{
  g_autofree gchar *hover = NULL;
  guint at = 0, len = 0;
  GString *out;

  *out_json = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  hover = lql_assist_hover (env, text, offset, &at, &len);
  g_mutex_unlock (&env_lock);
  if (hover == NULL)
    return CMACS_LQL_OK;
  out = g_string_new ("{\"text\":");
  json_append_string (out, hover);
  g_string_append_printf (out, ",\"offset\":%u,\"length\":%u}", at, len);
  *out_json = g_string_free (out, FALSE);
  return CMACS_LQL_OK;
}

/**
 * cmacs_lql_env_signature:
 * @text: the query text
 * @offset: byte offset in @text
 * @out_json: (out) (transfer full) (nullable):
 *   {"signature","doc","argument"} for the call around @offset
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_signature (const gchar *text, guint offset, gchar **out_json)
{
  LqlFunction *fn;
  guint arg = 0;
  GString *out;

  *out_json = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  fn = lql_assist_signature (env, text, offset, &arg);
  if (fn != NULL)
    {
      out = g_string_new ("{\"signature\":");
      json_append_string (out, lql_function_get_signature (fn) != NULL
                               ? lql_function_get_signature (fn)
                               : lql_function_get_name (fn));
      g_string_append (out, ",\"doc\":");
      json_append_string (out, lql_function_get_description (fn));
      g_string_append_printf (out, ",\"argument\":%u}", arg);
      *out_json = g_string_free (out, FALSE);
    }
  g_mutex_unlock (&env_lock);
  return CMACS_LQL_OK;
}

/**
 * cmacs_lql_env_diagnose:
 * @text: the query text
 * @out_json: (out) (transfer full): a JSON array of
 *   {"message","line","column","offset","length","code"}
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_diagnose (const gchar *text, gchar **out_json)
{
  g_autoptr (GPtrArray) diags = NULL;
  GString *out;
  guint i;

  *out_json = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  diags = lql_assist_diagnose (env, text, NULL);
  g_mutex_unlock (&env_lock);

  out = g_string_new ("[");
  for (i = 0; diags != NULL && i < diags->len; i++)
    {
      LqlDiagnostic *d = g_ptr_array_index (diags, i);

      if (i > 0)
        g_string_append_c (out, ',');
      g_string_append (out, "{\"message\":");
      json_append_string (out, d->message);
      g_string_append_printf (out, ",\"line\":%u,\"column\":%u,"
                              "\"offset\":%u,\"length\":%u,\"code\":%d}",
                              d->line, d->column, d->offset, d->length,
                              d->code);
    }
  g_string_append_c (out, ']');
  *out_json = g_string_free (out, FALSE);
  return CMACS_LQL_OK;
}

/**
 * cmacs_lql_env_explain:
 * @text: the query text
 * @out_text: (out) (transfer full): the plan liblql would run
 * @error: return location for a #GError
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_explain (const gchar *text, gchar **out_text, GError **error)
{
  g_autoptr (LqlQuery) query = NULL;

  *out_text = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  query = lql_environment_prepare (env, text, NULL, error);
  if (query != NULL)
    *out_text = lql_query_explain (query);
  g_mutex_unlock (&env_lock);
  return query != NULL ? CMACS_LQL_OK : CMACS_LQL_ERROR;
}

/**
 * cmacs_lql_env_format:
 * @text: the query text
 * @width: the line width to fill (0: liblql's default)
 * @out_text: (out) (transfer full): the formatted query
 * @error: return location for a #GError
 *
 * Returns: the status.
 */
CmacsLqlStatus
cmacs_lql_env_format (const gchar *text, guint width, gchar **out_text,
                      GError **error)
{
  *out_text = NULL;
  if (!env_try_enter ())
    return CMACS_LQL_BUSY;
  *out_text = lql_assist_format (env, text, width, error);
  g_mutex_unlock (&env_lock);
  return *out_text != NULL ? CMACS_LQL_OK : CMACS_LQL_ERROR;
}

/**
 * cmacs_lql_env_list_sources:
 *
 * Returns: (transfer full) (nullable): every source and source command
 *   name, or %NULL while a query holds the environment.
 */
gchar **
cmacs_lql_env_list_sources (void)
{
  g_auto (GStrv) sources = NULL;
  g_auto (GStrv) commands = NULL;
  GStrvBuilder *b;
  gchar **out;

  if (!env_try_enter ())
    return NULL;
  sources = lql_environment_list_sources (env);
  commands = lql_environment_list_source_commands (env);
  g_mutex_unlock (&env_lock);

  b = g_strv_builder_new ();
  if (sources != NULL)
    g_strv_builder_addv (b, (const char **) sources);
  if (commands != NULL)
    g_strv_builder_addv (b, (const char **) commands);
  out = g_strv_builder_end (b);
  g_strv_builder_unref (b);
  return out;
}

/**
 * cmacs_lql_version:
 *
 * Returns: (transfer none): the linked liblql's version string.
 */
const gchar *
cmacs_lql_version (void)
{
  return LQL_VERSION_STRING;
}

#endif /* HAVE_CMACS_LQL */
