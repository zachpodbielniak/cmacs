/* cmacs-lsp-cli.h --- `emacs --cmacs-lsp' command-line entry

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_CLI_H
#define CMACS_LSP_CLI_H

#include <stdio.h>

/* Handle `emacs --cmacs-lsp [LANG]' at ARGV[LSP_IDX]: run the LANG
   language server over stdio and exit with its status, or list the
   compiled-in servers on stderr and exit 1 when LANG is missing or
   unknown.  Never returns.  */
extern _Noreturn void cmacs_lsp_main (int argc, char **argv, int lsp_idx);

/* Print the `--help' section enumerating the compiled-in language
   servers to STREAM.  */
extern void cmacs_lsp_print_help (FILE *stream);

#endif /* CMACS_LSP_CLI_H */
