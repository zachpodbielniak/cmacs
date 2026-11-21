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
 * Every method is a row of cmacs-dbus-forward-table.h, served through
 * cmacs-dbus-forward.c: Kill, Create and Save by the registry tools of
 * those names, the rest by the cmacs-dbus-method-buffer-* functions in
 * lisp/cmacs/cmacs-dbus-forward.el.  Either way a buffer the
 * redaction rules exclude is not listed, found, or described, exactly
 * as a buffer that does not exist is not.  The typed replies (as, b,
 * s, x) are what they always were. */

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

  /* Every method of this interface has a row in
     cmacs-dbus-forward-table.h and is served from the capability
     table: there is no per-method code here.  The fallback below is
     for a method added to the XML above without a row or a body.  */
  if (cmacs_dbus_forward (iface_name, method_name, parameters, invocation))
    return;

  g_dbus_method_invocation_return_dbus_error (
    invocation, "org.freedesktop.DBus.Error.UnknownMethod", method_name);
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
