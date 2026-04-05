/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-file.c — file operation subcommands for cmacsgi
 *
 * Subcommands:
 *   open PATH           open a file in the editor
 *   save [PATH]         save current buffer (optionally to PATH)
 *   close [NAME]        close a buffer
 *   recent [-n N]       list recent files
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

gint
cmd_file_open(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi open: missing path\n");
        return 1;
    }

    escaped = cmacs_gi_lisp_escape(argv[2]);
    elisp = g_strdup_printf("(find-file \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

gint
cmd_file_save(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 3)
        return cmacs_gi_eval_quiet(proxy, "(save-buffer)");

    escaped = cmacs_gi_lisp_escape(argv[2]);
    elisp = g_strdup_printf("(write-file \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

gint
cmd_file_close(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 3)
        return cmacs_gi_eval_quiet(proxy, "(kill-buffer (current-buffer))");

    escaped = cmacs_gi_lisp_escape(argv[2]);
    elisp = g_strdup_printf("(kill-buffer \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

gint
cmd_file_recent(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gint n, i;
    gchar *elisp;
    gint rc;

    n = 20; /* default */
    for (i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)
        {
            n = atoi(argv[i + 1]);
            i++;
        }
    }

    elisp = g_strdup_printf(
        "(progn"
        " (require 'recentf)"
        " (mapconcat #'identity"
        "   (seq-take recentf-list %d) \"\\n\"))",
        n);
    rc = cmacs_gi_eval_print(proxy, elisp);
    g_free(elisp);
    return rc;
}
