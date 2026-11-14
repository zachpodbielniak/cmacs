/* cmacs-dbus-iface-lql.c --- org.cmacs.Editor1.Lql: LQL over D-Bus
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The D-Bus twin of the lql_query / lql_sources tools, and what
 * `emacsctl lql' talks to.  Queries are read-only by construction --
 * LQL has no statement that writes -- so this surface needs no gate
 * beyond the session bus itself.
 *
 * Every method evaluates a small, fixed Lisp form through the eval
 * dispatcher; the only caller-supplied text is the query, which goes in
 * through cmacs_dbus_lisp_escape (never g_strescape: the reader turns
 * its octal escapes into raw bytes).  `cmacs-lql-run-sync' runs the
 * query on the LQL worker thread and polls it with
 * `accept-process-output', which is safe inside a dispatch.  */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_LQL)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Lql'>"
  "    <method name='Query'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='i' name='max_rows' direction='in'/>"
  "      <arg type='s' name='table' direction='out'/>"
  "    </method>"
  "    <method name='QueryJson'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='i' name='max_rows' direction='in'/>"
  "      <arg type='s' name='json' direction='out'/>"
  "    </method>"
  "    <method name='Explain'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='s' name='plan' direction='out'/>"
  "    </method>"
  "    <method name='Sources'>"
  "      <arg type='s' name='sources' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Evaluate EXPR (taking ownership) and return its string value.  */
static void
eval_to_reply (GDBusMethodInvocation *iv, gchar *expr)
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
  g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", result));
  g_free (result);
}

/* The rows a caller asked for: 1..10000, or 100 for zero/negative.  */
static gint
clamp_rows (gint32 n)
{
  if (n <= 0)
    return 100;
  return n > 10000 ? 10000 : n;
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Query") == 0 || g_strcmp0 (m, "QueryJson") == 0)
    {
      const gchar *query;
      gint32 max_rows;
      gchar *q;
      gboolean json = g_strcmp0 (m, "QueryJson") == 0;

      g_variant_get (p, "(&si)", &query, &max_rows);
      if (*query == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing query");
          return;
        }
      q = cmacs_dbus_lisp_escape (query);
      /* Errors come back as the reply text ("error: ..."), not a D-Bus
         error: a bad query is an answer, the way a calc error is.  */
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-lql)"
        " (let ((p (cmacs-lql-run-sync \"%s\" :max-rows %d %s)))"
        "  (pcase (car p)"
        "   (:ok %s)"
        "   (:error (concat \"error: \" (cadr p)))"
        "   (_ \"error: cancelled\"))))",
        q, clamp_rows (max_rows),
        json ? "" : ":text-width 200",
        json ? "(plist-get (cdr p) :json)"
             : "(format \"%s\\n(%d rows, %.3fs)\" "
               "(or (plist-get (cdr p) :text) \"\") "
               "(plist-get (cdr p) :rows) (plist-get (cdr p) :elapsed))"));
      g_free (q);
    }
  else if (g_strcmp0 (m, "Explain") == 0)
    {
      const gchar *query;
      gchar *q;

      g_variant_get (p, "(&s)", &query);
      q = cmacs_dbus_lisp_escape (query);
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-lql)"
        " (condition-case e (cmacs-lql--explain \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        q));
      g_free (q);
    }
  else if (g_strcmp0 (m, "Sources") == 0)
    {
      eval_to_reply (iv, g_strdup (
        "(progn (require 'cmacs-lql)"
        " (condition-case e (mapconcat #'identity (cmacs-lql--sources) \"\\n\")"
        "  (error (format \"error: %s\" (error-message-string e)))))"));
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_lql_register (GDBusConnection *conn,
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
cmacs_dbus_iface_lql_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_LQL */
