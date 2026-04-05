/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-win.c — window management subcommands for cmacsgi
 *
 * Subcommands:
 *   win list              list windows and their buffers
 *   win split [-v]        split window (horizontal, -v vertical)
 *   win close             close current window
 *   win only              close all other windows
 *   win next              cycle to next window
 *   win balance           balance window sizes
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Handlers ─────────────────────────────────────────────────────── */

static gint
win_list(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;

    return cmacs_gi_eval_print(transport,
        "(mapconcat"
        " (lambda (w)"
        "   (format \"%s\\t%d\\t%d\""
        "     (buffer-name (window-buffer w))"
        "     (window-total-width w)"
        "     (window-total-height w)))"
        " (window-list) \"\\n\")");
}

static gint
win_split(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gboolean vertical;
    gint i;

    vertical = FALSE;
    for (i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "-v") == 0)
            vertical = TRUE;
        else if (strcmp(argv[i], "split") == 0)
            continue;
    }

    if (vertical)
        return cmacs_gi_eval_quiet(transport,
            "(split-window nil nil 'right)");
    else
        return cmacs_gi_eval_quiet(transport,
            "(split-window nil nil 'below)");
}

static gint
win_close(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(delete-window)");
}

static gint
win_only(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(delete-other-windows)");
}

static gint
win_next(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(other-window 1)");
}

static gint
win_balance(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(balance-windows)");
}

/* ── Dispatch table ───────────────────────────────────────────────── */

static const CmacsGiSubcmd win_subcmds[] = {
    { "list",    win_list,    "win list",       "list windows and their buffers" },
    { "split",   win_split,   "win split [-v]", "split window (-v for vertical)" },
    { "close",   win_close,   "win close",      "close current window" },
    { "only",    win_only,    "win only",       "close all other windows" },
    { "next",    win_next,    "win next",       "cycle to next window" },
    { "balance", win_balance, "win balance",    "balance window sizes" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_win(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_gi_dispatch_group("win", win_subcmds,
                                   transport, argc, argv, 2);
}
