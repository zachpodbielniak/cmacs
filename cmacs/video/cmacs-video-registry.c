/* cmacs-video-registry.c --- handle table + per-frame standalone list.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "cmacs-video-registry.h"
#include <stdatomic.h>

static GHashTable *handles_by_id    = NULL; /* uint64 -> CmacsVideoStream* */
static GHashTable *streams_by_frame = NULL; /* struct frame* -> GSList* */
static GMutex      registry_mtx;
static GMutex      frame_mtx;               /* guards streams_by_frame */
static _Atomic uint64_t next_handle = 1;
static gboolean    registry_inited = FALSE;

static gboolean
uint64_equal (gconstpointer a, gconstpointer b)
{
  return *(const uint64_t *)a == *(const uint64_t *)b;
}

static guint
uint64_hash (gconstpointer a)
{
  uint64_t v = *(const uint64_t *)a;
  return (guint)(v ^ (v >> 32));
}

void
cmacs_video_registry_init (void)
{
  if (registry_inited)
    return;
  g_mutex_init (&registry_mtx);
  g_mutex_init (&frame_mtx);
  handles_by_id    = g_hash_table_new_full (uint64_hash, uint64_equal,
                                            g_free, NULL);
  streams_by_frame = g_hash_table_new (g_direct_hash, g_direct_equal);
  registry_inited  = TRUE;
}

uint64_t
cmacs_video_registry_insert (CmacsVideoStream *stream)
{
  if (!stream)
    return 0;
  uint64_t h = atomic_fetch_add (&next_handle, 1);
  stream->handle = h;

  uint64_t *key = g_malloc (sizeof *key);
  *key = h;

  g_mutex_lock (&registry_mtx);
  g_hash_table_insert (handles_by_id, key, stream);
  g_mutex_unlock (&registry_mtx);
  return h;
}

CmacsVideoStream *
cmacs_video_registry_lookup (uint64_t handle)
{
  CmacsVideoStream *s = NULL;
  g_mutex_lock (&registry_mtx);
  s = g_hash_table_lookup (handles_by_id, &handle);
  g_mutex_unlock (&registry_mtx);
  return s;
}

void
cmacs_video_registry_remove (uint64_t handle)
{
  g_mutex_lock (&registry_mtx);
  g_hash_table_remove (handles_by_id, &handle);
  g_mutex_unlock (&registry_mtx);
}

GList *
cmacs_video_registry_handles (void)
{
  GList *out = NULL;
  g_mutex_lock (&registry_mtx);
  GHashTableIter iter;
  gpointer key, val;
  g_hash_table_iter_init (&iter, handles_by_id);
  while (g_hash_table_iter_next (&iter, &key, &val))
    {
      uint64_t *h = g_new (uint64_t, 1);
      *h = *(uint64_t *)key;
      out = g_list_prepend (out, h);
    }
  g_mutex_unlock (&registry_mtx);
  return out;
}

void
cmacs_video_registry_attach_frame (struct frame *frame, CmacsVideoStream *stream)
{
  if (!frame || !stream)
    return;
  g_mutex_lock (&frame_mtx);
  GSList *list = g_hash_table_lookup (streams_by_frame, frame);
  if (!g_slist_find (list, stream))
    {
      list = g_slist_prepend (list, stream);
      g_hash_table_insert (streams_by_frame, frame, list);
    }
  g_mutex_unlock (&frame_mtx);
}

void
cmacs_video_registry_detach_frame (struct frame *frame, CmacsVideoStream *stream)
{
  if (!frame || !stream)
    return;
  g_mutex_lock (&frame_mtx);
  GSList *list = g_hash_table_lookup (streams_by_frame, frame);
  if (list)
    {
      GSList *new_list = g_slist_remove (list, stream);
      if (new_list)
        g_hash_table_insert (streams_by_frame, frame, new_list);
      else
        g_hash_table_remove (streams_by_frame, frame);
    }
  g_mutex_unlock (&frame_mtx);
}

GSList *
cmacs_video_registry_frame_streams (struct frame *frame)
{
  if (!frame)
    return NULL;
  g_mutex_lock (&frame_mtx);
  GSList *src = g_hash_table_lookup (streams_by_frame, frame);
  GSList *copy = g_slist_copy (src);
  g_mutex_unlock (&frame_mtx);
  return copy;
}

void
cmacs_video_registry_drop_frame (struct frame *frame)
{
  if (!frame)
    return;
  /* Take a copy under mutex, then close each stream outside the
   * mutex so the destructor can grab the registry mutex itself. */
  g_mutex_lock (&frame_mtx);
  GSList *src = g_hash_table_lookup (streams_by_frame, frame);
  GSList *copy = g_slist_copy (src);
  g_hash_table_remove (streams_by_frame, frame);
  g_mutex_unlock (&frame_mtx);

  for (GSList *l = copy; l; l = l->next)
    {
      CmacsVideoStream *s = l->data;
      cmacs_video_registry_remove (s->handle);
      cmacs_video_stream_destroy (s);
    }
  g_slist_free (copy);
}

#endif /* HAVE_CMACS_VIDEO */
