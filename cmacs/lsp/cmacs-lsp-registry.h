/* cmacs-lsp-registry.h --- registry of compiled-in language servers

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_REGISTRY_H
#define CMACS_LSP_REGISTRY_H

#include <stddef.h>

/* One compiled-in language server, selected by
   `emacs --cmacs-lsp NAME'.  */
typedef struct CmacsLspLanguage
{
  const char *name;         /* the --cmacs-lsp argument, e.g. "gnucalc" */
  const char *description;  /* one line for --help */
  const char *file_glob;    /* informational, e.g. "*.calc" */
  int (*run) (int argc, char **argv);   /* blocking; returns exit status */
} CmacsLspLanguage;

extern const CmacsLspLanguage *cmacs_lsp_find_language (const char *name);
extern const CmacsLspLanguage *cmacs_lsp_languages (size_t *n_out);

#endif /* CMACS_LSP_REGISTRY_H */
