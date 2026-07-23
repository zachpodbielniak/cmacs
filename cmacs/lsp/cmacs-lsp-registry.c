/* cmacs-lsp-registry.c --- registry of compiled-in language servers

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* The single source of truth for which `--cmacs-lsp' language servers
   this build carries.  Adding a server = one cmacs-lsp-<lang>.c backend,
   one guarded entry here, and a configure conditional defining its
   HAVE_CMACS_LSP_<LANG> macro (see doc_org/cmacs/lsp.org).  `--help' and
   the bare/unknown `--cmacs-lsp' error path both enumerate this table.  */

#include <config.h>

#ifdef HAVE_CMACS_LSP

#include "cmacs-lsp-registry.h"

#ifdef HAVE_CMACS_LSP_GNUCALC
#include "cmacs-lsp-gnucalc.h"
#endif

#include <string.h>

/* NULL-name sentinel terminated, so the table is never empty even in a
   build with no language backends compiled in.  */
static const CmacsLspLanguage cmacs_lsp_language_table[] =
{
#ifdef HAVE_CMACS_LSP_GNUCALC
  {
    "gnucalc",
    "GNU Calc .calc sheets (builtins, cmacs calculators, units)",
    "*.calc",
    cmacs_lsp_gnucalc_run
  },
#endif
  { NULL, NULL, NULL, NULL }
};

const CmacsLspLanguage *
cmacs_lsp_find_language (const char *name)
{
  const CmacsLspLanguage *lang;

  if (name == NULL)
    return NULL;

  for (lang = cmacs_lsp_language_table; lang->name != NULL; lang++)
    if (strcmp (lang->name, name) == 0)
      return lang;
  return NULL;
}

const CmacsLspLanguage *
cmacs_lsp_languages (size_t *n_out)
{
  if (n_out != NULL)
    {
      size_t n = 0;

      while (cmacs_lsp_language_table[n].name != NULL)
        n++;
      *n_out = n;
    }
  return cmacs_lsp_language_table;
}

#endif /* HAVE_CMACS_LSP */
