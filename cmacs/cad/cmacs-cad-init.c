/* cmacs-cad-init.c --- Subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_CAD

#include "lisp.h"
#include "cmacs-cad.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_cad (void)
{
  syms_of_cmacs_cad_defuns ();
  syms_of_cmacs_cad_sketch ();
}

void
init_cmacs_cad (void)
{
  if (init_done) return;
  init_done = true;
}

#endif /* HAVE_CMACS_CAD */
