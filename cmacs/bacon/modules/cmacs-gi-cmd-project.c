/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-project.c — project/build subcommands for cmacsgi
 *
 * Subcommands:
 *   grep PATTERN [DIR]      recursive grep
 *   find FILENAME [DIR]     find file by name
 *   project-root            print project root
 *   compile CMD             run compilation command
 *   next-error              jump to next compilation error
 *   prev-error              jump to previous compilation error
 *   diag [-b BUF]           list diagnostics
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

gint
cmd_grep(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_pat, *esc_dir, *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi grep: missing pattern\n");
        return 1;
    }

    esc_pat = cmacs_gi_lisp_escape(argv[2]);

    if (argc >= 4)
    {
        esc_dir = cmacs_gi_lisp_escape(argv[3]);
        elisp = g_strdup_printf(
            "(let ((default-directory \"%s\"))"
            " (grep-find"
            "  (format \"grep -rn --color=never %%s .\" \"%s\")))",
            esc_dir, esc_pat);
        g_free(esc_dir);
    }
    else
    {
        elisp = g_strdup_printf(
            "(grep-find"
            " (format \"grep -rn --color=never %%s .\" \"%s\"))",
            esc_pat);
    }

    g_free(esc_pat);
    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_find(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    gchar *esc_name, *esc_dir, *elisp;
    gint rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi find: missing filename\n");
        return 1;
    }

    esc_name = cmacs_gi_lisp_escape(argv[2]);

    if (argc >= 4)
    {
        esc_dir = cmacs_gi_lisp_escape(argv[3]);
        elisp = g_strdup_printf(
            "(let ((default-directory \"%s\"))"
            " (let ((f (locate-file \"%s\" (list default-directory))))"
            "  (or f"
            "   (car (file-expand-wildcards"
            "     (format \"**/%s\" \"%s\") t)))))",
            esc_dir, esc_name, "%s", esc_name);
        g_free(esc_dir);
    }
    else
    {
        elisp = g_strdup_printf(
            "(or (locate-file \"%s\" (list default-directory))"
            " (car (file-expand-wildcards"
            "   (format \"**/%s\" \"%s\") t)))",
            esc_name, "%s", esc_name);
    }

    g_free(esc_name);
    rc = cmacs_gi_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_project_root(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_print(transport,
        "(let ((pr (project-current)))"
        " (if pr (project-root pr) \"\"))");
}

gint
cmd_compile(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    GString *cmd;
    gchar *escaped, *elisp;
    gint i, rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi compile: missing command\n");
        return 1;
    }

    cmd = g_string_new(argv[2]);
    for (i = 3; i < argc; i++)
    {
        g_string_append_c(cmd, ' ');
        g_string_append(cmd, argv[i]);
    }

    escaped = cmacs_gi_lisp_escape(cmd->str);
    g_string_free(cmd, TRUE);

    elisp = g_strdup_printf("(compile \"%s\")", escaped);
    g_free(escaped);

    rc = cmacs_gi_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

gint
cmd_next_error(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(next-error)");
}

gint
cmd_prev_error(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(transport, "(previous-error)");
}

gint
cmd_diag(CmacsGiTransport *transport, gint argc, gchar **argv)
{
    const gchar *buf;
    gint i;
    gchar *esc, *elisp;
    gint rc;

    buf = NULL;
    for (i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
        {
            buf = argv[i + 1];
            i++;
        }
    }

    /* Try flymake first, then flycheck. */
    if (buf != NULL)
    {
        esc = cmacs_gi_lisp_escape(buf);
        elisp = g_strdup_printf(
            "(with-current-buffer \"%s\""
            " (if (bound-and-true-p flymake-mode)"
            "   (mapconcat"
            "    (lambda (d)"
            "      (format \"%%s:%%d: %%s: %%s\""
            "        (or (buffer-file-name) (buffer-name))"
            "        (line-number-at-pos (flymake-diagnostic-beg d))"
            "        (pcase (flymake-diagnostic-type d)"
            "          (:error \"error\") (:warning \"warning\")"
            "          (_ \"note\"))"
            "        (flymake-diagnostic-text d)))"
            "    (flymake-diagnostics) \"\\n\")"
            "   \"no diagnostics backend active\"))",
            esc);
        g_free(esc);
    }
    else
    {
        elisp = g_strdup(
            "(if (bound-and-true-p flymake-mode)"
            " (mapconcat"
            "  (lambda (d)"
            "    (format \"%s:%d: %s: %s\""
            "      (or (buffer-file-name) (buffer-name))"
            "      (line-number-at-pos (flymake-diagnostic-beg d))"
            "      (pcase (flymake-diagnostic-type d)"
            "        (:error \"error\") (:warning \"warning\")"
            "        (_ \"note\"))"
            "      (flymake-diagnostic-text d)))"
            "  (flymake-diagnostics) \"\\n\")"
            " \"no diagnostics backend active\")");
    }

    rc = cmacs_gi_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}
