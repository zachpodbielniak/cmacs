/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-service.c — D-Bus service for CMacs
 *
 * Provides a GDBus-based D-Bus service (org.cmacs.Editor1) that external
 * processes can use to interact with CMacs.  The bacon shell's `cmacsgi`
 * builtin uses this to call elisp, GI functions, open files, etc.
 *
 * The service runs on the CMacs GMainContext, so method handlers fire
 * on the Emacs main thread during event dispatch — safe for calling
 * Emacs primitives via the same path as GLib timeout/idle callbacks.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <unistd.h>

/* ── D-Bus interface definition ────────────────────────────────────── */

static const gchar introspection_xml[] =
  "<node>"
  "  <interface name='org.cmacs.Editor1'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='FindFile'>"
  "      <arg type='s' name='path' direction='in'/>"
  "    </method>"
  "    <method name='Message'>"
  "      <arg type='s' name='text' direction='in'/>"
  "    </method>"
  "    <method name='GiRequire'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='s' name='version' direction='in'/>"
  "      <arg type='b' name='success' direction='out'/>"
  "    </method>"
  "    <method name='GiCall'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='s' name='function' direction='in'/>"
  "      <arg type='as' name='args' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GiListFunctions'>"
  "      <arg type='s' name='namespace_' direction='in'/>"
  "      <arg type='as' name='functions' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

/* ── State ─────────────────────────────────────────────────────────── */

static GDBusConnection *dbus_conn = NULL;
static GDBusNodeInfo   *dbus_introspection = NULL;
static guint            dbus_owner_id = 0;
static guint            dbus_reg_id = 0;
static gchar           *dbus_bus_name = NULL;

/* ── D-Bus error helper ────────────────────────────────────────────── */

static void
dbus_return_gerror (GDBusMethodInvocation *invocation, GError *err)
{
  g_dbus_method_invocation_return_dbus_error (
    invocation, "org.cmacs.Editor1.Error", err->message);
  g_error_free (err);
}

/* ── Method handler ────────────────────────────────────────────────── */

static void
handle_method_call (GDBusConnection       *connection,
                    const gchar           *sender,
                    const gchar           *object_path,
                    const gchar           *interface_name,
                    const gchar           *method_name,
                    GVariant              *parameters,
                    GDBusMethodInvocation *invocation,
                    gpointer               user_data)
{
  (void)connection; (void)sender; (void)object_path;
  (void)interface_name; (void)user_data;

  if (g_strcmp0 (method_name, "Eval") == 0)
    {
      const gchar *expr;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s)", &expr);
      result = cmacs_dispatch_eval (expr, &err);
      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "FindFile") == 0)
    {
      const gchar *path;
      g_variant_get (parameters, "(&s)", &path);
      cmacs_dispatch_find_file (path);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_strcmp0 (method_name, "Message") == 0)
    {
      const gchar *text;
      g_variant_get (parameters, "(&s)", &text);
      cmacs_dispatch_message (text);
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_strcmp0 (method_name, "GiRequire") == 0)
    {
      const gchar *ns, *ver;
      GError *err = NULL;
      gboolean ok;

      g_variant_get (parameters, "(&s&s)", &ns, &ver);
      ok = cmacs_dispatch_gi_require (ns, ver, &err);
      if (err != NULL)
        dbus_return_gerror (invocation, err);
      else
        g_dbus_method_invocation_return_value (
          invocation, g_variant_new ("(b)", ok));
    }
  else if (g_strcmp0 (method_name, "GiCall") == 0)
    {
      const gchar *ns, *func, *arg;
      GVariantIter *iter;
      GPtrArray *args_arr;
      GError *err = NULL;
      gchar *result;

      g_variant_get (parameters, "(&s&sas)", &ns, &func, &iter);

      args_arr = g_ptr_array_new ();
      while (g_variant_iter_next (iter, "&s", &arg))
        g_ptr_array_add (args_arr, (gpointer)arg);
      g_variant_iter_free (iter);

      result = cmacs_dispatch_gi_call (
        ns, func, (const gchar *const *)args_arr->pdata,
        (gint)args_arr->len, &err);
      g_ptr_array_free (args_arr, TRUE);

      if (result != NULL)
        {
          g_dbus_method_invocation_return_value (
            invocation, g_variant_new ("(s)", result));
          g_free (result);
        }
      else
        dbus_return_gerror (invocation, err);
    }
  else if (g_strcmp0 (method_name, "GiListFunctions") == 0)
    {
      const gchar *ns;
      gchar **funcs;
      GVariantBuilder builder;
      gint i;

      g_variant_get (parameters, "(&s)", &ns);
      funcs = cmacs_dispatch_gi_list_functions (ns);

      g_variant_builder_init (&builder, G_VARIANT_TYPE ("as"));
      for (i = 0; funcs[i] != NULL; i++)
        g_variant_builder_add (&builder, "s", funcs[i]);
      g_strfreev (funcs);

      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(as)", &builder));
    }
}

static const GDBusInterfaceVTable vtable = {
  handle_method_call,
  NULL,  /* get_property */
  NULL,  /* set_property */
  { 0 }
};

/* ── Bus name callbacks ────────────────────────────────────────────── */

static void
on_name_acquired (GDBusConnection *connection,
                  const gchar     *name,
                  gpointer         user_data)
{
  (void)connection; (void)name; (void)user_data;
}

static void
on_name_lost (GDBusConnection *connection,
              const gchar     *name,
              gpointer         user_data)
{
  (void)connection; (void)name; (void)user_data;
}

/* ── Elisp interface ───────────────────────────────────────────────── */

DEFUN ("cmacs-dbus-start", Fcmacs_dbus_start,
       Scmacs_dbus_start, 0, 0, 0,
       doc: /* Start the CMacs D-Bus service.
Returns the D-Bus bus name as a string.
The service exposes the org.cmacs.Editor1 interface so that external
processes (e.g. the bacon shell `cmacsgi` builtin) can call into CMacs
for elisp evaluation, file operations, and GObject Introspection. */)
  (void)
{
  GError *err = NULL;
  GMainContext *ctx;
  gchar *addr;

  /* Already running — return existing name. */
  if (dbus_conn != NULL)
    return build_string (dbus_bus_name);

  ctx = cmacs_glib_get_context ();
  if (ctx == NULL)
    error ("CMacs GLib context not initialized");

  /* Parse introspection XML. */
  dbus_introspection = g_dbus_node_info_new_for_xml (introspection_xml, &err);
  if (dbus_introspection == NULL)
    {
      gchar *msg = g_strdup (err->message);
      g_error_free (err);
      error ("D-Bus introspection: %s", msg);
    }

  /* Get the session bus address. */
  addr = g_dbus_address_get_for_bus_sync (G_BUS_TYPE_SESSION, NULL, &err);
  if (addr == NULL)
    {
      gchar *msg = g_strdup (err->message);
      g_error_free (err);
      g_dbus_node_info_unref (dbus_introspection);
      dbus_introspection = NULL;
      error ("D-Bus address: %s", msg);
    }

  /* Create a private connection on our GMainContext. */
  g_main_context_push_thread_default (ctx);
  dbus_conn = g_dbus_connection_new_for_address_sync (
    addr,
    G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT
    | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
    NULL, NULL, &err);
  g_main_context_pop_thread_default (ctx);
  g_free (addr);

  if (dbus_conn == NULL)
    {
      gchar *msg = g_strdup (err->message);
      g_error_free (err);
      g_dbus_node_info_unref (dbus_introspection);
      dbus_introspection = NULL;
      error ("D-Bus connect: %s", msg);
    }

  /* Register the object. */
  dbus_reg_id = g_dbus_connection_register_object (
    dbus_conn, "/org/cmacs/Editor",
    dbus_introspection->interfaces[0],
    &vtable, NULL, NULL, &err);
  if (dbus_reg_id == 0)
    {
      gchar *msg = g_strdup (err->message);
      g_error_free (err);
      g_object_unref (dbus_conn);
      dbus_conn = NULL;
      g_dbus_node_info_unref (dbus_introspection);
      dbus_introspection = NULL;
      error ("D-Bus register: %s", msg);
    }

  /* Request a well-known bus name unique to this CMacs instance. */
  dbus_bus_name = g_strdup_printf ("org.cmacs.Editor.Pid%d",
                                   (int)getpid ());
  dbus_owner_id = g_bus_own_name_on_connection (
    dbus_conn, dbus_bus_name,
    G_BUS_NAME_OWNER_FLAGS_NONE,
    on_name_acquired, on_name_lost,
    NULL, NULL);

  return build_string (dbus_bus_name);
}

DEFUN ("cmacs-dbus-stop", Fcmacs_dbus_stop,
       Scmacs_dbus_stop, 0, 0, 0,
       doc: /* Stop the CMacs D-Bus service. */)
  (void)
{
  if (dbus_conn == NULL)
    return Qnil;

  if (dbus_owner_id > 0)
    {
      g_bus_unown_name (dbus_owner_id);
      dbus_owner_id = 0;
    }
  if (dbus_reg_id > 0)
    {
      g_dbus_connection_unregister_object (dbus_conn, dbus_reg_id);
      dbus_reg_id = 0;
    }
  g_object_unref (dbus_conn);
  dbus_conn = NULL;

  if (dbus_introspection != NULL)
    {
      g_dbus_node_info_unref (dbus_introspection);
      dbus_introspection = NULL;
    }
  g_free (dbus_bus_name);
  dbus_bus_name = NULL;

  return Qt;
}

DEFUN ("cmacs-dbus-name", Fcmacs_dbus_name,
       Scmacs_dbus_name, 0, 0, 0,
       doc: /* Return the D-Bus bus name of the CMacs service, or nil if not running. */)
  (void)
{
  if (dbus_bus_name == NULL)
    return Qnil;
  return build_string (dbus_bus_name);
}

void
syms_of_cmacs_dbus_service (void)
{
  defsubr (&Scmacs_dbus_start);
  defsubr (&Scmacs_dbus_stop);
  defsubr (&Scmacs_dbus_name);
}

#endif /* HAVE_CMACS_GLIB */
