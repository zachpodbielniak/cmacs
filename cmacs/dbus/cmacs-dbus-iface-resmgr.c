/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-resmgr.c --- Frame / Window / Process manager
 * interfaces (Phase 2).
 *
 * Three thin root-level managers at /org/cmacs/Editor:
 *
 *   org.cmacs.Editor1.FrameManager
 *     List       () -> as            visible frame indices as strings
 *     Selected   () -> i             index of selected-frame
 *     Count      () -> i
 *     RaiseAll   () -> b
 *
 *   org.cmacs.Editor1.WindowManager
 *     List       () -> as            window IDs
 *     Selected   () -> s
 *     Count      () -> i
 *     SplitBelow () -> b
 *     SplitRight () -> b
 *     Other      () -> s             switch-to-other-window, returns new buf
 *
 *   org.cmacs.Editor1.ProcessManager
 *     List       () -> as            process names
 *     Status     (s name) -> s       run/stop/exit/...
 *     Pid        (s name) -> i
 *     Kill       (s name) -> b
 *
 * Each iface registers independently via its own vtable. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

/* ── Helpers (mirrors bufmgr) ─────────────────────────────────── */

static gchar *
strip_quotes (gchar *s)
{
  size_t len = s ? strlen (s) : 0;
  if (len >= 2 && s[0] == '"' && s[len - 1] == '"')
    {
      memmove (s, s + 1, len - 2);
      s[len - 2] = '\0';
    }
  return s;
}

static gboolean
result_is_t (const gchar *r)
{
  return g_strcmp0 (r, "t") == 0;
}

/* ── FrameManager ─────────────────────────────────────────────── */

static const gchar *frame_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.FrameManager'>"
  "    <method name='List'>"
  "      <arg type='as' name='ids' direction='out'/>"
  "    </method>"
  "    <method name='Selected'>"
  "      <arg type='i' name='index' direction='out'/>"
  "    </method>"
  "    <method name='Count'>"
  "      <arg type='i' name='count' direction='out'/>"
  "    </method>"
  "    <method name='RaiseAll'>"
  "      <arg type='b' name='ok' direction='out'/>"
  "    </method>"
  "    <signal name='FrameAdded'>"
  "      <arg type='i' name='index'/>"
  "    </signal>"
  "    <signal name='FrameRemoved'>"
  "      <arg type='i' name='index'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *frame_info = NULL;

static void
frame_method (GDBusConnection *c, const gchar *s, const gchar *o,
              const gchar *i, const gchar *m, GVariant *p,
              GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  gchar *r;
  (void) c; (void) s; (void) o; (void) i; (void) p; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      r = cmacs_dispatch_eval (
        "(mapconcat (lambda (f) (format \"%d\" (frame-parameter f 'name)))"
        " (frame-list) \" \")", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      {
        GVariantBuilder b;
        gchar **toks = g_strsplit (r, " ", -1);
        gsize k;
        g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
        for (k = 0; toks[k] != NULL; k++)
          if (toks[k][0] != '\0')
            g_variant_builder_add (&b, "s", toks[k]);
        g_strfreev (toks); g_free (r);
        g_dbus_method_invocation_return_value (
          iv, g_variant_new ("(as)", &b));
      }
    }
  else if (g_strcmp0 (m, "Selected") == 0)
    {
      r = cmacs_dispatch_eval (
        "(or (cl-position (selected-frame) (frame-list)) -1)", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(i)", (gint32) g_ascii_strtoll (r, NULL, 10)));
      g_free (r);
    }
  else if (g_strcmp0 (m, "Count") == 0)
    {
      r = cmacs_dispatch_eval ("(length (frame-list))", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(i)", (gint32) g_ascii_strtoll (r, NULL, 10)));
      g_free (r);
    }
  else if (g_strcmp0 (m, "RaiseAll") == 0)
    {
      r = cmacs_dispatch_eval (
        "(progn (mapc #'raise-frame (frame-list)) t)", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (
        iv, g_variant_new ("(b)", result_is_t (r)));
      g_free (r);
    }
}

static const GDBusInterfaceVTable frame_vtable = {
  frame_method, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_framemgr_register (GDBusConnection *conn, const gchar *path,
                                     GError **error)
{
  if (frame_info == NULL)
    {
      frame_info = g_dbus_node_info_new_for_xml (frame_xml, error);
      if (frame_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, frame_info->interfaces[0], &frame_vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_framemgr_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (frame_info != NULL) { g_dbus_node_info_unref (frame_info); frame_info = NULL; }
}

/* ── WindowManager ────────────────────────────────────────────── */

static const gchar *win_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.WindowManager'>"
  "    <method name='List'>"
  "      <arg type='as' name='ids' direction='out'/>"
  "    </method>"
  "    <method name='Selected'>"
  "      <arg type='s' name='id' direction='out'/>"
  "    </method>"
  "    <method name='Count'>"
  "      <arg type='i' name='count' direction='out'/>"
  "    </method>"
  "    <method name='SplitBelow'>"
  "      <arg type='b' name='ok' direction='out'/>"
  "    </method>"
  "    <method name='SplitRight'>"
  "      <arg type='b' name='ok' direction='out'/>"
  "    </method>"
  "    <method name='Other'>"
  "      <arg type='s' name='new_buffer_name' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *win_info = NULL;

static void
win_method (GDBusConnection *c, const gchar *s, const gchar *o,
            const gchar *i, const gchar *m, GVariant *p,
            GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  gchar *r;
  (void) c; (void) s; (void) o; (void) i; (void) p; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      r = cmacs_dispatch_eval (
        "(mapconcat (lambda (w) (format \"win-%d\" (window-total-width w)))"
        " (window-list) \" \")", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      {
        GVariantBuilder b;
        gchar **toks = g_strsplit (r, " ", -1);
        gsize k;
        g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
        for (k = 0; toks[k] != NULL; k++)
          if (toks[k][0] != '\0')
            g_variant_builder_add (&b, "s", toks[k]);
        g_strfreev (toks); g_free (r);
        g_dbus_method_invocation_return_value (iv,
          g_variant_new ("(as)", &b));
      }
    }
  else if (g_strcmp0 (m, "Selected") == 0)
    {
      r = cmacs_dispatch_eval (
        "(format \"win-%d\" (window-total-width (selected-window)))", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", r));
      g_free (r);
    }
  else if (g_strcmp0 (m, "Count") == 0)
    {
      r = cmacs_dispatch_eval ("(length (window-list))", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (iv,
        g_variant_new ("(i)", (gint32) g_ascii_strtoll (r, NULL, 10)));
      g_free (r);
    }
  else if (g_strcmp0 (m, "SplitBelow") == 0
           || g_strcmp0 (m, "SplitRight") == 0)
    {
      const gchar *expr = g_strcmp0 (m, "SplitBelow") == 0
        ? "(progn (split-window-below) t)"
        : "(progn (split-window-right) t)";
      r = cmacs_dispatch_eval (expr, &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (iv,
        g_variant_new ("(b)", result_is_t (r)));
      g_free (r);
    }
  else if (g_strcmp0 (m, "Other") == 0)
    {
      r = cmacs_dispatch_eval (
        "(progn (other-window 1) (buffer-name))", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", r));
      g_free (r);
    }
}

static const GDBusInterfaceVTable win_vtable = {
  win_method, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_winmgr_register (GDBusConnection *conn, const gchar *path,
                                   GError **error)
{
  if (win_info == NULL)
    {
      win_info = g_dbus_node_info_new_for_xml (win_xml, error);
      if (win_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, win_info->interfaces[0], &win_vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_winmgr_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (win_info != NULL) { g_dbus_node_info_unref (win_info); win_info = NULL; }
}

/* ── ProcessManager ───────────────────────────────────────────── */

static const gchar *proc_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.ProcessManager'>"
  "    <method name='List'>"
  "      <arg type='as' name='names' direction='out'/>"
  "    </method>"
  "    <method name='Status'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Pid'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='i' name='pid' direction='out'/>"
  "    </method>"
  "    <method name='Kill'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='b' name='killed' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *proc_info = NULL;

static void
proc_method (GDBusConnection *c, const gchar *s, const gchar *o,
             const gchar *i, const gchar *m, GVariant *p,
             GDBusMethodInvocation *iv, gpointer u)
{
  GError *err = NULL;
  gchar *r;
  const gchar *name;
  gchar *escaped, *elisp;
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    {
      r = cmacs_dispatch_eval (
        "(mapconcat #'process-name (process-list) \"|||\")", &err);
      if (r == NULL) { cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      {
        GVariantBuilder b;
        gchar **toks = g_strsplit (r, "|||", -1);
        gsize k;
        g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
        for (k = 0; toks[k] != NULL; k++)
          if (toks[k][0] != '\0')
            g_variant_builder_add (&b, "s", toks[k]);
        g_strfreev (toks); g_free (r);
        g_dbus_method_invocation_return_value (iv,
          g_variant_new ("(as)", &b));
      }
      return;
    }

  g_variant_get (p, "(&s)", &name);
  escaped = cmacs_dbus_lisp_escape (name);

  if (g_strcmp0 (m, "Status") == 0)
    {
      elisp = g_strdup_printf (
        "(let ((p (get-process \"%s\"))) "
        " (if p (symbol-name (process-status p)) \"none\"))", escaped);
      r = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      if (r == NULL) { g_free (escaped); cmacs_dbus_return_gerror (iv, err); return; }
      strip_quotes (r);
      g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", r));
      g_free (r);
    }
  else if (g_strcmp0 (m, "Pid") == 0)
    {
      elisp = g_strdup_printf (
        "(let ((p (get-process \"%s\"))) "
        " (if p (or (process-id p) -1) -1))", escaped);
      r = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      if (r == NULL) { g_free (escaped); cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (iv,
        g_variant_new ("(i)", (gint32) g_ascii_strtoll (r, NULL, 10)));
      g_free (r);
    }
  else if (g_strcmp0 (m, "Kill") == 0)
    {
      elisp = g_strdup_printf (
        "(let ((p (get-process \"%s\"))) "
        " (and p (delete-process p) t))", escaped);
      r = cmacs_dispatch_eval (elisp, &err);
      g_free (elisp);
      if (r == NULL) { g_free (escaped); cmacs_dbus_return_gerror (iv, err); return; }
      g_dbus_method_invocation_return_value (iv,
        g_variant_new ("(b)", result_is_t (r)));
      g_free (r);
    }
  g_free (escaped);
}

static const GDBusInterfaceVTable proc_vtable = {
  proc_method, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_procmgr_register (GDBusConnection *conn, const gchar *path,
                                    GError **error)
{
  if (proc_info == NULL)
    {
      proc_info = g_dbus_node_info_new_for_xml (proc_xml, error);
      if (proc_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, proc_info->interfaces[0], &proc_vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_procmgr_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (proc_info != NULL) { g_dbus_node_info_unref (proc_info); proc_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
