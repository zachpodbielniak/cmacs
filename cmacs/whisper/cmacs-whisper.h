/* cmacs-whisper.h --- whisper.cpp offline STT for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header.  whisper.cpp models are loaded on first reference
 * and cached in a path -> context hash; subsequent calls reuse the
 * loaded weights.  Inference runs on a libdex thread-pool worker so
 * the Emacs main thread never blocks.
 */

#ifndef CMACS_WHISPER_H
#define CMACS_WHISPER_H

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include "lisp.h"

#endif /* HAVE_CMACS_WHISPER */
#endif /* CMACS_WHISPER_H */
