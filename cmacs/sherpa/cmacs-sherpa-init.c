/* cmacs-sherpa-init.c --- subsystem init + symbol registration
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_SHERPA

#include "lisp.h"
#include "cmacs-sherpa.h"
#include "cmacs-sherpa-engine.h"
#include "cmacs-glib-loop.h"

#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_sherpa (void)
{
  syms_of_cmacs_sherpa_defuns ();
}

void
init_cmacs_sherpa (void)
{
  if (init_done)
    return;
  init_done = true;
  /* Results are delivered on the context cmacs pumps from pselect, so
     callbacks run on Emacs's thread with the input guard handled.  */
  cmacs_sherpa_engine_init (cmacs_glib_get_context ());
}

#endif /* HAVE_CMACS_SHERPA */
