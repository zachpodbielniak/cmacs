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
                   ? json_object_get_string_member (arguments, "output_path")
                   : NULL;
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    ca_eval (&err,
             "(progn (require 'cmacs-audio) "
             "(cmacs-audio-record-to-file %s %g) %g)",
             out ? g_strdup_printf ("\"%s\"", out)
                 : g_strdup ("(expand-file-name "
                              "(format-time-string \"audio-%%Y%%m%%d-%%H%%M%%S.wav\") "
                              "cmacs-audio-output-dir)"),
             seconds, seconds);
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

#ifdef HAVE_CMACS_WHISPER
static McpToolResult *
handle_transcribe (McpServer *server, const gchar *name,
                   JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *path = arguments && json_object_has_member (arguments, "audio_path")
                    ? json_object_get_string_member (arguments, "audio_path") : NULL;
  const gchar *lang = arguments && json_object_has_member (arguments, "language")
                    ? json_object_get_string_member (arguments, "language") : "en";
  if (!path)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: audio_path");
      return r;
    }
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res =
    ca_eval (&err,
             "(progn (require 'cmacs-whisper) "
             "(cdr (assq :text (cmacs-whisper-transcribe-file "
             "(cmacs-whisper-model-path) \"%s\" \"%s\"))))",
             path, lang ? lang : "en");
  if (!res)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, err ? err->message : "transcribe failed");
      return r;
    }
  McpToolResult *r = mcp_tool_result_new (FALSE);
  mcp_tool_result_add_text (r, res);
  return r;
}

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
handle_synthesize_speech (McpServer *server, const gchar *name,
                          JsonObject *arguments, gpointer user_data)
{
  (void) server; (void) name; (void) user_data;
  const gchar *text = arguments && json_object_has_member (arguments, "text")
                    ? json_object_get_string_member (arguments, "text") : NULL;
  const gchar *out  = arguments && json_object_has_member (arguments, "output_path")
                    ? json_object_get_string_member (arguments, "output_path") : NULL;
  if (!text)
    {
      McpToolResult *r = mcp_tool_result_new (TRUE);
      mcp_tool_result_add_text (r, "Missing required argument: text");
      return r;
    }
  g_autoptr (GError) err = NULL;
  g_autofree gchar *res;
  if (out)
    res = ca_eval (&err,
      "(progn (require 'cmacs-piper) "
      "(let* ((pcm (cmacs-piper--synth-sync-1 "
      "(cmacs-piper-voice-path) \"%s\"))) "
      "(with-temp-file \"%s\" "
      "(set-buffer-multibyte nil) (insert pcm)) \"%s\"))",
      text, out, out);
  else
    res = ca_eval (&err,
      "(progn (require 'cmacs-piper) "
      "(cmacs-piper-speak-async \"%s\") \"ok\")", text);
  McpToolResult *r = mcp_tool_result_new (res == NULL);
  mcp_tool_result_add_text (r, res ? res : (err ? err->message : "speak failed"));
  return r;
}

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

#ifdef HAVE_CMACS_WHISPER
  tool = mcp_tool_new ("transcribe",
    "Transcribe a WAV file using whisper.cpp.  Returns the transcript text.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"audio_path\":{\"type\":\"string\",\"description\":\"Path to a WAV file\"},"
    "\"language\":{\"type\":\"string\",\"description\":\"ISO 2-letter code (default en)\"}"
    "},\"required\":[\"audio_path\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_transcribe, NULL, NULL);
  g_object_unref (tool);

  tool = mcp_tool_new ("list_whisper_models",
    "List whisper.cpp models available in cmacs-whisper-models-directory.");
  schema = cmacs_mcp_schema_from_string ("{\"type\":\"object\",\"properties\":{}}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_tool_set_read_only_hint (tool, TRUE);
  mcp_server_add_tool (server, tool, handle_list_whisper_models, NULL, NULL);
  g_object_unref (tool);
#endif

#ifdef HAVE_CMACS_PIPER
  tool = mcp_tool_new ("synthesize_speech",
    "Synthesise TEXT via Piper.  Writes a WAV to OUTPUT_PATH if given, "
    "otherwise plays through the default audio sink.");
  schema = cmacs_mcp_schema_from_string (
    "{\"type\":\"object\",\"properties\":{"
    "\"text\":{\"type\":\"string\",\"description\":\"Text to speak\"},"
    "\"output_path\":{\"type\":\"string\",\"description\":\"Optional WAV path\"}"
    "},\"required\":[\"text\"]}");
  mcp_tool_set_input_schema (tool, schema);
  mcp_server_add_tool (server, tool, handle_synthesize_speech, NULL, NULL);
  g_object_unref (tool);

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
