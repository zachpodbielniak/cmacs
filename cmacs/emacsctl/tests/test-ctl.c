/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* test-ctl.c --- transport-free unit tests for emacsctl internals:
 * CtlResult, the JSON<->YAML converter, the frame codec, config
 * parsing, and the REPL multi-line balancers.  Run via
 * `make -C cmacs/emacsctl check'. */

#include "ctl-result.h"
#include "ctl-json-yaml.h"
#include "ctl-frame.h"
#include "ctl-config.h"
#include "ctl-repl.h"
#include "ctl-tool-args.h"
#include "ctl-alias.h"
#include "ctl-cmd-alias.h"
#include "ctl-cmd-tool.h"
#include "ctl-completion.h"
#include "ctl-ifaces.h"

#include <gio/gio.h>
#include <glib/gstdio.h>
#include <string.h>

/* ── CtlResult ─────────────────────────────────────────────────────── */

static void
test_result_scalar (void)
{
  CtlResult *result = ctl_result_new_scalar ("hello");
  JsonNode *node;

  g_assert_cmpint (ctl_result_get_kind (result), ==,
                   CTL_RESULT_SCALAR);
  g_assert_cmpstr (ctl_result_get_scalar (result), ==, "hello");

  node = ctl_result_to_json_node (result);
  g_assert_cmpstr (json_node_get_string (node), ==, "hello");
  json_node_unref (node);

  ctl_result_ref (result);
  ctl_result_unref (result);
  ctl_result_unref (result);
}

static void
test_result_list_columns (void)
{
  JsonArray *rows = json_array_new ();
  CtlResult *result;
  JsonObject *row = json_object_new ();
  JsonNode *node = json_node_new (JSON_NODE_OBJECT);

  json_object_set_string_member (row, "name", "alpha");
  json_object_set_int_member (row, "pid", 42);
  json_node_take_object (node, row);
  json_array_add_element (rows, node);

  result = ctl_result_new_list (rows);
  ctl_result_add_column (result, "Name", "name");
  ctl_result_add_column (result, "Pid", "pid");

  g_assert_cmpuint (ctl_result_get_n_columns (result), ==, 2);
  g_assert_cmpstr (ctl_result_get_column_title (result, 0), ==, "Name");
  g_assert_cmpstr (ctl_result_get_column_key (result, 1), ==, "pid");
  ctl_result_unref (result);
}

/* ── JSON <-> YAML round trip ──────────────────────────────────────── */

static void
test_json_yaml_roundtrip (void)
{
  const gchar *json_text =
    "{\"name\":\"x\",\"n\":3,\"ok\":true,"
    "\"list\":[1,2,\"three\"],\"nested\":{\"a\":null}}";
  JsonParser *parser = json_parser_new ();
  YamlNode *yaml;
  JsonNode *back;
  JsonObject *obj;

  g_assert_true (json_parser_load_from_data (parser, json_text, -1,
                                             NULL));
  yaml = ctl_json_to_yaml (json_parser_get_root (parser));
  g_assert_nonnull (yaml);
  back = ctl_yaml_to_json (yaml);
  g_assert_true (JSON_NODE_HOLDS_OBJECT (back));
  obj = json_node_get_object (back);
  g_assert_cmpstr (json_object_get_string_member (obj, "name"), ==,
                   "x");
  g_assert_true (JSON_NODE_HOLDS_ARRAY (
    json_object_get_member (obj, "list")));

  yaml_node_unref (yaml);
  json_node_unref (back);
  g_object_unref (parser);
}

/* ── Frame codec ───────────────────────────────────────────────────── */

static void
test_frame_roundtrip (void)
{
  JsonObject *frame = ctl_frame_new ("call");
  GOutputStream *out = g_memory_output_stream_new_resizable ();
  GInputStream *in;
  JsonObject *read_back;
  GError *error = NULL;
  gboolean eof = FALSE;
  GVariant *params, *got;

  json_object_set_int_member (frame, "id", 7);
  params = g_variant_ref_sink (g_variant_new ("(si)", "x", 9));
  ctl_frame_set_variant (frame, "params", params);

  g_assert_true (ctl_frame_write (out, frame, &error));
  g_assert_no_error (error);
  json_object_unref (frame);

  g_output_stream_close (out, NULL, NULL);
  in = g_memory_input_stream_new_from_bytes (
    g_memory_output_stream_steal_as_bytes (
      G_MEMORY_OUTPUT_STREAM (out)));
  read_back = ctl_frame_read (in, &eof, &error);
  g_assert_no_error (error);
  g_assert_nonnull (read_back);
  g_assert_cmpint (
    json_object_get_int_member (read_back, "id"), ==, 7);

  got = ctl_frame_get_variant (read_back, "params", &error);
  g_assert_no_error (error);
  g_assert_nonnull (got);
  g_assert_true (g_variant_equal (params, got));

  g_variant_unref (params);
  g_variant_unref (got);
  json_object_unref (read_back);
  g_object_unref (in);
  g_object_unref (out);
}

static void
test_frame_large_payload (void)
{
  JsonObject *frame = ctl_frame_new ("call");
  GOutputStream *out = g_memory_output_stream_new_resizable ();
  GInputStream *in;
  JsonObject *read_back;
  GError *error = NULL;
  gboolean eof = FALSE;
  GString *big = g_string_new (NULL);
  gsize k;

  for (k = 0; k < (80u << 10); k++)
    g_string_append_c (big, 'a' + (gchar) (k % 26));
  json_object_set_string_member (frame, "blob", big->str);

  g_assert_true (ctl_frame_write (out, frame, &error));
  g_assert_no_error (error);

  g_output_stream_close (out, NULL, NULL);
  in = g_memory_input_stream_new_from_bytes (
    g_memory_output_stream_steal_as_bytes (
      G_MEMORY_OUTPUT_STREAM (out)));
  read_back = ctl_frame_read (in, &eof, &error);
  g_assert_no_error (error);
  g_assert_cmpstr (
    json_object_get_string_member (read_back, "blob"), ==, big->str);

  g_string_free (big, TRUE);
  json_object_unref (frame);
  json_object_unref (read_back);
  g_object_unref (in);
  g_object_unref (out);
}

static void
test_frame_truncated (void)
{
  /* A header announcing 100 bytes followed by only 3. */
  const guchar bytes[] = { 0, 0, 0, 100, 'a', 'b', 'c' };
  GInputStream *in = g_memory_input_stream_new_from_data (
    bytes, sizeof bytes, NULL);
  GError *error = NULL;
  gboolean eof = FALSE;
  JsonObject *frame = ctl_frame_read (in, &eof, &error);

  g_assert_null (frame);
  g_assert_false (eof);
  g_assert_nonnull (error);
  g_clear_error (&error);
  g_object_unref (in);
}

/* ── Config ────────────────────────────────────────────────────────── */

static void
test_config_boilerplate_parses (void)
{
  gchar *dir = g_dir_make_tmp ("emacsctl-test-XXXXXX", NULL);
  gchar *path = g_build_filename (dir, "emacsctl.yaml", NULL);
  GError *error = NULL;
  CtlConfig *config;
  CtlContext *ctx;
  gchar **names;

  g_assert_true (ctl_config_init_boilerplate (path, &error));
  g_assert_no_error (error);

  config = ctl_config_load (path, &error);
  g_assert_no_error (error);
  g_assert_nonnull (config);
  g_assert_cmpstr (ctl_config_get_current_context (config), ==,
                   "local");

  ctx = ctl_config_resolve_context (config, NULL, &error);
  g_assert_nonnull (ctx);
  g_assert_cmpstr (ctx->name, ==, "local");
  g_assert_cmpstr (ctx->instance, ==, "primary");
  ctl_context_free (ctx);

  names = ctl_config_list_contexts (config);
  g_assert_cmpuint (g_strv_length (names), ==, 1);
  g_strfreev (names);

  /* Unknown context names error out. */
  ctx = ctl_config_resolve_context (config, "nope", &error);
  g_assert_null (ctx);
  g_clear_error (&error);

  g_object_unref (config);
  g_remove (path);
  g_remove (dir);
  g_free (path);
  g_free (dir);
}

static void
test_config_use_context_preserves_comments (void)
{
  gchar *dir = g_dir_make_tmp ("emacsctl-test-XXXXXX", NULL);
  gchar *path = g_build_filename (dir, "emacsctl.yaml", NULL);
  const gchar *body =
    "# my precious comment\n"
    "current-context: a\n"
    "contexts:\n"
    "  - name: a\n"
    "  - name: b\n";
  GError *error = NULL;
  CtlConfig *config;
  gchar *contents = NULL;

  g_assert_true (g_file_set_contents (path, body, -1, NULL));
  config = ctl_config_load (path, &error);
  g_assert_no_error (error);

  g_assert_true (ctl_config_use_context (config, "b", &error));
  g_assert_no_error (error);

  g_assert_true (g_file_get_contents (path, &contents, NULL, NULL));
  g_assert_nonnull (strstr (contents, "# my precious comment"));
  g_assert_nonnull (strstr (contents, "current-context: b"));
  g_free (contents);

  /* Unknown context refused. */
  g_assert_false (ctl_config_use_context (config, "zzz", &error));
  g_clear_error (&error);

  g_object_unref (config);
  g_remove (path);
  g_remove (dir);
  g_free (path);
  g_free (dir);
}

/* ── REPL balancers ────────────────────────────────────────────────── */

static void
test_repl_is_complete (void)
{
  CtlReplRuntime *elisp, *crispy, *bacon;
  GError *error = NULL;

  ctl_repl_register_builtin_runtimes ();

  elisp = ctl_repl_runtime_new_for_lang ("elisp", &error);
  g_assert_no_error (error);
  g_assert_true (ctl_repl_runtime_is_complete (elisp, "(+ 1 2)"));
  g_assert_false (ctl_repl_runtime_is_complete (elisp, "(+ 1"));
  g_assert_false (ctl_repl_runtime_is_complete (elisp,
                                                "(insert \"(\""));
  g_assert_true (ctl_repl_runtime_is_complete (elisp,
                                               "(insert \"(\")"));

  crispy = ctl_repl_runtime_new_for_lang ("crispy", &error);
  g_assert_no_error (error);
  g_assert_false (ctl_repl_runtime_is_complete (crispy,
                                                "if (x) {"));
  g_assert_true (ctl_repl_runtime_is_complete (crispy,
                                               "if (x) { y(); }"));

  bacon = ctl_repl_runtime_new_for_lang ("bacon", &error);
  g_assert_no_error (error);
  g_assert_true (ctl_repl_runtime_is_complete (bacon, "echo {"));

  /* Unknown language errors with the available list. */
  g_assert_null (ctl_repl_runtime_new_for_lang ("cobol", &error));
  g_assert_nonnull (error);
  g_clear_error (&error);

  g_object_unref (elisp);
  g_object_unref (crispy);
  g_object_unref (bacon);
}

/* ── `emacsctl tool': typed flags and help from a capability table ── */

/* A table shaped like org.cmacs.Editor1.Tools.List's, written here so
 * the test needs no editor.  Caller unrefs the parser. */
static JsonArray *
tool_fixture (JsonParser **parser)
{
  static const gchar *json =
    "{\"version\":1,\"tools\":["
    "{\"name\":\"calc_eval\",\"cli\":\"calc eval\",\"group\":\"calc\","
    " \"description\":\"Evaluate an expression.  Longer text.\","
    " \"returns\":\"string\",\"destructive\":false,\"confirm\":null,"
    " \"async\":false,\"timeout\":120,"
    " \"surfaces\":[\"mcp\",\"dbus\",\"cli\",\"agents\"],"
    " \"aliases\":[\"calculate\"],"
    " \"params\":[{\"name\":\"expression\",\"type\":\"string\","
    "   \"description\":\"Expression\",\"required\":true}]},"
    "{\"name\":\"speech_transcribe\",\"cli\":\"speech transcribe\","
    " \"group\":\"speech\",\"description\":\"Transcribe a file.\","
    " \"returns\":\"json\",\"destructive\":false,\"confirm\":null,"
    " \"async\":true,\"timeout\":900,"
    " \"surfaces\":[\"dbus\",\"cli\"],\"aliases\":[],"
    " \"params\":["
    "  {\"name\":\"path\",\"type\":\"string\",\"description\":\"File\","
    "   \"required\":true},"
    "  {\"name\":\"max_speakers\",\"type\":\"integer\","
    "   \"description\":\"Cap\",\"required\":false},"
    "  {\"name\":\"gain\",\"type\":\"number\",\"description\":\"Gain\","
    "   \"required\":false},"
    "  {\"name\":\"timestamps\",\"type\":\"boolean\","
    "   \"description\":\"Stamp\",\"required\":false}]},"
    "{\"name\":\"team_add\",\"cli\":\"team add\",\"group\":\"team\","
    " \"description\":\"Define a team.\",\"returns\":\"string\","
    " \"destructive\":false,\"confirm\":null,\"async\":false,"
    " \"timeout\":120,\"surfaces\":[\"dbus\",\"cli\"],\"aliases\":[],"
    " \"params\":["
    "  {\"name\":\"members\",\"type\":\"array\",\"description\":\"Ids\","
    "   \"required\":true,"
    "   \"schema\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},"
    "  {\"name\":\"tags\",\"type\":\"array\",\"description\":\"Tags\","
    "   \"required\":false,"
    "   \"schema\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},"
    "  {\"name\":\"steps\",\"type\":\"array\",\"description\":\"Steps\","
    "   \"required\":false,"
    "   \"schema\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}}},"
    "  {\"name\":\"rule\",\"type\":\"object\",\"description\":\"Rule\","
    "   \"required\":false,"
    "   \"schema\":{\"type\":\"object\",\"properties\":"
    "    {\"app\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"}},"
    "    \"required\":[\"app\"]}}]},"
    "{\"name\":\"agents_only\",\"cli\":\"misc agents-only\",\"group\":null,"
    " \"description\":\"Not for the CLI.\",\"returns\":\"string\","
    " \"destructive\":false,\"confirm\":null,\"async\":false,"
    " \"timeout\":120,\"surfaces\":[\"dbus\"],\"aliases\":[],"
    " \"params\":[]}"
    "]}";
  GError *error = NULL;

  *parser = json_parser_new ();
  json_parser_load_from_data (*parser, json, -1, &error);
  g_assert_no_error (error);
  return json_object_get_array_member (
    json_node_get_object (json_parser_get_root (*parser)), "tools");
}

static void
test_tool_lookup (void)
{
  JsonParser *parser;
  JsonArray *tools = tool_fixture (&parser);
  JsonObject *calc = ctl_tool_find_by_name (tools, "calc_eval");

  g_assert_nonnull (calc);
  /* The registry spelling and an alias reach the same tool. */
  g_assert_true (ctl_tool_find_by_name (tools, "calc-eval") == calc);
  g_assert_true (ctl_tool_find_by_name (tools, "calculate") == calc);
  g_assert_true (ctl_tool_find_by_cli (tools, "calc", "eval") == calc);
  g_assert_null (ctl_tool_find_by_name (tools, "calc"));
  g_assert_null (ctl_tool_find_by_cli (tools, "calc", "nope"));

  g_assert_true (ctl_tool_on_surface (calc, "cli"));
  g_assert_false (ctl_tool_on_surface (
    ctl_tool_find_by_name (tools, "agents_only"), "cli"));

  /* Only an async tool raises the method timeout, and only upward. */
  g_assert_cmpint (ctl_tool_timeout_ms (calc, 30000), ==, 30000);
  g_assert_cmpint (ctl_tool_timeout_ms (calc, -1), ==, -1);
  g_assert_cmpint (ctl_tool_timeout_ms (
    ctl_tool_find_by_name (tools, "speech_transcribe"), 30000), ==, 905000);
  g_assert_cmpint (ctl_tool_timeout_ms (
    ctl_tool_find_by_name (tools, "speech_transcribe"), 2000000),
    ==, 2000000);

  g_object_unref (parser);
}

/* Build args for TOOL from a NULL-terminated word list; returns the
 * JSON (caller frees) or NULL with *ERROR set. */
static gchar *
tool_args (JsonObject *tool, GError **error, ...)
{
  GPtrArray *words = g_ptr_array_new ();
  const gchar *word;
  gchar *out;
  va_list ap;

  va_start (ap, error);
  while ((word = va_arg (ap, const gchar *)) != NULL)
    g_ptr_array_add (words, (gpointer) word);
  va_end (ap);
  out = ctl_tool_build_args (tool, (gchar **) words->pdata,
                             (gint) words->len, error);
  g_ptr_array_free (words, TRUE);
  return out;
}

static void
test_tool_build_args (void)
{
  JsonParser *parser;
  JsonArray *tools = tool_fixture (&parser);
  JsonObject *speech = ctl_tool_find_by_name (tools, "speech_transcribe");
  JsonObject *calc = ctl_tool_find_by_name (tools, "calc_eval");
  GError *error = NULL;
  gchar *json;

  /* Each flag is typed by the table: a string stays a string even when
   * it looks like a number, an integer becomes a JSON number, a bare
   * boolean flag is true, and `-' stands for `_'. */
  json = tool_args (speech, &error, "--path", "42", "--max-speakers", "3",
                    "--gain=1.5", "--timestamps", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"path\":\"42\",\"max_speakers\":3,"
                             "\"gain\":1.5,\"timestamps\":true}");
  g_free (json);

  json = tool_args (speech, &error, "--path", "a.wav", "--no-timestamps",
                    NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"path\":\"a.wav\",\"timestamps\":false}");
  g_free (json);

  json = tool_args (speech, &error, "--timestamps", "false", "--path", "x",
                    NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"timestamps\":false,\"path\":\"x\"}");
  g_free (json);

  /* --json supplies the object; a flag beside it overrides a member,
   * whichever comes first on the line. */
  json = tool_args (speech, &error, "--max-speakers", "9", "--json",
                    "{\"path\":\"j.wav\",\"max_speakers\":2}", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"path\":\"j.wav\",\"max_speakers\":9}");
  g_free (json);

  /* Quotes and backslashes in a value are JSON's problem, not ours. */
  json = tool_args (calc, &error, "--expression", "a \"b\" \\ c", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"expression\":\"a \\\"b\\\" \\\\ c\"}");
  g_free (json);

  /* The refusals, each a usage error naming the flag. */
  g_assert_null (tool_args (speech, &error, "--path", "x",
                            "--max-speakers", "many", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_nonnull (strstr (error->message, "--max_speakers"));
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--path", "x", "--gain", "1.5x",
                            NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--path", "x", "--bogus", "1",
                            NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_nonnull (strstr (error->message, "--bogus"));
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--max-speakers", "2", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_nonnull (strstr (error->message, "--path"));
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--path", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "stray", "--path", "x", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--json", "[1,2]", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  g_assert_null (tool_args (speech, &error, "--json", "{not json", NULL));
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  g_object_unref (parser);
}

/* Array and object parameters: one element per flag, the whole array
 * as JSON, an object as JSON -- and a usage error before any call for
 * the forms that are neither. */
static void
test_tool_structured_args (void)
{
  JsonParser *parser;
  JsonArray *tools = tool_fixture (&parser);
  JsonObject *team = ctl_tool_find_by_name (tools, "team_add");
  GError *error = NULL;
  gchar *json;

  g_assert_nonnull (team);

  /* Repeating the flag appends, typed by the array's item type: the
   * integers are numbers, and a tag made of digits stays a string. */
  json = tool_args (team, &error, "--members", "3", "--members=4",
                    "--tags", "42", "--tags", "b c", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==,
                   "{\"members\":[3,4],\"tags\":[\"42\",\"b c\"]}");
  g_free (json);

  /* The whole array at once, and the two forms mixed. */
  json = tool_args (team, &error, "--members", "[1,2]", "--members", "3",
                    NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"members\":[1,2,3]}");
  g_free (json);

  /* An element of the wrong type is refused here, naming the flag. */
  json = tool_args (team, &error, "--members", "three", NULL);
  g_assert_null (json);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_nonnull (strstr (error->message, "--members"));
  g_clear_error (&error);

  /* An array of objects takes JSON: one element per flag, or all. */
  json = tool_args (team, &error, "--members", "1",
                    "--steps", "{\"k\":1}", "--steps", "{\"k\":2}", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==,
                   "{\"members\":[1],\"steps\":[{\"k\":1},{\"k\":2}]}");
  g_free (json);
  json = tool_args (team, &error, "--members", "1", "--steps", "nope",
                    NULL);
  g_assert_null (json);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  /* An object is a JSON object and nothing else. */
  json = tool_args (team, &error, "--members", "1",
                    "--rule", "{\"app\":\"foot\"}", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==,
                   "{\"members\":[1],\"rule\":{\"app\":\"foot\"}}");
  g_free (json);
  json = tool_args (team, &error, "--members", "1", "--rule", "[1]", NULL);
  g_assert_null (json);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_nonnull (strstr (error->message, "JSON object"));
  g_clear_error (&error);

  /* A flag replaces what --json gave for that array; it does not add
   * to it.  Members --json gave and no flag touched are kept. */
  json = tool_args (team, &error,
                    "--json", "{\"members\":[9,9],\"tags\":[\"x\"]}",
                    "--members", "1", NULL);
  g_assert_no_error (error);
  g_assert_cmpstr (json, ==, "{\"members\":[1],\"tags\":[\"x\"]}");
  g_free (json);

  /* A required array that was never given is still a usage error. */
  json = tool_args (team, &error, "--tags", "a", NULL);
  g_assert_null (json);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_clear_error (&error);

  /* --help says how each is written. */
  json = ctl_tool_help_string (team, "emacsctl");
  g_assert_nonnull (strstr (json, "--members INT…"));
  g_assert_nonnull (strstr (json, "[--tags STRING…]"));
  g_assert_nonnull (strstr (json, "[--steps JSON…]"));
  g_assert_nonnull (strstr (json, "[--rule JSON]"));
  g_assert_nonnull (strstr (json, "repeat the flag for each element"));
  g_assert_nonnull (strstr (json, "A JSON object with: app, title"));
  g_free (json);

  g_object_unref (parser);
}

static void
test_tool_help (void)
{
  JsonParser *parser;
  JsonArray *tools = tool_fixture (&parser);
  gchar *help;

  /* One tool: its CLI words, every flag with its type, and that it is
   * async -- all from the table. */
  help = ctl_tool_help_string (
    ctl_tool_find_by_name (tools, "speech_transcribe"), "emacsctl");
  g_assert_nonnull (strstr (help, "emacsctl [OPTION…] tool speech "
                                  "transcribe --path STRING"));
  g_assert_nonnull (strstr (help, "[--max_speakers INT]"));
  g_assert_nonnull (strstr (help, "[--timestamps]"));
  g_assert_nonnull (strstr (help, "(required) File"));
  g_assert_nonnull (strstr (help, "within 900s"));
  g_free (help);

  /* The overview lists what is on the cli surface and nothing else. */
  help = ctl_tool_group_help_string (tools, "emacsctl", NULL);
  g_assert_nonnull (strstr (help, "calc:\n"));
  g_assert_nonnull (strstr (help, "Evaluate an expression."));
  g_assert_null (strstr (help, "Longer text"));
  g_assert_null (strstr (help, "agents-only"));
  g_free (help);

  help = ctl_tool_group_help_string (tools, "emacsctl", "speech");
  g_assert_nonnull (strstr (help, "transcribe"));
  g_assert_null (strstr (help, "calc:"));
  g_free (help);

  g_assert_null (ctl_tool_group_help_string (tools, "emacsctl", "nope"));
  /* `misc' exists in the table but has nothing on the cli surface. */
  g_assert_null (ctl_tool_group_help_string (tools, "emacsctl", "misc"));

  g_object_unref (parser);
}

/* ── Verb aliases ──────────────────────────────────────────────────── */

void ctl_cmd_core_register   (CtlCommandRegistry *registry);
void ctl_cmd_editor_register (CtlCommandRegistry *registry);
void ctl_cmd_subsys_register (CtlCommandRegistry *registry);
void ctl_cmd_gowl_register   (CtlCommandRegistry *registry);
void ctl_cmd_sb_register     (CtlCommandRegistry *registry);

/* The registry exactly as ctl-main.c builds it. */
static CtlCommandRegistry *
full_registry (void)
{
  CtlCommandRegistry *registry = ctl_command_registry_new ();

  ctl_cmd_core_register (registry);
  ctl_cmd_editor_register (registry);
  ctl_cmd_subsys_register (registry);
  ctl_cmd_gowl_register (registry);
  ctl_cmd_sb_register (registry);
  ctl_cmd_tool_register (registry);
  return registry;
}

/* The JSON the alias for VERB sends for the words in LINE (split on
 * `|', so an argument may contain spaces).  Caller g_frees. */
static gchar *
alias_args_for (const gchar *verb, const gchar *line, GError **error)
{
  const CtlAliasSpec *spec = ctl_cmd_alias_find (verb);
  gchar **argv = g_strsplit (line, "|", -1);
  gint argc = (gint) g_strv_length (argv);
  gchar *out;

  g_assert_nonnull (spec);
  /* "" is no words, not one empty word. */
  if (*line == '\0')
    argc = 0;
  out = ctl_alias_build_args (spec, argv, argc, error);
  g_strfreev (argv);
  return out;
}

static void
assert_alias_args (const gchar *verb, const gchar *line,
                   const gchar *expected)
{
  GError *error = NULL;
  gchar *got = alias_args_for (verb, line, &error);

  g_assert_no_error (error);
  g_assert_cmpstr (got, ==, expected);
  g_free (got);
}

/* Every row: a well-formed tool name, positionals that pair one to one
 * with distinct parameters, a D-Bus method to fall back to, and a verb
 * nobody else has. */
static void
test_alias_table (void)
{
  guint n = 0, k, j;
  const CtlAliasSpec *specs = ctl_cmd_alias_specs (&n);

  g_assert_cmpuint (n, >, 0);
  for (k = 0; k < n; k++)
    {
      gchar *problem = ctl_alias_spec_problem (&specs[k]);

      if (problem != NULL)
        g_error ("alias '%s': %s", specs[k].legacy.name, problem);
      g_assert_true (g_str_has_prefix (specs[k].legacy.iface,
                                       CTL_IFACE_ROOT));
      /* The generic interface is the path, never the fallback. */
      g_assert_cmpstr (specs[k].legacy.iface, !=, CTL_IFACE_TOOLS);
      g_assert_nonnull (specs[k].legacy.summary);
      for (j = 0; j < k; j++)
        g_assert_cmpstr (specs[j].legacy.name, !=, specs[k].legacy.name);
      /* With no words, an alias whose positionals are all optional
       * sends an object; one with a required positional refuses. */
      {
        GError *error = NULL;
        gchar *args = ctl_alias_build_args (&specs[k], NULL, 0, &error);

        if (args == NULL)
          g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
        else
          g_assert_true (g_str_has_prefix (args, "{"));
        g_clear_error (&error);
        g_free (args);
      }
    }

  /* What ctl_alias_spec_problem is for. */
  {
    CtlAliasSpec bad = specs[0];
    gchar *problem;

    bad.tool = "Calc.Eval";
    problem = ctl_alias_spec_problem (&bad);
    g_assert_nonnull (problem);
    g_free (problem);

    bad = *ctl_cmd_alias_find ("calc units");
    bad.params = "expression expression";
    problem = ctl_alias_spec_problem (&bad);
    g_assert_nonnull (strstr (problem, "two positionals"));
    g_free (problem);

    bad.params = "expression";
    problem = ctl_alias_spec_problem (&bad);
    g_assert_nonnull (strstr (problem, "parameter name"));
    g_free (problem);

    bad = *ctl_cmd_alias_find ("calc eval");
    bad.defaults = "expression=1";       /* required: never absent */
    problem = ctl_alias_spec_problem (&bad);
    g_assert_nonnull (strstr (problem, "optional positional"));
    g_free (problem);

    bad = *ctl_cmd_alias_find ("calc eval");
    bad.legacy.argspec = "A:expression"; /* an array has no scalar param */
    problem = ctl_alias_spec_problem (&bad);
    g_assert_nonnull (strstr (problem, "argspec letter"));
    g_free (problem);
  }
}

/* Positionals to parameters, for verbs from every group and of every
 * argument type. */
static void
test_alias_build_args (void)
{
  GError *error = NULL;
  gchar *args;

  /* strings; an optional one left out is no member */
  assert_alias_args ("calc eval", "2+2", "{\"expression\":\"2+2\"}");
  assert_alias_args ("calc units", "60 mph|m/s",
                     "{\"expression\":\"60 mph\",\"units\":\"m/s\"}");
  assert_alias_args ("calc units", "60 mph", "{\"expression\":\"60 mph\"}");
  assert_alias_args ("calc list", "", "{}");
  /* the old wire's "" for "not given" is no member either */
  assert_alias_args ("gsurf navigate", "https://gnu.org|",
                     "{\"url\":\"https://gnu.org\"}");
  /* a positional that starts with dashes is a positional */
  assert_alias_args ("calc eval", "--5", "{\"expression\":\"--5\"}");

  /* the verb's names are not always the tool's */
  assert_alias_args ("audio record", "2.5|/tmp/a.wav",
                     "{\"seconds\":2.5,\"output_path\":\"/tmp/a.wav\"}");
  assert_alias_args ("gsurf url", "*gsurf*", "{\"buffer\":\"*gsurf*\"}");
  assert_alias_args ("sb node", "n42", "{\"id\":\"n42\"}");

  /* numbers: doubles, integers, and the lenient conversion kept */
  assert_alias_args ("gsurf zoom", "1.5", "{\"level\":1.5}");
  assert_alias_args ("lrg move", "7|1|2.5|-3",
                     "{\"id\":7,\"x\":1.0,\"y\":2.5,\"z\":-3.0}");
  assert_alias_args ("edit goto-line", "notes.org|42",
                     "{\"buffer\":\"notes.org\",\"line\":42}");
  assert_alias_args ("gsurf click", "10|20|3|web",
                     "{\"x\":10.0,\"y\":20.0,\"button\":3,"
                     "\"buffer\":\"web\"}");
  assert_alias_args ("compositor screensaver-fps", "30", "{\"fps\":30}");
  assert_alias_args ("compositor screensaver-fps", "fast", "{\"fps\":0}");

  /* an optional 0 was how the wire said "left out" */
  assert_alias_args ("db query", "main|select 1|0",
                     "{\"connection\":\"main\",\"sql\":\"select 1\"}");
  assert_alias_args ("db query", "main|select 1|25",
                     "{\"connection\":\"main\",\"sql\":\"select 1\","
                     "\"max_rows\":25}");
  assert_alias_args ("gnuseye query", "aircraft",
                     "{\"kind\":\"aircraft\"}");

  /* booleans: required ones are always sent, optional false is not */
  assert_alias_args ("gsurf module", "adblock|true",
                     "{\"name\":\"adblock\",\"enabled\":true}");
  assert_alias_args ("gsurf module", "adblock|false",
                     "{\"name\":\"adblock\",\"enabled\":false}");
  assert_alias_args ("sb open", "true", "{\"three_d\":true}");
  assert_alias_args ("sb open", "", "{}");
  assert_alias_args ("sb expand", "|true", "{\"collapse\":true}");

  /* defaults: what the old method supplied and the tool does not */
  assert_alias_args ("lrg save", "", "{\"path\":\"level.rlevel\"}");
  assert_alias_args ("lrg save", "a.rlevel", "{\"path\":\"a.rlevel\"}");
  assert_alias_args ("logs show", "", "{\"lines\":50}");
  assert_alias_args ("logs show", "5", "{\"lines\":5}");

  /* no arguments at all, and extra words ignored as they always were */
  assert_alias_args ("compositor clients", "", "{}");
  assert_alias_args ("compositor clients", "stray", "{}");
  assert_alias_args ("brigade log", "t1|3",
                     "{\"id\":\"t1\",\"from_turn\":\"3\"}");

  /* a missing required positional: the old message, a usage error */
  args = alias_args_for ("calc eval", "", &error);
  g_assert_null (args);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_cmpstr (error->message, ==,
                   "missing required argument <expression>");
  g_clear_error (&error);

  args = alias_args_for ("gsurf module", "adblock", &error);
  g_assert_null (args);
  g_assert_error (error, CTL_ERROR, CTL_ERROR_USAGE);
  g_assert_cmpint (ctl_exit_code_for_error (error), ==, CTL_EXIT_USAGE);
  g_clear_error (&error);
}

static GError *
remote_error (const gchar *name)
{
  return g_dbus_error_new_for_dbus_error (name, "said the editor");
}

/* When a failed Tools.Call is retried through the old D-Bus method:
 * exactly when the tool cannot have started. */
static void
test_alias_fallback_decision (void)
{
  static const gchar *fallback[] = {
    /* an older cmacs, or a build without the registry */
    "org.freedesktop.DBus.Error.UnknownInterface",
    "org.freedesktop.DBus.Error.UnknownMethod",
    /* a registry that will not serve this call */
    "org.cmacs.Editor1.Error.NoSuchTool",
    "org.cmacs.Editor1.Error.NotOnSurface",
    "org.cmacs.Editor1.Error.BadArguments",
    NULL
  };
  static const gchar *fail[] = {
    /* the tool ran, or may have */
    "org.cmacs.Editor1.Error.ToolFailed",
    "org.cmacs.Editor1.Error.Timeout",
    "org.cmacs.Editor1.Error.ServiceStopped",
    "org.freedesktop.DBus.Error.NoReply",
    /* nobody to ask either way */
    "org.freedesktop.DBus.Error.ServiceUnknown",
    "org.freedesktop.DBus.Error.NameHasNoOwner",
    /* the old methods' own error name is not a refusal */
    "org.cmacs.Editor1.Error",
    NULL
  };
  GError *error;
  gint k;

  for (k = 0; fallback[k] != NULL; k++)
    {
      error = remote_error (fallback[k]);
      g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FALLBACK);
      g_error_free (error);

      /* The same refusal through the ssh proxy, which rebuilds the
       * error on this side as "NAME: message". */
      error = g_error_new (CTL_ERROR, CTL_ERROR_FAILED, "%s: said the "
                           "editor", fallback[k]);
      g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FALLBACK);
      g_error_free (error);
    }
  for (k = 0; fail[k] != NULL; k++)
    {
      error = remote_error (fail[k]);
      g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FAIL);
      g_error_free (error);

      error = g_error_new (CTL_ERROR, CTL_ERROR_FAILED, "%s: said the "
                           "editor", fail[k]);
      g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FAIL);
      g_error_free (error);
    }

  /* The ssh transport's own spelling of "no such interface". */
  error = g_error_new (CTL_ERROR, CTL_ERROR_UNSUPPORTED, "whatever");
  g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FALLBACK);
  g_error_free (error);

  /* A tool whose own message happens to start like an error name is
   * still a tool that ran. */
  error = g_error_new (CTL_ERROR, CTL_ERROR_FAILED,
                       "no such tool: calc_eval");
  g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FAIL);
  g_error_free (error);
  error = g_error_new (G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "timed out");
  g_assert_cmpint (ctl_alias_decide (error), ==, CTL_ALIAS_FAIL);
  g_error_free (error);
  g_assert_cmpint (ctl_alias_decide (NULL), ==, CTL_ALIAS_FAIL);
}

/* The tool's text back into what the old verb printed. */
static void
test_alias_output (void)
{
  CtlResult *result;
  gchar *plain;

  plain = ctl_alias_unprint ("\"Profiler started\"");
  g_assert_cmpstr (plain, ==, "Profiler started");
  g_free (plain);
  plain = ctl_alias_unprint ("\"say \\\"hi\\\" in C:\\\\tmp\\nnext\"");
  g_assert_cmpstr (plain, ==, "say \"hi\" in C:\\tmp\\nnext");
  g_free (plain);
  plain = ctl_alias_unprint ("\"two\nlines\"");
  g_assert_cmpstr (plain, ==, "two\nlines");
  g_free (plain);
  plain = ctl_alias_unprint ("\"\"");
  g_assert_cmpstr (plain, ==, "");
  g_free (plain);
  /* Not a printed string: left exactly as it came. */
  plain = ctl_alias_unprint ("plain text");
  g_assert_cmpstr (plain, ==, "plain text");
  g_free (plain);
  plain = ctl_alias_unprint ("\"a\" and \"b\"");
  g_assert_cmpstr (plain, ==, "\"a\" and \"b\"");
  g_free (plain);
  plain = ctl_alias_unprint ("\"ends in a backslash\\\"");
  g_assert_cmpstr (plain, ==, "\"ends in a backslash\\\"");
  g_free (plain);
  plain = ctl_alias_unprint ("\"");
  g_assert_cmpstr (plain, ==, "\"");
  g_free (plain);

  result = ctl_alias_format_result (CTL_ALIAS_TEXT, "{\"a\": 1}");
  g_assert_cmpint (ctl_result_get_kind (result), ==, CTL_RESULT_SCALAR);
  g_assert_cmpstr (ctl_result_get_scalar (result), ==, "{\"a\": 1}");
  ctl_result_unref (result);

  result = ctl_alias_format_result (CTL_ALIAS_JSON, "[{\"id\": 3}]");
  g_assert_cmpint (ctl_result_get_kind (result), ==, CTL_RESULT_DOCUMENT);
  ctl_result_unref (result);
  /* JSON that is not: the text, as the old CTL_REPLY_JSON printed it */
  result = ctl_alias_format_result (CTL_ALIAS_JSON, "nil");
  g_assert_cmpint (ctl_result_get_kind (result), ==, CTL_RESULT_SCALAR);
  g_assert_cmpstr (ctl_result_get_scalar (result), ==, "nil");
  ctl_result_unref (result);

  result = ctl_alias_format_result (CTL_ALIAS_PRINTED, "\"((a . 1))\"");
  g_assert_cmpstr (ctl_result_get_scalar (result), ==, "((a . 1))");
  ctl_result_unref (result);

  result = ctl_alias_format_result (CTL_ALIAS_PRINTED_LINES,
                                    "\"car\ncar-safe\n\"");
  g_assert_cmpint (ctl_result_get_kind (result), ==, CTL_RESULT_LIST);
  g_assert_cmpuint (json_array_get_length (ctl_result_get_rows (result)),
                    ==, 2);
  g_assert_cmpstr (json_array_get_string_element (
                     ctl_result_get_rows (result), 1), ==, "car-safe");
  ctl_result_unref (result);
  result = ctl_alias_format_result (CTL_ALIAS_PRINTED_LINES, "\"\"");
  g_assert_cmpuint (json_array_get_length (ctl_result_get_rows (result)),
                    ==, 0);
  ctl_result_unref (result);
}

/* An async tool's allowance, from the row: no List to learn it. */
static void
test_alias_timeout (void)
{
  const CtlAliasSpec *sync = ctl_cmd_alias_find ("calc eval");
  const CtlAliasSpec *slow = ctl_cmd_alias_find ("speech transcribe");

  g_assert_cmpint (sync->timeout_s, ==, 0);
  g_assert_cmpint (ctl_alias_timeout_ms (sync, 30000), ==, 30000);
  g_assert_cmpint (ctl_alias_timeout_ms (sync, -1), ==, -1);
  g_assert_cmpint (slow->timeout_s, >, 30);
  g_assert_cmpint (ctl_alias_timeout_ms (slow, 30000), ==,
                   slow->timeout_s * 1000 + 5000);
  /* --timeout longer than the tool's own is the user's to give */
  g_assert_cmpint (ctl_alias_timeout_ms (slow, 7200000), ==, 7200000);
  g_assert_cmpint (ctl_alias_timeout_ms (slow, -1), ==, -1);
}

/* Help comes from the tool's entry in the capability table, and says
 * what the verb is an alias of. */
static void
test_alias_help (void)
{
  static const gchar *table_json =
    "[{\"name\": \"calc_convert_units\", \"cli\": \"calc convert-units\","
    "  \"description\": \"LIVE DESCRIPTION of the tool.  More text.\","
    "  \"params\": ["
    "    {\"name\": \"expression\", \"type\": \"string\","
    "     \"description\": \"LIVE expression text\", \"required\": true},"
    "    {\"name\": \"units\", \"type\": \"string\","
    "     \"description\": \"LIVE units text\", \"required\": false}]}]";
  const CtlAliasSpec *spec = ctl_cmd_alias_find ("calc units");
  JsonParser *parser = json_parser_new ();
  JsonArray *tools;
  JsonObject *tool;
  gchar *help, *summary;

  g_assert_true (json_parser_load_from_data (parser, table_json, -1, NULL));
  tools = json_node_get_array (json_parser_get_root (parser));
  tool = ctl_tool_find_by_name (tools, spec->tool);
  g_assert_nonnull (tool);

  help = ctl_alias_help_string (spec, tool, "emacsctl");
  /* the old spelling, positionally */
  g_assert_nonnull (strstr (help, "emacsctl [OPTION…] calc units "
                            "<expression> [units]"));
  /* the text is the editor's, not this client's */
  g_assert_nonnull (strstr (help, "LIVE DESCRIPTION of the tool."));
  g_assert_nonnull (strstr (help, "LIVE expression text"));
  g_assert_nonnull (strstr (help, "LIVE units text"));
  g_assert_null (strstr (help, spec->legacy.summary));
  /* and it names the generic command it is the same as */
  g_assert_nonnull (strstr (help, "Same as: emacsctl tool calc "
                            "convert-units --expression expression "
                            "[--units units]"));
  g_free (help);

  summary = ctl_alias_summary (spec, tool);
  g_assert_cmpstr (summary, ==, "LIVE DESCRIPTION of the tool.  "
                   "[= tool calc convert-units]");
  g_free (summary);

  /* No editor to ask: the built-in summary, and the page says so.  The
   * target is then the spelling that needs no table. */
  help = ctl_alias_help_string (spec, NULL, "emacsctl");
  g_assert_nonnull (strstr (help, spec->legacy.summary));
  g_assert_nonnull (strstr (help, "Same as: emacsctl tool call "
                            "calc_convert_units"));
  g_assert_nonnull (strstr (help, "No running cmacs answered"));
  g_free (help);

  summary = ctl_alias_summary (spec, NULL);
  g_assert_true (g_str_has_prefix (summary, spec->legacy.summary));
  g_assert_true (g_str_has_suffix (summary,
                                   "[= tool call calc_convert_units]"));
  g_free (summary);

  /* A default the alias supplies is shown where the argument is. */
  help = ctl_alias_help_string (ctl_cmd_alias_find ("logs show"), NULL,
                                "emacsctl");
  g_assert_nonnull (strstr (help, "(default here: 50)"));
  g_free (help);

  g_object_unref (parser);
}

/* The registry as shipped: every alias row is a registered command
 * under its old name, and every command that is not an alias has a
 * recorded reason for being hand-written. */
static void
test_alias_registry (void)
{
  CtlCommandRegistry *registry = full_registry ();
  guint n = ctl_command_registry_get_n_commands (registry);
  guint n_specs = 0, n_kept = 0, n_aliases = 0, k, j;
  const CtlAliasSpec *specs = ctl_cmd_alias_specs (&n_specs);
  const CtlKeptVerb *kept = ctl_cmd_alias_kept (&n_kept);

  for (k = 0; k < n; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get_nth (registry, k);
      const gchar *name = ctl_command_get_name (cmd);
      const gchar *reason = ctl_cmd_alias_kept_reason (name);

      if (CTL_IS_ALIAS_COMMAND (cmd))
        {
          n_aliases++;
          g_assert_true (ctl_alias_command_get_spec (
                           CTL_ALIAS_COMMAND (cmd))
                         == ctl_cmd_alias_find (name));
          /* An alias with an exact "kept" line is a contradiction.  (A
           * group line -- "compositor *" -- may cover its neighbours.) */
          for (j = 0; j < n_kept; j++)
            g_assert_cmpstr (kept[j].pattern, !=, name);
          /* It takes its words as a method command did: no flags. */
          g_assert_null (ctl_command_get_option_entries (cmd));
          continue;
        }
      if (reason == NULL || *reason == '\0')
        g_error ("'%s' is hand-written and ctl-cmd-alias.c records no "
                 "reason: make it an alias, or add it to kept_verbs",
                 name);
    }

  /* Each row is registered exactly once, under the old name. */
  g_assert_cmpuint (n_aliases, ==, n_specs);
  for (k = 0; k < n_specs; k++)
    {
      CtlCommand *cmd = ctl_command_registry_get (registry,
                                                  specs[k].legacy.name);
      g_assert_nonnull (cmd);
      g_assert_true (CTL_IS_ALIAS_COMMAND (cmd));
    }

  /* No stale reasons: every line still matches a hand-written verb. */
  for (j = 0; j < n_kept; j++)
    {
      const gchar *pattern = kept[j].pattern;
      gsize len = strlen (pattern);
      gboolean group = len >= 2 && pattern[len - 1] == '*';
      gboolean matched = FALSE;

      g_assert_true (*kept[j].reason != '\0');
      for (k = 0; k < n && !matched; k++)
        {
          CtlCommand *cmd = ctl_command_registry_get_nth (registry, k);
          const gchar *name = ctl_command_get_name (cmd);

          if (CTL_IS_ALIAS_COMMAND (cmd))
            continue;
          matched = group
            ? (strncmp (name, pattern, len - 1) == 0)
            : (strcmp (name, pattern) == 0);
        }
      if (!matched)
        g_error ("kept_verbs has '%s', which no hand-written verb "
                 "matches any more", pattern);
    }

  /* A bare command is not covered by anybody's group line. */
  g_assert_null (ctl_cmd_alias_kept_reason ("no-such-verb"));
  g_assert_null (ctl_cmd_alias_kept_reason ("nosuchgroup verb"));
  g_assert_nonnull (ctl_cmd_alias_kept_reason ("compositor lock"));
  /* an exact line wins over its group's */
  g_assert_cmpstr (ctl_cmd_alias_kept_reason ("compositor spawn"), !=,
                   ctl_cmd_alias_kept_reason ("compositor lock"));

  g_object_unref (registry);
}

/* Shell completion is generated from the registry, so the aliased
 * verbs are still offered under their old names. */
static void
test_alias_completion (void)
{
  if (g_test_subprocess ())
    {
      CtlCommandRegistry *registry = full_registry ();
      CtlInvocation *inv = ctl_invocation_new ();
      gchar *words[] = { (gchar *) "calc", (gchar *) "", NULL };

      ctl_invocation_set_args (inv, words, 2);
      ctl_completion_complete (registry, inv);
      ctl_invocation_unref (inv);
      g_object_unref (registry);
      return;
    }
  g_test_trap_subprocess (NULL, 0, G_TEST_SUBPROCESS_DEFAULT);
  g_test_trap_assert_passed ();
  g_test_trap_assert_stdout ("*eval\n*");
  g_test_trap_assert_stdout ("*symbolic\n*");
  g_test_trap_assert_stdout ("*units\n*");
  g_test_trap_assert_stdout ("*describe\n*");
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/result/scalar", test_result_scalar);
  g_test_add_func ("/result/list-columns", test_result_list_columns);
  g_test_add_func ("/json-yaml/roundtrip", test_json_yaml_roundtrip);
  g_test_add_func ("/frame/roundtrip", test_frame_roundtrip);
  g_test_add_func ("/frame/large", test_frame_large_payload);
  g_test_add_func ("/frame/truncated", test_frame_truncated);
  g_test_add_func ("/config/boilerplate", test_config_boilerplate_parses);
  g_test_add_func ("/config/use-context",
                   test_config_use_context_preserves_comments);
  g_test_add_func ("/repl/is-complete", test_repl_is_complete);
  g_test_add_func ("/tool/lookup", test_tool_lookup);
  g_test_add_func ("/tool/build-args", test_tool_build_args);
  g_test_add_func ("/tool/structured-args", test_tool_structured_args);
  g_test_add_func ("/tool/help", test_tool_help);
  g_test_add_func ("/alias/table", test_alias_table);
  g_test_add_func ("/alias/build-args", test_alias_build_args);
  g_test_add_func ("/alias/fallback-decision", test_alias_fallback_decision);
  g_test_add_func ("/alias/output", test_alias_output);
  g_test_add_func ("/alias/timeout", test_alias_timeout);
  g_test_add_func ("/alias/help", test_alias_help);
  g_test_add_func ("/alias/registry", test_alias_registry);
  g_test_add_func ("/alias/completion", test_alias_completion);

  return g_test_run ();
}
