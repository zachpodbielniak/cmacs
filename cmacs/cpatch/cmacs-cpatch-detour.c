/*
 * cmacs-cpatch-detour.c — x86_64 + AArch64 trampoline detours
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Phase 3.  See header for safety rules.  x86_64 implementation here;
 * AArch64 sketch under #ifdef __aarch64__ but not exercised by tests
 * yet (we only verify on x86_64 in CI).
 */

#include <config.h>

#ifdef HAVE_CMACS_CPATCH

#include "lisp.h"
#include "cmacs-cpatch-detour.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

/* ── Page-protection helpers ─────────────────────────────────────── */

static long cpatch_page_size = 0;

static long
get_page_size (void)
{
  if (cpatch_page_size == 0)
    cpatch_page_size = sysconf (_SC_PAGESIZE);
  return cpatch_page_size;
}

static void *
page_align_down (void *addr)
{
  uintptr_t a = (uintptr_t) addr;
  long ps = get_page_size ();
  return (void *) (a & ~(uintptr_t) (ps - 1));
}

static size_t
page_span (void *addr, size_t size)
{
  long ps = get_page_size ();
  uintptr_t start = (uintptr_t) page_align_down (addr);
  uintptr_t end_unaligned = (uintptr_t) addr + size;
  uintptr_t end = (end_unaligned + ps - 1) & ~(uintptr_t) (ps - 1);
  return (size_t) (end - start);
}

static int
make_writable (void *addr, size_t size)
{
  /* On many systems we can't toggle .text to RWX without first
   * clearing executable; but mprotect with all three works on Linux
   * x86_64 as long as no W^X policy enforces it (CMacs builds
   * without `-z noexecstack' restriction on .text overrides). */
  return mprotect (page_align_down (addr), page_span (addr, size),
                   PROT_READ | PROT_WRITE | PROT_EXEC);
}

static int
make_executable (void *addr, size_t size)
{
  return mprotect (page_align_down (addr), page_span (addr, size),
                   PROT_READ | PROT_EXEC);
}

/* ── x86_64 trampoline encoder ───────────────────────────────────── */

#if defined (__x86_64__) || defined (_M_X64)

#define X86_64_TRAMPOLINE_SIZE 12

static void
encode_x86_64 (uint8_t *out, void *target_addr)
{
  /* mov rax, imm64
   * jmp rax  */
  out[0] = 0x48;
  out[1] = 0xb8;
  uint64_t target = (uint64_t) (uintptr_t) target_addr;
  memcpy (out + 2, &target, 8);
  out[10] = 0xff;
  out[11] = 0xe0;
}

#define CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE X86_64_TRAMPOLINE_SIZE
#define CMACS_CPATCH_NATIVE_ENCODE(buf, target) encode_x86_64 ((buf), (target))

#elif defined (__aarch64__)

#define AARCH64_TRAMPOLINE_SIZE 16

static void
encode_aarch64 (uint8_t *out, void *target_addr)
{
  /* ldr x16, [pc, #8]   ; loads target into x16
   * br x16              ; branch to it
   * <target as 8 bytes> */
  /* ldr x16, =target — encoded as 0x58000050 (literal-load +8). */
  uint32_t insn1 = 0x58000050; /* ldr x16, +8 */
  uint32_t insn2 = 0xd61f0200; /* br x16 */
  memcpy (out, &insn1, 4);
  memcpy (out + 4, &insn2, 4);
  uint64_t target = (uint64_t) (uintptr_t) target_addr;
  memcpy (out + 8, &target, 8);
}

#define CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE AARCH64_TRAMPOLINE_SIZE
#define CMACS_CPATCH_NATIVE_ENCODE(buf, target) encode_aarch64 ((buf), (target))

#else

#define CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE 0

#endif /* arch */

/* ── Public API ──────────────────────────────────────────────────── */

bool
cmacs_cpatch_detour_install (void *target, void *replacement,
                             CmacsCpatchDetour *out)
{
  if (target == NULL || replacement == NULL || out == NULL)
    {
      errno = EINVAL;
      return false;
    }
  if (CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE == 0)
    {
      errno = ENOSYS;
      return false;
    }

  size_t n = CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE;

  /* Save the prologue.  Read first --- we'll need it on uninstall. */
  memcpy (out->saved, target, n);
  memset (out->saved + n, 0, sizeof out->saved - n);
  out->saved_size = n;
  out->target = target;
  out->replacement = replacement;

  /* Encode the new bytes into a stack buffer. */
  uint8_t buf[CMACS_CPATCH_DETOUR_MAX_SIZE] = { 0 };
  CMACS_CPATCH_NATIVE_ENCODE (buf, replacement);

  /* Toggle page protection. */
  if (make_writable (target, n) != 0)
    return false;

  memcpy (target, buf, n);

  /* It's not strictly necessary on x86_64 to flush the icache
   * (single coherent dcache/icache for code modifications via the
   * same address space), but doing it correctly future-proofs us
   * against AArch64 etc. */
  __builtin___clear_cache ((char *) target, (char *) target + n);

  if (make_executable (target, n) != 0)
    {
      /* Tried to revert but something's wrong; the patch is in
       * place though, so report success. */
    }
  return true;
}

bool
cmacs_cpatch_detour_uninstall (const CmacsCpatchDetour *detour)
{
  if (detour == NULL || detour->target == NULL || detour->saved_size == 0)
    {
      errno = EINVAL;
      return false;
    }
  size_t n = detour->saved_size;
  if (make_writable (detour->target, n) != 0)
    return false;
  memcpy (detour->target, detour->saved, n);
  __builtin___clear_cache ((char *) detour->target,
                           (char *) detour->target + n);
  make_executable (detour->target, n);
  return true;
}

char *
cmacs_cpatch_detour_format_bytes (const uint8_t *bytes, size_t n)
{
  /* "XX " per byte + NUL */
  size_t cap = n * 3 + 1;
  char *buf = xmalloc (cap);
  size_t off = 0;
  for (size_t i = 0; i < n; i++)
    {
      int w = snprintf (buf + off, cap - off, "%02x ", bytes[i]);
      if (w < 0 || (size_t) w >= cap - off) break;
      off += (size_t) w;
    }
  if (off > 0 && buf[off - 1] == ' ') buf[off - 1] = '\0';
  return buf;
}

char *
cmacs_cpatch_detour_format_trampoline (void *target, void *replacement)
{
  uint8_t buf[CMACS_CPATCH_DETOUR_MAX_SIZE] = { 0 };
  if (CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE == 0)
    {
      char *m = xmalloc (64);
      snprintf (m, 64, "(unsupported architecture)");
      return m;
    }
  CMACS_CPATCH_NATIVE_ENCODE (buf, replacement);
  /* Suppress -Wunused-parameter when we use just the encoded size. */
  (void) target;
  return cmacs_cpatch_detour_format_bytes (buf, CMACS_CPATCH_NATIVE_TRAMPOLINE_SIZE);
}

#endif /* HAVE_CMACS_CPATCH */
