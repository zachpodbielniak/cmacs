/* cmacs-gowl-pointer-history.c --- where the pointer was, a moment ago
 *
 * Copyright (C) 2026 Zach Podbielniak
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See cmacs-gowl-pointer-history.h.
 *
 * The ring.  HISTORY_SIZE fixed entries, written by a timer that fires
 * every HISTORY_PERIOD_MS on the compositor's wl_event_loop -- never on
 * GLib's default context, which under cmacs is pgtk's loop on Emacs's
 * thread and would run the callback without the gowl lock.  The timer
 * exists only while the history is enabled.
 *
 * A tick stores a sample only when something changed since the last
 * one (the pointer moved, or what is under it did), so an entry means
 * "from this time on, until the next entry".  A still pointer therefore
 * costs nothing and the ring reaches back much further than
 * HISTORY_SIZE * HISTORY_PERIOD_MS (about ten seconds, the worst case
 * of a pointer that never rests).  No allocation per sample.
 *
 * Clients are stored by id, never by pointer: a window can close
 * between the sample and the lookup, and a lookup turns an id back into
 * an object only after finding it in the live client list.
 *
 * Times are CLOCK_MONOTONIC milliseconds (g_get_monotonic_time () /
 * 1000), the clock `gowl-pointer-history-now' returns.
 *
 * Locking.  The ring is written on the dispatch thread and read on
 * Emacs's; both sides hold the recursive gowl lock.  The callback takes
 * it itself rather than relying on the dispatcher holding it.  */

#include <config.h>

#ifdef HAVE_CMACS_GOWL

#include <math.h>
#include <string.h>

#include "lisp.h"
#include "cmacs-gowl.h"
#include "cmacs-gobject.h"
#include "cmacs-eval-dispatch.h"
#include "cmacs-gowl-pointer-history.h"
#include <gowl.h>
#include <wayland-server-core.h>

/* A power of two, so an index wraps with a mask.  */
#define HISTORY_SIZE 512
#define HISTORY_MASK (HISTORY_SIZE - 1)
/* 50 Hz: finer than a hand settles on a target, and coarse next to the
   other errors in the chain (see doc_org/cmacs/cmacs-deixis.org).  */
#define HISTORY_PERIOD_MS 20
/* A move smaller than this is not a new sample.  */
#define HISTORY_MIN_MOVE 0.5
/* Samples this close together (layout pixels) are one dwell, unless
   the caller says otherwise.  */
#define HISTORY_DWELL_RADIUS 48.0

struct history_sample
{
  gint64 ms;                    /* monotonic, when this state began */
  double x, y;                  /* layout pixels */
  guint client;                 /* gowl client id under the pointer, 0: none */
  gint monitor;                 /* index in the monitor list, -1: none */
};

static struct history_sample history_ring[HISTORY_SIZE];
static unsigned int history_head;    /* next slot to write */
static unsigned int history_count;   /* valid entries, <= HISTORY_SIZE */
static bool history_enabled;
static gint64 history_last_tick;     /* monotonic ms of the last tick */

static struct wl_event_source *history_timer;
/* The compositor whose loop HISTORY_TIMER is on.  Only ever compared,
   never dereferenced: when it is not the running compositor the source
   went with its loop, and removing it again would be a use after free.  */
static GowlCompositor *history_timer_owner;

static gint64
history_now (void)
{
  return g_get_monotonic_time () / 1000;
}

/* Entry I, 0 being the oldest.  Caller holds the lock.  */
static struct history_sample *
history_entry (unsigned int i)
{
  return &history_ring[(history_head - history_count + i) & HISTORY_MASK];
}

static void
history_clear (void)
{
  memset (history_ring, 0, sizeof history_ring);
  history_head = 0;
  history_count = 0;
  history_last_tick = 0;
}

/* The index of the monitor containing X, Y, or -1.  Caller holds the
   lock.  */
static gint
history_monitor_at (double x, double y)
{
  GList *l;
  gint i = 0;

  for (l = gowl_compositor_get_monitors (cmacs_gowl_compositor); l != NULL;
       l = l->next, i++)
    {
      gint mx = 0, my = 0, mw = 0, mh = 0;

      gowl_monitor_get_geometry (l->data, &mx, &my, &mw, &mh);
      if (x >= mx && x < mx + mw && y >= my && y < my + mh)
        return i;
    }
  return -1;
}

/* One tick: note the pointer's state if it changed.  Caller holds the
   lock.  */
static void
history_sample_now (void)
{
  struct history_sample s, *last;
  GowlClient *c;

  /* A locked session has nothing to point at, and what the pointer does
     over a lock screen is nobody's business.  */
  if (cmacs_gowl_compositor == NULL
      || gowl_compositor_is_locked (cmacs_gowl_compositor)
      || !gowl_compositor_get_cursor_position (cmacs_gowl_compositor,
                                               &s.x, &s.y))
    return;

  s.ms = history_now ();
  history_last_tick = s.ms;
  /* The scene-graph hit test pointer focus uses: the window a click
     would land on, not merely one whose geometry contains the point.  */
  c = gowl_compositor_client_at (cmacs_gowl_compositor, s.x, s.y);
  s.client = c != NULL ? gowl_client_get_id (c) : 0;
  s.monitor = history_monitor_at (s.x, s.y);

  if (history_count > 0)
    {
      last = history_entry (history_count - 1);
      if (last->client == s.client && last->monitor == s.monitor
          && fabs (last->x - s.x) < HISTORY_MIN_MOVE
          && fabs (last->y - s.y) < HISTORY_MIN_MOVE)
        return;
    }
  history_ring[history_head] = s;
  history_head = (history_head + 1) & HISTORY_MASK;
  if (history_count < HISTORY_SIZE)
    history_count++;
}

/* The wl_event_loop timer.  Runs on the thread that dispatches the
   compositor's loop.  */
static int
history_timer_cb (void *data)
{
  (void) data;
  cmacs_gowl_lock ();
  if (history_enabled && history_timer != NULL)
    {
      history_sample_now ();
      wl_event_source_timer_update (history_timer, HISTORY_PERIOD_MS);
    }
  cmacs_gowl_unlock ();
  return 0;
}

/* Take the timer off the loop.  Caller holds the lock.  */
static void
history_timer_stop (void)
{
  if (history_timer != NULL
      && history_timer_owner == cmacs_gowl_compositor
      && cmacs_gowl_compositor != NULL)
    wl_event_source_remove (history_timer);
  history_timer = NULL;
  history_timer_owner = NULL;
}

void
cmacs_gowl_pointer_history_forget (void)
{
  cmacs_gowl_lock ();
  history_timer_stop ();
  history_enabled = false;
  history_clear ();
  cmacs_gowl_unlock ();
}

/* The live client with ID, or NULL: the window a sample named may have
   closed since.  Caller holds the lock.  */
static GowlClient *
history_live_client (guint id)
{
  GList *l;

  if (id == 0 || cmacs_gowl_compositor == NULL)
    return NULL;
  for (l = gowl_compositor_get_clients (cmacs_gowl_compositor); l != NULL;
       l = l->next)
    if (gowl_client_get_id (l->data) == id)
      return l->data;
  return NULL;
}

/* ----------------------------------------------------------- Lisp half -- */

/* Hold the gowl lock for the rest of this call; the release is on the
   specpdl, so a signal below cannot leave the dispatch thread wedged
   (mirrors cmacs-gowl.c's own).  */
static specpdl_ref
cmacs_gowl_lock_scoped (void)
{
  specpdl_ref count = SPECPDL_INDEX ();

  cmacs_gowl_lock ();
  record_unwind_protect_void (cmacs_gowl_unlock);
  return count;
}

/* The plist a lookup returns.  :client is the live client object or nil;
   :client-id is what the sample recorded (0: nothing was under the
   pointer), so a caller can tell "nothing there" from "a window that
   has closed since".  DURATION < 0: no :duration entry.  Caller holds
   the lock.  */
static Lisp_Object
history_plist (gint64 ms, double x, double y, guint client, gint monitor,
               gint64 duration)
{
  GowlClient *c = history_live_client (client);
  Lisp_Object tail = Qnil;

  if (duration >= 0)
    tail = list2 (intern_c_string (":duration"), make_int (duration));
  tail = Fcons (intern_c_string (":monitor"),
                Fcons (monitor >= 0 ? make_fixnum (monitor) : Qnil, tail));
  tail = Fcons (intern_c_string (":client-id"),
                Fcons (make_fixnum ((EMACS_INT) client), tail));
  tail = Fcons (intern_c_string (":client"),
                Fcons (c != NULL ? cmacs_gobject_wrap (G_OBJECT (c)) : Qnil,
                       tail));
  tail = Fcons (intern_c_string (":y"), Fcons (make_float (y), tail));
  tail = Fcons (intern_c_string (":x"), Fcons (make_float (x), tail));
  return Fcons (intern_c_string (":time"), Fcons (make_int (ms), tail));
}

/* A time argument in milliseconds, integer or float.  */
static gint64
history_ms_arg (Lisp_Object ms)
{
  CHECK_NUMBER (ms);
  return (gint64) XFLOATINT (ms);
}

DEFUN ("gowl-pointer-history-now", Fgowl_pointer_history_now,
       Sgowl_pointer_history_now, 0, 0, 0,
       doc: /* Return the monotonic clock in milliseconds.
This is the clock the pointer history's samples are stamped with
\(CLOCK_MONOTONIC); it has no relation to `float-time'.  */)
  (void)
{
  return make_int (history_now ());
}

DEFUN ("gowl-pointer-history-enable", Fgowl_pointer_history_enable,
       Sgowl_pointer_history_enable, 1, 1, 0,
       doc: /* Start (ENABLE non-nil) or stop sampling the pointer's position.
While on, the compositor notes where the pointer is and which window is
under it, fifty times a second, in a fixed ring in memory -- about ten
seconds of a pointer that never rests, far longer for one that does.
Nothing is written anywhere else, nothing is sampled while the session
is locked, and turning the history off empties the ring.

Return non-nil when the history is now on.  With no compositor running
this does nothing and returns nil.  */)
  (Lisp_Object enable)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();

  if (cmacs_gowl_compositor == NULL)
    {
      /* Whatever was there belonged to a compositor that is gone.  */
      history_timer_stop ();
      history_enabled = false;
      history_clear ();
      return unbind_to (lock_count, Qnil);
    }

  if (NILP (enable))
    {
      history_timer_stop ();
      history_enabled = false;
      history_clear ();
      return unbind_to (lock_count, Qnil);
    }

  /* A timer left from an earlier compositor is not ours to remove.  */
  if (history_timer != NULL && history_timer_owner != cmacs_gowl_compositor)
    history_timer_stop ();

  if (history_timer == NULL)
    {
      struct wl_event_loop *loop
        = gowl_compositor_get_event_loop (cmacs_gowl_compositor);

      history_clear ();
      history_timer = loop != NULL
        ? wl_event_loop_add_timer (loop, history_timer_cb, NULL) : NULL;
      if (history_timer == NULL)
        {
          history_enabled = false;
          return unbind_to (lock_count, Qnil);
        }
      history_timer_owner = cmacs_gowl_compositor;
      wl_event_source_timer_update (history_timer, HISTORY_PERIOD_MS);
    }
  history_enabled = true;
  /* So a lookup right after enabling has something to find.  */
  history_sample_now ();
  return unbind_to (lock_count, Qt);
}

DEFUN ("gowl-pointer-history-enabled-p", Fgowl_pointer_history_enabled_p,
       Sgowl_pointer_history_enabled_p, 0, 0, 0,
       doc: /* Return non-nil while the pointer history is sampling.  */)
  (void)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();

  return unbind_to (lock_count,
                    history_enabled && cmacs_gowl_compositor != NULL
                    ? Qt : Qnil);
}

DEFUN ("gowl-pointer-history-at", Fgowl_pointer_history_at,
       Sgowl_pointer_history_at, 1, 1, 0,
       doc: /* Return where the pointer was at time MS.
MS is on the clock of `gowl-pointer-history-now'.  The value is a plist
\(:time T :x X :y Y :client CLIENT :client-id ID :monitor N) for the
latest sample at or before MS: T is when the pointer came to be there,
X and Y are layout pixels, N the index of the output in
`gowl-list-monitors' (nil off every output).  ID is the id of the
window that was under the pointer (0: none) and CLIENT that window, or
nil when there was none or it has closed since.

Return nil when the history is off or MS is older than the ring.  */)
  (Lisp_Object ms)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  gint64 t = history_ms_arg (ms);
  unsigned int i;

  if (!history_enabled || cmacs_gowl_compositor == NULL)
    return unbind_to (lock_count, Qnil);
  for (i = history_count; i > 0; i--)
    {
      struct history_sample *s = history_entry (i - 1);

      if (s->ms <= t)
        return unbind_to (lock_count,
                          history_plist (s->ms, s->x, s->y, s->client,
                                         s->monitor, -1));
    }
  return unbind_to (lock_count, Qnil);
}

DEFUN ("gowl-pointer-history-dwell", Fgowl_pointer_history_dwell,
       Sgowl_pointer_history_dwell, 2, 3, 0,
       doc: /* Return where the pointer rested longest between FROM-MS and TO-MS.
People point a little before or after the word, so the caller asks about
a window of time around it.  The samples in the window (and the one in
force when it opens) are grouped into dwells -- runs over the same
window that stay within RADIUS layout pixels (default 48) of where the
run began -- and the dwell that lasted longest wins; of equals, the
earliest.

The value is as for `gowl-pointer-history-at', with X and Y the
time-weighted mean of the dwell, T when it began (not before FROM-MS)
and an added :duration in milliseconds.  Return nil when the history is
off or holds nothing for the window.  */)
  (Lisp_Object from_ms, Lisp_Object to_ms, Lisp_Object radius)
{
  specpdl_ref lock_count = cmacs_gowl_lock_scoped ();
  gint64 from = history_ms_arg (from_ms);
  gint64 to = history_ms_arg (to_ms);
  double r = HISTORY_DWELL_RADIUS;
  unsigned int i, start = 0;
  bool have_start = false;
  /* The dwell being built and the best one so far.  WEIGHT is its time
     plus one per sample, so a dwell of zero length still has a mean.  */
  struct dwell
  {
    bool open;
    gint64 begin, duration;
    double ax, ay, sx, sy, weight;
    guint client;
    gint monitor;
  } cur = { 0 }, best = { 0 };

  if (!NILP (radius))
    {
      CHECK_NUMBER (radius);
      r = XFLOATINT (radius);
    }
  if (to < from)
    {
      gint64 swap = from;
      from = to;
      to = swap;
    }
  if (!history_enabled || cmacs_gowl_compositor == NULL
      || history_count == 0)
    return unbind_to (lock_count, Qnil);

  /* Start from the state in force when the window opens: the latest
     sample at or before FROM.  With none (the window opens before the
     ring does), from the oldest sample inside it.  */
  for (i = history_count; i > 0 && !have_start; i--)
    if (history_entry (i - 1)->ms <= from)
      {
        start = i - 1;
        have_start = true;
      }
  if (!have_start)
    {
      if (history_entry (0)->ms > to)
        return unbind_to (lock_count, Qnil);
      start = 0;
    }

  for (i = start; i < history_count; i++)
    {
      struct history_sample *s = history_entry (i);
      gint64 t0, t1;
      double w;

      if (s->ms > to)
        break;
      /* This state lasted until the next sample, or is still so.  */
      t0 = s->ms > from ? s->ms : from;
      t1 = (i + 1 < history_count && history_entry (i + 1)->ms < to)
        ? history_entry (i + 1)->ms : to;
      if (t1 < t0)
        t1 = t0;
      w = (double) (t1 - t0) + 1.0;

      if (cur.open && cur.client == s->client
          && hypot (s->x - cur.ax, s->y - cur.ay) <= r)
        {
          cur.duration += t1 - t0;
          cur.sx += s->x * w;
          cur.sy += s->y * w;
          cur.weight += w;
        }
      else
        {
          if (cur.open && (!best.open || cur.duration > best.duration))
            best = cur;
          cur.open = true;
          cur.begin = t0;
          cur.duration = t1 - t0;
          cur.ax = s->x;
          cur.ay = s->y;
          cur.sx = s->x * w;
          cur.sy = s->y * w;
          cur.weight = w;
          cur.client = s->client;
          cur.monitor = s->monitor;
        }
    }
  if (cur.open && (!best.open || cur.duration > best.duration))
    best = cur;
  if (!best.open)
    return unbind_to (lock_count, Qnil);
  return unbind_to (lock_count,
                    history_plist (best.begin, best.sx / best.weight,
                                   best.sy / best.weight, best.client,
                                   best.monitor, best.duration));
}

void
syms_of_cmacs_gowl_pointer_history (void)
{
  defsubr (&Sgowl_pointer_history_now);
  defsubr (&Sgowl_pointer_history_enable);
  defsubr (&Sgowl_pointer_history_enabled_p);
  defsubr (&Sgowl_pointer_history_at);
  defsubr (&Sgowl_pointer_history_dwell);
}

#endif /* HAVE_CMACS_GOWL */
