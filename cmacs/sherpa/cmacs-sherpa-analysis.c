/* cmacs-sherpa-analysis.c --- who spoke, which language, what sound
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Kinds that analyse rather than transcribe or synthesise:
 *   diarize       speaker turns in a recording (pyannote + embeddings)
 *   speaker       embeddings, enrollment, identification, verification
 *   punct         add punctuation to unpunctuated text (offline)
 *   punct-online  same, with casing, for streaming output
 *   lid           spoken language identification
 *   tag           audio event tagging ("speech", "music", "dog", ...)
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <string.h>

static int
half_cores (void)
{
  int n = (int) g_get_num_processors () / 2;
  return CLAMP (n, 1, 4);
}

static gboolean
need_audio (CmacsSherpaJob *job, GError **error)
{
  if (job->samples && job->n_samples)
    return TRUE;
  g_set_error (error, CMACS_SHERPA_ERROR, 6, "no audio");
  return FALSE;
}

/* --- diarize --- */

static const char *const diarize_extra[] = { NULL };

static gpointer
diarize_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflineSpeakerDiarizationConfig *c = h->cstruct;
  (void) error;
  if (c->segmentation.num_threads <= 0)
    c->segmentation.num_threads = half_cores ();
  if (c->embedding.num_threads <= 0)
    c->embedding.num_threads = half_cores ();
  /* Unless told how many speakers, cluster by distance.  */
  if (c->clustering.num_clusters <= 0 && c->clustering.threshold <= 0.0f)
    c->clustering.threshold = 0.5f;
  return (gpointer) SherpaOnnxCreateOfflineSpeakerDiarization (c);
}

static void
diarize_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflineSpeakerDiarization (obj);
}

static int32_t
diarize_progress (int32_t done, int32_t total, void *arg)
{
  CmacsSherpaJob *job = arg;
  if (job->chunk && total > 0)
    {
      GVariantDict d;
      g_variant_dict_init (&d, NULL);
      g_variant_dict_insert (&d, "progress", "d", (double) done / total);
      cmacs_sherpa_job_post_chunk (job, g_variant_dict_end (&d));
    }
  return 0;
}

static GVariant *
diarize_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxOfflineSpeakerDiarization *sd = job->handle->obj;
  const SherpaOnnxOfflineSpeakerDiarizationResult *r;
  const SherpaOnnxOfflineSpeakerDiarizationSegment *segs;
  int rate = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate (sd);
  int nspk = cmacs_sherpa_param_int (job->params, "num-speakers", 0);
  double thr = cmacs_sherpa_param_double (job->params, "threshold", 0.0);
  GVariantBuilder b;
  GVariantDict d;
  int n;

  if (!need_audio (job, error))
    return NULL;
  if (job->sample_rate != rate)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6,
                   "diarization wants %d Hz audio, got %d Hz", rate,
                   job->sample_rate);
      return NULL;
    }

  /* A per-job speaker count or threshold overrides the handle's.  */
  if (nspk > 0 || thr > 0.0)
    {
      SherpaOnnxOfflineSpeakerDiarizationConfig c
        = *(SherpaOnnxOfflineSpeakerDiarizationConfig *) job->handle->cstruct;
      c.clustering.num_clusters = nspk > 0 ? nspk : -1;
      if (thr > 0.0)
        c.clustering.threshold = (float) thr;
      SherpaOnnxOfflineSpeakerDiarizationSetConfig (sd, &c);
    }

  r = SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback
        (sd, job->samples, (int32_t) job->n_samples, diarize_progress, job);

  if (nspk > 0 || thr > 0.0)
    SherpaOnnxOfflineSpeakerDiarizationSetConfig (sd, job->handle->cstruct);

  if (!r)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "diarization failed");
      return NULL;
    }

  n = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments (r);
  segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime (r);
  g_variant_builder_init (&b, G_VARIANT_TYPE ("aa{sv}"));
  for (int i = 0; segs && i < n; i++)
    {
      GVariantDict s;
      g_variant_dict_init (&s, NULL);
      g_variant_dict_insert (&s, "start", "x",
                             (gint64) (segs[i].start * 1000.0f));
      g_variant_dict_insert (&s, "end", "x", (gint64) (segs[i].end * 1000.0f));
      g_variant_dict_insert (&s, "speaker", "i", segs[i].speaker);
      if (segs[i].confidence > -1.5f)
        g_variant_dict_insert (&s, "confidence", "d",
                               (double) segs[i].confidence);
      g_variant_builder_add_value (&b, g_variant_dict_end (&s));
    }
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "segments", g_variant_builder_end (&b));
  g_variant_dict_insert (&d, "num-speakers", "i",
                         SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers
                         (r));
  if (segs)
    SherpaOnnxOfflineSpeakerDiarizationDestroySegment (segs);
  SherpaOnnxOfflineSpeakerDiarizationDestroyResult (r);
  return g_variant_dict_end (&d);
}

static GVariant *
diarize_info (CmacsSherpaHandle *h)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "sample-rate", "i",
                         SherpaOnnxOfflineSpeakerDiarizationGetSampleRate
                         (h->obj));
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_diarize = {
  .name = "diarize",
  .table = CMACS_SHERPA_T_DIARIZATION,
  .struct_size = sizeof (SherpaOnnxOfflineSpeakerDiarizationConfig),
  .extra_keys = diarize_extra,
  .create = diarize_create,
  .destroy = diarize_destroy,
  .run = diarize_run,
  .info = diarize_info,
};

/* --- speaker --- */

typedef struct
{
  const SherpaOnnxSpeakerEmbeddingExtractor *ex;
  const SherpaOnnxSpeakerEmbeddingManager   *mgr;
  int                                        dim;
} Speaker;

static gpointer
speaker_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxSpeakerEmbeddingExtractorConfig *c = h->cstruct;
  Speaker *s;

  (void) error;
  if (c->num_threads <= 0)
    c->num_threads = 1;
  s = g_new0 (Speaker, 1);
  s->ex = SherpaOnnxCreateSpeakerEmbeddingExtractor (c);
  if (!s->ex)
    {
      g_free (s);
      return NULL;
    }
  s->dim = SherpaOnnxSpeakerEmbeddingExtractorDim (s->ex);
  s->mgr = SherpaOnnxCreateSpeakerEmbeddingManager (s->dim);
  return s;
}

static void
speaker_destroy (gpointer obj)
{
  Speaker *s = obj;
  if (s->mgr)
    SherpaOnnxDestroySpeakerEmbeddingManager (s->mgr);
  SherpaOnnxDestroySpeakerEmbeddingExtractor (s->ex);
  g_free (s);
}

/* Embedding of the job's audio; free with
   SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding.  */
static const float *
speaker_embed (Speaker *s, CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxOnlineStream *st;
  const float *v = NULL;

  if (!need_audio (job, error))
    return NULL;
  st = SherpaOnnxSpeakerEmbeddingExtractorCreateStream (s->ex);
  SherpaOnnxOnlineStreamAcceptWaveform (st, job->sample_rate, job->samples,
                                        (int32_t) job->n_samples);
  SherpaOnnxOnlineStreamInputFinished (st);
  if (SherpaOnnxSpeakerEmbeddingExtractorIsReady (s->ex, st))
    v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding (s->ex, st);
  else
    g_set_error (error, CMACS_SHERPA_ERROR, 6,
                 "not enough speech for a speaker embedding");
  SherpaOnnxDestroyOnlineStream (st);
  return v;
}

static GVariant *
floats_variant (const float *v, int n)
{
  GVariantBuilder b;
  g_variant_builder_init (&b, G_VARIANT_TYPE ("ad"));
  for (int i = 0; i < n; i++)
    g_variant_builder_add (&b, "d", (double) v[i]);
  return g_variant_builder_end (&b);
}

static GVariant *
speaker_run (CmacsSherpaJob *job, GError **error)
{
  Speaker *s = job->handle->obj;
  const char *name = job->text;
  float thr = (float) cmacs_sherpa_param_double (job->params, "threshold",
                                                 0.5);
  const float *v = NULL;
  GVariantDict d;

  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "dim", "i", s->dim);

  if ((job->op == CMACS_SHERPA_OP_ENROLL
       || job->op == CMACS_SHERPA_OP_ADD_EMBEDDING
       || job->op == CMACS_SHERPA_OP_VERIFY
       || job->op == CMACS_SHERPA_OP_REMOVE)
      && (!name || !*name))
    {
      g_variant_dict_clear (&d);
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "a speaker name is needed");
      return NULL;
    }

  switch (job->op)
    {
    case CMACS_SHERPA_OP_LIST:
      {
        const char *const *all = SherpaOnnxSpeakerEmbeddingManagerGetAllSpeakers
                                   (s->mgr);
        GVariantBuilder b;
        g_variant_builder_init (&b, G_VARIANT_TYPE ("as"));
        for (int i = 0; all && all[i]; i++)
          g_variant_builder_add (&b, "s", all[i]);
        if (all)
          SherpaOnnxSpeakerEmbeddingManagerFreeAllSpeakers (all);
        g_variant_dict_insert_value (&d, "speakers", g_variant_builder_end (&b));
      }
      break;

    case CMACS_SHERPA_OP_REMOVE:
      g_variant_dict_insert (&d, "removed", "b",
                             SherpaOnnxSpeakerEmbeddingManagerRemove (s->mgr,
                                                                      name)
                             != 0);
      break;

    case CMACS_SHERPA_OP_ADD_EMBEDDING:
      if ((int) job->n_samples != s->dim)
        {
          g_variant_dict_clear (&d);
          g_set_error (error, CMACS_SHERPA_ERROR, 6,
                       "embedding has %d values; this model's have %d",
                       (int) job->n_samples, s->dim);
          return NULL;
        }
      if (SherpaOnnxSpeakerEmbeddingManagerContains (s->mgr, name))
        SherpaOnnxSpeakerEmbeddingManagerRemove (s->mgr, name);
      g_variant_dict_insert (&d, "added", "b",
                             SherpaOnnxSpeakerEmbeddingManagerAdd
                             (s->mgr, name, job->samples) != 0);
      g_variant_dict_insert (&d, "name", "s", name);
      break;

    case CMACS_SHERPA_OP_ENROLL:
    case CMACS_SHERPA_OP_IDENTIFY:
    case CMACS_SHERPA_OP_VERIFY:
    case CMACS_SHERPA_OP_RUN:
    default:
      v = speaker_embed (s, job, error);
      if (!v)
        {
          g_variant_dict_clear (&d);
          return NULL;
        }
      if (job->op == CMACS_SHERPA_OP_ENROLL)
        {
          if (SherpaOnnxSpeakerEmbeddingManagerContains (s->mgr, name))
            SherpaOnnxSpeakerEmbeddingManagerRemove (s->mgr, name);
          g_variant_dict_insert (&d, "added", "b",
                                 SherpaOnnxSpeakerEmbeddingManagerAdd
                                 (s->mgr, name, v) != 0);
          g_variant_dict_insert (&d, "name", "s", name);
          /* Hand the vector back so Lisp can persist the enrollment.  */
          g_variant_dict_insert_value (&d, "embedding",
                                       floats_variant (v, s->dim));
        }
      else if (job->op == CMACS_SHERPA_OP_IDENTIFY)
        {
          int n = cmacs_sherpa_param_int (job->params, "n", 3);
          const SherpaOnnxSpeakerEmbeddingManagerBestMatchesResult *m
            = SherpaOnnxSpeakerEmbeddingManagerGetBestMatches (s->mgr, v, thr,
                                                               n > 0 ? n : 3);
          GVariantBuilder b;
          g_variant_builder_init (&b, G_VARIANT_TYPE ("aa{sv}"));
          for (int i = 0; m && i < m->count; i++)
            {
              GVariantDict md;
              g_variant_dict_init (&md, NULL);
              g_variant_dict_insert (&md, "name", "s", m->matches[i].name);
              g_variant_dict_insert (&md, "score", "d",
                                     (double) m->matches[i].score);
              g_variant_builder_add_value (&b, g_variant_dict_end (&md));
            }
          if (m)
            SherpaOnnxSpeakerEmbeddingManagerFreeBestMatches (m);
          g_variant_dict_insert_value (&d, "matches",
                                       g_variant_builder_end (&b));
        }
      else if (job->op == CMACS_SHERPA_OP_VERIFY)
        g_variant_dict_insert (&d, "match", "b",
                               SherpaOnnxSpeakerEmbeddingManagerVerify
                               (s->mgr, name, v, thr) != 0);
      else
        g_variant_dict_insert_value (&d, "embedding",
                                     floats_variant (v, s->dim));
      SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding (v);
      break;
    }
  return g_variant_dict_end (&d);
}

static GVariant *
speaker_info (CmacsSherpaHandle *h)
{
  Speaker *s = h->obj;
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "dim", "i", s->dim);
  g_variant_dict_insert (&d, "num-speakers", "i",
                         SherpaOnnxSpeakerEmbeddingManagerNumSpeakers (s->mgr));
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_speaker = {
  .name = "speaker",
  .table = CMACS_SHERPA_T_SPEAKER_EMBEDDING,
  .struct_size = sizeof (SherpaOnnxSpeakerEmbeddingExtractorConfig),
  .create = speaker_create,
  .destroy = speaker_destroy,
  .run = speaker_run,
  .info = speaker_info,
};

/* --- punct (offline) --- */

static gpointer
punct_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflinePunctuationConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = 1;
  return (gpointer) SherpaOnnxCreateOfflinePunctuation (c);
}

static void
punct_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflinePunctuation (obj);
}

static GVariant *
text_result (const char *text)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "text", "s", text ? text : "");
  return g_variant_dict_end (&d);
}

static GVariant *
punct_run (CmacsSherpaJob *job, GError **error)
{
  const char *out;
  GVariant *r;
  (void) error;
  if (!job->text || !*job->text)
    return text_result ("");
  out = SherpaOfflinePunctuationAddPunct (job->handle->obj, job->text);
  r = text_result (out);
  if (out)
    SherpaOfflinePunctuationFreeText (out);
  return r;
}

const CmacsSherpaKindClass cmacs_sherpa_class_punct = {
  .name = "punct",
  .table = CMACS_SHERPA_T_OFFLINE_PUNCT,
  .struct_size = sizeof (SherpaOnnxOfflinePunctuationConfig),
  .create = punct_create,
  .destroy = punct_destroy,
  .run = punct_run,
};

/* --- punct-online --- */

static gpointer
punct_online_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOnlinePunctuationConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = 1;
  return (gpointer) SherpaOnnxCreateOnlinePunctuation (c);
}

static void
punct_online_destroy (gpointer obj)
{
  SherpaOnnxDestroyOnlinePunctuation (obj);
}

static GVariant *
punct_online_run (CmacsSherpaJob *job, GError **error)
{
  const char *out;
  GVariant *r;
  (void) error;
  if (!job->text || !*job->text)
    return text_result ("");
  out = SherpaOnnxOnlinePunctuationAddPunct (job->handle->obj, job->text);
  r = text_result (out);
  if (out)
    SherpaOnnxOnlinePunctuationFreeText (out);
  return r;
}

const CmacsSherpaKindClass cmacs_sherpa_class_punct_online = {
  .name = "punct-online",
  .table = CMACS_SHERPA_T_ONLINE_PUNCT,
  .struct_size = sizeof (SherpaOnnxOnlinePunctuationConfig),
  .create = punct_online_create,
  .destroy = punct_online_destroy,
  .run = punct_online_run,
};

/* --- lid --- */

static gpointer
lid_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxSpokenLanguageIdentificationConfig *c = h->cstruct;
  (void) error;
  if (c->num_threads <= 0)
    c->num_threads = half_cores ();
  return (gpointer) SherpaOnnxCreateSpokenLanguageIdentification (c);
}

static void
lid_destroy (gpointer obj)
{
  SherpaOnnxDestroySpokenLanguageIdentification (obj);
}

static GVariant *
lid_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxSpokenLanguageIdentification *lid = job->handle->obj;
  SherpaOnnxOfflineStream *st;
  const SherpaOnnxSpokenLanguageIdentificationResult *r;
  GVariantDict d;

  if (!need_audio (job, error))
    return NULL;
  st = SherpaOnnxSpokenLanguageIdentificationCreateOfflineStream (lid);
  SherpaOnnxAcceptWaveformOffline (st, job->sample_rate, job->samples,
                                   (int32_t) job->n_samples);
  r = SherpaOnnxSpokenLanguageIdentificationCompute (lid, st);
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "lang", "s", r && r->lang ? r->lang : "");
  if (r)
    SherpaOnnxDestroySpokenLanguageIdentificationResult (r);
  SherpaOnnxDestroyOfflineStream (st);
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_lid = {
  .name = "lid",
  .table = CMACS_SHERPA_T_LID,
  .struct_size = sizeof (SherpaOnnxSpokenLanguageIdentificationConfig),
  .create = lid_create,
  .destroy = lid_destroy,
  .run = lid_run,
};

/* --- tag --- */

static gpointer
tag_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxAudioTaggingConfig *c = h->cstruct;
  (void) error;
  if (c->model.num_threads <= 0)
    c->model.num_threads = half_cores ();
  return (gpointer) SherpaOnnxCreateAudioTagging (c);
}

static void
tag_destroy (gpointer obj)
{
  SherpaOnnxDestroyAudioTagging (obj);
}

static GVariant *
tag_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxAudioTagging *tg = job->handle->obj;
  const SherpaOnnxOfflineStream *st;
  const SherpaOnnxAudioEvent *const *ev;
  int top_k = cmacs_sherpa_param_int (job->params, "top-k", 5);
  GVariantBuilder b;
  GVariantDict d;

  if (!need_audio (job, error))
    return NULL;
  st = SherpaOnnxAudioTaggingCreateOfflineStream (tg);
  SherpaOnnxAcceptWaveformOffline (st, job->sample_rate, job->samples,
                                   (int32_t) job->n_samples);
  ev = SherpaOnnxAudioTaggingCompute (tg, st, top_k > 0 ? top_k : 5);
  g_variant_builder_init (&b, G_VARIANT_TYPE ("aa{sv}"));
  for (int i = 0; ev && ev[i]; i++)
    {
      GVariantDict e;
      g_variant_dict_init (&e, NULL);
      g_variant_dict_insert (&e, "name", "s", ev[i]->name);
      g_variant_dict_insert (&e, "index", "i", ev[i]->index);
      g_variant_dict_insert (&e, "prob", "d", (double) ev[i]->prob);
      g_variant_builder_add_value (&b, g_variant_dict_end (&e));
    }
  if (ev)
    SherpaOnnxAudioTaggingFreeResults (ev);
  SherpaOnnxDestroyOfflineStream (st);
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "events", g_variant_builder_end (&b));
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_tag = {
  .name = "tag",
  .table = CMACS_SHERPA_T_AUDIO_TAGGING,
  .struct_size = sizeof (SherpaOnnxAudioTaggingConfig),
  .create = tag_create,
  .destroy = tag_destroy,
  .run = tag_run,
};

#endif /* HAVE_CMACS_SHERPA */
