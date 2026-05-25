/* cmacs-audio.h --- GStreamer-backed audio capture and playback for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header for the cmacs-audio subsystem.  Public entry points
 * for src/emacs.c (syms_of_cmacs_audio, init_cmacs_audio) and for
 * src/pgtkterm.c (cmacs_audio_overlay_paint).
 *
 * Mirrors cmacs-video architecturally: per-stream struct, PCM
 * double-buffer, bus watch attached to cmacs_glib_get_context(), and
 * per-stream Lisp_Object state in a staticpro'd hash table.
 *
 * Two pipeline shapes:
 *   CAPTURE:  pipewiresrc|pulsesrc ! audioconvert ! audioresample
 *             ! capsfilter(S16LE,mono,16kHz) ! appsink
 *   PLAYBACK: appsrc ! audioconvert ! audioresample ! autoaudiosink
 *
 * The 16 kHz/mono/S16LE capture caps are whisper.cpp-ready so capture
 * PCM can be handed straight to cmacs-whisper without resampling.
 */

#ifndef CMACS_AUDIO_H
#define CMACS_AUDIO_H

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "lisp.h"
struct frame;
typedef struct _cairo cairo_t;

/* Called from src/emacs.c during early Lisp init. */
extern void syms_of_cmacs_audio (void);

/* Called once at startup after Lisp is up.  Runs gst_init_check
 * (idempotent; harmless if cmacs-video already initialised it) and
 * registers the handle tables. */
extern void init_cmacs_audio (void);

/* Called from src/pgtkterm.c::pgtk_handle_draw AFTER the video
 * overlay paint pass.  Paints the cached waveform surface for any
 * audio stream anchored to a frame rect or a buffer marker. */
extern void cmacs_audio_overlay_paint (struct frame *f, cairo_t *cr);

#endif /* HAVE_CMACS_AUDIO */
#endif /* CMACS_AUDIO_H */
