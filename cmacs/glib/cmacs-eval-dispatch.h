/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-eval-dispatch.h — shared dispatch for CMacs eval operations
 *
 * Pure C dispatch layer used by both the D-Bus service and the
 * socketpair IPC handler.  All functions run on the Emacs main thread.
 */

#ifndef CMACS_EVAL_DISPATCH_H
#define CMACS_EVAL_DISPATCH_H

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include <glib.h>

/* Evaluate EXPRESSION as elisp.  On success, return the printed
   result (caller must g_free).  On error, set *ERROR and return NULL. */
gchar *cmacs_dispatch_eval (const gchar *expression, GError **error);

/* Open PATH in Emacs via find-file. */
void cmacs_dispatch_find_file (const gchar *path);

/* Display TEXT in the echo area via message. */
void cmacs_dispatch_message (const gchar *text);

/* Require GI namespace NS version VER.  Returns TRUE on success. */
gboolean cmacs_dispatch_gi_require (const gchar *ns, const gchar *ver,
                                    GError **error);

/* Call GI function FUNC in namespace NS with string args.
   Returns printed result (caller must g_free), or NULL on error. */
gchar *cmacs_dispatch_gi_call (const gchar *ns, const gchar *func,
                               const gchar *const *args, gint n_args,
                               GError **error);

/* List functions in GI namespace NS.
   Returns NULL-terminated string array (caller must g_strfreev). */
gchar **cmacs_dispatch_gi_list_functions (const gchar *ns);

#endif /* HAVE_CMACS_GLIB */
#endif /* CMACS_EVAL_DISPATCH_H */
