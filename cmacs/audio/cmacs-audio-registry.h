/* cmacs-audio-registry.h --- handle -> stream map + per-frame list.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Direct parallel of cmacs-video-registry; see that file for the
 * rationale on the two indexes (global handle table + per-frame
 * standalone list).
 */

#ifndef CMACS_AUDIO_REGISTRY_H
#define CMACS_AUDIO_REGISTRY_H

#include <config.h>

#ifdef HAVE_CMACS_AUDIO

#include "cmacs-audio-stream.h"
#include <glib.h>

struct frame;

extern void cmacs_audio_registry_init (void);
extern uint64_t cmacs_audio_registry_insert (CmacsAudioStream *stream);
extern CmacsAudioStream *cmacs_audio_registry_lookup (uint64_t handle);
extern void cmacs_audio_registry_remove (uint64_t handle);
extern GList *cmacs_audio_registry_handles (void);

extern void cmacs_audio_registry_attach_frame (struct frame      *frame,
                                               CmacsAudioStream  *stream);
extern void cmacs_audio_registry_detach_frame (struct frame      *frame,
                                               CmacsAudioStream  *stream);
extern GSList *cmacs_audio_registry_frame_streams (struct frame *frame);
extern void cmacs_audio_registry_drop_frame (struct frame *frame);

#endif /* HAVE_CMACS_AUDIO */
#endif /* CMACS_AUDIO_REGISTRY_H */
