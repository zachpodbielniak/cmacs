/* cmacs-video-registry.h --- handle -> stream map + per-frame standalone list.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Two indexes:
 *   1. Global handle table: uint64 -> CmacsVideoStream*.  Used by every
 *      DEFUN that takes a HANDLE.  Lookup is single-threaded (main
 *      thread only) but the table is mutex-guarded for defence in
 *      depth (snapshot/destroy paths could later add async callers).
 *   2. Per-frame standalone list: struct frame * -> GSList of streams.
 *      Used by the paint walker for streams anchored to a frame rect
 *      rather than to a buffer marker (i.e. cmacs-video-mode buffers).
 */

#ifndef CMACS_VIDEO_REGISTRY_H
#define CMACS_VIDEO_REGISTRY_H

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "cmacs-video-stream.h"
#include <glib.h>

struct frame;

/* Called once from init_cmacs_video. */
extern void cmacs_video_registry_init (void);

/* Returns a fresh monotonic handle and inserts STREAM into the table. */
extern uint64_t cmacs_video_registry_insert (CmacsVideoStream *stream);

/* Returns NULL if the handle is unknown or already closed. */
extern CmacsVideoStream *cmacs_video_registry_lookup (uint64_t handle);

/* Removes a handle from the table; safe to call even if not present. */
extern void cmacs_video_registry_remove (uint64_t handle);

/* Returns a fresh GList<uint64_t> of all live handles (caller frees with
 * g_list_free).  Used by `cmacs-video-list' and the shutdown sweep. */
extern GList *cmacs_video_registry_handles (void);

/* --- Per-frame standalone anchor list --- */

/* Adds STREAM to the GSList for FRAME.  Idempotent. */
extern void cmacs_video_registry_attach_frame (struct frame      *frame,
                                               CmacsVideoStream  *stream);

/* Removes STREAM from FRAME's GSList.  No-op if not present. */
extern void cmacs_video_registry_detach_frame (struct frame      *frame,
                                               CmacsVideoStream  *stream);

/* Returns a *fresh copy* of FRAME's GSList of CmacsVideoStream*
 * pointers.  Caller MUST g_slist_free the returned list (NOT
 * g_slist_free_full).  Returned under mutex so the underlying list
 * may safely change after this returns. */
extern GSList *cmacs_video_registry_frame_streams (struct frame *frame);

/* Drops every entry whose frame == FRAME, closing each stream
 * synchronously.  Hooked into delete-frame-functions from Lisp. */
extern void cmacs_video_registry_drop_frame (struct frame *frame);

#endif /* HAVE_CMACS_VIDEO */
#endif /* CMACS_VIDEO_REGISTRY_H */
