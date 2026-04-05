/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-gi-command.c — `cmacsgi` builtin: interact with CMacs via D-Bus
 *
 * Uses GDBus to call the org.cmacs.Editor1 D-Bus interface, which CMacs
 * exposes for GObject Introspection, elisp evaluation, and file ops.
 *
 * Usage:
 *   cmacsgi eval "(+ 1 2)"
 *   cmacsgi find-file /tmp/foo.txt
 *   cmacsgi message "hello from bacon"
 *   cmacsgi require GLib 2.0
 *   cmacsgi call GLib get_user_name
 *   cmacsgi call GLib compute_checksum_for_string 2 hello -1
 *   cmacsgi list GLib
 */

#define BACON_COMPILATION
#include "cmacs-gi-command.h"
#include <bacon-types.h>

#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

struct _CmacsGiCommand
{
    BaconCommand parent_instance;
};

G_DEFINE_FINAL_TYPE(CmacsGiCommand, cmacs_gi_command, BACON_TYPE_COMMAND)

/* ── D-Bus proxy management ──────────────────────────────────────── */

static GDBusProxy *
get_cmacs_proxy(GError **error)
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

/* ── Argument quoting for GI calls ───────────────────────────────── */

/* Check if a string looks like a number (for Lisp reader). */
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

/* Quote a string for the Lisp reader if it doesn't already look like
   a Lisp expression (number, quoted string, or s-expression). */
static gchar *
lisp_quote_arg(const gchar *s)
{
    /* Already a number, quoted string, or s-expression — pass through. */
    if (looks_like_number(s) || *s == '"' || *s == '(' || *s == '\'')
        return g_strdup(s);

    /* Lisp keywords: t, nil */
    if (strcmp(s, "t") == 0 || strcmp(s, "nil") == 0)
        return g_strdup(s);

    /* Otherwise wrap as a Lisp string literal. */
    GString *q = g_string_new("\"");
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

/* ── Subcommand handlers ─────────────────────────────────────────── */

static gint
cmd_eval(GDBusProxy *proxy, gint argc, gchar **argv)
{
    GError   *err = NULL;
    GVariant *result;
    GString  *expr;
    gint      i;

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

    result = g_dbus_proxy_call_sync(
        proxy, "Eval",
        g_variant_new("(s)", expr->str),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
    g_string_free(expr, TRUE);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi eval: %s\n", err->message);
        g_error_free(err);
        return 1;
    }

    const gchar *val;
    g_variant_get(result, "(&s)", &val);
    printf("%s\n", val);
    g_variant_unref(result);
    return 0;
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
    GError   *err = NULL;
    GVariant *result;
    GString  *text;
    gint      i;

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

    result = g_dbus_proxy_call_sync(
        proxy, "Message",
        g_variant_new("(s)", text->str),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
    g_string_free(text, TRUE);

    if (result == NULL)
    {
        fprintf(stderr, "cmacsgi message: %s\n", err->message);
        g_error_free(err);
        return 1;
    }
    g_variant_unref(result);
    return 0;
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
        fprintf(stderr, "cmacsgi call: usage: cmacsgi call NAMESPACE FUNCTION [ARGS...]\n");
        return 1;
    }

    /* Build the args array, quoting strings for the Lisp reader. */
    g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
    for (i = 4; i < argc; i++)
    {
        gchar *quoted = lisp_quote_arg(argv[i]);
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

    const gchar *val;
    g_variant_get(result, "(&s)", &val);
    printf("%s\n", val);
    g_variant_unref(result);
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
           "\n"
           "  cmacsgi eval EXPR              evaluate elisp in CMacs\n"
           "  cmacsgi find-file PATH         open a file in CMacs\n"
           "  cmacsgi message TEXT           display a message in CMacs\n"
           "  cmacsgi require NS [VERSION]   load a GI namespace\n"
           "  cmacsgi call NS FUNC [ARGS]    call a GI function\n"
           "  cmacsgi list NS                list functions in a namespace\n"
           "\n"
           "Requires CMacs D-Bus service (CMACS_DBUS_NAME).";
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
    gint         rc;

    (void)cmd;
    (void)shell;

    if (argc < 2)
    {
        fprintf(stderr, "cmacsgi: usage: cmacsgi COMMAND [ARGS...]\n");
        return 1;
    }

    subcmd = argv[1];

    if (strcmp(subcmd, "--help") == 0 || strcmp(subcmd, "-h") == 0)
    {
        printf("%s\n", cmacs_gi_command_get_help(cmd));
        return 0;
    }

    proxy = get_cmacs_proxy(error);
    if (proxy == NULL)
    {
        fprintf(stderr, "cmacsgi: %s\n",
                (*error) ? (*error)->message : "cannot connect to CMacs");
        return 1;
    }

    if (strcmp(subcmd, "eval") == 0)
        rc = cmd_eval(proxy, argc, argv);
    else if (strcmp(subcmd, "find-file") == 0)
        rc = cmd_find_file(proxy, argc, argv);
    else if (strcmp(subcmd, "message") == 0)
        rc = cmd_message(proxy, argc, argv);
    else if (strcmp(subcmd, "require") == 0)
        rc = cmd_require(proxy, argc, argv);
    else if (strcmp(subcmd, "call") == 0)
        rc = cmd_call(proxy, argc, argv);
    else if (strcmp(subcmd, "list") == 0)
        rc = cmd_list(proxy, argc, argv);
    else
    {
        fprintf(stderr, "cmacsgi: unknown command '%s'\n", subcmd);
        fprintf(stderr, "Try 'cmacsgi --help' for usage.\n");
        rc = 1;
    }

    g_object_unref(proxy);
    return rc;
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
