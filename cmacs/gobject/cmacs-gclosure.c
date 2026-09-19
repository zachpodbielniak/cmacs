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
#include "cmacs-eval-dispatch.h"

#include <glib-object.h>

/* ──────────────────────────────────────────────────────────────────── */
/* GC protection for closure functions                                 */
/* ──────────────────────────────────────────────────────────────────── */

/* All live Elisp closures are held on this list so the Emacs GC does
   not collect the lambda while GLib still references it.  Each entry
   is a (FUNC) cons owned by exactly one GClosure -- added in
   cmacs_gclosure_new, removed in the invalidate notifier when that
   closure is freed.  The cons, not FUNC, is what is delq'd: the same
   function object connected to two signals used to lose BOTH roots
   when either handler was disconnected, and the survivor then ran a
   collected lambda.  */
static Lisp_Object cmacs_gclosure_prevent_gc_list;

/* ──────────────────────────────────────────────────────────────────── */
/* Elisp GClosure type                                                 */
/* ──────────────────────────────────────────────────────────────────── */

typedef struct
{
  GClosure closure;
  Lisp_Object func;
  /* This closure's own entry on cmacs_gclosure_prevent_gc_list. */
  Lisp_Object cell;
} CmacsElispClosure;

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

  /* Marshal signal parameters to elisp through the one converter
   * gobject-get also uses, so a handler sees the same Lisp value for a
   * type that a property read gives.  This used to keep its own table,
   * which tested `type == G_TYPE_ENUM': an enum parameter has a
   * DERIVED type, so every enum a signal carried arrived as nil.
   * Skip param_values[0], the instance (already known). */
  for (i = 1; i < n_param_values; i++)
    args[i] = cmacs_gvalue_to_lisp (&param_values[i]);

  /* Call the elisp function.
   *
   * GLib may dispatch this closure while Emacs is in input-wait
   * (e.g. xg_select → g_main_context_dispatch).  If waiting_for_input
   * is set and the Elisp code signals an error, signal_or_quit aborts
   * unconditionally.  cmacs_dispatch_safe_callN_value clears the flag
   * around the call so errors stay inside safe_funcall's
   * condition-case, and binds `inhibit-interaction': a handler that
   * reached a minibuffer prompt from inside a GLib dispatch entered a
   * recursive edit underneath it and wedged the editor (see
   * cmacs-eval-dispatch.c).  */
  result = cmacs_dispatch_safe_callN_value (args[0],
                                            (ptrdiff_t) n_param_values - 1,
                                            args + 1);

  /* If the signal expects a return value, marshal it back.  Only
   * non-signalling conversions: this is a GLib callback frame. */
  if (return_value != NULL && G_VALUE_TYPE (return_value) != G_TYPE_NONE)
    {
      GType rtype = G_VALUE_TYPE (return_value);

      if (rtype == G_TYPE_BOOLEAN)
        g_value_set_boolean (return_value, !NILP (result));
      else if (rtype == G_TYPE_INT && FIXNUMP (result))
        g_value_set_int (return_value, (gint)XFIXNUM (result));
      else if (rtype == G_TYPE_UINT && FIXNATP (result))
        g_value_set_uint (return_value, (guint)XFIXNAT (result));
      else if (rtype == G_TYPE_DOUBLE && NUMBERP (result))
        g_value_set_double (return_value, XFLOATINT (result));
      else if (G_TYPE_IS_ENUM (rtype) && FIXNUMP (result))
        g_value_set_enum (return_value, (gint)XFIXNUM (result));
      else if (G_TYPE_IS_FLAGS (rtype) && FIXNATP (result))
        g_value_set_flags (return_value, (guint)XFIXNAT (result));
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
        Fdelq (eclosure->cell, cmacs_gclosure_prevent_gc_list);
      return;
    }

  {
    /* The Lisp_Object is copied by value: the closure is being torn down
       and must not be read from the idle.  The cell stays reachable
       from the list until the idle runs, so the copy is a live root. */
    Lisp_Object *held = g_malloc (sizeof *held);

    *held = eclosure->cell;
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

  /* Protect the function from GC while the closure is alive, through a
     cell that belongs to this closure alone. */
  eclosure->cell = Fcons (func, Qnil);
  cmacs_gclosure_prevent_gc_list =
    Fcons (eclosure->cell, cmacs_gclosure_prevent_gc_list);

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
