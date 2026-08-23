/* cmacs-vidstudio.h --- Reel-based video editor subsystem.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_VIDSTUDIO_H
#define CMACS_VIDSTUDIO_H

#include <config.h>

#ifdef HAVE_CMACS_VIDSTUDIO

/* Per-file DEFUN registration entry points.  These are NOT in
   lisp.h -- only the subsystem's top-level syms_of_/init_ pair is
   -- so without them here each definition has no prototype.  */
extern void syms_of_cmacs_vidstudio_defuns (void);

#endif /* HAVE_CMACS_VIDSTUDIO */

#endif /* CMACS_VIDSTUDIO_H */
