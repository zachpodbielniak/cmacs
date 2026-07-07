/* cmacs-lrgscript-init.c --- subsystem lifecycle.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Aggregates the DEFUN registration and registers the Emacs Lisp backend with
 * libregnum's process-wide scripting manager.  Registration is delegated to
 * the libregnum-side cmacs_lrgscript_register_backend() (in
 * cmacs-lrgscript-elisp.c) so this translation unit stays on the lisp side of
 * the firewall (no <libregnum.h>). */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include "lisp.h"
#include "cmacs-lrgscript.h"
#include <stdbool.h>

static bool init_done = false;

void
syms_of_cmacs_lrgscript (void)
{
  syms_of_cmacs_lrgscript_defuns ();
  syms_of_cmacs_lrgscript_game_defuns ();
}

void
init_cmacs_lrgscript (void)
{
  if (init_done)
    return;
  init_done = true;

  /* Plug the elisp backend into libregnum's LrgScriptingManager so scene
   * nodes / games can select language "elisp".  Safe to call once here at
   * startup, before any script attaches. */
  cmacs_lrgscript_register_backend ();
}

#endif /* HAVE_CMACS_LRGSCRIPT */
