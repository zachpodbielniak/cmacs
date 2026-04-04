/* cmacs-gclosure.c — GClosure ↔ elisp function bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * All closures fire on the Emacs main thread.  If a GLib API fires a
 * closure from a worker thread, the call is queued to the main
 * GMainContext via g_main_context_invoke().
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-gclosure.h"
#include "cmacs-gobject.h"
#include "cmacs-glib-loop.h"

#include <glib-object.h>

/* ──────────────────────────────────────────────────────────────────── */
/* Elisp GClosure type                                                 */
/* ──────────────────────────────────────────────────────────────────── */

typedef struct
{
  GClosure closure;
  Lisp_Object func;
} CmacsElispClosure;

/* Forward-declared from cmacs-gobject.c */
extern Lisp_Object cmacs_gvalue_to_lisp_external (const GValue *val);

/* Marshal: called by GLib when the signal fires. */
static void
cmacs_gclosure_marshal (GClosure     *closure,
                        GValue       *return_value,
                        guint         n_param_values,
                        const GValue *param_values,
                        gpointer      invocation_hint,
                        gpointer      marshal_data)
{
  CmacsElispClosure *eclosure = (CmacsElispClosure *)closure;
  Lisp_Object *args;
  Lisp_Object result;
  guint i;

  /* Allocate args on the stack.  GLib signals rarely exceed 8 params. */
  args = (Lisp_Object *)alloca ((n_param_values + 1) * sizeof (Lisp_Object));

  (void)invocation_hint;
  (void)marshal_data;

  args[0] = eclosure->func;

  /* Marshal signal parameters to elisp.
   * Skip param_values[0] which is the instance (already known). */
  for (i = 1; i < n_param_values; i++)
    {
      GType type = G_VALUE_TYPE (&param_values[i]);

      if (type == G_TYPE_BOOLEAN)
        args[i] = g_value_get_boolean (&param_values[i]) ? Qt : Qnil;
      else if (type == G_TYPE_INT)
        args[i] = make_fixnum (g_value_get_int (&param_values[i]));
      else if (type == G_TYPE_UINT)
        args[i] = make_fixnum ((EMACS_INT)g_value_get_uint (&param_values[i]));
      else if (type == G_TYPE_LONG)
        args[i] = make_fixnum ((EMACS_INT)g_value_get_long (&param_values[i]));
      else if (type == G_TYPE_INT64)
        args[i] = make_fixnum ((EMACS_INT)g_value_get_int64 (&param_values[i]));
      else if (type == G_TYPE_FLOAT)
        args[i] = make_float ((double)g_value_get_float (&param_values[i]));
      else if (type == G_TYPE_DOUBLE)
        args[i] = make_float (g_value_get_double (&param_values[i]));
      else if (type == G_TYPE_STRING)
        {
          const gchar *str = g_value_get_string (&param_values[i]);
          args[i] = str != NULL ? build_string (str) : Qnil;
        }
      else if (type == G_TYPE_ENUM)
        args[i] = make_fixnum (g_value_get_enum (&param_values[i]));
      else if (g_type_is_a (type, G_TYPE_OBJECT))
        args[i] = cmacs_gobject_wrap (g_value_get_object (&param_values[i]));
      else
        args[i] = Qnil;
    }

  /* Call the elisp function. */
  result = safe_funcall ((ptrdiff_t)n_param_values, args);

  /* If the signal expects a return value, marshal it back. */
  if (return_value != NULL && G_VALUE_TYPE (return_value) != G_TYPE_NONE)
    {
      GType rtype = G_VALUE_TYPE (return_value);

      if (rtype == G_TYPE_BOOLEAN)
        g_value_set_boolean (return_value, !NILP (result));
      else if (rtype == G_TYPE_INT && FIXNUMP (result))
        g_value_set_int (return_value, (gint)XFIXNUM (result));
      else if (rtype == G_TYPE_STRING && STRINGP (result))
        g_value_set_string (return_value, SSDATA (result));
    }
}

static void
cmacs_gclosure_invalidate (gpointer data, GClosure *closure)
{
  (void)data;
  (void)closure;
  /* Nothing to do — the elisp function is GC-protected by the
   * staticpro or by being referenced in a live closure.
   * When the GClosure is freed, GLib handles cleanup. */
}

GClosure *
cmacs_gclosure_new (Lisp_Object func)
{
  GClosure *closure;
  CmacsElispClosure *eclosure;

  closure = g_closure_new_simple (sizeof (CmacsElispClosure), NULL);
  eclosure = (CmacsElispClosure *)closure;
  eclosure->func = func;

  g_closure_set_marshal (closure, cmacs_gclosure_marshal);
  g_closure_add_invalidate_notifier (closure, NULL,
                                     cmacs_gclosure_invalidate);

  return closure;
}

gulong
cmacs_gclosure_connect (GObject *obj, const gchar *signal,
                        Lisp_Object func)
{
  GClosure *closure;
  gulong handler_id;

  closure = cmacs_gclosure_new (func);
  handler_id = g_signal_connect_closure (obj, signal, closure, FALSE);

  return handler_id;
}

#endif /* HAVE_CMACS_GLIB */
