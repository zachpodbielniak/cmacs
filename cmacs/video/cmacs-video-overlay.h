/* cmacs-video-overlay.h --- Cairo post-glyph paint hook for video.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_VIDEO_OVERLAY_H
#define CMACS_VIDEO_OVERLAY_H

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "lisp.h"
struct frame;
typedef struct _cairo cairo_t;

/* The paint hook called from pgtk_handle_draw.  Two passes:
 *   1. Standalone streams attached to FRAME (cmacs-video-mode).
 *   2. Buffer-anchored streams via per-leaf-window walk reading
 *      buffer-local `cmacs-video--streams'.
 * No-op when FRAME is not a pgtk frame. */
extern void cmacs_video_overlay_paint (struct frame *f, cairo_t *cr);

/* Cached symbol setup; called once from syms_of_cmacs_video. */
extern void cmacs_video_overlay_init_symbols (void);

#endif /* HAVE_CMACS_VIDEO */
#endif /* CMACS_VIDEO_OVERLAY_H */
