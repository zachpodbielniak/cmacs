/*
 * cmacs-cpatch-detour.h — x86_64 + AArch64 trampoline detours
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Replace any C function in the running cmacs process with a
 * trampoline jumping to a replacement function.  Used by
 * cmacs-c-patch-function for non-DEFUN code.  The DEFUN swap path
 * (cmacs-cpatch.c) doesn't need this --- it just rewrites the
 * Lisp_Subr.function pointer.
 *
 * x86_64: 12-byte `mov rax, imm64; jmp rax' --- always reachable
 * regardless of the JIT pool's distance from the target.
 * AArch64: 16-byte `ldr x16, +8; br x16; <8 bytes target>' (Phase 3.5).
 *
 * Safety rules:
 *   1. The target function must have at least 12 bytes of patchable
 *      prologue (true for every reasonable C function compiled with
 *      a frame-pointer prologue + body).
 *   2. The target must not be currently executing on any thread.
 *      Cmacs's single-threaded Lisp eval makes this trivially true
 *      for any function patched while the user is at the top level.
 *      For background-thread / GLib-callback contexts, the caller
 *      must coordinate via cmacs_context_acquired (NOT YET WIRED ---
 *      Phase 3 v1 documents the limitation).
 */

#ifndef CMACS_CPATCH_DETOUR_H
#define CMACS_CPATCH_DETOUR_H

#include "lisp.h"

#ifdef HAVE_CMACS_CPATCH

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* On x86_64 the trampoline is 12 bytes.  On AArch64 it'll be 16.
 * We always store 16 bytes of saved prologue --- caller passes a
 * fixed-size buffer.  Unused trailing bytes are zero. */
#define CMACS_CPATCH_DETOUR_MAX_SIZE 16

typedef struct
{
  void *target;
  void *replacement;
  uint8_t saved[CMACS_CPATCH_DETOUR_MAX_SIZE];
  size_t saved_size;        /* actual bytes overwritten (12 on x86_64) */
} CmacsCpatchDetour;

/* Install the trampoline.  Fills *OUT with the data needed for
 * uninstall.  Returns true on success, false on failure (with errno
 * set or a diagnostic appended via xsignal at the call site).
 *
 * Holds no locks; caller is responsible for ensuring the target
 * isn't being executed concurrently. */
extern bool cmacs_cpatch_detour_install (void *target, void *replacement,
                                         CmacsCpatchDetour *out);

/* Uninstall a previously-installed detour.  Restores the saved
 * prologue bytes. */
extern bool cmacs_cpatch_detour_uninstall (const CmacsCpatchDetour *detour);

/* Format the saved prologue as hex bytes for diff display.  *OUT
 * is xmalloc'd; caller frees. */
extern char *cmacs_cpatch_detour_format_bytes (const uint8_t *bytes, size_t n);

/* Build a hex-string preview of what the trampoline would look like
 * on this architecture, given target+replacement.  *OUT xmalloc'd. */
extern char *cmacs_cpatch_detour_format_trampoline (void *target,
                                                    void *replacement);

#endif /* HAVE_CMACS_CPATCH */
#endif /* CMACS_CPATCH_DETOUR_H */
