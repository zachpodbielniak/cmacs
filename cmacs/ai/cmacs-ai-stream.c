/* cmacs-ai-stream.c --- AiStreamable signals -> Elisp callbacks.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Maps ai-glib's streaming model (signals: stream-start, delta,
 * tool-use, stream-end) onto a single Elisp callback per stream
 * called repeatedly with a plist payload describing what happened:
 *
 *   (:start)
 *   (:delta TEXT)
 *   (:tool-use NAME INPUT-JSON ID)
 *   (:end :text TEXT :stop SYMBOL)
 *   (:error MESSAGE)
 *
 * The callback is stashed in a staticpro'd Lisp hash table
 * (`Vcmacs_ai__stream_callbacks') keyed by an integer stream id so
 * it stays GC-rooted across the multi-event lifetime.  The cookie
 * pattern in cmacs-eval-dispatch is single-shot and not suitable
 * for streaming.
 *
 * Signal handlers run on cmacs's main thread because ai-glib's
 * GTask completions are dispatched on the default GMainContext,
 * which cmacs-glib drives. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <ai-glib.h>
#include <glib.h>

/* ── Staticpro'd callback table ─────────────────────────────────── */

static Lisp_Object Vcmacs_ai__stream_callbacks;   /* hash: int -> callback */

static void
cmacs_ai_stream__callbacks_init (void)
{
  if (!NILP (Vcmacs_ai__stream_callbacks)) return;
  Vcmacs_ai__stream_callbacks =
    CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
cmacs_ai_stream__callback_lookup (guint stream_id)
{
  cmacs_ai_stream__callbacks_init ();
  return Fgethash (make_uint (stream_id),
                   Vcmacs_ai__stream_callbacks, Qnil);
}

static void
cmacs_ai_stream__callback_set (guint stream_id, Lisp_Object cb)
{
  cmacs_ai_stream__callbacks_init ();
  Fputhash (make_uint (stream_id), cb, Vcmacs_ai__stream_callbacks);
}

static void
cmacs_ai_stream__callback_drop (guint stream_id)
{
  if (NILP (Vcmacs_ai__stream_callbacks)) return;
  Fremhash (make_uint (stream_id), Vcmacs_ai__stream_callbacks);
}

/* ── Per-stream context (C heap; no Lisp_Objects here) ─────────── */

typedef struct
{
  AiStreamable    *streamable;       /* (transfer none); ref held by session */
  guint            session_handle;
  guint            stream_id;
  /* Signal IDs so we can disconnect on stream-end / cancel. */
  gulong           sig_start;
  gulong           sig_delta;
  gulong           sig_tool;
  gulong           sig_end;
  GString         *text;             /* accumulated for final :end payload */
} CmacsAiStream;

static guint cmacs_ai__next_stream_id = 1;

static void
cmacs_ai_stream__free (CmacsAiStream *s)
{
  if (!s) return;
  if (s->streamable)
    {
      if (s->sig_start) g_signal_handler_disconnect (s->streamable, s->sig_start);
      if (s->sig_delta) g_signal_handler_disconnect (s->streamable, s->sig_delta);
      if (s->sig_tool)  g_signal_handler_disconnect (s->streamable, s->sig_tool);
      if (s->sig_end)   g_signal_handler_disconnect (s->streamable, s->sig_end);
    }
  cmacs_ai_stream__callback_drop (s->stream_id);
  if (s->text) g_string_free (s->text, TRUE);
  g_free (s);
}

static void
cmacs_ai_stream__deliver (CmacsAiStream *s, Lisp_Object payload)
{
  Lisp_Object cb = cmacs_ai_stream__callback_lookup (s->stream_id);
  if (!NILP (cb))
    cmacs_dispatch_safe_call1 (cb, payload);
}

/* ── Signal handlers ────────────────────────────────────────────── */

static void
on_stream_start (AiStreamable *src, gpointer user)
{
  (void) src;
  CmacsAiStream *s = user;
  cmacs_ai_stream__deliver (s, list1 (intern (":start")));
}

static void
on_stream_delta (AiStreamable *src, const gchar *text, gpointer user)
{
  (void) src;
  CmacsAiStream *s = user;
  if (text == NULL) return;
  if (s->text) g_string_append (s->text, text);
  cmacs_ai_stream__deliver (s, list2 (intern (":delta"),
                                       build_string (text)));
}

static void
on_stream_tool_use (AiStreamable *src, AiToolUse *tu, gpointer user)
{
  (void) src;
  CmacsAiStream *s = user;
  const gchar *name = ai_tool_use_get_name (tu);
  const gchar *id   = ai_tool_use_get_id   (tu);
  JsonNode    *in   = ai_tool_use_get_input (tu);
  g_autofree gchar *input_str = in
    ? json_to_string (in, FALSE) : g_strdup ("{}");
  cmacs_ai_stream__deliver (s, list4 (intern (":tool-use"),
                                       build_string (name ? name : ""),
                                       build_string (input_str),
                                       build_string (id ? id : "")));
}

static Lisp_Object
cmacs_ai__stop_reason_sym (AiStopReason r)
{
  switch (r)
    {
    case AI_STOP_REASON_END_TURN:       return intern ("end-turn");
    case AI_STOP_REASON_STOP_SEQUENCE:  return intern ("stop-sequence");
    case AI_STOP_REASON_MAX_TOKENS:     return intern ("max-tokens");
    case AI_STOP_REASON_TOOL_USE:       return intern ("tool-use");
    case AI_STOP_REASON_CONTENT_FILTER: return intern ("content-filter");
    case AI_STOP_REASON_ERROR:          return intern ("error");
    default:                            return intern ("none");
    }
}

static void
cmacs_ai_stream__complete (CmacsAiStream *s, AiResponse *resp)
{
  const gchar *text = s->text ? s->text->str : "";
  Lisp_Object stop  = cmacs_ai__stop_reason_sym (
    ai_response_get_stop_reason (resp));

  /* Append a complete assistant message to history -- copy ALL
   * content blocks (text + tool_use) from the response, mirroring
   * ai-glib's own AiToolExecutor pattern.  Without the tool_use
   * blocks, the next turn would lose the assistant's call IDs and
   * the provider would reject our tool_result messages. */
  CmacsAiSession *sess = cmacs_ai_session_lookup (s->session_handle);
  if (sess)
    {
      AiMessage *m = ai_message_new (AI_ROLE_ASSISTANT);
      gboolean has_block = FALSE;
      for (GList *l = ai_response_get_content_blocks (resp);
           l != NULL; l = l->next)
        {
          AiContentBlock *b = l->data;
          /* g_object_ref is type-preserving in this GLib, so the old
           * cast here is now flagged as useless. */
          ai_message_add_content_block (m, g_object_ref (b));
          has_block = TRUE;
        }
      if (has_block)
        cmacs_ai_session_append_message_obj (sess, m);
      g_object_unref (m);
      cmacs_ai_session_clear_cancellable (sess);
    }

  /* Emit :tool-use payloads from the response's tool_uses BEFORE
   * :end, so the Elisp callback has the full set ready when it
   * acts on the stop reason.  Some providers (e.g. grok) don't
   * fire ai-glib's streaming `tool-use' signal even when tool_use
   * blocks are present in the final response; this pass is the
   * authoritative source.  Elisp dedups by tool-use id. */
  for (GList *l = ai_response_get_tool_uses (resp); l != NULL; l = l->next)
    {
      AiToolUse *tu = l->data;
      const gchar *name = ai_tool_use_get_name (tu);
      const gchar *id   = ai_tool_use_get_id   (tu);
      JsonNode    *in   = ai_tool_use_get_input (tu);
      g_autofree gchar *input_str = in
        ? json_to_string (in, FALSE) : g_strdup ("{}");
      cmacs_ai_stream__deliver (s, list4 (intern (":tool-use"),
                                           build_string (name ? name : ""),
                                           build_string (input_str),
                                           build_string (id ? id : "")));
    }

  cmacs_ai_stream__deliver (s, list5 (intern (":end"),
                                       intern (":text"),
                                       build_string (text),
                                       intern (":stop"), stop));
  cmacs_ai_stream__free (s);
}

static void
on_stream_end (AiStreamable *src, AiResponse *resp, gpointer user)
{
  (void) src;
  cmacs_ai_stream__complete ((CmacsAiStream *) user, resp);
}

/* ── Non-streaming fallback ──────────────────────────────────────
 *
 * Not every provider implements AiStreamable -- claude-tmux, for one --
 * and refusing to talk to those at all made a provider the chat UI
 * offers simply not work when chosen.  Every AiProvider implements the
 * plain chat call, so the answer is fetched whole and delivered through
 * the same payload sequence a streamed reply produces: :start, one
 * :delta carrying all of it, then :end.  The Elisp side cannot tell the
 * difference apart from the text arriving at once.  */

static void
on_chat_finished (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsAiStream *s = user;
  GError *err = NULL;
  g_autoptr (AiResponse) resp = ai_provider_chat_finish (AI_PROVIDER (source),
                                                         res, &err);
  if (resp == NULL)
    {
      cmacs_ai_stream__deliver (s, list2 (intern (":error"),
                                           build_string (err ? err->message
                                                             : "chat failed")));
      if (err) g_error_free (err);
      cmacs_ai_stream__free (s);
      return;
    }

  /* One delta with the whole answer, so a caller accumulating deltas
   * ends up with the same string a streamed reply would have given it. */
  const gchar *text = ai_response_get_text (resp);
  if (text != NULL && *text != '\0')
    {
      if (s->text) g_string_append (s->text, text);
      cmacs_ai_stream__deliver (s, list2 (intern (":delta"),
                                           build_string (text)));
    }
  cmacs_ai_stream__complete (s, resp);
}

static void
on_stream_finished (GObject *source, GAsyncResult *res, gpointer user)
{
  CmacsAiStream *s = user;
  GError *err = NULL;
  g_autoptr (AiResponse) resp = ai_streamable_chat_stream_finish (
    AI_STREAMABLE (source), res, &err);
  if (resp == NULL)
    {
      /* on_stream_end didn't fire; deliver :error and free. */
      cmacs_ai_stream__deliver (s, list2 (intern (":error"),
                                           build_string (err ? err->message
                                                             : "stream failed")));
      if (err) g_error_free (err);
      cmacs_ai_stream__free (s);
    }
  /* else: on_stream_end already ran and freed s */
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

/* Shared kickoff for chat-stream and chat-continue-stream. */
static Lisp_Object
cmacs_ai__start_stream (Lisp_Object session, Lisp_Object callback,
                        Lisp_Object executor, bool append_user_msg,
                        Lisp_Object prompt)
{
  CHECK_FIXNAT (session);
  CmacsAiSession *sess = cmacs_ai_session_lookup (XFIXNUM (session));
  if (sess == NULL) error ("cmacs-ai: bad session handle");
  AiProvider *prov = cmacs_ai_session_get_provider (sess);
  if (prov == NULL) error ("cmacs-ai: session has no live client");


  /* Optionally append a fresh user turn. */
  if (append_user_msg)
    {
      CHECK_STRING (prompt);
      AiMessage *m = ai_message_new_user (SSDATA (prompt));
      cmacs_ai_session_append_message_obj (sess, m);
      g_object_unref (m);
    }

  /* Resolve tools from optional executor handle. */
  GList *tools = NULL;
  if (!NILP (executor))
    {
      CHECK_FIXNAT (executor);
      AiToolExecutor *exec = cmacs_ai_tools_lookup (XFIXNUM (executor));
      if (exec == NULL)
        error ("cmacs-ai: bad executor handle");
      tools = ai_tool_executor_get_tools (exec);
    }

  CmacsAiStream *s = g_new0 (CmacsAiStream, 1);
  /* NULL for a non-streaming provider: the field doubles as the handle
   * the signal disconnects run against, and connecting them to a
   * provider that never emits them would leave dangling ids. */
  s->streamable     = AI_IS_STREAMABLE (prov) ? AI_STREAMABLE (prov) : NULL;
  s->session_handle = XFIXNUM (session);
  s->stream_id      = cmacs_ai__next_stream_id++;
  s->text           = g_string_new (NULL);
  cmacs_ai_stream__callback_set (s->stream_id, callback);

  if (s->streamable == NULL)
    {
      GCancellable *c = cmacs_ai_session_install_cancellable (sess);
      cmacs_ai_stream__deliver (s, list1 (intern (":start")));
      ai_provider_chat_async (prov, cmacs_ai_session_get_messages (sess),
                              NULL, 0, tools, c, on_chat_finished, s);
      return Qt;
    }

  s->sig_start = g_signal_connect (prov, "stream-start",
                                   G_CALLBACK (on_stream_start), s);
  s->sig_delta = g_signal_connect (prov, "delta",
                                   G_CALLBACK (on_stream_delta), s);
  s->sig_tool  = g_signal_connect (prov, "tool-use",
                                   G_CALLBACK (on_stream_tool_use), s);
  s->sig_end   = g_signal_connect (prov, "stream-end",
                                   G_CALLBACK (on_stream_end), s);

  GCancellable *cancel = cmacs_ai_session_install_cancellable (sess);

  ai_streamable_chat_stream_async (s->streamable,
                                   cmacs_ai_session_get_messages (sess),
                                   NULL,   /* system: take from client */
                                   0,      /* max_tokens: take from client */
                                   tools,  /* (transfer none); ai-glib copies */
                                   cancel,
                                   on_stream_finished,
                                   s);
  return Qt;
}

DEFUN ("cmacs-ai-chat-stream", Fcmacs_ai_chat_stream,
       Scmacs_ai_chat_stream, 3, 4, 0,
       doc: /* Stream a chat completion for SESSION.
SESSION is a session handle.  PROMPT is the user-turn text (appended to
history before sending).  CALLBACK is a function called repeatedly with
plist payloads:
  (:start)
  (:delta TEXT)
  (:tool-use NAME INPUT-JSON ID)
  (:end :text TEXT :stop SYMBOL)
  (:error MESSAGE)
Optional EXECUTOR is a tool-executor handle (from `cmacs-ai-tools-new');
when provided, the executor's tool list is advertised to the model so
it can emit tool_use blocks.  The :end / :error payload always closes
the stream; subsequent calls will not fire.  Returns t.  Use
`cmacs-ai-chat-cancel' to abort.  */)
  (Lisp_Object session, Lisp_Object prompt, Lisp_Object callback,
   Lisp_Object executor)
{
  return cmacs_ai__start_stream (session, callback, executor,
                                  /* append_user_msg = */ true, prompt);
}

DEFUN ("cmacs-ai-chat-continue-stream",
       Fcmacs_ai_chat_continue_stream,
       Scmacs_ai_chat_continue_stream, 2, 3, 0,
       doc: /* Re-stream the current SESSION with no new user turn.
Used after `cmacs-ai-tools-execute-into-session' has appended one or
more tool_result messages, to ask the model to continue.  CALLBACK
and EXECUTOR have the same semantics as `cmacs-ai-chat-stream'.  */)
  (Lisp_Object session, Lisp_Object callback, Lisp_Object executor)
{
  return cmacs_ai__start_stream (session, callback, executor,
                                  /* append_user_msg = */ false, Qnil);
}

DEFUN ("cmacs-ai-chat-cancel", Fcmacs_ai_chat_cancel,
       Scmacs_ai_chat_cancel, 1, 1, 0,
       doc: /* Cancel any in-flight request on SESSION.  No-op if idle.  */)
  (Lisp_Object session)
{
  CHECK_FIXNAT (session);
  CmacsAiSession *sess = cmacs_ai_session_lookup (XFIXNUM (session));
  if (sess == NULL) return Qnil;
  /* install_cancellable replaces -> previous one is dropped (and any
   * active GCancellable still held by the in-flight task survives the
   * replace; we cancel it explicitly via the fresh one returned).  */
  GCancellable *c = cmacs_ai_session_install_cancellable (sess);
  if (c) g_cancellable_cancel (c);
  cmacs_ai_session_clear_cancellable (sess);
  return Qt;
}

/* Map a provider symbol to an AiProviderType.  Errors on unknown
 * symbols (deliberately stricter than ai_provider_type_from_string,
 * which silently falls back to Claude). */
static AiProviderType
cmacs_ai__provider_type (Lisp_Object provider)
{
  CHECK_SYMBOL (provider);
  if (EQ (provider, intern ("claude")))      return AI_PROVIDER_CLAUDE;
  if (EQ (provider, intern ("openai")))      return AI_PROVIDER_OPENAI;
  if (EQ (provider, intern ("gemini")))      return AI_PROVIDER_GEMINI;
  if (EQ (provider, intern ("grok")))        return AI_PROVIDER_GROK;
  if (EQ (provider, intern ("ollama")))      return AI_PROVIDER_OLLAMA;
  if (EQ (provider, intern ("claude-code"))) return AI_PROVIDER_CLAUDE_CODE;
  if (EQ (provider, intern ("opencode")))    return AI_PROVIDER_OPENCODE;
  if (EQ (provider, intern ("claude-tmux"))) return AI_PROVIDER_CLAUDE_TMUX;
  if (EQ (provider, intern ("grok-build"))) return AI_PROVIDER_GROK_BUILD;
  error ("cmacs-ai: unknown provider %s",
         SSDATA (SYMBOL_NAME (provider)));
}

/* Build an AiSimple for optional PROVIDER (symbol or nil) and
 * optional MODEL (string or nil).  A model with no provider pins
 * the model on the configured default provider. */
static AiSimple *
cmacs_ai__simple_for (Lisp_Object provider, Lisp_Object model)
{
  const gchar *model_str = NULL;

  if (!NILP (model))
    {
      CHECK_STRING (model);
      model_str = SSDATA (model);
    }

  if (!NILP (provider))
    return ai_simple_new_with_provider (cmacs_ai__provider_type (provider),
                                        model_str);
  if (model_str != NULL)
    return ai_simple_new_with_provider
      (ai_config_get_default_provider (ai_config_get_default ()),
       model_str);
  return ai_simple_new ();
}

DEFUN ("cmacs-ai-prompt-sync", Fcmacs_ai_prompt_sync,
       Scmacs_ai_prompt_sync, 1, 4, 0,
       doc: /* Send PROMPT to the default provider synchronously.
Returns the response text (string), or signals `cmacs-ai-error' on
failure.  Optional PROVIDER (symbol: claude / openai / ...) overrides
the default; optional SYSTEM is a string system prompt; optional
MODEL is a model name string overriding the provider's default
\(e.g. "claude-opus-5", "fable").  This is a stateless single-shot
wrapper (`ai_simple_prompt') -- it does not maintain conversation
history.  */)
  (Lisp_Object prompt, Lisp_Object provider, Lisp_Object system,
   Lisp_Object model)
{
  CHECK_STRING (prompt);
  g_autoptr (AiSimple) ai = cmacs_ai__simple_for (provider, model);
  if (!NILP (system))
    {
      CHECK_STRING (system);
      ai_simple_set_system_prompt (ai, SSDATA (system));
    }
  g_autoptr (GError) err = NULL;
  g_autofree gchar *out = ai_simple_prompt (ai, SSDATA (prompt), NULL, &err);
  if (out == NULL)
    xsignal1 (intern ("cmacs-ai-error"),
              build_string (err ? err->message : "ai_simple_prompt failed"));
  return build_string (out);
}

DEFUN ("cmacs-ai--call", Fcmacs_ai_call,
       Scmacs_ai_call, 1, 6, 0,
       doc: /* Send PROMPT to an AI provider and return the final answer.
This is the low-level primitive; user configs normally use the
`cmacs-ai-call' Elisp wrapper (plist API + executor lifecycle) instead.
Like `cmacs-ai-prompt-sync', but when EXECUTOR (a tool-executor handle
from `cmacs-ai-tools-new') is supplied the model may call that
executor's tools in a synchronous multi-turn loop (capped at ~20
turns), and the final assistant text is returned as a string.  Custom
Elisp tools registered with `cmacs-ai-tools-register' have their return
value handed back to the model.

Optional PROVIDER (symbol: claude / openai / ...) overrides the default
provider; SYSTEM is a system-prompt string; MODEL overrides the
provider's default model; EXECUTOR is a tool-executor handle (nil = no
tools, identical to `cmacs-ai-prompt-sync'); MAX-TOKENS caps each turn's
response.  Signals `cmacs-ai-error' on failure.

Runs synchronously and blocks Emacs for the duration of the loop -- keep
tool loops short, especially under `emacs --gowl' where the main thread
is the Wayland compositor.  */)
  (Lisp_Object prompt, Lisp_Object provider, Lisp_Object system,
   Lisp_Object model, Lisp_Object executor, Lisp_Object max_tokens)
{
  CHECK_STRING (prompt);

  /* No executor: stateless single-shot, identical to prompt-sync. */
  if (NILP (executor))
    return Fcmacs_ai_prompt_sync (prompt, provider, system, model);

  CHECK_FIXNAT (executor);
  AiToolExecutor *exec = cmacs_ai_tools_lookup (XFIXNUM (executor));
  if (exec == NULL)
    error ("cmacs-ai: bad executor handle");

  gint maxtok = 0;
  if (!NILP (max_tokens))
    {
      CHECK_FIXNAT (max_tokens);
      maxtok = (gint) XFIXNUM (max_tokens);
    }

  const gchar *sys = NULL;
  if (!NILP (system))
    {
      CHECK_STRING (system);
      sys = SSDATA (system);
    }

  /* Resolve the provider BEFORE pushing the private context: this can
   * longjmp on an unknown symbol, which must not leave the thread-default
   * stack unbalanced. */
  AiSimple *ai = cmacs_ai__simple_for (provider, model);
  AiProvider *prov = ai_simple_get_provider (ai);

  AiMessage *umsg = ai_message_new_user (SSDATA (prompt));
  GList *messages = g_list_append (NULL, umsg);

  /* Drive the blocking, multi-turn tool loop on a PRIVATE thread-default
   * context so its GMainLoop (and the provider's async I/O, which binds
   * to the thread-default) cannot re-enter Emacs's own GLib dispatch.
   * Tool callbacks still fire on this (main) thread, so custom Elisp
   * tools run and return their values safely.  */
  GMainContext *ctx = g_main_context_new ();
  g_main_context_push_thread_default (ctx);

  GError *err = NULL;
  gchar *out = ai_tool_executor_run (exec, prov, messages, sys, maxtok,
                                     NULL, &err);

  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);
  g_list_free (messages);
  g_object_unref (umsg);

  if (out == NULL)
    {
      /* xsignal longjmps past manual cleanup -- release ai + err first. */
      Lisp_Object msg =
        build_string (err ? err->message : "cmacs-ai-call failed");
      g_clear_error (&err);
      g_object_unref (ai);
      xsignal1 (intern ("cmacs-ai-error"), msg);
    }
  g_object_unref (ai);
  Lisp_Object result = build_string (out);
  g_free (out);
  return result;
}

/* ── Model listing (sync wrapper over the async provider API) ───── */

struct cmacs_ai__models_state
{
  gboolean done;
  GList *models;                /* of gchar*, owned */
  GError *error;                /* owned */
};

static void
cmacs_ai__models_cb (GObject *source, GAsyncResult *result,
                     gpointer user_data)
{
  struct cmacs_ai__models_state *st = user_data;
  st->models = ai_provider_list_models_finish (AI_PROVIDER (source),
                                               result, &st->error);
  st->done = TRUE;
}

static gboolean
cmacs_ai__models_timeout (gpointer user_data)
{
  g_cancellable_cancel ((GCancellable *) user_data);
  return G_SOURCE_REMOVE;
}

DEFUN ("cmacs-ai-list-models", Fcmacs_ai_list_models,
       Scmacs_ai_list_models, 0, 1, 0,
       doc: /* Return the list of model names PROVIDER offers.
PROVIDER is a symbol (claude / openai / gemini / grok / ollama /
claude-code / opencode / claude-tmux / grok-build), or nil for the configured
default.  Queries the provider (network for API providers, static
tables for CLI providers) with a 30 second timeout; signals
`cmacs-ai-error' on failure.  */)
  (Lisp_Object provider)
{
  g_autoptr (AiSimple) ai = NULL;
  g_autoptr (GCancellable) cancellable = NULL;
  GMainContext *ctx;
  GSource *timeout;
  struct cmacs_ai__models_state st = { FALSE, NULL, NULL };
  Lisp_Object out = Qnil;
  GList *l;

  /* Resolve the provider before pushing the private context:
   * cmacs_ai__simple_for can longjmp on an unknown symbol, which
   * must not leave the thread-default stack unbalanced. */
  ai = cmacs_ai__simple_for (provider, Qnil);

  /* The async op and everything it schedules runs on a private
   * thread-default context, so iterating it to completion here
   * cannot re-enter Emacs's own GLib dispatch. */
  ctx = g_main_context_new ();
  g_main_context_push_thread_default (ctx);

  cancellable = g_cancellable_new ();
  timeout = g_timeout_source_new_seconds (30);
  g_source_set_callback (timeout, cmacs_ai__models_timeout,
                         cancellable, NULL);
  g_source_attach (timeout, ctx);

  ai_provider_list_models_async (ai_simple_get_provider (ai),
                                 cancellable, cmacs_ai__models_cb, &st);
  while (!st.done)
    g_main_context_iteration (ctx, TRUE);

  g_source_destroy (timeout);
  g_source_unref (timeout);
  g_clear_object (&ai);
  g_main_context_pop_thread_default (ctx);
  g_main_context_unref (ctx);

  if (st.error != NULL)
    {
      /* xsignal longjmps past the g_autoptr cleanups -- free here. */
      Lisp_Object msg = build_string (st.error->message);
      g_error_free (st.error);
      g_list_free_full (st.models, g_free);
      g_clear_object (&cancellable);
      xsignal1 (intern ("cmacs-ai-error"), msg);
    }

  for (l = st.models; l != NULL; l = l->next)
    out = Fcons (build_string ((const gchar *) l->data), out);
  g_list_free_full (st.models, g_free);
  return Fnreverse (out);
}

void syms_of_cmacs_ai_stream_defuns (void);
void
syms_of_cmacs_ai_stream_defuns (void)
{
  DEFSYM (Qcmacs_ai_error, "cmacs-ai-error");
  Fput (Qcmacs_ai_error, Qerror_conditions,
        list2 (Qcmacs_ai_error, Qerror));
  Fput (Qcmacs_ai_error, Qerror_message,
        build_string ("CMacs ai error"));

  Vcmacs_ai__stream_callbacks = Qnil;
  staticpro (&Vcmacs_ai__stream_callbacks);

  defsubr (&Scmacs_ai_chat_stream);
  defsubr (&Scmacs_ai_chat_continue_stream);
  defsubr (&Scmacs_ai_chat_cancel);
  defsubr (&Scmacs_ai_prompt_sync);
  defsubr (&Scmacs_ai_call);
  defsubr (&Scmacs_ai_list_models);
}

#endif /* HAVE_CMACS_AI */
