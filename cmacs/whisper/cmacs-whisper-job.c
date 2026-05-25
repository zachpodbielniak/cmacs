/* cmacs-whisper-job.c --- One transcription job.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A job:
 *   1. Holds PCM samples (S16LE 16 kHz mono) + model path + language.
 *   2. Runs `whisper_full' on a worker thread (libdex thread-pool).
 *   3. Posts the result back to the cmacs GMainContext, where the
 *      registered Lisp callback is invoked via `safe_calln'.
 *
 * The result shape is an alist:
 *   ((:text . "full text")
 *    (:segments . ( ((:start . S) (:end . E) (:text . "..."))  ... )))
 *
 * Synchronous wrappers `cmacs_whisper_run_pcm_blocking' are also
 * exported for the file/region M-x entry points that may legitimately
 * want to block on the main thread (with a progress message).
 */

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include "lisp.h"
#include "cmacs-glib-loop.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <whisper.h>

extern struct whisper_context *cmacs_whisper_context_get (const char *path,
                                                          GError **error);

/* --- Internal job struct --- */

typedef struct {
  /* Input (owned by job). */
  char        *model_path;
  char        *language;       /* may be NULL = auto */
  float       *samples;        /* converted to f32 in [-1, +1] */
  size_t       n_samples;
  /* Output (set on completion). */
  GString     *full_text;
  GArray      *segments;       /* of struct CmacsSeg */
  char        *error_msg;
  /* Callback cookie -- indexes into the staticpro'd registry in
   * cmacs-eval-dispatch.  Holding a raw Lisp_Object in this struct
   * would crash mid-job once GC reclaimed the closure. */
  uint64_t     cb_cookie;
  /* Lifecycle: posted from worker to main via g_main_context_invoke. */
} CmacsWhisperJob;

typedef struct {
  gint64  start_ms;
  gint64  end_ms;
  char   *text;            /* owned */
} CmacsSeg;

/* --- Convert s16 PCM (mono) into float32 in [-1, +1]. --- */

static float *
s16_to_f32 (const int16_t *in, size_t n)
{
  float *out = g_malloc (n * sizeof (float));
  for (size_t i = 0; i < n; i++)
    out[i] = (float) in[i] / 32768.0f;
  return out;
}

/* --- Read WAV file into S16LE mono samples. ---
 * Minimal RIFF parser: assumes the standard 44-byte header laid
 * down by cmacs-audio-stream-write-wav.  For arbitrary WAV files
 * with extra chunks, we walk chunks until "data". */

static int16_t *
read_wav_s16_mono (const char *path, size_t *out_n, GError **err)
{
  FILE *f = fopen (path, "rb");
  if (!f) { g_set_error (err, G_FILE_ERROR, g_file_error_from_errno (errno),
                         "open %s: %s", path, g_strerror (errno));
            return NULL; }
  char riff[4], wave[4];
  uint32_t chunk_size;
  if (fread (riff, 1, 4, f) != 4
      || fread (&chunk_size, 4, 1, f) != 1
      || fread (wave, 1, 4, f) != 4
      || memcmp (riff, "RIFF", 4) != 0
      || memcmp (wave, "WAVE", 4) != 0)
    { fclose (f);
      g_set_error_literal (err, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                           "not a RIFF/WAVE file");
      return NULL; }

  uint16_t fmt_tag = 0, channels = 0, bps = 0;
  uint32_t rate = 0;
  int16_t *data = NULL;
  size_t   nbytes = 0;
  while (!feof (f))
    {
      char cid[4]; uint32_t csz;
      if (fread (cid, 1, 4, f) != 4) break;
      if (fread (&csz, 4, 1, f) != 1) break;
      if (memcmp (cid, "fmt ", 4) == 0)
        {
          if (fread (&fmt_tag, 2, 1, f) != 1) break;
          if (fread (&channels, 2, 1, f) != 1) break;
          if (fread (&rate, 4, 1, f) != 1) break;
          fseek (f, 6, SEEK_CUR);   /* byte_rate + block_align */
          if (fread (&bps, 2, 1, f) != 1) break;
          if (csz > 16) fseek (f, csz - 16, SEEK_CUR);
        }
      else if (memcmp (cid, "data", 4) == 0)
        {
          data = g_malloc (csz);
          nbytes = fread (data, 1, csz, f);
          break;
        }
      else
        fseek (f, csz, SEEK_CUR);
    }
  fclose (f);
  if (!data || fmt_tag != 1 || bps != 16 || channels == 0)
    { g_free (data);
      g_set_error_literal (err, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                           "unsupported WAV format (need PCM S16LE)");
      return NULL; }
  size_t n_frames = nbytes / (channels * 2);
  /* Downmix to mono if needed. */
  if (channels > 1)
    {
      int16_t *mono = g_malloc (n_frames * 2);
      for (size_t i = 0; i < n_frames; i++)
        {
          int32_t acc = 0;
          for (int c = 0; c < channels; c++)
            acc += data[i * channels + c];
          mono[i] = (int16_t) (acc / channels);
        }
      g_free (data);
      data = mono;
    }
  *out_n = n_frames;
  return data;
}

/* --- Run inference, collect segments. --- */

static gboolean
cmacs_whisper__run (CmacsWhisperJob *j)
{
  GError *err = NULL;
  struct whisper_context *ctx = cmacs_whisper_context_get (j->model_path, &err);
  if (!ctx)
    {
      j->error_msg = g_strdup (err ? err->message : "model load failed");
      if (err) g_error_free (err);
      return FALSE;
    }
  struct whisper_full_params wp =
    whisper_full_default_params (WHISPER_SAMPLING_GREEDY);
  wp.print_progress    = false;
  wp.print_special     = false;
  wp.print_realtime    = false;
  wp.print_timestamps  = false;
  wp.translate         = false;
  wp.language          = j->language ? j->language : "en";
  wp.n_threads         = (int) g_get_num_processors ();

  int rc = whisper_full (ctx, wp, j->samples, (int) j->n_samples);
  if (rc != 0)
    {
      j->error_msg = g_strdup_printf ("whisper_full returned %d", rc);
      return FALSE;
    }
  int n_seg = whisper_full_n_segments (ctx);
  j->full_text = g_string_sized_new (256);
  j->segments  = g_array_new (FALSE, FALSE, sizeof (CmacsSeg));
  for (int i = 0; i < n_seg; i++)
    {
      const char *text = whisper_full_get_segment_text (ctx, i);
      int64_t t0 = whisper_full_get_segment_t0 (ctx, i) * 10; /* centisec -> ms */
      int64_t t1 = whisper_full_get_segment_t1 (ctx, i) * 10;
      g_string_append (j->full_text, text);
      CmacsSeg s = { t0, t1, g_strdup (text) };
      g_array_append_val (j->segments, s);
    }
  return TRUE;
}

/* --- Free job. --- */

static void
cmacs_whisper__job_free (CmacsWhisperJob *j)
{
  if (!j) return;
  g_free (j->model_path);
  g_free (j->language);
  g_free (j->samples);
  if (j->full_text) g_string_free (j->full_text, TRUE);
  if (j->segments)
    {
      for (guint i = 0; i < j->segments->len; i++)
        g_free (g_array_index (j->segments, CmacsSeg, i).text);
      g_array_free (j->segments, TRUE);
    }
  g_free (j->error_msg);
  g_free (j);
}

/* --- Convert job output to a Lisp alist. --- */

static Lisp_Object
cmacs_whisper__result_to_lisp (CmacsWhisperJob *j)
{
  if (j->error_msg)
    return Fcons (Fcons (intern (":error"),
                         build_string (j->error_msg)), Qnil);
  Lisp_Object segs = Qnil;
  for (gint i = (gint) j->segments->len - 1; i >= 0; i--)
    {
      CmacsSeg *s = &g_array_index (j->segments, CmacsSeg, i);
      Lisp_Object e = Qnil;
      e = Fcons (Fcons (intern (":text"), build_string (s->text)), e);
      e = Fcons (Fcons (intern (":end"),
                        make_int (s->end_ms)), e);
      e = Fcons (Fcons (intern (":start"),
                        make_int (s->start_ms)), e);
      segs = Fcons (e, segs);
    }
  Lisp_Object out = Qnil;
  out = Fcons (Fcons (intern (":segments"), segs), out);
  out = Fcons (Fcons (intern (":text"),
                      build_string (j->full_text->str)), out);
  return out;
}

/* --- Main-thread completion: call the registered Lisp callback. --- */

static gboolean
cmacs_whisper__main_completion (gpointer user)
{
  CmacsWhisperJob *j = user;
  cmacs_dispatch_callback_invoke1 (j->cb_cookie,
                                   cmacs_whisper__result_to_lisp (j));
  cmacs_whisper__job_free (j);
  return G_SOURCE_REMOVE;
}

/* --- Worker thread entry point. --- */

static gpointer
cmacs_whisper__worker (gpointer user)
{
  CmacsWhisperJob *j = user;
  cmacs_whisper__run (j);
  /* Always hand off to main thread for Lisp callback. */
  g_main_context_invoke (cmacs_glib_get_context (),
                         cmacs_whisper__main_completion, j);
  return NULL;
}

/* --- Public entry: async PCM transcription. --- */

void cmacs_whisper_transcribe_pcm_async (const char *model_path,
                                         const char *language,
                                         const int16_t *pcm, size_t n_samples,
                                         Lisp_Object callback);
void
cmacs_whisper_transcribe_pcm_async (const char *model_path,
                                    const char *language,
                                    const int16_t *pcm, size_t n_samples,
                                    Lisp_Object callback)
{
  CmacsWhisperJob *j = g_new0 (CmacsWhisperJob, 1);
  j->model_path = g_strdup (model_path);
  j->language   = language ? g_strdup (language) : NULL;
  j->samples    = s16_to_f32 (pcm, n_samples);
  j->n_samples  = n_samples;
  j->cb_cookie  = cmacs_dispatch_callback_register (callback);
  /* Spawn a worker.  GThread is sufficient here; libdex's thread-pool
   * scheduler offers no extra benefit for a single long-running job. */
  GThread *t = g_thread_new ("cmacs-whisper-job", cmacs_whisper__worker, j);
  g_thread_unref (t);   /* detach; completion runs on main thread */
}

/* --- Public entry: async file transcription. --- */

void cmacs_whisper_transcribe_file_async (const char *model_path,
                                          const char *language,
                                          const char *wav_path,
                                          Lisp_Object callback);
void
cmacs_whisper_transcribe_file_async (const char *model_path,
                                     const char *language,
                                     const char *wav_path,
                                     Lisp_Object callback)
{
  GError *err = NULL;
  size_t n = 0;
  int16_t *pcm = read_wav_s16_mono (wav_path, &n, &err);
  if (!pcm)
    {
      /* Fire callback immediately with :error. */
      Lisp_Object res = Fcons (
        Fcons (intern (":error"),
               build_string (err ? err->message : "WAV read failed")), Qnil);
      if (err) g_error_free (err);
      cmacs_dispatch_safe_call1 (callback, res);
      return;
    }
  cmacs_whisper_transcribe_pcm_async (model_path, language, pcm, n, callback);
  g_free (pcm);
}

/* --- Public entry: synchronous PCM transcription (returns Lisp alist). --- */

Lisp_Object cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                               const char *language,
                                               const int16_t *pcm,
                                               size_t n_samples);
Lisp_Object
cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                   const char *language,
                                   const int16_t *pcm, size_t n_samples)
{
  CmacsWhisperJob j = {0};
  j.model_path = g_strdup (model_path);
  j.language   = language ? g_strdup (language) : NULL;
  j.samples    = s16_to_f32 (pcm, n_samples);
  j.n_samples  = n_samples;
  j.cb_cookie  = 0;  /* sync path -- no callback to invoke */
  cmacs_whisper__run (&j);
  Lisp_Object out = cmacs_whisper__result_to_lisp (&j);
  /* Don't free j here; it lives on stack.  Free the heap fields manually. */
  g_free (j.model_path);
  g_free (j.language);
  g_free (j.samples);
  if (j.full_text) g_string_free (j.full_text, TRUE);
  if (j.segments)
    {
      for (guint i = 0; i < j.segments->len; i++)
        g_free (g_array_index (j.segments, CmacsSeg, i).text);
      g_array_free (j.segments, TRUE);
    }
  g_free (j.error_msg);
  return out;
}

/* --- Public entry: synchronous file transcription. --- */

Lisp_Object cmacs_whisper_transcribe_file_sync (const char *model_path,
                                                const char *language,
                                                const char *wav_path,
                                                GError **err);
Lisp_Object
cmacs_whisper_transcribe_file_sync (const char *model_path,
                                    const char *language,
                                    const char *wav_path,
                                    GError **err)
{
  size_t n = 0;
  int16_t *pcm = read_wav_s16_mono (wav_path, &n, err);
  if (!pcm) return Qnil;
  Lisp_Object out = cmacs_whisper_transcribe_pcm_sync (model_path, language,
                                                       pcm, n);
  g_free (pcm);
  return out;
}

#endif /* HAVE_CMACS_WHISPER */
