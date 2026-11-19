/* cmacs-sherpa-engine.h --- sherpa-onnx engine core (no Lisp, no sherpa)
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The engine half of cmacs-sherpa.  It owns every sherpa-onnx object,
 * the worker threads that drive them, and job cancellation.  It never
 * includes lisp.h, and this header never includes sherpa's c-api.h, so
 * the two halves of the subsystem meet only through what is declared
 * here: C strings, GBytes of S16LE PCM, GHashTables of string config,
 * integer handles, and GVariant results.
 *
 * Threading model
 * ---------------
 * - Every handle has its own single-thread GThreadPool, so the jobs on
 *   one handle run strictly in the order they were submitted (a stream
 *   must see its audio in order; a VAD's state carries across feeds).
 * - Every operation also takes the lock of the handle's ROOT (itself,
 *   or its parent for a stream), so two streams of one recognizer never
 *   decode concurrently.  Parallelism comes from opening more handles.
 * - Results reach the caller's DONE / CHUNK functions on the main
 *   GMainContext handed to cmacs_sherpa_engine_init, never on a worker.
 *   DONE is called exactly once per accepted job -- with
 *   {"cancelled": true} for a cancelled one -- and USER_DATA is released
 *   with its GDestroyNotify right after.
 */

#ifndef CMACS_SHERPA_ENGINE_H
#define CMACS_SHERPA_ENGINE_H

#include <glib.h>
#include <stdint.h>

G_BEGIN_DECLS

/**
 * CmacsSherpaKind:
 * @CMACS_SHERPA_KIND_ASR: non-streaming recognizer (whisper, parakeet, ...)
 * @CMACS_SHERPA_KIND_STREAM_ASR: streaming recognizer (zipformer, ...)
 * @CMACS_SHERPA_KIND_STREAM: one stream of a STREAM_ASR parent
 * @CMACS_SHERPA_KIND_KWS: keyword spotter
 * @CMACS_SHERPA_KIND_KWS_STREAM: one stream of a KWS parent
 * @CMACS_SHERPA_KIND_VAD: voice activity detector (silero / ten-vad)
 * @CMACS_SHERPA_KIND_TTS: text to speech (vits, kokoro, matcha, ...)
 * @CMACS_SHERPA_KIND_DIARIZE: offline speaker diarization
 * @CMACS_SHERPA_KIND_SPEAKER: speaker embedding extractor plus manager
 * @CMACS_SHERPA_KIND_PUNCT: offline punctuation
 * @CMACS_SHERPA_KIND_PUNCT_ONLINE: online (cased) punctuation
 * @CMACS_SHERPA_KIND_LID: spoken language identification
 * @CMACS_SHERPA_KIND_TAG: audio tagging
 * @CMACS_SHERPA_KIND_DENOISE: offline speech enhancement
 * @CMACS_SHERPA_KIND_DENOISE_STREAM: streaming speech enhancement
 * @CMACS_SHERPA_KIND_SEPARATE: source separation (vocals / accompaniment)
 *
 * What a handle is.  The Lisp names are cmacs_sherpa_kind_name().
 */
typedef enum
{
  CMACS_SHERPA_KIND_ASR = 0,
  CMACS_SHERPA_KIND_STREAM_ASR,
  CMACS_SHERPA_KIND_STREAM,
  CMACS_SHERPA_KIND_KWS,
  CMACS_SHERPA_KIND_KWS_STREAM,
  CMACS_SHERPA_KIND_VAD,
  CMACS_SHERPA_KIND_TTS,
  CMACS_SHERPA_KIND_DIARIZE,
  CMACS_SHERPA_KIND_SPEAKER,
  CMACS_SHERPA_KIND_PUNCT,
  CMACS_SHERPA_KIND_PUNCT_ONLINE,
  CMACS_SHERPA_KIND_LID,
  CMACS_SHERPA_KIND_TAG,
  CMACS_SHERPA_KIND_DENOISE,
  CMACS_SHERPA_KIND_DENOISE_STREAM,
  CMACS_SHERPA_KIND_SEPARATE,
  CMACS_SHERPA_N_KINDS
} CmacsSherpaKind;

/**
 * CmacsSherpaOp:
 * @CMACS_SHERPA_OP_RUN: the kind's one-shot operation (transcribe,
 *   generate, diarize, embed, punctuate, identify language, tag,
 *   denoise, separate)
 * @CMACS_SHERPA_OP_FEED: push audio into a streaming kind
 * @CMACS_SHERPA_OP_FINISH: end of input for a streaming kind; flush
 * @CMACS_SHERPA_OP_RESET: drop a streaming kind's state
 * @CMACS_SHERPA_OP_ENROLL: SPEAKER: embed PCM and register it as TEXT
 * @CMACS_SHERPA_OP_ADD_EMBEDDING: SPEAKER: register raw float32
 *   embedding bytes (in the PCM slot) as TEXT
 * @CMACS_SHERPA_OP_IDENTIFY: SPEAKER: best enrolled matches for PCM
 * @CMACS_SHERPA_OP_VERIFY: SPEAKER: does PCM match enrolled speaker TEXT
 * @CMACS_SHERPA_OP_REMOVE: SPEAKER: forget speaker TEXT
 * @CMACS_SHERPA_OP_LIST: SPEAKER: enrolled speaker names
 */
typedef enum
{
  CMACS_SHERPA_OP_RUN = 0,
  CMACS_SHERPA_OP_FEED,
  CMACS_SHERPA_OP_FINISH,
  CMACS_SHERPA_OP_RESET,
  CMACS_SHERPA_OP_ENROLL,
  CMACS_SHERPA_OP_ADD_EMBEDDING,
  CMACS_SHERPA_OP_IDENTIFY,
  CMACS_SHERPA_OP_VERIFY,
  CMACS_SHERPA_OP_REMOVE,
  CMACS_SHERPA_OP_LIST
} CmacsSherpaOp;

/**
 * CmacsSherpaDoneFn:
 * @result: (transfer none): an a{sv} dictionary; never %NULL.  A
 *   failure is {"error": s}; a cancelled job is {"cancelled": b}.
 * @user_data: the pointer given at submission
 *
 * Called once per job on the main context.
 */
typedef void (*CmacsSherpaDoneFn) (GVariant *result, gpointer user_data);

/**
 * CmacsSherpaChunkFn:
 * @chunk: (transfer none): an a{sv} dictionary -- audio as it is
 *   generated ({"pcm": ay, "sample-rate": i, "progress": d}) or progress
 *   alone ({"progress": d})
 * @user_data: the pointer given at submission
 *
 * Called zero or more times before the job's DONE, on the main context.
 */
typedef void (*CmacsSherpaChunkFn) (GVariant *chunk, gpointer user_data);

/* Error domain for every GError this engine sets.  */
#define CMACS_SHERPA_ERROR (cmacs_sherpa_error_quark ())
GQuark cmacs_sherpa_error_quark (void);

/**
 * cmacs_sherpa_engine_init:
 * @main_context: (transfer none): where DONE / CHUNK functions run
 *
 * Idempotent.  Must be called on the main thread before anything else.
 */
void cmacs_sherpa_engine_init (GMainContext *main_context);

/* Version strings, owned by sherpa-onnx; never NULL.  */
const char *cmacs_sherpa_version (void);
const char *cmacs_sherpa_onnxruntime_version (void);

/* Kind <-> its Lisp name ("asr", "stream-asr", "tts", ...).  */
const char *cmacs_sherpa_kind_name (CmacsSherpaKind kind);
gboolean    cmacs_sherpa_kind_from_name (const char *name,
                                         CmacsSherpaKind *out);

/**
 * cmacs_sherpa_config_keys:
 * @kind: a kind
 *
 * Returns: (transfer full): an a(ss) array of (KEY, TYPE) for every
 * config key @kind accepts, TYPE being "string", "int" or "float".
 */
GVariant *cmacs_sherpa_config_keys (CmacsSherpaKind kind);

/**
 * cmacs_sherpa_open:
 * @kind: what to create
 * @config: (transfer none): string -> string config (see
 *   doc_org/cmacs/cmacs-sherpa.org); keys are sherpa field paths with
 *   `_' spelled `-', and may omit a leading "model-config." / "model."
 * @parent: the parent handle for STREAM / KWS_STREAM kinds, else 0
 * @error: return location for a #GError
 *
 * Load synchronously (can take seconds for a large model; Lisp uses
 * cmacs_sherpa_open_async).
 *
 * Returns: a non-zero handle, or 0 with @error set.
 */
guint64 cmacs_sherpa_open (CmacsSherpaKind kind, GHashTable *config,
                           guint64 parent, GError **error);

/**
 * cmacs_sherpa_open_async:
 * @kind: what to create
 * @config: (transfer none): as for cmacs_sherpa_open (copied)
 * @parent: as for cmacs_sherpa_open
 * @done: called on the main context with {"handle": t} or {"error": s}
 * @user_data: passed to @done
 * @user_data_free: (nullable): releases @user_data after @done
 *
 * Load on a loader thread.
 */
void cmacs_sherpa_open_async (CmacsSherpaKind kind, GHashTable *config,
                              guint64 parent, CmacsSherpaDoneFn done,
                              gpointer user_data,
                              GDestroyNotify user_data_free);

/**
 * cmacs_sherpa_close:
 * @handle: a handle
 *
 * Forget @handle.  Jobs still queued on it complete as cancelled; the
 * sherpa object is destroyed once the last running job lets go of it.
 *
 * Returns: %FALSE if @handle was unknown.
 */
gboolean cmacs_sherpa_close (guint64 handle);

/**
 * cmacs_sherpa_submit:
 * @handle: target handle
 * @op: what to do
 * @pcm: (nullable) (transfer none): S16LE mono PCM; for
 *   %CMACS_SHERPA_OP_ADD_EMBEDDING, native float32 values instead
 * @sample_rate: rate of @pcm (0 means 16000)
 * @text: (nullable): text input (TTS, punctuation, speaker name)
 * @params: (nullable) (transfer none): per-job string parameters
 * @done: completion, on the main context
 * @chunk: (nullable): streaming audio / progress, on the main context
 * @user_data: passed to @done and @chunk
 * @user_data_free: (nullable): releases @user_data after @done
 * @error: return location for a #GError
 *
 * Returns: a non-zero job id (for cmacs_sherpa_cancel), or 0 with
 * @error set, in which case neither callback will ever run and
 * @user_data is NOT released.
 */
guint64 cmacs_sherpa_submit (guint64 handle, CmacsSherpaOp op,
                             GBytes *pcm, int sample_rate, const char *text,
                             GHashTable *params, CmacsSherpaDoneFn done,
                             CmacsSherpaChunkFn chunk, gpointer user_data,
                             GDestroyNotify user_data_free, GError **error);

/**
 * cmacs_sherpa_run_sync:
 * @handle: target handle
 * @op: what to do
 * @pcm: (nullable): as for cmacs_sherpa_submit
 * @sample_rate: rate of @pcm (0 means 16000)
 * @text: (nullable): text input
 * @params: (nullable): per-job string parameters
 * @error: return location for a #GError
 *
 * Run @op on the CALLING thread and return its result -- for RPC
 * surfaces that answer synchronously, as whisper's sync transcription
 * always has.  Waits behind any job already running on the handle.
 * Chunks are not delivered.
 *
 * Returns: (transfer full) (nullable): the a{sv} result, or %NULL with
 * @error set.
 */
GVariant *cmacs_sherpa_run_sync (guint64 handle, CmacsSherpaOp op, GBytes *pcm,
                                 int sample_rate, const char *text,
                                 GHashTable *params, GError **error);

/* Cancel a job.  Queued: it completes as cancelled without running.
   Running TTS: generation stops at the next chunk.  Other running jobs
   finish and are then reported as cancelled.  FALSE if unknown/done.  */
gboolean cmacs_sherpa_cancel (guint64 job);

/* Static facts about a handle (sample-rate, num-speakers, dim, ...) as
   a{sv}; NULL if unknown.  (transfer full)  */
GVariant *cmacs_sherpa_info (guint64 handle);

/* Every open handle: aa{sv} with id, kind, model, parent, jobs,
   pending, opened, last-used.  (transfer full)  */
GVariant *cmacs_sherpa_list (void);

/* Read a PCM WAV file (any rate; first channel) as S16LE bytes, with
   its rate in *SAMPLE_RATE.  (transfer full) (nullable)  */
GBytes *cmacs_sherpa_read_wave (const char *path, int *sample_rate,
                                GError **error);

/* Check keyword LINES against the model's tokens before sherpa sees
   them (a bad line crashes sherpa later).  */
gboolean cmacs_sherpa_kws_validate (const char *tokens_path,
                                    const char *keywords, GError **error);

/* Spell PHRASE as a keyword-spotter line using the model's tokens.txt
   (cmacs-sherpa-kws-tokens.c).  (transfer full)  */
char *cmacs_sherpa_kws_tokenize (const char *tokens_path, const char *phrase,
                                 gboolean cjk, GError **error);

G_END_DECLS

#endif /* CMACS_SHERPA_ENGINE_H */
