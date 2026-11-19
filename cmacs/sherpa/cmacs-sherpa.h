/* cmacs-sherpa.h --- sherpa-onnx speech engine for cmacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Umbrella header for the lisp.h side of the subsystem.  The engine
 * side is cmacs-sherpa-engine.h (no Lisp); the two never include each
 * other's dependencies.  syms_of_cmacs_sherpa / init_cmacs_sherpa are
 * declared in src/lisp.h; the per-file entry points are declared here.
 */

#ifndef CMACS_SHERPA_H
#define CMACS_SHERPA_H

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

extern void syms_of_cmacs_sherpa_defuns (void);

#endif /* HAVE_CMACS_SHERPA */
#endif /* CMACS_SHERPA_H */
