/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-helpers.c --- eval wrappers, string utilities, and
 * dispatch-group helper for the CMacs API.
 *
 * Extracted from cmacs/bacon/modules/cmacs-gi-command.c so that both
 * the bacon cmacsgi module and crispy scripts share this code.
 */

#include "cmacs-api.h"

#include <stdio.h>
#include <string.h>

/* ── String utilities ─────────────────────────────────────────────── */

gchar *
cmacs_api_lisp_escape (const gchar *s)
{
    GString *q;

    q = g_string_new (NULL);
    while (*s != '\0')
    {
        if (*s == '\\' || *s == '"')
            g_string_append_c (q, '\\');
        g_string_append_c (q, *s);
        s++;
    }
    return g_string_free (q, FALSE);
}

static gboolean
looks_like_number (const gchar *s)
{
    if (*s == '-' || *s == '+')
        s++;
    if (*s == '\0')
        return FALSE;
    while (*s != '\0')
    {
        if (!g_ascii_isdigit (*s) && *s != '.' && *s != 'e' && *s != 'E')
            return FALSE;
        s++;
    }
    return TRUE;
}

gchar *
cmacs_api_lisp_quote (const gchar *s)
{
    GString *q;

    /* Already a number, quoted string, or s-expression --- pass through. */
    if (looks_like_number (s) || *s == '"' || *s == '(' || *s == '\'')
        return g_strdup (s);

    /* Lisp keywords: t, nil */
    if (strcmp (s, "t") == 0 || strcmp (s, "nil") == 0)
        return g_strdup (s);

    /* Otherwise wrap as a Lisp string literal. */
    q = g_string_new ("\"");
    while (*s != '\0')
    {
        if (*s == '\\' || *s == '"')
            g_string_append_c (q, '\\');
        g_string_append_c (q, *s);
        s++;
    }
    g_string_append_c (q, '"');
    return g_string_free (q, FALSE);
}

/* ── Eval helpers ─────────────────────────────────────────────────── */

gint
cmacs_api_eval_print (CmacsApiTransport *transport, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;
    const gchar *val;

    result = cmacs_api_transport_call (
        transport, "Eval",
        g_variant_new ("(s)", elisp), &err);

    if (result == NULL)
    {
        fprintf (stderr, "cmacs-api: %s\n", err->message);
        g_error_free (err);
        return 1;
    }

    g_variant_get (result, "(&s)", &val);
    printf ("%s\n", val);
    g_variant_unref (result);
    return 0;
}

gint
cmacs_api_eval_quiet (CmacsApiTransport *transport, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;

    result = cmacs_api_transport_call (
        transport, "Eval",
        g_variant_new ("(s)", elisp), &err);

    if (result == NULL)
    {
        fprintf (stderr, "cmacs-api: %s\n", err->message);
        g_error_free (err);
        return 1;
    }

    g_variant_unref (result);
    return 0;
}

gchar *
cmacs_api_eval_get_string (CmacsApiTransport *transport, const gchar *elisp)
{
    GError   *err = NULL;
    GVariant *result;
    const gchar *val;
    gchar *ret;

    result = cmacs_api_transport_call (
        transport, "Eval",
        g_variant_new ("(s)", elisp), &err);

    if (result == NULL)
    {
        fprintf (stderr, "cmacs-api: %s\n", err->message);
        g_error_free (err);
        return NULL;
    }

    g_variant_get (result, "(&s)", &val);
    ret = g_strdup (val);
    g_variant_unref (result);
    return ret;
}

/* ── Group dispatch helper ────────────────────────────────────────── */

void
cmacs_api_print_group_help (const gchar          *group_name,
                            const CmacsApiSubcmd *table)
{
    const CmacsApiSubcmd *p;

    printf ("cmacsgi %s subcommands:\n\n", group_name);
    for (p = table; p->name != NULL; p++)
        printf ("  %-24s %s\n", p->usage, p->help);
    printf ("\n");
}

gint
cmacs_api_dispatch_group (const gchar          *group_name,
                          const CmacsApiSubcmd *table,
                          CmacsApiTransport    *transport,
                          gint                  argc,
                          gchar               **argv,
                          gint                  depth)
{
    const CmacsApiSubcmd *p;
    const gchar *sub;

    if (depth >= argc)
    {
        fprintf (stderr, "cmacsgi %s: missing subcommand\n", group_name);
        cmacs_api_print_group_help (group_name, table);
        return 1;
    }

    sub = argv[depth];

    if (strcmp (sub, "--help") == 0 || strcmp (sub, "-h") == 0)
    {
        cmacs_api_print_group_help (group_name, table);
        return 0;
    }

    for (p = table; p->name != NULL; p++)
    {
        if (strcmp (sub, p->name) == 0)
            return p->handler (transport, argc, argv);
    }

    fprintf (stderr, "cmacsgi %s: unknown subcommand '%s'\n",
             group_name, sub);
    fprintf (stderr, "Try 'cmacsgi %s --help' for usage.\n", group_name);
    return 1;
}
