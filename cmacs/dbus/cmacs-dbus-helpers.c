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

#include <glib.h>
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

#endif /* HAVE_CMACS_GLIB */
