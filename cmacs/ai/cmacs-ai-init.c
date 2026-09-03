/* cmacs-ai-init.c --- subsystem init + symbol registration.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "lisp.h"
#include "cmacs-ai.h"
#include <stdbool.h>

extern void syms_of_cmacs_ai_defuns        (void);
extern void syms_of_cmacs_ai_config_defuns (void);
extern void syms_of_cmacs_ai_client_defuns (void);
extern void syms_of_cmacs_ai_session_defuns(void);
extern void syms_of_cmacs_ai_stream_defuns (void);
extern void syms_of_cmacs_ai_tools_defuns  (void);
extern void syms_of_cmacs_ai_image_defuns  (void);
extern void syms_of_cmacs_ai_embed_defuns  (void);
extern void syms_of_cmacs_ai_harness       (void);

static bool init_done = false;

void
syms_of_cmacs_ai (void)
{
  syms_of_cmacs_ai_defuns ();
  syms_of_cmacs_ai_config_defuns ();
  syms_of_cmacs_ai_client_defuns ();
  syms_of_cmacs_ai_session_defuns ();
  syms_of_cmacs_ai_stream_defuns ();
  syms_of_cmacs_ai_tools_defuns ();
  syms_of_cmacs_ai_image_defuns ();
  syms_of_cmacs_ai_embed_defuns ();
  syms_of_cmacs_ai_harness ();
}

void
init_cmacs_ai (void)
{
  if (init_done) return;
  init_done = true;
  /* Runs on the Emacs main thread; record it so the tool-callback
   * bridge knows when it is safe to return a Lisp value to the model. */
  cmacs_ai__main_gthread = g_thread_self ();
  cmacs_ai_client_registry_init ();
  cmacs_ai_session_registry_init ();
  cmacs_ai_typelib_autoload ();
}

#endif /* HAVE_CMACS_AI */
