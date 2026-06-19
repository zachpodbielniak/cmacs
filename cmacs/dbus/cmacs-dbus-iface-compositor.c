/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-compositor.c --- Wayland compositor control.
 *
 * org.cmacs.Editor1.Compositor at /org/cmacs/Editor.  Replaces the
 * Gowl* method block previously on org.cmacs.Editor1; method names
 * lose the Gowl prefix because the iface name now carries that
 * context.  Available only when --with-cmacs-gowl is enabled.
 *
 * All methods bypass the elisp eval round-trip and call directly
 * into cmacs_dispatch_gowl_* for performance. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#ifdef HAVE_CMACS_GOWL

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Compositor'>"
  "  <method name='ListClients'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FocusedClient'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Spawn'>"
  "    <arg type='s' name='command' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='AddKeybind'>"
  "    <arg type='s' name='key' direction='in'/>"
  "    <arg type='i' name='action' direction='in'/>"
  "    <arg type='s' name='arg' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ListKeybinds'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='AddRule'>"
  "    <arg type='s' name='app_id' direction='in'/>"
  "    <arg type='s' name='title' direction='in'/>"
  "    <arg type='u' name='tags' direction='in'/>"
  "    <arg type='b' name='floating' direction='in'/>"
  "    <arg type='i' name='monitor' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetMfact'>"
  "    <arg type='d' name='mfact' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetNmaster'>"
  "    <arg type='i' name='n' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ViewTags'>"
  "    <arg type='u' name='tagmask' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Lock'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Unlock'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetScreensaverWallpaper'>"
  "    <arg type='s' name='config' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='StopScreensaverWallpaper'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ListScreensaverConfigs'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ReloadConfig'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ConfigGet'>"
  "    <arg type='s' name='property' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FindClient'>"
  "    <arg type='s' name='pattern' direction='in'/>"
  "    <arg type='s' name='by' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FocusClient'>"
  "    <arg type='s' name='pattern' direction='in'/>"
  "    <arg type='s' name='by' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='CloseClient'>"
  "    <arg type='s' name='pattern' direction='in'/>"
  "    <arg type='s' name='by' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetClientGeometry'>"
  "    <arg type='s' name='pattern' direction='in'/>"
  "    <arg type='s' name='by' direction='in'/>"
  "    <arg type='i' name='x' direction='in'/>"
  "    <arg type='i' name='y' direction='in'/>"
  "    <arg type='i' name='width' direction='in'/>"
  "    <arg type='i' name='height' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetLayout'>"
  "    <arg type='s' name='layout' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='WorkspaceList'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='WorkspaceSwitch'>"
  "    <arg type='i' name='id' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='Screenshot'>"
  "    <arg type='s' name='mode' direction='in'/>"
  "    <arg type='s' name='client' direction='in'/>"
  "    <arg type='s' name='by' direction='in'/>"
  "    <arg type='s' name='file' direction='in'/>"
  "    <arg type='s' name='path' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

/* Validate a "by" selector, defaulting to app-id (mirrors
 * gowl_by_field in cmacs-mcp-tools-gowl.c).  The returned value is
 * spliced into elisp as a quoted symbol, so it MUST come from this
 * whitelist. */
static const gchar *
by_field (const gchar *by)
{
  if (by != NULL && g_strcmp0 (by, "title") == 0)
    return "title";
  return "app-id";
}

#define RETURN_STR(call_)                                              \
  do {                                                                 \
    GError *err = NULL;                                                \
    gchar *result = (call_);                                           \
    if (result != NULL) {                                              \
      g_dbus_method_invocation_return_value (                          \
        iv, g_variant_new ("(s)", result));                            \
      g_free (result);                                                 \
    } else                                                             \
      cmacs_dbus_return_gerror (iv, err);                              \
    return;                                                            \
  } while (0)

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "ListClients") == 0)
    RETURN_STR (cmacs_dispatch_gowl_list_clients (&err));
  else if (g_strcmp0 (m, "FocusedClient") == 0)
    RETURN_STR (cmacs_dispatch_gowl_focused_client (&err));
  else if (g_strcmp0 (m, "Spawn") == 0)
    {
      const gchar *cmd;
      g_variant_get (p, "(&s)", &cmd);
      RETURN_STR (cmacs_dispatch_gowl_spawn (cmd, &err));
    }
  else if (g_strcmp0 (m, "AddKeybind") == 0)
    {
      const gchar *key, *arg;
      gint action;
      g_variant_get (p, "(&si&s)", &key, &action, &arg);
      RETURN_STR (cmacs_dispatch_gowl_add_keybind (key, action, arg, &err));
    }
  else if (g_strcmp0 (m, "ListKeybinds") == 0)
    RETURN_STR (cmacs_dispatch_gowl_list_keybinds (&err));
  else if (g_strcmp0 (m, "AddRule") == 0)
    {
      const gchar *app_id, *title;
      guint32 tags;
      gboolean floating;
      gint monitor;
      g_variant_get (p, "(&s&subi)", &app_id, &title, &tags,
                     &floating, &monitor);
      RETURN_STR (cmacs_dispatch_gowl_add_rule (app_id, title, tags,
                                                 floating, monitor, &err));
    }
  else if (g_strcmp0 (m, "SetMfact") == 0)
    {
      gdouble mfact;
      g_variant_get (p, "(d)", &mfact);
      RETURN_STR (cmacs_dispatch_gowl_set_mfact (mfact, &err));
    }
  else if (g_strcmp0 (m, "SetNmaster") == 0)
    {
      gint n;
      g_variant_get (p, "(i)", &n);
      RETURN_STR (cmacs_dispatch_gowl_set_nmaster (n, &err));
    }
  else if (g_strcmp0 (m, "ViewTags") == 0)
    {
      guint32 tagmask;
      g_variant_get (p, "(u)", &tagmask);
      RETURN_STR (cmacs_dispatch_gowl_view_tags (tagmask, &err));
    }
  else if (g_strcmp0 (m, "Lock") == 0)
    RETURN_STR (cmacs_dispatch_gowl_lock (&err));
  else if (g_strcmp0 (m, "Unlock") == 0)
    RETURN_STR (cmacs_dispatch_gowl_unlock (&err));
  else if (g_strcmp0 (m, "SetScreensaverWallpaper") == 0)
    {
      const gchar *config;
      g_variant_get (p, "(&s)", &config);
      RETURN_STR (cmacs_dispatch_screensaver_set_wallpaper (config, &err));
    }
  else if (g_strcmp0 (m, "StopScreensaverWallpaper") == 0)
    RETURN_STR (cmacs_dispatch_screensaver_stop_wallpaper (&err));
  else if (g_strcmp0 (m, "ListScreensaverConfigs") == 0)
    RETURN_STR (cmacs_dispatch_screensaver_list_configs (&err));
  else if (g_strcmp0 (m, "ReloadConfig") == 0)
    RETURN_STR (cmacs_dispatch_gowl_reload_config (&err));
  else if (g_strcmp0 (m, "ConfigGet") == 0)
    {
      const gchar *property;
      g_variant_get (p, "(&s)", &property);
      RETURN_STR (cmacs_dispatch_gowl_config_get (property, &err));
    }
  else if (g_strcmp0 (m, "FindClient") == 0)
    {
      const gchar *pattern, *by;
      g_variant_get (p, "(&s&s)", &pattern, &by);
      RETURN_STR (cmacs_dispatch_gowl_find_client (pattern, by, &err));
    }
  else if (g_strcmp0 (m, "FocusClient") == 0)
    {
      const gchar *pattern, *by;
      const gchar *args[1];
      gchar *tmpl;
      g_variant_get (p, "(&s&s)", &pattern, &by);
      args[0] = pattern;
      tmpl = g_strdup_printf (
        "(let ((c (gowl-find-client \"%%s\" '%s)))"
        "  (if c (progn (gowl-focus-client c) \"focused\")"
        "    (error \"no client matching pattern\")))",
        by_field (by));
      cmacs_dbus_eval_to_reply_string (iv, tmpl, args, 1);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "CloseClient") == 0)
    {
      const gchar *pattern, *by;
      const gchar *args[1];
      gchar *tmpl;
      g_variant_get (p, "(&s&s)", &pattern, &by);
      args[0] = pattern;
      tmpl = g_strdup_printf (
        "(let ((c (gowl-find-client \"%%s\" '%s)))"
        "  (if c (progn (gowl-close-client c) \"closed\")"
        "    (error \"no client matching pattern\")))",
        by_field (by));
      cmacs_dbus_eval_to_reply_string (iv, tmpl, args, 1);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "SetClientGeometry") == 0)
    {
      const gchar *pattern, *by;
      gint x, y, w, h;
      const gchar *args[1];
      gchar *tmpl;
      g_variant_get (p, "(&s&siiii)", &pattern, &by, &x, &y, &w, &h);
      args[0] = pattern;
      tmpl = g_strdup_printf (
        "(let ((c (gowl-find-client \"%%s\" '%s)))"
        "  (if c (progn (gowl-client-set-geometry c %d %d %d %d)"
        "               \"geometry set\")"
        "    (error \"no client matching pattern\")))",
        by_field (by), x, y, w, h);
      cmacs_dbus_eval_to_reply_string (iv, tmpl, args, 1);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "SetLayout") == 0)
    {
      const gchar *layout;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &layout);
      args[0] = layout;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (gowl-set-layout \"%s\") \"layout set\")", args, 1);
    }
  else if (g_strcmp0 (m, "WorkspaceList") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(prin1-to-string (gowl-workspace-list))", NULL, 0);
  else if (g_strcmp0 (m, "WorkspaceSwitch") == 0)
    {
      gint id;
      gchar *tmpl;
      g_variant_get (p, "(i)", &id);
      tmpl = g_strdup_printf (
        "(if (gowl-workspace-switch %d) \"switched\""
        "  \"workspace unchanged or unknown id\")", id);
      cmacs_dbus_eval_to_reply_string (iv, tmpl, NULL, 0);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "Screenshot") == 0)
    {
      const gchar *mode, *client, *by, *file;
      g_variant_get (p, "(&s&s&s&s)", &mode, &client, &by, &file);
      if (g_strcmp0 (mode, "desktop") != 0
          && g_strcmp0 (mode, "window") != 0
          && g_strcmp0 (mode, "all") != 0)
        mode = "desktop";
      if (client != NULL && *client != '\0')
        {
          const gchar *args[3];
          gchar *tmpl;
          args[0] = client; args[1] = file; args[2] = file;
          tmpl = g_strdup_printf (
            "(let ((c (gowl-find-client \"%%s\" '%s)))"
            "  (if c (let ((shot (gowl-screenshot-client c)))"
            "          (if shot"
            "              (progn (apply #'gowl-screenshot-save-png"
            "                            (append shot (list \"%%s\")))"
            "                     \"%%s\")"
            "            (error \"screenshot capture produced no image\")))"
            "    (error \"no client matching pattern\")))",
            by_field (by));
          cmacs_dbus_eval_to_reply_string (iv, tmpl, args, 3);
          g_free (tmpl);
        }
      else
        {
          const gchar *args[2];
          gchar *tmpl;
          args[0] = file; args[1] = file;
          tmpl = g_strdup_printf (
            "(progn (gowl-screenshot '%s \"%%s\" t) \"%%s\")", mode);
          cmacs_dbus_eval_to_reply_string (iv, tmpl, args, 2);
          g_free (tmpl);
        }
    }
}

#undef RETURN_STR

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_compositor_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_compositor_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GOWL */
#endif /* HAVE_CMACS_GLIB */
