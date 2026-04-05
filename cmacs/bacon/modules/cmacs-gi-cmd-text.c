/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-text.c — text editing subcommands for cmacsgi
 *
 * Subcommands:
 *   insert [-b BUF] [-p POS] TEXT   insert text at point or position
 *   delete [-b BUF] START END       delete region, print deleted text
 *   line [-b BUF] [N]               get Nth line (default: current)
 *   append [-b BUF] TEXT            append text to end of buffer
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Flag parsing helper ───────��──────────────────────────────────── */

/* Parse optional -b BUF and -p POS from argv starting at *idx.
   Advances *idx past consumed flags.  buf and pos are set to NULL/0
   if not found. */
static void
parse_buf_pos_flags(gint argc, gchar **argv, gint *idx,
                    const gchar **buf, gint *pos)
{
    gint i;

    *buf = NULL;
    *pos = 0;

    i = *idx;
    while (i < argc)
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            *buf = argv[i + 1];
            i += 2;
        }
        else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc)
        {
            *pos = atoi(argv[i + 1]);
            i += 2;
        }
        else
            break;
    }
    *idx = i;
}

/* Build a (with-current-buffer ...) wrapper if buf is non-NULL. */
static gchar *
wrap_with_buffer(const gchar *buf, const gchar *body)
{
    gchar *esc, *result;

    if (buf == NULL)
        return g_strdup_printf("(progn %s)", body);

    esc = cmacs_gi_lisp_escape(buf);
    result = g_strdup_printf(
        "(with-current-buffer \"%s\" %s)", esc, body);
    g_free(esc);
    return result;
}

/* ── Subcommand handlers ────────���─────────────────────────────��───── */

gint
cmd_insert(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint pos, i;
    GString *text;
    gchar *escaped, *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_pos_flags(argc, argv, &i, &buf, &pos);

    if (i >= argc)
    {
        fprintf(stderr, "cmacsgi insert: missing text\n");
        return 1;
    }

    /* Join remaining args as text. */
    text = g_string_new(argv[i]);
    for (i = i + 1; i < argc; i++)
    {
        g_string_append_c(text, ' ');
        g_string_append(text, argv[i]);
    }

    escaped = cmacs_gi_lisp_escape(text->str);
    g_string_free(text, TRUE);

    if (pos > 0)
        body = g_strdup_printf(
            "(goto-char %d)(insert \"%s\")", pos, escaped);
    else
        body = g_strdup_printf("(insert \"%s\")", escaped);
    g_free(escaped);

    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_delete(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint dummy_pos, i;
    gint start, end;
    gchar *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_pos_flags(argc, argv, &i, &buf, &dummy_pos);

    if (i + 1 >= argc)
    {
        fprintf(stderr, "cmacsgi delete: usage: delete [-b BUF] START END\n");
        return 1;
    }

    start = atoi(argv[i]);
    end   = atoi(argv[i + 1]);

    body = g_strdup_printf(
        "(delete-and-extract-region %d %d)", start, end);
    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_gi_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_line(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint dummy_pos, i;
    gint line_num;
    gchar *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_pos_flags(argc, argv, &i, &buf, &dummy_pos);

    if (i < argc)
        line_num = atoi(argv[i]);
    else
        line_num = 0; /* 0 = current line */

    if (line_num > 0)
        body = g_strdup_printf(
            "(save-excursion"
            " (goto-char (point-min))"
            " (forward-line %d)"
            " (buffer-substring"
            "   (line-beginning-position)"
            "   (line-end-position)))",
            line_num - 1);
    else
        body = g_strdup(
            "(buffer-substring"
            " (line-beginning-position)"
            " (line-end-position))");

    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_gi_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_append(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint dummy_pos, i;
    GString *text;
    gchar *escaped, *body, *elisp;
    gint rc;

    i = 2;
    parse_buf_pos_flags(argc, argv, &i, &buf, &dummy_pos);

    if (i >= argc)
    {
        fprintf(stderr, "cmacsgi append: missing text\n");
        return 1;
    }

    text = g_string_new(argv[i]);
    for (i = i + 1; i < argc; i++)
    {
        g_string_append_c(text, ' ');
        g_string_append(text, argv[i]);
    }

    escaped = cmacs_gi_lisp_escape(text->str);
    g_string_free(text, TRUE);

    body = g_strdup_printf(
        "(goto-char (point-max))(insert \"%s\")", escaped);
    g_free(escaped);

    elisp = wrap_with_buffer(buf, body);
    g_free(body);

    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}
