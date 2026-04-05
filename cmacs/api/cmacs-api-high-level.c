/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-api-high-level.c --- convenience wrappers for common operations
 *
 * These functions provide a clean C API for crispy init.c scripts.
 * Each one builds the appropriate elisp expression and evaluates it
 * through the transport layer.
 */

#include "cmacs-api.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ── CmacsApi handle ──────────────────────────────────────────────── */

struct _CmacsApi
{
    CmacsApiTransport *transport;
};

CmacsApi *
cmacs_api_new (GError **error)
{
    CmacsApi *api;
    CmacsApiTransport *t;

    t = cmacs_api_transport_new (error);
    if (t == NULL)
        return NULL;

    api = g_new0 (CmacsApi, 1);
    api->transport = t;
    return api;
}

void
cmacs_api_free (CmacsApi *api)
{
    if (api == NULL)
        return;
    cmacs_api_transport_free (api->transport);
    g_free (api);
}

/* ── Internal helpers ─────────────────────────────────────────────── */

static gboolean
value_is_number_or_keyword (const gchar *s)
{
    const gchar *p;

    if (strcmp (s, "t") == 0 || strcmp (s, "nil") == 0)
        return TRUE;

    p = s;
    if (*p == '-' || *p == '+')
        p++;
    if (*p == '\0')
        return FALSE;
    while (*p != '\0')
    {
        if (!g_ascii_isdigit (*p) && *p != '.' && *p != 'e' && *p != 'E')
            return FALSE;
        p++;
    }
    return TRUE;
}

/* ── High-level operations ────────────────────────────────────────── */

gint
cmacs_set (CmacsApi *api, const gchar *var, const gchar *value)
{
    gchar *elisp;
    gint rc;

    if (value_is_number_or_keyword (value))
        elisp = g_strdup_printf ("(setq %s %s)", var, value);
    else
    {
        gchar *esc = cmacs_api_lisp_escape (value);
        elisp = g_strdup_printf ("(setq %s \"%s\")", var, esc);
        g_free (esc);
    }

    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}

gint
cmacs_get (CmacsApi *api, const gchar *var, gchar **out)
{
    gchar *elisp, *val;

    elisp = g_strdup_printf ("(symbol-value '%s)", var);
    val = cmacs_api_eval_get_string (api->transport, elisp);
    g_free (elisp);

    if (val == NULL)
        return 1;
    if (out != NULL)
        *out = val;
    else
        g_free (val);
    return 0;
}

gint
cmacs_theme (CmacsApi *api, const gchar *name)
{
    gchar *elisp;
    gint rc;

    elisp = g_strdup_printf ("(load-theme '%s t)", name);
    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}

gint
cmacs_font (CmacsApi *api, const gchar *family, gint size)
{
    gchar *esc, *elisp;
    gint rc;

    esc = cmacs_api_lisp_escape (family);

    if (size > 0)
    {
        gint height = (size < 100) ? size * 10 : size;
        elisp = g_strdup_printf (
            "(set-face-attribute 'default nil :family \"%s\" :height %d)",
            esc, height);
    }
    else
    {
        elisp = g_strdup_printf (
            "(set-face-attribute 'default nil :family \"%s\")", esc);
    }

    g_free (esc);
    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}

gint
cmacs_mode (CmacsApi *api, const gchar *name)
{
    gchar *elisp;
    gint rc;

    if (g_str_has_suffix (name, "-mode"))
        elisp = g_strdup_printf ("(funcall (intern \"%s\"))", name);
    else
        elisp = g_strdup_printf ("(funcall (intern \"%s-mode\"))", name);

    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}

gint
cmacs_eval (CmacsApi *api, const gchar *elisp)
{
    return cmacs_api_eval_quiet (api->transport, elisp);
}

gint
cmacs_open (CmacsApi *api, const gchar *path)
{
    GError *err = NULL;
    GVariant *result;

    result = cmacs_api_transport_call (
        api->transport, "FindFile",
        g_variant_new ("(s)", path), &err);

    if (result == NULL)
    {
        fprintf (stderr, "cmacs_open: %s\n", err->message);
        g_error_free (err);
        return 1;
    }
    if (result != NULL)
        g_variant_unref (result);
    return 0;
}

gint
cmacs_message (CmacsApi *api, const gchar *text)
{
    gchar *esc, *elisp;
    gint rc;

    esc = cmacs_api_lisp_escape (text);
    elisp = g_strdup_printf ("(message \"%%s\" \"%s\")", esc);
    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    g_free (esc);
    return rc;
}

gint
cmacs_pkg_install (CmacsApi *api, const gchar *name)
{
    gchar *elisp;
    gint rc;

    elisp = g_strdup_printf (
        "(progn (require 'package)"
        " (unless (package-installed-p '%s)"
        "   (package-refresh-contents)"
        "   (package-install '%s)))",
        name, name);
    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}

gint
cmacs_pkg_remove (CmacsApi *api, const gchar *name)
{
    gchar *elisp;
    gint rc;

    elisp = g_strdup_printf (
        "(progn (require 'package)"
        " (when (package-installed-p '%s)"
        "   (package-delete (cadr (assq '%s package-alist)))))",
        name, name);
    rc = cmacs_api_eval_quiet (api->transport, elisp);
    g_free (elisp);
    return rc;
}
