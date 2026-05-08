/*
 * cmacs-cintrospect-defun.h — Emacs DEFUN registry walker
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Walks the obarray to enumerate every Lisp_Subr (Emacs DEFUN), and
 * cross-references each with DWARF to give back a (symbol-name,
 * c-name, file, line, fn-pointer) tuple per primitive.
 *
 * Also exposes the safe Lisp_Subr.function-pointer write helper used
 * by cmacs/cpatch/ to atomically swap a DEFUN's implementation
 * during quiescent windows.
 */

#ifndef CMACS_CINTROSPECT_DEFUN_H
#define CMACS_CINTROSPECT_DEFUN_H

#include "lisp.h"

#ifdef HAVE_CMACS_CINTROSPECT

#include <stdbool.h>

typedef struct
{
  const char *symbol_name;  /* Lisp side, e.g. "buffer-string" */
  const char *c_name;       /* C side, e.g. "Fbuffer_string"; may be NULL */
  short min_args;
  short max_args;            /* -1 == MANY, -2 == UNEVALLED */
  void *fn_ptr;             /* the union member that's currently active */
  Lisp_Object subr;         /* the live Lisp_Subr Lisp_Object */
} CmacsCintroDefun;

typedef bool (*CmacsCintroDefunIterFn) (const CmacsCintroDefun *d,
                                        void *user_data);

/* Iterate every DEFUN currently in obarray.  Stops if FN returns
 * false. */
extern void cmacs_cintrospect_defun_walk (CmacsCintroDefunIterFn fn,
                                          void *user_data);

/* Look up a single DEFUN by Lisp symbol or by C name (the same lookup
 * used by `cmacs-c-defun-info`).  *OUT remains valid only until the
 * next DEFUN registry mutation (which doesn't happen at runtime in
 * standard Emacs). */
extern bool cmacs_cintrospect_defun_lookup (Lisp_Object name_or_sym,
                                            CmacsCintroDefun *out);

/* Write a new function pointer into a Lisp_Subr atomically.  The
 * compiler's atomic store (which on every supported arch is a single
 * pointer-aligned 64-bit/32-bit store) is sufficient because Emacs
 * Lisp eval is single-threaded.  Returns the previous pointer so the
 * caller can register it for unpatch.  Used only from cmacs/cpatch/. */
extern void *cmacs_cintrospect_defun_swap_fn (Lisp_Object subr,
                                              void *new_fn);

#endif /* HAVE_CMACS_CINTROSPECT */
#endif /* CMACS_CINTROSPECT_DEFUN_H */
