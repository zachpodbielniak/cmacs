/*
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

/* cmacs-eval-dispatch.c — shared dispatch for CMacs eval operations
 *
 * Transport-agnostic dispatch: the D-Bus service and socketpair IPC
 * handler both call these functions.  They run on the Emacs main
 * thread via the CMacs GMainContext.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-eval-dispatch.h"

#include <glib.h>

/* ── Safe evaluation helpers ───────────────────────────────────────── */

static Lisp_Object
dispatch_eval_body (Lisp_Object form)
{
  return Feval (form, Qnil);
}

static Lisp_Object
dispatch_eval_error (Lisp_Object err)
{
  return Fcons (Qerror, Ferror_message_string (err));
}

static Lisp_Object
dispatch_safe_eval (Lisp_Object form)
{
  return internal_condition_case_1 (dispatch_eval_body, form,
                                    Qt, dispatch_eval_error);
}

static gboolean
dispatch_result_is_error (Lisp_Object result)
{
  return CONSP (result) && EQ (XCAR (result), Qerror);
}

#define CMACS_DISPATCH_ERROR_DOMAIN (g_quark_from_static_string ("cmacs-dispatch"))

/* ── Public API ────────────────────────────────────────────────────── */

gchar *
cmacs_dispatch_eval (const gchar *expression, GError **error)
{
  Lisp_Object form, result, printed;

  form = Fcar (Fread_from_string (build_string (expression), Qnil, Qnil));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

void
cmacs_dispatch_find_file (const gchar *path)
{
  safe_calln (intern ("find-file"), build_string (path));
}

void
cmacs_dispatch_message (const gchar *text)
{
  safe_calln (intern ("message"), build_string (text));
}

gboolean
cmacs_dispatch_gi_require (const gchar *ns, const gchar *ver,
                           GError **error)
{
  Lisp_Object form, result;

  form = list3 (intern ("gi-require"),
                build_string (ns), build_string (ver));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return FALSE;
    }

  return !NILP (result);
}

gchar *
cmacs_dispatch_gi_call (const gchar *ns, const gchar *func,
                        const gchar *const *args, gint n_args,
                        GError **error)
{
  Lisp_Object args_list, form, result, printed;
  gint i;

  /* Build args list from strings, reading each as a Lisp expression. */
  args_list = Qnil;
  for (i = n_args - 1; i >= 0; i--)
    {
      Lisp_Object parsed =
        Fcar (Fread_from_string (build_string (args[i]), Qnil, Qnil));
      args_list = Fcons (parsed, args_list);
    }

  /* Build: (gi-call "NS" "func" arg1 arg2 ...) */
  form = Fcons (intern ("gi-call"),
                Fcons (build_string (ns),
                       Fcons (build_string (func), args_list)));
  result = dispatch_safe_eval (form);

  if (dispatch_result_is_error (result))
    {
      Lisp_Object msg = XCDR (result);
      g_set_error (error, CMACS_DISPATCH_ERROR_DOMAIN, 1,
                   "%s", STRINGP (msg) ? SSDATA (msg) : "unknown error");
      return NULL;
    }

  printed = Fprin1_to_string (result, Qnil, Qnil);
  return g_strdup (SSDATA (printed));
}

gchar **
cmacs_dispatch_gi_list_functions (const gchar *ns)
{
  Lisp_Object form, result, tail;
  GPtrArray *arr;

  form = list2 (intern ("gi-list-functions"), build_string (ns));
  result = dispatch_safe_eval (form);

  arr = g_ptr_array_new ();
  if (!dispatch_result_is_error (result))
    {
      tail = result;
      while (CONSP (tail))
        {
          Lisp_Object s = XCAR (tail);
          if (STRINGP (s))
            g_ptr_array_add (arr, g_strdup (SSDATA (s)));
          tail = XCDR (tail);
        }
    }
  g_ptr_array_add (arr, NULL);
  return (gchar **)g_ptr_array_free (arr, FALSE);
}

#endif /* HAVE_CMACS_GLIB */
