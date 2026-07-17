/* cmacs-calculator-cli.h --- `emacs --calc' command-line entry

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_CALCULATOR_CLI_H
#define CMACS_CALCULATOR_CLI_H

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR

/* Rewrite `--calc [EXPR]' in ARGV into the equivalent `--batch --eval FORM',
 * so the calculator REPL runs with the Lisp VM up (its engine is GNU Calc,
 * which is Elisp -- it cannot use the --bacon style of bypassing Emacs init).
 *
 * Returns ARGV unchanged when --calc is absent, otherwise a new malloc'd
 * vector and *ARGCP updated to match.  Must be called from main() BEFORE
 * sort_args, so the substituted arguments go through Emacs's normal option
 * handling.  Never returns NULL.
 *
 * This header pulls in no Emacs types, so it is safe to include early.  */
extern char **cmacs_calculator_rewrite_args (int *argcp, char **argv);

#endif /* HAVE_CMACS_CALCULATOR */
#endif /* CMACS_CALCULATOR_CLI_H */
