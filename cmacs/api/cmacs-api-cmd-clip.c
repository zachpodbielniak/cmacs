/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-clip.c — clipboard/kill-ring subcommands for cmacsgi
 *
 * Subcommands:
 *   copy [-b BUF] START END   copy region to kill ring
 *   cut [-b BUF] START END    cut region (delete + copy)
 *   paste [-b BUF]            paste from kill ring
 *   clip list [-n N]          list kill ring entries
 */

#include "cmacs-api.h"

/* ── Helpers ──────────────────────────────────────────────────────── */

static gchar *
wrap_with_buffer(const gchar *buf, const gchar *body)
{
    gchar *esc, *result;

    if (buf == NULL)
        return g_strdup_printf("(progn %s)", body);

    esc = cmacs_api_lisp_escape(buf);
    result = g_strdup_printf(
        "(with-current-buffer \"%s\" %s)", esc, body);
    g_free(esc);
    return result;
}

static void
parse_buf_flag(gint argc, gchar **argv, gint *idx, const gchar **buf)
{
    gint i;

    *buf = NULL;
    i = *idx;
    while (i < argc)
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            *buf = argv[i + 1];
            i += 2;
        }
        else
            break;
    }
    *idx = i;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

gint
cmd_copy(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i, start, end;
    gchar *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_flag(argc, argv, &i, &buf);

    if (i + 1 >= argc)
    {
        fprintf(stderr, "cmacsgi copy: usage: copy [-b BUF] START END\n");
        return 1;
    }

    start = atoi(argv[i]);
    end   = atoi(argv[i + 1]);

    body = g_strdup_printf("(copy-region-as-kill %d %d)", start, end);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_cut(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i, start, end;
    gchar *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_flag(argc, argv, &i, &buf);

    if (i + 1 >= argc)
    {
        fprintf(stderr, "cmacsgi cut: usage: cut [-b BUF] START END\n");
        return 1;
    }

    start = atoi(argv[i]);
    end   = atoi(argv[i + 1]);

    body = g_strdup_printf("(kill-region %d %d)", start, end);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_paste(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i;
    gchar *elisp;
    gint rc;

    i = 2;
    parse_buf_flag(argc, argv, &i, &buf);

    elisp = wrap_with_buffer(buf, "(yank)");
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

/* ── clip subgroup ────────────────────────────────────────────────── */

static gint
clip_list(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gint n, i;
    gchar *elisp;
    gint rc;

    n = 10; /* default */
    for (i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)
        {
            n = atoi(argv[i + 1]);
            i++;
        }
        else if (strcmp(argv[i], "list") == 0)
            continue;
    }

    elisp = g_strdup_printf(
        "(mapconcat #'identity (seq-take kill-ring %d) \"\\n\")", n);
    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

static const CmacsApiSubcmd clip_subcmds[] = {
    { "list", clip_list, "clip list [-n N]", "list kill ring entries" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_clip(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_api_dispatch_group("clip", clip_subcmds,
                                   transport, argc, argv, 2);
}
