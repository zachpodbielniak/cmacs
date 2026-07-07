/* cmacs-lrgscript-defuns.c --- Elisp-facing DEFUNs for the elisp backend.
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The cmacs-lrgscript-* commands.  These drive the genuine LrgScripting
 * object (via the opaque accessors in cmacs-lrgscript-object.h) so the
 * backend's vtable + GValue marshalling are exercised end to end and are
 * testable headlessly (no GL context needed for the scripting bridge).
 *
 * Includes lisp.h + glib, never <libregnum.h> (the firewall -- see
 * cmacs-lrgscript.h).  GValue is glib and safe alongside lisp.h. */

#include <config.h>

#ifdef HAVE_CMACS_LRGSCRIPT

#include "lisp.h"
#include "cmacs-lrgscript.h"
#include <glib.h>
#include <glib-object.h>

/* The error symbol `cmacs-lrgscript-error' is DEFSYM'd in syms_of below;
 * DEFSYM auto-generates Qcmacs_lrgscript_error into globals.h (make-docfile
 * scans this file textually), so no declaration is needed or allowed here. */

/* NAME may be a string or a symbol; return its C string (points into Lisp
 * storage that stays live for the call's duration). */
static const char *
name_c (Lisp_Object name)
{
  if (SYMBOLP (name) && !NILP (name))
    return SSDATA (SYMBOL_NAME (name));
  CHECK_STRING (name);
  return SSDATA (name);
}

static AVOID
signal_msg (char *msg, const char *fallback)
{
  Lisp_Object m = build_string (msg ? msg : fallback);
  g_free (msg);
  xsignal1 (Qcmacs_lrgscript_error, m);
}

/* Build a GValue array from N Lisp args (args[base..]); caller frees. */
static GValue *
build_gvalues (ptrdiff_t n, Lisp_Object *args)
{
  GValue *argv;
  ptrdiff_t i;

  if (n <= 0)
    return NULL;
  argv = g_new0 (GValue, n);
  for (i = 0; i < n; i++)
    cmacs_lrgscript_bridge_lisp_to_gvalue (args[i], &argv[i]);
  return argv;
}

static void
free_gvalues (GValue *argv, ptrdiff_t n)
{
  ptrdiff_t i;
  if (argv == NULL)
    return;
  for (i = 0; i < n; i++)
    if (G_IS_VALUE (&argv[i]))
      g_value_unset (&argv[i]);
  g_free (argv);
}

DEFUN ("cmacs-lrgscript-available-p", Fcmacs_lrgscript_available_p,
       Scmacs_lrgscript_available_p, 0, 0, 0,
       doc: /* Return t if the Emacs Lisp libregnum scripting backend is
registered and available.  When t, libregnum scene nodes and games can select
language "elisp" (LrgScriptLanguage value 5), and cmacs-libregnum-scripting-
languages lists it.  */)
  (void)
{
  return cmacs_lrgscript_available_p () ? Qt : Qnil;
}

DEFUN ("cmacs-lrgscript-eval", Fcmacs_lrgscript_eval,
       Scmacs_lrgscript_eval, 1, 1, 0,
       doc: /* Evaluate CODE (an elisp source string) in the scripting backend.
CODE may contain several top-level forms; it is wrapped in a `progn'.  Returns
t on success and signals `cmacs-lrgscript-error' on failure.  This runs through
the real LrgScripting elisp context, so it exercises the same path libregnum
scene scripts use.  For a return value, define a function and call it with
`cmacs-lrgscript-call'.  Best for ASCII/UTF-8 source; load non-trivial scripts
from a file (coding-correct) via the backend's load-file path.  */)
  (Lisp_Object code)
{
  char *err = NULL;
  CHECK_STRING (code);
  if (!cmacs_lrgscript_ctx_load_string (cmacs_lrgscript_shared_context (),
                                        "cmacs-lrgscript-eval",
                                        SSDATA (code), &err))
    signal_msg (err, "elisp scripting eval failed");
  return Qt;
}

DEFUN ("cmacs-lrgscript-call", Fcmacs_lrgscript_call,
       Scmacs_lrgscript_call, 1, MANY, 0,
       doc: /* Call elisp function NAME (string or symbol) with ARGS.
Arguments and the return value are marshalled across the GValue boundary the
libregnum scripting backend uses: integers, floats, strings and booleans
round-trip; other Lisp values cross as their printed form.  Signals
`cmacs-lrgscript-error' if NAME is unbound or signals.

usage: (cmacs-lrgscript-call NAME &rest ARGS)  */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  const char *fn = name_c (args[0]);
  ptrdiff_t n = nargs - 1;
  GValue *argv = build_gvalues (n, args + 1);
  GValue ret = G_VALUE_INIT;
  char *err = NULL;
  Lisp_Object result;
  bool ok;

  ok = cmacs_lrgscript_ctx_call (cmacs_lrgscript_shared_context (), fn,
                                 (guint) n, argv, &ret, &err);
  free_gvalues (argv, n);
  if (!ok)
    signal_msg (err, "elisp scripting call failed");

  result = cmacs_lrgscript_bridge_gvalue_to_lisp (&ret);
  if (G_IS_VALUE (&ret))
    g_value_unset (&ret);
  return result;
}

DEFUN ("cmacs-lrgscript-get", Fcmacs_lrgscript_get,
       Scmacs_lrgscript_get, 1, 1, 0,
       doc: /* Return the value of elisp global variable NAME via the backend.
NAME is a string or symbol.  Signals `cmacs-lrgscript-error' if unbound.  */)
  (Lisp_Object name)
{
  GValue out = G_VALUE_INIT;
  char *err = NULL;
  Lisp_Object result;

  if (!cmacs_lrgscript_ctx_get_global (cmacs_lrgscript_shared_context (),
                                       name_c (name), &out, &err))
    signal_msg (err, "elisp scripting get failed");

  result = cmacs_lrgscript_bridge_gvalue_to_lisp (&out);
  if (G_IS_VALUE (&out))
    g_value_unset (&out);
  return result;
}

DEFUN ("cmacs-lrgscript-set", Fcmacs_lrgscript_set,
       Scmacs_lrgscript_set, 2, 2, 0,
       doc: /* Set elisp global variable NAME to VALUE via the backend.
NAME is a string or symbol; VALUE is marshalled across the GValue boundary.  */)
  (Lisp_Object name, Lisp_Object value)
{
  GValue v = G_VALUE_INIT;
  char *err = NULL;
  bool ok;

  cmacs_lrgscript_bridge_lisp_to_gvalue (value, &v);
  ok = cmacs_lrgscript_ctx_set_global (cmacs_lrgscript_shared_context (),
                                       name_c (name), &v, &err);
  if (G_IS_VALUE (&v))
    g_value_unset (&v);
  if (!ok)
    signal_msg (err, "elisp scripting set failed");
  return value;
}

DEFUN ("cmacs-lrgscript--invoke-host", Fcmacs_lrgscript__invoke_host,
       Scmacs_lrgscript__invoke_host, 1, MANY, 0,
       doc: /* Internal: trampoline for a registered host C function NAME.
Bound to NAME by LrgScripting::register_function so a script's call to NAME
dispatches to the C callback.  Not for direct use.

usage: (cmacs-lrgscript--invoke-host NAME &rest ARGS)  */)
  (ptrdiff_t nargs, Lisp_Object *args)
{
  const char *fn = name_c (args[0]);
  ptrdiff_t n = nargs - 1;
  GValue *argv = build_gvalues (n, args + 1);
  GValue ret = G_VALUE_INIT;
  char *err = NULL;
  Lisp_Object result;
  bool ok;

  ok = cmacs_lrgscript_invoke_host_fn (fn, (guint) n, argv, &ret, &err);
  free_gvalues (argv, n);
  if (!ok)
    signal_msg (err, "host function failed");

  result = cmacs_lrgscript_bridge_gvalue_to_lisp (&ret);
  if (G_IS_VALUE (&ret))
    g_value_unset (&ret);
  return result;
}

void
syms_of_cmacs_lrgscript_defuns (void)
{
  DEFSYM (Qcmacs_lrgscript_error, "cmacs-lrgscript-error");
  Fput (Qcmacs_lrgscript_error, Qerror_conditions,
        list2 (Qcmacs_lrgscript_error, Qerror));
  Fput (Qcmacs_lrgscript_error, Qerror_message,
        build_string ("cmacs-lrgscript error"));

  defsubr (&Scmacs_lrgscript_available_p);
  defsubr (&Scmacs_lrgscript_eval);
  defsubr (&Scmacs_lrgscript_call);
  defsubr (&Scmacs_lrgscript_get);
  defsubr (&Scmacs_lrgscript_set);
  defsubr (&Scmacs_lrgscript__invoke_host);
}

#endif /* HAVE_CMACS_LRGSCRIPT */
