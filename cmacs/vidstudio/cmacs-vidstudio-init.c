/* cmacs-vidstudio-init.c --- Subsystem init + sym registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_VIDSTUDIO

#include "lisp.h"
#include "cmacs-vidstudio.h"

#include <stdbool.h>


static bool init_done = false;

void
syms_of_cmacs_vidstudio (void)
{
  syms_of_cmacs_vidstudio_defuns ();
}

void
init_cmacs_vidstudio (void)
{
  if (init_done)
    return;
  init_done = true;
  /* Projects are created lazily per editor buffer; nothing global here. */
}

#endif /* HAVE_CMACS_VIDSTUDIO */
