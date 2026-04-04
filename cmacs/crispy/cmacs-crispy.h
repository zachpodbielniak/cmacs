/* cmacs-crispy.h — Crispy C scripting integration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Native C evaluation inside Emacs via libcrispy.
 */

#ifndef CMACS_CRISPY_H
#define CMACS_CRISPY_H

#include <config.h>

#ifdef HAVE_CMACS_CRISPY

/* Register DEFUN primitives. */
extern void syms_of_cmacs_crispy (void);

#endif /* HAVE_CMACS_CRISPY */
#endif /* CMACS_CRISPY_H */
