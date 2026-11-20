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
 *   (:error MESSAGE :kind KIND :reset TIMESTAMP)   a limit, a 429, a
 *       lapsed login or an empty balance -- see cmacs_ai_error_payload
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
#include <string.h>

/* ── Errors worth telling apart ──────────────────────────────────────
 *
 * ai-glib 0.13 reclassifies what a CLI says into real codes: a usage
 * limit is AI_ERROR_SESSION_LIMIT rather than a failed run, a 429 is
 * AI_ERROR_RATE_LIMITED, an expired login AI_ERROR_INVALID_API_KEY, an
 * empty balance AI_ERROR_INSUFFICIENT_QUOTA.  The first two can carry a
 * machine-readable notice -- `ai-glib-session-limit: reset=<unix time>'
 * -- inside the message, so a supervisor reading a log line can see
 * the pause without parsing a localised sentence.
 *
 * Everything cmacs shows a person or decides on goes through here, for
 * the reason ai-glib gives for having one formatter: three layers
 * describing one condition reads like three problems. */

/* MESSAGE without the notice token(s).  The notice sits mid-sentence
 * ("...resets at 18:50 on Friday NOTICE (codex: ...)"), so the text
 * either side is rejoined with exactly one space.  Never NULL for a
 * non-NULL MESSAGE. */
static gchar *
cmacs_ai__strip_limit_notice (const gchar *message)
{
  const gsize plen = strlen (AI_SESSION_LIMIT_NOTICE_PREFIX);
  GString *out;
  const gchar *rest, *at;

  if (message == NULL)
    return NULL;

  out = g_string_new (NULL);
  rest = message;

  while ((at = strstr (rest, AI_SESSION_LIMIT_NOTICE_PREFIX)) != NULL)
    {
      const gchar *end = at + plen;
      const gchar *value = end;

      g_string_append_len (out, rest, at - rest);

      /* The value is optional: ai_session_limit_notice_parse accepts
       * the bare marker, so the stripper has to as well. */
      while (*value == ' ')
        value++;
      if (g_str_has_prefix (value, "reset="))
        {
          end = value + strlen ("reset=");
          while (g_ascii_isdigit (*end))
            end++;
        }

      /* One space where the notice was, none at either end. */
      while (out->len > 0 && out->str[out->len - 1] == ' ')
        g_string_truncate (out, out->len - 1);
      while (*end == ' ')
        end++;
      if (out->len > 0 && *end != '\0')
        g_string_append_c (out, ' ');

      rest = end;
    }

  g_string_append (out, rest);
  return g_string_free (out, FALSE);
}

const gchar *
cmacs_ai_error_classify (const GError *gerr, gint64 *reset_out,
                         gchar **clean_out)
{
  const gchar *kind = NULL;
  gint64 reset = 0;
  gboolean noticed;

  if (reset_out != NULL) *reset_out = 0;
  if (clean_out != NULL) *clean_out = NULL;
  if (gerr == NULL)
    return NULL;

  noticed = ai_session_limit_notice_parse (gerr->message, &reset);

  if (gerr->domain == AI_ERROR)
    switch (gerr->code)
      {
      case AI_ERROR_SESSION_LIMIT:      kind = "session-limit"; break;
      case AI_ERROR_RATE_LIMITED:       kind = "rate-limited";  break;
      case AI_ERROR_INVALID_API_KEY:    kind = "signed-out";    break;
      case AI_ERROR_INSUFFICIENT_QUOTA: kind = "quota";         break;
      default: break;
      }

  /* A notice under any other code or domain is still a pause.  The
   * tool loop and the conversation layer both re-wrap a provider's
   * error on the way up, and a wrapper that lost the code must not
   * turn "paused until 18:50" into "failed" -- the same reasoning
   * ai_session_limit_notice_parse gives for accepting a bare marker. */
  if (kind == NULL && noticed)
    kind = "session-limit";

  /* No notice, but the words may still say when: codex's "try again
   * at 3:45 PM", a Retry-After.  Only for the two kinds that are a
   * wait; a reset time on "signed out" would be a misreading. */
  if (kind != NULL && reset <= 0
      && (strcmp (kind, "session-limit") == 0
          || strcmp (kind, "rate-limited") == 0))
    {
      if (!ai_session_limit_parse_reset (gerr->message,
                                         g_get_real_time () / G_USEC_PER_SEC,
                                         &reset))
        reset = 0;
    }

  if (reset_out != NULL) *reset_out = reset > 0 ? reset : 0;
  if (clean_out != NULL)
    *clean_out = cmacs_ai__strip_limit_notice (gerr->message);
  return kind;
}

Lisp_Object
cmacs_ai_error_payload (const GError *gerr, const char *fallback)
{
  g_autofree gchar *clean = NULL;
  gint64 reset = 0;
  const gchar *kind;
  Lisp_Object msg;

  if (gerr == NULL)
    return list2 (intern (":error"), build_string (fallback));

  kind = cmacs_ai_error_classify (gerr, &reset, &clean);
  msg = build_string (clean != NULL ? clean : fallback);

  /* Unclassified errors keep the two-element shape they always had, so
   * the extension is invisible to every caller that does not ask. */
  if (kind == NULL)
    return list2 (intern (":error"), msg);

  return list (intern (":error"), msg,
               intern (":kind"), intern (kind),
               intern (":reset"), reset > 0 ? make_int (reset) : Qnil);
}

/* ERROR's message as a Lisp string with the notice removed, for the
 * synchronous paths that signal rather than deliver a payload. */
static Lisp_Object
cmacs_ai__error_message (const GError *gerr, const char *fallback)
{
  g_autofree gchar *clean =
    gerr != NULL ? cmacs_ai__strip_limit_notice (gerr->message) : NULL;

  return build_string (clean != NULL ? clean : fallback);
}

DEFUN ("cmacs-ai-error-classify", Fcmacs_ai_error_classify,
       Scmacs_ai_error_classify, 2, 2, 0,
       doc: /* Classify an ai-glib error given as CODE and MESSAGE.

CODE is the error's nick as a symbol or string -- `session-limit',
`rate-limited', `invalid-api-key', `insufficient-quota',
`cli-execution', ... -- or nil for an error outside ai-glib's own
domain.  MESSAGE is its text.

Returns (KIND RESET CLEAN):

  KIND   `session-limit', `rate-limited', `signed-out', `quota', or
         nil for every other error.
  RESET  when the limit lifts, as a Unix timestamp, or nil if unknown.
  CLEAN  MESSAGE with ai-glib's machine-readable
         `ai-glib-session-limit:' notice removed.

This is the classifier the async error payloads use -- (:error MESSAGE
:kind KIND :reset RESET) -- exposed so it can be tested, and so Lisp
holding only an error's text can ask the same question the same way.  */)
  (Lisp_Object code, Lisp_Object message)
{
  g_autoptr (GError) gerror = NULL;
  g_autofree gchar *clean = NULL;
  const gchar *kind;
  gint64 reset = 0;

  CHECK_STRING (message);

  if (NILP (code))
    /* Any domain that is not AI_ERROR; the code is irrelevant. */
    gerror = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
                                  SSDATA (message));
  else
    {
      const gchar *nick;
      GEnumClass *klass;
      GEnumValue *value;

      if (STRINGP (code))
        nick = SSDATA (code);
      else
        {
          CHECK_SYMBOL (code);
          nick = SSDATA (SYMBOL_NAME (code));
        }

      klass = g_type_class_ref (AI_TYPE_ERROR);
      value = g_enum_get_value_by_nick (klass, nick);
      if (value != NULL)
        gerror = g_error_new_literal (AI_ERROR, value->value,
                                      SSDATA (message));
      g_type_class_unref (klass);

      if (gerror == NULL)
        error ("cmacs-ai: unknown error code %s", nick);
    }

  kind = cmacs_ai_error_classify (gerror, &reset, &clean);

  return list3 (kind != NULL ? intern (kind) : Qnil,
                reset > 0 ? make_int (reset) : Qnil,
                build_string (clean != NULL ? clean : ""));
}

DEFUN ("cmacs-ai-session-limit-scan", Fcmacs_ai_session_limit_scan,
       Scmacs_ai_session_limit_scan, 1, 1, 0,
       doc: /* Look for a usage-limit report in TEXT, a worker's output.

Returns nil, or (KIND RESET) where KIND is `session-limit' and RESET is
the Unix time the limit lifts, or nil when the text does not say.

Two things count.  ai-glib's own notice line
\(`ai-glib-session-limit: reset=N'), which anything built on ai-glib
prints, is taken at its word.  Failing that, a CLI's own sentence counts
only when it both names a session or usage limit AND states a reset
time ai-glib can read -- a worker's output is mostly a model's prose,
and prose that merely mentions a limit must not park a task.

For a subprocess the brigade spawned directly, which never passes
through ai-glib's error classification.  */)
  (Lisp_Object text)
{
  gint64 reset = 0;
  g_autofree gchar *lower = NULL;

  CHECK_STRING (text);

  if (ai_session_limit_notice_parse (SSDATA (text), &reset))
    return list2 (intern ("session-limit"),
                  reset > 0 ? make_int (reset) : Qnil);

  lower = g_ascii_strdown (SSDATA (text), -1);
  if ((strstr (lower, "session limit") != NULL
       || strstr (lower, "usage limit") != NULL)
      && ai_session_limit_parse_reset (SSDATA (text),
                                       g_get_real_time () / G_USEC_PER_SEC,
                                       &reset)
      && reset > 0)
    return list2 (intern ("session-limit"), make_int (reset));

  return Qnil;
}

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
      cmacs_ai_stream__deliver (s, cmacs_ai_error_payload (err,
                                                           "chat failed"));
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
      cmacs_ai_stream__deliver (s, cmacs_ai_error_payload (err,
                                                           "stream failed"));
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

  /* CMACS: an HTTP provider reads a NULL system prompt from its own
   * configuration, but the CLI base class hands whatever it is given
   * straight to build_argv -- so NULL meant "no --system-prompt-file",
   * and every streamed CLI turn ran under Claude Code's default coding
   * persona instead of the caller's prompt (a summariser asked for JSON
   * replied with questions about the source tree it was started in).
   * Pass the client's prompt explicitly for CLI clients. */
  const gchar *system_prompt = AI_IS_CLI_CLIENT (prov)
    ? ai_cli_client_get_system_prompt (AI_CLI_CLIENT (prov)) : NULL;

  ai_streamable_chat_stream_async (s->streamable,
                                   cmacs_ai_session_get_messages (sess),
                                   system_prompt,
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
  /* The in-flight task holds the cancellable installed when the request
   * started, so that exact object is the one to cancel.  Installing a
   * fresh one first and cancelling that -- which this used to do --
   * cancelled an object the task had never seen, and the request ran to
   * completion every time.  */
  cmacs_ai_session_cancel_current (sess);
  return Qt;
}

/* Map a provider symbol to an AiProviderType.  One table, in
 * cmacs-ai-config.c: three copies of it is how `codex-cli' worked in a
 * chat and was an unknown provider in `cmacs-ai-prompt-sync'. */
static AiProviderType
cmacs_ai__provider_type (Lisp_Object provider)
{
  CHECK_SYMBOL (provider);
  return cmacs_ai_provider_type_from_symbol (provider);
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

  AiSimple *ai;

  if (!NILP (provider))
    {
      ai = ai_simple_new_with_provider (
        cmacs_ai__provider_type (provider), model_str);
      /* A named endpoint is the type plus its own URL and key, and the
       * type is all that reached the factory. */
      if (ai != NULL)
        cmacs_ai_apply_endpoint_settings (provider,
                                          ai_simple_get_provider (ai));
    }
  else if (model_str != NULL)
    ai = ai_simple_new_with_provider
      (ai_config_get_default_provider (ai_config_get_default ()),
       model_str);
  else
    ai = ai_simple_new ();

  /* The configured default provider (PROVIDER nil) can be a codex
   * client too, and `cmacs-ai-codex-transport' applies to it as it
   * does to a named one. */
  if (ai != NULL && NILP (provider))
    cmacs_ai_apply_provider_settings (Qnil, ai_simple_get_provider (ai));

  /* A CLI agent's account, from `cmacs-ai-cli-config-dirs'.  Also for
   * the default provider (PROVIDER nil): the lookup falls back to the
   * client type's own name. */
  if (ai != NULL)
    {
      gchar *why = cmacs_ai_apply_cli_config_dir (
                     provider, ai_simple_get_provider (ai));
      if (why != NULL)
        {
          Lisp_Object msg = build_string (why);
          g_free (why);
          g_object_unref (ai);
          xsignal1 (Quser_error, msg);
        }
    }
  return ai;
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
              cmacs_ai__error_message (err, "ai_simple_prompt failed"));
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
      Lisp_Object msg = cmacs_ai__error_message (err, "cmacs-ai-call failed");
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
openai-compatible / claude-code / opencode / claude-tmux / grok-build /
antigravity / cursor / codex-cli, or a name from
`cmacs-ai-openai-compatible-endpoints'), or nil for the configured
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
      Lisp_Object msg = cmacs_ai__error_message (st.error,
                                                 "could not list models");
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
  defsubr (&Scmacs_ai_error_classify);
  defsubr (&Scmacs_ai_session_limit_scan);
}

#endif /* HAVE_CMACS_AI */
