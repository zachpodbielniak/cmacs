/* cmacs-calculator-init.c --- calculator subsystem init

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#include <config.h>

#ifdef HAVE_CMACS_CALCULATOR

#include "lisp.h"
#include "cmacs-calculator.h"

/* Idempotence guard: init_cmacs_calculator runs from src/emacs.c after
   terminal setup, and a dumped Emacs can reach it more than once.  */
static bool init_done = false;

void
syms_of_cmacs_calculator (void)
{
  syms_of_cmacs_calculator_defuns ();
}

void
init_cmacs_calculator (void)
{
  if (init_done)
    return;
  init_done = true;
  /* Nothing to set up eagerly: the engine is Elisp and loads on demand, and a
     chart view is created only when a buffer asks for one (which is also the
     first point a GL context is needed).  This hook exists so the subsystem
     has somewhere to grow into and to keep the src/emacs.c block uniform with
     the other subsystems.  */
}

#endif /* HAVE_CMACS_CALCULATOR */
