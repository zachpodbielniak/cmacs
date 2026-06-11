/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-lrg.c --- libregnum 3D level editor via D-Bus.
 *
 * org.cmacs.Editor1.Lrg
 *
 * MCP parity: mirrors the lrg_editor_* tools in
 * cmacs/mcp/cmacs-mcp-tools-libregnum.c (sync discipline: adding a
 * tool there requires a matching method here, and vice versa).  The
 * elisp bodies are identical to the MCP handlers'. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_LIBREGNUM)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

/* Keep in sync with LRG_EDITOR_BUF in cmacs-mcp-tools-libregnum.c. */
#define LRG_EDITOR_BUF "*cmacs-libregnum editor*"

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Lrg'>"
  "    <method name='Open'>"
  "      <arg type='s' name='path' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Play'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Stop'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Save'>"
  "      <arg type='s' name='path' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Select'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Move'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='d' name='x' direction='in'/>"
  "      <arg type='d' name='y' direction='in'/>"
  "      <arg type='d' name='z' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Delete'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='AddPrimitive'>"
  "      <arg type='x' name='primitive' direction='in'/>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='AddVisual'>"
  "      <arg type='x' name='kind' direction='in'/>"
  "      <arg type='s' name='asset' direction='in'/>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ObjectTree'>"
  "      <arg type='s' name='tree' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
lrg_reply (GDBusMethodInvocation *iv, gchar *expr)
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

/* Quote S as an elisp string literal, falling back to FALLBACK when
 * empty. */
static gchar *
lrg_lisp_str (const gchar *s, const gchar *fallback)
{
  gchar *esc, *out;
  if (s == NULL || *s == '\0')
    s = fallback;
  esc = cmacs_dbus_lisp_escape (s != NULL ? s : "");
  out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

/* Wrap BODY so it runs with `buf' bound to the active editor buffer,
 * erroring nicely when no editor is open.  Takes ownership of BODY.
 * Mirrors lrg_with_editor in cmacs-mcp-tools-libregnum.c. */
static gchar *
lrg_with_editor (gchar *body)
{
  gchar *out = g_strdup_printf
    ("(let ((buf (get-buffer \"%s\")))"
     " (if (and buf (cmacs-libregnum-editor-active-p buf)) (progn %s)"
     "   \"No libregnum editor open (M-x cmacs-libregnum-editor)\"))",
     LRG_EDITOR_BUF, body);
  g_free (body);
  return out;
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Open") == 0)
    {
      const gchar *path;
      gchar *qp;
      g_variant_get (p, "(&s)", &path);
      qp = lrg_lisp_str (path, "level.rlevel");
      lrg_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-libregnum) (cmacs-libregnum-editor %s)"
         " \"opened\")", qp));
      g_free (qp);
    }
  else if (g_strcmp0 (m, "Play") == 0)
    lrg_reply (iv, lrg_with_editor (g_strdup
      ("(if (cmacs-libregnum-editor-play buf) \"playing\""
       " \"could not instantiate\")")));
  else if (g_strcmp0 (m, "Stop") == 0)
    lrg_reply (iv, lrg_with_editor (g_strdup
      ("(progn (cmacs-libregnum-editor-stop buf) \"stopped\")")));
  else if (g_strcmp0 (m, "Save") == 0)
    {
      const gchar *path;
      gchar *qp;
      g_variant_get (p, "(&s)", &path);
      qp = lrg_lisp_str (path, "level.rlevel");
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(progn (cmacs-libregnum-editor-save buf %s) \"saved\")", qp)));
      g_free (qp);
    }
  else if (g_strcmp0 (m, "Select") == 0)
    {
      gint64 id;
      g_variant_get (p, "(x)", &id);
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(progn (cmacs-libregnum-editor-select buf %" G_GINT64_FORMAT
         ") \"selected\")", id)));
    }
  else if (g_strcmp0 (m, "Move") == 0)
    {
      gint64 id;
      gdouble x, y, z;
      g_variant_get (p, "(xddd)", &id, &x, &y, &z);
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(progn (cmacs-libregnum-editor-set-position buf %" G_GINT64_FORMAT
         " %g %g %g) \"moved\")", id, x, y, z)));
    }
  else if (g_strcmp0 (m, "Delete") == 0)
    {
      gint64 id;
      g_variant_get (p, "(x)", &id);
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(progn (cmacs-libregnum-editor-delete buf %" G_GINT64_FORMAT
         ") \"deleted\")", id)));
    }
  else if (g_strcmp0 (m, "AddPrimitive") == 0)
    {
      gint64 prim;
      const gchar *name;
      gchar *qn;
      g_variant_get (p, "(x&s)", &prim, &name);
      qn = lrg_lisp_str (name, "Object");
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(format \"added node %%S\""
         " (cmacs-libregnum-editor-add-primitive buf %" G_GINT64_FORMAT
         " %s))", prim, qn)));
      g_free (qn);
    }
  else if (g_strcmp0 (m, "AddVisual") == 0)
    {
      gint64 kind;
      const gchar *asset, *name;
      gchar *qa, *qn;
      g_variant_get (p, "(x&s&s)", &kind, &asset, &name);
      qa = (*asset != '\0') ? lrg_lisp_str (asset, NULL) : g_strdup ("nil");
      qn = lrg_lisp_str (name, "Object");
      lrg_reply (iv, lrg_with_editor (g_strdup_printf
        ("(format \"added node %%S\""
         " (cmacs-libregnum-editor-add-visual buf %" G_GINT64_FORMAT
         " %s %s))", kind, qa, qn)));
      g_free (qa);
      g_free (qn);
    }
  else if (g_strcmp0 (m, "ObjectTree") == 0)
    lrg_reply (iv, lrg_with_editor (g_strdup
      ("(format \"%S\" (cmacs-libregnum-tree-nodes buf))")));
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_lrg_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_lrg_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_LIBREGNUM */
