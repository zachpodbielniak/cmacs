/* cmacs-lrgscript-bridge.h --- GValue-only bridge to the Emacs Lisp VM.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Declares the bridge functions that cmacs-lrgscript-elisp.c (the libregnum
 * side, which must never include lisp.h) calls to do the actual Emacs Lisp
 * work.  Every signature is GValue + plain C, so no Lisp_Object leaks across
 * the firewall.  Implemented in cmacs-lrgscript-bridge.c (the lisp side,
 * which must never include <libregnum.h>).
 *
 * All of these run on the Emacs main thread and, where they enter Lisp, go
 * through cmacs-eval-dispatch's waiting_for_input guard so a signalled elisp
 * error stays inside a condition-case instead of aborting the process. */

#ifndef CMACS_LRGSCRIPT_BRIDGE_H
#define CMACS_LRGSCRIPT_BRIDGE_H

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include <glib.h>
#include <glib-object.h>

G_BEGIN_DECLS

/* Read + eval CODE (a NUL-terminated elisp string), discarding the value.
 * NAME is used only in error messages.  On error return FALSE and, if ERR is
 * non-NULL, store a g_strdup'd message in *ERR (caller g_free). */
gboolean cmacs_lrgscript_bridge_load_string (const gchar *name,
                                             const gchar *code,
                                             gchar      **err);

/* Load the elisp file at PATH (read + eval each top-level form). */
gboolean cmacs_lrgscript_bridge_load_file (const gchar *path, gchar **err);

/* Call the elisp function named NAME with N_ARGS GValue arguments.  If RET is
 * non-NULL it is initialised and set to the marshalled return value (caller
 * g_value_unset).  A signalled elisp error is caught and reported via ERR. */
gboolean cmacs_lrgscript_bridge_call (const gchar  *name,
                                      guint         n_args,
                                      const GValue *args,
                                      GValue       *ret,
                                      gchar       **err);

/* Whether an elisp function NAME is currently fboundp (used for hook-name
 * probing: LrgScriptComponent asks for "lrg_script_update", we also accept the
 * idiomatic "lrg-script-update"). */
gboolean cmacs_lrgscript_bridge_fboundp (const gchar *name);

/* Get / set an elisp global variable as a GValue. */
gboolean cmacs_lrgscript_bridge_get_global (const gchar *name,
                                            GValue      *out,
                                            gchar      **err);
gboolean cmacs_lrgscript_bridge_set_global (const gchar  *name,
                                            const GValue *val,
                                            gchar       **err);

/* Bind the elisp symbol NAME to the host-function trampoline so scripts can
 * call a C callback registered via LrgScripting::register_function.  The
 * trampoline (cmacs-lrgscript--invoke-host) resolves the callback through
 * cmacs_lrgscript_invoke_host_fn(). */
gboolean cmacs_lrgscript_bridge_bind_host_fn (const gchar *name, gchar **err);

/* Unbind a previously bound host-function symbol (LrgScripting::reset). */
void cmacs_lrgscript_bridge_unbind_host_fn (const gchar *name);

G_END_DECLS

#endif /* HAVE_CMACS_LRGSCRIPT */
#endif /* CMACS_LRGSCRIPT_BRIDGE_H */
