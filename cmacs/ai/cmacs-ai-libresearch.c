/* cmacs-ai-libresearch.c --- libresearch (search/fetch/LQL/research) for Elisp.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ai-glib's AiLibresearchSearch is a REST client of libresearchd: web
 * search with categories, a page's readable text (optionally from the
 * Wayback Machine), LQL queries over search results, cited research
 * answers, and the server's LQL environment.  This file is the Elisp
 * surface for all five.
 *
 * Every request runs on a WORKER THREAD with a private thread-default
 * GMainContext, never on the editor's own loop.  That is a deliberate
 * departure from the embed/stream pattern (async on the default
 * context), for three reasons that all bite this API in particular:
 *
 *   - A research run takes minutes.  Callers that must look
 *     synchronous -- an MCP tool, a brigade tool -- wait with `sit-for'.
 *     When that wait happens inside an MCP or D-Bus dispatch, the
 *     cmacs GLib hook is already dispatching and skips the nested
 *     iteration (cmacs-glib-loop.c), so a request bound to the editor's
 *     context would never complete.  A worker's private loop does not
 *     care who is waiting, or how.
 *
 *   - The default GMainContext is only iterated when a toolkit happens
 *     to do it (cmacs-glib-loop.h); `emacs --lrg' and a tty frame have
 *     none.  The worker pumps its own.
 *
 *   - Nothing about a request needs Lisp until it is over.
 *
 * Only C strings cross the thread boundary (the Emacs allocator is not
 * thread-safe), and the job struct is refcounted so the main thread can
 * forget a job while its worker is still blocked on the network.  The
 * result comes back one of two ways:
 *
 *   - CALLBACK non-nil: delivered once, on the Lisp thread, through
 *     `cmacs_glib_invoke_on_main'.  The callback is held in a
 *     staticpro'd hash table keyed by job id -- never in the C struct,
 *     where the GC cannot see it.
 *   - CALLBACK nil: the caller polls `cmacs-ai--libresearch-poll'.
 *     This is the path for code that has to wait (MCP, brigade tools).
 *
 * Payloads, either way:
 *
 *   (:ok :kind KIND :text TEXT :json JSON)
 *   (:error MESSAGE)
 *   (:cancelled)
 *
 * TEXT is ai-glib's own rendering (ai_libresearch_format_*), the same
 * text every other host shows a model; JSON is the server's document,
 * so Lisp can render Org from the structure.  */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <ai-glib.h>
#include <glib.h>
#include <json-glib/json-glib.h>

/* ── Request kinds ──────────────────────────────────────────────── */

typedef enum
{
  CMACS_AI_LR_SEARCH,
  CMACS_AI_LR_FETCH,
  CMACS_AI_LR_LQL,
  CMACS_AI_LR_RESEARCH,
  CMACS_AI_LR_ENVIRONMENT
} CmacsAiLrKind;

/* The Lisp-facing name of KIND, as it appears in :kind.  */
static const char *
cmacs_ai_lr__kind_name (CmacsAiLrKind kind)
{
  switch (kind)
    {
    case CMACS_AI_LR_SEARCH:      return "search";
    case CMACS_AI_LR_FETCH:       return "fetch";
    case CMACS_AI_LR_LQL:         return "lql";
    case CMACS_AI_LR_RESEARCH:    return "research";
    case CMACS_AI_LR_ENVIRONMENT: return "environment";
    }
  return "unknown";
}

/* ── The job (C heap only; no Lisp_Object may live here) ────────── */

typedef struct
{
  gint            ref;            /* atomic */
  guint           id;
  CmacsAiLrKind   kind;

  /* Inputs, owned UTF-8 copies, read-only once the worker starts.  */
  gchar          *endpoint;       /* NULL = ai-glib's default */
  gchar          *token;          /* NULL = no bearer token */
  gchar          *arg;            /* query / url / lql / question */
  gchar          *category;       /* search */
  gchar          *site;           /* search */
  gchar          *archive;        /* fetch: never / fallback / only */
  guint           count;          /* search */
  guint           max_chars;      /* fetch */
  guint           pages;          /* research */
  guint           max_rows;       /* formatter cap for search/lql */
  guint           timeout;        /* seconds; 0 = ai-glib's own */
  gboolean        flag;           /* lql: explain; research: deep */
  gboolean        deliver;        /* a callback is waiting */

  GCancellable   *cancellable;

  /* Outputs, written by the worker under LOCK, then DONE.  */
  GMutex          lock;
  gboolean        done;
  gboolean        cancelled;
  gchar          *text;
  gchar          *json;
  gchar          *error;
} CmacsAiLrJob;

static CmacsAiLrJob *
cmacs_ai_lr__job_ref (CmacsAiLrJob *job)
{
  g_atomic_int_inc (&job->ref);
  return job;
}

static void
cmacs_ai_lr__job_unref (gpointer data)
{
  CmacsAiLrJob *job = data;

  if (job == NULL || !g_atomic_int_dec_and_test (&job->ref))
    return;
  g_free (job->endpoint);
  g_free (job->token);
  g_free (job->arg);
  g_free (job->category);
  g_free (job->site);
  g_free (job->archive);
  g_clear_object (&job->cancellable);
  g_mutex_clear (&job->lock);
  g_free (job->text);
  g_free (job->json);
  g_free (job->error);
  g_free (job);
}

/* ── Registries (Lisp thread only) ──────────────────────────────── */

/* id -> CmacsAiLrJob*, holding one ref.  A job leaves when its result
 * is delivered or polled.  */
static GHashTable *cmacs_ai_lr__jobs;
static guint cmacs_ai_lr__next_id = 1;

/* id -> callback.  The GC root for every pending callback.  */
static Lisp_Object Vcmacs_ai__libresearch_callbacks;

static void
cmacs_ai_lr__jobs_init (void)
{
  if (cmacs_ai_lr__jobs != NULL)
    return;
  cmacs_ai_lr__jobs = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                             NULL, cmacs_ai_lr__job_unref);
}

static void
cmacs_ai_lr__callbacks_init (void)
{
  if (!NILP (Vcmacs_ai__libresearch_callbacks))
    return;
  Vcmacs_ai__libresearch_callbacks = CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
cmacs_ai_lr__callback_take (guint id)
{
  Lisp_Object cb;

  if (NILP (Vcmacs_ai__libresearch_callbacks))
    return Qnil;
  cb = Fgethash (make_uint (id), Vcmacs_ai__libresearch_callbacks, Qnil);
  Fremhash (make_uint (id), Vcmacs_ai__libresearch_callbacks);
  return cb;
}

/* ── The worker thread ──────────────────────────────────────────── */

/* State of one request on the worker's private loop.  */
typedef struct
{
  gboolean      done;
  gboolean      timed_out;
  JsonNode     *node;
  GError       *error;
  GCancellable *cancellable;
} CmacsAiLrWait;

static void
cmacs_ai_lr__on_done (GObject *source, GAsyncResult *result, gpointer user)
{
  CmacsAiLrWait *w = user;

  w->node = ai_libresearch_search_request_finish (AI_LIBRESEARCH_SEARCH (source),
                                                  result, &w->error);
  w->done = TRUE;
}

static gboolean
cmacs_ai_lr__on_deadline (gpointer user)
{
  CmacsAiLrWait *w = user;

  w->timed_out = TRUE;
  g_cancellable_cancel (w->cancellable);
  return G_SOURCE_REMOVE;
}

/* Start JOB's request on CLIENT; the reply lands in W.  */
static void
cmacs_ai_lr__start (CmacsAiLrJob *job, AiLibresearchSearch *client,
                    CmacsAiLrWait *w)
{
  switch (job->kind)
    {
    case CMACS_AI_LR_SEARCH:
      {
        g_autoptr (AiSearchOptions) opts = ai_search_options_new ();

        if (job->count > 0)
          ai_search_options_set_count (opts, job->count);
        if (job->site != NULL)
          ai_search_options_set_site (opts, job->site);
        ai_libresearch_search_web_async (client, job->arg, opts,
                                         job->category, job->cancellable,
                                         cmacs_ai_lr__on_done, w);
      }
      break;
    case CMACS_AI_LR_FETCH:
      ai_libresearch_search_fetch_async (client, job->arg, job->max_chars,
                                         job->archive, job->cancellable,
                                         cmacs_ai_lr__on_done, w);
      break;
    case CMACS_AI_LR_LQL:
      ai_libresearch_search_query_async (client, job->arg, job->flag,
                                         job->cancellable,
                                         cmacs_ai_lr__on_done, w);
      break;
    case CMACS_AI_LR_RESEARCH:
      ai_libresearch_search_research_async (client, job->arg, job->flag,
                                            job->pages, job->cancellable,
                                            cmacs_ai_lr__on_done, w);
      break;
    case CMACS_AI_LR_ENVIRONMENT:
      ai_libresearch_search_environment_async (client, job->cancellable,
                                               cmacs_ai_lr__on_done, w);
      break;
    }
}

/* Render DOC as ai-glib renders it for a model.  The environment has no
 * formatter of its own; its JSON, pretty-printed, is the readable form. */
static gchar *
cmacs_ai_lr__format (CmacsAiLrKind kind, JsonNode *doc, guint max_rows)
{
  switch (kind)
    {
    case CMACS_AI_LR_SEARCH:
      return ai_libresearch_format_search (doc, max_rows);
    case CMACS_AI_LR_FETCH:
      return ai_libresearch_format_fetch (doc);
    case CMACS_AI_LR_LQL:
      return ai_libresearch_format_query (doc, max_rows);
    case CMACS_AI_LR_RESEARCH:
      return ai_libresearch_format_research (doc);
    case CMACS_AI_LR_ENVIRONMENT:
      return json_to_string (doc, TRUE);
    }
  return g_strdup ("");
}

/* Lisp-thread half of delivery: hand the payload to the callback.  */
static gboolean cmacs_ai_lr__deliver (gpointer data);

static gpointer
cmacs_ai_lr__worker (gpointer data)
{
  CmacsAiLrJob *job = data;        /* this thread's own ref */
  GMainContext *ctx;
  AiLibresearchSearch *client;
  GSource *deadline = NULL;
  CmacsAiLrWait w = { FALSE, FALSE, NULL, NULL, job->cancellable };
  gchar *text = NULL, *json = NULL, *err = NULL;
  gboolean cancelled = FALSE;

  /* A private thread-default context BEFORE the client exists: the
   * client's soup session binds to the context current at creation,
   * and without one pushed that would be the process-global default,
   * which the Lisp thread owns -- the request would then run (or not)
   * on the editor's loop, which is precisely what this file avoids. */
  ctx = g_main_context_new ();
  g_main_context_push_thread_default (ctx);

  client = ai_libresearch_search_new (job->endpoint, job->token);

  if (job->timeout > 0)
    {
      deadline = g_timeout_source_new_seconds (job->timeout);
      g_source_set_callback (deadline, cmacs_ai_lr__on_deadline, &w, NULL);
      g_source_attach (deadline, ctx);
    }

  cmacs_ai_lr__start (job, client, &w);
  while (!w.done)
    g_main_context_iteration (ctx, TRUE);

  if (deadline != NULL)
    {
      g_source_destroy (deadline);
      g_source_unref (deadline);
    }

  /* Render while still on this thread: formatting is pure C and can be
   * slow for a large document, and the Lisp thread should only build
   * strings.  */
  if (w.node != NULL)
    {
      text = cmacs_ai_lr__format (job->kind, w.node, job->max_rows);
      json = json_to_string (w.node, FALSE);
      json_node_unref (w.node);
    }
  else if (w.timed_out)
    err = g_strdup_printf ("libresearch %s timed out after %u s",
                           cmacs_ai_lr__kind_name (job->kind), job->timeout);
  else if (w.error != NULL
           && g_error_matches (w.error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    cancelled = TRUE;
  else
    err = g_strdup (w.error != NULL ? w.error->message
                                    : "libresearch request failed");
  g_clear_error (&w.error);

  /* Drop the client, then let anything it scheduled on the way out run
   * on the context it belongs to before that context goes away.  */
  g_object_unref (client);
  while (g_main_context_iteration (ctx, FALSE))
    ;
  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);

  g_mutex_lock (&job->lock);
  job->text = text;
  job->json = json;
  job->error = err;
  job->cancelled = cancelled;
  job->done = TRUE;
  g_mutex_unlock (&job->lock);

  if (job->deliver)
    cmacs_glib_invoke_on_main (cmacs_ai_lr__deliver,
                               cmacs_ai_lr__job_ref (job),
                               cmacs_ai_lr__job_unref);

  cmacs_ai_lr__job_unref (job);
  return NULL;
}

/* ── Lisp-thread side ───────────────────────────────────────────── */

/* The payload for a finished JOB.  Lisp thread only.  */
static Lisp_Object
cmacs_ai_lr__payload (CmacsAiLrJob *job)
{
  Lisp_Object out;

  g_mutex_lock (&job->lock);
  if (job->cancelled)
    out = list1 (intern (":cancelled"));
  else if (job->error != NULL)
    out = list2 (intern (":error"), build_string (job->error));
  else
    out = list (intern (":ok"),
                intern (":kind"), intern (cmacs_ai_lr__kind_name (job->kind)),
                intern (":text"), build_string (job->text ? job->text : ""),
                intern (":json"), build_string (job->json ? job->json : "null"));
  g_mutex_unlock (&job->lock);
  return out;
}

static gboolean
cmacs_ai_lr__deliver (gpointer data)
{
  CmacsAiLrJob *job = data;         /* the source's ref; NOTIFY drops it */
  guint id = job->id;
  Lisp_Object cb, payload;

  /* Already collected by `cmacs-ai--libresearch-poll': nothing to do. */
  if (cmacs_ai_lr__jobs == NULL
      || !g_hash_table_contains (cmacs_ai_lr__jobs, GUINT_TO_POINTER (id)))
    return G_SOURCE_REMOVE;

  payload = cmacs_ai_lr__payload (job);
  cb = cmacs_ai_lr__callback_take (id);
  g_hash_table_remove (cmacs_ai_lr__jobs, GUINT_TO_POINTER (id));

  if (!NILP (cb))
    cmacs_dispatch_safe_call1 (cb, payload);
  return G_SOURCE_REMOVE;
}

/* ── Argument handling ──────────────────────────────────────────── */

/* OPTIONS' value for KEY.  */
static Lisp_Object
cmacs_ai_lr__opt (Lisp_Object options, const char *key)
{
  return NILP (options) ? Qnil : plist_get (options, intern (key));
}

/* OPTIONS' KEY as an owned UTF-8 string, or NULL when absent or empty.
 * A symbol is taken by name, so `:archive 'fallback' works as well as
 * the string.  */
static gchar *
cmacs_ai_lr__opt_string (Lisp_Object options, const char *key)
{
  Lisp_Object v = cmacs_ai_lr__opt (options, key);
  gchar *s;

  if (NILP (v))
    return NULL;
  if (SYMBOLP (v))
    v = SYMBOL_NAME (v);
  CHECK_STRING (v);
  s = cmacs_dispatch_string_to_utf8 (v);
  if (*s == '\0')
    {
      g_free (s);
      return NULL;
    }
  return s;
}

/* OPTIONS' KEY as a natural number in [LO, HI], or 0 when absent.
 * Zero always means "the server's default", so it is always allowed. */
static guint
cmacs_ai_lr__opt_nat (Lisp_Object options, const char *key,
                      EMACS_INT lo, EMACS_INT hi)
{
  Lisp_Object v = cmacs_ai_lr__opt (options, key);

  if (NILP (v))
    return 0;
  CHECK_FIXNAT (v);
  if (XFIXNAT (v) != 0 && (XFIXNAT (v) < lo || XFIXNAT (v) > hi))
    args_out_of_range_3 (v, make_fixnum (lo), make_fixnum (hi));
  return (guint) XFIXNAT (v);
}

/* True when S is one of the NULL-terminated CHOICES.  */
static bool
cmacs_ai_lr__one_of (const gchar *s, const char *const *choices)
{
  for (; *choices != NULL; choices++)
    if (g_strcmp0 (s, *choices) == 0)
      return true;
  return false;
}

/* Validate the options every kind shares, signalling on a bad one.
 * Allocates nothing, so a DEFUN calls it before it owns any memory a
 * longjmp would leak.  */
static void
cmacs_ai_lr__check_common (Lisp_Object options)
{
  Lisp_Object v;

  if (!NILP (options) && !CONSP (options))
    wrong_type_argument (Qlistp, options);
  cmacs_ai_lr__opt_nat (options, ":timeout", 1, 86400);
  v = cmacs_ai_lr__opt (options, ":endpoint");
  if (!NILP (v) && !STRINGP (v))
    wrong_type_argument (Qstringp, v);
  v = cmacs_ai_lr__opt (options, ":token");
  if (!NILP (v) && !STRINGP (v))
    wrong_type_argument (Qstringp, v);
}

/* A new job of KIND for the string ARG (Qnil for environment), with the
 * connection options every kind shares already read.  Never signals:
 * the caller has run `cmacs_ai_lr__check_common' first, so a kind's
 * DEFUN can hand it memory it already owns.  */
static CmacsAiLrJob *
cmacs_ai_lr__job_new (CmacsAiLrKind kind, Lisp_Object arg,
                      Lisp_Object options)
{
  CmacsAiLrJob *job;
  Lisp_Object v;
  gchar *endpoint = NULL, *token = NULL;

  v = cmacs_ai_lr__opt (options, ":endpoint");
  if (STRINGP (v) && SCHARS (v) > 0)
    endpoint = cmacs_dispatch_string_to_utf8 (v);
  v = cmacs_ai_lr__opt (options, ":token");
  if (STRINGP (v) && SCHARS (v) > 0)
    token = cmacs_dispatch_string_to_utf8 (v);

  /* An explicit endpoint wins; then the environment ai-glib's own
   * default provider reads; then ai-glib's built-in default (NULL).  */
  if (endpoint == NULL)
    {
      const gchar *env = g_getenv ("LIBRESEARCH_URL");
      if (env != NULL && *env != '\0')
        endpoint = g_strdup (env);
    }
  if (token == NULL)
    {
      const gchar *env = g_getenv ("LIBRESEARCH_TOKEN");
      if (env != NULL && *env != '\0')
        token = g_strdup (env);
    }

  v = cmacs_ai_lr__opt (options, ":timeout");

  job = g_new0 (CmacsAiLrJob, 1);
  job->ref = 1;
  job->kind = kind;
  job->endpoint = endpoint;
  job->token = token;
  job->timeout = FIXNATP (v) ? (guint) XFIXNAT (v) : 0;
  job->arg = STRINGP (arg) ? cmacs_dispatch_string_to_utf8 (arg) : NULL;
  job->cancellable = g_cancellable_new ();
  g_mutex_init (&job->lock);
  return job;
}

/* Register JOB (and CALLBACK, when non-nil) and start its worker.
 * Returns the job id.  Takes over the caller's ref.  */
static Lisp_Object
cmacs_ai_lr__launch (CmacsAiLrJob *job, Lisp_Object callback)
{
  GThread *thread;
  g_autoptr (GError) gerror = NULL;

  cmacs_ai_lr__jobs_init ();
  cmacs_ai_lr__callbacks_init ();

  job->id = cmacs_ai_lr__next_id++;
  job->deliver = !NILP (callback);

  /* The table's ref is the caller's; the worker gets its own.  */
  g_hash_table_insert (cmacs_ai_lr__jobs, GUINT_TO_POINTER (job->id), job);
  if (!NILP (callback))
    Fputhash (make_uint (job->id), callback,
              Vcmacs_ai__libresearch_callbacks);

  thread = g_thread_try_new ("cmacs-libresearch", cmacs_ai_lr__worker,
                             cmacs_ai_lr__job_ref (job), &gerror);
  if (thread == NULL)
    {
      Lisp_Object msg = build_string (gerror != NULL ? gerror->message
                                                     : "cannot start a thread");
      guint id = job->id;

      /* The worker's ref never reached a worker.  */
      cmacs_ai_lr__job_unref (job);
      cmacs_ai_lr__callback_take (id);
      g_hash_table_remove (cmacs_ai_lr__jobs, GUINT_TO_POINTER (id));
      g_clear_error (&gerror);
      xsignal1 (Qcmacs_ai_error, msg);
    }
  /* Detached: the job, not the thread handle, is what anybody waits on. */
  g_thread_unref (thread);
  return make_uint (job->id);
}

static void
cmacs_ai_lr__check_callback (Lisp_Object callback)
{
  if (!NILP (callback) && NILP (Ffunctionp (callback)))
    wrong_type_argument (Qfunctionp, callback);
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-ai--libresearch-search", Fcmacs_ai__libresearch_search,
       Scmacs_ai__libresearch_search, 1, 3, 0,
       doc: /* Search the web through libresearch for QUERY.

Low-level primitive; `cmacs-ai-research-search' is the command.  Runs on
a worker thread and returns an integer request id at once.

When CALLBACK is non-nil it is called once, on the Lisp thread, with
\(:ok :kind search :text TEXT :json JSON), (:error MESSAGE) or
\(:cancelled).  When it is nil, collect the result with
`cmacs-ai--libresearch-poll'.

OPTIONS is a plist:
  :endpoint URL    the libresearchd base URL; default LIBRESEARCH_URL,
                   else http://127.0.0.1:8087
  :token STRING    bearer token; default LIBRESEARCH_TOKEN
  :category CAT    web, images, videos, news or code
  :count N         results to ask for, 1-100
  :site HOST       restrict to one site
  :max-rows N      results shown in TEXT (0 = all)
  :timeout SECS    give up after SECS (default: ai-glib's own)  */)
  (Lisp_Object query, Lisp_Object callback, Lisp_Object options)
{
  static const char *const categories[] =
    { "web", "images", "videos", "news", "code", NULL };
  CmacsAiLrJob *job;
  gchar *category, *site;
  guint count, max_rows;

  CHECK_STRING (query);
  if (SCHARS (query) == 0)
    error ("cmacs-ai--libresearch-search: empty query");
  cmacs_ai_lr__check_callback (callback);
  cmacs_ai_lr__check_common (options);

  count = cmacs_ai_lr__opt_nat (options, ":count", 1, 100);
  max_rows = cmacs_ai_lr__opt_nat (options, ":max-rows", 1, 1000);
  category = cmacs_ai_lr__opt_string (options, ":category");
  if (category != NULL && !cmacs_ai_lr__one_of (category, categories))
    {
      Lisp_Object bad = build_string (category);
      g_free (category);
      xsignal2 (Qcmacs_ai_error,
                build_string ("category must be web, images, videos, news or code"),
                bad);
    }
  site = NULL;
  {
    Lisp_Object v = cmacs_ai_lr__opt (options, ":site");
    if (!NILP (v) && !STRINGP (v))
      {
        g_free (category);
        wrong_type_argument (Qstringp, v);
      }
    if (STRINGP (v) && SCHARS (v) > 0)
      site = cmacs_dispatch_string_to_utf8 (v);
  }

  job = cmacs_ai_lr__job_new (CMACS_AI_LR_SEARCH, query, options);
  job->category = category;
  job->site = site;
  job->count = count;
  job->max_rows = max_rows;
  return cmacs_ai_lr__launch (job, callback);
}

DEFUN ("cmacs-ai--libresearch-fetch", Fcmacs_ai__libresearch_fetch,
       Scmacs_ai__libresearch_fetch, 1, 3, 0,
       doc: /* Read the page at URL through libresearch.

Low-level primitive; `cmacs-ai-web-fetch' is the command.  CALLBACK and
the result are as in `cmacs-ai--libresearch-search', with :kind fetch.
The server applies its own SSRF guard.

OPTIONS is a plist taking :endpoint, :token and :timeout as in
`cmacs-ai--libresearch-search', plus:
  :max-chars N     longest text to return, 100-1000000 (0 = server default)
  :archive WHICH   never, fallback or only -- whether the Wayback Machine
                   may stand in for the live page (default never)  */)
  (Lisp_Object url, Lisp_Object callback, Lisp_Object options)
{
  static const char *const archives[] = { "never", "fallback", "only", NULL };
  CmacsAiLrJob *job;
  gchar *archive;
  guint max_chars;

  CHECK_STRING (url);
  if (SCHARS (url) == 0)
    error ("cmacs-ai--libresearch-fetch: empty URL");
  cmacs_ai_lr__check_callback (callback);
  cmacs_ai_lr__check_common (options);

  max_chars = cmacs_ai_lr__opt_nat (options, ":max-chars", 100, 1000000);
  archive = cmacs_ai_lr__opt_string (options, ":archive");
  if (archive != NULL && !cmacs_ai_lr__one_of (archive, archives))
    {
      Lisp_Object bad = build_string (archive);
      g_free (archive);
      xsignal2 (Qcmacs_ai_error,
                build_string ("archive must be never, fallback or only"),
                bad);
    }

  job = cmacs_ai_lr__job_new (CMACS_AI_LR_FETCH, url, options);
  job->archive = archive;
  job->max_chars = max_chars;
  return cmacs_ai_lr__launch (job, callback);
}

DEFUN ("cmacs-ai--libresearch-lql", Fcmacs_ai__libresearch_lql,
       Scmacs_ai__libresearch_lql, 1, 3, 0,
       doc: /* Run the LQL query LQL on a libresearch server.

Low-level primitive; `cmacs-ai-lql' is the command.  CALLBACK and the
result are as in `cmacs-ai--libresearch-search', with :kind lql.  An
invalid query comes back as (:error MESSAGE) carrying the server's
position and caret excerpt.

OPTIONS is a plist taking :endpoint, :token and :timeout as in
`cmacs-ai--libresearch-search', plus:
  :explain BOOL    plan the query without running it
  :max-rows N      rows shown in TEXT (0 = all)  */)
  (Lisp_Object lql, Lisp_Object callback, Lisp_Object options)
{
  CmacsAiLrJob *job;
  guint max_rows;
  bool explain;

  CHECK_STRING (lql);
  if (SCHARS (lql) == 0)
    error ("cmacs-ai--libresearch-lql: empty query");
  cmacs_ai_lr__check_callback (callback);
  cmacs_ai_lr__check_common (options);

  max_rows = cmacs_ai_lr__opt_nat (options, ":max-rows", 1, 100000);
  explain = !NILP (cmacs_ai_lr__opt (options, ":explain"));

  job = cmacs_ai_lr__job_new (CMACS_AI_LR_LQL, lql, options);
  job->flag = explain;
  job->max_rows = max_rows;
  return cmacs_ai_lr__launch (job, callback);
}

DEFUN ("cmacs-ai--libresearch-research", Fcmacs_ai__libresearch_research,
       Scmacs_ai__libresearch_research, 1, 3, 0,
       doc: /* Ask a libresearch server for a cited answer to QUESTION.

Low-level primitive; `cmacs-ai-research' is the command.  CALLBACK and
the result are as in `cmacs-ai--libresearch-search', with :kind
research.  A run takes minutes.  A server whose research module is not
active answers (:error MESSAGE).

OPTIONS is a plist taking :endpoint, :token and :timeout as in
`cmacs-ai--libresearch-search', plus:
  :deep BOOL       let the server's model run follow-up searches
  :pages N         pages to read, 1-20 (0 = server default)  */)
  (Lisp_Object question, Lisp_Object callback, Lisp_Object options)
{
  CmacsAiLrJob *job;
  guint pages;
  bool deep;

  CHECK_STRING (question);
  if (SCHARS (question) == 0)
    error ("cmacs-ai--libresearch-research: empty question");
  cmacs_ai_lr__check_callback (callback);
  cmacs_ai_lr__check_common (options);

  pages = cmacs_ai_lr__opt_nat (options, ":pages", 1, 20);
  deep = !NILP (cmacs_ai_lr__opt (options, ":deep"));

  job = cmacs_ai_lr__job_new (CMACS_AI_LR_RESEARCH, question, options);
  job->flag = deep;
  job->pages = pages;
  return cmacs_ai_lr__launch (job, callback);
}

DEFUN ("cmacs-ai--libresearch-environment",
       Fcmacs_ai__libresearch_environment,
       Scmacs_ai__libresearch_environment, 0, 2, 0,
       doc: /* Read a libresearch server's LQL environment.

Low-level primitive; `cmacs-ai-research-environment' is the command.
The environment is the authoritative list of the commands, sources,
functions and constants a query on that server may name.  CALLBACK and
the result are as in `cmacs-ai--libresearch-search', with :kind
environment; TEXT is the document pretty-printed.  OPTIONS takes
:endpoint, :token and :timeout.  */)
  (Lisp_Object callback, Lisp_Object options)
{
  CmacsAiLrJob *job;

  cmacs_ai_lr__check_callback (callback);
  cmacs_ai_lr__check_common (options);
  job = cmacs_ai_lr__job_new (CMACS_AI_LR_ENVIRONMENT, Qnil, options);
  return cmacs_ai_lr__launch (job, callback);
}

DEFUN ("cmacs-ai--libresearch-poll", Fcmacs_ai__libresearch_poll,
       Scmacs_ai__libresearch_poll, 1, 1, 0,
       doc: /* Return the result of libresearch request ID, or nil while pending.

The result is the payload a callback would have received.  Collecting
it forgets the request, and a callback registered for it is then never
called.  Signals `cmacs-ai-error' for an ID that is unknown -- never
issued, or already collected.  */)
  (Lisp_Object id)
{
  CmacsAiLrJob *job;
  Lisp_Object payload;
  gboolean done;

  CHECK_FIXNAT (id);
  job = cmacs_ai_lr__jobs != NULL
    ? g_hash_table_lookup (cmacs_ai_lr__jobs,
                           GUINT_TO_POINTER ((guint) XFIXNAT (id)))
    : NULL;
  if (job == NULL)
    xsignal2 (Qcmacs_ai_error,
              build_string ("no such libresearch request"), id);

  g_mutex_lock (&job->lock);
  done = job->done;
  g_mutex_unlock (&job->lock);
  if (!done)
    return Qnil;

  payload = cmacs_ai_lr__payload (job);
  cmacs_ai_lr__callback_take (job->id);
  g_hash_table_remove (cmacs_ai_lr__jobs,
                       GUINT_TO_POINTER ((guint) XFIXNAT (id)));
  return payload;
}

DEFUN ("cmacs-ai--libresearch-cancel", Fcmacs_ai__libresearch_cancel,
       Scmacs_ai__libresearch_cancel, 1, 1, 0,
       doc: /* Cancel libresearch request ID.

Returns t when ID names a request still in the registry, nil otherwise.
The request still finishes, once, as (:cancelled) -- through its
callback, or through `cmacs-ai--libresearch-poll'.  */)
  (Lisp_Object id)
{
  CmacsAiLrJob *job;

  CHECK_FIXNAT (id);
  if (cmacs_ai_lr__jobs == NULL)
    return Qnil;
  job = g_hash_table_lookup (cmacs_ai_lr__jobs,
                             GUINT_TO_POINTER ((guint) XFIXNAT (id)));
  if (job == NULL)
    return Qnil;
  g_cancellable_cancel (job->cancellable);
  return Qt;
}

DEFUN ("cmacs-ai--libresearch-format", Fcmacs_ai__libresearch_format,
       Scmacs_ai__libresearch_format, 2, 3, 0,
       doc: /* Render the libresearch JSON document JSON as text for KIND.

KIND is `search', `fetch', `lql', `research' or `environment'.  The text
is ai-glib's own rendering, the same the request primitives return as
:text; MAX-ROWS caps the results or rows shown for `search' and `lql'
\(nil or 0 = all).  Needs no server, which is what makes it the place to
test a rendering against a canned document.  */)
  (Lisp_Object kind, Lisp_Object json, Lisp_Object max_rows)
{
  CmacsAiLrKind k;
  g_autofree gchar *utf8 = NULL;
  g_autofree gchar *out = NULL;
  g_autoptr (GError) gerror = NULL;
  JsonNode *doc;
  guint rows = 0;
  Lisp_Object result;

  CHECK_SYMBOL (kind);
  CHECK_STRING (json);
  if (!NILP (max_rows))
    {
      CHECK_FIXNAT (max_rows);
      rows = (guint) min (XFIXNAT (max_rows), G_MAXUINT);
    }

  if (EQ (kind, intern ("search")))
    k = CMACS_AI_LR_SEARCH;
  else if (EQ (kind, intern ("fetch")))
    k = CMACS_AI_LR_FETCH;
  else if (EQ (kind, intern ("lql")))
    k = CMACS_AI_LR_LQL;
  else if (EQ (kind, intern ("research")))
    k = CMACS_AI_LR_RESEARCH;
  else if (EQ (kind, intern ("environment")))
    k = CMACS_AI_LR_ENVIRONMENT;
  else
    xsignal2 (Qcmacs_ai_error,
              build_string ("unknown libresearch document kind"), kind);

  utf8 = cmacs_dispatch_string_to_utf8 (json);
  doc = json_from_string (utf8, &gerror);
  if (doc == NULL || !JSON_NODE_HOLDS_OBJECT (doc))
    {
      Lisp_Object msg = build_string (gerror != NULL ? gerror->message
                                                     : "not a JSON object");
      if (doc != NULL)
        json_node_unref (doc);
      g_clear_error (&gerror);
      xsignal1 (Qcmacs_ai_error, msg);
    }

  out = cmacs_ai_lr__format (k, doc, rows);
  json_node_unref (doc);
  result = build_string (out != NULL ? out : "");
  return result;
}

DEFUN ("cmacs-ai--libresearch-default-endpoint",
       Fcmacs_ai__libresearch_default_endpoint,
       Scmacs_ai__libresearch_default_endpoint, 0, 0, 0,
       doc: /* Return ai-glib's built-in libresearch endpoint, a URL string.  */)
  (void)
{
  return build_string (AI_LIBRESEARCH_DEFAULT_ENDPOINT);
}

/* ── Registration ───────────────────────────────────────────────── */

void syms_of_cmacs_ai_libresearch_defuns (void);

void
syms_of_cmacs_ai_libresearch_defuns (void)
{
  Vcmacs_ai__libresearch_callbacks = Qnil;
  staticpro (&Vcmacs_ai__libresearch_callbacks);

  defsubr (&Scmacs_ai__libresearch_search);
  defsubr (&Scmacs_ai__libresearch_fetch);
  defsubr (&Scmacs_ai__libresearch_lql);
  defsubr (&Scmacs_ai__libresearch_research);
  defsubr (&Scmacs_ai__libresearch_environment);
  defsubr (&Scmacs_ai__libresearch_poll);
  defsubr (&Scmacs_ai__libresearch_cancel);
  defsubr (&Scmacs_ai__libresearch_format);
  defsubr (&Scmacs_ai__libresearch_default_endpoint);
}

#endif /* HAVE_CMACS_AI */
