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
 */

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include <glib.h>
#include <whisper.h>

static GHashTable *contexts = NULL;
static GMutex      ctx_mtx;
static gboolean    inited = FALSE;

void cmacs_whisper_context_init (void);
struct whisper_context *cmacs_whisper_context_get (const char *path,
                                                   GError **error);
void cmacs_whisper_context_free_all (void);

void
cmacs_whisper_context_init (void)
{
  if (inited) return;
  g_mutex_init (&ctx_mtx);
  contexts = g_hash_table_new_full (g_str_hash, g_str_equal,
                                    g_free, NULL /* leak ctx on shutdown */);
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
