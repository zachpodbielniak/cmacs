/* cmacs-office-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later */

#include <config.h>

#ifdef HAVE_CMACS_OFFICE

#include "lisp.h"
#include "cmacs-office.h"
#include "cmacs-office-xml.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_office (void)
{
  syms_of_cmacs_office_defuns ();
}

void
init_cmacs_office (void)
{
  if (init_done) return;
  init_done = true;

  /* Documents are opened lazily, one handle each, and libzip needs no
     setup.  libxml2 does want an explicit init before first use, and
     this process shares it with upstream Emacs's src/xml.c -- so it is
     initialised here and deliberately never torn down. */
  cmacs_office_xml_init ();
}

#endif /* HAVE_CMACS_OFFICE */
