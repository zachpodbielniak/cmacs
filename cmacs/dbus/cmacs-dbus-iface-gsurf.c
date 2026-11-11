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
  "    <method name='Click'>"
  "      <arg type='d' name='x' direction='in'/>"
  "      <arg type='d' name='y' direction='in'/>"
  "      <arg type='i' name='button' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='TypeText'>"
  "      <arg type='s' name='text' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='PressKey'>"
  "      <arg type='s' name='key' direction='in'/>"
  "      <arg type='s' name='modifiers' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ClickElement'>"
  "      <arg type='s' name='selector' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='SetCookie'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='value' direction='in'/>"
  "      <arg type='s' name='domain' direction='in'/>"
  "      <arg type='s' name='path' direction='in'/>"
  "      <arg type='b' name='secure' direction='in'/>"
  "      <arg type='b' name='http_only' direction='in'/>"
  "      <arg type='x' name='expires' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ToggleModule'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='enabled' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='RunAction'>"
  "      <arg type='s' name='action' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListActions'>"
  "      <arg type='s' name='actions' direction='out'/>"
  "    </method>"
  "    <method name='ListContainers'>"
  "      <arg type='s' name='containers' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Build an elisp string literal (always, even for ""), escaped with
   cmacs_dispatch_lisp_escape -- never g_strescape. */
static gchar *
str_lit (const gchar *s)
{
  gchar *esc = cmacs_dispatch_lisp_escape (s);
  gchar *out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

/* Build an elisp string literal, or "nil" when S is empty. */
static gchar *
str_or_nil (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return g_strdup ("nil");
  return str_lit (s);
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
  /* gsurf 0.5 control surface (helpers in lisp/cmacs/cmacs-gsurf-control.el) */
  else if (g_strcmp0 (m, "Click") == 0)
    {
      gdouble x, y;
      gint button;
      const gchar *buffer;
      gchar xs[G_ASCII_DTOSTR_BUF_SIZE], ys[G_ASCII_DTOSTR_BUF_SIZE];
      gchar *buf;
      g_variant_get (p, "(ddi&s)", &x, &y, &button, &buffer);
      if (button < 1 || button > 3)
        button = 1;
      g_ascii_dtostr (xs, sizeof xs, x);
      g_ascii_dtostr (ys, sizeof ys, y);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-click %s %s %d %s)",
                         xs, ys, button, buf));
      g_free (buf);
    }
  else if (g_strcmp0 (m, "TypeText") == 0)
    {
      const gchar *text, *buffer;
      gchar *q, *buf;
      g_variant_get (p, "(&s&s)", &text, &buffer);
      q = str_lit (text);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-type-text %s %s)", q, buf));
      g_free (q); g_free (buf);
    }
  else if (g_strcmp0 (m, "PressKey") == 0)
    {
      const gchar *key, *mods, *buffer;
      gchar *qk, *qm, *buf;
      g_variant_get (p, "(&s&s&s)", &key, &mods, &buffer);
      qk = str_lit (key);
      qm = str_or_nil (mods);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-press-key %s %s %s)", qk, qm, buf));
      g_free (qk); g_free (qm); g_free (buf);
    }
  else if (g_strcmp0 (m, "ClickElement") == 0)
    {
      const gchar *sel, *buffer;
      gchar *q, *buf;
      g_variant_get (p, "(&s&s)", &sel, &buffer);
      q = str_lit (sel);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-click-element %s %s)", q, buf));
      g_free (q); g_free (buf);
    }
  else if (g_strcmp0 (m, "SetCookie") == 0)
    {
      const gchar *name, *value, *domain, *path, *buffer;
      gboolean secure, http_only;
      gint64 expires;
      gchar *qn, *qv, *qd, *qp, *buf;
      g_variant_get (p, "(&s&s&s&sbbx&s)", &name, &value, &domain, &path,
                     &secure, &http_only, &expires, &buffer);
      qn = str_lit (name);
      qv = str_lit (value);
      qd = str_lit (domain);
      qp = str_or_nil (path);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-set-cookie %s %s %s %s %s %s %lld %s)",
                         qn, qv, qd, qp, secure ? "t" : "nil",
                         http_only ? "t" : "nil", (long long) expires, buf));
      g_free (qn); g_free (qv); g_free (qd); g_free (qp); g_free (buf);
    }
  else if (g_strcmp0 (m, "ToggleModule") == 0)
    {
      const gchar *name;
      gboolean enabled;
      gchar *q;
      g_variant_get (p, "(&sb)", &name, &enabled);
      q = str_lit (name);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-toggle-module %s %s)", q,
                         enabled ? "t" : "nil"));
      g_free (q);
    }
  else if (g_strcmp0 (m, "RunAction") == 0)
    {
      const gchar *action, *buffer;
      gchar *q, *buf;
      g_variant_get (p, "(&s&s)", &action, &buffer);
      q = str_lit (action);
      buf = str_or_nil (buffer);
      gsurf_reply (iv,
        g_strdup_printf ("(cmacs-gsurf-mcp-run-action %s %s)", q, buf));
      g_free (q); g_free (buf);
    }
  else if (g_strcmp0 (m, "ListActions") == 0)
    gsurf_reply (iv, g_strdup ("(cmacs-gsurf-mcp-list-actions)"));
  else if (g_strcmp0 (m, "ListContainers") == 0)
    gsurf_reply (iv, g_strdup ("(cmacs-gsurf-mcp-list-containers)"));
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
