/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-vc.c — version control subcommands for cmacsgi
 *
 * Subcommands:
 *   vc status             show version control status
 *   vc diff [FILE]        show diff
 *   vc log [-n N] [FILE]  show log
 *   vc blame [FILE]       show blame annotations
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Handlers ─────────────────────────────────────────────────────── */

static gint
vc_status(GDBusProxy *proxy, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;

    return cmacs_gi_eval_print(proxy,
        "(let ((root (vc-root-dir)))"
        " (if root"
        "   (with-temp-buffer"
        "    (let ((default-directory root))"
        "     (call-process \"git\" nil t nil"
        "       \"status\" \"--porcelain\" \"-b\"))"
        "    (buffer-string))"
        "   \"not in a VC-controlled directory\"))");
}

static gint
vc_diff(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;

    if (argc >= 4)
    {
        escaped = cmacs_gi_lisp_escape(argv[3]);
        elisp = g_strdup_printf(
            "(with-temp-buffer"
            " (call-process \"git\" nil t nil"
            "   \"diff\" \"--no-color\" \"%s\")"
            " (buffer-string))",
            escaped);
        g_free(escaped);
    }
    else
    {
        elisp = g_strdup(
            "(with-temp-buffer"
            " (let ((default-directory"
            "         (or (vc-root-dir) default-directory)))"
            "  (call-process \"git\" nil t nil"
            "    \"diff\" \"--no-color\"))"
            " (buffer-string))");
    }

    rc = cmacs_gi_eval_print(proxy, elisp);
    g_free(elisp);
    return rc;
}

static gint
vc_log(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gint n, i;
    const gchar *file;
    gchar *elisp;
    gint rc;

    n = 20;
    file = NULL;

    for (i = 3; i < argc; i++)
    {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)
        {
            n = atoi(argv[i + 1]);
            i++;
        }
        else if (file == NULL)
            file = argv[i];
    }

    if (file != NULL)
    {
        gchar *esc = cmacs_gi_lisp_escape(file);
        elisp = g_strdup_printf(
            "(with-temp-buffer"
            " (call-process \"git\" nil t nil"
            "   \"log\" \"--oneline\" \"-n\" \"%d\" \"--\" \"%s\")"
            " (buffer-string))",
            n, esc);
        g_free(esc);
    }
    else
    {
        elisp = g_strdup_printf(
            "(with-temp-buffer"
            " (let ((default-directory"
            "         (or (vc-root-dir) default-directory)))"
            "  (call-process \"git\" nil t nil"
            "    \"log\" \"--oneline\" \"-n\" \"%d\"))"
            " (buffer-string))",
            n);
    }

    rc = cmacs_gi_eval_print(proxy, elisp);
    g_free(elisp);
    return rc;
}

static gint
vc_blame(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *escaped, *elisp;
    gint rc;
    const gchar *file;

    if (argc >= 4)
        file = argv[3];
    else
    {
        /* Use current buffer's file. */
        file = NULL;
    }

    if (file != NULL)
    {
        escaped = cmacs_gi_lisp_escape(file);
        elisp = g_strdup_printf(
            "(with-temp-buffer"
            " (call-process \"git\" nil t nil"
            "   \"blame\" \"--no-color\" \"%s\")"
            " (buffer-string))",
            escaped);
        g_free(escaped);
    }
    else
    {
        elisp = g_strdup(
            "(let ((f (buffer-file-name)))"
            " (if f"
            "   (with-temp-buffer"
            "    (call-process \"git\" nil t nil"
            "      \"blame\" \"--no-color\" f)"
            "    (buffer-string))"
            "   \"no file associated with current buffer\"))");
    }

    rc = cmacs_gi_eval_print(proxy, elisp);
    g_free(elisp);
    return rc;
}

/* ── Dispatch table ───────────────────────────────────────────────── */

static const CmacsGiSubcmd vc_subcmds[] = {
    { "status", vc_status, "vc status",              "show VC status" },
    { "diff",   vc_diff,   "vc diff [FILE]",         "show diff" },
    { "log",    vc_log,    "vc log [-n N] [FILE]",   "show log" },
    { "blame",  vc_blame,  "vc blame [FILE]",        "show blame annotations" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_vc(GDBusProxy *proxy, gint argc, gchar **argv)
{
    return cmacs_gi_dispatch_group("vc", vc_subcmds,
                                   proxy, argc, argv, 2);
}
