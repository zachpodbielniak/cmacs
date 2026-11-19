/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-dbus-iface-media.c --- media subsystems via D-Bus.
 *
 * Three interfaces, individually gated:
 *
 *   org.cmacs.Editor1.Video   (HAVE_CMACS_VIDEO)
 *   org.cmacs.Editor1.Audio   (HAVE_CMACS_AUDIO)
 *   org.cmacs.Editor1.Speech  (HAVE_CMACS_WHISPER and/or HAVE_CMACS_PIPER)
 *
 * MCP parity: mirrors video_list / video_snapshot
 * (cmacs-mcp-tools-shell.c) and record_audio / transcribe /
 * list_whisper_models / synthesize_speech / list_voices
 * (cmacs-mcp-tools-audio.c).  Sync discipline: adding a tool there
 * requires a matching method here, and vice versa.  Unlike MCP, the
 * snapshot/record methods take an explicit output file path and
 * return it, rather than streaming binary content. */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "cmacs-dbus.h"
#include "cmacs-dbus-internal.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <string.h>

#if defined(HAVE_CMACS_VIDEO) || defined(HAVE_CMACS_AUDIO) \
  || defined(HAVE_CMACS_WHISPER) || defined(HAVE_CMACS_PIPER) \
  || defined(HAVE_CMACS_SHERPA)

/* Eval EXPR (already fully built) and reply with the raw string. */
static void
media_reply (GDBusMethodInvocation *iv, gchar *expr)
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
  g_dbus_method_invocation_return_value (
    iv, g_variant_new ("(s)", result));
  g_free (result);
}

/* Quote S as an elisp string literal. */
static gchar *
media_lisp_str (const gchar *s)
{
  gchar *esc, *out;
  esc = cmacs_dbus_lisp_escape (s != NULL ? s : "");
  out = g_strdup_printf ("\"%s\"", esc);
  g_free (esc);
  return out;
}

#endif

/* ── org.cmacs.Editor1.Video ────────────────────────────────────────── */

#ifdef HAVE_CMACS_VIDEO

static const gchar *video_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Video'>"
  "    <method name='List'>"
  "      <arg type='s' name='handles' direction='out'/>"
  "    </method>"
  "    <method name='Snapshot'>"
  "      <arg type='x' name='handle' direction='in'/>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='path' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *video_info = NULL;

static void
video_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                   const gchar *i, const gchar *m, GVariant *p,
                   GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "List") == 0)
    media_reply (iv, g_strdup ("(prin1-to-string (cmacs-video-list))"));
  else if (g_strcmp0 (m, "Snapshot") == 0)
    {
      gint64 handle;
      const gchar *file;
      gchar *qf;
      g_variant_get (p, "(x&s)", &handle, &file);
      qf = media_lisp_str (file);
      media_reply (iv, g_strdup_printf
        ("(progn (cmacs-video-snapshot-to-file %lld %s) %s)",
         (long long) handle, qf, qf));
      g_free (qf);
    }
}

static const GDBusInterfaceVTable video_vtable = {
  video_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_video_register (GDBusConnection *conn, const gchar *path,
                                 GError **error)
{
  if (video_info == NULL)
    {
      video_info = g_dbus_node_info_new_for_xml (video_xml, error);
      if (video_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, video_info->interfaces[0], &video_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_video_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (video_info != NULL)
    { g_dbus_node_info_unref (video_info); video_info = NULL; }
}

#endif /* HAVE_CMACS_VIDEO */

/* ── org.cmacs.Editor1.Audio ────────────────────────────────────────── */

#ifdef HAVE_CMACS_AUDIO

static const gchar *audio_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Audio'>"
  "    <method name='Record'>"
  "      <arg type='d' name='seconds' direction='in'/>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='path' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *audio_info = NULL;

static void
audio_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                   const gchar *i, const gchar *m, GVariant *p,
                   GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Record") == 0)
    {
      gdouble seconds;
      const gchar *file;
      gchar *path_form;
      g_variant_get (p, "(d&s)", &seconds, &file);
      if (file != NULL && *file != '\0')
        path_form = media_lisp_str (file);
      else
        path_form = g_strdup
          ("(expand-file-name"
           " (format-time-string \"audio-%Y%m%d-%H%M%S.wav\")"
           " cmacs-audio-output-dir)");
      media_reply (iv, g_strdup_printf
        ("(progn (require 'cmacs-audio)"
         " (let ((path %s))"
         "   (cmacs-audio-record-to-file path %g)"
         "   path))",
         path_form, seconds));
      g_free (path_form);
    }
}

static const GDBusInterfaceVTable audio_vtable = {
  audio_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_audio_register (GDBusConnection *conn, const gchar *path,
                                 GError **error)
{
  if (audio_info == NULL)
    {
      audio_info = g_dbus_node_info_new_for_xml (audio_xml, error);
      if (audio_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, audio_info->interfaces[0], &audio_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_audio_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (audio_info != NULL)
    { g_dbus_node_info_unref (audio_info); audio_info = NULL; }
}

#endif /* HAVE_CMACS_AUDIO */

/* ── org.cmacs.Editor1.Speech (whisper STT + piper TTS) ─────────────── */

#if defined(HAVE_CMACS_WHISPER) || defined(HAVE_CMACS_PIPER) \
  || defined(HAVE_CMACS_SHERPA)

static const gchar *speech_xml =
  "<node>"
  "  <interface name='org.cmacs.Editor1.Speech'>"
  "    <method name='Transcribe'>"
  "      <arg type='s' name='audio_path' direction='in'/>"
  "      <arg type='s' name='language' direction='in'/>"
  "      <arg type='s' name='text' direction='out'/>"
  "    </method>"
  "    <method name='ListWhisperModels'>"
  "      <arg type='s' name='models' direction='out'/>"
  "    </method>"
  "    <method name='Synthesize'>"
  "      <arg type='s' name='text' direction='in'/>"
  "      <arg type='s' name='file' direction='in'/>"
  "      <arg type='s' name='result' direction='out'/>"
  "    </method>"
  "    <method name='ListVoices'>"
  "      <arg type='s' name='voices' direction='out'/>"
  "    </method>"
  "    <method name='Components'>"
  "      <arg type='s' name='table' direction='out'/>"
  "    </method>"
  "    <method name='SetComponent'>"
  "      <arg type='s' name='component' direction='in'/>"
  "      <arg type='s' name='backend' direction='in'/>"
  "      <arg type='s' name='model' direction='in'/>"
  "      <arg type='s' name='resolved' direction='out'/>"
  "    </method>"
  "    <method name='Models'>"
  "      <arg type='s' name='component' direction='in'/>"
  "      <arg type='s' name='table' direction='out'/>"
  "    </method>"
  "    <method name='WhoSpoke'>"
  "      <arg type='s' name='audio_path' direction='in'/>"
  "      <arg type='s' name='transcript' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *speech_info = NULL;

/* Only the builds that are missing a backend ever call this -- every use
   is in an #else branch -- so with both compiled in it is an unused
   function.  Guarded rather than deleted: it is what those builds
   answer with. */
#if !defined HAVE_CMACS_WHISPER || !defined HAVE_CMACS_PIPER
static void
speech_unsupported (GDBusMethodInvocation *iv, const gchar *what)
{
  gchar *msg = g_strdup_printf (
    "%s support not compiled into this cmacs", what);
  g_dbus_method_invocation_return_dbus_error (
    iv, "org.cmacs.Editor1.Error", msg);
  g_free (msg);
}
#endif

static void
speech_method_call (GDBusConnection *c, const gchar *s, const gchar *o,
                    const gchar *i, const gchar *m, GVariant *p,
                    GDBusMethodInvocation *iv, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_strcmp0 (m, "Transcribe") == 0)
    {
      /* Through cmacs-speech: whisper.cpp or sherpa-onnx, as chosen in
         M-x cmacs-speech; any audio or video format ffmpeg reads.  */
      const gchar *path, *lang;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &path, &lang);
      args[0] = path;
      args[1] = lang;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-speech)"
        " (let ((r (cmacs-speech-transcribe-file-now \"%s\" :feature 'rpc"
        " :language (let ((l \"%s\")) (and (> (length l) 0) l)))))"
        " (or (cdr (assq :text r)) (error \"%%s\" (cdr (assq :error r))))))",
        args, 2);
    }
  else if (g_strcmp0 (m, "ListWhisperModels") == 0)
    {
#ifdef HAVE_CMACS_WHISPER
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-whisper)"
        " (format \"%%S\" (cmacs-whisper-list-models)))", NULL, 0);
#else
      speech_unsupported (iv, "whisper (STT)");
#endif
    }
  else if (g_strcmp0 (m, "Synthesize") == 0)
    {
      /* Through cmacs-speech; with FILE, a real WAV (header and rate),
         not the raw PCM this used to write.  */
      const gchar *text, *file;
      const gchar *args[2];
      g_variant_get (p, "(&s&s)", &text, &file);
      args[0] = text;
      args[1] = file;
      if (*file != '\0')
        cmacs_dbus_eval_to_reply_string (iv,
          "(progn (require 'cmacs-speech)"
          " (let ((r (cmacs-speech-synthesize-now \"%s\" :feature 'rpc)))"
          " (when (assq :error r) (error \"%%s\" (cdr (assq :error r))))"
          " (cmacs-speech-write-wav \"%s\" (cdr (assq :pcm r))"
          " (cdr (assq :sample-rate r)))))",
          args, 2);
      else
        cmacs_dbus_eval_to_reply_string (iv,
          "(progn (require 'cmacs-speech)"
          " (cmacs-speech-speak \"%s\" :feature 'rpc) \"ok\")",
          args, 1);
    }
  else if (g_strcmp0 (m, "Components") == 0)
    cmacs_dbus_eval_to_reply_string (iv,
      "(progn (require 'cmacs-speech)"
      " (mapconcat (lambda (r) (format \"%%s%%s\\t%%s\\t%%s\\t%%s\""
      " (plist-get r :component)"
      " (if (plist-get r :feature) (format \"/%%s\" (plist-get r :feature)) \"\")"
      " (or (plist-get r :backend) \"-\") (or (plist-get r :model) \"-\")"
      " (plist-get r :source)))"
      " (cmacs-speech-describe-resolution) \"\\n\"))", NULL, 0);
  else if (g_strcmp0 (m, "SetComponent") == 0)
    {
      /* Session only: a remote caller never rewrites saved choices.  */
      const gchar *comp, *backend, *model;
      const gchar *args[4];
      g_variant_get (p, "(&s&s&s)", &comp, &backend, &model);
      args[0] = comp; args[1] = backend; args[2] = model; args[3] = comp;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-speech)"
        " (cmacs-speech-session-set (intern \"%s\") (intern \"%s\")"
        " :model (let ((m \"%s\")) (and (> (length m) 0) m)))"
        " (format \"%%S\" (cmacs-speech-resolve (intern \"%s\"))))",
        args, 4);
    }
  else if (g_strcmp0 (m, "Models") == 0)
    {
      const gchar *comp;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &comp);
      args[0] = comp;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-speech-models)"
        " (mapconcat (lambda (m) (format \"%%s\\t%%s\\t%%s\\t%%s\""
        " (if (plist-get m :installed) \"installed\" \"available\")"
        " (plist-get m :backend) (plist-get m :id)"
        " (mapconcat #'symbol-name (plist-get m :components) \",\")))"
        " (cmacs-speech-models :component (let ((c \"%s\"))"
        " (and (> (length c) 0) (intern c)))) \"\\n\"))",
        args, 1);
    }
  else if (g_strcmp0 (m, "WhoSpoke") == 0)
    {
      const gchar *path;
      const gchar *args[1];
      g_variant_get (p, "(&s)", &path);
      args[0] = path;
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-speech) (cmacs-speech-who-spoke-now \"%s\"))",
        args, 1);
    }
  else if (g_strcmp0 (m, "ListVoices") == 0)
    {
#ifdef HAVE_CMACS_PIPER
      cmacs_dbus_eval_to_reply_string (iv,
        "(progn (require 'cmacs-piper)"
        " (format \"%%S\" (cmacs-piper-list-voices)))", NULL, 0);
#else
      speech_unsupported (iv, "piper (TTS)");
#endif
    }
}

static const GDBusInterfaceVTable speech_vtable = {
  speech_method_call, NULL, NULL, { NULL }
};

guint
cmacs_dbus_iface_speech_register (GDBusConnection *conn, const gchar *path,
                                  GError **error)
{
  if (speech_info == NULL)
    {
      speech_info = g_dbus_node_info_new_for_xml (speech_xml, error);
      if (speech_info == NULL) return 0;
    }
  return g_dbus_connection_register_object (
    conn, path, speech_info->interfaces[0], &speech_vtable,
    NULL, NULL, error);
}

void
cmacs_dbus_iface_speech_unregister (GDBusConnection *conn, guint id)
{
  if (id > 0) g_dbus_connection_unregister_object (conn, id);
  if (speech_info != NULL)
    { g_dbus_node_info_unref (speech_info); speech_info = NULL; }
}

#endif /* HAVE_CMACS_WHISPER || HAVE_CMACS_PIPER || HAVE_CMACS_SHERPA */

#endif /* HAVE_CMACS_GLIB */
