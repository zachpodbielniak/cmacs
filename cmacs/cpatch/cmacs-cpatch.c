/*
 * cmacs-cpatch.c — runtime C hot-patching: subsystem entry
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Phase-1: skeleton + safe `cmacs-c-patch-defun' atomic pointer swap
 * (covers ~90% of practical use cases).  Trampoline detour for
 * arbitrary C functions is Phase-3.
 */

#include <config.h>

#ifdef HAVE_CMACS_CPATCH

#include "lisp.h"
#include "cmacs-cpatch.h"
#include "cmacs-cintrospect-defun.h"
#include "cmacs-cintrospect.h"
#include "cmacs-cpatch-detour.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ── Patch registry ───────────────────────────────────────────────── */

typedef enum
{
  CPATCH_KIND_DEFUN_SWAP = 0,   /* Lisp_Subr.function pointer swap */
  CPATCH_KIND_DETOUR     = 1,   /* trampoline at function prologue */
} CmacsCpatchKind;

typedef struct CmacsCpatchEntry CmacsCpatchEntry;
struct CmacsCpatchEntry
{
  CmacsCpatchKind kind;
  /* DEFUN-swap fields. */
  Lisp_Object subr;          /* the patched Lisp_Subr Lisp_Object */
  void *original_fn;         /* what to restore on unpatch */
  void *patched_fn;          /* current pointer */
  /* Detour fields. */
  char *target_name;         /* xmalloc'd C symbol name */
  CmacsCpatchDetour detour;  /* saved bytes for restore */
  CmacsCpatchEntry *next;
};

static CmacsCpatchEntry *patch_head;
static int patch_count;

/* Qcpatch_not_implemented is declared in globals.h (auto-generated
 * from the DEFSYM call in syms_of_cmacs_cpatch). */

/* ── DEFUNs ───────────────────────────────────────────────────────── */

/* Run the `cmacs-cintrospect-patch-applied-hook' for podomation /
 * libreclaw integrations.  Each hook function receives one argument:
 * a plist describing the patch. */
static void
run_patch_applied_hook (Lisp_Object plist)
{
  Lisp_Object hook = intern ("cmacs-cintrospect-patch-applied-hook");
  if (!NILP (Fboundp (hook)))
    {
      Lisp_Object val = find_symbol_value (hook);
      if (!NILP (val) && !EQ (val, Qunbound))
        CALLN (Frun_hook_with_args, hook, plist);
    }
}

DEFUN ("cmacs-c-patch-defun", Fcmacs_c_patch_defun,
       Scmacs_c_patch_defun, 2, 2, 0,
       doc: /* Patch the DEFUN named SYM to call NEW-FN-ADDR instead.
NEW-FN-ADDR is an integer (typically obtained from a
`cmacs-c-compile' handle's :fn-addr).  Records the original pointer
so `cmacs-c-unpatch-defun' can restore.

The pointer write is a single aligned store; safe because Emacs Lisp
eval is single-threaded.  Returns t on success.

Runs `cmacs-cintrospect-patch-applied-hook' with a plist describing
the patch.  */)
  (Lisp_Object sym, Lisp_Object new_fn_addr)
{
  CmacsCintroDefun d;
  if (!cmacs_cintrospect_defun_lookup (sym, &d))
    xsignal2 (Qerror,
              build_string ("cmacs-c-patch-defun: not a DEFUN"),
              sym);
  CHECK_INTEGER (new_fn_addr);
  uintmax_t a = FIXNUMP (new_fn_addr) ? (uintmax_t) XFIXNUM (new_fn_addr)
                                      : bignum_to_uintmax (new_fn_addr);
  void *new_fn = (void *) (uintptr_t) a;
  if (new_fn == NULL)
    xsignal1 (Qerror, build_string ("cmacs-c-patch-defun: NULL fn-addr"));

  void *old = cmacs_cintrospect_defun_swap_fn (d.subr, new_fn);

  CmacsCpatchEntry *e = xmalloc (sizeof *e);
  e->kind = CPATCH_KIND_DEFUN_SWAP;
  e->subr = d.subr;
  e->original_fn = old;
  e->patched_fn = new_fn;
  e->target_name = NULL;
  memset (&e->detour, 0, sizeof e->detour);
  e->next = patch_head;
  patch_head = e;
  patch_count++;

  /* Notify any registered patch-applied-hook listeners. */
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (intern (":kind"), intern ("defun-swap")));
  plist = nconc2 (plist, list2 (intern (":symbol"), sym));
  plist = nconc2 (plist, list2 (intern (":original-addr"),
                                make_uint ((uintmax_t) (uintptr_t) old)));
  plist = nconc2 (plist, list2 (intern (":patched-addr"),
                                make_uint ((uintmax_t) (uintptr_t) new_fn)));
  run_patch_applied_hook (plist);
  return Qt;
}

DEFUN ("cmacs-c-unpatch-defun", Fcmacs_c_unpatch_defun,
       Scmacs_c_unpatch_defun, 1, 1, 0,
       doc: /* Restore the original C function pointer for DEFUN SYM.  */)
  (Lisp_Object sym)
{
  CmacsCintroDefun d;
  if (!cmacs_cintrospect_defun_lookup (sym, &d))
    return Qnil;
  CmacsCpatchEntry **link = &patch_head;
  while (*link != NULL)
    {
      if ((*link)->kind == CPATCH_KIND_DEFUN_SWAP
          && EQ ((*link)->subr, d.subr))
        {
          cmacs_cintrospect_defun_swap_fn (d.subr, (*link)->original_fn);
          CmacsCpatchEntry *gone = *link;
          *link = gone->next;
          xfree (gone->target_name);
          xfree (gone);
          patch_count--;
          return Qt;
        }
      link = &(*link)->next;
    }
  return Qnil;
}

DEFUN ("cmacs-c-unpatch-all", Fcmacs_c_unpatch_all,
       Scmacs_c_unpatch_all, 0, 0, 0,
       doc: /* Restore every patched DEFUN/function.  Panic button.
Returns the count of patches removed.  */)
  (void)
{
  int restored = 0;
  while (patch_head != NULL)
    {
      switch (patch_head->kind)
        {
        case CPATCH_KIND_DEFUN_SWAP:
          cmacs_cintrospect_defun_swap_fn (patch_head->subr,
                                           patch_head->original_fn);
          break;
        case CPATCH_KIND_DETOUR:
          cmacs_cpatch_detour_uninstall (&patch_head->detour);
          break;
        }
      CmacsCpatchEntry *gone = patch_head;
      patch_head = gone->next;
      xfree (gone->target_name);
      xfree (gone);
      restored++;
      patch_count--;
    }
  return make_fixnum (restored);
}

DEFUN ("cmacs-c-patch-list", Fcmacs_c_patch_list,
       Scmacs_c_patch_list, 0, 0, 0,
       doc: /* Return list of currently-applied patches.
Each entry is a plist (:kind :symbol :original-addr :patched-addr).
:kind is `defun-swap' or `detour'.  */)
  (void)
{
  Lisp_Object out = Qnil;
  for (CmacsCpatchEntry *e = patch_head; e != NULL; e = e->next)
    {
      Lisp_Object plist = Qnil;
      plist = nconc2 (plist,
                      list2 (intern (":kind"),
                             intern (e->kind == CPATCH_KIND_DEFUN_SWAP
                                     ? "defun-swap" : "detour")));
      plist = nconc2 (plist,
                      list2 (intern (":symbol"),
                             e->kind == CPATCH_KIND_DEFUN_SWAP
                             ? (SUBRP (e->subr)
                                ? intern (XSUBR (e->subr)->symbol_name)
                                : Qnil)
                             : (e->target_name
                                ? build_string (e->target_name)
                                : Qnil)));
      if (e->kind == CPATCH_KIND_DEFUN_SWAP)
        {
          plist = nconc2 (plist,
                          list2 (intern (":original-addr"),
                                 make_uint ((uintmax_t) (uintptr_t) e->original_fn)));
          plist = nconc2 (plist,
                          list2 (intern (":patched-addr"),
                                 make_uint ((uintmax_t) (uintptr_t) e->patched_fn)));
        }
      else
        {
          plist = nconc2 (plist,
                          list2 (intern (":target-addr"),
                                 make_uint ((uintmax_t) (uintptr_t) e->detour.target)));
          plist = nconc2 (plist,
                          list2 (intern (":replacement-addr"),
                                 make_uint ((uintmax_t) (uintptr_t) e->detour.replacement)));
        }
      out = Fcons (plist, out);
    }
  return out;
}

DEFUN ("cmacs-c-patch-function", Fcmacs_c_patch_function,
       Scmacs_c_patch_function, 2, 2, 0,
       doc: /* Hot-patch the C function named NAME so that calls jump to
NEW-FN-ADDR (an integer; typically the :fn-addr from a
`cmacs-c-handle-info' plist or `cmacs-c-symbol-info' result).

Installs a 12-byte (x86_64) / 16-byte (AArch64) trampoline at the
target's prologue using mprotect to temporarily make the page
writable.  Saves the original bytes for `cmacs-c-unpatch-function'
to restore.

Caveats: the target must not currently be executing.  In
single-threaded Lisp eval (the typical M-x case) this is trivially
true.  Wrong arity/type signatures will SIGSEGV the next caller.  */)
  (Lisp_Object name, Lisp_Object new_fn_addr)
{
  CHECK_STRING (name);
  CHECK_INTEGER (new_fn_addr);

  void *target = cmacs_cintrospect_function_address (SSDATA (name));
  if (target == NULL)
    xsignal2 (Qerror,
              build_string ("cmacs-c-patch-function: target function not found"),
              name);

  uintmax_t a = FIXNUMP (new_fn_addr)
                ? (uintmax_t) XFIXNUM (new_fn_addr)
                : bignum_to_uintmax (new_fn_addr);
  void *replacement = (void *) (uintptr_t) a;
  if (replacement == NULL)
    xsignal1 (Qerror, build_string ("cmacs-c-patch-function: NULL replacement"));

  /* Refuse double-patching the same target. */
  for (CmacsCpatchEntry *e = patch_head; e != NULL; e = e->next)
    if (e->kind == CPATCH_KIND_DETOUR && e->detour.target == target)
      xsignal2 (Qerror,
                build_string ("cmacs-c-patch-function: already patched"),
                name);

  CmacsCpatchEntry *e = xmalloc (sizeof *e);
  memset (e, 0, sizeof *e);
  e->kind = CPATCH_KIND_DETOUR;
  e->subr = Qnil;
  e->target_name = xmalloc (SBYTES (name) + 1);
  memcpy (e->target_name, SDATA (name), SBYTES (name));
  e->target_name[SBYTES (name)] = '\0';

  if (!cmacs_cpatch_detour_install (target, replacement, &e->detour))
    {
      Lisp_Object errs = build_string (strerror (errno));
      xfree (e->target_name);
      xfree (e);
      xsignal2 (Qerror,
                build_string ("cmacs-c-patch-function: detour install failed"),
                errs);
    }

  e->next = patch_head;
  patch_head = e;
  patch_count++;

  /* Hook for podomation/libreclaw. */
  Lisp_Object plist = Qnil;
  plist = nconc2 (plist, list2 (intern (":kind"), intern ("detour")));
  plist = nconc2 (plist, list2 (intern (":symbol"), name));
  plist = nconc2 (plist, list2 (intern (":target-addr"),
                                make_uint ((uintmax_t) (uintptr_t) target)));
  plist = nconc2 (plist, list2 (intern (":replacement-addr"),
                                make_uint ((uintmax_t) (uintptr_t) replacement)));
  run_patch_applied_hook (plist);
  return Qt;
}

DEFUN ("cmacs-c-unpatch-function", Fcmacs_c_unpatch_function,
       Scmacs_c_unpatch_function, 1, 1, 0,
       doc: /* Remove a previously-installed trampoline detour for NAME.
Restores the original prologue bytes.  Returns t on success, nil
if no detour was registered.  */)
  (Lisp_Object name)
{
  CHECK_STRING (name);
  CmacsCpatchEntry **link = &patch_head;
  while (*link != NULL)
    {
      if ((*link)->kind == CPATCH_KIND_DETOUR
          && (*link)->target_name != NULL
          && strcmp ((*link)->target_name, SSDATA (name)) == 0)
        {
          cmacs_cpatch_detour_uninstall (&(*link)->detour);
          CmacsCpatchEntry *gone = *link;
          *link = gone->next;
          xfree (gone->target_name);
          xfree (gone);
          patch_count--;
          return Qt;
        }
      link = &(*link)->next;
    }
  return Qnil;
}

DEFUN ("cmacs-c-patch-diff", Fcmacs_c_patch_diff,
       Scmacs_c_patch_diff, 2, 2, 0,
       doc: /* Preview the trampoline that would be installed for TARGET.

TARGET is either a symbol (treated as a DEFUN --- the diff is
"(defun-swap, no instruction modification)") or a string (treated
as a C function name --- the diff shows the original prologue bytes
vs. the new trampoline bytes in hex).

REPLACEMENT-ADDR is an integer giving the destination function
address.

Returns a multi-line string suitable for display.  */)
  (Lisp_Object target, Lisp_Object replacement_addr)
{
  CHECK_INTEGER (replacement_addr);
  uintmax_t addr_uint = FIXNUMP (replacement_addr)
                        ? (uintmax_t) XFIXNUM (replacement_addr)
                        : bignum_to_uintmax (replacement_addr);
  void *replacement = (void *) (uintptr_t) addr_uint;

  if (SYMBOLP (target))
    {
      CmacsCintroDefun d;
      if (!cmacs_cintrospect_defun_lookup (target, &d))
        return build_string ("(target is not a DEFUN)");
      char *line = NULL;
      int unused = asprintf (&line,
        "DEFUN swap (atomic, no instruction modification):\n"
        "  symbol:    %s\n"
        "  current:   0x%lx\n"
        "  patched:   0x%lx\n",
        d.symbol_name,
        (unsigned long) (uintptr_t) d.fn_ptr,
        (unsigned long) (uintptr_t) replacement);
      (void) unused;
      Lisp_Object r = build_string (line ? line : "(format failed)");
      free (line);
      return r;
    }

  CHECK_STRING (target);
  void *target_addr = cmacs_cintrospect_function_address (SSDATA (target));
  if (target_addr == NULL)
    return build_string ("(target function not found in DWARF)");

  /* Read the existing 12 bytes (architecture-native trampoline size). */
  uint8_t saved[CMACS_CPATCH_DETOUR_MAX_SIZE] = { 0 };
  size_t n = 12;
  memcpy (saved, target_addr, n);

  char *current_hex = cmacs_cpatch_detour_format_bytes (saved, n);
  char *new_hex = cmacs_cpatch_detour_format_trampoline (target_addr, replacement);

  char *out = NULL;
  int unused = asprintf (&out,
    "Trampoline detour preview:\n"
    "  target:      %s @ 0x%lx\n"
    "  replacement: 0x%lx\n"
    "  current bytes: %s\n"
    "  new bytes:     %s\n",
    SSDATA (target),
    (unsigned long) (uintptr_t) target_addr,
    (unsigned long) (uintptr_t) replacement,
    current_hex ? current_hex : "?",
    new_hex ? new_hex : "?");
  (void) unused;
  Lisp_Object r = build_string (out ? out : "(format failed)");
  free (out);
  xfree (current_hex);
  xfree (new_hex);
  return r;
}

/* ── syms_of / init ───────────────────────────────────────────────── */

void
init_cmacs_cpatch (void)
{
  patch_head = NULL;
  patch_count = 0;
}

void
syms_of_cmacs_cpatch (void)
{
  DEFSYM (Qcpatch_not_implemented, "cmacs-cpatch-not-implemented");
  Fput (Qcpatch_not_implemented, Qerror_conditions,
        list2 (Qcpatch_not_implemented, Qerror));
  Fput (Qcpatch_not_implemented, Qerror_message,
        build_string ("cmacs-cpatch: not implemented in this build phase"));

  defsubr (&Scmacs_c_patch_defun);
  defsubr (&Scmacs_c_unpatch_defun);
  defsubr (&Scmacs_c_unpatch_all);
  defsubr (&Scmacs_c_patch_list);
  defsubr (&Scmacs_c_patch_function);
  defsubr (&Scmacs_c_unpatch_function);
  defsubr (&Scmacs_c_patch_diff);
}

#endif /* HAVE_CMACS_CPATCH */
