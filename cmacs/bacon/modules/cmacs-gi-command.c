/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-command.c — `cmacsgi` builtin: interact with CMacs via D-Bus
 *
 * Core dispatch, shared utilities, and GObject boilerplate for the
 * cmacsgi bacon builtin.  Individual command groups live in separate
 * cmacs-gi-cmd-*.c files; this file owns the top-level dispatch table,
 * the D-Bus proxy helper, eval wrappers, and the original subcommands
 * (eval, find-file, message, require, call, list).
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

/* ── D-Bus proxy management ──────────────────────────────────────── */

GDBusProxy *
cmacs_gi_get_proxy(GError **error)
{
    const gchar *bus_name;
    GDBusProxy  *proxy;

    bus_name = g_getenv("CMACS_DBUS_NAME");
    if (bus_name == NULL || *bus_name == '\0')
    {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                    "CMACS_DBUS_NAME not set — not running inside CMacs?");
        return NULL;
    }

    proxy = g_dbus_proxy_new_for_bus_sync(
        G_BUS_TYPE_SESSION,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL,
        bus_name,
        "/org/cmacs/Editor",
        "org.cmacs.Editor1",
        NULL, error);
    return proxy;
}

/* ── String utilities ─────────────────────────────────────────────── */

gchar *
cmacs_gi_lisp_escape(const gchar *s)
{
    GString *q;

    q = g_string_new(NULL);
    while (*s != '\0')
    {
        if (*s == '\\' || *s == '"')
            g_string_append_c(q, '\\');
        g_string_append_c(q, *s);
        s++;
    }
    return g_string_free(q, FALSE);
}

static gboolean
looks_like_number(const gchar *s)
{
    if (*s == '-' || *s == '+')
        s++;
    if (*s == '\0')
        return FALSE;
    while (*s != '\0')
    {
        if (!g_ascii_isdigit(*s) && *s != '.' && *s != 'e' && *s != 'E')
            return FALSE;
        s++;
    }
    return TRUE;
}

gchar *
cmacs_gi_lisp_quote(const gchar *s)
{
    GString *q;

    /* Already a number, quoted string, or s-expression — pass through. */
    if (looks_like_number(s) || *s == '"' || *s == '(' || *s == '\'')
        return g_strdup(s);

    /* Lisp keywords: t, nil */
    if (strcmp(s, "t") == 0 || strcmp(s, "nil") == 0)
        return g_strdup(s);

    /* Otherwise wrap as a Lisp string literal. */
    q = g_string_new("\"");
    while (*s != '\0')
    {
        if (*s == '\\' || *s == '"')
            g_string_append_c(q, '\\');
        g_string_append_c(q, *s);
        s++;
    }
    g_string_append_c(q, '"');
    return g_string_free(q, FALSE);
}

/* ── Eval helpers ─────────────────────────────────────────────────── */

gint
cmacs_gi_eval_print(GDBusProxy *proxy, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;
    const gchar *val;

    result = g_dbus_proxy_call_sync(
        proxy, "Eval",
        g_variant_new("(s)", elisp),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    g_variant_get(result, "(&s)", &val);
    printf("%s\n", val);
    g_variant_unref(result);
    return 0;
}

gint
cmacs_gi_eval_quiet(GDBusProxy *proxy, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;

    result = g_dbus_proxy_call_sync(
        proxy, "Eval",
        g_variant_new("(s)", elisp),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    g_variant_unref(result);
    return 0;
}

gchar *
cmacs_gi_eval_get_string(GDBusProxy *proxy, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;
    const gchar *val;
    gchar *ret;

    result = g_dbus_proxy_call_sync(
        proxy, "Eval",
        g_variant_new("(s)", elisp),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n", err->message);
        g_error_free(err);
        return NULL;
    }

    g_variant_get(result, "(&s)", &val);
    ret = g_strdup(val);
    g_variant_unref(result);
    return ret;
}

/* ── Group dispatch helper ────────────────────────────────────────── */

void
cmacs_gi_print_group_help(const gchar        *group_name,
                          const CmacsGiSubcmd *table)
{
    const CmacsGiSubcmd *p;

    printf("cmacsgi %s subcommands:\n\n", group_name);
    for (p = table; p->name != NULL; p++)
        printf("  %-24s %s\n", p->usage, p->help);
    printf("\n");
}

gint
cmacs_gi_dispatch_group(const gchar        *group_name,
                        const CmacsGiSubcmd *table,
                        GDBusProxy          *proxy,
                        gint                 argc,
                        gchar              **argv,
                        gint                 depth)
{
    const CmacsGiSubcmd *p;
    const gchar *sub;

    if (depth >= argc)
    {
        fprintf(stderr, "cmacsgi %s: missing subcommand\n", group_name);
        cmacs_gi_print_group_help(group_name, table);
        return 1;
    }

    sub = argv[depth];

    if (strcmp(sub, "--help") == 0 || strcmp(sub, "-h") == 0)
    {
        cmacs_gi_print_group_help(group_name, table);
        return 0;
    }

    for (p = table; p->name != NULL; p++)
    {
        if (strcmp(sub, p->name) == 0)
            return p->handler(proxy, argc, argv);
    }

    fprintf(stderr, "cmacsgi %s: unknown subcommand '%s'\n", group_name, sub);
    fprintf(stderr, "Try 'cmacsgi %s --help' for usage.\n", group_name);
    return 1;
}

/* ── Original subcommand handlers ─────────────────────────────────── */

static gint
cmd_eval(GDBusProxy *proxy, gint argc, gchar **argv)
{
    GString  *expr;
    gint      i;
    gint      rc;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi eval: missing expression\n");
        return 1;
    }

    /* Join all remaining args as the expression. */
    expr = g_string_new(argv[2]);
    for (i = 3; i < argc; i++)
    {
        g_string_append_c(expr, ' ');
        g_string_append(expr, argv[i]);
    }

    rc = cmacs_gi_eval_print(proxy, expr->str);
    g_string_free(expr, TRUE);
    return rc;
}

static gint
cmd_find_file(GDBusProxy *proxy, gint argc, gchar **argv)
{
    GError   *err = NULL;
    GVariant *result;

    if (argc < 3)
    {
        fprintf(stderr, "cmacsgi find-file: missing path\n");
        return 1;
    }

    result = g_dbus_proxy_call_sync(
        proxy, "FindFile",
        g_variant_new("(s)", argv[2]),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi find-file: %s\n", err->message);
        g_error_free(err);
        return 1;
    }
    g_variant_unref(result);
    return 0;
}

static gint
cmd_message(GDBusProxy *proxy, gint argc, gchar **argv)
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

    escaped = cmacs_gi_lisp_escape(text->str);
    elisp = g_strdup_printf("(message \"%%s\" \"%s\")", escaped);
    rc = cmacs_gi_eval_quiet(proxy, elisp);
    g_free(elisp);
    g_free(escaped);
    g_string_free(text, TRUE);
    return rc;
}

static gint
cmd_require(GDBusProxy *proxy, gint argc, gchar **argv)
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

    result = g_dbus_proxy_call_sync(
        proxy, "GiRequire",
        g_variant_new("(ss)", ns, ver),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

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
cmd_call(GDBusProxy *proxy, gint argc, gchar **argv)
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

    /* Build the args array, quoting strings for the Lisp reader. */
    g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
    for (i = 4; i < argc; i++)
    {
        gchar *quoted = cmacs_gi_lisp_quote(argv[i]);
        g_variant_builder_add(&builder, "s", quoted);
        g_free(quoted);
    }

    result = g_dbus_proxy_call_sync(
        proxy, "GiCall",
        g_variant_new("(ssas)", argv[2], argv[3], &builder),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

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
cmd_list(GDBusProxy *proxy, gint argc, gchar **argv)
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

    result = g_dbus_proxy_call_sync(
        proxy, "GiListFunctions",
        g_variant_new("(s)", argv[2]),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);

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

/* ── Forward declarations for group handlers ──────────────────────── */

/* Each cmacs-gi-cmd-*.c defines a cmd_GROUP function. */
extern gint cmd_buf     (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_file_open   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_file_save   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_file_close  (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_file_recent (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_insert  (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_delete  (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_line    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_append  (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_point   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_goto    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_search  (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_replace (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_occur   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_win     (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_set     (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_get_var (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_theme   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_font    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_mode    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_grep    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_find    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_project_root (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_compile (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_next_error (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_prev_error (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_diag    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_mark    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_copy    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_cut     (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_paste   (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_clip    (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_vc      (GDBusProxy *proxy, gint argc, gchar **argv);
extern gint cmd_pkg     (GDBusProxy *proxy, gint argc, gchar **argv);

/* ── Top-level dispatch table ─────────────────────────────────────── */

static const CmacsGiSubcmd subcmds[] = {
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
    return "Interact with CMacs via GObject Introspection over D-Bus.\n"
           "Use 'cmacsgi --help' for a full list of commands.";
}

static void
print_top_help(void)
{
    const CmacsGiSubcmd *p;

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
    GDBusProxy  *proxy;
    const gchar *subcmd;
    const CmacsGiSubcmd *p;
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

    /* "help COMMAND" — look up and print that command's help. */
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

    proxy = cmacs_gi_get_proxy(error);
    if (proxy == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n",
                (error && *error) ? (*error)->message
                                  : "cannot connect to CMacs");
        return 1;
    }

    /* Table lookup. */
    rc = 1;
    for (p = subcmds; p->name != NULL; p++)
    {
        if (strcmp(subcmd, p->name) == 0)
        {
            rc = p->handler(proxy, argc, argv);
            g_object_unref(proxy);
            return rc;
        }
    }

    fprintf(stderr, "cmacsgi: unknown command '%s'\n", subcmd);
    fprintf(stderr, "Try 'cmacsgi --help' for usage.\n");
    g_object_unref(proxy);
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
