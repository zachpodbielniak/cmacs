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
extern AiToolExecutor *cmacs_ai_session_ensure_executor (CmacsAiSession *s);
extern GCancellable *cmacs_ai_session_install_cancellable (CmacsAiSession *s);
extern void        cmacs_ai_session_clear_cancellable  (CmacsAiSession *s);

/* Auto-load AiGlib-1.0 typelib so gi-require / cmacsgi find it
 * without manual GI_TYPELIB_PATH setup (cmacs-ai-typelib.c). */
extern void   cmacs_ai_typelib_autoload      (void);

/* Tool registry (cmacs-ai-tools.c).  Used by the MCP tool group
 * and the chat layer; safe to call even without a session. */
extern AiToolExecutor *cmacs_ai_tools_new_default (void);
extern AiToolExecutor *cmacs_ai_tools_lookup      (guint handle);

#endif /* HAVE_CMACS_AI */
#endif /* CMACS_AI_H */
