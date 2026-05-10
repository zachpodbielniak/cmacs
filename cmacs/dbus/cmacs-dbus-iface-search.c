/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-search.c --- search/replace/occur via D-Bus.
 * Mirrors cmacsgi's `search', `replace', and `occur' subcommands. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Search'>"
  "    <method name='Search'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='hits' direction='out'/>"
  "    </method>"
  "    <method name='Replace'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='replacement' direction='in'/>"
  "      <arg type='s' name='count' direction='out'/>"
  "    </method>"
  "    <method name='Occur'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='matches' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Search") == 0)
    {
      const gchar *pat;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &pat);
      args[0] = pat;
      cmacs_dbus_eval_to_reply (iv,
        "(save-excursion"
        " (goto-char (point-min))"
        " (let ((c 0))"
        "  (while (re-search-forward \"%s\" nil t) (cl-incf c))"
        "  (format \"%%d match(es)\" c)))",
        args, 1);
    }
  else if (g_strcmp0 (m, "Replace") == 0)
    {
      const gchar *pat, *rep;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &pat, &rep);
      args[0] = pat; args[1] = rep;
      cmacs_dbus_eval_to_reply (iv,
        "(save-excursion"
        " (goto-char (point-min))"
        " (let ((c 0))"
        "  (while (re-search-forward \"%s\" nil t)"
        "    (replace-match \"%s\" t nil) (cl-incf c))"
        "  (format \"%%d replacement(s)\" c)))",
        args, 2);
    }
  else if (g_strcmp0 (m, "Occur") == 0)
    {
      const gchar *pat;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &pat);
      args[0] = pat;
      cmacs_dbus_eval_to_reply (iv,
        "(save-excursion"
        " (goto-char (point-min))"
        " (let (out)"
        "  (while (re-search-forward \"%s\" nil t)"
        "    (push (format \"%%d:%%s\" (line-number-at-pos)"
        "                 (buffer-substring-no-properties"
        "                  (line-beginning-position)"
        "                  (line-end-position))) out)"
        "    (forward-line 1))"
        "  (mapconcat #'identity (nreverse out) \"\\n\")))",
        args, 1);
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_search_register (GDBusConnection *conn, const gchar *path,
                                   GError **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_search_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
