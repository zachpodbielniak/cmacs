/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-cmd-pkg.c — package management subcommands for cmacsgi
 *
 * Subcommands:
 *   pkg install NAME      install a package
 *   pkg remove NAME       remove a package
 *   pkg list [-a]         list packages (-a for available)
 *   pkg refresh           refresh package archives
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-cmd-internal.h"

/* ── Handlers ─────────────────────────────────────────────────────── */

static gint
pkg_install(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi pkg install: missing package name\n");
        return 1;
    }

    elisp = g_strdup_printf(
        "(progn (require 'package)"
        " (unless package-archive-contents (package-refresh-contents))"
        " (package-install '%s))", argv[3]);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    return rc;
}

static gint
pkg_remove(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gchar *elisp;
    gint rc;

    if (argc < 4)
    {
        fprintf(stderr, "cmacsgi pkg remove: missing package name\n");
        return 1;
    }

    elisp = g_strdup_printf(
        "(progn (require 'package)"
        " (let ((desc (cadr (assq '%s package-alist))))"
        "  (if desc (package-delete desc) (error \"package not found\"))))",
        argv[3]);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    return rc;
}

static gint
pkg_list(GDBusProxy *proxy, gint argc, gchar **argv)
{
    gboolean available;
    gint i;
    gchar *elisp;
    gint rc;

    available = FALSE;
    for (i = 3; i < argc; i++)
    {
        if (strcmp(argv[i], "-a") == 0)
            available = TRUE;
    }

    if (available)
        elisp = g_strdup(
            "(progn (require 'package)"
            " (unless package-archive-contents (package-refresh-contents))"
            " (mapconcat"
            "  (lambda (p)"
            "    (let ((desc (cadr p)))"
            "      (format \"%s\\t%s\\t%s\""
            "        (package-desc-name desc)"
            "        (package-version-join (package-desc-version desc))"
            "        (or (package-desc-summary desc) \"\"))))"
            "  package-archive-contents \"\\n\"))");
    else
        elisp = g_strdup(
            "(progn (require 'package)"
            " (mapconcat"
            "  (lambda (p)"
            "    (let ((desc (cadr p)))"
            "      (format \"%s\\t%s\\t%s\""
            "        (package-desc-name desc)"
            "        (package-version-join (package-desc-version desc))"
            "        (or (package-desc-summary desc) \"\"))))"
            "  package-alist \"\\n\"))");

    rc = cmacs_gi_eval_print(proxy, elisp);
    g_free(elisp);
    return rc;
}

static gint
pkg_refresh(GDBusProxy *proxy, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_gi_eval_quiet(proxy,
        "(progn (require 'package) (package-refresh-contents))");
}

/* ── Dispatch table ───────────────────────────────────────────────── */

static const CmacsGiSubcmd pkg_subcmds[] = {
    { "install", pkg_install, "pkg install NAME",  "install a package" },
    { "remove",  pkg_remove,  "pkg remove NAME",   "remove a package" },
    { "list",    pkg_list,    "pkg list [-a]",     "list packages (-a available)" },
    { "refresh", pkg_refresh, "pkg refresh",       "refresh package archives" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_pkg(GDBusProxy *proxy, gint argc, gchar **argv)
{
    return cmacs_gi_dispatch_group("pkg", pkg_subcmds,
                                   proxy, argc, argv, 2);
}
