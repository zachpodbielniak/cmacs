/* cmacs-ink-overlay.h — Post-glyph stroke overlay paint pass
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Hooked into pgtk_frame_up_to_date in src/pgtkterm.c.  Walks every
 * leaf window of the frame, reads the buffer-local list
 * `cmacs-ink-region--annotations', and paints transparent stroke
 * layers on top of the already-rendered glyphs.  Strokes track the
 * underlying text via per-redisplay pos_visible_p lookups, so the
 * buffer text remains live and editable.
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

extern void cmacs_ink_overlay_paint (struct frame *f);
extern void syms_of_cmacs_ink_overlay (void);

#endif /* CMACS_INK_OVERLAY_H */
