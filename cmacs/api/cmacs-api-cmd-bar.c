/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-cmd-bar.c — gowl bar subcommands for cmacsgi
 *
 * Subcommands:
 *   bar configure [top|bottom] KEY=VALUE...   configure a bar slot
 *   bar height     [top|bottom]               print bar height
 *   bar set-height SIZE [top|bottom]          set bar height
 *   bar show       [top|bottom]               show a bar
 *   bar hide       [top|bottom]               hide a bar
 *   bar redraw     [top|bottom|all]           force a redraw
 *   bar title      TITLE [top|bottom]         set bar title
 *
 * Every subsubcommand translates to an Elisp form and dispatches
 * via cmacs_api_eval_*.  No GI types are needed in the bacon
 * address space.
 */

#include "cmacs-api.h"

#include <ctype.h>

/* ── Helpers ───────────────────────────────────────────────────────── */

/* Parse an optional "top" / "bottom" token.  Returns a string that
   the caller can embed into the `position' setting verbatim (owned
   by static storage -- don't free). */
static const gchar *
bar_parse_position(const gchar *s)
{
    if (s == NULL)
        return "top";
    if (g_ascii_strcasecmp(s, "bottom") == 0)
        return "bottom";
    if (g_ascii_strcasecmp(s, "all") == 0)
        return "all";
    return "top";
}

/* Build an alist fragment for the KEY=VALUE arguments starting at
   argv[from].  Returns a GString the caller must free with
   g_string_free(,TRUE). */
static GString *
bar_build_alist(gint from, gint argc, gchar **argv)
{
    GString *s = g_string_new(NULL);
    gint     i;

    for (i = from; i < argc; i++)
    {
        const gchar *eq = strchr(argv[i], '=');
        gchar       *key, *val, *esc_key, *esc_val;

        if (eq == NULL)
        {
            /* Reserved for positional hints like "top"/"bottom" when
               they appear in the KEY=VALUE list -- the caller is
               expected to strip those before getting here. */
            continue;
        }

        key = g_strndup(argv[i], (gsize)(eq - argv[i]));
        val = g_strdup(eq + 1);

        esc_key = cmacs_api_lisp_escape(key);
        esc_val = cmacs_api_lisp_escape(val);
        g_string_append_printf(s, " (\"%s\" . \"%s\")",
                                esc_key, esc_val);
        g_free(esc_key);
        g_free(esc_val);
        g_free(key);
        g_free(val);
    }

    return s;
}

/* ── Subcommand handlers ──────────────────────────────────────────── */

static gint
bar_configure_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gint         pos_start;
    GString     *alist;
    gchar       *elisp;
    gint         rc;

    /* argv layout: [0]=cmacsgi [1]=bar [2]=configure [3]=POSITION? */
    if (argc < 4)
    {
        fprintf(stderr,
                "cmacsgi bar configure: usage: "
                "bar configure [top|bottom] KEY=VALUE...\n");
        return 1;
    }

    /* Position is optional and must come right after `configure'. */
    if (strchr(argv[3], '=') == NULL)
    {
        position = bar_parse_position(argv[3]);
        pos_start = 4;
    }
    else
    {
        position = "top";
        pos_start = 3;
    }

    alist = bar_build_alist(pos_start, argc, argv);
    elisp = g_strdup_printf(
        "(gowl-bar-configure '((\"position\" . \"%s\")%s))",
        position, alist->str);
    g_string_free(alist, TRUE);

    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_height_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gchar       *elisp;
    gint         rc;

    position = (argc >= 4) ? bar_parse_position(argv[3]) : "top";
    elisp = g_strdup_printf("(gowl-bar-height '%s)", position);
    rc = cmacs_api_eval_print(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_set_height_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gint         n;
    gchar       *elisp;
    gint         rc;

    if (argc < 4)
    {
        fprintf(stderr,
                "cmacsgi bar set-height: usage: "
                "bar set-height SIZE [top|bottom]\n");
        return 1;
    }

    n = atoi(argv[3]);
    position = (argc >= 5) ? bar_parse_position(argv[4]) : "top";
    elisp = g_strdup_printf("(gowl-set-bar-height %d '%s)", n, position);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_show_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gchar       *elisp;
    gint         rc;

    position = (argc >= 4) ? bar_parse_position(argv[3]) : "top";
    elisp = g_strdup_printf("(gowl-set-bar-visible t '%s)", position);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_hide_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gchar       *elisp;
    gint         rc;

    position = (argc >= 4) ? bar_parse_position(argv[3]) : "top";
    elisp = g_strdup_printf("(gowl-set-bar-visible nil '%s)", position);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_redraw_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    gchar *elisp;
    gint   rc;

    (void)argc;
    (void)argv;
    /* Module-level redraw refreshes every slot already. */
    elisp = g_strdup("(gowl-bar-redraw)");
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

static gint
bar_title_cmd(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *position;
    gchar       *esc, *elisp;
    gint         rc;

    if (argc < 4)
    {
        fprintf(stderr,
                "cmacsgi bar title: usage: bar title TITLE [top|bottom]\n");
        return 1;
    }

    esc = cmacs_api_lisp_escape(argv[3]);
    position = (argc >= 5) ? bar_parse_position(argv[4]) : "top";
    elisp = g_strdup_printf("(gowl-bar-set-title \"%s\" '%s)",
                             esc, position);
    g_free(esc);
    rc = cmacs_api_eval_quiet(transport, elisp);
    g_free(elisp);
    return rc;
}

/* ── Top-level dispatch ───────────────────────────────────────────── */

gint
cmd_bar(CmacsApiTransport *transport, gint argc, gchar **argv)
{
    const gchar *sub;

    if (argc < 3)
    {
        fprintf(stderr,
                "cmacsgi bar: usage: bar SUBCMD [ARGS...]\n"
                "  configure [top|bottom] KEY=VALUE...  configure a bar\n"
                "  height     [top|bottom]              print bar height\n"
                "  set-height SIZE [top|bottom]         set bar height\n"
                "  show       [top|bottom]              show a bar\n"
                "  hide       [top|bottom]              hide a bar\n"
                "  redraw                               force redraw\n"
                "  title      TITLE [top|bottom]        set bar title\n");
        return 1;
    }

    sub = argv[2];
    if (strcmp(sub, "configure") == 0)
        return bar_configure_cmd(transport, argc, argv);
    if (strcmp(sub, "height") == 0)
        return bar_height_cmd(transport, argc, argv);
    if (strcmp(sub, "set-height") == 0)
        return bar_set_height_cmd(transport, argc, argv);
    if (strcmp(sub, "show") == 0)
        return bar_show_cmd(transport, argc, argv);
    if (strcmp(sub, "hide") == 0)
        return bar_hide_cmd(transport, argc, argv);
    if (strcmp(sub, "redraw") == 0)
        return bar_redraw_cmd(transport, argc, argv);
    if (strcmp(sub, "title") == 0)
        return bar_title_cmd(transport, argc, argv);

    fprintf(stderr, "cmacsgi bar: unknown subcommand: %s\n", sub);
    return 1;
}
