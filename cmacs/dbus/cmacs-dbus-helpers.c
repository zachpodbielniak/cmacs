/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-helpers.c --- shared utilities for the cmacs D-Bus
 * subsystem.
 *
 * cmacs_dbus_lisp_escape and cmacs_dbus_lisp_quote mirror their
 * cmacs_api_* counterparts in cmacs/api/cmacs-api-helpers.c.  The
 * functions are intentionally duplicated rather than linked: the
 * cmacs/api/ helpers ship in libcmacs-api.so (a separate .so the
 * editor binary does not link against), and copying the 30-line
 * implementations is cheaper than introducing a shared static
 * archive. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <gio/gio.h>
#include <string.h>

/* ── Lisp string escaping ────────────────────────────────────────── */

gchar *
cmacs_dbus_lisp_escape (const gchar *s)
{
  GString *q = g_string_new (NULL);
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
cmacs_dbus_lisp_quote (const gchar *s)
{
  GString *q;

  /* Already a number, quoted string, or s-expression --- pass through. */
  if (looks_like_number (s) || *s == '"' || *s == '(' || *s == '\'')
    return g_strdup (s);

  /* Lisp keywords. */
  if (strcmp (s, "t") == 0 || strcmp (s, "nil") == 0)
    return g_strdup (s);

  /* Wrap as a Lisp string literal. */
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

/* ── Common error helper ─────────────────────────────────────────── */

void
cmacs_dbus_return_gerror (GDBusMethodInvocation *invocation, GError *err)
{
  g_dbus_method_invocation_return_dbus_error (
    invocation, "org.cmacs.Editor1.Error",
    err->message ? err->message : "(unknown error)");
  g_error_free (err);
}

/* ── Generic elisp-to-(s)-reply helper ───────────────────────────── */

void
cmacs_dbus_eval_to_reply (GDBusMethodInvocation *invocation,
                          const gchar           *elisp_template,
                          const gchar          **args,
                          gint                   n_args)
{
  gchar *expr;
  gchar *result;
  GError *err = NULL;

  /* Substitute %s placeholders with lisp-escaped argv values.
     %% emits a literal %.  Other % escapes are kept verbatim. */
  expr = cmacs_dbus_build_elisp (elisp_template, args, n_args);

  result = cmacs_dispatch_eval (expr, &err);
  g_free (expr);

  if (result == NULL)
    {
      cmacs_dbus_return_gerror (invocation, err);
      return;
    }
  g_dbus_method_invocation_return_value (
    invocation, g_variant_new ("(s)", result));
  g_free (result);
}

/* ── Raw-string variant ──────────────────────────────────────────────
 *
 * Like cmacs_dbus_eval_to_reply, but string results come back verbatim
 * (no prin1 quoting).  Used by the parity ifaces that surface raw text
 * such as buffer contents, shell output, or generated reports. */

gchar *
cmacs_dbus_build_elisp (const gchar  *elisp_template,
                        const gchar **args,
                        gint          n_args)
{
  GString *expr;
  const gchar *p = elisp_template;
  gint arg_index = 0;

  expr = g_string_new (NULL);
  while (*p != '\0')
    {
      if (p[0] == '%' && p[1] == 's' && arg_index < n_args)
        {
          gchar *escaped =
            cmacs_dbus_lisp_escape (args[arg_index] ? args[arg_index] : "");
          arg_index++;
          g_string_append (expr, escaped);
          g_free (escaped);
          p += 2;
        }
      else if (p[0] == '%' && p[1] == '%')
        {
          g_string_append_c (expr, '%');
          p += 2;
        }
      else
        {
          g_string_append_c (expr, *p);
          p++;
        }
    }
  return g_string_free (expr, FALSE);
}

void
cmacs_dbus_eval_to_reply_string (GDBusMethodInvocation *invocation,
                                 const gchar           *elisp_template,
                                 const gchar          **args,
                                 gint                   n_args)
{
  gchar *expr;
  gchar *result;
  GError *err = NULL;

  expr = cmacs_dbus_build_elisp (elisp_template, args, n_args);
  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);

  if (result == NULL)
    {
      cmacs_dbus_return_gerror (invocation, err);
      return;
    }
  g_dbus_method_invocation_return_value (
    invocation, g_variant_new ("(s)", result));
  g_free (result);
}

#endif /* HAVE_CMACS_GLIB */
