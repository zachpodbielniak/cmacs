/* cmacs-piper-job.c --- Run Piper as a subprocess; collect PCM stdout.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Invocation:
 *   piper --model VOICE.onnx --output_raw
 *   (reads UTF-8 text on stdin; writes raw PCM to stdout)
 *
 * Returned PCM is S16LE mono at the voice model's native sample rate
 * (typically 16000 or 22050 Hz).  The Lisp layer wires this PCM into
 * `cmacs-audio--playback-open-pcm-1' for live output, or writes it to
 * a WAV file via `cmacs-audio-stream-write-wav'.
 *
 * Synchronous and async variants are provided.  The async path uses
 * `g_subprocess_communicate_async' so the spawned piper is polled by
 * the cmacs GMainContext (no extra thread).
 */

#include <config.h>

#ifdef HAVE_CMACS_PIPER

#include "lisp.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <gio/gio.h>
#include <glib.h>
#include <stdint.h>
#include <string.h>

#ifndef CMACS_PIPER_DEFAULT_BINARY
# define CMACS_PIPER_DEFAULT_BINARY "piper"
#endif

/* Public helpers, declared here for cmacs-piper-defuns.c. */

gboolean cmacs_piper_supported_p (void);
gchar   *cmacs_piper_synth_sync   (const char *binary, const char *model,
                                   const char *text, gsize *out_pcm_bytes,
                                   GError **err);
void     cmacs_piper_synth_async  (const char *binary, const char *model,
                                   const char *text, Lisp_Object callback);

/* --- Resolve the piper executable path. --- */

static gchar *piper_path_cache = NULL;

static const gchar *
cmacs_piper__binary_path (const char *override)
{
  if (override && *override) return override;
  if (piper_path_cache && *piper_path_cache) return piper_path_cache;
  gchar *found = g_find_program_in_path (CMACS_PIPER_DEFAULT_BINARY);
  if (found)
    {
      g_free (piper_path_cache);
      piper_path_cache = found;
      return piper_path_cache;
    }
  return CMACS_PIPER_DEFAULT_BINARY;
}

gboolean
cmacs_piper_supported_p (void)
{
  const gchar *p = cmacs_piper__binary_path (NULL);
  if (!p || !*p) return FALSE;
  if (g_path_is_absolute (p))
    return g_file_test (p, G_FILE_TEST_IS_EXECUTABLE);
  gchar *abs = g_find_program_in_path (p);
  if (abs) { g_free (abs); return TRUE; }
  return FALSE;
}

/* --- Synchronous synthesis: text -> PCM bytes. --- */

gchar *
cmacs_piper_synth_sync (const char *binary, const char *model,
                        const char *text, gsize *out_pcm_bytes,
                        GError **err)
{
  if (!text) text = "";
  if (!model || !*model)
    {
      g_set_error_literal (err, G_SPAWN_ERROR, G_SPAWN_ERROR_FAILED,
                           "cmacs-piper: model path required");
      return NULL;
    }
  const gchar *piper = cmacs_piper__binary_path (binary);
  gchar *argv[] = {
    (gchar *) piper,
    "--model",       (gchar *) model,
    "--output_raw",
    NULL
  };
  GSubprocessLauncher *l = g_subprocess_launcher_new (
    G_SUBPROCESS_FLAGS_STDIN_PIPE
    | G_SUBPROCESS_FLAGS_STDOUT_PIPE
    | G_SUBPROCESS_FLAGS_STDERR_PIPE);
  GSubprocess *p = g_subprocess_launcher_spawnv (l, (const gchar * const *) argv,
                                                 err);
  g_object_unref (l);
  if (!p) return NULL;

  GBytes *stdin_b  = g_bytes_new (text, strlen (text));
  GBytes *stdout_b = NULL, *stderr_b = NULL;
  gboolean ok = g_subprocess_communicate (p, stdin_b, NULL,
                                          &stdout_b, &stderr_b, err);
  g_bytes_unref (stdin_b);
  g_object_unref (p);
  if (!ok)
    {
      if (stdout_b) g_bytes_unref (stdout_b);
      if (stderr_b) g_bytes_unref (stderr_b);
      return NULL;
    }
  gsize  sz = 0;
  gconstpointer raw = g_bytes_get_data (stdout_b, &sz);
  gchar *out = g_malloc (sz);
  memcpy (out, raw, sz);
  if (out_pcm_bytes) *out_pcm_bytes = sz;
  if (stdout_b) g_bytes_unref (stdout_b);
  if (stderr_b) g_bytes_unref (stderr_b);
  return out;
}

/* --- Async variant. --- */

/* Per-job context.  cb_cookie indexes into the staticpro'd registry
 * in cmacs-eval-dispatch (so the Lisp callback is GC-rooted for the
 * lifetime of the subprocess).  Storing the Lisp_Object directly in
 * this struct would leak the callback through C heap without any GC
 * root and crash mid-job once Emacs decided to reclaim the closure. */
typedef struct {
  uint64_t     cb_cookie;
  GSubprocess *proc;
} PiperAsync;

static void
cmacs_piper__on_done (GObject *src, GAsyncResult *res, gpointer user)
{
  PiperAsync *p = user;
  GError *err = NULL;
  GBytes *stdout_b = NULL, *stderr_b = NULL;
  gboolean ok = g_subprocess_communicate_finish (G_SUBPROCESS (src), res,
                                                 &stdout_b, &stderr_b, &err);
  if (!ok)
    {
      Lisp_Object e = Fcons (intern (":error"),
                             build_string (err ? err->message
                                               : "piper subprocess failed"));
      if (err) g_error_free (err);
      cmacs_dispatch_callback_invoke1 (p->cb_cookie, e);
    }
  else
    {
      gsize sz = 0;
      gconstpointer data = g_bytes_get_data (stdout_b, &sz);
      Lisp_Object pcm = make_unibyte_string (data, sz);
      cmacs_dispatch_callback_invoke1 (p->cb_cookie, pcm);
    }
  if (stdout_b) g_bytes_unref (stdout_b);
  if (stderr_b) g_bytes_unref (stderr_b);
  g_object_unref (p->proc);
  g_free (p);
}

void
cmacs_piper_synth_async (const char *binary, const char *model,
                         const char *text, Lisp_Object callback)
{
  if (!text) text = "";
  const gchar *piper = cmacs_piper__binary_path (binary);
  gchar *argv[] = {
    (gchar *) piper,
    "--model",       (gchar *) model,
    "--output_raw",
    NULL
  };
  GError *err = NULL;
  GSubprocessLauncher *l = g_subprocess_launcher_new (
    G_SUBPROCESS_FLAGS_STDIN_PIPE
    | G_SUBPROCESS_FLAGS_STDOUT_PIPE
    | G_SUBPROCESS_FLAGS_STDERR_PIPE);
  GSubprocess *proc = g_subprocess_launcher_spawnv (
    l, (const gchar * const *) argv, &err);
  g_object_unref (l);
  if (!proc)
    {
      Lisp_Object e = Fcons (intern (":error"),
                             build_string (err ? err->message
                                               : "spawn piper failed"));
      if (err) g_error_free (err);
      cmacs_dispatch_safe_call1 (callback, e);
      return;
    }
  PiperAsync *p = g_new0 (PiperAsync, 1);
  p->cb_cookie = cmacs_dispatch_callback_register (callback);
  p->proc      = proc;
  GBytes *stdin_b = g_bytes_new (text, strlen (text));
  g_subprocess_communicate_async (proc, stdin_b, NULL,
                                  cmacs_piper__on_done, p);
  g_bytes_unref (stdin_b);
}

#endif /* HAVE_CMACS_PIPER */
