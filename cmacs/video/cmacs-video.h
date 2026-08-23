/* cmacs-video.h --- GStreamer-backed video overlay for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header for the cmacs-video subsystem.  Public entry points
 * for src/emacs.c (syms_of_cmacs_video, init_cmacs_video) and for
 * src/pgtkterm.c (cmacs_video_overlay_paint).
 *
 * Compositor-agnostic: the paint hook runs inside pgtk_handle_draw,
 * so cmacs-video works under any Wayland/X11 compositor (mutter,
 * kwin, sway, hyprland, weston, gowl, X11+pgtk).  Has NO dependency
 * on --with-cmacs-gowl.
 */

#ifndef CMACS_VIDEO_H
#define CMACS_VIDEO_H

#include <config.h>

#ifdef HAVE_CMACS_VIDEO

#include "lisp.h"
struct frame;
typedef struct _cairo cairo_t;

/* Called from src/emacs.c during early Lisp init. */

/* Called once at startup after Lisp is up; runs gst_init_check
 * and registers the registry tables.  Safe to call multiple times. */

/* Called from src/pgtkterm.c::pgtk_handle_draw AFTER the back-surface
 * copy and BEFORE cmacs_ink_overlay_paint, so that:
 *   1. Text lands on the per-event cr (back-surface copy).
 *   2. Video frames blit on top of text at the overlay's rectangle.
 *   3. Ink strokes blit on top of video (annotations on live feeds).
 * No-op when no streams are anchored to this frame or any of its
 * windows' buffers.
 *
 * Declared by cmacs-video-overlay.h and pulled in here rather than
 * repeated: pgtkterm.c includes only this umbrella, the overlay TU
 * includes only that header, and two copies of the prototype is a
 * redundant redeclaration in every file that sees both.  */
#include "cmacs-video-overlay.h"

#endif /* HAVE_CMACS_VIDEO */
#endif /* CMACS_VIDEO_H */
