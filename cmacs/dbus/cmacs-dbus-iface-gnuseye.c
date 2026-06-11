/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-gnuseye.c --- GNU's Eye situational-awareness globe
 * via D-Bus.
 *
 * org.cmacs.Editor1.GnusEye
 *
 * MCP parity: mirrors the gnuseye_* tools in
 * cmacs/mcp/cmacs-mcp-tools-gnuseye.c (sync discipline: adding a tool
 * there requires a matching method here, and vice versa).  The elisp
 * bodies are identical to the MCP handlers'. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_GNUSEYE)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.GnusEye'>"
  "    <method name='Open'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListLayers'>"
  "      <arg type='s' name='layers' direction='out'/>"
  "    </method>"
  "    <method name='ToggleLayer'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='FlyTo'>"
  "      <arg type='d' name='lat' direction='in'/>"
  "      <arg type='d' name='lon' direction='in'/>"
  "      <arg type='d' name='range' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Refresh'>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='QueryEntities'>"
  "      <arg type='s' name='kind' direction='in'/>"
  "      <arg type='d' name='west' direction='in'/>"
  "      <arg type='d' name='east' direction='in'/>"
  "      <arg type='d' name='south' direction='in'/>"
  "      <arg type='d' name='north' direction='in'/>"
  "      <arg type='i' name='limit' direction='in'/>"
  "      <arg type='s' name='entities_json' direction='out'/>"
  "    </method>"
  "    <method name='Brief'>"
  "      <arg type='s' name='summary' direction='out'/>"
  "    </method>"
  "    <method name='AddGeofence'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='d' name='lat' direction='in'/>"
  "      <arg type='d' name='lon' direction='in'/>"
  "      <arg type='d' name='radius_km' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Cii'>"
  "      <arg type='s' name='scores_json' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
ge_reply (GDBusMethodInvocation *iv, gchar *expr)
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

/* Quote S as an elisp string literal ("" when empty). */
static gchar *
ge_lisp_str (const gchar *s)
{
  gchar *esc, *out;
  esc = cmacs_dbus_lisp_escape (s != NULL ? s : "");
  out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Open") == 0)
    ge_reply (iv, g_strdup
      ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye) \"opened\")"));
  else if (g_strcmp0 (m, "ListLayers") == 0)
    ge_reply (iv, g_strdup
      ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye--load-layers)"
       " (let (r) (maphash (lambda (k v)"
       "   (push (list k :on (and (cmacs-gnuseye-layer-enabled v) t)"
       "               :group (cmacs-gnuseye-layer-group v)"
       "               :title (cmacs-gnuseye-layer-title v)) r))"
       "  cmacs-gnuseye--layers) (format \"%S\" (nreverse r))))"));
  else if (g_strcmp0 (m, "ToggleLayer") == 0)
    {
      const gchar *name;
      gchar *qn;
      g_variant_get (p, "(&s)", &name);
      qn = ge_lisp_str (name);
      ge_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye--load-layers)"
         " (let ((l (gethash (intern %s) cmacs-gnuseye--layers)))"
         "  (if (null l) \"unknown layer\""
         "    (if (cmacs-gnuseye-layer-enabled l)"
         "        (progn (cmacs-gnuseye--disable-layer l)"
         "               (format \"%%s off\" %s))"
         "      (progn (cmacs-gnuseye--enable-layer l)"
         "             (format \"%%s on\" %s))))))",
         qn, qn, qn));
      g_free (qn);
    }
  else if (g_strcmp0 (m, "FlyTo") == 0)
    {
      gdouble lat, lon, range;
      g_variant_get (p, "(ddd)", &lat, &lon, &range);
      if (range <= 0.0)
        range = 14.0;
      ge_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-gnuseye)"
         " (if (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))"
         "   (progn (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer %g %g %g t)"
         "          (format \"flew to %g,%g\"))"
         "  \"no globe open\"))",
         lat, lon, range, lat, lon));
    }
  else if (g_strcmp0 (m, "Refresh") == 0)
    ge_reply (iv, g_strdup
      ("(progn (require 'cmacs-gnuseye) (cmacs-gnuseye-refresh-all)"
       " \"refreshing\")"));
  else if (g_strcmp0 (m, "QueryEntities") == 0)
    {
      const gchar *kind;
      gdouble w, e, so, no;
      gint limit;
      gchar *qk;
      g_variant_get (p, "(&sddddi)", &kind, &w, &e, &so, &no, &limit);
      if (limit <= 0)
        limit = 200;
      qk = (kind != NULL && *kind != '\0')
        ? ge_lisp_str (kind) : g_strdup ("nil");
      ge_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-gnuseye)"
         " (let ((kf %s) (rows nil) (n 0))"
         "  (catch 'done (maphash (lambda (id e)"
         "    (when (and (or (null kf) (eq (plist-get e :kind) (intern kf)))"
         "               (>= (or (plist-get e :lat) 0) %g)"
         "               (<= (or (plist-get e :lat) 0) %g)"
         "               (>= (or (plist-get e :lon) 0) %g)"
         "               (<= (or (plist-get e :lon) 0) %g))"
         "      (push (list :id id :kind (plist-get e :kind)"
         "                  :label (plist-get e :label)"
         "                  :lat (plist-get e :lat)"
         "                  :lon (plist-get e :lon)) rows)"
         "      (when (>= (setq n (1+ n)) %d) (throw 'done nil))))"
         "   cmacs-gnuseye--id-index))"
         "  (require 'json) (json-encode (nreverse rows))))",
         qk, so, no, w, e, limit));
      g_free (qk);
    }
  else if (g_strcmp0 (m, "Brief") == 0)
    ge_reply (iv, g_strdup
      ("(progn (require 'cmacs-gnuseye)"
       " (let ((counts (make-hash-table :test 'eq)) (total 0))"
       "  (maphash (lambda (_ e) (setq total (1+ total))"
       "    (cl-incf (gethash (or (plist-get e :kind) 'generic) counts 0)))"
       "   cmacs-gnuseye--id-index)"
       "  (let (parts)"
       "   (maphash (lambda (k c) (push (format \"%s:%d\" k c) parts)) counts)"
       "   (format \"%d entities indexed; by kind: %s\""
       "     total (string-join (sort parts #'string<) \", \")))))"));
  else if (g_strcmp0 (m, "AddGeofence") == 0)
    {
      const gchar *name;
      gdouble lat, lon, rad;
      gchar *qn;
      g_variant_get (p, "(&sddd)", &name, &lat, &lon, &rad);
      if (rad <= 0.0)
        rad = 100.0;
      qn = ge_lisp_str ((name != NULL && *name != '\0') ? name : "fence");
      ge_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-gnuseye) (require 'cmacs-gnuseye-geofence)"
         " (cmacs-gnuseye-add-geofence %s %g %g %g)"
         " (format \"geofence %%s @ %g,%g r=%gkm\" %s))",
         qn, lat, lon, rad, lat, lon, rad, qn));
      g_free (qn);
    }
  else if (g_strcmp0 (m, "Cii") == 0)
    ge_reply (iv, g_strdup
      ("(progn (require 'cmacs-gnuseye) (require 'cmacs-gnuseye-intel)"
       " (cmacs-gnuseye-intel--compute-cii)"
       " (let (r) (maphash (lambda (iso v) (push (cons iso v) r))"
       "   cmacs-gnuseye-cii--scores)"
       "  (require 'json)"
       "  (json-encode (seq-take (sort r (lambda (x y) (> (cdr x) (cdr y))))"
       "                         15))))"));
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_gnuseye_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_gnuseye_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_GNUSEYE */
