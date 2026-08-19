/* cmacs-ai-harness.c --- ai-glib's agentic harness in an Emacs buffer.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ai-glib's view layer models a session as an AiTranscript: an ordered,
 * observable list of AiViewBlock, each of which renders to text plus a
 * list of style spans.  An ncurses frontend (ai-tui) and this one both
 * consume that and neither knows what a tool is.  See
 * deps/ai-glib/docs/transcript.org, which carries the recipe this file
 * implements.
 *
 * Why a C bridge rather than driving it from Elisp over cmacs-gi, which
 * is what the library's own documentation shows: cmacs-gi skips
 * out-parameters entirely and has no signal support.  The harness needs
 * both -- ai_rendered_text_get_span() and
 * ai_completion_result_get_item_fields() are out-parameter APIs *because*
 * a plain struct behind a pointer does not survive g-ir-scanner, and
 * ::block-changed is what makes streaming appear at all.  Teaching
 * cmacs-gi those two things is worth doing and is a bigger, riskier
 * change to a subsystem everything else already depends on.
 *
 * The shape follows cmacs-ai-stream.c exactly, because the two hazards
 * are the same:
 *
 *  - Lisp callbacks live in a staticpro'd hash table keyed by handle,
 *    never in the C context struct.  A Lisp_Object in GLib-allocated
 *    memory is invisible to the garbage collector.
 *  - Every call into Lisp goes through cmacs_dispatch_safe_call*, which
 *    clears `waiting_for_input' around the call.  Signalling an error
 *    while that flag is set aborts the editor.
 *
 * Handles are integers rather than Lisp objects wrapping pointers, for
 * the same reason the rest of cmacs-ai uses them: a stale handle is an
 * error message, a stale pointer is a crash.
 */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "coding.h"   /* ENCODE_FILE / DECODE_FILE for the working dir */
#include "cmacs-ai.h"
#include "cmacs-eval-dispatch.h"

#include <ai-glib.h>
#include <glib.h>

/* ── Staticpro'd callback table ─────────────────────────────────── */

static Lisp_Object Vcmacs_ai__harness_callbacks;   /* hash: int -> callback */

static void
cmacs_ai_harness__callbacks_init (void)
{
  if (!NILP (Vcmacs_ai__harness_callbacks)) return;
  Vcmacs_ai__harness_callbacks =
    CALLN (Fmake_hash_table, QCtest, Qeql);
}

static Lisp_Object
cmacs_ai_harness__callback_lookup (guint handle)
{
  cmacs_ai_harness__callbacks_init ();
  return Fgethash (make_uint (handle),
                   Vcmacs_ai__harness_callbacks, Qnil);
}

static void
cmacs_ai_harness__callback_drop (guint handle)
{
  if (NILP (Vcmacs_ai__harness_callbacks)) return;
  Fremhash (make_uint (handle), Vcmacs_ai__harness_callbacks);
}

/* ── Per-harness context (C heap; no Lisp_Objects here) ─────────── */

typedef struct
{
  guint                 handle;
  AiConversation       *conversation;    /* owned */
  AiResourceRegistry   *registry;        /* owned, may be NULL */
  AiCommandSet         *commands;        /* owned, may be NULL */
  AiCompletionContext  *completion;      /* owned, may be NULL */

  guint                 executor_handle;   /* 0 until asked for */

  gulong                sig_items;
  gulong                sig_block;
  gulong                sig_busy;
  gulong                sig_activity;
} CmacsAiHarness;

static GHashTable *cmacs_ai__harnesses;      /* guint -> CmacsAiHarness* */
static guint       cmacs_ai__next_harness = 1;

static void
cmacs_ai_harness__free (gpointer data)
{
  CmacsAiHarness *h = data;

  if (h == NULL) return;

  /* Before the conversation goes, since dropping the handle forgets
   * this harness's custom-tool closures and the conversation owns the
   * executor those were registered on.  Skipping it roots one Lisp
   * closure per custom tool for the life of the process. */
  if (h->executor_handle != 0)
    {
      cmacs_ai_tools_drop (h->executor_handle);
      h->executor_handle = 0;
    }

  if (h->conversation != NULL)
    {
      AiTranscript *t = ai_conversation_get_transcript (h->conversation);

      if (t != NULL)
        {
          if (h->sig_items) g_signal_handler_disconnect (t, h->sig_items);
          if (h->sig_block) g_signal_handler_disconnect (t, h->sig_block);
        }

      if (h->sig_busy)
        g_signal_handler_disconnect (h->conversation, h->sig_busy);
      if (h->sig_activity)
        g_signal_handler_disconnect (h->conversation, h->sig_activity);
    }

  cmacs_ai_harness__callback_drop (h->handle);

  g_clear_object (&h->completion);
  g_clear_object (&h->commands);
  g_clear_object (&h->registry);
  g_clear_object (&h->conversation);
  g_free (h);
}

static void
cmacs_ai_harness__table_init (void)
{
  if (cmacs_ai__harnesses != NULL) return;
  cmacs_ai__harnesses = g_hash_table_new_full (g_direct_hash, g_direct_equal,
                                               NULL,
                                               cmacs_ai_harness__free);
}

static CmacsAiHarness *
cmacs_ai_harness__lookup (Lisp_Object handle)
{
  CmacsAiHarness *h;

  CHECK_FIXNAT (handle);
  cmacs_ai_harness__table_init ();

  h = g_hash_table_lookup (cmacs_ai__harnesses,
                           GUINT_TO_POINTER ((guint) XFIXNUM (handle)));

  if (h == NULL)
    error ("cmacs-ai-harness: bad handle %"pI"d", XFIXNUM (handle));

  return h;
}

/* ── Delivering events to Elisp ─────────────────────────────────
 *
 * One callback per harness, called as (CALLBACK EVENT &rest ARGS), so
 * the Elisp side has a single entry point to route rather than four
 * separate hooks to keep in step.  EVENT is a keyword.
 */

static void
cmacs_ai_harness__emit (CmacsAiHarness *h, Lisp_Object payload)
{
  Lisp_Object cb = cmacs_ai_harness__callback_lookup (h->handle);

  if (!NILP (cb))
    cmacs_dispatch_safe_call1 (cb, payload);
}

static void
on_items_changed (GListModel *model, guint position, guint removed,
                  guint added, gpointer user)
{
  CmacsAiHarness *h = user;

  (void) model;

  cmacs_ai_harness__emit (h,
    list4 (intern (":items-changed"), make_uint (position),
           make_uint (removed), make_uint (added)));
}

static void
on_block_changed (AiTranscript *t, guint position, AiViewBlock *block,
                  gpointer user)
{
  CmacsAiHarness *h = user;

  (void) t;

  /* The block's id, not its position: positions shift when blocks are
   * removed and the Elisp side keys its region map on the id. */
  cmacs_ai_harness__emit (h,
    list3 (intern (":block-changed"), make_uint (position),
           make_fixnum ((EMACS_INT) ai_view_block_get_id (block))));
}

static void
on_busy_notify (GObject *obj, GParamSpec *pspec, gpointer user)
{
  CmacsAiHarness *h = user;

  (void) pspec;

  cmacs_ai_harness__emit (h,
    list2 (intern (":busy"),
           ai_conversation_get_busy (AI_CONVERSATION (obj)) ? Qt : Qnil));
}

static void
on_activity_notify (GObject *obj, GParamSpec *pspec, gpointer user)
{
  CmacsAiHarness *h = user;
  const gchar *activity;

  (void) pspec;

  activity = ai_conversation_get_activity (AI_CONVERSATION (obj));

  cmacs_ai_harness__emit (h,
    list2 (intern (":activity"),
           activity ? build_string (activity) : Qnil));
}

/* ── Provider construction ──────────────────────────────────────── */

/* Provider symbol -> AiProviderType, strictly.
 *
 * ai_provider_type_from_string() falls back to Claude on anything it
 * does not recognise, which for a typed provider name means a typo runs
 * -- and bills -- somewhere the user did not ask for.  The same table
 * appears in cmacs-ai-stream.c and cmacs-ai-config.c for the same
 * reason; it is short enough that sharing it would cost more in
 * plumbing than it saves. */
static AiProviderType
cmacs_ai_harness__provider_type (Lisp_Object sym)
{
  if (EQ (sym, intern ("claude")))      return AI_PROVIDER_CLAUDE;
  if (EQ (sym, intern ("openai")))      return AI_PROVIDER_OPENAI;
  if (EQ (sym, intern ("gemini")))      return AI_PROVIDER_GEMINI;
  if (EQ (sym, intern ("grok")))        return AI_PROVIDER_GROK;
  if (EQ (sym, intern ("ollama")))      return AI_PROVIDER_OLLAMA;
  if (EQ (sym, intern ("claude-code"))) return AI_PROVIDER_CLAUDE_CODE;
  if (EQ (sym, intern ("opencode")))    return AI_PROVIDER_OPENCODE;
  if (EQ (sym, intern ("claude-tmux"))) return AI_PROVIDER_CLAUDE_TMUX;
  if (EQ (sym, intern ("grok-build")))  return AI_PROVIDER_GROK_BUILD;
  error ("cmacs-ai-harness: unknown provider %s",
         SSDATA (SYMBOL_NAME (sym)));
}

static GObject *
cmacs_ai_harness__make_provider (Lisp_Object provider_sym,
                                 Lisp_Object model)
{
  AiProviderType type;
  GObject *prov;
  g_autoptr (GError) gerror = NULL;

  if (NILP (provider_sym))
    type = ai_config_get_default_provider (ai_config_get_default ());
  else
    type = cmacs_ai_harness__provider_type (provider_sym);

  prov = ai_provider_factory_new (type, ai_config_get_default (), &gerror);

  if (prov == NULL)
    error ("cmacs-ai-harness: %s",
           gerror ? gerror->message : "could not build that provider");

  /* Set after construction rather than passed in: the factory takes a
   * config, and the two client hierarchies spell the model setter
   * differently. */
  if (!NILP (model))
    {
      if (AI_IS_CLIENT (prov))
        ai_client_set_model (AI_CLIENT (prov), SSDATA (model));
      else if (AI_IS_CLI_CLIENT (prov))
        ai_cli_client_set_model (AI_CLI_CLIENT (prov), SSDATA (model));
    }

  return prov;
}

/* ── DEFUNs: lifecycle ──────────────────────────────────────────── */

DEFUN ("cmacs-ai-harness-new", Fcmacs_ai_harness_new,
       Scmacs_ai_harness_new, 0, 3, 0,
       doc: /* Create an agentic harness session.  Returns an integer handle.

PROVIDER is a provider symbol or nil for the configured default.  MODEL
is a model string or nil.  DIRECTORY is the working directory the agent
runs in, or nil for `default-directory'.

The working directory is not cosmetic: it is what CLAUDE.md, .claude,
the project's own command files and every relative path a tool touches
resolve against.  An agent started in the wrong directory is a
different agent.

Free with `cmacs-ai-harness-free'.  */)
  (Lisp_Object provider, Lisp_Object model, Lisp_Object directory)
{
  CmacsAiHarness *h;
  g_autoptr (GObject) prov = NULL;
  guint handle;

  if (!NILP (provider)) CHECK_SYMBOL (provider);
  if (!NILP (model)) CHECK_STRING (model);
  if (!NILP (directory)) CHECK_STRING (directory);

  prov = cmacs_ai_harness__make_provider (provider, model);

  if (prov == NULL)
    error ("cmacs-ai-harness: could not build that provider");

  cmacs_ai_harness__table_init ();

  h = g_new0 (CmacsAiHarness, 1);
  h->handle = cmacs_ai__next_harness++;
  h->conversation = ai_conversation_new (prov);

  if (!NILP (directory))
    {
      Lisp_Object enc = ENCODE_FILE (Fexpand_file_name (directory, Qnil));
      ai_conversation_set_working_directory (h->conversation, SSDATA (enc));
    }

  /* The harness layer: the commands, skills and agents other tools keep
   * on disk, plus completion over them.  Scanning reads the user's
   * ~/.claude and friends, which is exactly the point -- a slash command
   * they already wrote should work here without being re-declared. */
  h->registry = ai_resource_registry_new ();
  ai_resource_registry_scan (h->registry);
  h->commands = ai_command_set_new (h->registry);
  ai_conversation_set_command_set (h->conversation, h->commands);

  h->completion = ai_completion_context_new (
    h->commands, ai_conversation_get_working_directory (h->conversation));

  {
    AiTranscript *t = ai_conversation_get_transcript (h->conversation);

    h->sig_items = g_signal_connect (t, "items-changed",
                                     G_CALLBACK (on_items_changed), h);
    /* Not optional.  Streaming mutates a block in place, which
     * ::items-changed does not cover -- without this the buffer shows
     * the first delta of each reply and then stops. */
    h->sig_block = g_signal_connect (t, "block-changed",
                                     G_CALLBACK (on_block_changed), h);
  }

  h->sig_busy = g_signal_connect (h->conversation, "notify::busy",
                                  G_CALLBACK (on_busy_notify), h);
  h->sig_activity = g_signal_connect (h->conversation, "notify::activity",
                                      G_CALLBACK (on_activity_notify), h);

  handle = h->handle;
  g_hash_table_replace (cmacs_ai__harnesses,
                        GUINT_TO_POINTER (handle), h);

  return make_uint (handle);
}

DEFUN ("cmacs-ai-harness-free", Fcmacs_ai_harness_free,
       Scmacs_ai_harness_free, 1, 1, 0,
       doc: /* Destroy harness HANDLE, cancelling any run in flight.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h;

  CHECK_FIXNAT (handle);
  cmacs_ai_harness__table_init ();

  h = g_hash_table_lookup (cmacs_ai__harnesses,
                           GUINT_TO_POINTER ((guint) XFIXNUM (handle)));

  if (h == NULL) return Qnil;

  if (ai_conversation_get_busy (h->conversation))
    ai_conversation_cancel (h->conversation);

  g_hash_table_remove (cmacs_ai__harnesses,
                       GUINT_TO_POINTER ((guint) XFIXNUM (handle)));
  return Qt;
}

DEFUN ("cmacs-ai-harness-set-callback", Fcmacs_ai_harness_set_callback,
       Scmacs_ai_harness_set_callback, 2, 2, 0,
       doc: /* Call FUNCTION when harness HANDLE changes.

FUNCTION is called with one argument, a list whose car is a keyword:

  (:items-changed POSITION REMOVED ADDED)
  (:block-changed POSITION BLOCK-ID)
  (:busy FLAG)
  (:activity STRING-OR-NIL)

The callback is held in a GC-rooted table for the life of the handle;
it is dropped when the harness is freed.  */)
  (Lisp_Object handle, Lisp_Object function)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  cmacs_ai_harness__callbacks_init ();
  Fputhash (make_uint (h->handle), function,
            Vcmacs_ai__harness_callbacks);
  return Qt;
}

/* ── DEFUNs: the input pipeline ─────────────────────────────────── */

static void
on_input_sent (GObject *source, GAsyncResult *result, gpointer user)
{
  CmacsAiHarness *h = user;
  g_autoptr (AiCommandResult) command = NULL;
  g_autoptr (GError) error = NULL;

  ai_conversation_send_input_finish (AI_CONVERSATION (source), result,
                                     &command, &error);

  if (error != NULL)
    {
      cmacs_ai_harness__emit (h,
        list2 (intern (":error"), build_string (error->message)));
      return;
    }

  /* A built-in resolved locally and was never sent.  The conversation
   * cannot know what /clear means to a buffer, so it hands it back. */
  if (command != NULL)
    {
      const gchar *name = ai_command_result_get_name (command);
      const gchar *arguments = ai_command_result_get_arguments (command);

      cmacs_ai_harness__emit (h,
        list3 (intern (":builtin"),
               build_string (name ? name : ""),
               arguments ? build_string (arguments) : Qnil));
    }
}

DEFUN ("cmacs-ai-harness-send-input", Fcmacs_ai_harness_send_input,
       Scmacs_ai_harness_send_input, 2, 2, 0,
       doc: /* Send LINE through harness HANDLE's input pipeline.

Returns t.  The work is asynchronous; watch the callback registered with
`cmacs-ai-harness-set-callback' for what happens next.

LINE goes through the whole pipeline, not straight to the model: a slash
command is resolved, @ mentions are expanded, what you typed is what the
transcript records, and what the expansion produced is what is sent.
Those last two differ on purpose -- showing the expansion would bury a
one-line question under the file it pulled in, and hiding it would make
a surprising answer impossible to explain.

A line resolving to a built-in is not sent at all; it comes back to the
callback as (:builtin NAME ARGUMENTS).  */)
  (Lisp_Object handle, Lisp_Object line)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  CHECK_STRING (line);

  ai_conversation_send_input_async (h->conversation, SSDATA (line),
                                    NULL, on_input_sent, h);
  return Qt;
}

DEFUN ("cmacs-ai-harness-cancel", Fcmacs_ai_harness_cancel,
       Scmacs_ai_harness_cancel, 1, 1, 0,
       doc: /* Cancel the run in flight on harness HANDLE.  No-op if idle.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  if (!ai_conversation_get_busy (h->conversation)) return Qnil;

  ai_conversation_cancel (h->conversation);
  return Qt;
}

DEFUN ("cmacs-ai-harness-clear", Fcmacs_ai_harness_clear,
       Scmacs_ai_harness_clear, 1, 1, 0,
       doc: /* Empty harness HANDLE's transcript, history and todos.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  ai_conversation_clear (h->conversation);
  return Qt;
}

DEFUN ("cmacs-ai-harness-busy-p", Fcmacs_ai_harness_busy_p,
       Scmacs_ai_harness_busy_p, 1, 1, 0,
       doc: /* Return t when harness HANDLE has a run in flight.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  return ai_conversation_get_busy (h->conversation) ? Qt : Qnil;
}

DEFUN ("cmacs-ai-harness-activity", Fcmacs_ai_harness_activity,
       Scmacs_ai_harness_activity, 1, 1, 0,
       doc: /* Return what harness HANDLE is doing, as a string, or nil.

A gerund like "Reading ai-glib.h" -- what the current turn is up to, for
a mode line.  Nil when idle.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  const gchar *activity = ai_conversation_get_activity (h->conversation);

  return activity ? build_string (activity) : Qnil;
}

/* ── DEFUNs: reading the transcript ─────────────────────────────── */

DEFUN ("cmacs-ai-harness-block-count", Fcmacs_ai_harness_block_count,
       Scmacs_ai_harness_block_count, 1, 1, 0,
       doc: /* Return how many blocks harness HANDLE's transcript holds.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiTranscript *t = ai_conversation_get_transcript (h->conversation);

  return make_uint (ai_transcript_get_n_blocks (t));
}

static Lisp_Object
cmacs_ai_harness__block_kind_symbol (AiViewBlockKind kind)
{
  switch (kind)
    {
    case AI_VIEW_BLOCK_TURN:     return intern ("turn");
    case AI_VIEW_BLOCK_TEXT:     return intern ("text");
    case AI_VIEW_BLOCK_THINKING: return intern ("thinking");
    case AI_VIEW_BLOCK_TOOL:     return intern ("tool");
    case AI_VIEW_BLOCK_STATUS:   return intern ("status");
    case AI_VIEW_BLOCK_TODO:     return intern ("todo");
    case AI_VIEW_BLOCK_AGENT:    return intern ("agent");
    default:                     return intern ("unknown");
    }
}

static AiViewBlock *
cmacs_ai_harness__block_by_id (CmacsAiHarness *h, EMACS_INT id,
                               guint *out_position)
{
  AiTranscript *t = ai_conversation_get_transcript (h->conversation);
  guint n = ai_transcript_get_n_blocks (t);
  guint i;

  for (i = 0; i < n; i++)
    {
      AiViewBlock *b = ai_transcript_get_block (t, i);

      if (b != NULL
          && (EMACS_INT) ai_view_block_get_id (b) == id)
        {
          if (out_position != NULL) *out_position = i;
          return b;
        }
    }

  return NULL;
}

DEFUN ("cmacs-ai-harness-block-at", Fcmacs_ai_harness_block_at,
       Scmacs_ai_harness_block_at, 2, 2, 0,
       doc: /* Describe the block at POSITION in harness HANDLE.

Returns a plist (:id N :kind SYMBOL :expanded FLAG :complete FLAG), or
nil when POSITION is past the end.

KIND is one of turn, text, thinking, tool, status, todo, agent.

Key anything long-lived on :id, never on POSITION: positions shift when
blocks are removed, ids are unique for the life of the process.  */)
  (Lisp_Object handle, Lisp_Object position)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiTranscript *t = ai_conversation_get_transcript (h->conversation);
  AiViewBlock *b;

  CHECK_FIXNAT (position);

  b = ai_transcript_get_block (t, (guint) XFIXNUM (position));

  if (b == NULL) return Qnil;

  return list (intern (":id"),
               make_fixnum ((EMACS_INT) ai_view_block_get_id (b)),
               intern (":kind"),
               cmacs_ai_harness__block_kind_symbol (
                 ai_view_block_get_kind (b)),
               intern (":expanded"),
               ai_view_block_get_expanded (b) ? Qt : Qnil,
               intern (":complete"),
               ai_view_block_get_complete (b) ? Qt : Qnil);
}

DEFUN ("cmacs-ai-harness-block-render", Fcmacs_ai_harness_block_render,
       Scmacs_ai_harness_block_render, 2, 3, 0,
       doc: /* Render block ID of harness HANDLE.

Returns (TEXT . SPANS), or nil when there is no such block.  SPANS is a
list of (START END TAG) where TAG is a style-role string such as
"tool-name" or "added".

START and END are BYTE offsets into TEXT, not character positions --
that is ai-glib's convention throughout, and a span never begins or ends
inside a multi-byte character, so converting with `byte-to-position' is
always exact.  Getting this wrong misplaces every face after the first
accented filename in the buffer.

Optional WIDTH wraps to that many terminal columns; the default of 0
means do not wrap, which is what Emacs wants -- it fills text itself and
would fight pre-wrapped content.  */)
  (Lisp_Object handle, Lisp_Object id, Lisp_Object width)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiViewBlock *b;
  g_autoptr (AiRenderedText) rendered = NULL;
  const gchar *text;
  Lisp_Object spans = Qnil;
  guint n, i;

  CHECK_FIXNUM (id);
  if (!NILP (width)) CHECK_FIXNAT (width);

  b = cmacs_ai_harness__block_by_id (h, XFIXNUM (id), NULL);

  if (b == NULL) return Qnil;

  rendered = ai_view_block_render (b,
                                   NILP (width) ? 0 : (guint) XFIXNUM (width));
  text = ai_rendered_text_get_text (rendered);
  n = ai_rendered_text_get_n_spans (rendered);

  /* Built back-to-front so the list comes out in span order without a
   * reverse: the spans are already sorted and a frontend applying them
   * out of order would still be correct, but a caller reading them
   * would not expect the shuffle. */
  for (i = n; i > 0; i--)
    {
      guint start, len;
      AiStyleTag tag;

      if (!ai_rendered_text_get_span (rendered, i - 1, &start, &len, &tag))
        continue;

      spans = Fcons (list3 (make_uint (start),
                            make_uint (start + len),
                            build_string (ai_style_tag_to_string (tag))),
                     spans);
    }

  return Fcons (build_string (text ? text : ""), spans);
}

DEFUN ("cmacs-ai-harness-set-expanded", Fcmacs_ai_harness_set_expanded,
       Scmacs_ai_harness_set_expanded, 3, 3, 0,
       doc: /* Expand or collapse block ID of harness HANDLE.

FLAG non-nil expands.  Returns t when the block exists.  The change
emits a block-changed event, so the buffer re-renders itself through the
normal path rather than the caller redrawing by hand.  */)
  (Lisp_Object handle, Lisp_Object id, Lisp_Object flag)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiViewBlock *b;

  CHECK_FIXNUM (id);

  b = cmacs_ai_harness__block_by_id (h, XFIXNUM (id), NULL);

  if (b == NULL) return Qnil;

  ai_view_block_set_expanded (b, !NILP (flag));
  return Qt;
}


/* ── DEFUNs: tools ──────────────────────────────────────────────── */

DEFUN ("cmacs-ai-harness-executor", Fcmacs_ai_harness_executor,
       Scmacs_ai_harness_executor, 1, 1, 0,
       doc: /* Return a tool-executor handle for harness HANDLE.

The handle names the AiToolExecutor the conversation already created for
itself, adopted into the same registry `cmacs-ai-tools-new' uses, so
`cmacs-ai-tools-register-mcp-bridge', `cmacs-ai-tools-register' and
`cmacs-ai-tools-set-search-provider' all work on it.

The same handle every time.  Minting a fresh one per call would register
the MCP bridge's tool callbacks onto the same executor again, and
`ai_tool_executor_register_callback' does not dedupe.

Freed with the harness; do not pass it to `cmacs-ai-tools-free'.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiToolExecutor *exec;

  if (h->executor_handle != 0)
    return make_uint (h->executor_handle);

  exec = ai_conversation_get_executor (h->conversation);
  if (exec == NULL)
    error ("cmacs-ai-harness: conversation has no executor");

  h->executor_handle = cmacs_ai_tools_adopt (exec);

  return make_uint (h->executor_handle);
}

DEFUN ("cmacs-ai-harness-set-local-tools",
       Fcmacs_ai_harness_set_local_tools,
       Scmacs_ai_harness_set_local_tools, 2, 2, 0,
       doc: /* Run harness HANDLE's tools in this process when FLAG.

Returns the value that actually stuck, which is not always FLAG: ai-glib
refuses local tools for a CLI provider, because those run their own
tools in their own process and ignore the tools argument entirely.  A
caller that reported the requested value would claim a claude-code
harness had local tools when it has none.

Without this the executor is decoration: the provider is sent no tools
array at all, and an agent-tuned model asked to do something will
describe a tool call in prose instead of making one.  */)
  (Lisp_Object handle, Lisp_Object flag)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  ai_conversation_set_local_tools (h->conversation, !NILP (flag));

  return ai_conversation_get_local_tools (h->conversation) ? Qt : Qnil;
}

DEFUN ("cmacs-ai-harness-local-tools-p",
       Fcmacs_ai_harness_local_tools_p,
       Scmacs_ai_harness_local_tools_p, 1, 1, 0,
       doc: /* Return t when harness HANDLE runs tools in this process.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  return ai_conversation_get_local_tools (h->conversation) ? Qt : Qnil;
}

DEFUN ("cmacs-ai-harness-set-system-prompt",
       Fcmacs_ai_harness_set_system_prompt,
       Scmacs_ai_harness_set_system_prompt, 2, 2, 0,
       doc: /* Set harness HANDLE's system prompt to PROMPT, or nil for none.

A model handed a tool array and no instructions is what produces a
narrated tool call rather than a made one.  */)
  (Lisp_Object handle, Lisp_Object prompt)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);

  if (!NILP (prompt)) CHECK_STRING (prompt);

  ai_conversation_set_system_prompt (h->conversation,
                                     NILP (prompt) ? NULL : SSDATA (prompt));
  return Qt;
}

DEFUN ("cmacs-ai-harness-cli-p", Fcmacs_ai_harness_cli_p,
       Scmacs_ai_harness_cli_p, 1, 1, 0,
       doc: /* Return t when harness HANDLE drives a command-line agent.

Which half of the tool wiring applies depends on this: an HTTP provider
takes a tools array built from the executor, a CLI one takes an MCP
config naming a server.  They are different mechanisms, not two
spellings of one.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  GObject *prov = ai_conversation_get_provider (h->conversation);

  return (prov != NULL && AI_IS_CLI_CLIENT (prov)) ? Qt : Qnil;
}

DEFUN ("cmacs-ai-harness-set-mcp-config",
       Fcmacs_ai_harness_set_mcp_config,
       Scmacs_ai_harness_set_mcp_config, 2, 3, 0,
       doc: /* Point harness HANDLE's CLI agent at the MCP config PATH.

KIND is the endpoint kind, a string, defaulting to "mcp-config" (Claude
Code's schema).  Pass "mcp-config-opencode" or "mcp-config-grok" for a
provider that reads a different dialect; the provider decides how the
file is delivered.

Returns t when the provider took it, nil when it does not accept that
kind.  Nil is worth saying out loud: a session that looks tool-enabled
and has none is the failure this exists to prevent.  */)
  (Lisp_Object handle, Lisp_Object path, Lisp_Object kind)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  g_autoptr (AiAgentEndpoint) ep = NULL;
  g_autoptr (GError) gerror = NULL;
  Lisp_Object enc;

  CHECK_STRING (path);
  if (!NILP (kind)) CHECK_STRING (kind);

  enc = ENCODE_FILE (Fexpand_file_name (path, Qnil));
  ep = ai_agent_endpoint_new (NILP (kind) ? AI_ENDPOINT_KIND_MCP_CONFIG
                                          : SSDATA (kind),
                              SSDATA (enc));

  if (!ai_conversation_set_tool_endpoint (h->conversation, ep, &gerror))
    return Qnil;

  return Qt;
}

DEFUN ("cmacs-ai-harness-revoke-mcp-config",
       Fcmacs_ai_harness_revoke_mcp_config,
       Scmacs_ai_harness_revoke_mcp_config, 1, 1, 0,
       doc: /* Withdraw harness HANDLE's MCP config.  Returns t.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  g_autoptr (GError) gerror = NULL;

  ai_conversation_set_tool_endpoint (h->conversation, NULL, &gerror);

  return Qt;
}

DEFUN ("cmacs-ai-harness-todos", Fcmacs_ai_harness_todos,
       Scmacs_ai_harness_todos, 1, 1, 0,
       doc: /* Return harness HANDLE's todo list as ((LABEL . STATE) ...).

STATE is a string: "pending", "in_progress" or "completed".  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiToolExecutor *exec = ai_conversation_get_executor (h->conversation);
  Lisp_Object out = Qnil;
  guint n, i;

  if (exec == NULL) return Qnil;

  n = ai_tool_executor_get_n_todos (exec);
  for (i = 0; i < n; i++)
    {
      const gchar *content = NULL;
      AiTodoState state = AI_TODO_PENDING;

      if (!ai_tool_executor_get_todo_fields (exec, i, &content, &state))
        continue;

      out = Fcons (Fcons (build_string (content ? content : ""),
                          build_string (ai_todo_state_to_string (state))),
                   out);
    }

  return Fnreverse (out);
}

/* ── DEFUNs: export ─────────────────────────────────────────────── */

DEFUN ("cmacs-ai-harness-export", Fcmacs_ai_harness_export,
       Scmacs_ai_harness_export, 1, 2, 0,
       doc: /* Return harness HANDLE's session as a document string.

FORMAT is the symbol `text', `markdown' or `org'; the default is
`markdown'.

Every block is rendered expanded whatever the buffer is showing, so a
collapsed tool group still records which files it touched.  */)
  (Lisp_Object handle, Lisp_Object format)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  AiTranscript *t = ai_conversation_get_transcript (h->conversation);
  AiExportFormat fmt = AI_EXPORT_FORMAT_MARKDOWN;
  g_autofree gchar *doc = NULL;

  if (!NILP (format))
    {
      CHECK_SYMBOL (format);

      if (!ai_export_format_from_string (SSDATA (SYMBOL_NAME (format)), &fmt))
        error ("cmacs-ai-harness: unknown export format %s",
               SSDATA (SYMBOL_NAME (format)));
    }

  doc = ai_transcript_export (t, fmt);

  return build_string (doc ? doc : "");
}

DEFUN ("cmacs-ai-harness-export-extension",
       Fcmacs_ai_harness_export_extension,
       Scmacs_ai_harness_export_extension, 1, 1, 0,
       doc: /* Return the file extension for export FORMAT, without the dot.

From ai-glib, so that cmacs and `ai-tui' cannot disagree about what an
org export is called.  */)
  (Lisp_Object format)
{
  AiExportFormat fmt;

  CHECK_SYMBOL (format);

  if (!ai_export_format_from_string (SSDATA (SYMBOL_NAME (format)), &fmt))
    error ("cmacs-ai-harness: unknown export format %s",
           SSDATA (SYMBOL_NAME (format)));

  return build_string (ai_export_format_extension (fmt));
}

/* ── DEFUNs: completion ─────────────────────────────────────────── */

DEFUN ("cmacs-ai-harness-complete", Fcmacs_ai_harness_complete,
       Scmacs_ai_harness_complete, 3, 3, 0,
       doc: /* Complete TEXT at BYTE-POS for harness HANDLE.

Returns (START END CANDIDATES) where START and END are BYTE offsets into
TEXT bounding the token being completed, and CANDIDATES is a list of
(TEXT DISPLAY DESCRIPTION DIRECTORY-P).  Returns nil when there is
nothing to complete.

Let the library decide the range.  Recomputing it in Elisp -- "the word
before point", say -- disagrees the first time somebody completes
@src/co, where the token includes a slash.  */)
  (Lisp_Object handle, Lisp_Object text, Lisp_Object byte_pos)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  g_autoptr (AiCompletionResult) result = NULL;
  Lisp_Object candidates = Qnil;
  guint n, i;

  CHECK_STRING (text);
  CHECK_FIXNAT (byte_pos);

  if (h->completion == NULL) return Qnil;

  result = ai_completion_context_query (h->completion, SSDATA (text),
                                        (gsize) XFIXNUM (byte_pos));

  if (result == NULL) return Qnil;

  n = ai_completion_result_get_n_items (result);

  if (n == 0) return Qnil;

  for (i = n; i > 0; i--)
    {
      const gchar *ctext = NULL;
      const gchar *display = NULL;
      const gchar *description = NULL;
      const gchar *origin = NULL;
      gboolean is_dir = FALSE;

      /* Out-parameters, because a struct behind a pointer does not
       * survive introspection -- and the same reason this bridge exists
       * rather than a cmacs-gi call. */
      if (!ai_completion_result_get_item_fields (result, i - 1, &ctext,
                                                 &display, &description,
                                                 &origin, &is_dir))
        continue;

      candidates =
        Fcons (list4 (build_string (ctext ? ctext : ""),
                      display ? build_string (display) : Qnil,
                      description ? build_string (description)
                                  : Qnil,
                      is_dir ? Qt : Qnil),
               candidates);
    }

  return list3 (make_uint (ai_completion_result_get_start (result)),
                make_uint (ai_completion_result_get_end (result)),
                candidates);
}

DEFUN ("cmacs-ai-harness-commands", Fcmacs_ai_harness_commands,
       Scmacs_ai_harness_commands, 1, 1, 0,
       doc: /* Return the slash commands harness HANDLE knows.

A list of (NAME DESCRIPTION ARGUMENT-HINT ORIGIN), where ORIGIN says
where the command came from -- nil for a built-in, otherwise the harness
whose directory it was read from.

This is what makes /help answerable in the buffer rather than only in
the terminal frontend: the set is the library's, including every command
file the user already wrote for another tool.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  GList *commands, *l;
  Lisp_Object out = Qnil;

  if (h->commands == NULL) return Qnil;

  commands = ai_command_set_list (h->commands);

  /* Built back-to-front so the result comes out in the library's order
   * rather than reversed. */
  commands = g_list_reverse (commands);

  for (l = commands; l != NULL; l = l->next)
    {
      AiCommand *c = l->data;
      const gchar *name = ai_command_get_name (c);
      const gchar *desc = ai_command_get_description (c);
      const gchar *hint = ai_command_get_argument_hint (c);
      const gchar *origin = ai_command_get_origin (c);

      out = Fcons (list4 (build_string (name ? name : ""),
                          desc ? build_string (desc) : Qnil,
                          hint ? build_string (hint) : Qnil,
                          origin ? build_string (origin) : Qnil),
                   out);
    }

  g_list_free_full (commands, g_object_unref);

  return out;
}

/* ── DEFUNs: working directory ──────────────────────────────────── */

DEFUN ("cmacs-ai-harness-working-directory",
       Fcmacs_ai_harness_working_directory,
       Scmacs_ai_harness_working_directory, 1, 1, 0,
       doc: /* Return harness HANDLE's working directory.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  const gchar *dir = ai_conversation_get_working_directory (h->conversation);

  return dir ? DECODE_FILE (build_unibyte_string (dir)) : Qnil;
}

DEFUN ("cmacs-ai-harness-set-working-directory",
       Fcmacs_ai_harness_set_working_directory,
       Scmacs_ai_harness_set_working_directory, 2, 2, 0,
       doc: /* Run harness HANDLE's agent in DIRECTORY from now on.  */)
  (Lisp_Object handle, Lisp_Object directory)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  Lisp_Object enc;

  CHECK_STRING (directory);
  enc = ENCODE_FILE (Fexpand_file_name (directory, Qnil));

  ai_conversation_set_working_directory (h->conversation, SSDATA (enc));

  /* Completion resolves @paths against the working directory, so it has
   * to follow -- otherwise /cwd moves the agent and leaves its file
   * completion pointing at where it used to be. */
  if (h->completion != NULL)
    ai_completion_context_set_working_directory (
      h->completion,
      ai_conversation_get_working_directory (h->conversation));

  return Qt;
}

DEFUN ("cmacs-ai-harness-provider-name", Fcmacs_ai_harness_provider_name,
       Scmacs_ai_harness_provider_name, 1, 1, 0,
       doc: /* Return the display name of harness HANDLE's provider.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  GObject *prov = ai_conversation_get_provider (h->conversation);
  const gchar *name;

  if (prov == NULL || !AI_IS_PROVIDER (prov)) return Qnil;

  name = ai_provider_get_name (AI_PROVIDER (prov));

  return name ? build_string (name) : Qnil;
}

DEFUN ("cmacs-ai-harness-model", Fcmacs_ai_harness_model,
       Scmacs_ai_harness_model, 1, 1, 0,
       doc: /* Return the model harness HANDLE runs, or nil.  */)
  (Lisp_Object handle)
{
  CmacsAiHarness *h = cmacs_ai_harness__lookup (handle);
  GObject *prov = ai_conversation_get_provider (h->conversation);
  const gchar *model = NULL;

  if (prov == NULL) return Qnil;

  if (AI_IS_CLIENT (prov))
    model = ai_client_get_model (AI_CLIENT (prov));
  else if (AI_IS_CLI_CLIENT (prov))
    model = ai_cli_client_get_model (AI_CLI_CLIENT (prov));

  return model ? build_string (model) : Qnil;
}

/* ── Registration ───────────────────────────────────────────────── */

void syms_of_cmacs_ai_harness (void);
void
syms_of_cmacs_ai_harness (void)
{
  Vcmacs_ai__harness_callbacks = Qnil;
  staticpro (&Vcmacs_ai__harness_callbacks);

  defsubr (&Scmacs_ai_harness_new);
  defsubr (&Scmacs_ai_harness_free);
  defsubr (&Scmacs_ai_harness_set_callback);
  defsubr (&Scmacs_ai_harness_send_input);
  defsubr (&Scmacs_ai_harness_cancel);
  defsubr (&Scmacs_ai_harness_clear);
  defsubr (&Scmacs_ai_harness_busy_p);
  defsubr (&Scmacs_ai_harness_activity);
  defsubr (&Scmacs_ai_harness_block_count);
  defsubr (&Scmacs_ai_harness_block_at);
  defsubr (&Scmacs_ai_harness_block_render);
  defsubr (&Scmacs_ai_harness_set_expanded);
  defsubr (&Scmacs_ai_harness_executor);
  defsubr (&Scmacs_ai_harness_set_local_tools);
  defsubr (&Scmacs_ai_harness_local_tools_p);
  defsubr (&Scmacs_ai_harness_set_system_prompt);
  defsubr (&Scmacs_ai_harness_cli_p);
  defsubr (&Scmacs_ai_harness_set_mcp_config);
  defsubr (&Scmacs_ai_harness_revoke_mcp_config);
  defsubr (&Scmacs_ai_harness_todos);
  defsubr (&Scmacs_ai_harness_export);
  defsubr (&Scmacs_ai_harness_export_extension);
  defsubr (&Scmacs_ai_harness_complete);
  defsubr (&Scmacs_ai_harness_commands);
  defsubr (&Scmacs_ai_harness_working_directory);
  defsubr (&Scmacs_ai_harness_set_working_directory);
  defsubr (&Scmacs_ai_harness_provider_name);
  defsubr (&Scmacs_ai_harness_model);
}

#endif /* HAVE_CMACS_AI */
