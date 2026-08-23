/* cmacs-piper.h --- Piper offline TTS for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Piper is invoked as a subprocess via GSubprocess; PCM (S16LE) is
 * read from its stdout and either fed to a cmacs-audio playback
 * stream or written to a WAV file.
 */

#ifndef CMACS_PIPER_H
#define CMACS_PIPER_H

#include <config.h>

#ifdef HAVE_CMACS_PIPER

#include "lisp.h"

#endif /* HAVE_CMACS_PIPER */
#endif /* CMACS_PIPER_H */
