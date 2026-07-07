/* cmacs-lrgscript-object.h --- libregnum-side accessors for the elisp backend.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Prototypes implemented by cmacs-lrgscript-elisp.c (the <libregnum.h> side).
 * This header is deliberately lisp.h-free (glib only) so that both the
 * libregnum side (elisp.c) and the lisp side (defuns.c / init.c, via
 * cmacs-lrgscript.h which includes this) can see the same declarations
 * without either dragging in the other's headers.  Everything crosses as
 * GValue + plain C; no Lisp_Object and no LrgScripting type appears here.
 *
 * The context handle is an opaque `gpointer' (an LrgScripting *). */

#ifndef CMACS_LRGSCRIPT_OBJECT_H
#define CMACS_LRGSCRIPT_OBJECT_H

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include <glib.h>
#include <glib-object.h>

G_BEGIN_DECLS

/* Register the elisp backend with libregnum's scripting manager (idempotent). */
void cmacs_lrgscript_register_backend (void);

/* Whether the elisp backend is registered/available in the manager. */
gboolean cmacs_lrgscript_available_p (void);

/* A lazily-created, process-shared elisp LrgScripting context (owned; kept
 * for process lifetime).  Elisp uses one global obarray, so a single shared
 * context suffices for the convenience DEFUNs.  Returns NULL if creation
 * fails (e.g. backend not registered). */
gpointer cmacs_lrgscript_shared_context (void);

/* Drive a context through the genuine LrgScripting vtable.  On failure return
 * FALSE and, if ERR is non-NULL, store a g_strdup'd message (caller g_free). */
gboolean cmacs_lrgscript_ctx_load_string (gpointer ctx, const gchar *name,
                                          const gchar *code, gchar **err);
gboolean cmacs_lrgscript_ctx_call (gpointer ctx, const gchar *name,
                                   guint n_args, const GValue *args,
                                   GValue *ret, gchar **err);
gboolean cmacs_lrgscript_ctx_get_global (gpointer ctx, const gchar *name,
                                         GValue *out, gchar **err);
gboolean cmacs_lrgscript_ctx_set_global (gpointer ctx, const gchar *name,
                                         const GValue *val, gchar **err);

/* Resolve + call a host function registered via LrgScripting::register_function
 * (backs the cmacs-lrgscript--invoke-host trampoline). */
gboolean cmacs_lrgscript_invoke_host_fn (const gchar *name, guint n_args,
                                         const GValue *args, GValue *ret,
                                         gchar **err);

G_END_DECLS

#endif /* HAVE_CMACS_LRGSCRIPT */
#endif /* CMACS_LRGSCRIPT_OBJECT_H */
