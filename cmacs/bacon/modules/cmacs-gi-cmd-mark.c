/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-mark.c — bookmark subcommands for cmacsgi
 *
 * Subcommands:
 *   mark set NAME        set bookmark at current position
 *   mark list            list all bookmarks
 *   mark jump NAME       jump to bookmark
 *   mark del NAME        delete bookmark
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Handlers ─────────────────────────────────────────────────────── */

static gint
mark_set(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi mark set: missing bookmark name\n");
        return 1;
    }

    escaped = cmacs_gi_lisp_escape(argv[3]);
    elisp = g_strdup_printf("(bookmark-set \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
mark_list(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;

    return cmacs_gi_eval_print(transport,
        "(progn"
        " (require 'bookmark)"
        " (mapconcat"
        "  (lambda (bm)"
        "    (let ((name (car bm))"
        "          (file (cdr (assq 'filename (cdr bm))))"
        "          (pos  (cdr (assq 'position (cdr bm)))))"
        "      (format \"%s\\t%s\\t%s\""
        "        name (or file \"\") (or (and pos (number-to-string pos)) \"\"))))"
        "  bookmark-alist \"\\n\"))");
}

static gint
mark_jump(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi mark jump: missing bookmark name\n");
        return 1;
    }

    escaped = cmacs_gi_lisp_escape(argv[3]);
    elisp = g_strdup_printf("(bookmark-jump \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
mark_del(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi mark del: missing bookmark name\n");
        return 1;
    }

    escaped = cmacs_gi_lisp_escape(argv[3]);
    elisp = g_strdup_printf("(bookmark-delete \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

/* ── Dispatch table ───────────────────────────────────────────────── */

static const CmacsGiSubcmd mark_subcmds[] = {
    { "set",  mark_set,  "mark set NAME",  "set bookmark at point" },
    { "list", mark_list, "mark list",      "list all bookmarks" },
    { "jump", mark_jump, "mark jump NAME", "jump to bookmark" },
    { "del",  mark_del,  "mark del NAME",  "delete bookmark" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_mark(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_gi_dispatch_group("mark", mark_subcmds,
                                   transport, argc, argv, 2);
}
