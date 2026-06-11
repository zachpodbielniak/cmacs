/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-podomation.c --- podomation automation engine via
 * D-Bus.
 *
 * org.cmacs.Editor1.Podomation
 *
 * MCP parity: mirrors the podomation_* tools in
 * cmacs/mcp/cmacs-mcp-tools-shell.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  The elisp
 * bodies are identical to the MCP handlers'; event/context payloads
 * arrive as a{ss} dicts instead of JSON objects. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_PODOMATION)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Podomation'>"
  "    <method name='Control'>"
  "      <arg type='s' name='action' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EmitEvent'>"
  "      <arg type='s' name='event' direction='in'/>"
  "      <arg type='a{ss}' name='data' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EvalDsl'>"
  "      <arg type='s' name='dsl' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ReplEval'>"
  "      <arg type='s' name='line' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListPods'>"
  "      <arg type='s' name='pods' direction='out'/>"
  "    </method>"
  "    <method name='ListModules'>"
  "      <arg type='s' name='modules' direction='out'/>"
  "    </method>"
  "    <method name='LoadFile'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Reload'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetContext'>"
  "      <arg type='a{ss}' name='context' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Stats'>"
  "      <arg type='s' name='stats' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Build an elisp alist literal "(list (cons \"k\" \"v\") ...)" from an
 * a{ss} dict iterator.  Returns "nil" when empty.  Mirrors
 * podomation_data_alist in cmacs-mcp-tools-shell.c. */
static gchar *
dict_to_alist (GVariantIter *iter)
{
  GString *s;
  const gchar *key, *val;
  gboolean any = FALSE;

  s = g_string_new ("(list");
  while (g_variant_iter_loop (iter, "{&s&s}", &key, &val))
    {
      gchar *ek = cmacs_dbus_lisp_escape (key);
      gchar *ev = cmacs_dbus_lisp_escape (val);
      g_string_append_printf (s, " (cons \"%s\" \"%s\")", ek, ev);
      g_free (ek);
      g_free (ev);
      any = TRUE;
    }
  g_string_append_c (s, ')');
  if (!any)
    {
      g_string_free (s, TRUE);
      return g_strdup ("nil");
    }
  return g_string_free (s, FALSE);
}

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
pod_reply (GDBusMethodInvocation *iv, gchar *expr)
{
  gchar *result;
  GError *err = NULL;

  result = cmacs_dispatch_eval_string (expr, &err);
  g_free (expr);
  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }
  g_dbus_method_invocation_return_value (
    iv, g_variant_new ("(s)", result));
  g_free (result);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Control") == 0)
    {
      const gchar *action;
      g_variant_get (p, "(&s)", &action);
      if (g_strcmp0 (action, "start") == 0)
        pod_reply (iv, g_strdup
          ("(progn (cmacs-podomation-start) \"engine started\")"));
      else if (g_strcmp0 (action, "stop") == 0)
        pod_reply (iv, g_strdup
          ("(progn (cmacs-podomation-stop) \"engine stopped\")"));
      else if (g_strcmp0 (action, "status") == 0)
        pod_reply (iv, g_strdup
          ("(if (cmacs-podomation-running-p) \"running\" \"stopped\")"));
      else
        g_dbus_method_invocation_return_dbus_error (
          iv, "org.cmacs.Editor1.Error",
          "action must be one of: start, stop, status");
    }
  else if (g_strcmp0 (m, "EmitEvent") == 0)
    {
      const gchar *event;
      GVariantIter *iter;
      gchar *ee, *alist;
      g_variant_get (p, "(&sa{ss})", &event, &iter);
      ee = cmacs_dbus_lisp_escape (event);
      alist = dict_to_alist (iter);
      g_variant_iter_free (iter);
      pod_reply (iv, g_strdup_printf
        ("(progn (cmacs-podomation-emit-event \"%s\" %s)"
         "       (format \"emitted %%s\" \"%s\"))",
         ee, alist, ee));
      g_free (ee);
      g_free (alist);
    }
  else if (g_strcmp0 (m, "EvalDsl") == 0)
    {
      const gchar *dsl;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &dsl);
      args[0] = dsl;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (cmacs-podomation-eval-dsl \"%s\") \"DSL evaluated\")",
        args, 1);
    }
  else if (g_strcmp0 (m, "ReplEval") == 0)
    {
      const gchar *line;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &line);
      args[0] = line;
      cmacs_dbus_eval_to_reply_string (iv,
        "(let ((r (cmacs-podomation-repl-eval \"%s\")))"
        "  (format \"%%s: %%s\" (car r) (or (cdr r) \"\")))",
        args, 1);
    }
  else if (g_strcmp0 (m, "ListPods") == 0)
    pod_reply (iv, g_strdup
      ("(prin1-to-string (cmacs-podomation-list-pods))"));
  else if (g_strcmp0 (m, "ListModules") == 0)
    pod_reply (iv, g_strdup
      ("(prin1-to-string (cmacs-podomation-list-modules))"));
  else if (g_strcmp0 (m, "LoadFile") == 0)
    {
      const gchar *file;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &file);
      args[0] = file;
      cmacs_dbus_eval_to_reply_string (iv,
        "(let ((path (expand-file-name \"%s\")))"
        "  (cmacs-podomation-load-file path)"
        "  (format \"loaded %%s\" path))",
        args, 1);
    }
  else if (g_strcmp0 (m, "Reload") == 0)
    pod_reply (iv, g_strdup
      ("(progn (cmacs-podomation-reload) \"engine reloaded\")"));
  else if (g_strcmp0 (m, "SetContext") == 0)
    {
      GVariantIter *iter;
      gchar *alist;
      g_variant_get (p, "(a{ss})", &iter);
      alist = dict_to_alist (iter);
      g_variant_iter_free (iter);
      pod_reply (iv, g_strdup_printf
        ("(progn (cmacs-podomation-set-context %s) \"context set\")",
         alist));
      g_free (alist);
    }
  else if (g_strcmp0 (m, "Stats") == 0)
    pod_reply (iv, g_strdup
      ("(prin1-to-string (cmacs-podomation-stats))"));
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_podomation_register (GDBusConnection *conn,
                                      const gchar *path, GError **error)
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
cmacs_dbus_iface_podomation_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_PODOMATION */
