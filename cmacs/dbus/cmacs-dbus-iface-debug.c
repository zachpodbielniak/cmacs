/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-debug.c --- runtime introspection and debugging
 * via D-Bus.
 *
 * org.cmacs.Editor1.Debug
 *
 * MCP parity: mirrors backtrace / memory_info / list_hooks /
 * describe_mode / profiler_* in cmacs/mcp/cmacs-mcp-tools-debug.c and
 * describe_function / describe_variable / apropos / completions in
 * cmacs-mcp-tools-eval.c (sync discipline: adding a tool there
 * requires a matching method here, and vice versa).  The elisp bodies
 * are identical to the MCP handlers'. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Debug'>"
  "    <method name='Backtrace'>"
  "      <arg type='s' name='trace' direction='out'/>"
  "    </method>"
  "    <method name='MemoryInfo'>"
  "      <arg type='s' name='info' direction='out'/>"
  "    </method>"
  "    <method name='ListHooks'>"
  "      <arg type='s' name='hooks' direction='out'/>"
  "    </method>"
  "    <method name='DescribeMode'>"
  "      <arg type='s' name='modes' direction='out'/>"
  "    </method>"
  "    <method name='DescribeFunction'>"
  "      <arg type='s' name='symbol' direction='in'/>"
  "      <arg type='s' name='doc' direction='out'/>"
  "    </method>"
  "    <method name='DescribeVariable'>"
  "      <arg type='s' name='symbol' direction='in'/>"
  "      <arg type='s' name='doc' direction='out'/>"
  "    </method>"
  "    <method name='Apropos'>"
  "      <arg type='s' name='pattern' direction='in'/>"
  "      <arg type='s' name='symbols' direction='out'/>"
  "    </method>"
  "    <method name='Completions'>"
  "      <arg type='s' name='prefix' direction='in'/>"
  "      <arg type='as' name='candidates' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerStart'>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerStop'>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='ProfilerReport'>"
  "      <arg type='s' name='report' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Same symbol whitelist as iface-input: reject splice attempts. */
static gboolean
valid_symbol_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  for (; *s != '\0'; s++)
    if (!g_ascii_isalnum (*s) && strchr ("-_+*/<>=!?:", *s) == NULL)
      return FALSE;
  return TRUE;
}

static void
describe_symbol_reply (GDBusMethodInvocation *iv, GVariant *p,
                       const gchar *elisp_fmt)
{
  const gchar *symbol;
  gchar *expr;
  gchar *result;
  GError *err = NULL;

  g_variant_get (p, "(&s)", &symbol);
  if (!valid_symbol_name (symbol))
    {
      g_dbus_method_invocation_return_dbus_error (
        iv, "org.cmacs.Editor1.Error",
        "argument must be a plain elisp symbol name");
      return;
    }
  expr = g_strdup_printf (elisp_fmt, symbol);
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

  if (g_strcmp0 (m, "Backtrace") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(with-output-to-string (backtrace))", NULL, 0);
  else if (g_strcmp0 (m, "MemoryInfo") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(format \"GC stats: %%S\\nMemory use counts: %%S\""
      "  (garbage-collect) (memory-use-counts))", NULL, 0);
  else if (g_strcmp0 (m, "ListHooks") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(let (hooks)"
      "  (mapatoms"
      "    (lambda (sym)"
      "      (when (and (boundp sym)"
      "                 (string-suffix-p \"-hook\" (symbol-name sym))"
      "                 (symbol-value sym))"
      "        (push (format \"%%s: %%S\" sym (symbol-value sym)) hooks))))"
      "  (mapconcat #'identity (sort hooks #'string<) \"\\n\"))", NULL, 0);
  else if (g_strcmp0 (m, "DescribeMode") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(format \"Major mode: %%s\\nMinor modes: %%s\""
      "  (symbol-name major-mode)"
      "  (mapconcat #'symbol-name minor-mode-list \" \"))", NULL, 0);
  else if (g_strcmp0 (m, "DescribeFunction") == 0)
    describe_symbol_reply (iv, p,
      "(let ((sym '%s))"
      "  (if (fboundp sym)"
      "    (format \"%%s\\n\\nArgs: %%s\\n\\n%%s\""
      "      sym"
      "      (or (help-function-arglist sym t) \"()\")"
      "      (or (documentation sym t) \"No documentation.\"))"
      "    (format \"%%s is not a known function\" sym)))");
  else if (g_strcmp0 (m, "DescribeVariable") == 0)
    describe_symbol_reply (iv, p,
      "(let ((sym '%s))"
      "  (if (boundp sym)"
      "    (format \"%%s\\n\\nValue: %%S\\n\\n%%s\""
      "      sym"
      "      (symbol-value sym)"
      "      (or (documentation-property sym 'variable-documentation t)"
      "          \"No documentation.\"))"
      "    (format \"%%s is void\" sym)))");
  else if (g_strcmp0 (m, "Apropos") == 0)
    {
      const gchar *pattern;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &pattern);
      args[0] = pattern;
      cmacs_dbus_eval_to_reply_string (iv,
        "(mapconcat #'symbol-name (apropos-internal \"%s\") \"\\n\")",
        args, 1);
    }
  else if (g_strcmp0 (m, "Completions") == 0)
    {
      const gchar *prefix;
      const gchar *args[1];
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &prefix);
      args[0] = prefix;
      expr = cmacs_dbus_build_elisp (
        "(let ((comps (all-completions \"%s\" obarray)))"
        "  (mapconcat #'identity (seq-take comps 100) \"\\n\"))",
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
  else if (g_strcmp0 (m, "ProfilerStart") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(progn (profiler-start 'cpu) \"Profiler started\")", NULL, 0);
  else if (g_strcmp0 (m, "ProfilerStop") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(progn (profiler-stop) \"Profiler stopped\")", NULL, 0);
  else if (g_strcmp0 (m, "ProfilerReport") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(with-temp-buffer"
      "  (profiler-report-cpu)"
      "  (buffer-substring-no-properties (point-min) (point-max)))",
      NULL, 0);
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_debug_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_debug_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB */
