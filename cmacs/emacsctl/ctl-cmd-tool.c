/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-tool.c --- the `tool' command group: every capability the
 * editor registered, with no table of them here.
 *
 *   emacsctl tool list [--group G] [--json]     what is there
 *   emacsctl tool describe NAME [--json]        one tool
 *   emacsctl tool call NAME [--ARG VALUE ...] [--json '{...}']
 *   emacsctl tool GROUP VERB [--ARG VALUE ...]  the same, by CLI words
 *
 * The other ctl-cmd-*.c files are tables: one row per verb, naming a
 * D-Bus method somebody wrote for it (or, in ctl-cmd-alias.c, naming
 * the tool the verb is an old spelling of).  This one asks the running
 * editor what it can do -- org.cmacs.Editor1.Tools.List, which is the
 * brigade tool registry rendered by lisp/cmacs/cmacs-capability.el --
 * and builds the verbs, the typed flags and the --help text from the
 * answer.  A tool defined in someone's init file with
 * `cmacs-brigade-deftool' is therefore a subcommand here the moment it
 * is defined, and a tool this build of emacsctl has never heard of
 * works the same as one that shipped with it.
 *
 * The instance being talked to is the source of truth.  Two editors
 * with different tools give two different `emacsctl tool --help'
 * outputs, which is correct.
 *
 * An :async tool needs nothing special: Tools.Call simply answers when
 * the tool finishes.  The one thing the client does is raise its
 * method timeout to cover the tool's own, which the table carries.  */

#include "ctl-cmd-tool.h"
#include "ctl-ifaces.h"
#include "ctl-result.h"
#include "ctl-tool-args.h"
#include "ctl-transport.h"
#include "ctl.h"

#include <json-glib/json-glib.h>
#include <stdio.h>
#include <string.h>

/* ── Talking to org.cmacs.Editor1.Tools ──────────────────────────── */

/* Call METHOD with PARAMS (consumed) and return its (s) reply.  Caller
 * g_frees. */
static gchar *
tool_rpc (CtlInvocation *inv, const gchar *method, GVariant *params,
          gint timeout_ms, GError **error)
{
  CtlTransport *transport;
  GVariant *reply;
  gchar *out;

  transport = ctl_invocation_get_transport (inv, error);
  if (transport == NULL)
    {
      if (params != NULL)
        g_variant_unref (g_variant_ref_sink (params));
      return NULL;
    }
  reply = ctl_transport_call (transport, CTL_IFACE_TOOLS, method, params,
                              timeout_ms, error);
  if (reply == NULL)
    return NULL;
  g_variant_get (reply, "(s)", &out);
  g_variant_unref (reply);
  return out;
}

/* Fetch the capability table.  On success *PARSER owns the document
 * and the returned array, the "tools" member, is borrowed from it. */
static JsonArray *
tool_table (CtlInvocation *inv, JsonParser **parser, GError **error)
{
  gchar *json;
  JsonNode *root;
  JsonObject *doc;

  *parser = NULL;
  json = tool_rpc (inv, "List", NULL, ctl_invocation_get_timeout_ms (inv),
                   error);
  if (json == NULL)
    return NULL;

  *parser = json_parser_new ();
  if (!json_parser_load_from_data (*parser, json, -1, error))
    {
      g_free (json);
      g_clear_object (parser);
      return NULL;
    }
  g_free (json);

  root = json_parser_get_root (*parser);
  doc = (root != NULL && JSON_NODE_HOLDS_OBJECT (root))
    ? json_node_get_object (root) : NULL;
  if (doc == NULL || !json_object_has_member (doc, "tools")
      || !JSON_NODE_HOLDS_ARRAY (json_object_get_member (doc, "tools")))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "the editor's capability table has no tool list "
                   "(is this emacsctl older than the editor?)");
      g_clear_object (parser);
      return NULL;
    }
  return json_object_get_array_member (doc, "tools");
}

/* The string member KEY of OBJ, or "" (never NULL). */
static const gchar *
str_member (JsonObject *obj, const gchar *key)
{
  JsonNode *node;

  if (!json_object_has_member (obj, key))
    return "";
  node = json_object_get_member (obj, key);
  if (!JSON_NODE_HOLDS_VALUE (node)
      || json_node_get_value_type (node) != G_TYPE_STRING)
    return "";
  return json_node_get_string (node);
}

/* Emit TEXT: as a document when AS_JSON and it parses, else verbatim. */
static gint
tool_emit (CtlInvocation *inv, const gchar *text, gboolean as_json,
           GError **error)
{
  CtlResult *result = NULL;
  gboolean ok;

  if (as_json)
    {
      JsonParser *parser = json_parser_new ();
      if (json_parser_load_from_data (parser, text, -1, NULL)
          && json_parser_get_root (parser) != NULL)
        result = ctl_result_new_document (
          json_node_copy (json_parser_get_root (parser)));
      g_object_unref (parser);
    }
  if (result == NULL)
    result = ctl_result_new_scalar (text);

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

JsonArray *
ctl_cmd_tool_table (CtlInvocation *inv, JsonParser **parser, GError **error)
{
  return tool_table (inv, parser, error);
}

/* ── Running a tool ──────────────────────────────────────────────── */

/* Call TOOL with the flags in ARGV and print what it returns.
 *
 * The exit status is the tool's: 0 when it succeeded, 2 when the
 * arguments were refused (here or by the editor), 1 for every other
 * failure.  The failure text goes to stderr through the application's
 * usual error path. */
static gint
tool_run (CtlInvocation *inv, JsonObject *tool, gchar **argv, gint argc,
          GError **error)
{
  const gchar *name = str_member (tool, "name");
  gchar *args, *reply;
  gint code;

  if (!ctl_tool_on_surface (tool, "cli"))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_FAILED,
                   "%s is not published on the cli surface", name);
      return CTL_EXIT_ERROR;
    }

  args = ctl_tool_build_args (tool, argv, argc, error);
  if (args == NULL)
    return CTL_EXIT_USAGE;

  reply = tool_rpc (inv, "Call", g_variant_new ("(ss)", name, args),
                    ctl_tool_timeout_ms (tool,
                                         ctl_invocation_get_timeout_ms (inv)),
                    error);
  g_free (args);
  if (reply == NULL)
    {
      gchar *remote = (error != NULL && *error != NULL)
        ? g_dbus_error_get_remote_error (*error) : NULL;

      code = (remote != NULL && g_str_has_suffix (remote, ".BadArguments"))
        ? CTL_EXIT_USAGE
        : ctl_exit_code_for_error (error != NULL ? *error : NULL);
      g_free (remote);
      return code;
    }

  code = tool_emit (inv, reply,
                    g_strcmp0 (str_member (tool, "returns"), "json") == 0,
                    error);
  g_free (reply);
  return code;
}

/* -- tool call NAME ... ------------------------------------------- */

static gint
cmd_tool_call (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  JsonParser *parser = NULL;
  JsonArray *tools;
  JsonObject *tool;
  gint code;

  (void) self;

  if (argc < 1 || g_str_has_prefix (argv[0], "--"))
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "tool call needs a tool name "
                   "(see 'emacsctl tool list')");
      return CTL_EXIT_USAGE;
    }

  tools = tool_table (inv, &parser, error);
  if (tools == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  tool = ctl_tool_find_by_name (tools, argv[0]);
  if (tool == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "no tool named '%s' on this cmacs "
                   "(see 'emacsctl tool list')", argv[0]);
      code = CTL_EXIT_USAGE;
    }
  else
    code = tool_run (inv, tool, argv + 1, argc - 1, error);

  g_object_unref (parser);
  return code;
}

/* -- tool GROUP VERB ... ------------------------------------------ */

/* The fallback the registry reaches for any `tool X ...' that is not
 * list, describe or call: X is a tool group and the next word a verb. */
static gint
cmd_tool (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  JsonParser *parser = NULL;
  JsonArray *tools;
  JsonObject *tool = NULL;
  gint code;

  (void) self;

  tools = tool_table (inv, &parser, error);
  if (tools == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  if (argc >= 2 && !g_str_has_prefix (argv[0], "--")
      && !g_str_has_prefix (argv[1], "--"))
    tool = ctl_tool_find_by_cli (tools, argv[0], argv[1]);

  if (tool != NULL)
    code = tool_run (inv, tool, argv + 2, argc - 2, error);
  else
    {
      /* Not a tool: show what there is.  A known group gets its verbs,
       * anything else the whole list. */
      gchar *help = NULL;

      if (argc >= 1 && !g_str_has_prefix (argv[0], "--"))
        help = ctl_tool_group_help_string (tools, "emacsctl", argv[0]);
      if (argc >= 2 && help != NULL)
        fprintf (stderr, "emacsctl: no tool '%s %s'\n\n", argv[0], argv[1]);
      else if (argc >= 1 && help == NULL)
        fprintf (stderr, "emacsctl: no tool group '%s'\n\n", argv[0]);
      if (help == NULL)
        help = ctl_tool_group_help_string (tools, "emacsctl", NULL);

      /* A bare `emacsctl tool' asked for the overview and gets it on
       * stdout; a miss is a usage error and goes to stderr. */
      fputs (help, argc == 0 ? stdout : stderr);
      g_free (help);
      code = argc == 0 ? CTL_EXIT_OK : CTL_EXIT_USAGE;
    }

  g_object_unref (parser);
  return code;
}

/* -- tool list ---------------------------------------------------- */

static gchar *tool_opt_group = NULL;
static gboolean tool_opt_list_json = FALSE;

static const GOptionEntry tool_list_entries[] = {
  { "group", 'g', 0, G_OPTION_ARG_STRING, &tool_opt_group,
    "Only the tools in this CLI group", "GROUP" },
  { "json", 0, 0, G_OPTION_ARG_NONE, &tool_opt_list_json,
    "Print the capability table itself, as the editor sent it", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

/* "destructive, confirm, async" for TOOL.  Caller g_frees. */
static gchar *
tool_flags (JsonObject *tool)
{
  GString *out = g_string_new (NULL);

  if (json_object_get_boolean_member_with_default (tool, "destructive",
                                                   FALSE))
    g_string_append (out, "destructive");
  if (*str_member (tool, "confirm") != '\0')
    g_string_append_printf (out, "%sconfirm", out->len > 0 ? "," : "");
  if (json_object_get_boolean_member_with_default (tool, "async", FALSE))
    g_string_append_printf (out, "%sasync", out->len > 0 ? "," : "");
  return g_string_free (out, FALSE);
}

static gint
cmd_tool_list (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  JsonParser *parser = NULL;
  JsonArray *tools, *rows;
  CtlResult *result;
  gboolean ok;
  guint n, k;
  gsize group_len = tool_opt_group != NULL ? strlen (tool_opt_group) : 0;

  (void) self;

  tools = tool_table (inv, &parser, error);
  if (tools == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  rows = json_array_new ();
  n = json_array_get_length (tools);
  for (k = 0; k < n; k++)
    {
      JsonNode *node = json_array_get_element (tools, k);
      JsonObject *tool;
      const gchar *cli;

      if (!JSON_NODE_HOLDS_OBJECT (node))
        continue;
      tool = json_node_get_object (node);
      /* The D-Bus table lists what is callable over D-Bus; the CLI is
       * its own surface and a tool may have opted out of it. */
      if (!ctl_tool_on_surface (tool, "cli"))
        continue;
      cli = str_member (tool, "cli");
      if (tool_opt_group != NULL
          && !(strncmp (cli, tool_opt_group, group_len) == 0
               && cli[group_len] == ' '))
        continue;

      if (tool_opt_list_json)
        json_array_add_element (rows, json_node_copy (node));
      else
        {
          JsonObject *row = json_object_new ();
          gchar *flags = tool_flags (tool);
          const gchar *desc = str_member (tool, "description");
          const gchar *stop = strstr (desc, ".  ");
          gchar *summary = stop != NULL
            ? g_strndup (desc, stop - desc + 1) : g_strdup (desc);

          json_object_set_string_member (row, "command", cli);
          json_object_set_string_member (row, "tool",
                                         str_member (tool, "name"));
          json_object_set_string_member (row, "flags", flags);
          json_object_set_string_member (row, "summary", summary);
          json_array_add_object_element (rows, row);
          g_free (flags);
          g_free (summary);
        }
    }

  if (tool_opt_list_json)
    {
      JsonNode *root = json_node_new (JSON_NODE_ARRAY);
      json_node_take_array (root, rows);
      result = ctl_result_new_document (root);
    }
  else
    {
      result = ctl_result_new_list (rows);
      ctl_result_add_column (result, "COMMAND", "command");
      ctl_result_add_column (result, "TOOL", "tool");
      ctl_result_add_column (result, "FLAGS", "flags");
      ctl_result_add_column (result, "SUMMARY", "summary");
    }

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_object_unref (parser);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

/* -- tool describe NAME ------------------------------------------- */

static gboolean tool_opt_describe_json = FALSE;

static const GOptionEntry tool_describe_entries[] = {
  { "json", 0, 0, G_OPTION_ARG_NONE, &tool_opt_describe_json,
    "Print the tool's table entry, as the editor sent it", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static gint
cmd_tool_describe (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  gint argc;
  gchar **argv = ctl_invocation_get_args (inv, &argc);
  JsonParser *parser = NULL;
  JsonArray *tools;
  JsonObject *tool;
  gint code = CTL_EXIT_OK;

  (void) self;

  if (argc < 1)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "tool describe needs a tool name");
      return CTL_EXIT_USAGE;
    }

  tools = tool_table (inv, &parser, error);
  if (tools == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  /* By wire name, or by the two CLI words: `tool describe calc eval'
   * is what someone who just ran `tool calc eval' will type. */
  tool = ctl_tool_find_by_name (tools, argv[0]);
  if (tool == NULL && argc >= 2)
    tool = ctl_tool_find_by_cli (tools, argv[0], argv[1]);

  if (tool == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "no tool named '%s' on this cmacs "
                   "(see 'emacsctl tool list')", argv[0]);
      code = CTL_EXIT_USAGE;
    }
  else if (tool_opt_describe_json)
    {
      JsonNode *node = json_node_new (JSON_NODE_OBJECT);
      CtlResult *result;

      json_node_set_object (node, tool);
      result = ctl_result_new_document (node);
      if (!ctl_invocation_emit (inv, result, error))
        code = CTL_EXIT_ERROR;
      ctl_result_unref (result);
    }
  else
    {
      gchar *help = ctl_tool_help_string (tool, "emacsctl");
      fputs (help, stdout);
      g_free (help);
    }

  g_object_unref (parser);
  return code;
}

/* ── Help from the live table ────────────────────────────────────── */

gint
ctl_cmd_tool_help (CtlInvocation *inv, const gchar *prog,
                   gchar **words, gint n_words)
{
  JsonParser *parser = NULL;
  JsonArray *tools;
  JsonObject *tool = NULL;
  GError *error = NULL;
  gchar *help = NULL;

  if (n_words < 1 || g_strcmp0 (words[0], "tool") != 0)
    return -1;

  /* list and describe have ordinary static flags; their help is the
   * generic renderer's.  `tool call --help' with no name likewise. */
  if (n_words >= 2
      && (g_strcmp0 (words[1], "list") == 0
          || g_strcmp0 (words[1], "describe") == 0
          || (g_strcmp0 (words[1], "call") == 0 && n_words == 2)))
    return -1;

  tools = tool_table (inv, &parser, &error);
  if (tools == NULL)
    {
      /* No editor to ask is not a reason to print nothing: say so and
       * let the caller show the static usage. */
      g_dbus_error_strip_remote_error (error);
      fprintf (stderr,
               "%s: cannot read the tool list from a running cmacs (%s); "
               "showing the built-in usage only\n\n", prog, error->message);
      g_error_free (error);
      return -1;
    }

  if (n_words == 1)
    help = ctl_tool_group_help_string (tools, prog, NULL);
  else if (g_strcmp0 (words[1], "call") == 0)
    tool = ctl_tool_find_by_name (tools, words[2]);
  else if (n_words >= 3)
    tool = ctl_tool_find_by_cli (tools, words[1], words[2]);

  if (tool != NULL)
    help = ctl_tool_help_string (tool, prog);
  else if (help == NULL)
    {
      /* A group, or a miss: the group's verbs when it is one, the
       * whole list when it is not. */
      help = ctl_tool_group_help_string (tools, prog, words[1]);
      if (help == NULL)
        help = ctl_tool_group_help_string (tools, prog, NULL);
    }

  fputs (help, stdout);
  g_free (help);
  g_object_unref (parser);
  return CTL_EXIT_OK;
}

/* ── Registration ────────────────────────────────────────────────── */

void
ctl_cmd_tool_register (CtlCommandRegistry *registry)
{
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "tool list",
      "List the capabilities the running cmacs registered",
      NULL, tool_list_entries, cmd_tool_list));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "tool describe",
      "Show one tool: its arguments, surfaces and flags",
      "NAME", tool_describe_entries, cmd_tool_describe));
  /* No option entries on the next two: their flags are the tool's
   * parameters, which are not known until the editor is asked, so the
   * application passes the words through and ctl_tool_build_args types
   * them against the table. */
  ctl_command_registry_add (registry,
    ctl_simple_command_new (
      "tool call",
      "Call a tool by name (flags come from 'tool describe NAME')",
      "NAME [--ARG VALUE…] [--json '{…}']", cmd_tool_call));
  ctl_command_registry_add (registry,
    ctl_simple_command_new (
      "tool",
      "Run a registered capability: tool GROUP VERB [--ARG VALUE…]",
      "GROUP VERB [--ARG VALUE…]", cmd_tool));
}
