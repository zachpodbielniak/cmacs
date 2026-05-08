/*
 * cmacs-cintrospect-jit.h — runtime C compile-and-call API
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Phase 2: spawn `gcc' as a subprocess to compile a SOURCE string to
 * a temporary .so, dlopen it, dlsym a named function, and dispatch
 * calls through a Lisp-callable handle.
 *
 * libgccjit (already linked for native-compilation) does NOT compile
 * C source --- it's an IR construction API.  Re-implementing a C
 * frontend on top of libgccjit IR is not in scope; we instead spawn
 * the same `gcc' that built cmacs.  The cintrospect-jit handle is
 * still introspectable via libdw because we pass `-g -gdwarf-5'.
 *
 * Symbol resolution against the running cmacs process works because
 * cmacs is linked with `-Wl,--export-dynamic' (via CMACS_GLIB_LIBS),
 * so the dynamic linker resolves Fcons, make_string, etc. at dlopen
 * time.  Inline functions in lisp.h compile inline into the .so as
 * always.
 */

#ifndef CMACS_CINTROSPECT_JIT_H
#define CMACS_CINTROSPECT_JIT_H

#include "lisp.h"

#ifdef HAVE_CMACS_CINTROSPECT

#include <stdbool.h>

/* ── Subsystem lifecycle ─────────────────────────────────────────── */

extern bool cmacs_cintrospect_jit_init (void);
extern void cmacs_cintrospect_jit_shutdown (void);
extern void syms_of_cmacs_cintrospect_jit (void);

/* ── Handle representation ───────────────────────────────────────── */

typedef enum
{
  CMACS_CINTRO_JIT_SIG_VOID = 0,    /* Lisp_Object (void)              */
  CMACS_CINTRO_JIT_SIG_A1,          /* Lisp_Object (Lisp_Object)       */
  CMACS_CINTRO_JIT_SIG_A2,
  CMACS_CINTRO_JIT_SIG_A3,
  CMACS_CINTRO_JIT_SIG_A4,
  CMACS_CINTRO_JIT_SIG_A5,
  CMACS_CINTRO_JIT_SIG_A6,
  CMACS_CINTRO_JIT_SIG_A7,
  CMACS_CINTRO_JIT_SIG_A8,
  CMACS_CINTRO_JIT_SIG_MANY,        /* Lisp_Object (ptrdiff_t, Lisp_Object *) */
  CMACS_CINTRO_JIT_SIG_INT_INT,     /* int (int) */
  CMACS_CINTRO_JIT_SIG_INT_INT_INT, /* int (int, int) */
} CmacsCintroJitSig;

/* Look up a registered handle by id.  Returns the underlying
 * function pointer or NULL.  Used by cpatch when the user passes a
 * handle id where a function address is required. */
extern void *cmacs_cintrospect_jit_handle_addr (intmax_t handle_id);

/* Return the signature kind for the handle, or -1 if not found. */
extern int cmacs_cintrospect_jit_handle_sig (intmax_t handle_id);

#endif /* HAVE_CMACS_CINTROSPECT */
#endif /* CMACS_CINTROSPECT_JIT_H */
