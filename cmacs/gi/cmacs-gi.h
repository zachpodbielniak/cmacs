/* cmacs-gi.h — GObject Introspection bridge for elisp
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Dynamic access to any GObject library from elisp without writing
 * C wrappers.  Loads .typelib files, reflects the API, and marshals
 * between C and elisp types.
 */

#ifndef CMACS_GI_H
#define CMACS_GI_H

#include <config.h>

#ifdef HAVE_CMACS_GI

#include <girepository.h>

/* Register DEFUN primitives. */
extern void syms_of_cmacs_gi (void);

#endif /* HAVE_CMACS_GI */
#endif /* CMACS_GI_H */
