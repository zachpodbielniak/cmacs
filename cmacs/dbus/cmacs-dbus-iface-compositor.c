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
 * Methods a registry tool provides -- the client list, focus, close,
 * geometry, layout, workspaces, the screensaver -- are rows of
 * cmacs-dbus-forward-table.h and have no body here: they are served
 * by the tool, redaction included (cmacs-dbus-forward.c).  What is
 * left below has no tool: it calls into cmacs_dispatch_gowl_*, which
 * takes the compositor lock itself, or evaluates one fixed form. */

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
  /* AddKeybindFull rather than a fourth argument on AddKeybind: a
     D-Bus signature is part of the contract, and emacsctl, podomation
     rules and user scripts already call the (sis) form.  An empty
     `desc' means no description. */
  "  <method name='AddKeybindFull'>"
  "    <arg type='s' name='key' direction='in'/>"
  "    <arg type='i' name='action' direction='in'/>"
  "    <arg type='s' name='arg' direction='in'/>"
  "    <arg type='s' name='desc' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='RunKeybind'>"
  "    <arg type='s' name='key' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ListKeybinds'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* A gowl macro by name, with arguments.  Loads the opt-in macro
     module on first use, as every cmacs-gowl-macro- function does. */
  "  <method name='RunMacro'>"
  "    <arg type='s' name='name' direction='in'/>"
  "    <arg type='as' name='args' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* Input broadcasting (multiboxing): status, list, on, off, toggle or
     panic.  Loads the opt-in broadcast module on first use. */
  "  <method name='Broadcast'>"
  "    <arg type='s' name='verb' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* The floating desktop: VERB is the floatdesk module's command
     without its prefix (toggle, on, off, default, status, minimize,
     restore, maximize, snap, dock-*); ARGS its one-line arguments. */
  "  <method name='Floatdesk'>"
  "    <arg type='s' name='verb' direction='in'/>"
  "    <arg type='s' name='args' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* Hotkeys (AutoHotkey): VERB is the hotkey module's command without
     its prefix (status, list, add, remove, enable, disable, toggle,
     fire, suspend, mode, send, send-text, call, ...); ARGS its one-line
     arguments.  Loads the opt-in hotkey module on first use. */
  "  <method name='Hotkey'>"
  "    <arg type='s' name='verb' direction='in'/>"
  "    <arg type='s' name='args' direction='in'/>"
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
  "  <method name='ScreensaverStatus'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ScreensaverRestart'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ScreensaverPause'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ScreensaverResume'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='ScreensaverSetFps'>"
  "    <arg type='i' name='fps' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SetKeyMode'>"
  "    <arg type='s' name='mode' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='KeyMode'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='SwitchKeyboardLayout'>"
  "    <arg type='s' name='which' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='KeyboardLayout'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FocusDirection'>"
  "    <arg type='s' name='direction' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FocusUrgent'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='FocusLast'>"
  "    <arg type='s' name='result' direction='out'/></method>"
  "  <method name='OutputPower'>"
  "    <arg type='s' name='mode' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* The compositor's pointer confinement: "on", "off", "toggle", or
     "state" (or "") to only ask.  Answers "on" or "off". */
  "  <method name='PointerConfine'>"
  "    <arg type='s' name='mode' direction='in'/>"
  "    <arg type='s' name='result' direction='out'/></method>"
  /* Signals: what a script outside the process used to have to poll
     for.  Emitted from cmacs-gowl.c on the compositor's own signals. */
  "  <signal name='ClientAdded'>"
  "    <arg type='s' name='app_id'/><arg type='s' name='title'/></signal>"
  "  <signal name='ClientRemoved'>"
  "    <arg type='s' name='app_id'/><arg type='s' name='title'/></signal>"
  "  <signal name='FocusChanged'>"
  "    <arg type='s' name='app_id'/><arg type='s' name='title'/></signal>"
  "  <signal name='ModeChanged'>"
  "    <arg type='s' name='mode'/></signal>"
  "  <signal name='KeyboardLayoutChanged'>"
  "    <arg type='s' name='name'/><arg type='u' name='index'/></signal>"
  "  <signal name='OutputPowerChanged'>"
  "    <arg type='s' name='output'/><arg type='b' name='on'/></signal>"
  "  <signal name='OutputProfileChanged'>"
  "    <arg type='s' name='profile'/></signal>"
  "  <signal name='MonitorHdrChanged'>"
  "    <arg type='s' name='output'/><arg type='b' name='on'/></signal>"
  "  <signal name='ClientTitleChanged'>"
  "    <arg type='s' name='app_id'/><arg type='s' name='title'/></signal>"
  "  <signal name='LockChanged'>"
  "    <arg type='b' name='locked'/></signal>"
  "  <signal name='PointerConfineChanged'>"
  "    <arg type='b' name='active'/><arg type='s' name='app_id'/>"
  "    <arg type='s' name='reason'/></signal>"
  /* A gowl module announced a change of state: module "broadcast",
     text "on eq" / "off panic" -- what IPC subscribers see as EVENT. */
  "  <signal name='ModuleEvent'>"
  "    <arg type='s' name='module'/><arg type='s' name='text'/></signal>"
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

/* CALL_ is substituted INSIDE this block, so the `&err' every caller
   writes binds to the err declared here -- one fresh NULL error per
   invocation, consumed by the same expansion.  on_method therefore has
   no err of its own; one there would only be shadowed. */
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
  (void) c; (void) s; (void) o; (void) i; (void) u;

  /* Served from the capability table when the method has a row in
     cmacs-dbus-forward-table.h; the bodies below are the methods
     that have none.  */
  if (cmacs_dbus_forward (i, m, p, iv))
    return;

  if (g_strcmp0 (m, "AddKeybind") == 0)
    {
      const gchar *key, *arg;
      gint action;
      g_variant_get (p, "(&si&s)", &key, &action, &arg);
      RETURN_STR (cmacs_dispatch_gowl_add_keybind (key, action, arg,
                                                    NULL, &err));
    }
  else if (g_strcmp0 (m, "AddKeybindFull") == 0)
    {
      const gchar *key, *arg, *desc;
      gint action;
      g_variant_get (p, "(&si&s&s)", &key, &action, &arg, &desc);
      RETURN_STR (cmacs_dispatch_gowl_add_keybind (
                    key, action, arg,
                    (desc != NULL && desc[0] != '\0') ? desc : NULL,
                    &err));
    }
  else if (g_strcmp0 (m, "RunKeybind") == 0)
    {
      const gchar *key;
      g_variant_get (p, "(&s)", &key);
      RETURN_STR (cmacs_dispatch_gowl_run_keybind (key, &err));
    }
  else if (g_strcmp0 (m, "RunMacro") == 0)
    {
      const gchar *name;
      g_autofree const gchar **args = NULL;
      g_variant_get (p, "(&s^a&s)", &name, &args);
      RETURN_STR (cmacs_dispatch_gowl_run_macro (name, args, &err));
    }
  else if (g_strcmp0 (m, "Broadcast") == 0)
    {
      const gchar *verb;
      g_variant_get (p, "(&s)", &verb);
      RETURN_STR (cmacs_dispatch_gowl_broadcast (verb, &err));
    }
  else if (g_strcmp0 (m, "Floatdesk") == 0)
    {
      const gchar *verb, *args;
      g_variant_get (p, "(&s&s)", &verb, &args);
      RETURN_STR (cmacs_dispatch_gowl_floatdesk (verb, args, &err));
    }
  else if (g_strcmp0 (m, "Hotkey") == 0)
    {
      const gchar *verb, *args;
      g_variant_get (p, "(&s&s)", &verb, &args);
      RETURN_STR (cmacs_dispatch_gowl_hotkey (verb, args, &err));
    }
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
  else if (g_strcmp0 (m, "SetKeyMode") == 0)
    {
      const gchar *mode;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &mode);
      args[0] = mode;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (gowl-set-key-mode \"%s\") (gowl-key-mode))", args, 1);
    }
  else if (g_strcmp0 (m, "KeyMode") == 0)
    cmacs_dbus_eval_to_reply_string (iv, "(gowl-key-mode)", NULL, 0);
  else if (g_strcmp0 (m, "SwitchKeyboardLayout") == 0)
    {
      const gchar *which;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &which);
      args[0] = (which != NULL && *which != '\0') ? which : "next";
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (gowl-switch-keyboard-layout \"%s\") "
        "(car (gowl-keyboard-layout)))", args, 1);
    }
  else if (g_strcmp0 (m, "KeyboardLayout") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(car (gowl-keyboard-layout))", NULL, 0);
  else if (g_strcmp0 (m, "FocusDirection") == 0)
    {
      const gchar *direction;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &direction);
      args[0] = direction;
      cmacs_dbus_eval_to_reply_string (iv,
        "(if (gowl-focus-direction (intern \"%s\")) \"moved\" \"nothing\")",
        args, 1);
    }
  else if (g_strcmp0 (m, "FocusUrgent") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(if (gowl-focus-urgent) \"moved\" \"nothing\")", NULL, 0);
  else if (g_strcmp0 (m, "FocusLast") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(if (gowl-focus-last) \"moved\" \"nothing\")", NULL, 0);
  else if (g_strcmp0 (m, "OutputPower") == 0)
    {
      /* "on", "off", or anything else toggles, as the keybind action. */
      const gchar *mode;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &mode);
      args[0] = mode;
      cmacs_dbus_eval_to_reply_string (iv,
        "(let ((m \"%s\")) (gowl-set-outputs-powered "
        "(cond ((equal m \"on\") t) ((equal m \"off\") nil) "
        "(t (gowl-outputs-powered-off-p)))) "
        "(if (gowl-outputs-powered-off-p) \"off\" \"on\"))", args, 1);
    }
  else if (g_strcmp0 (m, "PointerConfine") == 0)
    {
      /* The mode picks one of four fixed forms; nothing the caller
         sent is ever spliced into the Lisp.  */
      const gchar *mode;
      const gchar *form;
      g_variant_get (p, "(&s)", &mode);
      if (g_strcmp0 (mode, "on") == 0)
        form = "(if (gowl-pointer-confine 'on) \"on\" \"off\")";
      else if (g_strcmp0 (mode, "off") == 0)
        form = "(if (gowl-pointer-confine 'off) \"on\" \"off\")";
      else if (g_strcmp0 (mode, "toggle") == 0)
        form = "(if (gowl-pointer-confine 'toggle) \"on\" \"off\")";
      else if (*mode == '\0' || g_strcmp0 (mode, "state") == 0)
        form = "(if (gowl-pointer-confine-client) \"on\" \"off\")";
      else
        {
          g_dbus_method_invocation_return_error (iv, G_DBUS_ERROR,
            G_DBUS_ERROR_INVALID_ARGS,
            "mode must be on, off, toggle or state");
          return;
        }
      cmacs_dbus_eval_to_reply_string (iv, form, NULL, 0);
    }
  else if (g_strcmp0 (m, "ReloadConfig") == 0)
    RETURN_STR (cmacs_dispatch_gowl_reload_config (&err));
  else if (g_strcmp0 (m, "ConfigGet") == 0)
    {
      const gchar *property;
      g_variant_get (p, "(&s)", &property);
      RETURN_STR (cmacs_dispatch_gowl_config_get (property, &err));
    }
  else
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.freedesktop.DBus.Error.UnknownMethod", m);
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
