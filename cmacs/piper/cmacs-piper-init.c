/* cmacs-piper-init.c --- Subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_PIPER

#include "lisp.h"
#include "cmacs-piper.h"
#include <stdbool.h>

extern void syms_of_cmacs_piper_defuns (void);

static bool init_done = false;

void
syms_of_cmacs_piper (void)
{
  syms_of_cmacs_piper_defuns ();
}

void
init_cmacs_piper (void)
{
  if (init_done) return;
  init_done = true;
}

#endif /* HAVE_CMACS_PIPER */
