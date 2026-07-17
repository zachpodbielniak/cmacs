/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-calculator.c --- cmacs-calculator surface via D-Bus.
 *
 * org.cmacs.Editor1.Calc
 *
 * MCP parity: mirrors calc_eval / calc_eval_symbolic / calc_convert_units
 * / calc_list / calc_describe in cmacs/mcp/cmacs-mcp-tools-calculator.c
 * (sync discipline: adding a tool there requires a matching method here,
 * and vice versa).  The elisp bodies are identical to the MCP handlers'.
 *
 * Every handler routes through the Elisp dispatch path, so a D-Bus caller
 * runs the same engine -- same corrected precedence, radian angle mode and
 * strict validation -- as M-x, the sheet buffer and the MCP tools. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_CALCULATOR)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Calc'>"
  "    <method name='Eval'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='EvalSymbolic'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ConvertUnits'>"
  "      <arg type='s' name='expression' direction='in'/>"
  "      <arg type='s' name='units' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListCalculators'>"
  "      <arg type='s' name='category' direction='in'/>"
  "      <arg type='s' name='calculators' direction='out'/>"
  "    </method>"
  "    <method name='Describe'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='s' name='description' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Calculator and category names are spliced into the elisp as BARE
 * symbols (quote forms), so unlike expressions they cannot be made safe
 * by string-escaping --- whitelist them instead.  Same pattern as
 * valid_provider_name() in cmacs-dbus-iface-ai.c, and the identical
 * regexp the MCP tools use. */
static gboolean
valid_calc_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  return g_regex_match_simple ("^[a-z][a-z0-9-]*$", s, 0, 0);
}

/* Evaluate EXPR and reply with the raw string result.  Consumes EXPR. */
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

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Eval") == 0)
    {
      const gchar *expr;
      gchar *expr_q;

      g_variant_get (p, "(&s)", &expr);
      if (*expr == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing expression");
          return;
        }
      expr_q = cmacs_dbus_lisp_escape (expr);
      /* The calculator signals on bad input rather than returning it
         unevaluated, so catch and report instead of failing the call. */
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-calculator)"
        " (condition-case e (cmacs-calculator-eval \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        expr_q));
      g_free (expr_q);
    }
  else if (g_strcmp0 (m, "EvalSymbolic") == 0)
    {
      const gchar *expr;
      gchar *expr_q;

      g_variant_get (p, "(&s)", &expr);
      if (*expr == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing expression");
          return;
        }
      expr_q = cmacs_dbus_lisp_escape (expr);
      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-calculator)"
        " (condition-case e (cmacs-calculator-eval-symbolic \"%s\")"
        "  (error (format \"error: %%s\" (error-message-string e)))))",
        expr_q));
      g_free (expr_q);
    }
  else if (g_strcmp0 (m, "ConvertUnits") == 0)
    {
      const gchar *expr, *units;
      gchar *expr_q, *units_q;

      g_variant_get (p, "(&s&s)", &expr, &units);
      if (*expr == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing expression");
          return;
        }
      expr_q = cmacs_dbus_lisp_escape (expr);
      /* No target units means "reduce to base SI". */
      if (*units == '\0')
        eval_to_reply (iv, g_strdup_printf (
          "(progn (require 'cmacs-calculator)"
          " (condition-case e (cmacs-calculator-to-base-units \"%s\")"
          "  (error (format \"error: %%s\" (error-message-string e)))))",
          expr_q));
      else
        {
          units_q = cmacs_dbus_lisp_escape (units);
          eval_to_reply (iv, g_strdup_printf (
            "(progn (require 'cmacs-calculator)"
            " (condition-case e (cmacs-calculator-convert-units \"%s\" \"%s\")"
            "  (error (format \"error: %%s\" (error-message-string e)))))",
            expr_q, units_q));
          g_free (units_q);
        }
      g_free (expr_q);
    }
  else if (g_strcmp0 (m, "ListCalculators") == 0)
    {
      const gchar *category;
      gchar *cat_arg;

      g_variant_get (p, "(&s)", &category);
      /* A category is a bare symbol in the call, so allow only names
         that cannot alter the form being built; anything else (and the
         empty string) lists every calculator. */
      cat_arg = valid_calc_name (category)
        ? g_strdup_printf ("'%s", category)
        : g_strdup ("nil");

      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-calculator)"
        " (mapconcat (lambda (c) (format \"%%s (%%s) -- %%s\""
        "   (plist-get c :name) (plist-get c :category)"
        "   (or (plist-get c :title) \"\")))"
        "  (cmacs-calculator-list %s) \"\\n\"))",
        cat_arg));
      g_free (cat_arg);
    }
  else if (g_strcmp0 (m, "Describe") == 0)
    {
      const gchar *calc;

      g_variant_get (p, "(&s)", &calc);
      if (!valid_calc_name (calc))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error",
            "name must be a calculator name ([a-z][a-z0-9-]*)");
          return;
        }

      eval_to_reply (iv, g_strdup_printf (
        "(progn (require 'cmacs-calculator)"
        " (let ((c (cmacs-calculator-get '%s)))"
        "  (if (null c) \"error: no such calculator\""
        "   (format \"%%s -- %%s\\ncategory: %%s\\nargs: %%S\\nreturns: %%s\\n%%s\""
        "    (plist-get c :name) (or (plist-get c :title) \"\")"
        "    (plist-get c :category) (plist-get c :args)"
        "    (or (plist-get c :returns) \"\") (or (plist-get c :doc) \"\")))))",
        calc));
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_calculator_register (GDBusConnection *conn,
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
cmacs_dbus_iface_calculator_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_CALCULATOR */
