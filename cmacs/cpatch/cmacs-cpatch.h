/*
 * cmacs-cpatch.h — runtime C hot-patching: public API
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Phase-1: subsystem skeleton, DEFUN swap helper available, full
 * trampoline detour deferred to Phase-3.  See plan file.
 */

#ifndef CMACS_CPATCH_H
#define CMACS_CPATCH_H

#include "lisp.h"

#ifdef HAVE_CMACS_CPATCH

extern void syms_of_cmacs_cpatch (void);
extern void init_cmacs_cpatch (void);

#endif /* HAVE_CMACS_CPATCH */
#endif /* CMACS_CPATCH_H */
