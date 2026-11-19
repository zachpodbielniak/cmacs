/* cmacs-sherpa-asr.c --- recognizers, streams and keyword spotting
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Five kinds:
 *   asr         offline recognizer; RUN transcribes a whole utterance
 *   stream-asr  online recognizer; a parent only
 *   stream      one online stream; FEED gives partials and endpoints
 *   kws         keyword spotter; a parent only
 *   kws-stream  one spotter stream; FEED reports detections
 *
 * The offline result deliberately has the same shape as cmacs-whisper's
 * -- text plus segments with millisecond start/end -- so every consumer
 * of whisper results consumes these unchanged.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <string.h>

/* Default inference threads when the config names none: enough to be
   fast, not so many that a background transcription starves the
   editor (whose own redisplay shares these cores).  */
static int
default_threads (void)
{
  int n = (int) g_get_num_processors () / 2;
  return CLAMP (n, 1, 4);
}

/* --- result helpers --- */

/* Append TOKEN to S, turning SentencePiece's word marker (U+2581)
   into a space.  */
static void
append_token (GString *s, const char *token)
{
  static const char marker[] = "\xe2\x96\x81";
  while (*token)
    {
      if (strncmp (token, marker, 3) == 0)
        {
          g_string_append_c (s, ' ');
          token += 3;
        }
      else
        g_string_append_c (s, *token++);
    }
}

/* Collapse runs of whitespace and trim, in place.  */
static char *
tidy (char *s)
{
  char *r = s, *w = s;
  gboolean space = TRUE;
  for (; *r; r++)
    {
      if (g_ascii_isspace (*r))
        {
          if (!space)
            *w++ = ' ';
          space = TRUE;
        }
      else
        {
          *w++ = *r;
          space = FALSE;
        }
    }
  if (w > s && w[-1] == ' ')
    w--;
  *w = '\0';
  return s;
}

static gboolean
ends_sentence (const char *token)
{
  size_t n = strlen (token);
  if (n == 0)
    return FALSE;
  if (strchr (".?!", token[n - 1]))
    return TRUE;
  /* Full-width 。？！ (three UTF-8 bytes each).  */
  return n >= 3 && (g_str_has_suffix (token, "\xe3\x80\x82")
                    || g_str_has_suffix (token, "\xef\xbc\x9f")
                    || g_str_has_suffix (token, "\xef\xbc\x81"));
}

static GVariant *
segment_variant (gint64 start_ms, gint64 end_ms, const char *text)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "start", "x", start_ms);
  g_variant_dict_insert (&d, "end", "x", end_ms);
  g_variant_dict_insert (&d, "text", "s", text);
  return g_variant_dict_end (&d);
}

/* Segments for an offline result.  Models that segment themselves
   (whisper, with segment timestamps on) are taken as is.  Token-level
   models (transducer, CTC, paraformer) are grouped into readable
   segments: a new one starts after a pause, after sentence punctuation
   once a segment has some length, or when one gets too long.  Without
   timestamps the whole utterance is one segment.  */
static GVariant *
build_segments (const SherpaOnnxOfflineRecognizerResult *r,
                gint64 duration_ms)
{
  GVariantBuilder b;
  g_variant_builder_init (&b, G_VARIANT_TYPE ("aa{sv}"));

  if (r->segment_count > 0 && r->segment_timestamps)
    {
      for (int i = 0; i < r->segment_count; i++)
        {
          gint64 s = (gint64) (r->segment_timestamps[i] * 1000.0f);
          gint64 e = r->segment_durations
            ? s + (gint64) (r->segment_durations[i] * 1000.0f)
            : (i + 1 < r->segment_count
               ? (gint64) (r->segment_timestamps[i + 1] * 1000.0f)
               : duration_ms);
          g_autofree char *t = g_strdup (r->segment_texts_arr
                                         && r->segment_texts_arr[i]
                                         ? r->segment_texts_arr[i] : "");
          g_variant_builder_add_value (&b, segment_variant (s, e, tidy (t)));
        }
    }
  else if (r->count > 0 && r->timestamps && r->tokens_arr)
    {
      const float pause_s = 0.8f, min_s = 1.0f, max_s = 15.0f;
      g_autoptr (GString) text = g_string_new (NULL);
      float seg_start = r->timestamps[0];
      float last = seg_start;

      for (int i = 0; i < r->count; i++)
        {
          float t = r->timestamps[i];
          gboolean brk = FALSE;
          if (i > 0)
            {
              brk = (t - last) > pause_s || (t - seg_start) > max_s
                || (ends_sentence (r->tokens_arr[i - 1])
                    && (t - seg_start) > min_s);
            }
          if (brk && text->len)
            {
              float end = last + (r->durations ? r->durations[i - 1] : 0.2f);
              g_autofree char *s = g_strdup (text->str);
              g_variant_builder_add_value
                (&b, segment_variant ((gint64) (seg_start * 1000.0f),
                                      (gint64) (end * 1000.0f), tidy (s)));
              g_string_truncate (text, 0);
              seg_start = t;
            }
          append_token (text, r->tokens_arr[i]);
          last = t;
        }
      if (text->len)
        {
          float end = last + (r->durations ? r->durations[r->count - 1]
                              : 0.2f);
          gint64 end_ms = (gint64) (end * 1000.0f);
          g_autofree char *s = g_strdup (text->str);
          if (duration_ms > 0 && end_ms > duration_ms)
            end_ms = duration_ms;
          g_variant_builder_add_value
            (&b, segment_variant ((gint64) (seg_start * 1000.0f), end_ms,
                                  tidy (s)));
        }
    }
  else if (r->text && *r->text)
    {
      g_autofree char *s = g_strdup (r->text);
      g_variant_builder_add_value (&b, segment_variant (0, duration_ms,
                                                        tidy (s)));
    }
  return g_variant_builder_end (&b);
}

static void
dict_insert_nonempty (GVariantDict *d, const char *key, const char *val)
{
  if (val && *val)
    g_variant_dict_insert (d, key, "s", val);
}

/* --- asr (offline) --- */

static gpointer
asr_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOfflineRecognizerConfig *c = h->cstruct;
  (void) error;
  if (c->model_config.num_threads <= 0)
    c->model_config.num_threads = default_threads ();
  /* Whisper segments its own output; ask for the timestamps so the
     result has real segments (subtitles need them) unless the caller
     said otherwise.  */
  if (c->model_config.whisper.encoder
      && !g_hash_table_contains (h->config,
                                 "whisper.enable-segment-timestamps")
      && !g_hash_table_contains
           (h->config, "model-config.whisper.enable-segment-timestamps"))
    c->model_config.whisper.enable_segment_timestamps = 1;
  return (gpointer) SherpaOnnxCreateOfflineRecognizer (c);
}

static void
asr_destroy (gpointer obj)
{
  SherpaOnnxDestroyOfflineRecognizer (obj);
}

static GVariant *
asr_run (CmacsSherpaJob *job, GError **error)
{
  const SherpaOnnxOfflineRecognizer *rec = job->handle->obj;
  const char *hot = cmacs_sherpa_param (job->params, "hotwords");
  const SherpaOnnxOfflineStream *st;
  const SherpaOnnxOfflineRecognizerResult *r;
  gint64 duration_ms;
  GVariantDict d;
  GVariantBuilder toks;

  if (!job->samples || job->n_samples == 0)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6, "no audio to transcribe");
      return NULL;
    }
  st = hot && *hot ? SherpaOnnxCreateOfflineStreamWithHotwords (rec, hot)
                   : SherpaOnnxCreateOfflineStream (rec);
  if (!st)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 6,
                   "could not create an offline stream");
      return NULL;
    }
  SherpaOnnxAcceptWaveformOffline (st, job->sample_rate, job->samples,
                                   (int32_t) job->n_samples);
  SherpaOnnxDecodeOfflineStream (rec, st);
  r = SherpaOnnxGetOfflineStreamResult (st);
  duration_ms = (gint64) job->n_samples * 1000 / job->sample_rate;

  g_variant_dict_init (&d, NULL);
  {
    g_autofree char *text = g_strdup (r && r->text ? r->text : "");
    g_variant_dict_insert (&d, "text", "s", tidy (text));
  }
  g_variant_dict_insert (&d, "duration", "x", duration_ms);
  if (r)
    {
      g_variant_dict_insert_value (&d, "segments",
                                   build_segments (r, duration_ms));
      dict_insert_nonempty (&d, "lang", r->lang);
      dict_insert_nonempty (&d, "emotion", r->emotion);
      dict_insert_nonempty (&d, "event", r->event);
      g_variant_builder_init (&toks, G_VARIANT_TYPE ("as"));
      for (int i = 0; r->tokens_arr && i < r->count; i++)
        g_variant_builder_add (&toks, "s", r->tokens_arr[i]);
      g_variant_dict_insert_value (&d, "tokens",
                                   g_variant_builder_end (&toks));
      SherpaOnnxDestroyOfflineRecognizerResult (r);
    }
  SherpaOnnxDestroyOfflineStream (st);
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_asr = {
  .name = "asr",
  .table = CMACS_SHERPA_T_OFFLINE_RECOGNIZER,
  .struct_size = sizeof (SherpaOnnxOfflineRecognizerConfig),
  .create = asr_create,
  .destroy = asr_destroy,
  .run = asr_run,
};

/* --- stream-asr (online recognizer, parent only) --- */

static gpointer
stream_asr_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxOnlineRecognizerConfig *c = h->cstruct;
  (void) error;
  if (c->model_config.num_threads <= 0)
    c->model_config.num_threads = default_threads ();
  /* Endpointing is the point of a streaming recognizer here (it is what
     ends an utterance), so on unless the config turned it off.  */
  if (!g_hash_table_contains (h->config, "enable-endpoint"))
    c->enable_endpoint = 1;
  return (gpointer) SherpaOnnxCreateOnlineRecognizer (c);
}

static void
stream_asr_destroy (gpointer obj)
{
  SherpaOnnxDestroyOnlineRecognizer (obj);
}

static GVariant *
no_run (CmacsSherpaJob *job, GError **error)
{
  (void) job;
  g_set_error (error, CMACS_SHERPA_ERROR, 5,
               "this handle only makes streams");
  return NULL;
}

const CmacsSherpaKindClass cmacs_sherpa_class_stream_asr = {
  .name = "stream-asr",
  .table = CMACS_SHERPA_T_ONLINE_RECOGNIZER,
  .struct_size = sizeof (SherpaOnnxOnlineRecognizerConfig),
  .create = stream_asr_create,
  .destroy = stream_asr_destroy,
  .run = no_run,
};

/* --- stream (one online stream) --- */

typedef struct
{
  const SherpaOnnxOnlineRecognizer *rec;   /* owned by the parent */
  const SherpaOnnxOnlineStream     *st;
  gint64                            fed;    /* samples since open */
  gint64                            seg_start; /* samples, this segment */
  int                               segment;
} Stream;

static const char *const stream_extra[] = { "hotwords", NULL };

static gpointer
stream_create (CmacsSherpaHandle *h, GError **error)
{
  Stream *s = g_new0 (Stream, 1);
  const char *hot = g_hash_table_lookup (h->config, "hotwords");
  (void) error;
  s->rec = h->parent->obj;
  s->st = hot && *hot ? SherpaOnnxCreateOnlineStreamWithHotwords (s->rec, hot)
                      : SherpaOnnxCreateOnlineStream (s->rec);
  if (!s->st)
    {
      g_free (s);
      return NULL;
    }
  return s;
}

static void
stream_destroy (gpointer obj)
{
  Stream *s = obj;
  SherpaOnnxDestroyOnlineStream (s->st);
  g_free (s);
}

static char *
stream_text (Stream *s)
{
  const SherpaOnnxOnlineRecognizerResult *r
    = SherpaOnnxGetOnlineStreamResult (s->rec, s->st);
  char *t = g_strdup (r && r->text ? r->text : "");
  if (r)
    SherpaOnnxDestroyOnlineRecognizerResult (r);
  return tidy (t);
}

static GVariant *
stream_run (CmacsSherpaJob *job, GError **error)
{
  Stream *s = job->handle->obj;
  int rate = job->sample_rate;
  GVariantDict d;
  g_autofree char *text = NULL;
  gboolean endpoint = FALSE;

  (void) error;
  g_variant_dict_init (&d, NULL);

  switch (job->op)
    {
    case CMACS_SHERPA_OP_RESET:
      SherpaOnnxOnlineStreamReset (s->rec, s->st);
      s->seg_start = s->fed;
      g_variant_dict_insert (&d, "reset", "b", TRUE);
      return g_variant_dict_end (&d);

    case CMACS_SHERPA_OP_FINISH:
      SherpaOnnxOnlineStreamInputFinished (s->st);
      while (SherpaOnnxIsOnlineStreamReady (s->rec, s->st))
        SherpaOnnxDecodeOnlineStream (s->rec, s->st);
      endpoint = TRUE;
      break;

    case CMACS_SHERPA_OP_FEED:
    default:
      if (job->samples && job->n_samples)
        {
          SherpaOnnxOnlineStreamAcceptWaveform (s->st, rate, job->samples,
                                                (int32_t) job->n_samples);
          s->fed += (gint64) job->n_samples;
        }
      while (SherpaOnnxIsOnlineStreamReady (s->rec, s->st))
        SherpaOnnxDecodeOnlineStream (s->rec, s->st);
      endpoint = SherpaOnnxOnlineStreamIsEndpoint (s->rec, s->st) != 0;
      break;
    }

  text = stream_text (s);
  g_variant_dict_insert (&d, "partial", "s", text);
  g_variant_dict_insert (&d, "segment", "i", s->segment);
  g_variant_dict_insert (&d, "time", "x", s->fed * 1000 / rate);
  if (endpoint)
    {
      g_variant_dict_insert (&d, "endpoint", "b", TRUE);
      if (*text)
        {
          g_variant_dict_insert (&d, "final", "s", text);
          g_variant_dict_insert (&d, "start", "x", s->seg_start * 1000 / rate);
          g_variant_dict_insert (&d, "end", "x", s->fed * 1000 / rate);
          s->segment++;
        }
      /* Start the next utterance from here.  After FINISH this also
         lets the stream be fed again.  */
      SherpaOnnxOnlineStreamReset (s->rec, s->st);
      s->seg_start = s->fed;
    }
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_stream = {
  .name = "stream",
  .table = CMACS_SHERPA_T_NONE,
  .extra_keys = stream_extra,
  .needs_parent = TRUE,
  .parent_kind = CMACS_SHERPA_KIND_STREAM_ASR,
  .create = stream_create,
  .destroy = stream_destroy,
  .run = stream_run,
};

/* --- kws (keyword spotter, parent only) --- */

static gpointer
kws_create (CmacsSherpaHandle *h, GError **error)
{
  SherpaOnnxKeywordSpotterConfig *c = h->cstruct;
  (void) error;
  if (c->model_config.num_threads <= 0)
    c->model_config.num_threads = 1;   /* always-on: keep it light */
  return (gpointer) SherpaOnnxCreateKeywordSpotter (c);
}

static void
kws_destroy (gpointer obj)
{
  SherpaOnnxDestroyKeywordSpotter (obj);
}

const CmacsSherpaKindClass cmacs_sherpa_class_kws = {
  .name = "kws",
  .table = CMACS_SHERPA_T_KEYWORD_SPOTTER,
  .struct_size = sizeof (SherpaOnnxKeywordSpotterConfig),
  .create = kws_create,
  .destroy = kws_destroy,
  .run = no_run,
};

/* --- kws-stream --- */

typedef struct
{
  const SherpaOnnxKeywordSpotter *kws;    /* owned by the parent */
  const SherpaOnnxOnlineStream   *st;
  gint64                          fed;
  gint64                          base;   /* samples at last reset */
} KwsStream;

static const char *const kws_stream_extra[] = { "keywords", NULL };

static gpointer
kws_stream_create (CmacsSherpaHandle *h, GError **error)
{
  KwsStream *s;
  const char *kw = g_hash_table_lookup (h->config, "keywords");
  const SherpaOnnxKeywordSpotterConfig *pc = h->parent->cstruct;

  if (kw && *kw
      && !cmacs_sherpa_kws_validate (pc->model_config.tokens, kw, error))
    return NULL;
  s = g_new0 (KwsStream, 1);
  s->kws = h->parent->obj;
  s->st = kw && *kw ? SherpaOnnxCreateKeywordStreamWithKeywords (s->kws, kw)
                    : SherpaOnnxCreateKeywordStream (s->kws);
  if (!s->st)
    {
      g_free (s);
      return NULL;
    }
  return s;
}

static void
kws_stream_destroy (gpointer obj)
{
  KwsStream *s = obj;
  SherpaOnnxDestroyOnlineStream (s->st);
  g_free (s);
}

static GVariant *
kws_stream_run (CmacsSherpaJob *job, GError **error)
{
  KwsStream *s = job->handle->obj;
  int rate = job->sample_rate;
  GVariantBuilder hits;
  GVariantDict d;

  (void) error;
  g_variant_builder_init (&hits, G_VARIANT_TYPE ("aa{sv}"));

  if (job->op == CMACS_SHERPA_OP_RESET)
    {
      SherpaOnnxResetKeywordStream (s->kws, s->st);
      s->base = s->fed;
    }
  else
    {
      if (job->op == CMACS_SHERPA_OP_FEED && job->samples && job->n_samples)
        {
          SherpaOnnxOnlineStreamAcceptWaveform (s->st, rate, job->samples,
                                                (int32_t) job->n_samples);
          s->fed += (gint64) job->n_samples;
        }
      if (job->op == CMACS_SHERPA_OP_FINISH)
        SherpaOnnxOnlineStreamInputFinished (s->st);

      while (SherpaOnnxIsKeywordStreamReady (s->kws, s->st))
        {
          const SherpaOnnxKeywordResult *r;
          SherpaOnnxDecodeKeywordStream (s->kws, s->st);
          r = SherpaOnnxGetKeywordResult (s->kws, s->st);
          if (r && r->keyword && *r->keyword)
            {
              GVariantDict h;
              g_variant_dict_init (&h, NULL);
              g_variant_dict_insert (&h, "keyword", "s", r->keyword);
              g_variant_dict_insert (&h, "start", "x",
                                     s->base * 1000 / rate
                                     + (gint64) (r->start_time * 1000.0f));
              g_variant_dict_insert (&h, "time", "x", s->fed * 1000 / rate);
              g_variant_builder_add_value (&hits, g_variant_dict_end (&h));
              /* sherpa requires a reset after each detection, or the
                 same keyword fires again on the next decode.  */
              SherpaOnnxResetKeywordStream (s->kws, s->st);
              s->base = s->fed;
            }
          if (r)
            SherpaOnnxDestroyKeywordResult (r);
        }
    }

  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert_value (&d, "detections",
                               g_variant_builder_end (&hits));
  g_variant_dict_insert (&d, "time", "x", s->fed * 1000 / rate);
  return g_variant_dict_end (&d);
}

const CmacsSherpaKindClass cmacs_sherpa_class_kws_stream = {
  .name = "kws-stream",
  .table = CMACS_SHERPA_T_NONE,
  .extra_keys = kws_stream_extra,
  .needs_parent = TRUE,
  .parent_kind = CMACS_SHERPA_KIND_KWS,
  .create = kws_stream_create,
  .destroy = kws_stream_destroy,
  .run = kws_stream_run,
};

#endif /* HAVE_CMACS_SHERPA */
