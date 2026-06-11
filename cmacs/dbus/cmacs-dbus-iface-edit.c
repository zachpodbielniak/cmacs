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
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "GetContent") == 0)
    {
      const gchar *buf;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &buf);
      args[0] = buf;
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer \"%s\""
        "  (buffer-substring-no-properties (point-min) (point-max)))",
        args, 1);
    }
  else if (g_strcmp0 (m, "SetContent") == 0)
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
  else if (g_strcmp0 (m, "EditExact") == 0)
    {
      const gchar *buf, *old_s, *new_s;
      gboolean all;
      const gchar *args[4];
      g_variant_get (p, "(&s&s&sb)", &buf, &old_s, &new_s, &all);
      args[0] = buf; args[1] = old_s; args[2] = new_s;
      args[3] = all ? "t" : "nil";
      /* args[3] passes through lisp-escape unchanged ("t"/"nil"). */
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer \"%s\""
        "  (let ((old \"%s\") (new \"%s\") (all %s)"
        "        (case-fold-search nil) (cnt 0))"
        "    (save-excursion"
        "      (goto-char (point-min))"
        "      (while (search-forward old nil t) (setq cnt (1+ cnt))))"
        "    (cond"
        "     ((= cnt 0) (error \"old_string not found in buffer\"))"
        "     ((and (> cnt 1) (not all))"
        "      (error \"old_string matches %%d times; pass replace_all\" cnt))"
        "     (t (save-excursion"
        "          (goto-char (point-min))"
        "          (let ((m 0))"
        "            (while (and (search-forward old nil t)"
        "                        (or all (= m 0)))"
        "              (replace-match new t t)"
        "              (setq m (1+ m)))"
        "            (format \"replaced %%d occurrence(s)\" m)))))))",
        args, 4);
    }
  else if (g_strcmp0 (m, "Replace") == 0)
    {
      const gchar *buf, *re, *rep;
      const gchar *args[3];
      g_variant_get (p, "(&s&s&s)", &buf, &re, &rep);
      args[0] = buf; args[1] = re; args[2] = rep;
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer \"%s\""
        "  (save-excursion"
        "    (goto-char (point-min))"
        "    (let ((c 0))"
        "      (while (re-search-forward \"%s\" nil t)"
        "        (replace-match \"%s\" t nil) (setq c (1+ c)))"
        "      (format \"replaced %%d match(es)\" c))))",
        args, 3);
    }
  else if (g_strcmp0 (m, "Search") == 0)
    {
      const gchar *buf, *re;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &buf, &re);
      args[0] = buf; args[1] = re;
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer \"%s\""
        "  (save-excursion"
        "    (goto-char (point-min))"
        "    (let ((out '()) (n 0))"
        "      (while (and (< n 200) (re-search-forward \"%s\" nil t))"
        "        (push (format \"%%d: %%s\" (line-number-at-pos)"
        "                      (buffer-substring-no-properties"
        "                       (line-beginning-position)"
        "                       (line-end-position)))"
        "              out)"
        "        (setq n (1+ n))"
        "        (forward-line 1))"
        "      (if out (mapconcat #'identity (nreverse out) \"\\n\")"
        "        \"(no matches)\"))))",
        args, 2);
    }
  else if (g_strcmp0 (m, "GotoLine") == 0)
    {
      const gchar *buf;
      gint line;
      const gchar *args[2];
      gchar line_str[32];
      g_variant_get (p, "(&si)", &buf, &line);
      g_snprintf (line_str, sizeof line_str, "%d", line);
      args[0] = buf; args[1] = line_str;
      cmacs_dbus_eval_to_reply_string (iv,
        "(with-current-buffer \"%s\""
        "  (goto-char (point-min))"
        "  (forward-line (1- %s))"
        "  (let ((w (get-buffer-window (current-buffer) t)))"
        "    (when w (set-window-point w (point))))"
        "  (format \"line %%d at point %%d\""
        "          (line-number-at-pos) (point)))",
        args, 2);
    }
  else if (g_strcmp0 (m, "GetOrgContent") == 0)
    {
      /* MCP parity: get_org_content in cmacs-mcp-tools-edit.c (both
         call cmacs_dispatch_org_content). */
      const gchar *buf, *match;
      gint max_depth;
      gboolean include_body, include_props;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&sibb)", &buf, &match, &max_depth,
                     &include_body, &include_props);
      result = cmacs_dispatch_org_content (buf, match, max_depth,
                                           include_body, include_props,
                                           &err);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(s)", result));
      g_free (result);
    }
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
