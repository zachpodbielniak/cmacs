/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-buf.c — buffer management subcommands for cmacsgi
 *
 * Subcommands:
 *   buf list [-l]           list open buffers
 *   buf show [NAME]         print buffer content
 *   buf create NAME         create an empty buffer
 *   buf kill NAME           kill a buffer
 *   buf save [NAME]         save buffer to file
 *   buf save-as NAME PATH   save buffer to new file
 *   buf current             print current buffer name
 *   buf switch NAME         switch to buffer
 *   buf info [NAME]         show buffer metadata
 *   buf rename OLD NEW      rename buffer
 */

#include "cmacs-api.h"

/* ── Handlers ───���────────────────────────────���────────────────────── */

static gint
buf_list(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gboolean long_fmt;
    gint i;
    const gchar *elisp;

    long_fmt = FALSE;
    for (i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "-l") == 0)
            long_fmt = TRUE;
        else if (strcmp(argv[i], "list") == 0)
            continue; /* skip the subcommand name itself */
        else
            break;
    }

    if (long_fmt)
        elisp = "(mapconcat"
                " (lambda (b)"
                "   (format \"%s\\t%s\\t%s\\t%d\\t%s\""
                "     (buffer-name b)"
                "     (or (buffer-file-name b) \"\")"
                "     (if (buffer-modified-p b) \"*\" \"\")"
                "     (buffer-size b)"
                "     (with-current-buffer b (symbol-name major-mode))))"
                " (buffer-list) \"\\n\")";
    else
        elisp = "(mapconcat #'buffer-name (buffer-list) \"\\n\")";

    return cmacs_api_eval_print(transport, elisp);
}

static gint
buf_show(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    /* buf show [NAME] — if no NAME, use current buffer */
    if (argc < 4 || strcmp(argv[3], "") == 0)
        return cmacs_api_eval_print(transport, "(buffer-string)");

    escaped = cmacs_api_lisp_escape(argv[3]);
    elisp = g_strdup_printf(
        "(with-current-buffer \"%s\" (buffer-string))", escaped);
    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
buf_create(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi buf create: missing buffer name\n");
        return 1;
    }

    escaped = cmacs_api_lisp_escape(argv[3]);
    elisp = g_strdup_printf(
        "(buffer-name (get-buffer-create \"%s\"))", escaped);
    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
buf_kill(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi buf kill: missing buffer name\n");
        return 1;
    }

    escaped = cmacs_api_lisp_escape(argv[3]);
    elisp = g_strdup_printf("(kill-buffer \"%s\")", escaped);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
buf_save(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
        return cmacs_api_eval_quiet(transport, "(save-buffer)");

    escaped = cmacs_api_lisp_escape(argv[3]);
    elisp = g_strdup_printf(
        "(with-current-buffer \"%s\" (save-buffer))", escaped);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
buf_save_as(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_buf, *esc_path, *elisp;
    gint rc;

    if (argc < 5)
    {
        fprintf(stderr,
                "cmacsgi buf save-as: usage: buf save-as NAME PATH\n");
        return 1;
    }

    esc_buf  = cmacs_api_lisp_escape(argv[3]);
    esc_path = cmacs_api_lisp_escape(argv[4]);
    elisp = g_strdup_printf(
        "(with-current-buffer \"%s\" (write-file \"%s\"))",
        esc_buf, esc_path);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(esc_path);
    g_free(esc_buf);
    return rc;
}

static gint
buf_current(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport, "(buffer-name)");
}

static gint
buf_switch(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi buf switch: missing buffer name\n");
        return 1;
    }

    escaped = cmacs_api_lisp_escape(argv[3]);
    elisp = g_strdup_printf("(switch-to-buffer \"%s\")", escaped);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    return rc;
}

static gint
buf_info(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;
    const gchar *tmpl;

    tmpl = "(let ((b (get-buffer %s)))"
           " (if b"
           "   (with-current-buffer b"
           "     (format \"name=%%s\\nfile=%%s\\nmodified=%%s\\nsize=%%d"
           "\\nmode=%%s\\nreadonly=%%s\\nlines=%%d\""
           "       (buffer-name)"
           "       (or (buffer-file-name) \"\")"
           "       (if (buffer-modified-p) \"yes\" \"no\")"
           "       (buffer-size)"
           "       (symbol-name major-mode)"
           "       (if buffer-read-only \"yes\" \"no\")"
           "       (count-lines (point-min) (point-max))))"
           "   \"error=buffer not found\"))";

    if (argc < 4)
    {
        elisp = g_strdup_printf(tmpl, "(current-buffer)");
    }
    else
    {
        escaped = cmacs_api_lisp_escape(argv[3]);
        {
            gchar *bufarg = g_strdup_printf("\"%s\"", escaped);
            elisp = g_strdup_printf(tmpl, bufarg);
            g_free(bufarg);
        }
        g_free(escaped);
    }

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
buf_rename(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_old, *esc_new, *elisp;
    gint rc;

    if (argc < 5)
    {
        fprintf(stderr,
                "cmacsgi buf rename: usage: buf rename OLD NEW\n");
        return 1;
    }

    esc_old = cmacs_api_lisp_escape(argv[3]);
    esc_new = cmacs_api_lisp_escape(argv[4]);
    elisp = g_strdup_printf(
        "(with-current-buffer \"%s\" (rename-buffer \"%s\"))",
        esc_old, esc_new);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(esc_new);
    g_free(esc_old);
    return rc;
}

/* ── Dispatch table ────────────��──────────────────────────────────── */

static const CmacsApiSubcmd buf_subcmds[] = {
    { "list",    buf_list,    "buf list [-l]",         "list open buffers" },
    { "show",    buf_show,    "buf show [NAME]",       "print buffer content" },
    { "create",  buf_create,  "buf create NAME",       "create an empty buffer" },
    { "kill",    buf_kill,    "buf kill NAME",         "kill a buffer" },
    { "save",    buf_save,    "buf save [NAME]",       "save buffer to file" },
    { "save-as", buf_save_as, "buf save-as NAME PATH", "save to new file" },
    { "current", buf_current, "buf current",           "print current buffer name" },
    { "switch",  buf_switch,  "buf switch NAME",       "switch to buffer" },
    { "info",    buf_info,    "buf info [NAME]",       "show buffer metadata" },
    { "rename",  buf_rename,  "buf rename OLD NEW",    "rename a buffer" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_buf(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_api_dispatch_group("buf", buf_subcmds,
                                   transport, argc, argv, 2);
}
