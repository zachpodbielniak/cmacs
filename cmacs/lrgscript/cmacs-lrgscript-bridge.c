/* cmacs-lrgscript-bridge.c --- GValue <-> Emacs Lisp bridge.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The lisp side of the elisp scripting backend.  Implements the GValue +
 * plain-C functions declared in cmacs-lrgscript-bridge.h that the LrgScripting
 * subclass (cmacs-lrgscript-elisp.c) calls to enter the Emacs Lisp VM.  This
 * translation unit includes lisp.h and NEVER <libregnum.h> -- no LrgScripting
 * or raylib type is named here, and no Lisp_Object escapes to the libregnum
 * side (everything crosses as GValue).
 *
 * Every path that evaluates Lisp goes through the waiting_for_input guard: the
 * hook/game paths are driven from GLib callbacks (the libregnum animation
 * timer / render loop), where a signalled elisp error would otherwise hit
 * signal_or_quit's impossible branch and abort the process.  We clear
 * waiting_for_input around the call and catch signals with
 * internal_condition_case_1, exactly like cmacs-eval-dispatch.c. */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include "lisp.h"
#include "keyboard.h"   /* waiting_for_input, {clear,set}_waiting_for_input */
#include "cmacs-lrgscript.h"
#include "cmacs-lrgscript-bridge.h"
#include <glib.h>
#include <glib-object.h>

/* Uninterned marker whose car tags an error result from a guarded eval, so we
 * can distinguish "the form legitimately returned a cons" from "the form
 * signalled".  Set + staticpro'd on first use. */
static Lisp_Object Vlrgscript_err_tag;

static void
ensure_err_tag (void)
{
  if (NILP (Vlrgscript_err_tag))
    {
      Vlrgscript_err_tag = Fmake_symbol (build_string ("cmacs-lrgscript--err"));
      staticpro (&Vlrgscript_err_tag);
    }
}

/* internal_condition_case_1 body/handler for a plain Feval. */
static Lisp_Object
eval_form_body (Lisp_Object form)
{
  return Feval (form, Qnil);
}

/* body for a funcall: PACKED = (fn . args-list); apply fn to the list. */
static Lisp_Object
apply_body (Lisp_Object packed)
{
  Lisp_Object av[2];
  av[0] = XCAR (packed);
  av[1] = XCDR (packed);
  return Fapply (2, av);
}

static Lisp_Object
err_handler (Lisp_Object data)
{
  return Fcons (Vlrgscript_err_tag, data);
}

/* Store a g_strdup'd message from a tagged error cons into *ERR. */
static void
take_error (Lisp_Object tagged, gchar **err)
{
  if (err == NULL)
    return;
  Lisp_Object data = XCDR (tagged);
  Lisp_Object msg = Ferror_message_string (data);
  *err = STRINGP (msg) ? g_strdup (SSDATA (msg)) : g_strdup ("elisp error");
}

/* Run BODY(ARG) under the input guard, catching all signals.  On success
 * return TRUE and store the value in *OUT; on a signalled error return FALSE
 * and set *ERR (caller g_free). */
static gboolean
guarded_run (Lisp_Object (*body) (Lisp_Object),
             Lisp_Object   arg,
             Lisp_Object  *out,
             gchar       **err)
{
  Lisp_Object result;
  bool was_waiting;

  ensure_err_tag ();

  was_waiting = waiting_for_input;
  if (was_waiting)
    clear_waiting_for_input ();
  result = internal_condition_case_1 (body, arg, Qt, err_handler);
  if (was_waiting)
    set_waiting_for_input (input_available_clear_time);

  if (CONSP (result) && EQ (XCAR (result), Vlrgscript_err_tag))
    {
      take_error (result, err);
      return FALSE;
    }

  if (out != NULL)
    *out = result;
  return TRUE;
}

/* ── GValue <-> Lisp_Object marshalling ───────────────────────────── */

void
cmacs_lrgscript_bridge_lisp_to_gvalue (Lisp_Object v, GValue *out)
{
  if (NILP (v))
    {
      g_value_init (out, G_TYPE_BOOLEAN);
      g_value_set_boolean (out, FALSE);
    }
  else if (EQ (v, Qt))
    {
      g_value_init (out, G_TYPE_BOOLEAN);
      g_value_set_boolean (out, TRUE);
    }
  else if (FIXNUMP (v))
    {
      g_value_init (out, G_TYPE_INT64);
      g_value_set_int64 (out, XFIXNUM (v));
    }
  else if (BIGNUMP (v))
    {
      g_value_init (out, G_TYPE_INT64);
      g_value_set_int64 (out, bignum_to_intmax (v));
    }
  else if (FLOATP (v))
    {
      g_value_init (out, G_TYPE_DOUBLE);
      g_value_set_double (out, XFLOAT_DATA (v));
    }
  else if (STRINGP (v))
    {
      g_value_init (out, G_TYPE_STRING);
      g_value_set_string (out, SSDATA (v));
    }
  else if (SYMBOLP (v))
    {
      /* Interned symbol -> its name as a string. */
      Lisp_Object nm = SYMBOL_NAME (v);
      g_value_init (out, G_TYPE_STRING);
      g_value_set_string (out, SSDATA (nm));
    }
  else
    {
      /* Fallback: printed representation.  Lists, vectors, etc. cross the
       * GValue boundary as their prin1 text (documented limitation). */
      Lisp_Object printed = Fprin1_to_string (v, Qnil, Qnil);
      g_value_init (out, G_TYPE_STRING);
      g_value_set_string (out, SSDATA (printed));
    }
}

Lisp_Object
cmacs_lrgscript_bridge_gvalue_to_lisp (const GValue *v)
{
  GType t;

  if (v == NULL || !G_IS_VALUE (v))
    return Qnil;

  t = G_VALUE_TYPE (v);

  switch (G_TYPE_FUNDAMENTAL (t))
    {
    case G_TYPE_BOOLEAN:
      return g_value_get_boolean (v) ? Qt : Qnil;
    case G_TYPE_CHAR:
      return make_fixnum (g_value_get_schar (v));
    case G_TYPE_UCHAR:
      return make_fixnum (g_value_get_uchar (v));
    case G_TYPE_INT:
      return make_int (g_value_get_int (v));
    case G_TYPE_UINT:
      return make_int (g_value_get_uint (v));
    case G_TYPE_LONG:
      return make_int (g_value_get_long (v));
    case G_TYPE_ULONG:
      return make_int (g_value_get_ulong (v));
    case G_TYPE_INT64:
      return make_int (g_value_get_int64 (v));
    case G_TYPE_UINT64:
      return make_uint (g_value_get_uint64 (v));
    case G_TYPE_ENUM:
      return make_int (g_value_get_enum (v));
    case G_TYPE_FLAGS:
      return make_uint (g_value_get_flags (v));
    case G_TYPE_FLOAT:
      return make_float (g_value_get_float (v));
    case G_TYPE_DOUBLE:
      return make_float (g_value_get_double (v));
    case G_TYPE_STRING:
      {
        const gchar *s = g_value_get_string (v);
        return s ? build_string (s) : Qnil;
      }
    default:
      return Qnil;
    }
}

/* ── load / call / globals ────────────────────────────────────────── */

gboolean
cmacs_lrgscript_bridge_load_string (const gchar *name,
                                    const gchar *code,
                                    gchar      **err)
{
  Lisp_Object wrapped, form;

  if (code == NULL)
    {
      if (err) *err = g_strdup ("null code");
      return FALSE;
    }

  /* cmacs convention: a single form is read from the string, so wrap the
   * (possibly multi-form) script body in a progn.  NAME is currently only
   * carried for future error context. */
  (void) name;
  wrapped = concat3 (build_string ("(progn\n"), build_string (code),
                     build_string ("\n)"));
  form = Fcar (Fread_from_string (wrapped, Qnil, Qnil));

  return guarded_run (eval_form_body, form, NULL, err);
}

gboolean
cmacs_lrgscript_bridge_load_file (const gchar *path, gchar **err)
{
  Lisp_Object form;

  if (path == NULL)
    {
      if (err) *err = g_strdup ("null path");
      return FALSE;
    }

  /* (load PATH nil t t): NOERROR=nil, NOMESSAGE=t, NOSUFFIX=t so the exact
   * path is loaded without suffix probing or echo-area noise. */
  form = list5 (intern ("load"), build_string (path), Qnil, Qt, Qt);
  return guarded_run (eval_form_body, form, NULL, err);
}

gboolean
cmacs_lrgscript_bridge_fboundp (const gchar *name)
{
  if (name == NULL)
    return FALSE;
  return !NILP (Ffboundp (intern (name)));
}

gboolean
cmacs_lrgscript_bridge_call (const gchar  *name,
                             guint         n_args,
                             const GValue *args,
                             GValue       *ret,
                             gchar       **err)
{
  Lisp_Object fn, args_list, packed, result;
  guint i;

  if (name == NULL)
    {
      if (err) *err = g_strdup ("null function name");
      return FALSE;
    }

  fn = intern (name);
  if (NILP (Ffboundp (fn)))
    {
      if (err) *err = g_strdup_printf ("no such function: %s", name);
      return FALSE;
    }

  /* Build the argument list from the GValue array (reverse-cons then it is
   * already in order because we prepend from the end). */
  args_list = Qnil;
  for (i = n_args; i > 0; i--)
    args_list = Fcons (cmacs_lrgscript_bridge_gvalue_to_lisp (&args[i - 1]),
                       args_list);

  packed = Fcons (fn, args_list);
  if (!guarded_run (apply_body, packed, &result, err))
    return FALSE;

  if (ret != NULL)
    cmacs_lrgscript_bridge_lisp_to_gvalue (result, ret);
  return TRUE;
}

gboolean
cmacs_lrgscript_bridge_get_global (const gchar *name,
                                   GValue      *out,
                                   gchar      **err)
{
  Lisp_Object sym, val;

  if (name == NULL)
    {
      if (err) *err = g_strdup ("null variable name");
      return FALSE;
    }

  sym = intern (name);
  if (NILP (Fboundp (sym)))
    {
      if (err) *err = g_strdup_printf ("void variable: %s", name);
      return FALSE;
    }

  val = find_symbol_value (sym);
  cmacs_lrgscript_bridge_lisp_to_gvalue (val, out);
  return TRUE;
}

gboolean
cmacs_lrgscript_bridge_set_global (const gchar  *name,
                                   const GValue *val,
                                   gchar       **err)
{
  Lisp_Object sym, lval;

  if (name == NULL)
    {
      if (err) *err = g_strdup ("null variable name");
      return FALSE;
    }

  sym = intern (name);
  lval = cmacs_lrgscript_bridge_gvalue_to_lisp (val);
  Fset (sym, lval);
  return TRUE;
}

/* ── host-function trampoline binding ─────────────────────────────── */

gboolean
cmacs_lrgscript_bridge_bind_host_fn (const gchar *name, gchar **err)
{
  Lisp_Object sym, bound;

  if (name == NULL)
    {
      if (err) *err = g_strdup ("null host-function name");
      return FALSE;
    }

  /* (fset 'NAME (apply-partially #'cmacs-lrgscript--invoke-host "NAME")) */
  sym = intern (name);
  bound = calln (intern ("apply-partially"),
                 intern ("cmacs-lrgscript--invoke-host"),
                 build_string (name));
  Ffset (sym, bound);
  return TRUE;
}

void
cmacs_lrgscript_bridge_unbind_host_fn (const gchar *name)
{
  if (name == NULL)
    return;
  Ffmakunbound (intern (name));
}

#endif /* HAVE_CMACS_LRGSCRIPT */
