/* cmacs-glib-loop.c — GLib event loop integration for Emacs
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Strategy: do NOT replace the Emacs event loop.  Instead, integrate
 * GMainContext as a source within it:
 *
 *  1. Create a GMainContext owned by CMacs
 *  2. Before each Emacs pselect() call, query GMainContext for its fds
 *     and timeouts via g_main_context_query()
 *  3. Add those fds to Emacs's fd_set
 *  4. After pselect() returns, call g_main_context_check() and
 *     g_main_context_dispatch() to fire any ready GLib sources
 *  5. GLib callbacks fire on the Emacs event loop thread — no threads
 */

#include <config.h>

#ifdef HAVE_CMACS_GLIB

#include "lisp.h"
#include "timespec.h"
#include "keyboard.h"
#include "cmacs-glib-loop.h"
#include "cmacs-glib-screenshot.h"
#include "cmacs-ink-overlay.h"

#include <glib.h>
#include <stdlib.h>
#include <string.h>

/* The CMacs-owned GMainContext.  All GLib sources created by CMacs
 * are attached to this context.  It is NOT the GLib default context
 * (which PGTK/GTK may own). */
static GMainContext *cmacs_context = NULL;

/* Scratch arrays for g_main_context_query() results.
 * Grown as needed.  Persistent to avoid per-iteration alloc. */
static GPollFD *poll_fds = NULL;
static gint     poll_fds_alloc = 0;
static gint     poll_fds_count = 0;
static gint     poll_max_priority = 0;

/* TRUE when cmacs_glib_prepare successfully acquired the context.
 * Guards cmacs_glib_prepare against re-entrant calls (a GLib
 * callback may eval Lisp that re-enters wait_reading_process_output
 * → cmacs_glib_prepare → would try to acquire an already-held
 * context, corrupting the poll_fds scratch array). */
static bool cmacs_context_acquired = false;

/* TRUE while cmacs_glib_dispatch is actively running its
 * check/dispatch loop on cmacs_context.  Guards against re-entrant
 * calls from GLib callbacks that evaluate Lisp → sleep-for /
 * accept-process-output → wait_reading_process_output →
 * cmacs_glib_dispatch.  Without this flag the inner invocation
 * would call g_main_context_check and g_main_context_dispatch on a
 * context that the outer invocation is still iterating, mutating
 * the pending-dispatches list mid-iteration and tripping g_main's
 * `source->context == context` assertion (gmain.c g_main_dispatch).
 * Note: cmacs_context_acquired is *not* a suitable reentry guard
 * here because the outer dispatch leaves it set for the full
 * duration of its check/dispatch/release cycle -- by design, since
 * inner cmacs_glib_prepare needs it true to know it shouldn't
 * acquire again.  We need a second, orthogonal flag. */
static bool cmacs_context_dispatching = false;

/* ──────────────────────────────────────────────────────────────────── */
/* Event loop hooks                                                    */
/* ──────────────────────────────────────────────────────────────────── */

int
cmacs_glib_prepare (fd_set *readable, fd_set *writeable,
                    struct timespec *timeout)
{
  gint glib_timeout_ms;
  gint n_fds;
  gint i;
  int max_glib_fd = -1;

  if (cmacs_context == NULL)
    return -1;

  /* Acquire and prepare — tells GLib sources to report readiness.
   * If we already hold the context (re-entrant call from a GLib
   * callback → Lisp → wait_reading_process_output), skip GLib
   * integration for this iteration to avoid corrupting the shared
   * poll_fds array and double-dispatching sources. */
  if (cmacs_context_acquired)
    return -1;

  if (!g_main_context_acquire (cmacs_context))
    return -1;

  cmacs_context_acquired = true;

  g_main_context_prepare (cmacs_context, &poll_max_priority);

  /* Query how many fds GLib wants us to poll. */
  n_fds = g_main_context_query (cmacs_context, poll_max_priority,
                                &glib_timeout_ms, NULL, 0);

  /* Grow scratch array if needed. */
  if (n_fds > poll_fds_alloc)
    {
      poll_fds_alloc = n_fds + 16;
      poll_fds = g_renew (GPollFD, poll_fds, poll_fds_alloc);
    }

  /* Query again with the properly-sized array. */
  poll_fds_count = g_main_context_query (cmacs_context, poll_max_priority,
                                         &glib_timeout_ms,
                                         poll_fds, poll_fds_alloc);

  /* Merge GLib fds into Emacs fd_sets. */
  for (i = 0; i < poll_fds_count; i++)
    {
      gint fd = poll_fds[i].fd;
      if (fd < 0 || fd >= FD_SETSIZE)
        continue;

      if (poll_fds[i].events & (G_IO_IN | G_IO_HUP | G_IO_ERR))
        FD_SET (fd, readable);

      if (poll_fds[i].events & G_IO_OUT)
        FD_SET (fd, writeable);

      if (fd > max_glib_fd)
        max_glib_fd = fd;
    }

  /* If GLib needs a shorter timeout, reduce ours.
   * glib_timeout_ms == -1 means "no timeout" (infinite). */
  if (glib_timeout_ms >= 0 && timeout != NULL)
    {
      struct timespec glib_ts;
      glib_ts.tv_sec = glib_timeout_ms / 1000;
      glib_ts.tv_nsec = (glib_timeout_ms % 1000) * 1000000L;

      if (timespec_cmp (glib_ts, *timeout) < 0)
        *timeout = glib_ts;
    }

  return max_glib_fd;
}

void
cmacs_glib_dispatch (fd_set *readable, int nfds)
{
  gint i;

  if (cmacs_context == NULL || !cmacs_context_acquired)
    return;

  /* Reentry guard.  cmacs_glib_prepare already blocks the inner
   * wait_reading_process_output from contributing fds to the
   * pselect (see cmacs_context_acquired check at the top of
   * cmacs_glib_prepare), but wait_reading_process_output still
   * unconditionally calls cmacs_glib_dispatch after pselect.  We
   * must no-op here when we're already inside an outer dispatch,
   * otherwise the inner call runs g_main_context_check +
   * g_main_context_dispatch + g_main_context_release on a context
   * the outer g_main_context_dispatch is still iterating, which
   * mutates `context->pending_dispatches' mid-walk and trips an
   * assertion in g_main_dispatch (`source->context == context').
   *
   * The outer dispatch still owns the acquire and will perform the
   * check/dispatch/release sequence when it unwinds.  The inner
   * call must be a pure no-op -- no check, no dispatch, no release. */
  if (cmacs_context_dispatching)
    return;
  cmacs_context_dispatching = true;

  /* If pselect failed, just release the context — fd_sets are undefined. */
  if (nfds < 0)
    {
      g_main_context_release (cmacs_context);
      cmacs_context_acquired = false;
      cmacs_context_dispatching = false;
      return;
    }

  /* Map pselect() results back to GPollFD revents.
   *
   * IMPORTANT: when nfds == 0 (pselect returned due to timeout), the
   * fd_sets may contain stale bits from before the call — Linux does
   * not zero them on timeout.  Only consult FD_ISSET when nfds > 0
   * (i.e. at least one fd was actually ready).  Timeout and idle
   * GLib sources still fire correctly via their ready_time. */
  for (i = 0; i < poll_fds_count; i++)
    {
      gint fd = poll_fds[i].fd;
      poll_fds[i].revents = 0;

      if (nfds == 0 || fd < 0 || fd >= FD_SETSIZE)
        continue;

      if (FD_ISSET (fd, readable))
        poll_fds[i].revents |= (poll_fds[i].events & (G_IO_IN | G_IO_HUP));
    }

  /* Let GLib check and dispatch ready sources.
   *
   * GLib callbacks (IPC, D-Bus, idle handlers) may evaluate Lisp code.
   * We are called from wait_reading_process_output, where
   * `waiting_for_input' may be true (e.g. during read_char → sit_for).
   * Emacs aborts unconditionally if any Lisp error is signaled while
   * `waiting_for_input' is set, because signal_or_quit treats it as an
   * "impossible" situation.  Temporarily clear the flag so that Lisp
   * errors in GLib callbacks are handled normally, then restore it.
   *
   * Note: we do *not* push cmacs_context as thread-default across
   * this dispatch.  An earlier revision tried that, intending to
   * make async GIO calls from cmacs_context callbacks attach their
   * new sources to cmacs_context.  It caused a latent reentrancy
   * bug to surface as a hard crash: holding cmacs_context as
   * thread-default across a long Lisp call made GTK/GDK's async
   * callbacks (frame clock, iconify paths, etc.) also attach to
   * cmacs_context, fattening its pending-dispatches list; when Lisp
   * then re-entered wait_reading_process_output via sleep-for, the
   * inner dispatch walked the same mutated list and tripped
   * g_main_dispatch's `source->context == context' assertion.  The
   * MCP-on-wrong-context problem the push was solving is handled
   * from the Lisp-error side by dispatch_safe_eval's own
   * waiting_for_input clear/restore guard in
   * cmacs/glib/cmacs-eval-dispatch.c. */
  g_main_context_check (cmacs_context, poll_max_priority,
                        poll_fds, poll_fds_count);
  {
    bool was_waiting = waiting_for_input;
    if (was_waiting)
      clear_waiting_for_input ();
    g_main_context_dispatch (cmacs_context);
    if (was_waiting)
      set_waiting_for_input (input_available_clear_time);
  }
  g_main_context_release (cmacs_context);
  cmacs_context_acquired = false;
  cmacs_context_dispatching = false;
}

GMainContext *
cmacs_glib_get_context (void)
{
  return cmacs_context;
}

/* ──────────────────────────────────────────────────────────────────── */
/* DEFUN primitives                                                    */
/* ──────────────────────────────────────────────────────────────────── */

DEFUN ("cmacs-glib-context-p", Fcmacs_glib_context_p,
       Scmacs_glib_context_p, 0, 0, 0,
       doc: /* Return non-nil if the CMacs GLib context is initialized. */)
  (void)
{
  return cmacs_context != NULL ? Qt : Qnil;
}

DEFUN ("cmacs-glib-iteration", Fcmacs_glib_iteration,
       Scmacs_glib_iteration, 0, 1, 0,
       doc: /* Run one iteration of the GLib main loop.
If BLOCK is non-nil, block until a source is ready.
Return non-nil if any sources were dispatched. */)
  (Lisp_Object block)
{
  gboolean dispatched;

  if (cmacs_context == NULL)
    return Qnil;

  dispatched = g_main_context_iteration (cmacs_context, !NILP (block));
  return dispatched ? Qt : Qnil;
}

DEFUN ("cmacs-glib-pending-p", Fcmacs_glib_pending_p,
       Scmacs_glib_pending_p, 0, 0, 0,
       doc: /* Return non-nil if GLib sources are pending dispatch. */)
  (void)
{
  if (cmacs_context == NULL)
    return Qnil;

  return g_main_context_pending (cmacs_context) ? Qt : Qnil;
}

/* Callback data for cmacs-glib-timeout-add. */
typedef struct
{
  Lisp_Object callback;
} CmacsGlibTimerData;

static gboolean
cmacs_glib_timer_cb (gpointer user_data)
{
  CmacsGlibTimerData *data = (CmacsGlibTimerData *)user_data;
  Lisp_Object result;

  /* Call the elisp function.  If it returns nil, remove the source. */
  result = safe_calln (data->callback);
  return !NILP (result);
}

static void
cmacs_glib_timer_destroy (gpointer user_data)
{
  CmacsGlibTimerData *data = (CmacsGlibTimerData *)user_data;
  /* Allow GC to collect the callback. */
  (void)data;
  g_free (data);
}

DEFUN ("cmacs-glib-timeout-add", Fcmacs_glib_timeout_add,
       Scmacs_glib_timeout_add, 2, 2, 0,
       doc: /* Add a GLib timeout source that calls CALLBACK every MS milliseconds.
CALLBACK is called with no arguments.  If it returns nil, the timer is removed.
Returns a source ID (integer) that can be used to remove it. */)
  (Lisp_Object ms, Lisp_Object callback)
{
  CmacsGlibTimerData *data;
  GSource *source;
  guint source_id;

  CHECK_FIXNAT (ms);
  CHECK_TYPE (FUNCTIONP (callback), Qfunctionp, callback);

  if (cmacs_context == NULL)
    error ("CMacs GLib context not initialized");

  data = g_new0 (CmacsGlibTimerData, 1);
  data->callback = callback;

  source = g_timeout_source_new ((guint)XFIXNAT (ms));
  g_source_set_callback (source, cmacs_glib_timer_cb, data,
                         cmacs_glib_timer_destroy);
  source_id = g_source_attach (source, cmacs_context);
  g_source_unref (source);

  return make_fixnum (source_id);
}

DEFUN ("cmacs-glib-source-remove", Fcmacs_glib_source_remove,
       Scmacs_glib_source_remove, 1, 1, 0,
       doc: /* Remove a GLib source by its ID.
Returns non-nil if the source was found and removed. */)
  (Lisp_Object source_id)
{
  GSource *source;

  CHECK_FIXNAT (source_id);

  source = g_main_context_find_source_by_id (cmacs_context,
                                             (guint)XFIXNAT (source_id));
  if (source == NULL)
    return Qnil;

  g_source_destroy (source);
  return Qt;
}

DEFUN ("cmacs-glib-idle-add", Fcmacs_glib_idle_add,
       Scmacs_glib_idle_add, 1, 1, 0,
       doc: /* Add a GLib idle source that calls CALLBACK when idle.
CALLBACK is called with no arguments.  If it returns nil, the source is removed.
Returns a source ID. */)
  (Lisp_Object callback)
{
  CmacsGlibTimerData *data;
  GSource *source;
  guint source_id;

  CHECK_TYPE (FUNCTIONP (callback), Qfunctionp, callback);

  if (cmacs_context == NULL)
    error ("CMacs GLib context not initialized");

  data = g_new0 (CmacsGlibTimerData, 1);
  data->callback = callback;

  source = g_idle_source_new ();
  g_source_set_callback (source, cmacs_glib_timer_cb, data,
                         cmacs_glib_timer_destroy);
  source_id = g_source_attach (source, cmacs_context);
  g_source_unref (source);

  return make_fixnum (source_id);
}

/* ──────────────────────────────────────────────────────────────────── */
/* Init                                                                */
/* ──────────────────────────────────────────────────────────────────── */

void
init_cmacs_glib (void)
{
  cmacs_context = g_main_context_new ();
}

/* ──────────────────────────────────────────────────────────────────────
 * cmacs-setenv: libc setenv(3) wrapper
 *
 * Emacs's built-in `setenv' only manipulates `process-environment'
 * (the Lisp variable used to build subprocess env via make-process).
 * It does NOT call libc setenv(3), so any C code that reads
 * `getenv()' directly -- including glib's g_find_program_in_path()
 * used by cmacs-piper, plus everything inside GStreamer plugins,
 * libsoup, etc. -- sees the original libc environ unchanged.
 *
 * `cmacs-env.el' calls this DEFUN after updating
 * `process-environment' to keep the two views in sync.  Without it,
 * piper (and any other tool resolved via libc PATH lookups) stays
 * invisible to cmacs even when `executable-find' finds it just
 * fine. */

DEFUN ("cmacs-setenv", Fcmacs_setenv, Scmacs_setenv, 2, 2, 0,
       doc: /* Call libc setenv(3) on NAME=VALUE.  Both strings.
This is required in addition to the Lisp `setenv', whose effect is
confined to `process-environment' and not visible to C code that
reads `getenv()' directly (glib, GStreamer, libsoup, etc.).

Returns t on success, nil on failure.  */)
  (Lisp_Object name, Lisp_Object value)
{
  CHECK_STRING (name);
  CHECK_STRING (value);
  /* setenv copies the strings internally, so SDATA -> char* is safe. */
  int rc = setenv ((const char *) SDATA (name),
                   (const char *) SDATA (value),
                   1 /* overwrite */);
  return rc == 0 ? Qt : Qnil;
}

void
syms_of_cmacs_glib (void)
{
  defsubr (&Scmacs_glib_context_p);
  defsubr (&Scmacs_glib_iteration);
  defsubr (&Scmacs_glib_pending_p);
  defsubr (&Scmacs_glib_timeout_add);
  defsubr (&Scmacs_glib_source_remove);
  defsubr (&Scmacs_glib_idle_add);
  defsubr (&Scmacs_setenv);

  /* Frame Cairo screenshot DEFUNs (cmacs-glib-screenshot.c) live in
     a sibling translation unit; pull their symbols into the same
     init pass so emacs.c only has to call us once. */
  syms_of_cmacs_glib_screenshot ();

  /* Post-glyph ink overlay paint hook needs to staticpro a few
     symbols.  Cheap to fold into the same init. */
  syms_of_cmacs_ink_overlay ();
}

#endif /* HAVE_CMACS_GLIB */
