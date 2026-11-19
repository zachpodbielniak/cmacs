/* cmacs-sherpa-tts.c --- in-process text to speech
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * One kind, tts, covering every sherpa-onnx TTS family (VITS -- which
 * includes every Piper voice --, Kokoro, Matcha, Kitten, ZipVoice, ...).
 *
 * Audio is streamed: sherpa calls back per generated sentence, and each
 * call is posted to the main context as a chunk {pcm, sample-rate,
 * progress}, so playback starts after the first sentence instead of
 * after the whole paragraph.  Cancelling the job makes the next
 * callback return 0, which stops generation inside sherpa.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <string.h>

/* Per-job keys that are ours, not GenerationConfig fields.  */
static const char *const generation_extra[] = { "collect", "espeak-voice",
                                                NULL };

/* The espeak-ng data directory when this voice needs its text
   phonemized for it: an espeak-backed family (VITS/Piper, Kokoro,
   Matcha) with espeak data and no lexicon to look words up in.
   sherpa-onnx 2.0 dropped its built-in espeak frontend, so for these
   the caller supplies phonemes; NULL when sherpa can tokenize alone.  */
static const char *
espeak_data_dir (CmacsSherpaHandle *h)
{
  const SherpaOnnxOfflineTtsConfig *c = h->cstruct;
  /* cmacs's own key: sherpa 2.0 deprecates and ignores *.data-dir.  */
  const char *own = g_hash_table_lookup (h->config, "espeak-data-dir");
  if (own && *own)
    return own;
  if (c->model.vits.data_dir && *c->model.vits.data_dir
      && !(c->model.vits.lexicon && *c->model.vits.lexicon))
    return c->model.vits.data_dir;
  if (c->model.kokoro.data_dir && *c->model.kokoro.data_dir
      && !(c->model.kokoro.lexicon && *c->model.kokoro.lexicon))
    return c->model.kokoro.data_dir;
  if (c->model.matcha.data_dir && *c->model.matcha.data_dir
      && !(c->model.matcha.lexicon && *c->model.matcha.lexicon))
    return c->model.matcha.data_dir;
  return NULL;
}

static gpointer
tts_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflineTtsConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    {
      int n = (int) g_get_num_processors () / 2;
      c->model.num_threads = CLAMP (n, 1, 4);
    }
  return (gpointer) SherpaOnnxCreateOfflineTts (c);
}

static void
tts_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflineTts (obj);
}

/* Runs on the worker inside sherpa's generation loop.  */
static int32_t
tts_progress (const float *samples, int32_t n, float p, void *arg)
{
  CmacsSherpaJob *job = arg;
  if (g_atomic_int_get (&job->cancelled)
      || g_atomic_int_get (&job->handle->closed))
    return 0;                   /* stop generating */
  if (job->chunk && n > 0)
    {
      GVariantDict d;
      g_variant_dict_init (&d, NULL);
      g_variant_dict_insert_value (&d, "pcm",
                                   cmacs_sherpa_variant_pcm (samples,
                                                             (gsize) n));
      g_variant_dict_insert (&d, "sample-rate", "i",
                             SherpaOnnxOfflineTtsSampleRate
                             (job->handle->obj));
      g_variant_dict_insert (&d, "progress", "d", (double) p);
      cmacs_sherpa_job_post_chunk (job, g_variant_dict_end (&d));
    }
  return 1;
}

static GVariant *
tts_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxOfflineTts *tts = job->handle->obj;
  SherpaOnnxGenerationConfig gc;
  const SherpaOnnxGeneratedAudio *a;
  gboolean collect = cmacs_sherpa_param_bool (job->params, "collect", TRUE);
  GVariantDict d;

  if (!job->text || !*job->text)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "nothing to say");
      return NULL;
    }

  memset (&gc, 0, sizeof gc);
  /* sherpa's own defaults; the per-job params override them.  */
  gc.speed = 1.0f;
  gc.silence_scale = 0.2f;
  if (!cmacs_sherpa_config_fill (CMACS_SHERPA_T_GENERATION, &gc, job->params,
                                 generation_extra, error))
    return NULL;
  if (gc.speed <= 0.0f)
    gc.speed = 1.0f;

  /* Phonemes, for the voices that need them handed in.  */
  {
    const char *data_dir = espeak_data_dir (job->handle);
    g_autoptr (GArray) cps = g_array_new (FALSE, FALSE, sizeof (gint32));
    g_autoptr (GArray) lens = g_array_new (FALSE, FALSE, sizeof (gint32));
    if (data_dir)
      {
        const char *voice = cmacs_sherpa_param (job->params, "espeak-voice");
        const char *lang = voice ? NULL : SherpaOnnxOfflineTtsLang (tts);
        gboolean ok = cmacs_sherpa_phonemize (data_dir,
                                              voice ? voice
                                              : (lang && *lang ? lang
                                                 : "en-us"),
                                              job->text, cps, lens, error);
        if (lang)
          SherpaOnnxDestroyOfflineTtsLang (lang);
        if (!ok)
          return NULL;
        gc.phoneme_codepoints = (const int32_t *) (void *) cps->data;
        gc.phoneme_codepoints_lens = (const int32_t *) (void *) lens->data;
        gc.phoneme_codepoints_num_sentences = (int32_t) lens->len;
      }
    a = SherpaOnnxOfflineTtsGenerateWithConfig (tts, job->text, &gc,
                                                tts_progress, job);
  }
  if (!a)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "speech generation failed");
      return NULL;
    }

  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i", a->sample_rate);
  g_variant_dict_insert (&d, "samples", "x", (gint64) a->n);
  g_variant_dict_insert (&d, "duration", "x",
                         a->sample_rate
                         ? (gint64) a->n * 1000 / a->sample_rate : 0);
  if (collect)
    g_variant_dict_insert_value (&d, "pcm",
                                 cmacs_sherpa_variant_pcm (a->samples,
                                                           (gsize) a->n));
  SherpaOnnxDestroyOfflineTtsGeneratedAudio (a);
  return g_variant_dict_end (&d);
}

static GVariant *
tts_info (CmacsSherpaHandle *h)
{
  GVariantDict d;
  const char *lang = SherpaOnnxOfflineTtsLang (h->obj);
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i",
                         SherpaOnnxOfflineTtsSampleRate (h->obj));
  g_variant_dict_insert (&d, "num-speakers", "i",
                         SherpaOnnxOfflineTtsNumSpeakers (h->obj));
  if (lang)
    {
      if (*lang)
        g_variant_dict_insert (&d, "lang", "s", lang);
      SherpaOnnxDestroyOfflineTtsLang (lang);
    }
  return g_variant_dict_end (&d);
}

/* Handle config keys that are cmacs's, not sherpa's.  */
static const char *const tts_extra[] = { "espeak-data-dir", NULL };

const CmacsSherpaKindClass cmacs_sherpa_class_tts = {
  .name = "tts",
  .table = CMACS_SHERPA_T_TTS,
  .struct_size = sizeof (SherpaOnnxOfflineTtsConfig),
  .extra_keys = tts_extra,
  .create = tts_create,
  .destroy = tts_destroy,
  .run = tts_run,
  .info = tts_info,
};

#endif /* HAVE_CMACS_SHERPA */
