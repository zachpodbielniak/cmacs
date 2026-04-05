/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api.h --- public C API for interacting with CMacs
 *
 * Include this header from crispy init.c scripts or any C code that
 * needs to call back into the CMacs editor.  Three transport backends
 * are available:
 *
 *   DIRECT  -- in-process function calls (crispy scripts loaded via
 *              g_module_open into the Emacs process)
 *   FD      -- length-prefixed JSON over a Unix socketpair
 *              (bacon child process, $CMACS_IPC_FD)
 *   D-Bus   -- GDBusProxy to org.cmacs.Editor1
 *              (external tools, $CMACS_DBUS_NAME)
 *
 * Auto-detection order: DIRECT > FD > D-Bus.
 */

#ifndef CMACS_API_H
#define CMACS_API_H

#include <glib.h>
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

G_BEGIN_DECLS

/* ── Opaque handle ────────────────────────────────────────────────── */

typedef struct _CmacsApi CmacsApi;

/* Create a new API handle.  Auto-detects the best transport.
   Returns NULL on failure (sets *error). */
CmacsApi *cmacs_api_new (GError **error);

/* Free the API handle and its resources. */
void cmacs_api_free (CmacsApi *api);

/* ── Direct dispatch (in-process transport) ───────────────────────── */

/* Function pointer table for the DIRECT transport backend.
   Populated by cmacs-crispy.c before executing scripts so that
   in-process code can call Emacs dispatch functions without a
   link-time dependency on Emacs internals. */
typedef struct
{
  gchar    *(*eval)       (const gchar *expression, GError **error);
  void      (*find_file)  (const gchar *path);
  void      (*message)    (const gchar *text);
  gboolean  (*gi_require) (const gchar *ns, const gchar *ver,
                           GError **error);
  gchar    *(*gi_call)    (const gchar *ns, const gchar *func,
                           const gchar *const *args, gint n_args,
                           GError **error);
  gchar   **(*gi_list_functions) (const gchar *ns);
} CmacsApiDirectDispatch;

/* Register the direct dispatch table.  Must be called before any
   CmacsApi handle uses the DIRECT transport.  The pointer must
   remain valid for the lifetime of the process. */
void cmacs_api_set_direct_dispatch (const CmacsApiDirectDispatch *dispatch);

/* ── High-level operations ────────────────────────────────────────── */

/* Set an Emacs variable.  VALUE is auto-quoted: numbers and t/nil
   pass through as Lisp values, everything else becomes a string. */
gint cmacs_set (CmacsApi *api, const gchar *var, const gchar *value);

/* Get an Emacs variable value.  On success, stores the printed Lisp
   value in *out (caller must g_free).  Returns 0 on success. */
gint cmacs_get (CmacsApi *api, const gchar *var, gchar **out);

/* Load a color theme by name. */
gint cmacs_theme (CmacsApi *api, const gchar *name);

/* Set the default font.  Pass size <= 0 to leave it unchanged. */
gint cmacs_font (CmacsApi *api, const gchar *family, gint size);

/* Enable a global minor mode (or set a major mode).
   Appends "-mode" if not already present. */
gint cmacs_mode (CmacsApi *api, const gchar *name);

/* Evaluate arbitrary elisp.  Returns 0 on success. */
gint cmacs_eval (CmacsApi *api, const gchar *elisp);

/* Open a file in the editor. */
gint cmacs_open (CmacsApi *api, const gchar *path);

/* Display a message in the echo area. */
gint cmacs_message (CmacsApi *api, const gchar *text);

/* Install an Emacs package via package.el. */
gint cmacs_pkg_install (CmacsApi *api, const gchar *name);

/* Remove an Emacs package. */
gint cmacs_pkg_remove (CmacsApi *api, const gchar *name);

/* ── Low-level transport access ───────────────────────────────────── */

/* The transport layer is exposed for advanced use (e.g. the cmacsgi
   bacon module).  Most users should use the high-level API above. */

typedef struct _CmacsApiTransport CmacsApiTransport;

/* Auto-detect transport.  Returns NULL on failure (sets *error). */
CmacsApiTransport *cmacs_api_transport_new (GError **error);

/* Free the transport. */
void cmacs_api_transport_free (CmacsApiTransport *t);

/* Call a method with GVariant params.  Returns the result GVariant
   (caller unrefs), or NULL on error (sets *error). */
GVariant *cmacs_api_transport_call (CmacsApiTransport *t,
                                    const gchar       *method,
                                    GVariant          *params,
                                    GError           **error);

/* ── Eval helpers (for building cmacsgi-style commands) ───────────── */

/* Evaluate elisp via transport, print result to stdout. */
gint cmacs_api_eval_print (CmacsApiTransport *t, const gchar *elisp);

/* Evaluate elisp via transport, suppress output. */
gint cmacs_api_eval_quiet (CmacsApiTransport *t, const gchar *elisp);

/* Evaluate elisp, return result as string (caller g_free). */
gchar *cmacs_api_eval_get_string (CmacsApiTransport *t,
                                  const gchar       *elisp);

/* ── String utilities ─────────────────────────────────────────────── */

/* Escape a C string for embedding in a Lisp string literal.
   Does NOT add outer quotes.  Caller must g_free(). */
gchar *cmacs_api_lisp_escape (const gchar *s);

/* Quote a value for the Lisp reader: numbers, t/nil, quoted strings,
   and s-expressions pass through; bare words become string literals.
   Caller must g_free(). */
gchar *cmacs_api_lisp_quote (const gchar *s);

/* ── Dispatch table types (for cmacsgi command groups) ────────────── */

typedef gint (*CmacsApiHandler)(CmacsApiTransport *transport,
                                gint argc, gchar **argv);

typedef struct {
    const gchar     *name;
    CmacsApiHandler  handler;
    const gchar     *usage;
    const gchar     *help;
} CmacsApiSubcmd;

/* Dispatch argv[depth] against a NULL-terminated subcommand table.
   Prints error on unknown subcommand. */
gint cmacs_api_dispatch_group (const gchar          *group_name,
                               const CmacsApiSubcmd *table,
                               CmacsApiTransport    *transport,
                               gint                  argc,
                               gchar               **argv,
                               gint                  depth);

/* Print subcommand table as help text. */
void cmacs_api_print_group_help (const gchar          *group_name,
                                 const CmacsApiSubcmd *table);

G_END_DECLS

#endif /* CMACS_API_H */
