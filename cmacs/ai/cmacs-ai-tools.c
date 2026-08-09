/* cmacs-ai-tools.c --- AiToolExecutor wrapper + Elisp custom tools.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Wraps `AiToolExecutor' (which carries ai-glib's built-in
 * bash/read/write/edit/glob/grep/web_fetch implementations) for use
 * from Elisp.  Custom tools registered from Elisp dispatch their
 * callback through the staticpro'd `Vcmacs_ai__tool_callbacks' hash
 * (Lisp_Object stays GC-rooted across the multi-turn loop) and run
 * synchronously on the cmacs main thread when the model invokes
 * them.
 *
 * The full multi-turn loop (`cmacs-ai-tools-run-async') drives
 * `ai_tool_executor_run' on a GThread worker and posts the final
 * answer back via the cookie pattern. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
/* ENCODE_FILE, for handing a directory name to a subprocess in the
 * filesystem's encoding rather than Emacs's internal one. */
#include "coding.h"
#include "cmacs-ai.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#ifdef HAVE_CMACS_MCP
#include "cmacs-mcp.h"
#include "cmacs-ai-mcp-bridge.h"
#endif

#include <ai-glib.h>
#include <glib.h>

/* ── Per-executor callback registry (staticpro'd) ───────────────── */
/* Keyed by composite "tool-name@executor-id" string so the same tool
 * name can have different implementations across executors.  The
 * value is the Elisp callable supplied at registration. */

static Lisp_Object Vcmacs_ai__tool_callbacks;
static guint       cmacs_ai__next_exec_id = 1;

/* The Emacs main GThread, set by init_cmacs_ai (declared in cmacs-ai.h).
 * Gates whether a tool callback may return a Lisp value to the model. */
GThread *cmacs_ai__main_gthread = NULL;

static void
cmacs_ai_tools__cb_init (void)
{
  if (!NILP (Vcmacs_ai__tool_callbacks)) return;
  Vcmacs_ai__tool_callbacks =
    CALLN (Fmake_hash_table, QCtest, Qequal);
}

static Lisp_Object
cmacs_ai_tools__cb_key (guint exec_id, const gchar *tool_name)
{
  g_autofree gchar *k = g_strdup_printf ("%u@%s", exec_id, tool_name);
  return build_string (k);
}

/* Drop every callback registered against EXEC_ID.
 *
 * The table is staticpro'd, so an entry left behind is a Lisp closure
 * rooted for the life of the process -- one per tool per executor, and
 * the brigade installs an agent's whole allowlist on each.  Freeing the
 * executor without this leaked them all, silently and permanently.
 *
 * Collected first and removed second: `maphash' must not mutate the
 * table it is walking.  */
static void
cmacs_ai_tools__cb_forget (guint exec_id)
{
  g_autofree gchar *prefix = NULL;
  Lisp_Object doomed = Qnil;
  ptrdiff_t plen;

  if (NILP (Vcmacs_ai__tool_callbacks)) return;

  prefix = g_strdup_printf ("%u@", exec_id);
  plen = strlen (prefix);

  DOHASH (XHASH_TABLE (Vcmacs_ai__tool_callbacks), k, v)
    {
      (void) v;
      if (STRINGP (k)
	  && SBYTES (k) >= plen
	  && memcmp (SSDATA (k), prefix, plen) == 0)
	doomed = Fcons (k, doomed);
    }

  for (; CONSP (doomed); doomed = XCDR (doomed))
    Fremhash (XCAR (doomed), Vcmacs_ai__tool_callbacks);
}

/* ── Executor handle registry ───────────────────────────────────── */

static GHashTable *cmacs_ai__executors = NULL;   /* guint -> AiToolExecutor* */
static GMutex      cmacs_ai__executor_mutex;

static void
cmacs_ai__executor_registry_init (void)
{
  static gboolean done = FALSE;
  if (done) return;
  done = TRUE;
  g_mutex_init (&cmacs_ai__executor_mutex);
  cmacs_ai__executors =
    g_hash_table_new_full (g_direct_hash, g_direct_equal,
                           NULL, g_object_unref);
}

AiToolExecutor *
cmacs_ai_tools_new_default (void)
{
  return ai_tool_executor_new ();
}

AiToolExecutor *
cmacs_ai_tools_lookup (guint handle)
{
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  AiToolExecutor *exec = g_hash_table_lookup (cmacs_ai__executors,
                                              GUINT_TO_POINTER (handle));
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  return exec;
}

/* ── Custom tool callback bridge ────────────────────────────────── */

typedef struct
{
  guint    exec_id;
  gchar   *tool_name;     /* owned */
} CmacsAiToolCtx;

static void
cmacs_ai_tool_ctx_free (gpointer p)
{
  CmacsAiToolCtx *c = p;
  if (!c) return;
  g_free (c->tool_name);
  g_free (c);
}

/* One Elisp tool call, marshalled from a worker thread to the main one.
 *
 * Everything crossing the boundary is a C string.  Emacs's allocator is
 * not thread-safe, so `build_string' -- and therefore every Lisp_Object
 * in this call -- has to happen on the main thread; a worker that built
 * them itself would corrupt the heap under a concurrent GC.  For the
 * same reason there is no Lisp_Object in this struct: one sitting in
 * C-heap memory across a GC is unrooted and would be collected. */
typedef struct
{
  gint      refs;          /* worker + pending main-thread source */
  guint     exec_id;
  gchar    *tool_name;     /* owned */
  gchar    *input_json;    /* owned */
  gchar    *tool_id;       /* owned */
  gchar    *result;        /* out, owned; NULL when error is set */
  gchar    *error;         /* out, owned */
  gboolean  done;
  GMutex    lock;
  GCond     cond;
} CmacsAiToolCall;

/* Reference counted, because the worker may give up waiting while the
 * main-thread source is still queued.  A stack-allocated struct could
 * not be abandoned -- the source would write into a dead frame -- so
 * whichever side finishes last frees it. */
static CmacsAiToolCall *
cmacs_ai_tool_call_new (guint exec_id, const gchar *tool_name,
                        const gchar *input_json, const gchar *tool_id)
{
  CmacsAiToolCall *c = g_new0 (CmacsAiToolCall, 1);
  c->refs       = 2;
  c->exec_id    = exec_id;
  c->tool_name  = g_strdup (tool_name);
  c->input_json = g_strdup (input_json);
  c->tool_id    = g_strdup (tool_id ? tool_id : "");
  g_mutex_init (&c->lock);
  g_cond_init (&c->cond);
  return c;
}

static void
cmacs_ai_tool_call_unref (CmacsAiToolCall *c)
{
  if (c == NULL || !g_atomic_int_dec_and_test (&c->refs))
    return;
  g_free (c->tool_name);
  g_free (c->input_json);
  g_free (c->tool_id);
  g_free (c->result);
  g_free (c->error);
  g_cond_clear (&c->cond);
  g_mutex_clear (&c->lock);
  g_free (c);
}

/* Run one Elisp tool on the main thread.  Always signals, on every
 * path: a worker is asleep on the condition and a path that returned
 * without signalling would leave it there for good. */
static gboolean
cmacs_ai_tool__call_on_main (gpointer user)
{
  CmacsAiToolCall *c = user;
  Lisp_Object key = cmacs_ai_tools__cb_key (c->exec_id, c->tool_name);
  Lisp_Object cb  = Fgethash (key, Vcmacs_ai__tool_callbacks, Qnil);

  if (NILP (cb))
    c->error = g_strdup_printf ("cmacs-ai: no callback registered for tool %s",
                                c->tool_name);
  else
    {
      /* The callback is called as (CB NAME INPUT-JSON ID) and must
       * return a string.  safe_callN_value so a Lisp error in one tool
       * does not abort the whole loop. */
      Lisp_Object args[3];
      args[0] = build_string (c->tool_name);
      args[1] = build_string (c->input_json);
      args[2] = build_string (c->tool_id);

      Lisp_Object rv = cmacs_dispatch_safe_callN_value (cb, 3, args);
      if (STRINGP (rv))
        c->result = g_strdup (SSDATA (rv));
      else if (NILP (rv))
        c->error = g_strdup_printf ("cmacs-ai: tool '%s' returned nil",
                                    c->tool_name);
      else
        {
          /* Non-string, non-nil: hand the model its printed form. */
          Lisp_Object printed = Fprin1_to_string (rv, Qnil, Qnil);
          c->result = g_strdup (SSDATA (printed));
        }
    }

  g_mutex_lock (&c->lock);
  c->done = TRUE;
  g_cond_signal (&c->cond);
  g_mutex_unlock (&c->lock);
  cmacs_ai_tool_call_unref (c);
  return G_SOURCE_REMOVE;
}

static gchar *
cmacs_ai_tool__elisp_dispatch (AiToolUse    *tool_use,
                               GCancellable *cancellable,
                               GError      **error,
                               gpointer      user_data)
{
  (void) cancellable;
  CmacsAiToolCtx *ctx = user_data;
  JsonNode *in = ai_tool_use_get_input (tool_use);
  g_autofree gchar *input_str = in
    ? json_to_string (in, FALSE) : g_strdup ("{}");
  CmacsAiToolCall *call =
    cmacs_ai_tool_call_new (ctx->exec_id, ctx->tool_name, input_str,
                            ai_tool_use_get_id (tool_use));
  gchar *result = NULL;
  gboolean timed_out = FALSE;

  if (cmacs_ai__main_gthread != NULL
      && g_thread_self () == cmacs_ai__main_gthread)
    {
      /* Already on the main thread -- the synchronous `cmacs-ai-call'
       * path.  Going through the invoke would deadlock: the source
       * cannot run until this call returns. */
      cmacs_ai_tool__call_on_main (call);
    }
  else
    {
      /* From `cmacs-ai-tools-run-async''s worker.  Hand the call to the
       * main thread and wait for its answer, so the model gets what the
       * tool actually returned.  This used to return the placeholder
       * string "(cmacs-ai tool dispatched)" and discard the real result,
       * which made every Elisp tool -- so every brigade tool -- useless
       * to an in-process agent. */
      gint64 deadline = g_get_monotonic_time ()
        + cmacs_ai_tool_call_timeout * G_TIME_SPAN_SECOND;

      g_main_context_invoke (cmacs_glib_get_context (),
                             cmacs_ai_tool__call_on_main, call);

      g_mutex_lock (&call->lock);
      while (!call->done && !timed_out)
        {
          if (!g_cond_wait_until (&call->cond, &call->lock, deadline))
            timed_out = TRUE;
        }
      g_mutex_unlock (&call->lock);
    }

  if (timed_out)
    {
      /* Give up on this one tool rather than park the worker for the
       * rest of the session.  The source still holds a reference, so it
       * is free to fire later and write into a struct that is still
       * alive; whichever side unrefs last frees it. */
      g_set_error (error, AI_ERROR, AI_ERROR_TOOL_ERROR,
                   "cmacs-ai: tool '%s' timed out after %d seconds waiting "
                   "for the Emacs main thread",
                   ctx->tool_name, (int) cmacs_ai_tool_call_timeout);
      cmacs_ai_tool_call_unref (call);
      return NULL;
    }

  if (call->error != NULL)
    g_set_error_literal (error, AI_ERROR, AI_ERROR_INVALID_REQUEST,
                         call->error);
  else
    result = g_strdup (call->result);

  cmacs_ai_tool_call_unref (call);
  return result;
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-ai-tools-new", Fcmacs_ai_tools_new,
       Scmacs_ai_tools_new, 0, 0, 0,
       doc: /* Create an AiToolExecutor with the default built-in
tools (bash, read, write, edit, glob, grep, ls, web_fetch).
Returns an integer handle.  Free with `cmacs-ai-tools-free'.  */)
  (void)
{
  cmacs_ai__executor_registry_init ();
  AiToolExecutor *exec = cmacs_ai_tools_new_default ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  guint h = cmacs_ai__next_exec_id++;
  g_hash_table_insert (cmacs_ai__executors, GUINT_TO_POINTER (h), exec);
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  return make_uint (h);
}

DEFUN ("cmacs-ai-tools-free", Fcmacs_ai_tools_free,
       Scmacs_ai_tools_free, 1, 1, 0,
       doc: /* Free tool-executor HANDLE and forget its tool callbacks.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  g_hash_table_remove (cmacs_ai__executors, GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  cmacs_ai_tools__cb_forget (XFIXNUM (handle));
  return Qt;
}

DEFUN ("cmacs-ai-tools-register",
       Fcmacs_ai_tools_register,
       Scmacs_ai_tools_register, 4, 4, 0,
       doc: /* Register CALLBACK as a custom tool on EXECUTOR.
NAME is the tool name (string), DESCRIPTION is its summary (string),
PARAMS is an alist ((NAME TYPE DESCRIPTION REQUIRED-P) ...).
CALLBACK is (lambda (NAME INPUT-JSON ID) ...) called when the model
invokes the tool.  */)
  (Lisp_Object executor, Lisp_Object name, Lisp_Object description,
   Lisp_Object params_and_callback)
{
  /* PARAMS and CALLBACK passed as a cons (PARAMS . CALLBACK) because
   * defsubr maxes at MANY for variadic; we keep arity fixed at 4. */
  CHECK_FIXNAT (executor);
  CHECK_STRING (name);
  CHECK_STRING (description);
  CHECK_CONS (params_and_callback);
  Lisp_Object params   = XCAR (params_and_callback);
  Lisp_Object callback = XCDR (params_and_callback);

  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  AiToolExecutor *exec = g_hash_table_lookup (cmacs_ai__executors,
                                              GUINT_TO_POINTER (XFIXNUM (executor)));
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  g_autoptr (AiTool) tool = ai_tool_new (SSDATA (name), SSDATA (description));
  Lisp_Object tail = params;
  FOR_EACH_TAIL_SAFE (tail)
    {
      Lisp_Object p = XCAR (tail);
      if (!CONSP (p)) continue;
      Lisp_Object pname = Fnth (make_fixnum (0), p);
      Lisp_Object ptype = Fnth (make_fixnum (1), p);
      Lisp_Object pdesc = Fnth (make_fixnum (2), p);
      Lisp_Object preq  = Fnth (make_fixnum (3), p);
      if (!STRINGP (pname) || !STRINGP (ptype) || !STRINGP (pdesc))
        continue;
      ai_tool_add_parameter (tool, SSDATA (pname), SSDATA (ptype),
                             SSDATA (pdesc), !NILP (preq));
    }

  cmacs_ai_tools__cb_init ();
  Lisp_Object key = cmacs_ai_tools__cb_key (XFIXNUM (executor), SSDATA (name));
  Fputhash (key, callback, Vcmacs_ai__tool_callbacks);

  CmacsAiToolCtx *ctx = g_new0 (CmacsAiToolCtx, 1);
  ctx->exec_id   = XFIXNUM (executor);
  ctx->tool_name = g_strdup (SSDATA (name));
  ai_tool_executor_register_callback (exec, tool,
                                       cmacs_ai_tool__elisp_dispatch,
                                       ctx, cmacs_ai_tool_ctx_free);
  return Qt;
}

/* ── Async tool-loop runner ─────────────────────────────────────── */

/* Read once, on the main thread, at the point of use.  DEFVAR_INT
 * variables are plain C globals a user can set from Lisp at any time; the
 * indirection is only so the clamp lives in one place. */
static gint
cmacs_ai_tools__history_limit (void)
{
  return (gint) cmacs_ai_history_limit;
}

typedef struct
{
  AiToolExecutor *exec;     /* owned ref */
  AiProvider     *provider; /* owned ref */
  GList          *messages; /* (transfer container); each AiMessage owned */
  gchar          *system_prompt;
  gint            max_tokens;
  uint64_t        cb_cookie;
  gchar          *result;   /* set in worker; read on main */
  GError         *error;    /* set in worker; read on main */
  /* Which session to fold the run's own messages back into, by handle
   * rather than by pointer: the session may be freed while the worker is
   * still going, and a stale pointer would be dereferenced on the main
   * thread long after.  Zero means do not fold anything back. */
  guint           session_id;
  /* (transfer full) the assistant turns and tool results the run
   * produced.  Set in the worker, consumed on the main thread. */
  GList          *new_messages;
} CmacsAiToolsJob;

static void
cmacs_ai_tools_job__free (CmacsAiToolsJob *j)
{
  if (!j) return;
  g_clear_object (&j->exec);
  g_clear_object (&j->provider);
  g_list_free_full (j->messages, g_object_unref);
  g_list_free_full (j->new_messages, g_object_unref);
  g_free (j->system_prompt);
  g_free (j->result);
  if (j->error) g_error_free (j->error);
  g_free (j);
}

static gboolean
cmacs_ai_tools__main_done (gpointer user)
{
  CmacsAiToolsJob *j = user;
  Lisp_Object payload;

  /* Fold the run's own messages back into the session before the
   * callback fires, so anything the callback does -- including starting
   * the next turn -- sees a session that remembers this one.
   *
   * Without this the tool executor's work was simply discarded: it
   * copies the caller's message list, appends the assistant turns and
   * tool results to its copy, and frees the lot.  A second turn on the
   * same session therefore showed the model its original instruction and
   * the new question, with no trace of what it had already said or
   * done -- which is not a continued conversation, just a fresh one
   * wearing the same handle.
   *
   * Looked up by handle here: freeing the session mid-run is legal, and
   * finding it gone simply means there is nothing to fold into. */
  if (j->session_id != 0 && j->new_messages != NULL)
    {
      CmacsAiSession *sess = cmacs_ai_session_lookup (j->session_id);
      if (sess != NULL)
        {
          GList *l;
          for (l = j->new_messages; l != NULL; l = l->next)
            cmacs_ai_session_append_message_obj (sess, l->data);
          cmacs_ai_session_trim (sess, cmacs_ai_tools__history_limit ());
        }
    }

  if (j->result)
    payload = list2 (intern (":text"), build_string (j->result));
  else
    payload = list2 (intern (":error"),
                     build_string (j->error ? j->error->message
                                            : "tool loop failed"));
  cmacs_dispatch_callback_invoke1 (j->cb_cookie, payload);
  cmacs_ai_tools_job__free (j);
  return G_SOURCE_REMOVE;
}

static gpointer
cmacs_ai_tools__worker (gpointer user)
{
  CmacsAiToolsJob *j = user;
  GMainContext *ctx;

  /* A PRIVATE main context, pushed as this thread's default for the
   * duration of the run.  Without it the whole point of the worker is
   * lost, in a way that is invisible until something blocks:
   *
   * `ai_tool_executor_run' binds its GMainLoop to the thread-default
   * context, and with none pushed that is the process-global default --
   * the very context Emacs's own loop iterates from `xg_select'.  The
   * provider's libsoup calls attach there too.  So the main thread won
   * the race to own that context, dispatched the HTTP completion, and
   * ran the model's tool calls itself, while this thread sat in
   * g_main_context_wait_internal waiting for a context it would never
   * get.  A `bash' tool running `just bootstrap' then blocked the
   * editor in wait4 for the length of a full build.
   *
   * With a private context the loop, the HTTP completion and the tool
   * calls all belong to this thread, and Emacs never touches them.  */
  ctx = g_main_context_new ();
  g_main_context_push_thread_default (ctx);

  j->result = ai_tool_executor_run_full (j->exec, j->provider,
                                         j->messages, j->system_prompt,
                                         j->max_tokens, NULL,
                                         &j->new_messages, &j->error);

  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);

  g_main_context_invoke (cmacs_glib_get_context (),
                         cmacs_ai_tools__main_done, j);
  return NULL;
}

DEFUN ("cmacs-ai-tools-run-async", Fcmacs_ai_tools_run_async,
       Scmacs_ai_tools_run_async, 3, 3, 0,
       doc: /* Run the multi-turn tool loop on SESSION using EXECUTOR.
CALLBACK is fired once with (:text TEXT) on success or (:error MSG) on
failure.  All current session messages are sent.

The messages the run produces -- the assistant's turns and the results of
any tools it called -- are appended back onto SESSION before CALLBACK
fires, so running again on the same session continues the conversation
rather than restarting it.  The session is then trimmed to
`cmacs-ai-history-limit'.  */)
  (Lisp_Object session, Lisp_Object executor, Lisp_Object callback)
{
  CHECK_FIXNAT (session);
  CHECK_FIXNAT (executor);
  CmacsAiSession *sess = cmacs_ai_session_lookup (XFIXNUM (session));
  if (sess == NULL) error ("cmacs-ai: bad session handle");
  AiProvider *prov = cmacs_ai_session_get_provider (sess);
  if (prov == NULL) error ("cmacs-ai: session has no live client");
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  AiToolExecutor *exec = g_hash_table_lookup (cmacs_ai__executors,
                                              GUINT_TO_POINTER (XFIXNUM (executor)));
  if (exec) g_object_ref (exec);
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  CmacsAiToolsJob *j = g_new0 (CmacsAiToolsJob, 1);
  j->exec       = exec;
  j->provider   = g_object_ref (prov);
  /* Deep-copy the message list: the session is owned by the main
   * thread; we hand a snapshot to the worker. */
  GList *snapshot = NULL;
  for (GList *l = cmacs_ai_session_get_messages (sess); l; l = l->next)
    snapshot = g_list_append (snapshot, g_object_ref (l->data));
  j->messages   = snapshot;
  j->max_tokens = 4096;
  j->session_id = XFIXNUM (session);
  j->cb_cookie  = cmacs_dispatch_callback_register (callback);

  GThread *t = g_thread_new ("cmacs-ai-tools", cmacs_ai_tools__worker, j);
  g_thread_unref (t);
  return Qt;
}

DEFUN ("cmacs-ai-tools-execute-into-session",
       Fcmacs_ai_tools_execute_into_session,
       Scmacs_ai_tools_execute_into_session, 5, 5, 0,
       doc: /* Execute one tool call and append a tool_result message to SESSION.
EXECUTOR is the tool-executor handle.  TOOL-NAME, TOOL-INPUT-JSON,
and TOOL-ID identify the tool_use block emitted by the model.  The
tool is executed synchronously on the calling thread; the result
text (or an error string prefixed with the failure) is appended to
SESSION's message history as a tool_result message keyed by TOOL-ID.

Returns the result text on success or an error description (string)
on failure.  Use `cmacs-ai-chat-continue-stream' after this to ask
the model to continue with the new context.  */)
  (Lisp_Object session, Lisp_Object executor,
   Lisp_Object tool_name, Lisp_Object tool_input_json, Lisp_Object tool_id)
{
  CHECK_FIXNAT (session);
  CHECK_FIXNAT (executor);
  CHECK_STRING (tool_name);
  CHECK_STRING (tool_input_json);
  CHECK_STRING (tool_id);
  CmacsAiSession *sess = cmacs_ai_session_lookup (XFIXNUM (session));
  if (sess == NULL) error ("cmacs-ai: bad session handle");
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  AiToolExecutor *exec =
    g_hash_table_lookup (cmacs_ai__executors,
                         GUINT_TO_POINTER (XFIXNUM (executor)));
  if (exec) g_object_ref (exec);
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  /* Reconstruct an AiToolUse from the plist payload. */
  g_autoptr (AiToolUse) tu = ai_tool_use_new_from_json_string (
    SSDATA (tool_id), SSDATA (tool_name), SSDATA (tool_input_json));

  g_autoptr (GError) err = NULL;
  g_autofree gchar *result = ai_tool_executor_execute (exec, tu, NULL, &err);
  g_object_unref (exec);

  gboolean is_error = (result == NULL);
  const gchar *content = result
    ? result
    : (err ? err->message : "tool execution failed");

  /* Append a tool_result message keyed by ID + name (the _with_name
   * variant round-trips through Gemini's wire format). */
  AiMessage *rm = ai_message_new_tool_result_with_name (
    SSDATA (tool_id), SSDATA (tool_name), content, is_error);
  cmacs_ai_session_append_message_obj (sess, rm);
  g_object_unref (rm);

  return build_string (content);
}

#ifdef HAVE_CMACS_MCP
/* Lisp list of regexp strings -> GPtrArray<const gchar *>.
 * The returned array does NOT own its strings; the caller must keep
 * the Lisp list alive for the duration of the use. */
static GPtrArray *
cmacs_ai__lisp_regex_list (Lisp_Object lst)
{
  if (NILP (lst)) return NULL;
  GPtrArray *out = g_ptr_array_new ();
  Lisp_Object tail = lst;
  FOR_EACH_TAIL_SAFE (tail)
    {
      Lisp_Object s = XCAR (tail);
      if (STRINGP (s))
        g_ptr_array_add (out, SSDATA (s));
    }
  return out;
}

DEFUN ("cmacs-ai-tools-register-mcp-bridge",
       Fcmacs_ai_tools_register_mcp_bridge,
       Scmacs_ai_tools_register_mcp_bridge, 1, 4, 0,
       doc: /* Register cmacs MCP tools on EXECUTOR as ai-glib tool callbacks.

Enumerates the tools registered on cmacs's process-lifetime internal
McpServer (see `cmacs_mcp_get_internal_server') and adds each one that
passes the filters as a custom AiToolCallback on EXECUTOR.  When the
model invokes one of these tools, the callback routes back through
`mcp_server_invoke_tool', running the SAME handler an external MCP
client would hit.

ALLOWLIST is a list of regexp strings; a tool is kept iff some regex
matches its name (nil/omitted means match all).  DENYLIST is similar;
\"\\\\`ai_\" is always implicitly added to prevent AI-driving-AI
recursion.  READONLY-ONLY = t restricts to tools flagged with the
MCP read-only hint.

Returns the integer count of tools successfully registered.  */)
  (Lisp_Object executor, Lisp_Object allowlist,
   Lisp_Object denylist, Lisp_Object readonly_only)
{
  CHECK_FIXNAT (executor);
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  AiToolExecutor *exec =
    g_hash_table_lookup (cmacs_ai__executors,
                         GUINT_TO_POINTER (XFIXNUM (executor)));
  if (exec) g_object_ref (exec);
  g_mutex_unlock (&cmacs_ai__executor_mutex);
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  McpServer *server = cmacs_mcp_get_internal_server ();
  if (server == NULL)
    {
      g_object_unref (exec);
      error ("cmacs-ai: cmacs-mcp internal server not initialised");
    }

  g_autoptr (GPtrArray) allow = cmacs_ai__lisp_regex_list (allowlist);
  g_autoptr (GPtrArray) deny  = cmacs_ai__lisp_regex_list (denylist);
  guint n = cmacs_ai_mcp_bridge_register_tools (exec, server,
                                                allow, deny,
                                                !NILP (readonly_only));
  g_object_unref (exec);
  return make_fixnum (n);
}
#endif /* HAVE_CMACS_MCP */

/* ── web_search provider wiring ─────────────────────────────────── */

DEFUN ("cmacs-ai-tools-set-working-directory",
       Fcmacs_ai_tools_set_working_directory,
       Scmacs_ai_tools_set_working_directory, 2, 2, 0,
       doc: /* Run EXECUTOR\'s built-in tools in DIRECTORY.

The built-in tools -- bash, read, write, edit, glob, grep, ls -- resolve
relative paths against DIRECTORY and run commands there.  A nil
DIRECTORY restores the default, which is the directory Emacs itself is
in: whatever buffer you last visited a file from, which is almost never
what an agent meant by "src/main.c".

An absolute path from the model is always used as given.  Returns t.  */)
  (Lisp_Object executor, Lisp_Object directory)
{
  CHECK_FIXNAT (executor);
  if (!NILP (directory))
    CHECK_STRING (directory);

  AiToolExecutor *exec = cmacs_ai_tools_lookup (XFIXNUM (executor));
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  if (NILP (directory))
    ai_tool_executor_set_working_directory (exec, NULL);
  else
    {
      /* ENCODE_FILE, not SSDATA: a directory name is a file name, and
       * the subprocess wants it in the filesystem\'s encoding. */
      Lisp_Object encoded = ENCODE_FILE (Fexpand_file_name (directory, Qnil));
      ai_tool_executor_set_working_directory (exec, SSDATA (encoded));
    }
  return Qt;
}

DEFUN ("cmacs-ai-tools-set-search-provider",
       Fcmacs_ai_tools_set_search_provider,
       Scmacs_ai_tools_set_search_provider, 2, 3, 0,
       doc: /* Enable the web_search tool on EXECUTOR using PROVIDER.

PROVIDER is one of the symbols `auto', `brave', `bing', or
`duckduckgo'.  `auto' uses Brave or Bing when the corresponding API
key is available and otherwise falls back to the keyless DuckDuckGo
backend (best-effort, no SLA).  `brave' and `bing' require an API
key: the optional API-KEY string, or else the BRAVE_API_KEY /
BING_API_KEY environment variable.  `duckduckgo' needs no key.

Registers ai-glib's web_search tool on EXECUTOR so the model can use
it -- and, when it asks, the tool's count/freshness/safesearch/
country/language/site/fetch_content options.  Returns t, or signals
an error when a keyed provider has no key or PROVIDER is unknown.  */)
  (Lisp_Object executor, Lisp_Object provider, Lisp_Object api_key)
{
  CHECK_FIXNAT (executor);
  CHECK_SYMBOL (provider);
  if (!NILP (api_key))
    CHECK_STRING (api_key);

  AiToolExecutor *exec = cmacs_ai_tools_lookup (XFIXNUM (executor));
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  AiSearchProvider *sp = NULL;

  if (EQ (provider, intern ("auto")))
    {
      g_autoptr (GError) err = NULL;
      sp = ai_search_provider_new_default (&err);
      if (sp == NULL)
        error ("cmacs-ai: search provider unavailable: %s",
               err ? err->message : "unknown");
    }
  else if (EQ (provider, intern ("duckduckgo")))
    {
      sp = AI_SEARCH_PROVIDER (ai_duckduckgo_search_new ());
    }
  else if (EQ (provider, intern ("brave")) || EQ (provider, intern ("bing")))
    {
      gboolean     is_brave = EQ (provider, intern ("brave"));
      const gchar *envvar   = is_brave ? "BRAVE_API_KEY" : "BING_API_KEY";
      const gchar *key      = !NILP (api_key) ? SSDATA (api_key)
                                              : g_getenv (envvar);
      if (key == NULL || *key == '\0')
        error ("cmacs-ai: %s search needs an API key (set %s)",
               is_brave ? "Brave" : "Bing", envvar);
      sp = is_brave
           ? AI_SEARCH_PROVIDER (ai_brave_search_new (key))
           : AI_SEARCH_PROVIDER (ai_bing_search_new (key));
    }
  else
    error ("cmacs-ai: unknown search provider `%s'",
           SSDATA (SYMBOL_NAME (provider)));

  if (sp == NULL)
    error ("cmacs-ai: failed to create search provider");

  ai_tool_executor_set_search_provider (exec, sp);
  g_object_unref (sp);   /* the executor took its own ref */
  return Qt;
}

DEFUN ("cmacs-ai-tools-list", Fcmacs_ai_tools_list,
       Scmacs_ai_tools_list, 1, 1, 0,
       doc: /* Return the list of tool-name strings advertised by EXECUTOR.

Includes ai-glib's built-ins (bash, read, write, edit, glob, grep,
ls, web_fetch), web_search once a search provider has been set via
`cmacs-ai-tools-set-search-provider', any custom tools registered
with `cmacs-ai-tools-register', and bridged MCP tools.  */)
  (Lisp_Object executor)
{
  CHECK_FIXNAT (executor);
  AiToolExecutor *exec = cmacs_ai_tools_lookup (XFIXNUM (executor));
  if (exec == NULL) error ("cmacs-ai: bad executor handle");

  Lisp_Object names = Qnil;
  for (GList *l = ai_tool_executor_get_tools (exec); l != NULL; l = l->next)
    {
      const gchar *n = ai_tool_get_name ((AiTool *) l->data);
      if (n != NULL)
        names = Fcons (build_string (n), names);
    }
  return Fnreverse (names);
}

void syms_of_cmacs_ai_tools_defuns (void);
void
syms_of_cmacs_ai_tools_defuns (void)
{
  Vcmacs_ai__tool_callbacks = Qnil;
  staticpro (&Vcmacs_ai__tool_callbacks);

  DEFVAR_INT ("cmacs-ai-tool-call-timeout", cmacs_ai_tool_call_timeout,
	      doc: /* Seconds a background tool loop waits for the Emacs main thread.

An in-process agent runs its tool loop on a worker thread, but an Elisp
tool has to run where Lisp lives, so the worker hands the call to the
main thread and waits for the answer.  The main thread picks it up from
its GLib dispatch, which happens whenever Emacs reaches the event loop --
so in practice this is immediate.

If it does not, the agent gets a timeout error for that one tool call
rather than the worker parking forever.  Raise it if you have Elisp tools
that legitimately take minutes.  */);
  cmacs_ai_tool_call_timeout = 120;

  DEFVAR_INT ("cmacs-ai-history-limit", cmacs_ai_history_limit,
	      doc: /* Most messages a session keeps before the oldest are dropped.

Every turn re-sends the whole session, so a conversation that runs for
dozens of turns costs quadratically in the number of turns -- and does it
quietly, because nothing about a long conversation looks different from a
short one until the bill arrives.

Trimming takes from the oldest end, which is both the part the model is
least likely to still need and the only part it is safe to lose: an
agent's standing instructions live in the system prompt, not in this
list, so they are never what gets dropped.

Zero or negative keeps everything, which is the right setting only if you
are watching the cost yourself.  */);
  cmacs_ai_history_limit = 200;

  defsubr (&Scmacs_ai_tools_new);
  defsubr (&Scmacs_ai_tools_free);
  defsubr (&Scmacs_ai_tools_register);
  defsubr (&Scmacs_ai_tools_run_async);
  defsubr (&Scmacs_ai_tools_execute_into_session);
  defsubr (&Scmacs_ai_tools_set_search_provider);
  defsubr (&Scmacs_ai_tools_set_working_directory);
  defsubr (&Scmacs_ai_tools_list);
#ifdef HAVE_CMACS_MCP
  defsubr (&Scmacs_ai_tools_register_mcp_bridge);
#endif
}

#endif /* HAVE_CMACS_AI */
