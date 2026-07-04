/* cmacs-imgedit-init.c --- Subsystem init + sym registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_IMGEDIT

#include "lisp.h"
#include "cmacs-imgedit.h"

#include <stdbool.h>

extern void syms_of_cmacs_imgedit_defuns (void);

static bool init_done = false;

void
syms_of_cmacs_imgedit (void)
{
  syms_of_cmacs_imgedit_defuns ();
}

void
init_cmacs_imgedit (void)
{
  if (init_done)
    return;
  init_done = true;
  /* The document model is created lazily per editor buffer; nothing global
     to initialise here yet. */
}

#endif /* HAVE_CMACS_IMGEDIT */
