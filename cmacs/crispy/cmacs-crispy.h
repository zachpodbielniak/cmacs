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

/* syms_of_cmacs_crispy is declared in lisp.h alongside the other
   cmacs subsystems. */

/* Entry point for `emacs --crispy' batch mode: run a crispy script,
   inline code, stdin, or the terminal REPL without initializing
   Emacs.  Called from main() in emacs.c.  Never returns. */
extern _Noreturn void cmacs_crispy_main (int argc, char **argv,
                                         int crispy_idx);

#endif /* HAVE_CMACS_CRISPY */
#endif /* CMACS_CRISPY_H */
