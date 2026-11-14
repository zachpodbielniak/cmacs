/* cmacs-lql-defuns.c --- Elisp surface of the LQL subsystem

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

   The Lisp half (cmacs-lql.h explains the split).  It never includes
   <lql.h>; everything it gets from the model half is a C string.

   Queries.  `cmacs-lql--run' queues a job on a one-thread pool and
   returns an integer id at once.  Jobs run one at a time, each under a
   private thread-default GMainContext, so a slow source never touches
   the editor's loop -- the same reasoning as cmacs-ai-libresearch.c,
   which also has to serve MCP and D-Bus callers that wait with
   `sit-for' from inside a dispatch.  The result comes back either:

   - to CALLBACK, once, on the Lisp thread, via cmacs_glib_invoke_on_main
     (the callback lives in a staticpro'd hash table, never in the C job);
   - or to a caller polling `cmacs-lql--poll' (CALLBACK nil).

   Payloads:

     (:ok :json JSON :text TEXT :rows N :elapsed SECONDS)
     (:error MESSAGE)
     (:cancelled)

   Offsets.  liblql speaks byte offsets into UTF-8.  A multibyte Lisp
   string's data IS UTF-8 for any text a query can contain, so SSDATA is
   handed over as it is and character positions are converted with
   string_char_to_byte on the way in.  Offsets on the way out stay bytes
   in the JSON; cmacs-lql.el converts the few it needs.  */

#include <config.h>

#ifdef HAVE_CMACS_LQL

#include "lisp.h"
#include "coding.h"
#include "cmacs-lql.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

/* ── Jobs ───────────────────────────────────────────────────────── */

typedef struct
{
  gint          ref_count;
  guint         id;
  gboolean      deliver;        /* a callback is waiting */

  /* Input, set before the job is queued; read-only afterwards.  */
  gchar        *text;
  GPtrArray    *snapshots;      /* CmacsLqlSnapshot */
  guint         max_rows;
  guint         text_width;
  gint64        timeout_ms;
  GCancellable *cancellable;

  /* Output, under LOCK.  */
  GMutex        lock;
  gboolean      done;
  gboolean      cancelled;
  gchar        *error;
  CmacsLqlResult result;
} CmacsLqlJob;

static CmacsLqlJob *
job_ref (CmacsLqlJob *job)
{
  g_atomic_int_inc (&job->ref_count);
  return job;
}

static void
job_unref (gpointer data)
{
  CmacsLqlJob *job = data;

  if (!g_atomic_int_dec_and_test (&job->ref_count))
    return;
  g_free (job->text);
  g_clear_pointer (&job->snapshots, g_ptr_array_unref);
  g_clear_object (&job->cancellable);
  g_free (job->error);
  cmacs_lql_result_clear (&job->result);
  g_mutex_clear (&job->lock);
  g_free (job);
}

/* id -> CmacsLqlJob, every job not yet collected.  Lisp thread only.  */
static GHashTable *jobs;
static guint next_id = 1;
static GThreadPool *pool;

/* id -> callback.  The GC root for every pending callback.  */
static Lisp_Object Vcmacs_lql__callbacks;

static Lisp_Object
callback_take (guint id)
{
  Lisp_Object cb;

  if (NILP (Vcmacs_lql__callbacks))
    return Qnil;
  cb = Fgethash (make_uint (id), Vcmacs_lql__callbacks, Qnil);
  Fremhash (make_uint (id), Vcmacs_lql__callbacks);
  return cb;
}

/* The payload for a finished JOB.  Lisp thread only.  */
static Lisp_Object
job_payload (CmacsLqlJob *job)
{
  Lisp_Object out;

  g_mutex_lock (&job->lock);
  if (job->cancelled)
    out = list1 (QCcancelled);
  else if (job->error != NULL)
    out = list2 (QCerror, build_string (job->error));
  else
    out = list (intern_c_string (":ok"),
                QCjson, build_string (job->result.json != NULL
                                      ? job->result.json : "null"),
                intern_c_string (":text"), (job->result.text != NULL
                         ? build_string (job->result.text) : Qnil),
                QCrows, make_uint (job->result.n_rows),
                QCelapsed, make_float ((double) job->result.elapsed_us
                                       / 1e6));
  g_mutex_unlock (&job->lock);
  return out;
}

static gboolean
job_deliver (gpointer data)
{
  CmacsLqlJob *job = data;          /* the source's ref; NOTIFY drops it */
  guint id = job->id;
  Lisp_Object cb, payload;

  /* Already collected by `cmacs-lql--poll': nothing to do.  */
  if (jobs == NULL || !g_hash_table_contains (jobs, GUINT_TO_POINTER (id)))
    return G_SOURCE_REMOVE;

  payload = job_payload (job);
  cb = callback_take (id);
  g_hash_table_remove (jobs, GUINT_TO_POINTER (id));
  if (!NILP (cb))
    cmacs_dispatch_safe_call1 (cb, payload);
  return G_SOURCE_REMOVE;
}

/* The pool's one thread.  Runs JOB under a private thread-default
   context, records the outcome, and hands it to the Lisp thread.  */
static void
job_run (gpointer data, gpointer user_data)
{
  CmacsLqlJob *job = data;          /* the pool's ref */
  GMainContext *ctx = g_main_context_new ();
  CmacsLqlResult result = { 0 };
  GError *err = NULL;
  gboolean ok;

  (void) user_data;
  g_main_context_push_thread_default (ctx);
  if (g_cancellable_is_cancelled (job->cancellable))
    ok = FALSE;
  else
    ok = cmacs_lql_env_run (job->text, job->snapshots, job->max_rows,
                            job->text_width, job->timeout_ms,
                            job->cancellable, &result, &err);
  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);

  g_mutex_lock (&job->lock);
  job->cancelled = g_cancellable_is_cancelled (job->cancellable);
  if (ok)
    job->result = result;
  else
    {
      cmacs_lql_result_clear (&result);
      if (!job->cancelled)
        job->error = g_strdup (err != NULL ? err->message
                                           : "LQL query failed");
    }
  job->done = TRUE;
  g_mutex_unlock (&job->lock);
  g_clear_error (&err);

  if (job->deliver)
    cmacs_glib_invoke_on_main (job_deliver, job_ref (job), job_unref);
  job_unref (job);
}

/* ── Argument helpers ───────────────────────────────────────────── */

static Lisp_Object
opt (Lisp_Object options, Lisp_Object key)
{
  return NILP (options) ? Qnil : plist_get (options, key);
}

static guint
opt_nat (Lisp_Object options, Lisp_Object key, guint dflt)
{
  Lisp_Object v = opt (options, key);

  if (NILP (v))
    return dflt;
  CHECK_FIXNAT (v);
  return (guint) min (XFIXNAT (v), G_MAXUINT);
}

/* Character position POS of STRING as a byte offset, clamped.  */
static guint
char_to_byte (Lisp_Object string, Lisp_Object pos)
{
  ptrdiff_t p;

  CHECK_FIXNAT (pos);
  p = min (XFIXNAT (pos), SCHARS (string));
  return (guint) string_char_to_byte (string, p);
}

/* Signal `cmacs-lql-busy' -- a query holds the environment.  Callers in
   Lisp catch it and retry; it is its own condition so they need not
   parse a message.  */
static AVOID
signal_busy (void)
{
  xsignal1 (Qcmacs_lql_busy,
            build_string ("an LQL query is running; try again"));
}

/* A string result of an editor-side helper, or a signal.  */
static Lisp_Object
status_result (CmacsLqlStatus status, gchar *owned, GError *error)
{
  Lisp_Object out = Qnil;

  if (status == CMACS_LQL_BUSY)
    {
      g_free (owned);
      g_clear_error (&error);
      signal_busy ();
    }
  if (status == CMACS_LQL_ERROR)
    {
      Lisp_Object msg = build_string (error != NULL ? error->message
                                                    : "LQL error");
      g_free (owned);
      g_clear_error (&error);
      xsignal1 (Qcmacs_lql_error, msg);
    }
  if (owned != NULL)
    out = build_string (owned);
  g_free (owned);
  g_clear_error (&error);
  return out;
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-lql--run", Fcmacs_lql__run, Scmacs_lql__run, 1, 3, 0,
       doc: /* Run the LQL query QUERY on the LQL worker thread.

Low-level primitive; `cmacs-lql-run' is the Lisp entry point.  Returns
an integer request id at once.

OPTIONS is a plist:
  :snapshots  alist of (NAME . JSON): rows for Elisp-defined sources,
              each a JSON array of objects, installed before the run.
  :max-rows   rows to put in the JSON result (default: all).
  :text-width when non-nil, also render the result as text this wide.
  :timeout    the run's time limit in milliseconds.

When CALLBACK is non-nil it is called once, on the Lisp thread, with
\(:ok :json JSON :text TEXT :rows N :elapsed SECONDS), (:error MESSAGE)
or (:cancelled).  JSON is {"columns":[{"name","type"}],"rows":[[...]],
"total":N}.  When CALLBACK is nil, collect the result with
`cmacs-lql--poll'.  */)
  (Lisp_Object query, Lisp_Object options, Lisp_Object callback)
{
  CmacsLqlJob *job;
  Lisp_Object tail;
  g_autoptr (GError) gerror = NULL;

  CHECK_STRING (query);
  if (!NILP (callback) && NILP (Ffunctionp (callback)))
    wrong_type_argument (Qfunctionp, callback);

  job = g_new0 (CmacsLqlJob, 1);
  job->ref_count = 1;
  g_mutex_init (&job->lock);
  job->text = g_strdup (SSDATA (ENCODE_UTF_8 (query)));
  job->snapshots = g_ptr_array_new_with_free_func (cmacs_lql_snapshot_free);
  job->cancellable = g_cancellable_new ();
  job->max_rows = opt_nat (options, QCmax_rows, 0);
  job->text_width = opt_nat (options, QCtext_width, 0);
  job->timeout_ms = opt_nat (options, intern_c_string (":timeout"), 0);

  for (tail = opt (options, QCsnapshots); CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object pair = XCAR (tail);
      CmacsLqlSnapshot *s;

      if (!CONSP (pair) || !STRINGP (XCAR (pair)) || !STRINGP (XCDR (pair)))
        {
          job_unref (job);
          wrong_type_argument (Qconsp, pair);
        }
      s = g_new0 (CmacsLqlSnapshot, 1);
      s->name = g_strdup (SSDATA (ENCODE_UTF_8 (XCAR (pair))));
      s->rows_json = g_strdup (SSDATA (ENCODE_UTF_8 (XCDR (pair))));
      g_ptr_array_add (job->snapshots, s);
    }

  if (pool == NULL)
    {
      pool = g_thread_pool_new (job_run, NULL, 1, TRUE, &gerror);
      if (pool == NULL)
        {
          Lisp_Object msg = build_string (gerror->message);
          job_unref (job);
          xsignal1 (Qcmacs_lql_error, msg);
        }
    }
  if (jobs == NULL)
    jobs = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                  NULL, job_unref);
  if (NILP (Vcmacs_lql__callbacks))
    Vcmacs_lql__callbacks = CALLN (Fmake_hash_table, QCtest, Qeql);

  job->id = next_id++;
  job->deliver = !NILP (callback);
  g_hash_table_insert (jobs, GUINT_TO_POINTER (job->id), job);
  if (!NILP (callback))
    Fputhash (make_uint (job->id), callback, Vcmacs_lql__callbacks);

  if (!g_thread_pool_push (pool, job_ref (job), &gerror))
    {
      Lisp_Object msg = build_string (gerror->message);
      guint id = job->id;

      job_unref (job);              /* the pool's ref that never arrived */
      callback_take (id);
      g_hash_table_remove (jobs, GUINT_TO_POINTER (id));
      xsignal1 (Qcmacs_lql_error, msg);
    }
  return make_uint (job->id);
}

DEFUN ("cmacs-lql--poll", Fcmacs_lql__poll, Scmacs_lql__poll, 1, 1, 0,
       doc: /* Return the result of LQL request ID, or nil while pending.

The result is the payload a callback would have received.  Collecting it
forgets the request, and a callback registered for it is then never
called.  Signals `cmacs-lql-error' for an unknown ID.  */)
  (Lisp_Object id)
{
  CmacsLqlJob *job;
  Lisp_Object payload;
  gboolean done;

  CHECK_FIXNAT (id);
  job = jobs != NULL
    ? g_hash_table_lookup (jobs, GUINT_TO_POINTER ((guint) XFIXNAT (id)))
    : NULL;
  if (job == NULL)
    xsignal2 (Qcmacs_lql_error, build_string ("no such LQL request"), id);

  g_mutex_lock (&job->lock);
  done = job->done;
  g_mutex_unlock (&job->lock);
  if (!done)
    return Qnil;

  payload = job_payload (job);
  callback_take (job->id);
  g_hash_table_remove (jobs, GUINT_TO_POINTER ((guint) XFIXNAT (id)));
  return payload;
}

DEFUN ("cmacs-lql--cancel", Fcmacs_lql__cancel, Scmacs_lql__cancel, 1, 1, 0,
       doc: /* Cancel LQL request ID.

Returns t when ID names a request still pending, nil otherwise.  The
request still finishes once, as (:cancelled).  */)
  (Lisp_Object id)
{
  CmacsLqlJob *job;

  CHECK_FIXNAT (id);
  job = jobs != NULL
    ? g_hash_table_lookup (jobs, GUINT_TO_POINTER ((guint) XFIXNAT (id)))
    : NULL;
  if (job == NULL)
    return Qnil;
  g_cancellable_cancel (job->cancellable);
  return Qt;
}

DEFUN ("cmacs-lql--define-source", Fcmacs_lql__define_source,
       Scmacs_lql__define_source, 2, 3, 0,
       doc: /* Define the Elisp-backed LQL source NAME.

COLUMNS is a JSON array of {"name": ..., "type": ...} objects, the
types being LQL's (String, Int, Double, Boolean, Timestamp, Duration,
Array, Record, Any).  DESCRIPTION is a one-line description.  Rows are
supplied per run through `cmacs-lql--run's :snapshots.  Never blocks;
a definition made while a query runs takes effect after it.  */)
  (Lisp_Object name, Lisp_Object columns, Lisp_Object description)
{
  CHECK_STRING (name);
  CHECK_STRING (columns);
  if (!NILP (description))
    CHECK_STRING (description);
  cmacs_lql_env_define_source (SSDATA (ENCODE_UTF_8 (name)),
                               SSDATA (ENCODE_UTF_8 (columns)),
                               NILP (description) ? NULL
                               : SSDATA (ENCODE_UTF_8 (description)));
  return Qnil;
}

DEFUN ("cmacs-lql--describe", Fcmacs_lql__describe, Scmacs_lql__describe,
       0, 0, 0,
       doc: /* Return the LQL environment as lql-environment/1 JSON.

That is the document `lql-language-server --environment FILE' reads.
Signals `cmacs-lql-busy' while a query holds the environment.  */)
  (void)
{
  gchar *json = NULL;
  GError *error = NULL;
  CmacsLqlStatus st = cmacs_lql_env_describe (&json, &error);

  return status_result (st, json, error);
}

DEFUN ("cmacs-lql--complete", Fcmacs_lql__complete, Scmacs_lql__complete,
       2, 2, 0,
       doc: /* Completion candidates for the LQL text TEXT at POS.

POS is a 0-based character index into TEXT.  Returns a JSON array of
{"label","kind","detail","doc","insert","offset","length"}, where
offset and length are BYTE offsets into TEXT's UTF-8.  Signals
`cmacs-lql-busy' while a query holds the environment.  */)
  (Lisp_Object text, Lisp_Object pos)
{
  gchar *json = NULL;
  CmacsLqlStatus st;

  CHECK_STRING (text);
  st = cmacs_lql_env_complete (SSDATA (text), char_to_byte (text, pos), &json);
  return status_result (st, json, NULL);
}

DEFUN ("cmacs-lql--hover", Fcmacs_lql__hover, Scmacs_lql__hover, 2, 2, 0,
       doc: /* Documentation for the LQL text TEXT at POS (0-based chars).

Returns a JSON object {"text","offset","length"} or nil.  Signals
`cmacs-lql-busy' while a query holds the environment.  */)
  (Lisp_Object text, Lisp_Object pos)
{
  gchar *json = NULL;
  CmacsLqlStatus st;

  CHECK_STRING (text);
  st = cmacs_lql_env_hover (SSDATA (text), char_to_byte (text, pos), &json);
  return status_result (st, json, NULL);
}

DEFUN ("cmacs-lql--signature", Fcmacs_lql__signature, Scmacs_lql__signature,
       2, 2, 0,
       doc: /* The function call around POS in LQL text TEXT.

Returns a JSON object {"signature","doc","argument"} or nil.  */)
  (Lisp_Object text, Lisp_Object pos)
{
  gchar *json = NULL;
  CmacsLqlStatus st;

  CHECK_STRING (text);
  st = cmacs_lql_env_signature (SSDATA (text), char_to_byte (text, pos),
                                &json);
  return status_result (st, json, NULL);
}

DEFUN ("cmacs-lql--diagnose", Fcmacs_lql__diagnose, Scmacs_lql__diagnose,
       1, 1, 0,
       doc: /* Diagnostics for the LQL text TEXT, as a JSON array.

Each element is {"message","line","column","offset","length","code"};
offsets are bytes.  */)
  (Lisp_Object text)
{
  gchar *json = NULL;
  CmacsLqlStatus st;

  CHECK_STRING (text);
  st = cmacs_lql_env_diagnose (SSDATA (text), &json);
  return status_result (st, json, NULL);
}

DEFUN ("cmacs-lql--explain", Fcmacs_lql__explain, Scmacs_lql__explain,
       1, 1, 0,
       doc: /* The plan liblql would run for the LQL query TEXT.  */)
  (Lisp_Object text)
{
  gchar *out = NULL;
  GError *error = NULL;
  CmacsLqlStatus st;

  CHECK_STRING (text);
  st = cmacs_lql_env_explain (SSDATA (text), &out, &error);
  return status_result (st, out, error);
}

DEFUN ("cmacs-lql--format", Fcmacs_lql__format, Scmacs_lql__format,
       1, 2, 0,
       doc: /* The LQL query TEXT, formatted to WIDTH columns.  */)
  (Lisp_Object text, Lisp_Object width)
{
  gchar *out = NULL;
  GError *error = NULL;
  CmacsLqlStatus st;
  guint w = 0;

  CHECK_STRING (text);
  if (!NILP (width))
    {
      CHECK_FIXNAT (width);
      w = (guint) min (XFIXNAT (width), G_MAXUINT);
    }
  st = cmacs_lql_env_format (SSDATA (text), w, &out, &error);
  return status_result (st, out, error);
}

DEFUN ("cmacs-lql--sources", Fcmacs_lql__sources, Scmacs_lql__sources,
       0, 0, 0,
       doc: /* Every LQL source and source command name, as strings.

Signals `cmacs-lql-busy' while a query holds the environment.  */)
  (void)
{
  gchar **names = cmacs_lql_env_list_sources ();
  Lisp_Object out = Qnil;
  gint i;

  if (names == NULL)
    signal_busy ();
  for (i = (gint) g_strv_length (names) - 1; i >= 0; i--)
    out = Fcons (build_string (names[i]), out);
  g_strfreev (names);
  return out;
}

DEFUN ("cmacs-lql--version", Fcmacs_lql__version, Scmacs_lql__version,
       0, 0, 0,
       doc: /* The version of liblql linked into this Emacs.  */)
  (void)
{
  return build_string (cmacs_lql_version ());
}

/* ── Registration ───────────────────────────────────────────────── */

void
syms_of_cmacs_lql_defuns (void)
{
  DEFSYM (Qcmacs_lql_error, "cmacs-lql-error");
  Fput (Qcmacs_lql_error, Qerror_conditions,
        list2 (Qcmacs_lql_error, Qerror));
  Fput (Qcmacs_lql_error, Qerror_message, build_string ("LQL error"));
  DEFSYM (Qcmacs_lql_busy, "cmacs-lql-busy");
  Fput (Qcmacs_lql_busy, Qerror_conditions,
        list3 (Qcmacs_lql_busy, Qcmacs_lql_error, Qerror));
  Fput (Qcmacs_lql_busy, Qerror_message,
        build_string ("LQL environment busy"));

  DEFSYM (QCcancelled, ":cancelled");
  DEFSYM (QCjson, ":json");
  DEFSYM (QCrows, ":rows");
  DEFSYM (QCelapsed, ":elapsed");
  DEFSYM (QCsnapshots, ":snapshots");
  DEFSYM (QCmax_rows, ":max-rows");
  DEFSYM (QCtext_width, ":text-width");

  Vcmacs_lql__callbacks = Qnil;
  staticpro (&Vcmacs_lql__callbacks);

  defsubr (&Scmacs_lql__run);
  defsubr (&Scmacs_lql__poll);
  defsubr (&Scmacs_lql__cancel);
  defsubr (&Scmacs_lql__define_source);
  defsubr (&Scmacs_lql__describe);
  defsubr (&Scmacs_lql__complete);
  defsubr (&Scmacs_lql__hover);
  defsubr (&Scmacs_lql__signature);
  defsubr (&Scmacs_lql__diagnose);
  defsubr (&Scmacs_lql__explain);
  defsubr (&Scmacs_lql__format);
  defsubr (&Scmacs_lql__sources);
  defsubr (&Scmacs_lql__version);
}

#endif /* HAVE_CMACS_LQL */
