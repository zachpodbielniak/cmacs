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
  "    <method name='GenerateImage'>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='aspect' direction='in'/>"
  "      <arg type='s' name='references' direction='in'/>"
  "      <arg type='s' name='buffer' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='OpenChat'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='prompt' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='buffer' direction='out'/>"
  "    </method>"
  "    <method name='Research'>"
  "      <arg type='s' name='question' direction='in'/>"
  "      <arg type='b' name='deep' direction='in'/>"
  "      <arg type='i' name='pages' direction='in'/>"
  "      <arg type='s' name='answer' direction='out'/>"
  "    </method>"
  "    <method name='WebFetch'>"
  "      <arg type='s' name='url' direction='in'/>"
  "      <arg type='s' name='archive' direction='in'/>"
  "      <arg type='i' name='max_chars' direction='in'/>"
  "      <arg type='s' name='text' direction='out'/>"
  "    </method>"
  "    <method name='Lql'>"
  "      <arg type='s' name='query' direction='in'/>"
  "      <arg type='b' name='explain' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
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

/* Research / WebFetch / Lql: MCP parity with ai_research, ai_web_fetch and
 * ai_lql (cmacs-mcp-tools-ai.c), same Lisp form, same argument checks.
 * The request runs on a worker thread; the eval waits for it with
 * accept-process-output (see the MCP side for why not sit-for).  FORM is
 * already escaped and is freed here; a failure string from
 * cmacs-ai-research-sync-text becomes a D-Bus error. */
static void
ai_research_reply (GDBusMethodInvocation *iv, gchar *form)
{
  GError *err = NULL;
  gchar *expr = g_strdup_printf (
    "(condition-case e"
    " (progn (require 'cmacs-ai-research) %s)"
    " (error (format \"error: %%s\" (error-message-string e))))",
    form);
  gchar *result = cmacs_dispatch_eval_string (expr, &err);

  g_free (form);
  g_free (expr);
  if (result == NULL)
    {
      cmacs_dbus_return_gerror (iv, err);
      return;
    }
  if (g_str_has_prefix (result, "error: "))
    g_dbus_method_invocation_return_dbus_error (
      iv, "org.cmacs.Editor1.Error", result + strlen ("error: "));
  else
    g_dbus_method_invocation_return_value (iv, g_variant_new ("(s)", result));
  g_free (result);
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
  else if (g_strcmp0 (m, "GenerateImage") == 0)
    {
      /* MCP parity: the generate_image tool in
       * cmacs/mcp/cmacs-mcp-tools-ai.c.  Blocks for as long as the
       * provider takes, which is tens of seconds. */
      const gchar *prompt, *provider, *model, *aspect, *refs, *buffer;
      gchar *prompt_q, *provider_form, *model_form;
      gchar *aspect_arg, *refs_arg, *buffer_form;
      gchar *expr;
      gchar *result;
      GError *err = NULL;

      g_variant_get (p, "(&s&s&s&s&s&s)", &prompt, &provider, &model,
                     &aspect, &refs, &buffer);
      if (*prompt == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "prompt is required");
          return;
        }
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
      if (*aspect != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (aspect);
          aspect_arg = g_strdup_printf (":aspect \"%s\"", esc);
          g_free (esc);
        }
      else
        aspect_arg = g_strdup ("");
      if (*refs != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (refs);
          refs_arg = g_strdup_printf (
            ":references (cmacs-ai-image-chat--parse-refs \"%s\")", esc);
          g_free (esc);
        }
      else
        refs_arg = g_strdup ("");
      if (*buffer != '\0')
        {
          gchar *esc = cmacs_dbus_lisp_escape (buffer);
          buffer_form = g_strdup_printf (
            "(or (get-buffer \"%s\") (current-buffer))", esc);
          g_free (esc);
        }
      else
        buffer_form = g_strdup ("(current-buffer)");

      expr = g_strdup_printf (
        "(condition-case e"
        " (progn (require 'cmacs-ai-image) (require 'cmacs-ai-image-chat)"
        "  (with-current-buffer %s"
        "   (let* ((h (cmacs-ai-image--client %s %s))"
        "          (pl (unwind-protect"
        "                  (cmacs-ai-image-generate-sync"
        "                   h \"%s\" (list %s %s) cmacs-ai-image-timeout)"
        "                (ignore-errors (cmacs-ai-client-free h))))"
        "          (n (cmacs-ai-image--place (plist-get pl :images)"
        "                                     \"%s\" (current-buffer)"
        "                                     (point))))"
        "     (format \"Inserted %%d image(s) into %%s\" n (buffer-name)))))"
        " (error (format \"error: %%S\" e)))",
        buffer_form, provider_form, model_form, prompt_q,
        aspect_arg, refs_arg, prompt_q);
      g_free (prompt_q);
      g_free (provider_form);
      g_free (model_form);
      g_free (aspect_arg);
      g_free (refs_arg);
      g_free (buffer_form);

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
  else if (g_strcmp0 (m, "Research") == 0)
    {
      const gchar *question;
      gboolean deep;
      gint32 pages;
      gchar *q, *pages_arg;

      g_variant_get (p, "(&sbi)", &question, &deep, &pages);
      if (*question == '\0' || pages < 0 || pages > 20)
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error",
            "Research: need a question, and pages 0-20 (0 = default)");
          return;
        }
      q = cmacs_dbus_lisp_escape (question);
      pages_arg = pages > 0 ? g_strdup_printf (" :pages %d", pages)
                            : g_strdup ("");
      ai_research_reply (iv, g_strdup_printf (
        "(cmacs-ai-research-sync-text 'research \"%s\"%s%s)", q,
        deep ? " :deep t" : "", pages_arg));
      g_free (q);
      g_free (pages_arg);
    }
  else if (g_strcmp0 (m, "WebFetch") == 0)
    {
      const gchar *url, *archive;
      gint32 max_chars;
      gchar *u, *max_arg;

      g_variant_get (p, "(&s&si)", &url, &archive, &max_chars);
      if (*url == '\0'
          || (*archive != '\0' && g_strcmp0 (archive, "never") != 0
              && g_strcmp0 (archive, "fallback") != 0
              && g_strcmp0 (archive, "only") != 0)
          || (max_chars != 0 && (max_chars < 100 || max_chars > 1000000)))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error",
            "WebFetch: need a url; archive is never, fallback, only or "
            "empty; max_chars 100-1000000 or 0");
          return;
        }
      u = cmacs_dbus_lisp_escape (url);
      max_arg = max_chars > 0 ? g_strdup_printf (" :max-chars %d",
                                                 max_chars)
                              : g_strdup ("");
      /* ARCHIVE is one of three literals by now: safe to splice. */
      ai_research_reply (iv, g_strdup_printf (
        "(cmacs-ai-research-sync-text 'fetch \"%s\"%s%s%s%s)", u,
        *archive != '\0' ? " :archive \"" : "", archive,
        *archive != '\0' ? "\"" : "", max_arg));
      g_free (u);
      g_free (max_arg);
    }
  else if (g_strcmp0 (m, "Lql") == 0)
    {
      const gchar *query;
      gboolean explain;
      gchar *q;

      g_variant_get (p, "(&sb)", &query, &explain);
      if (*query == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "Lql: need a query");
          return;
        }
      q = cmacs_dbus_lisp_escape (query);
      ai_research_reply (iv, g_strdup_printf (
        "(cmacs-ai-research-sync-text 'lql \"%s\" :max-rows 100%s)", q,
        explain ? " :explain t" : ""));
      g_free (q);
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
