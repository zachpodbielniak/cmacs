/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-command.c --- cmacsgi bacon builtin (thin wrapper)
 *
 * BaconCommand GObject subclass that provides the `cmacsgi` shell
 * builtin.  The actual command implementations, transport layer,
 * and helper functions now live in the shared cmacs-api library
 * (cmacs/api/).  This file only contains the BaconCommand dispatch
 * and GObject boilerplate.
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-gi-command.h"
#include "cmacs-gi-cmd-internal.h"
#include <bacon-types.h>

struct _CmacsGiCommand
{
    BaconCommand parent_instance;
};

G_DEFINE_FINAL_TYPE(CmacsGiCommand, cmacs_gi_command, BACON_TYPE_COMMAND)

/* ── Original subcommand handlers ─────────────────────────────────── */

/* These six handlers were defined here before the extraction and use
   the transport layer + eval helpers from the API library via the
   compat macros in cmacs-gi-cmd-internal.h. */

static gint
cmd_eval(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GString  *expr;
    gint      i;
    gint      rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi eval: missing expression\n");
        return 1;
    }

    expr = g_string_new(argv[2]);
    for (i = 3; i < argc; i++)
    {
        g_string_append_c(expr, ' ');
        g_string_append(expr, argv[i]);
    }

    rc = cmacs_api_eval_print(transport, expr->str);
    g_string_free(expr, TRUE);
    return rc;
}

/* gowl SUBCMD --- compositor session control + animated screensaver
   wallpaper.  Evaluates the corresponding Elisp in the running cmacs.
   NB: lock/unlock live here (and in D-Bus / emacsctl) but deliberately NOT
   in the MCP surface. */
static gint
cmd_gowl(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *sub = (argc >= 3) ? argv[2] : "";
    g_autofree gchar *expr = NULL;

    if (g_strcmp0(sub, "lock") == 0)
        expr = g_strdup("(gowl-lock)");
    else if (g_strcmp0(sub, "unlock") == 0)
        expr = g_strdup("(gowl-unlock)");
    else if (g_strcmp0(sub, "screensaver") == 0)
    {
        if (argc >= 4)
            expr = g_strdup_printf(
                "(progn (require 'cmacs-screensaver)"
                " (cmacs-screensaver-set-wallpaper '%s))", argv[3]);
        else
            expr = g_strdup(
                "(progn (require 'cmacs-screensaver)"
                " (cmacs-screensaver-set-wallpaper"
                " (or cmacs-screensaver-wallpaper-config"
                " cmacs-screensaver-default-config)))");
    }
    else if (g_strcmp0(sub, "screensaver-stop") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (cmacs-screensaver-stop-wallpaper))");
    else if (g_strcmp0(sub, "screensaver-configs") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (mapconcat (lambda (e) (symbol-name (car e)))"
                        " cmacs-screensaver-configs \"\\n\"))");
    else if (g_strcmp0(sub, "screensaver-status") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (prin1-to-string (cmacs-screensaver-status)))");
    else if (g_strcmp0(sub, "screensaver-restart") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (cmacs-screensaver-restart))");
    else if (g_strcmp0(sub, "screensaver-pause") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (cmacs-screensaver-pause))");
    else if (g_strcmp0(sub, "screensaver-resume") == 0)
        expr = g_strdup("(progn (require 'cmacs-screensaver)"
                        " (cmacs-screensaver-resume))");
    else if (g_strcmp0(sub, "screensaver-fps") == 0 && argc >= 4)
        expr = g_strdup_printf("(progn (require 'cmacs-screensaver)"
                               " (cmacs-screensaver-set-fps %s))", argv[3]);
    else
    {
        fprintf(stderr,
                "cmacsgi gowl: unknown subcommand '%s'\n"
                "  usage: gowl {lock | unlock | screensaver [CONFIG] |"
                " screensaver-stop | screensaver-configs |"
                " screensaver-status | screensaver-restart |"
                " screensaver-pause | screensaver-resume |"
                " screensaver-fps N}\n", sub);
        return 1;
    }

    return cmacs_api_eval_print(transport, expr);
}

static gint
cmd_find_file(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GError   *err = NULL;
    GVariant *result;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi find-file: missing path\n");
        return 1;
    }

    result = cmacs_api_transport_call(
        transport, "FindFile",
        g_variant_new("(s)", argv[2]), &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi find-file: %s\n", err->message);
        g_error_free(err);
        return 1;
    }
    if (result != NULL)
        g_variant_unref(result);
    return 0;
}

static gint
cmd_message(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GString  *text;
    gint      i;
    gchar    *escaped;
    gchar    *elisp;
    gint      rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi message: missing text\n");
        return 1;
    }

    text = g_string_new(argv[2]);
    for (i = 3; i < argc; i++)
    {
        g_string_append_c(text, ' ');
        g_string_append(text, argv[i]);
    }

    escaped = cmacs_api_lisp_escape(text->str);
    elisp = g_strdup_printf("(message \"%%s\" \"%s\")", escaped);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    g_free(escaped);
    g_string_free(text, TRUE);
    return rc;
}

static gint
cmd_require(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GError     *err = NULL;
    GVariant   *result;
    const gchar *ns, *ver;
    gboolean    success;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi require: missing namespace\n");
        return 1;
    }

    ns  = argv[2];
    ver = (argc >= 4) ? argv[3] : "";

    result = cmacs_api_transport_call(
        transport, "GiRequire",
        g_variant_new("(ss)", ns, ver), &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi require: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    g_variant_get(result, "(b)", &success);
    g_variant_unref(result);

    if (!success)
    {
        fprintf(stderr, "cmacsgi require: failed to load %s %s\n", ns, ver);
        return 1;
    }
    return 0;
}

static gint
cmd_call(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GError         *err = NULL;
    GVariant       *result;
    GVariantBuilder builder;
    gint            i;

    if (argc < 4)
    {
        fprintf(stderr,
                "cmacsgi call: usage: cmacsgi call NAMESPACE FUNCTION [ARGS...]\n");
        return 1;
    }

    g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
    for (i = 4; i < argc; i++)
    {
        gchar *quoted = cmacs_api_lisp_quote(argv[i]);
        g_variant_builder_add(&builder, "s", quoted);
        g_free(quoted);
    }

    result = cmacs_api_transport_call(
        transport, "GiCall",
        g_variant_new("(ssas)", argv[2], argv[3], &builder), &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi call: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    {
        const gchar *val;
        g_variant_get(result, "(&s)", &val);
        printf("%s\n", val);
        g_variant_unref(result);
    }
    return 0;
}

static gint
cmd_list(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GError       *err = NULL;
    GVariant     *result;
    GVariantIter *iter;
    const gchar  *func;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi list: missing namespace\n");
        return 1;
    }

    result = cmacs_api_transport_call(
        transport, "GiListFunctions",
        g_variant_new("(s)", argv[2]), &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi list: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    g_variant_get(result, "(as)", &iter);
    while (g_variant_iter_next(iter, "&s", &func))
        printf("%s\n", func);
    g_variant_iter_free(iter);
    g_variant_unref(result);
    return 0;
}

/* ── Forward declarations for group handlers (in libcmacs-api) ────── */

extern gint cmd_buf     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_file_open   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_file_save   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_file_close  (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_file_recent (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_insert  (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_delete  (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_line    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_append  (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_point   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_goto    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_search  (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_replace (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_occur   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_win     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_set     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_get_var (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_theme   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_font    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_mode    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_grep    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_find    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_project_root (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_compile (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_next_error (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_prev_error (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_diag    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_mark    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_copy    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_cut     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_paste   (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_clip    (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_vc      (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_pkg     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_monitor (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_rg      (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_bar     (CmacsApiTransport *transport, gint argc, gchar **argv);
extern gint cmd_c       (CmacsApiTransport *transport, gint argc, gchar **argv);

/* ── Top-level dispatch table ─────────────────────────────────────── */

static const CmacsApiSubcmd subcmds[] = {
    /* ── buffer / file ─────────────────────────────────────────────── */
    { "buf",          cmd_buf,
      "buf SUBCMD [ARGS...]",       "buffer operations (list, show, create, kill, ...)" },
    { "open",         cmd_file_open,
      "open PATH",                  "open a file in the editor" },
    { "save",         cmd_file_save,
      "save [PATH]",                "save current buffer (or to PATH)" },
    { "close",        cmd_file_close,
      "close [NAME]",               "close a buffer" },
    { "recent",       cmd_file_recent,
      "recent [-n N]",              "list recent files" },

    /* ── text editing ──────────────────────────────────────────────── */
    { "insert",       cmd_insert,
      "insert [-b BUF] [-p POS] TEXT",  "insert text at point or position" },
    { "delete",       cmd_delete,
      "delete [-b BUF] START END",      "delete region, print deleted text" },
    { "line",         cmd_line,
      "line [-b BUF] [N]",             "get Nth line (default: current)" },
    { "append",       cmd_append,
      "append [-b BUF] TEXT",           "append text to end of buffer" },

    /* ── navigation ────────────────────────────────────────────────── */
    { "point",        cmd_point,
      "point [-b BUF]",                "print cursor position (line:col)" },
    { "goto",         cmd_goto,
      "goto [-b BUF] LINE[:COL]",      "go to line and column" },

    /* ── search / replace ──────────────────────────────────────────── */
    { "search",       cmd_search,
      "search [-b BUF] [-r] [-c] PATTERN",     "search for pattern" },
    { "replace",      cmd_replace,
      "replace [-b BUF] [-r] PATTERN REPL",    "replace all occurrences" },
    { "occur",        cmd_occur,
      "occur [-b BUF] PATTERN",                "list matching lines (grep-style)" },

    /* ── windows ───────────────────────────────────────────────────── */
    { "win",          cmd_win,
      "win SUBCMD [ARGS...]",       "window operations (list, split, close, ...)" },

    /* ── configuration ─────────────────────────────────────────────── */
    { "set",          cmd_set,
      "set VAR VALUE",              "set an Emacs variable" },
    { "get",          cmd_get_var,
      "get VAR",                    "get an Emacs variable value" },
    { "theme",        cmd_theme,
      "theme NAME",                 "load a color theme" },
    { "font",         cmd_font,
      "font FAMILY [SIZE]",         "set the default font" },
    { "mode",         cmd_mode,
      "mode NAME",                  "set major mode" },

    /* ── project / build ───────────────────────────────────────────── */
    { "grep",         cmd_grep,
      "grep PATTERN [DIR]",         "recursive grep in project" },
    { "find",         cmd_find,
      "find FILENAME [DIR]",        "find file by name" },
    { "project-root", cmd_project_root,
      "project-root",               "print project root directory" },
    { "compile",      cmd_compile,
      "compile CMD",                "run a compilation command" },
    { "next-error",   cmd_next_error,
      "next-error",                 "jump to next compilation error" },
    { "prev-error",   cmd_prev_error,
      "prev-error",                 "jump to previous compilation error" },
    { "diag",         cmd_diag,
      "diag [-b BUF]",             "list diagnostics (flymake/flycheck)" },

    /* ── bookmarks ─────────────────────────────────────────────────── */
    { "mark",         cmd_mark,
      "mark SUBCMD [ARGS...]",      "bookmark operations (set, list, jump, del)" },

    /* ── clipboard ─────────────────────────────────────────────────── */
    { "copy",         cmd_copy,
      "copy [-b BUF] START END",    "copy region to kill ring" },
    { "cut",          cmd_cut,
      "cut [-b BUF] START END",     "cut region (delete + copy)" },
    { "paste",        cmd_paste,
      "paste [-b BUF]",             "paste from kill ring" },
    { "clip",         cmd_clip,
      "clip SUBCMD [ARGS...]",      "clipboard operations (list)" },

    /* ── version control ───────────────────────────────────────────── */
    { "vc",           cmd_vc,
      "vc SUBCMD [ARGS...]",        "version control (status, diff, log, blame)" },

    /* ── packages ──────────────────────────────────────────────────── */
    { "pkg",          cmd_pkg,
      "pkg SUBCMD [ARGS...]",       "package management (install, remove, list)" },

    /* ── monitor management ────────────────────────────────────────── */
    { "monitor",      cmd_monitor,
      "monitor SUBCMD [ARGS...]",       "monitor management (list, modes, scale, ...)" },

    /* ── gowl compositor: session lock + screensaver wallpaper ─────── */
    { "gowl",         cmd_gowl,
      "gowl {lock|unlock|screensaver [CONFIG]|screensaver-stop"
      "|screensaver-configs|screensaver-status|screensaver-restart"
      "|screensaver-pause|screensaver-resume|screensaver-fps N}",
      "compositor session lock/unlock + animated screensaver wallpaper" },

    /* ── ripgrep ────────────────────────────────────────────────────── */
    { "rg",           cmd_rg,
      "rg [search|files|type] [-i] [-w] PATTERN [DIR]",
      "ripgrep search, results in clickable *rg* buffer" },

    /* ── gowl bar ──────────────────────────────────────────────────── */
    { "bar",          cmd_bar,
      "bar SUBCMD [ARGS...]",
      "gowl bar operations (configure, height, show, hide, redraw, title)" },

    /* ── C runtime introspection / hot-patching ────────────────────── */
    { "c",            cmd_c,
      "c SUBCMD [ARGS...]",
      "C runtime introspection and hot-patching (cintrospect/cpatch)" },

    /* ── original commands ─────────────────────────────────────────── */
    { "eval",         cmd_eval,
      "eval EXPR",                  "evaluate elisp expression" },
    { "find-file",    cmd_find_file,
      "find-file PATH",             "open a file (alias for open)" },
    { "message",      cmd_message,
      "message TEXT",               "display a message in CMacs" },
    { "require",      cmd_require,
      "require NS [VERSION]",       "load a GI namespace" },
    { "call",         cmd_call,
      "call NS FUNC [ARGS...]",     "call a GI function" },
    { "list",         cmd_list,
      "list NS",                    "list functions in a GI namespace" },

    { NULL, NULL, NULL, NULL }
};

/* ── BaconCommand vfuncs ─────────────────────────────────────────── */

static const gchar *
cmacs_gi_command_get_name(BaconCommand *cmd)
{
    (void)cmd;
    return "cmacsgi";
}

static const gchar *
cmacs_gi_command_get_usage(BaconCommand *cmd)
{
    (void)cmd;
    return "cmacsgi COMMAND [ARGS...]";
}

static const gchar *
cmacs_gi_command_get_help(BaconCommand *cmd)
{
    (void)cmd;
    return "Interact with CMacs via GObject Introspection.\n"
           "Use 'cmacsgi --help' for a full list of commands.";
}

static void
print_top_help(void)
{
    const CmacsApiSubcmd *p;

    printf("cmacsgi — interact with CMacs from the Bacon shell\n\n");
    printf("Usage: cmacsgi COMMAND [ARGS...]\n\n");
    printf("Commands:\n");
    for (p = subcmds; p->name != NULL; p++)
        printf("  %-28s %s\n", p->usage, p->help);
    printf("\nUse 'cmacsgi help COMMAND' for details on a specific command.\n");
}

static gint
cmacs_gi_command_run(BaconCommand  *cmd,
                     gint          argc,
                     gchar       **argv,
                     gpointer      shell,
                     GError      **error)
{
    CmacsApiTransport  *transport;
    const gchar *subcmd;
    const CmacsApiSubcmd *p;
    gint         rc;

    (void)cmd;
    (void)shell;

    if (argc < 2)
    {
        print_top_help();
        return 1;
    }

    subcmd = argv[1];

    if (strcmp(subcmd, "--help") == 0 || strcmp(subcmd, "-h") == 0)
    {
        print_top_help();
        return 0;
    }

    if (strcmp(subcmd, "help") == 0)
    {
        if (argc < 3)
        {
            print_top_help();
            return 0;
        }
        for (p = subcmds; p->name != NULL; p++)
        {
            if (strcmp(argv[2], p->name) == 0)
            {
                printf("Usage: cmacsgi %s\n\n  %s\n", p->usage, p->help);
                return 0;
            }
        }
        fprintf(stderr, "cmacsgi help: unknown command '%s'\n", argv[2]);
        return 1;
    }

    transport = cmacs_api_transport_new(error);
    if (transport == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n",
                (error && *error) ? (*error)->message
                                  : "cannot connect to CMacs");
        return 1;
    }

    rc = 1;
    for (p = subcmds; p->name != NULL; p++)
    {
        if (strcmp(subcmd, p->name) == 0)
        {
            rc = p->handler(transport, argc, argv);
            cmacs_api_transport_free(transport);
            return rc;
        }
    }

    fprintf(stderr, "cmacsgi: unknown command '%s'\n", subcmd);
    fprintf(stderr, "Try 'cmacsgi --help' for usage.\n");
    cmacs_api_transport_free(transport);
    return 1;
}

/* ── GObject boilerplate ─────────────────────────────────────────── */

static void
cmacs_gi_command_class_init(CmacsGiCommandClass *klass)
{
    BaconCommandClass *cmd_class = BACON_COMMAND_CLASS(klass);

    cmd_class->get_name  = cmacs_gi_command_get_name;
    cmd_class->get_usage = cmacs_gi_command_get_usage;
    cmd_class->get_help  = cmacs_gi_command_get_help;
    cmd_class->run       = cmacs_gi_command_run;
}

static void
cmacs_gi_command_init(CmacsGiCommand *self)
{
    (void)self;
}

CmacsGiCommand *
cmacs_gi_command_new(void)
{
    return g_object_new(CMACS_TYPE_GI_COMMAND, NULL);
}
