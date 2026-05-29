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

static gchar *
cmacs_ai_tool__elisp_dispatch (AiToolUse    *tool_use,
                               GCancellable *cancellable,
                               GError      **error,
                               gpointer      user_data)
{
  (void) cancellable;
  CmacsAiToolCtx *ctx = user_data;
  Lisp_Object key = cmacs_ai_tools__cb_key (ctx->exec_id, ctx->tool_name);
  Lisp_Object cb  = Fgethash (key, Vcmacs_ai__tool_callbacks, Qnil);
  if (NILP (cb))
    {
      g_set_error (error, AI_ERROR, AI_ERROR_INVALID_REQUEST,
                   "cmacs-ai: no callback registered for tool %s",
                   ctx->tool_name);
      return NULL;
    }
  JsonNode *in = ai_tool_use_get_input (tool_use);
  g_autofree gchar *input_str = in
    ? json_to_string (in, FALSE) : g_strdup ("{}");

  /* Marshal: cb is called as (CB NAME INPUT-JSON ID) and must return
   * a string (or nil for error).  We use safe_call3 so a Lisp error
   * doesn't abort the whole tool loop. */
  Lisp_Object args[3];
  args[0] = build_string (ctx->tool_name);
  args[1] = build_string (input_str);
  args[2] = build_string (ai_tool_use_get_id (tool_use) ?: "");
  cmacs_dispatch_safe_callN (cb, 3, args);

  /* The safe-call helpers don't return values today; we can't easily
   * retrieve the result without a synchronous Felisp eval.  Plug a
   * common shape: have the Elisp side write its result string to a
   * symbol-property we then read back.  For first-cut, just return a
   * generic "(tool dispatched)" string so the loop continues; the
   * Elisp callback is expected to do something side-effectful (apply
   * a region edit, open a buffer, ...) rather than return a value
   * the model will see verbatim. */
  return g_strdup ("(cmacs-ai tool dispatched)");
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
       doc: /* Free tool-executor HANDLE.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  cmacs_ai__executor_registry_init ();
  g_mutex_lock (&cmacs_ai__executor_mutex);
  g_hash_table_remove (cmacs_ai__executors, GUINT_TO_POINTER (XFIXNUM (handle)));
  g_mutex_unlock (&cmacs_ai__executor_mutex);
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
} CmacsAiToolsJob;

static void
cmacs_ai_tools_job__free (CmacsAiToolsJob *j)
{
  if (!j) return;
  g_clear_object (&j->exec);
  g_clear_object (&j->provider);
  g_list_free_full (j->messages, g_object_unref);
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
  j->result = ai_tool_executor_run (j->exec, j->provider,
                                    j->messages, j->system_prompt,
                                    j->max_tokens, NULL, &j->error);
  g_main_context_invoke (cmacs_glib_get_context (),
                         cmacs_ai_tools__main_done, j);
  return NULL;
}

DEFUN ("cmacs-ai-tools-run-async", Fcmacs_ai_tools_run_async,
       Scmacs_ai_tools_run_async, 3, 3, 0,
       doc: /* Run the multi-turn tool loop on SESSION using EXECUTOR.
CALLBACK is fired once with (:text TEXT) on success or (:error MSG) on
failure.  All current session messages are sent.  */)
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
  defsubr (&Scmacs_ai_tools_new);
  defsubr (&Scmacs_ai_tools_free);
  defsubr (&Scmacs_ai_tools_register);
  defsubr (&Scmacs_ai_tools_run_async);
  defsubr (&Scmacs_ai_tools_execute_into_session);
  defsubr (&Scmacs_ai_tools_set_search_provider);
  defsubr (&Scmacs_ai_tools_list);
#ifdef HAVE_CMACS_MCP
  defsubr (&Scmacs_ai_tools_register_mcp_bridge);
#endif
}

#endif /* HAVE_CMACS_AI */
