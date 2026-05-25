/* cmacs-ai-typelib.c --- auto-load AiGlib-1.0 typelib at init.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Prepends CMACS_AI_GIR_DIR (set at configure time to the in-tree
 * deps/ai-glib build dir) to GIRepository's search path so that
 * (gi-require "AiGlib" "1.0") works out of the box, both from
 * Elisp and from the bacon `cmacsgi' builtin.  System-installed
 * AiGlib typelibs are still found via the standard GI search path
 * (which is queried after the prepended dir). */

#include <config.h>

#ifdef HAVE_CMACS_AI

#include "cmacs-ai.h"

#include <glib.h>

#ifdef HAVE_CMACS_GI
#include <girepository.h>
#endif

#ifndef CMACS_AI_GIR_DIR
#define CMACS_AI_GIR_DIR ""
#endif

void
cmacs_ai_typelib_autoload (void)
{
#ifdef HAVE_CMACS_GI
  static gboolean done = FALSE;
  if (done) return;
  done = TRUE;

  GIRepository *repo = g_irepository_get_default ();

  /* Prepend the in-tree build dir so a developer running from the
   * source tree never sees "Typelib 'AiGlib' not found"; system
   * install (g-ir-compiler output in /usr/lib/.../girepository-1.0/)
   * still resolves via the default search path appended below. */
  if (CMACS_AI_GIR_DIR[0])
    g_irepository_prepend_search_path (CMACS_AI_GIR_DIR);

  /* Require eagerly so the typelib is in the cache before any user
   * code runs; failure is non-fatal (Elisp gi-require will surface
   * the proper error if it actually tries to use it). */
  g_autoptr (GError) err = NULL;
  if (g_irepository_require (repo, "AiGlib", "1.0", 0, &err) == NULL)
    g_message ("cmacs-ai: AiGlib typelib not loaded at init: %s",
               err ? err->message : "(unknown)");
#endif
}

#endif /* HAVE_CMACS_AI */
