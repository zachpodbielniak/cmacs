/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-mpris.c --- MPRIS-as-buffer-navigator (Phase 5)
 *
 * Implements the standard MPRIS MediaPlayer2 spec server-side, but
 * with a twist: instead of audio playback, mediakeys navigate
 * cmacs's buffer ring.  Hitting "Next" on a Bluetooth headset
 * = (next-buffer).  Status bar shows the current buffer as the
 * "now playing" track.
 *
 * Opt-in: M-x cmacs-mpris-buffer-nav-mode.  Off by default --
 * registering the bus name org.mpris.MediaPlayer2.cmacs would
 * conflict with any actual media player named cmacs.
 *
 * Spec: https://specifications.freedesktop.org/mpris-spec/latest/
 *
 * Two interfaces, both at /org/mpris/MediaPlayer2:
 *   org.mpris.MediaPlayer2          (root: name, identity, raise, quit)
 *   org.mpris.MediaPlayer2.Player   (transport: next, prev, play-pause,
 *                                    seek, metadata)
 *
 * The Lisp helper lisp/cmacs/cmacs-dbus-mpris.el owns the actual
 * navigation logic; this C side just exposes the surface and routes
 * each method through cmacs_dispatch_eval. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include <gio/gio.h>
#include <string.h>

#define MPRIS_PATH "/org/mpris/MediaPlayer2"

static const gchar *iface_xml =
  "<node>"
  "<interface name='org.mpris.MediaPlayer2'>"
  "  <method name='Raise'/>"
  "  <method name='Quit'/>"
  "  <property name='CanQuit' type='b' access='read'/>"
  "  <property name='CanRaise' type='b' access='read'/>"
  "  <property name='HasTrackList' type='b' access='read'/>"
  "  <property name='Identity' type='s' access='read'/>"
  "  <property name='DesktopEntry' type='s' access='read'/>"
  "  <property name='SupportedUriSchemes' type='as' access='read'/>"
  "  <property name='SupportedMimeTypes' type='as' access='read'/>"
  "</interface>"
  "<interface name='org.mpris.MediaPlayer2.Player'>"
  "  <method name='Next'/>"
  "  <method name='Previous'/>"
  "  <method name='Pause'/>"
  "  <method name='PlayPause'/>"
  "  <method name='Stop'/>"
  "  <method name='Play'/>"
  "  <method name='Seek'><arg type='x' name='offset' direction='in'/></method>"
  "  <property name='PlaybackStatus' type='s' access='read'/>"
  "  <property name='Metadata' type='a{sv}' access='read'/>"
  "  <property name='Position' type='x' access='read'/>"
  "  <property name='CanGoNext' type='b' access='read'/>"
  "  <property name='CanGoPrevious' type='b' access='read'/>"
  "  <property name='CanPlay' type='b' access='read'/>"
  "  <property name='CanPause' type='b' access='read'/>"
  "  <property name='CanSeek' type='b' access='read'/>"
  "  <property name='CanControl' type='b' access='read'/>"
  "</interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;
static guint reg_root_id = 0;
static guint reg_player_id = 0;
static guint owner_id = 0;

static void
mpris_method (GDBusConnection *c, const gchar *s, const gchar *o,
              const gchar *iface, const gchar *m, GVariant *p,
              GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  gchar *r = NULL;
  (void) c; (void) s; (void) o; (void) iface; (void) p; (void) u;

  if (g_strcmp0 (m, "Raise") == 0)
    r = cmacs_dispatch_eval (
      "(progn (raise-frame (selected-frame)) t)", &err);
  else if (g_strcmp0 (m, "Quit") == 0)
    r = cmacs_dispatch_eval (
      "(progn (save-buffers-kill-emacs) t)", &err);
  else if (g_strcmp0 (m, "Next") == 0)
    r = cmacs_dispatch_eval ("(progn (next-buffer) t)", &err);
  else if (g_strcmp0 (m, "Previous") == 0)
    r = cmacs_dispatch_eval ("(progn (previous-buffer) t)", &err);
  else if (g_strcmp0 (m, "PlayPause") == 0
           || g_strcmp0 (m, "Pause") == 0
           || g_strcmp0 (m, "Stop") == 0)
    r = cmacs_dispatch_eval ("(progn (bury-buffer) t)", &err);
  else if (g_strcmp0 (m, "Play") == 0)
    r = cmacs_dispatch_eval ("(progn (raise-frame (selected-frame)) t)", &err);
  else if (g_strcmp0 (m, "Seek") == 0)
    {
      gint64 offset;
      gchar buf[24];
      const gchar *args[1];
      g_variant_get (p, "(x)", &offset);
      g_snprintf (buf, sizeof buf, "%" G_GINT64_FORMAT, offset / 1000000);
      args[0] = buf;
      cmacs_dbus_eval_to_reply (iv,
        "(progn (forward-line %s) \"ok\")", args, 1);
      return;
    }
  else
    {
      g_dbus_method_invocation_return_value (iv, NULL);
      return;
    }

  if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
  g_free (r);
  g_dbus_method_invocation_return_value (iv, NULL);
}

static GVariant *
mpris_get_property (GDBusConnection *c, const gchar *s, const gchar *o,
                    const gchar *iface, const gchar *prop,
                    GError **error, gpointer u)
{
  (void) c; (void) s; (void) o; (void) error; (void) u;

  /* org.mpris.MediaPlayer2 root */
  if (g_strcmp0 (iface, "org.mpris.MediaPlayer2") == 0)
    {
      if (g_strcmp0 (prop, "CanQuit") == 0
          || g_strcmp0 (prop, "CanRaise") == 0)
        return g_variant_new_boolean (TRUE);
      if (g_strcmp0 (prop, "HasTrackList") == 0)
        return g_variant_new_boolean (FALSE);
      if (g_strcmp0 (prop, "Identity") == 0)
        return g_variant_new_string ("cmacs Buffer Navigator");
      if (g_strcmp0 (prop, "DesktopEntry") == 0)
        return g_variant_new_string ("emacs");
      if (g_strcmp0 (prop, "SupportedUriSchemes") == 0
          || g_strcmp0 (prop, "SupportedMimeTypes") == 0)
        {
          GVariantBuilder b;
          g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
          return g_variant_builder_end (&b);
        }
    }

  /* org.mpris.MediaPlayer2.Player */
  if (g_strcmp0 (iface, "org.mpris.MediaPlayer2.Player") == 0)
    {
      if (g_strcmp0 (prop, "PlaybackStatus") == 0)
        return g_variant_new_string ("Playing");
      if (g_strcmp0 (prop, "Position") == 0)
        return g_variant_new_int64 (0);
      if (g_strcmp0 (prop, "CanGoNext") == 0
          || g_strcmp0 (prop, "CanGoPrevious") == 0
          || g_strcmp0 (prop, "CanPlay") == 0
          || g_strcmp0 (prop, "CanPause") == 0
          || g_strcmp0 (prop, "CanSeek") == 0
          || g_strcmp0 (prop, "CanControl") == 0)
        return g_variant_new_boolean (TRUE);
      if (g_strcmp0 (prop, "Metadata") == 0)
        {
          GVariantBuilder b;
          gchar *bufname = cmacs_dispatch_eval (
            "(buffer-name (current-buffer))", NULL);
          gchar *clean = bufname;
          if (clean) {
            size_t len = strlen (clean);
            if (len >= 2 && clean[0] == '"' && clean[len - 1] == '"')
              { memmove (clean, clean + 1, len - 2); clean[len - 2] = '\0'; }
          }
          g_variant_builder_init (&b, G_VARIANT_TYPE ("a{sv}"));
          g_variant_builder_add (&b, "{sv}", "mpris:trackid",
            g_variant_new_object_path ("/org/cmacs/Editor/Track"));
          g_variant_builder_add (&b, "{sv}", "xesam:title",
            g_variant_new_string (clean ? clean : "(unknown)"));
          g_variant_builder_add (&b, "{sv}", "xesam:artist",
            g_variant_new_strv ((const gchar *[]) { "cmacs", NULL }, 1));
          g_free (bufname);
          return g_variant_builder_end (&b);
        }
    }
  return NULL;
}

static const GDBusInterfaceVTable vtable = {
  mpris_method, mpris_get_property, NULL, { NULL }
};

static gboolean is_active = FALSE;

static void
on_acquired (GDBusConnection *conn, const gchar *name, gpointer u)
{
  (void) conn; (void) name; (void) u;
}

static void
on_lost (GDBusConnection *conn, const gchar *name, gpointer u)
{
  (void) conn; (void) name; (void) u;
}

DEFUN ("cmacs-dbus-mpris-start", Fcmacs_dbus_mpris_start,
       Scmacs_dbus_mpris_start, 0, 0, 0,
       doc: /* Register cmacs as an MPRIS MediaPlayer2 server.
Mediakeys (Next/Previous/PlayPause/Stop) become buffer navigation
(next-buffer / previous-buffer / bury-buffer).  Status bar applets,
GNOME shell, KDE, etc. all show the current buffer as "now playing".

Opt-in.  Returns t if registered, nil if already active or no D-Bus.  */)
  (void)
{
  GDBusConnection *conn = cmacs_dbus_get_connection ();
  GError *err = NULL;

  if (is_active || conn == NULL)
    return Qnil;

  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, &err);
      if (iface_info == NULL)
        {
          if (err) g_error_free (err);
          return Qnil;
        }
    }

  reg_root_id = g_dbus_connection_register_object (
    conn, MPRIS_PATH, iface_info->interfaces[0],
    &vtable, NULL, NULL, NULL);
  reg_player_id = g_dbus_connection_register_object (
    conn, MPRIS_PATH, iface_info->interfaces[1],
    &vtable, NULL, NULL, NULL);

  /* Claim org.mpris.MediaPlayer2.cmacs.  Allow replacement so a
     fresh cmacs takes over from a stale instance. */
  owner_id = g_bus_own_name_on_connection (
    conn, "org.mpris.MediaPlayer2.cmacs",
    G_BUS_NAME_OWNER_FLAGS_REPLACE,
    on_acquired, on_lost, NULL, NULL);

  is_active = TRUE;
  return Qt;
}

DEFUN ("cmacs-dbus-mpris-stop", Fcmacs_dbus_mpris_stop,
       Scmacs_dbus_mpris_stop, 0, 0, 0,
       doc: /* Unregister the MPRIS surface.  Returns t if was active,
nil otherwise.  */)
  (void)
{
  GDBusConnection *conn = cmacs_dbus_get_connection ();

  if (!is_active)
    return Qnil;
  if (owner_id) { g_bus_unown_name (owner_id); owner_id = 0; }
  if (conn != NULL)
    {
      if (reg_root_id) {
        g_dbus_connection_unregister_object (conn, reg_root_id);
        reg_root_id = 0;
      }
      if (reg_player_id) {
        g_dbus_connection_unregister_object (conn, reg_player_id);
        reg_player_id = 0;
      }
    }
  is_active = FALSE;
  return Qt;
}

void
syms_of_cmacs_dbus_mpris (void)
{
  defsubr (&Scmacs_dbus_mpris_start);
  defsubr (&Scmacs_dbus_mpris_stop);
}

#endif
