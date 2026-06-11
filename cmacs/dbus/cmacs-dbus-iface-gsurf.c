/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-gsurf.c --- gsurf embedded web browser via D-Bus.
 *
 * org.cmacs.Editor1.Gsurf
 *
 * MCP parity: mirrors the gsurf_* tools in
 * cmacs/mcp/cmacs-mcp-tools-gsurf.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  Like the
 * MCP layer, every method is a thin bridge into the
 * cmacs-gsurf-mcp-* helpers in lisp/cmacs/cmacs-gsurf.el, so the
 * buffer-resolution logic stays in one place (Elisp).
 *
 * Convention: an empty BUFFER argument means "the most recent gsurf
 * buffer" (elisp nil). */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_GSURF)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Gsurf'>"
  "    <method name='Open'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Navigate'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Back'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Forward'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Reload'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Stop'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='GetUri'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='uri' direction='out'/>"
  "    </method>"
  "    <method name='GetTitle'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='title' direction='out'/>"
  "    </method>"
  "    <method name='Current'>"
  "      <arg type='s' name='info' direction='out'/>"
  "    </method>"
  "    <method name='List'>"
  "      <arg type='s' name='buffers' direction='out'/>"
  "    </method>"
  "    <method name='ModulesList'>"
  "      <arg type='s' name='modules' direction='out'/>"
  "    </method>"
  "    <method name='EvalJs'>"
  "      <arg type='s' name='script' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetZoom'>"
  "      <arg type='d' name='level' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='LiteOpen'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ExtractText'>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='text' direction='out'/>"
  "    </method>"
  "    <method name='DownloadList'>"
  "      <arg type='s' name='downloads' direction='out'/>"
  "    </method>"
  "    <method name='DownloadCancel'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Snapshot'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='b' name='full_page' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PrintPdf'>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PermissionPolicy'>"
  "      <arg type='s' name='origin' direction='in'/>"
  "      <arg type='s' name='type' direction='in'/>"
  "      <arg type='s' name='verdict' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Build an elisp string literal, or "nil" when S is empty. */
static gchar *
str_or_nil (const gchar *s)
{
  gchar *esc, *out;
  if (s == NULL || *s == '\0')
    return g_strdup ("nil");
  esc = cmacs_dbus_lisp_escape (s);
  out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
gsurf_reply (GDBusMethodInvocation *iv, gchar *expr)
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

/* The (buffer-only) navigation verbs share one shape. */
static void
gsurf_verb_reply (GDBusMethodInvocation *iv, GVariant *p, const gchar *fn)
{
  const gchar *buffer;
  gchar *buf;
  g_variant_get (p, "(&s)", &buffer);
  buf = str_or_nil (buffer);
  gsurf_reply (iv, g_strdup_printf ("(%s %s)", fn, buf));
  g_free (buf);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Open") == 0)
    {
      const gchar *url;
      gchar *q;
      g_variant_get (p, "(&s)", &url);
      q = str_or_nil (url);
      gsurf_reply (iv, g_strdup_printf ("(cmacs-gsurf-mcp-open %s)", q));
      g_free (q);
    }
  else if (g_strcmp0 (m, "Navigate") == 0)
    {
      const gchar *url, *buffer;
      gchar *q, *buf;
      g_variant_get (p, "(&s&s)", &url, &buffer);
      q = str_or_nil (url);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-navigate %s %s)", q, buf));
      g_free (q); g_free (buf);
    }
  else if (g_strcmp0 (m, "Back") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-back");
  else if (g_strcmp0 (m, "Forward") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-forward");
  else if (g_strcmp0 (m, "Reload") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-reload");
  else if (g_strcmp0 (m, "Stop") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-stop");
  else if (g_strcmp0 (m, "GetUri") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-get-uri");
  else if (g_strcmp0 (m, "GetTitle") == 0)
    gsurf_verb_reply (iv, p, "cmacs-gsurf-mcp-get-title");
  else if (g_strcmp0 (m, "Current") == 0)
    gsurf_reply (iv, g_strdup ("(cmacs-gsurf-mcp-current)"));
  else if (g_strcmp0 (m, "List") == 0)
    gsurf_reply (iv, g_strdup ("(cmacs-gsurf-mcp-list)"));
  else if (g_strcmp0 (m, "ModulesList") == 0)
    gsurf_reply (iv, g_strdup ("(cmacs-gsurf-modules-list)"));
  else if (g_strcmp0 (m, "EvalJs") == 0)
    {
      const gchar *script, *buffer;
      gchar *q, *buf;
      g_variant_get (p, "(&s&s)", &script, &buffer);
      q = str_or_nil (script);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-eval-js %s %s)", q, buf));
      g_free (q); g_free (buf);
    }
  else if (g_strcmp0 (m, "SetZoom") == 0)
    {
      gdouble level;
      const gchar *buffer;
      gchar *buf;
      g_variant_get (p, "(d&s)", &level, &buffer);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-set-zoom %g %s)", level, buf));
      g_free (buf);
    }
  else if (g_strcmp0 (m, "LiteOpen") == 0)
    {
      const gchar *url;
      gchar *q;
      g_variant_get (p, "(&s)", &url);
      q = str_or_nil (url);
      gsurf_reply (iv,
        g_strdup_printf ("(progn (require 'cmacs-gsurf-lite) "
                         "(cmacs-gsurf-lite-mcp-open %s))", q));
      g_free (q);
    }
  else if (g_strcmp0 (m, "ExtractText") == 0)
    {
      const gchar *buffer;
      gchar *buf;
      g_variant_get (p, "(&s)", &buffer);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(progn (require 'cmacs-gsurf-lite) "
                         "(cmacs-gsurf-lite-mcp-extract-text %s))", buf));
      g_free (buf);
    }
  else if (g_strcmp0 (m, "DownloadList") == 0)
    gsurf_reply (iv,
      g_strdup ("(progn (require 'cmacs-gsurf-downloads) "
                "(cmacs-gsurf-mcp-download-list))"));
  else if (g_strcmp0 (m, "DownloadCancel") == 0)
    {
      gint64 id;
      g_variant_get (p, "(x)", &id);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-download-cancel %lld)",
                         (long long) id));
    }
  else if (g_strcmp0 (m, "Snapshot") == 0)
    {
      const gchar *file, *buffer;
      gboolean full;
      gchar *qf, *buf;
      g_variant_get (p, "(&sb&s)", &file, &full, &buffer);
      qf = str_or_nil (file);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-snapshot %s %s %s)",
                         qf, full ? "t" : "nil", buf));
      g_free (qf); g_free (buf);
    }
  else if (g_strcmp0 (m, "PrintPdf") == 0)
    {
      const gchar *file, *buffer;
      gchar *qf, *buf;
      g_variant_get (p, "(&s&s)", &file, &buffer);
      qf = str_or_nil (file);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-print-pdf %s %s)", qf, buf));
      g_free (qf); g_free (buf);
    }
  else if (g_strcmp0 (m, "PermissionPolicy") == 0)
    {
      const gchar *origin, *type, *verdict;
      gchar *qo, *qt, *qv;
      g_variant_get (p, "(&s&s&s)", &origin, &type, &verdict);
      qo = str_or_nil (origin);
      qt = str_or_nil (type);
      qv = str_or_nil (verdict);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-permission-policy %s %s %s)",
                         qo, qt, qv));
      g_free (qo); g_free (qt); g_free (qv);
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_gsurf_register (GDBusConnection *conn, const gchar *path,
                                 GError **error)
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
cmacs_dbus_iface_gsurf_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_GSURF */
