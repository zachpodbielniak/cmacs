/* cmacs-libregnum-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_LIBREGNUM

#include "lisp.h"
#include "cmacs-libregnum.h"
#include <stdbool.h>

extern void syms_of_cmacs_libregnum_defuns   (void);

#ifdef HAVE_PGTK
extern void syms_of_cmacs_libregnum_dnd (void);
#endif

static bool init_done = false;

void
syms_of_cmacs_libregnum (void)
{
  syms_of_cmacs_libregnum_defuns ();
#ifdef HAVE_PGTK
  syms_of_cmacs_libregnum_dnd ();
#endif
}

void
init_cmacs_libregnum (void)
{
  if (init_done) return;
  init_done = true;
  cmacs_libregnum_view_registry_init ();
}

#endif /* HAVE_CMACS_LIBREGNUM */
