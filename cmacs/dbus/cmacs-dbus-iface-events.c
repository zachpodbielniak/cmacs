/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-events.c --- unified editor events surface.
 *
 * org.cmacs.Editor1.Events  at  /org/cmacs/Editor
 *
 * A single endpoint external tools subscribe to in order to observe
 * editor activity (files, buffers, projects, windows, frames, the
 * editor lifecycle, text edits, and cmacs subsystems).  Two ways to
 * consume it:
 *
 *   signal Event(s category, s name, s detail, a{sv} data, t ts_us)
 *       The firehose: one subscription carries every event.  Emitted
 *       from Elisp via the cmacs-dbus-emit-event DEFUN (cmacs-dbus-emit.c),
 *       which stamps the microsecond timestamp server-side.
 *
 *   typed named signals (FileOpened, BufferSwitched, ProjectSwitched,
 *       FrameFocusChanged, ...) for selective subscription and
 *       self-documenting introspection.  Emitted alongside the firehose
 *       from Elisp via cmacs-dbus-emit-signal.
 *
 * Methods (discoverability + late-subscriber backlog):
 *
 *   EventTypes() -> as     the taxonomy as "category/name" strings
 *   Categories() -> as     currently-enabled categories (read-only)
 *   Recent(i n)  -> s      JSON array of the last n events (ring buffer)
 *
 * Emission is entirely Lisp-driven; the actual hooks live in
 * lisp/cmacs/cmacs-dbus-events.el.  This file owns the introspection
 * contract and the three query methods, which route to the Lisp helpers
 * (guarded by fboundp so the surface answers even before the emitter
 * mode has loaded). */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Events'>"
  "    <method name='EventTypes'>"
  "      <arg type='as' name='types' direction='out'/>"
  "    </method>"
  "    <method name='Categories'>"
  "      <arg type='as' name='categories' direction='out'/>"
  "    </method>"
  "    <method name='Recent'>"
  "      <arg type='i' name='count' direction='in'/>"
  "      <arg type='s' name='events_json' direction='out'/>"
  "    </method>"
  /* ── Firehose ── */
  "    <signal name='Event'>"
  "      <arg type='s'     name='category'/>"
  "      <arg type='s'     name='name'/>"
  "      <arg type='s'     name='detail'/>"
  "      <arg type='a{sv}' name='data'/>"
  "      <arg type='t'     name='timestamp_us'/>"
  "    </signal>"
  /* ── File ── */
  "    <signal name='FileOpened'><arg type='s' name='path'/></signal>"
  "    <signal name='FileSaved'><arg type='s' name='path'/></signal>"
  "    <signal name='FileClosed'><arg type='s' name='path'/></signal>"
  /* ── Buffer ── */
  "    <signal name='BufferCreated'><arg type='s' name='name'/></signal>"
  "    <signal name='BufferKilled'><arg type='s' name='name'/></signal>"
  "    <signal name='BufferSwitched'>"
  "      <arg type='s' name='name'/><arg type='s' name='previous'/></signal>"
  "    <signal name='BufferSaved'>"
  "      <arg type='s' name='name'/><arg type='s' name='file'/></signal>"
  /* Modified state is split into two string-only signals rather than a
     boolean arg: Emacs has no boolean false (nil marshals as ""), so a
     'b' arg could never carry the unmodified case correctly. */
  "    <signal name='BufferModified'><arg type='s' name='name'/></signal>"
  "    <signal name='BufferUnmodified'><arg type='s' name='name'/></signal>"
  /* ── Project ── */
  "    <signal name='ProjectSwitched'>"
  "      <arg type='s' name='root'/><arg type='s' name='previous'/></signal>"
  /* ── Window / frame ── */
  "    <signal name='WindowSelectionChanged'>"
  "      <arg type='s' name='buffer'/><arg type='s' name='frame'/></signal>"
  "    <signal name='FrameOpened'><arg type='s' name='frame'/></signal>"
  "    <signal name='FrameClosed'><arg type='s' name='frame'/></signal>"
  "    <signal name='FrameFocused'><arg type='s' name='frame'/></signal>"
  "    <signal name='FrameUnfocused'><arg type='s' name='frame'/></signal>"
  /* ── Editor lifecycle ── */
  "    <signal name='EditorStartup'/>"
  "    <signal name='EditorShutdown'/>"
  /* ── Text (throttled, opt-in) ── */
  "    <signal name='TextChanged'>"
  "      <arg type='s' name='name'/><arg type='x' name='beg'/>"
  "      <arg type='x' name='end'/><arg type='x' name='length'/></signal>"
  /* ── Subsystems (opt-in) ── */
  "    <signal name='BrowserLoadChanged'>"
  "      <arg type='s' name='buffer'/><arg type='s' name='state'/></signal>"
  "    <signal name='BrowserUriChanged'>"
  "      <arg type='s' name='buffer'/><arg type='s' name='uri'/></signal>"
  "    <signal name='BrowserTitleChanged'>"
  "      <arg type='s' name='buffer'/><arg type='s' name='title'/></signal>"
  "    <signal name='BrowserCrashed'><arg type='s' name='buffer'/></signal>"
  "    <signal name='AiMessage'>"
  "      <arg type='s' name='room'/><arg type='s' name='sender'/>"
  "      <arg type='s' name='text'/></signal>"
  "    <signal name='PatchApplied'><arg type='s' name='function'/></signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* The documented taxonomy, mirroring the named signals above.  Static
 * because it is the wire contract, not runtime state. */
static const gchar *event_types[] = {
  "file/opened", "file/saved", "file/closed",
  "buffer/created", "buffer/killed", "buffer/switched", "buffer/saved",
  "buffer/modified", "buffer/unmodified",
  "project/switched",
  "window/selection-changed",
  "frame/opened", "frame/closed", "frame/focused", "frame/unfocused",
  "editor/startup", "editor/shutdown",
  "text/changed",
  "gsurf/load-changed", "gsurf/uri-changed", "gsurf/title-changed",
  "gsurf/crashed",
  "ai/message",
  "cintrospect/patch-applied",
  NULL
};

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "EventTypes") == 0)
    {
      GVariantBuilder b;
      gint k;
      g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
      for (k = 0; event_types[k] != NULL; k++)
        g_variant_builder_add (&b, "s", event_types[k]);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(as)", &b));
    }
  else if (g_strcmp0 (m, "Categories") == 0)
    {
      /* The emitter joins enabled category symbols with "|||". */
      gchar *r = cmacs_dispatch_eval_string (
        "(if (fboundp 'cmacs-dbus-events--categories-string)"
        " (cmacs-dbus-events--categories-string) \"\")", &err);
      GVariantBuilder b;
      gchar **cats;
      gsize j;

      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }

      cats = g_strsplit (r, "|||", -1);
      g_free (r);
      g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
      for (j = 0; cats[j] != NULL; j++)
        if (cats[j][0] != '\0')
          g_variant_builder_add (&b, "s", cats[j]);
      g_strfreev (cats);
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(as)", &b));
    }
  else if (g_strcmp0 (m, "Recent") == 0)
    {
      gint count;
      gchar *expr, *result;

      g_variant_get (p, "(i)", &count);
      if (count <= 0)
        count = 50;
      expr = g_strdup_printf (
        "(if (fboundp 'cmacs-dbus-events--recent-json)"
        " (cmacs-dbus-events--recent-json %d) \"[]\")", count);
      result = cmacs_dispatch_eval_string (expr, &err);
      g_free (expr);
      if (result == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(s)", result));
      g_free (result);
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_events_register (GDBusConnection *conn, const gchar *path,
                                  GError **error)
{
  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL)
        return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_events_unregister (GDBusConnection *conn, guint id)
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
