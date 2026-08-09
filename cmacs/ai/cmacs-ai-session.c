/* cmacs-ai-session.c --- conversation state (GList<AiMessage>).
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A CmacsAiSession bundles:
 *   - the AiProvider/AiClient handle to send turns to
 *   - the GList<AiMessage> history accumulated across turns
 *   - an optional AiToolExecutor (created lazily on first tool turn)
 *
 * The session is the unit of conversation memory.  Streaming and
 * tool-loop DEFUNs (cmacs-ai-stream.c, cmacs-ai-tools.c) read/write
 * the message list, never touching ai-glib internals directly. */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"

#include <ai-glib.h>
#include <glib.h>

struct CmacsAiSession
{
  guint            client_handle;
  GList           *messages;          /* GList<AiMessage*> (owned) */
  AiToolExecutor  *tool_executor;     /* nullable, owned */
  GCancellable    *current_cancel;    /* in-flight request, nullable */
};

static GHashTable *cmacs_ai__sessions = NULL;   /* guint -> CmacsAiSession* */
static guint       cmacs_ai__next_session = 1;
static GMutex      cmacs_ai__session_mutex;

static void
cmacs_ai_session__free (gpointer p)
{
  CmacsAiSession *s = p;
  if (!s) return;
  g_list_free_full (s->messages, g_object_unref);
  g_clear_object (&s->tool_executor);
  if (s->current_cancel)
    {
      g_cancellable_cancel (s->current_cancel);
      g_clear_object (&s->current_cancel);
    }
  g_free (s);
}

void
cmacs_ai_session_registry_init (void)
{
  static gboolean done = FALSE;
  if (done) return;
  done = TRUE;
  g_mutex_init (&cmacs_ai__session_mutex);
  cmacs_ai__sessions =
    g_hash_table_new_full (g_direct_hash, g_direct_equal,
                           NULL, cmacs_ai_session__free);
}

guint
cmacs_ai_session_create (guint client_handle)
{
  /* The session merely references the client by handle so it survives
   * an explicit client-free; lookups validate at use time. */
  CmacsAiSession *s = g_new0 (CmacsAiSession, 1);
  s->client_handle = client_handle;
  g_mutex_lock (&cmacs_ai__session_mutex);
  guint h = cmacs_ai__next_session++;
  g_hash_table_insert (cmacs_ai__sessions, GUINT_TO_POINTER (h), s);
  g_mutex_unlock (&cmacs_ai__session_mutex);
  return h;
}

CmacsAiSession *
cmacs_ai_session_lookup (guint handle)
{
  g_mutex_lock (&cmacs_ai__session_mutex);
  CmacsAiSession *s = g_hash_table_lookup (cmacs_ai__sessions,
                                           GUINT_TO_POINTER (handle));
  g_mutex_unlock (&cmacs_ai__session_mutex);
  return s;
}

void
cmacs_ai_session_destroy (guint handle)
{
  g_mutex_lock (&cmacs_ai__session_mutex);
  g_hash_table_remove (cmacs_ai__sessions, GUINT_TO_POINTER (handle));
  g_mutex_unlock (&cmacs_ai__session_mutex);
}

/* ── Helpers exported to other ai/ files (no DEFUN bridge needed) ── */

AiProvider *
cmacs_ai_session_get_provider (CmacsAiSession *s)
{
  if (!s) return NULL;
  return AI_PROVIDER (cmacs_ai_client_lookup (s->client_handle));
}

GList *
cmacs_ai_session_get_messages (CmacsAiSession *s)
{
  return s ? s->messages : NULL;
}

void
cmacs_ai_session_append_message_obj (CmacsAiSession *s, AiMessage *msg)
{
  if (!s || !msg) return;
  s->messages = g_list_append (s->messages, g_object_ref (msg));
}

void
cmacs_ai_session_trim (CmacsAiSession *s, gint limit)
{
  guint len;

  if (!s || limit <= 0) return;
  len = g_list_length (s->messages);
  if (len <= (guint) limit) return;

  /* Dropped from the front, oldest first.  A session that accumulates
   * across turns is re-sent whole on every one of them, so an
   * unbounded history makes a long conversation cost quadratically in
   * the number of turns -- quietly, since nothing about it looks
   * different from a short one until the bill arrives.
   *
   * The oldest end is also the right end to lose: it is the part the
   * model is least likely to still need, and the standing instructions
   * live in the system prompt rather than in this list, so they are
   * never what gets dropped. */
  while (g_list_length (s->messages) > (guint) limit)
    {
      GList *first = s->messages;
      s->messages = g_list_remove_link (s->messages, first);
      g_object_unref (first->data);
      g_list_free_1 (first);
    }
}

AiToolExecutor *
cmacs_ai_session_ensure_executor (CmacsAiSession *s)
{
  if (!s) return NULL;
  if (!s->tool_executor)
    s->tool_executor = cmacs_ai_tools_new_default ();
  return s->tool_executor;
}

GCancellable *
cmacs_ai_session_install_cancellable (CmacsAiSession *s)
{
  if (!s) return NULL;
  g_clear_object (&s->current_cancel);
  s->current_cancel = g_cancellable_new ();
  return s->current_cancel;
}

void
cmacs_ai_session_clear_cancellable (CmacsAiSession *s)
{
  if (!s) return;
  g_clear_object (&s->current_cancel);
}

/* ── DEFUNs ─────────────────────────────────────────────────────── */

DEFUN ("cmacs-ai-session-new", Fcmacs_ai_session_new,
       Scmacs_ai_session_new, 1, 1, 0,
       doc: /* Create a session bound to CLIENT-HANDLE.  Returns an
integer handle.  Free with `cmacs-ai-session-free'.  */)
  (Lisp_Object client_handle)
{
  CHECK_FIXNAT (client_handle);
  if (cmacs_ai_client_lookup (XFIXNUM (client_handle)) == NULL)
    error ("cmacs-ai: bad client handle");
  return make_uint (cmacs_ai_session_create (XFIXNUM (client_handle)));
}

DEFUN ("cmacs-ai-session-free", Fcmacs_ai_session_free,
       Scmacs_ai_session_free, 1, 1, 0,
       doc: /* Free session HANDLE.  Cancels any in-flight request.  */)
  (Lisp_Object handle)
{
  CHECK_FIXNAT (handle);
  cmacs_ai_session_destroy (XFIXNUM (handle));
  return Qt;
}

DEFUN ("cmacs-ai-session-append-message",
       Fcmacs_ai_session_append_message,
       Scmacs_ai_session_append_message, 3, 3, 0,
       doc: /* Append a message to SESSION.
ROLE is either the symbol `user' or the symbol `assistant'.  TEXT is the
message content as a string.  Returns t.

There is deliberately no `system' role here: a system prompt belongs to
the client, not to the message list, and is set with
`cmacs-ai-client-set-system-prompt'.  This docstring used to offer
`system' anyway, which meant the obvious call signalled.  */)
  (Lisp_Object session, Lisp_Object role, Lisp_Object text)
{
  CHECK_FIXNAT (session);
  CHECK_SYMBOL (role);
  CHECK_STRING (text);
  CmacsAiSession *s = cmacs_ai_session_lookup (XFIXNUM (session));
  if (s == NULL) error ("cmacs-ai: bad session handle");
  AiMessage *m;
  if (EQ (role, intern ("user")))
    m = ai_message_new_user (SSDATA (text));
  else if (EQ (role, intern ("assistant")))
    m = ai_message_new_assistant (SSDATA (text));
  else
    error ("cmacs-ai: role must be 'user or 'assistant");
  cmacs_ai_session_append_message_obj (s, m);
  g_object_unref (m);
  return Qt;
}

DEFUN ("cmacs-ai-session-clear", Fcmacs_ai_session_clear,
       Scmacs_ai_session_clear, 1, 1, 0,
       doc: /* Clear all messages in SESSION (history reset).  */)
  (Lisp_Object session)
{
  CHECK_FIXNAT (session);
  CmacsAiSession *s = cmacs_ai_session_lookup (XFIXNUM (session));
  if (s == NULL) error ("cmacs-ai: bad session handle");
  g_list_free_full (s->messages, g_object_unref);
  s->messages = NULL;
  return Qt;
}

DEFUN ("cmacs-ai-session-message-count",
       Fcmacs_ai_session_message_count,
       Scmacs_ai_session_message_count, 1, 1, 0,
       doc: /* Return number of messages in SESSION.  */)
  (Lisp_Object session)
{
  CHECK_FIXNAT (session);
  CmacsAiSession *s = cmacs_ai_session_lookup (XFIXNUM (session));
  if (s == NULL) return make_fixnum (0);
  return make_fixnum (g_list_length (s->messages));
}

void syms_of_cmacs_ai_session_defuns (void);
void
syms_of_cmacs_ai_session_defuns (void)
{
  defsubr (&Scmacs_ai_session_new);
  defsubr (&Scmacs_ai_session_free);
  defsubr (&Scmacs_ai_session_append_message);
  defsubr (&Scmacs_ai_session_clear);
  defsubr (&Scmacs_ai_session_message_count);
}

#endif /* HAVE_CMACS_AI */
