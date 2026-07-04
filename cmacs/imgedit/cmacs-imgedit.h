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
extern void syms_of_cmacs_imgedit (void);

/* Post-Lisp runtime init (idempotent). */
extern void init_cmacs_imgedit (void);

#endif /* HAVE_CMACS_IMGEDIT */
#endif /* CMACS_IMGEDIT_H */
