/* cmacs-imgedit.h --- 2D image / sprite editor subsystem.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef CMACS_IMGEDIT_H
#define CMACS_IMGEDIT_H

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

/* Registers the cmacs-imgedit-* DEFUNs (called from syms_of_* in emacs.c). */

/* Post-Lisp runtime init (idempotent). */

/* Per-file DEFUN registration entry points.  These are NOT in
   lisp.h -- only the subsystem's top-level syms_of_/init_ pair is
   -- so without them here each definition has no prototype.  */
extern void syms_of_cmacs_imgedit_defuns (void);

#endif /* HAVE_CMACS_IMGEDIT */

#endif /* CMACS_IMGEDIT_H */
