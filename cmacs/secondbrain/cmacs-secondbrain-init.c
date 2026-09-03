/* cmacs-secondbrain-init.c --- subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_SECONDBRAIN

#include "lisp.h"
#include "cmacs-secondbrain.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_secondbrain (void)
{
  syms_of_cmacs_secondbrain_defuns ();
}

void
init_cmacs_secondbrain (void)
{
  if (init_done) return;
  init_done = true;
  /* Nothing to set up eagerly: the graph, the layout and the render
     context are all created lazily, per buffer, on attach. */
}

#endif /* HAVE_CMACS_SECONDBRAIN */
