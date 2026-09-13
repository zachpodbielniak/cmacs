/* cmacs-gclosure.c — GClosure ↔ elisp function bridge
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * All closures fire on the Emacs main thread.  If a GLib API fires a
 * closure from a worker thread, the call is queued to the CMacs
 * GMainContext and runs there instead.
 *
 * THIS FILE SAID THAT FOR A YEAR AND DID NOT DO IT.  The marshaller
 * called safe_funcall on whatever thread GLib dispatched it on, and
 * under `cmacs --gowl' that is the compositor's dispatch thread: every
 * window that set a title ran Elisp beside a main thread that was very
 * often already in the Lisp VM.  `specpdl' belongs to current_thread
 * and a foreign pthread does not have one, so both threads pushed and
 * popped the MAIN thread's unwind stack.  The result is not a wrong
 * answer, it is a garbage function pointer in a SPECPDL_UNWIND slot,
 * which the next `do_one_unbind' calls: SIGSEGV at 0x0 or 0x31, on
 * whichever thread reached it first, with a backtrace naming neither
 * the writer nor the cause.  Two cores on 2026-09-13, one of them nine
 * seconds into a session because session restore maps clients that
 * immediately set titles.
 *
 * So the hop below is not an optimisation and not tidiness.  Note that
 * it has to happen BEFORE the parameters are marshalled: building a
 * Lisp object allocates, and allocating is exactly as unsafe as
 * calling.
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "cmacs-gclosure.h"
#include "cmacs-gobject.h"
#include "cmacs-glib-loop.h"

#include <glib-object.h>

/* ──────────────────────────────────────────────────────────────────── */
/* GC protection for closure functions                                 */
/* ──────────────────────────────────────────────────────────────────── */

/* All live Elisp closures are held on this list so the Emacs GC does
   not collect the lambda while GLib still references it.  Entries are
   added in cmacs_gclosure_new and removed in the invalidate
   notifier when the GClosure is freed.  */
static Lisp_Object cmacs_gclosure_prevent_gc_list;

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

/* One deferred closure call: everything needed to run it later, owning
   a reference to all of it.  The GValue copies matter -- a signal's
   parameters live only for the length of the emission, and a copy of a
   GObject-typed value takes a reference, which is what keeps the
   GowlClient in a `client-title-changed' alive until the hook runs. */
typedef struct
{
  GClosure *closure;
  guint     n_values;
  GValue   *values;
} CmacsDeferredCall;

static void
cmacs_deferred_call_free (gpointer data)
{
  CmacsDeferredCall *call = data;
  guint i;

  for (i = 0; i < call->n_values; i++)
    {
      if (G_IS_VALUE (&call->values[i]))
        g_value_unset (&call->values[i]);
    }
  g_free (call->values);
  g_closure_unref (call->closure);
  g_free (call);
}

static void cmacs_gclosure_invoke (GClosure *closure, GValue *return_value,
                                   guint n_param_values,
                                   const GValue *param_values);

/* Runs on the Lisp thread, from the CMacs context. */
static gboolean
cmacs_gclosure_deferred_idle (gpointer data)
{
  CmacsDeferredCall *call = data;

  /* The closure may have been invalidated between the emission and now
     -- the object it was connected to went away.  g_closure_ref keeps
     the struct alive; `is_invalid' says whether it still means
     anything. */
  if (!call->closure->is_invalid)
    cmacs_gclosure_invoke (call->closure, NULL, call->n_values,
                           call->values);
  return G_SOURCE_REMOVE;
}

/* Marshal: called by GLib when the signal fires, on whatever thread the
   emitter happened to be on. */
static void
cmacs_gclosure_marshal (GClosure     *closure,
                        GValue       *return_value,
                        guint         n_param_values,
                        const GValue *param_values,
                        gpointer      invocation_hint,
                        gpointer      marshal_data)
{
  (void)invocation_hint;
  (void)marshal_data;

  if (cmacs_glib_on_main_thread ())
    {
      cmacs_gclosure_invoke (closure, return_value, n_param_values,
                             param_values);
      return;
    }

  /* Off the Lisp thread.  Copy everything and run it there instead.
     Nothing below this point may touch Lisp -- not even to build an
     argument. */
  {
    CmacsDeferredCall *call;
    guint i;

    if (return_value != NULL && G_VALUE_TYPE (return_value) != G_TYPE_NONE)
      {
        /* A handler whose answer the emitter reads cannot be deferred:
           by the time it runs, the emitter has long since used the
           default.  Running it late is still better than corrupting the
           VM, so the call goes ahead and this says so once. */
        static gboolean warned = FALSE;
        if (!warned)
          {
            warned = TRUE;
            g_warning ("cmacs-gclosure: a signal expecting a return value "
                       "fired off the Lisp thread; the handler will run, "
                       "but its value cannot be given back");
          }
      }

    call = g_new0 (CmacsDeferredCall, 1);
    call->closure = g_closure_ref (closure);
    call->n_values = n_param_values;
    call->values = g_new0 (GValue, n_param_values);
    for (i = 0; i < n_param_values; i++)
      {
        g_value_init (&call->values[i], G_VALUE_TYPE (&param_values[i]));
        g_value_copy (&param_values[i], &call->values[i]);
      }
    cmacs_glib_invoke_on_main (cmacs_gclosure_deferred_idle, call,
                               cmacs_deferred_call_free);
  }
}

/* The actual call.  ALWAYS on the Lisp thread. */
static void
cmacs_gclosure_invoke (GClosure     *closure,
                       GValue       *return_value,
                       guint         n_param_values,
                       const GValue *param_values)
{
  CmacsElispClosure *eclosure = (CmacsElispClosure *)closure;
  Lisp_Object *args;
  Lisp_Object result;
  guint i;

  /* The last line of defence.  If some future path reaches here off the
     Lisp thread without going through the hop above, refusing is a lost
     event; carrying on is memory corruption that surfaces later,
     somewhere else, as an unattributable crash. */
  if (!cmacs_glib_on_main_thread ())
    {
      g_critical ("cmacs-gclosure: refusing to run Elisp off the Lisp "
                  "thread; the handler was dropped");
      return;
    }

  /* Allocate args on the stack.  GLib signals rarely exceed 8 params. */
  args = (Lisp_Object *)alloca ((n_param_values + 1) * sizeof (Lisp_Object));

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
      /* glong and gint64 are both EMACS_INT's own width on an LP64
         build, so naming the cast is a -Wuseless-cast; the implicit
         conversion is still correct where they differ.  G_TYPE_UINT
         above keeps its cast because that one genuinely widens. */
      else if (type == G_TYPE_LONG)
        args[i] = make_fixnum (g_value_get_long (&param_values[i]));
      else if (type == G_TYPE_INT64)
        args[i] = make_fixnum (g_value_get_int64 (&param_values[i]));
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
      else if (g_type_is_a (type, G_TYPE_BOXED))
        {
          gpointer boxed = g_value_get_boxed (&param_values[i]);
          args[i] = boxed ? cmacs_boxed_wrap (type, boxed) : Qnil;
        }
      else
        args[i] = Qnil;
    }

  /* Call the elisp function.
   *
   * GLib may dispatch this closure while Emacs is in input-wait
   * (e.g. xg_select → g_main_context_dispatch).  If waiting_for_input
   * is set and the Elisp code signals an error, signal_or_quit aborts
   * unconditionally.  Temporarily clear the flag so errors are handled
   * normally by safe_funcall's condition-case wrapper.  */
  {
    bool was_waiting = waiting_for_input;
    if (was_waiting)
      waiting_for_input = false;
    result = safe_funcall ((ptrdiff_t)n_param_values, args);
    if (was_waiting)
      waiting_for_input = true;
  }

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

/* Drop one function from the GC protection list, on the Lisp thread. */
static gboolean
cmacs_gclosure_unprotect_idle (gpointer data)
{
  Lisp_Object *held = data;

  cmacs_gclosure_prevent_gc_list =
    Fdelq (*held, cmacs_gclosure_prevent_gc_list);
  return G_SOURCE_REMOVE;
}

static void
cmacs_gclosure_unprotect_free (gpointer data)
{
  g_free (data);
}

/*
 * A closure is invalidated when the object it was connected to is
 * finalised -- and under `cmacs --gowl' that happens on the compositor
 * thread: a monitor is unplugged, its GowlMonitor goes, and every
 * per-output bridge connected to it is invalidated right there.
 *
 * Fdelq walks and rewrites a Lisp list that the main thread's GC also
 * walks, so this is the same hazard as calling a handler off-thread,
 * only quieter: it corrupts a GC root rather than the unwind stack.
 * Deferring costs one cons of protection living until the next idle,
 * which is nothing.
 */
static void
cmacs_gclosure_invalidate (gpointer data, GClosure *closure)
{
  CmacsElispClosure *eclosure = (CmacsElispClosure *)closure;
  (void)data;

  if (cmacs_glib_on_main_thread ())
    {
      cmacs_gclosure_prevent_gc_list =
        Fdelq (eclosure->func, cmacs_gclosure_prevent_gc_list);
      return;
    }

  {
    /* The Lisp_Object is copied by value: the closure is being torn down
       and must not be read from the idle. */
    Lisp_Object *held = g_malloc (sizeof *held);

    *held = eclosure->func;
    cmacs_glib_invoke_on_main (cmacs_gclosure_unprotect_idle, held,
                               cmacs_gclosure_unprotect_free);
  }
}

GClosure *
cmacs_gclosure_new (Lisp_Object func)
{
  GClosure *closure;
  CmacsElispClosure *eclosure;

  closure = g_closure_new_simple (sizeof (CmacsElispClosure), NULL);
  eclosure = (CmacsElispClosure *)closure;
  eclosure->func = func;

  /* Protect the function from GC while the closure is alive. */
  cmacs_gclosure_prevent_gc_list =
    Fcons (func, cmacs_gclosure_prevent_gc_list);

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

void
cmacs_gclosure_init (void)
{
  cmacs_gclosure_prevent_gc_list = Qnil;
  staticpro (&cmacs_gclosure_prevent_gc_list);
}

#endif /* HAVE_CMACS_GLIB */
