/* cmacs-roamgraph-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_ROAMGRAPH

#include "lisp.h"
#include "cmacs-roamgraph.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_roamgraph (void)
{
  syms_of_cmacs_roamgraph_defuns ();
  syms_of_cmacs_roamgraph_scan ();
}

void
init_cmacs_roamgraph (void)
{
  if (init_done) return;
  init_done = true;
  /* Nothing to set up eagerly: the graph, the solver and the render
     context are all created lazily, per buffer, on attach. */
}

#endif /* HAVE_CMACS_ROAMGRAPH */
