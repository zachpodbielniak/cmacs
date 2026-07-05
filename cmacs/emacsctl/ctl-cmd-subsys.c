/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* ctl-cmd-subsys.c --- cmacs subsystem command groups (the Phase 6
 * MCP-parity interfaces): crispy, bacon, eshell, ai, gsurf, gnuseye,
 * podomation, video, audio, speech, libregnum.
 *
 * If the target cmacs was built without a subsystem its interface is
 * absent and the call maps to exit code 3 with a clear message ---
 * the CLI does not need to know the server's configure flags. */

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
  { "ai providers", "List configured AI providers",
    CTL_IFACE_AI, "ListProviders", NULL, CTL_REPLY_STRING },

  /* gsurf */
  { "gsurf open", "Open a URL in a new gsurf buffer",
    CTL_IFACE_GSURF, "Open", "s:url", CTL_REPLY_STRING },
  { "gsurf navigate", "Navigate a gsurf buffer",
    CTL_IFACE_GSURF, "Navigate", "s:url s?:buffer", CTL_REPLY_STRING },
  { "gsurf back", "History back",
    CTL_IFACE_GSURF, "Back", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf forward", "History forward",
    CTL_IFACE_GSURF, "Forward", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf reload", "Reload the page",
    CTL_IFACE_GSURF, "Reload", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf stop", "Stop loading",
    CTL_IFACE_GSURF, "Stop", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf url", "Current page URL",
    CTL_IFACE_GSURF, "GetUri", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf title", "Current page title",
    CTL_IFACE_GSURF, "GetTitle", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf current", "Most recent gsurf buffer info",
    CTL_IFACE_GSURF, "Current", NULL, CTL_REPLY_STRING },
  { "gsurf list", "List gsurf buffers",
    CTL_IFACE_GSURF, "List", NULL, CTL_REPLY_STRING },
  { "gsurf modules", "List loaded gsurf modules",
    CTL_IFACE_GSURF, "ModulesList", NULL, CTL_REPLY_STRING },
  { "gsurf js", "Evaluate JavaScript in the page",
    CTL_IFACE_GSURF, "EvalJs", "s:script s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf zoom", "Set the zoom level",
    CTL_IFACE_GSURF, "SetZoom", "d:level s?:buffer",
    CTL_REPLY_STRING },
  { "gsurf lite", "Render a page into a text buffer (gsurf-lite)",
    CTL_IFACE_GSURF, "LiteOpen", "s:url", CTL_REPLY_STRING },
  { "gsurf text", "Extract the page's text content",
    CTL_IFACE_GSURF, "ExtractText", "s?:buffer", CTL_REPLY_STRING },
  { "gsurf downloads", "List downloads",
    CTL_IFACE_GSURF, "DownloadList", NULL, CTL_REPLY_STRING },
  { "gsurf download-cancel", "Cancel a download by id",
    CTL_IFACE_GSURF, "DownloadCancel", "x:id", CTL_REPLY_STRING },
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

  /* gnuseye */
  { "gnuseye open", "Open the GNU's Eye globe",
    CTL_IFACE_GNUSEYE, "Open", NULL, CTL_REPLY_STRING },
  { "gnuseye brief", "Entity index summary",
    CTL_IFACE_GNUSEYE, "Brief", NULL, CTL_REPLY_STRING },
  { "gnuseye layers", "List data layers",
    CTL_IFACE_GNUSEYE, "ListLayers", NULL, CTL_REPLY_STRING },
  { "gnuseye toggle", "Toggle a data layer",
    CTL_IFACE_GNUSEYE, "ToggleLayer", "s:name", CTL_REPLY_STRING },
  { "gnuseye fly-to", "Fly the camera to lat/lon",
    CTL_IFACE_GNUSEYE, "FlyTo", "d:lat d:lon d?:range",
    CTL_REPLY_STRING },
  { "gnuseye refresh", "Refresh all layers",
    CTL_IFACE_GNUSEYE, "Refresh", NULL, CTL_REPLY_STRING },
  { "gnuseye query", "Query indexed entities "
    "(kind west east south north limit)",
    CTL_IFACE_GNUSEYE, "QueryEntities",
    "s?:kind d?:west d?:east d?:south d?:north i?:limit",
    CTL_REPLY_JSON },
  { "gnuseye geofence", "Add a circular geofence",
    CTL_IFACE_GNUSEYE, "AddGeofence", "s:name d:lat d:lon d:radius_km",
    CTL_REPLY_STRING },
  { "gnuseye cii", "Country instability index (top 15)",
    CTL_IFACE_GNUSEYE, "Cii", NULL, CTL_REPLY_JSON },

  /* podomation */
  { "pod status", "Engine status (start|stop|status)",
    CTL_IFACE_PODOMATION, "Control", "s:action", CTL_REPLY_STRING },
  { "pod pods", "List active pods",
    CTL_IFACE_PODOMATION, "ListPods", NULL, CTL_REPLY_STRING },
  { "pod modules", "List loaded modules",
    CTL_IFACE_PODOMATION, "ListModules", NULL, CTL_REPLY_STRING },
  { "pod stats", "Engine statistics",
    CTL_IFACE_PODOMATION, "Stats", NULL, CTL_REPLY_STRING },
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
  { "video list", "List live video stream handles",
    CTL_IFACE_VIDEO, "List", NULL, CTL_REPLY_STRING },
  { "video snapshot", "Save a video frame to a PNG file",
    CTL_IFACE_VIDEO, "Snapshot", "x:handle s:file",
    CTL_REPLY_STRING },

  /* audio */
  { "audio record", "Record microphone audio to a WAV file",
    CTL_IFACE_AUDIO, "Record", "d:seconds s?:file",
    CTL_REPLY_STRING },

  /* speech */
  { "speech transcribe", "Transcribe a WAV file (whisper)",
    CTL_IFACE_SPEECH, "Transcribe", "s:audio_path s?:language",
    CTL_REPLY_STRING },
  { "speech models", "List whisper models",
    CTL_IFACE_SPEECH, "ListWhisperModels", NULL, CTL_REPLY_STRING },
  { "speech say", "Speak text (piper); FILE saves PCM instead",
    CTL_IFACE_SPEECH, "Synthesize", "s:text s?:file",
    CTL_REPLY_STRING },
  { "speech voices", "List piper voices",
    CTL_IFACE_SPEECH, "ListVoices", NULL, CTL_REPLY_STRING },

  /* lrg (libregnum editor) */
  { "lrg open", "Open the libregnum level editor",
    CTL_IFACE_LRG, "Open", "s?:path", CTL_REPLY_STRING },
  { "lrg play", "Enter play mode",
    CTL_IFACE_LRG, "Play", NULL, CTL_REPLY_STRING },
  { "lrg stop", "Stop play mode",
    CTL_IFACE_LRG, "Stop", NULL, CTL_REPLY_STRING },
  { "lrg save", "Save the level",
    CTL_IFACE_LRG, "Save", "s?:path", CTL_REPLY_STRING },
  { "lrg tree", "Object tree",
    CTL_IFACE_LRG, "ObjectTree", NULL, CTL_REPLY_STRING },
  { "lrg select", "Select a node by id",
    CTL_IFACE_LRG, "Select", "x:id", CTL_REPLY_STRING },
  { "lrg move", "Move a node",
    CTL_IFACE_LRG, "Move", "x:id d:x d:y d:z", CTL_REPLY_STRING },
  { "lrg delete", "Delete a node",
    CTL_IFACE_LRG, "Delete", "x:id", CTL_REPLY_STRING },
  { "lrg add-primitive", "Add a primitive node",
    CTL_IFACE_LRG, "AddPrimitive", "x:primitive s?:name",
    CTL_REPLY_STRING },
  { "lrg add-visual", "Add a visual node",
    CTL_IFACE_LRG, "AddVisual", "x:kind s?:asset s?:name",
    CTL_REPLY_STRING },

  /* instance/log surface */
  { "logs show", "Recent *Messages* lines",
    CTL_IFACE_LOG, "RecentMessages", "i?:lines", CTL_REPLY_STRING },

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
    "claude-code / opencode / claude-tmux; default: configured)", \
    "NAME" }
#define AI_MODEL_ENTRY \
  { "model", 'm', 0, G_OPTION_ARG_STRING, &ai_opt_model, \
    "Model name overriding the provider's default " \
    "(see 'ai models')", "MODEL" }

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

void
ctl_cmd_subsys_register (CtlCommandRegistry *registry)
{
  gint k;
  for (k = 0; subsys_specs[k].name != NULL; k++)
    ctl_command_registry_add (registry,
                              ctl_method_command_new (&subsys_specs[k]));

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
}
