/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-nav.c — cursor/navigation subcommands for cmacsgi
 *
 * Subcommands:
 *   point [-b BUF]           print cursor position as line:col
 *   goto [-b BUF] LINE[:COL] go to line and optional column
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

/* ── Subcommand handlers ────────────────────────────────────���─────── */

gint
cmd_point(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i;
    gchar *elisp;
    gint rc;

    i = 2;
    parse_buf_flag(argc, argv, &i, &buf);

    elisp = wrap_with_buffer(buf,
        "(format \"%d:%d\""
        " (line-number-at-pos)"
        " (current-column))");

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_goto(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i;
    gint line, col;
    gchar *pos_str, *colon;
    gchar *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_flag(argc, argv, &i, &buf);

    if (i >= argc)
    {
        fprintf(stderr, "cmacsgi goto: missing LINE[:COL]\n");
        return 1;
    }

    /* Parse LINE[:COL] */
    pos_str = argv[i];
    colon = strchr(pos_str, ':');
    if (colon != NULL)
    {
        *colon = '\0';
        line = atoi(pos_str);
        col  = atoi(colon + 1);
        *colon = ':'; /* restore */
    }
    else
    {
        line = atoi(pos_str);
        col  = 0;
    }

    if (col > 0)
        body = g_strdup_printf(
            "(goto-char (point-min))"
            "(forward-line %d)"
            "(forward-char %d)"
            "(format \"%%d:%%d\""
            " (line-number-at-pos) (current-column))",
            line - 1, col);
    else
        body = g_strdup_printf(
            "(goto-char (point-min))"
            "(forward-line %d)"
            "(format \"%%d:%%d\""
            " (line-number-at-pos) (current-column))",
            line - 1);

    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}
