/* cmacs-whisper.h --- whisper.cpp offline STT for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header.  whisper.cpp models are loaded on first reference
 * and cached in a path -> context hash; subsequent calls reuse the
 * loaded weights.  Inference runs on a worker thread so the Emacs main
 * thread never blocks.
 *
 * The functions declared here are the ones shared between this
 * subsystem's translation units; per-file entry points that predate
 * the header are still declared next to their callers.
 */

#ifndef CMACS_WHISPER_H
#define CMACS_WHISPER_H

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include "lisp.h"
#include <glib.h>
#include <stdint.h>

struct whisper_context;

/* Samples per window of the Silero VAD model whisper.cpp ships: 512
   at 16 kHz, i.e. 32 ms.  whisper.h does not export the value; the
   ggml Silero conversion fixes it.  */
#define CMACS_WHISPER_VAD_WINDOW (512)

/* --- cmacs-whisper-context.c --- */
extern void     cmacs_whisper_context_init (void);
extern struct whisper_context *cmacs_whisper_context_get (const char *path,
                                                          GError **error);
extern void     cmacs_whisper_context_free_all (void);
extern gboolean cmacs_whisper_context_claim_default (struct whisper_context *ctx);
extern void     cmacs_whisper_context_release_default (struct whisper_context *ctx);

/* --- cmacs-whisper-job.c: streaming VAD --- */
extern uint64_t cmacs_whisper_vad_open (const char *model_path, int n_threads);
extern gboolean cmacs_whisper_vad_feed (uint64_t handle, const int16_t *pcm,
                                        size_t n_samples, Lisp_Object callback);
extern gboolean cmacs_whisper_vad_reset (uint64_t handle);
extern gboolean cmacs_whisper_vad_close (uint64_t handle);
extern Lisp_Object cmacs_whisper_vad_list (void);

#endif /* HAVE_CMACS_WHISPER */
#endif /* CMACS_WHISPER_H */
