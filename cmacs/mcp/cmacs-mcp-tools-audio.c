/*
 * cmacs-mcp-tools-audio.c — Audio capture, whisper STT, piper TTS tools
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Three tool groups, each conditionally compiled on the matching
 * HAVE_CMACS_* feature:
 *   record_audio         (HAVE_CMACS_AUDIO)
 *   list_voices          (HAVE_CMACS_PIPER)
 *   list_whisper_models  (HAVE_CMACS_WHISPER)
 *   transcribe           (HAVE_CMACS_WHISPER)
 *   synthesize_speech    (HAVE_CMACS_PIPER)
 *
 * All tools route through `cmacs_dispatch_eval' so the implementation
 * stays in Elisp and the C side is just wire conversion.  This
 * matches the existing cmacs-mcp-tools-* pattern.
 */

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
#include "cmacs-mcp-tools.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>

/* Helper: dispatch a printf-shaped Elisp expression. */
static gchar *ca_eval (GError **err, const char *fmt, ...) G_GNUC_PRINTF (2, 3);

static gchar *
ca_eval (GError **err, const char *fmt, ...)
{
  va_list ap;
  va_start (ap, fmt);
  gchar *expr = g_strdup_vprintf (fmt, ap);
  va_end (ap);
  gchar *out = cmacs_dispatch_eval (expr, err);
  g_free (expr);
  return out;
}

/* ── record_audio ─────────────────────────────────────────────────── */

static McpToolResult *
handle_record_audio (McpServer *server, const gchar *name,
                     JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  if (!arguments || !json_object_has_member (arguments, "seconds"))
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: seconds");
      return r;
    }
  gdouble seconds = json_object_get_double_member (arguments, "seconds");
  const gchar *out = json_object_has_member (arguments, "output_path")
                   ? json_object_get_string_member_with_default (arguments, "output_path", NULL)
                   : NULL;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *eout = out ? cmacs_dispatch_lisp_escape (out) : NULL;
  g_autofree gchar *out_form = eout
    ? g_strdup_printf ("\"%s\"", eout)
    : g_strdup ("(expand-file-name "
                "(format-time-string \"audio-%Y%m%d-%H%M%S.wav\") "
                "cmacs-audio-output-dir)");
  g_autofree gchar *res =
    ca_eval (&err,
             "(progn (require 'cmacs-audio) "
             "(cmacs-audio-record-to-file %s %g) %g)",
             out_form, seconds, seconds);
  if (!res)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, err ? err->message : "record failed");
      return r;
    }
  McpToolResult *r = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (r, res);
  return r;
}

/* ── Speech, through cmacs-speech: whichever engine M-x cmacs-speech
   chose (whisper.cpp, sherpa-onnx, piper).  The *-now Lisp functions
   run the engine on this thread, as these tools always did. ──────── */

/* A string argument, Lisp-escaped, or NULL.  */
static gchar *
arg_escaped (JsonObject *a, const char *key)
{
  const gchar *v = a && json_object_has_member (a, key)
    ? json_object_get_string_member_with_default (a, key, NULL) : NULL;
  return v && *v ? cmacs_dispatch_lisp_escape (v) : NULL;
}

/* `:KEY "VALUE"' for a present string argument, else "".  */
static gchar *
kw_arg (JsonObject *a, const char *json_key, const char *kw, gboolean symbol)
{
  g_autofree gchar *v = arg_escaped (a, json_key);
  if (!v)
    return g_strdup ("");
  return symbol ? g_strdup_printf (" :%s '%s", kw, v)
                : g_strdup_printf (" :%s \"%s\"", kw, v);
}

static McpToolResult *
tool_result (gchar *res, GError *err, const char *fallback)
{
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r, res ? res : (err ? err->message : fallback));
  return r;
}

static McpToolResult *
handle_transcribe (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  g_autofree gchar *path = arg_escaped (arguments, "audio_path");
  g_autofree gchar *lang = kw_arg (arguments, "language", "language", FALSE);
  g_autofree gchar *backend = kw_arg (arguments, "backend", "backend", TRUE);
  g_autofree gchar *model = kw_arg (arguments, "model", "model", FALSE);
  gboolean diarize = arguments && json_object_has_member (arguments, "diarize")
    && json_object_get_boolean_member_with_default (arguments, "diarize", FALSE);
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;

  if (!path)
    return tool_result (NULL, NULL, "Missing required argument: audio_path");
  if (diarize)
    res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                   "(cmacs-speech-who-spoke-now \"%s\"))", path);
  else
    res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                   "(let ((r (cmacs-speech-transcribe-file-now \"%s\" :feature 'rpc%s%s%s))) "
                   "(or (cdr (assq :text r)) (error \"%%s\" (cdr (assq :error r))))))",
                   path, lang, backend, model);
  return tool_result (res, err, "transcribe failed");
}

static McpToolResult *
handle_synthesize_speech (McpServer *server, const gchar *name,
                          JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  g_autofree gchar *text = arg_escaped (arguments, "text");
  g_autofree gchar *out = arg_escaped (arguments, "output_path");
  g_autofree gchar *voice = kw_arg (arguments, "voice", "voice", FALSE);
  g_autofree gchar *backend = kw_arg (arguments, "backend", "backend", TRUE);
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;

  if (!text)
    return tool_result (NULL, NULL, "Missing required argument: text");
  if (out)
    /* A real WAV (header and rate), not the raw PCM this used to write.  */
    res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                   "(let ((r (cmacs-speech-synthesize-now \"%s\" :feature 'rpc%s%s))) "
                   "(when (assq :error r) (error \"%%s\" (cdr (assq :error r)))) "
                   "(cmacs-speech-write-wav \"%s\" (cdr (assq :pcm r)) "
                   "(cdr (assq :sample-rate r)))))",
                   text, voice, backend, out);
  else
    res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                   "(cmacs-speech-speak \"%s\" :feature 'rpc) \"ok\")", text);
  return tool_result (res, err, "speak failed");
}

static McpToolResult *
handle_speech_components (McpServer *server, const gchar *name,
                          JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) arguments; (void) user_data;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    cmacs_dispatch_eval ("(progn (require 'cmacs-speech) "
                         "(mapconcat (lambda (r) (format \"%s%s\\t%s\\t%s\\t%s\" "
                         "(plist-get r :component) "
                         "(if (plist-get r :feature) (format \"/%s\" (plist-get r :feature)) \"\") "
                         "(or (plist-get r :backend) \"-\") (or (plist-get r :model) \"-\") "
                         "(plist-get r :source))) "
                         "(cmacs-speech-describe-resolution) \"\\n\"))", &err);
  return tool_result (res, err, "describe failed");
}

static McpToolResult *
handle_speech_set (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  g_autofree gchar *component = arg_escaped (arguments, "component");
  g_autofree gchar *backend = arg_escaped (arguments, "backend");
  g_autofree gchar *model = kw_arg (arguments, "model", "model", FALSE);
  g_autofree gchar *feature = kw_arg (arguments, "feature", "feature", TRUE);
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;

  if (!component || !backend)
    return tool_result (NULL, NULL, "Missing required argument: component and backend");
  /* Session only: an agent never rewrites the user's saved choices.  */
  res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                 "(cmacs-speech-session-set (intern \"%s\") (intern \"%s\")%s%s) "
                 "(format \"%%S\" (cmacs-speech-resolve (intern \"%s\"))))",
                 component, backend, model, feature, component);
  return tool_result (res, err, "set failed");
}

static McpToolResult *
handle_speech_models (McpServer *server, const gchar *name,
                      JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  g_autofree gchar *component = kw_arg (arguments, "component", "component", TRUE);
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    ca_eval (&err, "(progn (require 'cmacs-speech-models) "
             "(mapconcat (lambda (m) (format \"%%s\\t%%s\\t%%s\\t%%s\\t%%s\" "
             "(if (plist-get m :installed) \"installed\" \"available\") "
             "(plist-get m :backend) (plist-get m :id) "
             "(mapconcat #'symbol-name (plist-get m :components) \",\") "
             "(or (plist-get m :description) \"\"))) "
             "(cmacs-speech-models%s) \"\\n\"))", component);
  return tool_result (res, err, "list failed");
}

/* Analysis tools on an audio file: COMPONENT, then how to print.  */
static McpToolResult *
run_on_file (JsonObject *arguments, const char *component, const char *fmt_result)
{
  g_autofree gchar *path = arg_escaped (arguments, "audio_path");
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;
  if (!path)
    return tool_result (NULL, NULL, "Missing required argument: audio_path");
  res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                 "(let* ((got (cmacs-speech-file-pcm-now \"%s\")) "
                 "(r (cmacs-speech-run-now '%s (car got) :rate (cdr got)%s))) "
                 "(when (assq :error r) (error \"%%s\" (cdr (assq :error r)))) %s))",
                 path, component,
                 g_strcmp0 (component, "speaker-id") == 0 ? " :op 'identify" : "",
                 fmt_result);
  return tool_result (res, err, "speech analysis failed");
}

static McpToolResult *
handle_speech_diarize (McpServer *server, const gchar *name,
                       JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  g_autofree gchar *path = arg_escaped (arguments, "audio_path");
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res = NULL;
  if (!path)
    return tool_result (NULL, NULL, "Missing required argument: audio_path");
  res = ca_eval (&err, "(progn (require 'cmacs-speech) "
                 "(cmacs-speech-who-spoke-now \"%s\"))", path);
  return tool_result (res, err, "diarize failed");
}

static McpToolResult *
handle_speech_tag_audio (McpServer *server, const gchar *name,
                         JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  return run_on_file (arguments, "audio-tag",
                      "(mapconcat (lambda (e) (format \"%s %.2f\" (cdr (assq :name e)) "
                      "(cdr (assq :prob e)))) (cdr (assq :events r)) \"\\n\")");
}

static McpToolResult *
handle_speech_identify (McpServer *server, const gchar *name,
                        JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  return run_on_file (arguments, "speaker-id",
                      "(mapconcat (lambda (m) (format \"%s %.2f\" (cdr (assq :name m)) "
                      "(cdr (assq :score m)))) (cdr (assq :matches r)) \"\\n\")");
}

#ifdef HAVE_CMACS_WHISPER
static McpToolResult *
handle_list_whisper_models (McpServer *server, const gchar *name,
                            JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) arguments; (void) user_data;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    cmacs_dispatch_eval ("(progn (require 'cmacs-whisper) "
                         "(format \"%S\" (cmacs-whisper-list-models)))", &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r, res ? res : (err ? err->message : "list failed"));
  return r;
}
#endif /* HAVE_CMACS_WHISPER */

#ifdef HAVE_CMACS_PIPER
static McpToolResult *
handle_list_voices (McpServer *server, const gchar *name,
                    JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) arguments; (void) user_data;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    cmacs_dispatch_eval ("(progn (require 'cmacs-piper) "
                         "(format \"%S\" (cmacs-piper-list-voices)))", &err);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r, res ? res : (err ? err->message : "list failed"));
  return r;
}
#endif /* HAVE_CMACS_PIPER */

void
cmacs_mcp_tools_audio_register (McpServer *server)
{
  McpTool *tool;
  JsonNode *schema;

  tool = mcp_tool_new ("record_audio",
    "Capture microphone audio for SECONDS into OUTPUT_PATH (WAV). "
    "Returns the output path on success.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"seconds\":{\"type\":\"number\",\"description\":\"Duration in seconds\"},"
    "\"output_path\":{\"type\":\"string\",\"description\":\"Optional WAV path\"}"
    "},\"required\":[\"seconds\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_record_audio, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("transcribe",
    "Transcribe an audio or video file with the engine M-x cmacs-speech "
    "chose (whisper.cpp or sherpa-onnx).  Returns the transcript; with "
    "diarize, a speaker-labelled one.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"audio_path\":{\"type\":\"string\",\"description\":\"Audio or video file (any format ffmpeg reads)\"},"
    "\"language\":{\"type\":\"string\",\"description\":\"ISO 2-letter code hint\"},"
    "\"backend\":{\"type\":\"string\",\"description\":\"whisper or sherpa (default: as configured)\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Installed model id (see speech_models)\"},"
    "\"diarize\":{\"type\":\"boolean\",\"description\":\"Label who spoke when\"}"
    "},\"required\":[\"audio_path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_transcribe, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("synthesize_speech",
    "Speak TEXT with the configured voice, or write it to OUTPUT_PATH as "
    "a WAV file.  VOICE picks an installed voice (see speech_models).");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"text\":{\"type\":\"string\",\"description\":\"Text to speak\"},"
    "\"output_path\":{\"type\":\"string\",\"description\":\"Optional WAV path\"},"
    "\"voice\":{\"type\":\"string\",\"description\":\"Installed voice id\"},"
    "\"backend\":{\"type\":\"string\",\"description\":\"sherpa or piper\"}"
    "},\"required\":[\"text\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_synthesize_speech, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_components",
    "Which engine and model serve each speech component and feature, and "
    "why (tab-separated: component[/feature], backend, model, source).");
  schema = cmacs_mcp_schema_from_string ("{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_speech_components, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_set",
    "Choose the engine (and model) for a speech component, for this "
    "session only -- the user's saved choices are never changed.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"component\":{\"type\":\"string\",\"description\":\"stt, stt-live, stt-stream, wake, vad, tts, diarize, speaker-id, punctuate, lang-id, audio-tag, denoise, separate\"},"
    "\"backend\":{\"type\":\"string\",\"description\":\"whisper, sherpa, piper, or auto\"},"
    "\"model\":{\"type\":\"string\",\"description\":\"Installed model id\"},"
    "\"feature\":{\"type\":\"string\",\"description\":\"Limit to one feature (dictate, voice-loop, ...)\"}"
    "},\"required\":[\"component\",\"backend\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_speech_set, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_models",
    "Installed and downloadable speech models (tab-separated: state, "
    "backend, id, components, description).  Downloads are started by the "
    "user in M-x cmacs-speech.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"component\":{\"type\":\"string\",\"description\":\"Only models serving this component\"}"
    "}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_speech_models, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_diarize",
    "Who spoke when in an audio or video file: a speaker-labelled transcript.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"audio_path\":{\"type\":\"string\",\"description\":\"Audio or video file\"}"
    "},\"required\":[\"audio_path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_speech_diarize, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_tag_audio",
    "What sounds are in an audio file (speech, music, laughter, ...), with probabilities.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"audio_path\":{\"type\":\"string\",\"description\":\"Audio or video file\"}"
    "},\"required\":[\"audio_path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_speech_tag_audio, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("speech_identify_speaker",
    "Which enrolled speaker an audio file sounds like, best matches first.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"audio_path\":{\"type\":\"string\",\"description\":\"Audio or video file\"}"
    "},\"required\":[\"audio_path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_speech_identify, NULL, NULL);
  g_object_unref (tool);

#ifdef HAVE_CMACS_WHISPER
  tool = mcp_tool_new ("list_whisper_models",
    "List whisper.cpp models available in cmacs-whisper-models-directory.");
  schema = cmacs_mcp_schema_from_string ("{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_whisper_models, NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_PIPER
  tool = mcp_tool_new ("list_voices",
    "List Piper voice .onnx files in cmacs-piper-voices-directory.");
  schema = cmacs_mcp_schema_from_string ("{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_voices, NULL, NULL);
  g_object_unref (tool);
#endif
}

#endif /* HAVE_CMACS_AUDIO */
