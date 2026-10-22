/* cmacs-whisper-context.c --- whisper_context cache.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Holds a global hash mapping `model_path -> struct whisper_context*'.
 * First lookup loads + caches; subsequent lookups are O(1).  Thread-
 * safe via a single GMutex (only the loader path is contended).
 *
 * No automatic eviction at this stage: whisper models are large
 * (74 MB - 2.9 GB) but few in practice (usually one).  Future work:
 * idle-timer eviction after N seconds of disuse.
 *
 * A context's *default state* (the one `whisper_full' uses) is not
 * safe to share between threads, and the voice loop runs partial,
 * wake-word and final transcriptions that can overlap -- as can
 * cmacs-transcribe's parallel pool.  `cmacs_whisper_context_claim_default'
 * hands the default state to exactly one job at a time; a job that
 * loses the race allocates a private `whisper_state' instead (see
 * cmacs-whisper-job.c), so weights stay shared and inference stays
 * parallel without two threads ever writing one state.
 *
 * This file also installs the whisper/ggml log filter: whisper.cpp
 * logs several INFO lines per call, and the streaming VAD is called
 * ten times a second, which would fill the journal of a `--gowl'
 * session.  Only WARN and ERROR reach stderr unless the environment
 * variable CMACS_WHISPER_DEBUG is set.
 */

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include <glib.h>
#include <whisper.h>

#include <stdio.h>
#include "cmacs-whisper.h"

static GHashTable *contexts = NULL;
static GHashTable *default_busy = NULL; /* set of ctx whose default state
                                            is claimed; guarded by ctx_mtx */
static GMutex      ctx_mtx;
static gboolean    inited = FALSE;

/* Level of the last record printed, so GGML_LOG_LEVEL_CONT lines
   (continuations) follow the decision made for their first line.  */
static enum ggml_log_level log_last_level = GGML_LOG_LEVEL_NONE;
static gboolean            log_verbose = FALSE;

/* cmacs_whisper__log:
 * @level: the ggml log level of @text.
 * @text: one log record (usually newline-terminated).
 * @user: unused.
 *
 * whisper/ggml log callback that drops DEBUG and INFO records (unless
 * CMACS_WHISPER_DEBUG was set at init) and writes the rest to stderr.
 * Runs on whatever thread logged; touches only stdio and two statics
 * whose races are benign (a continuation line printed or not).  */
static void
cmacs_whisper__log (enum ggml_log_level level, const char *text, void *user)
{
  (void) user;
  if (level != GGML_LOG_LEVEL_CONT)
    log_last_level = level;
  if (!log_verbose && log_last_level < GGML_LOG_LEVEL_WARN)
    return;
  if (text)
    fputs (text, stderr);
}

void
cmacs_whisper_context_init (void)
{
  if (inited) return;
  g_mutex_init (&ctx_mtx);
  contexts = g_hash_table_new_full (g_str_hash, g_str_equal,
                                    g_free, NULL /* leak ctx on shutdown */);
  default_busy = g_hash_table_new (g_direct_hash, g_direct_equal);
  log_verbose = g_getenv ("CMACS_WHISPER_DEBUG") != NULL;
  whisper_log_set (cmacs_whisper__log, NULL);
  inited = TRUE;
}

struct whisper_context *
cmacs_whisper_context_get (const char *path, GError **error)
{
  if (!path || !*path)
    {
      g_set_error_literal (error, G_FILE_ERROR, G_FILE_ERROR_INVAL,
                           "cmacs-whisper: empty model path");
      return NULL;
    }
  cmacs_whisper_context_init ();
  g_mutex_lock (&ctx_mtx);
  struct whisper_context *ctx = g_hash_table_lookup (contexts, path);
  if (!ctx)
    {
      struct whisper_context_params cparams = whisper_context_default_params ();
      ctx = whisper_init_from_file_with_params (path, cparams);
      if (ctx)
        g_hash_table_insert (contexts, g_strdup (path), ctx);
      else
        g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                     "cmacs-whisper: failed to load model: %s", path);
    }
  g_mutex_unlock (&ctx_mtx);
  return ctx;
}

/* cmacs_whisper_context_claim_default:
 * @ctx: a context returned by cmacs_whisper_context_get().
 *
 * Try to take exclusive use of @ctx's default state.  Never blocks.
 *
 * Returns: TRUE when the caller may run `whisper_full' on @ctx and must
 * later call cmacs_whisper_context_release_default(); FALSE when another
 * job holds it and the caller should use a private state.  */
gboolean
cmacs_whisper_context_claim_default (struct whisper_context *ctx)
{
  gboolean won;

  cmacs_whisper_context_init ();
  g_mutex_lock (&ctx_mtx);
  won = !g_hash_table_contains (default_busy, ctx);
  if (won)
    g_hash_table_add (default_busy, ctx);
  g_mutex_unlock (&ctx_mtx);
  return won;
}

/* cmacs_whisper_context_release_default:
 * @ctx: a context whose default state the caller claimed.
 *
 * Give @ctx's default state back.  */
void
cmacs_whisper_context_release_default (struct whisper_context *ctx)
{
  g_mutex_lock (&ctx_mtx);
  g_hash_table_remove (default_busy, ctx);
  g_mutex_unlock (&ctx_mtx);
}

void
cmacs_whisper_context_free_all (void)
{
  if (!inited) return;
  g_mutex_lock (&ctx_mtx);
  GHashTableIter it;
  gpointer key, val;
  g_hash_table_iter_init (&it, contexts);
  while (g_hash_table_iter_next (&it, &key, &val))
    whisper_free ((struct whisper_context *) val);
  g_hash_table_remove_all (contexts);
  g_mutex_unlock (&ctx_mtx);
}

#endif /* HAVE_CMACS_WHISPER */
