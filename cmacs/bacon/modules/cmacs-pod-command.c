/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-pod-command.c --- pod bacon builtin
 *
 * BaconCommand subclass that provides the `pod` shell builtin for
 * the podomation automation engine.  All operations go through the
 * CMacs API transport (Elisp eval of podomation DEFUNs).
 */

#ifndef BACON_COMPILATION
#define BACON_COMPILATION
#endif
#include "cmacs-pod-command.h"
#include <cmacs-api.h>
#include <bacon-types.h>

#include <stdio.h>
#include <string.h>
#include <readline/readline.h>

struct _CmacsPodCommand
{
    BaconCommand parent_instance;
};

G_DEFINE_FINAL_TYPE(CmacsPodCommand, cmacs_pod_command, BACON_TYPE_COMMAND)

/* ── Subcommand handlers ─────────────────────────────────────────── */

static gint
cmd_start(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport, "(cmacs-podomation-start)");
}

static gint
cmd_stop(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport, "(cmacs-podomation-stop)");
}

static gint
cmd_status(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport,
        "(if (cmacs-podomation-running-p) \"running\" \"stopped\")");
}

static gint
cmd_modules(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport,
        "(mapconcat #'identity (cmacs-podomation-list-modules) \"\\n\")");
}

static gint
cmd_pods(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport,
        "(mapconcat (lambda (p) (format \"%s\\t%s\" (car p) (cdr p)))"
        " (cmacs-podomation-list-pods) \"\\n\")");
}

static gint
cmd_stats(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc;
    (void)argv;
    return cmacs_api_eval_print(transport,
        "(let ((s (cmacs-podomation-stats)))"
        "  (format \"events-dispatched: %d\\n"
        "handlers-called: %d\\n"
        "handlers-failed: %d\\n"
        "pipe-chains-executed: %d\""
        "    (plist-get s :events-dispatched)"
        "    (plist-get s :handlers-called)"
        "    (plist-get s :handlers-failed)"
        "    (plist-get s :pipe-chains-executed)))");
}

static gint
cmd_eval(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    GString *dsl;
    gchar   *escaped;
    gchar   *elisp;
    gint     i, rc;

    if (argc < 3)
    {
        fprintf(stderr, "pod eval: missing DSL text\n");
        return 1;
    }

    dsl = g_string_new(argv[2]);
    for (i = 3; i < argc; i++)
    {
        g_string_append_c(dsl, ' ');
        g_string_append(dsl, argv[i]);
    }

    escaped = cmacs_api_lisp_escape(dsl->str);
    g_string_free(dsl, TRUE);

    elisp = g_strdup_printf(
        "(cmacs-podomation-eval-dsl \"%s\")", escaped);
    g_free(escaped);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
cmd_load(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *escaped;
    gchar *elisp;
    gint   rc;

    if (argc < 3)
    {
        fprintf(stderr, "pod load: missing file path\n");
        return 1;
    }

    escaped = cmacs_api_lisp_escape(argv[2]);
    elisp = g_strdup_printf(
        "(cmacs-podomation-load \"%s\")", escaped);
    g_free(escaped);

    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
cmd_repl(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *line;
    gchar *escaped;
    gchar *elisp;
    gchar *result;

    (void)argc;
    (void)argv;

    /* Ensure engine is started. */
    cmacs_api_eval_quiet(transport,
        "(unless (cmacs-podomation-running-p)"
        "  (cmacs-podomation-start))");

    printf("Podomation REPL (type :quit to exit)\n");

    for (;;)
    {
        line = readline("podomation> ");
        if (line == NULL)
            break;

        if (line[0] == '\0')
        {
            free(line);
            continue;
        }

        if (strcmp(line, ":quit") == 0 || strcmp(line, ":q") == 0)
        {
            free(line);
            break;
        }

        escaped = cmacs_api_lisp_escape(line);
        free(line);

        elisp = g_strdup_printf(
            "(let ((r (cmacs-podomation-repl-eval \"%s\")))"
            "  (if (cdr r) (cdr r) \"\"))",
            escaped);
        g_free(escaped);

        result = cmacs_api_eval_get_string(transport, elisp);
        g_free(elisp);

        if (result != NULL)
        {
            if (result[0] != '\0')
                printf("%s\n", result);
            g_free(result);
        }
    }

    return 0;
}

/* ── Dispatch table ──────────────────────────────────────────────── */

typedef gint (*PodHandler)(CmacsApiTransport *transport,
                           gint argc, gchar **argv);

typedef struct {
    const gchar *name;
    PodHandler   handler;
    const gchar *usage;
    const gchar *help;
} PodSubcmd;

static const PodSubcmd subcmds[] = {
    { "start",   cmd_start,
      "start",                      "start the podomation engine" },
    { "stop",    cmd_stop,
      "stop",                       "stop the podomation engine" },
    { "status",  cmd_status,
      "status",                     "show engine running state" },
    { "modules", cmd_modules,
      "modules",                    "list loaded modules" },
    { "pods",    cmd_pods,
      "pods",                       "list active pods" },
    { "stats",   cmd_stats,
      "stats",                      "show engine statistics" },
    { "eval",    cmd_eval,
      "eval DSL_TEXT",              "parse and execute DSL text" },
    { "load",    cmd_load,
      "load FILE",                  "load a .pod file" },
    { "repl",    cmd_repl,
      "repl",                       "enter interactive REPL" },
    { NULL, NULL, NULL, NULL }
};

/* ── BaconCommand vfuncs ────────────────────────────────────────── */

static const gchar *
cmacs_pod_command_get_name(BaconCommand *cmd)
{
    (void)cmd;
    return "pod";
}

static const gchar *
cmacs_pod_command_get_usage(BaconCommand *cmd)
{
    (void)cmd;
    return "pod COMMAND [ARGS...]";
}

static const gchar *
cmacs_pod_command_get_help(BaconCommand *cmd)
{
    (void)cmd;
    return "Podomation automation engine.\n"
           "Use 'pod --help' for a full list of commands.";
}

static void
print_top_help(void)
{
    const PodSubcmd *p;

    printf("pod — podomation automation engine\n\n");
    printf("Usage: pod COMMAND [ARGS...]\n\n");
    printf("Commands:\n");
    for (p = subcmds; p->name != NULL; p++)
        printf("  %-28s %s\n", p->usage, p->help);
    printf("\n");
}

static gint
cmacs_pod_command_run(BaconCommand  *cmd,
                      gint          argc,
                      gchar       **argv,
                      gpointer      shell,
                      GError      **error)
{
    CmacsApiTransport  *transport;
    const gchar *subcmd;
    const PodSubcmd *p;
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
                printf("Usage: pod %s\n\n  %s\n", p->usage, p->help);
                return 0;
            }
        }
        fprintf(stderr, "pod help: unknown command '%s'\n", argv[2]);
        return 1;
    }

    transport = cmacs_api_transport_new(error);
    if (transport == NULL)
    {
        fprintf(stderr, "pod: %s\n",
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

    fprintf(stderr, "pod: unknown command '%s'\n", subcmd);
    fprintf(stderr, "Try 'pod --help' for usage.\n");
    cmacs_api_transport_free(transport);
    return 1;
}

/* ── GObject boilerplate ────────────────────────────────────────── */

static void
cmacs_pod_command_class_init(CmacsPodCommandClass *klass)
{
    BaconCommandClass *cmd_class = BACON_COMMAND_CLASS(klass);

    cmd_class->get_name  = cmacs_pod_command_get_name;
    cmd_class->get_usage = cmacs_pod_command_get_usage;
    cmd_class->get_help  = cmacs_pod_command_get_help;
    cmd_class->run       = cmacs_pod_command_run;
}

static void
cmacs_pod_command_init(CmacsPodCommand *self)
{
    (void)self;
}

CmacsPodCommand *
cmacs_pod_command_new(void)
{
    return g_object_new(CMACS_TYPE_POD_COMMAND, NULL);
}
