/* cmacs-brigade-defuns.c --- Top-level cmacs-brigade DEFUNs.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Subsystem-wide entry points: supported-p, version, and the
 * compile-time capability probe the Elisp layer branches on.  The
 * registries, memory index, agent runtime and MCP host live in
 * dedicated files. */

#include <config.h>

#ifdef HAVE_CMACS_AI_BRIGADE

#include "lisp.h"
#include "cmacs-brigade.h"

#include <glib.h>

/* Bumped whenever the C<->Elisp contract changes shape (new required
 * DEFUN, changed plist keys, changed index format).  The Elisp layer
 * compares it so a stale .elc against a newer binary fails loudly
 * rather than misbehaving at the marshalling boundary. */
#define CMACS_BRIGADE_ABI_VERSION (1)

DEFUN ("cmacs-brigade-supported-p", Fcmacs_brigade_supported_p,
       Scmacs_brigade_supported_p, 0, 0, 0,
       doc: /* Return t when the AI brigade fabric is built into this cmacs.  */)
  (void)
{
  return Qt;
}

DEFUN ("cmacs-brigade-abi-version", Fcmacs_brigade_abi_version,
       Scmacs_brigade_abi_version, 0, 0, 0,
       doc: /* Return the integer C<->Elisp ABI version of this build.

The Elisp layer refuses to load against an unexpected value rather than
risking a silent marshalling mismatch between a stale .elc and a newer
cmacs binary.  */)
  (void)
{
  return make_fixnum (CMACS_BRIGADE_ABI_VERSION);
}

DEFUN ("cmacs-brigade-capabilities", Fcmacs_brigade_capabilities,
       Scmacs_brigade_capabilities, 0, 0, 0,
       doc: /* Return a plist of compile-time brigade capabilities.

Keys are keywords with t or nil values.  Elisp branches on these rather
than on `IS-CMACS-*' directly, so an optional integration can be probed
in one place:

  :libreclaw   libreclaw surfaces (Matrix/GenTeam, inbox) available
  :mcp         the MCP host and `emacs --mcp-relay' bridge available
  :f16c        the fp16 vector scan can use F16C intrinsics on a CPU
               that reports support (the dispatch is at runtime; a
               scalar LUT path is always present)  */)
  (void)
{
  Lisp_Object plist = Qnil;

  /* Built back-to-front: each push prepends, so the last pushed pair
     ends up first in the returned plist. */

  /* :f16c reports only that the F16C code path could be COMPILED, not
   * that this CPU has the instructions -- that is decided at runtime by
   * __builtin_cpu_supports ("f16c"), with a scalar LUT fallback, so the
   * same binary runs on a host without F16C.  Detected here rather than
   * in configure.ac on purpose: a compile test in a cmacs feature block
   * runs before AC_USE_SYSTEM_EXTENSIONS and breaks _GNU_SOURCE for
   * every later probe.  */
#if (defined __x86_64__ || defined __i386__) \
    && (!defined __has_include || __has_include (<immintrin.h>))
  plist = Fcons (intern (":f16c"), Fcons (Qt, plist));
#else
  plist = Fcons (intern (":f16c"), Fcons (Qnil, plist));
#endif

#ifdef HAVE_CMACS_MCP
  plist = Fcons (intern (":mcp"), Fcons (Qt, plist));
#else
  plist = Fcons (intern (":mcp"), Fcons (Qnil, plist));
#endif

#ifdef HAVE_CMACS_LIBRECLAW
  plist = Fcons (intern (":libreclaw"), Fcons (Qt, plist));
#else
  plist = Fcons (intern (":libreclaw"), Fcons (Qnil, plist));
#endif

  return plist;
}

void syms_of_cmacs_ai_brigade_defuns (void);
void
syms_of_cmacs_ai_brigade_defuns (void)
{
  DEFSYM (Qcmacs_brigade_error, "cmacs-brigade-error");
  Fput (Qcmacs_brigade_error, Qerror_conditions,
        list2 (Qcmacs_brigade_error, Qerror));
  Fput (Qcmacs_brigade_error, Qerror_message,
        build_string ("CMacs brigade error"));

  defsubr (&Scmacs_brigade_supported_p);
  defsubr (&Scmacs_brigade_abi_version);
  defsubr (&Scmacs_brigade_capabilities);
}

#endif /* HAVE_CMACS_AI_BRIGADE */
