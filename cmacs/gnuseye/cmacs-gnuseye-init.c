/* cmacs-gnuseye-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_GNUSEYE

#include "lisp.h"
#include "cmacs-gnuseye.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_gnuseye (void)
{
  syms_of_cmacs_gnuseye_defuns ();
  syms_of_cmacs_gnuseye_geo ();
  syms_of_cmacs_gnuseye_sgp4 ();
  syms_of_cmacs_gnuseye_http ();
}

void
init_cmacs_gnuseye (void)
{
  if (init_done) return;
  init_done = true;
  cmacs_gnuseye_http_init ();
}

#endif /* HAVE_CMACS_GNUSEYE */
