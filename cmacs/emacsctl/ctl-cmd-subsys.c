/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-subsys.c --- cmacs subsystem command groups (the Phase 6
 * MCP-parity interfaces): crispy, bacon, eshell, ai, gsurf, gnuseye,
 * podomation, video, audio, speech, libregnum, calc, db.
 *
 * If the target cmacs was built without a subsystem its interface is
 * absent and the call maps to exit code 3 with a clear message ---
 * the CLI does not need to know the server's configure flags.
 *
 * A CTL_ALIAS_ROW ("verb") is a verb whose capability is a registry
 * tool; its row is in ctl-cmd-alias.c, and it runs through the same
 * Tools.Call as `emacsctl tool'. */

#include "ctl-cmd-alias.h"
#include "ctl-command-registry.h"
#include "ctl-ifaces.h"

#include <stdio.h>
#include <string.h>

void ctl_cmd_subsys_register (CtlCommandRegistry *registry);

static const CtlMethodSpec subsys_specs[] = {
  /* crispy */
  { "crispy eval", "Run inline crispy C, printing captured stdout",
    CTL_IFACE_CRISPY, "EvalString", "s:code", CTL_REPLY_STRING },
  { "crispy run", "Run inline crispy C, printing the exit code",
    CTL_IFACE_CRISPY, "Eval", "s:code", CTL_REPLY_INT },

  /* bacon */
  { "bacon eval", "Run a bacon shell command line",
    CTL_IFACE_BACON, "Eval", "s:command", CTL_REPLY_EXIT_OUTPUT },
  { "bacon eval-c", "Run a C block through bacon/crispy",
    CTL_IFACE_BACON, "EvalC", "s:code", CTL_REPLY_EXIT_OUTPUT },
  { "bacon complete", "Bacon shell completion candidates",
    CTL_IFACE_BACON, "Complete", "s:prefix", CTL_REPLY_STRLIST },

  /* eshell */
  { "eshell eval", "Run an eshell command line",
    CTL_IFACE_ESHELL, "Eval", "s:command", CTL_REPLY_STRING },

  /* ai --- prompt/models/chat are flag-driven CtlSimpleCommands
   * below; only the no-argument verb stays a table row. */
  CTL_ALIAS_ROW ("ai providers"),

  /* brigade --- subagent control.  Same verbs as the agent_* tools an
   * agent gets over MCP, so a shell script and a model drive the queue
   * through the same path. */
  { "brigade spawn", "Hand a task to an agent; prints the task id",
    CTL_IFACE_BRIGADE, "Spawn", "s:task s?:agent s?:title s?:model",
    CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("brigade status"),
  CTL_ALIAS_ROW ("brigade result"),
  { "brigade cancel", "Stop a running task",
    CTL_IFACE_BRIGADE, "Cancel", "s:id", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("brigade list"),
  { "brigade agents", "Agent definitions available to spawn",
    CTL_IFACE_BRIGADE, "Agents", NULL, CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("brigade providers"),
  CTL_ALIAS_ROW ("brigade models"),
  /* The mailbox: a task you can go on talking to.  `send' works whether
   * the task is running (delivered when its turn ends) or already
   * finished (it starts again on the same session). */
  { "brigade send", "Queue a message for a task; wakes a parked agent",
    CTL_IFACE_BRIGADE, "Send", "s:id s:message", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("brigade inbox"),
  { "brigade drop", "Remove a queued message; omit INDEX to clear the queue",
    CTL_IFACE_BRIGADE, "Drop", "s:id s?:index", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("brigade log"),
  { "brigade close", "End a conversation and release its session",
    CTL_IFACE_BRIGADE, "Close", "s:id", CTL_REPLY_STRING },

  /* gsurf */
  CTL_ALIAS_ROW ("gsurf open"),
  CTL_ALIAS_ROW ("gsurf navigate"),
  CTL_ALIAS_ROW ("gsurf back"),
  CTL_ALIAS_ROW ("gsurf forward"),
  CTL_ALIAS_ROW ("gsurf reload"),
  CTL_ALIAS_ROW ("gsurf stop"),
  CTL_ALIAS_ROW ("gsurf url"),
  CTL_ALIAS_ROW ("gsurf title"),
  CTL_ALIAS_ROW ("gsurf current"),
  CTL_ALIAS_ROW ("gsurf list"),
  CTL_ALIAS_ROW ("gsurf modules"),
  { "gsurf js", "Evaluate JavaScript in the page",
    CTL_IFACE_GSURF, "EvalJs", "s:script s?:buffer",
    CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("gsurf zoom"),
  CTL_ALIAS_ROW ("gsurf lite"),
  CTL_ALIAS_ROW ("gsurf text"),
  CTL_ALIAS_ROW ("gsurf downloads"),
  CTL_ALIAS_ROW ("gsurf download-cancel"),
  { "gsurf snapshot", "Screenshot the page to a PNG file",
    CTL_IFACE_GSURF, "Snapshot", "s:file b?:full_page s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf pdf", "Print the page to a PDF file",
    CTL_IFACE_GSURF, "PrintPdf", "s:file s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf permission", "Set a permission policy "
    "(origin type allow|deny|ask)",
    CTL_IFACE_GSURF, "PermissionPolicy", "s:origin s:type s:verdict",
    CTL_REPLY_STRING },
  /* gsurf 0.5 control surface: trusted page input, cookies, modules,
   actions and containers. */
  CTL_ALIAS_ROW ("gsurf click"),
  { "gsurf type", "Type text into the focused page element",
    CTL_IFACE_GSURF, "TypeText", "s:text s?:buffer", CTL_REPLY_STRING },
  { "gsurf key", "Press a key in the page "
    "(e.g. Enter, Tab, ArrowDown; modifiers like ctrl+shift)",
    CTL_IFACE_GSURF, "PressKey", "s:key s?:modifiers s?:buffer",
    CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("gsurf click-element"),
  { "gsurf cookie", "Add a cookie to the view's session",
    CTL_IFACE_GSURF, "SetCookie",
    "s:name s:value s:domain s?:path b?:secure b?:http_only x?:expires "
    "s?:buffer",
    CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("gsurf module"),
  CTL_ALIAS_ROW ("gsurf action"),
  CTL_ALIAS_ROW ("gsurf actions"),
  CTL_ALIAS_ROW ("gsurf containers"),

  /* gnuseye */
  CTL_ALIAS_ROW ("gnuseye open"),
  CTL_ALIAS_ROW ("gnuseye brief"),
  CTL_ALIAS_ROW ("gnuseye layers"),
  CTL_ALIAS_ROW ("gnuseye toggle"),
  CTL_ALIAS_ROW ("gnuseye fly-to"),
  CTL_ALIAS_ROW ("gnuseye refresh"),
  CTL_ALIAS_ROW ("gnuseye query"),
  CTL_ALIAS_ROW ("gnuseye geofence"),
  CTL_ALIAS_ROW ("gnuseye cii"),

  /* podomation */
  { "pod status", "Engine status (start|stop|status)",
    CTL_IFACE_PODOMATION, "Control", "s:action", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("pod pods"),
  CTL_ALIAS_ROW ("pod modules"),
  CTL_ALIAS_ROW ("pod stats"),
  { "pod emit", "Emit an event (with KEY=VALUE payload)",
    CTL_IFACE_PODOMATION, "EmitEvent", "s:event D:data",
    CTL_REPLY_STRING },
  { "pod eval", "Evaluate podomation DSL source",
    CTL_IFACE_PODOMATION, "EvalDsl", "s:dsl", CTL_REPLY_STRING },
  { "pod repl-eval", "Evaluate one line in the persistent DSL REPL",
    CTL_IFACE_PODOMATION, "ReplEval", "s:line", CTL_REPLY_STRING },
  { "pod load", "Load a .pod DSL file",
    CTL_IFACE_PODOMATION, "LoadFile", "s:file", CTL_REPLY_STRING },
  { "pod reload", "Hot-reload the engine",
    CTL_IFACE_PODOMATION, "Reload", NULL, CTL_REPLY_STRING },
  { "pod set-context", "Set engine context (KEY=VALUE...)",
    CTL_IFACE_PODOMATION, "SetContext", "D:context",
    CTL_REPLY_STRING },

  /* video */
  CTL_ALIAS_ROW ("video list"),
  { "video snapshot", "Save a video frame to a PNG file",
    CTL_IFACE_VIDEO, "Snapshot", "x:handle s:file",
    CTL_REPLY_STRING },

  /* audio */
  CTL_ALIAS_ROW ("audio record"),

  /* speech: through cmacs-speech (whisper.cpp / sherpa-onnx / piper) */
  CTL_ALIAS_ROW ("speech transcribe"),
  { "speech who", "Who spoke when: a speaker-labelled transcript",
    CTL_IFACE_SPEECH, "WhoSpoke", "s:audio_path", CTL_REPLY_STRING },
  { "speech say", "Speak text; FILE writes a WAV instead",
    CTL_IFACE_SPEECH, "Synthesize", "s:text s?:file",
    CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("speech components"),
  CTL_ALIAS_ROW ("speech set"),
  { "speech models", "Installed and downloadable speech models",
    CTL_IFACE_SPEECH, "Models", "s?:component", CTL_REPLY_STRING },
  CTL_ALIAS_ROW ("speech whisper-models"),
  CTL_ALIAS_ROW ("speech voices"),

  /* lrg (libregnum editor) */
  CTL_ALIAS_ROW ("lrg open"),
  CTL_ALIAS_ROW ("lrg play"),
  CTL_ALIAS_ROW ("lrg stop"),
  CTL_ALIAS_ROW ("lrg save"),
  CTL_ALIAS_ROW ("lrg tree"),
  CTL_ALIAS_ROW ("lrg select"),
  CTL_ALIAS_ROW ("lrg move"),
  CTL_ALIAS_ROW ("lrg delete"),
  CTL_ALIAS_ROW ("lrg add-primitive"),
  CTL_ALIAS_ROW ("lrg add-visual"),

  /* calc --- `emacsctl eval -l calc EXPR' and `emacsctl repl -l calc'
   * cover plain evaluation too (both ride the same Calc.Eval method). */
  CTL_ALIAS_ROW ("calc eval"),
  CTL_ALIAS_ROW ("calc symbolic"),
  CTL_ALIAS_ROW ("calc units"),
  CTL_ALIAS_ROW ("calc list"),
  CTL_ALIAS_ROW ("calc describe"),

  /* db (database explorer) --- CONNECTION is always the name of a
   * connection someone saved, never a URL, so a shell one-liner cannot
   * reach a database the target cmacs was not already given.  The
   * structured verbs reply with JSON, which -o table renders as rows
   * and -o json/yaml passes through. */
  CTL_ALIAS_ROW ("db connections"),
  CTL_ALIAS_ROW ("db connect"),
  CTL_ALIAS_ROW ("db disconnect"),
  CTL_ALIAS_ROW ("db query"),
  { "db execute", "Run a writing statement; prints the rows affected",
    CTL_IFACE_DBEXPLORER, "Execute", "s:connection s:sql",
    CTL_REPLY_JSON },
  CTL_ALIAS_ROW ("db tables"),
  CTL_ALIAS_ROW ("db columns"),
  { "db export", "Write a query's whole result to a file",
    CTL_IFACE_DBEXPLORER, "Export",
    "s:connection s:sql s:format s:path", CTL_REPLY_STRING },

  /* lql --- LQL linked into the target cmacs: files, git, journal,
   * sql, and the editor's own state.  Read-only by construction. */
  { "lql query", "Run an LQL query; prints the rows as a table",
    CTL_IFACE_LQL, "Query", "s:query i?:max_rows", CTL_REPLY_STRING },
  { "lql json", "Run an LQL query; prints {columns, rows, total}",
    CTL_IFACE_LQL, "QueryJson", "s:query i?:max_rows", CTL_REPLY_JSON },
  { "lql explain", "Show the plan for an LQL query",
    CTL_IFACE_LQL, "Explain", "s:query", CTL_REPLY_STRING },
  { "lql sources", "List every LQL source",
    CTL_IFACE_LQL, "Sources", NULL, CTL_REPLY_STRING },

  /* instance/log surface */
  CTL_ALIAS_ROW ("logs show"),

  { NULL, NULL, NULL, NULL, NULL, 0 }
};

/* ── ai group ───────────────────────────────────────────────────────
 *
 * The ai verbs take their provider / model / system prompt as flags
 * (kubectl-style) instead of fragile positional slots, and `prompt'
 * composes its text from positionals, stdin, and -f/--file
 * attachments:
 *
 *   emacsctl ai prompt -p ollama -m llama3.2 'why is the sky blue?'
 *   git diff | emacsctl ai prompt -s 'Review this diff'
 *   emacsctl ai prompt -f main.c -f util.c 'find the bug'
 *   emacsctl ai models -p claude
 *   emacsctl ai chat -p claude -m claude-opus-4-8 'hello'
 */

static gchar  *ai_opt_provider = NULL;
static gchar  *ai_opt_model = NULL;
static gchar  *ai_opt_system = NULL;
static gchar **ai_opt_files = NULL;
static gboolean ai_opt_tools = FALSE;

#define AI_PROVIDER_ENTRY \
  { "provider", 'p', 0, G_OPTION_ARG_STRING, &ai_opt_provider, \
    "AI provider (claude / openai / gemini / grok / ollama / " \
    "claude-code / opencode / claude-tmux / grok-build / " \
    "antigravity / cursor; " \
    "default: configured)", \
    "NAME" }
#define AI_MODEL_ENTRY \
  { "model", 'm', 0, G_OPTION_ARG_STRING, &ai_opt_model, \
    "Model name overriding the provider's default " \
    "(see 'ai models')", "MODEL" }

static gchar *ai_opt_aspect = NULL;
static gchar **ai_opt_refs = NULL;
static gchar *ai_opt_buffer = NULL;

static const GOptionEntry ai_prompt_entries[] = {
  AI_PROVIDER_ENTRY,
  AI_MODEL_ENTRY,
  { "system", 's', 0, G_OPTION_ARG_STRING, &ai_opt_system,
    "System prompt", "TEXT" },
  { "file", 'f', 0, G_OPTION_ARG_FILENAME_ARRAY, &ai_opt_files,
    "Append FILE's contents to the prompt (repeatable)", "FILE" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static const GOptionEntry ai_call_entries[] = {
  AI_PROVIDER_ENTRY,
  AI_MODEL_ENTRY,
  { "system", 's', 0, G_OPTION_ARG_STRING, &ai_opt_system,
    "System prompt", "TEXT" },
  { "file", 'f', 0, G_OPTION_ARG_FILENAME_ARRAY, &ai_opt_files,
    "Append FILE's contents to the prompt (repeatable)", "FILE" },
  { "tools", 't', 0, G_OPTION_ARG_NONE, &ai_opt_tools,
    "Give the model the built-in agent tools (bash/read/write/edit/... "
    "-- runs a multi-turn loop; blocks the target's main thread)", NULL },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static const GOptionEntry ai_models_entries[] = {
  AI_PROVIDER_ENTRY,
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static const GOptionEntry ai_image_entries[] = {
  AI_PROVIDER_ENTRY,
  AI_MODEL_ENTRY,
  { "aspect", 'a', 0, G_OPTION_ARG_STRING, &ai_opt_aspect,
    "Aspect ratio, e.g. 16:9", "RATIO" },
  { "ref", 'r', 0, G_OPTION_ARG_STRING_ARRAY, &ai_opt_refs,
    "Reference image as PATH or PATH::ROLE (repeatable, for "
    "multi-image conditioning)", "PATH" },
  { "buffer", 'b', 0, G_OPTION_ARG_STRING, &ai_opt_buffer,
    "Insert into this buffer (default: the current one)", "NAME" },
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

static const GOptionEntry ai_chat_entries[] = {
  AI_PROVIDER_ENTRY,
  AI_MODEL_ENTRY,
  { NULL, 0, 0, 0, NULL, NULL, NULL }
};

/* Read all of stdin (for `ai prompt' with no argument).
 * Caller g_frees. */
static gchar *
ai_read_stdin (void)
{
  GString *buf = g_string_new (NULL);
  gchar chunk[4096];
  gsize got;

  while ((got = fread (chunk, 1, sizeof chunk, stdin)) > 0)
    g_string_append_len (buf, chunk, got);
  return g_string_free (buf, FALSE);
}

/* Join the command's positionals with single spaces; NULL when there
 * are none.  Caller g_frees. */
static gchar *
ai_join_args (CtlInvocation *inv)
{
  gint argc = 0;
  gchar **argv = ctl_invocation_get_args (inv, &argc);

  if (argc == 0)
    return NULL;
  return g_strjoinv (" ", argv);
}

/* Call an Ai method and return its (s) reply.  Caller g_frees. */
static gchar *
ai_call (CtlInvocation *inv, const gchar *method, GVariant *params,
         GError **error)
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
  reply = ctl_transport_call (transport, CTL_IFACE_AI, method, params,
                              ctl_invocation_get_timeout_ms (inv),
                              error);
  if (reply == NULL)
    return NULL;
  g_variant_get (reply, "(s)", &out);
  g_variant_unref (reply);
  return out;
}

static gint
cmd_ai_call (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *provider =
    ai_opt_provider != NULL ? ai_opt_provider : "";
  const gchar *system =
    ai_opt_system != NULL ? ai_opt_system : "";
  const gchar *model =
    ai_opt_model != NULL ? ai_opt_model : "";
  gchar *prompt;
  GString *text;
  gchar *response;
  CtlResult *result;
  gboolean ok;
  gint k;

  (void) self;

  /* Prompt text: positionals, else stdin (same rules as `ai prompt'). */
  prompt = ai_join_args (inv);
  if (prompt == NULL && ai_opt_files == NULL)
    {
      prompt = ai_read_stdin ();
      if (*prompt == '\0')
        {
          g_free (prompt);
          prompt = NULL;
        }
    }
  if (prompt == NULL && ai_opt_files == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "no prompt given and stdin was empty "
                   "(see 'ai call --help')");
      return CTL_EXIT_USAGE;
    }

  text = g_string_new (prompt != NULL ? prompt : "");
  g_free (prompt);

  for (k = 0; ai_opt_files != NULL && ai_opt_files[k] != NULL; k++)
    {
      gchar *contents = NULL;
      gsize len = 0;

      if (!g_file_get_contents (ai_opt_files[k], &contents, &len, error))
        {
          g_string_free (text, TRUE);
          return CTL_EXIT_ERROR;
        }
      if (text->len > 0)
        g_string_append (text, "\n\n");
      g_string_append_printf (text, "--- FILE: %s ---\n",
                              ai_opt_files[k]);
      g_string_append_len (text, contents, (gssize) len);
      g_free (contents);
    }

  response = ai_call (inv, "Call",
                      g_variant_new ("(ssssb)", text->str, provider,
                                     system, model, ai_opt_tools),
                      error);
  g_string_free (text, TRUE);
  if (response == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  result = ctl_result_new_scalar (response);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_free (response);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_ai_prompt (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *provider =
    ai_opt_provider != NULL ? ai_opt_provider : "";
  const gchar *system =
    ai_opt_system != NULL ? ai_opt_system : "";
  const gchar *model =
    ai_opt_model != NULL ? ai_opt_model : "";
  gchar *prompt;
  GString *text;
  gchar *response;
  CtlResult *result;
  gboolean ok;
  gint k;

  (void) self;

  /* Prompt text: positionals, else stdin --- but only when no -f
   * attachments could stand alone (an interactive tty with -f given
   * should not block on stdin). */
  prompt = ai_join_args (inv);
  if (prompt == NULL && ai_opt_files == NULL)
    {
      prompt = ai_read_stdin ();
      if (*prompt == '\0')
        {
          g_free (prompt);
          prompt = NULL;
        }
    }
  if (prompt == NULL && ai_opt_files == NULL)
    {
      g_set_error (error, CTL_ERROR, CTL_ERROR_USAGE,
                   "no prompt given and stdin was empty "
                   "(see 'ai prompt --help')");
      return CTL_EXIT_USAGE;
    }

  text = g_string_new (prompt != NULL ? prompt : "");
  g_free (prompt);

  /* Append -f/--file attachments with filename headers, so the model
   * can tell the sources apart. */
  for (k = 0; ai_opt_files != NULL && ai_opt_files[k] != NULL; k++)
    {
      gchar *contents = NULL;
      gsize len = 0;

      if (!g_file_get_contents (ai_opt_files[k], &contents, &len,
                                error))
        {
          g_string_free (text, TRUE);
          return CTL_EXIT_ERROR;
        }
      if (text->len > 0)
        g_string_append (text, "\n\n");
      g_string_append_printf (text, "--- FILE: %s ---\n",
                              ai_opt_files[k]);
      g_string_append_len (text, contents, (gssize) len);
      g_free (contents);
    }

  response = ai_call (inv, "Prompt",
                      g_variant_new ("(ssss)", text->str, provider,
                                     system, model),
                      error);
  g_string_free (text, TRUE);
  if (response == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  result = ctl_result_new_scalar (response);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_free (response);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_ai_models (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *provider =
    ai_opt_provider != NULL ? ai_opt_provider : "";
  gchar *json;
  JsonParser *parser;
  CtlResult *result;
  gboolean ok;

  (void) self;

  json = ai_call (inv, "ListModels", g_variant_new ("(s)", provider),
                  error);
  if (json == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  /* Reply is a JSON object provider -> [models].  Tables flatten it
   * to one provider/model row per model; -o json/yaml emit the
   * object as-is; -o raw prints bare model names, one per line. */
  parser = json_parser_new ();
  if (!json_parser_load_from_data (parser, json, -1, NULL))
    {
      result = ctl_result_new_scalar (json);
    }
  else if (g_strcmp0 (ctl_invocation_get_output (inv), "json") == 0
           || g_strcmp0 (ctl_invocation_get_output (inv), "yaml") == 0)
    {
      result = ctl_result_new_document (
        json_node_copy (json_parser_get_root (parser)));
    }
  else if (g_strcmp0 (ctl_invocation_get_output (inv), "raw") == 0)
    {
      JsonObject *by_provider =
        json_node_get_object (json_parser_get_root (parser));
      JsonObjectIter iter;
      const gchar *prov_name;
      JsonNode *models_node;
      JsonArray *rows = json_array_new ();

      json_object_iter_init_ordered (&iter, by_provider);
      while (json_object_iter_next_ordered (&iter, &prov_name,
                                            &models_node))
        {
          JsonArray *models = json_node_get_array (models_node);
          guint n = json_array_get_length (models);
          guint j;

          for (j = 0; j < n; j++)
            json_array_add_string_element (
              rows, json_array_get_string_element (models, j));
        }
      result = ctl_result_new_list (rows);
    }
  else
    {
      JsonObject *by_provider =
        json_node_get_object (json_parser_get_root (parser));
      JsonObjectIter iter;
      const gchar *prov_name;
      JsonNode *models_node;
      JsonArray *rows = json_array_new ();

      json_object_iter_init_ordered (&iter, by_provider);
      while (json_object_iter_next_ordered (&iter, &prov_name,
                                            &models_node))
        {
          JsonArray *models = json_node_get_array (models_node);
          guint n = json_array_get_length (models);
          guint j;

          for (j = 0; j < n; j++)
            {
              JsonObject *row = json_object_new ();
              json_object_set_string_member (row, "provider",
                                             prov_name);
              json_object_set_string_member (
                row, "model",
                json_array_get_string_element (models, j));
              json_array_add_object_element (rows, row);
            }
        }
      result = ctl_result_new_list (rows);
      ctl_result_add_column (result, "Provider", "provider");
      ctl_result_add_column (result, "Model", "model");
    }
  g_object_unref (parser);
  g_free (json);

  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_ai_chat (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *provider =
    ai_opt_provider != NULL ? ai_opt_provider : "";
  const gchar *model =
    ai_opt_model != NULL ? ai_opt_model : "";
  gchar *prompt = ai_join_args (inv);
  gchar *buffer;
  CtlResult *result;
  gboolean ok;

  (void) self;

  buffer = ai_call (inv, "OpenChat",
                    g_variant_new ("(sss)", provider,
                                   prompt != NULL ? prompt : "",
                                   model),
                    error);
  g_free (prompt);
  if (buffer == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  result = ctl_result_new_scalar (buffer);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_free (buffer);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

static gint
cmd_ai_generate_image (CtlCommand *self, CtlInvocation *inv, GError **error)
{
  const gchar *provider = ai_opt_provider != NULL ? ai_opt_provider : "";
  const gchar *model = ai_opt_model != NULL ? ai_opt_model : "";
  const gchar *aspect = ai_opt_aspect != NULL ? ai_opt_aspect : "";
  const gchar *buffer = ai_opt_buffer != NULL ? ai_opt_buffer : "";
  gchar *prompt = ai_join_args (inv);
  gchar *refs;
  gchar *out;
  CtlResult *result;
  gboolean ok;

  (void) self;

  if (prompt == NULL || *prompt == '\0')
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                   "a prompt is required");
      g_free (prompt);
      return CTL_EXIT_ERROR;
    }

  /* The wire format is one comma-separated string, matching the MCP
   * tool -- the bridge's schema translator cannot carry a list. */
  refs = (ai_opt_refs != NULL)
    ? g_strjoinv (",", ai_opt_refs)
    : g_strdup ("");

  out = ai_call (inv, "GenerateImage",
                 g_variant_new ("(ssssss)", prompt, provider, model,
                                aspect, refs, buffer),
                 error);
  g_free (prompt);
  g_free (refs);
  if (out == NULL)
    return ctl_exit_code_for_error (error != NULL ? *error : NULL);

  result = ctl_result_new_scalar (out);
  ok = ctl_invocation_emit (inv, result, error);
  ctl_result_unref (result);
  g_free (out);
  return ok ? CTL_EXIT_OK : CTL_EXIT_ERROR;
}

void
ctl_cmd_subsys_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; subsys_specs[k].name != NULL; k++)
    ctl_command_registry_add (
      registry, ctl_cmd_alias_command_for_row (&subsys_specs[k]));

  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "ai prompt", "One-shot AI prompt (blocking)",
      "[PROMPT...]", ai_prompt_entries, cmd_ai_prompt));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "ai call", "One-shot AI call, optionally with agent tools (-t)",
      "[PROMPT...]", ai_call_entries, cmd_ai_call));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "ai models", "List the models each AI provider offers",
      NULL, ai_models_entries, cmd_ai_models));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "ai chat", "Open a chat buffer (optionally sending a prompt)",
      "[PROMPT...]", ai_chat_entries, cmd_ai_chat));
  ctl_command_registry_add (registry,
    ctl_simple_command_new_with_options (
      "ai generate-image",
      "Generate an image and insert it into a buffer (blocking)",
      "[PROMPT...]", ai_image_entries, cmd_ai_generate_image));
}
