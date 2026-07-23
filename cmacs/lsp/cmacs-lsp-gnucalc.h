/* cmacs-lsp-gnucalc.h --- gnucalc language server for .calc sheets

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.  */

#ifndef CMACS_LSP_GNUCALC_H
#define CMACS_LSP_GNUCALC_H

/* Run the gnucalc language server over stdio until the client exits;
   returns the process exit status.  Registered in
   cmacs-lsp-registry.c as `emacs --cmacs-lsp gnucalc'.  */
extern int cmacs_lsp_gnucalc_run (int argc, char **argv);

#endif /* CMACS_LSP_GNUCALC_H */
