/* cmacs-sherpa-engine.c --- handles, worker pools, jobs, cancellation
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The family-independent core of the sherpa engine: a registry of
 * handles, one ordered worker pool per handle, a loader pool for model
 * loads, the job table that makes cancellation possible, and delivery
 * of results to the main context.  See cmacs-sherpa-engine.h for the
 * threading contract.
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "cmacs-sherpa-private.h"

#include <string.h>

/* --- globals --- */

static GMainContext *main_ctx;           /* where callbacks run */
static GMutex        registry_lock;      /* handles + jobs tables */
static GHashTable   *handles;            /* id -> CmacsSherpaHandle* */
static GHashTable   *jobs;               /* id -> CmacsSherpaJob* (weak) */
static guint64       next_handle_id = 1;
static guint64       next_job_id = 1;
static GThreadPool  *loader_pool;        /* async opens */

G_DEFINE_QUARK (cmacs-sherpa-error-quark, cmacs_sherpa_error)

static const CmacsSherpaKindClass *const kind_classes[CMACS_SHERPA_N_KINDS] = {
  [CMACS_SHERPA_KIND_ASR]            = &cmacs_sherpa_class_asr,
  [CMACS_SHERPA_KIND_STREAM_ASR]     = &cmacs_sherpa_class_stream_asr,
  [CMACS_SHERPA_KIND_STREAM]         = &cmacs_sherpa_class_stream,
  [CMACS_SHERPA_KIND_KWS]            = &cmacs_sherpa_class_kws,
  [CMACS_SHERPA_KIND_KWS_STREAM]     = &cmacs_sherpa_class_kws_stream,
  [CMACS_SHERPA_KIND_VAD]            = &cmacs_sherpa_class_vad,
  [CMACS_SHERPA_KIND_TTS]            = &cmacs_sherpa_class_tts,
  [CMACS_SHERPA_KIND_DIARIZE]        = &cmacs_sherpa_class_diarize,
  [CMACS_SHERPA_KIND_SPEAKER]        = &cmacs_sherpa_class_speaker,
  [CMACS_SHERPA_KIND_PUNCT]          = &cmacs_sherpa_class_punct,
  [CMACS_SHERPA_KIND_PUNCT_ONLINE]   = &cmacs_sherpa_class_punct_online,
  [CMACS_SHERPA_KIND_LID]            = &cmacs_sherpa_class_lid,
  [CMACS_SHERPA_KIND_TAG]            = &cmacs_sherpa_class_tag,
  [CMACS_SHERPA_KIND_DENOISE]        = &cmacs_sherpa_class_denoise,
  [CMACS_SHERPA_KIND_DENOISE_STREAM] = &cmacs_sherpa_class_denoise_stream,
  [CMACS_SHERPA_KIND_SEPARATE]       = &cmacs_sherpa_class_separate,
};

/* --- small helpers --- */

static void
wipe_free (float *p, gsize n)
{
  /* Speech samples are personal data; do not leave them in freed heap
     (the same rule cmacs-whisper follows).  */
  if (p)
    {
      memset_explicit (p, 0, n * sizeof *p);
      g_free (p);
    }
}

GBytes *
cmacs_sherpa_pcm_from_float (const float *samples, gsize n)
{
  gint16 *out = g_new (gint16, n ? n : 1);
  for (gsize i = 0; i < n; i++)
    {
      float s = samples[i] * 32767.0f;
      if (s > 32767.0f)
        s = 32767.0f;
      else if (s < -32768.0f)
        s = -32768.0f;
      out[i] = GINT16_TO_LE ((gint16) s);
    }
  return g_bytes_new_take (out, n * sizeof (gint16));
}

GVariant *
cmacs_sherpa_variant_pcm (const float *samples, gsize n)
{
  g_autoptr (GBytes) b = cmacs_sherpa_pcm_from_float (samples, n);
  return g_variant_new_from_bytes (G_VARIANT_TYPE_BYTESTRING, b, TRUE);
}

GVariant *
cmacs_sherpa_variant_error (const char *message)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, "error", "s", message ? message : "error");
  return g_variant_dict_end (&d);
}

static GVariant *
variant_flag (const char *key)
{
  GVariantDict d;
  g_variant_dict_init (&d, NULL);
  g_variant_dict_insert (&d, key, "b", TRUE);
  return g_variant_dict_end (&d);
}

/* --- kinds --- */

const char *
cmacs_sherpa_kind_name (CmacsSherpaKind kind)
{
  if ((int) kind < 0 || kind >= CMACS_SHERPA_N_KINDS)
    return "unknown";
  return kind_classes[kind]->name;
}

gboolean
cmacs_sherpa_kind_from_name (const char *name, CmacsSherpaKind *out)
{
  for (int k = 0; k < CMACS_SHERPA_N_KINDS; k++)
    if (strcmp (kind_classes[k]->name, name) == 0)
      {
        *out = (CmacsSherpaKind) k;
        return TRUE;
      }
  return FALSE;
}

GVariant *
cmacs_sherpa_config_keys (CmacsSherpaKind kind)
{
  GVariantBuilder b;
  const CmacsSherpaKindClass *klass;
  const CmacsSherpaField *f;

  g_variant_builder_init (&b, G_VARIANT_TYPE ("a(ss)"));
  if ((int) kind >= 0 && kind < CMACS_SHERPA_N_KINDS)
    {
      klass = kind_classes[kind];
      for (f = cmacs_sherpa_table (klass->table); f && f->key; f++)
        g_variant_builder_add (&b, "(ss)", f->key,
                               f->type == CMACS_SHERPA_F_STR ? "string"
                               : f->type == CMACS_SHERPA_F_INT ? "int"
                               : "float");
      if (klass->extra_keys)
        for (const char *const *e = klass->extra_keys; *e; e++)
          g_variant_builder_add (&b, "(ss)", *e, "string");
    }
  return g_variant_ref_sink (g_variant_builder_end (&b));
}

const char *
cmacs_sherpa_version (void)
{
  const char *v = SherpaOnnxGetVersionStr ();
  return v ? v : "unknown";
}

const char *
cmacs_sherpa_onnxruntime_version (void)
{
  const char *v = SherpaOnnxGetOnnxruntimeVersionStr ();
  return v ? v : "unknown";
}

/* --- handle lifetime --- */

CmacsSherpaHandle *
cmacs_sherpa_handle_root (CmacsSherpaHandle *h)
{
  return h->parent ? h->parent : h;
}

static CmacsSherpaHandle *
handle_ref (CmacsSherpaHandle *h)
{
  g_atomic_int_inc (&h->ref);
  return h;
}

static void
handle_unref (CmacsSherpaHandle *h)
{
  if (!h || !g_atomic_int_dec_and_test (&h->ref))
    return;
  /* The last reference is dropped by a job's main-context completion or
     by close on the main thread, never from inside this handle's own
     pool, so waiting for the pool here cannot deadlock.  */
  if (h->pool)
    g_thread_pool_free (h->pool, TRUE, TRUE);
  if (h->obj)
    kind_classes[h->kind]->destroy (h->obj);
  if (h->parent)
    handle_unref (h->parent);
  g_free (h->cstruct);
  if (h->config)
    g_hash_table_unref (h->config);
  g_mutex_clear (&h->lock);
  g_free (h->model);
  g_free (h);
}

static void job_worker (gpointer data, gpointer user_data);

/* A short, human description of what a handle loaded: the first model
   path found among the usual keys, else its kind.  */
static char *
describe_model (CmacsSherpaKind kind, GHashTable *config)
{
  static const char *const keys[] = {
    "model", "encoder", "model-config.transducer.encoder",
    "transducer.encoder", "whisper.encoder", "sense-voice.model",
    "moonshine.encoder", "paraformer.model", "nemo-ctc.model",
    "silero-vad.model", "ten-vad.model", "vits.model", "kokoro.model",
    "matcha.acoustic-model", "segmentation.pyannote.model",
    "embedding.model", "ct-transformer", "cnn-bilstm", "zipformer.model",
    "gtcrn.model", "spleeter.vocals", "tokens", NULL };
  if (config)
    for (int i = 0; keys[i]; i++)
      {
        const char *v = g_hash_table_lookup (config, keys[i]);
        if (v && *v)
          return g_strdup (v);
      }
  return g_strdup (cmacs_sherpa_kind_name (kind));
}

static GHashTable *
copy_config (GHashTable *config)
{
  GHashTable *c = g_hash_table_new_full (g_str_hash, g_str_equal,
                                         g_free, g_free);
  if (config)
    {
      GHashTableIter it;
      gpointer k, v;
      g_hash_table_iter_init (&it, config);
      while (g_hash_table_iter_next (&it, &k, &v))
        g_hash_table_insert (c, g_strdup (k), g_strdup (v ? v : ""));
    }
  return c;
}

/* Build and load a handle.  Takes ownership of CONFIG.  Not yet
   registered.  Thread-agnostic.  */
static CmacsSherpaHandle *
handle_create (CmacsSherpaKind kind, GHashTable *config,
               CmacsSherpaHandle *parent, GError **error)
{
  const CmacsSherpaKindClass *klass = kind_classes[kind];
  CmacsSherpaHandle *h = g_new0 (CmacsSherpaHandle, 1);

  h->ref = 1;
  h->kind = kind;
  h->config = config;
  h->parent = parent;           /* reference transferred by the caller */
  g_mutex_init (&h->lock);
  h->opened_us = g_get_real_time ();
  h->last_used_us = h->opened_us;
  h->model = describe_model (kind, config);

  if (klass->struct_size)
    h->cstruct = g_malloc0 (klass->struct_size);
  if (!cmacs_sherpa_config_fill (klass->table, h->cstruct, config,
                                 klass->extra_keys, error))
    goto fail;

  h->obj = klass->create (h, error);
  if (!h->obj)
    {
      if (error && !*error)
        g_set_error (error, CMACS_SHERPA_ERROR, 3,
                     "sherpa-onnx could not create a %s from `%s' "
                     "(check the model files; set debug=1 for detail)",
                     klass->name, h->model);
      goto fail;
    }

  h->pool = g_thread_pool_new (job_worker, NULL, 1, FALSE, error);
  if (!h->pool)
    goto fail;
  return h;

 fail:
  handle_unref (h);
  return NULL;
}

/* Validate PARENT for KIND and return a new reference to it.  */
static CmacsSherpaHandle *
parent_for (CmacsSherpaKind kind, guint64 parent_id, GError **error)
{
  const CmacsSherpaKindClass *klass = kind_classes[kind];
  CmacsSherpaHandle *p = NULL;

  if (!klass->needs_parent)
    {
      if (parent_id)
        {
          g_set_error (error, CMACS_SHERPA_ERROR, 4,
                       "a %s takes no parent handle", klass->name);
          return NULL;
        }
      return NULL;
    }

  g_mutex_lock (&registry_lock);
  p = handles ? g_hash_table_lookup (handles, &parent_id) : NULL;
  if (p && !g_atomic_int_get (&p->closed) && p->kind == klass->parent_kind)
    handle_ref (p);
  else
    p = NULL;
  g_mutex_unlock (&registry_lock);

  if (!p)
    g_set_error (error, CMACS_SHERPA_ERROR, 4,
                 "a %s needs an open %s parent handle", klass->name,
                 cmacs_sherpa_kind_name (klass->parent_kind));
  return p;
}

static guint64
handle_register (CmacsSherpaHandle *h)
{
  guint64 *key = g_new (guint64, 1);
  g_mutex_lock (&registry_lock);
  h->id = next_handle_id++;
  *key = h->id;
  g_hash_table_insert (handles, key, h);
  g_mutex_unlock (&registry_lock);
  return h->id;
}

guint64
cmacs_sherpa_open (CmacsSherpaKind kind, GHashTable *config,
                   guint64 parent_id, GError **error)
{
  CmacsSherpaHandle *parent, *h;

  if ((int) kind < 0 || kind >= CMACS_SHERPA_N_KINDS)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 4, "unknown kind");
      return 0;
    }
  {
    GError *perr = NULL;
    parent = parent_for (kind, parent_id, &perr);
    if (perr)
      {
        g_propagate_error (error, perr);
        return 0;
      }
  }
  h = handle_create (kind, copy_config (config), parent, error);
  return h ? handle_register (h) : 0;
}

/* --- async open --- */

typedef struct
{
  CmacsSherpaKind    kind;
  GHashTable        *config;
  guint64            parent_id;
  CmacsSherpaDoneFn  done;
  gpointer           user_data;
  GDestroyNotify     user_data_free;
  GVariant          *result;
} OpenJob;

static gboolean
open_deliver (gpointer data)
{
  OpenJob *o = data;
  o->done (o->result, o->user_data);
  if (o->user_data_free)
    o->user_data_free (o->user_data);
  g_variant_unref (o->result);
  g_free (o);
  return G_SOURCE_REMOVE;
}

static void
loader_worker (gpointer data, gpointer unused)
{
  OpenJob *o = data;
  g_autoptr (GError) err = NULL;
  guint64 id;
  GVariantDict d;

  (void) unused;
  id = cmacs_sherpa_open (o->kind, o->config, o->parent_id, &err);
  g_hash_table_unref (o->config);
  if (id)
    {
      g_variant_dict_init (&d, NULL);
      g_variant_dict_insert (&d, "handle", "t", id);
      o->result = g_variant_ref_sink (g_variant_dict_end (&d));
    }
  else
    o->result = g_variant_ref_sink
      (cmacs_sherpa_variant_error (err ? err->message : "open failed"));
  g_main_context_invoke (main_ctx, open_deliver, o);
}

void
cmacs_sherpa_open_async (CmacsSherpaKind kind, GHashTable *config,
                         guint64 parent, CmacsSherpaDoneFn done,
                         gpointer user_data, GDestroyNotify user_data_free)
{
  OpenJob *o = g_new0 (OpenJob, 1);
  o->kind = kind;
  o->config = copy_config (config);
  o->parent_id = parent;
  o->done = done;
  o->user_data = user_data;
  o->user_data_free = user_data_free;
  g_thread_pool_push (loader_pool, o, NULL);
}

gboolean
cmacs_sherpa_close (guint64 id)
{
  CmacsSherpaHandle *h = NULL;
  gpointer key = NULL;

  g_mutex_lock (&registry_lock);
  if (handles && g_hash_table_lookup_extended (handles, &id, &key,
                                               (gpointer *) &h))
    g_hash_table_steal (handles, &id);
  g_mutex_unlock (&registry_lock);
  g_free (key);
  if (!h)
    return FALSE;
  /* Queued jobs see this and complete as cancelled.  */
  g_atomic_int_set (&h->closed, 1);
  handle_unref (h);
  return TRUE;
}

/* --- jobs --- */

static void
job_free (CmacsSherpaJob *job)
{
  wipe_free (job->samples, job->n_samples);
  g_free (job->text);
  if (job->params)
    g_hash_table_unref (job->params);
  if (job->result)
    g_variant_unref (job->result);
  handle_unref (job->handle);
  g_free (job);
}

static gboolean
job_deliver (gpointer data)
{
  CmacsSherpaJob *job = data;

  g_mutex_lock (&registry_lock);
  g_hash_table_remove (jobs, &job->id);
  g_mutex_unlock (&registry_lock);

  job->done (job->result, job->user_data);
  if (job->user_data_free)
    job->user_data_free (job->user_data);
  g_atomic_int_add (&job->handle->pending, -1);
  job_free (job);
  return G_SOURCE_REMOVE;
}

typedef struct
{
  CmacsSherpaJob *job;          /* NOT owned: DONE is queued after us */
  GVariant       *chunk;
} ChunkPost;

static gboolean
chunk_deliver (gpointer data)
{
  ChunkPost *c = data;
  if (!g_atomic_int_get (&c->job->cancelled))
    c->job->chunk (c->chunk, c->job->user_data);
  g_variant_unref (c->chunk);
  g_free (c);
  return G_SOURCE_REMOVE;
}

void
cmacs_sherpa_job_post_chunk (CmacsSherpaJob *job, GVariant *chunk)
{
  ChunkPost *c;

  g_variant_ref_sink (chunk);
  if (!job->chunk)
    {
      g_variant_unref (chunk);
      return;
    }
  c = g_new (ChunkPost, 1);
  c->job = job;
  c->chunk = chunk;
  /* The main context runs idle sources in FIFO order at one priority,
     so every chunk posted here is delivered before the job's DONE,
     which the worker posts after the last chunk; the job is therefore
     still alive in chunk_deliver.  */
  g_main_context_invoke_full (main_ctx, G_PRIORITY_DEFAULT,
                              chunk_deliver, c, NULL);
}

static void
job_worker (gpointer data, gpointer unused)
{
  CmacsSherpaJob *job = data;
  CmacsSherpaHandle *root;
  g_autoptr (GError) err = NULL;
  GVariant *r = NULL;

  (void) unused;
  if (g_atomic_int_get (&job->cancelled)
      || g_atomic_int_get (&job->handle->closed))
    r = variant_flag ("cancelled");
  else
    {
      root = cmacs_sherpa_handle_root (job->handle);
      g_mutex_lock (&root->lock);
      job->handle->last_used_us = g_get_real_time ();
      r = kind_classes[job->handle->kind]->run (job, &err);
      g_mutex_unlock (&root->lock);
      if (!r)
        r = cmacs_sherpa_variant_error (err ? err->message
                                        : "sherpa-onnx job failed");
      else if (g_atomic_int_get (&job->cancelled))
        {
          g_variant_unref (g_variant_ref_sink (r));
          r = variant_flag ("cancelled");
        }
    }
  job->result = g_variant_ref_sink (r);
  g_main_context_invoke_full (main_ctx, G_PRIORITY_DEFAULT,
                              job_deliver, job, NULL);
}

/* Which ops each kind accepts.  */
static gboolean
op_valid (CmacsSherpaKind kind, CmacsSherpaOp op)
{
  switch (kind)
    {
    case CMACS_SHERPA_KIND_STREAM:
    case CMACS_SHERPA_KIND_KWS_STREAM:
    case CMACS_SHERPA_KIND_VAD:
    case CMACS_SHERPA_KIND_DENOISE_STREAM:
      return op == CMACS_SHERPA_OP_FEED || op == CMACS_SHERPA_OP_FINISH
        || op == CMACS_SHERPA_OP_RESET;
    case CMACS_SHERPA_KIND_SPEAKER:
      return op == CMACS_SHERPA_OP_RUN || op == CMACS_SHERPA_OP_ENROLL
        || op == CMACS_SHERPA_OP_ADD_EMBEDDING
        || op == CMACS_SHERPA_OP_IDENTIFY || op == CMACS_SHERPA_OP_VERIFY
        || op == CMACS_SHERPA_OP_REMOVE || op == CMACS_SHERPA_OP_LIST;
    case CMACS_SHERPA_KIND_STREAM_ASR:
    case CMACS_SHERPA_KIND_KWS:
      /* Parents only make streams; they have no ops of their own.  */
      return FALSE;
    default:
      return op == CMACS_SHERPA_OP_RUN;
    }
}

/* Convert PCM into JOB's float samples (raw floats for ADD_EMBEDDING).  */
static void
job_load_input (CmacsSherpaJob *job, GBytes *pcm)
{
  gsize nbytes = 0;
  const guint8 *raw;

  if (!pcm)
    return;
  raw = g_bytes_get_data (pcm, &nbytes);
  if (job->op == CMACS_SHERPA_OP_ADD_EMBEDDING)
    {
      job->n_samples = nbytes / sizeof (float);
      job->samples = g_new (float, job->n_samples ? job->n_samples : 1);
      memcpy (job->samples, raw, job->n_samples * sizeof (float));
    }
  else
    {
      /* S16LE -> float [-1, 1).  memcpy each sample: the bytes come from
         a Lisp string and carry no alignment guarantee.  */
      job->n_samples = nbytes / 2;
      job->samples = g_new (float, job->n_samples ? job->n_samples : 1);
      for (gsize i = 0; i < job->n_samples; i++)
        {
          gint16 s;
          memcpy (&s, raw + 2 * i, 2);
          job->samples[i] = (float) GINT16_FROM_LE (s) / 32768.0f;
        }
    }
}

GVariant *
cmacs_sherpa_run_sync (guint64 id, CmacsSherpaOp op, GBytes *pcm,
                       int sample_rate, const char *text, GHashTable *params,
                       GError **error)
{
  CmacsSherpaHandle *h, *root;
  CmacsSherpaJob *job;
  GVariant *r;

  g_mutex_lock (&registry_lock);
  h = handles ? g_hash_table_lookup (handles, &id) : NULL;
  if (h)
    handle_ref (h);
  g_mutex_unlock (&registry_lock);
  if (!h)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 5, "unknown sherpa handle %"
                   G_GUINT64_FORMAT, id);
      return NULL;
    }
  if (!op_valid (h->kind, op))
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 5,
                   "operation not supported on a %s handle",
                   cmacs_sherpa_kind_name (h->kind));
      handle_unref (h);
      return NULL;
    }

  /* A job on the stack of this thread: same run function, same root
     lock, no pool and no callbacks.  */
  job = g_new0 (CmacsSherpaJob, 1);
  job->handle = h;              /* job_free drops this reference */
  job->op = op;
  job->sample_rate = sample_rate > 0 ? sample_rate : 16000;
  job->text = g_strdup (text);
  job->params = params ? copy_config (params) : NULL;
  job_load_input (job, pcm);

  root = cmacs_sherpa_handle_root (h);
  g_mutex_lock (&root->lock);
  h->last_used_us = g_get_real_time ();
  h->n_jobs++;
  r = kind_classes[h->kind]->run (job, error);
  g_mutex_unlock (&root->lock);
  if (r)
    g_variant_ref_sink (r);
  job_free (job);
  return r;
}

guint64
cmacs_sherpa_submit (guint64 id, CmacsSherpaOp op, GBytes *pcm,
                     int sample_rate, const char *text, GHashTable *params,
                     CmacsSherpaDoneFn done, CmacsSherpaChunkFn chunk,
                     gpointer user_data, GDestroyNotify user_data_free,
                     GError **error)
{
  CmacsSherpaHandle *h = NULL;
  CmacsSherpaJob *job;
  guint64 *key;

  g_mutex_lock (&registry_lock);
  h = handles ? g_hash_table_lookup (handles, &id) : NULL;
  if (h)
    handle_ref (h);
  g_mutex_unlock (&registry_lock);
  if (!h)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 5, "unknown sherpa handle %"
                   G_GUINT64_FORMAT, id);
      return 0;
    }
  if (!op_valid (h->kind, op))
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 5,
                   "operation not supported on a %s handle",
                   cmacs_sherpa_kind_name (h->kind));
      handle_unref (h);
      return 0;
    }

  job = g_new0 (CmacsSherpaJob, 1);
  job->handle = h;
  job->op = op;
  job->sample_rate = sample_rate > 0 ? sample_rate : 16000;
  job->text = g_strdup (text);
  job->params = params ? copy_config (params) : NULL;
  job->done = done;
  job->chunk = chunk;
  job->user_data = user_data;
  job->user_data_free = user_data_free;

  job_load_input (job, pcm);

  key = g_new (guint64, 1);
  g_mutex_lock (&registry_lock);
  job->id = next_job_id++;
  *key = job->id;
  g_hash_table_insert (jobs, key, job);
  g_mutex_unlock (&registry_lock);

  g_atomic_int_inc (&h->pending);
  h->n_jobs++;
  g_thread_pool_push (h->pool, job, NULL);
  return job->id;
}

gboolean
cmacs_sherpa_cancel (guint64 id)
{
  CmacsSherpaJob *job;
  gboolean found = FALSE;

  g_mutex_lock (&registry_lock);
  job = jobs ? g_hash_table_lookup (jobs, &id) : NULL;
  if (job)
    {
      g_atomic_int_set (&job->cancelled, 1);
      found = TRUE;
    }
  g_mutex_unlock (&registry_lock);
  return found;
}

/* --- introspection --- */

GVariant *
cmacs_sherpa_info (guint64 id)
{
  CmacsSherpaHandle *h;
  GVariant *v = NULL;

  g_mutex_lock (&registry_lock);
  h = handles ? g_hash_table_lookup (handles, &id) : NULL;
  if (h)
    handle_ref (h);
  g_mutex_unlock (&registry_lock);
  if (!h)
    return NULL;

  if (kind_classes[h->kind]->info)
    {
      CmacsSherpaHandle *root = cmacs_sherpa_handle_root (h);
      g_mutex_lock (&root->lock);
      v = kind_classes[h->kind]->info (h);
      g_mutex_unlock (&root->lock);
    }
  if (!v)
    {
      GVariantDict d;
      g_variant_dict_init (&d, NULL);
      v = g_variant_dict_end (&d);
    }
  handle_unref (h);
  return g_variant_ref_sink (v);
}

GVariant *
cmacs_sherpa_list (void)
{
  GVariantBuilder b;
  GHashTableIter it;
  gpointer k, v;

  g_variant_builder_init (&b, G_VARIANT_TYPE ("aa{sv}"));
  g_mutex_lock (&registry_lock);
  if (handles)
    {
      g_hash_table_iter_init (&it, handles);
      while (g_hash_table_iter_next (&it, &k, &v))
        {
          CmacsSherpaHandle *h = v;
          GVariantDict d;
          g_variant_dict_init (&d, NULL);
          g_variant_dict_insert (&d, "id", "t", h->id);
          g_variant_dict_insert (&d, "kind", "s",
                                 cmacs_sherpa_kind_name (h->kind));
          g_variant_dict_insert (&d, "model", "s", h->model);
          g_variant_dict_insert (&d, "parent", "t",
                                 h->parent ? h->parent->id : 0);
          g_variant_dict_insert (&d, "jobs", "x", h->n_jobs);
          g_variant_dict_insert (&d, "pending", "i",
                                 g_atomic_int_get (&h->pending));
          g_variant_dict_insert (&d, "opened", "x",
                                 h->opened_us / G_USEC_PER_SEC);
          g_variant_dict_insert (&d, "last-used", "x",
                                 h->last_used_us / G_USEC_PER_SEC);
          g_variant_builder_add_value (&b, g_variant_dict_end (&d));
        }
    }
  g_mutex_unlock (&registry_lock);
  return g_variant_ref_sink (g_variant_builder_end (&b));
}

/* --- WAV input --- */

GBytes *
cmacs_sherpa_read_wave (const char *path, int *sample_rate, GError **error)
{
  const SherpaOnnxWave *w = SherpaOnnxReadWave (path);
  GBytes *b;

  if (!w)
    {
      g_set_error (error, CMACS_SHERPA_ERROR, 8,
                   "cannot read `%s' as a PCM WAV file", path);
      return NULL;
    }
  b = cmacs_sherpa_pcm_from_float (w->samples, (gsize) w->num_samples);
  if (sample_rate)
    *sample_rate = w->sample_rate;
  SherpaOnnxFreeWave (w);
  return b;
}

/* --- init --- */

void
cmacs_sherpa_engine_init (GMainContext *context)
{
  if (handles)
    return;
  main_ctx = g_main_context_ref (context ? context
                                 : g_main_context_default ());
  handles = g_hash_table_new_full (g_int64_hash, g_int64_equal, g_free,
                                   NULL);
  jobs = g_hash_table_new_full (g_int64_hash, g_int64_equal, g_free, NULL);
  /* Two concurrent model loads: enough that opening a small VAD is not
     stuck behind a 600 MB recognizer, few enough not to thrash disk.  */
  loader_pool = g_thread_pool_new (loader_worker, NULL, 2, FALSE, NULL);
}

#endif /* HAVE_CMACS_SHERPA */
