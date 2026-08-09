/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-cmd-brigade.c — AI brigade subcommands for cmacsgi/bacon
 *
 * Subcommands:
 *   brigade spawn TASK [-a AGENT] [-t TITLE] [-m MODEL]
 *   brigade status ID
 *   brigade result ID [-t TURN]
 *   brigade cancel ID
 *   brigade list
 *   brigade agents
 *   brigade providers
 *   brigade models PROVIDER
 *   brigade send ID MESSAGE
 *   brigade inbox ID
 *   brigade drop ID [INDEX]
 *   brigade log ID [-f FROM-TURN] [-k KINDS]
 *   brigade close ID
 *
 * Every verb funnels into `cmacs-brigade-call-tool', the same entry point
 * an agent reaches over MCP and a shell reaches over D-Bus.  Three
 * surfaces, one code path: a bacon caller cannot end up somewhere a model
 * making the same request would not, which is the whole reason the tool
 * layer is where the behaviour lives rather than here.
 *
 * Arguments are assembled as a JSON object because that is what
 * `cmacs-brigade-call-tool' takes.  It is built by hand rather than with
 * json-glib to keep libcmacs-api.so free of a dependency it otherwise
 * does not have -- the escaping is the standard JSON string escape and is
 * exercised by every verb that takes free text.
 */

#include "cmacs-api.h"

/* ── JSON argument assembly ───────────────────────────────────────── */

/* Escape S for inclusion in a JSON string literal.  Control characters
 * become \u00XX rather than being passed through: a task description
 * pasted from a terminal routinely carries them, and an unescaped one
 * makes the whole object unparseable at the far end. */
static void
json_escape_into(GString *out, const gchar *s)
{
    const guchar *p;

    for (p = (const guchar *)s; *p != '\0'; p++)
    {
        switch (*p)
        {
        case '"':  g_string_append(out, "\\\""); break;
        case '\\': g_string_append(out, "\\\\"); break;
        case '\n': g_string_append(out, "\\n");  break;
        case '\r': g_string_append(out, "\\r");  break;
        case '\t': g_string_append(out, "\\t");  break;
        default:
            if (*p < 0x20)
                g_string_append_printf(out, "\\u%04x", (guint)*p);
            else
                g_string_append_c(out, (gchar)*p);
            break;
        }
    }
}

/* Build a JSON object from NULL-terminated key/value pairs, skipping any
 * pair whose value is NULL or empty.  Skipping rather than emitting null
 * matters: an omitted optional argument must reach the tool as absent, so
 * that its own default applies. */
static gchar *
build_args(const gchar *first_key, ...)
{
    GString     *out;
    const gchar *key;
    va_list      ap;
    gboolean     first;

    out = g_string_new("{");
    first = TRUE;
    key = first_key;

    va_start(ap, first_key);
    while (key != NULL)
    {
        const gchar *val = va_arg(ap, const gchar *);
        if (val != NULL && *val != '\0')
        {
            if (!first)
                g_string_append_c(out, ',');
            first = FALSE;
            g_string_append_c(out, '"');
            json_escape_into(out, key);
            g_string_append(out, "\":\"");
            json_escape_into(out, val);
            g_string_append_c(out, '"');
        }
        key = va_arg(ap, const gchar *);
    }
    va_end(ap);

    g_string_append_c(out, '}');
    return g_string_free(out, FALSE);
}

/* Call brigade tool NAME with ARGS_JSON and print whatever it returns.
 *
 * Confirmation is bound away for the same reason the D-Bus surface does
 * it: a `:confirm' tool exists so an *agent* cannot start paid work
 * unattended, and a bacon caller is the session owner, who could equally
 * well have evalled the elisp directly.  It also cannot work as-is --
 * a prompt inside an RPC eval signals rather than asking. */
static gint
call_tool(CmacsApiTransport *transport, const gchar *name,
          const gchar *args_json)
{
    gchar *args_q;
    gchar *elisp;
    gint   rc;

    args_q = cmacs_api_lisp_escape(args_json != NULL ? args_json : "{}");
    elisp = g_strdup_printf(
        "(progn (require 'cmacs-brigade)"
        " (require 'cmacs-brigade-subagent)"
        " (require 'cmacs-brigade-mailbox nil t)"
        " (let ((cmacs-brigade-confirm-function (lambda (_) t)))"
        "  (condition-case e (cmacs-brigade-call-tool \"%s\" \"%s\" \"bacon\")"
        "   (error (format \"error: %%s\" (error-message-string e))))))",
        name, args_q);
    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    g_free(args_q);
    return rc;
}

/* Find the value of flag FLAG in ARGV, or NULL.  Flags may appear in any
 * order after the positional arguments, which is how every other cmacsgi
 * group behaves. */
static const gchar *
flag_value(gint argc, gchar **argv, gint from, const gchar *flag)
{
    gint i;

    for (i = from; i + 1 < argc; i++)
    {
        if (strcmp(argv[i], flag) == 0)
            return argv[i + 1];
    }
    return NULL;
}

/* The first argument at or after FROM that is not a flag or a flag's
 * value.  Positional arguments are picked out this way so that
 * `brigade send ID MESSAGE' and `brigade log ID -f 2' can share one
 * parser without a full option library. */
static const gchar *
positional(gint argc, gchar **argv, gint from, gint want)
{
    gint i, seen;

    seen = 0;
    for (i = from; i < argc; i++)
    {
        if (argv[i][0] == '-' && argv[i][1] != '\0')
        {
            i++; /* skip the flag's value */
            continue;
        }
        if (seen == want)
            return argv[i];
        seen++;
    }
    return NULL;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

static gint
brigade_spawn(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *task;
    g_autofree gchar *args = NULL;

    task = positional(argc, argv, 2, 0);
    if (task == NULL)
    {
        g_printerr("usage: brigade spawn TASK [-a AGENT] [-t TITLE] "
                   "[-m MODEL]\n");
        return 1;
    }
    args = build_args("task", task,
                      "agent", flag_value(argc, argv, 2, "-a"),
                      "title", flag_value(argc, argv, 2, "-t"),
                      "model", flag_value(argc, argv, 2, "-m"),
                      NULL);
    return call_tool(transport, "agent_spawn", args);
}

/* Every verb whose only argument is a task id.  One handler rather than
 * six near-identical ones; the tool name comes from argv[1]. */
static gint
brigade_by_id(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *id;
    const gchar *tool;
    g_autofree gchar *args = NULL;

    id = positional(argc, argv, 2, 0);
    if (id == NULL)
    {
        g_printerr("usage: brigade %s ID\n", argc > 1 ? argv[1] : "VERB");
        return 1;
    }

    if (strcmp(argv[1], "status") == 0)      tool = "agent_status";
    else if (strcmp(argv[1], "cancel") == 0) tool = "agent_cancel";
    else if (strcmp(argv[1], "inbox") == 0)  tool = "agent_inbox";
    else if (strcmp(argv[1], "close") == 0)  tool = "agent_close";
    else                                     tool = "agent_result";

    /* `result' alone takes an optional turn, so that the reply to one
     * message of a conversation can be read after later ones have
     * arrived. */
    args = build_args("id", id,
                      "turn", (strcmp(argv[1], "result") == 0)
                              ? flag_value(argc, argv, 2, "-t") : NULL,
                      NULL);
    return call_tool(transport, tool, args);
}

static gint
brigade_list(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc; (void)argv;
    return call_tool(transport, "agent_list", "{}");
}

static gint
brigade_agents(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc; (void)argv;
    return cmacs_api_eval_print(
        transport,
        "(progn (require 'cmacs-brigade)"
        " (mapconcat (lambda (a) (format \"%s\" a))"
        "  (cmacs-brigade-registry-list 'agent) \"\\n\"))");
}

static gint
brigade_providers(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    (void)argc; (void)argv;
    return call_tool(transport, "agent_providers", "{}");
}

static gint
brigade_models(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *provider;
    g_autofree gchar *args = NULL;

    provider = positional(argc, argv, 2, 0);
    if (provider == NULL)
    {
        g_printerr("usage: brigade models PROVIDER\n");
        return 1;
    }
    args = build_args("provider", provider, NULL);
    return call_tool(transport, "agent_models", args);
}

static gint
brigade_send(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *id;
    const gchar *message;
    g_autofree gchar *args = NULL;

    id = positional(argc, argv, 2, 0);
    message = positional(argc, argv, 2, 1);
    if (id == NULL || message == NULL)
    {
        g_printerr("usage: brigade send ID MESSAGE\n");
        return 1;
    }
    args = build_args("id", id, "message", message, NULL);
    return call_tool(transport, "agent_send", args);
}

static gint
brigade_drop(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *id;
    const gchar *index;
    g_autofree gchar *args = NULL;

    id = positional(argc, argv, 2, 0);
    if (id == NULL)
    {
        g_printerr("usage: brigade drop ID [INDEX]\n");
        return 1;
    }
    /* An absent index reaches the tool as an absent argument, which is
     * what makes it mean "clear the whole queue". */
    index = positional(argc, argv, 2, 1);
    args = build_args("id", id, "index", index, NULL);
    return call_tool(transport, "agent_drop", args);
}

static gint
brigade_log(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *id;
    g_autofree gchar *args = NULL;

    id = positional(argc, argv, 2, 0);
    if (id == NULL)
    {
        g_printerr("usage: brigade log ID [-f FROM-TURN] [-k KINDS]\n");
        return 1;
    }
    args = build_args("id", id,
                      "from_turn", flag_value(argc, argv, 2, "-f"),
                      "kinds", flag_value(argc, argv, 2, "-k"),
                      NULL);
    return call_tool(transport, "agent_log", args);
}

/* ── brigade subgroup ─────────────────────────────────────────────── */

static const CmacsApiSubcmd brigade_subcmds[] = {
    { "spawn",     brigade_spawn,
      "brigade spawn TASK [-a AGENT] [-t TITLE] [-m MODEL]",
      "hand a task to an agent; prints the task id" },
    { "status",    brigade_by_id, "brigade status ID",
      "state, turns, tokens and cost of a task" },
    { "result",    brigade_by_id, "brigade result ID [-t TURN]",
      "what a task produced, latest turn or a named one" },
    { "cancel",    brigade_by_id, "brigade cancel ID",
      "stop a task, running or parked" },
    { "list",      brigade_list, "brigade list",
      "every known task with its state" },
    { "agents",    brigade_agents, "brigade agents",
      "agent definitions available to spawn" },
    { "providers", brigade_providers, "brigade providers",
      "AI providers this cmacs can reach" },
    { "models",    brigade_models, "brigade models PROVIDER",
      "models a provider offers, as provider/model" },
    { "send",      brigade_send, "brigade send ID MESSAGE",
      "queue a message for a task; wakes a parked agent" },
    { "inbox",     brigade_by_id, "brigade inbox ID",
      "messages queued but not yet delivered" },
    { "drop",      brigade_drop, "brigade drop ID [INDEX]",
      "remove a queued message, or all of them" },
    { "log",       brigade_log, "brigade log ID [-f FROM-TURN] [-k KINDS]",
      "transaction log: messages, replies and tool calls" },
    { "close",     brigade_by_id, "brigade close ID",
      "end a conversation and release its session" },
    { NULL, NULL, NULL, NULL }
};

gint
cmd_brigade(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    return cmacs_api_dispatch_group("brigade", brigade_subcmds,
                                    transport, argc, argv, 2);
}
