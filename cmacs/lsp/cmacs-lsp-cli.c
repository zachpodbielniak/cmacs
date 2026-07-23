/* cmacs-lsp-cli.c --- `emacs --cmacs-lsp' command-line entry

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

/* `emacs --cmacs-lsp LANG' runs the compiled-in LSP language server for
   LANG over stdio and never returns to Emacs -- the same early-main
   never-return model as `--bacon' / `--crispy' (see the hook in
   src/emacs.c): the servers are pure C/GLib, so no Emacs or Lisp
   initialization may run, and none is needed.  Editors spawn the server
   as a subprocess call back to this same binary (in cmacs itself:
   `(expand-file-name invocation-name invocation-directory)', the
   portable /proc/self/exe).

   Both `--cmacs-lsp LANG' and `--cmacs-lsp=LANG' are accepted.  With no
   LANG, or an unknown one, the available servers are listed on stderr
   and the process exits 1 -- the same list `--help' prints via
   cmacs_lsp_print_help.  */

#include <config.h>

#ifdef HAVE_CMACS_LSP

#include "cmacs-lsp-cli.h"
#include "cmacs-lsp-registry.h"

#include <stdlib.h>
#include <string.h>

/* List the compiled-in language servers to STREAM, one line each.  */

static void
print_language_list (FILE *stream)
{
  const CmacsLspLanguage *langs;
  size_t n;
  size_t i;

  langs = cmacs_lsp_languages (&n);
  if (n == 0)
    {
      fprintf (stream, "  (none compiled in)\n");
      return;
    }

  for (i = 0; i < n; i++)
    fprintf (stream, "  %-10s %s  [%s]\n",
             langs[i].name, langs[i].description, langs[i].file_glob);
}

void
cmacs_lsp_print_help (FILE *stream)
{
  fprintf (stream, "\nCompiled-in --cmacs-lsp language servers:\n");
  print_language_list (stream);
}

void
cmacs_lsp_main (int argc, char **argv, int lsp_idx)
{
  const char *lang_name;
  const CmacsLspLanguage *lang;

  /* --cmacs-lsp=LANG, or LANG as the following argument.  */
  if (strncmp (argv[lsp_idx], "--cmacs-lsp=", 12) == 0)
    lang_name = argv[lsp_idx] + 12;
  else if (lsp_idx + 1 < argc && argv[lsp_idx + 1][0] != '\0'
           && argv[lsp_idx + 1][0] != '-')
    lang_name = argv[lsp_idx + 1];
  else
    lang_name = NULL;

  if (lang_name == NULL || *lang_name == '\0')
    {
      fprintf (stderr,
               "emacs --cmacs-lsp: no language given; available"
               " language servers:\n");
      print_language_list (stderr);
      exit (1);
    }

  lang = cmacs_lsp_find_language (lang_name);
  if (lang == NULL)
    {
      fprintf (stderr,
               "emacs --cmacs-lsp: unknown language `%s'; available"
               " language servers:\n", lang_name);
      print_language_list (stderr);
      exit (1);
    }

  exit (lang->run (argc, argv));
}

#endif /* HAVE_CMACS_LSP */
