/* cmacs-bacon.h — Bacon shell integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * A C-native shell inside Emacs via libbacon.
 */

#ifndef CMACS_BACON_H
#define CMACS_BACON_H

#include <config.h>

#ifdef HAVE_CMACS_BACON

/* Register DEFUN primitives. */
extern void syms_of_cmacs_bacon (void);

#endif /* HAVE_CMACS_BACON */
#endif /* CMACS_BACON_H */
