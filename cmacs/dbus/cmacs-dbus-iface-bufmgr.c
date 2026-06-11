/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-bufmgr.c --- BufferManager root iface (Phase 2).
 *
 * Provides org.cmacs.Editor1.BufferManager at /org/cmacs/Editor:
 *   List         () -> as     buffer names
 *   Find         (s name)     -> b
 *   Current      () -> s      current buffer name
 *   FilenameFor  (s name)     -> s   (or "" if no file)
 *   PointFor     (s name)     -> x
 *   ModifiedP    (s name)     -> b
 *   Kill         (s name)     -> b
 *   SaveCurrent  ()           -> b
 *
 * Methods route through cmacs_dispatch_eval; thin elisp wrappers
 * keep the typed surface readable without duplicating the elisp
 * dispatcher. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.BufferManager'>"
  "    <method name='List'>"
  "      <arg type='as' name='names' direction='out'/>"
  "    </method>"
  "    <method name='Find'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='exists' direction='out'/>"
  "    </method>"
  "    <method name='Current'>"
  "      <arg type='s' name='name' direction='out'/>"
  "    </method>"
  "    <method name='FilenameFor'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='filename' direction='out'/>"
  "    </method>"
  "    <method name='PointFor'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='x' name='point' direction='out'/>"
  "    </method>"
  "    <method name='ModifiedP'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='modified' direction='out'/>"
  "    </method>"
  "    <method name='Kill'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='killed' direction='out'/>"
  "    </method>"
  "    <method name='SaveCurrent'>"
  "      <arg type='b' name='saved' direction='out'/>"
  "    </method>"
  "    <method name='Create'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='created' direction='out'/>"
  "    </method>"
  "    <method name='Switch'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='switched' direction='out'/>"
  "    </method>"
  "    <method name='Save'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='saved' direction='out'/>"
  "    </method>"
  "    <signal name='BufferAdded'>"
  "      <arg type='s' name='name'/>"
  "    </signal>"
  "    <signal name='BufferRemoved'>"
  "      <arg type='s' name='name'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Helper: eval ELISP, return printed result.  On error, sets
   *error and returns NULL. */
static gchar *
eval_string (const gchar *elisp, GError **error)
{
  return cmacs_dispatch_eval (elisp, error);
}

/* Helper: eval and parse a printed string ("foo") -> "foo",
   nil -> "".  Caller g_free(). */
static gchar *
eval_string_unwrap (const gchar *elisp, GError **error)
{
  gchar *raw = eval_string (elisp, error);
  gchar *out;
  size_t len;

  if (raw == NULL)
    return NULL;

  if (g_strcmp0 (raw, "nil") == 0)
    {
      g_free (raw);
      return g_strdup ("");
    }

  len = strlen (raw);
  if (len >= 2 && raw[0] == '"' && raw[len - 1] == '"')
    {
      /* Strip outer quotes; un-escape \\ and \". */
      gchar *r = raw + 1, *w;
      out = g_malloc (len + 1);
      w = out;
      while (r < raw + len - 1)
        {
          if (*r == '\\' && (r[1] == '"' || r[1] == '\\'))
            *w++ = *++r;
          else
            *w++ = *r;
          r++;
        }
      *w = '\0';
      g_free (raw);
      return out;
    }
  return raw;  /* unquoted (number, symbol, etc.) */
}

static void
on_method_call (GDBusConnection       *conn,
                const gchar           *sender,
                const gchar           *object_path,
                const gchar           *iface_name,
                const gchar           *method_name,
                GVariant              *parameters,
                GDBusMethodInvocation *invocation,
                gpointer               user_data)
{
  (void) conn; (void) sender; (void) object_path;
  (void) iface_name; (void) user_data;

  if (g_strcmp0 (method_name, "List") == 0)
    {
      GError *err = NULL;
      /* Use |||  as separator: not a legal char in buffer-name and
         not subject to prin1 escaping. */
      gchar *result = cmacs_dispatch_eval (
        "(mapconcat #'buffer-name (buffer-list) \"|||\")", &err);
      GVariantBuilder builder;
      gchar **names;
      gsize i;

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }

      /* Strip outer "" quotes from prin1 output. */
      {
        size_t len = strlen (result);
        if (len >= 2 && result[0] == '"' && result[len - 1] == '"')
          {
            memmove (result, result + 1, len - 2);
            result[len - 2] = '\0';
          }
      }

      names = g_strsplit (result, "|||", -1);
      g_free (result);

      g_variant_builder_init (&builder, G_VARIANT_TYPE ("as"));
      for (i = 0; names[i] != NULL; i++)
        if (names[i][0] != '\0')
          g_variant_builder_add (&builder, "s", names[i]);
      g_strfreev (names);

      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(as)", &builder));
    }
  else if (g_strcmp0 (method_name, "Find") == 0)
    {
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean found;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf ("(if (get-buffer \"%s\") t nil)", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      found = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", found));
    }
  else if (g_strcmp0 (method_name, "Current") == 0)
    {
      GError *err = NULL;
      gchar *name = eval_string_unwrap ("(buffer-name (current-buffer))", &err);
      if (name == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(s)", name));
      g_free (name);
    }
  else if (g_strcmp0 (method_name, "FilenameFor") == 0)
    {
      const gchar *name;
      gchar *escaped, *elisp, *filename;
      GError *err = NULL;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\"))) "
        " (if b (or (buffer-file-name b) \"\") \"\"))", escaped);
      filename = eval_string_unwrap (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (filename == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(s)", filename));
      g_free (filename);
    }
  else if (g_strcmp0 (method_name, "PointFor") == 0)
    {
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gint64 point;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\"))) "
        " (if b (with-current-buffer b (point)) -1))", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      point = g_ascii_strtoll (result, NULL, 10);
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(x)", point));
    }
  else if (g_strcmp0 (method_name, "ModifiedP") == 0)
    {
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean modified;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\"))) "
        " (and b (buffer-modified-p b)))", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      modified = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", modified));
    }
  else if (g_strcmp0 (method_name, "Kill") == 0)
    {
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean killed;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\"))) (and b (kill-buffer b) t))",
        escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      killed = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", killed));
    }
  else if (g_strcmp0 (method_name, "SaveCurrent") == 0)
    {
      GError *err = NULL;
      gchar *result = cmacs_dispatch_eval (
        "(progn (save-buffer) t)", &err);
      gboolean ok;

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      ok = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", ok));
    }
  else if (g_strcmp0 (method_name, "Create") == 0)
    {
      /* MCP parity: create_buffer in cmacs-mcp-tools-buffer.c. */
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean ok;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(and (get-buffer-create \"%s\") t)", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      ok = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", ok));
    }
  else if (g_strcmp0 (method_name, "Switch") == 0)
    {
      /* MCP parity: switch_to_buffer in cmacs-mcp-tools-buffer.c. */
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean ok;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\")))"
        " (and b (progn (switch-to-buffer b) t)))", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      ok = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", ok));
    }
  else if (g_strcmp0 (method_name, "Save") == 0)
    {
      /* MCP parity: save_buffer in cmacs-mcp-tools-buffer.c. */
      const gchar *name;
      gchar *escaped, *elisp, *result;
      GError *err = NULL;
      gboolean ok;

      g_variant_get (parameters, "(&s)", &name);
      escaped = cmacs_dbus_lisp_escape (name);
      elisp = g_strdup_printf (
        "(let ((b (get-buffer \"%s\")))"
        " (and b (with-current-buffer b (save-buffer) t)))", escaped);
      result = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      g_free (escaped);

      if (result == NULL)
        {
          cmacs_dbus_return_gerror (invocation, err);
          return;
        }
      ok = g_strcmp0 (result, "t") == 0;
      g_free (result);
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(b)", ok));
    }
}

static const GDBusInterfaceVTable iface_vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_bufmgr_register (GDBusConnection *conn,
                                   const gchar     *path,
                                   GError         **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL)
        return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0],
    &iface_vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_bufmgr_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0)
    g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    {
      g_dbus_node_info_unref (iface_info);
      iface_info = NULL;
    }
}

#endif /* HAVE_CMACS_GLIB */
