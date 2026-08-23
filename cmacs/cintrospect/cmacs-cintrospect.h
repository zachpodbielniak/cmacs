/*
 * cmacs-cintrospect.h — CMacs runtime C self-introspection: public API
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Reads the running binary's DWARF debug info via libdw (elfutils)
 * and exposes structured access from Lisp and from other cmacs
 * subsystems (cpatch, mcp, bacon).  Compiled when
 * HAVE_CMACS_CINTROSPECT is defined.
 *
 * Threading: all public entry points must be called from the Emacs
 * main thread.  libdw itself is not thread-safe; we hold a coarse
 * lock in cmacs-cintrospect-dwarf.c.
 *
 * Address model: everything stored internally is a (object-id,
 * file-offset) pair.  Runtime addresses are derived via dl_iterate_phdr
 * load biases on demand.  This is robust under PIE/ASLR and across
 * pdumper load.
 */

#ifndef CMACS_CINTROSPECT_H
#define CMACS_CINTROSPECT_H

#include "lisp.h"

#ifdef HAVE_CMACS_CINTROSPECT

/* ── Subsystem lifecycle ───────────────────────────────────────────── */

/* ── Internal helpers shared with cpatch ─────────────────────────────
 *
 * cpatch links against cintrospect for DWARF lookup, the DEFUN
 * registry, and (Phase 2) the JIT context's mutex coordination.
 * These are intentionally not in the Lisp surface. */

/* Look up the file:line where the C function NAME is defined.
 * Returns true on success and writes the file path into *FILE_OUT
 * (caller must free with xfree) and the line into *LINE_OUT. */
extern bool cmacs_cintrospect_function_source (const char *name,
                                               char **file_out,
                                               int *line_out);

/* Look up the runtime address of the C function NAME.  Returns NULL
 * if the symbol is not found, was inlined away, or is data not text. */
extern void *cmacs_cintrospect_function_address (const char *name);

/* Resolve a runtime address into (file, line, function-name).
 * Caller must free *FILE_OUT and *FN_OUT (xfree).  Returns true on
 * success; on failure leaves the out-params untouched. */
extern bool cmacs_cintrospect_addr_to_source (void *addr,
                                              char **file_out,
                                              int *line_out,
                                              char **fn_out);

#endif /* HAVE_CMACS_CINTROSPECT */
#endif /* CMACS_CINTROSPECT_H */
