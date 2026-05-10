/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-search-provider.c --- org.gnome.Shell.SearchProvider2
 *
 * Lets users type queries in the GNOME shell overview and see hits
 * from open buffers / recentf / bookmarks.  Pressing Enter raises
 * cmacs and switches to the chosen result.
 *
 * Spec: https://developer.gnome.org/documentation/tutorials/search-provider.html
 *
 * Pair with /usr/share/gnome-shell/search-providers/cmacs-search-provider.ini
 * which is shipped at install time.  GNOME shell auto-discovers any
 * .ini in that directory at session start. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node><interface name='org.gnome.Shell.SearchProvider2'>"
  "  <method name='GetInitialResultSet'>"
  "    <arg type='as' name='terms' direction='in'/>"
  "    <arg type='as' name='results' direction='out'/></method>"
  "  <method name='GetSubsearchResultSet'>"
  "    <arg type='as' name='previous_results' direction='in'/>"
  "    <arg type='as' name='terms' direction='in'/>"
  "    <arg type='as' name='results' direction='out'/></method>"
  "  <method name='GetResultMetas'>"
  "    <arg type='as' name='identifiers' direction='in'/>"
  "    <arg type='aa{sv}' name='metas' direction='out'/></method>"
  "  <method name='ActivateResult'>"
  "    <arg type='s' name='identifier' direction='in'/>"
  "    <arg type='as' name='terms' direction='in'/>"
  "    <arg type='u' name='timestamp' direction='in'/></method>"
  "  <method name='LaunchSearch'>"
  "    <arg type='as' name='terms' direction='in'/>"
  "    <arg type='u' name='timestamp' direction='in'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Build a Lisp-friendly OR-pattern from terms array.  Returns
   "term1\\|term2\\|term3" — caller g_free()s. */
static gchar *
join_terms (GVariantIter *it)
{
  GString *s = g_string_new (NULL);
  const gchar *term;
  gboolean first = TRUE;
  while (g_variant_iter_next (it, "&s", &term))
    {
      gchar *escaped = cmacs_dbus_lisp_escape (term);
      if (!first) g_string_append (s, "\\\\|");
      g_string_append (s, escaped);
      g_free (escaped);
      first = FALSE;
    }
  return g_string_free (s, FALSE);
}

static void
do_search (const gchar *pattern, GDBusMethodInvocation *iv)
{
  GError *err = NULL;
  gchar *expr, *result;
  GVariantBuilder b;
  gchar **ids;
  gsize i;

  /* Note: no `;'-comments in this expression -- the elisp reader
     would otherwise eat the rest of the expression because we
     concatenate string fragments with no newlines. */
  expr = g_strdup_printf (
    "(let ((re \"%s\") out)"
    " (dolist (b (buffer-list))"
    "  (let ((n (buffer-name b)))"
    "   (when (and (> (length n) 0)"
    "              (not (eq (aref n 0) ?\\s))"
    "              (string-match-p re n))"
    "    (push (concat \"buf:\" n) out))))"
    " (when (boundp 'recentf-list)"
    "  (dolist (f recentf-list)"
    "    (when (string-match-p re f)"
    "      (push (concat \"file:\" f) out))))"
    " (mapconcat #'identity"
    "  (let ((lst (nreverse out)))"
    "   (if (> (length lst) 20) (cl-subseq lst 0 20) lst))"
    "  \"|||\"))",
    pattern);

  result = cmacs_dispatch_eval (expr, &err);
  g_free (expr);

  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }

  /* Strip prin1 quotes. */
  {
    size_t len = strlen (result);
    if (len >= 2 && result[0] == '"' && result[len - 1] == '"')
      {
        memmove (result, result + 1, len - 2);
        result[len - 2] = '\0';
      }
  }

  ids = g_strsplit (result, "|||", -1);
  g_free (result);

  g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
  for (i = 0; ids[i] != NULL; i++)
    if (ids[i][0] != '\0')
      g_variant_builder_add (&b, "s", ids[i]);
  g_strfreev (ids);

  g_dbus_method_invocation_return_value (
    iv, g_variant_new ("(as)", &b));
}

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "GetInitialResultSet") == 0)
    {
      GVariantIter *it;
      gchar *pat;
      g_variant_get (p, "(as)", &it);
      pat = join_terms (it);
      g_variant_iter_free (it);
      do_search (pat, iv);
      g_free (pat);
    }
  else if (g_strcmp0 (m, "GetSubsearchResultSet") == 0)
    {
      GVariantIter *prev_it, *terms_it;
      gchar *pat;
      g_variant_get (p, "(asas)", &prev_it, &terms_it);
      g_variant_iter_free (prev_it);
      pat = join_terms (terms_it);
      g_variant_iter_free (terms_it);
      do_search (pat, iv);
      g_free (pat);
    }
  else if (g_strcmp0 (m, "GetResultMetas") == 0)
    {
      GVariantIter *it;
      const gchar *id;
      GVariantBuilder root;

      g_variant_get (p, "(as)", &it);
      g_variant_builder_init (&root, G_VARIANT_TYPE ("aa{sv}"));
      while (g_variant_iter_next (it, "&s", &id))
        {
          GVariantBuilder meta;
          const gchar *display = id;
          if (g_str_has_prefix (id, "buf:")) display = id + 4;
          else if (g_str_has_prefix (id, "file:")) display = id + 5;
          g_variant_builder_init (&meta, G_VARIANT_TYPE ("a{sv}"));
          g_variant_builder_add (&meta, "{sv}", "id",
                                 g_variant_new_string (id));
          g_variant_builder_add (&meta, "{sv}", "name",
                                 g_variant_new_string (display));
          g_variant_builder_add (&meta, "{sv}", "gicon",
                                 g_variant_new_string ("text-editor"));
          g_variant_builder_add_value (&root, g_variant_builder_end (&meta));
        }
      g_variant_iter_free (it);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(aa{sv})", &root));
    }
  else if (g_strcmp0 (m, "ActivateResult") == 0)
    {
      const gchar *id;
      gchar *escaped, *expr, *r;
      g_variant_get (p, "(&sasu)", &id, NULL, NULL);
      escaped = cmacs_dbus_lisp_escape (id);
      if (g_str_has_prefix (id, "buf:"))
        expr = g_strdup_printf (
          "(progn (switch-to-buffer \"%s\")"
          "       (raise-frame (selected-frame)) t)", escaped + 4);
      else if (g_str_has_prefix (id, "file:"))
        expr = g_strdup_printf (
          "(progn (find-file \"%s\")"
          "       (raise-frame (selected-frame)) t)", escaped + 5);
      else
        expr = g_strdup ("t");
      r = cmacs_dispatch_eval (expr, &err);
      g_free (expr); g_free (escaped);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
  else if (g_strcmp0 (m, "LaunchSearch") == 0)
    {
      /* Open *Help* with grep-occur on the terms; activates cmacs. */
      gchar *r = cmacs_dispatch_eval (
        "(progn (raise-frame (selected-frame)) t)", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_search_provider_register (GDBusConnection *conn,
                                      const gchar *path,
                                      GError **error)
{
  if (iface_info == NULL) {
    iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
    if (iface_info == NULL) return 0;
  }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_search_provider_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
