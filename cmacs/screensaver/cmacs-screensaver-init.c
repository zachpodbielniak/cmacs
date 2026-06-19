/* cmacs-screensaver-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_SCREENSAVER

#include "lisp.h"
#include "cmacs-screensaver.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_screensaver (void)
{
  syms_of_cmacs_screensaver_defuns ();
}

void
init_cmacs_screensaver (void)
{
  if (init_done) return;
  init_done = true;
}

#endif /* HAVE_CMACS_SCREENSAVER */
