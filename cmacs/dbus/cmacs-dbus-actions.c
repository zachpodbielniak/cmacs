/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-actions.c --- org.gtk.Actions
 *
 * Typed action group spec from GApplication / GAction.  Lets desktop
 * shells (GNOME quicklists, KRunner, Plasma applets) discover and
 * invoke arbitrary cmacs commands.
 *
 * Phase 4 implements a curated action set; Phase 5 may extend with
 * dynamic "every interactive defun" enumeration if there's demand. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.gtk.Actions'>"
  "  <method name='List'>"
  "    <arg type='as' name='actions' direction='out'/></method>"
  "  <method name='Describe'>"
  "    <arg type='s' name='action_name' direction='in'/>"
  "    <arg type='(bgav)' name='description' direction='out'/></method>"
  "  <method name='DescribeAll'>"
  "    <arg type='a{s(bgav)}' name='descriptions' direction='out'/></method>"
  "  <method name='Activate'>"
  "    <arg type='s' name='action_name' direction='in'/>"
  "    <arg type='av' name='parameter' direction='in'/>"
  "    <arg type='a{sv}' name='platform_data' direction='in'/></method>"
  "  <method name='SetState'>"
  "    <arg type='s' name='action_name' direction='in'/>"
  "    <arg type='v' name='value' direction='in'/>"
  "    <arg type='a{sv}' name='platform_data' direction='in'/></method>"
  "  <signal name='Changed'>"
  "    <arg type='as' name='removals'/>"
  "    <arg type='a{sb}' name='enable_changes'/>"
  "    <arg type='a{sv}' name='state_changes'/>"
  "    <arg type='a{s(bgav)}' name='additions'/></signal>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Curated action allowlist: name -> elisp-form-evaluable-name. */
static const gchar *action_names[] = {
  "save-buffers-kill-emacs",
  "save-buffer",
  "find-file",
  "switch-to-buffer",
  "next-buffer",
  "previous-buffer",
  "kill-buffer",
  "split-window-below",
  "split-window-right",
  "delete-window",
  "delete-other-windows",
  "compile",
  "next-error",
  "previous-error",
  "isearch-forward",
  "isearch-backward",
  "query-replace",
  "goto-line",
  "magit-status",
  "dired",
  NULL
};

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      GVariantBuilder b;
      gint idx;
      g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
      for (idx = 0; action_names[idx] != NULL; idx++)
        g_variant_builder_add (&b, "s", action_names[idx]);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(as)", &b));
    }
  else if (g_strcmp0 (m, "Describe") == 0)
    {
      /* Always describe as: enabled=true, no parameter type, no state. */
      GVariantBuilder state_b;
      g_variant_builder_init (&state_b, G_VARIANT_TYPE ("av"));
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("((bgav))", TRUE, "", &state_b));
    }
  else if (g_strcmp0 (m, "DescribeAll") == 0)
    {
      GVariantBuilder root;
      gint idx;
      g_variant_builder_init (&root, G_VARIANT_TYPE ("a{s(bgav)}"));
      for (idx = 0; action_names[idx] != NULL; idx++)
        {
          GVariantBuilder state_b;
          g_variant_builder_init (&state_b, G_VARIANT_TYPE ("av"));
          g_variant_builder_add (&root, "{s(bgav)}",
                                 action_names[idx],
                                 TRUE, "", &state_b);
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(a{s(bgav)})", &root));
    }
  else if (g_strcmp0 (m, "Activate") == 0)
    {
      const gchar *name;
      gchar *escaped, *expr, *r;
      g_variant_get (p, "(&sava{sv})", &name, NULL, NULL);
      escaped = cmacs_dbus_lisp_escape (name);
      expr = g_strdup_printf (
        "(let ((cmd (intern \"%s\")))"
        " (cond ((commandp cmd) (call-interactively cmd))"
        "       ((fboundp cmd) (funcall cmd))"
        "       (t (error \"unknown action: %%s\" \"%s\"))) t)",
        escaped, escaped);
      r = cmacs_dispatch_eval (expr, &err);
      g_free (expr); g_free (escaped);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_free (r);
      g_dbus_method_invocation_return_value (iv, NULL);
    }
  else if (g_strcmp0 (m, "SetState") == 0)
    {
      /* Stateless actions only in Phase 4 -- no-op, no error. */
      g_dbus_method_invocation_return_value (iv, NULL);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_actions_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_actions_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
