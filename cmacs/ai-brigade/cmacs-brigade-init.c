/* cmacs-brigade-init.c --- subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"
#include <stdbool.h>

/* Forward-declared here rather than in the header so each unit's
 * registration entry point stays private to the fan-out below; the
 * local decl also avoids -Wredundant-decls against the definition. */
extern void syms_of_cmacs_ai_brigade_defuns    (void);
extern void syms_of_cmacs_ai_brigade_registry  (void);
extern void syms_of_cmacs_ai_brigade_allowlist (void);

GThread *cmacs_brigade__main_gthread = NULL;

static bool init_done = false;

void
syms_of_cmacs_ai_brigade (void)
{
  syms_of_cmacs_ai_brigade_defuns ();
  syms_of_cmacs_ai_brigade_registry ();
  syms_of_cmacs_ai_brigade_allowlist ();
}

void
init_cmacs_ai_brigade (void)
{
  if (init_done) return;
  init_done = true;
  /* Runs on the Emacs main thread.  Record it so any code that may be
   * reached from a worker thread can tell whether it has to marshal
   * back before touching Lisp. */
  cmacs_brigade__main_gthread = g_thread_self ();
  cmacs_brigade_registry_init ();
}

#endif /* HAVE_CMACS_AI_BRIGADE */
