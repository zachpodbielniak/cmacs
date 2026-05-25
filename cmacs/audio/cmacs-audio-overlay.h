/* cmacs-audio-overlay.h --- Cairo paint hook for audio waveforms.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_AUDIO_OVERLAY_H
#define CMACS_AUDIO_OVERLAY_H

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
struct frame;
typedef struct _cairo cairo_t;

extern void cmacs_audio_overlay_paint (struct frame *f, cairo_t *cr);
extern void cmacs_audio_overlay_init_symbols (void);

#endif /* HAVE_CMACS_AUDIO */
#endif /* CMACS_AUDIO_OVERLAY_H */
