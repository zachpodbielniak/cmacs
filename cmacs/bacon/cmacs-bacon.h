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

/* Enter bacon shell mode.  Called from main() when --bacon is detected.
   Strips argv[bacon_idx], runs the shell REPL, and never returns. */
extern _Noreturn void cmacs_bacon_main (int argc, char **argv, int bacon_idx);

#endif /* HAVE_CMACS_BACON */
#endif /* CMACS_BACON_H */
