/* cmacs-ink-overlay.h — Post-glyph stroke overlay paint pass
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Hooked into pgtk_handle_draw in src/pgtkterm.c (GTK's `draw'
 * signal handler).  Walks every leaf window of the frame, reads
 * the buffer-local list `cmacs-ink-region--annotations', and paints
 * transparent stroke layers on top of the already-presented glyphs.
 * The cairo_t argument is the GTK widget's per-draw context, NOT
 * the pgtk frame's persistent back-surface context — paint here is
 * idempotent across redisplays.  Earlier versions hooked into the
 * post-glyph back-surface paint, which accumulated alpha across
 * redisplays (each redisplay added another 0.5α stroke layer onto
 * the unchanged pixels of the persistent back surface, driving
 * highlighter to apparent full opacity within a few cursor blinks).
 *
 * No-op when:
 *   - HAVE_PGTK is undefined
 *   - frame is not a pgtk frame
 *   - the buffer has no annotations or the mode is off
 */

#ifndef CMACS_INK_OVERLAY_H
#define CMACS_INK_OVERLAY_H

#include "lisp.h"

struct frame;
typedef struct _cairo cairo_t;

extern void cmacs_ink_overlay_paint (struct frame *f, cairo_t *cr);
extern void syms_of_cmacs_ink_overlay (void);

#endif /* CMACS_INK_OVERLAY_H */
