/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-log.c --- *Messages* access and live log signal.
 *
 * org.cmacs.Editor1.Log
 *
 *   RecentMessages(n) -> s      tail of *Messages* (MCP parity with
 *                               recent_messages in
 *                               cmacs-mcp-tools-debug.c)
 *   signal MessageLogged(s)     one signal per new *Messages* line
 *
 * MessageLogged is driven by a 500 ms GLib timeout on the cmacs
 * GMainContext that diffs *Messages* against the last seen end
 * position.  Polling (rather than hooking message_dolog in xdisp.c)
 * keeps this entirely in cmacs-owned code per the upstream-merge
 * discipline, and catches BOTH C- and Lisp-originated messages.  The
 * tick is cheap: one safe-dispatched elisp form; emission itself does
 * no Lisp work and never writes to *Messages*, so it cannot recurse.
 * Lines are batched per tick, which bounds signal floods at the rate
 * messages are actually logged. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-glib-loop.h"

#include <gio/gio.h>
#include <stdlib.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Log'>"
  "    <method name='RecentMessages'>"
  "      <arg type='i' name='lines' direction='in'/>"
  "      <arg type='s' name='messages' direction='out'/>"
  "    </method>"
  "    <signal name='MessageLogged'>"
  "      <arg type='s' name='line'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Watcher state. */
static GSource *log_source = NULL;
static glong    log_last_end = -1;   /* -1: not yet initialized */

/* ── MessageLogged watcher ─────────────────────────────────────────── */

static gboolean
log_tick (gpointer user_data)
{
  gchar *expr;
  gchar *result;
  gchar *nl;
  glong new_end;

  (void) user_data;

  /* First tick: record the current end so history is not replayed. */
  if (log_last_end < 0)
    {
      result = cmacs_dispatch_eval_string (
        "(if (get-buffer \"*Messages*\")"
        "    (with-current-buffer \"*Messages*\""
        "      (number-to-string (point-max)))"
        "  \"1\")", NULL);
      if (result != NULL)
        {
          log_last_end = strtol (result, NULL, 10);
          g_free (result);
        }
      return G_SOURCE_CONTINUE;
    }

  expr = g_strdup_printf (
    "(if (get-buffer \"*Messages*\")"
    "    (with-current-buffer \"*Messages*\""
    "      (let* ((end (point-max))"
    "             (start (if (or (> %ld end) (< %ld (point-min)))"
    "                        (point-min) %ld)))"
    "        (format \"%%d\\n%%s\" end"
    "                (if (< start end)"
    "                    (buffer-substring-no-properties start end)"
    "                  \"\"))))"
    "  \"1\\n\")",
    log_last_end, log_last_end, log_last_end);
  result = cmacs_dispatch_eval_string (expr, NULL);
  g_free (expr);
  if (result == NULL)
    return G_SOURCE_CONTINUE;

  new_end = strtol (result, NULL, 10);
  nl = strchr (result, '\n');
  if (nl != NULL && new_end != log_last_end)
    {
      gchar **lines = g_strsplit (nl + 1, "\n", -1);
      gint k;
      for (k = 0; lines[k] != NULL; k++)
        if (lines[k][0] != '\0')
          cmacs_dbus_emit_signal (CMACS_DBUS_ROOT_PATH,
                                  "org.cmacs.Editor1.Log",
                                  "MessageLogged",
                                  g_variant_new ("(s)", lines[k]));
      g_strfreev (lines);
    }
  log_last_end = new_end;
  g_free (result);
  return G_SOURCE_CONTINUE;
}

static void
log_watcher_start (void)
{
  GMainContext *ctx;

  if (log_source != NULL || noninteractive)
    return;
  ctx = cmacs_glib_get_context ();
  if (ctx == NULL)
    return;
  log_source = g_timeout_source_new (500);
  g_source_set_callback (log_source, log_tick, NULL, NULL);
  g_source_attach (log_source, ctx);
}

static void
log_watcher_stop (void)
{
  if (log_source != NULL)
    {
      g_source_destroy (log_source);
      g_source_unref (log_source);
      log_source = NULL;
    }
  log_last_end = -1;
}

/* ── Method handlers ───────────────────────────────────────────────── */

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "RecentMessages") == 0)
    {
      gint lines;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(i)", &lines);
      if (lines <= 0)
        lines = 50;
      expr = g_strdup_printf (
        "(with-current-buffer \"*Messages*\""
        "  (let ((s (max (- (point-max) 1) (point-min))))"
        "    (save-excursion"
        "      (goto-char (point-max))"
        "      (forward-line -%d)"
        "      (buffer-substring-no-properties (point) (point-max)))))",
        lines);
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
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_log_register (GDBusConnection *conn, const gchar *path,
                               GError **error)
{
  guint id;

  if (iface_info == NULL)
    {
      iface_info = g_dbus_node_info_new_for_xml (iface_xml, error);
      if (iface_info == NULL) return 0;
    }
  id = g_dbus_connection_register_object (
    conn, path, iface_info->interfaces[0], &vtable, NULL, NULL, error);
  if (id > 0)
    log_watcher_start ();
  return id;
}

void
cmacs_dbus_iface_log_unregister (GDBusConnection *conn, guint id)
{
  log_watcher_stop ();
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
