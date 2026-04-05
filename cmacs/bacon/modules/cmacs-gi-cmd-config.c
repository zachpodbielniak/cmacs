/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-config.c — configuration subcommands for cmacsgi
 *
 * Subcommands:
 *   set VAR VALUE       set an Emacs variable
 *   get VAR             get an Emacs variable value
 *   theme NAME          load a color theme
 *   font FAMILY [SIZE]  set the default font
 *   mode NAME           set major mode
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Helpers ───────────────────────────────────────────────────────── */

static gboolean
looks_like_number_or_keyword(const gchar *s)
{
    const gchar *p;

    if (strcmp(s, "t") == 0 || strcmp(s, "nil") == 0)
        return TRUE;

    p = s;
    if (*p == '-' || *p == '+')
        p++;
    if (*p == '\0')
        return FALSE;
    while (*p != '\0')
    {
        if (!g_ascii_isdigit(*p) && *p != '.' && *p != 'e' && *p != 'E')
            return FALSE;
        p++;
    }
    return TRUE;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

gint
cmd_set(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_val, *elisp;
    gint rc;
    const gchar *var, *val;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi set: usage: set VAR VALUE\n");
        return 1;
    }

    var = argv[2];
    val = argv[3];

    /* Smart value quoting: numbers and t/nil pass through as-is,
       everything else becomes a string. */
    if (looks_like_number_or_keyword(val))
        elisp = g_strdup_printf("(setq %s %s)", var, val);
    else
    {
        esc_val = cmacs_gi_lisp_escape(val);
        elisp = g_strdup_printf("(setq %s \"%s\")", var, esc_val);
        g_free(esc_val);
    }

    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_get_var(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi get: missing variable name\n");
        return 1;
    }

    elisp = g_strdup_printf("(symbol-value '%s)", argv[2]);
    rc = cmacs_gi_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_theme(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi theme: missing theme name\n");
        return 1;
    }

    elisp = g_strdup_printf("(load-theme '%s t)", argv[2]);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_font(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_fam, *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi font: missing font family\n");
        return 1;
    }

    esc_fam = cmacs_gi_lisp_escape(argv[2]);

    if (argc >= 4)
    {
        gint size = atoi(argv[3]);
        /* Convert point size to height in 1/10pt units. */
        if (size < 100)
            size *= 10;
        elisp = g_strdup_printf(
            "(set-face-attribute 'default nil :family \"%s\" :height %d)",
            esc_fam, size);
    }
    else
    {
        elisp = g_strdup_printf(
            "(set-face-attribute 'default nil :family \"%s\")", esc_fam);
    }

    g_free(esc_fam);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_mode(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi mode: missing mode name\n");
        return 1;
    }

    /* Try <name>-mode first; if it ends with -mode already, use as-is. */
    if (g_str_has_suffix(argv[2], "-mode"))
        elisp = g_strdup_printf("(funcall (intern \"%s\"))", argv[2]);
    else
        elisp = g_strdup_printf("(funcall (intern \"%s-mode\"))", argv[2]);

    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}
