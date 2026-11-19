/* cmacs-sherpa-audio.c --- VAD, speech enhancement, source separation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Kinds that take audio and give back either a speech/no-speech signal
 * (vad) or audio (denoise, denoise-stream, separate).
 *
 * The vad result carries a per-window speech flag in `probs', the same
 * key and shape cmacs-whisper's Silero VAD uses, so cmacs-voice's
 * detector can switch engines without changing its frame logic.  sherpa
 * does not expose the raw probability, only its thresholded decision,
 * so the values are 0.0 or 1.0.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <string.h>

/* --- vad --- */

typedef struct
{
  const SherpaOnnxVoiceActivityDetector *vad;
  int                                    window;  /* samples */
  int                                    rate;
  GArray                                *rest;    /* float, < window */
  gint64                                 fed;     /* samples */
} Vad;

static const char *const vad_extra[] = { "buffer-size-in-seconds", NULL };

static gpointer
vad_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxVadModelConfig *c = h->cstruct;
  const char *buf = g_hash_table_lookup (h->config, "buffer-size-in-seconds");
  float buffer_s = buf ? (float) g_ascii_strtod (buf, NULL) : 60.0f;
  Vad *v;

  (void) error;
  if (c->sample_rate <= 0)
    c->sample_rate = 16000;
  if (c->num_threads <= 0)
    c->num_threads = 1;
  v = g_new0 (Vad, 1);
  v->rate = c->sample_rate;
  /* The window the model steps by: Silero's default is 512 samples
     (32 ms at 16 kHz), TEN-VAD's 256.  */
  if (c->ten_vad.model && *c->ten_vad.model)
    v->window = c->ten_vad.window_size > 0 ? c->ten_vad.window_size : 256;
  else
    v->window = c->silero_vad.window_size > 0 ? c->silero_vad.window_size
                                              : 512;
  v->vad = SherpaOnnxCreateVoiceActivityDetector (c, buffer_s > 1.0f
                                                  ? buffer_s : 60.0f);
  if (!v->vad)
    {
      g_free (v);
      return NULL;
    }
  v->rest = g_array_new (FALSE, FALSE, sizeof (float));
  return v;
}

static void
vad_destroy (gpointer obj)
{
  Vad *v = obj;
  SherpaOnnxDestroyVoiceActivityDetector (v->vad);
  if (v->rest->len)
    memset_explicit (v->rest->data, 0, v->rest->len * sizeof (float));
  g_array_free (v->rest, TRUE);
  g_free (v);
}

/* Pop every completed speech segment into B.  */
static void
vad_drain (Vad *v, GVariantBuilder *b, gboolean with_pcm)
{
  while (!SherpaOnnxVoiceActivityDetectorEmpty (v->vad))
    {
      const SherpaOnnxSpeechSegment *seg
        = SherpaOnnxVoiceActivityDetectorFront (v->vad);
      GVariantDict d;
      g_variant_dict_init (&d, NULL);
      g_variant_dict_insert (&d, "start", "x", seg->start * 1000 / v->rate);
      g_variant_dict_insert (&d, "end", "x",
                             (seg->start + seg->n) * 1000 / v->rate);
      if (with_pcm)
        g_variant_dict_insert_value (&d, "pcm",
                                     cmacs_sherpa_variant_pcm (seg->samples,
                                                               (gsize) seg->n));
      g_variant_builder_add_value (b, g_variant_dict_end (&d));
      SherpaOnnxDestroySpeechSegment (seg);
      SherpaOnnxVoiceActivityDetectorPop (v->vad);
    }
}

static GVariant *
vad_run (CmacsSherpaJob *job, GError **error)
{
  Vad *v = job->handle->obj;
  gboolean with_pcm = cmacs_sherpa_param_bool (job->params, "segment-pcm",
                                               FALSE);
  GVariantBuilder probs, segs;
  GVariantDict d;

  (void) error;
  g_variant_builder_init (&probs, G_VARIANT_TYPE ("ad"));
  g_variant_builder_init (&segs, G_VARIANT_TYPE ("aa{sv}"));

  switch (job->op)
    {
    case CMACS_SHERPA_OP_RESET:
      SherpaOnnxVoiceActivityDetectorReset (v->vad);
      g_array_set_size (v->rest, 0);
      break;

    case CMACS_SHERPA_OP_FINISH:
      SherpaOnnxVoiceActivityDetectorFlush (v->vad);
      vad_drain (v, &segs, with_pcm);
      break;

    case CMACS_SHERPA_OP_FEED:
    default:
      if (job->samples)
        g_array_append_vals (v->rest, job->samples, (guint) job->n_samples);
      /* Step exactly one model window at a time so every window gets
         its own decision; carry the remainder to the next feed.  */
      {
        guint off = 0;
        while (v->rest->len - off >= (guint) v->window)
          {
            float *w = &g_array_index (v->rest, float, off);
            SherpaOnnxVoiceActivityDetectorAcceptWaveform (v->vad, w,
                                                           v->window);
            g_variant_builder_add (&probs, "d",
                                   SherpaOnnxVoiceActivityDetectorDetected
                                   (v->vad) ? 1.0 : 0.0);
            off += (guint) v->window;
            v->fed += v->window;
          }
        if (off)
          {
            memset_explicit (v->rest->data, 0, off * sizeof (float));
            g_array_remove_range (v->rest, 0, off);
          }
      }
      vad_drain (v, &segs, with_pcm);
      break;
    }

  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "probs", g_variant_builder_end (&probs));
  g_variant_dict_insert (&d, "window", "i", v->window);
  g_variant_dict_insert_value (&d, "segments", g_variant_builder_end (&segs));
  g_variant_dict_insert (&d, "speaking", "b",
                         SherpaOnnxVoiceActivityDetectorDetected (v->vad) != 0);
  g_variant_dict_insert (&d, "time", "x", v->fed * 1000 / v->rate);
  return g_variant_dict_end (&d);
}

static GVariant *
vad_info (CmacsSherpaHandle *h)
{
  Vad *v = h->obj;
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "window", "i", v->window);
  g_variant_dict_insert (&d, "sample-rate", "i", v->rate);
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_vad = {
  .name = "vad",
  .table = CMACS_SHERPA_T_VAD,
  .struct_size = sizeof (SherpaOnnxVadModelConfig),
  .extra_keys = vad_extra,
  .create = vad_create,
  .destroy = vad_destroy,
  .run = vad_run,
  .info = vad_info,
};

/* --- shared: audio result --- */

static GVariant *
audio_result (const float *samples, gsize n, int rate)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "pcm", cmacs_sherpa_variant_pcm (samples,
                                                                    n));
  g_variant_dict_insert (&d, "sample-rate", "i", rate);
  return g_variant_dict_end (&d);
}

static GVariant *
rate_info (int rate)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i", rate);
  return g_variant_dict_end (&d);
}

/* --- denoise (offline) --- */

static gpointer
denoise_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflineSpeechDenoiserConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = 2;
  return (gpointer) SherpaOnnxCreateOfflineSpeechDenoiser (c);
}

static void
denoise_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflineSpeechDenoiser (obj);
}

static GVariant *
denoise_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxDenoisedAudio *a;
  GVariant *r;

  if (!job->samples || !job->n_samples)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "no audio to denoise");
      return NULL;
    }
  a = SherpaOnnxOfflineSpeechDenoiserRun (job->handle->obj, job->samples,
                                          (int32_t) job->n_samples,
                                          job->sample_rate);
  if (!a)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "denoising failed");
      return NULL;
    }
  r = audio_result (a->samples, (gsize) a->n, a->sample_rate);
  SherpaOnnxDestroyDenoisedAudio (a);
  return r;
}

static GVariant *
denoise_info (CmacsSherpaHandle *h)
{
  return rate_info (SherpaOnnxOfflineSpeechDenoiserGetSampleRate (h->obj));
}

const CmacsSherpaKindClass cmacs_sherpa_class_denoise = {
  .name = "denoise",
  .table = CMACS_SHERPA_T_OFFLINE_DENOISER,
  .struct_size = sizeof (SherpaOnnxOfflineSpeechDenoiserConfig),
  .create = denoise_create,
  .destroy = denoise_destroy,
  .run = denoise_run,
  .info = denoise_info,
};

/* --- denoise-stream --- */

static gpointer
denoise_stream_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOnlineSpeechDenoiserConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = 1;
  return (gpointer) SherpaOnnxCreateOnlineSpeechDenoiser (c);
}

static void
denoise_stream_destroy (gpointer obj)
{
  SherpaOnnxDestroyOnlineSpeechDenoiser (obj);
}

static GVariant *
denoise_stream_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxOnlineSpeechDenoiser *dn = job->handle->obj;
  const SherpaOnnxDenoisedAudio *a = NULL;
  GVariant *r;

  (void) error;
  switch (job->op)
    {
    case CMACS_SHERPA_OP_RESET:
      SherpaOnnxOnlineSpeechDenoiserReset (dn);
      return audio_result (NULL, 0,
                           SherpaOnnxOnlineSpeechDenoiserGetSampleRate (dn));
    case CMACS_SHERPA_OP_FINISH:
      a = SherpaOnnxOnlineSpeechDenoiserFlush (dn);
      break;
    case CMACS_SHERPA_OP_FEED:
    default:
      if (!job->samples || !job->n_samples)
        return audio_result (NULL, 0,
                             SherpaOnnxOnlineSpeechDenoiserGetSampleRate (dn));
      a = SherpaOnnxOnlineSpeechDenoiserRun (dn, job->samples,
                                             (int32_t) job->n_samples,
                                             job->sample_rate);
      break;
    }
  if (!a)
    return audio_result (NULL, 0,
                         SherpaOnnxOnlineSpeechDenoiserGetSampleRate (dn));
  r = audio_result (a->samples, (gsize) a->n, a->sample_rate);
  SherpaOnnxDestroyDenoisedAudio (a);
  return r;
}

static GVariant *
denoise_stream_info (CmacsSherpaHandle *h)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i",
                         SherpaOnnxOnlineSpeechDenoiserGetSampleRate (h->obj));
  g_variant_dict_insert (&d, "frame-shift", "i",
                         SherpaOnnxOnlineSpeechDenoiserGetFrameShiftInSamples
                         (h->obj));
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_denoise_stream = {
  .name = "denoise-stream",
  .table = CMACS_SHERPA_T_ONLINE_DENOISER,
  .struct_size = sizeof (SherpaOnnxOnlineSpeechDenoiserConfig),
  .create = denoise_stream_create,
  .destroy = denoise_stream_destroy,
  .run = denoise_stream_run,
  .info = denoise_stream_info,
};

/* --- separate --- */

static gpointer
separate_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflineSourceSeparationConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = 2;
  return (gpointer) SherpaOnnxCreateOfflineSourceSeparation (c);
}

static void
separate_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflineSourceSeparation (obj);
}

static GVariant *
separate_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxSourceSeparationOutput *o;
  /* The models are stereo; mono input is presented as two identical
     channels, and each stem is mixed back down to mono.  */
  int channels = cmacs_sherpa_param_int (job->params, "channels", 2);
  const float *chans[8];
  GVariantBuilder stems;
  GVariantDict d;

  if (!job->samples || !job->n_samples)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "no audio to separate");
      return NULL;
    }
  channels = CLAMP (channels, 1, 8);
  for (int c = 0; c < channels; c++)
    chans[c] = job->samples;
  o = SherpaOnnxOfflineSourceSeparationProcess (job->handle->obj, chans,
                                                channels,
                                                (int32_t) job->n_samples,
                                                job->sample_rate);
  if (!o)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "separation failed");
      return NULL;
    }

  g_variant_builder_init (&stems, G_VARIANT_TYPE ("aa{sv}"));
  for (int s = 0; s < o->num_stems; s++)
    {
      const SherpaOnnxSourceSeparationStem *st = &o->stems[s];
      g_autofree float *mono = g_new0 (float, st->n ? st->n : 1);
      GVariantDict sd;
      for (int c = 0; c < st->num_channels; c++)
        for (int i = 0; i < st->n; i++)
          mono[i] += st->samples[c][i] / (float) st->num_channels;
      g_variant_dict_init (&sd, NULL);
      g_variant_dict_insert (&sd, "index", "i", s);
      g_variant_dict_insert_value (&sd, "pcm",
                                   cmacs_sherpa_variant_pcm (mono,
                                                             (gsize) st->n));
      g_variant_builder_add_value (&stems, g_variant_dict_end (&sd));
    }
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "stems", g_variant_builder_end (&stems));
  g_variant_dict_insert (&d, "sample-rate", "i", o->sample_rate);
  SherpaOnnxDestroySourceSeparationOutput (o);
  return g_variant_dict_end (&d);
}

static GVariant *
separate_info (CmacsSherpaHandle *h)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i",
                         SherpaOnnxOfflineSourceSeparationGetOutputSampleRate
                         (h->obj));
  g_variant_dict_insert (&d, "stems", "i",
                         SherpaOnnxOfflineSourceSeparationGetNumberOfStems
                         (h->obj));
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_separate = {
  .name = "separate",
  .table = CMACS_SHERPA_T_SOURCE_SEPARATION,
  .struct_size = sizeof (SherpaOnnxOfflineSourceSeparationConfig),
  .create = separate_create,
  .destroy = separate_destroy,
  .run = separate_run,
  .info = separate_info,
};

#endif /* HAVE_CMACS_SHERPA */
