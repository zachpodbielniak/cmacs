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
#include "cmacs-whisper.h"

#include <glib.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <whisper.h>


/* --- Internal job struct --- */

typedef struct {
  /* Input (owned by job). */
  char        *model_path;
  char        *language;       /* may be NULL = auto */
  float       *samples;        /* converted to f32 in [-1, +1] */
  size_t       n_samples;
  int          n_threads;      /* whisper inference threads; <=0 = all cores */
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
  wp.n_threads         = j->n_threads > 0
                         ? j->n_threads : (int) g_get_num_processors ();

  /* Use the context's default state when no other job holds it, else
   * a private one: two threads in one whisper_state corrupt each other
   * (the voice loop overlaps partial and final transcriptions, and
   * cmacs-transcribe runs files in parallel on one model).  */
  gboolean own_default = cmacs_whisper_context_claim_default (ctx);
  struct whisper_state *st = NULL;
  int rc;
  if (own_default)
    rc = whisper_full (ctx, wp, j->samples, (int) j->n_samples);
  else
    {
      st = whisper_init_state (ctx);
      if (!st)
        {
          j->error_msg = g_strdup ("whisper_init_state failed");
          return FALSE;
        }
      rc = whisper_full_with_state (ctx, st, wp, j->samples,
                                    (int) j->n_samples);
    }
  if (rc != 0)
    {
      j->error_msg = g_strdup_printf ("whisper_full returned %d", rc);
      if (st)
        whisper_free_state (st);
      else
        cmacs_whisper_context_release_default (ctx);
      return FALSE;
    }
  int n_seg = st ? whisper_full_n_segments_from_state (st)
                 : whisper_full_n_segments (ctx);
  j->full_text = g_string_sized_new (256);
  j->segments  = g_array_new (FALSE, FALSE, sizeof (CmacsSeg));
  for (int i = 0; i < n_seg; i++)
    {
      const char *text;
      int64_t t0, t1;
      if (st)
        {
          text = whisper_full_get_segment_text_from_state (st, i);
          t0 = whisper_full_get_segment_t0_from_state (st, i) * 10;
          t1 = whisper_full_get_segment_t1_from_state (st, i) * 10;
        }
      else
        {
          text = whisper_full_get_segment_text (ctx, i);
          t0 = whisper_full_get_segment_t0 (ctx, i) * 10; /* cs -> ms */
          t1 = whisper_full_get_segment_t1 (ctx, i) * 10;
        }
      g_string_append (j->full_text, text);
      CmacsSeg s = { t0, t1, g_strdup (text) };
      g_array_append_val (j->segments, s);
    }
  if (st)
    whisper_free_state (st);
  else
    cmacs_whisper_context_release_default (ctx);
  return TRUE;
}

/* --- Free job. --- */

static void
cmacs_whisper__job_free (CmacsWhisperJob *j)
{
  if (!j) return;
  g_free (j->model_path);
  g_free (j->language);
  if (j->samples)
    memset_explicit (j->samples, 0, j->n_samples * sizeof (float));
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
                                         int n_threads,
                                         Lisp_Object callback);
void
cmacs_whisper_transcribe_pcm_async (const char *model_path,
                                    const char *language,
                                    const int16_t *pcm, size_t n_samples,
                                    int n_threads,
                                    Lisp_Object callback)
{
  CmacsWhisperJob *j = g_new0 (CmacsWhisperJob, 1);
  j->model_path = g_strdup (model_path);
  j->language   = language ? g_strdup (language) : NULL;
  j->samples    = s16_to_f32 (pcm, n_samples);
  j->n_samples  = n_samples;
  j->n_threads  = n_threads;
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
                                          int n_threads,
                                          Lisp_Object callback);
void
cmacs_whisper_transcribe_file_async (const char *model_path,
                                     const char *language,
                                     const char *wav_path,
                                     int n_threads,
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
  cmacs_whisper_transcribe_pcm_async (model_path, language, pcm, n,
                                      n_threads, callback);
  g_free (pcm);
}

/* --- Public entry: synchronous PCM transcription (returns Lisp alist). --- */

Lisp_Object cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                               const char *language,
                                               const int16_t *pcm,
                                               size_t n_samples,
                                               int n_threads);
Lisp_Object
cmacs_whisper_transcribe_pcm_sync (const char *model_path,
                                   const char *language,
                                   const int16_t *pcm, size_t n_samples,
                                   int n_threads)
{
  CmacsWhisperJob j = {0};
  j.model_path = g_strdup (model_path);
  j.language   = language ? g_strdup (language) : NULL;
  j.samples    = s16_to_f32 (pcm, n_samples);
  j.n_samples  = n_samples;
  j.n_threads  = n_threads;
  j.cb_cookie  = 0;  /* sync path -- no callback to invoke */
  cmacs_whisper__run (&j);
  Lisp_Object out = cmacs_whisper__result_to_lisp (&j);
  /* Don't free j here; it lives on stack.  Free the heap fields manually. */
  g_free (j.model_path);
  g_free (j.language);
  if (j.samples)
    memset_explicit (j.samples, 0, j.n_samples * sizeof (float));
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
                                                int n_threads,
                                                GError **err);
Lisp_Object
cmacs_whisper_transcribe_file_sync (const char *model_path,
                                    const char *language,
                                    const char *wav_path,
                                    int n_threads,
                                    GError **err)
{
  size_t n = 0;
  int16_t *pcm = read_wav_s16_mono (wav_path, &n, err);
  if (!pcm) return Qnil;
  Lisp_Object out = cmacs_whisper_transcribe_pcm_sync (model_path, language,
                                                       pcm, n, n_threads);
  g_free (pcm);
  return out;
}

/* --- Streaming voice-activity detection ---------------------------
 *
 * whisper.cpp v1.9 ships the Silero VAD as a ggml model and exposes
 * `whisper_vad_detect_speech_no_reset', which keeps the model's LSTM
 * state across calls -- exactly what a microphone stream needs: feed
 * each new run of 512-sample windows as it arrives and get one speech
 * probability per window back, with the network still remembering the
 * audio before it.
 *
 * Threading.  Every VAD operation (feed, reset, close) goes through
 * ONE GThreadPool with a single worker, so the operations on a stream
 * run strictly in the order Lisp issued them -- a reset can never
 * overtake the feed before it, and a close always runs last.  The
 * worker owns `vctx': it loads the model lazily on the first feed (so
 * opening a stream never blocks Emacs on file I/O), runs inference,
 * and frees it on close.  Results go back to the main thread with
 * g_main_context_invoke, where the Lisp callback runs through the
 * GC-rooted cookie registry in cmacs-eval-dispatch -- no Lisp_Object
 * is ever held in this heap memory, and no Lisp runs off the main
 * thread.
 *
 * The handle table is touched only on the main thread (the DEFUNs),
 * so it needs no lock.  A stream is removed from it by close before
 * its CLOSE job is queued, so no feed can be queued after the close.
 *
 * Privacy.  Sample buffers are wiped (memset_explicit) before they
 * are freed; nothing is written to disk.  */

typedef struct {
  uint64_t                    handle;
  char                       *model_path;
  int                         n_threads;
  struct whisper_vad_context *vctx;        /* worker thread only */
  char                       *load_error;  /* worker thread only */
} CmacsWhisperVad;

typedef enum {
  CMACS_WHISPER_VAD_OP_FEED = 0,
  CMACS_WHISPER_VAD_OP_RESET,
  CMACS_WHISPER_VAD_OP_CLOSE
} CmacsWhisperVadOp;

typedef struct {
  CmacsWhisperVadOp  op;
  CmacsWhisperVad   *vad;
  float             *samples;     /* FEED input, owned */
  size_t             n_samples;
  uint64_t           cb_cookie;   /* FEED only */
  float             *probs;       /* FEED output, owned */
  int                n_probs;
  char              *error_msg;   /* FEED output, owned */
} CmacsWhisperVadJob;

static GThreadPool *vad_pool = NULL;        /* created on first open */
static GHashTable  *vad_streams = NULL;     /* handle -> stream; main thread */
static uint64_t     vad_next_handle = 1;

/* cmacs_whisper__wipe_free:
 * @p: (nullable): a buffer of @n floats.
 * @n: element count.
 *
 * Zero @p in a way the compiler may not elide, then free it.  */
static void
cmacs_whisper__wipe_free (float *p, size_t n)
{
  if (!p)
    return;
  memset_explicit (p, 0, n * sizeof (float));
  g_free (p);
}

static void
cmacs_whisper__vad_job_free (CmacsWhisperVadJob *j)
{
  cmacs_whisper__wipe_free (j->samples, j->n_samples);
  g_free (j->probs);
  g_free (j->error_msg);
  g_free (j);
}

/* cmacs_whisper__vad_main_completion:
 * @user: (transfer full): the finished CmacsWhisperVadJob.
 *
 * Main-thread half of a FEED: build the result alist and hand it to
 * the registered Lisp callback.
 *
 * Result: `((:probs . [P0 P1 ...]) (:window . 512))', one probability
 * in [0, 1] per 512-sample window, or `((:error . MESSAGE))'.  */
static gboolean
cmacs_whisper__vad_main_completion (gpointer user)
{
  CmacsWhisperVadJob *j = user;
  Lisp_Object res;

  if (j->error_msg)
    res = list1 (Fcons (intern (":error"), build_string (j->error_msg)));
  else
    {
      Lisp_Object v = make_nil_vector (j->n_probs);
      for (int i = 0; i < j->n_probs; i++)
        ASET (v, i, make_float ((double) j->probs[i]));
      res = list2 (Fcons (intern (":probs"), v),
                   Fcons (intern (":window"),
                          make_fixnum (CMACS_WHISPER_VAD_WINDOW)));
    }
  cmacs_dispatch_callback_invoke1 (j->cb_cookie, res);
  cmacs_whisper__vad_job_free (j);
  return G_SOURCE_REMOVE;
}

/* cmacs_whisper__vad_load:
 * @v: the stream, on the worker thread.
 *
 * Load @v's model once.  A failure is remembered, so a missing or
 * corrupt model costs one attempt rather than one per feed.
 *
 * Returns: TRUE when @v->vctx is usable.  */
static gboolean
cmacs_whisper__vad_load (CmacsWhisperVad *v)
{
  if (v->vctx)
    return TRUE;
  if (v->load_error)
    return FALSE;

  struct whisper_vad_context_params cp = whisper_vad_default_context_params ();
  cp.n_threads = v->n_threads > 0 ? v->n_threads : 1;
  cp.use_gpu   = false;
  v->vctx = whisper_vad_init_from_file_with_params (v->model_path, cp);
  if (!v->vctx)
    v->load_error = g_strdup_printf ("cmacs-whisper: failed to load VAD "
                                     "model: %s", v->model_path);
  return v->vctx != NULL;
}

/* cmacs_whisper__vad_worker:
 * @data: (transfer full): a CmacsWhisperVadJob.
 * @user: unused.
 *
 * The single VAD worker.  FEED posts its job to the main thread;
 * RESET and CLOSE finish here.  */
static void
cmacs_whisper__vad_worker (gpointer data, gpointer user)
{
  CmacsWhisperVadJob *j = data;
  CmacsWhisperVad *v = j->vad;

  (void) user;
  switch (j->op)
    {
    case CMACS_WHISPER_VAD_OP_FEED:
      if (j->n_samples == 0)
        j->n_probs = 0;
      else if (!cmacs_whisper__vad_load (v))
        j->error_msg = g_strdup (v->load_error);
      else if (!whisper_vad_detect_speech_no_reset (v->vctx, j->samples,
                                                    (int) j->n_samples))
        j->error_msg = g_strdup ("cmacs-whisper: VAD inference failed");
      else
        {
          int n = whisper_vad_n_probs (v->vctx);
          const float *p = whisper_vad_probs (v->vctx);
          j->n_probs = n > 0 ? n : 0;
          j->probs = g_new0 (float, j->n_probs > 0 ? j->n_probs : 1);
          if (p && n > 0)
            memcpy (j->probs, p, (size_t) n * sizeof (float));
        }
      /* Done with the audio before the round-trip to the main thread. */
      cmacs_whisper__wipe_free (j->samples, j->n_samples);
      j->samples = NULL;
      g_main_context_invoke (cmacs_glib_get_context (),
                             cmacs_whisper__vad_main_completion, j);
      return;

    case CMACS_WHISPER_VAD_OP_RESET:
      if (v->vctx)
        whisper_vad_reset_state (v->vctx);
      break;

    case CMACS_WHISPER_VAD_OP_CLOSE:
      if (v->vctx)
        whisper_vad_free (v->vctx);
      g_free (v->model_path);
      g_free (v->load_error);
      g_free (v);
      j->vad = NULL;
      break;

    default:
      break;
    }
  cmacs_whisper__vad_job_free (j);
}

/* cmacs_whisper__vad_push:
 * @j: (transfer full): the job to queue.
 *
 * Queue @j on the VAD worker.  On the (practically impossible) failure
 * to queue, a FEED still answers its callback, with an error, so the
 * cookie's GC root is released.  */
static void
cmacs_whisper__vad_push (CmacsWhisperVadJob *j)
{
  GError *err = NULL;

  if (g_thread_pool_push (vad_pool, j, &err))
    return;
  if (j->op == CMACS_WHISPER_VAD_OP_FEED)
    {
      j->error_msg = g_strdup_printf ("cmacs-whisper: VAD queue: %s",
                                      err ? err->message : "push failed");
      cmacs_whisper__vad_main_completion (j);
    }
  else
    cmacs_whisper__vad_job_free (j);
  if (err)
    g_error_free (err);
}

/* cmacs_whisper_vad_open:
 * @model_path: the Silero ggml model file (already file-name encoded).
 * @n_threads: inference threads; <= 0 means 1.
 *
 * Create a streaming VAD.  Main thread only.  The model is loaded by
 * the worker on the first feed.
 *
 * Returns: the new handle, or 0 if the worker could not be started.  */
uint64_t
cmacs_whisper_vad_open (const char *model_path, int n_threads)
{
  if (!vad_pool)
    {
      GError *err = NULL;
      vad_pool = g_thread_pool_new (cmacs_whisper__vad_worker, NULL,
                                    1, FALSE, &err);
      if (!vad_pool)
        {
          if (err)
            g_error_free (err);
          return 0;
        }
      vad_streams = g_hash_table_new (g_int64_hash, g_int64_equal);
    }

  CmacsWhisperVad *v = g_new0 (CmacsWhisperVad, 1);
  v->handle     = vad_next_handle++;
  v->model_path = g_strdup (model_path);
  v->n_threads  = n_threads;
  g_hash_table_insert (vad_streams, &v->handle, v);
  return v->handle;
}

static CmacsWhisperVad *
cmacs_whisper__vad_lookup (uint64_t handle)
{
  if (!vad_streams)
    return NULL;
  return g_hash_table_lookup (vad_streams, &handle);
}

/* cmacs_whisper_vad_feed:
 * @handle: a handle from cmacs_whisper_vad_open().
 * @pcm: S16LE mono 16 kHz samples (copied before return).
 * @n_samples: sample count.  Whole multiples of
 *   CMACS_WHISPER_VAD_WINDOW keep the windows aligned across calls; a
 *   ragged tail is zero-padded by whisper.cpp.
 * @callback: Lisp function called on the main thread with the result.
 *
 * Returns: FALSE when @handle is unknown (nothing was queued).  */
gboolean
cmacs_whisper_vad_feed (uint64_t handle, const int16_t *pcm,
                        size_t n_samples, Lisp_Object callback)
{
  CmacsWhisperVad *v = cmacs_whisper__vad_lookup (handle);
  if (!v)
    return FALSE;

  CmacsWhisperVadJob *j = g_new0 (CmacsWhisperVadJob, 1);
  j->op        = CMACS_WHISPER_VAD_OP_FEED;
  j->vad       = v;
  j->samples   = n_samples ? s16_to_f32 (pcm, n_samples) : NULL;
  j->n_samples = n_samples;
  j->cb_cookie = cmacs_dispatch_callback_register (callback);
  cmacs_whisper__vad_push (j);
  return TRUE;
}

/* cmacs_whisper_vad_reset:
 * @handle: a VAD handle.
 *
 * Queue a reset of the model's recurrent state, ordered after every
 * feed already queued.
 *
 * Returns: FALSE when @handle is unknown.  */
gboolean
cmacs_whisper_vad_reset (uint64_t handle)
{
  CmacsWhisperVad *v = cmacs_whisper__vad_lookup (handle);
  if (!v)
    return FALSE;
  CmacsWhisperVadJob *j = g_new0 (CmacsWhisperVadJob, 1);
  j->op  = CMACS_WHISPER_VAD_OP_RESET;
  j->vad = v;
  cmacs_whisper__vad_push (j);
  return TRUE;
}

/* cmacs_whisper_vad_close:
 * @handle: a VAD handle.
 *
 * Forget @handle and queue the release of its model.  Feeds already
 * queued still answer their callbacks.
 *
 * Returns: FALSE when @handle is unknown.  */
gboolean
cmacs_whisper_vad_close (uint64_t handle)
{
  CmacsWhisperVad *v = cmacs_whisper__vad_lookup (handle);
  if (!v)
    return FALSE;
  g_hash_table_remove (vad_streams, &handle);
  CmacsWhisperVadJob *j = g_new0 (CmacsWhisperVadJob, 1);
  j->op  = CMACS_WHISPER_VAD_OP_CLOSE;
  j->vad = v;
  cmacs_whisper__vad_push (j);
  return TRUE;
}

/* cmacs_whisper_vad_list:
 *
 * Returns: a Lisp list of the open VAD handles.  Main thread only.  */
Lisp_Object
cmacs_whisper_vad_list (void)
{
  Lisp_Object out = Qnil;
  GHashTableIter it;
  gpointer key, val;

  if (!vad_streams)
    return Qnil;
  g_hash_table_iter_init (&it, vad_streams);
  while (g_hash_table_iter_next (&it, &key, &val))
    out = Fcons (make_int ((EMACS_INT) ((CmacsWhisperVad *) val)->handle),
                 out);
  return out;
}

#endif /* HAVE_CMACS_WHISPER */
