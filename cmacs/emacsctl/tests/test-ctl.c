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
  g_test_add_func ("/tool/help", test_tool_help);

  return g_test_run ();
}
