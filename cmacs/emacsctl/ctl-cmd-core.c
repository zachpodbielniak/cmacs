/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-core.c --- the built-in verbs that are not plain method
 * calls: version, instances, eval, logs, repl, config, completion,
 * and the hidden __complete / proxy modes. */

#include "ctl-command-registry.h"
#include "ctl-completion.h"
#include "ctl-config.h"
#include "ctl-ifaces.h"
#include "ctl-proxy.h"
#include "ctl-repl.h"
#include "ctl-transport-dbus.h"
#include "ctl-watcher.h"

#include <stdio.h>
#include <string.h>

void ctl_cmd_core_register (CtlCommandRegistry *registry);

/* ── version ───────────────────────────────────────────────────────── */

static gint
cmd_version (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self; (void) error;

  printf ("emacsctl %s (cmacsctl)\n", CTL_VERSION);

  /* Best effort: also report the target editor when reachable. */
  {
    GError *local = NULL;
    CtlTransport *transport = ctl_invocation_get_transport (inv, &local);
    if (transport != NULL)
      {
        GVariant *reply = ctl_transport_call (
          transport, CTL_IFACE_INSTANCE, "Info", NULL,
          ctl_invocation_get_timeout_ms (inv), &local);
        if (reply != NULL)
          {
            const gchar *json;
            g_variant_get (reply, "(&s)", &json);
            printf ("server: %s\n", json);
            g_variant_unref (reply);
          }
      }
    g_clear_error (&local);
  }
  return CTL_EXIT_OK;
}

/* ── instances ─────────────────────────────────────────────────────── */

/* Fetch Info() from one instance as a row object. */
static JsonObject *
instance_row (const gchar *pid, gint timeout_ms)
{
  CtlDbusTransport *transport;
  JsonObject *row = NULL;
  GError *error = NULL;
  GVariant *reply;

  transport = ctl_dbus_transport_new (pid, &error);
  if (transport == NULL)
    {
      g_clear_error (&error);
      return NULL;
    }
  reply = ctl_transport_call (CTL_TRANSPORT (transport),
                              CTL_IFACE_INSTANCE, "Info", NULL,
                              timeout_ms, &error);
  if (reply != NULL)
    {
      const gchar *json;
      JsonParser *parser = json_parser_new ();
      g_variant_get (reply, "(&s)", &json);
      if (json_parser_load_from_data (parser, json, -1, NULL))
        {
          JsonNode *root = json_parser_get_root (parser);
          if (JSON_NODE_HOLDS_OBJECT (root))
            row = json_object_ref (json_node_get_object (root));
        }
      g_object_unref (parser);
      g_variant_unref (reply);
    }
  g_clear_error (&error);

  if (row == NULL)
    {
      /* Degrade to ListNames-only metadata (old server). */
      row = json_object_new ();
      json_object_set_int_member (row, "pid",
                                  g_ascii_strtoll (pid, NULL, 10));
    }
  ctl_transport_close (CTL_TRANSPORT (transport));
  g_object_unref (transport);
  return row;
}

static gint
cmd_instances (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlTransport *transport;
  gchar **pids;
  JsonArray *rows;
  CtlResult *result;
  gint k;
  gboolean ok;

  (void) self;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;
  pids = ctl_transport_list_instances (transport, error);
  if (pids == NULL)
    return CTL_EXIT_ERROR;

  rows = json_array_new ();
  for (k = 0; pids[k] != NULL; k++)
    {
      JsonObject *row;
      if (ctl_invocation_get_host (inv) == NULL)
        row = instance_row (pids[k],
                            ctl_invocation_get_timeout_ms (inv));
      else
        {
          /* Remote: avoid spawning one ssh per pid; report pids. */
          row = json_object_new ();
          json_object_set_int_member (row, "pid",
            g_ascii_strtoll (pids[k], NULL, 10));
        }
      if (row != NULL)
        {
          JsonNode *node = json_node_new (JSON_NODE_OBJECT);
          json_node_take_object (node, row);
          json_array_add_element (rows, node);
        }
    }
  g_strfreev (pids);

  result = ctl_result_new_list (rows);
  ctl_result_add_column (result, "Pid", "pid");
  ctl_result_add_column (result, "Version", "version");
  ctl_result_add_column (result, "Primary", "primary");
  ctl_result_add_column (result, "Uptime", "uptime");
  ctl_result_add_column (result, "Bus Name", "bus_name");
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* ── describe instance ─────────────────────────────────────────────── */

static gint
cmd_describe_instance (CtlCommand *self, CtlInvocation *inv,
                       GError **error)
{
  CtlTransport *transport;
  GVariant *reply;
  const gchar *json;
  JsonParser *parser;
  CtlResult *result;
  gboolean ok;

  (void) self;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;
  reply = ctl_transport_call (transport, CTL_IFACE_INSTANCE, "Info",
                              NULL, ctl_invocation_get_timeout_ms (inv),
                              error);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  g_variant_get (reply, "(&s)", &json);
  parser = json_parser_new ();
  if (json_parser_load_from_data (parser, json, -1, NULL))
    result = ctl_result_new_document (
      json_node_copy (json_parser_get_root (parser)));
  else
    result = ctl_result_new_scalar (json);
  g_object_unref (parser);
  g_variant_unref (reply);

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* ── get content-org ───────────────────────────────────────────────── */

/* Flatten the nested headline tree into outline-style table rows. */
static void
org_flatten_headlines (JsonArray *headlines, JsonArray *rows)
{
  guint n = headlines != NULL ? json_array_get_length (headlines) : 0;
  guint k;

  for (k = 0; k < n; k++)
    {
      JsonNode *node = json_array_get_element (headlines, k);
      JsonObject *h;
      JsonObject *row;
      JsonNode *row_node;
      gint64 level;
      GString *title;
      gint64 i;

      if (!JSON_NODE_HOLDS_OBJECT (node))
        continue;
      h = json_node_get_object (node);
      level = json_object_get_int_member_with_default (h, "level", 1);

      title = g_string_new (NULL);
      for (i = 1; i < level; i++)
        g_string_append (title, "  ");
      g_string_append (title,
        json_object_get_string_member_with_default (h, "title", ""));

      row = json_object_new ();
      json_object_set_int_member (row, "level", level);
      json_object_set_string_member (row, "todo",
        json_object_get_string_member_with_default (h, "todo", ""));
      json_object_set_string_member (row, "title", title->str);
      g_string_free (title, TRUE);

      {
        GString *tags = g_string_new (NULL);
        if (json_object_has_member (h, "tags"))
          {
            JsonArray *ta = json_object_get_array_member (h, "tags");
            guint tn = json_array_get_length (ta);
            guint tk;
            for (tk = 0; tk < tn; tk++)
              {
                if (tk > 0)
                  g_string_append_c (tags, ':');
                g_string_append (tags,
                  json_array_get_string_element (ta, tk));
              }
          }
        json_object_set_string_member (row, "tags", tags->str);
        g_string_free (tags, TRUE);
      }
      json_object_set_string_member (row, "scheduled",
        json_object_get_string_member_with_default (h, "scheduled",
                                                    ""));

      row_node = json_node_new (JSON_NODE_OBJECT);
      json_node_take_object (row_node, row);
      json_array_add_element (rows, row_node);

      if (json_object_has_member (h, "children"))
        org_flatten_headlines (
          json_object_get_array_member (h, "children"), rows);
    }
}

static gchar *content_org_opt_match = NULL;
static gint content_org_opt_depth = 0;
static gboolean content_org_opt_no_body = FALSE;
static gboolean content_org_opt_no_props = FALSE;

static const GOptionEntry content_org_entries[] = {
  { "match", 'm', 0, G_OPTION_ARG_STRING, &content_org_opt_match,
    "org agenda match string (tags/todo/property query), e.g. "
    "\"work+urgent/TODO\"", "EXPR" },
  { "depth", 'd', 0, G_OPTION_ARG_INT, &content_org_opt_depth,
    "Limit headline depth (0 = unlimited)", "N" },
  { "no-body", 0, 0, G_OPTION_ARG_NONE, &content_org_opt_no_body,
    "Structure only: drop entry body text", NULL },
  { "no-properties", 0, 0, G_OPTION_ARG_NONE,
    &content_org_opt_no_props, "Drop property drawers", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_get_content_org (CtlCommand *self, CtlInvocation *inv,
                     GError **error)
{
  const gchar *buffer = ctl_invocation_get_arg (inv, 0);
  const gchar *match =
    content_org_opt_match != NULL ? content_org_opt_match : "";
  gint max_depth = content_org_opt_depth;
  gboolean include_body = !content_org_opt_no_body;
  gboolean include_props = !content_org_opt_no_props;
  CtlTransport *transport;
  GVariant *reply;
  const gchar *json;
  JsonParser *parser;
  CtlResult *result;
  gboolean ok;

  (void) self;

  if (buffer == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "missing required argument <buffer> "
                   "(see 'get content-org --help')");
      return CTL_EXIT_USAGE;
    }

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;

  reply = ctl_transport_call (
    transport, CTL_IFACE_EDIT, "GetOrgContent",
    g_variant_new ("(ssibb)", buffer, match, max_depth,
                   include_body, include_props),
    ctl_invocation_get_timeout_ms (inv), error);
  if (reply == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  g_variant_get (reply, "(&s)", &json);
  parser = json_parser_new ();
  if (!json_parser_load_from_data (parser, json, -1, NULL))
    {
      result = ctl_result_new_scalar (json);
    }
  else if (g_strcmp0 (ctl_invocation_get_output (inv), "table") == 0)
    {
      /* Outline-style table: one row per headline, depth-indented. */
      JsonNode *root = json_parser_get_root (parser);
      JsonArray *rows = json_array_new ();
      if (JSON_NODE_HOLDS_OBJECT (root)
          && json_object_has_member (json_node_get_object (root),
                                     "headlines"))
        org_flatten_headlines (
          json_object_get_array_member (json_node_get_object (root),
                                        "headlines"),
          rows);
      result = ctl_result_new_list (rows);
      ctl_result_add_column (result, "Lvl", "level");
      ctl_result_add_column (result, "Todo", "todo");
      ctl_result_add_column (result, "Title", "title");
      ctl_result_add_column (result, "Tags", "tags");
      ctl_result_add_column (result, "Scheduled", "scheduled");
    }
  else
    result = ctl_result_new_document (
      json_node_copy (json_parser_get_root (parser)));
  g_object_unref (parser);
  g_variant_unref (reply);

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* ── eval (multi-language) ─────────────────────────────────────────── */

static gchar *eval_opt_lang = NULL;

static const GOptionEntry eval_entries[] = {
  { "lang", 'l', 0, G_OPTION_ARG_STRING, &eval_opt_lang,
    "Language: elisp (default), crispy, bacon, or eshell", "LANG" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_eval (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  const gchar *lang = eval_opt_lang != NULL ? eval_opt_lang : "elisp";
  GString *expr;
  CtlReplRuntime *runtime;
  CtlTransport *transport;
  gchar *output;
  gint k;

  (void) self;

  if (argc == 0)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "missing expression (see 'eval --help')");
      return CTL_EXIT_USAGE;
    }

  expr = g_string_new (NULL);
  for (k = 0; k < argc; k++)
    {
      if (k > 0)
        g_string_append_c (expr, ' ');
      g_string_append (expr, argv[k]);
    }

  runtime = ctl_repl_runtime_new_for_lang (lang, error);
  if (runtime == NULL)
    {
      g_string_free (expr, TRUE);
      return CTL_EXIT_USAGE;
    }
  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      g_object_unref (runtime);
      g_string_free (expr, TRUE);
      return CTL_EXIT_NO_INSTANCE;
    }

  output = ctl_repl_runtime_eval (runtime, transport,
                                  ctl_invocation_get_timeout_ms (inv),
                                  expr->str, error);
  g_string_free (expr, TRUE);
  g_object_unref (runtime);
  if (output == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  {
    CtlResult *result = ctl_result_new_scalar (output);
    gboolean ok = ctl_invocation_emit (inv, result, error);
    ctl_result_unref (result);
    g_free (output);
    return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
  }
}

/* ── logs [-f] [-n N] ──────────────────────────────────────────────── */

static void
logs_print_event (CtlWatcher *watcher, CtlResult *result,
                  gpointer user_data)
{
  CtlInvocation *inv = user_data;
  GError *error = NULL;

  (void) watcher;

  if (!ctl_invocation_emit (inv, result, &error))
    g_clear_error (&error);
  fflush (stdout);
}

static gboolean logs_opt_follow = FALSE;
static gint logs_opt_lines = 50;

static const GOptionEntry logs_entries[] = {
  { "follow", 'f', 0, G_OPTION_ARG_NONE, &logs_opt_follow,
    "Keep streaming new lines as they are logged", NULL },
  { "lines", 'n', 0, G_OPTION_ARG_INT, &logs_opt_lines,
    "Number of backlog lines to print (default 50)", "N" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_logs (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gboolean follow = logs_opt_follow || ctl_invocation_get_watch (inv);
  gint lines = logs_opt_lines;
  CtlTransport *transport;

  (void) self;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;

  /* Backlog first. */
  {
    GVariant *reply = ctl_transport_call (
      transport, CTL_IFACE_LOG, "RecentMessages",
      g_variant_new ("(i)", lines),
      ctl_invocation_get_timeout_ms (inv), error);
    if (reply == NULL)
      return ctl_exit_code_for_error (error != NULL ? *error : NULL);
    {
      const gchar *text;
      CtlResult *result;
      gboolean ok;
      g_variant_get (reply, "(&s)", &text);
      result = ctl_result_new_scalar (text);
      ok = ctl_invocation_emit (inv, result, error);
      ctl_result_unref (result);
      g_variant_unref (reply);
      if (!ok)
        return CTL_EXIT_ERROR;
    }
  }

  if (!follow)
    return CTL_EXIT_OK;

  fflush (stdout);
  {
    CtlWatcher *watcher = ctl_watcher_new (transport);
    ctl_watcher_add_signal (watcher, CTL_IFACE_LOG, "MessageLogged");
    g_signal_connect (watcher, "event",
                      G_CALLBACK (logs_print_event), inv);
    ctl_watcher_run (watcher);
    g_object_unref (watcher);
  }
  return CTL_EXIT_OK;
}

/* ── watch stream ──────────────────────────────────────────────────── */

static gint
cmd_watch_stream (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlTransport *transport;
  CtlWatcher *watcher;

  (void) self;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    return CTL_EXIT_NO_INSTANCE;

  watcher = ctl_watcher_new (transport);
  ctl_watcher_add_signal (watcher, CTL_IFACE_BUFMGR, "BufferAdded");
  ctl_watcher_add_signal (watcher, CTL_IFACE_BUFMGR, "BufferRemoved");
  ctl_watcher_add_signal (watcher, CTL_IFACE_FRAMEMGR, "FrameAdded");
  ctl_watcher_add_signal (watcher, CTL_IFACE_FRAMEMGR, "FrameRemoved");
  g_signal_connect (watcher, "event",
                    G_CALLBACK (logs_print_event), inv);
  ctl_watcher_run (watcher);
  g_object_unref (watcher);
  return CTL_EXIT_OK;
}

/* ── repl ──────────────────────────────────────────────────────────── */

static gchar *repl_opt_lang = NULL;

static const GOptionEntry repl_entries[] = {
  { "lang", 'l', 0, G_OPTION_ARG_STRING, &repl_opt_lang,
    "Language: elisp (default), crispy, bacon, or eshell", "LANG" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_repl (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self;
  return ctl_repl_run (inv,
                       repl_opt_lang != NULL ? repl_opt_lang : "elisp",
                       error);
}

/* ── config group ──────────────────────────────────────────────────── */

static gint
cmd_config_init (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self;
  return ctl_config_init_boilerplate (
    ctl_invocation_get_arg (inv, 0), error)
    ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_config_view (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlConfig *config = ctl_invocation_get_config (inv);
  gchar *contents = NULL;

  (void) self;

  if (!g_file_test (ctl_config_get_path (config), G_FILE_TEST_EXISTS))
    {
      printf ("# no config at %s (run `config init')\n",
              ctl_config_get_path (config));
      return CTL_EXIT_OK;
    }
  if (!g_file_get_contents (ctl_config_get_path (config), &contents,
                            NULL, error))
    return CTL_EXIT_ERROR;
  fputs (contents, stdout);
  g_free (contents);
  return CTL_EXIT_OK;
}

static gint
cmd_config_use_context (CtlCommand *self, CtlInvocation *inv,
                        GError **error)
{
  const gchar *name = ctl_invocation_get_arg (inv, 0);

  (void) self;

  if (name == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "usage: config use-context NAME");
      return CTL_EXIT_USAGE;
    }
  if (!ctl_config_use_context (ctl_invocation_get_config (inv), name,
                               error))
    return CTL_EXIT_ERROR;
  printf ("switched to context \"%s\"\n", name);
  return CTL_EXIT_OK;
}

static gint
cmd_config_get_contexts (CtlCommand *self, CtlInvocation *inv,
                         GError **error)
{
  CtlConfig *config = ctl_invocation_get_config (inv);
  gchar **names = ctl_config_list_contexts (config);
  const gchar *current = ctl_config_get_current_context (config);
  JsonArray *rows = json_array_new ();
  CtlResult *result;
  gint k;
  gboolean ok;

  (void) self;

  for (k = 0; names[k] != NULL; k++)
    {
      JsonObject *row = json_object_new ();
      JsonNode *node = json_node_new (JSON_NODE_OBJECT);
      json_object_set_string_member (row, "name", names[k]);
      json_object_set_boolean_member (row, "current",
        g_strcmp0 (names[k], current) == 0);
      json_node_take_object (node, row);
      json_array_add_element (rows, node);
    }
  g_strfreev (names);

  result = ctl_result_new_list (rows);
  ctl_result_add_column (result, "Name", "name");
  ctl_result_add_column (result, "Current", "current");
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* ── completion + __complete ───────────────────────────────────────── */

static CtlCommandRegistry *complete_registry = NULL;

static gint
cmd_completion (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  (void) self;
  return ctl_completion_print_script (ctl_invocation_get_arg (inv, 0),
                                      error);
}

static gint
cmd_complete_hidden (CtlCommand *self, CtlInvocation *inv,
                     GError **error)
{
  (void) self; (void) error;
  return ctl_completion_complete (complete_registry, inv);
}

/* ── proxy (hidden) ────────────────────────────────────────────────── */

static gint
cmd_proxy (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  CtlProxyServer *server;
  gint code;

  (void) self;

  server = ctl_proxy_server_new (ctl_invocation_get_instance (inv),
                                 error);
  if (server == NULL)
    return CTL_EXIT_NO_INSTANCE;
  code = ctl_proxy_server_run (server);
  g_object_unref (server);
  return code;
}

/* ── Registration ──────────────────────────────────────────────────── */

void
ctl_cmd_core_register (CtlCommandRegistry *registry)
{
  complete_registry = registry;

  ctl_command_registry_add (registry, ctl_simple_command_new (
    "version", "Client (and reachable server) version", "",
    cmd_version));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "instances", "List running cmacs instances", "", cmd_instances));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "get instances", "List running cmacs instances", "",
    cmd_instances));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "describe instance", "Full identity of the target instance", "",
    cmd_describe_instance));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "get content-org",
      "Structured org buffer content (headline tree; filterable)",
      "BUFFER", content_org_entries, cmd_get_content_org));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "eval", "Evaluate an expression in the editor", "EXPR…",
      eval_entries, cmd_eval));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "logs", "Show (and follow) *Messages*", "",
      logs_entries, cmd_logs));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "repl", "Interactive REPL on the live editor", "",
      repl_entries, cmd_repl));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "watch stream", "Stream buffer/frame change events", "",
    cmd_watch_stream));

  ctl_command_registry_add (registry, ctl_simple_command_new (
    "config init", "Write a commented starter config", "[PATH]",
    cmd_config_init));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "config view", "Print the active config file", "",
    cmd_config_view));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "config use-context", "Switch the current context", "NAME",
    cmd_config_use_context));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "config get-contexts", "List configured contexts", "",
    cmd_config_get_contexts));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "get contexts", "List configured contexts", "",
    cmd_config_get_contexts));

  ctl_command_registry_add (registry, ctl_simple_command_new (
    "completion", "Print a shell completion script", "bash|zsh",
    cmd_completion));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "__complete", "(internal) completion backend", "-- WORDS...",
    cmd_complete_hidden));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "_proxy", "(internal) stdio D-Bus bridge", "", cmd_proxy));
  ctl_command_registry_add (registry, ctl_simple_command_new (
    "proxy", "(internal) stdio D-Bus bridge for --host", "",
    cmd_proxy));
}
