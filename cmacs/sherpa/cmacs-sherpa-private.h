/* cmacs-sherpa-private.h --- shared internals of the sherpa engine TUs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Included only by the engine translation units (cmacs-sherpa-engine.c,
 * -config.c, -asr.c, -audio.c, -tts.c, -analysis.c).  It pulls in
 * sherpa's c-api.h, so it must never be included next to lisp.h.
 */

#ifndef CMACS_SHERPA_PRIVATE_H
#define CMACS_SHERPA_PRIVATE_H

#include "cmacs-sherpa-engine.h"

#include <sherpa-onnx/c-api/c-api.h>
#include <glib.h>

/* --- config tables (cmacs-sherpa-config.c) --- */

typedef enum
{
  CMACS_SHERPA_F_STR,
  CMACS_SHERPA_F_INT,
  CMACS_SHERPA_F_FLOAT
} CmacsSherpaFieldType;

typedef struct
{
  const char           *key;     /* "model-config.whisper.encoder" */
  CmacsSherpaFieldType  type;
  size_t                offset;  /* into the root config struct */
} CmacsSherpaField;

/* Which generated table a root struct uses.  */
typedef enum
{
  CMACS_SHERPA_T_NONE = 0,
  CMACS_SHERPA_T_OFFLINE_RECOGNIZER,
  CMACS_SHERPA_T_ONLINE_RECOGNIZER,
  CMACS_SHERPA_T_KEYWORD_SPOTTER,
  CMACS_SHERPA_T_VAD,
  CMACS_SHERPA_T_TTS,
  CMACS_SHERPA_T_GENERATION,
  CMACS_SHERPA_T_DIARIZATION,
  CMACS_SHERPA_T_SPEAKER_EMBEDDING,
  CMACS_SHERPA_T_OFFLINE_PUNCT,
  CMACS_SHERPA_T_ONLINE_PUNCT,
  CMACS_SHERPA_T_LID,
  CMACS_SHERPA_T_AUDIO_TAGGING,
  CMACS_SHERPA_T_OFFLINE_DENOISER,
  CMACS_SHERPA_T_ONLINE_DENOISER,
  CMACS_SHERPA_T_SOURCE_SEPARATION
} CmacsSherpaTable;

const CmacsSherpaField *cmacs_sherpa_table (CmacsSherpaTable t);

/* Fill STRUCT_PTR (a zeroed root struct of table T) from CONFIG.
   String fields point INTO config's values, so CONFIG must outlive
   every use of the struct.  Keys listed in EXTRA (NULL-terminated, may
   be NULL) are skipped -- the kind consumes them itself.  Any other
   unknown key, or an unparseable number, is an error naming the key.  */
gboolean cmacs_sherpa_config_fill (CmacsSherpaTable t, void *struct_ptr,
                                   GHashTable *config,
                                   const char *const *extra,
                                   GError **error);

/* Typed lookups of a string map (NULL map is fine).  */
const char *cmacs_sherpa_param (GHashTable *params, const char *key);
int         cmacs_sherpa_param_int (GHashTable *params, const char *key,
                                    int fallback);
double      cmacs_sherpa_param_double (GHashTable *params, const char *key,
                                       double fallback);
gboolean    cmacs_sherpa_param_bool (GHashTable *params, const char *key,
                                     gboolean fallback);

/* --- engine (cmacs-sherpa-engine.c) --- */

typedef struct CmacsSherpaHandle CmacsSherpaHandle;
typedef struct CmacsSherpaJob    CmacsSherpaJob;

struct CmacsSherpaHandle
{
  gint                 ref;
  guint64              id;
  CmacsSherpaKind      kind;
  gpointer             obj;       /* kind-private object */
  CmacsSherpaHandle   *parent;    /* ref held; streams only */
  GHashTable          *config;    /* keeps config strings alive */
  void                *cstruct;   /* the filled root config struct */
  GThreadPool         *pool;      /* single thread: ordered jobs */
  GMutex               lock;      /* taken on the ROOT handle per op */
  gint                 closed;    /* atomic */
  gint                 pending;   /* atomic: queued + running jobs */
  gint64               n_jobs;
  gint64               opened_us;
  gint64               last_used_us;
  char                *model;     /* short description for listings */
};

struct CmacsSherpaJob
{
  guint64              id;
  CmacsSherpaHandle   *handle;    /* ref held */
  CmacsSherpaOp        op;
  float               *samples;   /* converted PCM, or raw floats */
  gsize                n_samples;
  int                  sample_rate;
  char                *text;
  GHashTable          *params;    /* string -> string, may be NULL */
  CmacsSherpaDoneFn    done;
  CmacsSherpaChunkFn   chunk;
  gpointer             user_data;
  GDestroyNotify       user_data_free;
  gint                 cancelled; /* atomic */
  GVariant            *result;    /* set by the worker */
};

/* Per-kind behaviour.  CREATE runs on a loader thread (or the main
   thread for a synchronous open); RUN on the handle's pool thread with
   the root lock held; DESTROY wherever the last reference drops.  */
typedef struct
{
  const char        *name;
  CmacsSherpaTable   table;
  gsize              struct_size;
  const char *const *extra_keys;
  gboolean           needs_parent;
  CmacsSherpaKind    parent_kind;
  gpointer         (*create)  (CmacsSherpaHandle *h, GError **error);
  void             (*destroy) (gpointer obj);
  GVariant        *(*run)     (CmacsSherpaJob *job, GError **error);
  GVariant        *(*info)    (CmacsSherpaHandle *h);
} CmacsSherpaKindClass;

/* Kind classes, defined in the family TUs.  */
extern const CmacsSherpaKindClass cmacs_sherpa_class_asr;
extern const CmacsSherpaKindClass cmacs_sherpa_class_stream_asr;
extern const CmacsSherpaKindClass cmacs_sherpa_class_stream;
extern const CmacsSherpaKindClass cmacs_sherpa_class_kws;
extern const CmacsSherpaKindClass cmacs_sherpa_class_kws_stream;
extern const CmacsSherpaKindClass cmacs_sherpa_class_vad;
extern const CmacsSherpaKindClass cmacs_sherpa_class_tts;
extern const CmacsSherpaKindClass cmacs_sherpa_class_diarize;
extern const CmacsSherpaKindClass cmacs_sherpa_class_speaker;
extern const CmacsSherpaKindClass cmacs_sherpa_class_punct;
extern const CmacsSherpaKindClass cmacs_sherpa_class_punct_online;
extern const CmacsSherpaKindClass cmacs_sherpa_class_lid;
extern const CmacsSherpaKindClass cmacs_sherpa_class_tag;
extern const CmacsSherpaKindClass cmacs_sherpa_class_denoise;
extern const CmacsSherpaKindClass cmacs_sherpa_class_denoise_stream;
extern const CmacsSherpaKindClass cmacs_sherpa_class_separate;

/* Post a chunk for JOB to the main context (any thread).  CHUNK is
   sunk and consumed.  No-op when the job has no chunk function.  */
void cmacs_sherpa_job_post_chunk (CmacsSherpaJob *job, GVariant *chunk);

/* Root handle whose lock serialises ops (self, or the parent).  */
CmacsSherpaHandle *cmacs_sherpa_handle_root (CmacsSherpaHandle *h);

/* espeak-ng phonemes for voices sherpa no longer phonemizes itself
   (cmacs-sherpa-phonemize.c).  CODEPOINTS and LENS are gint32 arrays.  */
gboolean cmacs_sherpa_phonemize (const char *data_dir, const char *voice,
                                 const char *text, GArray *codepoints,
                                 GArray *lens, GError **error);

/* --- helpers shared by the family TUs --- */

/* float [-1,1] -> S16LE bytes, clamped.  (transfer full)  */
GBytes   *cmacs_sherpa_pcm_from_float (const float *samples, gsize n);
/* "ay" GVariant of S16LE bytes for N float samples.  (floating)  */
GVariant *cmacs_sherpa_variant_pcm (const float *samples, gsize n);
/* Error dictionary {"error": MESSAGE}.  (floating)  */
GVariant *cmacs_sherpa_variant_error (const char *message);

#endif /* CMACS_SHERPA_PRIVATE_H */
