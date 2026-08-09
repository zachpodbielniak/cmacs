/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-brigade.c --- subagent control via D-Bus.
 *
 * org.cmacs.Editor1.Brigade
 *
 * MCP parity: mirrors agent_spawn / agent_status / agent_result /
 * agent_cancel / agent_list, published from the brigade tool registry by
 * cmacs/mcp/cmacs-mcp-tools-brigade.c (sync discipline: a control added
 * on one surface wants a matching method here, and vice versa).
 *
 * The point of having it here as well is that D-Bus reaches a running
 * cmacs from outside it -- a shell script, a systemd unit, another
 * machine over the emacsctl ssh tunnel -- without going through an MCP
 * client or an agent at all.  Every handler routes through the Elisp
 * dispatch path, so a D-Bus caller drives the same queue, concurrency
 * cap and state machine as the dashboard.  */

#include <config.h>

#if defined(HAVE_CMACS_GLIB) && defined(HAVE_CMACS_AI_BRIGADE)

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <json-glib/json-glib.h>
#include <stdarg.h>
#include <string.h>

static const gchar *iface_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Brigade'>"
  "    <method name='Spawn'>"
  "      <arg type='s' name='task' direction='in'/>"
  "      <arg type='s' name='agent' direction='in'/>"
  "      <arg type='s' name='title' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='id' direction='out'/>"
  "    </method>"
  "    <method name='Status'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='status' direction='out'/>"
  "    </method>"
  "    <method name='Result'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='output' direction='out'/>"
  "    </method>"
  "    <method name='Cancel'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='List'>"
  "      <arg type='s' name='tasks' direction='out'/>"
  "    </method>"
  "    <method name='Agents'>"
  "      <arg type='s' name='agents' direction='out'/>"
  "    </method>"
  "    <method name='Providers'>"
  "      <arg type='s' name='providers' direction='out'/>"
  "    </method>"
  "    <method name='Models'>"
  "      <arg type='s' name='provider' direction='in'/>"
  "      <arg type='s' name='models' direction='out'/>"
  "    </method>"
  /* The mailbox: continuing a conversation with a task rather than
   * starting a new one, and reading what any task has been doing. */
  "    <method name='Send'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='message' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Inbox'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='messages' direction='out'/>"
  "    </method>"
  "    <method name='Drop'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='index' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='Log'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='from_turn' direction='in'/>"
  "      <arg type='s' name='kinds' direction='in'/>"
  "      <arg type='s' name='log' direction='out'/>"
  "    </method>"
  "    <method name='Close'>"
  "      <arg type='s' name='id' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *iface_info = NULL;

/* An agent name is spliced into elisp as a bare symbol, so unlike the
 * task text it cannot be made safe by escaping -- whitelist it instead.
 * Same pattern as valid_calc_name() in cmacs-dbus-iface-calculator.c.
 * Empty is allowed and means "the default agent". */
static gboolean
valid_agent_name (const gchar *s)
{
  if (s == NULL || *s == '\0')
    return TRUE;
  return g_regex_match_simple ("^[a-zA-Z][a-zA-Z0-9_@:-]*$", s, 0, 0);
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

/* Build a JSON object from NULL-terminated key/value pairs, skipping
 * pairs whose value is NULL or empty.  Through json-glib rather than
 * printf because a task description containing a quote or a newline --
 * which is most of them -- would otherwise break out of the argument. */
static gchar *
build_args (const gchar *first_key, ...)
{
  g_autoptr (JsonBuilder) b = json_builder_new ();
  g_autoptr (JsonGenerator) gen = json_generator_new ();
  JsonNode *root;
  const gchar *key = first_key;
  gchar *out;
  va_list ap;

  json_builder_begin_object (b);
  va_start (ap, first_key);
  while (key != NULL)
    {
      const gchar *val = va_arg (ap, const gchar *);
      if (val != NULL && *val != '\0')
        {
          json_builder_set_member_name (b, key);
          json_builder_add_string_value (b, val);
        }
      key = va_arg (ap, const gchar *);
    }
  va_end (ap);
  json_builder_end_object (b);

  root = json_builder_get_root (b);
  json_generator_set_root (gen, root);
  out = json_generator_to_data (gen, NULL);
  json_node_unref (root);
  return out;
}

/* Call the brigade tool NAME the way every other surface does, so a
 * D-Bus caller cannot end up on a different code path from an agent
 * making the same request.
 *
 * Confirmation is bypassed deliberately.  It exists so an *agent* cannot
 * start paid work unattended; a D-Bus caller is the session owner, who
 * already has org.cmacs.Editor1.Eval on the same bus and could just run
 * the elisp.  It also could not work as-is: RPC evals bind
 * `inhibit-interaction', so a confirmation prompt inside a dispatch
 * signals instead of asking, and every Spawn would fail. */
static void
call_tool (GDBusMethodInvocation *iv, const gchar *name, const gchar *args_json)
{
  gchar *args_q = cmacs_dbus_lisp_escape (args_json ? args_json : "{}");

  eval_to_reply (iv, g_strdup_printf (
    "(progn (require 'cmacs-brigade)"
    " (require 'cmacs-brigade-subagent)"
    " (require 'cmacs-brigade-mailbox nil t)"
    " (let ((cmacs-brigade-confirm-function (lambda (_) t)))"
    "  (condition-case e (cmacs-brigade-call-tool \"%s\" \"%s\" \"dbus\")"
    "   (error (format \"error: %%s\" (error-message-string e))))))",
    name, args_q));
  g_free (args_q);
}

static void
on_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                const gchar *i, const gchar *m, GVariant *p,
                GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Spawn") == 0)
    {
      const gchar *task, *agent, *title, *model;
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s&s&s&s)", &task, &agent, &title, &model);
      if (*task == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing task");
          return;
        }
      if (!valid_agent_name (agent))
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error",
            "agent must be an agent name ([a-zA-Z][a-zA-Z0-9_@:-]*)");
          return;
        }
      args = build_args ("task", task, "agent", agent, "title", title,
                         "model", model, NULL);
      call_tool (iv, "agent_spawn", args);
    }
  else if (g_strcmp0 (m, "Status") == 0
           || g_strcmp0 (m, "Result") == 0
           || g_strcmp0 (m, "Cancel") == 0
           || g_strcmp0 (m, "Inbox") == 0
           || g_strcmp0 (m, "Close") == 0)
    {
      const gchar *id;
      const gchar *tool = (g_strcmp0 (m, "Status") == 0) ? "agent_status"
                        : (g_strcmp0 (m, "Result") == 0) ? "agent_result"
                        : (g_strcmp0 (m, "Inbox")  == 0) ? "agent_inbox"
                        : (g_strcmp0 (m, "Close")  == 0) ? "agent_close"
                        : "agent_cancel";
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s)", &id);
      if (*id == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing task id");
          return;
        }
      args = build_args ("id", id, NULL);
      call_tool (iv, tool, args);
    }
  else if (g_strcmp0 (m, "List") == 0)
    {
      call_tool (iv, "agent_list", "{}");
    }
  else if (g_strcmp0 (m, "Providers") == 0)
    {
      call_tool (iv, "agent_providers", "{}");
    }
  else if (g_strcmp0 (m, "Models") == 0)
    {
      const gchar *provider;
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s)", &provider);
      if (*provider == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing provider");
          return;
        }
      args = build_args ("provider", provider, NULL);
      call_tool (iv, "agent_models", args);
    }
  else if (g_strcmp0 (m, "Send") == 0)
    {
      const gchar *id, *message;
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s&s)", &id, &message);
      if (*id == '\0' || *message == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "Send needs an id and a message");
          return;
        }
      args = build_args ("id", id, "message", message, NULL);
      call_tool (iv, "agent_send", args);
    }
  else if (g_strcmp0 (m, "Drop") == 0)
    {
      const gchar *id, *index;
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s&s)", &id, &index);
      if (*id == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing task id");
          return;
        }
      /* An empty index is dropped by build_args, which leaves the tool's
       * own optional argument unset -- and unset means "clear the whole
       * queue", which is exactly what an omitted index should mean.  The
       * number arrives as a string and the tool layer coerces it; every
       * argument on this interface is a string so a shell caller does not
       * have to think about D-Bus types. */
      args = build_args ("id", id, "index", index, NULL);
      call_tool (iv, "agent_drop", args);
    }
  else if (g_strcmp0 (m, "Log") == 0)
    {
      const gchar *id, *from_turn, *kinds;
      g_autofree gchar *args = NULL;

      g_variant_get (p, "(&s&s&s)", &id, &from_turn, &kinds);
      if (*id == '\0')
        {
          g_dbus_method_invocation_return_dbus_error (
            iv, "org.cmacs.Editor1.Error", "missing task id");
          return;
        }
      args = build_args ("id", id, "from_turn", from_turn,
                         "kinds", kinds, NULL);
      call_tool (iv, "agent_log", args);
    }
  else if (g_strcmp0 (m, "Agents") == 0)
    {
      eval_to_reply (iv, g_strdup (
        "(progn (require 'cmacs-brigade)"
        " (mapconcat (lambda (a) (format \"%s\" a))"
        "  (cmacs-brigade-registry-list 'agent) \"\\n\"))"));
    }
}

static const GDBusInterfaceVTable vtable = {
  on_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_brigade_register (GDBusConnection *conn,
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
cmacs_dbus_iface_brigade_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (iface_info != NULL)
    { g_dbus_node_info_unref (iface_info); iface_info = NULL; }
}

#endif /* HAVE_CMACS_GLIB && HAVE_CMACS_AI_BRIGADE */
