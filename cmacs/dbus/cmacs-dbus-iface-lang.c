/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-lang.c --- embedded-language eval over D-Bus.
 *
 * Three interfaces, one per runtime:
 *
 *   org.cmacs.Editor1.Crispy  --- inline crispy C snippets
 *   org.cmacs.Editor1.Bacon   --- bacon shell command lines
 *   org.cmacs.Editor1.Eshell  --- eshell command lines
 *
 * MCP parity: mirrors crispy_eval / bacon_eval in
 * cmacs/mcp/cmacs-mcp-tools-shell.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  Each
 * method reuses the same underlying DEFUNs the MCP tools call
 * (crispy-eval, crispy-eval-string, bacon-eval, bacon-eval-c,
 * bacon-complete), so behavior is identical across both surfaces. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <stdlib.h>
#include <string.h>

/* ── Shared: eval elisp returning "EXITCODE\nOUTPUT", reply (is) ──── */

#if defined(HAVE_CMACS_BACON)
static void
eval_to_exit_output_reply (GDBusMethodInvocation *iv,
                           const gchar           *elisp_template,
                           const gchar          **args,
                           gint                   n_args)
{
  gchar *expr;
  gchar *result;
  gchar *nl;
  gint code;
  GError *err = NULL;

  expr = cmacs_dbus_build_elisp (elisp_template, args, n_args);
  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);

  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }

  /* First line is the exit code, the rest is captured output. */
  code = (gint) strtol (result, NULL, 10);
  nl = strchr (result, '\n');
  g_dbus_method_invocation_return_value (
    iv, g_variant_new ("(is)", code, nl != NULL ? nl + 1 : ""));
  g_free (result);
}
#endif /* HAVE_CMACS_BACON */

/* ── org.cmacs.Editor1.Crispy ───────────────────────────────────────── */

#ifdef HAVE_CMACS_CRISPY

static const gchar *crispy_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Crispy'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='code' direction='in'/>"
  "      <arg type='i' name='exit_code' direction='out'/>"
  "    </method>"
  "    <method name='EvalString'>"
  "      <arg type='s' name='code' direction='in'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *crispy_info = NULL;

static void
crispy_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                    const gchar *i, const gchar *m, GVariant *p,
                    GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Eval") == 0)
    {
      const gchar *code;
      const gchar *args[1];
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &code);
      args[0] = code;
      expr = cmacs_dbus_build_elisp ("(crispy-eval \"%s\")", args, 1);
      result = cmacs_dispatch_eval (expr, &err);
      g_free (expr);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(i)", (gint) strtol (result, NULL, 10)));
      g_free (result);
    }
  else if (g_strcmp0 (m, "EvalString") == 0)
    {
      const gchar *code;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &code);
      args[0] = code;
      cmacs_dbus_eval_to_reply_string (iv,
        "(crispy-eval-string \"%s\")", args, 1);
    }
}

static const GDBusInterfaceVTable crispy_vtable = {
  crispy_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_crispy_register (GDBusConnection *conn, const gchar *path,
                                  GError **error)
{
  if (crispy_info == NULL)
    {
      crispy_info = g_dbus_node_info_new_for_xml (crispy_xml, error);
      if (crispy_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, crispy_info->interfaces[0], &crispy_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_crispy_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (crispy_info != NULL)
    { g_dbus_node_info_unref (crispy_info); crispy_info = NULL; }
}

#endif /* HAVE_CMACS_CRISPY */

/* ── org.cmacs.Editor1.Bacon ────────────────────────────────────────── */

#ifdef HAVE_CMACS_BACON

static const gchar *bacon_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Bacon'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='command' direction='in'/>"
  "      <arg type='i' name='exit_code' direction='out'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "    <method name='EvalC'>"
  "      <arg type='s' name='code' direction='in'/>"
  "      <arg type='i' name='exit_code' direction='out'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "    <method name='Complete'>"
  "      <arg type='s' name='prefix' direction='in'/>"
  "      <arg type='as' name='candidates' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *bacon_info = NULL;

static void
bacon_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                   const gchar *i, const gchar *m, GVariant *p,
                   GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Eval") == 0)
    {
      const gchar *command;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &command);
      args[0] = command;
      eval_to_exit_output_reply (iv,
        "(let ((r (bacon-eval \"%s\")))"
        "  (format \"%%d\\n%%s\" (car r) (cdr r)))",
        args, 1);
    }
  else if (g_strcmp0 (m, "EvalC") == 0)
    {
      const gchar *code;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &code);
      args[0] = code;
      eval_to_exit_output_reply (iv,
        "(let ((r (bacon-eval-c \"%s\")))"
        "  (format \"%%d\\n%%s\" (car r) (cdr r)))",
        args, 1);
    }
  else if (g_strcmp0 (m, "Complete") == 0)
    {
      const gchar *prefix;
      const gchar *args[1];
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &prefix);
      args[0] = prefix;
      expr = cmacs_dbus_build_elisp (
        "(mapconcat #'identity (bacon-complete \"%s\") \"\\n\")",
        args, 1);
      result = cmacs_dispatch_eval_string (expr, &err);
      g_free (expr);
      if (result == NULL)
        {
          cmacs_dbus_return_gerror (iv, err);
          return;
        }
      {
        gchar **lines = g_strsplit (result, "\n", -1);
        GVariantBuilder b;
        gint k;
        g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
        for (k = 0; lines[k] != NULL; k++)
          if (lines[k][0] != '\0')
            g_variant_builder_add (&b, "s", lines[k]);
        g_dbus_method_invocation_return_value (
          iv, g_variant_new ("(as)", &b));
        g_strfreev (lines);
      }
      g_free (result);
    }
}

static const GDBusInterfaceVTable bacon_vtable = {
  bacon_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_bacon_register (GDBusConnection *conn, const gchar *path,
                                 GError **error)
{
  if (bacon_info == NULL)
    {
      bacon_info = g_dbus_node_info_new_for_xml (bacon_xml, error);
      if (bacon_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, bacon_info->interfaces[0], &bacon_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_bacon_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (bacon_info != NULL)
    { g_dbus_node_info_unref (bacon_info); bacon_info = NULL; }
}

#endif /* HAVE_CMACS_BACON */

/* ── org.cmacs.Editor1.Eshell ───────────────────────────────────────── */

static const gchar *eshell_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Eshell'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='command' direction='in'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *eshell_info = NULL;

static void
eshell_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                    const gchar *i, const gchar *m, GVariant *p,
                    GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Eval") == 0)
    {
      const gchar *command;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &command);
      args[0] = command;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'eshell)"
        " (with-temp-buffer"
        "   (eshell-command \"%s\" t)"
        "   (buffer-substring-no-properties (point-min) (point-max))))",
        args, 1);
    }
}

static const GDBusInterfaceVTable eshell_vtable = {
  eshell_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_eshell_register (GDBusConnection *conn, const gchar *path,
                                  GError **error)
{
  if (eshell_info == NULL)
    {
      eshell_info = g_dbus_node_info_new_for_xml (eshell_xml, error);
      if (eshell_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, eshell_info->interfaces[0], &eshell_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_eshell_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (eshell_info != NULL)
    { g_dbus_node_info_unref (eshell_info); eshell_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
