/* cmacs-whisper-init.c --- subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_WHISPER

#include "lisp.h"
#include "cmacs-whisper.h"
#include <stdbool.h>

extern void syms_of_cmacs_whisper_defuns (void);
extern void cmacs_whisper_context_init (void);
extern void cmacs_whisper_context_free_all (void);

static bool init_done = false;

void
syms_of_cmacs_whisper (void)
{
  syms_of_cmacs_whisper_defuns ();
}

void
init_cmacs_whisper (void)
{
  if (init_done) return;
  init_done = true;
  cmacs_whisper_context_init ();
}

#endif /* HAVE_CMACS_WHISPER */
