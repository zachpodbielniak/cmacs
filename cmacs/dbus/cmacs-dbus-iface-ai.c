/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-ai.c --- cmacs-ai coding agent surface via D-Bus.
 *
 * org.cmacs.Editor1.Ai
 *
 * MCP parity: mirrors ai_prompt / ai_list_providers / ai_list_models
 * / ai_open_chat in cmacs/mcp/cmacs-mcp-tools-ai.c (sync discipline:
 * adding a tool there requires a matching method here, and vice
 * versa).  The elisp bodies are identical to the MCP handlers'. */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_AI)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Ai'>"
  "    <method name='ListProviders'>"
  "      <arg type='s' name='providers' direction='out'/>"
  "    </method>"
  "    <method name='ListModels'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='models' direction='out'/>"
  "    </method>"
  "    <method name='Prompt'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='system' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='response' direction='out'/>"
  "    </method>"
  "    <method name='Call'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='system' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='b' name='tools' direction='in'/>"
  "      <arg type='s' name='response' direction='out'/>"
  "    </method>"
  "    <method name='OpenChat'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='buffer' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* Provider names become quoted elisp symbols --- whitelist them. */
static gboolean
valid_provider_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return FALSE;
  for (; *s != '\0'; s++)
    if (!g_ascii_isalnum (*s) && *s != '-' && *s != '_')
      return FALSE;
  return TRUE;
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "ListProviders") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(format \"%%S\" (cmacs-ai-providers))", NULL, 0);
  else if (g_strcmp0 (m, "ListModels") == 0)
    {
      const gchar *provider;
      gchar *provider_form;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s)", &provider);
      if (*provider != '\0' && !valid_provider_name (provider))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "invalid provider name");
          return;
        }
      /* Empty provider = every supported provider; each one guarded
       * so a keyless/offline provider reports instead of failing the
       * whole call.  Reply is a JSON object provider -> [models]. */
      provider_form = (*provider != '\0')
        ? g_strdup_printf ("(list (quote %s))", provider)
        : g_strdup ("(cmacs-ai-providers)");
      expr = g_strdup_printf (
        "(let ((tbl (make-hash-table :test (quote equal))))"
        " (dolist (pv %s)"
        "  (puthash (symbol-name pv)"
        "   (condition-case e"
        "    (apply (function vector) (cmacs-ai-list-models pv))"
        "    (error (vector (format \"(unavailable: %%s)\""
        "                    (error-message-string e)))))"
        "   tbl))"
        " (json-serialize tbl))",
        provider_form);
      g_free (provider_form);

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
  else if (g_strcmp0 (m, "Prompt") == 0)
    {
      const gchar *prompt, *provider, *system, *model;
      gchar *prompt_q, *system_form, *provider_form, *model_form;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&s&s&s)", &prompt, &provider, &system,
                     &model);
      if (*provider != '\0' && !valid_provider_name (provider))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "invalid provider name");
          return;
        }
      prompt_q = cmacs_dbus_lisp_escape (prompt);
      provider_form = (*provider != '\0')
        ? g_strdup_printf ("(quote %s)", provider)
        : g_strdup ("nil");
      if (*system != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (system);
          system_form = g_strdup_printf ("\"%s\"", esc);
          g_free (esc);
        }
      else
        system_form = g_strdup ("nil");
      if (*model != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (model);
          model_form = g_strdup_printf ("\"%s\"", esc);
          g_free (esc);
        }
      else
        model_form = g_strdup ("nil");

      expr = g_strdup_printf (
        "(condition-case e (cmacs-ai-prompt-sync \"%s\" %s %s %s)"
        " (error (format \"error: %%S\" e)))",
        prompt_q, provider_form, system_form, model_form);
      g_free (prompt_q);
      g_free (provider_form);
      g_free (system_form);
      g_free (model_form);

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
  else if (g_strcmp0 (m, "Call") == 0)
    {
      /* Like Prompt, but when TOOLS is true the model is given the
       * built-in agent tools (bash/read/write/edit/glob/grep/ls/
       * web_fetch) and runs a synchronous multi-turn loop.  DANGER: that
       * loop blocks the target's main thread -- under `emacs --gowl' the
       * compositor thread -- so callers should keep it bounded. */
      const gchar *prompt, *provider, *system, *model;
      gboolean tools;
      gchar *prompt_q, *system_form, *provider_form, *model_form;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&s&s&sb)", &prompt, &provider, &system,
                     &model, &tools);
      if (*provider != '\0' && !valid_provider_name (provider))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "invalid provider name");
          return;
        }
      prompt_q = cmacs_dbus_lisp_escape (prompt);
      provider_form = (*provider != '\0')
        ? g_strdup_printf (":provider (quote %s)", provider)
        : g_strdup ("");
      if (*system != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (system);
          system_form = g_strdup_printf (":system \"%s\"", esc);
          g_free (esc);
        }
      else
        system_form = g_strdup ("");
      if (*model != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (model);
          model_form = g_strdup_printf (":model \"%s\"", esc);
          g_free (esc);
        }
      else
        model_form = g_strdup ("");

      expr = g_strdup_printf (
        "(condition-case e"
        " (progn (require 'cmacs-ai-call)"
        "  (cmacs-ai-call \"%s\" %s %s %s %s))"
        " (error (format \"error: %%S\" e)))",
        prompt_q, provider_form, system_form, model_form,
        tools ? ":builtin-tools t" : "");
      g_free (prompt_q);
      g_free (provider_form);
      g_free (system_form);
      g_free (model_form);

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
  else if (g_strcmp0 (m, "OpenChat") == 0)
    {
      const gchar *provider, *prompt, *model;
      gchar *prompt_q, *provider_form, *model_form;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&s&s)", &provider, &prompt, &model);
      if (*provider != '\0' && !valid_provider_name (provider))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "invalid provider name");
          return;
        }
      prompt_q = cmacs_dbus_lisp_escape (prompt);
      provider_form = (*provider != '\0')
        ? g_strdup_printf ("(quote %s)", provider)
        : g_strdup ("nil");
      if (*model != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (model);
          model_form = g_strdup_printf ("\"%s\"", esc);
          g_free (esc);
        }
      else
        model_form = g_strdup ("nil");

      expr = g_strdup_printf (
        "(progn (require 'cmacs-ai-chat) "
        " (let ((buf (cmacs-ai-chat-open %s %s))) "
        "   (when (and \"%s\" (not (string-empty-p \"%s\"))) "
        "     (with-current-buffer buf "
        "       (goto-char (point-max)) "
        "       (insert \"%s\") "
        "       (cmacs-ai-chat-send-compose))) "
        "   (buffer-name buf)))",
        provider_form, model_form, prompt_q, prompt_q, prompt_q);
      g_free (prompt_q);
      g_free (provider_form);
      g_free (model_form);

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
cmacs_dbus_iface_ai_register (GDBusConnection *conn, const gchar *path,
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
cmacs_dbus_iface_ai_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_AI */
