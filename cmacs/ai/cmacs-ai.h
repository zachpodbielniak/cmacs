/* cmacs-ai.h --- ai-glib AI subsystem for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header.  Wraps ai-glib (HTTP + CLI providers, streaming,
 * tool use, image generation) for use from Elisp.  All resources are
 * exposed via integer handles into staticpro'd registries so the
 * Lisp_Object closures stay GC-rooted for the lifetime of any async
 * operation. */

#ifndef CMACS_AI_H
#define CMACS_AI_H

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include <ai-glib.h>

/* syms_of_cmacs_ai / init_cmacs_ai are declared in src/lisp.h
 * alongside the other cmacs subsystem entry points; do not
 * re-declare here (gcc -Wredundant-decls). */

/* Client registry (cmacs-ai-client.c). */
/* ── User-defined OpenAI-compatible endpoints ────────────────────────
 *
 * ai-glib has one AI_PROVIDER_OPENAI_COMPATIBLE, but a user has more
 * than one server to talk to: a vLLM box, a llama.cpp on the laptop, a
 * hosted gateway.  `cmacs-ai-openai-compatible-endpoints' names each
 * one, and every provider symbol in that alist behaves like a provider
 * of its own -- it completes in `cmacs-ai-chat-with-provider', it can
 * be a brigade agent's model prefix, it can be the textops provider.
 *
 * Returns the endpoint's plist for SYM, or Qnil when SYM does not name
 * one.  Reading the variable is a plain cell read, so this is safe from
 * anywhere the client factory runs. */
extern Lisp_Object cmacs_ai_openai_compatible_endpoint (Lisp_Object sym);

/* True when SYM is `openai-compatible' (or its `http' alias). */
extern bool cmacs_ai_openai_compatible_symbol_p (Lisp_Object sym);

/* Provider symbol -> AiProviderType, strictly: an unknown name is an
 * error rather than ai_provider_type_from_string's silent fall back to
 * Claude, which for a typo means billing somewhere nobody asked for.
 * Endpoint-aware, so a user's own server name resolves too. */
extern AiProviderType cmacs_ai_provider_type_from_symbol (Lisp_Object sym);

/* When SYM names an entry in `cmacs-ai-openai-compatible-endpoints',
 * push that entry's base-url / api-key / model onto PROV.  A no-op for
 * every other symbol, and for a provider object that is not an
 * OpenAI-compatible client.
 *
 * The type alone is not enough to build one of these: two endpoints are
 * the same AI_PROVIDER_OPENAI_COMPATIBLE and differ only in properties,
 * so any path that constructs from a type has to call this or it gets
 * whichever server the environment happens to name. */
extern void cmacs_ai_apply_endpoint_settings (Lisp_Object sym, gpointer prov);

/* Run PROV under the account `cmacs-ai-cli-config-dirs' names for SYM
 * (or, failing that, for PROV's provider type), through
 * ai_cli_client_set_config_dir.  Call it wherever a client is built, the
 * same places as cmacs_ai_apply_endpoint_settings.
 *
 * Does not signal for a bad setting: returns NULL when there is nothing
 * to do or the directory took, else a newly allocated message the
 * caller g_frees
 * after releasing PROV and signals as a `user-error' -- an entry for an
 * HTTP provider, or for a CLI that keeps its login under $HOME
 * (cursor, antigravity). */
extern gchar *cmacs_ai_apply_cli_config_dir (Lisp_Object sym, gpointer prov);

/* ── ACP agents and the codex transport (ai-glib 0.13) ───────────────
 *
 * `cmacs-ai-acp-agents' is to AI_PROVIDER_ACP what the endpoint alist is
 * to AI_PROVIDER_OPENAI_COMPATIBLE: ACP has no request that selects a
 * model, so what distinguishes one agent from another is its command
 * line, and each named command line is a provider symbol of its own.
 *
 * Returns the agent's plist for SYM, or Qnil. */
extern Lisp_Object cmacs_ai_acp_agent (Lisp_Object sym);

/* True when SYM is `acp' or one of ai-glib's aliases for it. */
extern bool cmacs_ai_acp_symbol_p (Lisp_Object sym);

/* Everything a freshly built provider needs that its type alone does
 * not carry, in one call so no construction site can apply half of it:
 * a named OpenAI-compatible endpoint's URL and key, a named ACP agent's
 * command line and permission flags, and `cmacs-ai-codex-transport' on
 * a codex client.  Each part is a no-op for a provider it does not
 * concern, and SYM may be Qnil (the configured default provider).
 * Never signals.
 *
 * cmacs_ai_apply_endpoint_settings is the older name for the first
 * third and now simply calls this, so a site written against it gets
 * the rest too. */
extern void cmacs_ai_apply_provider_settings (Lisp_Object sym, gpointer prov);

/* ── Errors worth telling apart (cmacs-ai-stream.c) ──────────────────
 *
 * A usage limit, a 429, an expired login and an empty wallet used to
 * reach Lisp as four strings.  ai-glib 0.13 gives them codes and, for
 * the first two, a machine-readable reset time; this is the one place
 * cmacs reads them.
 *
 * Returns the kind as a C string -- "session-limit", "rate-limited",
 * "signed-out", "quota" -- or NULL for every other error.  *RESET_OUT
 * is the Unix time the limit lifts, 0 when unknown.  *CLEAN_OUT, when
 * non-NULL, receives ERROR's message with the raw
 * `ai-glib-session-limit:' notice removed (caller g_frees); the notice
 * is for supervisors, and a person should never have to read it.
 *
 * Pure: no Lisp, callable from any thread. */
extern const gchar *cmacs_ai_error_classify (const GError *gerr,
                                             gint64       *reset_out,
                                             gchar       **clean_out);

/* The Lisp payload for ERROR: (:error MESSAGE), or
 * (:error MESSAGE :kind SYMBOL :reset TIMESTAMP-OR-NIL) when the error
 * classifies.  MESSAGE stays second so every consumer that reads
 * `cadr' or `plist-get :error' is unaffected.  FALLBACK is the message
 * when ERROR is NULL.  Main thread only: it allocates Lisp objects. */
extern Lisp_Object cmacs_ai_error_payload (const GError *gerr,
                                           const char   *fallback);

/* ── Steering (cmacs-ai-tools.c) ─────────────────────────────────────
 *
 * Words into a running turn, through ai-glib's AiSteerable.  TARGET is
 * the executor or provider to steer.  The answer is delivered on the
 * main thread as (:steer RESULT REASON ID), RESULT one of the symbols
 * `delivered', `indeterminate', `refused': to harness HARNESS's event
 * callback when HARNESS is non-zero, else to the one-shot callback
 * COOKIE.  Returns ID, a ticket that is all the async callback carries
 * -- an integer, so a harness or executor freed mid-steer leaves it a
 * number that fails to look up rather than a pointer to dereference.
 * Main thread only. */
extern guint cmacs_ai_steer_start (gpointer target, const gchar *text,
                                   guint harness, uint64_t cookie);

/* Deliver PAYLOAD to harness HANDLE's event callback, if it still
 * exists (cmacs-ai-harness.c).  Main thread only. */
extern void cmacs_ai_harness_emit_handle (guint handle, Lisp_Object payload);

extern void   cmacs_ai_client_registry_init  (void);
extern guint  cmacs_ai_client_register       (gpointer client_gobject);
extern gpointer cmacs_ai_client_lookup       (guint handle);
extern void   cmacs_ai_client_unregister     (guint handle);

/* Session registry (cmacs-ai-session.c).  A session owns its
 * AiClient ref + GList<AiMessage>. */
typedef struct CmacsAiSession CmacsAiSession;
extern void   cmacs_ai_session_registry_init (void);
extern guint  cmacs_ai_session_create        (guint client_handle);
extern CmacsAiSession *cmacs_ai_session_lookup (guint handle);
extern void   cmacs_ai_session_destroy       (guint handle);

/* Session field accessors (private to cmacs/ai/, do NOT expose via
 * gi-call --- they take CmacsAiSession*, not GObject). */
extern AiProvider *cmacs_ai_session_get_provider       (CmacsAiSession *s);
extern GList      *cmacs_ai_session_get_messages       (CmacsAiSession *s);
extern void        cmacs_ai_session_append_message_obj (CmacsAiSession *s,
                                                        AiMessage *msg);
/* Drop the oldest messages until at most LIMIT remain; LIMIT <= 0 is a
 * no-op.  For sessions that live across turns, where the whole list is
 * re-sent every time. */
extern void        cmacs_ai_session_trim               (CmacsAiSession *s,
                                                        gint limit);
extern AiToolExecutor *cmacs_ai_session_ensure_executor (CmacsAiSession *s);
extern GCancellable *cmacs_ai_session_install_cancellable (CmacsAiSession *s);
extern void        cmacs_ai_session_clear_cancellable  (CmacsAiSession *s);
extern void        cmacs_ai_session_cancel_current     (CmacsAiSession *s);

/* ── Image input (cmacs-ai-vision.c) ─────────────────────────────────
 *
 * IMAGES is what every image-taking DEFUN accepts: a list of plists
 * (:file PATH) or (:data UNIBYTE-STRING :mime TYPE), or one plist.
 * Returns a GList of AiImageContent the caller owns (free with
 * cmacs_ai_images_free), or NULL for nil.  Signals `cmacs-ai-error' --
 * having allocated nothing -- for an image that is not a PNG/JPEG/GIF/
 * WebP by its bytes, a file that is not a regular file or is over
 * `cmacs-ai-image-max-bytes', or more than `cmacs-ai-image-max-count'
 * images.  Main thread only.
 *
 * A caller that may signal after this returns registers
 * cmacs_ai_images_unwind with record_unwind_protect_ptr. */
extern GList *cmacs_ai_images_from_lisp (Lisp_Object images);
extern void   cmacs_ai_images_free      (GList *images);
extern void   cmacs_ai_images_unwind    (void *images);

/* A user message holding TEXT and then IMAGES (transfer none: each
 * block is referenced).  With IMAGES NULL this is exactly
 * ai_message_new_user (TEXT). */
extern AiMessage *cmacs_ai_user_message_new (const char *text,
                                             GList *images);

/* Auto-load AiGlib-1.0 typelib so gi-require / cmacsgi find it
 * without manual GI_TYPELIB_PATH setup (cmacs-ai-typelib.c). */
extern void   cmacs_ai_typelib_autoload      (void);

/* Tool registry (cmacs-ai-tools.c).  Used by the MCP tool group
 * and the chat layer; safe to call even without a session. */
extern AiToolExecutor *cmacs_ai_tools_new_default (void);
extern AiToolExecutor *cmacs_ai_tools_lookup      (guint handle);
/* Give an executor cmacs did not create a handle in the same registry,
 * so the MCP bridge and custom Elisp tools can reach it. */
extern guint           cmacs_ai_tools_adopt       (AiToolExecutor *exec);
extern void            cmacs_ai_tools_drop        (guint handle);

/* The Emacs main GThread, captured in init_cmacs_ai (defined in
 * cmacs-ai-tools.c).  A tool callback fired on this thread may safely
 * call back into Lisp and return the result to the model; a callback on
 * a worker thread (the async tool loop) must not. */
extern GThread *cmacs_ai__main_gthread;

#endif /* HAVE_CMACS_AI */
#endif /* CMACS_AI_H */
