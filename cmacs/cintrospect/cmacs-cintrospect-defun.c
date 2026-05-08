/*
 * cmacs-cintrospect-defun.c — DEFUN walker + safe pointer swap
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <config.h>

#ifdef HAVE_CMACS_CINTROSPECT

#include "lisp.h"
#include "cmacs-cintrospect-defun.h"

#include <string.h>

/* ── Walk obarray for SUBRP entries ──────────────────────────────── */

void
cmacs_cintrospect_defun_walk (CmacsCintroDefunIterFn fn, void *user_data)
{
  if (fn == NULL)
    return;
  if (!OBARRAYP (Vobarray))
    return;

  bool stop = false;
  DOOBARRAY (XOBARRAY (Vobarray), it)
    {
      if (stop) break;
      Lisp_Object sym = obarray_iter_symbol (&it);
      if (!SYMBOLP (sym))
        continue;
      Lisp_Object func = (XSYMBOL (sym)->u.s.function != Qunbound)
                         ? XSYMBOL (sym)->u.s.function
                         : Qnil;
      if (!SUBRP (func))
        continue;
      struct Lisp_Subr *s = XSUBR (func);
      CmacsCintroDefun d =
        {
          .symbol_name = SSDATA (SYMBOL_NAME (sym)),
          .c_name      = s->symbol_name,
          .min_args    = s->min_args,
          .max_args    = s->max_args,
          .fn_ptr      = (void *) s->function.aMANY,
          .subr        = func,
        };
      if (!fn (&d, user_data))
        stop = true;
    }
}

bool
cmacs_cintrospect_defun_lookup (Lisp_Object name_or_sym,
                                CmacsCintroDefun *out)
{
  if (out == NULL)
    return false;
  Lisp_Object sym = name_or_sym;
  if (STRINGP (name_or_sym))
    sym = intern (SSDATA (name_or_sym));
  if (!SYMBOLP (sym) || NILP (Ffboundp (sym)))
    return false;
  Lisp_Object f = Fsymbol_function (sym);
  if (!SUBRP (f))
    return false;
  struct Lisp_Subr *s = XSUBR (f);
  out->symbol_name = SSDATA (SYMBOL_NAME (sym));
  out->c_name      = s->symbol_name;
  out->min_args    = s->min_args;
  out->max_args    = s->max_args;
  out->fn_ptr      = (void *) s->function.aMANY;
  out->subr        = f;
  return true;
}

/* ── Atomic Lisp_Subr.function pointer swap ──────────────────────── */

void *
cmacs_cintrospect_defun_swap_fn (Lisp_Object subr, void *new_fn)
{
  if (!SUBRP (subr))
    return NULL;
  struct Lisp_Subr *s = XSUBR (subr);
  /* Single pointer-aligned store --- always atomic on aligned
   * pointer-sized writes on every supported arch.  Lisp eval is
   * single-threaded, so the only race is with the GC scanner, which
   * doesn't touch the function-pointer union. */
  void *old = (void *) s->function.aMANY;
  s->function.aMANY = (Lisp_Object (*) (ptrdiff_t, Lisp_Object *)) new_fn;
  return old;
}

#endif /* HAVE_CMACS_CINTROSPECT */
