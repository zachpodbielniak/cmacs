/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-clipboard.c --- clipboard operations.
 * Mirrors cmacsgi copy/cut/paste/clip and adds direct Put/Get for
 * external producers/consumers that don't have a buffer region to
 * point at -- e.g. a CI pipeline pushing build output to the
 * clipboard, or a status-bar widget sampling the current selection. */

#include <config.h>
#ifdef HAVE_CMACS_GLIB
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include <gio/gio.h>

static const gchar *iface_xml =
  "<node><interface name='org.cmacs.Editor1.Clipboard'>"
  "  <method name='Copy'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Cut'><arg type='x' name='start' direction='in'/>"
  "    <arg type='x' name='end' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Paste'><arg type='s' name='ack' direction='out'/></method>"
  "  <method name='List'><arg type='s' name='entries' direction='out'/></method>"
  "  <method name='Put'>"
  "    <arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='PutSelection'>"
  "    <arg type='s' name='selection' direction='in'/>"
  "    <arg type='s' name='text' direction='in'/>"
  "    <arg type='s' name='ack' direction='out'/></method>"
  "  <method name='Get'>"
  "    <arg type='s' name='text' direction='out'/></method>"
  "  <method name='GetSelection'>"
  "    <arg type='s' name='selection' direction='in'/>"
  "    <arg type='s' name='text' direction='out'/></method>"
  "</interface></node>";

static GDBusNodeInfo *iface_info = NULL;

static void
on_method (GDBusConnection *c, const gchar *s, const gchar *o,
           const gchar *i, const gchar *m, GVariant *p,
           GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Copy") == 0 || g_strcmp0 (m, "Cut") == 0)
    {
      gint64 start, end;
      gchar sbuf[24], ebuf[24];
      const gchar *args[2];
      const gchar *fn = g_strcmp0 (m, "Copy") == 0
        ? "kill-ring-save" : "kill-region";
      gchar *tmpl;
      g_variant_get (p, "(xx)", &start, &end);
      g_snprintf (sbuf, sizeof sbuf, "%" G_GINT64_FORMAT, start);
      g_snprintf (ebuf, sizeof ebuf, "%" G_GINT64_FORMAT, end);
      args[0] = sbuf; args[1] = ebuf;
      tmpl = g_strdup_printf (
        "(progn (%s %%s %%s) \"ok\")", fn);
      cmacs_dbus_eval_to_reply (iv, tmpl, args, 2);
      g_free (tmpl);
    }
  else if (g_strcmp0 (m, "Paste") == 0)
    cmacs_dbus_eval_to_reply (iv, "(progn (yank) \"ok\")", NULL, 0);
  else if (g_strcmp0 (m, "List") == 0)
    cmacs_dbus_eval_to_reply (iv,
      "(mapconcat (lambda (s) (substring s 0 (min 80 (length s))))"
      " kill-ring \"|||\")", NULL, 0);
  else if (g_strcmp0 (m, "Put") == 0)
    {
      const gchar *text;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &text);
      args[0] = text;
      /* Push to kill-ring; if the user has select-enable-clipboard
         set (the Emacs default for graphical sessions), this also
         pushes to the system CLIPBOARD selection.  Force-set the
         system clipboard regardless so headless / non-pgtk callers
         still see it land. */
      cmacs_dbus_eval_to_reply (iv,
        "(progn (kill-new \"%s\")"
        " (when (fboundp 'gui-set-selection)"
        "   (condition-case nil"
        "     (gui-set-selection 'CLIPBOARD \"%s\")"
        "     (error nil)))"
        " \"ok\")",
        (const gchar *[]) { text, text }, 2);
    }
  else if (g_strcmp0 (m, "PutSelection") == 0)
    {
      const gchar *sel, *text;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &sel, &text);
      args[0] = sel; args[1] = text;
      /* PRIMARY / SECONDARY / CLIPBOARD per X11/Wayland spec.  Lisp
         expects an unquoted symbol, so we intern at the elisp side. */
      cmacs_dbus_eval_to_reply (iv,
        "(progn"
        " (when (fboundp 'gui-set-selection)"
        "   (gui-set-selection (intern \"%s\") \"%s\"))"
        " \"ok\")", args, 2);
    }
  else if (g_strcmp0 (m, "Get") == 0)
    /* Prefer the system CLIPBOARD over kill-ring head -- matches
       what `yank' would actually pick up when select-enable-clipboard
       is t.  Falls back to the kill-ring on terminals / when no
       gui-get-selection is available. */
    cmacs_dbus_eval_to_reply (iv,
      "(or (and (fboundp 'gui-get-selection)"
      "         (condition-case nil"
      "           (gui-get-selection 'CLIPBOARD 'STRING)"
      "           (error nil)))"
      "    (and kill-ring (car kill-ring))"
      "    \"\")", NULL, 0);
  else if (g_strcmp0 (m, "GetSelection") == 0)
    {
      const gchar *sel;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &sel);
      args[0] = sel;
      cmacs_dbus_eval_to_reply (iv,
        "(or (and (fboundp 'gui-get-selection)"
        "         (condition-case nil"
        "           (gui-get-selection (intern \"%s\") 'STRING)"
        "           (error nil)))"
        "    \"\")", args, 1);
    }
}

static const GDBusInterfaceVTable vtable = { on_method, NULL, NULL, { NULL } };

guint
cmacs_dbus_iface_clipboard_register (GDBusConnection *conn, const gchar *path,
                                      GError **error)
{
  if (iface_info == NULL) {
    iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
    if (iface_info == NULL) return 0;
  }
  return g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
}

void
cmacs_dbus_iface_clipboard_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL) { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif
