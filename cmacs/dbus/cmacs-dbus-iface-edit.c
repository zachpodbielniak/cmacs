/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-edit.c --- buffer-content editing via D-Bus.
 *
 * org.cmacs.Editor1.Edit
 *
 * MCP parity: mirrors get_buffer_content / set_buffer_content /
 * edit_buffer / replace_in_buffer / search_buffer / goto_line in
 * cmacs/mcp/cmacs-mcp-tools-edit.c and -buffer.c (sync discipline:
 * adding a tool there requires a matching method here, and vice
 * versa).  The elisp bodies are identical to the MCP handlers'. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Edit'>"
  "    <method name='GetContent'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='content' direction='out'/>"
  "    </method>"
  "    <method name='SetContent'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='content' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='EditExact'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='old_string' direction='in'/>"
  "      <arg type='s' name='new_string' direction='in'/>"
  "      <arg type='b' name='replace_all' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Replace'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='regexp' direction='in'/>"
  "      <arg type='s' name='replacement' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Search'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='regexp' direction='in'/>"
  "      <arg type='s' name='matches' direction='out'/>"
  "    </method>"
  "    <method name='GotoLine'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='i' name='line' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='GetOrgContent'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='match' direction='in'/>"
  "      <arg type='i' name='max_depth' direction='in'/>"
  "      <arg type='b' name='include_body' direction='in'/>"
  "      <arg type='b' name='include_properties' direction='in'/>"
  "      <arg type='s' name='json' direction='out'/>"
  "    </method>"
  "    <method name='InsertOrg'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='text' direction='in'/>"
  "      <arg type='a{ss}' name='options' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
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

  /* Served from the capability table when the method has a row in
     cmacs-dbus-forward-table.h; the bodies below are the methods
     that have none.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  if (g_strcmp0 (m, "SetContent") == 0)
    {
      const gchar *buf, *content;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &buf, &content);
      args[0] = buf; args[1] = content;
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer (get-buffer-create \"%s\")"
        "  (erase-buffer)"
        "  (insert \"%s\")"
        "  (format \"%%d chars\" (buffer-size)))",
        args, 2);
    }
  else if (g_strcmp0 (m, "InsertOrg") == 0)
    {
      /* MCP parity: insert_org in cmacs-mcp-tools-edit.c (both call
         cmacs_dispatch_org_insert).  OPTIONS is an a{ss} dict so the
         surface can grow without signature breaks; unknown keys are
         ignored.  Recognized: heading, position, wrap, lang, drawer,
         child, todo, tags, create ("t"/"true"), timestamp. */
      const gchar *buf, *text;
      GVariantIter *iter;
      const gchar *key, *value;
      gchar *heading = NULL, *position = NULL, *wrap = NULL;
      gchar *lang = NULL, *drawer = NULL, *child = NULL;
      gchar *todo = NULL, *tags = NULL;
      gboolean create = FALSE, timestamp = FALSE;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&sa{ss})", &buf, &text, &iter);
      /* iter_loop borrows; copy --- the values must outlive it. */
      while (g_variant_iter_loop (iter, "{&s&s}", &key, &value))
        {
          if (g_strcmp0 (key, "heading") == 0)
            { g_free (heading); heading = g_strdup (value); }
          else if (g_strcmp0 (key, "position") == 0)
            { g_free (position); position = g_strdup (value); }
          else if (g_strcmp0 (key, "wrap") == 0)
            { g_free (wrap); wrap = g_strdup (value); }
          else if (g_strcmp0 (key, "lang") == 0)
            { g_free (lang); lang = g_strdup (value); }
          else if (g_strcmp0 (key, "drawer") == 0)
            { g_free (drawer); drawer = g_strdup (value); }
          else if (g_strcmp0 (key, "child") == 0)
            { g_free (child); child = g_strdup (value); }
          else if (g_strcmp0 (key, "todo") == 0)
            { g_free (todo); todo = g_strdup (value); }
          else if (g_strcmp0 (key, "tags") == 0)
            { g_free (tags); tags = g_strdup (value); }
          else if (g_strcmp0 (key, "create") == 0)
            create = g_strcmp0 (value, "t") == 0
                  || g_strcmp0 (value, "true") == 0;
          else if (g_strcmp0 (key, "timestamp") == 0)
            timestamp = g_strcmp0 (value, "t") == 0
                     || g_strcmp0 (value, "true") == 0;
        }
      g_variant_iter_free (iter);

      result = cmacs_dispatch_org_insert (buf, text, heading, position,
                                          wrap, lang, drawer, child,
                                          todo, tags, create, timestamp,
                                          &err);
      g_free (heading);
      g_free (position);
      g_free (wrap);
      g_free (lang);
      g_free (drawer);
      g_free (child);
      g_free (todo);
      g_free (tags);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(s)", result));
      g_free (result);
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_edit_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_edit_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
