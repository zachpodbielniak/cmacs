/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-internal.h — shared types and utilities for cmacsgi subcommands
 *
 * Every cmacs-gi-cmd-*.c file includes this header.  It provides the
 * dispatch-table types, shared D-Bus/eval helpers, and string utilities
 * so that individual command groups are self-contained.
 */

#ifndef CMACS_GI_CMD_INTERNAL_H
#define CMACS_GI_CMD_INTERNAL_H

#include <gio/gio.h>
#include <glib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ── Dispatch table types ─────────────────────────────────────────── */

/* Handler signature: receives the D-Bus proxy and the FULL argc/argv
   from the top-level cmacsgi invocation.  argv[0] is "cmacsgi",
   argv[1] is the subcommand name.  For group commands (e.g. "buf list")
   the group handler receives the same argv — it dispatches on argv[2]. */
typedef gint (*CmacsGiHandler)(GDBusProxy *proxy, gint argc, gchar **argv);

typedef struct {
    const gchar     *name;      /* subcommand name */
    CmacsGiHandler   handler;   /* function pointer */
    const gchar     *usage;     /* one-line usage string */
    const gchar     *help;      /* short description (one sentence) */
} CmacsGiSubcmd;

/* ── D-Bus proxy ──────────────────────────────────────────────────── */

/* Get a GDBus proxy to the CMacs Editor1 interface.
   Reads $CMACS_DBUS_NAME.  Caller must g_object_unref(). */
GDBusProxy *cmacs_gi_get_proxy (GError **error);

/* ── Eval helpers ─────────────────────────────────────────────────── */

/* Call Eval over D-Bus, print result to stdout, return exit code. */
gint cmacs_gi_eval_print (GDBusProxy *proxy, const gchar *elisp);

/* Call Eval over D-Bus, suppress stdout, return exit code. */
gint cmacs_gi_eval_quiet (GDBusProxy *proxy, const gchar *elisp);

/* Call Eval over D-Bus, return result as an allocated string.
   Returns NULL on error (prints to stderr).  Caller must g_free(). */
gchar *cmacs_gi_eval_get_string (GDBusProxy *proxy, const gchar *elisp);

/* ── String utilities ─────────────────────────────────────────────── */

/* Escape a C string for embedding in an elisp string literal.
   Handles backslash and double-quote.  Does NOT add outer quotes.
   Caller must g_free(). */
gchar *cmacs_gi_lisp_escape (const gchar *s);

/* Quote a value for the Lisp reader: numbers, quoted strings, and
   s-expressions pass through; bare words become Lisp string literals.
   Caller must g_free(). */
gchar *cmacs_gi_lisp_quote (const gchar *s);

/* ── Group dispatch helper ────────────────────────────────────────── */

/* Look up argv[depth] in TABLE (NULL-terminated) and call its handler.
   On unknown subcommand, prints error + available subcommands. */
gint cmacs_gi_dispatch_group (const gchar        *group_name,
                              const CmacsGiSubcmd *table,
                              GDBusProxy          *proxy,
                              gint                 argc,
                              gchar              **argv,
                              gint                 depth);

/* Print a subcommand table as help text (name + help columns). */
void cmacs_gi_print_group_help (const gchar        *group_name,
                                const CmacsGiSubcmd *table);

#endif /* CMACS_GI_CMD_INTERNAL_H */
